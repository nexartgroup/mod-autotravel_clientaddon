-- AT_Core.lua
-- ---------------------------------------------------------------------------
-- AutoTravel  --  Client-Teil
--
-- Aufgabenteilung:
--
--   Carbonite   ->  "wohin"        (Goto-Wegpunkt)
--   Addon       ->  Ziel auslesen, in normalisierte Zonenkoordinaten wandeln,
--                   an das Servermodul schicken, Status anzeigen, Uebergabe
--                   zwischen Spieler und Autopilot bedienen
--   mod-autotravel (Server) -> "wie": WorldMapArea.dbc, PathGenerator
--                   (Navmesh), MoveSpline, Kampfpause, Repath, Stuck, Mount,
--                   Flugmeister, Transporte
--
-- Warum serverseitig: ein 3.3.5a-Addon kann den Charakter nicht bewegen (alle
-- Bewegungsfunktionen sind protected), und der Playerbot-Befehl "go" kann nur
-- Ziele innerhalb der eigenen Zone benennen.
--
-- Protokoll (Einzelheiten und Handschlag in AT_Net.lua):
--
--   Befehle (Chat, serverseitig abgefangen und nie gebroadcastet):
--     .at hello
--     .at start   <uiMapId> <nx> <ny> <hasCalib> <pnx> <pny> <curMap> <cnx> <cny> <Name...>
--     .at route <0|1> <map:nx:ny:art> ...      .at rstart <curMap> <cnx> <cny> <Name...>
--     .at tp | resolve | diag   <wie start>
--     .at stop | pause | resume | repath | status | debug <0|1> | set <schluessel> <wert>
--
--   Rueckmeldungen (Systemnachricht):
--     [AT]H|...   Handschlag     [AT]S|...   Status     [AT]M|<Text>   Meldung
--     [AT]D|<Text>   Debug       [AT]W|<map>|<x>|<y>|<z>   Weltkoordinaten
-- ---------------------------------------------------------------------------

AutoTravel = AutoTravel or {}
local AT = AutoTravel
local CB = AT.Carb
local N  = AT.Net

AT.VERSION = "11.2"
local PREFIX = "|cff33ccffAutoTravel|r: "

-- Anzeigenamen fuer Optionen -> Tastaturbelegung (siehe Bindings.xml).
BINDING_HEADER_AUTOTRAVEL      = "AutoTravel"
BINDING_NAME_AUTOTRAVEL_TOGGLE = "Reise starten / stoppen"
BINDING_NAME_AUTOTRAVEL_PAUSE  = "Steuerung uebernehmen / zurueckgeben"
BINDING_NAME_AUTOTRAVEL_BOT    = "Playerbot-Selbstmodus umschalten"

AT.active   = false
AT.pendingStartAt = nil     -- Zeitpunkt eines gesendeten, noch nicht angenommenen Starts
AT.supportOn = false        -- Selbstmodus/Erbstueckschutz laufen fuer die aktuelle Reise
AT.lastRx   = 0
AT.status   = { state = "IDLE", distance = 0, target = "-", mounted = 0, points = 0,
                attempts = 0, leg = 0, legs = 0, progress = 0, flags = 0,
                flying = false, swimming = false, driving = false, paused = false }

local DEFAULTS = {
   HideProtocol  = 1,
   PanelVisible  = 1,
   MinimapButton = 1,
   MinimapAngle  = 200,
   TeleportMode  = "module",   -- "module" = .at tp | "go" = .go xyz ueber .at resolve
   ConfirmTp     = 1,
   Debug         = 0,
   AutoHello     = 1,          -- beim Anmelden das Servermodul abfragen

   -- Uebergabe an den Spieler
   AutoResume       = 1,       -- nach Ruhezeit selbst zurueckgeben
   QuietSeconds     = 8,       -- Ruhe, bevor der Countdown beginnt
   CountdownSeconds = 3,       -- sichtbarer Countdown, den jede Eingabe abbricht

   -- Zielradius. Der Server kennt seinen eigenen Standard; gemeldet wird nur,
   -- was der Spieler selbst eingestellt hat (ArriveCustom).
   ArriveYards   = 8,
   ArriveCustom  = 0,

   -- Playerbot-Selbstmodus
   BotControl     = 1,
   Profile        = "verteidigen",
   SelfOnCommand  = ".playerbots bot self",
   SelfOffCommand = ".playerbots bot self",
   HideBotCmd     = 1,
   ShowProtocol   = 0,
   GuardHeirlooms = 1,
   GuardAlways    = 1,
   AutoDisableBot = 0,

   -- ---------------------------------------------------------------
   -- Natuerliche Navigation
   -- ---------------------------------------------------------------
   --
   -- Diese Werte werden an das Servermodul uebergeben (nur Spielleiter, sie
   -- gelten serverweit). Das Addon berechnet keine NavMesh-Wege selbst.
   --
   NaturalPathing           = 1,
   ContourProbing           = 1,
   ContourTriggerElevation  = 15,
   ContourTriggerSlope      = 20,
   ContourNarrowOffset      = 100,
   ContourWideOffset        = 180,
   ContourMaxDistanceFactor = 250,
}
AT.DEFAULTS = DEFAULTS

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
-- Senden (Warteschlange und Handschlag: AT_Net.lua)
-- ---------------------------------------------------------------------------
-- Kurzformen, die auch AT_Bot und AT_Options benutzen.

function AT.Send(cmd, opts)  return N.Send(cmd, opts) end
function AT.SendNow(cmd, key) return N.SendNow(cmd, key) end
function AT.Queue(fn, tag)   N.Queue(fn, tag) end

-- Serverweite Einstellung (".at set"). Sie gilt fuer ALLE Spieler und ist
-- deshalb Spielleitern vorbehalten. Einem normalen Spieler wuerde der Server
-- jeden Klick mit einer Absage quittieren; das Addon fragt deshalb vorher die
-- Berechtigung aus dem Handschlag ab und merkt sich den Wert nur lokal.
function AT.SetServerOption(key, value)
   if value == nil then return end

   -- Der Wert selbst wird NICHT hier gespeichert: 'key' ist der Schluessel des
   -- Servers ("natural"), nicht der der Einstellung im Addon ("NaturalPathing").
   -- Die Oberflaeche speichert ihren Wert, bevor sie diese Funktion ruft; ein
   -- zweites Speichern unter dem Serverschluessel legte nur Muell in die
   -- gespeicherten Variablen.
   if not N.Can("SETTINGS") then
      AT.Debug("Serveroption " .. tostring(key) .. " nicht gesendet: nur fuer Spielleiter.")
      return
   end

   -- Der Server nimmt Dezimalwerte mit Punkt entgegen.
   local v = string.gsub(tostring(value), ",", ".")

   -- Schluessel "set:<name>": eine neue Einstellung desselben Wertes ersetzt
   -- die noch wartende alte.
   AT.Send("at set " .. tostring(key) .. " " .. v, { key = "set:" .. tostring(key) })
   AT.Debug("Serveroption: " .. tostring(key) .. " = " .. v)
end

function AT.SetServerBool(key, value)
   local v = (value == 1 or value == true) and 1 or 0
   AT.SetServerOption(key, v)
end

function AT.SetServerNumber(key, value)
   value = tonumber(value)
   if not value then return end
   AT.SetServerOption(key, value)
end

-- Einstellung, die nur die eigene Reise betrifft (arrival, grace). Jeder darf sie
-- setzen; sie geht mit der Sitzung verloren und wird deshalb nach dem
-- Handschlag erneut gemeldet.
function AT.SetSessionOption(key, value)
   value = tonumber(value)
   if not value then return end
   AT.Send("at set " .. key .. " " .. string.gsub(tostring(value), ",", "."),
           { key = "set:" .. key })
end

-- Kleine Verzoegerung ohne Zusatzbibliothek.
local timers = {}
local timerFrame = CreateFrame("Frame")
timerFrame:SetScript("OnUpdate", function()
   if #timers == 0 then return end
   local now = GetTime()
   for i = #timers, 1, -1 do
      if now >= timers[i].at then
         local fn = timers[i].fn
         table.remove(timers, i)
         fn()
      end
   end
end)
function AT.After(seconds, fn) table.insert(timers, { at = GetTime() + seconds, fn = fn }) end

-- Der Server hat auf den Handschlag geantwortet.
function AT.OnServerKnown()
   if AT.GetBool("ArriveCustom") then
      AT.SetSessionOption("arrival", AT.Get("ArriveYards"))
   end
   -- Das Debugkennzeichen gilt je Sitzung des Servers und ging mit dem Abmelden
   -- verloren; das Addon merkt es sich aber dauerhaft.
   if AT.GetBool("Debug") then
      AT.Send("at debug 1", { key = "debug" })
   end
   if AT.UI then AT.UI.Update() end
   if AT.Options then AT.Options.Load() end
end

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

   local nx, ny, mapName, _, d = CB.GetDestinationNormalized()
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

-- Teilt die Route in Chatnachrichten (PACK_LIMIT Zeichen) und gibt die Liste der
-- Befehle zurueck. Ausgelagert, damit sich die Aufteilung testen laesst.
function AT.PackRoute(route)
   local cmds = {}
   local first = true
   local buf = ""
   local function flush()
      if buf == "" then return end
      table.insert(cmds, "at route " .. (first and "0" or "1") .. " " .. buf)
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
   return cmds
end

-- ---------------------------------------------------------------------------
-- Reise
-- ---------------------------------------------------------------------------

-- Meldet sich der Server nach einem Start nicht, ist etwas falsch: Modul
-- abgestuerzt, Verbindung weg, Befehl abgewiesen.
--
-- Ein Start gilt erst als angenommen, wenn eine STATUSzeile kommt. Eine
-- Textmeldung ("Du bist tot.", "Zu schnell") genuegt nicht: der Server meldet so
-- auch Absagen, und das Addon wuerde auf "Startet" haengen bleiben. Beim
-- Teleport dagegen kommt keine Statuszeile, dort zaehlt jede Antwort.
--
-- Ein einziger Rahmen fuer alle Aufrufe; frueher entstand je Start ein neuer,
-- und Rahmen werden in WoW nie freigegeben.
local wdFrom, wdNeedStatus = nil, false
local wdFrame = CreateFrame("Frame", "AutoTravelWatchdog")
wdFrame:SetScript("OnUpdate", function()
   if not wdFrom then return end

   local got = wdNeedStatus and (AT.lastStatusRx or 0) or AT.lastRx
   if got > wdFrom then
      wdFrom = nil
      return
   end

   if (GetTime() - wdFrom) > 8 then
      local needStatus = wdNeedStatus
      wdFrom = nil
      if N.IsReady() then
         if needStatus then
            AT.Warn("Keine Statusmeldung vom Server auf den Start. Verbindung pruefen; " ..
                    "'/at hello' fragt das Modul erneut ab.")
            AT.active = false
            AT.status.state = "IDLE"
            if AT.UI then AT.UI.Update() end
         else
            AT.Warn("Keine Antwort vom Server. Verbindung pruefen; '/at hello' fragt das Modul erneut ab.")
         end
      end
   end
end)

local function Watchdog(needStatus)
   wdFrom = GetTime()
   wdNeedStatus = needStatus and true or false
end

function AT.Start()
   local d = CB.IsAvailable() and CB.GetDestination() or nil
   local name = d and sanitize(d.name) or "Ziel"

   local route, rerr = AT.BuildRoute()
   local accepted

   if route and #route > 1 then
      local curMap, cnx, cny = AT.MapIds.SelfSample()
      local taxiLegs = 0
      for _, l in ipairs(route) do taxiLegs = taxiLegs + (l.flag or 0) end
      AT.Debug(string.format("Route mit %d Stuetzpunkten, davon %d Flugpunkte.", #route, taxiLegs))

      AT.lastRx = 0
      local cmds = AT.PackRoute(route)
      for i = 1, #cmds do
         accepted = AT.Send(cmds[i], { tag = "start" })
         if not accepted then return end
      end
      accepted = AT.Send(string.format("at rstart %d %.5f %.5f %s", curMap, cnx, cny, name),
                         { tag = "start" })
   else
      -- Einzelziel: Carbonite liefert nur den Endpunkt
      if not route then AT.Debug("Route nicht nutzbar (" .. tostring(rerr) .. ") - Einzelziel.") end
      local args, nameOrErr = AT.BuildTargetArgs()
      if not args then AT.Warn(nameOrErr) return end
      name = nameOrErr
      AT.lastRx = 0
      accepted = AT.Send("at start " .. args, { tag = "start" })
   end

   if not accepted then return end

   AT.active = true
   AT.status.state  = "STARTING"
   AT.status.target = name
   AT.status.progress = 0
   -- Selbstmodus und Erbstueckschutz erst, wenn der Server den Start angenommen hat
   -- (siehe AT.BeginTripSupport). Eine Absage -- etwa "keine Verbindung ueber die
   -- Kartengrenze" -- soll den Bot nicht trotzdem einschalten.
   AT.pendingStartAt = GetTime()
   -- Der Erbstueck-Schnappschuss gehoert an den Klick, nicht an die Antwort: die
   -- Ueberwachung ist ab AT.active scharf und soll nicht mit einem alten Stand arbeiten.
   if AT.Gear then AT.Gear.Start() end
   if AT.UI then AT.UI.Update() end
   if N.IsReady() then Watchdog(true) end
end

-- Wie lange nach dem Senden eines Starts die erste aktive Statuszeile noch als
-- dessen Annahme gilt. Grosszuegig: ein Start mit langer Route geht in mehreren
-- Befehlen hinaus, und vor dem Handschlag wartet er in der Schlange.
local START_WINDOW = 30

-- Der Server hat den Start angenommen: Playerbot-Selbstmodus und Erbstueckschutz
-- einschalten. Wird vom Statusempfang aufgerufen, nicht beim Klick.
function AT.BeginTripSupport()
   AT.pendingStartAt = nil
   -- Nur wenn Bot.Enable wirklich etwas tut: mit abgeschalteter Playerbot-Steuerung
   -- kehrt es sofort zurueck, und ein spaeteres Disable (Umschalter!) wuerde den Bot
   -- dann EINschalten.
   AT.supportOn = AT.GetBool("BotControl")
   if AT.Bot then AT.Bot.Enable() end
end

-- true, solange ein gesendeter Start auf seine Annahme wartet
function AT.StartPending()
   return AT.pendingStartAt ~= nil and (GetTime() - AT.pendingStartAt) <= START_WINDOW
end

function AT.Stop()
   -- Ein noch wartender Start (in der Warteschlange oder hinter dem Handschlag)
   -- ist damit hinfaellig. Ohne das Verwerfen ueberholte der dringende Stop die
   -- wartenden Startbefehle auf der Leitung: der Server bekam erst "stop" (keine
   -- Reise, nichts zu tun) und dann den Start -- und das Addon zeigte IDLE,
   -- waehrend der Autopilot loslief.
   N.DropTag("start")
   AT.pendingStartAt = nil
   -- Disable ist ein Umschalter: nur ausschalten, was diese Reise eingeschaltet hat.
   -- Ein Stop vor der Antwort des Servers hat nichts eingeschaltet.
   local hadSupport = AT.supportOn
   AT.supportOn = false
   AT.SendNow("at stop", "stop")
   AT.active = false
   AT.status.state = "IDLE"
   if hadSupport and AT.Bot and AT.GetBool("AutoDisableBot") then AT.Bot.Disable() end
   if AT.UI then AT.UI.Update() end
end

function AT.Toggle()
   if AT.active then AT.Stop() else AT.Start() end
end

function AT.Repath() AT.Send("at repath", { key = "repath" }) end

-- ---------------------------------------------------------------------------
-- Teleport
-- ---------------------------------------------------------------------------

local function DoTeleport()
   local args, nameOrErr = AT.BuildTargetArgs()
   if not args then AT.Warn(nameOrErr) return end

   AT.lastRx = 0
   if AT.Get("TeleportMode") == "go" then
      -- Weltkoordinaten beim Modul anfragen, danach den GM-Befehl benutzen. Das
      -- Zeitfenster fuer die Antwort wird erst geoeffnet, wenn die Anfrage
      -- tatsaechlich angenommen wurde.
      if AT.Send("at resolve " .. args) then N.SetPendingGo(nameOrErr) end
   else
      AT.Send("at tp " .. args)
   end
   if N.IsReady() then Watchdog(false) end
end

function AT.Teleport()
   -- Der Handschlag verraet, ob der Server diesem Spieler den Teleport erlaubt.
   -- Ohne die Abfrage laeuft ein Klick ins Leere und endet in einer Absage.
   if AT.Get("TeleportMode") ~= "go" and not N.Can("TELEPORT") then
      if N.state ~= "READY" and N.state ~= "UNKNOWN" and N.state ~= "HELLO" then
         -- Gesperrt, weil das Modul nicht antwortet -- nicht wegen der Rechte.
         AT.Warn("Keine Verbindung zum Servermodul. '/at hello' fragt es erneut ab.")
      else
         AT.Warn("Der Teleport ist dir auf diesem Server nicht erlaubt " ..
                 "(Stufe " .. tostring(AT.server.sec) .. "). Ein Spielleiter kann ihn mit " ..
                 "AutoTravel.TeleportSecurity freigeben.")
      end
      return
   end

   if not AT.GetBool("ConfirmTp") then DoTeleport() return end

   local args, nameOrErr = AT.BuildTargetArgs()
   if not args then AT.Warn(nameOrErr) return end

   StaticPopup_Show("AUTOTRAVEL_TP_CONFIRM", nameOrErr)
end

StaticPopupDialogs["AUTOTRAVEL_TP_CONFIRM"] = {
   text = "Zum Carbonite-Ziel teleportieren?\n\n|cffffffff%s|r",
   button1 = YES or "Ja",
   button2 = NO or "Nein",
   OnAccept = function() DoTeleport() end,
   timeout = 20,
   whileDead = false,
   hideOnEscape = true,
   showAlert = true,
}

-- ---------------------------------------------------------------------------
-- Diagnose
-- ---------------------------------------------------------------------------

local CAP_LABELS = {
   { "HANDOVER", "Uebergabe" }, { "ROUTE", "Route" }, { "TAXI", "Flugmeister" },
   { "TRANSPORT", "Transporte" }, { "TELEPORT", "Teleport" }, { "SETTINGS", "Serveroptionen" },
}

function AT.PrintInfo()
   local s = AT.server
   AT.Print("Addon " .. AT.VERSION .. "  |  Protokoll " .. N.PROTOCOL ..
            " (akzeptiert ab " .. N.MIN_PROTOCOL .. ")")

   local stateText = {
      UNKNOWN = "noch nicht abgefragt", HELLO = "Anfrage laeuft", READY = "verbunden",
      ABSENT = "keine Antwort", INCOMPATIBLE = "Modul zu alt", DISABLED = "serverseitig aus",
   }
   AT.Print("Servermodul: " .. (stateText[N.state] or N.state))

   if s.known then
      AT.Print(string.format("   Version %s, Protokoll %d, %d Reiseknoten, Kontostufe %d",
               s.version, s.proto, s.nodes, s.sec))
      local caps = {}
      for _, c in ipairs(CAP_LABELS) do
         table.insert(caps, (N.Can(c[1]) and "|cff53d17a+" or "|cff9099a8-") .. c[2] .. "|r")
      end
      AT.Print("   " .. table.concat(caps, "  "))
      if not s.capsKnown then
         AT.Print("   (aelteres Modul: Faehigkeiten unbekannt, alle Knoepfe bleiben frei)")
      end
   end

   AT.Print("Carbonite: " .. (CB.IsAvailable() and "gefunden" or "|cffff8800nicht gefunden|r") ..
            "  |  Kartentabelle: " .. AT.MapIds.Count() .. " Zonen")
   AT.Print(string.format("Uebergabe: automatisch %s, Ruhe %ds, Countdown %ds",
            AT.GetBool("AutoResume") and "an" or "aus",
            tonumber(AT.Get("QuietSeconds")) or 8, tonumber(AT.Get("CountdownSeconds")) or 3))
   if AT.Bot then
      AT.Print("Playerbot-Selbstmodus: " .. AT.Bot.StatusText() .. "  |  Profil: " .. AT.Bot.Current().name)
   end
end

-- ---------------------------------------------------------------------------
-- Ereignisse
-- ---------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event, arg1)
   if event == "ADDON_LOADED" and arg1 == "AutoTravel" then
      AutoTravelDB = AutoTravelDB or {}
      for k, v in pairs(DEFAULTS) do
         if AutoTravelDB[k] == nil then AutoTravelDB[k] = v end
      end

      -- Fruehere Fassungen lieferten andere Standardbefehle. Hat der Spieler sie
      -- nie angefasst, auf die heutigen umstellen; eigene Eingaben bleiben.
      if AutoTravelDB.SelfOnCommand == ".playerbots bot self on" then
         AutoTravelDB.SelfOnCommand = DEFAULTS.SelfOnCommand
      end
      if AutoTravelDB.SelfOffCommand == ".playerbots bot self off" then
         AutoTravelDB.SelfOffCommand = DEFAULTS.SelfOffCommand
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

      -- Handschlag mit kleiner Verzoegerung: unmittelbar nach dem Login ist der
      -- Chat noch nicht zuverlaessig bereit.
      if AT.GetBool("AutoHello") then
         -- Nur, wenn bis dahin keiner lief: ein frueher Start hat den Handschlag
         -- womoeglich schon erledigt, und ein zweiter wuerfe den Zustand auf HELLO
         -- zurueck, solange die Antwort aussteht.
         AT.After(2.5, function() if N.state == "UNKNOWN" then N.Hello() end end)
      end
   end
end)

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
      "/at pause | weiter    Steuerung uebernehmen / zurueckgeben",
      "/at info              Version, Verbindung, Faehigkeiten",
      "/at hello             Servermodul erneut abfragen",
      "/at target            erkanntes Ziel pruefen",
      "/at koords            Weltkoordinaten des Ziels anzeigen",
      "/at diag              Diagnose: warum scheitert der Pfad?",
      "/at knoten            Zustand des Playerbot-Knotengraphen",
      "/at route             Stuetzpunkte der Carbonite-Route anzeigen",
      "/at profil            Profil wechseln (ohne Argument: Liste)",
      "/at profil bearbeiten Profil-Editor oeffnen",
      "/at profil reset <name|alle>  vorgegebene Profile auf den Standard",
      "/at bot               Playerbot-Steuerung an/aus",
      "/at erbstuecke        geschuetzte Erbstuecke anzeigen",
      "/at botan | botaus    Selbstmodus von Hand schalten",
      "/at selfon <befehl>   Befehl zum Einschalten des Selbstmodus",
      "/at selfoff <befehl>  Befehl zum Ausschalten",
      "/at karte <id>        WorldMapArea-ID erzwingen (0 = automatisch)",
      "/at karten            Kartentabelle neu aufbauen",
      "/at tpmodus <modul|go>  Teleportweg waehlen",
      "/at nachfrage         Sicherheitsabfrage vor Teleport an/aus",
      "/at ziel <n>          Zielradius in Yards",
      "/at ruhe <s>          Ruhezeit bis zur Uebernahme (Sekunden)",
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
   elseif cmd == "status" then AT.Send("at status", { key = "status" })
   elseif cmd == "tp" or cmd == "teleport" then AT.Teleport()
   elseif cmd == "pause" then
      if not AT.Handover.Pause() then AT.Print("Gerade nicht moeglich.") end
   elseif cmd == "weiter" or cmd == "resume" then
      if not AT.Handover.Resume() then AT.Print("Gerade nicht moeglich.") end
   elseif cmd == "info" or cmd == "version" then AT.PrintInfo()
   elseif cmd == "hello" then
      if N.state == "HELLO" then AT.Print("Anfrage laeuft bereits.")
      else
         N.state = "UNKNOWN"
         N.Hello()
         AT.Print("Servermodul wird abgefragt ...")
      end

   elseif cmd == "target" then
      local args, nameOrErr = AT.BuildTargetArgs()
      if not args then AT.Warn(nameOrErr)
      else AT.Print("Ziel: " .. nameOrErr .. "  |  Parameter: " .. args) end

   elseif cmd == "profil" or cmd == "profile" then
      local sub, arg = string.match(rest, "^(%S+)%s*(.-)$")
      sub = sub and string.lower(sub) or ""
      arg = string.lower(arg or "")

      if rest == "" then
         AT.Bot.PrintProfiles()

      elseif sub == "bearbeiten" or sub == "edit" then
         AT.ProfileEditor.Open()

      elseif sub == "reset" or sub == "zuruecksetzen" then
         -- /at profil reset <name>   ein festes Profil auf den Standard
         -- /at profil reset alle     alle festen Profile
         local B = AT.Bot
         local touched              -- hat sich am wirksamen Profil etwas geaendert?
         if arg == "" then
            AT.Warn("Welches Profil? '/at profil reset <name>' oder '/at profil reset alle'.")
            return
         elseif arg == "alle" or arg == "all" then
            local current = B.Current().key
            touched = B.IsModified(current)
            B.ResetAllBuiltin()
            AT.Print("Alle vorgegebenen Profile sind wieder auf den Standardwerten.")
         else
            local key
            for _, d in ipairs(B.Builtin) do
               if d.key == arg or string.lower(d.name) == arg then key = d.key end
            end
            if not key then
               AT.Warn("Nur vorgegebene Profile lassen sich zuruecksetzen (eigene: 'Leeren' im Editor).")
               return
            end
            touched = (key == B.Current().key) and B.IsModified(key)
            B.ResetBuiltin(key)
            AT.Print("Profil " .. B.BuiltinDefault(key).name .. " ist wieder auf den Standardwerten.")
         end
         -- Dem Bot nur melden, was sich fuer ihn aendert.
         if touched and B.IsRunning() then B.ApplyProfile() end
         if AT.ProfileEditor and AT.ProfileEditor.Refresh then AT.ProfileEditor.Refresh() end
         if AT.UI then AT.UI.Update() end

      else
         local found
         local want = string.lower(rest)
         for _, p in ipairs(AT.Bot.List()) do
            if string.lower(p.name) == want or p.key == want then found = p end
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
         AT.Gear.Snapshot(true)
         AT.Gear.Report()
      else
         AT.Set("GuardHeirlooms", AT.GetBool("GuardHeirlooms") and 0 or 1)
         AT.Print("Erbstueckschutz " .. (AT.GetBool("GuardHeirlooms") and "AN" or "AUS"))
      end

   elseif cmd == "botan" then AT.Bot.Enable()
   elseif cmd == "botaus" then AT.Bot.Disable()

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
      AT.Send("at nodes", { key = "nodes" })

   elseif cmd == "diag" then
      local args, err = AT.BuildTargetArgs()
      if not args then AT.Warn(err) else AT.Send("at diag " .. args, { key = "diag" }) end

   elseif cmd == "koords" then
      local args, err = AT.BuildTargetArgs()
      if not args then AT.Warn(err) else AT.Send("at resolve " .. args, { key = "resolve" }) end

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
      if n and n >= 1 and n <= 100 then
         AT.Set("ArriveYards", n)
         AT.Set("ArriveCustom", 1)
         AT.SetSessionOption("arrival", n)
         if AT.Options then AT.Options.Load() end
      else
         AT.Print("Verwendung: /at ziel <yards>  (1 bis 100)")
      end

   elseif cmd == "ruhe" then
      local n = tonumber(rest)
      if n and n >= 2 and n <= 60 then
         AT.Set("QuietSeconds", n)
         AT.Print("Ruhezeit bis zur Uebernahme: " .. n .. " s")
         if AT.Options then AT.Options.Load() end
      else
         AT.Print("Verwendung: /at ruhe <sekunden>  (2 bis 60)")
      end

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
      AT.Send("at debug " .. (AT.GetBool("Debug") and "1" or "0"), { key = "debug" })
      AT.Print("Debug " .. (AT.GetBool("Debug") and "AN" or "AUS"))

   else Help() end
end
