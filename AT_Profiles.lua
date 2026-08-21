-- AT_Profiles.lua
-- ---------------------------------------------------------------------------
-- Unterseite "Eigene Profile" unter Interface -> AddOns -> AutoTravel.
--
-- Drei frei belegbare Profile, kontoweit gespeichert (SavedVariables, nicht
-- PerCharacter) und damit auf allen Charakteren verfuegbar. Jede Strategie
-- laesst sich einzeln an- oder abwaehlen; ein Freitextfeld nimmt zusaetzliche
-- Befehle auf, etwa klassenspezifische Strategien oder "ll skill".
--
-- Beim Anwenden wird JEDE Flagge ausdruecklich mit + oder - gesetzt, nicht nur
-- die angehakten. Sonst haengt das Ergebnis davon ab, was "co !" als Standard
-- hinterlaesst.
-- ---------------------------------------------------------------------------

local AT = AutoTravel
AT.ProfileEditor = {}
local P = AT.ProfileEditor

local frame
local current = 1
local boxes = { combat = {}, noncombat = {} }
local nameEdit, extraEdit, titleFs
local slotButtons = {}

local WHITE = "Interface\\Buttons\\WHITE8X8"

-- ---------------------------------------------------------------------------

local cbCount = 0
local function FlagBox(parent, flag, tip, x, y, kind)
   cbCount = cbCount + 1
   local name = "AutoTravelFlagBox" .. cbCount
   local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
   cb:SetPoint("TOPLEFT", x, y)
   cb:SetWidth(20) cb:SetHeight(20)

   local fs = _G[name .. "Text"]
   if fs then
      fs:SetText(flag)
      fs:SetFontObject("GameFontHighlightSmall")
   end

   cb:SetScript("OnEnter", function()
      GameTooltip:SetOwner(cb, "ANCHOR_RIGHT")
      GameTooltip:AddLine(flag)
      GameTooltip:AddLine(tip, 0.7, 0.7, 0.7, true)
      GameTooltip:Show()
   end)
   cb:SetScript("OnLeave", function() GameTooltip:Hide() end)

   cb:SetScript("OnClick", function()
      local c = AT.Bot.CustomSlot(current)
      c[kind] = c[kind] or {}
      if cb:GetChecked() then c[kind][flag] = true else c[kind][flag] = nil end
      P.MarkDirty()
   end)

   cb.flag = flag
   table.insert(boxes[kind], cb)
   return cb
end

function P.MarkDirty()
   -- Laeuft das bearbeitete Profil gerade, sofort neu anwenden.
   local cur = AT.Bot.Current()
   if cur.customIndex == current and AT.Bot.IsRunning() then
      AT.Bot.ApplyProfile()
   end
   if AT.UI then AT.UI.Update() end
end

local function LoadSlot(i)
   current = i
   local c = AT.Bot.CustomSlot(i)

   if titleFs then titleFs:SetText("Profil " .. i .. ": " .. (c.name or "")) end
   if nameEdit then nameEdit:SetText(c.name or "") end
   if extraEdit then extraEdit:SetText(c.extra or "") end

   for _, cb in ipairs(boxes.combat) do
      cb:SetChecked(c.combat and c.combat[cb.flag] or false)
   end
   for _, cb in ipairs(boxes.noncombat) do
      cb:SetChecked(c.noncombat and c.noncombat[cb.flag] or false)
   end

   for idx, b in ipairs(slotButtons) do
      if idx == i then
         b:SetBackdropColor(0.16, 0.34, 0.46, 1)
         b:SetBackdropBorderColor(0.35, 0.71, 0.91, 1)
      else
         b:SetBackdropColor(0.13, 0.15, 0.18, 1)
         b:SetBackdropBorderColor(0.26, 0.29, 0.34, 1)
      end
   end
end
P.LoadSlot = LoadSlot

-- ---------------------------------------------------------------------------

local function Build()
   if frame then return frame end

   frame = CreateFrame("Frame", "AutoTravelProfilePanel", UIParent)
   frame.name = "Eigene Profile"
   frame.parent = "AutoTravel"

   local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
   title:SetPoint("TOPLEFT", 16, -16)
   title:SetText("Eigene Profile")

   local sub = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
   sub:SetPoint("TOPLEFT", 16, -38)
   sub:SetWidth(560) sub:SetJustifyH("LEFT")
   sub:SetText("Drei frei belegbare Profile, kontoweit gespeichert und auf allen " ..
               "Charakteren verfuegbar. Ein Profil erscheint in der Auswahl, sobald " ..
               "mindestens eine Strategie angehakt ist.")
   sub:SetTextColor(0.6, 0.63, 0.68)

   -- Auswahl der drei Plaetze
   for i = 1, AT.Bot.CUSTOM_COUNT do
      local b = AT.UI.Button(frame, 90, 22, "Profil " .. i, function() LoadSlot(i) end)
      b:SetPoint("TOPLEFT", 16 + (i - 1) * 96, -76)
      table.insert(slotButtons, b)
   end

   titleFs = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
   titleFs:SetPoint("TOPLEFT", 310, -80)
   titleFs:SetTextColor(0.35, 0.71, 0.91)

   -- Name
   local nameLbl = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
   nameLbl:SetPoint("TOPLEFT", 16, -108)
   nameLbl:SetText("Name")

   nameEdit = CreateFrame("EditBox", "AutoTravelProfileName", frame, "InputBoxTemplate")
   nameEdit:SetPoint("TOPLEFT", 20, -124)
   nameEdit:SetWidth(200) nameEdit:SetHeight(20)
   nameEdit:SetAutoFocus(false)
   nameEdit:SetScript("OnEnterPressed", function()
      local c = AT.Bot.CustomSlot(current)
      local v = AT.trim(nameEdit:GetText())
      c.name = (v ~= "") and v or ("Eigenes " .. current)
      nameEdit:ClearFocus()
      titleFs:SetText("Profil " .. current .. ": " .. c.name)
      AT.Print("Profil " .. current .. " heisst jetzt: " .. c.name)
      P.MarkDirty()
   end)
   nameEdit:SetScript("OnEscapePressed", function() nameEdit:ClearFocus() LoadSlot(current) end)

   local apply = AT.UI.Button(frame, 150, 22, "Dieses Profil benutzen", function()
      local c = AT.Bot.CustomSlot(current)
      local used = AT.Bot.CustomUsed(current)
      if not used then
         AT.Warn("Dieses Profil ist noch leer - erst Strategien anhaken.")
         return
      end
      AT.Set("Profile", "custom" .. current)
      AT.Print("Profil: |cffffffff" .. (c.name or "") .. "|r")
      if AT.Bot.IsRunning() then AT.Bot.ApplyProfile() end
      if AT.UI then AT.UI.Update() end
   end)
   apply:SetPoint("TOPLEFT", 240, -124)

   local clear = AT.UI.Button(frame, 100, 22, "Leeren", function()
      local g = AT.Bot.Global()
      g.custom[current] = nil
      AT.Bot.CustomSlot(current)
      LoadSlot(current)
      AT.Print("Profil " .. current .. " geleert.")
      if AT.UI then AT.UI.Update() end
   end)
   clear:SetPoint("TOPLEFT", 400, -124)

   -- Kampfstrategien
   local h1 = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
   h1:SetPoint("TOPLEFT", 16, -158)
   h1:SetText("Kampf  (co)")
   h1:SetTextColor(0.35, 0.71, 0.91)

   local line1 = frame:CreateTexture(nil, "ARTWORK")
   line1:SetTexture(WHITE) line1:SetVertexColor(0.25, 0.28, 0.33, 0.8)
   line1:SetPoint("TOPLEFT", 16, -176) line1:SetWidth(560) line1:SetHeight(1)

   for i, f in ipairs(AT.Bot.CombatFlags) do
      local col = (i - 1) % 3
      local row = math.floor((i - 1) / 3)
      FlagBox(frame, f[1], f[2], 16 + col * 190, -186 - row * 22, "combat")
   end

   local rows = math.ceil(#AT.Bot.CombatFlags / 3)
   local yn = -186 - rows * 22 - 14

   -- Nichtkampf
   local h2 = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
   h2:SetPoint("TOPLEFT", 16, yn)
   h2:SetText("Ausserhalb des Kampfes  (nc)")
   h2:SetTextColor(0.35, 0.71, 0.91)

   local line2 = frame:CreateTexture(nil, "ARTWORK")
   line2:SetTexture(WHITE) line2:SetVertexColor(0.25, 0.28, 0.33, 0.8)
   line2:SetPoint("TOPLEFT", 16, yn - 18) line2:SetWidth(560) line2:SetHeight(1)

   for i, f in ipairs(AT.Bot.NonCombatFlags) do
      local col = (i - 1) % 3
      local row = math.floor((i - 1) / 3)
      FlagBox(frame, f[1], f[2], 16 + col * 190, yn - 28 - row * 22, "noncombat")
   end

   local yr = yn - 28 - math.ceil(#AT.Bot.NonCombatFlags / 3) * 22 - 16

   -- Freitext
   local exLbl = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
   exLbl:SetPoint("TOPLEFT", 16, yr)
   exLbl:SetText("Zusaetzliche Befehle, mit Semikolon getrennt (z. B. ll normal; ll skill)")

   extraEdit = CreateFrame("EditBox", "AutoTravelProfileExtra", frame, "InputBoxTemplate")
   extraEdit:SetPoint("TOPLEFT", 20, yr - 18)
   extraEdit:SetWidth(540) extraEdit:SetHeight(20)
   extraEdit:SetAutoFocus(false)
   extraEdit:SetScript("OnEnterPressed", function()
      AT.Bot.CustomSlot(current).extra = AT.trim(extraEdit:GetText())
      extraEdit:ClearFocus()
      AT.Print("Zusatzbefehle gespeichert.")
      P.MarkDirty()
   end)
   extraEdit:SetScript("OnEscapePressed", function() extraEdit:ClearFocus() LoadSlot(current) end)

   local note = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
   note:SetPoint("TOPLEFT", 20, yr - 44)
   note:SetWidth(540) note:SetJustifyH("LEFT")
   note:SetText("Enter speichert. Beim Anwenden wird jede Strategie ausdruecklich mit " ..
                "+ oder - gesetzt, damit das Ergebnis nicht davon abhaengt, was 'co !' " ..
                "als Standard hinterlaesst. Achtung: 'new rpg' laesst den Bot questen " ..
                "und dabei Ausruestung wechseln.")

   frame.refresh = function() LoadSlot(current) end
   frame.okay    = function() end
   frame.cancel  = function() end

   if InterfaceOptions_AddCategory then
      InterfaceOptions_AddCategory(frame)
   end
   return frame
end

function P.Open()
   Build()
   LoadSlot(current)
   if InterfaceOptionsFrame_OpenToCategory then
      InterfaceOptionsFrame_OpenToCategory(frame)
      InterfaceOptionsFrame_OpenToCategory(frame)
   end
end

function P.Init()
   Build()
   LoadSlot(1)
end
