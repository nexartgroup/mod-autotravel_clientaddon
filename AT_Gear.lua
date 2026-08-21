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
local MAX_TRIES = 4
local RETRY_GAP = 2.0        -- Sekunden zwischen zwei Rueckversuchen je Platz

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
            if not w or w.id ~= id then
               G.guarded[slot] = { id = id, link = link, tries = 0, lastTry = 0 }
            else
               w.link = link
               w.tries = 0
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
-- Pruefen
-- ---------------------------------------------------------------------------

local function CheckSlot(slot, now)
   local w = G.guarded[slot]
   if not w then return end

   local quality = GetInventoryItemQuality("player", slot)
   local link = GetInventoryItemLink("player", slot)

   if link and ItemId(link) == w.id then
      w.tries = 0
      return                                   -- unveraendert
   end

   if quality == HEIRLOOM and link then
      -- Erbstueck gegen Erbstueck getauscht: gewollt, neuen Stand uebernehmen.
      G.guarded[slot] = { id = ItemId(link), link = link, tries = 0, lastTry = 0 }
      return
   end

   if (now - (w.lastTry or 0)) < RETRY_GAP then return end

   local bag, bslot, blink = FindInBags(w.id)
   if not bag then
      AT.Warn("Erbstueck aus Platz " .. slot .. " ist weder angelegt noch in den Taschen. " ..
              "Ueberwachung fuer diesen Platz beendet.")
      G.guarded[slot] = nil
      return
   end

   w.tries = (w.tries or 0) + 1
   w.lastTry = now
   if w.tries > MAX_TRIES then
      AT.Warn("Erbstueck " .. (blink or w.link or "?") ..
              " liess sich nicht wieder anlegen - Ueberwachung fuer diesen Platz beendet.")
      G.guarded[slot] = nil
      return
   end

   G.restored = G.restored + 1
   AT.Print("Erbstueck wurde ersetzt - lege " .. (blink or w.link) .. " wieder an.")
   AT.Bot.Whisper("e " .. (blink or w.link))
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
function G.Stop()   end                     -- Ueberwachung laeuft weiter

function G.Report()
   local n = 0
   for slot, w in pairs(G.guarded) do
      n = n + 1
      DEFAULT_CHAT_FRAME:AddMessage(string.format("   Platz %2d  %s", slot, w.link or "?"))
   end
   local mode = AT.GetBool("GuardAlways") and "immer" or "nur waehrend der Reise"
   if not AT.GetBool("GuardHeirlooms") then
      AT.Print("Erbstueckschutz ist |cffff8800aus|r.")
   elseif n == 0 then
      AT.Print("Keine Erbstuecke angelegt. Schutz: " .. mode .. ".")
   else
      AT.Print(n .. " Erbstueck(e) unter Beobachtung (" .. mode .. "), " ..
               G.restored .. " Ruecktausch(e) bisher:")
   end
end
