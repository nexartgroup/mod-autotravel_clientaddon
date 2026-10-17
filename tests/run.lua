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
   -- Der Handschlag hat einen "at status" vorgemerkt (eine laufende Reise nach einem
   -- Reload wieder aufgreifen); er geht zusammen mit den fuenf eigenen Befehlen hinaus.
   local fromHandshake = 1
   for i = 1, 5 do AutoTravel.Send("at status", { key = nil }) end
   W.Advance(0.3)
   check(#W.sent <= 1, "in 0,3 s hoechstens ein normaler Befehl, waren " .. #W.sent)
   W.Advance(4)
   eq(#W.sent, 5 + fromHandshake, "alle fuenf eigenen kommen an, dazu der eine des Handschlags")
   eq(count(".at status"), 5 + fromHandshake, "es sind alles Statusabfragen")
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
   -- Flug, Transport und Warten auf die Verbindung: der Knopf bleibt frei (seit 11.4);
   -- der Server lehnt dort ab und erklaert es.
   for _, st in ipairs({ "TAXI", "TRANSPORT", "MANUAL", "REPATHING", "TRAVELING", "MOUNTING", "TAKEOFF" }) do
      status(st .. "|900|Ziel|0|0|0|1|2|10")
      check(H.CanPause(), "Uebernehmen moeglich: " .. st)
      check(not H.CanResume(), "kein Weiter: " .. st)
   end
   status("COMBAT|900|Ziel|0|0|0|1|2|10")
   check(not H.CanPause() and not H.CanResume(), "nicht im Kampf")
   status("PLAYER|900|Ziel|16|0|0|1|2|10")
   check(not H.CanPause() and H.CanResume(), "bei der Uebergabe: nur Weiter")
   for _, st in ipairs({ "IDLE", "ARRIVED", "FAILED" }) do
      status("TRAVELING|900|Ziel|8|0|0|1|2|10")
      status(st .. "|0|-|0|0|0|0|0|0")
      check(not H.CanPause() and not H.CanResume(), "ohne Reise nichts moeglich: " .. st)
   end
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
      check(start:sub(-15) == " Sturmwind Bank", "der Name ist sauber: ohne Reste des Farbcodes (war: Sturmwind cffff0000Bankr)")
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

test("Label: Farbcodes, Links und Texturen werden entfernt, der Text bleibt (der Server vergleicht ihn mit NPC-Namen)", function()
   boot()
   local L = AutoTravel.SanitizeLabel
   eq(L("Ganaar"), "Ganaar", "einfacher Name")
   eq(L("High Chief Stillpine"), "High Chief Stillpine", "englischer Name wie in Carbonite")
   eq(L("Sturmwind |cffff0000Bank|r"), "Sturmwind Bank", "Farbcode")
   eq(L("|cff00ff00|Hquest:123:80|h[Die Suche nach dem Lehrer]|h|r"), "Die Suche nach dem Lehrer", "Questlink: der Text in den Klammern")
   eq(L("Quest |Hitem:6256:0:0:0:0:0:0:0:80|h[Angel]|h abgeben"), "Quest Angel abgeben", "Link mitten im Text")
   eq(L("|TInterface\\Icons\\Trade_Fishing:16|t Angeln"), "Angeln", "Textur")
   eq(L("  viel     Leerraum  "), "viel Leerraum", "Leerraum zusammengefasst")
   eq(L(""), "Ziel", "leer")
   eq(L("   "), "Ziel", "nur Leerraum")
   eq(L("|r|r"), "Ziel", "nur Steuerzeichen")
   eq(L(nil), "Ziel", "kein Text")
   eq(L(42), "Ziel", "keine Zeichenkette")
   check(not L("a|b|c"):find("|", 1, true), "kein '|' bleibt uebrig")
end)

test("Label: nie mitten in einem UTF-8-Zeichen abgeschnitten, hoechstens 64 Bytes", function()
   boot()
   local L = AutoTravel.SanitizeLabel
   local function validUtf8(str)
      local i, n = 1, #str
      while i <= n do
         local c = str:byte(i)
         local len = (c < 0x80 and 1) or (c >= 0xC2 and c < 0xE0 and 2) or (c >= 0xE0 and c < 0xF0 and 3)
                     or (c >= 0xF0 and c < 0xF5 and 4) or nil
         if not len or i + len - 1 > n then return false end
         for k = 1, len - 1 do
            local b = str:byte(i + k)
            if b < 0x80 or b >= 0xC0 then return false end
         end
         i = i + len
      end
      return true
   end
   local long = string.rep("a", 61) .. "\195\164\195\164\195\164"      -- ... dann drei Umlaute (je 2 Byte), Grenze liegt mitten im zweiten
   local cut = L(long)
   check(#cut <= 64, "hoechstens 64 Bytes: " .. #cut)
   check(validUtf8(cut), "gueltiges UTF-8 (kein halbes Zeichen am Ende)")
   eq(cut, string.rep("a", 61) .. "\195\164", "ein ganzer Umlaut bleibt, der angeschnittene faellt weg")
   local names = "Stallmeister M\195\188ller-L\195\182wenzahn der Gro\195\159e W\195\164chter von Sturmwind und Umgebung"
   local c2 = L(names)
   check(#c2 <= 64 and validUtf8(c2), "langer Name mit Umlauten bleibt gueltiges UTF-8")
   check(not validUtf8(string.sub(long, 1, 64)), "Gegenprobe: ein roher Schnitt an dieser Stelle waere ungueltig")
   eq(#L(string.rep("x", 64)), 64, "genau 64 Bytes bleiben")
   eq(#L(string.rep("x", 65)), 64, "65 werden auf 64 gekuerzt")
end)

test("Route: der letzte Punkt (das Ziel) geht nicht verloren, auch wenn er auf dem vorigen liegt", function()
   ready()
   installCarbonite(1)
   -- drei Punkte; die letzten beiden liegen praktisch aufeinander (Unterschied weit unter 0.004)
   local tra = {
      { TMX = 1, TMY = 2, MaI = 1, TaN1 = "Start" },
      { TMX = 10, TMY = 20, MaI = 1, TaN1 = "Zwischenpunkt" },
      { TMX = 10.001, TMY = 20.001, MaI = 1, TaN1 = "Ganaar" },
   }
   _G.Nx.Map.GeM = function()
      return {
         Tra1 = tra, Tar = {}, PlX = 1, PlY = 1,
         GZP = function(self, mi, x, y) return 10 + x * 2, 20 + y end,
      }
   end
   AutoTravel.MapIds.Build(true)
   local route = AutoTravel.BuildRoute()
   check(route ~= nil and #route == 2, "zwei Punkte statt drei (der Zwischenpunkt fiel weg)")
   if route and #route == 2 then
      eq(route[2].name, "Ganaar", "der letzte Punkt traegt das Ziel")
      check(math.abs(route[2].nx - (10 + 10.001 * 2) / 100) < 1e-9, "und seine Koordinaten, nicht die des Zwischenpunkts")
      check(math.abs(route[2].nx - (10 + 10 * 2) / 100) > 1e-6, "nicht die des Zwischenpunkts")
   end

   -- liegt der NEUE Punkt nicht am Ziel, bleibt es beim alten Verhalten: der doppelte faellt weg
   tra[#tra] = nil
   tra[#tra + 1] = { TMX = 10.001, TMY = 20.001, MaI = 1, TaN1 = "doppelt" }
   tra[#tra + 1] = { TMX = 30, TMY = 40, MaI = 1, TaN1 = "Ziel" }
   local r2 = AutoTravel.BuildRoute()
   check(r2 ~= nil and #r2 == 3, "ein Zwischenpunkt auf dem anderen wird weiterhin zusammengefasst")
   if r2 and #r2 == 3 then
      eq(r2[2].name, "Zwischenpunkt", "der erste von zwei Zwischenpunkten bleibt")
      eq(r2[3].name, "Ziel", "das Ziel am Ende")
   end
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

-- ---------------------------------------------------------------------------
-- 11.4: Statusaufnahme nach dem Handschlag, Uebernehmen / Neu berechnen,
--       Knopfsperre, Diagnosebefehle, Druidengestalt
-- ---------------------------------------------------------------------------

-- Die vom Handschlag vorgemerkten Befehle ("at status") hinausgehen lassen und
-- vergessen, damit der Test nur noch seine eigenen sieht.
local function settle()
   W.Advance(2)
   W.ClearSent()
end

local function msgCount() return #W.messages end

local function messagesSince(n)
   local out = {}
   for i = n + 1, #W.messages do out[#out + 1] = W.messages[i] end
   return out
end

local function anyMessage(list, text)
   for _, m in ipairs(list) do
      if m:find(text, 1, true) then return true end
   end
   return false
end

local function sentIs(expected, msg)
   local got = W.SentCommands()
   local ok = (#got == #expected)
   if ok then
      for i = 1, #expected do if got[i] ~= expected[i] then ok = false end end
   end
   check(ok, msg .. "  (erwartet [" .. table.concat(expected, " | ") ..
              "], war [" .. table.concat(got, " | ") .. "])")
end

-- Handschlag: Statusabfrage ---------------------------------------------

test("nach dem Handschlag geht 'at status' genau einmal und vor den vorgemerkten Befehlen hinaus", function()
   boot()
   AutoTravel.Send("at repath", { key = "repath" })     -- vor dem Handschlag: vorgemerkt
   AutoTravel.Send("at nodes", { key = "nodes" })
   W.Advance(3)
   hello()
   W.Advance(4)
   local pos = {}
   for i, c in ipairs(W.SentCommands()) do pos[c] = pos[c] or i end
   eq(count(".at status"), 1, "genau eine Statusabfrage")
   check(pos[".at hello"] and pos[".at status"] and pos[".at hello"] < pos[".at status"],
         "nach dem Handschlag selbst")
   check(pos[".at repath"] and pos[".at status"] < pos[".at repath"], "vor dem ersten vorgemerkten Befehl")
   check(pos[".at nodes"] and pos[".at repath"] < pos[".at nodes"], "deren Reihenfolge bleibt")
end)

test("Start vor dem Handschlag: keine zusaetzliche Statusabfrage, die Anzeige springt nicht auf START", function()
   boot()
   installCarbonite(1)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Start()                                   -- der Handschlag steht noch aus
   eq(AutoTravel.status.state, "STARTING", "STARTING")
   W.Advance(1)
   hello()
   W.Advance(3)
   eq(count(".at status"), 0, "keine Abfrage: die Antwort des Starts genuegt")
   eq(count(".at start"), 1, "der Start geht hinaus")
   -- Haette das Addon gefragt, antwortete der Server vor dem Start noch ohne Reise.
   if count(".at status") > 0 then status("IDLE|0|-|0|0|0|0|0|0") end
   eq(AutoTravel.active, true, "noch aktiv, kein Rueckfall auf START")
   status("TRAVELING|300|Ziel|8|20|0|1|1|10")
   eq(AutoTravel.status.state, "TRAVELING", "die Annahme")
   eq(_G.AutoTravelPanel.go.label:GetText(), "STOP", "STOP")
end)

test("ein vorgemerktes '/at status' wird mit der Abfrage des Handschlags zusammengelegt", function()
   boot()
   SlashCmdList["AUTOTRAVEL"]("status")                 -- vor dem Handschlag vorgemerkt
   hello()
   W.Advance(4)
   eq(count(".at status"), 1, "nicht doppelt")
end)

test("eine Statuszeile holt aus ABSENT zurueck, ohne dass noch ein 'at status' folgt", function()
   boot()
   W.Advance(3) W.Advance(5.5) W.Advance(5.5)
   eq(AutoTravel.Net.state, "ABSENT", "ABSENT")
   W.ClearSent()
   status("TRAVELING|300|Ziel|8|20|0|1|1|10")
   W.Advance(4)
   eq(AutoTravel.Net.state, "READY", "READY")
   eq(count(".at status"), 0, "die Statuszeile ist die Antwort: keine weitere Abfrage")
end)

test("eine laufende Reise wird nach dem Handschlag wieder aufgegriffen", function()
   boot()
   W.Advance(3)
   hello()
   W.Advance(1)
   check(W.SentContains(".at status"), "Statusabfrage geht hinaus")
   eq(AutoTravel.active, false, "bis zur Antwort kennt das Addon die Reise nicht")
   status("TRAVELING|300|Ziel|8|20|0|1|1|10")           -- die Antwort des Servers
   eq(AutoTravel.active, true, "Reise aktiv")
   check(AutoTravel.Handover.CanPause(), "Uebernehmen moeglich")
   eq(_G.AutoTravelPanel.pause:IsEnabled(), 1, "Knopf frei")
   eq(_G.AutoTravelPanel.go.label:GetText(), "STOP", "START/STOP zeigt STOP")
end)

-- Uebergabe ---------------------------------------------------------------

test("Toggle ohne bekannte Reise sendet Pause und Status und meldet nichts Irrefuehrendes", function()
   ready()
   settle()
   local H = AutoTravel.Handover
   eq(AutoTravel.active, false, "keine Reise bekannt")
   local n = msgCount()
   H.Toggle()
   W.Advance(1)
   sentIs({ ".at pause", ".at status" }, "erst die Pause, dann die Statusabfrage")
   eq(#messagesSince(n), 0, "nichts im Chat ausgegeben")
   check(not anyMessage(W.messages, "Keine Reise aktiv"), "kein 'Keine Reise aktiv'")
   check(not H.IsManual(), "keine Pause vorgemerkt: die Anzeige bleibt ehrlich")
   eq(H.StatusText(), nil, "keine Uebergabeanzeige")
end)

test("Toggle im Kampf nennt den Kampf und sendet nichts", function()
   ready()
   settle()
   status("COMBAT|300|Ziel|0|0|0|1|1|10")
   local n = msgCount()
   AutoTravel.Handover.Toggle()
   W.Advance(2)
   eq(#W.sent, 0, "nichts gesendet")
   local m = messagesSince(n)
   eq(#m, 1, "genau eine Meldung")
   check(anyMessage(m, "Im Kampf hast du ohnehin die Kontrolle"), "Hinweis auf den Kampf")
end)

test("Toggle: ohne Servermodul geht nichts hinaus, bei fehlender Faehigkeit gibt es einen Hinweis", function()
   boot()
   W.Advance(3) W.Advance(5.5) W.Advance(5.5)
   eq(AutoTravel.Net.state, "ABSENT", "ABSENT")
   W.ClearSent()
   AutoTravel.Handover.Toggle()
   W.Advance(2)
   eq(#W.sent, 0, "nichts hinaus (sonst riefe der Charakter es in /sagen)")

   ready(62, 0)                                         -- alle Faehigkeiten ausser Uebergabe
   settle()
   status("PLAYER|300|Ziel|0|0|0|1|1|10")
   local n = msgCount()
   AutoTravel.Handover.Toggle()
   W.Advance(2)
   eq(#W.sent, 0, "ohne Faehigkeit nichts gesendet")
   check(anyMessage(messagesSince(n), "Gerade nicht moeglich (PLAYER)"), "Hinweis mit Zustand")
end)

test("CanPause/CanResume: Matrix ueber Reisezustand, Modulzustand und Faehigkeit", function()
   ready()
   local AT, H = AutoTravel, AutoTravel.Handover
   local pausable = { "TAXI", "TRANSPORT", "MANUAL", "REPATHING", "TRAVELING", "MOUNTING", "TAKEOFF" }
   local notPausable = { "COMBAT", "PLAYER", "IDLE", "ARRIVED", "FAILED", "STARTING" }

   AT.active = true
   for _, st in ipairs(pausable) do
      AT.status.state = st
      check(H.CanPause(), "CanPause " .. st)
      check(not H.CanResume(), "kein CanResume " .. st)
   end
   for _, st in ipairs(notPausable) do
      AT.status.state = st
      check(not H.CanPause(), "kein CanPause " .. st)
      check(H.CanResume() == (st == "PLAYER"), "CanResume nur bei PLAYER: " .. st)
   end

   -- ohne bekannte Reise geht keines von beiden (Toggle fragt dann den Server)
   AT.active = false
   for _, st in ipairs({ "TRAVELING", "PLAYER", "IDLE" }) do
      AT.status.state = st
      check(not H.CanPause() and not H.CanResume(), "keine Reise: " .. st)
   end

   -- Modulzustand
   AT.active = true
   for ns, ok in pairs({ READY = true, HELLO = true, UNKNOWN = true,
                         ABSENT = false, INCOMPATIBLE = false, DISABLED = false }) do
      AT.Net.state = ns
      AT.status.state = "TRAVELING"
      check(H.CanPause() == ok, "CanPause bei Modul " .. ns)
      AT.status.state = "PLAYER"
      check(H.CanResume() == ok, "CanResume bei Modul " .. ns)
   end

   -- ohne die Faehigkeit "Uebergabe" (Bit 1) gilt beides nicht
   ready(62, 0)                                         -- ladet das Addon neu
   AT, H = AutoTravel, AutoTravel.Handover
   AT.active = true
   AT.status.state = "TRAVELING"
   check(not H.CanPause(), "ohne Faehigkeit: kein CanPause")
   AT.status.state = "PLAYER"
   check(not H.CanResume(), "ohne Faehigkeit: kein CanResume")
end)

test("Uebernehmen im Flug: der Befehl geht hinaus, aber es wird keine Pause vorgemerkt", function()
   ready()
   settle()
   local H = AutoTravel.Handover
   status("TAXI|900|Ziel|0|0|0|1|2|10")
   check(H.Pause(), "Pause angenommen")
   W.Advance(1)
   sentIs({ ".at pause" }, "der Server bekommt die Pause und erklaert die Ablehnung")
   check(not H.IsManual(), "die Anzeige behauptet keine Pause (der Server lehnt in diesem Abschnitt ab)")
   eq(H.StatusText(), nil, "keine Uebergabeanzeige")
   W.Advance(6)
   status("TRAVELING|900|Ziel|8|0|0|1|2|10")
   check(H.Pause(), "waehrend der Fahrt")
   check(H.IsManual(), "dort wird die Pause vorgemerkt")
end)

test("Uebernehmen zwischen Klick auf START und erster Statuszeile ist gesperrt", function()
   ready()
   settle()
   installCarbonite(1)
   AutoTravel.MapIds.Build(true)
   AutoTravel.Start()
   eq(AutoTravel.status.state, "STARTING", "STARTING")
   local H, P = AutoTravel.Handover, _G.AutoTravelPanel
   check(not H.CanPause(), "keine Pause: sie wuerde den wartenden Start ueberholen")
   eq(P.pause:IsEnabled(), nil, "Knopf gesperrt")
   W.ClearSent()
   click(P.pause)
   eq(#W.sent, 0, "nichts gesendet")
   W.Advance(1)
   status("TRAVELING|300|Ziel|8|20|0|1|1|10")
   check(H.CanPause(), "nach der Annahme moeglich")
   eq(P.pause:IsEnabled(), 1, "Knopf frei")
end)

-- Knopfsperre ---------------------------------------------------------------

test("UI.Button: ein gesperrter Knopf ignoriert Klicks und benutzt weder Enable() noch Disable()", function()
   boot()
   local UI = AutoTravel.UI
   local calls, enables, disables = 0, 0, 0
   local b = UI.Button(_G.UIParent, 80, 20, "Test", function() calls = calls + 1 end)
   b.Enable = function() enables = enables + 1 end
   b.Disable = function() disables = disables + 1 end

   eq(b:IsEnabled(), 1, "frei")
   click(b)
   eq(calls, 1, "freier Knopf ruft den Handler")

   UI.SetEnabled(b, false, "Grund")
   eq(b:IsEnabled(), nil, "IsEnabled liefert nil, solange er gesperrt ist")
   eq(b:GetAlpha(), 0.45, "abgeblendet")
   click(b)
   click(b)
   eq(calls, 1, "Handler wird nicht gerufen")
   eq(b.nClick, 3, "Klicks werden fuer '/at ui' trotzdem gezaehlt")

   UI.SetEnabled(b, true)
   eq(b:IsEnabled(), 1, "wieder frei")
   eq(b:GetAlpha(), 1, "wieder voll sichtbar")
   click(b)
   eq(calls, 2, "ruft den Handler wieder")

   eq(enables, 0, "Enable() nie gerufen")
   eq(disables, 0, "Disable() nie gerufen")
   eq(b.__enabled, true, "der Zustand der Engine blieb unberuehrt")
end)

test("UI.Button: wiederholte Wechsel zwischen frei und gesperrt verlieren keinen Klick", function()
   boot()
   local UI = AutoTravel.UI
   local calls = 0
   local b = UI.Button(_G.UIParent, 80, 20, "Test", function() calls = calls + 1 end)

   local expected = 0
   for i = 1, 300 do
      local on = (i % 3) ~= 0
      UI.SetEnabled(b, on, "Grund")
      click(b)
      if on then expected = expected + 1 end
   end
   eq(calls, expected, "genau die Klicks auf den freien Knopf kamen an")

   for _ = 1, 50 do
      UI.SetEnabled(b, false, "Grund")
      UI.SetEnabled(b, true)
   end
   local before = calls
   click(b)
   eq(calls, before + 1, "nach vielen Wechseln noch ein Klick")
   eq(b:IsEnabled(), 1, "und frei")
end)

test("Panel: Neu berechnen ueberlebt wechselnde Modulzustaende, kein Klick geht verloren", function()
   ready()
   settle()
   local P = _G.AutoTravelPanel
   AutoTravel.active = false
   local sent, clicks = 0, 0
   for i = 1, 20 do
      AutoTravel.Net.state = (i % 2 == 0) and "ABSENT" or "READY"
      AutoTravel.UI.Update()
      W.ClearSent()
      click(P.re)
      W.Advance(0.6)
      clicks = clicks + 1
      if i % 2 == 1 then sent = sent + count(".at repath") end
   end
   eq(sent, 10, "jeder Klick bei erreichbarem Modul sendete einen Befehl")
   eq(P.re.nClick, clicks, "alle Klicks kamen am Knopf an")
end)

test("UI.SetEnabled: Hervorhebung, wenn die Maus beim Freigeben schon auf dem Knopf liegt", function()
   boot()
   local UI = AutoTravel.UI
   local b = UI.Button(_G.UIParent, 80, 20, "Test", function() end)
   local colors = {}
   b.SetBackdropColor = function(_, r, g, bl) colors[#colors + 1] = { r, g, bl } end

   UI.SetEnabled(b, false, "Grund")
   check(#colors == 1 and colors[1][1] == 0.13, "beim Sperren: Ruhefarben")

   colors = {}
   b.__over = false
   UI.SetEnabled(b, true)
   eq(#colors, 0, "Maus nicht darueber: keine Hervorhebung")

   UI.SetEnabled(b, false, "Grund")
   colors = {}
   b.__over = true
   UI.SetEnabled(b, true)
   eq(#colors, 1, "Maus schon darueber: sofort hervorgehoben")
   check(colors[1] and colors[1][1] == 0.19 and colors[1][3] == 0.27, "Hervorhebungsfarbe")

   colors = {}
   UI.SetEnabled(b, true)
   UI.SetEnabled(b, true)
   eq(#colors, 0, "wiederholtes Freigeben (UI.Update) faerbt nicht erneut")

   -- ueber die Ersatzabfrage Frame:IsMouseOver, wenn es MouseIsOver nicht gibt
   local saved = _G.MouseIsOver
   _G.MouseIsOver = nil
   UI.SetEnabled(b, false, "Grund")
   colors = {}
   UI.SetEnabled(b, true)
   eq(#colors, 1, "ohne MouseIsOver greift Frame:IsMouseOver")
   _G.MouseIsOver = saved
end)

test("UI.Button: OnEnter eines gesperrten Knopfes zeigt den Grund und hebt nichts hervor", function()
   boot()
   local UI = AutoTravel.UI
   local b = UI.Button(_G.UIParent, 80, 20, "Test", function() end)
   local tipCalls, colors, lines = 0, {}, {}
   b.tip = function() tipCalls = tipCalls + 1 end
   b.SetBackdropColor = function(_, r) colors[#colors + 1] = r end
   _G.GameTooltip.AddLine = function(_, text) lines[#lines + 1] = text end

   UI.SetEnabled(b, false, "Das ist der Grund")
   colors = {}
   b.__scripts.OnEnter(b)
   eq(lines[1], "Das ist der Grund", "Tooltip nennt den Grund")
   eq(tipCalls, 0, "der normale Tooltip bleibt aus")
   eq(#colors, 0, "keine Hervorhebung")
   eq(b.nEnter, 1, "Betreten gezaehlt")

   UI.SetEnabled(b, true)
   lines = {}
   b.__scripts.OnEnter(b)
   eq(tipCalls, 1, "freier Knopf zeigt seinen Tooltip")
   check(#colors >= 1, "und wird hervorgehoben")
   eq(b.nEnter, 2, "Betreten gezaehlt")
   _G.GameTooltip.AddLine = nil
end)

-- Panel: Zustandsmatrix ---------------------------------------------------

test("Panel: Uebernehmen und Neu berechnen ueber Reise x Modulzustand x Reisezustand", function()
   ready()
   local AT = AutoTravel
   local P = _G.AutoTravelPanel
   local function linked(ns) return ns ~= "ABSENT" and ns ~= "INCOMPATIBLE" and ns ~= "DISABLED" end
   local notPausable = { COMBAT = true, PLAYER = true, IDLE = true, ARRIVED = true,
                         FAILED = true, STARTING = true }
   local nets = { "READY", "UNKNOWN", "HELLO", "ABSENT", "INCOMPATIBLE", "DISABLED" }
   local states = { "IDLE", "STARTING", "REPATHING", "TRAVELING", "COMBAT", "PLAYER", "MOUNTING",
                    "TAKEOFF", "TAXI", "TRANSPORT", "MANUAL", "ARRIVED", "FAILED" }
   local cases = 0

   for _, active in ipairs({ true, false }) do
      for _, ns in ipairs(nets) do
         for _, st in ipairs(states) do
            AT.active = active
            AT.status.state = st
            AT.Net.state = ns
            AT.UI.Update()
            cases = cases + 1
            local tag = string.format("aktiv=%s Modul=%s Zustand=%s", tostring(active), ns, st)
            local noModule = "Kein Servermodul erreichbar (" .. ns .. "). '/at hello' fragt es erneut ab."

            -- Neu berechnen: frei, solange eine Reise laeuft oder das Modul erreichbar ist
            local wantRe = active or linked(ns)
            eq(P.re:IsEnabled() ~= nil, wantRe, tag .. ": Neu berechnen frei")
            if not wantRe then eq(P.re.disabledTip, noModule, tag .. ": Grund bei Neu berechnen") end

            -- Uebernehmen / Weiter
            local canResume = active and st == "PLAYER" and linked(ns)
            local canPause = active and not notPausable[st] and linked(ns)
            if canResume then
               eq(P.pause.label:GetText(), "|cff53d17aWeiter|r", tag .. ": Beschriftung Weiter")
               eq(P.pause:IsEnabled() ~= nil, true, tag .. ": Weiter frei")
            else
               eq(P.pause.label:GetText(), "Übernehmen", tag .. ": Beschriftung Uebernehmen")
               local want = canPause
               if not active then want = linked(ns) end
               eq(P.pause:IsEnabled() ~= nil, want, tag .. ": Uebernehmen frei")
               if not want then
                  local tip = P.pause.disabledTip
                  check(type(tip) == "string" and tip ~= "", tag .. ": Grund vorhanden")
                  if not active then
                     eq(tip, noModule, tag .. ": Grund ohne Reise")
                  elseif st == "COMBAT" then
                     eq(tip, "Im Kampf hast du die Kontrolle ohnehin. Danach geht es von selbst weiter.",
                        tag .. ": Grund im Kampf")
                  elseif linked(ns) then
                     eq(tip, "In diesem Zustand (" .. st .. ") ist keine Übernahme nötig.",
                        tag .. ": Grund im Zustand")
                  end
               end
            end
         end
      end
   end
   eq(cases, 2 * 6 * 13, "alle Kombinationen geprueft")
end)

-- Klicks auf das Panel --------------------------------------------------------

test("Neu berechnen ohne bekannte Reise sendet 'at repath'; ohne Modul geht nichts hinaus", function()
   ready()
   settle()
   local P = _G.AutoTravelPanel
   AutoTravel.active = false
   AutoTravel.status.state = "IDLE"
   AutoTravel.UI.Update()
   check(P.re:IsEnabled() ~= nil, "Knopf frei")
   click(P.re)
   W.Advance(1)
   sentIs({ ".at repath" }, "ein 'at repath'")

   W.ClearSent()
   status("TRAVELING|300|Ziel|8|20|0|1|1|10")
   click(P.re)
   W.Advance(1)
   sentIs({ ".at repath" }, "auch mit bekannter Reise")

   AutoTravel.active = false
   AutoTravel.Net.state = "ABSENT"
   AutoTravel.UI.Update()
   eq(P.re:IsEnabled(), nil, "ohne Modul gesperrt")
   W.ClearSent()
   local n = msgCount()
   click(P.re)
   W.Advance(2)
   eq(#W.sent, 0, "nichts gesendet")
   eq(#messagesSince(n), 0, "keine Meldung")
end)

test("Uebernehmen sendet je nach Lage Pause, Weiter oder Pause mit Statusabfrage", function()
   ready()
   settle()
   local P = _G.AutoTravelPanel

   -- Reise laeuft: Pause
   status("TRAVELING|300|Ziel|8|20|0|1|1|10")
   click(P.pause)
   W.Advance(1)
   sentIs({ ".at pause" }, "waehrend der Fahrt: Pause")

   -- uebernommen: der Knopf heisst Weiter und sendet resume
   status("PLAYER|300|Ziel|16|0|0|1|1|10")
   eq(P.pause.label:GetText(), "|cff53d17aWeiter|r", "Beschriftung Weiter")
   W.ClearSent()
   click(P.pause)
   W.Advance(1)
   sentIs({ ".at resume" }, "bei der Uebergabe: Weiter")

   -- Kampf: gesperrt, nichts gesendet, nichts gemeldet
   status("COMBAT|300|Ziel|0|0|0|1|1|10")
   eq(P.pause:IsEnabled(), nil, "im Kampf gesperrt")
   W.ClearSent()
   local n = msgCount()
   click(P.pause)
   W.Advance(2)
   eq(#W.sent, 0, "im Kampf nichts gesendet")
   eq(#messagesSince(n), 0, "im Kampf keine Meldung")

   -- Flug: der Server bekommt die Pause und erklaert
   status("TAXI|900|Ziel|0|0|0|1|2|10")
   eq(P.pause:IsEnabled(), 1, "im Flug frei")
   W.ClearSent()
   click(P.pause)
   W.Advance(1)
   sentIs({ ".at pause" }, "im Flug: Pause")

   -- keine Reise bekannt, Modul da: Pause und Statusabfrage
   status("IDLE|0|-|0|0|0|0|0|0")
   eq(P.pause:IsEnabled(), 1, "ohne bekannte Reise frei, solange das Modul da ist")
   W.ClearSent()
   click(P.pause)
   W.Advance(1)
   sentIs({ ".at pause", ".at status" }, "ohne bekannte Reise: Pause und Statusabfrage")

   -- Modul fehlt: gesperrt
   AutoTravel.Net.state = "ABSENT"
   AutoTravel.UI.Update()
   eq(P.pause:IsEnabled(), nil, "ohne Modul gesperrt")
   W.ClearSent()
   click(P.pause)
   W.Advance(2)
   eq(#W.sent, 0, "ohne Modul nichts gesendet")
end)

test("Minimap-Knopf: Mittelklick uebernimmt auch ohne bekannte Reise (AT.UI-unabhaengig)", function()
   ready()
   settle()
   local mini = _G.AutoTravelMinimapButton
   check(mini ~= nil, "Minimap-Knopf vorhanden")
   mini.__scripts.OnClick(mini, "MiddleButton")
   W.Advance(1)
   sentIs({ ".at pause", ".at status" }, "Mittelklick: Pause und Statusabfrage")
end)

test("ohne Oberflaeche (AT.UI fehlt) laufen Uebergabe und Netz fehlerfrei", function()
   ready()
   settle()
   local AT = AutoTravel
   local saved = AT.UI
   AT.UI = nil
   local ok, err = pcall(function()
      AT.Handover.Toggle()                               -- ohne Reise
      status("TRAVELING|300|Ziel|8|20|0|1|1|10")
      AT.Handover.Toggle()                               -- Pause
      status("PLAYER|300|Ziel|16|0|0|1|1|10")
      AT.Handover.Toggle()                               -- Weiter
      W.Advance(30)
      status("IDLE|0|-|0|0|0|0|0|0")
      W.ServerLine("[AT]H|1.0|1|0|0|0|2|0|0")            -- Modul zu alt: bricht die Reise lokal ab
   end)
   AT.UI = saved
   check(ok, "kein Fehler: " .. tostring(err))
end)

local ICON_BEAR, ICON_CAT = "Ability_Racial_BearForm", "Ability_Druid_CatForm"

-- Einen Druiden einrichten; 'active' ist der Name der aktiven Gestalt oder nil.
local function druid(active, level, talents)
   W.world.class = "DRUID"
   W.world.level = level or 80
   W.world.talents = talents or { 0, 0, 0 }
   W.world.spells = {
      [5487]  = { "Baergestalt", ICON_BEAR },
      [9634]  = { "Terrorbaergestalt", ICON_BEAR },
      [768]   = { "Katzengestalt", ICON_CAT },
      [24858] = { "Mondkingestalt", "Spell_Nature_ForceOfNature" },
      [33891] = { "Baum des Lebens", "Ability_Druid_TreeofLife" },
   }
   local function form(name, icon) return { name = name, icon = icon, active = (name == active) } end
   W.world.forms = {
      form("Wassergestalt", "Ability_Druid_AquaticForm"),
      form("Baergestalt", ICON_BEAR),
      form("Katzengestalt", ICON_CAT),
      form("Reisegestalt", "Ability_Druid_TravelForm"),
      form("Mondkingestalt", "Spell_Nature_ForceOfNature"),
      form("Baum des Lebens", "Ability_Druid_TreeofLife"),
   }
end

-- Diagnosebefehle ------------------------------------------------------------

test("/at ui: laeuft mit und ohne Panel fehlerfrei und nennt den Zustand der Knoepfe", function()
   ready()
   settle()
   local P = _G.AutoTravelPanel

   local n = msgCount()
   local ok, err = pcall(SlashCmdList["AUTOTRAVEL"], "ui")
   check(ok, "mit Panel: " .. tostring(err))
   local m = messagesSince(n)
   check(#m >= 3, "drei Zeilen (waren " .. #m .. ")")
   check(anyMessage(m, "Uebernehmen frei, Neu berechnen frei, START frei"), "Zustand der Knoepfe")
   check(anyMessage(m, "Modul=READY"), "Modulzustand")
   check(anyMessage(m, "OnEnter 0 x, OnClick 0 x"), "Zaehler")
   check(anyMessage(m, "Unter der Maus: nichts"), "kein Fokus")

   -- gesperrter Knopf, Maus darauf, Klicks werden gezaehlt
   AutoTravel.Net.state = "ABSENT"
   AutoTravel.UI.Update()
   click(P.pause)
   P.pause.__scripts.OnEnter(P.pause)
   W.world.focus = P.pause
   n = msgCount()
   ok, err = pcall(SlashCmdList["AUTOTRAVEL"], "ui")
   check(ok, "gesperrt: " .. tostring(err))
   m = messagesSince(n)
   check(anyMessage(m, "Uebernehmen GESPERRT, Neu berechnen GESPERRT"), "gesperrt gemeldet")
   check(anyMessage(m, "OnEnter 1 x, OnClick 1 x"), "Zaehler zaehlen auch gesperrte Klicks")
   check(anyMessage(m, "Alpha 0.45"), "Abblendung")
   check(anyMessage(m, "Unter der Maus: Übernehmen"), "Fokus erkannt")

   -- ein fremder Frame unter der Maus
   W.world.focus = _G.UIParent
   n = msgCount()
   ok, err = pcall(SlashCmdList["AUTOTRAVEL"], "ui")
   check(ok, "fremder Frame: " .. tostring(err))
   check(anyMessage(messagesSince(n), "Unter der Maus: UIParent"), "Name des fremden Frames")

   -- ohne Panel (z. B. vor dem Anmelden)
   _G.AutoTravelPanel = nil
   n = msgCount()
   ok, err = pcall(SlashCmdList["AUTOTRAVEL"], "ui")
   check(ok, "ohne Panel: " .. tostring(err))
   m = messagesSince(n)
   check(anyMessage(m, "Uebernehmen fehlt, Neu berechnen fehlt, START fehlt"), "fehlt gemeldet")
   _G.AutoTravelPanel = P
end)

test("/at strat: meldet Gestalt und Formen und fragt die Strategien des Bots ab", function()
   ready()
   settle()
   local B = AutoTravel.Bot

   -- kein Druide
   local n = msgCount()
   local ok, err = pcall(SlashCmdList["AUTOTRAVEL"], "strat")
   check(ok, "als Krieger: " .. tostring(err))
   check(anyMessage(messagesSince(n), "Gestalt: keine  |  gesendet: -"), "keine Gestalt")
   W.Advance(3)
   check(hasWhisper("co ?") and hasWhisper("nc ?"), "beide Abfragen gefluestert")

   -- Druide in Katzengestalt
   W.ClearSent()
   druid("Katzengestalt")
   n = msgCount()
   ok, err = pcall(SlashCmdList["AUTOTRAVEL"], "strat")
   check(ok, "als Druide: " .. tostring(err))
   local m = messagesSince(n)
   check(anyMessage(m, "Gestalt: cat  |  gesendet: -"), "Katze erkannt")
   check(anyMessage(m, "Form 3: Katzengestalt"), "Formliste")
   check(anyMessage(m, "AKTIV"), "aktive Form markiert")
   W.Advance(3)
   check(hasWhisper("co ?") and hasWhisper("nc ?"), "beide Abfragen gefluestert")
   check(B.formStrategy == nil, "die Diagnose aendert nichts am Bot")
end)

-- Playerbot: Strategien und Druidengestalt -----------------------------------

test("Bot.DruidForm: erkennt die Gestalt ueber die Zauber, Reise- und Wassergestalt zaehlen nicht", function()
   ready()
   local B = AutoTravel.Bot
   eq(B.DruidForm(), nil, "Krieger")

   druid(nil)
   eq(B.DruidForm(), nil, "Druide ohne Gestalt")
   for _, c in ipairs({ { "Katzengestalt", "cat" }, { "Baergestalt", "bear" },
                        { "Mondkingestalt", "balance" }, { "Baum des Lebens", "resto" },
                        { "Reisegestalt", nil }, { "Wassergestalt", nil } }) do
      druid(c[1])
      eq(B.DruidForm(), c[2], "Gestalt " .. c[1])
   end

   W.world.forms = { { name = "Terrorbaergestalt", icon = ICON_BEAR, active = true } }
   eq(B.DruidForm(), "bear", "Terrorbaer")
   -- Name weicht ab (andere Sprache), das Symbol passt
   W.world.forms = { { name = "Cat Form", icon = ICON_CAT, active = true } }
   eq(B.DruidForm(), "cat", "Katze ueber das Symbol")
   W.world.forms = { { name = "Bear Form", icon = ICON_BEAR, active = true } }
   eq(B.DruidForm(), "bear", "Baer ueber das Symbol")

   -- kein Druide: die Gestalt zaehlt nicht
   W.world.class = "PRIEST"
   eq(B.DruidForm(), nil, "Priester")

   -- ohne die API laeuft es nicht in den Fehler
   W.world.class = "DRUID"
   local saved = _G.GetShapeshiftFormInfo
   _G.GetShapeshiftFormInfo = nil
   eq(B.DruidForm(), nil, "ohne GetShapeshiftFormInfo")
   _G.GetShapeshiftFormInfo = saved
end)

test("Bot.IsFeralSpec: Wilder Kampf erst ab Stufe 10 und bei den meisten Punkten (Gleichstand: erster Baum)", function()
   ready()
   local B = AutoTravel.Bot
   local function feral(level, t) W.world.level = level W.world.talents = t return B.IsFeralSpec() end
   eq(feral(80, { 0, 51, 20 }), true, "Wilder Kampf vorn")
   eq(feral(9, { 0, 5, 0 }), false, "unter Stufe 10 immer Gleichgewicht")
   eq(feral(10, { 0, 1, 0 }), true, "ab Stufe 10")
   eq(feral(80, { 0, 0, 0 }), false, "ohne Punkte")
   eq(feral(80, { 51, 10, 10 }), false, "Gleichgewicht vorn")
   eq(feral(80, { 10, 10, 0 }), false, "Gleichstand: der erste Baum gewinnt")
   eq(feral(80, { 0, 10, 10 }), true, "Gleichstand zwischen Wilder Kampf und Wiederherstellung: der erste (Wilder Kampf)")
   eq(feral(80, { 0, 0, 31 }), false, "Wiederherstellung vorn")

   local saved = _G.GetTalentTabInfo
   _G.GetTalentTabInfo = nil
   eq(B.IsFeralSpec(), false, "ohne API")
   _G.GetTalentTabInfo = saved
   local savedLevel = _G.UnitLevel
   _G.UnitLevel = nil
   eq(B.IsFeralSpec(), false, "ohne UnitLevel")
   _G.UnitLevel = savedLevel
end)

test("Bot.FormCommand: Baer und Katze ohne Wilden Kampf schalten aoe, cc, boost und cure ab", function()
   ready()
   local B = AutoTravel.Bot
   W.world.level = 80
   eq(B.FormCommand(nil), nil, "keine Gestalt")

   W.world.talents = { 51, 10, 0 }                       -- Gleichgewicht
   eq(B.FormCommand("bear"), "co +bear,-aoe,-cc,-boost,-cure", "Baer ohne Wilden Kampf")
   eq(B.FormCommand("cat"), "co +cat,-aoe,-cc,-boost,-cure", "Katze ohne Wilden Kampf")
   eq(B.FormCommand("balance"), "co +balance", "Eule")
   eq(B.FormCommand("resto"), "co +resto", "Baum")

   W.world.talents = { 0, 51, 10 }                       -- Wilder Kampf
   eq(B.FormCommand("bear"), "co +bear", "Baer mit Wildem Kampf")
   eq(B.FormCommand("cat"), "co +cat", "Katze mit Wildem Kampf")
end)

test("feste Profile setzen weder +heal noch +dps allein (Klassenstrategien, Druidensicherheit)", function()
   boot()
   local B = AutoTravel.Bot
   for _, d in ipairs(B.Builtin) do
      check(not d.combat:find("+heal", 1, true), d.key .. ": kein '+heal' in " .. d.combat)
      check(not d.combat:find("+dps,", 1, true), d.key .. ": kein '+dps,' in " .. d.combat)
      check(not d.combat:find("%+dps$"), d.key .. ": kein '+dps' am Ende")
      for tok in d.combat:gmatch("[^,]+") do
         check(tok ~= "+dps" and tok ~= "+heal", d.key .. ": Strategie '" .. tok .. "'")
      end
   end
   -- wer kaempfen soll, setzt "dps assist" (Angreifer als Ziel), das klassenneutral ist
   for _, key in ipairs({ "verteidigen", "normal", "aggressiv", "plus" }) do
      check(B.Find(key).combat:find("+dps assist", 1, true) ~= nil, key .. ": +dps assist")
   end
   -- Minimal und Aengstlich bleiben bei den Verboten
   check(B.Find("minimal").combat:find("-dps", 1, true) ~= nil, "Minimal: -dps")
   check(B.Find("aengstlich").combat:find("-dps", 1, true) ~= nil, "Aengstlich: -dps")
end)

test("Bot.ApplyProfile(true) sendet nur die Kampfstrategien und die Gestalt, keine Zaehlung, kein nc", function()
   ready()
   settle()
   local B = AutoTravel.Bot
   AutoTravel.Set("Profile", "normal")
   druid("Katzengestalt", 80, { 51, 10, 0 })

   local count0, msgs0 = B.applyCount, msgCount()
   B.ApplyProfile(true)
   W.Advance(6)
   local w = whispers()
   eq(#w, 3, "drei Fluesternachrichten")
   eq(w[1], "co !", "zuerst 'co !'")
   eq(w[2], "co +dps assist,+aoe,+avoid aoe,-grind", "die Kampfstrategien des Profils")
   eq(w[3], "co +cat,-aoe,-cc,-boost,-cure", "als letztes die Gestalt")
   for _, t in ipairs(w) do check(t:sub(1, 3) ~= "nc ", "kein nc-Befehl: " .. t) end
   check(not hasWhisper("ll normal"), "keine Zusatzbefehle")
   check(not W.SentContains(".at set grace"), "keine Wartezeit")
   eq(B.applyCount, count0, "applyCount nicht erhoeht")
   eq(msgCount(), msgs0, "keine Profilmeldung")
   eq(B.formStrategy, "cat", "Gestalt gemerkt")

   -- die volle Anwendung zaehlt, sendet nc und die Gestalt zuletzt
   W.ClearSent()
   B.ApplyProfile()
   W.Advance(10)
   w = whispers()
   eq(B.applyCount, count0 + 1, "applyCount erhoeht")
   check(hasWhisper("nc !"), "nc ! gesendet")
   check(hasWhisper("nc +loot,-gather,-grind,-new rpg,-follow,+food"), "nc-Strategien gesendet")
   check(hasWhisper("ll normal"), "Zusatzbefehl gesendet")
   check(W.SentContains(".at set grace 7"), "Wartezeit gesendet")
   eq(w[#w], "co +cat,-aoe,-cc,-boost,-cure", "die Gestalt steht auch hier zuletzt")

   -- Profilnachricht erscheint nur bei der vollen Anwendung
   check(anyMessage(messagesSince(msgs0), "Profil:"), "Meldung bei voller Anwendung")
end)

test("Bot.ApplyProfile(true) bei eigenem Profil: Kampfflaggen ja, nc und Zusatzbefehle nein", function()
   ready()
   settle()
   local B = AutoTravel.Bot
   local c = B.CustomSlot(1)
   c.name = "Test"
   c.combat.dps = true
   c.noncombat.loot = true
   c.extra = "ll normal"
   AutoTravel.Set("Profile", "custom1")
   druid("Katzengestalt", 80, { 0, 51, 0 })

   B.ApplyProfile(true)
   W.Advance(8)
   local w = whispers()
   check(#w >= 3, "mindestens co !, Flaggenliste und Gestalt")
   eq(w[1], "co !", "zuerst 'co !'")
   eq(w[#w], "co +cat", "zuletzt die Gestalt (Wilder Kampf: ohne Abschaltungen)")
   for i = 2, #w - 1 do check(w[i]:sub(1, 3) == "co ", "nur Kampfstrategien: " .. w[i]) end
   check(not hasWhisper("ll normal"), "kein Zusatzbefehl")
   check(not anyWhisperMatches("nc "), "kein nc")
end)

test("Bot.ApplyProfile ohne Druide sendet keinen Gestaltbefehl; ohne Playerbot-Steuerung nichts", function()
   ready()
   settle()
   local B = AutoTravel.Bot
   AutoTravel.Set("Profile", "verteidigen")
   B.ApplyProfile(true)
   W.Advance(5)
   local w = whispers()
   eq(#w, 2, "co ! und die Kampfstrategien")
   eq(B.formStrategy, nil, "keine Gestalt")

   AutoTravel.Set("BotControl", 0)
   W.ClearSent()
   B.ApplyProfile(true)
   B.ApplyProfile()
   W.Advance(5)
   eq(#whispers(), 0, "ohne Steuerung nichts")
end)

test("Gestaltwechsel: UPDATE_SHAPESHIFT_FORM sendet nach der Entprellung genau einmal und nur bei Aenderung", function()
   ready()
   local B = AutoTravel.Bot
   AutoTravel.Set("Profile", "normal")
   druid("Katzengestalt", 80, { 51, 10, 0 })
   B.Enable()
   W.ServerLine("SelfBot is now active.")
   W.Advance(10)
   check(B.IsRunning(), "Bot laeuft")
   eq(B.formStrategy, "cat", "Katze gesendet")
   W.ClearSent()
   local applied = B.applyCount

   -- Ereignisse ohne Gestaltwechsel: nichts geht hinaus
   for _ = 1, 3 do W.Fire("UPDATE_SHAPESHIFT_FORM") W.Advance(0.1) end
   W.Advance(5)
   eq(#whispers(), 0, "gleiche Gestalt: nichts gesendet")

   -- Wechsel auf den Baeren, mehrere Ereignisse dicht hintereinander
   druid("Baergestalt", 80, { 51, 10, 0 })
   for _ = 1, 3 do W.Fire("UPDATE_SHAPESHIFT_FORM") W.Advance(0.1) end
   W.Advance(0.4)
   eq(#whispers(), 0, "noch in der Entprellung")
   W.Advance(6)
   local w = whispers()
   local resets = 0
   for _, t in ipairs(w) do if t == "co !" then resets = resets + 1 end end
   eq(resets, 1, "genau eine Neusendung")
   eq(#w, 3, "co !, Profilstrategien, Gestalt")
   eq(w[#w], "co +bear,-aoe,-cc,-boost,-cure", "Baer ohne Wilden Kampf")
   check(not anyWhisperMatches("nc "), "kein nc")
   eq(B.applyCount, applied, "applyCount unveraendert")
   eq(B.formStrategy, "bear", "Gestalt gemerkt")

   -- noch ein Ereignis, Gestalt unveraendert: nichts
   W.ClearSent()
   W.Fire("UPDATE_SHAPESHIFT_FORM")
   W.Advance(5)
   eq(#whispers(), 0, "unveraendert: nichts")

   -- Reisegestalt: die Strategie der Gestalt entfaellt
   druid("Reisegestalt", 80, { 51, 10, 0 })
   W.Fire("UPDATE_SHAPESHIFT_FORM")
   W.Advance(5)
   w = whispers()
   eq(#w, 2, "co ! und Profilstrategien, kein Gestaltbefehl")
   eq(B.formStrategy, nil, "keine Gestaltstrategie")

   -- Bot aus: kein Senden
   W.ServerLine("SelfBot is now deactivated.")
   W.ClearSent()
   druid("Katzengestalt", 80, { 51, 10, 0 })
   W.Fire("UPDATE_SHAPESHIFT_FORM")
   W.Advance(5)
   eq(#whispers(), 0, "Bot laeuft nicht: nichts gesendet")

   -- Steuerung aus: kein Senden
   W.ServerLine("SelfBot is now active.")
   AutoTravel.Set("BotControl", 0)
   druid("Baergestalt", 80, { 51, 10, 0 })
   W.Fire("UPDATE_SHAPESHIFT_FORM")
   W.Advance(5)
   eq(#whispers(), 0, "ohne Playerbot-Steuerung nichts gesendet")
end)

test("Gestaltwechsel bei Nicht-Druiden: Ereignis bleibt folgenlos", function()
   ready()
   local B = AutoTravel.Bot
   B.Enable()
   W.ServerLine("SelfBot is now active.")
   W.Advance(10)
   W.ClearSent()
   W.Fire("UPDATE_SHAPESHIFT_FORM")
   W.Advance(5)
   eq(#whispers(), 0, "nichts gesendet")
end)

-- ---------------------------------------------------------------------------
-- 11.5: Traenke, Wartung, Haltung des Begleiters
-- ---------------------------------------------------------------------------

local function setPet(present)
   _G.UnitExists = function(u)
      if u == "pet" then return present and 1 or nil end
      return 1
   end
end

local function petWhispers()
   local n = 0
   for _, t in ipairs(whispers()) do if t:find("^pet ") then n = n + 1 end end
   return n
end

test("neue Strategien: potions (Kampf) und maintenance (Nichtkampf) stehen in den Listen der Profile", function()
   boot()
   local B = AutoTravel.Bot
   local function has(list, name)
      for _, f in ipairs(list) do if f[1] == name then return true end end
      return false
   end
   check(has(B.CombatFlags, "potions"), "potions im Kampf")
   check(has(B.NonCombatFlags, "maintenance"), "maintenance ausserhalb des Kampfes")
   check(has(B.BuiltinNonCombatFlags, "maintenance"), "...auch bei den festen Profilen")
   check(has(B.BuiltinNonCombatFlags, "gather"), "gather bleibt bei den festen Profilen")
   check(not has(B.NonCombatFlags, "gather"), "gather bleibt aus der Liste der eigenen Profile heraus")
end)

test("feste Profile setzen weder potions noch maintenance (keine stille Aenderung)", function()
   boot()
   local B = AutoTravel.Bot
   for _, d in ipairs(B.Builtin) do
      check(not d.combat:find("potions", 1, true), d.key .. ": potions nicht gesetzt")
      check(not d.noncombat:find("maintenance", 1, true), d.key .. ": maintenance nicht gesetzt")
      check(B.ValidPet(d.pet) == nil, d.key .. ": keine Haltung gesetzt")
   end
end)

test("eigenes Profil: ohne Eintrag gilt potions als an und maintenance als aus (Standard des Servers)", function()
   ready()
   local B = AutoTravel.Bot
   W.ServerLine("SelfBot is now active.")
   local c = B.CustomSlot(1)
   c.combat.dps = true                       -- ein frueher gespeichertes Profil kennt potions nicht
   AutoTravel.Set("Profile", "custom1")
   W.ClearSent()
   B.ApplyProfile()
   W.Advance(10)
   local co, nc
   for _, t in ipairs(whispers()) do
      if t:find("^co %+") or t:find("^co %-") then co = (co or "") .. t .. "|" end
      if t:find("^nc %+") or t:find("^nc %-") then nc = (nc or "") .. t .. "|" end
   end
   check(co and co:find("+potions", 1, true), "co setzt +potions: " .. tostring(co))
   check(nc and nc:find("-maintenance", 1, true), "nc setzt -maintenance: " .. tostring(nc))
   check(not (co and co:find("-potions", 1, true)), "kein -potions")
end)

test("eigenes Profil: potions abwaehlen speichert ausdruecklich false und sendet -potions", function()
   ready()
   local B = AutoTravel.Bot
   W.ServerLine("SelfBot is now active.")
   AutoTravel.ProfileEditor.Select("custom", 1)
   local pot = flagBox("combat", "potions")
   check(pot ~= nil, "Kaestchen vorhanden")
   check(pot.__shown ~= false, "bei eigenen Profilen sichtbar")
   check(pot:GetChecked() == true or pot:GetChecked() == 1, "ohne Eintrag angehakt (Standard: an)")
   pot:SetChecked(false)
   click(pot)
   eq(B.CustomSlot(1).combat.potions, false, "abgewaehlt = ausdruecklich aus")
   check(B.CustomUsed(1), "das Profil zaehlt als benutzt")
   AutoTravel.Set("Profile", "custom1")
   W.ClearSent()
   B.ApplyProfile()
   W.Advance(10)
   check(anyWhisperMatches("-potions"), "-potions geht an den Bot")
   pot:SetChecked(true)
   click(pot)
   eq(B.CustomSlot(1).combat.potions, true, "wieder angehakt = an")

   -- eine andere Flagge ohne Standard bleibt bei nil, wenn sie abgewaehlt wird
   local boost = flagBox("combat", "boost")
   boost:SetChecked(true) click(boost)
   boost:SetChecked(false) click(boost)
   eq(B.CustomSlot(1).combat.boost, nil, "boost: abgewaehlt = nicht gesetzt, wie bisher")
end)

test("feste Profile: potions und maintenance lassen sich setzen und gehen an den Bot", function()
   ready()
   local B = AutoTravel.Bot
   W.ServerLine("SelfBot is now active.")
   AutoTravel.Set("Profile", "normal")
   AutoTravel.ProfileEditor.Select("builtin", "normal")
   local pot = flagBox("combat", "potions")
   local mnt = flagBox("noncombat", "maintenance")
   check(pot ~= nil and mnt ~= nil, "beide Kaestchen vorhanden")
   click(pot)                                -- nicht gesetzt -> an
   click(pot)                                -- an -> aus
   eq(B.BuiltinOverride("normal").combat.potions, false, "potions aus")
   click(mnt)                                -- nicht gesetzt -> an
   eq(B.BuiltinOverride("normal").noncombat.maintenance, true, "maintenance an")
   W.ClearSent()
   B.ApplyProfile()
   W.Advance(10)
   check(anyWhisperMatches("-potions"), "-potions im co-Befehl")
   check(anyWhisperMatches("+maintenance"), "+maintenance im nc-Befehl")
   -- Zuruecksetzen entfernt beides wieder
   AutoTravel.ProfileEditor.ResetSelected()
   check(not B.Find("normal").combat:find("potions", 1, true), "potions nicht mehr gesetzt")
   check(not B.Find("normal").noncombat:find("maintenance", 1, true), "maintenance nicht mehr gesetzt")
end)

test("Haltung des Begleiters: nur gueltige Werte, alles andere gilt als nicht gesetzt", function()
   boot()
   local B = AutoTravel.Bot
   eq(B.ValidPet("aggressive"), "aggressive", "aggressive")
   eq(B.ValidPet("defensive"), "defensive", "defensive")
   eq(B.ValidPet("passive"), "passive", "passive")
   eq(B.ValidPet("passive; destroy all"), nil, "angehaengter Befehl")
   eq(B.ValidPet("attack"), nil, "attack ist keine Haltung")
   eq(B.ValidPet(""), nil, "leer")
   eq(B.ValidPet(5), nil, "keine Zeichenkette")
   eq(B.ValidPet(nil), nil, "nil")
   eq(B.PetLabel("passive"), "passiv", "Anzeige")
   eq(B.PetLabel(nil), "unveraendert", "Anzeige ohne Wert")
end)

test("Haltung des Begleiters: feste Profile senden sie nur mit Begleiter und nur, wenn gesetzt", function()
   ready()
   local B = AutoTravel.Bot
   W.ServerLine("SelfBot is now active.")
   AutoTravel.Set("Profile", "normal")

   setPet(true)
   W.ClearSent()
   B.ApplyProfile()
   W.Advance(10)
   eq(petWhispers(), 0, "kein Standardwert: nichts gesendet")

   B.BuiltinOverride("normal").pet = "passive"
   check(B.IsModified("normal"), "die Haltung zaehlt als Aenderung")
   eq(B.Find("normal").pet, "passive", "wirksam")
   W.ClearSent()
   B.ApplyProfile()
   W.Advance(10)
   check(hasWhisper("pet passive"), "pet passive geht an den Bot")
   eq(petWhispers(), 1, "genau einmal")

   setPet(false)
   W.ClearSent()
   B.ApplyProfile()
   W.Advance(10)
   eq(petWhispers(), 0, "ohne Begleiter nichts (der Bot wuerde mit einer Fehlermeldung antworten)")

   B.ResetBuiltin("normal")
   eq(B.Find("normal").pet, nil, "Zuruecksetzen entfernt die Haltung")
   check(not B.IsModified("normal"), "wieder Standard")

   -- Die Formwechsel-Neuanwendung (nur Kampfstrategien) beruehrt den Begleiter nicht.
   B.BuiltinOverride("normal").pet = "defensive"
   setPet(true)
   W.ClearSent()
   B.ApplyProfile(true)
   W.Advance(10)
   eq(petWhispers(), 0, "ApplyProfile(true) sendet keine Haltung")
   setPet(nil)
end)

test("Haltung des Begleiters: eigene Profile, auch ohne Strategien", function()
   ready()
   local B = AutoTravel.Bot
   W.ServerLine("SelfBot is now active.")
   check(not B.CustomUsed(2), "Platz 2 ist leer")
   B.CustomSlot(2).pet = "aggressive"
   check(B.CustomUsed(2), "eine Haltung allein macht das Profil benutzt")
   eq(B.Find("custom2").pet, "aggressive", "im Profilobjekt")

   setPet(true)
   AutoTravel.Set("Profile", "custom2")
   W.ClearSent()
   B.ApplyProfile()
   W.Advance(10)
   check(hasWhisper("pet aggressive"), "pet aggressive geht an den Bot")

   -- von Hand verdorbene Datei: kein fremder Befehl wird daraus
   B.CustomSlot(2).pet = "aggressive; roll"
   eq(B.CustomSlot(2).pet, nil, "ungueltige Haltung wird verworfen")
   B.BuiltinOverride("normal").pet = "passive; destroy all"
   eq(B.BuiltinOverride("normal").pet, nil, "...auch bei einem festen Profil")
   setPet(nil)
end)

test("Haltung des Begleiters: ruft der Spieler den Begleiter spaeter, wird sie nachgezogen", function()
   ready()
   local B = AutoTravel.Bot
   W.ServerLine("SelfBot is now active.")
   W.Advance(5)
   B.BuiltinOverride("normal").pet = "passive"
   AutoTravel.Set("Profile", "normal")

   setPet(false)
   B.ApplyProfile()
   W.Advance(10)
   W.ClearSent()

   setPet(true)
   W.Fire("UNIT_PET", "player")
   W.Advance(0.5)
   eq(petWhispers(), 0, "entprellt: noch nichts")
   W.Advance(3)
   eq(petWhispers(), 1, "danach genau einmal")
   check(hasWhisper("pet passive"), "pet passive")

   -- fremde Einheit: folgenlos
   W.ClearSent()
   W.Fire("UNIT_PET", "party1")
   W.Advance(5)
   eq(petWhispers(), 0, "UNIT_PET einer anderen Einheit")

   -- Bot aus: nichts
   W.ServerLine("SelfBot is now deactivated.")
   W.ClearSent()
   W.Fire("UNIT_PET", "player")
   W.Advance(5)
   eq(petWhispers(), 0, "Bot laeuft nicht: nichts gesendet")

   -- Steuerung aus: nichts
   W.ServerLine("SelfBot is now active.")
   AutoTravel.Set("BotControl", 0)
   W.ClearSent()
   W.Fire("UNIT_PET", "player")
   W.Advance(5)
   eq(petWhispers(), 0, "ohne Playerbot-Steuerung nichts gesendet")
   setPet(nil)
end)

test("Editor: der Knopf fuer die Haltung wechselt durch alle Zustaende und markiert das Profil als geaendert", function()
   ready()
   local B = AutoTravel.Bot
   AutoTravel.ProfileEditor.Select("builtin", "verteidigen")
   local btn = AutoTravel.ProfileEditor.PetButton()
   check(btn ~= nil, "Knopf vorhanden")
   eq(btn.label:GetText(), "Haltung: unveraendert", "zunaechst unveraendert")
   check(not B.HasOverride("verteidigen"), "Anzeigen legt nichts an")

   click(btn)
   eq(B.BuiltinOverride("verteidigen").pet, "aggressive", "1. Klick")
   eq(btn.label:GetText(), "Haltung: aggressiv", "Anzeige aggressiv")
   check(B.IsModified("verteidigen"), "geaendert")
   click(btn)
   eq(B.BuiltinOverride("verteidigen").pet, "defensive", "2. Klick")
   eq(btn.label:GetText(), "Haltung: defensiv", "Anzeige defensiv")
   click(btn)
   eq(B.BuiltinOverride("verteidigen").pet, "passive", "3. Klick")
   eq(btn.label:GetText(), "Haltung: passiv", "Anzeige passiv")
   click(btn)
   -- Vorsicht: BuiltinOverride() legt eine Ueberschreibung an, wenn es keine gibt; erst pruefen, dann lesen.
   check(not B.HasOverride("verteidigen"), "4. Klick: die Ueberschreibung wird wieder entfernt")
   eq(B.Find("verteidigen").pet, nil, "4. Klick: wieder unveraendert")
   check(not B.IsModified("verteidigen"), "zurueck beim Standard")

   -- eigenes Profil
   AutoTravel.ProfileEditor.Select("custom", 3)
   btn = AutoTravel.ProfileEditor.PetButton()
   eq(btn.label:GetText(), "Haltung: unveraendert", "eigenes Profil: zunaechst unveraendert")
   click(btn)
   eq(B.CustomSlot(3).pet, "aggressive", "eigenes Profil: gesetzt")
   click(btn) click(btn) click(btn)
   eq(B.CustomSlot(3).pet, nil, "eigenes Profil: nach vier Klicks wieder nicht gesetzt")
end)

-- ---------------------------------------------------------------------------
-- 11.6: Verbrauchsgueter (Flaeschchen, Elixiere, Schriftrollen) aus den Taschen
-- ---------------------------------------------------------------------------

-- Gegenstaende aus AT_ConsumableData.lua (Kennung -> Art, Zauber, Stufe):
local ID = {
   flaskRage       = 46377,   -- Flask of Endless Rage        Flaeschchen  Stufe 75
   flaskFrost      = 46376,   -- Flask of the Frost Wyrm      Flaeschchen  Stufe 75
   mongoose        = 13452,   -- Elixir of the Mongoose       Kampf        Stufe 46
   mightyAgility   = 39666,   -- Elixir of Mighty Agility     Kampf        Stufe 70
   mightyFort      = 40078,   -- Elixir of Mighty Fortitude   Waechter     Stufe 70
   minorFort       = 2458,    -- Elixir of Minor Fortitude    Waechter     Stufe 2
   agility1        = 3012,    -- Scroll of Agility            Stufe 1
   agility4        = 10309,   -- Scroll of Agility IV         Stufe 40
   agility7        = 43463,   -- Scroll of Agility VII        Stufe 70
   strength8       = 43466,   -- Scroll of Strength VIII      Stufe 80
   runescroll      = 49632,   -- Runescroll of Fortitude      eigener Platz, Stufe 80
   recall          = 37118,   -- Scroll of Recall             nicht in der Tabelle
   waterBreathing  = 5996,    -- Elixir of Water Breathing    nicht in der Tabelle
}

local function spellOf(id) return AutoTravel.ConsData[id][2] end

local function useWhispers()
   local out = {}
   for _, t in ipairs(whispers()) do if t:find("^u ") then out[#out + 1] = t end end
   return out
end

local function idOf(text) return tonumber(tostring(text):match("Hitem:(%d+):")) end

-- Der Server fuehrt den Befehl aus: ein Stueck weniger, und der Buff liegt auf dem Spieler.
local function serverUses(id, withAura)
   W.TakeOne(id)
   if withAura ~= false then W.AddAura("Buff " .. spellOf(id), spellOf(id)) end
end

-- Warten, bis ein weiterer "u"-Befehl hinausgeht. Rueckgabe: die Kennung des Gegenstands (oder nil).
local function awaitUse(maxSeconds)
   local before = #useWhispers()
   local waited = 0
   while waited < (maxSeconds or 10) do
      W.Advance(0.1)
      waited = waited + 0.1
      local now = useWhispers()
      if #now > before then return idOf(now[#now]), now[#now] end
   end
   return nil
end

-- Ein Charakter im Selbstmodus mit einem eigenen Profil, das die Arten erlaubt. Die Klasse bestimmt, welche
-- Schriftrolle gewaehlt wird: der Schurke nimmt Beweglichkeit und hat keinen Dauerzauber (Jaeger).
local function consBoot(flags, class)
   ready()
   local B = AutoTravel.Bot
   W.ServerLine("SelfBot is now active.")
   W.world.level = 80
   W.world.class = class or "ROGUE"
   local c = B.CustomSlot(1)
   c.cons = flags or {}
   c.combat.dps = true                       -- ein Eintrag, damit das Profil als benutzt zaehlt
   AutoTravel.Set("Profile", "custom1")
   W.ClearSent()
   return B, AutoTravel.Cons
end

local ALL = function() return { flask = true, elixir = true, scroll = true } end

local function startFight()
   W.world.combat = true
   W.Fire("PLAYER_REGEN_DISABLED")
end

-- Reine Auswahl ---------------------------------------------------------------------------

local function stockOf(list)
   local st = {}
   for id, count in pairs(list) do
      st[id] = { id = id, link = W.ItemLink(id), count = count, d = AutoTravel.ConsData[id] }
   end
   return st
end

local function aurasOf(spells, noIds)
   local a = { ids = {}, names = {}, hasIds = not noIds }
   for _, sp in ipairs(spells or {}) do
      if not noIds then a.ids[sp] = true end
      a.names["Buff " .. sp] = true
   end
   return a
end

local function newState() return { slot = {}, item = {}, peace = {}, uses = {}, warned = {} } end

local function decide(list, spells, wanted, extra)
   extra = extra or {}
   return AutoTravel.Cons.Decide(stockOf(list), aurasOf(spells), {
      level = extra.level or 80, wanted = wanted, ignore = extra.ignore or {},
      state = extra.state or newState(), now = extra.now or 1000,
      mode = extra.mode, stats = extra.stats, friendly = extra.friendly, afterAll = extra.afterAll,
   })
end

test("Verbrauchsgueter: die Tabelle kennt Faeschchen, Elixiere und Schriftrollen, aber keine Hilfsmittel", function()
   boot()
   local D = AutoTravel.ConsData
   check(type(D) == "table", "Tabelle geladen")
   local kinds = {}
   for id, d in pairs(D) do
      kinds[d[1]] = (kinds[d[1]] or 0) + 1
      check(d[1] == "flask" or d[1] == "battle" or d[1] == "guardian" or d[1] == "scroll", "Art von " .. id)
      check(type(d[2]) == "number" and d[2] > 0, "Zauber von " .. id)
      check(type(d[3]) == "number" and type(d[4]) == "number", "Stufen von " .. id)
      if d[1] == "scroll" then
         check(type(d[5]) == "string" and type(d[6]) == "number", "Wert und Rang der Schriftrolle " .. id)
      end
   end
   check((kinds.flask or 0) >= 30 and (kinds.battle or 0) >= 30 and (kinds.guardian or 0) >= 20
         and (kinds.scroll or 0) >= 40, "von jeder Art genug Eintraege")
   eq(D[ID.flaskRage][1], "flask", "Flask of Endless Rage")
   eq(D[ID.mongoose][1], "battle", "Elixir of the Mongoose")
   eq(D[ID.mightyFort][1], "guardian", "Elixir of Mighty Fortitude")
   eq(D[ID.agility7][5], "agility", "Wert der Schriftrolle")
   eq(D[ID.agility7][6], 7, "Rang der Schriftrolle")
   check(D[ID.recall] == nil, "Scroll of Recall (Teleport) fehlt")
   check(D[ID.waterBreathing] == nil, "Wasseratmung fehlt")
   check(D[8827] == nil, "Wasserwandeln fehlt")
   check(D[9154] == nil, "Untote erkennen fehlt")
end)

test("Verbrauchsgueter: feste Profile erlauben nichts und bleiben unveraendert", function()
   boot()
   local B = AutoTravel.Bot
   for _, d in ipairs(B.Builtin) do
      check(d.cons == nil, d.key .. ": Standard ohne Verbrauchsgueter")
      check(not B.IsModified(d.key), d.key .. ": unveraendert")
   end
   AutoTravel.Set("Profile", "plus")
   local w = AutoTravel.Cons.Wanted()
   check(not w.flask and not w.elixir and not w.scroll, "Plus erlaubt nichts")
end)

test("Verbrauchsgueter: beschaedigte Eintraege der gespeicherten Profile fallen heraus", function()
   boot()
   local B = AutoTravel.Bot
   B.Global().custom[1] = { name = "X", combat = {}, noncombat = {}, extra = "", grace = 2,
                            cons = { flask = "ja", elixir = true, bogus = true, scroll = 1 } }
   local c = B.CustomSlot(1)
   eq(c.cons.elixir, true, "elixir bleibt")
   eq(c.cons.flask, nil, "flask = \"ja\" ist kein true")
   eq(c.cons.scroll, nil, "scroll = 1 ist kein true")
   eq(c.cons.bogus, nil, "unbekannte Art faellt heraus")
   B.Global().custom[2] = { cons = "kaputt" }
   check(type(B.CustomSlot(2).cons) == "table", "keine Tabelle: neu angelegt")
end)

test("Editor: Verbrauchsgueter in festen Profilen haben zwei Zustaende; das Profil gilt als geaendert und kehrt zurueck", function()
   ready()
   local B = AutoTravel.Bot
   AutoTravel.ProfileEditor.Select("builtin", "plus")
   local fl = flagBox("cons", "flask")
   check(fl ~= nil, "Kaestchen vorhanden")
   check(fl.text:GetText():find("Flaeschchen", 1, true), "Anzeigename statt Schluessel")
   check(not B.HasOverride("plus"), "Anzeigen legt nichts an")

   click(fl)
   eq(B.BuiltinOverride("plus").cons.flask, true, "1. Klick: an")
   check(B.IsModified("plus"), "geaendert")
   check(fl.text:GetText():find("+", 1, true), "Anzeige: +")
   AutoTravel.Set("Profile", "plus")
   local w = AutoTravel.Cons.Wanted()
   check(w.flask and not w.elixir and not w.scroll, "nur Flaeschchen erlaubt")

   click(fl)
   check(not B.HasOverride("plus"), "2. Klick: aus - die Ueberschreibung ist weg (kein 'ausdruecklich aus')")
   check(not B.IsModified("plus"), "wieder der Standard")
   check(not AutoTravel.Cons.Wanted().flask, "nichts erlaubt")
end)

test("Editor: eigenes Profil: Haken setzt true, Abwaehlen entfernt, das Profil zaehlt als benutzt", function()
   ready()
   local B = AutoTravel.Bot
   AutoTravel.ProfileEditor.Select("custom", 2)
   local el = flagBox("cons", "elixir")
   check(el ~= nil and el.__shown ~= false, "Kaestchen sichtbar")
   check(not B.CustomUsed(2), "zunaechst leer")
   el:SetChecked(true) click(el)
   eq(B.CustomSlot(2).cons.elixir, true, "angehakt")
   check(B.CustomUsed(2), "zaehlt als benutzt")
   AutoTravel.Set("Profile", "custom2")
   check(AutoTravel.Cons.Wanted().elixir, "das Profil erlaubt Elixiere")
   el:SetChecked(false) click(el)
   eq(B.CustomSlot(2).cons.elixir, nil, "abgewaehlt: nicht gesetzt")
   check(not B.CustomUsed(2), "wieder leer")
end)

test("Editor: die Verbrauchsgueter erscheinen nicht als Strategie beim Bot", function()
   ready()
   local B = AutoTravel.Bot
   W.ServerLine("SelfBot is now active.")
   B.CustomSlot(1).cons = ALL()
   B.CustomSlot(1).combat.dps = true
   AutoTravel.Set("Profile", "custom1")
   W.ClearSent()
   B.ApplyProfile()
   W.Advance(10)
   for _, t in ipairs(whispers()) do
      check(not t:find("flask", 1, true) and not t:find("elixir", 1, true) and not t:find("scroll", 1, true),
            "kein Verbrauchsgut in " .. t)
   end
end)

test("B.Whisper: der Rueckruf laeuft erst, wenn die Nachricht hinausgeht", function()
   ready()
   local B = AutoTravel.Bot
   local sent = false
   B.Whisper("pruefen", function() sent = true end)
   check(not sent, "noch nicht gesendet")
   W.Advance(1.0)
   check(sent, "nach dem Senden")
   check(hasWhisper("pruefen"), "die Nachricht ging hinaus")
end)

test("Auswahl: ohne Erlaubnis nichts, mit Erlaubnis die richtige Art", function()
   boot()
   local list = { [ID.flaskRage] = 1, [ID.mongoose] = 1, [ID.agility7] = 1 }
   eq(decide(list, {}, { flask = false, elixir = false, scroll = false }), nil, "nichts erlaubt")
   eq((decide(list, {}, { flask = true })).id, ID.flaskRage, "nur Flaeschchen")
   eq((decide(list, {}, { elixir = true })).id, ID.mongoose, "nur Elixiere")
   eq((decide(list, {}, { scroll = true })).id, ID.agility7, "nur Schriftrollen")
end)

test("Auswahl: ein wirkender Buff erledigt seinen Platz", function()
   boot()
   local list = { [ID.mongoose] = 1, [ID.mightyFort] = 1, [ID.agility7] = 1 }
   local all = ALL()
   local e, key = decide(list, {}, all)
   eq(e.id, ID.mongoose, "zuerst das Kampfelixier") eq(key, "battle", "Platz battle")
   e = decide(list, { spellOf(ID.mongoose) }, all)
   eq(e.id, ID.mightyFort, "danach das Waechterelixier")
   e = decide(list, { spellOf(ID.mongoose), spellOf(ID.mightyFort) }, all)
   eq(e.id, ID.agility7, "danach die Schriftrolle")
   e = decide(list, { spellOf(ID.mongoose), spellOf(ID.mightyFort), spellOf(ID.agility7) }, all)
   eq(e, nil, "alles wirkt: nichts zu tun")
end)

test("Auswahl: Kampf- und Waechterplatz sind unabhaengig voneinander", function()
   boot()
   local list = { [ID.mongoose] = 1, [ID.mightyFort] = 1 }
   local el = { elixir = true }
   -- nur ein Waechterelixier wirkt: das Kampfelixier ist trotzdem faellig
   local e, key = decide(list, { spellOf(ID.mightyFort) }, el)
   eq(e and e.id, ID.mongoose, "Waechterplatz belegt, Kampfplatz frei: Kampfelixier") eq(key, "battle", "Platz battle")
   -- nur ein Kampfelixier wirkt: das Waechterelixier ist faellig
   e, key = decide(list, { spellOf(ID.mongoose) }, el)
   eq(e and e.id, ID.mightyFort, "Kampfplatz belegt, Waechterplatz frei: Waechterelixier") eq(key, "guardian", "Platz guardian")
   -- beide belegt
   eq(decide(list, { spellOf(ID.mongoose), spellOf(ID.mightyFort) }, el), nil, "beide belegt: nichts")
   -- ein Waechterelixier im Beutel, das Kampfelixier fehlt: nur das Waechterelixier
   e = decide({ [ID.mightyFort] = 1 }, {}, el)
   eq(e and e.id, ID.mightyFort, "nur ein Waechterelixier vorhanden")
end)

test("Auswahl: ein Flaeschchen belegt beide Plaetze und wird nicht durch Elixiere ersetzt", function()
   boot()
   local list = { [ID.flaskRage] = 2, [ID.mongoose] = 1, [ID.mightyFort] = 1 }
   local all = ALL()
   local e = decide(list, {}, all)
   eq(e.id, ID.flaskRage, "ohne Buff zuerst das Flaeschchen")
   eq(decide(list, { spellOf(ID.flaskRage) }, all), nil, "wirkt das Flaeschchen, bleiben die Elixiere liegen")
   -- ein anderes Flaeschchen wirkt ebenso
   eq(decide(list, { spellOf(ID.flaskFrost) }, all), nil, "ein anderes Flaeschchen zaehlt auch")
   -- ein wirkendes Kampfelixier: das Flaeschchen wuerde es ersetzen
   e = decide(list, { spellOf(ID.mongoose) }, all)
   check(e == nil or e.id ~= ID.flaskRage, "ein Elixier wird nicht durch das Flaeschchen ersetzt")
   eq(e and e.id, ID.mightyFort, "stattdessen der freie Waechterplatz")
   -- Flaeschchen nicht erlaubt: die Elixiere kommen dran
   e = decide(list, {}, { elixir = true })
   eq(e.id, ID.mongoose, "ohne Flaeschchen-Erlaubnis das Elixier")
end)

test("Auswahl: von mehreren Gegenstaenden eines Platzes der hoechste, den der Charakter tragen darf", function()
   boot()
   local list = { [ID.agility1] = 1, [ID.agility4] = 1, [ID.agility7] = 1 }
   eq((decide(list, {}, { scroll = true }, { level = 80 })).id, ID.agility7, "Stufe 80: Rang 7")
   eq((decide(list, {}, { scroll = true }, { level = 69 })).id, ID.agility4, "Stufe 69: Rang 4 (Rang 7 braucht 70)")
   eq((decide(list, {}, { scroll = true }, { level = 39 })).id, ID.agility1, "Stufe 39: Rang 1")
   local e = decide({ [ID.agility7] = 1 }, {}, { scroll = true }, { level = 30 })
   eq(e, nil, "kein tragbarer Gegenstand: nichts")
   -- jede Stufe des Werts erledigt ihn
   eq(decide(list, { spellOf(ID.agility4) }, { scroll = true }), nil, "eine niedrigere Stufe wirkt: erledigt")
   -- Elixiere
   local el = { [ID.mongoose] = 1, [ID.mightyAgility] = 1 }
   eq((decide(el, {}, { elixir = true })).id, ID.mightyAgility, "das hoehere Kampfelixier")
   eq((decide(el, {}, { elixir = true }, { level = 50 })).id, ID.mongoose, "Stufe 50: das niedrigere")
end)

test("Auswahl: Ausschlussliste, Sperre und Mindestabstand", function()
   boot()
   local list = { [ID.mongoose] = 1, [ID.mightyAgility] = 1 }
   local el = { elixir = true }
   eq((decide(list, {}, el, { ignore = { [ID.mightyAgility] = true } })).id, ID.mongoose, "ausgeschlossen: das andere")
   eq(decide(list, {}, el, { ignore = { [ID.mightyAgility] = true, [ID.mongoose] = true } }), nil, "beide ausgeschlossen")

   local st = newState()
   st.item[ID.mightyAgility] = { tries = 0, blockedUntil = 1500 }
   eq((decide(list, {}, el, { state = st, now = 1000 })).id, ID.mongoose, "gesperrt: das andere")
   eq((decide(list, {}, el, { state = st, now = 1600 })).id, ID.mightyAgility, "Sperre abgelaufen")

   -- Mindestabstand je Platz
   st = newState()
   st.slot.battle = { lastUse = 1000, verified = true }
   eq(decide(list, {}, el, { state = st, now = 1030 }), nil, "30 s nach einer Benutzung (Buff gesehen): noch nicht")
   check(decide(list, {}, el, { state = st, now = 1046 }) ~= nil, "nach 45 s wieder")
   st.slot.battle = { lastUse = 1000, verified = false }
   eq(decide(list, {}, el, { state = st, now = 1500 }), nil, "Buff nie gesehen: 10 Minuten Pause")
   check(decide(list, {}, el, { state = st, now = 1601 }) ~= nil, "nach 10 Minuten wieder")
end)

test("Auswahl: ohne Zauberkennung des Clients gilt der Name, mit ihr nur die Kennung", function()
   boot()
   W.world.spells[spellOf(ID.mongoose)] = { "Buff " .. spellOf(ID.mongoose), "icon" }
   local list = { [ID.mongoose] = 1 }
   local stock = stockOf(list)
   local o = { level = 80, wanted = { elixir = true }, ignore = {}, state = newState(), now = 1000 }
   -- Name da, aber der Client liefert Kennungen: ein gleichnamiger fremder Buff zaehlt nicht
   local a = { ids = { [99999] = true }, names = { ["Buff " .. spellOf(ID.mongoose)] = true }, hasIds = true }
   check(AutoTravel.Cons.Decide(stock, a, o) ~= nil, "mit Kennungen: der Name allein genuegt nicht")
   -- ohne Kennungen: der Name genuegt
   a = { ids = {}, names = { ["Buff " .. spellOf(ID.mongoose)] = true }, hasIds = false }
   eq(AutoTravel.Cons.Decide(stock, a, o), nil, "ohne Kennungen: der Name zaehlt")
end)

-- Im Spiel -----------------------------------------------------------------------------------

test("Im Kampf: das Addon fluestert 'u <Link>', prueft das Ergebnis und macht mit dem naechsten Platz weiter", function()
   local B = consBoot(ALL())
   W.Give(ID.mongoose, 2)
   W.Give(ID.mightyFort, 1)
   W.Give(ID.agility7, 3)
   startFight()

   local id, text = awaitUse(5)
   eq(id, ID.mongoose, "zuerst das Kampfelixier")
   eq(text, "u " .. W.ItemLink(ID.mongoose), "der Befehl ist 'u' und der Link des Gegenstands")
   check(B.IsOwnCommand(text), "das Echo des Befehls wird verborgen")
   eq(#useWhispers(), 1, "genau ein Befehl")

   serverUses(ID.mongoose)
   id = awaitUse(10)
   eq(id, ID.mightyFort, "danach das Waechterelixier (nach dem Abstand von 3,5 s)")
   serverUses(ID.mightyFort)
   id = awaitUse(10)
   eq(id, ID.agility7, "danach die Schriftrolle")
   serverUses(ID.agility7)
   id = awaitUse(10)
   eq(id, nil, "alle Buffs wirken: nichts mehr")
   eq(#useWhispers(), 3, "insgesamt drei Befehle")
   eq(W.CountOf(ID.mongoose), 1, "ein Elixier blieb uebrig")
   eq(AutoTravel.Cons.state.total, 3, "drei gelungene Benutzungen gezaehlt")
end)

test("Im Kampf: nur im Kampf, nur im Selbstmodus, nur mit Erlaubnis des Profils", function()
   local B = consBoot(ALL())
   W.Give(ID.mongoose, 1)
   -- ausserhalb des Kampfes
   W.Advance(10)
   eq(#useWhispers(), 0, "ausserhalb des Kampfes nichts")

   -- Selbstmodus aus
   W.ServerLine("SelfBot is now deactivated.")
   startFight()
   W.Advance(10)
   eq(#useWhispers(), 0, "ohne Selbstmodus nichts")
   W.ServerLine("SelfBot is now active.")

   -- Profil erlaubt nichts
   B.CustomSlot(1).cons = {}
   W.Advance(10)
   eq(#useWhispers(), 0, "ohne Erlaubnis des Profils nichts")

   -- Playerbot-Steuerung aus
   B.CustomSlot(1).cons = ALL()
   AutoTravel.Set("BotControl", 0)
   W.Advance(10)
   eq(#useWhispers(), 0, "mit ausgeschalteter Steuerung nichts")
   AutoTravel.Set("BotControl", 1)

   -- jetzt sind alle Voraussetzungen da
   eq(awaitUse(5), ID.mongoose, "mit allen Voraussetzungen: der Befehl geht hinaus")
end)

test("Im Kampf: nur die Arten, die das Profil erlaubt", function()
   consBoot({ scroll = true })
   W.Give(ID.flaskRage, 1)
   W.Give(ID.mongoose, 1)
   W.Give(ID.agility7, 1)
   startFight()
   local id = awaitUse(5)
   eq(id, ID.agility7, "nur die Schriftrolle")
   serverUses(ID.agility7)
   eq(awaitUse(10), nil, "weder Flaeschchen noch Elixier")
end)

test("Im Kampf: ein Flaeschchen vor den Elixieren, und ein wirkendes Flaeschchen laesst die Elixiere liegen", function()
   consBoot({ flask = true, elixir = true })
   W.Give(ID.flaskRage, 2)
   W.Give(ID.mongoose, 1)
   W.Give(ID.mightyFort, 1)
   startFight()
   eq(awaitUse(5), ID.flaskRage, "zuerst das Flaeschchen")
   serverUses(ID.flaskRage)
   eq(awaitUse(20), nil, "danach kein Elixier: das Flaeschchen belegt beide Plaetze")
   eq(W.CountOf(ID.mongoose), 1, "das Elixier ist unberuehrt")
end)

test("Im Kampf: ist der Buff abgelaufen, kommt der naechste Gegenstand derselben Art dran", function()
   consBoot({ scroll = true })
   W.Give(ID.agility7, 3)
   startFight()
   eq(awaitUse(5), ID.agility7, "erste Schriftrolle")
   serverUses(ID.agility7)
   W.Advance(10)
   eq(#useWhispers(), 1, "solange der Buff wirkt, keine zweite")
   eq(W.CountOf(ID.agility7), 2, "zwei uebrig")

   -- der Buff laeuft aus (30 Minuten spaeter): die naechste kommt im Kampf
   W.RemoveAura(spellOf(ID.agility7))
   local id = awaitUse(60)
   eq(id, ID.agility7, "zweite Schriftrolle")
   serverUses(ID.agility7)
   W.Advance(20)
   eq(W.CountOf(ID.agility7), 1, "eine uebrig")
   eq(#useWhispers(), 2, "zwei Befehle insgesamt")
end)

test("Im Kampf: verschwindet der Buff gleich nach der Benutzung, gilt der Mindestabstand (keine Schleife)", function()
   consBoot({ scroll = true })
   W.Give(ID.agility7, 5)
   startFight()
   eq(awaitUse(5), ID.agility7, "erste")
   local t1 = W.now
   serverUses(ID.agility7)
   W.Advance(3)
   W.RemoveAura(spellOf(ID.agility7))              -- etwa von einem staerkeren Buff ersetzt
   W.Advance(30)
   eq(#useWhispers(), 1, "30 s lang keine zweite Benutzung")
   eq(awaitUse(30), ID.agility7, "danach wieder")
   local gap = W.now - t1
   check(gap >= 45 and gap < 52, "nach rund 45 s, nicht frueher: " .. gap)
end)

test("Im Kampf: ohne Wirkung wird mehrfach versucht, dann der Gegenstand gesperrt und der naechste genommen", function()
   consBoot({ elixir = true })
   W.Give(ID.mightyAgility, 1)
   W.Give(ID.mongoose, 1)
   startFight()

   local first = awaitUse(5)
   eq(first, ID.mightyAgility, "der hoehere zuerst")
   -- der Server tut nichts: es gibt weder weniger Stuecke noch einen Buff
   local tries = 1
   for _ = 1, 40 do
      local id = awaitUse(12)
      if not id then break end
      if id == ID.mightyAgility then tries = tries + 1 else
         eq(id, ID.mongoose, "nach der Sperre das niedrigere Elixier")
         break
      end
   end
   eq(tries, AutoTravel.Cons.MAX_TRIES, "so viele Versuche, dann im Kampf nicht mehr")
   local warned = false
   for _, m in ipairs(W.messages) do if m:find("liess sich im Kampf nicht benutzen", 1, true) then warned = true end end
   check(warned, "der Spieler erfaehrt, dass es nach dem Kampf versucht wird")
   eq(W.CountOf(ID.mightyAgility), 1, "nichts wurde verbraucht")
   check(AutoTravel.Cons.state.peace[ID.mightyAgility] ~= nil, "als 'nur nach dem Kampf' gemerkt")
end)

local function endFight()
   W.world.combat = false
   W.Fire("PLAYER_REGEN_ENABLED")
end

test("Nach dem Kampf: was im Kampf nicht ging, wird danach nachgeholt und im Kampf nicht mehr versucht", function()
   consBoot({ elixir = true })
   W.Give(ID.mongoose, 3)
   local tries = AutoTravel.Cons.MAX_TRIES
   startFight()
   for _ = 1, tries do awaitUse(12) end
   eq(#useWhispers(), tries, "so viele Versuche im Kampf")
   W.Advance(40)
   eq(#useWhispers(), tries, "danach im Kampf nichts mehr")

   endFight()
   local id = awaitUse(5)
   eq(id, ID.mongoose, "nach dem Kampf geht der Befehl hinaus")
   serverUses(ID.mongoose)                          -- jetzt klappt es
   W.Advance(10)
   eq(AutoTravel.Cons.state.total, 1, "gelungen")

   -- der Buff laeuft aus; im naechsten Kampf wird der Gegenstand nicht mehr versucht
   W.RemoveAura(spellOf(ID.mongoose))
   W.Advance(60)
   local n = #useWhispers()
   startFight()
   W.Advance(30)
   eq(#useWhispers(), n, "im Kampf nicht, denn dort ging es nicht")
   endFight()
   check(awaitUse(5) == ID.mongoose, "nach dem Kampf wieder")
end)

test("Nach dem Kampf: das Zeitfenster ist begrenzt, und ein erneuter Fehlschlag sperrt den Gegenstand", function()
   consBoot({ elixir = true })
   W.Give(ID.mongoose, 2)
   AutoTravel.Cons.state.peace[ID.mongoose] = true  -- im Kampf ging es nicht
   startFight()
   W.Advance(20)
   eq(#useWhispers(), 0, "im Kampf nichts")

   endFight()
   W.Advance(30)                                    -- das Fenster von 25 s verstreicht ohne Befehl? nein: es wird versucht
   local n = #useWhispers()
   eq(n, AutoTravel.Cons.MAX_TRIES, "im Fenster wird versucht, aber nur so oft wie erlaubt")
   local warned = false
   for _, m in ipairs(W.messages) do if m:find("Pause: 90 s", 1, true) then warned = true end end
   check(warned, "nach den Fehlschlaegen auch danach: gesperrt")
   W.Advance(100)
   eq(#useWhispers(), n, "ausserhalb des Fensters nichts mehr")
end)

test("Nach dem Kampf: nur das Nachzuholende, nichts anderes", function()
   consBoot({ elixir = true, scroll = true }, "WARRIOR")      -- der Krieger nimmt Staerke
   W.Give(ID.mongoose, 1)
   AutoTravel.Cons.state.peace[ID.mongoose] = true  -- im Kampf ging es nicht
   startFight()
   W.Advance(10)
   eq(#useWhispers(), 0, "im Kampf nichts: das Elixier geht dort nicht")
   endFight()
   W.Give(ID.strength8, 1)                          -- liegt erst jetzt in den Taschen
   eq(awaitUse(5), ID.mongoose, "nach dem Kampf das Nachzuholende")
   serverUses(ID.mongoose)
   W.Advance(15)
   eq(#useWhispers(), 1, "die Schriftrolle wartet auf den naechsten Kampf")
   startFight()
   eq(awaitUse(5), ID.strength8, "im naechsten Kampf kommt sie dran")
end)

test("Nach dem Kampf: ohne Gegenstaende, die im Kampf nicht gingen, geschieht nichts", function()
   consBoot({ elixir = true, scroll = true })
   W.Give(ID.mongoose, 1)
   startFight()
   eq(awaitUse(5), ID.mongoose, "im Kampf versucht")
   serverUses(ID.mongoose)
   W.Advance(10)
   endFight()
   W.RemoveAura(spellOf(ID.mongoose))
   W.Give(ID.agility7, 1)
   W.Advance(60)
   eq(#useWhispers(), 1, "nach dem Kampf wird nichts Neues begonnen")
end)

test("Im Kampf: verbraucht, aber kein Buff zu sehen: einmal warnen und zehn Minuten Pause", function()
   consBoot({ scroll = true })
   W.Give(ID.agility7, 4)
   startFight()
   eq(awaitUse(5), ID.agility7, "erste")
   local t1 = W.now
   serverUses(ID.agility7, false)                   -- verbraucht, aber kein Buff
   W.Advance(10)
   local warnings = 0
   for _, m in ipairs(W.messages) do if m:find("Buff ist nicht zu sehen", 1, true) then warnings = warnings + 1 end end
   eq(warnings, 1, "eine Warnung")
   W.Advance(300)
   eq(#useWhispers(), 1, "fuenf Minuten spaeter noch nichts")
   eq(awaitUse(400), ID.agility7, "danach wieder")
   local gap = W.now - t1
   check(gap >= 600 and gap < 610, "nach zehn Minuten, nicht frueher: " .. gap)
   warnings = 0
   for _, m in ipairs(W.messages) do if m:find("Buff ist nicht zu sehen", 1, true) then warnings = warnings + 1 end end
   eq(warnings, 1, "die Warnung kam nur einmal")
end)

test("Im Kampf: ein Flaeschchen ohne sichtbaren Buff laesst die Elixiere zehn Minuten in Ruhe", function()
   consBoot({ flask = true, elixir = true })
   W.Give(ID.flaskRage, 1)
   W.Give(ID.mongoose, 1)
   W.Give(ID.mightyFort, 1)
   startFight()
   eq(awaitUse(5), ID.flaskRage, "zuerst das Flaeschchen")
   local t1 = W.now
   serverUses(ID.flaskRage, false)                  -- verbraucht, der Buff ist nicht zu erkennen
   W.Advance(120)
   eq(#useWhispers(), 1, "ein Elixier wuerde das Flaeschchen ersetzen: zwei Minuten nichts")
   check(awaitUse(600) == ID.mongoose, "nach zehn Minuten kommen die Elixiere")
   check(W.now - t1 >= 600, "nicht frueher als nach zehn Minuten: " .. (W.now - t1))
end)

test("Im Kampf: wer zaubert, faehrt oder tot ist, bekommt nichts", function()
   consBoot({ scroll = true })
   W.Give(ID.agility7, 1)
   startFight()
   W.world.casting = true
   W.Advance(10)
   eq(#useWhispers(), 0, "beim Zaubern nichts")
   W.world.casting = false
   W.world.mounted = true
   W.Advance(10)
   eq(#useWhispers(), 0, "auf dem Reittier nichts")
   W.world.mounted = false
   W.world.onTaxi = true
   W.Advance(10)
   eq(#useWhispers(), 0, "auf dem Flug nichts")
   W.world.onTaxi = false
   W.world.vehicle = true
   W.Advance(10)
   eq(#useWhispers(), 0, "im Fahrzeug nichts")
   W.world.vehicle = false
   W.world.dead = true
   W.Advance(10)
   eq(#useWhispers(), 0, "tot nichts")
   W.world.dead = false
   check(awaitUse(5) == ID.agility7, "danach geht es los")
end)

test("Im Kampf: eine Stufe zu niedrig, eine Obergrenze je Zeitfenster und der Tod", function()
   consBoot({ scroll = true })
   W.Give(ID.agility7, 1)                           -- Stufe 70
   W.world.level = 60
   startFight()
   W.Advance(10)
   eq(#useWhispers(), 0, "Stufe 60: Rang 7 geht nicht")
   W.world.level = 80

   -- Obergrenze: zehn Benutzungen in zwei Minuten
   local C = AutoTravel.Cons
   local now = W.now
   for i = 1, 10 do C.state.uses[i] = now - i end
   W.Advance(10)
   eq(#useWhispers(), 0, "Obergrenze erreicht")
   W.Advance(120)
   check(#useWhispers() >= 1, "nach dem Fenster geht es weiter")
end)

test("Im Kampf: nach dem Tod gelten die Mindestabstaende nicht mehr", function()
   consBoot({ scroll = true })
   W.Give(ID.agility7, 3)
   startFight()
   eq(awaitUse(5), ID.agility7, "erste")
   serverUses(ID.agility7)
   W.Advance(5)
   -- der Charakter stirbt: die Buffs sind weg
   W.world.dead = true
   W.Fire("PLAYER_DEAD")
   W.RemoveAura(spellOf(ID.agility7))
   W.Advance(5)
   W.world.dead = false
   W.Advance(1)
   eq(awaitUse(8), ID.agility7, "gleich wieder, ohne die 45 s abzuwarten")
end)

test("Im Kampf: ein Befehl, der nie hinausgeht, blockiert nicht fuer immer", function()
   consBoot({ scroll = true })
   W.Give(ID.agility7, 2)
   startFight()
   W.Advance(0.2)
   AutoTravel.Net.DropTag("bot")                   -- die Warteschlange verwirft den Befehl
   W.Advance(10)
   eq(#useWhispers(), 0, "der Befehl ging nie hinaus")
   W.Advance(15)                                    -- nach 20 s gilt er als verloren
   check(awaitUse(10) == ID.agility7, "danach ein neuer Versuch")
end)

test("/at buffs: Zustand, jetzt, ignorieren, erlauben, liste", function()
   local B = consBoot(ALL())
   local slash = SlashCmdList["AUTOTRAVEL"]
   W.Give(ID.agility7, 2)
   W.Give(ID.mongoose, 1)

   local n0 = #W.messages
   slash("buffs")
   local text = table.concat(W.messages, "\n", n0 + 1)
   check(text:find("Gegenstand " .. ID.agility7, 1, true), "die Schriftrolle steht in der Liste")
   check(text:find("Gegenstand " .. ID.mongoose, 1, true), "das Elixier steht in der Liste")
   check(text:find("Als Naechstes", 1, true), "naechster Schritt genannt")
   check(text:find("Flaeschchen", 1, true), "Arten genannt")

   -- jetzt: auch ausserhalb des Kampfes
   W.ClearSent()
   slash("buffs jetzt")
   W.Advance(2)
   eq(#useWhispers(), 1, "'jetzt' sendet auch ausserhalb des Kampfes")
   serverUses(idOf(useWhispers()[1]))

   -- ignorieren / erlauben
   slash("buffs ignorieren " .. W.ItemLink(ID.agility7))
   check(AutoTravel.Cons.IgnoreList()[ID.agility7] == true, "ausgeschlossen")
   n0 = #W.messages
   slash("buffs liste")
   check(table.concat(W.messages, "\n", n0 + 1):find(tostring(ID.agility7), 1, true), "steht in der Liste")
   startFight()
   W.Advance(60)
   for _, t in ipairs(useWhispers()) do
      check(idOf(t) ~= ID.agility7, "die ausgeschlossene Schriftrolle wird nicht benutzt")
   end
   slash("buffs erlauben " .. W.ItemLink(ID.agility7))
   eq(AutoTravel.Cons.IgnoreList()[ID.agility7], nil, "wieder erlaubt")

   -- ohne Selbstmodus und ohne Erlaubnis
   n0 = #W.messages
   B.CustomSlot(1).cons = {}
   slash("buffs jetzt")
   check(table.concat(W.messages, "\n", n0 + 1):find("keine Verbrauchsgueter", 1, true), "Profil erlaubt nichts")
   slash("buffs zuruecksetzen")
   slash("buffs unsinn")
end)

test("/at buffs: ohne bekannte Gegenstaende und mit leeren Taschen", function()
   consBoot(ALL())
   local n0 = #W.messages
   SlashCmdList["AUTOTRAVEL"]("buffs")
   local text = table.concat(W.messages, "\n", n0 + 1)
   check(text:find("nichts, was das Addon kennt", 1, true), "Hinweis bei leeren Taschen")
   check(text:find("Als Naechstes: nichts", 1, true), "nichts zu tun")
   -- Hilfsmittel, die nicht in der Tabelle stehen, werden auch nicht angefasst
   W.Give(ID.recall, 1)
   W.Give(ID.waterBreathing, 1)
   startFight()
   W.Advance(10)
   eq(#useWhispers(), 0, "Scroll of Recall und Wasseratmung bleiben liegen")
end)

test("Taschen: mehrere Staepel und mehrere Taschen werden zusammengezaehlt", function()
   consBoot({ scroll = true })
   W.world.bags[0] = { size = 16 }
   W.world.bags[1] = { size = 16 }
   W.world.bags[0][3] = { id = ID.agility7, count = 2 }
   W.world.bags[1][5] = { id = ID.agility7, count = 3 }
   W.world.bags[1][6] = { id = 12345678, count = 9 }          -- unbekannter Gegenstand
   local stock = AutoTravel.Cons.Scan()
   eq(stock[ID.agility7].count, 5, "zusammengezaehlt")
   check(stock[12345678] == nil, "Unbekanntes wird nicht beachtet")
   startFight()
   eq(awaitUse(5), ID.agility7, "benutzt")
   -- die Pruefung zaehlt ueber alle Staepel: ein Stueck weniger genuegt
   W.world.bags[0][3].count = 1
   W.AddAura("Buff", spellOf(ID.agility7))
   W.Advance(3)
   eq(AutoTravel.Cons.state.total, 1, "als gelungen gezaehlt")
end)

-- ---------------------------------------------------------------------------
-- 11.7: Befunde der dritten Pruefung (Schriftrollen sind EIN Platz, Jaeger, Bewegung, Sperren ...)
-- ---------------------------------------------------------------------------

-- Ein Modell des Servers fuer "u <Link>": UseItemAction::UseItem, Spell::CheckCast und die Regeln der Zauber.
--   * Ein Befehl wartet, solange der Charakter einen Zauber MIT Zauberzeit wirkt (PlayerbotAI::UpdateAI), und
--     wird sonst nach 'delay' Sekunden ausgefuehrt.
--   * Er scheitert still, wenn sich der Charakter bewegt (isMoving: auch FALLEN), wenn er einen Kanalzauber
--     wirkt (sofort, kein Warten), wenn ein Dauerzauber laeuft ('autorepeat': Automatisches Schiessen) oder
--     wenn 'refuse(id)' ihn abweist. Er scheitert auch an der Stufe und an der Abklingzeit: Elixiere und
--     Flaeschchen teilen Kategorie 79 mit 3 s ab der AUSFUEHRUNG, Schriftrollen haben 1 s je Zauber.
--   * Sonst wird ein Stueck verbraucht und der Buff gelegt. Ein neuer Buff VERDRAENGT jeden anderen derselben
--     exklusiven Gruppe: die sechs Schriftrollenwerte (spell_group 1087), Kampfelixiere (Gruppe 1),
--     Waechterelixiere (Gruppe 2; ein Flaeschchen steht in beiden).
--   * Die Runenschriftrolle (49632) hat als Zauber nur ein Script (69377); der Kern wirkt daraus den Buff
--     72590 (ab Stufe 70). Das steht hier FEST und folgt nicht den Daten des Addons.
--   * Ausdauerbuffs (Gruppe 1084) sind Regel 4, "der staerkste gewinnt": mit 'rule4' gilt jeder andere wirkende
--     Ausdauerbuff als staerker. Eine Schriftrolle mit eigenem Aufbau-Zauber wird dann vor dem Verbrauch
--     abgewiesen (AURA_BOUNCED); die Runenschriftrolle ist verbraucht, und ihr Buff wird sofort verworfen.
local function serverModel(o)
   o = o or {}
   local S = { delay = o.delay or 0.4, autorepeat = o.autorepeat, refuse = o.refuse, rule4 = o.rule4,
               queue = {}, seen = #W.sent, executed = {}, refused = {}, catUntil = 0, spellUntil = {} }
   local D, G = AutoTravel.ConsData, AutoTravel.ConsGroups
   local SCRIPT = { [49632] = { aura = 72590, minLevel = 70 } }

   local function groupsOf(spell)
      local g = {}
      for _, d in pairs(D) do
         if d[2] == spell then
            if d[1] == "flask" then g.battle, g.guardian = true, true
            elseif d[1] == "battle" then g.battle = true
            elseif d[1] == "guardian" then g.guardian = true
            elseif d[1] == "scroll" and d[5] ~= "fortitude" then g.scroll = true end
         end
      end
      for _, sp in ipairs(G.battle) do if sp == spell then g.battle = true end end
      for _, sp in ipairs(G.guardian) do if sp == spell then g.guardian = true end end
      return g
   end

   local function inStamina(spell)
      for _, sp in ipairs(G.stamina) do if sp == spell then return true end end
      return false
   end

   -- Wirkt ein anderer Ausdauerbuff (der unter rule4 als staerker gilt)?
   local function strongerStamina(spell)
      if not S.rule4 or not inStamina(spell) then return false end
      for _, a in ipairs(W.world.auras) do
         if a.spellId ~= spell and inStamina(a.spellId) then return true end
      end
      return false
   end

   local function applyBuff(spell)
      local mine = groupsOf(spell)
      for i = #W.world.auras, 1, -1 do
         local other = groupsOf(W.world.auras[i].spellId)
         for k in pairs(mine) do
            if other[k] then table.remove(W.world.auras, i) break end
         end
      end
      W.AddAura("Buff " .. spell, spell)
   end

   local function onCooldown(id, now)
      local d = D[id]
      if SCRIPT[id] then return false end
      if d[1] == "scroll" then return (S.spellUntil[d[2]] or 0) > now end
      return S.catUntil > now
   end

   function S.run(id, now)
      local d = D[id]
      local why
      if W.world.speed > 0 or W.world.falling then why = "bewegt"
      elseif W.world.channel then why = "kanalisiert"
      elseif S.autorepeat then why = "dauerzauber"
      elseif S.refuse and S.refuse(id) then why = "abgewiesen"
      elseif W.CountOf(id) == 0 then why = "nichts da"
      elseif (d[3] or 0) > W.world.level then why = "stufe"
      elseif onCooldown(id, now) then why = "abklingzeit"
      elseif not SCRIPT[id] and strongerStamina(d[2]) then why = "bounce" end
      if why then
         S.refused[#S.refused + 1] = { id = id, why = why, at = now }
         return
      end
      W.TakeOne(id)
      if d[1] == "scroll" then
         if not SCRIPT[id] then S.spellUntil[d[2]] = now + 1.0 end
      else
         S.catUntil = now + 3.0
      end
      local sc = SCRIPT[id]
      if sc then
         -- das Script wirkt den Buff; neben einem staerkeren wird er sofort verworfen
         if W.world.level >= sc.minLevel and not strongerStamina(sc.aura) then applyBuff(sc.aura) end
      else
         applyBuff(d[2])
      end
      S.executed[#S.executed + 1] = { id = id, at = now }
   end

   W.onStep = function(now)
      if S.seen > #W.sent then S.seen = 0 end          -- W.ClearSent() leert die Liste
      while S.seen < #W.sent do
         S.seen = S.seen + 1
         local t = W.sent[S.seen].text
         if t:find("^u ") then S.queue[#S.queue + 1] = { id = idOf(t), due = now + S.delay } end
      end
      local i = 1
      while i <= #S.queue do
         local c = S.queue[i]
         -- ein Zauber mit Zauberzeit haelt den Befehl zurueck; ein Kanalzauber nicht (er wird abgewiesen)
         if now >= c.due and not W.world.casting then
            table.remove(S.queue, i)
            S.run(c.id, now)
         else
            i = i + 1
         end
      end
   end
   return S
end

local function famOf(id) return AutoTravel.ConsData[id][5] end

-- die hoechste Schriftrolle je Wert, die ein Charakter der Stufe 80 tragen darf
local function topScrolls()
   local best = {}
   local D = AutoTravel.ConsData
   for id, d in pairs(D) do
      if d[1] == "scroll" and d[5] ~= "fortitude" and d[3] <= 80 then
         local b = best[d[5]]
         if not b or d[6] > D[b][6] then best[d[5]] = id end
      end
   end
   return best
end

local function messageCount(needle)
   local n = 0
   for _, m in ipairs(W.messages) do if m:find(needle, 1, true) then n = n + 1 end end
   return n
end

test("Verbrauchsgueter: die Gruppen des Servers passen zur Tabelle", function()
   boot()
   local G = AutoTravel.ConsGroups
   check(type(G) == "table" and #G.battle >= 70 and #G.guardian >= 70, "beide Gruppen geladen")
   local battle, guardian = {}, {}
   for _, sp in ipairs(G.battle) do battle[sp] = true end
   for _, sp in ipairs(G.guardian) do guardian[sp] = true end
   for id, d in pairs(AutoTravel.ConsData) do
      if d[1] == "flask" then
         check(battle[d[2]] and guardian[d[2]], "Flaeschchen " .. id .. " steht in beiden Gruppen")
      elseif d[1] == "battle" then
         check(battle[d[2]] and not guardian[d[2]], "Kampfelixier " .. id .. " nur in der Kampfgruppe")
      elseif d[1] == "guardian" then
         check(guardian[d[2]] and not battle[d[2]], "Waechterelixier " .. id .. " nur in der Waechtergruppe")
      end
   end
   check(battle[16323] and battle[10667], "Juju Power und R.O.I.D.S. stehen in der Kampfgruppe")
   check(guardian[24382] and guardian[11319], "Spirit of Zanza und Wasserwandeln stehen in der Waechtergruppe")
   -- die Runenschriftrolle gehoert nicht zu den sechs Werten
   local fort = AutoTravel.ConsData[ID.runescroll]
   eq(fort[5], "fortitude", "Runenschriftrolle der Seelenstaerke")
end)

test("Auswahl: die sechs Werte der Schriftrollen teilen sich EINEN Platz (spell_group 1087)", function()
   boot()
   local list = { [ID.agility7] = 1, [ID.strength8] = 1 }
   local sc = { scroll = true }
   -- Wirkt irgendeine Schriftrolle, ist der Platz belegt: der Server entfernte die alte, wenn eine
   -- zweite eines anderen Werts kaeme, und die alte fehlte wieder.
   eq(decide(list, { spellOf(ID.strength8) }, sc), nil, "Staerke wirkt: keine Beweglichkeit hinterher")
   eq(decide(list, { spellOf(ID.agility7) }, sc), nil, "Beweglichkeit wirkt: keine Staerke hinterher")
   eq(decide(list, { spellOf(ID.agility1) }, sc), nil, "auch eine niedrige Stufe belegt den Platz")
   -- ohne Buff: genau EINE, nach der Vorliebe
   local e, key = decide(list, {}, sc, { stats = { "strength", "agility" } })
   eq(e and e.id, ID.strength8, "Staerke vorn") eq(key, "scroll", "ein Platz")
   e = decide(list, {}, sc, { stats = { "agility", "strength" } })
   eq(e and e.id, ID.agility7, "Beweglichkeit vorn")
   -- fehlt die erste Vorliebe in den Taschen: die naechste
   e = decide({ [ID.strength8] = 1 }, {}, sc, { stats = { "agility", "strength" } })
   eq(e and e.id, ID.strength8, "keine Beweglichkeit da: Staerke")
   -- ein Wert, der nicht in der Liste steht, wird nie benutzt; die Anzeige sagt warum
   local why
   e, _, why = decide({ [ID.strength8] = 1 }, {}, sc, { stats = { "agility", "intellect" } })
   eq(e, nil, "Staerke steht nicht in der Liste")
   check(table.concat(why, "\n"):find("Staerke", 1, true), "der Grund nennt den Wert")
   -- ohne Liste (Tests, Anzeige): alle sechs, nie mehrere
   e = decide(list, {}, sc)
   check(e ~= nil, "ohne Liste gilt jeder Wert")
end)

test("Auswahl: die Runenschriftrolle der Seelenstaerke hat einen eigenen Platz", function()
   boot()
   local list = { [ID.agility7] = 1, [ID.runescroll] = 1 }
   local sc = { scroll = true }
   local st = { stats = { "agility" } }
   local e, key = decide(list, { spellOf(ID.agility7) }, sc, st)
   eq(e and e.id, ID.runescroll, "neben einer Schriftrolle wirkt sie") eq(key, "fortitude", "eigener Platz")
   e = decide(list, { spellOf(ID.runescroll) }, sc, st)
   eq(e and e.id, ID.agility7, "sie belegt den Wertplatz nicht")
   eq(decide(list, { spellOf(ID.agility7), spellOf(ID.runescroll) }, sc, st), nil, "beide wirken")
end)

test("Auswahl: Zauber der Elixiergruppen, die kein Elixier sind (Juju, Zanza, Wasserwandeln), belegen den Platz", function()
   boot()
   local list = { [ID.mongoose] = 1, [ID.mightyFort] = 1, [ID.flaskRage] = 1 }
   local el = { elixir = true }
   -- Juju Power steht in der Kampfgruppe, Spirit of Zanza in der Waechtergruppe
   local e, key = decide(list, { 16323 }, el)
   eq(e and e.id, ID.mightyFort, "Juju Power belegt den Kampfplatz: nur das Waechterelixier") eq(key, "guardian", "Platz")
   e = decide(list, { 24382 }, el)
   eq(e and e.id, ID.mongoose, "Spirit of Zanza belegt den Waechterplatz: nur das Kampfelixier")
   eq(decide(list, { 16323, 24382 }, el), nil, "beide belegt: nichts")
   -- Wasserwandeln steht nicht in der Tabelle, belegt den Platz aber trotzdem
   eq((decide(list, { 11319 }, el)).id, ID.mongoose, "Wasserwandeln belegt den Waechterplatz")
   -- ein Flaeschchen wuerde das ersetzen
   eq(decide({ [ID.flaskRage] = 1 }, { 16323 }, { flask = true }), nil, "unter Juju kein Flaeschchen")
end)

test("Auswahl: ein Flaeschchen folgt nicht auf ein Elixier, dessen Buff nicht zu sehen war", function()
   boot()
   local fl = { flask = true }
   local st = newState()
   st.slot.battle = { lastUse = 1000, verified = false }
   eq(decide({ [ID.flaskRage] = 1 }, {}, fl, { state = st, now = 1100 }), nil, "das Elixier ist nicht zu sehen: kein Flaeschchen")
   check(decide({ [ID.flaskRage] = 1 }, {}, fl, { state = st, now = 1601 }) ~= nil, "nach zehn Minuten schon")
   st = newState()
   st.slot.guardian = { lastUse = 1000, verified = false }
   eq(decide({ [ID.flaskRage] = 1 }, {}, fl, { state = st, now = 1100 }), nil, "ebenso nach einem Waechterelixier")
   st = newState()
   st.slot.battle = { lastUse = 1000, verified = true }
   check(decide({ [ID.flaskRage] = 1 }, {}, fl, { state = st, now = 1100 }) ~= nil, "war der Buff zu sehen: gilt nur der Abstand von 45 s")
end)

test("Auswahl: ein Verbuendeter als Ziel haelt Schriftrollen zurueck, Elixiere nicht", function()
   boot()
   local list = { [ID.agility7] = 1, [ID.runescroll] = 1, [ID.mongoose] = 1 }
   local all = ALL()
   local e = decide(list, {}, all, { friendly = true, stats = { "agility" } })
   eq(e and e.id, ID.mongoose, "das Elixier ist ein Zauber auf sich selbst")
   eq(decide(list, { spellOf(ID.mongoose) }, all, { friendly = true, stats = { "agility" } }), nil,
      "Schriftrolle und Runenschriftrolle warten")
   e = decide(list, { spellOf(ID.mongoose) }, all, { friendly = false, stats = { "agility" } })
   eq(e and e.id, ID.agility7, "ohne Verbuendeten kommt die Schriftrolle")
end)

test("Auswahl: nach dem Kampf nur das Nachzuholende, nur Klassen ohne Kampfbenutzung alles", function()
   boot()
   local list = { [ID.mongoose] = 1, [ID.agility7] = 1 }
   local all = ALL()
   local st = newState()
   eq(decide(list, {}, all, { state = st, mode = "after", stats = { "agility" } }), nil, "nichts nachzuholen")
   local e = decide(list, {}, all, { state = st, mode = "after", afterAll = true, stats = { "agility" } })
   eq(e and e.id, ID.mongoose, "afterAll: alles kommt nach dem Kampf dran")
   st.peace[ID.mongoose] = 1000
   e = decide(list, {}, all, { state = st, mode = "after", stats = { "agility" }, now = 1010 })
   eq(e and e.id, ID.mongoose, "nur das, was im Kampf nicht ging")
   -- im Kampf: ein gemerkter Gegenstand ist raus, bis die Frist verstrichen ist
   e = decide(list, {}, all, { state = st, mode = "combat", stats = { "agility" }, now = 1010 })
   eq(e and e.id, ID.agility7, "im Kampf nur der andere")
   e = decide(list, {}, all, { state = st, mode = "combat", stats = { "agility" }, now = 1000 + AutoTravel.Cons.PEACE_DECAY + 1 })
   eq(e and e.id, ID.mongoose, "nach der Frist wieder im Kampf")
end)

test("Schriftrollen: der Wert richtet sich nach Klasse und Talentbaum, '/at buffs wert' ueberschreibt", function()
   boot()
   local B, C = AutoTravel.Bot, AutoTravel.Cons
   local function stats(class, talents)
      W.world.class = class
      W.world.talents = talents or { 0, 0, 0 }
      local list, source = C.PreferredStats()
      return table.concat(list, ","), source
   end
   eq((stats("MAGE")), "intellect,stamina,spirit", "Magier")
   eq((stats("WARLOCK")), "intellect,stamina,spirit", "Hexenmeister")
   eq((stats("PRIEST")), "intellect,spirit,stamina", "Priester")
   eq((stats("ROGUE")), "agility,stamina,protection", "Schurke")
   eq((stats("HUNTER")), "agility,stamina,protection", "Jaeger")
   eq((stats("DEATHKNIGHT")), "strength,stamina,protection", "Todesritter")
   eq((stats("WARRIOR")), "strength,stamina,protection", "Krieger ohne Talentpunkte")
   eq((stats("WARRIOR", { 31, 5, 0 })), "strength,stamina,protection", "Waffen")
   eq((stats("WARRIOR", { 5, 10, 31 })), "stamina,strength,protection", "Schutzkrieger")
   eq((stats("PALADIN", { 31, 0, 0 })), "intellect,strength,stamina,protection", "Heiliger Paladin")
   eq((stats("PALADIN", { 0, 31, 0 })), "stamina,strength,intellect,protection", "Schutzpaladin")
   eq((stats("PALADIN", { 0, 0, 31 })), "strength,intellect,stamina,protection", "Vergeltungspaladin")
   eq((stats("SHAMAN", { 31, 0, 0 })), "intellect,agility,stamina", "Elementarschamane")
   eq((stats("SHAMAN", { 0, 31, 0 })), "agility,intellect,stamina", "Verstaerker")
   eq((stats("DRUID", { 31, 0, 0 })), "intellect,agility,stamina", "Gleichgewicht")
   eq((stats("DRUID", { 0, 31, 0 })), "agility,intellect,stamina", "Wilder Kampf")
   -- Gleichstand: der erste Baum, wie beim Server
   eq((stats("PALADIN", { 20, 20, 20 })), "intellect,strength,stamina,protection", "Gleichstand: erster Baum")
   local _, source = stats("MAGE")
   eq(source, "Klasse", "Quelle: Klasse")
   _, source = stats("PALADIN", { 0, 0, 31 })
   eq(source, "Klasse und Talentbaum", "Quelle: Klasse und Talentbaum")
   -- unbekannte Klasse: Werte, die jedem helfen
   local list
   list, source = (function() W.world.class = "GNOME" return C.PreferredStats() end)()
   eq(table.concat(list, ","), "stamina,protection", "unbekannte Klasse")
   eq(source, "Klasse unbekannt", "Quelle: unbekannt")

   -- Ueberschreiben
   W.world.class = "MAGE"
   B.Global().consStat = "spirit"
   list, source = C.PreferredStats()
   eq(table.concat(list, ","), "spirit", "eingestellter Wert") eq(source, "eingestellt", "Quelle: eingestellt")
   B.Global().consStat = "fortitude"                  -- keiner der sechs
   eq(table.concat((C.PreferredStats()), ","), "intellect,stamina,spirit", "fortitude gilt nicht")
   B.Global().consStat = 5
   eq(table.concat((C.PreferredStats()), ","), "intellect,stamina,spirit", "beschaedigter Eintrag gilt nicht")
   B.Global().consStat = nil
end)

test("/at buffs wert: Anzeige, einstellen, Umlaute, englische Namen, auto, Unsinn", function()
   local B = consBoot(ALL(), "MAGE")
   local slash = SlashCmdList["AUTOTRAVEL"]
   local function say(cmd)
      local n0 = #W.messages
      slash(cmd)
      return table.concat(W.messages, "\n", n0 + 1)
   end
   check(say("buffs wert"):find("Intelligenz, Ausdauer, Willenskraft", 1, true), "ohne Wert: die Auswahl der Klasse")
   check(say("buffs wert staerke"):find("Staerke", 1, true), "gesetzt")
   eq(B.Global().consStat, "strength", "gespeichert: Staerke")
   eq(table.concat((AutoTravel.Cons.PreferredStats()), ","), "strength", "gilt")
   slash("buffs wert Willenskraft")
   eq(B.Global().consStat, "spirit", "Willenskraft")
   -- Umlaute, wie sie der Client schickt (UTF-8): der Wert muss sich vom vorigen unterscheiden
   slash("buffs wert St\195\164rke")
   eq(B.Global().consStat, "strength", "Umlaut: Staerke")
   slash("buffs wert R\195\188stung")
   eq(B.Global().consStat, "protection", "Umlaut: Ruestung")
   slash("buffs wert agility")
   eq(B.Global().consStat, "agility", "englischer Name")
   slash("buffs wert Schutz")
   eq(B.Global().consStat, "protection", "Schutz")
   local text = say("buffs wert unsinn")
   check(text:find("Unbekannter Wert", 1, true), "Unsinn wird gemeldet")
   eq(B.Global().consStat, "protection", "und aendert nichts")
   check(say("buffs wert auto"):find("automatisch", 1, true), "auto")
   eq(B.Global().consStat, nil, "auto loescht die Einstellung")
   check(say("buffs"):find("Gewaehlt wird: Intelligenz", 1, true), "/at buffs nennt die Wahl")
end)

test("Im Kampf: sechs Werte in den Taschen, ein Platz: ueber fuenf Kaempfe wird genau eine Schriftrolle verbraucht", function()
   consBoot({ scroll = true }, "MAGE")
   local server = serverModel()
   local top = topScrolls()
   local total = 0
   for _, id in pairs(top) do W.Give(id, 20) total = total + 20 end
   check(total == 120, "sechs Werte zu je 20 Stueck")
   for _ = 1, 5 do
      startFight()
      W.Advance(40)
      endFight()
      W.Advance(30)
   end
   eq(#server.executed, 1, "genau eine Schriftrolle")
   eq(famOf(server.executed[1].id), "intellect", "Intelligenz fuer den Magier")
   eq(#server.refused, 0, "nichts abgewiesen")
   local left = 0
   for _, id in pairs(top) do left = left + W.CountOf(id) end
   eq(left, total - 1, "119 uebrig")
   eq(#W.world.auras, 1, "nie mehr als ein Buff auf dem Charakter")
end)

test("Im Kampf: der Buff laeuft aus: wieder genau eine, und zwar vom selben Wert", function()
   consBoot({ scroll = true }, "WARRIOR")
   local server = serverModel()
   local top = topScrolls()
   for _, id in pairs(top) do W.Give(id, 5) end
   startFight()
   W.Advance(30)
   eq(#server.executed, 1, "erste")
   eq(famOf(server.executed[1].id), "strength", "Staerke fuer den Krieger")
   W.world.auras = {}                                  -- 30 Minuten spaeter
   W.Advance(60)
   eq(#server.executed, 2, "zweite")
   eq(famOf(server.executed[2].id), "strength", "wieder Staerke")
   eq(#server.refused, 0, "nichts abgewiesen")
end)

test("Im Kampf: eine fremde Schriftrolle, die schon wirkt, wird nicht ersetzt", function()
   consBoot({ scroll = true }, "WARRIOR")
   local server = serverModel()
   local top = topScrolls()
   for _, id in pairs(top) do W.Give(id, 5) end
   W.AddAura("Willenskraft", spellOf(top.spirit), nil)   -- der Spieler hat selbst eine benutzt
   startFight()
   W.Advance(60)
   eq(#server.executed, 0, "der Platz ist belegt: nichts wird benutzt")
   eq(#useWhispers(), 0, "kein Befehl")
end)

test("Jaeger: im Kampf nichts (Automatisches Schiessen), in den 25 s danach alles", function()
   consBoot(ALL(), "HUNTER")
   local server = serverModel({ autorepeat = true })
   W.Give(ID.mongoose, 1)
   W.Give(ID.agility7, 1)
   startFight()
   W.Advance(60)
   eq(#useWhispers(), 0, "im Kampf wird nichts gesendet")
   eq(#server.refused, 0, "und nichts abgewiesen")
   server.autorepeat = false                           -- der Kampf ist aus, das Schiessen auch
   endFight()
   eq(awaitUse(5), ID.mongoose, "nach dem Kampf geht der erste Befehl hinaus")
   eq(awaitUse(10), ID.agility7, "danach die Schriftrolle")
   W.Advance(10)
   eq(#server.executed, 2, "beide benutzt")
   eq(#server.refused, 0, "nichts abgewiesen")
   -- das Fenster ist begrenzt: ein spaeter dazugekommener Gegenstand wartet auf den naechsten Kampf
   W.Advance(30)                                       -- die 25 s sind um
   W.Give(ID.mightyFort, 1)
   W.Advance(60)
   eq(#useWhispers(), 2, "ausserhalb des Fensters nichts")
   startFight()
   W.Advance(30)
   eq(#useWhispers(), 2, "im naechsten Kampf wieder nichts")
   endFight()
   eq(awaitUse(5), ID.mightyFort, "nach dem naechsten Kampf")
end)

test("Jaeger: '/at buffs' erklaert, warum im Kampf nichts geschieht", function()
   consBoot(ALL(), "HUNTER")
   local n0 = #W.messages
   SlashCmdList["AUTOTRAVEL"]("buffs")
   check(table.concat(W.messages, "\n", n0 + 1):find("Automatische Schiessen", 1, true), "der Grund steht in der Anzeige")
   -- 'jetzt' geht trotzdem: der Spieler entscheidet
   W.Give(ID.mongoose, 1)
   W.ClearSent()
   SlashCmdList["AUTOTRAVEL"]("buffs jetzt")
   W.Advance(2)
   eq(#useWhispers(), 1, "'jetzt' sendet auch beim Jaeger")
end)

test("Im Kampf: solange sich der Charakter bewegt, wird nichts gesendet und kein Fehlschlag gezaehlt", function()
   consBoot({ scroll = true })
   local server = serverModel()
   W.Give(ID.agility7, 2)
   W.world.speed = 7
   startFight()
   W.Advance(60)
   eq(#useWhispers(), 0, "in Bewegung nichts")
   check(next(AutoTravel.Cons.state.item) == nil, "kein Fehlschlag gezaehlt")
   check(next(AutoTravel.Cons.state.peace) == nil, "und nichts als 'geht im Kampf nicht' gemerkt")
   W.world.speed = 0
   eq(awaitUse(5), ID.agility7, "im Stand geht der Befehl hinaus")
   W.Advance(10)
   eq(#server.executed, 1, "benutzt")
   eq(#server.refused, 0, "nichts abgewiesen")
end)

test("Im Kampf: ein Befehl, der ankommt, waehrend der Charakter laeuft, wird abgewiesen und spaeter erneut versucht", function()
   consBoot({ scroll = true })
   local server = serverModel({ delay = 1.0 })
   W.Give(ID.agility7, 2)
   startFight()
   awaitUse(5)
   W.world.speed = 7                                   -- der Charakter laeuft los, bevor der Befehl ankommt
   W.Advance(3)
   W.world.speed = 0
   eq(#server.refused, 1, "abgewiesen: bewegt")
   eq(server.refused[1].why, "bewegt", "Grund")
   W.Advance(20)
   eq(#server.executed, 1, "der naechste Versuch gelingt")
   eq(AutoTravel.Cons.state.total, 1, "als gelungen gezaehlt")
end)

test("Abgewiesen: ein dauerhaft abgewiesener Gegenstand erzeugt nicht bei jedem Kampf Befehle und Meldungen", function()
   consBoot({ scroll = true })
   -- Der Server weist alle Schriftrollen ab (etwa ein staerkerer Buff derselben Art vom Bot selbst)
   local server = serverModel({ refuse = function() return true end })
   W.Give(ID.agility7, 5)
   W.Give(ID.agility4, 5)
   W.Give(ID.agility1, 5)
   for _ = 1, 20 do                                    -- zwanzig Kaempfe in gut 30 Minuten
      startFight()
      W.Advance(40)
      endFight()
      W.Advance(60)
   end
   local n = #server.refused
   -- je Gegenstand hoechstens 3 Versuche im Kampf, 3 danach (erste Sperre), dann je 3 nach jeder weiteren Sperre
   -- (90 s, 5 min, 15 min): 15 in dieser Zeit. Vorher waren es bei jedem Kampf fuenf je Gegenstand.
   check(n >= 3, "es wurde versucht: " .. n)
   check(n <= 3 * 15, "ueber 33 Minuten auf wenige Befehle begrenzt: " .. n)
   local warnings = messageCount("liess sich")
   check(warnings <= 6, "hoechstens eine Meldung je Gegenstand und Art: " .. warnings)
   eq(W.CountOf(ID.agility7), 5, "nichts verbraucht")
   -- die Sperre waechst: die zweite ist laenger als die erste
   check(AutoTravel.Cons.BLOCK_STEPS[2] > AutoTravel.Cons.BLOCK_STEPS[1], "wachsende Pausen")
end)

test("Abgewiesen: eine Sperre waechst mit jeder Wiederholung und endet mit dem ersten Erfolg", function()
   consBoot({ elixir = true })
   local refuse = true
   local server = serverModel({ refuse = function() return refuse end })
   W.Give(ID.mongoose, 3)
   local C = AutoTravel.Cons
   -- im Kampf: drei Fehlschlaege, dann nur noch nach dem Kampf
   startFight()
   W.Advance(40)
   eq(#server.refused, C.MAX_TRIES, "im Kampf so viele Versuche")
   endFight()
   W.Advance(30)
   eq(#server.refused, 2 * C.MAX_TRIES, "nach dem Kampf so viele weitere")
   local it = C.state.item[ID.mongoose]
   eq(it and it.blocks, 1, "erste Sperre")
   check(it.blockedUntil - W.now > C.BLOCK_STEPS[1] - 40 and it.blockedUntil - W.now <= C.BLOCK_STEPS[1], "Dauer der ersten Sperre")

   -- nach der Sperre noch einmal: die zweite ist laenger
   W.Advance(C.BLOCK_STEPS[1] + 1)
   startFight() W.Advance(5) endFight()
   W.Advance(30)
   it = C.state.item[ID.mongoose]
   eq(it and it.blocks, 2, "zweite Sperre")
   check(it.blockedUntil - W.now > C.BLOCK_STEPS[1], "die zweite Sperre ist laenger als die erste")

   -- der Server nimmt ihn an: Erfolg setzt alles zurueck
   refuse = false
   W.Advance(C.BLOCK_STEPS[2] + 1)
   startFight() W.Advance(5) endFight()
   eq(awaitUse(10) ~= nil, true, "wieder versucht")
   W.Advance(15)
   eq(#server.executed, 1, "diesmal angenommen")
   eq(C.state.item[ID.mongoose], nil, "Zaehler und Sperren sind zurueckgesetzt")
end)

test("Verzoegert: fuehrt der Server den Befehl erst nach einigen Sekunden aus, wird nicht doppelt benutzt", function()
   consBoot({ scroll = true })
   local server = serverModel({ delay = 5.5 })        -- der Charakter zauberte: der Befehl wartete auf das Ende
   W.Give(ID.agility7, 3)
   startFight()
   W.Advance(40)
   eq(#server.executed, 1, "ein Stueck verbraucht")
   eq(W.CountOf(ID.agility7), 2, "zwei uebrig")
   eq(#useWhispers(), 1, "ein Befehl")
end)

test("Im Kampf: ein Verbuendeter als Ziel haelt die Schriftrolle zurueck, das Elixier geht hinaus", function()
   consBoot({ scroll = true, elixir = true })
   local server = serverModel()
   W.Give(ID.agility7, 1)
   W.Give(ID.mongoose, 1)
   W.world.target = { friend = true, self = false }
   startFight()
   eq(awaitUse(5), ID.mongoose, "das Elixier wirkt auf den Charakter selbst")
   W.Advance(30)
   eq(#useWhispers(), 1, "die Schriftrolle wartet")
   W.world.target = { friend = true, self = true }    -- man selbst: das ist kein Hindernis
   eq(awaitUse(10), ID.agility7, "man selbst ausgewaehlt: sie geht hinaus")
   W.Advance(10)
   eq(#server.executed, 2, "beide benutzt")
   -- ein Feind als Ziel ist ebenfalls kein Hindernis
   W.world.auras = {}
   W.world.target = { friend = false, self = false }
   W.Give(ID.agility7, 1)
   eq(awaitUse(60), ID.agility7, "ein Feind als Ziel: kein Hindernis")
end)

test("Im Kampf: eine verbrauchte Schriftrolle, die an einen Verbuendeten ging, sperrt den Platz zehn Minuten", function()
   consBoot({ scroll = true })
   W.Give(ID.agility7, 3)
   startFight()
   eq(awaitUse(5), ID.agility7, "erste")
   serverUses(ID.agility7, false)                      -- verbraucht, aber kein Buff auf dem Charakter
   W.Advance(60)
   eq(#useWhispers(), 1, "keine zweite innerhalb der Pause")
   eq(messageCount("Buff ist nicht zu sehen"), 1, "eine Warnung")
end)

test("Ohne Zauberkennung des Clients: der Name genuegt, auch im ganzen Ablauf", function()
   consBoot({ scroll = true, elixir = true })
   local server = serverModel()
   W.world.noSpellIds = true
   W.Give(ID.agility7, 3)
   W.Give(ID.mongoose, 3)
   for _, id in ipairs({ ID.agility7, ID.mongoose }) do
      W.world.spells[spellOf(id)] = { "Buff " .. spellOf(id), "Symbol" }
   end
   startFight()
   W.Advance(60)
   eq(#server.executed, 2, "je ein Stueck, keine Wiederholung")
   eq(AutoTravel.Cons.state.total, 2, "beide als gelungen mit sichtbarem Buff")
   check(AutoTravel.Cons.state.slot.scroll and AutoTravel.Cons.state.slot.scroll.verified == true, "der Name wurde als Buff erkannt")
   eq(#server.refused, 0, "nichts abgewiesen")
end)

test("Im Kampf: ein Juju, das den Platz belegt, wird nicht durch ein Elixier ersetzt", function()
   consBoot({ elixir = true })
   local server = serverModel()
   W.Give(ID.mongoose, 2)
   W.AddAura("Juju Power", 16323)                     -- der Spieler hat es selbst benutzt
   startFight()
   W.Advance(40)
   eq(#server.executed, 0, "der Kampfplatz ist belegt: kein Elixier ersetzt es")
   eq(W.CountOf(ID.mongoose), 2, "nichts verbraucht")
end)

test("Editor: ein Haken bei den Verbrauchsguetern sendet das Profil nicht neu, eine Strategie schon", function()
   ready()
   local B = AutoTravel.Bot
   W.ServerLine("SelfBot is now active.")
   B.CustomSlot(1).combat.dps = true
   AutoTravel.Set("Profile", "custom1")
   AutoTravel.ProfileEditor.Select("custom", 1)
   W.Advance(5)
   W.ClearSent()
   local fl = flagBox("cons", "flask")
   fl:SetChecked(true) click(fl)
   W.Advance(5)
   eq(#whispers(), 0, "ein Verbrauchsgut geht den Bot nichts an: nichts gesendet")
   eq(B.CustomSlot(1).cons.flask, true, "aber gespeichert")
   local st = flagBox("combat", "aoe")
   st:SetChecked(true) click(st)
   W.Advance(5)
   check(#whispers() > 0, "eine Strategie wird neu gesendet")
end)

test("/at buffs jetzt: sagt, warum nichts geschieht", function()
   consBoot(ALL())
   W.Give(ID.agility7, 1)
   local slash = SlashCmdList["AUTOTRAVEL"]
   local function say(cmd)
      local n0 = #W.messages
      slash(cmd)
      return table.concat(W.messages, "\n", n0 + 1)
   end
   W.world.speed = 5
   check(say("buffs jetzt"):find("bewegt sich", 1, true), "in Bewegung")
   W.world.speed = 0
   W.world.casting = true
   check(say("buffs jetzt"):find("zaubert", 1, true), "beim Zaubern")
   W.world.casting = false
   W.world.mounted = true
   check(say("buffs jetzt"):find("reitet", 1, true), "auf dem Reittier")
   W.world.mounted = false
   -- die Anzeige nennt das Hindernis ebenfalls
   W.world.speed = 5
   check(say("buffs"):find("Gerade geht nichts: der Charakter bewegt sich", 1, true), "Anzeige: Hindernis")
   W.world.speed = 0
   check(say("buffs jetzt"):find("Versuche:", 1, true), "ohne Hindernis: es wird versucht")
end)

test("Taschen und Anzeige: '/at buffs' zeigt Sperren und 'nur nach dem Kampf', auch mit Zeitstempel", function()
   consBoot({ elixir = true })
   W.Give(ID.mongoose, 1)
   W.Give(ID.mightyAgility, 1)
   AutoTravel.Cons.state.peace[ID.mongoose] = W.now
   AutoTravel.Cons.state.item[ID.mightyAgility] = { tries = 0, blocks = 1, blockedUntil = W.now + 120 }
   local n0 = #W.messages
   SlashCmdList["AUTOTRAVEL"]("buffs")
   local text = table.concat(W.messages, "\n", n0 + 1)
   check(text:find("nur nach dem Kampf", 1, true), "'nur nach dem Kampf' steht da")
   check(text:find("gesperrt noch", 1, true), "die Sperre steht da")
   -- nach der Frist verschwindet die Markierung
   W.Advance(AutoTravel.Cons.PEACE_DECAY + 1)
   n0 = #W.messages
   SlashCmdList["AUTOTRAVEL"]("buffs")
   text = table.concat(W.messages, "\n", n0 + 1)
   check(not text:find("nur nach dem Kampf", 1, true), "nach der Frist nicht mehr")
end)

-- ---------------------------------------------------------------------------
-- 11.7, zweite Runde: Befunde der vierten Pruefung
-- ---------------------------------------------------------------------------

test("Runenschriftrolle: die Tabelle fuehrt den Buff 72590, nicht das Script 69377 des Gegenstands", function()
   boot()
   local d = AutoTravel.ConsData[ID.runescroll]
   eq(d[2], 72590, "der Buff auf dem Charakter")
   local stamina = {}
   for _, sp in ipairs(AutoTravel.ConsGroups.stamina) do stamina[sp] = true end
   check(stamina[72590], "72590 steht in Gruppe 1084 (Ausdauerbuffs)")
   check(stamina[48161] and stamina[48162] and stamina[8099], "Machtwort, Gebet der Seelenstaerke, Schriftrolle der Ausdauer")
   check(not stamina[69377], "69377 ist nur das Script")
end)

test("Auswahl: die Runenschriftrolle wartet, solange irgendein Ausdauerbuff wirkt (der staerkste gewinnt)", function()
   boot()
   local list = { [ID.runescroll] = 1 }
   local sc = { scroll = true }
   local e, key = decide(list, {}, sc)
   eq(e and e.id, ID.runescroll, "ohne Ausdauerbuff wird sie benutzt") eq(key, "fortitude", "Platz")
   for _, sp in ipairs({ 48161, 48162, 8099 }) do          -- Machtwort, Gebet der Seelenstaerke, Schriftrolle der Ausdauer
      local e2, _, why = decide(list, { sp }, sc)
      eq(e2, nil, "Zauber " .. sp .. " wirkt: keine Runenschriftrolle")
      check(table.concat(why, "\n"):find("Ausdauerbuff", 1, true), "der Grund wird genannt")
   end
   local _, _, why = decide(list, { 72590 }, sc)
   eq((decide(list, { 72590 }, sc)), nil, "ihr eigener Buff wirkt: fertig")
   check(table.concat(why, "\n"):find("Runenschriftrolle: wirkt", 1, true), "und als wirkend gemeldet")
   e = decide(list, { 69377 }, sc)
   eq(e and e.id, ID.runescroll, "69377 ist nur das Script und nie ein Buff")
end)

test("Im Kampf: die Runenschriftrolle wirkt ueber ein Script: der Buff 72590 wird erkannt, keine Wiederholung unter dem Buff", function()
   consBoot({ scroll = true })
   local server = serverModel()
   W.Give(ID.runescroll, 6)
   for _ = 1, 12 do                                     -- eine Stunde
      startFight()
      W.Advance(60)
      endFight()
      W.Advance(240)
   end
   eq(#server.executed, 1, "genau eine, solange der Buff wirkt")
   eq(W.CountOf(ID.runescroll), 5, "fuenf uebrig")
   local slot = AutoTravel.Cons.state.slot.fortitude
   check(slot and slot.verified == true, "der Buff war zu sehen")
   eq(messageCount("Buff ist nicht zu sehen"), 0, "keine Warnung")
end)

test("Im Kampf: neben Machtwort: Seelenstaerke bleibt die Runenschriftrolle liegen (der Kern verwuerfe ihren Buff)", function()
   consBoot({ scroll = true })
   local server = serverModel({ rule4 = true })
   W.Give(ID.runescroll, 3)
   W.AddAura("Machtwort: Seelenstaerke", 48161)
   startFight()
   W.Advance(120)
   endFight()
   eq(#server.executed, 0, "nichts verbraucht")
   eq(W.CountOf(ID.runescroll), 3, "drei uebrig")
   eq(#useWhispers(), 0, "kein Befehl")
end)

test("Im Kampf: Runenschriftrolle neben Schriftrolle der Beweglichkeit: beide wirken", function()
   consBoot({ scroll = true }, "ROGUE")
   local server = serverModel({ rule4 = true })
   W.Give(ID.agility7, 1)
   W.Give(ID.runescroll, 1)
   startFight()
   W.Advance(40)
   eq(#server.executed, 2, "beide benutzt")
   local seen = {}
   for _, a in ipairs(W.world.auras) do seen[a.spellId] = true end
   check(seen[spellOf(ID.agility7)] and seen[72590], "beide Buffs liegen auf dem Charakter")
end)

test("Im Kampf: Fallen und Kanalzauber halten den Befehl zurueck", function()
   consBoot({ scroll = true })
   W.Give(ID.agility7, 1)
   startFight()
   W.world.falling = true
   W.Advance(20)
   eq(#useWhispers(), 0, "waehrend des Fallens nichts")
   W.world.falling = false
   W.world.channel = true
   W.Advance(20)
   eq(#useWhispers(), 0, "waehrend eines Kanalzaubers nichts")
   W.world.channel = false
   eq(awaitUse(5), ID.agility7, "danach geht es los")
end)

test("Im Kampf: ein Kanalzauber, der beginnt, waehrend der Befehl unterwegs ist, zaehlt nicht als Fehlschlag", function()
   consBoot({ scroll = true })
   local server = serverModel({ delay = 1.0 })
   W.Give(ID.agility7, 2)
   startFight()
   awaitUse(5)
   W.world.channel = true                               -- der Charakter beginnt einen Kanalzauber: der Server weist ab
   W.Advance(2.5)
   W.world.channel = false
   eq(#server.refused, 1, "abgewiesen")
   eq(server.refused[1].why, "kanalisiert", "wegen des Kanalzaubers")
   W.Advance(AutoTravel.Cons.VERIFY_UNTIL - 2.5 + 0.7)   -- die Geduld ist gerade abgelaufen, der neue Versuch noch nicht zu sehen
   local it = AutoTravel.Cons.state.item[ID.agility7]
   eq(it and it.tries, 0, "kein Fehlschlag gezaehlt")
   eq(it and it.unclear, 1, "als unklar vermerkt")
   check(next(AutoTravel.Cons.state.peace) == nil, "und nichts als 'im Kampf geht es nicht' gemerkt")
   W.Advance(15)
   eq(#server.executed, 1, "der naechste Versuch gelingt")
   eq(AutoTravel.Cons.state.item[ID.agility7], nil, "Zaehler zurueckgesetzt")
end)

test("Im Kampf: immer wieder unklare Versuche zaehlen irgendwann doch als Fehlschlag", function()
   consBoot({ scroll = true })
   serverModel({ delay = 0.3, refuse = function() return true end })
   W.Give(ID.agility7, 2)
   startFight()
   local C = AutoTravel.Cons
   for _ = 1, C.MAX_UNCLEAR do
      awaitUse(30)
      W.world.speed = 5                                  -- gleich nach dem Senden bewegt sich der Charakter
      W.Advance(C.VERIFY_UNTIL + 1)
      W.world.speed = 0
   end
   local it = C.state.item[ID.agility7]
   eq(it and it.tries, 1, "der fuenfte unklare Versuch zaehlte als Fehlschlag")
   eq(it and it.unclear, 0, "die Reihe ist zurueckgesetzt")
end)

test("Im Kampf: ein Befehl, der hinter einem Zauber wartet, wird danach ausgefuehrt und nicht doppelt gesendet", function()
   consBoot({ scroll = true })
   local server = serverModel()
   W.Give(ID.agility7, 3)
   startFight()
   awaitUse(5)
   W.world.casting = true                               -- ein Zauber mit Zauberzeit: der Befehl wartet
   W.Advance(5)
   eq(#server.executed, 0, "noch nicht ausgefuehrt")
   W.world.casting = false
   W.Advance(20)
   eq(#server.executed, 1, "danach ausgefuehrt")
   eq(#useWhispers(), 1, "es blieb bei einem Befehl")
   eq(AutoTravel.Cons.state.total, 1, "als gelungen gezaehlt")
end)

test("Abklingzeit: wird der erste Befehl verzoegert ausgefuehrt, wartet der naechste die Abklingzeit der Kategorie ab", function()
   consBoot({ elixir = true })
   local server = serverModel()
   W.Give(ID.mongoose, 1)
   W.Give(ID.mightyFort, 1)
   startFight()
   awaitUse(5)
   W.world.casting = true                               -- der erste Befehl wartet auf das Ende des Zaubers
   W.Advance(1.5)
   W.world.casting = false
   W.Advance(30)
   eq(#server.executed, 2, "beide Elixiere benutzt")
   eq(#server.refused, 0, "keines wegen der Abklingzeit abgewiesen")
   local gap = server.executed[2].at - server.executed[1].at
   check(gap >= 3.0, "mindestens die Abklingzeit der Kategorie dazwischen: " .. gap)
end)

test("Abklingzeit: Elixier und Flaeschchen teilen die Kategorie, eine Schriftrolle hat ihre eigene", function()
   consBoot({ elixir = true, scroll = true })
   local server = serverModel()
   W.Give(ID.mongoose, 1)
   W.Give(ID.agility7, 1)
   startFight()
   W.Advance(30)
   eq(#server.executed, 2, "beides benutzt")
   eq(#server.refused, 0, "nichts abgewiesen")
end)

test("/at buffs jetzt: nennt auch die Gruende der Auswahl und den Mindestabstand", function()
   consBoot(ALL(), "ROGUE")
   W.Give(ID.agility7, 1)
   local slash = SlashCmdList["AUTOTRAVEL"]
   local function say(cmd)
      local n0 = #W.messages
      slash(cmd)
      return table.concat(W.messages, "\n", n0 + 1)
   end
   W.world.target = { friend = true, self = false }
   check(say("buffs jetzt"):find("Verbuendeter", 1, true), "ein Verbuendeter ist ausgewaehlt")
   W.world.target = nil
   W.AddAura("Buff", spellOf(ID.agility7))
   check(say("buffs jetzt"):find("eine wirkt bereits", 1, true), "der Platz ist belegt")
   W.RemoveAura(spellOf(ID.agility7))
   -- ein Befehl ist unterwegs
   W.world.speed = 0
   local text = say("buffs jetzt")
   check(text:find("Versuche:", 1, true), "es wird versucht")
   text = say("buffs jetzt")
   check(text:find("unterwegs", 1, true), "ein Befehl ist noch unterwegs")
   -- nach dem Erfolg: der Mindestabstand
   W.Advance(3)
   serverUses(ID.agility7)
   W.Advance(2)
   W.RemoveAura(spellOf(ID.agility7))
   W.Give(ID.agility7, 1)
   check(say("buffs jetzt"):find("Mindestabstand", 1, true), "der Mindestabstand wird genannt")
end)

-- Luecken, die eingebaute Fehler offen gelegt haben -----------------------------------------------

test("Taschen: auch die fuenfte Tasche (Nummer 4) wird gelesen", function()
   consBoot({ scroll = true })
   W.world.bags[4] = { size = 12 }
   W.world.bags[4][12] = { id = ID.agility7, count = 1 }
   eq(AutoTravel.Cons.Scan()[ID.agility7] and AutoTravel.Cons.Scan()[ID.agility7].count, 1, "der Gegenstand in Tasche 4")
   startFight()
   eq(awaitUse(5), ID.agility7, "wird benutzt")
end)

test("Buffs: auch der vierzigste Buff wird gelesen, und ein Buff ohne Ablaufzeit zaehlt", function()
   boot()
   for i = 1, 39 do W.AddAura("Fremder Buff " .. i, 900000 + i) end
   W.AddAura("Buff", 31337, 0)                          -- Ablaufzeit 0: kein Ablauf (Flaeschchen, Auren)
   local a = AutoTravel.Cons.Auras()
   check(a.ids[31337] ~= nil, "der vierzigste Buff mit Ablaufzeit 0 ist erkannt")
   check(a.ids[900001] ~= nil and a.ids[900039] ~= nil, "und die davor")
   eq(a.hasIds, true, "Kennungen vorhanden")
   -- ein Flaeschchen ohne Ablaufzeit gilt als wirkend
   W.world.auras = {}
   W.AddAura("Flask of Endless Rage", spellOf(ID.flaskRage), 0)
   eq(decide({ [ID.flaskRage] = 1 }, {}, { flask = true }, { }) ~= nil, true, "ohne Buff wird es benutzt")
   check(AutoTravel.Cons.Auras().ids[spellOf(ID.flaskRage)], "der Buff mit Ablaufzeit 0 ist da")
end)

test("Ergebnis: ein Fehlschlag wird erkannt, auch wenn andere Buffs mit Kennung da sind", function()
   consBoot({ scroll = true })
   serverModel({ refuse = function() return true end })
   W.AddAura("Fremder Buff", 900001)                    -- der Client liefert Kennungen
   W.Give(ID.agility7, 1)
   startFight()
   local C = AutoTravel.Cons
   for _ = 1, C.MAX_TRIES do awaitUse(C.VERIFY_UNTIL + 4) end
   W.Advance(C.VERIFY_UNTIL + 1)
   eq(W.CountOf(ID.agility7), 1, "nichts verbraucht")
   eq(C.state.total, 0, "nichts als gelungen gezaehlt")
   check(C.state.peace[ID.agility7] ~= nil, "als 'geht im Kampf nicht' gemerkt")
end)

test("Ergebnis: ein Buff ohne weniger Stueck genuegt (der Bestand wird verzoegert aktualisiert)", function()
   consBoot({ scroll = true })
   W.Give(ID.agility7, 2)
   startFight()
   eq(awaitUse(5), ID.agility7, "benutzt")
   W.AddAura("Buff", spellOf(ID.agility7))              -- nur der Buff, die Zahl bleibt noch
   W.Advance(3)
   eq(AutoTravel.Cons.state.total, 1, "als gelungen gezaehlt")
   eq(AutoTravel.Cons.state.item[ID.agility7], nil, "kein Fehlschlag")
   eq(messageCount("Buff ist nicht zu sehen"), 0, "keine Warnung: der Buff war zu sehen")
end)

test("Ergebnis: eine gelungene Benutzung geht in die Obergrenze ein", function()
   consBoot({ scroll = true })
   W.Give(ID.agility7, 2)
   startFight()
   awaitUse(5)
   serverUses(ID.agility7)
   W.Advance(3)
   eq(#AutoTravel.Cons.state.uses, 1, "eine Benutzung vermerkt")
end)

test("Flaeschchen: ein wirkendes Waechterelixier haelt das Flaeschchen ab, ebenso ein Kampfelixier", function()
   boot()
   local fl = { flask = true }
   eq(decide({ [ID.flaskRage] = 1 }, { spellOf(ID.mightyFort) }, fl), nil, "Waechterelixier wirkt")
   eq(decide({ [ID.flaskRage] = 1 }, { spellOf(ID.mongoose) }, fl), nil, "Kampfelixier wirkt")
   check(decide({ [ID.flaskRage] = 1 }, {}, fl) ~= nil, "ohne beides: das Flaeschchen")
end)

test("Ergebnis: ohne Zauberkennung gilt der Name -- aber nur der richtige", function()
   boot()
   W.world.noSpellIds = true
   W.world.spells[spellOf(ID.mongoose)] = { "Mongoose", "Symbol" }
   W.AddAura("Mongoose", spellOf(ID.mongoose))
   W.AddAura("Anderer Name", spellOf(ID.mightyFort))
   local a = AutoTravel.Cons.Auras()
   eq(a.hasIds, false, "der Client liefert keine Kennungen")
   check(a.names["Mongoose"] and a.names["Anderer Name"], "die Namen sind da")
   -- Das Elixier mit dem Namen wirkt; das mit dem unbekannten Namen nicht
   local e = AutoTravel.Cons.Decide({ [ID.mongoose] = { id = ID.mongoose, link = "x", count = 1, d = AutoTravel.ConsData[ID.mongoose] } },
                                    a, { level = 80, wanted = { elixir = true }, ignore = {}, state = newState(), now = 1000 })
   eq(e, nil, "Kampfplatz belegt (Name stimmt)")
   -- ein Buff mit einem Namen, der zu keinem Zauber der Gruppe gehoert, belegt den Platz nicht
   e = AutoTravel.Cons.Decide({ [ID.mightyAgility] = { id = ID.mightyAgility, link = "x", count = 1, d = AutoTravel.ConsData[ID.mightyAgility] } },
                              { ids = {}, names = { ["Etwas ganz anderes"] = true }, hasIds = false },
                              { level = 80, wanted = { elixir = true }, ignore = {}, state = newState(), now = 1000 })
   check(e ~= nil, "ein fremder Name belegt den Platz nicht")
end)

test("Ereignisse: Tod, Ladebildschirm und ausgeschalteter Selbstmodus verwerfen den unterwegs befindlichen Befehl", function()
   local B = consBoot({ scroll = true })
   local C = AutoTravel.Cons
   W.Give(ID.agility7, 3)
   startFight()
   awaitUse(5)
   check(C.state.pending ~= nil, "ein Befehl ist unterwegs")
   -- Tod
   W.world.dead = true
   W.Fire("PLAYER_DEAD")
   eq(C.state.pending, nil, "Tod: verworfen")
   eq(C.state.item[ID.agility7], nil, "und nicht als Fehlschlag gezaehlt")
   W.world.dead = false
   W.Advance(10)

   -- Ladebildschirm
   C.state.pending = { id = ID.agility7, key = "scroll", link = W.ItemLink(ID.agility7), queuedAt = W.now, sentAt = W.now, countBefore = 3, mode = "combat" }
   C.state.nextAt = W.now + 50
   W.Fire("PLAYER_ENTERING_WORLD")
   eq(C.state.pending, nil, "Ladebildschirm: verworfen")
   eq(C.state.nextAt, 0, "und der Abstand aufgehoben")

   -- Selbstmodus aus
   C.state.pending = { id = ID.agility7, key = "scroll", link = W.ItemLink(ID.agility7), queuedAt = W.now, sentAt = W.now, countBefore = 3, mode = "combat" }
   W.ServerLine("SelfBot is now deactivated.")
   W.Advance(2)
   eq(C.state.pending, nil, "Selbstmodus aus: verworfen")
   eq(B.IsRunning(), false, "Selbstmodus ist aus")
end)

test("Jaeger: '/at buffs jetzt' geht auch im Kampf", function()
   consBoot(ALL(), "HUNTER")
   W.Give(ID.mongoose, 1)
   startFight()
   W.Advance(20)
   eq(#useWhispers(), 0, "von selbst im Kampf nichts")
   SlashCmdList["AUTOTRAVEL"]("buffs jetzt")
   W.Advance(2)
   eq(#useWhispers(), 1, "auf Befehl auch im Kampf")
end)

test("Sperren: die Zahlen, wie sie in der README stehen (3 Versuche, 90 s, 5 min, 15 min, 1 h; 7 s Geduld; 30 min)", function()
   boot()
   local C = AutoTravel.Cons
   eq(C.MAX_TRIES, 3, "drei Versuche")
   eq(table.concat(C.BLOCK_STEPS, ","), "90,300,900,3600", "Sperren")
   eq(C.VERIFY_UNTIL, 7, "Geduld")
   eq(C.PEACE_DECAY, 1800, "eine halbe Stunde")
   eq(C.MAX_UNCLEAR, 5, "fuenf unklare Versuche")
end)

test("Meldungen: die Warnung 'Buff nicht zu sehen' kommt je Gegenstand einmal, auch bei Wiederholung", function()
   consBoot({ scroll = true })
   W.Give(ID.agility7, 4)
   startFight()
   eq(awaitUse(5), ID.agility7, "erste")
   serverUses(ID.agility7, false)
   W.Advance(10)
   eq(messageCount("Buff ist nicht zu sehen"), 1, "eine Warnung")
   eq(awaitUse(700), ID.agility7, "zehn Minuten spaeter die zweite")
   serverUses(ID.agility7, false)
   W.Advance(10)
   eq(messageCount("Buff ist nicht zu sehen"), 1, "weiterhin nur eine")
end)

test("/at buffs: 'stat' ist ein Alias von 'wert', 'zuruecksetzen' loescht Sperren, beschaedigte Einstellung wird ignoriert", function()
   local B = consBoot({ scroll = true }, "MAGE")
   local slash = SlashCmdList["AUTOTRAVEL"]
   slash("buffs stat schutz")
   eq(B.Global().consStat, "protection", "stat wie wert")
   B.Global().consStat = "gibtsnicht"
   eq(table.concat((AutoTravel.Cons.PreferredStats()), ","), "intellect,stamina,spirit", "ein unbekannter Wert wird ignoriert")
   B.Global().consStat = nil
   local C = AutoTravel.Cons
   C.state.item[ID.agility7] = { tries = 2, blocks = 1, blockedUntil = W.now + 500 }
   C.state.peace[ID.agility7] = W.now
   C.state.slot.scroll = { lastUse = W.now, verified = true }
   C.state.warned.x = true
   C.state.uses[1] = W.now
   slash("buffs zuruecksetzen")
   eq(next(C.state.item), nil, "Sperren weg")
   eq(next(C.state.peace), nil, "gemerkte Gegenstaende weg")
   eq(next(C.state.slot), nil, "Mindestabstaende weg")
   eq(next(C.state.warned), nil, "Meldungen duerfen wieder kommen")
   eq(#C.state.uses, 0, "Benutzungen weg")
end)

test("Runenschriftrolle: verbraucht, aber Buff nicht zu sehen: zehn Minuten Pause und eine Warnung", function()
   consBoot({ scroll = true })
   W.Give(ID.runescroll, 4)
   startFight()
   eq(awaitUse(5), ID.runescroll, "erste")
   serverUses(ID.runescroll, false)                      -- verbraucht, kein Buff zu sehen
   W.Advance(10)
   eq(messageCount("Buff ist nicht zu sehen"), 1, "eine Warnung")
   W.Advance(300)
   eq(#useWhispers(), 1, "fuenf Minuten spaeter noch nichts")
   eq(awaitUse(400), ID.runescroll, "nach zehn Minuten wieder")
end)

test("Im Kampf: ein klarer Fehlschlag unterbricht die Reihe unklarer Versuche", function()
   consBoot({ scroll = true })
   W.Give(ID.agility7, 2)
   local C = AutoTravel.Cons
   -- ein Versuch, dessen Geduld gerade abgelaufen ist (nicht im Kampf: es wird nichts Neues gesendet)
   local function attempt(disturbed)
      C.state.pending = { id = ID.agility7, key = "scroll", link = W.ItemLink(ID.agility7), queuedAt = W.now - 9,
                          sentAt = W.now - 8, countBefore = 2, mode = "combat", disturbed = disturbed }
      C.Tick(W.now, false)
   end
   for _ = 1, C.MAX_UNCLEAR - 1 do attempt(true) end    -- vier unklare
   local it = C.state.item[ID.agility7]
   eq(it and it.unclear, C.MAX_UNCLEAR - 1, "vier unklare") eq(it and it.tries, 0, "kein Fehlschlag")
   attempt(false)                                        -- ein klarer Fehlschlag
   it = C.state.item[ID.agility7]
   eq(it and it.tries, 1, "der klare Fehlschlag zaehlt") eq(it and it.unclear, 0, "und beendet die Reihe")
   for _ = 1, C.MAX_UNCLEAR - 1 do attempt(true) end    -- wieder vier unklare
   it = C.state.item[ID.agility7]
   eq(it and it.tries, 1, "sie zaehlen nicht mit den ersten vieren zusammen")
   eq(it and it.unclear, C.MAX_UNCLEAR - 1, "vier unklare in der neuen Reihe")
   attempt(true)                                         -- der fuenfte in dieser Reihe
   it = C.state.item[ID.agility7]
   eq(it and it.tries, 2, "der fuenfte unklare zaehlt doch")
end)

test("Ergebnis: ein gleichnamiger Buff mit anderer Kennung zaehlt nicht als Erfolg", function()
   consBoot({ scroll = true })
   serverModel({ refuse = function() return true end })
   W.world.spells[spellOf(ID.agility7)] = { "Beweglichkeit", "Symbol" }
   W.AddAura("Beweglichkeit", 900001)                    -- etwa vom Elixier: gleicher Name, andere Kennung
   W.Give(ID.agility7, 1)
   startFight()
   local C = AutoTravel.Cons
   for _ = 1, C.MAX_TRIES do awaitUse(C.VERIFY_UNTIL + 4) end
   W.Advance(C.VERIFY_UNTIL + 1)
   eq(C.state.total, 0, "nichts als gelungen gezaehlt")
   check(C.state.peace[ID.agility7] ~= nil, "der Fehlschlag wurde erkannt")
end)

-- ---------------------------------------------------------------------------
-- 11.8: Wartezeit nach dem Kampf in den Einstellungen
-- ---------------------------------------------------------------------------

-- Die Wartezeit, die ein Profil bringt, und die, die der Spieler selbst festlegt.
local function botReady()
   ready()
   W.ServerLine("SelfBot is now active.")
   return AutoTravel.Bot
end

test("Wartezeit: ohne eigene Einstellung gilt der Wert des Profils, und er geht mit dem Profil hinaus", function()
   local B = botReady()
   local cases = { { "normal", 7 }, { "aggressiv", 7 }, { "plus", 7 }, { "verteidigen", 2 },
                   { "minimal", 1.5 }, { "aengstlich", 1.5 } }
   for _, c in ipairs(cases) do
      AutoTravel.Set("Profile", c[1])
      local v, custom = B.EffectiveGrace()
      eq(v, c[2], c[1] .. ": Wert des Profils")
      eq(custom, false, c[1] .. ": nicht selbst festgelegt")
      W.ClearSent()
      B.ApplyProfile()
      W.Advance(15)
      check(W.SentContains(".at set grace " .. c[2]), c[1] .. ": ." .. "at set grace " .. c[2] .. " geht hinaus")
      eq(count(".at set grace"), 1, c[1] .. ": genau einmal")
   end
end)

test("Wartezeit: ein eigenes Profil bringt seine eigene Wartezeit mit", function()
   local B = botReady()
   local c = B.CustomSlot(1)
   c.combat.dps = true
   c.grace = 4.5
   AutoTravel.Set("Profile", "custom1")
   eq((B.EffectiveGrace()), 4.5, "Wert des eigenen Profils")
   W.ClearSent()
   B.ApplyProfile()
   W.Advance(15)
   check(W.SentContains(".at set grace 4.5"), "wird gesendet")
end)

test("Wartezeit: eine selbst festgelegte gilt fuer alle Profile und geht dem Profil vor", function()
   local B = botReady()
   AutoTravel.Set("GraceCustom", 1)
   AutoTravel.Set("GraceSeconds", 3)
   for _, key in ipairs({ "normal", "verteidigen", "minimal" }) do
      AutoTravel.Set("Profile", key)
      local v, custom = B.EffectiveGrace()
      eq(v, 3, key .. ": der eigene Wert") eq(custom, true, key .. ": selbst festgelegt")
      W.ClearSent()
      B.ApplyProfile()
      W.Advance(15)
      check(W.SentContains(".at set grace 3"), key .. ": 3 s gehen hinaus")
      eq(count(".at set grace"), 1, key .. ": genau einmal, nicht zusaetzlich der Wert des Profils")
   end
end)

test("Wartezeit: 0 heisst sofort (der Server liest 0 als 'keine Vorgabe'), Grenzen und beschaedigte Werte", function()
   local B = botReady()
   AutoTravel.Set("GraceCustom", 1)
   local function eff(v)
      AutoTravel.Set("GraceSeconds", v)
      return (B.EffectiveGrace())
   end
   eq(eff(0), 0.1, "0 geht als 0,1 s hinaus, nie als 0")
   eq(eff(-5), 0.1, "negativ")
   eq(eff(99), 30, "ueber 30 s")
   eq(eff("abc"), 2, "keine Zahl: Standard")
   eq(eff(nil), 2, "nichts gespeichert: Standard")
   eq(eff(12.5), 12.5, "Dezimalwert bleibt")
   -- und so geht es an den Server
   AutoTravel.Set("GraceSeconds", 0)
   W.ClearSent()
   B.SendGrace()
   W.Advance(3)
   check(W.SentContains(".at set grace 0.1"), "0,1 s gesendet")
   for _, c in ipairs(W.SentCommands()) do
      check(c ~= ".at set grace 0", "nie 0 an den Server (er liest es als 'keine Vorgabe')")
   end
end)

test("nach dem Handschlag wird die selbst festgelegte Wartezeit erneut gemeldet, die des Profils nicht", function()
   boot()
   AutoTravel.Set("GraceCustom", 1)
   AutoTravel.Set("GraceSeconds", 4)
   W.Advance(3)
   hello()
   W.Advance(2)
   check(W.SentContains(".at set grace 4"), "erneut gesendet")

   boot()
   W.Advance(3)
   hello()
   W.Advance(2)
   eq(count(".at set grace"), 0, "ohne eigene Einstellung bleibt es dem Profil ueberlassen")
end)

test("Einstellungsseite: Haken und Regler fuer die Wartezeit nach dem Kampf", function()
   local B = botReady()
   AutoTravel.Set("Profile", "normal")
   local O = AutoTravel.Options
   O.Load()
   local cb, sl = O.graceCheck, O.graceSlider
   check(cb ~= nil and sl ~= nil, "Haken und Regler sind da")
   eq(cb:GetChecked(), nil, "Standard: es gilt der Wert des Profils")
   eq(sl:GetAlpha(), 0.55, "der Regler ist gedimmt, solange der Haken aus ist")

   -- Haken setzen: der gespeicherte Wert gilt sofort
   W.ClearSent()
   cb:SetChecked(true)
   cb.__scripts.OnClick(cb)
   W.Advance(3)
   eq(AutoTravel.Get("GraceCustom"), 1, "gespeichert")
   check(W.SentContains(".at set grace 2"), "der gespeicherte Wert (Standard 2 s) ging sofort hinaus")
   eq(sl:GetAlpha(), 1, "der Regler ist voll sichtbar")

   -- Regler ziehen: neuer Wert nach der Entprellung
   W.ClearSent()
   sl:SetValue(5)
   W.Advance(1)
   eq(AutoTravel.Get("GraceSeconds"), 5, "Wert gespeichert")
   check(W.SentContains(".at set grace 5"), "5 s gesendet")
   eq(count(".at set grace"), 1, "genau einmal")

   -- Haken weg: zurueck zum Wert des Profils (Normal: 7 s)
   W.ClearSent()
   cb:SetChecked(false)
   cb.__scripts.OnClick(cb)
   W.Advance(3)
   eq(AutoTravel.Get("GraceCustom"), 0, "aus")
   check(W.SentContains(".at set grace 7"), "der Wert des Profils geht wieder hinaus")
   eq(sl:GetAlpha(), 0.55, "Regler wieder gedimmt")
   eq(B.IsRunning(), true, "Selbstmodus unberuehrt")
end)

test("Einstellungsseite: den Regler anzufassen schaltet 'selbst festlegen' ein", function()
   botReady()
   local O = AutoTravel.Options
   O.Load()
   eq(AutoTravel.Get("GraceCustom"), 0, "zunaechst aus")
   O.graceSlider:SetValue(9)
   W.Advance(1)
   eq(AutoTravel.Get("GraceCustom"), 1, "der Regler schaltet es ein")
   eq(AutoTravel.Get("GraceSeconds"), 9, "mit seinem Wert")
   eq(O.graceCheck:GetChecked(), 1, "der Haken folgt")
end)

test("Einstellungsseite: beim Laden aus gespeicherten Werten stimmen Haken, Regler und Text", function()
   boot()
   AutoTravel.Set("GraceCustom", 1)
   AutoTravel.Set("GraceSeconds", 12)
   AutoTravel.Options.Load()
   local O = AutoTravel.Options
   eq(O.graceCheck:GetChecked(), 1, "Haken gesetzt")
   eq(O.graceSlider:GetValue(), 12, "Regler auf 12")
end)

test("/at wartezeit: setzen, Komma, 0, ungueltig, Anzeige und zurueck zum Profil", function()
   local B = botReady()
   AutoTravel.Set("Profile", "normal")
   local slash = SlashCmdList["AUTOTRAVEL"]
   local function say(cmd)
      local n0 = #W.messages
      slash(cmd)
      return table.concat(W.messages, "\n", n0 + 1)
   end

   W.ClearSent()
   check(say("wartezeit 4"):find("4 s", 1, true), "meldet den Wert")
   W.Advance(3)
   eq(AutoTravel.Get("GraceCustom"), 1, "selbst festgelegt")
   eq(AutoTravel.Get("GraceSeconds"), 4, "gespeichert")
   check(W.SentContains(".at set grace 4"), "gesendet")

   W.ClearSent()
   slash("wartezeit 1,5")
   W.Advance(3)
   eq(AutoTravel.Get("GraceSeconds"), 1.5, "Komma wird verstanden")
   check(W.SentContains(".at set grace 1.5"), "als 1.5 gesendet")

   W.ClearSent()
   slash("wartezeit 0")
   W.Advance(3)
   eq(AutoTravel.Get("GraceSeconds"), 0, "0 wird gespeichert")
   check(W.SentContains(".at set grace 0.1"), "und als 0,1 s gesendet, nicht als 0")

   W.ClearSent()
   check(say("wartezeit 31"):find("Verwendung", 1, true), "ueber 30 wird abgelehnt")
   check(say("wartezeit abc"):find("Verwendung", 1, true), "Unsinn wird abgelehnt")
   check(say("wartezeit -2"):find("Verwendung", 1, true), "negativ wird abgelehnt")
   W.Advance(3)
   eq(AutoTravel.Get("GraceSeconds"), 0, "und aendert nichts")
   eq(count(".at set grace"), 0, "und sendet nichts")

   local text = say("wartezeit")
   check(text:find("selbst festgelegt", 1, true), "ohne Angabe: Anzeige")

   W.ClearSent()
   check(say("wartezeit profil"):find("Wert des Profils", 1, true), "zurueck zum Profil")
   W.Advance(3)
   eq(AutoTravel.Get("GraceCustom"), 0, "aus")
   check(W.SentContains(".at set grace 7"), "Normal: 7 s gesendet")
   check(say("wartezeit"):find("Wert des Profils", 1, true), "Anzeige: Wert des Profils")
   eq(B.IsRunning(), true, "Selbstmodus unberuehrt")
end)

test("Profil-Editor: der Hinweis erscheint, wenn die Wartezeit in den Einstellungen festgelegt ist", function()
   ready()
   local P = AutoTravel.ProfileEditor
   P.Select("builtin", "normal")
   check(P.graceNote ~= nil, "Hinweisfeld vorhanden")
   eq(P.graceNote:GetText(), "", "ohne eigene Wartezeit kein Hinweis")
   AutoTravel.Set("GraceCustom", 1)
   AutoTravel.Set("GraceSeconds", 3)
   AutoTravel.Options.Load()
   local t = P.graceNote:GetText()
   check(t:find("Gilt gerade nicht", 1, true), "der Hinweis steht da")
   check(t:find("3 s", 1, true), "mit dem Wert")
   AutoTravel.Set("GraceCustom", 0)
   AutoTravel.Options.Load()
   eq(P.graceNote:GetText(), "", "wieder weg")
   -- auch beim Wechsel des Profils im Editor
   AutoTravel.Set("GraceCustom", 1)
   P.Select("builtin", "plus")
   check(P.graceNote:GetText():find("Gilt gerade nicht", 1, true), "bleibt beim Profilwechsel")
end)

print(string.format("\n%d Pruefungen, %d Fehler", passes, failures))
os.exit(failures == 0 and 0 or 1)
