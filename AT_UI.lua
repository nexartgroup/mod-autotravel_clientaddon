-- AT_UI.lua
-- ---------------------------------------------------------------------------
-- Panel und Minimap-Knopf.
--
-- Bewusst ohne die klobigen Standardrahmen: flacher dunkler Hintergrund,
-- duenne Kante, farbiger Statuspunkt, Fortschrittsbalken. Gebaut nur aus
-- Bordmitteln von 3.3.5a (Backdrop + WHITE8X8), damit keine Grafikdateien
-- mitgeliefert werden muessen.
-- ---------------------------------------------------------------------------

local AT = AutoTravel
AT.UI = {}
local UI = AT.UI

local WHITE = "Interface\\Buttons\\WHITE8X8"

local COL = {
   bg      = { 0.055, 0.062, 0.075, 0.94 },
   border  = { 0.22,  0.25,  0.30,  1 },
   accent  = { 0.20,  0.62,  0.92,  1 },
   text    = { 0.86,  0.88,  0.92,  1 },
   dim     = { 0.50,  0.54,  0.60,  1 },
}

local STATE = {
   ["IDLE"]            = { "|cff9099a8", "Bereit",            0.35, 0.38, 0.44 },
   ["STARTING"]        = { "|cffe8c44a", "Startet",           0.91, 0.77, 0.29 },
   ["REPATHING"]       = { "|cffe8c44a", "Berechnet neu",     0.91, 0.77, 0.29 },
   ["MOUNTING"]        = { "|cffe8c44a", "Mountet",           0.91, 0.77, 0.29 },
   ["TRAVELING"]       = { "|cff53d17a", "Unterwegs",         0.33, 0.82, 0.48 },
   ["PAUSED - COMBAT"] = { "|cffe8654a", "Kampf",             0.91, 0.40, 0.29 },
   ["PAUSED - SPIELER"]= { "|cffe8c44a", "Du hast Vorrang",   0.91, 0.77, 0.29 },
   ["WARTE AUF FLUG"]  = { "|cff58b6e8", "Wartet auf Flug",   0.35, 0.71, 0.91 },
   ["ARRIVED"]         = { "|cff53d17a", "Angekommen",        0.33, 0.82, 0.48 },
   ["FAILED"]          = { "|cffe8654a", "Fehlgeschlagen",    0.91, 0.40, 0.29 },
   ["TOT"]             = { "|cffe8654a", "Tot",               0.91, 0.40, 0.29 },
}

local panel, mini

-- ---------------------------------------------------------------------------
-- Bausteine
-- ---------------------------------------------------------------------------

function UI.Skin(frame, bg, border)
   frame:SetBackdrop({
      bgFile = WHITE, edgeFile = WHITE, tile = false, edgeSize = 1,
      insets = { left = 1, right = 1, top = 1, bottom = 1 },
   })
   bg = bg or COL.bg
   border = border or COL.border
   frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
   frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
end

-- Flacher Knopf ohne Blizzard-Rahmen
function UI.Button(parent, w, h, label, onClick)
   local b = CreateFrame("Button", nil, parent)
   b:SetWidth(w) b:SetHeight(h)
   UI.Skin(b, { 0.13, 0.15, 0.18, 1 }, { 0.26, 0.29, 0.34, 1 })

   local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
   fs:SetPoint("CENTER")
   fs:SetText(label)
   b.label = fs

   b:SetScript("OnEnter", function()
      b:SetBackdropColor(0.19, 0.22, 0.27, 1)
      b:SetBackdropBorderColor(COL.accent[1], COL.accent[2], COL.accent[3], 1)
      if b.tip then
         GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
         b.tip()
         GameTooltip:Show()
      end
   end)
   b:SetScript("OnLeave", function()
      b:SetBackdropColor(0.13, 0.15, 0.18, 1)
      b:SetBackdropBorderColor(0.26, 0.29, 0.34, 1)
      GameTooltip:Hide()
   end)
   b:SetScript("OnClick", onClick)
   return b
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------

local function BuildPanel()
   if panel then return end

   local f = CreateFrame("Frame", "AutoTravelPanel", UIParent)
   f:SetWidth(226)
   f:SetHeight(224)
   UI.Skin(f)
   f:SetMovable(true)
   f:EnableMouse(true)
   f:RegisterForDrag("LeftButton")
   f:SetScript("OnDragStart", function() f:StartMoving() end)
   f:SetScript("OnDragStop", function()
      f:StopMovingOrSizing()
      local p, _, _, x, y = f:GetPoint()
      AT.Set("PanelPoint", { p, x, y })
   end)
   f:SetClampedToScreen(true)

   local p = AT.Get("PanelPoint") or { "CENTER", 240, 0 }
   f:SetPoint(p[1] or "CENTER", UIParent, p[1] or "CENTER", p[2] or 0, p[3] or 0)

   -- Kopfzeile
   local head = CreateFrame("Frame", nil, f)
   head:SetPoint("TOPLEFT", 1, -1)
   head:SetPoint("TOPRIGHT", -1, -1)
   head:SetHeight(24)
   head:SetBackdrop({ bgFile = WHITE })
   head:SetBackdropColor(0.10, 0.12, 0.15, 1)

   local stripe = head:CreateTexture(nil, "OVERLAY")
   stripe:SetTexture(WHITE)
   stripe:SetVertexColor(COL.accent[1], COL.accent[2], COL.accent[3], 1)
   stripe:SetPoint("TOPLEFT", 0, 0)
   stripe:SetPoint("BOTTOMLEFT", 0, 0)
   stripe:SetWidth(3)

   local title = head:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
   title:SetPoint("LEFT", 10, 0)
   title:SetText("AutoTravel")
   title:SetTextColor(0.92, 0.94, 0.97)

   local cog = UI.Button(head, 18, 16, "|cffaaaaaa*|r", function() AT.Options.Open() end)
   cog:SetPoint("RIGHT", -24, 0)
   cog.tip = function() GameTooltip:AddLine("Einstellungen") end

   local close = UI.Button(head, 18, 16, "|cffaaaaaax|r", function()
      AT.Set("PanelVisible", 0)
      f:Hide()
   end)
   close:SetPoint("RIGHT", -4, 0)

   -- Statuszeile
   local dot = f:CreateTexture(nil, "OVERLAY")
   dot:SetTexture(WHITE)
   dot:SetWidth(6) dot:SetHeight(6)
   dot:SetPoint("TOPLEFT", 12, -34)
   f.dot = dot

   local st = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
   st:SetPoint("LEFT", dot, "RIGHT", 7, 0)
   f.lState = st

   local tgt = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
   tgt:SetPoint("TOPLEFT", 12, -50)
   tgt:SetWidth(202)
   tgt:SetJustifyH("LEFT")
   f.lTarget = tgt

   -- Fortschritt
   local barBg = CreateFrame("Frame", nil, f)
   barBg:SetPoint("TOPLEFT", 12, -68)
   barBg:SetWidth(202) barBg:SetHeight(8)
   UI.Skin(barBg, { 0.10, 0.11, 0.13, 1 }, { 0.20, 0.22, 0.26, 1 })

   local bar = CreateFrame("StatusBar", nil, barBg)
   bar:SetPoint("TOPLEFT", 1, -1)
   bar:SetPoint("BOTTOMRIGHT", -1, 1)
   bar:SetStatusBarTexture(WHITE)
   bar:SetMinMaxValues(0, 1)
   bar:SetValue(0)
   bar:SetStatusBarColor(COL.accent[1], COL.accent[2], COL.accent[3], 0.9)
   f.bar = bar

   local dist = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
   dist:SetPoint("TOPLEFT", 12, -82)
   f.lDist = dist

   local info = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
   info:SetPoint("TOPRIGHT", -12, -82)
   f.lInfo = info

   -- Profil und Botschalter getrennt
   local prof = UI.Button(f, 138, 20, "", function()
      local pr = AT.Bot.Next()
      AT.Print("Profil: |cffffffff" .. pr.name .. "|r - " .. pr.desc)
      if AT.Bot.IsRunning() then AT.Bot.ApplyProfile() end
      UI.Update()
   end)
   prof:SetPoint("TOPLEFT", 12, -100)
   prof.tip = function()
      GameTooltip:AddLine("Verhalten des Playerbots")
      local cur = AT.Bot.Current()
      for _, x in ipairs(AT.Bot.Profiles) do
         if x.key == cur.key then GameTooltip:AddLine(x.name .. " - " .. x.desc, 0.33, 0.82, 0.48)
         else GameTooltip:AddLine(x.name .. " - " .. x.desc, 0.6, 0.62, 0.66) end
      end
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("Klicken wechselt das Profil", 0.91, 0.77, 0.29)
      GameTooltip:AddLine("Eigene Profile: /at profile", 0.6, 0.62, 0.66)
   end
   f.prof = prof

   local botBtn = UI.Button(f, 60, 20, "", function() AT.Bot.Toggle() end)
   botBtn:SetPoint("TOPLEFT", 154, -100)
   botBtn.tip = function()
      GameTooltip:AddLine("Playerbot-Selbstmodus")
      GameTooltip:AddLine("Spielervorrang: " ..
         string.gsub(AT.Override.StatusText(), "|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""), 1, 1, 1)
      GameTooltip:AddLine("Klicken schaltet ihn ein oder aus.", 0.7, 0.7, 0.7)
      GameTooltip:AddLine("Er bleibt beim Reiseende an, solange", 0.7, 0.7, 0.7)
      GameTooltip:AddLine("in den Einstellungen nichts anderes steht.", 0.7, 0.7, 0.7)
   end
   f.botBtn = botBtn

   local heir = UI.Button(f, 202, 18, "", function()
      AT.Set("GuardHeirlooms", AT.GetBool("GuardHeirlooms") and 0 or 1)
      if AT.GetBool("GuardHeirlooms") then AT.Gear.Snapshot() end
      AT.Print("Erbstueckschutz " .. (AT.GetBool("GuardHeirlooms") and "AN" or "AUS"))
      UI.Update()
   end)
   heir:SetPoint("TOPLEFT", 12, -122)
   heir.tip = function()
      GameTooltip:AddLine("Erbstuecke schuetzen")
      GameTooltip:AddLine("Angelegte Teile der Qualitaetsstufe 7 werden", 0.7, 0.7, 0.7)
      GameTooltip:AddLine("nach einem Tausch wieder angelegt.", 0.7, 0.7, 0.7)
      GameTooltip:AddLine("Rechts steht, ob dauerhaft oder nur auf Reisen.", 0.6, 0.62, 0.66)
   end
   f.heir = heir

   -- Aktionen
   local go = UI.Button(f, 202, 26, "START", function() AT.Toggle() end)
   go:SetPoint("TOPLEFT", 12, -148)
   go.label:SetFontObject("GameFontNormal")
   f.go = go

   local re = UI.Button(f, 99, 20, "Neu berechnen", function() AT.Repath() end)
   re:SetPoint("TOPLEFT", 12, -178)

   local tp = UI.Button(f, 99, 20, "|cffe8c44aTeleport|r", function() AT.Teleport() end)
   tp:SetPoint("TOPLEFT", 115, -178)
   tp.tip = function()
      GameTooltip:AddLine("Direkt zum Ziel springen")
      GameTooltip:AddLine("Nur fuer den Notfall - der normale Weg", 0.7, 0.7, 0.7)
      GameTooltip:AddLine("ist START, damit der Charakter laeuft.", 0.7, 0.7, 0.7)
   end

   panel = f
   UI.Refresh()
end

-- ---------------------------------------------------------------------------
-- Minimap-Knopf
-- ---------------------------------------------------------------------------

local function PositionMinimap()
   if not mini then return end
   local a = AT.Get("MinimapAngle") or 200
   local rad = math.rad(a)
   mini:SetPoint("CENTER", Minimap, "CENTER", 78 * math.cos(rad), 78 * math.sin(rad))
end

local function BuildMinimap()
   if mini then return end

   local b = CreateFrame("Button", "AutoTravelMinimapButton", Minimap)
   b:SetWidth(31) b:SetHeight(31)
   b:SetFrameStrata("MEDIUM")
   b:SetFrameLevel(8)
   b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
   b:RegisterForDrag("LeftButton")
   b:SetMovable(true)

   local overlay = b:CreateTexture(nil, "OVERLAY")
   overlay:SetWidth(53) overlay:SetHeight(53)
   overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
   overlay:SetPoint("TOPLEFT", 0, 0)

   local icon = b:CreateTexture(nil, "BACKGROUND")
   icon:SetWidth(20) icon:SetHeight(20)
   icon:SetTexture("Interface\\Icons\\Ability_Mount_RidingHorse")
   icon:SetPoint("TOPLEFT", 7, -6)
   icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
   b.icon = icon

   b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

   b:SetScript("OnClick", function(self, button)
      if button == "RightButton" then AT.Teleport() else AT.Toggle() end
   end)

   b:SetScript("OnEnter", function()
      GameTooltip:SetOwner(b, "ANCHOR_LEFT")
      GameTooltip:AddLine("AutoTravel")
      local s = AT.status
      local d = STATE[s.state] or STATE["IDLE"]
      GameTooltip:AddLine(d[2] .. "  |cffffffff" .. tostring(s.target or "-") .. "|r", 1, 1, 1)
      if AT.active and s.distance and s.distance > 0 then
         GameTooltip:AddLine(string.format("noch %d yd", s.distance), 0.7, 0.7, 0.7)
      end
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("Links: Reise starten / stoppen", 0.33, 0.82, 0.48)
      GameTooltip:AddLine("Rechts: Teleport zum Ziel", 0.91, 0.77, 0.29)
      GameTooltip:AddLine("Ziehen: Knopf verschieben", 0.6, 0.6, 0.6)
      GameTooltip:Show()
   end)
   b:SetScript("OnLeave", function() GameTooltip:Hide() end)

   b:SetScript("OnDragStart", function() b.dragging = true end)
   b:SetScript("OnDragStop", function() b.dragging = false end)
   b:SetScript("OnUpdate", function()
      if not b.dragging then return end
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = UIParent:GetEffectiveScale()
      cx, cy = cx / scale, cy / scale
      AT.Set("MinimapAngle", math.deg(math.atan2(cy - my, cx - mx)))
      PositionMinimap()
   end)

   mini = b
   PositionMinimap()
   UI.RefreshMinimap()
end

-- ---------------------------------------------------------------------------

function UI.Build()
   BuildPanel()
   BuildMinimap()
   UI.Update()
end

function UI.Refresh()
   if not panel then return end
   if AT.GetBool("PanelVisible") then panel:Show() else panel:Hide() end
end

function UI.RefreshMinimap()
   if not mini then return end
   if AT.GetBool("MinimapButton") then mini:Show() else mini:Hide() end
end

function UI.Update()
   local s = AT.status
   local d = STATE[s.state] or { "|cffffffff", tostring(s.state or "?"), 0.6, 0.6, 0.6 }

   if mini and mini.icon then
      if AT.active then mini.icon:SetVertexColor(d[3], d[4], d[5])
      else mini.icon:SetVertexColor(1, 1, 1) end
   end

   if not panel then return end

   panel.dot:SetVertexColor(d[3], d[4], d[5], 1)
   panel.lState:SetText(d[1] .. d[2] .. "|r")
   panel.lTarget:SetText("|cffdde2ea" .. tostring(s.target or "-") .. "|r")

   -- Fortschritt: von der Startentfernung herunter
   if AT.active and s.distance and s.distance > 0 then
      if not AT.startDistance or s.distance > AT.startDistance then
         AT.startDistance = s.distance
      end
      local frac = 1 - (s.distance / math.max(1, AT.startDistance))
      panel.bar:SetValue(math.max(0, math.min(1, frac)))
      panel.lDist:SetText(string.format("|cffdde2ea%d|r |cff8a90a0yd|r", s.distance))
   else
      AT.startDistance = nil
      panel.bar:SetValue(0)
      panel.lDist:SetText("|cff8a90a0-|r")
   end

   local extra = ""
   if s.mounted == 1 then extra = "Mount" end
   if s.nodes and s.nodes > 0 then
      extra = extra ~= "" and (extra .. "  ") or ""
      extra = extra .. s.nodes .. " Nodes"
   end
   if s.attempts and s.attempts > 0 then
      extra = extra .. "  Retry " .. s.attempts
   end
   panel.lInfo:SetText(extra)

   if panel.prof then
      panel.prof.label:SetText("|cffdde2ea" .. AT.Bot.Current().name .. "|r")
   end

   if panel.botBtn then
      if not AT.GetBool("BotControl") then
         panel.botBtn.label:SetText("|cff6a7080gesperrt|r")
      elseif AT.Override and AT.Override.active and AT.GetBool("OverridePausesBot") then
         panel.botBtn.label:SetText("|cffe8c44aPause|r")
      else
         panel.botBtn.label:SetText("Bot " .. AT.Bot.StatusText())
      end
   end

   if panel.heir then
      if AT.GetBool("GuardHeirlooms") then
         panel.heir.label:SetText("|cff53d17aErbstuecke geschuetzt|r  |cff8a90a0(" ..
            (AT.GetBool("GuardAlways") and "immer" or "nur auf Reisen") .. ")|r")
      else
         panel.heir.label:SetText("|cff6a7080Erbstueckschutz aus|r")
      end
   end

   panel.go.label:SetText(AT.active and "STOP" or "START")
end
