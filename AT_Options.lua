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

   sl:SetScript("OnValueChanged", function()
      local v = math.floor(sl:GetValue() + 0.5)
      refresh(v)
      if sl.loading then return end
      AT.Set(key, v)
      if onChange then onChange(v) end
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

local function Build()
   if frame then return frame end

   frame = CreateFrame("Frame", "AutoTravelOptionsPanel", UIParent)
   frame.name = "AutoTravel"

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

   local y = -102
   for i, p in ipairs(AT.Bot.Profiles) do
      local col = (i - 1) % 3
      local row = math.floor((i - 1) / 3)
      local b = AT.UI.Button(frame, 118, 22, p.name, function()
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
         GameTooltip:AddLine("co " .. (p.combat or "-"), 0.55, 0.6, 0.68, true)
         GameTooltip:AddLine("nc " .. (p.noncombat or "-"), 0.55, 0.6, 0.68, true)
      end
      table.insert(profButtons, b)
   end

   Note(frame, "AutoTravel aendert am Charakter nichts ausser Strategien: keine Ausruestung, " ..
               "keine Talente, kein Handel. 'new rpg' wird in jedem Profil abgeschaltet.",
        20, -158)

   table.insert(widgets, Check(frame, "Playerbot-Selbstmodus mitsteuern",
      "Schaltet den Selbstmodus beim Start ein und am Ende der Reise wieder aus.",
      16, -184, "BotControl", function() if AT.UI then AT.UI.Update() end end))

   -- ---- Reise -----------------------------------------------------------
   Header(frame, "Reise", 16, -220)

   table.insert(widgets, Slider(frame, "Zielradius (yd)",
      "Ab dieser Entfernung gilt das Ziel als erreicht.",
      16, -252, 3, 50, 1, "ArriveYards", function(v) AT.Send("at ziel " .. v) end))

   table.insert(widgets, Check(frame, "Ankunft laut melden",
      "Meldungen des Servermoduls im Chat anzeigen statt sie auszublenden.",
      250, -248, "ShowProtocol", function(v) AT.Set("HideProtocol", (v == 1) and 0 or 1) end))

   -- ---- Teleport --------------------------------------------------------
   Header(frame, "Teleport", 16, -296)

   table.insert(widgets, Check(frame, "Vor dem Teleport nachfragen",
      "Sicherheitsabfrage, damit der Knopf nicht versehentlich ausloest.",
      16, -324, "ConfirmTp"))

   local tpMode = AT.UI.Button(frame, 180, 22, "", function()
      AT.Set("TeleportMode", (AT.Get("TeleportMode") == "go") and "module" or "go")
      O.Load()
   end)
   tpMode:SetPoint("TOPLEFT", 250, -322)
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
   Header(frame, "Anzeige", 16, -364)

   table.insert(widgets, Check(frame, "Panel anzeigen", nil, 16, -392, "PanelVisible",
      function() if AT.UI then AT.UI.Refresh() end end))
   table.insert(widgets, Check(frame, "Minimap-Knopf", nil, 250, -392, "MinimapButton",
      function() if AT.UI then AT.UI.RefreshMinimap() end end))
   table.insert(widgets, Check(frame, "Botbefehle im Chat verbergen", nil, 16, -418, "HideBotCmd"))
   table.insert(widgets, Check(frame, "Debug-Ausgaben", "Zeigt jeden gesendeten Befehl und die " ..
      "Diagnosemeldungen des Servermoduls.", 250, -418, "Debug",
      function(v) AT.Send("at debug " .. v) end))

   -- ---- Playerbot-Befehle ----------------------------------------------
   Header(frame, "Playerbot-Befehle", 16, -454)

   table.insert(widgets, Edit(frame, "Selbstmodus einschalten", 16, -482, 250, "SelfOnCommand"))
   table.insert(widgets, Edit(frame, "Selbstmodus ausschalten", 290, -482, 250, "SelfOffCommand"))

   Note(frame, "Genaue Schreibweise mit '.playerbots help' pruefen. Enter speichert.",
        20, -524)

   frame.refresh = function() O.Load() end
   frame.okay    = function() end
   frame.cancel  = function() end

   if InterfaceOptions_AddCategory then
      InterfaceOptions_AddCategory(frame)
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
   if InterfaceOptionsFrame_OpenToCategory then
      InterfaceOptionsFrame_OpenToCategory(frame)
      InterfaceOptionsFrame_OpenToCategory(frame)   -- 3.3.5a braucht zwei Aufrufe
   end
end

function O.Init()
   Build()
   O.Load()
end
