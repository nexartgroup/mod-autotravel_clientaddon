-- AT_MapIds.lua
-- ---------------------------------------------------------------------------
-- Carbonite kennt seine Zonen unter eigenen Indizes (Nx.MITN[index] = Name).
-- Das Servermodul braucht dagegen die WorldMapArea-ID aus WoW, denn nur damit
-- laesst sich per WorldMapArea.dbc exakt in Weltkoordinaten umrechnen.
--
-- Die Bruecke ist der lokalisierte Zonenname. Beim ersten Bedarf wird einmal
-- ueber alle Kontinente und Zonen iteriert:
--
--     SetMapZoom(kontinent, zone)  ->  GetCurrentMapAreaID()
--
-- Damit entsteht Name -> ID, ganz ohne fest eingebaute Tabelle. Beide Seiten
-- liefern denselben lokalisierten Namen, also passt die Zuordnung auch auf
-- deutschen Clients.
-- ---------------------------------------------------------------------------

AutoTravel = AutoTravel or {}
local AT = AutoTravel

AT.MapIds = {}
local M = AT.MapIds

local byName = nil
local built  = false

-- Karte per ID einstellen und PRUEFEN, ob es geklappt hat.
--
-- In 3.3.5a landet SetMapByID(id) nach Blizzards eigenem Code eine Karte neben
-- dem Erwarteten: WorldMapFrame_ToggleWindowSize ruft SetMapByID(
-- GetCurrentMapAreaID() - 1). Das waere auch die Erklaerung fuer die um eins
-- verschobenen Karten-IDs, die der Server aus der Position zurueckrechnen muss.
-- Ohne Spiel laesst sich das nicht entscheiden; deshalb werden beide Werte
-- versucht und nur das gilt, was GetCurrentMapAreaID() danach bestaetigt.
local function SetMap(id)
   if not SetMapByID or not GetCurrentMapAreaID or not id or id <= 0 then return false end
   pcall(SetMapByID, id)
   if GetCurrentMapAreaID() == id then return true end
   pcall(SetMapByID, id - 1)
   return GetCurrentMapAreaID() == id
end
M.SetMap = SetMap

-- Die vorher angezeigte Karte wiederherstellen; ist das nicht moeglich, zur Zone
-- des Charakters zurueck.
local function RestoreMap(prev)
   if prev and prev > 0 and SetMap(prev) then return end
   if SetMapToCurrentZone then pcall(SetMapToCurrentZone) end
end

local function norm(s)
   if type(s) ~= "string" then return nil end
   s = string.gsub(s, "^%s*(.-)%s*$", "%1")
   if s == "" then return nil end
   return string.lower(s)
end

function M.Build(force)
   if built and not force then return byName end
   byName = {}

   if not GetMapContinents or not SetMapZoom or not GetCurrentMapAreaID then
      built = true
      return byName
   end

   -- aktuelle Kartenansicht merken
   local prev = GetCurrentMapAreaID()

   local conts = { GetMapContinents() }
   for c = 1, #conts do
      local cname = norm(conts[c])
      SetMapZoom(c, 0)
      local cid = GetCurrentMapAreaID()
      if cname and cid and cid > 0 and not byName[cname] then byName[cname] = cid end

      local zones = { GetMapZones(c) }
      for z = 1, #zones do
         SetMapZoom(c, z)
         local id = GetCurrentMapAreaID()
         local zn = norm(zones[z])
         if zn and id and id > 0 and not byName[zn] then byName[zn] = id end
      end
   end

   -- Ansicht zuruecksetzen
   RestoreMap(prev)

   built = true
   local n = 0
   for _ in pairs(byName) do n = n + 1 end
   if AT.Debug then AT.Debug("Kartentabelle aufgebaut: " .. n .. " Zonen.") end
   return byName
end

-- Zonenname -> WorldMapArea-ID
function M.Resolve(name)
   if not name then return nil end
   M.Build()
   local key = norm(name)
   if not key then return nil end

   local id = byName[key]
   if id then return id end

   -- Carbonite haengt gelegentlich Zusaetze an ("Loch Modan (Instanz)").
   local base = string.match(key, "^([^%(]+)")
   if base then
      base = string.gsub(base, "%s+$", "")
      if byName[base] then return byName[base] end
   end
   return nil
end

function M.Count()
   M.Build()
   local n = 0
   for _ in pairs(byName or {}) do n = n + 1 end
   return n
end

-- Karten-ID UND normalisierte eigene Position der Zone, in der der Charakter
-- gerade steht. Der Server prueft damit die Zuordnung Client-ID ->
-- WorldMapArea-ID gegen die ihm bekannte echte Position -- auch dann, wenn
-- das Ziel in einer anderen Zone liegt.
-- Rueckgabe: mapId, nx, ny  (0,0,0 wenn nicht ermittelbar)
function M.SelfSample()
   local prev = GetCurrentMapAreaID and GetCurrentMapAreaID() or 0
   if SetMapToCurrentZone then pcall(SetMapToCurrentZone) end

   local id = GetCurrentMapAreaID and GetCurrentMapAreaID() or 0
   local px, py = GetPlayerMapPosition("player")

   if prev and prev > 0 and prev ~= id then
      RestoreMap(prev)
   end

   if id and id > 0 and px and py and (px > 0 or py > 0) then
      return id, px, py
   end
   return 0, 0, 0
end

-- Karten-ID der Zone, in der der Charakter gerade steht
function M.Current()
   if SetMapToCurrentZone then pcall(SetMapToCurrentZone) end
   return GetCurrentMapAreaID and GetCurrentMapAreaID() or nil
end

-- Normalisierte Position des Charakters auf der angegebenen Karte.
-- Rueckgabe: 1, px, py  wenn der Charakter auf dieser Karte steht, sonst 0,0,0
function M.Calibration(uiMapId)
   if not uiMapId or not GetPlayerMapPosition then return 0, 0, 0 end
   local prev = GetCurrentMapAreaID and GetCurrentMapAreaID() or 0
   local switched = false

   -- SetMap() prueft, ob die Karte wirklich gewechselt hat. pcall allein meldet
   -- Erfolg, auch wenn SetMapByID die Karte gar nicht gewechselt hat; dann
   -- lieferte GetPlayerMapPosition die Position auf der ALTEN Karte, und der
   -- Server bekaeme eine Gegenprobe, die zu einer ganz anderen Zone gehoert.
   if prev ~= uiMapId then
      switched = true                  -- die Ansicht kann sich bewegt haben, auch bei Misserfolg
      SetMap(uiMapId)
   end

   local shown = GetCurrentMapAreaID and GetCurrentMapAreaID() or 0
   local px, py = 0, 0
   if shown == uiMapId then
      px, py = GetPlayerMapPosition("player")
   end

   if switched then RestoreMap(prev) end

   if px and py and (px > 0 or py > 0) then return 1, px, py end
   return 0, 0, 0
end
