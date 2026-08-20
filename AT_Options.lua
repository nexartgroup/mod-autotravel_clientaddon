-- AT_Options.lua
-- ---------------------------------------------------------------------------
-- Einstellungsseite unter Interface -> AddOns -> AutoTravel.
--
-- Alles, was hier steht, laesst sich auch per Slash-Befehl setzen; die Seite
-- ist nur die bequeme Variante. Werte, die das Servermodul betreffen
-- (Zielradius), werden beim Aendern sofort dorthin gemeldet.
-- ---------------------------------------------------------------------------

local AT = AutoTravel
AT.Options = {}
local O = AT.Options

local frame

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
   line:SetWidth(560) line:SetHeight(1)
   return fs
end

local function Note(parent, text, x, y, width)
   local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
   fs:SetPoint("TOPLEFT", x, y)
   fs:SetWidth(width or 540)
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
      if not tip then return end
      GameTooltip:SetOwner(cb, "ANCHOR_RIGHT")
      GameTooltip:AddLine(label)
      GameTooltip:AddLine(tip, 0.7, 0.7, 0.7, true)
      GameTooltip:Show()
   end)
   cb:SetScript("OnLeave", function() GameTooltip:Hide() end)

   cb:SetScript("OnClick", function()
      AT.Set(key, cb:GetChecked() and 1 or 0)
      if onChange then onChange(cb:GetChecked() and 1 or 0) end
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
   sl:SetScript("OnUpdate", function()
      if not sl.pending then return end
      if (GetTime() - sl.pendingAt) < 0.4 then return end
      local v = sl.pending
      sl.pending = nil
      AT.Set(key, v)
      if onChange then onChange(v) end
   end)

   sl:SetScript("OnValueChanged", function()
      local v = math.floor(sl:GetValue() + 0.5)
      refresh(v)
      if sl.loading then return end
      sl.pending = v
      sl.pendingAt = GetTime()
   end)

   sl:SetScript("OnEnter", function()
      if not tip then return end
      GameTooltip:SetOwner(sl, "ANCHOR_RIGHT")
      GameTooltip:AddLine(label)
      GameTooltip:AddLine(tip, 0.7, 0.7, 0.7, true)
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
   eb.Load = function()
      local v = AT.Get(key)
      if not v or AT.trim(v) == "" then
         -- Leeres Feld hilft niemandem: den Standard sichtbar machen.
         v = (key == "SelfOnCommand") and ".playerbots bot self on"
             or ((key == "SelfOffCommand") and ".playerbots bot self off" or "")
         AT.Set(key, v)
      end
      eb:SetText(tostring(v))
   end
   return eb
end

-- ---------------------------------------------------------------------------
-- Seite
-- ---------------------------------------------------------------------------

local widgets = {}
local profButtons = {}

local function RefreshProfiles()
   local list = AT.Bot.List()
   local cur = AT.Bot.Current()

   for i, b in ipairs(profButtons) do
      local p = list[i]
      b.prof = p
      b.key = p and p.key or nil
      if p then
         b.label:SetText(p.name)
         b:Show()
      else
         b:Hide()
      end
   end

   for _, b in ipairs(profButtons) do
      if b.key and b.key == cur.key then
         b:SetBackdropColor(0.16, 0.34, 0.46, 1)
         b:SetBackdropBorderColor(0.35, 0.71, 0.91, 1)
      else
         b:SetBackdropColor(0.13, 0.15, 0.18, 1)
         b:SetBackdropBorderColor(0.26, 0.29, 0.34, 1)
      end
   end
end

local function Build()
   if frame then return frame end

   local outer = CreateFrame("Frame", "AutoTravelOptionsPanel", UIParent)
   outer.name = "AutoTravel"

   -- Die Seite ist hoeher als der sichtbare Bereich des Interface-Fensters,
   -- deshalb ein Scrollrahmen. Ohne ihn waeren die unteren Abschnitte
   -- abgeschnitten -- genau das Problem, sobald ein eigenes Profil dazukam.
   local scroll = CreateFrame("ScrollFrame", "AutoTravelOptionsScroll", outer,
                              "UIPanelScrollFrameTemplate")
   scroll:SetPoint("TOPLEFT", 4, -8)
   scroll:SetPoint("BOTTOMRIGHT", -28, 8)

   frame = CreateFrame("Frame", "AutoTravelOptionsContent", scroll)
   frame:SetWidth(600)
   frame:SetHeight(790)
   scroll:SetScrollChild(frame)

   local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
   title:SetPoint("TOPLEFT", 16, -16)
   title:SetText("AutoTravel")

   local sub = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
   sub:SetPoint("TOPLEFT", 16, -38)
   sub:SetWidth(560)
   sub:SetJustifyH("LEFT")
   sub:SetText("Carbonite liefert das Ziel, das Servermodul mod-autotravel den Weg. " ..
               "Alle Einstellungen gelten pro Charakter.")
   sub:SetTextColor(0.6, 0.63, 0.68)

   -- ---- Verhalten -------------------------------------------------------
   Header(frame, "Verhalten des Playerbots", 16, -74)

   -- Platz fuer 3 Zeilen a 3 Knoepfe fest reservieren: 6 feste plus bis zu
   -- 3 eigene Profile. Dadurch verrutscht nichts, wenn ein eigenes Profil
   -- dazukommt oder wegfaellt.
   local y = -102
   for i = 1, 9 do
      local col = (i - 1) % 3
      local row = math.floor((i - 1) / 3)
      local b = AT.UI.Button(frame, 118, 22, "", function()
         if not b.key then return end
         AT.Set("Profile", b.key)
         if AT.Bot.IsRunning() then AT.Bot.ApplyProfile() end
         RefreshProfiles()
         if AT.UI then AT.UI.Update() end
      end)
      b:SetPoint("TOPLEFT", 20 + col * 126, y - row * 26)
      b.tip = function()
         if not b.prof then return end
         local p = b.prof
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

   Note(frame, "AutoTravel sendet selbst keinen Ausruestungs-, Talent- oder Handelsbefehl. " ..
               "'new rpg' wird in jedem Profil abgeschaltet.",
        20, -184)

   table.insert(widgets, Check(frame, "Playerbot-Selbstmodus mitsteuern",
      "Schaltet den Selbstmodus beim Start ein und am Ende der Reise wieder aus.",
      16, -210, "BotControl", function() if AT.UI then AT.UI.Update() end end))

   table.insert(widgets, Check(frame, "Selbstmodus am Reiseende ausschalten",
      "Aus: der Bot bleibt aktiv, wenn das Ziel erreicht ist. Ein: er wird " ..
      "zusammen mit der Reise beendet.",
      16, -236, "AutoDisableBot"))

   local edit = AT.UI.Button(frame, 160, 22, "Eigene Profile bearbeiten", function()
      AT.ProfileEditor.Open()
   end)
   edit:SetPoint("TOPLEFT", 250, -234)

   table.insert(widgets, Check(frame, "Erbstuecke schuetzen",
      "Angelegte Gegenstaende der Qualitaetsstufe 7 werden ueberwacht. Tauscht der " ..
      "Bot eines aus, wird es automatisch wieder angelegt, solange es in den Taschen " ..
      "liegt. Normale Ausruestung darf der Bot weiterhin frei wechseln.",
      16, -262, "GuardHeirlooms", function(v)
         if v == 1 then AT.Gear.Snapshot() end
         if AT.UI then AT.UI.Update() end
      end))

   table.insert(widgets, Check(frame, "auch wenn der Bot aus ist",
      "Der Schutz laeuft dauerhaft, nicht nur waehrend einer Reise. Empfohlen, " ..
      "weil der Bot auch ausserhalb einer Reise tauschen kann.",
      250, -262, "GuardAlways", function() if AT.UI then AT.UI.Update() end end))

   -- ---- Spielervorrang --------------------------------------------------
   Header(frame, "Spielervorrang", 16, -296)

   table.insert(widgets, Check(frame, "Eigene Aktionen haben Vorrang",
      "Sobald du selbst etwas tust, pausiert die Reise und macht danach weiter. " ..
      "Erkannt werden eigene Zauber, Gegenstaende bewegen und geoeffnete Fenster " ..
      "(Beute, Haendler, Bank, Post, Handel, Quest, Flugmeister).\n\n" ..
      "Eigenes LAUFEN laesst sich nicht erkennen - weder im Client noch am " ..
      "Server. Dafuer gibt es die Tastenbelegung 'Spielervorrang ein/aus'.",
      16, -324, "PlayerOverride"))

   table.insert(widgets, Slider(frame, "Wartezeit (s)",
      "So lange muss nach der letzten erkannten Aktion Ruhe sein, bis die Reise " ..
      "wieder uebernimmt.",
      250, -324, 2, 30, 1, "OverrideSeconds"))

   table.insert(widgets, Check(frame, "Bewegungstasten abfangen",
      "Waehrend der Fahrt bewirken WASD und Leertaste ohnehin nichts - der " ..
      "Client blockiert die Bewegung, solange das Servermodul steuert. " ..
      "Sie werden deshalb auf den Spielervorrang gelegt: der erste Tastendruck " ..
      "pausiert die Reise und gibt dir die Steuerung zurueck, ab dem zweiten " ..
      "laeufst du normal.",
      250, -348, "GrabMoveKeys", function() AT.Override.UpdateGrab() end))

   table.insert(widgets, Check(frame, "Auch den Bot pausieren",
      "Standard ist aus: angehalten wird nur die Fahrt, denn sie haelt die " ..
      "Steuerung. Der Bot darf weiterkaempfen und heilen, waehrend du umziehst. " ..
      "Ein: der Selbstmodus wird zusaetzlich abgeschaltet und danach wieder " ..
      "eingeschaltet.",
      16, -348, "OverridePausesBot"))

   table.insert(widgets, Check(frame, "Steuerung waehrend der Fahrt abgeben",
      "AN (Standard und noetig): das Servermodul uebernimmt die Steuerung. " ..
      "Waehrend der Fahrt kannst du nicht selbst laufen - zaubern, Gegenstaende " ..
      "benutzen und Ausruestung wechseln geht weiterhin.\n\n" ..
      "AUS: der 3.3.5a-Client ignoriert Splines fuer die Einheit, die er selbst " ..
      "steuert. Der Charakter bewegt sich dann gar nicht. Nur zur Fehlersuche.",
      16, -374, "TakeControl", function(v)
         AT.Send("at set control " .. v)
      end))

   Note(frame, "Tastenbelegung unter Spiel -> Tastatur -> AutoTravel: " ..
               "'Spielervorrang ein/aus' pausiert von Hand, etwa zum Fluechten. " ..
               "Waehrend des Vorrangs wird die Steuerung immer zurueckgegeben, " ..
               "unabhaengig von der Einstellung darueber.",
        20, -400)

   -- ---- Reise -----------------------------------------------------------
   Header(frame, "Reise", 16, -440)

   table.insert(widgets, Slider(frame, "Zielradius (yd)",
      "Ab dieser Entfernung gilt das Ziel als erreicht.",
      16, -472, 1, 50, 1, "ArriveYards", function(v) AT.Send("at set arrival " .. v) end))

   table.insert(widgets, Check(frame, "Ankunft laut melden",
      "Meldungen des Servermoduls im Chat anzeigen statt sie auszublenden.",
      250, -468, "ShowProtocol", function(v) AT.Set("HideProtocol", (v == 1) and 0 or 1) end))

   -- ---- Teleport --------------------------------------------------------
   Header(frame, "Teleport", 16, -516)

   table.insert(widgets, Check(frame, "Vor dem Teleport nachfragen",
      "Sicherheitsabfrage, damit der Knopf nicht versehentlich ausloest.",
      16, -544, "ConfirmTp"))

   local tpMode = AT.UI.Button(frame, 180, 22, "", function()
      AT.Set("TeleportMode", (AT.Get("TeleportMode") == "go") and "module" or "go")
      O.Load()
   end)
   tpMode:SetPoint("TOPLEFT", 250, -542)
   tpMode.tip = function()
      GameTooltip:AddLine("Wie teleportiert wird")
      GameTooltip:AddLine("Modul: das Servermodul springt selbst (kein GM noetig).", 0.7, 0.7, 0.7, true)
      GameTooltip:AddLine("go xyz: Weltkoordinaten abfragen, dann den GM-Befehl benutzen.", 0.7, 0.7, 0.7, true)
   end
   tpMode.Load = function()
      tpMode.label:SetText("Weg: |cffdde2ea" ..
         ((AT.Get("TeleportMode") == "go") and ".go xyz" or "Servermodul") .. "|r")
   end
   table.insert(widgets, tpMode)

   -- ---- Anzeige ---------------------------------------------------------
   Header(frame, "Anzeige", 16, -580)

   table.insert(widgets, Check(frame, "Panel anzeigen", nil, 16, -608, "PanelVisible",
      function() if AT.UI then AT.UI.Refresh() end end))
   table.insert(widgets, Check(frame, "Minimap-Knopf", nil, 250, -608, "MinimapButton",
      function() if AT.UI then AT.UI.RefreshMinimap() end end))
   table.insert(widgets, Check(frame, "Botbefehle im Chat verbergen", nil, 16, -632, "HideBotCmd"))
   table.insert(widgets, Check(frame, "Debug-Ausgaben", "Zeigt jeden gesendeten Befehl und die " ..
      "Diagnosemeldungen des Servermoduls.", 250, -632, "Debug",
      function(v) AT.Send("at debug " .. v) end))

   -- ---- Playerbot-Befehle ----------------------------------------------
   Header(frame, "Playerbot-Befehle", 16, -668)

   table.insert(widgets, Edit(frame, "Selbstmodus einschalten", 16, -696, 250, "SelfOnCommand"))
   table.insert(widgets, Edit(frame, "Selbstmodus ausschalten", 290, -696, 250, "SelfOffCommand"))

   Note(frame, "Genaue Schreibweise mit '.playerbots help' pruefen. Enter speichert.",
        20, -738)

   outer.refresh = function() O.Load() end
   outer.okay    = function() end
   outer.cancel  = function() end
   frame.outer   = outer

   if InterfaceOptions_AddCategory then
      InterfaceOptions_AddCategory(outer)
   end
   return frame
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
end

function O.Open()
   Build()
   O.Load()
   if InterfaceOptionsFrame_OpenToCategory and frame.outer then
      InterfaceOptionsFrame_OpenToCategory(frame.outer)
      InterfaceOptionsFrame_OpenToCategory(frame.outer)   -- 3.3.5a braucht zwei Aufrufe
   end
end

function O.Init()
   Build()
   O.Load()
end
