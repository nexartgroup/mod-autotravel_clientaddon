-- AT_Gear.lua
-- ---------------------------------------------------------------------------
-- Schutz fuer Erbstuecke (Qualitaetsstufe 7).
--
-- Verhindern laesst sich ein Tausch vom Client aus nicht -- er passiert
-- serverseitig. Ueberwachen und rueckgaengig machen schon.
--
-- Der erste Anlauf hat waehrend Kaempfen und beim Looten Wechsel durchgehen
-- lassen. Zwei Gruende:
--
--   1. Die Ueberwachung lief nur waehrend einer Reise. Der Bot tauscht aber
--      auch dann, wenn AutoTravel gerade nichts tut.
--   2. Sie haing allein an PLAYER_EQUIPMENT_CHANGED. Bei Loot-Salven feuern
--      viele Ereignisse dicht hintereinander, und die Sperre nach dem ersten
--      Rueckversuch lief noch, wenn der naechste Tausch kam.
--
-- Deshalb jetzt: eine dauerhafte Pruefung im Sekundentakt, unabhaengig von
-- Ereignissen, und optional auch bei ausgeschaltetem Bot.
--
-- Ein Erbstueck darf durch ein ANDERES Erbstueck ersetzt werden -- das ist ein
-- gewollter Wechsel. Nur der Weg von Qualitaet 7 auf etwas anderes wird
-- zurueckgenommen.
-- ---------------------------------------------------------------------------

AutoTravel = AutoTravel or {}
local AT = AutoTravel

AT.Gear = {}
local G = AT.Gear

local HEIRLOOM = 7
local MAX_TRIES = 4          -- danach wird nicht aufgegeben, sondern gebremst
local RETRY_GAP = 2.0        -- Sekunden zwischen zwei Rueckversuchen je Platz
local BACKOFF_GAP = 20.0     -- Wartezeit, nachdem es mehrfach nicht klappte

local SLOTS = { 1,2,3,5,6,7,8,9,10,11,12,13,14,15,16,17,18 }

G.guarded = {}               -- slot -> { id, link, tries, lastTry }
G.restored = 0

-- ---------------------------------------------------------------------------

local function ItemId(link)
   if type(link) ~= "string" then return nil end
   local id = string.match(link, "item:(%d+)")
   return id and tonumber(id) or nil
end
G.ItemId = ItemId

local function FindInBags(id)
   for bag = 0, 4 do
      local slots = GetContainerNumSlots(bag) or 0
      for slot = 1, slots do
         local link = GetContainerItemLink(bag, slot)
         if link and ItemId(link) == id then return bag, slot, link end
      end
   end
   return nil
end
G.FindInBags = FindInBags

-- Schutz aktiv? Entweder dauerhaft oder nur waehrend einer Reise.
function G.IsActive()
   if not AT.GetBool("GuardHeirlooms") then return false end
   if AT.GetBool("GuardAlways") then return true end
   return AT.active == true
end

-- ---------------------------------------------------------------------------
-- Erfassen und nachfuehren
-- ---------------------------------------------------------------------------

-- Neue Erbstuecke uebernehmen, verschwundene nicht anfassen.
function G.Adopt()
   local n = 0
   for _, slot in ipairs(SLOTS) do
      if GetInventoryItemQuality("player", slot) == HEIRLOOM then
         local link = GetInventoryItemLink("player", slot)
         local id = ItemId(link)
         if id then
            local w = G.guarded[slot]
            if not w then
               G.guarded[slot] = { id = id, link = link, tries = 0, lastTry = 0 }
            elseif w.id ~= id then
               -- Erbstueck gegen anderes Erbstueck: gewollter Wechsel
               G.guarded[slot] = { id = id, link = link, tries = 0, lastTry = 0,
                                   cycles = w.cycles }
            else
               -- Unveraendert. Den Versuchszaehler NICHT anfassen -- sonst
               -- kann CheckSlot einen Erfolg nicht mehr von "war nie weg"
               -- unterscheiden und meldet nie, dass es geklappt hat.
               w.link = link
            end
            n = n + 1
         end
      end
   end
   return n
end

function G.Snapshot(silent)
   G.guarded = {}
   local n = G.Adopt()
   if not silent then
      AT.Debug(n .. " Erbstueck(e) unter Beobachtung.")
   end
   return n
end

-- ---------------------------------------------------------------------------
-- Anlegen
-- ---------------------------------------------------------------------------
-- Erster Anlauf hat den Bot per "e [Gegenstand]" darum gebeten. Das kam beim
-- Test nicht an -- vier Versuche, keine Reaktion.
--
-- Der Client kann das selbst: PickupContainerItem und EquipCursorItem sind in
-- 3.3.5a nicht geschuetzt (Sortier-Addons benutzen sie). Das ist der direkte
-- Weg ohne Umweg ueber den Bot. Der Botbefehl bleibt als Rueckfallebene.
--
-- Im Kampf verweigert der Server das Anlegen von Ruestung. Dann wird nicht
-- versucht, sondern gewartet.

local function CanEquipNow()
   if UnitAffectingCombat("player") then return false, "im Kampf" end
   if UnitIsDeadOrGhost("player") then return false, "tot" end
   if SpellIsTargeting and SpellIsTargeting() then return false, "Zauber aktiv" end
   if CursorHasItem and CursorHasItem() then return false, "Mauszeiger belegt" end
   return true
end
G.CanEquipNow = CanEquipNow

-- Drei Wege, ein Teil anzulegen. Welcher auf diesem Client funktioniert, weiss
-- ich nicht sicher -- deshalb wird reihum jeder probiert und im Debug
-- protokolliert, welcher es war. Raten hilft hier nicht weiter.
--
--   1. EquipItemByName  -- das, was auch /equip benutzt
--   2. Mauszeiger       -- PickupContainerItem + EquipCursorItem
--   3. Botbefehl        -- "e [Gegenstand]" per Fluestern
--
-- Wichtig beim Mauszeigerweg: nach EquipCursorItem NICHT sofort ClearCursor
-- aufrufen. Landet das abgelegte Teil auf dem Zeiger, wuerde das den Vorgang
-- abbrechen. Aufgeraeumt wird im naechsten Takt.

G.lastMethod = nil

local function EquipByName(link, invSlot)
   if not EquipItemByName then return false end
   EquipItemByName(link, invSlot)
   return true
end

local function EquipByCursor(bag, bslot, invSlot)
   if not PickupContainerItem or not EquipCursorItem then return false end
   if CursorHasItem() then ClearCursor() end
   PickupContainerItem(bag, bslot)
   if not CursorHasItem() then return false end
   EquipCursorItem(invSlot)
   G.cursorCleanup = GetTime() + 0.6
   return true
end

local function EquipByBot(link)
   local cmd = AT.Get("EquipCommand") or "e %s"
   AT.Bot.Whisper(string.format(cmd, link))
   return true
end

-- attempt = laufende Versuchsnummer, bestimmt den Weg
local function DoEquip(attempt, bag, bslot, invSlot, link)
   local order = { "name", "cursor", "bot" }
   local pick = order[((attempt - 1) % 3) + 1]

   local ok = false
   if pick == "name" then ok = EquipByName(link, invSlot)
   elseif pick == "cursor" then ok = EquipByCursor(bag, bslot, invSlot)
   else ok = EquipByBot(link) end

   if not ok then
      -- Weg nicht verfuegbar: sofort den naechsten nehmen
      for _, alt in ipairs(order) do
         if alt ~= pick then
            if alt == "name" then ok = EquipByName(link, invSlot)
            elseif alt == "cursor" then ok = EquipByCursor(bag, bslot, invSlot)
            else ok = EquipByBot(link) end
            if ok then pick = alt break end
         end
      end
   end

   G.lastMethod = pick
   return ok, pick
end
G.DoEquip = DoEquip

-- ---------------------------------------------------------------------------
-- Pruefen
-- ---------------------------------------------------------------------------

local function CheckSlot(slot, now)
   local w = G.guarded[slot]
   if not w then return end

   local quality = GetInventoryItemQuality("player", slot)
   local link = GetInventoryItemLink("player", slot)

   if link and ItemId(link) == w.id then
      if (w.tries or 0) > 0 then
         G.restored = G.restored + 1
         AT.Print("|cff53d17aErbstueck wieder angelegt|r: " .. (w.link or link) ..
                  (G.lastMethod and (" |cff8a90a0(" .. G.lastMethod .. ", Versuch " ..
                   w.tries .. ")|r") or ""))
         -- Wird uns dasselbe Teil gleich wieder abgenommen, ist das kein
         -- Bot-Unfall, sondern Absicht. Dann nicht endlos dagegenhalten.
         w.cycles = (w.cycles or 0) + 1
         w.tries = 0
         if w.cycles >= 3 then
            AT.Warn("Platz " .. slot .. " wurde " .. w.cycles ..
                    "-mal nach dem Zuruecklegen wieder geaendert.")
            AT.Warn("Das ist kein Ausrutscher: entweder legst du selbst um, oder der " ..
                    "Bot tauscht systematisch. Ich lasse den Platz jetzt in Ruhe.")
            AT.Warn("Dauerhaft abstellen laesst sich das nur serverseitig - in " ..
                    "playerbots.conf gibt es Optionen zum automatischen Ausruesten.")
            AT.Warn("'/at erbstuecke neu' nimmt den Platz wieder auf.")
            G.guarded[slot] = nil
            return
         end
      end
      w.tries = 0
      w.missing = 0
      return                                   -- unveraendert
   end

   if quality == HEIRLOOM and link then
      -- Erbstueck gegen Erbstueck getauscht: gewollt, neuen Stand uebernehmen.
      G.guarded[slot] = { id = ItemId(link), link = link, tries = 0, lastTry = 0 }
      return
   end

   if w.tries == 0 then
      -- Erster Befund: festhalten, wodurch ersetzt wurde. Das sagt mehr ueber
      -- die Ursache als jede Vermutung.
      w.replacedBy = link or "nichts"
      AT.Debug("Platz " .. slot .. " ersetzt durch " .. tostring(w.replacedBy))
   end

   local gap = (w.tries or 0) >= MAX_TRIES and BACKOFF_GAP or RETRY_GAP
   if (now - (w.lastTry or 0)) < gap then return end

   local bag, bslot, blink = FindInBags(w.id)
   if not bag then
      -- Kann voruebergehend sein: der Tausch ist noch nicht abgeschlossen.
      w.missing = (w.missing or 0) + 1
      w.lastTry = now
      if w.missing >= 3 then
         AT.Warn("Erbstueck aus Platz " .. slot .. " ist weder angelegt noch in den " ..
                 "Taschen. Ueberwachung fuer diesen Platz beendet.")
         G.guarded[slot] = nil
      end
      return
   end
   w.missing = 0

   local ok, why = CanEquipNow()
   if not ok then
      w.lastTry = now - gap + 1.0      -- bald erneut versuchen
      if not w.waitedFor then
         w.waitedFor = why
         AT.Debug("Erbstueck kann gerade nicht angelegt werden (" .. why .. ") - warte.")
      end
      return
   end
   w.waitedFor = nil

   w.tries = (w.tries or 0) + 1
   w.lastTry = now

   local _, how = DoEquip(w.tries, bag, bslot, slot, blink or w.link)
   AT.Debug(string.format("Anlegeversuch %d ueber '%s' (Tasche %d/%d -> Platz %d)",
            w.tries, tostring(how), bag, bslot, slot))

   if w.tries == 1 then
      AT.Print("Erbstueck wurde ersetzt durch " .. tostring(w.replacedBy or "?") ..
               " - lege " .. (blink or w.link) .. " wieder an.")
   elseif w.tries == MAX_TRIES then
      AT.Warn("Erbstueck " .. (blink or w.link) .. " laesst sich nicht anlegen. " ..
              "Weitere Versuche nur noch alle " .. math.floor(BACKOFF_GAP) .. " Sekunden.")
      AT.Warn("Moegliche Gruende: Stufen- oder Klassenanforderung, Platz belegt, " ..
              "oder der Bot legt sofort wieder um. '/at erbstuecke' zeigt den Stand.")
   else
      AT.Debug("Erbstueck-Rueckversuch " .. w.tries .. " (" .. how .. ")")
   end
end

function G.CheckAll()
   if not G.IsActive() then return end
   local now = GetTime()
   for slot in pairs(G.guarded) do
      CheckSlot(slot, now)
   end
end

-- ---------------------------------------------------------------------------
-- Takt und Ereignisse
-- ---------------------------------------------------------------------------

local ticker = CreateFrame("Frame")
local acc, evAcc, evPending = 0, 0, false

ticker:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ticker:RegisterEvent("UNIT_INVENTORY_CHANGED")
ticker:RegisterEvent("PLAYER_ENTERING_WORLD")

ticker:SetScript("OnEvent", function(self, event, arg1)
   if event == "PLAYER_ENTERING_WORLD" then
      G.Snapshot(true)
      return
   end
   if event == "UNIT_INVENTORY_CHANGED" and arg1 ~= "player" then return end
   evPending = true
   evAcc = 0
end)

ticker:SetScript("OnUpdate", function(self, elapsed)
   -- Liegt nach einem Anlegeversuch noch etwas auf dem Zeiger, zurueckgeben.
   if G.cursorCleanup and GetTime() > G.cursorCleanup then
      G.cursorCleanup = nil
      if CursorHasItem and CursorHasItem() then
         ClearCursor()
         AT.Debug("Mauszeiger nach Anlegeversuch geleert.")
      end
   end

   -- Ereignisgesteuert: kurz abwarten, bis der Tausch abgeschlossen ist.
   if evPending then
      evAcc = evAcc + elapsed
      if evAcc >= 0.4 then
         evPending = false
         evAcc = 0
         G.Adopt()
         G.CheckAll()
      end
   end

   -- Dauerlauf: faengt alles, was zwischen den Ereignissen durchrutscht --
   -- gerade bei Loot-Salven und im Kampf.
   acc = acc + elapsed
   if acc < 1.0 then return end
   acc = 0
   if not G.IsActive() then return end
   G.Adopt()
   G.CheckAll()
end)

-- ---------------------------------------------------------------------------

function G.Start()  G.Snapshot(true) end

-- Welche Anlege-Funktionen kennt dieser Client ueberhaupt?
function G.Probe()
   AT.Print("Verfuegbare Anlegewege:")
   DEFAULT_CHAT_FRAME:AddMessage("   EquipItemByName      " ..
      (EquipItemByName and "|cff53d17ada|r" or "|cffe8654afehlt|r"))
   DEFAULT_CHAT_FRAME:AddMessage("   PickupContainerItem  " ..
      (PickupContainerItem and "|cff53d17ada|r" or "|cffe8654afehlt|r"))
   DEFAULT_CHAT_FRAME:AddMessage("   EquipCursorItem      " ..
      (EquipCursorItem and "|cff53d17ada|r" or "|cffe8654afehlt|r"))
   local can, why = CanEquipNow()
   DEFAULT_CHAT_FRAME:AddMessage("   Anlegen jetzt        " ..
      (can and "|cff53d17amoeglich|r" or ("|cffe8c44a" .. why .. "|r")))
   if G.lastMethod then
      DEFAULT_CHAT_FRAME:AddMessage("   zuletzt benutzt      " .. G.lastMethod)
   end
end
function G.Stop()   end                     -- Ueberwachung laeuft weiter

function G.Report()
   local n = 0
   for slot, w in pairs(G.guarded) do
      n = n + 1
      local now = GetInventoryItemLink("player", slot)
      local ok = (now and ItemId(now) == w.id)
      DEFAULT_CHAT_FRAME:AddMessage(string.format("   Platz %2d  %s  %s%s%s",
         slot, w.link or "?",
         ok and "|cff53d17aangelegt|r" or "|cffe8654aFEHLT|r",
         (w.tries or 0) > 0 and ("  |cff8a90a0" .. w.tries .. " Versuch(e)|r") or "",
         (w.cycles or 0) > 0 and ("  |cffe8c44a" .. w.cycles .. "x zurueckgeholt|r") or ""))
   end
   local can, why = CanEquipNow()
   if not can then
      DEFAULT_CHAT_FRAME:AddMessage("   |cffe8c44aAnlegen gerade nicht moeglich: " .. why .. "|r")
   end
   local mode = AT.GetBool("GuardAlways") and "immer" or "nur waehrend der Reise"
   if not AT.GetBool("GuardHeirlooms") then
      AT.Print("Erbstueckschutz ist |cffff8800aus|r.")
   elseif n == 0 then
      AT.Print("Keine Erbstuecke angelegt. Schutz: " .. mode .. ".")
   else
      AT.Print(n .. " Erbstueck(e) unter Beobachtung (" .. mode .. "), " ..
               G.restored .. " erfolgreiche(r) Ruecktausch(e) bisher:")
   end
end
