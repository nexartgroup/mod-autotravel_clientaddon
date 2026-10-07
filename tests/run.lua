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

print(string.format("\n%d Pruefungen, %d Fehler", passes, failures))
os.exit(failures == 0 and 0 or 1)
