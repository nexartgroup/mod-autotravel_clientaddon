-- AT_Core.lua
-- ---------------------------------------------------------------------------
-- AutoTravel 5.0  --  Client-Teil
--
-- Aufgabenteilung:
--
--   Carbonite   ->  "wohin"        (Goto-Wegpunkt)
--   Addon       ->  Ziel auslesen, in normalisierte Zonenkoordinaten wandeln,
--                   an das Servermodul schicken, Status anzeigen
--   mod-autotravel (Server) -> "wie": WorldMapArea.dbc, PathGenerator
--                   (Navmesh), MoveSpline, Kampfpause, Repath, Stuck, Mount
--
-- Warum diesmal serverseitig: ein 3.3.5a-Addon kann den Charakter nicht
-- bewegen (alle Bewegungsfunktionen sind protected), und der Playerbot-Befehl
-- "go" kann nur Ziele innerhalb der eigenen Zone benennen. Beides faellt weg,
-- sobald ein eigenes Servermodul mitspielt.
--
-- Protokoll (Chat, wird serverseitig abgefangen und nie gebroadcastet):
--
--   .at start   <uiMapId> <nx> <ny> <hasCalib> <pnx> <pny> <Name...>
--   .at tp      <uiMapId> <nx> <ny> <hasCalib> <pnx> <pny> <Name...>
--   .at resolve <uiMapId> <nx> <ny> <hasCalib> <pnx> <pny>
--   .at stop | repath | status | debug <0|1> | set arrival <n>
--
-- Rueckmeldungen kommen als Systemnachricht:
--
--   [AT]S|<state>|<distanz>|<ziel>|<mount>|<nodes>|<versuche>
--   [AT]M|<Meldung>     [AT]D|<Debug>     [AT]W|<map>|<x>|<y>|<z>
-- ---------------------------------------------------------------------------

AutoTravel = AutoTravel or {}
local AT = AutoTravel
local CB = AT.Carb

AT.VERSION = "7.6"
local PREFIX = "|cff33ccffAutoTravel|r: "

AT.active   = false
AT.lastRx   = 0
AT.status   = { state = "IDLE", distance = 0, target = "-", mounted = 0, nodes = 0, attempts = 0 }

local pendingGo = nil     -- wartet auf [AT]W fuer den .go-xyz-Modus

local DEFAULTS = {
   HideProtocol  = 1,
   PanelVisible  = 1,
   MinimapButton = 1,
   MinimapAngle  = 200,
   TeleportMode  = "module",   -- "module" = .at tp | "go" = .go xyz ueber .at resolve
   ConfirmTp     = 1,
   Debug         = 0,

   -- Playerbot-Selbstmodus
   BotControl     = 1,
   Profile        = "verteidigen",
   SelfOnCommand  = ".playerbots bot self on",
   SelfOffCommand = ".playerbots bot self off",
   HideBotCmd     = 1,
   ShowProtocol   = 0,
   GuardHeirlooms = 1,
   GuardAlways    = 1,
   EquipCommand   = "e %s",
   PlayerOverride = 1,
   OverrideSeconds = 8,
   OverridePausesBot = 0,
   TakeControl    = 1,
   AutoDisableBot = 0,
}

function AT.Print(m) if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(m or "")) end end
function AT.Warn(m)  if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. "|cffff8800" .. tostring(m or "") .. "|r") end end
function AT.Debug(m) if AT.GetBool("Debug") then AT.Print("|cff888888" .. tostring(m or "") .. "|r") end end
function AT.trim(s) if not s then return "" end return (string.gsub(s, "^%s*(.-)%s*$", "%1")) end

function AT.Get(k)
   AutoTravelDB = AutoTravelDB or {}
   local v = AutoTravelDB[k]
   if v == nil then return DEFAULTS[k] end
   return v
end
function AT.Set(k, v) AutoTravelDB = AutoTravelDB or {} AutoTravelDB[k] = v end
function AT.GetBool(k) local v = AT.Get(k) return v == 1 or v == true end

-- ---------------------------------------------------------------------------
-- Senden
-- ---------------------------------------------------------------------------

-- Serverbefehle werden leicht entzerrt gesendet. Eine Route besteht aus
-- mehreren Nachrichten, und der Client hat eine eigene Flutbremse.
local sendQueue, lastSent = {}, 0
local SEND_GAP = 0.35

local function Send(cmd)
   table.insert(sendQueue, cmd)
end
AT.Send = Send

-- Beliebige Sendeaktion in dieselbe Warteschlange haengen, damit
-- Serverbefehle und Fluesterbefehle sich nicht ins Gehege kommen.
function AT.Queue(fn)
   table.insert(sendQueue, fn)
end

local pump = CreateFrame("Frame")
pump:SetScript("OnUpdate", function()
   if #sendQueue == 0 then return end
   local now = GetTime()
   if (now - lastSent) < SEND_GAP then return end
   local item = table.remove(sendQueue, 1)
   lastSent = now
   if type(item) == "function" then
      item()
   else
      SendChatMessage("." .. item, "SAY")
      AT.Debug("-> ." .. item)
   end
end)

-- ---------------------------------------------------------------------------
-- Ziel bestimmen
-- ---------------------------------------------------------------------------

local function sanitize(name)
   if type(name) ~= "string" then return "Ziel" end
   name = string.gsub(name, "|", "")
   name = string.gsub(name, "%s+", " ")
   name = AT.trim(name)
   if name == "" then return "Ziel" end
   if string.len(name) > 40 then name = string.sub(name, 1, 40) end
   return name
end

-- Rueckgabe: args-String fuer das Servermodul, Anzeigename
--        oder nil, Fehlertext
function AT.BuildTargetArgs()
   if not CB.IsAvailable() then
      return nil, "Carbonite ist nicht geladen."
   end

   local nx, ny, mapName, mapIndex, d = CB.GetDestinationNormalized()
   if not nx then return nil, ny end

   local uiMapId = AT.Get("ForcedMapId")
   if not uiMapId then
      uiMapId = AT.MapIds.Resolve(mapName)
   end
   if not uiMapId then
      -- Letzte Rettung: liegt das Ziel in der eigenen Zone, passt die aktuelle Karte.
      uiMapId = AT.MapIds.Current()
      if not uiMapId or uiMapId == 0 then
         return nil, "Zone '" .. tostring(mapName) .. "' konnte keiner WoW-Karte zugeordnet werden. " ..
                     "Mit /at karte <id> von Hand setzen."
      end
      AT.Warn("Zone '" .. tostring(mapName) .. "' unbekannt - benutze die aktuelle Karte (" .. uiMapId .. ").")
   end

   local hasCalib, pnx, pny = AT.MapIds.Calibration(uiMapId)
   local curMap, cnx, cny  = AT.MapIds.SelfSample()
   local name = sanitize(d and d.name or mapName)

   AT.Debug(string.format("Ziel %s | Zone %s -> Karte %d | %.4f/%.4f | Kalib %d | eigene Zone %d %.4f/%.4f",
            name, tostring(mapName), uiMapId, nx, ny, hasCalib, curMap, cnx, cny))

   return string.format("%d %.5f %.5f %d %.5f %.5f %d %.5f %.5f %s",
                        uiMapId, nx, ny, hasCalib, pnx, pny, curMap, cnx, cny, name), name, d
end

-- ---------------------------------------------------------------------------
-- Route
-- ---------------------------------------------------------------------------
-- Carbonite kennt die groben Stuetzpunkte einer Reise: Zonenuebergaenge,
-- Torbogen, Bruecken, Flugpunkte, das Ziel. Genau die werden uebertragen --
-- den eigentlichen Weg zwischen je zwei Punkten sucht das NavMesh des Servers.

local MAX_LEGS   = 24
local PACK_LIMIT = 200      -- Zeichen pro Chatnachricht

-- Rueckgabe: Liste { map, nx, ny, flag }  oder nil, Fehlertext
function AT.BuildRoute()
   if not CB.IsAvailable() then return nil, "Carbonite ist nicht geladen." end

   local legs = CB.GetRoute()
   if not legs then return nil, "Kein Carbonite-Ziel gesetzt." end

   local out = {}
   local skipped = 0

   for i = 1, #legs do
      local l = legs[i]
      local zx, zy = CB.ToZone(l.mapIndex, l.cx, l.cy)
      local uiMapId = l.mapName and AT.MapIds.Resolve(l.mapName) or nil

      if zx and uiMapId and zx >= -5 and zx <= 105 and zy >= -5 and zy <= 105 then
         local nx = math.max(0, math.min(100, zx)) / 100
         local ny = math.max(0, math.min(100, zy)) / 100
         local prev = out[#out]
         -- Punkte, die praktisch aufeinander liegen, zusammenfassen
         if not (prev and prev.map == uiMapId
                 and math.abs(prev.nx - nx) < 0.004 and math.abs(prev.ny - ny) < 0.004) then
            table.insert(out, { map = uiMapId, nx = nx, ny = ny,
                                flag = l.taxi and 1 or 0, name = l.name })
         end
      else
         skipped = skipped + 1
      end
   end

   if #out == 0 then return nil, "Kein Stuetzpunkt der Route liess sich zuordnen." end

   -- Bei sehr langen Routen ausduennen, aber Anfang, Ende und Flugpunkte behalten
   while #out > MAX_LEGS do
      local removed = false
      for i = #out - 1, 2, -1 do
         if out[i].flag == 0 then table.remove(out, i) removed = true break end
      end
      if not removed then break end
   end

   if skipped > 0 then
      AT.Debug(skipped .. " Stuetzpunkt(e) ohne Zonenzuordnung uebersprungen.")
   end
   return out
end

local function SendRoute(route)
   local first = true
   local buf = ""
   local function flush()
      if buf == "" then return end
      Send("at route " .. (first and "0" or "1") .. " " .. buf)
      first = false
      buf = ""
   end
   for i = 1, #route do
      local l = route[i]
      local tok = string.format("%d:%.4f:%.4f:%d", l.map, l.nx, l.ny, l.flag)
      if string.len(buf) + string.len(tok) + 1 > PACK_LIMIT then flush() end
      buf = (buf == "") and tok or (buf .. " " .. tok)
   end
   flush()
   if first then Send("at route 0 ") end       -- leere Route ausdruecklich loeschen
end

-- ---------------------------------------------------------------------------
-- Reise
-- ---------------------------------------------------------------------------

local function Watchdog()
   local started = GetTime()
   local f = CreateFrame("Frame")
   f:SetScript("OnUpdate", function()
      if AT.lastRx > started then
         f:SetScript("OnUpdate", nil)
      elseif (GetTime() - started) > 4 then
         f:SetScript("OnUpdate", nil)
         AT.Warn("Keine Antwort vom Server. Ist das Modul mod-autotravel installiert und aktiv?")
         AT.active = false
         AT.status.state = "IDLE"
         if AT.UI then AT.UI.Update() end
      end
   end)
end

function AT.Start()
   local d = CB.IsAvailable() and CB.GetDestination() or nil
   local name = d and sanitize(d.name) or "Ziel"

   local route, rerr = AT.BuildRoute()

   if route and #route > 1 then
      local curMap, cnx, cny = AT.MapIds.SelfSample()
      AT.Debug(string.format("Route mit %d Stuetzpunkten, davon %d Flugpunkte.",
               #route, (function() local n=0 for _,l in ipairs(route) do n=n+(l.flag or 0) end return n end)()))
      AT.lastRx = 0
      SendRoute(route)
      Send(string.format("at rstart %d %.5f %.5f %s", curMap, cnx, cny, name))
   else
      -- Einzelziel: Carbonite liefert nur den Endpunkt
      if not route then AT.Debug("Route nicht nutzbar (" .. tostring(rerr) .. ") - Einzelziel.") end
      local args, nameOrErr = AT.BuildTargetArgs()
      if not args then AT.Warn(nameOrErr) return end
      name = nameOrErr
      AT.lastRx = 0
      Send("at start " .. args)
   end

   Send("at set control " .. (AT.GetBool("TakeControl") and "1" or "0"))

   AT.active = true
   AT.status.state  = "STARTING"
   AT.status.target = name
   if AT.Bot then AT.Bot.Enable() end
   if AT.Gear then AT.Gear.Start() end
   if AT.UI then AT.UI.Update() end
   Watchdog()
end

function AT.Stop()
   Send("at stop")
   AT.active = false
   AT.status.state = "IDLE"
   if AT.Bot and AT.GetBool("AutoDisableBot") then AT.Bot.Disable() end
   if AT.UI then AT.UI.Update() end
end

function AT.Toggle()
   if AT.active then AT.Stop() else AT.Start() end
end

function AT.Repath() Send("at repath") end

-- ---------------------------------------------------------------------------
-- Teleport
-- ---------------------------------------------------------------------------

local function DoTeleport()
   local args, nameOrErr = AT.BuildTargetArgs()
   if not args then AT.Warn(nameOrErr) return end

   AT.lastRx = 0
   if AT.Get("TeleportMode") == "go" then
      -- Weltkoordinaten beim Modul anfragen, danach den GM-Befehl benutzen.
      pendingGo = { name = nameOrErr, at = GetTime() }
      Send("at resolve " .. args)
   else
      Send("at tp " .. args)
   end
   Watchdog()
end

function AT.Teleport()
   if not AT.GetBool("ConfirmTp") then DoTeleport() return end

   local args, nameOrErr = AT.BuildTargetArgs()
   if not args then AT.Warn(nameOrErr) return end

   StaticPopup_Show("AUTOTRAVEL_TP_CONFIRM", nameOrErr)
end

StaticPopupDialogs["AUTOTRAVEL_TP_CONFIRM"] = {
   text = "Zum Carbonite-Ziel teleportieren?\n\n|cffffffff%s|r",
   button1 = JA or YES or "Ja",
   button2 = NEIN or NO or "Nein",
   OnAccept = function() DoTeleport() end,
   timeout = 20,
   whileDead = false,
   hideOnEscape = true,
   showAlert = true,
}

-- ---------------------------------------------------------------------------
-- Empfang
-- ---------------------------------------------------------------------------

local function HandleProtocol(msg)
   AT.lastRx = GetTime()
   local kind = string.sub(msg, 5, 5)
   local body = string.sub(msg, 7)

   if kind == "S" then
      local st, dist, target, mounted, nodes, att =
         string.match(body, "^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
      if st then
         AT.status.state    = st
         AT.status.distance = tonumber(dist) or 0
         AT.status.target   = target
         AT.status.mounted  = tonumber(mounted) or 0
         AT.status.nodes    = tonumber(nodes) or 0
         AT.status.attempts = tonumber(att) or 0
         local wasActive = AT.active
         AT.active = (st ~= "IDLE" and st ~= "ARRIVED" and st ~= "FAILED")
         -- Reise ist serverseitig zu Ende (Ziel erreicht, Abbruch, Fehler):
         -- Selbstmodus wieder abschalten.
         if wasActive and not AT.active then
            if AT.Bot and AT.GetBool("AutoDisableBot") then AT.Bot.Disable() end
         end
         if AT.UI then AT.UI.Update() end
      end

   elseif kind == "M" then
      AT.Print(body)

   elseif kind == "D" then
      AT.Debug(body)

   elseif kind == "W" then
      local m, x, y, z = string.match(body, "^([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
      x, y, z = tonumber(x), tonumber(y), tonumber(z)
      if not x then return end
      if pendingGo and (GetTime() - pendingGo.at) < 8 then
         local name = pendingGo.name
         pendingGo = nil
         SendChatMessage(string.format(".go xyz %.3f %.3f %.3f %s", x, y, z, tostring(m)), "SAY")
         AT.Print(string.format("Teleport per .go xyz zu %s (%.1f / %.1f / %.1f).", name, x, y, z))
      else
         AT.Print(string.format("Weltkoordinaten: %.2f / %.2f / %.2f (Map %s)", x, y, z, tostring(m)))
      end
   end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event, arg1)
   if event == "ADDON_LOADED" and arg1 == "AutoTravel" then
      AutoTravelDB = AutoTravelDB or {}
      for k, v in pairs(DEFAULTS) do
         if AutoTravelDB[k] == nil then AutoTravelDB[k] = v end
      end
   elseif event == "PLAYER_LOGIN" then
      if AT.UI then AT.UI.Build() end
      if AT.Options then AT.Options.Init() end
      if AT.ProfileEditor then AT.ProfileEditor.Init() end
      if AT.Gear then AT.Gear.Snapshot(true) end
      AT.Print("v" .. AT.VERSION .. " geladen. /at fuer Hilfe.")
      if not CB.IsAvailable() then
         AT.Warn("Carbonite nicht gefunden - AutoTravel braucht es als Zielquelle.")
      end
   end
end)

local chat = CreateFrame("Frame")
chat:RegisterEvent("CHAT_MSG_SYSTEM")
chat:RegisterEvent("CHAT_MSG_WHISPER")
chat:SetScript("OnEvent", function(self, event, msg)
   if type(msg) ~= "string" then return end
   if string.sub(msg, 1, 4) == "[AT]" then
      HandleProtocol(msg)
      return
   end
   -- "Enable player botAI" / "Disable player botAI"
   if AT.Bot and AT.Bot.OnSystemMessage(msg) then return end
end)

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

-- Eigene Botbefehle nicht im Chat anzeigen (das Echo "An Dich selbst: co +dps")
local function BotCmdFilter(a1, a2, a3)
   if not AT.GetBool("HideBotCmd") then return false end
   local msg
   if type(a1) == "string" then msg = a2 else msg = a3 end
   if AT.Bot and AT.Bot.IsOwnCommand(msg) then return true end
   return false
end
if ChatFrame_AddMessageEventFilter then
   ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", BotCmdFilter)
   ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", BotCmdFilter)
end

-- ---------------------------------------------------------------------------
-- Slash-Befehle
-- ---------------------------------------------------------------------------

local function Help()
   AT.Print("Befehle:")
   local l = {
      "/at                   Reise Start / Stop",
      "/at tp                zum Ziel teleportieren",
      "/at start | stop | status | repath",
      "/at target            erkanntes Ziel pruefen",
      "/at koords            Weltkoordinaten des Ziels anzeigen",
      "/at diag              Diagnose: warum scheitert der Pfad?",
      "/at knoten            Zustand des Playerbot-Knotengraphen",
      "/at route             Stuetzpunkte der Carbonite-Route anzeigen",
      "/at profil            Profil wechseln (ohne Argument: Liste)",
      "/at bot               Playerbot-Steuerung an/aus",
      "/at erbstuecke        geschuetzte Erbstuecke anzeigen",
      "/at erbstuecke neu    aktuelle Ausruestung als Sollzustand nehmen",
      "/at erbstuecke test   welche Anlegewege kennt der Client?",
      "/at botan | botaus    Selbstmodus von Hand schalten",
      "/at profile           eigene Profile bearbeiten",
      "/at pause             Spielervorrang von Hand ein/aus",
      "/at kontrolle         Steuerungsuebernahme waehrend der Fahrt",
      "/at selfon <befehl>   Befehl zum Einschalten des Selbstmodus",
      "/at selfoff <befehl>  Befehl zum Ausschalten",
      "/at karte <id>        WorldMapArea-ID erzwingen (0 = automatisch)",
      "/at karten            Kartentabelle neu aufbauen",
      "/at tpmodus <modul|go>  Teleportweg waehlen",
      "/at nachfrage         Sicherheitsabfrage vor Teleport an/aus",
      "/at ziel <n>          Zielradius in Yards",
      "/at knopf             Minimap-Knopf an/aus",
      "/at panel             Fenster an/aus",
      "/at optionen          Einstellungsseite oeffnen",
      "/at debug             ausfuehrliche Ausgabe",
   }
   for _, s in ipairs(l) do DEFAULT_CHAT_FRAME:AddMessage("   " .. s) end
end

SLASH_AUTOTRAVEL1 = "/autotravel"
SLASH_AUTOTRAVEL2 = "/at"

SlashCmdList["AUTOTRAVEL"] = function(input)
   input = AT.trim(input or "")
   local cmd, rest = string.match(input, "^(%S*)%s*(.*)$")
   cmd = string.lower(cmd or "")

   if cmd == "" then AT.Toggle()
   elseif cmd == "start" then AT.Start()
   elseif cmd == "stop" then AT.Stop()
   elseif cmd == "repath" then AT.Repath()
   elseif cmd == "status" then Send("at status")
   elseif cmd == "tp" or cmd == "teleport" then AT.Teleport()

   elseif cmd == "target" then
      local args, nameOrErr = AT.BuildTargetArgs()
      if not args then AT.Warn(nameOrErr)
      else AT.Print("Ziel: " .. nameOrErr .. "  |  Parameter: " .. args) end

   elseif cmd == "profil" or cmd == "profile" then
      if rest == "" then
         AT.Bot.PrintProfiles()
      else
         local found
         for _, p in ipairs(AT.Bot.Profiles) do
            if string.lower(p.name) == rest or p.key == rest then found = p end
         end
         if not found then AT.Warn("Unbekanntes Profil.") AT.Bot.PrintProfiles()
         else
            AT.Set("Profile", found.key)
            AT.Print("Profil: |cffffffff" .. found.name .. "|r - " .. found.desc)
            if AT.Bot.active then AT.Bot.ApplyProfile() end
            if AT.UI then AT.UI.Update() end
         end
      end

   elseif cmd == "erbstuecke" or cmd == "heirloom" then
      if rest == "" then
         AT.Gear.Report()
      elseif rest == "neu" then
         AT.Gear.Snapshot()
         AT.Print("Erbstuecke neu erfasst.")
         AT.Gear.Report()
      elseif rest == "test" then
         AT.Gear.Probe()
      else
         AT.Set("GuardHeirlooms", AT.GetBool("GuardHeirlooms") and 0 or 1)
         AT.Print("Erbstueckschutz " .. (AT.GetBool("GuardHeirlooms") and "AN" or "AUS"))
      end

   elseif cmd == "pause" then AT.Override.Toggle()

   elseif cmd == "kontrolle" then
      AT.Set("TakeControl", AT.GetBool("TakeControl") and 0 or 1)
      Send("at set control " .. (AT.GetBool("TakeControl") and "1" or "0"))
      AT.Print("Steuerungsuebernahme " .. (AT.GetBool("TakeControl") and "AN" or "AUS") ..
               (AT.GetBool("TakeControl")
                and " - zuverlaessigere Bewegung, aber du kannst waehrend der Fahrt nichts tun."
                or  " - du behaeltst die Kontrolle, die Bewegung kann abbrechen."))

   elseif cmd == "botan" then AT.Bot.Enable()
   elseif cmd == "botaus" then AT.Bot.Disable()

   elseif cmd == "profile" then
      AT.ProfileEditor.Open()

   elseif cmd == "bot" then
      if rest == "status" then
         AT.Print("Selbstmodus: " .. AT.Bot.StatusText() ..
                  "  |  Profil: " .. AT.Bot.Current().name)
      else
         AT.Set("BotControl", AT.GetBool("BotControl") and 0 or 1)
         AT.Print("Playerbot-Steuerung " .. (AT.GetBool("BotControl") and "AN" or "AUS"))
         if AT.UI then AT.UI.Update() end
      end

   elseif cmd == "selfon" then
      if rest ~= "" then AT.Set("SelfOnCommand", rest) end
      AT.Print("Einschaltbefehl: " .. tostring(AT.Get("SelfOnCommand")))

   elseif cmd == "selfoff" then
      if rest ~= "" then AT.Set("SelfOffCommand", rest) end
      AT.Print("Ausschaltbefehl: " .. tostring(AT.Get("SelfOffCommand")))

   elseif cmd == "route" then
      local r, err = AT.BuildRoute()
      if not r then AT.Warn(err)
      else
         AT.Print("Route: " .. #r .. " Stuetzpunkte")
         for i = 1, #r do
            DEFAULT_CHAT_FRAME:AddMessage(string.format("   %2d. Karte %4d  %.1f / %.1f  %s%s",
               i, r[i].map, r[i].nx * 100, r[i].ny * 100,
               (r[i].flag == 1) and "|cffffcc00[Flug]|r " or "",
               tostring(r[i].name or "")))
         end
      end

   elseif cmd == "nodes" or cmd == "knoten" then
      Send("at nodes")

   elseif cmd == "diag" then
      local args, err = AT.BuildTargetArgs()
      if not args then AT.Warn(err) else Send("at diag " .. args) end

   elseif cmd == "koords" then
      local args, err = AT.BuildTargetArgs()
      if not args then AT.Warn(err) else Send("at resolve " .. args) end

   elseif cmd == "karte" then
      local id = tonumber(rest)
      if id and id > 0 then AT.Set("ForcedMapId", id) AT.Print("Karten-ID erzwungen: " .. id)
      else AT.Set("ForcedMapId", nil) AT.Print("Karten-ID wieder automatisch.") end

   elseif cmd == "karten" then
      AT.MapIds.Build(true)
      AT.Print("Kartentabelle neu aufgebaut: " .. AT.MapIds.Count() .. " Zonen.")

   elseif cmd == "tpmodus" then
      local m = string.lower(rest)
      if m == "go" then AT.Set("TeleportMode", "go") AT.Print("Teleport ueber .go xyz (braucht GM-Recht).")
      elseif m == "modul" or m == "module" then AT.Set("TeleportMode", "module") AT.Print("Teleport ueber das Servermodul.")
      else AT.Print("Aktuell: " .. tostring(AT.Get("TeleportMode")) .. "  (modul | go)") end

   elseif cmd == "nachfrage" then
      AT.Set("ConfirmTp", AT.GetBool("ConfirmTp") and 0 or 1)
      AT.Print("Sicherheitsabfrage " .. (AT.GetBool("ConfirmTp") and "AN" or "AUS"))

   elseif cmd == "ziel" then
      local n = tonumber(rest)
      if n then Send("at set arrival " .. n) else AT.Print("Verwendung: /at ziel <yards>") end

   elseif cmd == "knopf" then
      AT.Set("MinimapButton", AT.GetBool("MinimapButton") and 0 or 1)
      if AT.UI then AT.UI.RefreshMinimap() end

   elseif cmd == "optionen" or cmd == "options" or cmd == "config" then
      AT.Options.Open()

   elseif cmd == "panel" then
      AT.Set("PanelVisible", AT.GetBool("PanelVisible") and 0 or 1)
      if AT.UI then AT.UI.Refresh() end

   elseif cmd == "debug" then
      AT.Set("Debug", AT.GetBool("Debug") and 0 or 1)
      Send("at debug " .. (AT.GetBool("Debug") and "1" or "0"))
      AT.Print("Debug " .. (AT.GetBool("Debug") and "AN" or "AUS"))

   else Help() end
end

-- Beschriftungen fuer die Tastenbelegung (Spiel -> Tastatur -> AutoTravel)
BINDING_HEADER_AUTOTRAVEL       = "AutoTravel"
BINDING_NAME_AUTOTRAVEL_PAUSE   = "Spielervorrang ein/aus"
BINDING_NAME_AUTOTRAVEL_TOGGLE  = "Reise starten / stoppen"
BINDING_NAME_AUTOTRAVEL_BOT     = "Playerbot ein/aus"
