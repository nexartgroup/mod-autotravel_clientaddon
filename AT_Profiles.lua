-- AT_Profiles.lua
-- ---------------------------------------------------------------------------
-- Unterseite "Profile" unter Interface -> AddOns -> AutoTravel.
--
-- Zwei Arten von Profilen, beide kontoweit gespeichert (SavedVariables, nicht
-- PerCharacter) und damit auf allen Charakteren verfuegbar:
--
--   Feste Profile   Minimal ... Plus. Sie lassen sich aendern und jederzeit auf
--                   ihre Standardwerte zuruecksetzen. Der Standard bleibt im Code;
--                   eine Aenderung liegt als Ueberschreibung daneben.
--
--                   Jede Strategie hat drei Zustaende: nicht gesetzt (es bleibt, was
--                   "co !" / "nc !" als Standard hinterlaesst), an (+), aus (-).
--                   Die festen Profile setzen bewusst nicht alles; mit nur zwei
--                   Zustaenden wuerde das erste Speichern aus jeder nicht gesetzten
--                   Strategie ein ausdrueckliches "-" machen.
--
--   Eigene Profile  Drei frei belegbare Plaetze. Hier wird JEDE Flagge
--                   ausdruecklich mit + oder - gesetzt, nicht nur die angehakten.
--                   Sonst haengt das Ergebnis davon ab, was "co !" als Standard
--                   hinterlaesst.
--
-- Ein Freitextfeld nimmt zusaetzliche Befehle auf, etwa klassenspezifische
-- Strategien oder "ll skill". Die Wartezeit nach dem Kampf gilt fuer die eigene
-- Reise: so lange wartet der Autopilot, bevor er weiterlaeuft.
-- ---------------------------------------------------------------------------

local AT = AutoTravel
AT.ProfileEditor = {}
local P = AT.ProfileEditor

local frame, content
local sel = { kind = "custom", id = 1 }         -- kind: "builtin" (id = Schluessel) | "custom" (id = Platz)
local boxes = { combat = {}, noncombat = {} }
local nameEdit, extraEdit, graceEdit
local titleFs, descFs, nameLbl, useBtn, clearBtn, resetBtn, hintFs
local selButtons = {}
local MAX_LABEL = 14

local WHITE = "Interface\\Buttons\\WHITE8X8"
local WIDTH = 580

local COL_ON  = "|cff53d17a"
local COL_OFF = "|cffe8654a"
local COL_MOD = "|cffe8c44a"

-- Der Server liest die Wartezeit in Millisekunden und behandelt 0 als "keine
-- Vorgabe" (dann gilt AutoTravel.CombatGraceMs); 0 waere also keine Null-Pause.
local MIN_GRACE, MAX_GRACE = 0.1, 30

-- ---------------------------------------------------------------------------
-- Zugriff auf das gerade gewaehlte Profil
-- ---------------------------------------------------------------------------

local function IsBuiltin() return sel.kind == "builtin" end

-- Was im Editor angezeigt wird. Bei einem festen Profil ohne Aenderung kommen die
-- Standardwerte, OHNE dass dabei eine Ueberschreibung angelegt wird.
local function View()
   local B = AT.Bot
   if IsBuiltin() then
      local d = B.BuiltinDefault(sel.id)
      if B.HasOverride(sel.id) then
         local o = B.BuiltinOverride(sel.id)
         return { combat = o.combat, noncombat = o.noncombat, extra = o.extra, grace = o.grace,
                  name = d.name, desc = d.desc }
      end
      return { combat = B.ParseFlags(d.combat), noncombat = B.ParseFlags(d.noncombat),
               extra = table.concat(d.extra or {}, "; "), grace = d.grace or 2.0,
               name = d.name, desc = d.desc }
   end
   local c = B.CustomSlot(sel.id)
   return { combat = c.combat or {}, noncombat = c.noncombat or {}, extra = c.extra or "",
            grace = c.grace or 2.0, name = c.name or ("Eigenes " .. sel.id), desc = "" }
end

-- Zum Schreiben: legt bei einem festen Profil die Ueberschreibung an.
local function Target()
   if IsBuiltin() then return AT.Bot.BuiltinOverride(sel.id) end
   local c = AT.Bot.CustomSlot(sel.id)
   c.combat = c.combat or {}
   c.noncombat = c.noncombat or {}
   return c
end

local function ProfileKey()
   return IsBuiltin() and sel.id or ("custom" .. sel.id)
end

-- ---------------------------------------------------------------------------
-- Neu anwenden (mit Verzoegerung)
-- ---------------------------------------------------------------------------
-- Laeuft das bearbeitete Profil gerade, wird es neu an den Bot gesendet. Nicht bei
-- jedem Klick: jede Anwendung sind ein Dutzend Fluesternachrichten.

local applyToken = 0
local RefreshHeader         -- Titel und "Auf Standard"-Knopf; unten definiert

local function RefreshSelectors()
   for _, e in ipairs(selButtons) do
      AT.UI.SetSelected(e.btn, e.kind == sel.kind and e.id == sel.id)

      local label
      if e.kind == "builtin" then
         local d = AT.Bot.BuiltinDefault(e.id)
         label = d.name .. (AT.Bot.IsModified(e.id) and " *" or "")
      else
         label = AT.Bot.CustomSlot(e.id).name or ("Eigenes " .. e.id)
      end
      -- Der Knopf ist 104 px breit: lange Namen kuerzen.
      if string.len(label) > MAX_LABEL then label = string.sub(label, 1, MAX_LABEL - 1) .. "." end
      e.btn.label:SetText(label)
   end
end

function P.MarkDirty()
   local B = AT.Bot
   -- Wieder auf den Standard gebracht? Dann keine Ueberschreibung zurueckbehalten.
   if IsBuiltin() then B.NormalizeBuiltin(sel.id) end

   local cur = B.Current()
   if cur.key == ProfileKey() and B.IsRunning() then
      applyToken = applyToken + 1
      local token, applied = applyToken, B.applyCount
      AT.After(1.0, function()
         -- Wurde inzwischen etwas angewendet (anderes Profil, Zuruecksetzen ...),
         -- steckt diese Aenderung schon darin.
         if token == applyToken and applied == B.applyCount and B.IsRunning() then
            B.ApplyProfile()
         end
      end)
   end
   RefreshSelectors()
   if RefreshHeader then RefreshHeader() end
   if AT.UI then AT.UI.Update() end
end

-- ---------------------------------------------------------------------------
-- Strategien
-- ---------------------------------------------------------------------------

local function StateText(flag, st)
   if st == true  then return COL_ON  .. "+|r" .. flag end
   if st == false then return COL_OFF .. "-|r" .. flag end
   return "|cff8a92a3" .. flag .. "|r"
end

local function ShowFlag(cb, st)
   if IsBuiltin() then
      cb:SetChecked(st == true)
      if cb.text then cb.text:SetText(StateText(cb.flag, st)) end
   else
      cb:SetChecked(st and true or false)
      if cb.text then cb.text:SetText(cb.flag) end
   end
end

local cbCount = 0
local function FlagBox(parent, flag, tip, x, y, kind, builtinOnly)
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
   cb.text = fs

   cb:SetScript("OnEnter", function()
      GameTooltip:SetOwner(cb, "ANCHOR_RIGHT")
      GameTooltip:AddLine(flag)
      GameTooltip:AddLine(tip, 0.7, 0.7, 0.7, true)
      if IsBuiltin() then
         GameTooltip:AddLine(" ")
         GameTooltip:AddLine("Klick wechselt: nicht gesetzt - an (+) - aus (-).", 0.55, 0.6, 0.68, true)
      end
      GameTooltip:Show()
   end)
   cb:SetScript("OnLeave", function() GameTooltip:Hide() end)

   cb:SetScript("OnClick", function()
      local t = Target()
      t[kind] = t[kind] or {}
      if IsBuiltin() then
         local st = t[kind][flag]
         local nxt
         if st == nil then nxt = true elseif st == true then nxt = false else nxt = nil end
         t[kind][flag] = nxt
         ShowFlag(cb, nxt)
      else
         if cb:GetChecked() then t[kind][flag] = true else t[kind][flag] = nil end
      end
      P.MarkDirty()
   end)

   cb.flag = flag
   cb.kind = kind
   cb.builtinOnly = builtinOnly
   table.insert(boxes[kind], cb)
   return cb
end

-- ---------------------------------------------------------------------------
-- Auswahl laden
-- ---------------------------------------------------------------------------

local function FormatGrace(v)
   v = tonumber(v) or 2
   if v == math.floor(v) then return string.format("%d", v) end
   -- bis zu zwei Stellen, ohne angehaengte Nullen ("0.25", "1.5")
   local s = string.format("%.2f", v)
   s = string.gsub(s, "0+$", "")
   return s
end

-- Titelzeile und "Auf Standard"-Knopf: beides haengt davon ab, ob das feste
-- Profil vom Standard abweicht, und aendert sich schon bei einem Klick.
RefreshHeader = function()
   if not frame then return end
   local B = AT.Bot
   local v = View()
   local builtin = IsBuiltin()

   if titleFs then
      if builtin then
         titleFs:SetText("Vorgegebenes Profil: " .. v.name ..
                         (B.IsModified(sel.id) and ("  " .. COL_MOD .. "(geaendert)|r") or ""))
      else
         titleFs:SetText("Eigenes Profil " .. sel.id .. ": " .. v.name)
      end
   end

   if resetBtn and builtin then
      if B.IsModified(sel.id) then resetBtn:Enable() else resetBtn:Disable() end
      if resetBtn.SetAlpha then resetBtn:SetAlpha(B.IsModified(sel.id) and 1 or 0.5) end
   end
end

local function LoadSelection()
   if not frame then return end
   local v = View()
   local builtin = IsBuiltin()

   RefreshHeader()

   if descFs then
      descFs:SetText(v.desc or "")
      if builtin then descFs:Show() else descFs:Hide() end
   end

   -- Nur eigene Profile: Name und Leeren. Nur feste: Zuruecksetzen.
   for _, w in ipairs({ nameLbl, nameEdit, clearBtn }) do
      if w then if builtin then w:Hide() else w:Show() end end
   end
   if resetBtn then
      if builtin then resetBtn:Show() else resetBtn:Hide() end
   end
   if nameEdit and not builtin then nameEdit:SetText(v.name or "") end

   if extraEdit then extraEdit:SetText(v.extra or "") end
   if graceEdit then graceEdit:SetText(FormatGrace(v.grace)) end

   for _, kind in ipairs({ "combat", "noncombat" }) do
      for _, cb in ipairs(boxes[kind]) do
         if cb.builtinOnly and not builtin then
            cb:Hide()
         else
            cb:Show()
            ShowFlag(cb, v[kind] and v[kind][cb.flag])
         end
      end
   end

   if hintFs then
      if builtin then
         hintFs:SetText("Grau: nicht gesetzt (bleibt, wie 'co !' und 'nc !' es hinterlassen), " ..
                        COL_ON .. "+|r an, " .. COL_OFF .. "-|r aus. Ein Klick wechselt zum naechsten Zustand. " ..
                        "'Auf Standard' stellt die Werte aus dem Addon wieder her; bis dahin behaelt das " ..
                        "Profil seine Werte, auch wenn eine neue Version den Standard aendert. " ..
                        "Wartezeit und Zusatzbefehle speichert die Eingabetaste. " ..
                        "Achtung: 'new rpg' laesst den Bot questen und dabei Ausruestung wechseln.")
      else
         hintFs:SetText("Enter speichert. Beim Anwenden wird jede Strategie ausdruecklich mit " ..
                        "+ oder - gesetzt, damit das Ergebnis nicht davon abhaengt, was 'co !' " ..
                        "als Standard hinterlaesst. Achtung: 'new rpg' laesst den Bot questen " ..
                        "und dabei Ausruestung wechseln.")
      end
   end

   RefreshSelectors()
end

function P.Select(kind, id)
   if kind ~= "builtin" and kind ~= "custom" then return false end
   if kind == "builtin" and not AT.Bot.IsBuiltinKey(id) then return false end
   if kind == "custom" then
      id = tonumber(id)
      if not id or id < 1 or id > AT.Bot.CUSTOM_COUNT then return false end
   end
   sel.kind, sel.id = kind, id
   LoadSelection()
   return true
end

-- Das gewaehlte feste Profil auf den Standard zuruecksetzen.
function P.ResetSelected()
   if not IsBuiltin() then return false end
   local key = sel.id
   if not AT.Bot.ResetBuiltin(key) then return false end
   LoadSelection()
   AT.Print("Profil " .. AT.Bot.BuiltinDefault(key).name .. " ist wieder auf den Standardwerten.")
   P.MarkDirty()
   return true
end

-- Anzeige neu laden (nach einem Zuruecksetzen per Befehl).
function P.Refresh() LoadSelection() end

-- Die frueheren Aufrufer kannten nur die drei eigenen Plaetze.
function P.LoadSlot(i) return P.Select("custom", i) end

-- Das gerade aktive Profil auswaehlen (beim Oeffnen der Seite).
local function SelectActive()
   local cur = AT.Bot.Current()
   if cur.customIndex then
      sel.kind, sel.id = "custom", cur.customIndex
   elseif AT.Bot.IsBuiltinKey(cur.key) then
      sel.kind, sel.id = "builtin", cur.key
   end
end

-- ---------------------------------------------------------------------------
-- Seite
-- ---------------------------------------------------------------------------

local function Build()
   if frame then return frame end

   frame = CreateFrame("Frame", "AutoTravelProfilePanel", UIParent)
   frame.name = "Profile"
   frame.parent = "AutoTravel"

   -- Der Inhalt liegt in einem ScrollFrame; alle Bausteine haengen an 'content'.
   local sf = CreateFrame("ScrollFrame", "AutoTravelProfileScroll", frame, "UIPanelScrollFrameTemplate")
   sf:SetPoint("TOPLEFT", 0, -4)
   sf:SetPoint("BOTTOMRIGHT", -28, 4)
   sf:EnableMouseWheel(true)
   sf:SetScript("OnMouseWheel", function(self, delta)
      local bar = _G["AutoTravelProfileScrollScrollBar"]
      if bar then bar:SetValue(bar:GetValue() - delta * 40) end
   end)

   content = CreateFrame("Frame", "AutoTravelProfileContent", sf)
   content:SetWidth(WIDTH)
   content:SetHeight(700)
   sf:SetScrollChild(content)

   local c = content

   local title = c:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
   title:SetPoint("TOPLEFT", 16, -16)
   title:SetText("Profile")

   local sub = c:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
   sub:SetPoint("TOPLEFT", 16, -38)
   sub:SetWidth(WIDTH - 24) sub:SetJustifyH("LEFT")
   sub:SetText("Die vorgegebenen Profile lassen sich aendern und auf ihre Standardwerte " ..
               "zuruecksetzen (ein * markiert geaenderte). Dazu drei frei belegbare eigene " ..
               "Profile. Alles gilt kontoweit auf allen Charakteren. Ein eigenes Profil " ..
               "erscheint in der Auswahl, sobald mindestens eine Strategie gesetzt ist.")
   sub:SetTextColor(0.6, 0.63, 0.68)

   -- Auswahl: sechs feste, drei eigene (zwei Zeilen)
   local entries = {}
   for _, d in ipairs(AT.Bot.Builtin) do table.insert(entries, { kind = "builtin", id = d.key, label = d.name }) end
   for i = 1, AT.Bot.CUSTOM_COUNT do table.insert(entries, { kind = "custom", id = i, label = "Eigenes " .. i }) end

   for i, e in ipairs(entries) do
      local col = (i - 1) % 5
      local row = math.floor((i - 1) / 5)
      local b = AT.UI.Button(c, 104, 22, e.label, function() P.Select(e.kind, e.id) end)
      b:SetPoint("TOPLEFT", 16 + col * 110, -92 - row * 28)
      table.insert(selButtons, { btn = b, kind = e.kind, id = e.id })
   end

   titleFs = c:CreateFontString(nil, "ARTWORK", "GameFontNormal")
   titleFs:SetPoint("TOPLEFT", 16, -158)
   titleFs:SetTextColor(0.35, 0.71, 0.91)

   descFs = c:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
   descFs:SetPoint("TOPLEFT", 16, -178)
   descFs:SetWidth(WIDTH - 24) descFs:SetJustifyH("LEFT")
   descFs:SetTextColor(0.6, 0.63, 0.68)

   -- Name (nur eigene Profile)
   nameLbl = c:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
   nameLbl:SetPoint("TOPLEFT", 16, -178)
   nameLbl:SetText("Name")

   nameEdit = CreateFrame("EditBox", "AutoTravelProfileName", c, "InputBoxTemplate")
   nameEdit:SetPoint("TOPLEFT", 20, -194)
   nameEdit:SetWidth(200) nameEdit:SetHeight(20)
   nameEdit:SetAutoFocus(false)
   nameEdit:SetMaxLetters(16)
   nameEdit:SetScript("OnEnterPressed", function()
      if IsBuiltin() then return end
      local cs = AT.Bot.CustomSlot(sel.id)
      local v = AT.trim(nameEdit:GetText())
      cs.name = (v ~= "") and v or ("Eigenes " .. sel.id)
      nameEdit:ClearFocus()
      AT.Print("Profil " .. sel.id .. " heisst jetzt: " .. cs.name)
      LoadSelection()
      P.MarkDirty()
   end)
   nameEdit:SetScript("OnEscapePressed", function() nameEdit:ClearFocus() LoadSelection() end)

   useBtn = AT.UI.Button(c, 150, 22, "Dieses Profil benutzen", function()
      local B = AT.Bot
      local v = View()
      if not IsBuiltin() and not B.CustomUsed(sel.id) then
         AT.Warn("Dieses Profil ist noch leer - erst Strategien setzen.")
         return
      end
      AT.Set("Profile", ProfileKey())
      AT.Print("Profil: |cffffffff" .. (v.name or "") .. "|r")
      if B.IsRunning() then B.ApplyProfile() end
      if AT.UI then AT.UI.Update() end
   end)
   useBtn:SetPoint("TOPLEFT", 240, -194)

   clearBtn = AT.UI.Button(c, 100, 22, "Leeren", function()
      if IsBuiltin() then return end
      local g = AT.Bot.Global()
      g.custom[sel.id] = nil
      AT.Bot.CustomSlot(sel.id)
      LoadSelection()
      AT.Print("Profil " .. sel.id .. " geleert.")
      if AT.UI then AT.UI.Update() end
   end)
   clearBtn:SetPoint("TOPLEFT", 400, -194)

   resetBtn = AT.UI.Button(c, 170, 22, "Auf Standard zuruecksetzen", function() P.ResetSelected() end)
   resetBtn:SetPoint("TOPLEFT", 400, -194)
   resetBtn.disabledTip = "Dieses Profil ist unveraendert."
   resetBtn.tip = function()
      GameTooltip:AddLine("Auf Standard zuruecksetzen")
      GameTooltip:AddLine("Verwirft alle Aenderungen an diesem Profil.", 0.7, 0.7, 0.7, true)
   end

   -- Wartezeit nach dem Kampf
   local graceLbl = c:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
   graceLbl:SetPoint("TOPLEFT", 16, -230)
   graceLbl:SetText("Wartezeit nach dem Kampf in Sekunden (der Bot kann looten)")

   graceEdit = CreateFrame("EditBox", "AutoTravelProfileGrace", c, "InputBoxTemplate")
   graceEdit:SetPoint("LEFT", graceLbl, "RIGHT", 12, 0)
   graceEdit:SetWidth(50) graceEdit:SetHeight(20)
   graceEdit:SetAutoFocus(false)
   graceEdit:SetScript("OnEnterPressed", function()
      local raw = string.gsub(AT.trim(graceEdit:GetText()), ",", ".")
      local v = tonumber(raw)
      graceEdit:ClearFocus()
      if not v then
         AT.Warn("Wartezeit: bitte eine Zahl zwischen " .. MIN_GRACE .. " und " .. MAX_GRACE .. " eingeben.")
         LoadSelection()
         return
      end
      if v < MIN_GRACE then v = MIN_GRACE end
      if v > MAX_GRACE then v = MAX_GRACE end
      Target().grace = v
      LoadSelection()
      AT.Print("Wartezeit gespeichert: " .. FormatGrace(v) .. " s")
      P.MarkDirty()
   end)
   graceEdit:SetScript("OnEscapePressed", function() graceEdit:ClearFocus() LoadSelection() end)

   -- Kampfstrategien
   local h1 = c:CreateFontString(nil, "ARTWORK", "GameFontNormal")
   h1:SetPoint("TOPLEFT", 16, -262)
   h1:SetText("Kampf  (co)")
   h1:SetTextColor(0.35, 0.71, 0.91)

   local line1 = c:CreateTexture(nil, "ARTWORK")
   line1:SetTexture(WHITE) line1:SetVertexColor(0.25, 0.28, 0.33, 0.8)
   line1:SetPoint("TOPLEFT", 16, -280) line1:SetWidth(WIDTH - 20) line1:SetHeight(1)

   for i, f in ipairs(AT.Bot.CombatFlags) do
      local col = (i - 1) % 3
      local row = math.floor((i - 1) / 3)
      FlagBox(c, f[1], f[2], 16 + col * 190, -290 - row * 22, "combat")
   end

   local rows = math.ceil(#AT.Bot.CombatFlags / 3)
   local yn = -290 - rows * 22 - 14

   -- Nichtkampf
   local h2 = c:CreateFontString(nil, "ARTWORK", "GameFontNormal")
   h2:SetPoint("TOPLEFT", 16, yn)
   h2:SetText("Ausserhalb des Kampfes  (nc)")
   h2:SetTextColor(0.35, 0.71, 0.91)

   local line2 = c:CreateTexture(nil, "ARTWORK")
   line2:SetTexture(WHITE) line2:SetVertexColor(0.25, 0.28, 0.33, 0.8)
   line2:SetPoint("TOPLEFT", 16, yn - 18) line2:SetWidth(WIDTH - 20) line2:SetHeight(1)

   -- Die Liste der festen Profile enthaelt eine Strategie mehr ("gather").
   local ncList = AT.Bot.BuiltinNonCombatFlags
   local plain = {}
   for _, f in ipairs(AT.Bot.NonCombatFlags) do plain[f[1]] = true end
   for i, f in ipairs(ncList) do
      local col = (i - 1) % 3
      local row = math.floor((i - 1) / 3)
      FlagBox(c, f[1], f[2], 16 + col * 190, yn - 28 - row * 22, "noncombat", not plain[f[1]])
   end

   local yr = yn - 28 - math.ceil(#ncList / 3) * 22 - 16

   -- Freitext
   local exLbl = c:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
   exLbl:SetPoint("TOPLEFT", 16, yr)
   exLbl:SetText("Zusaetzliche Befehle, mit Semikolon getrennt (z. B. ll normal; ll skill)")

   extraEdit = CreateFrame("EditBox", "AutoTravelProfileExtra", c, "InputBoxTemplate")
   extraEdit:SetPoint("TOPLEFT", 20, yr - 18)
   extraEdit:SetWidth(WIDTH - 40) extraEdit:SetHeight(20)
   extraEdit:SetAutoFocus(false)
   extraEdit:SetScript("OnEnterPressed", function()
      Target().extra = AT.trim(extraEdit:GetText())
      extraEdit:ClearFocus()
      AT.Print("Zusatzbefehle gespeichert.")
      LoadSelection()
      P.MarkDirty()
   end)
   extraEdit:SetScript("OnEscapePressed", function() extraEdit:ClearFocus() LoadSelection() end)

   hintFs = c:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
   hintFs:SetPoint("TOPLEFT", 20, yr - 46)
   hintFs:SetWidth(WIDTH - 40) hintFs:SetJustifyH("LEFT")

   content:SetHeight(math.abs(yr) + 110)

   frame.refresh = function() LoadSelection() end
   frame.okay    = function() end
   frame.cancel  = function() end

   if InterfaceOptions_AddCategory then
      InterfaceOptions_AddCategory(frame)
   end
   return frame
end

function P.Open()
   Build()
   SelectActive()
   LoadSelection()
   if InterfaceOptionsFrame_OpenToCategory then
      InterfaceOptionsFrame_OpenToCategory(frame)
      InterfaceOptionsFrame_OpenToCategory(frame)
   end
end

function P.Init()
   Build()
   SelectActive()
   LoadSelection()
end
