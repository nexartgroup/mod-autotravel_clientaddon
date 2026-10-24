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
-- PlX/PlY des Spielers liegen im selben System. AutoTravel braucht davon bei
-- einem einzelnen Ziel nur EINEN Wert -- den letzten Routenpunkt, also das
-- eigentliche Ziel. Die Zwischenpunkte werden dann nur im Fallback-Korridormodus
-- benutzt.
--
-- Verkettet der Spieler mehrere Ziele (in Carbonite Strg + Umschalt + Linksklick auf
-- die Karte), sind die gesetzten Ziele .Tar jedoch Pflichtpunkte: GetRoute markiert
-- sie als Wegpunkte (waypoint = true), und das Servermodul laeuft sie der Reihe nach
-- ab, statt direkt zum letzten zu fahren. Welche Eintraege in .Tra1 gesetzte Ziele und
-- welche von Carbonite berechnete Stuetzpunkte sind, steht nicht in .Tra1 selbst --
-- deshalb der Abgleich mit .Tar (siehe MarkChain).
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

-- Ein Eintrag von Carbonite als Etappe, oder nil, wenn er keine Kontinentkoordinaten hat.
-- 'target': der Eintrag ist ein vom Spieler gesetztes Ziel. Ein Flugpunkt ist er dann nur, wenn
-- Carbonite ihn so kennzeichnet (Mod == "F"), nicht schon, weil sein Name "Flug" enthaelt: ein
-- Ziel wie "Flugmeister Bob" (eine Quest schickt dorthin) darf keinen Flug ausloesen.
local function ReadLeg(e, i, target)
   if type(e) ~= "table" then return nil end
   if type(e.TMX) ~= "number" or type(e.TMY) ~= "number" then return nil end
   local taxi
   if target then taxi = (e.Mod == "F") else taxi = IsTaxiLeg(e) end
   return {
      name     = e.TaN1 or ("Wegpunkt " .. i),
      cx       = e.TMX,
      cy       = e.TMY,
      mapIndex = e.MaI,
      mapName  = MapName(e.MaI),
      taxi     = taxi,
   }
end

local function ReadList(list, target)
   local out = {}
   if type(list) ~= "table" then return out end
   for i = 1, #list do
      local l = ReadLeg(list[i], i, target)
      if l then out[#out + 1] = l end
   end
   return out
end

-- Wie weit (Carbonite-Einheiten, eine Einheit sind rund 4,6 yd) ein gesetztes Ziel und der
-- zugehoerige Routenpunkt auseinanderliegen duerfen.
local MATCH_UNITS = 1.5

local function Near(a, b)
   return a.mapIndex == b.mapIndex
      and math.abs(a.cx - b.cx) <= MATCH_UNITS
      and math.abs(a.cy - b.cy) <= MATCH_UNITS
end

-- Markiert in 'legs' (der berechneten Route) die Punkte, die der Spieler als Ziele gesetzt hat.
-- Jedes Ziel gehoert zu genau einem Punkt, und zwar dem naechsten. Gibt true zurueck, wenn ALLE
-- Ziele einen Punkt gefunden haben; sonst bleibt 'legs' unveraendert.
local function MarkChain(legs, targets)
   local pick = {}
   local taken = {}
   for t = 1, #targets do
      local best, bestD
      for j = 1, #legs do
         if not taken[j] and not legs[j].taxi and Near(targets[t], legs[j]) then
            local d = math.abs(targets[t].cx - legs[j].cx) + math.abs(targets[t].cy - legs[j].cy)
            if not bestD or d < bestD then best, bestD = j, d end
         end
      end
      if not best then return false end
      taken[best] = true
      pick[#pick + 1] = best
   end
   for _, j in ipairs(pick) do legs[j].waypoint = true end
   return true
end

-- Geordnete Routenliste: { name, cx, cy, mapIndex, mapName, taxi, waypoint }
--
-- waypoint = true: ein Ziel, das der Spieler selbst gesetzt hat (Pflichtpunkt). Das gibt es nur,
-- wenn mindestens zwei Ziele gesetzt sind -- ein einzelnes Ziel ist das Endziel, das ohnehin
-- immer zaehlt. Drei Wege, sie zu erkennen:
--
--   * Die Route besteht aus den gesetzten Zielen selbst (.Tra1 leer, Rueckfall auf .Tar):
--     alle sind Wegpunkte.
--   * Jedes gesetzte Ziel findet seinen Punkt in der berechneten Route .Tra1: diese Punkte sind
--     die Wegpunkte, alles dazwischen sind Stuetzpunkte von Carbonite.
--   * Sonst (die Route kennt nicht alle Ziele) gilt die Kette der gesetzten Ziele allein.
--
-- allPoints (Einstellung "Alle Punkte der Carbonite-Route einzeln anlaufen"): jeder Punkt der
-- Route ausser Flugpunkten ist ein Wegpunkt, ohne Abgleich mit .Tar. Fuer den Fall, dass
-- Carbonite die Ziele anders ablegt, als der Abgleich erwartet.
--
-- Zweiter Rueckgabewert: wie die Wegpunkte erkannt wurden ("einzel", "ziele", "route", "abgleich",
-- "alle"), fuer Meldungen und /at route.
function CB.GetRoute(allPoints)
   local map = GetMap()
   if not map then return nil end

   local src = map.Tra1
   local usedTar = false
   if not src or #src == 0 then src = map.Tar usedTar = true end
   if not src or #src == 0 then return nil end

   -- Nur wenn die Route aus .Tar gelesen wird, sind ihre Eintraege gesetzte Ziele. (Vor der Kette
   -- galt auch dort die Namensregel fuer Flugpunkte; sie zaehlte nur bei mehr als einem Punkt.)
   local legs = ReadList(src, usedTar)
   if #legs == 0 then return nil end

   local how = "einzel"

   if allPoints then
      -- Ein erster Punkt, der praktisch auf dem Spieler liegt, ist der Start der Route und kein Ziel.
      local px, py = CB.GetPlayerCarb()
      for i = 1, #legs do
         local l = legs[i]
         if not l.taxi then
            local atPlayer = (i == 1 and px and py
                              and math.abs(l.cx - px) <= MATCH_UNITS and math.abs(l.cy - py) <= MATCH_UNITS)
            if not atPlayer then l.waypoint = true end
         end
      end
      how = "alle"
   elseif usedTar then
      if #legs >= 2 then
         for i = 1, #legs do legs[i].waypoint = true end
         how = "ziele"
      end
   else
      local targets = ReadList(map.Tar, true)
      if #targets >= 2 then
         if MarkChain(legs, targets) then
            how = "abgleich"
         else
            legs = targets
            for i = 1, #legs do legs[i].waypoint = true end
            how = "route"
         end
      end
   end

   return legs, how
end

-- Rohdaten zur Fehlersuche (/at route roh): was Carbonite unter .Tar und .Tra1 ablegt. Zeigt
-- je Eintrag alle Felder mit Zahl, Text oder Wahrheitswert, damit sich die Erkennung der
-- Wegpunkte pruefen laesst, ohne Carbonite zu kennen. Rueckgabe: Liste von Zeilen.
local DUMP_ENTRIES = 12
local DUMP_FIELDS  = 16

local function Describe(e)
   if type(e) ~= "table" then return "(" .. type(e) .. ") " .. tostring(e) end
   local keys = {}
   for k, v in pairs(e) do
      local t = type(v)
      if t == "number" or t == "string" or t == "boolean" then keys[#keys + 1] = tostring(k) end
   end
   table.sort(keys)
   local parts = {}
   for i = 1, math.min(#keys, DUMP_FIELDS) do
      local k = keys[i]
      local v = e[k]
      if v == nil then v = e[tonumber(k) or k] end
      if type(v) == "number" then v = string.format("%.3f", v):gsub("%.?0+$", "")
      else v = tostring(v):gsub("|", "||") end
      parts[#parts + 1] = k .. "=" .. v
   end
   if #keys > DUMP_FIELDS then parts[#parts + 1] = "... (+" .. (#keys - DUMP_FIELDS) .. ")" end
   return table.concat(parts, " ")
end

local function DumpList(out, label, list)
   if type(list) ~= "table" then
      out[#out + 1] = label .. ": " .. type(list)
      return
   end
   local n = #list
   out[#out + 1] = string.format("%s: %d Eintraege", label, n)
   for i = 1, math.min(n, DUMP_ENTRIES) do
      out[#out + 1] = string.format("   %2d. %s", i, Describe(list[i]))
   end
   if n > DUMP_ENTRIES then out[#out + 1] = string.format("   ... und %d weitere", n - DUMP_ENTRIES) end
end

function CB.Dump()
   local map = GetMap()
   if not map then return { "Carbonite ist nicht geladen." } end
   local out = {}
   DumpList(out, "Tar (gesetzte Ziele)", map.Tar)
   DumpList(out, "Tra1 (berechnete Route)", map.Tra1)
   return out
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
