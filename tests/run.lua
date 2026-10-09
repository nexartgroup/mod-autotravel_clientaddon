-- tests/run.lua
-- ---------------------------------------------------------------------------
--     lua5.1 tests/run.lua          (im Hauptverzeichnis des Addons)
--
-- Laedt das Addon in TOC-Reihenfolge in die Attrappe aus mock_wow.lua und prueft
-- Ablaeufe, die ohne Spiel pruefbar sind: Protokoll, Handschlag, Warteschlange,
-- Uebergabe, Routenaufteilung, Berechtigungen.
--
-- Was damit NICHT geprueft wird: Aussehen, Anordnung, Verhalten gegen einen
-- echten Server. Das bleibt dem Spiel vorbehalten.
-- ---------------------------------------------------------------------------

package.path = "./tests/?.lua;" .. package.path
local W = require("mock_wow")

local passes, failures = 0, 0
local current = ""

local function check(cond, msg)
   if cond then
      passes = passes + 1
   else
      failures = failures + 1
      print("  FEHLER [" .. current .. "] " .. tostring(msg))
   end
end

local function eq(a, b, msg)
   check(a == b, tostring(msg) .. "  (erwartet " .. tostring(b) .. ", war " .. tostring(a) .. ")")
end

local function boot()
   W.Install()
   W.LoadToc(".", "AutoTravel.toc")
   W.Fire("ADDON_LOADED", "AutoTravel")
   W.Fire("PLAYER_LOGIN")
end

-- Antwort des Servers auf den Handschlag
local CAPS_ALL      = 63    -- Uebergabe, Route, Flug, Teleport, Serveroptionen, Transport
local CAPS_PLAYER   = 39    -- Uebergabe, Route, Flug, Transport -- kein Teleport, keine Serveroptionen

local function hello(caps, sec, proto)
   W.ServerLine(string.format("[AT]H|4.0|1|250|1|1|%d|%d|%d", proto or 4, sec or 0, caps or CAPS_ALL))
end

local function ready(caps, sec)
   boot()
   W.Advance(3)                       -- der Handschlag geht nach 2,5 s hinaus
   hello(caps, sec)
   W.ClearSent()
end

local function status(line)
   W.ServerLine("[AT]S|" .. line)
end

local function count(prefix)
   local n = 0
   for _, c in ipairs(W.SentCommands()) do
      if c:sub(1, #prefix) == prefix then n = n + 1 end
   end
   return n
end

local function test(name, fn)
   current = name
   io.write("- " .. name .. "\n")
   local ok, err = xpcall(function() fn() end, debug.traceback)
   if not ok then
      failures = failures + 1
      print("  ABSTURZ [" .. name .. "] " .. tostring(err))
   end
end

-- ---------------------------------------------------------------------------
-- Laden
-- ---------------------------------------------------------------------------

test("alle Dateien laden, Oberflaeche und Optionen bauen ohne Fehler", function()
   boot()
   local AT = AutoTravel
   check(AT ~= nil and AT.UI and AT.Net and AT.Handover and AT.Options, "Module vorhanden")
   check(_G.AutoTravelPanel ~= nil, "Panel gebaut")
   check(_G.AutoTravelOptionsContent ~= nil, "Optionsseite gebaut")
   -- Die Seite ist deutlich hoeher als das Optionsfenster (~560): ohne ScrollFrame
   -- waere der Rest unerreichbar.
   check(_G.AutoTravelOptionsScroll ~= nil, "Optionsseite liegt in einem ScrollFrame")
   AT.Options.Open()
end)

test("Regression: UI.Update greift nicht auf eine nicht vorhandene Variable zu", function()
   boot()
   local AT = AutoTravel
   AT.active = true
   AT.status.state = "TRAVELING"
   AT.UI.Update()
   eq(_G.AutoTravelPanel.go.label:GetText(), "STOP", "START/STOP-Knopf zeigt STOP waehrend der Reise")
   AT.active = false
   AT.status.state = "IDLE"
   AT.UI.Update()
   eq(_G.AutoTravelPanel.go.label:GetText(), "START", "und wieder START")
end)

test("UI.Update bleibt fuer jeden Zustand des Servers fehlerfrei", function()
   boot()
   local AT = AutoTravel
   for _, st in ipairs({ "IDLE", "REPATHING", "TRAVELING", "COMBAT", "PLAYER", "MOUNTING", "TAKEOFF",
                         "TAXI", "TRANSPORT", "MANUAL", "ARRIVED", "FAILED", "STARTING", "UNBEKANNT" }) do
      AT.active = (st ~= "IDLE" and st ~= "ARRIVED" and st ~= "FAILED")
      AT.status.state = st
      AT.UI.Update()
   end
   check(true, "kein Fehler")
end)

test("jeder Serverzustand hat eine Beschriftung im Panel", function()
   boot()
   for _, st in ipairs({ "IDLE", "REPATHING", "TRAVELING", "COMBAT", "PLAYER", "MOUNTING", "TAKEOFF",
                         "TAXI", "TRANSPORT", "MANUAL", "ARRIVED", "FAILED" }) do
      check(AutoTravel.UI.STATE[st] ~= nil, "Zustand " .. st)
   end
end)

-- ---------------------------------------------------------------------------
-- Handschlag
-- ---------------------------------------------------------------------------

test("der Handschlag geht nach dem Login hinaus und macht READY", function()
   boot()
   eq(count(".at hello"), 0, "nicht sofort")
   W.Advance(3)
   eq(count(".at hello"), 1, "Handschlag gesendet")
   eq(AutoTravel.Net.state, "HELLO", "wartet auf Antwort")
   hello(CAPS_ALL, 3)
   eq(AutoTravel.Net.state, "READY", "verbunden")
   eq(AutoTravel.server.sec, 3, "Kontostufe uebernommen")
   eq(AutoTravel.server.proto, 4, "Protokoll uebernommen")
end)

test("Modulbefehle warten auf den Handschlag und gehen danach in Reihenfolge hinaus", function()
   boot()
   -- Vor dem Handschlag: nichts darf hinausgehen
   AutoTravel.Send("at status")
   AutoTravel.Send("at repath")
   W.Advance(1)
   eq(count(".at status"), 0, "kein Modulbefehl vor dem Handschlag")
   eq(count(".at hello"), 1, "der Befehl loeste den Handschlag aus")
   hello()
   W.Advance(2)
   local cmds = W.SentCommands()
   local iStatus, iRepath
   for i, c in ipairs(cmds) do
      if c == ".at status" then iStatus = i end
      if c == ".at repath" then iRepath = i end
   end
   check(iStatus and iRepath and iStatus < iRepath, "vorgemerkte Befehle gehen nach READY in Reihenfolge hinaus")
end)

test("ohne Antwort: zweiter Versuch, dann ABSENT, danach keine Modulbefehle mehr", function()
   boot()
   W.Advance(3)
   W.Advance(5.5)
   W.Advance(5.5)
   eq(count(".at hello"), 2, "genau zwei Versuche")
   eq(AutoTravel.Net.state, "ABSENT", "kein Modul")
   W.ClearSent()
   local ok = AutoTravel.Send("at start 1 0.5 0.5 0 0 0 0 0 0 Ziel")
   check(ok == false, "Befehl wird abgelehnt")
   W.Advance(2)
   eq(count(".at start"), 0, "nichts geht hinaus (sonst riefe der Charakter es in /sagen)")
end)

test("'/at hello' versucht es nach ABSENT erneut", function()
   boot()
   W.Advance(3) W.Advance(5.5) W.Advance(5.5)
   eq(AutoTravel.Net.state, "ABSENT", "ABSENT")
   W.ClearSent()
   SlashCmdList["AUTOTRAVEL"]("hello")
   W.Advance(1)
   eq(count(".at hello"), 1, "neuer Handschlag")
   hello()
   eq(AutoTravel.Net.state, "READY", "wieder verbunden")
end)

test("aelteres Modul ohne Protokollfeld bleibt benutzbar", function()
   boot()
   W.Advance(3)
   W.ServerLine("[AT]H|3.2|1|250|1|1")
   eq(AutoTravel.Net.state, "READY", "READY")
   eq(AutoTravel.server.capsKnown, false, "Faehigkeiten unbekannt")
   check(AutoTravel.Net.Can("TELEPORT"), "Knoepfe bleiben optimistisch frei")
   check(AutoTravel.Net.Can("SETTINGS"), "Einstellungen bleiben frei")
end)

test("zu altes Modul wird erkannt", function()
   boot()
   W.Advance(3)
   W.ServerLine("[AT]H|1.0|1|0|0|0|2|0|0")
   eq(AutoTravel.Net.state, "INCOMPATIBLE", "unvertraeglich")
   check(AutoTravel.Net.Can("HANDOVER") == false, "keine Faehigkeit")
end)

test("serverseitig abgeschaltetes Modul wird erkannt", function()
   boot()
   W.Advance(3)
   W.ServerLine("[AT]H|4.0|0|0|0|0|4|0|0")
   eq(AutoTravel.Net.state, "DISABLED", "abgeschaltet")
end)

test("nach dem Handschlag wird der selbst gewaehlte Zielradius erneut gemeldet", function()
   boot()
   AutoTravel.Set("ArriveCustom", 1)
   AutoTravel.Set("ArriveYards", 15)
   W.Advance(3)
   hello()
   W.Advance(2)
   check(W.SentContains(".at set arrival 15"), "Zielradius erneut gesendet")
end)

test("ohne eigene Einstellung wird der Zielradius des Servers nicht ueberschrieben", function()
   boot()
   W.Advance(3)
   hello()
   W.Advance(2)
   eq(count(".at set arrival"), 0, "kein Eingriff")
end)

-- ---------------------------------------------------------------------------
-- Protokoll
-- ---------------------------------------------------------------------------

test("Status mit neun Feldern wird gelesen (Regression: das Addon erwartete sechs)", function()
   ready()
   status("TRAVELING|412|Sturmwind Bank|9|35|0|2|5|40")
   local s = AutoTravel.status
   eq(s.state, "TRAVELING", "Zustand")
   eq(s.distance, 412, "Entfernung")
   eq(s.target, "Sturmwind Bank", "Ziel")
   eq(s.mounted, 1, "beritten (Flag 1)")
   eq(s.driving, true, "Server steuert (Flag 8)")
   eq(s.paused, false, "nicht pausiert")
   eq(s.leg, 2, "Etappe")
   eq(s.legs, 5, "Etappen")
   eq(s.progress, 40, "Fortschritt")
   eq(AutoTravel.active, true, "Reise aktiv")
end)

test("Status IDLE beendet die Reise im Addon", function()
   ready()
   status("TRAVELING|100|Ziel|0|10|0|1|1|10")
   check(AutoTravel.active, "aktiv")
   status("IDLE|0|-|0|0|0|0|0|0")
   eq(AutoTravel.active, false, "nicht mehr aktiv")
end)

test("Status mit weniger oder mehr Feldern bringt nichts zum Absturz", function()
   ready()
   status("TRAVELING|100|Ziel")
   status("TRAVELING|100|Ziel|1|2|3|4|5|6|7|8|9")
   status("")
   status("|")
   W.ServerLine("[AT]S")
   W.ServerLine("[AT]")
   W.ServerLine("[AT]X|irgendwas")
   W.ServerLine("[AT]W|0|1|2")
   check(true, "kein Fehler")
end)

test("Protokollzeilen werden im Chat verborgen, normale nicht", function()
   boot()
   check(W.Filtered("CHAT_MSG_SYSTEM", "[AT]S|TRAVELING|1|x|0|0|0|0|0|0"), "Protokollzeile verborgen")
   check(W.Filtered("CHAT_MSG_SYSTEM", "Willkommen in der Welt") == false, "normale Zeile bleibt")
   AutoTravel.Set("HideProtocol", 0)
   check(W.Filtered("CHAT_MSG_SYSTEM", "[AT]M|x") == false, "bei HideProtocol=0 sichtbar")
end)

test("Meldungen des Servers erscheinen im Chatfenster", function()
   ready()
   W.ServerLine("[AT]M|Reise gestartet: Test")
   local found = false
   for _, m in ipairs(W.messages) do if m:find("Reise gestartet: Test", 1, true) then found = true end end
   check(found, "Meldung angezeigt")
end)

-- ---------------------------------------------------------------------------
-- Warteschlange
-- ---------------------------------------------------------------------------

test("gleicher Schluessel: nur der letzte Wert geht hinaus", function()
   ready()
   AutoTravel.Send("at set natural 1", { key = "set:natural" })
   AutoTravel.Send("at set natural 0", { key = "set:natural" })
   AutoTravel.Send("at set natural 1", { key = "set:natural" })
   W.Advance(3)
   eq(count(".at set natural"), 1, "nur eine Meldung")
   check(W.SentContains(".at set natural 1"), "und zwar die letzte")
end)

test("dringende Befehle ueberholen wartende", function()
   ready()
   AutoTravel.Send("at status")
   AutoTravel.Send("at nodes")
   AutoTravel.Send("at taxi")
   AutoTravel.SendNow("at stop")
   W.Advance(0.6)
   local cmds = W.SentCommands()
   local iStop, iLast
   for i, c in ipairs(cmds) do
      if c == ".at stop" then iStop = i end
      if c == ".at taxi" then iLast = i end
   end
   check(iStop ~= nil, "Stop gesendet")
   check(iLast == nil or iStop < iLast, "Stop vor dem letzten normalen Befehl")
end)

test("Befehle gehen mit Abstand hinaus (Flutbremse des Clients)", function()
   ready()
   for i = 1, 5 do AutoTravel.Send("at status", { key = nil }) end
   W.Advance(0.3)
   check(#W.sent <= 1, "in 0,3 s hoechstens ein normaler Befehl, waren " .. #W.sent)
   W.Advance(3)
   eq(#W.sent, 5, "alle fuenf kommen an")
end)

test("Raw-Befehle brauchen keinen Handschlag", function()
   boot()
   AutoTravel.Send("playerbots bot self", { raw = true })
   W.Advance(1)
   check(W.SentContains(".playerbots bot self"), "Playerbot-Befehl gesendet")
   eq(AutoTravel.Net.state, "UNKNOWN", "kein Handschlag ausgeloest")
end)

test("DropTag verwirft nur markierte Aktionen", function()
   ready()
   AutoTravel.Queue(function() W.sent[#W.sent + 1] = { text = "BOT1" } end, "bot")
   AutoTravel.Queue(function() W.sent[#W.sent + 1] = { text = "BOT2" } end, "bot")
   AutoTravel.Queue(function() W.sent[#W.sent + 1] = { text = "ANDERE" } end)
   eq(AutoTravel.Net.DropTag("bot"), 2, "zwei verworfen")
   W.Advance(2)
   check(not W.SentContains("BOT1") and not W.SentContains("BOT2"), "markierte kamen nicht an")
   check(W.SentContains("ANDERE"), "unmarkierte schon")
end)

-- ---------------------------------------------------------------------------
-- Uebergabe
-- ---------------------------------------------------------------------------

test("Uebernehmen sendet .at pause; die Pause endet nicht von selbst", function()
   ready()
   status("TRAVELING|300|Ziel|8|20|0|1|1|10")
   check(AutoTravel.Handover.CanPause(), "Uebernehmen moeglich")
   check(AutoTravel.Handover.Pause(), "Pause angefordert")
   W.Advance(0.5)
   check(W.SentContains(".at pause"), ".at pause gesendet")

   status("PLAYER|300|Ziel|16|0|0|1|1|10")       -- Flag 16: vom Spieler pausiert
   check(AutoTravel.Handover.IsManual(), "ausdruecklich uebernommen")
   W.ClearSent()
   W.Advance(120)                                  -- zwei Minuten voellige Ruhe
   eq(count(".at resume"), 0, "keine automatische Rueckgabe nach Handpause")
   check(AutoTravel.Handover.CanResume(), "Weiter moeglich")

   AutoTravel.Handover.Resume()
   W.Advance(0.5)
   check(W.SentContains(".at resume"), "Weiter per Knopf sendet .at resume")
end)

test("nach dem Kampf: Ruhezeit, Countdown, dann .at resume", function()
   ready()
   status("TRAVELING|300|Ziel|8|20|0|1|1|10")
   status("COMBAT|300|Ziel|0|0|0|1|1|10")
   status("PLAYER|300|Ziel|0|0|0|1|1|10")         -- Flag 16 fehlt: nicht ausdruecklich
   W.ClearSent()

   W.Advance(7)
   eq(count(".at resume"), 0, "nach 7 s noch nicht")
   eq(AutoTravel.Handover.countdown, nil, "noch kein Countdown")

   W.Advance(2)                                    -- 9 s: Ruhezeit (8) ist um
   check(AutoTravel.Handover.countdown ~= nil, "Countdown laeuft")
   check(AutoTravel.Handover.countdown <= 3 and AutoTravel.Handover.countdown > 1, "Countdown zaehlt von 3")
   check((AutoTravel.Handover.StatusText() or ""):find("Autopilot in", 1, true) ~= nil, "Anzeige nennt den Countdown")
   eq(count(".at resume"), 0, "noch nicht gesendet")

   W.Advance(3)                                    -- 12 s
   eq(count(".at resume"), 1, "genau ein .at resume")
end)

test("Eingabe waehrend des Countdowns bricht ihn ab", function()
   ready()
   status("PLAYER|300|Ziel|0|0|0|1|1|10")
   W.Advance(9)
   check(AutoTravel.Handover.countdown ~= nil, "Countdown laeuft")

   W.world.speed = 7                               -- der Spieler laeuft los
   W.Advance(0.5)
   eq(AutoTravel.Handover.countdown, nil, "Countdown abgebrochen")
   W.world.speed = 0
   W.ClearSent()

   W.Advance(7)
   eq(count(".at resume"), 0, "die Ruhezeit beginnt von vorn")
   W.Advance(5)
   eq(count(".at resume"), 1, "danach geht es weiter")
end)

test("jede Art von Eingabe zaehlt als Aktivitaet", function()
   ready()
   local H = AutoTravel.Handover
   local function active() local a = H.Activity() return a end
   check(not active(), "Grundzustand ruhig")

   local cases = {
      { "tot",         function(v) W.world.dead = v end },
      { "Kampf",       function(v) W.world.combat = v end },
      { "Bewegung",    function(v) W.world.speed = v and 7 or 0 end },
      { "Fallen",      function(v) W.world.falling = v end },
      { "Mausblick",   function(v) W.world.mouselook = v end },
      { "Maustaste",   function(v) W.world.mouse.LeftButton = v end },
      { "Umschalter",  function(v) W.world.shift = v end },
      { "Zaubern",     function(v) W.world.casting = v end },
      { "Kanal",       function(v) W.world.channel = v end },
      { "Chat",        function(v) W.world.chatOpen = v end },
      { "Gegenstand",  function(v) W.world.cursorItem = v end },
      { "Beutefenster",function(v) W.SetFrameShown("LootFrame", v) end },
      { "Haendler",    function(v) W.SetFrameShown("MerchantFrame", v) end },
      { "Karte",       function(v) W.SetFrameShown("WorldMapFrame", v) end },
   }
   for _, c in ipairs(cases) do
      c[2](true)
      check(active(), c[1] .. " zaehlt als Aktivitaet")
      c[2](false)
      check(not active(), c[1] .. " vorbei -> wieder ruhig")
   end

   -- Mausbewegung: erst ein merkliches Stueck
   H.Activity()                                    -- Stand abtasten
   W.world.cursor = { 101, 101 }
   check(not active(), "Zittern des Zeigers zaehlt nicht")
   W.world.cursor = { 160, 140 }
   check(active(), "echte Mausbewegung zaehlt")
   check(not active(), "danach wieder ruhig, wenn der Zeiger stillsteht")
end)

test("Mausposition wird auch bei anderer Aktivitaet abgetastet (kein Phantombewegung danach)", function()
   ready()
   local H = AutoTravel.Handover
   H.Activity()
   W.world.speed = 7
   W.world.cursor = { 500, 500 }
   check(H.Activity(), "Bewegung")
   W.world.speed = 0
   local a, why = H.Activity()
   check(not a, "Zeiger steht still -> ruhig (war: " .. tostring(why) .. ")")
end)

test("ein toter Spieler bekommt keine Rueckgabe", function()
   ready()
   status("PLAYER|300|Ziel|0|0|0|1|1|10")
   W.world.dead = true
   W.Advance(30)
   eq(count(".at resume"), 0, "keine Rueckgabe, solange der Spieler tot ist")
end)

test("AutoResume aus: der Autopilot wartet auf den Knopf", function()
   ready()
   AutoTravel.Set("AutoResume", 0)
   status("PLAYER|300|Ziel|0|0|0|1|1|10")
   W.Advance(60)
   eq(count(".at resume"), 0, "keine automatische Rueckgabe")
end)

test("Uebernehmen ist nur in sinnvollen Zustaenden moeglich", function()
   ready()
   local H = AutoTravel.Handover
   status("TAXI|900|Ziel|0|0|0|1|2|10")
   check(not H.CanPause(), "nicht waehrend eines Flugs")
   status("TRANSPORT|900|Ziel|0|0|0|1|2|10")
   check(not H.CanPause(), "nicht auf einem Transport")
   status("COMBAT|900|Ziel|0|0|0|1|2|10")
   check(not H.CanPause() and not H.CanResume(), "nicht im Kampf")
   status("TRAVELING|900|Ziel|8|0|0|1|2|10")
   check(H.CanPause(), "beim Fahren")
end)

test("Taste und Knopf schalten je nach Lage um", function()
   ready()
   local H = AutoTravel.Handover
   status("TRAVELING|300|Ziel|8|20|0|1|1|10")
   H.Toggle()
   W.Advance(0.5)
   check(W.SentContains(".at pause"), "Toggle waehrend der Fahrt uebernimmt")
   status("PLAYER|300|Ziel|16|0|0|1|1|10")
   W.ClearSent()
   H.Toggle()
   W.Advance(0.5)
   check(W.SentContains(".at resume"), "Toggle waehrend der Uebergabe gibt zurueck")
end)

test("eine nie bestaetigte Pause haelt die Anzeige nicht dauerhaft fest", function()
   ready()
   local H = AutoTravel.Handover
   status("TRAVELING|300|Ziel|8|20|0|1|1|10")
   H.Pause()
   check(H.IsManual(), "zunaechst als Pause angezeigt")
   W.Advance(6)
   check(not H.IsManual(), "nach 5 s ohne Bestaetigung wieder zurueckgenommen")
end)

-- ---------------------------------------------------------------------------
-- Berechtigungen
-- ---------------------------------------------------------------------------

test("serverweite Einstellungen werden Spielern nicht gesendet", function()
   ready(CAPS_PLAYER, 0)
   AutoTravel.SetServerBool("natural", 0)
   W.Advance(2)
   eq(count(".at set natural"), 0, "kein Befehl fuer einen normalen Spieler")
   check(AutoTravelDB.natural == nil, "kein Muell unter dem Serverschluessel in den gespeicherten Variablen")
end)

test("Spielleiter senden serverweite Einstellungen", function()
   ready(CAPS_ALL, 2)
   AutoTravel.SetServerBool("natural", 0)
   W.Advance(2)
   check(W.SentContains(".at set natural 0"), "Befehl gesendet")
end)

test("Dezimalwerte gehen mit Punkt hinaus", function()
   ready(CAPS_ALL, 2)
   AutoTravel.SetServerNumber("contour_slope", 0.25)
   W.Advance(2)
   check(W.SentContains(".at set contour_slope 0.25"), "mit Punkt")
end)

test("Teleport wird ohne Berechtigung nicht angeboten", function()
   ready(CAPS_PLAYER, 0)
   AutoTravel.UI.Update()
   eq(_G.AutoTravelPanel.tp:IsEnabled(), nil, "Teleportknopf gesperrt")
   AutoTravel.Teleport()
   W.Advance(2)
   eq(count(".at tp"), 0, "nichts gesendet")
   eq(W.popup, nil, "keine Abfrage geoeffnet")
end)

test("Teleport-Knopf ist mit Berechtigung frei", function()
   ready(CAPS_ALL, 2)
   AutoTravel.UI.Update()
   eq(_G.AutoTravelPanel.tp:IsEnabled(), 1, "Teleportknopf frei")
end)

test("Einstellungsseite sperrt serverweite Werte fuer Spieler und gibt sie Spielleitern frei", function()
   ready(CAPS_PLAYER, 0)
   AutoTravel.Options.Load()
   local lockedChecks, lockedSliders = 0, 0
   for i = 1, 60 do
      local c = _G["AutoTravelOptCheck" .. i]
      if c and c.serverSide then
         lockedChecks = lockedChecks + 1
         check(c:IsEnabled() == nil, "Haken " .. i .. " gesperrt")
      end
      local s = _G["AutoTravelOptSlider" .. i]
      if s and s.serverSide then lockedSliders = lockedSliders + 1 end
   end
   check(lockedChecks >= 2, "mindestens zwei serverweite Haken (waren " .. lockedChecks .. ")")
   check(lockedSliders >= 4, "mindestens vier serverweite Regler (waren " .. lockedSliders .. ")")

   hello(CAPS_ALL, 2)
   for i = 1, 60 do
      local c = _G["AutoTravelOptCheck" .. i]
      if c and c.serverSide then check(c:IsEnabled() == 1, "Haken " .. i .. " frei fuer Spielleiter") end
   end
end)

-- ---------------------------------------------------------------------------
-- Ziel, Route, Start
-- ---------------------------------------------------------------------------

-- Carbonite-Attrappe: ein Ziel in "Elwynn" (Karten-ID 12), Routenpunkte in Zonenkoordinaten
local function installCarbonite(nPoints)
   local current = 0
   local ids = { Elwynn = 12, Westfall = 40, EK = 14 }
   _G.GetMapContinents = function() return "Oestliche Koenigreiche" end
   _G.GetMapZones = function(c) return "Elwynn", "Westfall" end
   _G.SetMapZoom = function(c, z)
      current = (z == 0) and ids.EK or ((z == 1) and ids.Elwynn or ids.Westfall)
   end
   _G.GetCurrentMapAreaID = function() return current end
   _G.SetMapByID = function(id) current = id end
   _G.SetMapToCurrentZone = function() current = ids.Elwynn end
   _G.GetPlayerMapPosition = function() return 0.40, 0.60 end

   local tra = {}
   for i = 1, nPoints do
      tra[#tra + 1] = { TMX = i, TMY = i * 2, MaI = 1, TaN1 = "Punkt " .. i }
   end
   tra[#tra].TaN1 = "Sturmwind |cffff0000Bank|r"      -- Name mit Farbcode: darf nicht roh hinausgehen
   _G.Nx = {
      Map = { GeM = function()
         return {
            Tra1 = tra, Tar = {}, PlX = 1, PlY = 1,
            GZP = function(self, mi, x, y) return 10 + x * 2, 20 + y end,   -- Zonenkoordinaten 0..100
         }
      end },
      MITN = { "Elwynn" },
   }
end

test("Einzelziel: .at start mit allen Parametern und bereinigtem Namen", function()
   ready()
   installCarbonite(1)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Start()
   W.Advance(2)
   local start
   for _, c in ipairs(W.SentCommands()) do if c:sub(1, 10) == ".at start " then start = c end end
   check(start ~= nil, ".at start gesendet")
   if start then
      local fields = {}
      for w in start:gmatch("%S+") do fields[#fields + 1] = w end
      eq(fields[3], "12", "Karten-ID aus dem Zonennamen")
      eq(fields[6], "1", "Gegenprobe vorhanden")
      check(not start:find("|", 1, true), "kein '|' im Befehl (Farbcodes entfernt)")
      check(start:find("Sturmwind", 1, true) ~= nil, "Name bleibt erkennbar")
   end
   eq(AutoTravel.active, true, "Reise gilt als aktiv")
end)

test("Route: Aufteilung in Chatnachrichten und .at rstart", function()
   ready()
   installCarbonite(12)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Start()
   W.Advance(6)
   local cmds = W.SentCommands()
   local routes, rstart = {}, nil
   for _, c in ipairs(cmds) do
      if c:sub(1, 10) == ".at route " then routes[#routes + 1] = c end
      if c:sub(1, 10) == ".at rstart" then rstart = c end
   end
   check(#routes >= 1, "Route gesendet")
   check(rstart ~= nil, ".at rstart gesendet")
   check(routes[1]:sub(1, 12) == ".at route 0 ", "erste Nachricht ersetzt (0)")
   for i = 2, #routes do check(routes[i]:sub(1, 12) == ".at route 1 ", "weitere Nachrichten haengen an (1)") end
   for _, r in ipairs(routes) do check(#r <= 220, "Nachricht passt in den Chat (" .. #r .. " Zeichen)") end
   -- rstart kommt nach der letzten Routennachricht
   local lastRoute, iR = 0, 0
   for i, c in ipairs(cmds) do
      if c:sub(1, 10) == ".at route " then lastRoute = i end
      if c:sub(1, 10) == ".at rstart" then iR = i end
   end
   check(iR > lastRoute, "rstart nach der letzten Routennachricht")
end)

test("PackRoute: kein Punkt geht verloren, jede Nachricht bleibt im Limit", function()
   boot()
   local route = {}
   for i = 1, 24 do route[i] = { map = 1500 + i, nx = 0.123456, ny = 0.654321, flag = i % 2 } end
   local cmds = AutoTravel.PackRoute(route)
   local tokens = 0
   for _, c in ipairs(cmds) do
      check(#c <= 11 + 200, "Limit eingehalten: " .. #c)
      for _ in c:gmatch("%d+:%d%.%d+:%d%.%d+:%d") do tokens = tokens + 1 end
   end
   eq(tokens, 24, "alle 24 Punkte uebertragen")
   eq(#AutoTravel.PackRoute({}), 0, "leere Route erzeugt keine Befehle (Start sendet nie eine)")
end)

test("Start ohne Carbonite meldet es, statt etwas zu senden", function()
   ready()
   AutoTravel.Start()
   W.Advance(2)
   eq(count(".at start"), 0, "kein Start gesendet")
   eq(AutoTravel.active, false, "nicht aktiv")
end)

test("Stop geht sofort hinaus und beendet den aktiven Zustand", function()
   ready()
   status("TRAVELING|300|Ziel|8|20|0|1|1|10")
   AutoTravel.Stop()
   W.Advance(0.3)
   check(W.SentContains(".at stop"), ".at stop gesendet")
   eq(AutoTravel.active, false, "nicht mehr aktiv")
end)

test("ohne Handschlag wartet der Start auf READY (und ruft nichts in /sagen)", function()
   boot()                              -- noch kein Handschlag
   installCarbonite(1)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Start()
   W.Advance(1)
   eq(count(".at start"), 0, "Start wartet")
   check(count(".at hello") >= 1, "Handschlag laeuft")
   hello()
   W.Advance(5)                        -- vor dem Start stehen noch die Strategiebefehle des Bots
   eq(count(".at start"), 1, "Start geht nach READY hinaus")
   eq(count(".at hello"), 1, "der Handschlag beim Anmelden wird nicht wiederholt, wenn der Start ihn schon erledigt hat")
end)

-- ---------------------------------------------------------------------------
-- Playerbot
-- ---------------------------------------------------------------------------

test("Playerbot: aktuelle und aeltere Bestaetigungstexte werden erkannt", function()
   ready()
   local B = AutoTravel.Bot
   W.ServerLine("SelfBot is now active.")
   eq(B.confirmed, true, "aktueller Text: an")
   W.ServerLine("SelfBot is now deactivated.")
   eq(B.confirmed, false, "aktueller Text: aus")
   W.ServerLine("Enable player botAI")
   eq(B.confirmed, true, "alter Text: an")
   W.ServerLine("Disable player botAI")
   eq(B.confirmed, false, "alter Text: aus")
end)

test("Playerbot: Verweigerung durch den Server wird erklaert und raeumt die Warteschlange", function()
   ready()
   local B = AutoTravel.Bot
   B.Enable()
   check(AutoTravel.Net.DropTag ~= nil, "DropTag vorhanden")
   W.ServerLine("SelfBot is restricted for this account.")
   eq(B.confirmed, false, "als aus gewertet")
   check(B.refused ~= nil, "Verweigerung gemerkt")
   W.Advance(3)
   local whispers = 0
   for _, s in ipairs(W.sent) do if s.channel == "WHISPER" then whispers = whispers + 1 end end
   eq(whispers, 0, "die Strategiebefehle hinter dem Umschalter wurden verworfen")
   local warned = false
   for _, m in ipairs(W.messages) do if m:find("verweigert", 1, true) then warned = true end end
   check(warned, "Spieler wird informiert")
end)

test("Playerbot: Standardbefehl ist der heutige Umschalter", function()
   boot()
   eq(AutoTravel.Get("SelfOnCommand"), ".playerbots bot self", "Einschaltbefehl")
   eq(AutoTravel.Get("SelfOffCommand"), ".playerbots bot self", "Ausschaltbefehl")
end)

test("alte Standardbefehle werden umgestellt, eigene bleiben", function()
   W.Install()
   _G.AutoTravelDB = { SelfOnCommand = ".playerbots bot self on", SelfOffCommand = ".mein befehl" }
   W.LoadToc(".", "AutoTravel.toc")
   W.Fire("ADDON_LOADED", "AutoTravel")
   eq(AutoTravelDB.SelfOnCommand, ".playerbots bot self", "alter Standard ersetzt")
   eq(AutoTravelDB.SelfOffCommand, ".mein befehl", "eigene Eingabe bleibt")
end)

test("Selbstmodus einschalten sendet den Befehl ohne Handschlag", function()
   boot()
   AutoTravel.Bot.Enable()
   W.Advance(1)
   check(W.SentContains(".playerbots bot self"), "Umschalter gesendet")
end)

test("Playerbot: alle Verweigerungstexte werden erkannt", function()
   for _, text in ipairs({ "SelfBot is disabled server-wide.",
                           "SelfBot is restricted for this account.",
                           "Playerbot system is currently disabled!",
                           "You cannot control bots yet" }) do
      ready()
      AutoTravel.Bot.Enable()
      W.ServerLine(text)
      eq(AutoTravel.Bot.confirmed, false, "als aus gewertet: " .. text)
      check(AutoTravel.Bot.refused ~= nil, "Verweigerung gemerkt: " .. text)
   end
end)

test("Playerbot: Gegenteil bestaetigt -> einmal erneut umschalten, Profil danach neu anwenden", function()
   ready()
   local B = AutoTravel.Bot
   B.Enable()                                   -- Zustand unbekannt: gewuenscht ist "an"
   W.ServerLine("SelfBot is now deactivated.")  -- war in Wahrheit schon an: der Klick hat ausgeschaltet
   W.Advance(2)
   eq(count(".playerbots bot self"), 2, "genau ein Wiederholungsversuch")
   local before = 0
   for _, x in ipairs(W.sent) do if x.channel == "WHISPER" then before = before + 1 end end
   eq(before, 0, "die Strategiebefehle hinter dem ersten Umschalter wurden verworfen")
   W.ServerLine("SelfBot is now active.")
   W.Advance(10)
   eq(B.confirmed, true, "Endzustand an")
   eq(count(".playerbots bot self"), 2, "kein dritter Umschalter")
   local resets = 0
   for _, x in ipairs(W.sent) do if x.channel == "WHISPER" and x.text == "co !" then resets = resets + 1 end end
   eq(resets, 1, "Profil nach dem Erfolg genau einmal angewandt")
end)

test("Playerbot: zweite Abweichung gibt auf und meldet, statt zu pendeln", function()
   ready()
   AutoTravel.Bot.Enable()
   W.ServerLine("SelfBot is now deactivated.")
   W.Advance(1)
   W.ServerLine("SelfBot is now deactivated.")
   W.Advance(2)
   eq(count(".playerbots bot self"), 2, "es bleibt bei einem Wiederholungsversuch")
   local warned = false
   for _, m in ipairs(W.messages) do if m:find("nicht in den gewuenschten Zustand", 1, true) then warned = true end end
   check(warned, "Spieler informiert")
end)

test("/at profil <name> waehlt das Profil und kennt auch Gross-/Kleinschreibung nicht", function()
   ready()
   SlashCmdList["AUTOTRAVEL"]("profil verteidigen")
   eq(AutoTravel.Get("Profile"), "verteidigen", "Profil gewaehlt")
   SlashCmdList["AUTOTRAVEL"]("profil Plus")
   eq(AutoTravel.Get("Profile"), "plus", "Name in anderer Schreibweise")
   SlashCmdList["AUTOTRAVEL"]("profil gibtsnicht")
   eq(AutoTravel.Get("Profile"), "plus", "unbekanntes Profil aendert nichts")
end)

test("Profil Plus: sammelt per nc-Strategie, ll bleibt gueltig", function()
   ready()
   local plus
   for _, p in ipairs(AutoTravel.Bot.List()) do if p.key == "plus" then plus = p end end
   check(plus ~= nil, "Profil vorhanden")
   check(plus.noncombat:find("+gather", 1, true) ~= nil, "+gather")
   check(plus.noncombat:find("+loot", 1, true) ~= nil, "+loot")
   for _, e in ipairs(plus.extra or {}) do
      check(e == "ll normal" or e == "ll all", "ll-Wert gueltig: " .. e)
   end
end)

-- ---------------------------------------------------------------------------
-- Warteschlange, Start und Stop
-- ---------------------------------------------------------------------------

test("Stop verwirft einen noch wartenden Start hinter dem Handschlag", function()
   boot()
   installCarbonite(1)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Start()
   W.Advance(0.5)
   AutoTravel.Stop()
   hello()
   W.Advance(8)
   eq(count(".at start"), 0, "der verworfene Start geht nie hinaus")
   eq(AutoTravel.active, false, "nicht aktiv")
end)

test("Stop verwirft einen Start, der schon in der Warteschlange steht (Route)", function()
   ready()
   installCarbonite(3)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Start()
   AutoTravel.Stop()                  -- keine Zeit dazwischen: alles steht noch in der Schlange
   W.Advance(5)
   eq(count(".at route"), 0, "keine Routenbefehle")
   eq(count(".at rstart"), 0, "kein rstart")
   eq(count(".at start"), 0, "kein start")
   eq(count(".at stop"), 1, "genau ein stop")
end)

test("Start ohne Statusmeldung: nach der Frist zurueckgenommen, mit Status bleibt er", function()
   ready()
   installCarbonite(1)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Start()
   W.Advance(1)
   eq(AutoTravel.active, true, "zunaechst aktiv")
   W.Advance(9)
   eq(AutoTravel.active, false, "ohne Statusmeldung zurueckgenommen")
   local warned = false
   for _, m in ipairs(W.messages) do if m:find("Keine Statusmeldung", 1, true) then warned = true end end
   check(warned, "Spieler informiert")

   AutoTravel.Start()
   W.Advance(1)
   status("TRAVELING|300|Ziel|8|20|0|1|1|10")
   W.Advance(12)
   eq(AutoTravel.active, true, "mit Status bleibt die Reise aktiv")
end)

test("wartender Start wird bei abgeschaltetem oder zu altem Modul verworfen", function()
   for _, line in ipairs({ "[AT]H|4.0|0|0|0|0|4|0|0", "[AT]H|1.0|1|0|0|0|2|0|0" }) do
      boot()
      installCarbonite(1)
      AutoTravel.MapIds.Build(true)
      AutoTravel.Start()
      W.ServerLine(line)
      eq(AutoTravel.active, false, "nicht mehr aktiv: " .. line)
      eq(AutoTravel.status.state, "IDLE", "Anzeige IDLE: " .. line)
      W.Advance(6)
      eq(count(".at start"), 0, "nichts gesendet: " .. line)
   end
end)

test("eine Statuszeile holt das Addon aus ABSENT zurueck", function()
   boot()
   W.Advance(3) W.Advance(5.5) W.Advance(5.5)
   eq(AutoTravel.Net.state, "ABSENT", "ABSENT")
   status("TRAVELING|300|Ziel|8|20|0|1|1|10")
   eq(AutoTravel.Net.state, "READY", "Modul antwortet also: READY")
   W.ClearSent()
   AutoTravel.Stop()
   W.Advance(1)
   eq(count(".at stop"), 1, "Stop geht wieder hinaus")
end)

test("der Anmeldehandschlag wird nicht wiederholt, wenn ein Start ihn schon erledigt hat", function()
   boot()
   AutoTravel.Send("at status")
   hello()
   W.Advance(5)
   eq(AutoTravel.Net.state, "READY", "READY bleibt")
   eq(count(".at hello"), 1, "genau ein Handschlag")
end)

-- ---------------------------------------------------------------------------
-- Uebergabe: Rueckgabe-Abstand, weitere Fenster
-- ---------------------------------------------------------------------------

test("Rueckgabe: Mindestabstand, auch bei winziger Ruhezeit ohne Countdown", function()
   ready()
   AutoTravel.Set("QuietSeconds", 1)
   AutoTravel.Set("CountdownSeconds", 0)
   status("PLAYER|300|Ziel|0|0|0|1|1|10")          -- der Server antwortet nie auf .at resume
   W.ClearSent()
   W.Advance(14)
   local n = count(".at resume")
   check(n >= 2 and n <= 3, "hoechstens alle 6 s ein .at resume (waren " .. n .. ")")
end)

test("weitere Fenster und Zustaende zaehlen als Aktivitaet", function()
   ready()
   local H = AutoTravel.Handover
   local function active() local a = H.Activity() return a end
   for _, name in ipairs({ "ClassTrainerFrame", "FriendsFrame", "LFDParentFrame", "AchievementFrame",
                           "PVPParentFrame", "CinematicFrame", "MovieFrame" }) do
      W.SetFrameShown(name, true)
      check(active(), name .. " offen -> Aktivitaet")
      W.SetFrameShown(name, false)
      check(not active(), name .. " zu -> ruhig")
   end
   W.world.onTaxi = true
   check(active(), "Flug mit dem Flugmeister")
   W.world.onTaxi = false
   W.world.vehicle = true
   check(active(), "Fahrzeug")
   W.world.vehicle = false
   check(not active(), "wieder ruhig")
end)

-- ---------------------------------------------------------------------------
-- Karten
-- ---------------------------------------------------------------------------

test("SetMap: bestaetigt die Karte und kommt mit um eins verschobenem SetMapByID zurecht", function()
   boot()
   local cur = 0
   _G.GetCurrentMapAreaID = function() return cur end

   _G.SetMapByID = function(id) cur = id end                -- wie dokumentiert
   check(AutoTravel.MapIds.SetMap(12), "direkter Treffer")
   eq(cur, 12, "Karte 12")

   _G.SetMapByID = function(id) cur = id + 1 end            -- verschoben: id zeigt auf id+1
   check(AutoTravel.MapIds.SetMap(12), "Treffer mit id-1")
   eq(cur, 12, "Karte 12 trotz Verschiebung")

   _G.SetMapByID = function() end                           -- tut nichts
   cur = 5
   check(AutoTravel.MapIds.SetMap(12) == false, "ohne Wirkung wird 'false' gemeldet")
   check(AutoTravel.MapIds.SetMap(0) == false and AutoTravel.MapIds.SetMap(nil) == false, "ungueltige ID")
end)

-- ---------------------------------------------------------------------------
-- Profile: Normal lootet, feste Profile aenderbar und rücksetzbar
-- ---------------------------------------------------------------------------

local function whispers()
   local out = {}
   for _, x in ipairs(W.sent) do if x.channel == "WHISPER" then out[#out + 1] = x.text end end
   return out
end

local function hasWhisper(text)
   for _, t in ipairs(whispers()) do if t == text then return true end end
   return false
end

local function anyWhisperMatches(pat)
   for _, t in ipairs(whispers()) do if t:find(pat, 1, true) then return true end end
   return false
end

local function flagBox(kind, flag)
   for i = 1, 300 do
      local cb = _G["AutoTravelFlagBox" .. i]
      if not cb then break end
      if cb.kind == kind and cb.flag == flag then return cb end
   end
end

local function click(widget) widget.__scripts.OnClick(widget) end

local function enter(editName, text)
   local eb = _G[editName]
   eb:SetText(text)
   eb.__scripts.OnEnterPressed(eb)
end

test("Profil Normal lootet: +loot und ll normal, keine -loot-Strategie, Wartezeit zum Looten", function()
   ready()
   local B = AutoTravel.Bot
   AutoTravel.Set("Profile", "normal")
   B.ApplyProfile()
   W.Advance(10)
   check(hasWhisper("nc +loot,-gather,-grind,-new rpg,-follow,+food"), "nc setzt +loot, aber kein gather")
   check(hasWhisper("ll normal"), "ll normal wird gesendet")
   check(not anyWhisperMatches("-loot"), "nirgends -loot")
   check(W.SentContains(".at set grace 7"), "Wartezeit 7 s, damit der Bot looten kann")
end)

test("Profile, die nicht looten sollen, tun es weiter nicht", function()
   ready()
   for _, key in ipairs({ "minimal", "aengstlich", "verteidigen" }) do
      local p = AutoTravel.Bot.Find(key)
      check(p.noncombat:find("-loot", 1, true) ~= nil, key .. " bleibt bei -loot")
   end
end)

test("jede Strategie der festen Profile ist im Editor vertreten (Umwandlung geht nichts verloren)", function()
   boot()
   local B = AutoTravel.Bot
   local function count(s) local n = 0 for _ in s:gmatch("[^,]+") do n = n + 1 end return n end
   for _, d in ipairs(B.Builtin) do
      local c = B.FormatFlags(B.ParseFlags(d.combat), B.CombatFlags)
      local n = B.FormatFlags(B.ParseFlags(d.noncombat), B.BuiltinNonCombatFlags)
      eq(count(c), count(d.combat), d.key .. ": Kampfstrategien vollstaendig")
      eq(count(n), count(d.noncombat), d.key .. ": Nichtkampfstrategien vollstaendig")
   end
   -- "gather" gibt es nur fuer feste Profile, die eigenen bleiben unveraendert
   local found = false
   for _, f in ipairs(B.NonCombatFlags) do if f[1] == "gather" then found = true end end
   check(not found, "eigene Profile bekommen keine neue Flagge (stille Aenderung vermieden)")
end)

test("feste Profile: Aenderung wirkt, Zuruecksetzen stellt den Standard wieder her", function()
   ready()
   local B = AutoTravel.Bot
   local default = B.Find("normal").noncombat
   check(not B.IsModified("normal"), "zunaechst unveraendert")

   local o = B.BuiltinOverride("normal")
   o.noncombat["loot"] = false
   o.extra = ""
   check(B.IsModified("normal"), "jetzt geaendert")
   local p = B.Find("normal")
   check(p.noncombat:find("-loot", 1, true) ~= nil, "die Aenderung ist wirksam")
   eq(#p.extra, 0, "Zusatzbefehle entfernt")
   check(p.modified == true, "als geaendert gekennzeichnet")

   AutoTravel.Set("Profile", "normal")
   B.ApplyProfile()
   W.Advance(10)
   check(anyWhisperMatches("-loot"), "der Bot bekommt die geaenderte Fassung")

   check(B.ResetBuiltin("normal"), "Zuruecksetzen")
   check(not B.HasOverride("normal"), "Ueberschreibung ist weg")
   eq(B.Find("normal").noncombat, default, "Standardwert wieder da")
   check(B.Find("normal").modified == nil, "nicht mehr geaendert")
   eq(B.ResetBuiltin("gibtsnicht"), false, "unbekanntes Profil")
   eq(B.ResetBuiltin("custom1"), false, "eigene Profile lassen sich so nicht zuruecksetzen")
end)

test("eine Ueberschreibung, die den Standard wiederholt, gilt nicht als geaendert", function()
   ready()
   local B = AutoTravel.Bot
   B.BuiltinOverride("verteidigen")                -- legt sie an, aendert nichts
   check(B.HasOverride("verteidigen"), "Ueberschreibung vorhanden")
   check(not B.IsModified("verteidigen"), "aber nicht geaendert")
   check(B.Find("verteidigen") == B.BuiltinDefault("verteidigen"), "es gilt der Standard selbst")
end)

test("Editor: eine Strategie hat drei Zustaende, nicht gesetzte bleiben unangetastet", function()
   ready()
   local B = AutoTravel.Bot
   check(AutoTravel.ProfileEditor.Select("builtin", "normal"), "Normal gewaehlt")

   local tank = flagBox("combat", "tank")           -- Normal setzt "tank" nicht
   check(tank ~= nil, "Kaestchen vorhanden")
   check(not B.HasOverride("normal"), "Anzeigen allein legt nichts an")
   check(tank.text:GetText() == "|cff8a92a3tank|r", "grau = nicht gesetzt")

   click(tank)
   eq(B.BuiltinOverride("normal").combat.tank, true, "erster Klick: an")
   check(tank.text:GetText():find("+", 1, true) ~= nil, "Anzeige +tank")
   click(tank)
   eq(B.BuiltinOverride("normal").combat.tank, false, "zweiter Klick: aus")
   check(tank.text:GetText():find("-", 1, true) ~= nil, "Anzeige -tank")
   click(tank)
   eq(B.BuiltinOverride("normal").combat.tank, nil, "dritter Klick: wieder nicht gesetzt")
   check(not B.IsModified("normal"), "zurueck beim Standard")

   -- was das Profil schon setzt, bleibt erhalten, wenn man etwas anderes aendert
   local boost = flagBox("combat", "boost")
   click(boost)
   check(B.Find("normal").combat:find("+dps", 1, true) ~= nil, "+dps ist noch da")
   check(B.Find("normal").combat:find("tank", 1, true) == nil, "tank wurde nie gesendet")
   check(B.Find("normal").combat:find("+boost", 1, true) ~= nil, "+boost neu")
end)

test("Editor: Zuruecksetzen ueber die Oberflaeche und die Anzeige der Aenderung", function()
   ready()
   local B = AutoTravel.Bot
   AutoTravel.ProfileEditor.Select("builtin", "plus")
   local gather = flagBox("noncombat", "gather")
   check(gather.__shown ~= false, "gather ist bei festen Profilen sichtbar")
   click(gather)                                    -- Plus hat +gather: an -> aus
   check(B.IsModified("plus"), "Plus geaendert")
   check(B.Find("plus").noncombat:find("-gather", 1, true) ~= nil, "-gather wirksam")

   check(AutoTravel.ProfileEditor.ResetSelected(), "zuruecksetzen")
   check(not B.IsModified("plus"), "Plus wieder Standard")
   check(B.Find("plus").noncombat:find("+gather", 1, true) ~= nil, "+gather wieder da")
   eq(AutoTravel.ProfileEditor.ResetSelected(), true, "mehrfach ist harmlos")

   AutoTravel.ProfileEditor.Select("custom", 1)
   eq(AutoTravel.ProfileEditor.ResetSelected(), false, "bei einem eigenen Profil kein Zuruecksetzen")
end)

test("Editor: eigene Profile arbeiten mit zwei Zustaenden wie bisher", function()
   ready()
   local B = AutoTravel.Bot
   AutoTravel.ProfileEditor.Select("custom", 1)
   local dps = flagBox("combat", "dps")
   dps:SetChecked(true)
   click(dps)
   eq(B.CustomSlot(1).combat.dps, true, "angehakt = an")
   dps:SetChecked(false)
   click(dps)
   eq(B.CustomSlot(1).combat.dps, nil, "abgewaehlt = nicht gesetzt")
   check(flagBox("noncombat", "gather").__shown == false, "gather bleibt bei eigenen Profilen verborgen")
   eq(B.HasOverride("normal"), false, "feste Profile nicht beruehrt")
end)

test("Editor: Wartezeit und Zusatzbefehle werden gespeichert und geprueft", function()
   ready()
   local B = AutoTravel.Bot
   AutoTravel.ProfileEditor.Select("builtin", "normal")

   enter("AutoTravelProfileGrace", "12,5")
   eq(B.Find("normal").grace, 12.5, "Komma als Dezimaltrenner")
   enter("AutoTravelProfileGrace", "99")
   eq(B.Find("normal").grace, 30, "nach oben begrenzt")
   enter("AutoTravelProfileGrace", "-4")
   eq(B.Find("normal").grace, 0.1, "nach unten begrenzt: 0 waere beim Server 'keine Vorgabe', nicht 'keine Pause'")
   enter("AutoTravelProfileGrace", "0")
   eq(B.Find("normal").grace, 0.1, "0 wird zu 0.1")
   enter("AutoTravelProfileGrace", "abc")
   eq(B.Find("normal").grace, 0.1, "Unsinn aendert nichts")
   enter("AutoTravelProfileGrace", "0,25")
   eq(B.Find("normal").grace, 0.25, "zwei Dezimalstellen bleiben")
   eq(_G.AutoTravelProfileGrace:GetText(), "0.25", "...und werden so angezeigt")
   enter("AutoTravelProfileGrace", "1,5")
   eq(_G.AutoTravelProfileGrace:GetText(), "1.5", "keine angehaengte Null")
   local warned = false
   for _, m in ipairs(W.messages) do if m:find("Wartezeit", 1, true) and m:find("Zahl", 1, true) then warned = true end end
   check(warned, "Hinweis bei ungueltiger Eingabe")

   enter("AutoTravelProfileExtra", "ll normal; ll skill ;; ")
   local p = B.Find("normal")
   eq(#p.extra, 2, "zwei Zusatzbefehle")
   eq(p.extra[2], "ll skill", "Leerraum entfernt")

   AutoTravel.ProfileEditor.ResetSelected()
   eq(B.Find("normal").grace, 7.0, "Wartezeit wieder Standard")
   eq(B.Find("normal").extra[1], "ll normal", "Zusatzbefehl wieder Standard")
end)

test("Editor: Neuanwendung beim Bearbeiten gebuendelt statt bei jedem Klick", function()
   ready()
   local B = AutoTravel.Bot
   W.ServerLine("SelfBot is now active.")
   W.Advance(5)
   AutoTravel.Set("Profile", "normal")
   AutoTravel.ProfileEditor.Select("builtin", "normal")
   W.ClearSent()
   click(flagBox("combat", "tank"))
   click(flagBox("combat", "tank"))
   click(flagBox("combat", "boost"))
   W.Advance(0.5)
   eq(#whispers(), 0, "noch nichts gesendet")
   W.Advance(5)
   local resets = 0
   for _, t in ipairs(whispers()) do if t == "co !" then resets = resets + 1 end end
   eq(resets, 1, "genau eine Neuanwendung")

   -- ein anderes als das aktive Profil loest nichts aus
   W.ClearSent()
   AutoTravel.ProfileEditor.Select("builtin", "minimal")
   click(flagBox("combat", "tank"))
   W.Advance(5)
   eq(#whispers(), 0, "anderes Profil bearbeitet: nichts gesendet")
end)

test("/at profil reset und /at profil bearbeiten", function()
   ready()
   local B = AutoTravel.Bot
   local o = B.BuiltinOverride("normal")
   o.noncombat["loot"] = false
   o = B.BuiltinOverride("plus")
   o.noncombat["gather"] = false

   SlashCmdList["AUTOTRAVEL"]("profil reset normal")
   check(not B.IsModified("normal"), "Normal zurueckgesetzt")
   check(B.IsModified("plus"), "Plus unberuehrt")

   SlashCmdList["AUTOTRAVEL"]("profil reset gibtsnicht")
   SlashCmdList["AUTOTRAVEL"]("profil reset")
   check(B.IsModified("plus"), "ungueltige Eingaben aendern nichts")

   SlashCmdList["AUTOTRAVEL"]("profil reset alle")
   check(not B.IsModified("plus"), "alle zurueckgesetzt")
   eq(next(B.Global().builtin), nil, "keine Ueberschreibungen mehr")

   local ok, err = pcall(SlashCmdList["AUTOTRAVEL"], "profil bearbeiten")
   check(ok, "bearbeiten oeffnet den Editor: " .. tostring(err))
   -- die Auswahl per Namen funktioniert weiter
   SlashCmdList["AUTOTRAVEL"]("profil Plus")
   eq(AutoTravel.Get("Profile"), "plus", "Auswahl unveraendert")
end)

test("kaputte gespeicherte Profile bringen nichts zum Absturz", function()
   W.Install()
   _G.AutoTravelGlobalDB = { builtin = "kaputt", custom = 5 }
   W.LoadToc(".", "AutoTravel.toc")
   W.Fire("ADDON_LOADED", "AutoTravel")
   W.Fire("PLAYER_LOGIN")
   local B = AutoTravel.Bot
   eq(#B.List(), #B.Builtin, "nur die festen Profile")
   _G.AutoTravelGlobalDB.builtin = { normal = "unsinn", plus = { combat = 7, noncombat = "x", extra = 3, grace = "viel" } }
   local p = B.Find("plus")
   check(p ~= nil and type(p.combat) == "string", "Plus bleibt benutzbar")
   B.ApplyProfile()
   check(true, "Anwenden ohne Fehler")
end)

-- ---------------------------------------------------------------------------
-- Diagnose
-- ---------------------------------------------------------------------------

test("/at info und alle Slash-Befehle laufen fehlerfrei", function()
   ready()
   installCarbonite(2)
   AutoTravel.MapIds.Build(true)
   for _, cmd in ipairs({ "info", "status", "target", "route", "koords", "diag", "knoten", "karten",
                          "pause", "weiter", "nachfrage", "ziel 12", "ruhe 10", "debug", "panel",
                          "knopf", "tpmodus go", "tpmodus modul", "bot", "bot status", "profil",
                          "hello", "", "unbekannt" }) do
      local ok, err = pcall(SlashCmdList["AUTOTRAVEL"], cmd)
      check(ok, "/at " .. cmd .. " -> " .. tostring(err))
   end
end)

-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Profile: Nachbesserungen nach der Durchsicht
-- ---------------------------------------------------------------------------

-- Auswahlknopf im Profil-Editor (nicht die gleichnamigen auf der Optionsseite)
local function selectorButton(label)
   for _, f in ipairs(W.frames) do
      if f.label and f.label.GetText and f.label:GetText():find(label, 1, true) == 1
         and f.__scripts.OnClick and f.__parent == _G.AutoTravelProfileContent then
         return f
      end
   end
end

test("Normal sammelt keine Ressourcen, Plus schon", function()
   ready()
   local B = AutoTravel.Bot
   check(B.Find("normal").noncombat:find("-gather", 1, true) ~= nil, "Normal: -gather")
   check(B.Find("normal").noncombat:find("+loot", 1, true) ~= nil, "Normal: +loot")
   check(B.Find("plus").noncombat:find("+gather", 1, true) ~= nil, "Plus: +gather")
   -- der Editor zeigt es nicht als "nicht gesetzt"
   AutoTravel.ProfileEditor.Select("builtin", "normal")
   check(flagBox("noncombat", "gather").text:GetText():find("-", 1, true) ~= nil, "Editor: -gather")
end)

test("Editor: wieder auf den Standard gebrachte Flaggen hinterlassen keine Ueberschreibung", function()
   ready()
   local B = AutoTravel.Bot
   AutoTravel.ProfileEditor.Select("builtin", "normal")
   local tank = flagBox("combat", "tank")
   click(tank)
   check(B.HasOverride("normal") and B.IsModified("normal"), "nach dem ersten Klick geaendert")
   click(tank)
   check(B.HasOverride("normal"), "aus ist immer noch eine Abweichung")
   click(tank)                                      -- wieder nicht gesetzt
   check(not B.HasOverride("normal"), "...und jetzt ist die Ueberschreibung verschwunden")
   check(not B.IsModified("normal"), "nicht mehr geaendert")

   -- Zusatzbefehle und Wartezeit genauso
   enter("AutoTravelProfileGrace", "3")
   check(B.HasOverride("normal"), "Wartezeit 3: geaendert")
   enter("AutoTravelProfileGrace", "7")
   check(not B.HasOverride("normal"), "Wartezeit wieder 7: keine Ueberschreibung")

   -- Titelzeile und "Auf Standard"-Knopf folgen schon dem Klick
   local reset
   for _, f in ipairs(W.frames) do if f.label and f.label:GetText() == "Auf Standard zuruecksetzen" then reset = f end end
   check(reset ~= nil, "Knopf gefunden")
   eq(reset:IsEnabled(), nil, "unveraendert: gesperrt")
   click(flagBox("combat", "boost"))
   check(reset:IsEnabled() ~= nil, "nach dem Klick: freigegeben")
   check(_G.AutoTravelProfilePanel ~= nil, "Seite vorhanden")

   -- eine spaetere Aenderung des Standards erreicht Profile ohne Ueberschreibung
   B.ResetBuiltin("normal")
   local saved = B.Builtin[4].noncombat
   B.Builtin[4].noncombat = saved .. ",+food"
   check(B.Find("normal").noncombat:find("+food,+food", 1, true) ~= nil, "neuer Standard wirkt")
   B.Builtin[4].noncombat = saved
end)

test("/at profil reset ohne Namen oder fuer ein anderes Profil sendet dem Bot nichts", function()
   ready()
   local B = AutoTravel.Bot
   AutoTravel.Set("Profile", "normal")
   B.Enable()
   W.Advance(10)
   W.ClearSent()

   SlashCmdList["AUTOTRAVEL"]("profil reset")
   W.Advance(10)
   eq(#whispers(), 0, "ohne Namen: keine Fluesternachricht")

   B.BuiltinOverride("plus").combat.tank = true      -- Plus geaendert, Normal nicht
   SlashCmdList["AUTOTRAVEL"]("profil reset plus")
   W.Advance(10)
   eq(#whispers(), 0, "ein Profil, das nicht aktiv ist: nichts zu senden")
   check(not B.IsModified("plus"), "...aber zurueckgesetzt")

   SlashCmdList["AUTOTRAVEL"]("profil reset alle")
   W.Advance(10)
   eq(#whispers(), 0, "alle, aktives Profil unveraendert: nichts zu senden")

   B.BuiltinOverride("normal").combat.tank = true
   SlashCmdList["AUTOTRAVEL"]("profil reset normal")
   W.Advance(10)
   check(hasWhisper("co !"), "das aktive, geaenderte Profil wird neu gesendet")
end)

test("Editor: eine Aenderung wird nicht doppelt gesendet, wenn inzwischen etwas angewendet wurde", function()
   ready()
   local B = AutoTravel.Bot
   AutoTravel.Set("Profile", "normal")
   B.Enable()
   W.Advance(10)
   AutoTravel.ProfileEditor.Select("builtin", "normal")
   W.ClearSent()

   click(flagBox("combat", "boost"))                 -- startet den Timer (1 s)
   B.ApplyProfile()                                  -- etwas anderes wendet das Profil an
   W.Advance(10)
   local n = 0
   for _, t in ipairs(whispers()) do if t == "co !" then n = n + 1 end end
   eq(n, 1, "'co !' nur einmal")

   W.ClearSent()
   click(flagBox("combat", "boost"))                 -- allein: der Timer sendet
   W.Advance(10)
   check(hasWhisper("co !"), "ohne andere Anwendung wird gesendet")
end)

test("Editor: das gewaehlte Profil bleibt hervorgehoben, auch wenn die Maus den Knopf verlaesst", function()
   ready()
   AutoTravel.ProfileEditor.Select("builtin", "normal")
   local b = selectorButton("Normal")
   check(b ~= nil, "Auswahlknopf gefunden")
   local last
   b.SetBackdropColor = function(_, r, g, bl) last = { r, g, bl } end
   b.__scripts.OnLeave(b)
   check(last and last[3] > 0.4, "ausgewaehlt: Hervorhebung bleibt (blau)")
   check(b.selected == true, "Merker gesetzt")

   AutoTravel.ProfileEditor.Select("builtin", "plus")
   check(b.selected == false, "nicht mehr ausgewaehlt")
   b.__scripts.OnLeave(b)
   check(last and last[3] < 0.3, "abgewaehlt: Ruhefarbe")
end)

test("Editor: lange Namen eigener Profile sprengen die Knoepfe nicht", function()
   ready()
   local B = AutoTravel.Bot
   B.CustomSlot(2).name = "Ein sehr langer Profilname"
   AutoTravel.ProfileEditor.Select("custom", 2)
   local found
   for _, f in ipairs(W.frames) do
      if f.label and f.label.GetText and f.label:GetText():find("Ein sehr", 1, true) then found = f.label:GetText() end
   end
   check(found and #found <= 14, "Beschriftung gekuerzt: " .. tostring(found))
   check(_G.AutoTravelProfileName.__maxLetters == nil or _G.AutoTravelProfileName.__maxLetters <= 16, "Namenslaenge begrenzt")
end)

test("beschaedigte eigene Profile (von Hand bearbeitete Datei) bringen weder Anmeldung noch Editor zu Fall", function()
   W.Install()
   _G.AutoTravelGlobalDB = { custom = {
      { combat = true, noncombat = "x", extra = 5, name = 7, grace = "viel" },
      "kaputt",
      { combat = { dps = true }, noncombat = false },
   } }
   W.LoadToc(".", "AutoTravel.toc")
   W.Fire("ADDON_LOADED", "AutoTravel")
   local ok, err = pcall(W.Fire, "PLAYER_LOGIN")
   check(ok, "Anmeldung: " .. tostring(err))
   local B = AutoTravel.Bot
   ok, err = pcall(B.List)
   check(ok, "List: " .. tostring(err))
   check(B.CustomUsed(1) == false, "Platz 1 leer nach der Reparatur")
   check(B.CustomUsed(2) == false, "Platz 2 leer")
   check(B.CustomUsed(3) == true, "Platz 3 behaelt, was brauchbar war")
   eq(type(B.CustomSlot(1).combat), "table", "combat ist wieder eine Tabelle")
   eq(B.CustomSlot(1).extra, "", "extra ist wieder Text")
   eq(B.CustomSlot(1).grace, 2.0, "grace ist wieder eine Zahl")
   eq(B.CustomSlot(2).name, "Eigenes 2", "Name ersetzt")
   ok, err = pcall(AutoTravel.ProfileEditor.Select, "custom", 1)
   check(ok, "Editor: " .. tostring(err))
   ok, err = pcall(function() click(flagBox("combat", "dps")) end)
   check(ok, "Klick: " .. tostring(err))
end)

test("Optionen: der Tooltip eines geleerten eigenen Profils zeigt nicht ein anderes Profil", function()
   W.Install()
   _G.AutoTravelGlobalDB = { custom = { { name = "Mein Profil", combat = { dps = true }, noncombat = {},
                                          extra = "", grace = 2.0 } } }
   W.LoadToc(".", "AutoTravel.toc")
   W.Fire("ADDON_LOADED", "AutoTravel")
   W.Fire("PLAYER_LOGIN")
   local btn
   for _, f in ipairs(W.frames) do
      if f.key == "custom1" then btn = f end
   end
   check(btn ~= nil and btn.tip ~= nil, "Knopf des eigenen Profils auf der Optionsseite")

   AutoTravel.Bot.Global().custom[1] = nil          -- geleert: Find liefert ein anderes Profil
   local lines = {}
   local old = _G.GameTooltip.AddLine
   _G.GameTooltip.AddLine = function(_, text) lines[#lines + 1] = text end
   btn.tip()
   _G.GameTooltip.AddLine = old
   check(lines[1] and lines[1]:find("Mein Profil", 1, true) ~= nil,
         "Tooltip nennt weiter den eigenen Namen: " .. tostring(lines[1]))
   check(lines[1] and not lines[1]:find("Verteidigen", 1, true), "...nicht Verteidigen")
end)


-- ---------------------------------------------------------------------------
-- Start: Selbstmodus erst nach Annahme durch den Server
-- ---------------------------------------------------------------------------

local function beginTripLine() return "TRAVELING|300|Ziel|8|20|0|1|1|10" end

test("abgelehnter Start schaltet weder Selbstmodus noch Profil ein", function()
   ready()
   installCarbonite(1)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Start()
   W.Advance(1)
   check(count(".at start") == 1, "Start gesendet")
   eq(count(".playerbots bot self"), 0, "Selbstmodus noch nicht eingeschaltet (Antwort steht aus)")
   -- der Server lehnt ab: Textmeldung und Statuszeile IDLE
   W.ServerLine("[AT]M|Das Ziel liegt auf einer anderen Karte (Map 0), und AutoTravel findet keine Verbindung dorthin.")
   status("IDLE|0|-|0|0|0|0|0|0")
   W.Advance(10)
   eq(AutoTravel.active, false, "nicht aktiv")
   eq(count(".playerbots bot self"), 0, "nach der Absage bleibt der Selbstmodus aus")
   eq(#whispers(), 0, "kein Profil an den Bot gesendet")
   check(not AutoTravel.Bot.active, "Bot nicht als laufend gemerkt")

   -- dreimal versuchen: nie ein Profilschwall
   for _ = 1, 3 do
      AutoTravel.Start()
      W.Advance(1)
      status("IDLE|0|-|0|0|0|0|0|0")
      W.Advance(1)
   end
   eq(#whispers(), 0, "auch nach mehreren Versuchen keine Fluesternachricht")
end)

test("angenommener Start schaltet Selbstmodus und Profil ein", function()
   ready()
   installCarbonite(1)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Set("Profile", "normal")
   AutoTravel.Start()
   W.Advance(1)
   eq(count(".playerbots bot self"), 0, "vor der Antwort noch nichts")
   status(beginTripLine())
   W.Advance(10)
   eq(count(".playerbots bot self"), 1, "Selbstmodus eingeschaltet")
   check(hasWhisper("co !") and hasWhisper("nc !"), "Profil gesendet")
   check(hasWhisper("ll normal"), "ll normal gesendet")
   eq(AutoTravel.supportOn, true, "Hilfen laufen")
   eq(AutoTravel.pendingStartAt, nil, "kein wartender Start mehr")

   -- weitere Statuszeilen schalten nichts doppelt ein
   status(beginTripLine())
   status(beginTripLine())
   W.Advance(10)
   eq(count(".playerbots bot self"), 1, "nur einmal")
end)

test("Stop vor der Antwort: eine spaete Statuszeile schaltet nichts ein", function()
   ready()
   installCarbonite(1)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Start()
   W.Advance(1)
   AutoTravel.Stop()
   status(beginTripLine())             -- die Antwort war schon unterwegs
   W.Advance(10)
   eq(count(".playerbots bot self"), 0, "kein Selbstmodus nach dem Stop")
   eq(#whispers(), 0, "kein Profil")
end)

test("eine Statuszeile lange nach dem Start gilt nicht mehr als dessen Annahme", function()
   ready()
   installCarbonite(1)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Start()
   W.Advance(1)
   status("IDLE|0|-|0|0|0|0|0|0")
   W.Advance(40)                       -- weit ueber die Frist
   check(not AutoTravel.StartPending(), "nichts wartet mehr")
   status(beginTripLine())
   W.Advance(10)
   eq(count(".playerbots bot self"), 0, "nicht eingeschaltet")
   eq(AutoTravel.pendingStartAt, nil, "Merker gesetzt zurueck")
end)

test("AutoDisableBot: nur eine angenommene Reise schaltet den Bot am Ende wieder aus", function()
   ready()
   installCarbonite(1)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Set("AutoDisableBot", 1)

   -- abgelehnt: kein Umschaltbefehl (der wuerde den Bot EINschalten)
   AutoTravel.Start()
   W.Advance(1)
   status("IDLE|0|-|0|0|0|0|0|0")
   W.Advance(2)
   eq(count(".playerbots bot self"), 0, "abgelehnt: kein Umschalter gesendet")

   -- angenommen und beendet: der Bot geht wieder aus
   AutoTravel.Start()
   W.Advance(1)
   status(beginTripLine())
   W.Advance(10)
   eq(count(".playerbots bot self"), 1, "eingeschaltet")
   status("ARRIVED|0|Ziel|0|0|0|1|1|100")
   status("IDLE|0|-|0|0|0|0|0|0")
   W.Advance(5)
   eq(count(".playerbots bot self"), 2, "am Ende wieder ausgeschaltet")
   eq(AutoTravel.supportOn, false, "Hilfen aus")
end)


test("Stop vor der Antwort des Servers schaltet den Bot nicht ein (Umschalter)", function()
   ready()
   installCarbonite(1)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Set("AutoDisableBot", 1)
   AutoTravel.Toggle()                 -- Start
   W.Advance(0.3)
   AutoTravel.Toggle()                 -- Stop, noch bevor der Server geantwortet hat
   W.Advance(5)
   eq(count(".playerbots bot self"), 0, "kein Umschalter gesendet")
   eq(#whispers(), 0, "kein Profil")
   -- die Antwort war schon unterwegs: sie schaltet nichts ein
   status(beginTripLine())
   W.Advance(5)
   eq(count(".playerbots bot self"), 0, "auch die verspaetete Statuszeile nicht")
end)

test("ohne Playerbot-Steuerung bleibt am Reiseende jeder Umschalter aus", function()
   ready()
   installCarbonite(1)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Set("BotControl", 0)
   AutoTravel.Set("AutoDisableBot", 1)
   AutoTravel.Start()
   W.Advance(1)
   status(beginTripLine())
   W.Advance(5)
   eq(AutoTravel.supportOn, false, "nichts eingeschaltet, also nichts auszuschalten")
   status("ARRIVED|0|Ziel|0|0|0|1|1|100")
   status("IDLE|0|-|0|0|0|0|0|0")
   W.Advance(5)
   eq(count(".playerbots bot self"), 0, "kein Umschalter")
end)

test("der Erbstueck-Schnappschuss entsteht beim Klick, vor der Antwort", function()
   ready()
   installCarbonite(1)
   AutoTravel.MapIds.Build(true)
   local snaps = 0
   local orig = AutoTravel.Gear.Snapshot
   AutoTravel.Gear.Snapshot = function(...) snaps = snaps + 1 return orig(...) end
   AutoTravel.Start()
   W.Advance(0.5)
   eq(snaps, 1, "Schnappschuss schon vor der Antwort")
   status(beginTripLine())
   W.Advance(5)
   eq(snaps, 1, "die Antwort macht keinen zweiten (er wuerde Aenderungen im Fenster vergessen)")
   AutoTravel.Gear.Snapshot = orig
end)

test("eine Statuszeile nach der Watchdog-Frist gilt noch als Annahme (Fenster 30 s)", function()
   ready()
   installCarbonite(1)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Start()
   W.Advance(9)                         -- Watchdog: keine Antwort, Anzeige zurueckgesetzt
   eq(AutoTravel.active, false, "Anzeige zurueckgesetzt")
   status(beginTripLine())              -- der Server war nur langsam
   W.Advance(5)
   eq(AutoTravel.active, true, "Reise laeuft")
   eq(count(".playerbots bot self"), 1, "und der Bot ist dabei")
end)

test("Routenstart mit mehreren Punkten: Bot erst nach der Antwort", function()
   ready()
   installCarbonite(12)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Start()
   W.Advance(6)
   check(count(".at rstart") == 1, "rstart gesendet")
   eq(count(".playerbots bot self"), 0, "noch kein Selbstmodus")
   status(beginTripLine())
   W.Advance(5)
   eq(count(".playerbots bot self"), 1, "nach der Antwort eingeschaltet")
end)

test("abgeschaltetes oder zu altes Modul verwirft auch den wartenden Start-Merker", function()
   boot()
   installCarbonite(1)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Start()
   check(AutoTravel.pendingStartAt ~= nil, "Start wartet")
   W.ServerLine("[AT]H|4.0|0|0|0|0|4|0|0")
   eq(AutoTravel.pendingStartAt, nil, "Merker verworfen")
   W.Advance(10)
   eq(count(".playerbots bot self"), 0, "kein Selbstmodus")
end)

print(string.format("\n%d Pruefungen, %d Fehler", passes, failures))
os.exit(failures == 0 and 0 or 1)
