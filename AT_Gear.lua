-- AT_Gear.lua
-- ---------------------------------------------------------------------------
-- Schutz fuer Erbstuecke (Qualitaetsstufe 7).
--
-- AutoTravel selbst sendet nie einen Ausruestungsbefehl. Trotzdem kann der
-- Playerbot Gegenstaende tauschen -- durch Loot-Upgrades, Serverkonfiguration
-- oder Strategien, die wir nicht kontrollieren. Bei normaler Ausruestung ist
-- das gewollt. Bei accountgebundenen Erbstuecken nicht: die sind teuer
-- erarbeitet und tragen Erfahrungsboni.
--
-- Verhindern laesst sich das vom Client aus nicht -- der Tausch passiert
-- serverseitig. Ueberwachen und rueckgaengig machen schon:
--
--   1. Beim Start der Reise werden alle angelegten Teile mit Qualitaet 7
--      erfasst (Slot, Gegenstands-ID, Link).
--   2. Aendert sich ein ueberwachter Slot, wird geprueft, ob das Erbstueck
--      noch in den Taschen liegt.
--   3. Wenn ja, bekommt der Bot "e [Erbstueck]" geflüstert und legt es
--      wieder an.
--
-- Nur Qualitaet 7 wird angefasst. Alles andere darf der Bot frei tauschen.
-- ---------------------------------------------------------------------------

AutoTravel = AutoTravel or {}
local AT = AutoTravel

AT.Gear = {}
local G = AT.Gear

local HEIRLOOM = 7
local MAX_TRIES = 3

-- Alle Ausruestungsplaetze ausser Hemd und Wappenrock (dort gibt es keine
-- Erbstuecke, und ein Tausch waere harmlos).
local SLOTS = {
   1,  -- Kopf
   2,  -- Hals
   3,  -- Schulter
   5,  -- Brust
   6,  -- Guertel
   7,  -- Beine
   8,  -- Fuesse
   9,  -- Handgelenke
   10, -- Haende
   11, 12, -- Ringe
   13, 14, -- Schmuck
   15, -- Umhang
   16, 17, 18, -- Waffen und Distanzwaffe
}

G.guarded = {}      -- slot -> { id, link, name, tries }
G.enabled = false

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
         if link and ItemId(link) == id then
            return bag, slot, link
         end
      end
   end
   return nil
end
G.FindInBags = FindInBags

-- ---------------------------------------------------------------------------
-- Erfassen
-- ---------------------------------------------------------------------------

function G.Snapshot(silent)
   G.guarded = {}
   if not AT.GetBool("GuardHeirlooms") then return 0 end

   local n = 0
   for _, slot in ipairs(SLOTS) do
      local quality = GetInventoryItemQuality("player", slot)
      if quality == HEIRLOOM then
         local link = GetInventoryItemLink("player", slot)
         local id = ItemId(link)
         if id then
            G.guarded[slot] = { id = id, link = link, tries = 0 }
            n = n + 1
         end
      end
   end

   if not silent then
      if n > 0 then
         AT.Debug(n .. " Erbstueck(e) unter Beobachtung.")
      else
         AT.Debug("Keine Erbstuecke angelegt.")
      end
   end
   return n
end

function G.Start()
   G.enabled = AT.GetBool("GuardHeirlooms")
   if G.enabled then G.Snapshot() end
end

function G.Stop()
   G.enabled = false
   G.guarded = {}
end

-- ---------------------------------------------------------------------------
-- Ueberwachen
-- ---------------------------------------------------------------------------

local function CheckSlot(slot)
   local watch = G.guarded[slot]
   if not watch then return end

   local link = GetInventoryItemLink("player", slot)
   if link and ItemId(link) == watch.id then
      watch.tries = 0
      return                            -- alles unveraendert
   end

   -- Slot hat sich geaendert. Liegt das Erbstueck noch in den Taschen?
   local bag, bslot, blink = FindInBags(watch.id)
   if not bag then
      AT.Warn("Erbstueck aus Platz " .. slot .. " ist weg und nicht in den Taschen. " ..
              "Ueberwachung fuer diesen Platz beendet.")
      G.guarded[slot] = nil
      return
   end

   watch.tries = (watch.tries or 0) + 1
   if watch.tries > MAX_TRIES then
      AT.Warn("Erbstueck " .. (blink or watch.link or "?") ..
              " liess sich nicht wieder anlegen - Ueberwachung fuer diesen Platz beendet.")
      G.guarded[slot] = nil
      return
   end

   AT.Print("Erbstueck wurde ersetzt - lege " .. (blink or watch.link) .. " wieder an.")
   AT.Bot.Whisper("e " .. (blink or watch.link))
end

function G.CheckAll()
   if not G.enabled then return end
   for slot in pairs(G.guarded) do
      CheckSlot(slot)
   end
end

-- ---------------------------------------------------------------------------
-- Ereignisse
-- ---------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ev:RegisterEvent("UNIT_INVENTORY_CHANGED")

local pending = false
local timer = 0

ev:SetScript("OnEvent", function(self, event, arg1)
   if not G.enabled then return end
   if event == "UNIT_INVENTORY_CHANGED" and arg1 ~= "player" then return end
   -- Kurz warten: beim Tausch feuern mehrere Ereignisse, und der Slot ist
   -- erst danach in seinem Endzustand.
   pending = true
   timer = 0
end)

ev:SetScript("OnUpdate", function(self, elapsed)
   if not pending then return end
   timer = timer + elapsed
   if timer < 0.5 then return end
   pending = false
   timer = 0
   G.CheckAll()
end)

-- ---------------------------------------------------------------------------

function G.Report()
   local n = 0
   for slot, w in pairs(G.guarded) do
      n = n + 1
      DEFAULT_CHAT_FRAME:AddMessage(string.format("   Platz %2d  %s", slot, w.link or "?"))
   end
   if n == 0 then
      AT.Print("Keine Erbstuecke unter Beobachtung." ..
               (AT.GetBool("GuardHeirlooms") and "" or " (Schutz ist aus)"))
   else
      AT.Print(n .. " Erbstueck(e) unter Beobachtung:")
   end
end
