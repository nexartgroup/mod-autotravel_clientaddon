-- AT_Net.lua
-- ---------------------------------------------------------------------------
-- Verbindung zum Servermodul: Handschlag, Sendewarteschlange, Protokoll.
--
-- Ablauf
--
--   Login  ->  ".at hello"  ->  "[AT]H|..."  ->  Zustand READY
--
-- Erst nach dem Handschlag gehen Modulbefehle hinaus. Gruende:
--
--   * Fehlt das Servermodul, antwortet AzerothCore auf jeden ".at ..."-Befehl mit
--     "Es gibt keinen solchen Befehl" -- bei jedem Klick. Auf Servern mit
--     AllowPlayerCommands = 0 (nicht Standard) behandelt der Core den Befehl
--     sogar als gewoehnlichen Text (ChatHandler::_ParseCommands), und der
--     Charakter riefe ".at start ..." in /sagen.
--   * Der Handschlag liefert Version, Protokoll und die Berechtigungen dieses
--     Spielers. Damit blendet das Addon Knoepfe aus, die der Server ohnehin
--     abwiese.
--
-- Befehle, die gar nicht vom Modul stammen (".playerbots ..."), sind davon
-- ausgenommen (raw = true).
--
-- Zustaende
--
--   UNKNOWN        noch kein Handschlag versucht
--   HELLO          Anfrage unterwegs
--   READY          Modul antwortet, Protokoll passt
--   ABSENT         keine Antwort: Modul fehlt oder Server ist offline
--   INCOMPATIBLE   Modul zu alt fuer dieses Addon
--   DISABLED       Modul ist serverseitig abgeschaltet
--
-- Sendewarteschlange
--
--   Der Client hat eine eigene Flutbremse, deshalb gehen Befehle mit Abstand
--   hinaus: 0,45 s normal, 0,10 s fuer dringende (Pause, Weiter, Stop).
--   Befehle mit gleichem Schluessel ersetzen einander -- ein Schieberegler, der
--   zehn Werte meldet, schickt am Ende nur den letzten.
-- ---------------------------------------------------------------------------

AutoTravel = AutoTravel or {}
local AT = AutoTravel

AT.Net = {}
local N = AT.Net

N.PROTOCOL     = 4      -- Protokollversion, die dieses Addon spricht
N.MIN_PROTOCOL = 3      -- aeltere Servermodule (3.x) sprechen dieselben Nachrichten

N.state = "UNKNOWN"

-- Faehigkeiten, die der Server meldet (siehe ATCapability im Servermodul).
N.CAP = { HANDOVER = 1, ROUTE = 2, TAXI = 4, TELEPORT = 8, SETTINGS = 16, TRANSPORT = 32 }

AT.server = {
   known    = false,   -- true, sobald ein Handschlag beantwortet wurde
   capsKnown = false,  -- false bei aelteren Servermodulen ohne Faehigkeitsfeld
   version  = "?",
   proto    = 0,
   enabled  = true,
   nodes    = 0,
   taxi     = false,
   afk      = false,
   sec      = 0,       -- Kontostufe: 0 Spieler, 1 Moderator, 2 Spielleiter, 3 Admin
   caps     = 0,
}

-- Der Server haelt zwischen zwei aufwaendigen Befehlen eines Spielers 400 ms
-- Abstand ein (AutoTravel.CommandCooldownMs). Der Abstand hier liegt knapp
-- darueber: zwei dicht hintereinander gesendete Befehle wuerden sonst am zweiten
-- mit "Zu schnell" abgewiesen.
local GAP_NORMAL     = 0.45
local GAP_URGENT     = 0.10
local HELLO_TIMEOUT  = 5.0
local HELD_MAX       = 30

local urgentQ, normalQ, held = {}, {}, {}
local lastSent = 0
local helloTries, helloDeadline = 0, 0
local lastWarn = 0

-- ---------------------------------------------------------------------------
-- Hilfen
-- ---------------------------------------------------------------------------

local function HasBit(value, bitValue)
   return (math.floor((value or 0) / bitValue) % 2) == 1
end

-- Darf der Spieler diese Faehigkeit benutzen? Bei unbekanntem Stand wird
-- optimistisch "ja" gemeldet: besser ein Knopf, den der Server abweist, als ein
-- Knopf, der bei einem aelteren Modul nie erscheint.
function N.Can(capName)
   local s = AT.server
   if N.state == "ABSENT" or N.state == "INCOMPATIBLE" or N.state == "DISABLED" then
      return false
   end
   if not s.capsKnown then return true end
   return HasBit(s.caps, N.CAP[capName] or 0)
end

function N.IsReady() return N.state == "READY" end

local function WarnThrottled(text)
   local now = GetTime()
   if (now - lastWarn) < 20 then return end
   lastWarn = now
   AT.Warn(text)
end

local function RemoveKeyed(list, key)
   for i = #list, 1, -1 do
      if list[i].key == key then table.remove(list, i) end
   end
end

local function Enqueue(item)
   local q = item.urgent and urgentQ or normalQ
   if item.key then RemoveKeyed(q, item.key) end
   table.insert(q, item)
end

-- Die laufende Reise im Addon beenden, weil der Server sie nie aufnehmen wird
-- (kein Modul, zu alt, abgeschaltet). Ein Start, der auf den Handschlag wartete,
-- liesse AT.active sonst auf true und den Zustand auf "Startet" stehen.
local function AbortLocalTrip()
   AT.pendingStartAt = nil
   if AT.active or AT.status.state == "STARTING" then
      AT.active = false
      AT.status.state = "IDLE"
      AT.status.progress = 0
   end
   if AT.UI then AT.UI.Update() end
end

-- ---------------------------------------------------------------------------
-- Senden
-- ---------------------------------------------------------------------------

-- cmd    Befehl ohne fuehrenden Punkt ("at stop") oder eine Funktion
-- opts   key     ersetzt einen noch wartenden Befehl mit demselben Schluessel
--        tag     Gruppe, die sich gemeinsam verwerfen laesst (DropTag)
--        urgent  eigene, schnellere Spur (Pause, Weiter, Stop)
--        raw     kein Modulbefehl: braucht keinen Handschlag
--
-- Rueckgabe: true, wenn der Befehl angenommen (gesendet oder vorgemerkt) wurde.
function N.Send(cmd, opts)
   opts = opts or {}
   local item = { cmd = cmd, key = opts.key, tag = opts.tag, urgent = opts.urgent }

   if opts.raw or N.state == "READY" then
      Enqueue(item)
      return true
   end

   if N.state == "UNKNOWN" or N.state == "HELLO" then
      -- Handschlag laeuft oder steht aus: vormerken, nach READY abschicken.
      if #held >= HELD_MAX then table.remove(held, 1) end
      table.insert(held, item)
      if N.state == "UNKNOWN" then N.Hello() end
      return true
   end

   if N.state == "DISABLED" then
      WarnThrottled("mod-autotravel ist auf diesem Server abgeschaltet.")
   elseif N.state == "INCOMPATIBLE" then
      WarnThrottled("Das Servermodul ist zu alt fuer dieses Addon (Protokoll " ..
                    tostring(AT.server.proto) .. ", gebraucht ab " .. N.MIN_PROTOCOL .. ").")
   else
      WarnThrottled("Keine Verbindung zu mod-autotravel. '/at hello' versucht es erneut.")
   end
   return false
end

-- Dringender Befehl: Pause, Weiter, Stop.
function N.SendNow(cmd, key)
   return N.Send(cmd, { urgent = true, key = key })
end

-- Beliebige Aktion in dieselbe Warteschlange (z. B. Fluesterbefehle an den
-- Playerbot), damit sich beides nicht ins Gehege kommt. Mit 'tag' markierte
-- Aktionen lassen sich gemeinsam wieder verwerfen (DropTag).
function N.Queue(fn, tag)
   Enqueue({ cmd = fn, tag = tag })
end

-- Verwirft alle noch wartenden Aktionen mit diesem Tag. Gebraucht, wenn sich
-- eine Voraussetzung zerschlaegt, nachdem die Folgebefehle schon eingereiht sind
-- (der Server verweigert den Selbstmodus, die Strategiebefehle sind sinnlos).
function N.DropTag(tag)
   local dropped = 0
   -- Auch die vorgemerkten Befehle: ein Start, der noch auf den Handschlag
   -- wartet, muss sich ebenfalls zurueckziehen lassen.
   for _, q in ipairs({ urgentQ, normalQ, held }) do
      for i = #q, 1, -1 do
         if q[i].tag == tag then table.remove(q, i) dropped = dropped + 1 end
      end
   end
   return dropped
end

local function FlushHeld()
   for i = 1, #held do Enqueue(held[i]) end
   held = {}
end

local function Transmit(item)
   if type(item.cmd) == "function" then
      item.cmd()
   else
      SendChatMessage("." .. item.cmd, "SAY")
      AT.Debug("-> ." .. item.cmd)
   end
end

-- ---------------------------------------------------------------------------
-- Handschlag
-- ---------------------------------------------------------------------------

function N.Hello()
   if N.state == "HELLO" then return end
   N.state = "HELLO"
   helloTries = 1
   helloDeadline = GetTime() + HELLO_TIMEOUT
   Enqueue({ cmd = "at hello", urgent = true, key = "hello" })
end

local function HelloFailed()
   N.state = "ABSENT"
   held = {}
   AT.Warn("Keine Antwort von mod-autotravel. Ist das Servermodul installiert und aktiv? " ..
           "'/at hello' versucht es erneut.")
   AbortLocalTrip()
   if AT.Options then AT.Options.Load() end
end

local function Num(v, default)
   local n = tonumber(v)
   if n == nil then return default end
   return n
end

local function OnHello(body)
   local ver, enabled, nodes, taxi, afk, proto, sec, caps = strsplit("|", body)
   local s = AT.server

   s.known    = true
   s.version  = ver or "?"
   s.enabled  = Num(enabled, 1) ~= 0
   s.nodes    = Num(nodes, 0)
   s.taxi     = Num(taxi, 0) ~= 0
   s.afk      = Num(afk, 0) ~= 0
   s.proto    = Num(proto, 3)           -- Module vor 4.0 melden keine Protokollnummer
   s.sec      = Num(sec, 0)
   s.capsKnown = (caps ~= nil and caps ~= "")
   s.caps     = Num(caps, 0)

   if s.proto < N.MIN_PROTOCOL then
      N.state = "INCOMPATIBLE"
      held = {}
      AT.Warn("Das Servermodul (Version " .. s.version .. ") ist zu alt fuer dieses Addon.")
      AbortLocalTrip()
   elseif not s.enabled then
      N.state = "DISABLED"
      held = {}
      AT.Warn("mod-autotravel ist auf diesem Server abgeschaltet.")
      AbortLocalTrip()
   else
      N.state = "READY"
      if s.proto > N.PROTOCOL then
         AT.Warn("Das Servermodul spricht ein neueres Protokoll (" .. s.proto ..
                 ") als dieses Addon (" .. N.PROTOCOL .. "). Bitte das Addon aktualisieren.")
      end
      AT.Debug(string.format("Server %s, Protokoll %d, Rechte %d, Faehigkeiten %d, %d Knoten",
               s.version, s.proto, s.sec, s.caps, s.nodes))
      FlushHeld()
   end

   if AT.OnServerKnown then AT.OnServerKnown() end
end

-- ---------------------------------------------------------------------------
-- Statusmeldung
-- ---------------------------------------------------------------------------
--
--   [AT]S|<zustand>|<restdistanz>|<ziel>|<flags>|<pfadpunkte>|<versuche>|<etappe>|<etappen>|<fortschritt>
--
-- flags: 1 beritten, 2 fliegt, 4 schwimmt, 8 Server steuert, 16 vom Spieler pausiert
--
-- Fehlende Felder gelten als 0: so bleibt das Addon lesbar, falls ein anderes
-- Modul weniger oder mehr Felder schickt. Zusaetzliche Felder werden ignoriert.

local INACTIVE = { IDLE = true, ARRIVED = true, FAILED = true }

local function OnStatus(body)
   local st, dist, target, flags, pts, att, leg, legs, prog = strsplit("|", body)
   if not st or st == "" then return end

   local f = Num(flags, 0)
   local old = AT.status.state

   local s = AT.status
   s.state    = st
   s.distance = Num(dist, 0)
   s.target   = (target and target ~= "") and target or "-"
   s.flags    = f
   s.mounted  = HasBit(f, 1) and 1 or 0
   s.flying   = HasBit(f, 2)
   s.swimming = HasBit(f, 4)
   s.driving  = HasBit(f, 8)
   s.paused   = HasBit(f, 16)
   s.points   = Num(pts, 0)
   s.attempts = Num(att, 0)
   s.leg      = Num(leg, 0)
   s.legs     = Num(legs, 0)
   s.progress = Num(prog, 0)

   AT.lastStatusRx = GetTime()

   local wasActive = AT.active
   AT.active = not INACTIVE[st]

   -- Die erste aktive Statuszeile nach einem Start ist dessen Annahme: jetzt erst
   -- Selbstmodus und Erbstueckschutz einschalten. Eine Absage kommt als Textmeldung
   -- mit einer Statuszeile IDLE und schaltet nichts ein.
   if AT.pendingStartAt then
      if not AT.StartPending() then
         AT.pendingStartAt = nil
      elseif not INACTIVE[st] then
         AT.BeginTripSupport()
      end
   end

   if wasActive and not AT.active then
      -- Reise ist serverseitig zu Ende (Ziel erreicht, Abbruch, Fehler). Den
      -- Selbstmodus nur ausschalten, wenn diese Reise ihn eingeschaltet hat: Disable
      -- ist ein Umschalter und wuerde ihn nach einer abgelehnten Reise einschalten.
      if AT.supportOn then
         if AT.Bot and AT.GetBool("AutoDisableBot") then AT.Bot.Disable() end
         if AT.Gear and AT.Gear.Stop then AT.Gear.Stop() end
      end
      AT.supportOn = false
   end

   if AT.Handover then AT.Handover.OnStatus(old, st) end
   if AT.UI then AT.UI.Update() end
end

-- ---------------------------------------------------------------------------
-- Verteiler
-- ---------------------------------------------------------------------------

local pendingGo = nil     -- wartet auf [AT]W fuer den .go-xyz-Modus

function N.SetPendingGo(name)
   pendingGo = { name = name, at = GetTime() }
end

local function OnWorldPos(body)
   local m, x, y, z = strsplit("|", body)
   x, y, z = tonumber(x), tonumber(y), tonumber(z)
   if not x or not y or not z then return end

   if pendingGo and (GetTime() - pendingGo.at) < 8 then
      local name = pendingGo.name
      pendingGo = nil

      -- ".go xyz" ist ein Spielleiterbefehl. Ohne entsprechende Kontostufe hiesse
      -- das, ihn ins Leere (oder bei AllowPlayerCommands = 0 in /sagen) zu rufen.
      if AT.server.known and AT.server.sec < 1 then
         AT.Warn("'.go xyz' braucht Spielleiterrechte. Mit '/at tpmodus modul' springt das Servermodul selbst.")
         return
      end

      -- Durch die Warteschlange, damit der Abstand zu anderen Befehlen gilt.
      AT.Send(string.format("go xyz %.3f %.3f %.3f %s", x, y, z, tostring(m or "")), { raw = true })
      AT.Print(string.format("Teleport per .go xyz zu %s (%.1f / %.1f / %.1f).", name, x, y, z))
   else
      AT.Print(string.format("Weltkoordinaten: %.2f / %.2f / %.2f (Map %s)", x, y, z, tostring(m)))
   end
end

-- Liefert true, wenn die Zeile eine Nachricht des Servermoduls war.
function N.Dispatch(msg)
   if type(msg) ~= "string" or string.sub(msg, 1, 4) ~= "[AT]" then return false end
   if string.sub(msg, 6, 6) ~= "|" then return true end        -- unbekanntes Format: ignorieren

   AT.lastRx = GetTime()
   local kind = string.sub(msg, 5, 5)
   local body = string.sub(msg, 7)

   -- Eine gueltige Statuszeile beweist, dass das Modul antwortet -- auch wenn der
   -- Handschlag verloren ging oder ausblieb (stumm geschaltet, Paketverlust,
   -- Neuladen mitten in einer Reise). Ohne das bliebe der Zustand ABSENT eine
   -- Sackgasse: jeder Befehl, auch Stop, wuerde abgelehnt, waehrend der Autopilot
   -- weiterfaehrt.
   if kind == "S" and (N.state == "ABSENT" or N.state == "UNKNOWN" or N.state == "HELLO") then
      N.state = "READY"
      FlushHeld()
   end

   if     kind == "H" then OnHello(body)
   elseif kind == "S" then OnStatus(body)
   elseif kind == "M" then AT.Print(body)
   elseif kind == "D" then AT.Debug(body)
   elseif kind == "W" then OnWorldPos(body)
   end
   return true
end

-- ---------------------------------------------------------------------------
-- Takt
-- ---------------------------------------------------------------------------

local pump = CreateFrame("Frame", "AutoTravelNet")
pump:SetScript("OnUpdate", function()
   local now = GetTime()

   if N.state == "HELLO" and now >= helloDeadline then
      if helloTries < 2 then
         helloTries = helloTries + 1
         helloDeadline = now + HELLO_TIMEOUT
         Enqueue({ cmd = "at hello", urgent = true, key = "hello" })
      else
         HelloFailed()
      end
   end

   local gap = now - lastSent
   if #urgentQ > 0 and gap >= GAP_URGENT then
      lastSent = now
      Transmit(table.remove(urgentQ, 1))
   elseif #normalQ > 0 and gap >= GAP_NORMAL then
      lastSent = now
      Transmit(table.remove(normalQ, 1))
   end
end)

-- ---------------------------------------------------------------------------
-- Chat
-- ---------------------------------------------------------------------------

local chat = CreateFrame("Frame")
chat:RegisterEvent("CHAT_MSG_SYSTEM")
chat:SetScript("OnEvent", function(self, event, msg)
   if N.Dispatch(msg) then return end
   -- Alles andere (z. B. die Bestaetigung des Playerbot-Selbstmodus) gehoert
   -- nicht diesem Modul.
   if AT.Bot and AT.Bot.OnSystemMessage then AT.Bot.OnSystemMessage(msg) end
end)

-- Protokollzeilen im Chat verbergen. In 3.3.5a lautet die Signatur
-- (self, event, msg, ...); die Abfrage unten kommt auch mit der aelteren
-- Form ohne self zurecht.
local function Filter(a1, a2, a3)
   local msg
   if type(a1) == "string" then msg = a2 else msg = a3 end
   if type(msg) == "string" and string.sub(msg, 1, 4) == "[AT]" then
      return AT.GetBool("HideProtocol")
   end
   return false
end
if ChatFrame_AddMessageEventFilter then
   ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", Filter)
end
