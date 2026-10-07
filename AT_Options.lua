-- AT_Options.lua
-- ---------------------------------------------------------------------------
-- Einstellungsseite unter Interface -> AddOns -> AutoTravel.
--
-- Alles, was hier steht, laesst sich auch per Slash-Befehl setzen; die Seite
-- ist nur die bequeme Variante.
--
-- Zwei Dinge, die frueher falsch waren:
--
--   * Die Seite reichte weit ueber den sichtbaren Bereich des Optionsfensters
--     hinaus (rund 600 Pixel hoch); alles ab "Teleport" war weder sichtbar noch
--     anklickbar. Jetzt liegt sie in einem ScrollFrame, und die Zeilen werden
--     fortlaufend gezaehlt statt von Hand mit y-Werten belegt.
--
--   * Die Einstellungen zur Navigation gelten fuer den ganzen SERVER, nicht fuer
--     den einzelnen Spieler. Ein normaler Spieler bekam bei jedem Klick eine
--     Absage vom Server. Jetzt sind sie fuer ihn gesperrt und sagen warum.
-- ---------------------------------------------------------------------------

local AT = AutoTravel
AT.Options = {}
local O = AT.Options

local frame, content, gateNote

local WIDTH = 580

-- ---------------------------------------------------------------------------
-- Bausteine
-- ---------------------------------------------------------------------------

local function Header(parent, text, x, y)
   local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
   fs:SetPoint("TOPLEFT", x, y)
   fs:SetText(text)
   fs:SetTextColor(0.35, 0.71, 0.91)

   local line = parent:CreateTexture(nil, "ARTWORK")
   line:SetTexture("Interface\\Buttons\\WHITE8X8")
   line:SetVertexColor(0.25, 0.28, 0.33, 0.8)
   line:SetPoint("TOPLEFT", x, y - 18)
   line:SetWidth(WIDTH - x) line:SetHeight(1)
   return fs
end

local function Note(parent, text, x, y, width)
   local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
   fs:SetPoint("TOPLEFT", x, y)
   fs:SetWidth(width or (WIDTH - x - 10))
   fs:SetJustifyH("LEFT")
   fs:SetText(text)
   return fs
end

local checkCount = 0
local function Check(parent, label, tip, x, y, key, onChange)
   checkCount = checkCount + 1
   local name = "AutoTravelOptCheck" .. checkCount
   local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
   cb:SetPoint("TOPLEFT", x, y)
   cb:SetWidth(24) cb:SetHeight(24)

   local fs = _G[name .. "Text"]
   if fs then
      fs:SetText(label)
      fs:SetFontObject("GameFontHighlightSmall")
   end

   cb.tooltipText = tip
   cb:SetScript("OnEnter", function()
      GameTooltip:SetOwner(cb, "ANCHOR_RIGHT")
      GameTooltip:AddLine(label)
      if tip then GameTooltip:AddLine(tip, 0.7, 0.7, 0.7, true) end
      if cb.serverSide and not AT.Net.Can("SETTINGS") then
         GameTooltip:AddLine(" ")
         GameTooltip:AddLine("Gilt fuer den ganzen Server - nur Spielleiter duerfen das aendern.",
                             0.91, 0.65, 0.29, true)
      end
      GameTooltip:Show()
   end)
   cb:SetScript("OnLeave", function() GameTooltip:Hide() end)

   cb:SetScript("OnClick", function()
      local v = cb:GetChecked() and 1 or 0
      AT.Set(key, v)
      if onChange then onChange(v) end
   end)

   cb.Load = function() cb:SetChecked(AT.GetBool(key)) end
   return cb
end

local sliderCount = 0
local function Slider(parent, label, tip, x, y, minV, maxV, step, key, onChange)
   sliderCount = sliderCount + 1
   local name = "AutoTravelOptSlider" .. sliderCount
   local sl = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
   sl:SetPoint("TOPLEFT", x + 6, y)
   sl:SetWidth(200)
   sl:SetMinMaxValues(minV, maxV)
   sl:SetValueStep(step)

   if _G[name .. "Low"]  then _G[name .. "Low"]:SetText(tostring(minV)) end
   if _G[name .. "High"] then _G[name .. "High"]:SetText(tostring(maxV)) end

   local head = _G[name .. "Text"]
   local function refresh(v)
      if head then head:SetText(label .. ": " .. tostring(v)) end
   end

   -- Entprellung: OnValueChanged feuert bei jeder Mausbewegung. Ohne das
   -- ginge pro Pixel ein Serverbefehl raus.
   sl.pending = nil
   local function commit()
      if not sl.pending then return end
      local v = sl.pending
      sl.pending = nil
      AT.Set(key, v)
      if onChange then onChange(v) end
   end
   sl:SetScript("OnUpdate", function()
      if not sl.pending then return end
      if (GetTime() - sl.pendingAt) < 0.4 then return end
      commit()
   end)
   -- OnUpdate laeuft nicht, solange der Rahmen verborgen ist: wer das
   -- Optionsfenster innerhalb der 0,4 s nach dem Ziehen schliesst, wuerde die
   -- Aenderung verlieren.
   sl:SetScript("OnHide", commit)

   sl:SetScript("OnValueChanged", function()
      local v = math.floor(sl:GetValue() + 0.5)
      refresh(v)
      if sl.loading then return end
      sl.pending = v
      sl.pendingAt = GetTime()
   end)

   sl:SetScript("OnEnter", function()
      GameTooltip:SetOwner(sl, "ANCHOR_RIGHT")
      GameTooltip:AddLine(label)
      if tip then GameTooltip:AddLine(tip, 0.7, 0.7, 0.7, true) end
      if sl.serverSide and not AT.Net.Can("SETTINGS") then
         GameTooltip:AddLine(" ")
         GameTooltip:AddLine("Gilt fuer den ganzen Server - nur Spielleiter duerfen das aendern.",
                             0.91, 0.65, 0.29, true)
      end
      GameTooltip:Show()
   end)
   sl:SetScript("OnLeave", function() GameTooltip:Hide() end)

   sl.Load = function()
      sl.loading = true
      local v = tonumber(AT.Get(key)) or minV
      sl:SetValue(v)
      refresh(math.floor(v + 0.5))
      sl.loading = false
   end
   return sl
end

local editCount = 0
local function Edit(parent, label, x, y, width, key)
   editCount = editCount + 1
   local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
   fs:SetPoint("TOPLEFT", x, y)
   fs:SetText(label)

   local eb = CreateFrame("EditBox", "AutoTravelOptEdit" .. editCount, parent, "InputBoxTemplate")
   eb:SetPoint("TOPLEFT", x + 4, y - 16)
   eb:SetWidth(width) eb:SetHeight(20)
   eb:SetAutoFocus(false)
   eb:SetScript("OnEnterPressed", function()
      AT.Set(key, AT.trim(eb:GetText()))
      eb:ClearFocus()
      AT.Print(label .. " gespeichert.")
   end)
   eb:SetScript("OnEscapePressed", function() eb:ClearFocus() eb.Load() end)
   eb.Load = function() eb:SetText(tostring(AT.Get(key) or "")) end
   return eb
end

-- ---------------------------------------------------------------------------
-- Seite
-- ---------------------------------------------------------------------------

local widgets = {}
local profButtons = {}

local function RefreshProfiles()
   local cur = AT.Bot.Current()
   for _, b in ipairs(profButtons) do
      if b.key == cur.key then
         b:SetBackdropColor(0.16, 0.34, 0.46, 1)
         b:SetBackdropBorderColor(0.35, 0.71, 0.91, 1)
      else
         b:SetBackdropColor(0.13, 0.15, 0.18, 1)
         b:SetBackdropBorderColor(0.26, 0.29, 0.34, 1)
      end
   end
end

-- Serverweite Einstellungen sperren, solange der Server dem Spieler das Aendern
-- nicht erlaubt. Bei unbekanntem Stand (noch kein Handschlag, aelteres Modul)
-- bleiben sie frei: ein Servermodul ohne Faehigkeitsfeld beantwortet die Absage
-- selbst.
local function ApplyGating()
   local allowed = AT.Net.Can("SETTINGS")
   for _, w in ipairs(widgets) do
      if w.serverSide then
         if w.IsObjectType and w:IsObjectType("CheckButton") then
            if allowed then w:Enable() else w:Disable() end
         else
            w:EnableMouse(allowed)
         end
         w:SetAlpha(allowed and 1 or 0.45)
      end
   end
   if gateNote then
      if allowed then gateNote:Hide() else gateNote:Show() end
   end
end

local function ServerSide(w)
   w.serverSide = true
   return w
end

local function Build()
   if frame then return frame end

   frame = CreateFrame("Frame", "AutoTravelOptionsPanel", UIParent)
   frame.name = "AutoTravel"

   -- Der Inhalt liegt in einem ScrollFrame; alle Bausteine haengen an 'content'.
   local sf = CreateFrame("ScrollFrame", "AutoTravelOptionsScroll", frame, "UIPanelScrollFrameTemplate")
   sf:SetPoint("TOPLEFT", 0, -4)
   sf:SetPoint("BOTTOMRIGHT", -28, 4)
   sf:EnableMouseWheel(true)
   sf:SetScript("OnMouseWheel", function(self, delta)
      local bar = _G["AutoTravelOptionsScrollScrollBar"]
      if bar then bar:SetValue(bar:GetValue() - delta * 40) end
   end)

   content = CreateFrame("Frame", "AutoTravelOptionsContent", sf)
   content:SetWidth(WIDTH)
   content:SetHeight(10)          -- wird am Ende auf die tatsaechliche Hoehe gesetzt
   sf:SetScrollChild(content)

   local c = content
   local y = -12                  -- laufende Zeile; wird nach unten gezaehlt

   local function Advance(h) y = y - h end

   local title = c:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
   title:SetPoint("TOPLEFT", 16, y)
   title:SetText("AutoTravel")
   Advance(22)

   local sub = c:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
   sub:SetPoint("TOPLEFT", 16, y)
   sub:SetWidth(WIDTH - 32)
   sub:SetJustifyH("LEFT")
   sub:SetText("Carbonite liefert das Ziel, das Servermodul mod-autotravel den Weg. " ..
               "Alle Einstellungen gelten pro Charakter, ausser den ausdruecklich als " ..
               "serverweit gekennzeichneten.")
   sub:SetTextColor(0.6, 0.63, 0.68)
   Advance(40)

   -- ---- Verbindung ------------------------------------------------------
   Header(c, "Verbindung zum Server", 16, y)
   Advance(28)

   local conn = c:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
   conn:SetPoint("TOPLEFT", 20, y)
   conn:SetWidth(WIDTH - 40)
   conn:SetJustifyH("LEFT")
   O.connText = conn
   Advance(30)

   table.insert(widgets, Check(c, "Servermodul beim Anmelden abfragen",
      "Schickt nach dem Login '.at hello', damit Panel und Einstellungen wissen, was der Server " ..
      "erlaubt. Aus: die Abfrage erfolgt erst beim ersten Start. Ohne das Servermodul " ..
      "antwortet der Server mit 'Es gibt keinen solchen Befehl'; auf Servern mit " ..
      "AllowPlayerCommands = 0 wuerde der Befehl sogar in /sagen erscheinen.",
      16, y, "AutoHello"))

   local hello = AT.UI.Button(c, 150, 22, "Jetzt abfragen", function()
      AT.Net.state = "UNKNOWN"
      AT.Net.Hello()
      AT.Print("Servermodul wird abgefragt ...")
   end)
   hello:SetPoint("TOPLEFT", 350, y - 2)
   Advance(34)

   -- ---- Verhalten -------------------------------------------------------
   Header(c, "Verhalten des Playerbots", 16, y)
   Advance(28)

   for i, p in ipairs(AT.Bot.List()) do
      local col = (i - 1) % 3
      local row = math.floor((i - 1) / 3)
      local b = AT.UI.Button(c, 118, 22, p.name, function()
         AT.Set("Profile", p.key)
         if AT.Bot.active then AT.Bot.ApplyProfile() end
         RefreshProfiles()
         if AT.UI then AT.UI.Update() end
      end)
      b:SetPoint("TOPLEFT", 20 + col * 126, y - row * 26)
      b.key = p.key
      b.tip = function()
         GameTooltip:AddLine(p.name)
         GameTooltip:AddLine(p.desc, 0.7, 0.7, 0.7, true)
         GameTooltip:AddLine(" ")
         if p.customIndex then
            GameTooltip:AddLine("Eigenes Profil - Unterseite 'Eigene Profile'", 0.55, 0.6, 0.68, true)
         else
            GameTooltip:AddLine("co " .. (p.combat or "-"), 0.55, 0.6, 0.68, true)
            GameTooltip:AddLine("nc " .. (p.noncombat or "-"), 0.55, 0.6, 0.68, true)
         end
      end
      table.insert(profButtons, b)
   end
   Advance(math.ceil(#AT.Bot.List() / 3) * 26 + 6)

   Note(c, "AutoTravel sendet selbst keinen Ausruestungs-, Talent- oder Handelsbefehl. " ..
           "'new rpg' wird in jedem Profil abgeschaltet.", 20, y)
   Advance(30)

   table.insert(widgets, Check(c, "Playerbot-Selbstmodus mitsteuern",
      "Schaltet den Selbstmodus beim Start ein. Der Server kann ihn Spielern ohne " ..
      "Spielleiterrechte verweigern (AiPlayerbot.SelfBotLevel).",
      16, y, "BotControl", function() if AT.UI then AT.UI.Update() end end))
   Advance(26)

   table.insert(widgets, Check(c, "Selbstmodus am Reiseende ausschalten",
      "Aus: der Bot bleibt aktiv, wenn das Ziel erreicht ist. Ein: er wird " ..
      "zusammen mit der Reise beendet.",
      16, y, "AutoDisableBot"))

   local edit = AT.UI.Button(c, 160, 22, "Eigene Profile bearbeiten", function()
      AT.ProfileEditor.Open()
   end)
   edit:SetPoint("TOPLEFT", 350, y - 2)
   Advance(28)

   table.insert(widgets, Check(c, "Erbstuecke schuetzen",
      "Angelegte Gegenstaende der Qualitaetsstufe 7 werden ueberwacht. Tauscht der " ..
      "Bot eines aus, wird es automatisch wieder angelegt, solange es in den Taschen " ..
      "liegt. Normale Ausruestung darf der Bot weiterhin frei wechseln.",
      16, y, "GuardHeirlooms", function(v)
         if v == 1 then AT.Gear.Snapshot() end
         if AT.UI then AT.UI.Update() end
      end))

   table.insert(widgets, Check(c, "auch wenn der Bot aus ist",
      "Der Schutz laeuft dauerhaft, nicht nur waehrend einer Reise. Empfohlen, " ..
      "weil der Bot auch ausserhalb einer Reise tauschen kann.",
      300, y, "GuardAlways", function() if AT.UI then AT.UI.Update() end end))
   Advance(40)

   -- ---- Reise -----------------------------------------------------------
   Header(c, "Reise", 16, y)
   Advance(34)

   table.insert(widgets, Slider(c, "Zielradius (yd)",
      "Ab dieser Entfernung gilt das Ziel als erreicht. Gilt nur fuer deine eigene Reise.",
      16, y, 1, 50, 1, "ArriveYards",
      function(v)
         AT.Set("ArriveCustom", 1)
         AT.SetSessionOption("arrival", v)
      end))

   table.insert(widgets, Check(c, "Protokollzeilen im Chat zeigen",
      "Zeigt die rohen [AT]-Zeilen des Servermoduls im Chat. Nur zur Fehlersuche: die " ..
      "Meldungen selbst gibt das Addon ohnehin aus.",
      300, y + 4, "ShowProtocol",
      function(v)
         AT.Set("HideProtocol", (v == 1) and 0 or 1)
      end))
   Advance(46)

   -- ---- Uebergabe -------------------------------------------------------
   Header(c, "Uebergabe an den Spieler", 16, y)
   Advance(28)

   table.insert(widgets, Check(c, "Automatisch zurueckgeben",
      "Haelt der Autopilot an (Kampf oder ausdruecklich uebernommen), faehrt er nach einer " ..
      "Weile ohne Eingabe selbst weiter. Aus: er wartet, bis du auf 'Weiter' klickst. " ..
      "Ein ausdruecklich uebernommener Halt endet nie von selbst; nur die Zeitgrenze des " ..
      "Servers (Standard 15 Minuten) beendet die Reise dann doch.",
      16, y, "AutoResume"))
   Advance(34)

   table.insert(widgets, Slider(c, "Ruhezeit (s)",
      "So lange darfst du nichts tun, bevor der Countdown beginnt. Bewegung, Mausblick, " ..
      "Maustasten, Zaubern, Kampf und offene Fenster zaehlen als Eingabe.",
      16, y, 2, 30, 1, "QuietSeconds"))

   table.insert(widgets, Slider(c, "Countdown (s)",
      "Sichtbarer Countdown vor der Uebernahme. Jede Eingabe bricht ihn ab. 0 = sofort.",
      290, y, 0, 10, 1, "CountdownSeconds"))
   Advance(46)

   Note(c, "Die Steuerung uebernimmst du mit dem Knopf im Panel, einem Mittelklick auf den " ..
           "Minimap-Knopf oder einer Taste (Optionen -> Tastaturbelegung -> AutoTravel).", 20, y)
   Advance(34)

   -- ---- Natuerliche Navigation -----------------------------------------
   Header(c, "Natuerliche Navigation (serverweit)", 16, y)
   Advance(26)

   gateNote = Note(c, "Diese Einstellungen gelten fuer den ganzen Server und sind Spielleitern " ..
                      "vorbehalten. Du siehst hier den Stand deines Addons.", 20, y)
   gateNote:SetTextColor(0.91, 0.65, 0.29)
   Advance(30)

   table.insert(widgets, ServerSide(Check(c,
      "Natuerliche Wege bevorzugen",
      "Bewertet mehrere gueltige NavMesh-Wege. Flache und natuerliche Wege " ..
      "werden gegen steile Berganstiege bevorzugt, solange der Umweg " ..
      "nicht unverhaeltnismaessig gross wird.",
      16, y, "NaturalPathing",
      function(v) AT.SetServerBool("natural", v) end)))

   table.insert(widgets, ServerSide(Check(c,
      "Contour-Probing",
      "Wenn der gewaehlte Weg wie ein Berganstieg aussieht, sucht das " ..
      "Servermodul automatisch links und rechts nach einem Weg um den Berg.",
      300, y, "ContourProbing",
      function(v) AT.SetServerBool("contour", v) end)))
   Advance(38)

   table.insert(widgets, ServerSide(Slider(c,
      "Berg-Hoehengewinn",
      "Hoehengewinn in Yards, ab dem ein Weg als moeglicher Berganstieg behandelt wird.",
      16, y, 5, 50, 1, "ContourTriggerElevation",
      function(v) AT.SetServerNumber("contour_elevation", v) end)))

   table.insert(widgets, ServerSide(Slider(c,
      "Berg-Steigung (%)",
      "Durchschnittliche Steigung, ab der Contour-Probing aktiviert wird.",
      290, y, 5, 50, 1, "ContourTriggerSlope",
      function(v) AT.SetServerNumber("contour_slope", v / 100) end)))
   Advance(46)

   table.insert(widgets, ServerSide(Slider(c,
      "Contour nah (yd)",
      "Erster Suchabstand links und rechts vom direkten Weg.",
      16, y, 50, 250, 10, "ContourNarrowOffset",
      function(v) AT.SetServerNumber("contour_narrow", v) end)))

   table.insert(widgets, ServerSide(Slider(c,
      "Contour weit (yd)",
      "Zweiter, weiterer Suchabstand links und rechts vom direkten Weg.",
      290, y, 100, 400, 10, "ContourWideOffset",
      function(v) AT.SetServerNumber("contour_wide", v) end)))
   Advance(46)

   table.insert(widgets, ServerSide(Slider(c,
      "Max. Contour-Umweg (%)",
      "Maximal erlaubte Contour-Laenge relativ zur direkten Route.",
      16, y, 120, 500, 10, "ContourMaxDistanceFactor",
      function(v) AT.SetServerNumber("contour_factor", v / 100) end)))
   Advance(46)

   Note(c, "Contour-Probing wird nur aktiviert, wenn der normale Weg einen " ..
           "nachhaltigen steilen Anstieg enthaelt. Dadurch entstehen normalerweise " ..
           "keine zusaetzlichen PathGenerator-Abfragen.", 20, y)
   Advance(40)

   -- ---- Teleport --------------------------------------------------------
   Header(c, "Teleport", 16, y)
   Advance(28)

   table.insert(widgets, Check(c,
      "Vor dem Teleport nachfragen",
      "Sicherheitsabfrage, damit der Knopf nicht versehentlich ausloest.",
      16, y, "ConfirmTp"))

   local tpMode = AT.UI.Button(c, 180, 22, "", function()
      AT.Set("TeleportMode", (AT.Get("TeleportMode") == "go") and "module" or "go")
      O.Load()
      if AT.UI then AT.UI.Update() end
   end)
   tpMode:SetPoint("TOPLEFT", 300, y - 2)
   tpMode.tip = function()
      GameTooltip:AddLine("Wie teleportiert wird")
      GameTooltip:AddLine("Modul: das Servermodul springt selbst. Der Server legt fest, ab " ..
                          "welcher Rechtestufe (AutoTravel.TeleportSecurity, Standard Spielleiter).",
                          0.7, 0.7, 0.7, true)
      GameTooltip:AddLine("go xyz: Weltkoordinaten abfragen, dann den GM-Befehl benutzen.",
                          0.7, 0.7, 0.7, true)
   end
   tpMode.Load = function()
      tpMode.label:SetText("Weg: |cffdde2ea" ..
         ((AT.Get("TeleportMode") == "go") and ".go xyz" or "Servermodul") .. "|r")
   end
   table.insert(widgets, tpMode)
   Advance(40)

   -- ---- Anzeige ---------------------------------------------------------
   Header(c, "Anzeige", 16, y)
   Advance(28)

   table.insert(widgets, Check(c, "Panel anzeigen", nil, 16, y, "PanelVisible",
      function() if AT.UI then AT.UI.Refresh() end end))
   table.insert(widgets, Check(c, "Minimap-Knopf", nil, 300, y, "MinimapButton",
      function() if AT.UI then AT.UI.RefreshMinimap() end end))
   Advance(26)

   table.insert(widgets, Check(c, "Botbefehle im Chat verbergen", nil, 16, y, "HideBotCmd"))
   table.insert(widgets, Check(c, "Debug-Ausgaben",
      "Zeigt jeden gesendeten Befehl und die Diagnosemeldungen des Servermoduls.",
      300, y, "Debug",
      function(v) AT.Send("at debug " .. v, { key = "debug" }) end))
   Advance(40)

   -- ---- Playerbot-Befehle ----------------------------------------------
   Header(c, "Playerbot-Befehle", 16, y)
   Advance(28)

   table.insert(widgets, Edit(c, "Selbstmodus einschalten", 16, y, 250, "SelfOnCommand"))
   table.insert(widgets, Edit(c, "Selbstmodus ausschalten", 290, y, 250, "SelfOffCommand"))
   Advance(46)

   Note(c, "'.playerbots bot self' ist ein Umschalter: derselbe Befehl schaltet ein und aus, " ..
           "deshalb steht er in beiden Feldern. Die Schreibweise mit '.playerbots help' pruefen. " ..
           "Enter speichert.", 20, y)
   Advance(50)

   content:SetHeight(-y + 10)

   frame.refresh = function() O.Load() end
   frame.okay    = function() end
   frame.cancel  = function() end

   if InterfaceOptions_AddCategory then
      InterfaceOptions_AddCategory(frame)
   end
   return frame
end

local function ConnectionText()
   local N = AT.Net
   local s = AT.server
   if N.state == "READY" then
      return string.format("|cff53d17averbunden|r  -  Modul %s, Protokoll %d, Kontostufe %d%s",
         s.version, s.proto, s.sec,
         N.Can("SETTINGS") and "  (darf Serveroptionen aendern)" or "")
   elseif N.state == "HELLO" then
      return "|cffe8c44aAnfrage laeuft ...|r"
   elseif N.state == "ABSENT" then
      return "|cffe8654akeine Antwort|r  -  Ist mod-autotravel auf dem Server installiert und aktiv?"
   elseif N.state == "INCOMPATIBLE" then
      return "|cffe8654aModul zu alt|r  -  Version " .. tostring(s.version)
   elseif N.state == "DISABLED" then
      return "|cffe8654amod-autotravel ist serverseitig abgeschaltet.|r"
   end
   return "|cff9099a8noch nicht abgefragt|r"
end

function O.Load()
   if not frame then return end
   for _, w in ipairs(widgets) do
      if w.Load then w.Load() end
   end
   -- Spiegelwert: HideProtocol ist invertiert
   AT.Set("ShowProtocol", AT.GetBool("HideProtocol") and 0 or 1)
   for _, w in ipairs(widgets) do
      if w.Load then w.Load() end
   end
   RefreshProfiles()
   ApplyGating()
   if O.connText then O.connText:SetText(ConnectionText()) end
end

function O.Open()
   Build()
   O.Load()
   if InterfaceOptionsFrame_OpenToCategory then
      InterfaceOptionsFrame_OpenToCategory(frame)
      InterfaceOptionsFrame_OpenToCategory(frame)   -- 3.3.5a braucht zwei Aufrufe
   end
end

function O.Init()
   Build()
   O.Load()
end
