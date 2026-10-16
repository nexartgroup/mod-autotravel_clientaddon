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

print(string.format("\n%d Pruefungen, %d Fehler", passes, failures))
os.exit(failures == 0 and 0 or 1)
