-- AT_Carbonite.lua
-- ---------------------------------------------------------------------------
-- Zugriff auf Carbonite (Nx).
--
-- Der Zugriffsweg stammt aus BotTravel 2.0 und ist dort nachweislich
-- funktionsfaehig:
--
--   Nx.Map:GeM(1)        Kartenobjekt
--     .Tar               gesetzte Ziele
--     .Tra1              berechnete Route; Eintrag.Mod == "F" ist Flugroute
--     .PlX / .PlY        eigene Position in Carbonite-Kontinentkoordinaten
--     :GZP(MaI, x, y)    Kontinent- -> Zonenkoordinaten (0-100)
--   Nx.MITN[MaI]         Kartenname
--
-- Entscheidender Punkt fuer AutoTravel: TMX/TMY der Routeneintraege und
-- PlX/PlY des Spielers liegen im selben System. AutoTravel braucht davon im
-- Normalfall nur EINEN Wert -- den letzten Routenpunkt, also das eigentliche
-- Ziel. Die Zwischenpunkte werden nur im Fallback-Korridormodus benutzt.
-- ---------------------------------------------------------------------------

AutoTravel = AutoTravel or {}
local AT = AutoTravel

AT.Carb = {}
local CB = AT.Carb

CB.YARDS_PER_UNIT = 4.575     -- eine Carbonite-Einheit in Yards

local function GetMap()
   if not Nx or not Nx.Map or not Nx.Map.GeM then return nil end
   local ok, map = pcall(function() return Nx.Map:GeM(1) end)
   if ok and type(map) == "table" then return map end
   return nil
end
CB.GetMap = GetMap

function CB.IsAvailable()
   return GetMap() ~= nil
end

-- Eigene Position in Carbonite-Kontinentkoordinaten
function CB.GetPlayerCarb()
   local map = GetMap()
   if not map then return nil end
   local x, y = map.PlX, map.PlY
   if type(x) == "number" and type(y) == "number" then return x, y end
   return nil
end

local function MapName(idx)
   if Nx and Nx.MITN and idx then return Nx.MITN[idx] end
   return nil
end

local function IsTaxiLeg(e)
   if e.Mod == "F" then return true end
   local n = e.TaN1
   if type(n) == "string" then
      n = string.lower(n)
      if string.find(n, "flight") or string.find(n, "flug") or string.find(n, "taxi") then
         return true
      end
   end
   return false
end

-- Geordnete Routenliste: { name, cx, cy, mapIndex, mapName, taxi }
function CB.GetRoute()
   local map = GetMap()
   if not map then return nil end

   local src = map.Tra1
   if not src or #src == 0 then src = map.Tar end
   if not src or #src == 0 then return nil end

   local legs = {}
   for i = 1, #src do
      local e = src[i]
      if type(e.TMX) == "number" and type(e.TMY) == "number" then
         table.insert(legs, {
            name     = e.TaN1 or ("Wegpunkt " .. i),
            cx       = e.TMX,
            cy       = e.TMY,
            mapIndex = e.MaI,
            mapName  = MapName(e.MaI),
            taxi     = IsTaxiLeg(e),
         })
      end
   end
   if #legs == 0 then return nil end
   return legs
end

function CB.HasTarget()
   local map = GetMap()
   if not map then return false end
   if map.Tra1 and #map.Tra1 > 0 then return true end
   if map.Tar and #map.Tar > 0 then return true end
   return false
end

-- Das eigentliche Ziel: der LETZTE Routenpunkt.
-- Rueckgabe: Tabelle oder nil
--   { cx, cy, name, mapIndex, mapName, taxi, legs, sig }
function CB.GetDestination()
   local legs = CB.GetRoute()
   if not legs then return nil end
   local last = legs[#legs]
   local taxi = false
   for i = 1, #legs do
      if legs[i].taxi then taxi = true break end
   end
   return {
      cx       = last.cx,
      cy       = last.cy,
      name     = last.name or "Ziel",
      mapIndex = last.mapIndex,
      mapName  = last.mapName,
      taxi     = taxi,
      legs     = #legs,
      sig      = string.format("%s:%d:%d", tostring(last.mapIndex),
                               math.floor(last.cx * 4), math.floor(last.cy * 4)),
   }
end

-- Zielposition als normalisierte Zonenkoordinaten 0..1 fuer das Servermodul.
-- Rueckgabe: nx, ny, zonenname, mapIndex   oder   nil, fehlertext
function CB.GetDestinationNormalized()
   local d = CB.GetDestination()
   if not d then return nil, "Kein Carbonite-Ziel gesetzt." end
   if not d.mapIndex then return nil, "Carbonite liefert keinen Kartenindex zum Ziel." end

   local zx, zy = CB.ToZone(d.mapIndex, d.cx, d.cy)
   if not zx then return nil, "Carbonite konnte das Ziel nicht in Zonenkoordinaten umrechnen." end
   if zx < -5 or zx > 105 or zy < -5 or zy > 105 then
      return nil, "Das Ziel liegt ausserhalb seiner eigenen Zone -- Route neu setzen."
   end

   zx = math.max(0, math.min(100, zx))
   zy = math.max(0, math.min(100, zy))
   return zx / 100, zy / 100, d.mapName, d.mapIndex, d
end


-- ---------------------------------------------------------------------------
-- Zonenkoordinaten
-- ---------------------------------------------------------------------------
-- Carbonite haelt seine Route in Kontinentkoordinaten. Das Servermodul
-- braucht normalisierte Zonenkoordinaten 0..1, weil nur die sich per
-- WorldMapArea.dbc exakt in Weltkoordinaten umrechnen lassen. Carbonite
-- liefert die Umrechnung selbst mit:
--
--     map:GZP(mapIndex, kontinentX, kontinentY)  ->  zonenX, zonenY  (0..100)

function CB.ToZone(mapIndex, cx, cy)
   local map = GetMap()
   if not map or not map.GZP or not mapIndex then return nil end
   local ok, zx, zy = pcall(function() return map:GZP(mapIndex, cx, cy) end)
   if ok and type(zx) == "number" and type(zy) == "number" then return zx, zy end
   return nil
end

-- Liegt der Kontinentpunkt innerhalb der Zone?  -> drin, zx, zy
function CB.InZone(mapIndex, cx, cy, margin)
   margin = margin or 1
   local zx, zy = CB.ToZone(mapIndex, cx, cy)
   if not zx then return false end
   local inside = zx >= margin and zx <= (100 - margin)
                  and zy >= margin and zy <= (100 - margin)
   return inside, zx, zy
end



-- Entfernung zwischen zwei Kontinentpunkten in Yards
function CB.Yards(ax, ay, bx, by)
   local dx, dy = bx - ax, by - ay
   return math.sqrt(dx * dx + dy * dy) * CB.YARDS_PER_UNIT
end
