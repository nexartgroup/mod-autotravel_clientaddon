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

-- Zustaende, wie das Servermodul sie meldet (ATStateName in AutoTravel_Config.cpp),
-- dazu STARTING, das nur das Addon kennt: Befehl gesendet, Antwort steht aus.
-- Eintrag: { Farbcode, Beschriftung, r, g, b }
local YELLOW = { "|cffe8c44a", 0.91, 0.77, 0.29 }
local GREEN  = { "|cff53d17a", 0.33, 0.82, 0.48 }
local RED    = { "|cffe8654a", 0.91, 0.40, 0.29 }
local BLUE   = { "|cff58b6e8", 0.35, 0.71, 0.91 }
local GREY   = { "|cff9099a8", 0.35, 0.38, 0.44 }

local function S(c, label) return { c[1], label, c[2], c[3], c[4] } end

local STATE = {
   IDLE      = S(GREY,   "Bereit"),
   STARTING  = S(YELLOW, "Startet"),
   REPATHING = S(YELLOW, "Berechnet neu"),
   MOUNTING  = S(YELLOW, "Sitzt auf"),
   TAKEOFF   = S(YELLOW, "Hebt ab"),
   TRAVELING = S(GREEN,  "Unterwegs"),
   COMBAT    = S(RED,    "Kampf"),
   PLAYER    = S(YELLOW, "Du steuerst"),
   TAXI      = S(BLUE,   "Flug"),
   TRANSPORT = S(BLUE,   "Transport"),
   MANUAL    = S(BLUE,   "Wartet auf Verbindung"),
   ARRIVED   = S(GREEN,  "Angekommen"),
   FAILED    = S(RED,    "Fehlgeschlagen"),
}
UI.STATE = STATE

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
      if b.disabledTip and not b:IsEnabled() then
         GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
         GameTooltip:AddLine(b.disabledTip, 0.8, 0.8, 0.8, true)
         GameTooltip:Show()
         return
      end
      b:SetBackdropColor(0.19, 0.22, 0.27, 1)
      b:SetBackdropBorderColor(COL.accent[1], COL.accent[2], COL.accent[3], 1)
      if b.tip then
         GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
         b.tip()
         GameTooltip:Show()
      end
   end)
   b:SetScript("OnLeave", function()
      UI.RestColors(b)
      GameTooltip:Hide()
   end)
   b:SetScript("OnClick", onClick)
   return b
end

-- Ruhefarben eines Knopfes; ein ausgewaehlter (z. B. das bearbeitete Profil) behaelt
-- seine Hervorhebung, wenn die Maus ihn verlaesst.
function UI.RestColors(b)
   if b.selected then
      b:SetBackdropColor(0.16, 0.34, 0.46, 1)
      b:SetBackdropBorderColor(0.35, 0.71, 0.91, 1)
   else
      b:SetBackdropColor(0.13, 0.15, 0.18, 1)
      b:SetBackdropBorderColor(0.26, 0.29, 0.34, 1)
   end
end

function UI.SetSelected(b, selected)
   if not b then return end
   b.selected = selected and true or false
   UI.RestColors(b)
end

-- Knopf sperren oder freigeben. Gesperrte Knoepfe bleiben sichtbar und erklaeren
-- im Tooltip, warum sie gesperrt sind, statt zu verschwinden.
function UI.SetEnabled(b, enabled, reason)
   if not b then return end
   b.disabledTip = reason
   if enabled then
      if not b:IsEnabled() then b:Enable() end
      b:SetAlpha(1)
   else
      if b:IsEnabled() then b:Disable() end
      b:SetAlpha(0.45)
   end
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------

local function BuildPanel()
   if panel then return end

   local f = CreateFrame("Frame", "AutoTravelPanel", UIParent)
   f:SetWidth(226)
   f:SetHeight(242)
   UI.Skin(f)
   f:SetMovable(true)
   f:EnableMouse(true)
   f:RegisterForDrag("LeftButton")
   f:SetScript("OnDragStart", function() f:StartMoving() end)
   f:SetScript("OnDragStop", function()
      f:StopMovingOrSizing()
      local p, _, rp, x, y = f:GetPoint()
      AT.Set("PanelPoint", { p, x, y, rp })
   end)
   f:SetClampedToScreen(true)

   -- Gespeichert wird { Anker, x, y, Bezugsanker }. Aeltere Fassungen legten nur
   -- { Anker, x, y } ab und nahmen an, dass Bezugs- und eigener Anker gleich sind.
   local p = AT.Get("PanelPoint") or { "CENTER", 240, 0 }
   f:SetPoint(p[1] or "CENTER", UIParent, p[4] or p[1] or "CENTER", p[2] or 0, p[3] or 0)

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

   local leg = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
   leg:SetPoint("TOPRIGHT", -12, -31)
   f.lLeg = leg

   -- Feste Hoehe: ein langer Zielname wird abgeschnitten, statt in die
   -- Fortschrittsleiste darunter umzubrechen.
   local tgt = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
   tgt:SetPoint("TOPLEFT", 12, -50)
   tgt:SetWidth(202)
   tgt:SetHeight(12)
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

   -- Eine Zeile fuer Navigationsart bzw. Uebergabe (hat Vorrang)
   local nav = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
   nav:SetPoint("TOPLEFT", 12, -96)
   nav:SetWidth(202)
   nav:SetHeight(12)
   nav:SetJustifyH("LEFT")
   f.lNav = nav

   -- Aktionen -------------------------------------------------------------
   local go = UI.Button(f, 202, 26, "START", function() AT.Toggle() end)
   go:SetPoint("TOPLEFT", 12, -114)
   go.label:SetFontObject("GameFontNormal")
   f.go = go

   local pause = UI.Button(f, 99, 20, "Uebernehmen", function() AT.Handover.Toggle() end)
   pause:SetPoint("TOPLEFT", 12, -144)
   pause.tip = function()
      GameTooltip:AddLine("Steuerung uebernehmen")
      GameTooltip:AddLine("Der Autopilot haelt an und gibt dir die Kontrolle.", 0.7, 0.7, 0.7, true)
      GameTooltip:AddLine("Nach einer Weile ohne Eingabe laeuft ein Countdown, " ..
                          "danach faehrt er weiter. Ein ausdruecklich uebernommener " ..
                          "Halt endet nur mit einem Klick auf 'Weiter'.", 0.6, 0.62, 0.66, true)
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("Auch per Taste: Optionen -> Tastaturbelegung -> AutoTravel.", 0.6, 0.62, 0.66, true)
   end
   f.pause = pause

   local re = UI.Button(f, 99, 20, "Neu berechnen", function() AT.Repath() end)
   re:SetPoint("TOPLEFT", 115, -144)
   f.re = re

   -- Profil und Botschalter getrennt
   local prof = UI.Button(f, 138, 20, "", function()
      local pr = AT.Bot.Next()
      AT.Print("Profil: |cffffffff" .. pr.name .. "|r - " .. pr.desc)
      if AT.Bot.IsRunning() then AT.Bot.ApplyProfile() end
      UI.Update()
   end)
   prof:SetPoint("TOPLEFT", 12, -168)
   prof.tip = function()
      GameTooltip:AddLine("Verhalten des Playerbots")
      local cur = AT.Bot.Current()
      for _, x in ipairs(AT.Bot.List()) do
         if x.key == cur.key then GameTooltip:AddLine(x.name .. " - " .. x.desc, 0.33, 0.82, 0.48)
         else GameTooltip:AddLine(x.name .. " - " .. x.desc, 0.6, 0.62, 0.66) end
      end
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("Klicken wechselt das Profil", 0.91, 0.77, 0.29)
      GameTooltip:AddLine("Profile bearbeiten: /at profil bearbeiten", 0.6, 0.62, 0.66)
   end
   f.prof = prof

   local botBtn = UI.Button(f, 60, 20, "", function() AT.Bot.Toggle() end)
   botBtn:SetPoint("TOPLEFT", 154, -168)
   botBtn.tip = function()
      GameTooltip:AddLine("Playerbot-Selbstmodus")
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
   heir:SetPoint("TOPLEFT", 12, -192)
   heir.tip = function()
      GameTooltip:AddLine("Erbstuecke schuetzen")
      GameTooltip:AddLine("Angelegte Teile der Qualitaetsstufe 7 werden", 0.7, 0.7, 0.7)
      GameTooltip:AddLine("nach einem Tausch wieder angelegt.", 0.7, 0.7, 0.7)
      GameTooltip:AddLine("Rechts steht, ob dauerhaft oder nur auf Reisen.", 0.6, 0.62, 0.66)
   end
   f.heir = heir

   local tp = UI.Button(f, 202, 20, "|cffe8c44aTeleport|r", function() AT.Teleport() end)
   tp:SetPoint("TOPLEFT", 12, -214)
   tp.tip = function()
      GameTooltip:AddLine("Direkt zum Ziel springen")
      GameTooltip:AddLine("Nur fuer den Notfall - der normale Weg", 0.7, 0.7, 0.7)
      GameTooltip:AddLine("ist START, damit der Charakter laeuft.", 0.7, 0.7, 0.7)
   end
   f.tp = tp

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
   mini:ClearAllPoints()
   mini:SetPoint("CENTER", Minimap, "CENTER", 78 * math.cos(rad), 78 * math.sin(rad))
end

local function BuildMinimap()
   if mini then return end

   local b = CreateFrame("Button", "AutoTravelMinimapButton", Minimap)
   b:SetWidth(31) b:SetHeight(31)
   b:SetFrameStrata("MEDIUM")
   b:SetFrameLevel(8)
   b:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
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
      if button == "RightButton" then AT.Teleport()
      elseif button == "MiddleButton" then AT.Handover.Toggle()
      else AT.Toggle() end
   end)

   b:SetScript("OnEnter", function()
      GameTooltip:SetOwner(b, "ANCHOR_LEFT")
      GameTooltip:AddLine("AutoTravel")
      local s = AT.status
      local d = STATE[s.state] or STATE.IDLE
      GameTooltip:AddLine(d[2] .. "  |cffffffff" .. tostring(s.target or "-") .. "|r", 1, 1, 1)
      if AT.active and s.distance and s.distance > 0 then
         GameTooltip:AddLine(string.format("noch %d yd", s.distance), 0.7, 0.7, 0.7)
      end
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("Links: Reise starten / stoppen", 0.33, 0.82, 0.48)
      GameTooltip:AddLine("Mitte: Steuerung uebernehmen / zurueckgeben", 0.35, 0.71, 0.91)
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

-- Text der Navigationszeile: Uebergabe hat Vorrang vor der Navigationsart.
local function NavLine()
   local h = AT.Handover.StatusText()
   if h then
      local col = (AT.status.state == "COMBAT") and "|cffe8654a" or "|cffe8c44a"
      return col .. h .. "|r"
   end

   local natural = AT.GetBool("NaturalPathing")
   local contour = AT.GetBool("ContourProbing")

   if natural and contour then
      return "|cff53d17aNatuerliche Navigation|r  |cff58b6e8Contour aktiv|r"
   elseif natural then
      return "|cff53d17aNatuerliche Navigation|r"
   elseif contour then
      return "|cff58b6e8Contour aktiv|r"
   end
   return "|cff9099a8Normale Navigation|r"
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

   if AT.active and s.legs and s.legs > 1 then
      panel.lLeg:SetText(string.format("Etappe %d/%d", s.leg or 0, s.legs))
   else
      panel.lLeg:SetText("")
   end

   -- Fortschritt kommt vom Server (Anteil der zurueckgelegten Luftlinie). Ein
   -- aelteres Modul ohne dieses Feld meldet 0; dann wird wie frueher von der
   -- ersten gesehenen Entfernung heruntergerechnet.
   if AT.active and s.distance and s.distance > 0 then
      local frac
      if s.progress and s.progress > 0 then
         frac = s.progress / 100
      else
         if not AT.startDistance or s.distance > AT.startDistance then
            AT.startDistance = s.distance
         end
         frac = 1 - (s.distance / math.max(1, AT.startDistance))
      end
      panel.bar:SetValue(math.max(0, math.min(1, frac)))
      panel.lDist:SetText(string.format("|cffdde2ea%d|r |cff8a90a0yd|r", s.distance))
   else
      AT.startDistance = nil
      panel.bar:SetValue(s.state == "ARRIVED" and 1 or 0)
      panel.lDist:SetText("|cff8a90a0-|r")
   end

   local extra = ""
   if s.flying then extra = "Flug"
   elseif s.swimming then extra = "Schwimmt"
   elseif s.mounted == 1 then extra = "Mount" end
   if s.attempts and s.attempts > 0 then
      extra = extra .. (extra ~= "" and "  " or "") .. "Retry " .. s.attempts
   end
   if AT.Net.state ~= "READY" and AT.Net.state ~= "UNKNOWN" then
      local why = { HELLO = "verbindet ...", ABSENT = "kein Server", INCOMPATIBLE = "Modul zu alt",
                    DISABLED = "Modul aus" }
      extra = "|cffff8800" .. (why[AT.Net.state] or AT.Net.state) .. "|r"
   end
   panel.lInfo:SetText(extra)

   panel.lNav:SetText(NavLine())

   if panel.prof then
      panel.prof.label:SetText("|cffdde2ea" .. AT.Bot.Current().name .. "|r")
   end

   if panel.botBtn then
      if not AT.GetBool("BotControl") then
         panel.botBtn.label:SetText("|cff6a7080gesperrt|r")
      else
         panel.botBtn.label:SetText("Bot " .. AT.Bot.StatusText())
      end
   end

   if panel.heir then
      if AT.GetBool("GuardHeirlooms") then
         -- Kurz genug fuer den 202 Pixel breiten Knopf.
         panel.heir.label:SetText("|cff53d17aErbstuecke|r  |cff8a90a0(" ..
            (AT.GetBool("GuardAlways") and "immer" or "nur auf Reisen") .. ")|r")
      else
         panel.heir.label:SetText("|cff6a7080Erbstueckschutz aus|r")
      end
   end

   panel.go.label:SetText(AT.active and "STOP" or "START")

   -- Uebernehmen / Weiter
   if AT.Handover.CanResume() then
      panel.pause.label:SetText("|cff53d17aWeiter|r")
      UI.SetEnabled(panel.pause, true)
   else
      panel.pause.label:SetText("Uebernehmen")
      local can = AT.Handover.CanPause()
      local why
      if not AT.active then why = "Es laeuft keine Reise."
      elseif s.state == "COMBAT" then why = "Im Kampf hast du die Kontrolle ohnehin. Danach geht es von selbst weiter."
      elseif not can then why = "In diesem Zustand (" .. tostring(s.state) .. ") steuert ohnehin niemand." end
      UI.SetEnabled(panel.pause, can, why)
   end

   UI.SetEnabled(panel.re, AT.active, "Es laeuft keine Reise.")

   -- Teleport: nur anbieten, wenn der Server ihn diesem Spieler erlaubt.
   local tpOk = (AT.Get("TeleportMode") == "go") or AT.Net.Can("TELEPORT")
   UI.SetEnabled(panel.tp, tpOk,
      "Der Teleport ist dir auf diesem Server nicht erlaubt (AutoTravel.TeleportSecurity).")
end
