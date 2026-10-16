-- AT_Bot.lua
-- ---------------------------------------------------------------------------
-- Steuerung des Playerbot-Selbstmodus.
--
-- Aufgabenteilung bleibt strikt:
--   AutoTravel  bewegt den Charakter (Servermodul, NavMesh)
--   Playerbot   kaempft, heilt, lootet
--
-- Gesendet werden Strategiebefehle (co / nc / ll). Nie "ue", "roll", "s", "b",
-- "talents", "destroy". Ausnahmen sind "e <Erbstueck>" aus AT_Gear.lua, das ein vom
-- Bot abgelegtes Erbstueck wieder anlegt, "pet <Haltung>" (aggressive, defensive,
-- passive), das nur die Reaktion des Begleiters umstellt, und "u <Gegenstand>" aus
-- AT_Consumables.lua (Flaeschchen, Elixiere, Schriftrollen im Kampf). Die Strategie
-- "new rpg" wird in den festen Profilen aktiv abgeschaltet, weil sie Questen ausloest
-- und darueber Ausruestung wechseln kann.
--
-- Befehle gehen als Fluesternachricht an den eigenen Namen -- so erwartet es
-- mod-playerbots fuer Einzelbots.
-- ---------------------------------------------------------------------------

AutoTravel = AutoTravel or {}
local AT = AutoTravel

AT.Bot = {}
local B = AT.Bot

-- ---------------------------------------------------------------------------
-- Bekannte Strategien
-- ---------------------------------------------------------------------------
-- Nur die allgemeinen aus der Playerbot-Dokumentation. Klassenspezifische
-- (Totems, Segen, Aspekte, Pets) gehoeren ins Freitextfeld eines eigenen
-- Profils, weil sie je nach Klasse ohnehin nur teilweise passen.

B.CombatFlags = {
   -- Achtung: "dps" und "heal" sind KLASSENstrategien. Fuer Druiden heisst "dps"
   -- Katzenform und "heal" Wiederherstellung (Heiler, greift nicht an); die
   -- beiden verdraengen einander und die Standardstrategie des Talentbaums.
   -- Die festen Profile setzen sie deshalb nicht; "co !" waehlt die richtige.
   { "dps",             "Klassenstrategie Schaden (Druide: Katze!)" },
   { "dps assist",      "Angreifer als Ziel waehlen und bekaempfen" },
   { "aoe",             "mehrere Ziele gleichzeitig" },
   { "tank",            "Bedrohung aufbauen" },
   { "tank assist",     "Gegner von anderen wegziehen" },
   { "heal",            "Klassenstrategie Heilen (Druide: greift nicht an!)" },
   { "healer dps",      "Heiler zaubern Schaden bei genug Mana" },
   { "save mana",       "Heiler sparen Mana unter einem Schwellwert" },
   { "potions",         "Heil- und Manatraenke aus dem Beutel benutzen: Gesundheitsstein oder Heiltrank bei kritischer Gesundheit, Manatrank bei wenig Mana (Standard des Servers: an)" },
   { "boost",           "grosse Abklingzeiten benutzen" },
   { "cc",              "Kontrolle benutzen (braucht rti-Ziel)" },
   { "threat",          "Schadensklassen meiden Bedrohung" },
   { "focus",           "kein Flaechenzauber auf mehrere Angreifer" },
   { "avoid aoe",       "schaedlichen Flaechenzaubern ausweichen" },
   { "grind",           "jedes sichtbare Ziel angreifen" },
   { "behind",          "hinter das Ziel laufen" },
   { "tank face",       "Ziel von Fernkaempfern wegdrehen" },
   { "pull",            "mit Fernkampf anpullen" },
   { "pull back",       "nach dem Pull zurueckziehen" },
   { "mark rti",        "Angreifer automatisch markieren" },
}

B.NonCombatFlags = {
   { "loot",            "Beute aufnehmen" },
   { "food",            "essen und trinken" },
   { "follow",          "dem Meister folgen" },
   { "grind",           "selbst Ziele suchen" },
   { "new rpg",         "questen (aendert Ausruestung!)" },
   { "pvp",             "PvP-Modus" },
   { "maintenance",     "Wartung (Standard: aus): lernt Rezepte aus dem Beutel, verzaubert und entzaubert eigene Gegenstaende, benutzt Questgegenstaende, raeumt das Questlog auf und kann bei fast vollen Taschen Ueberfluessiges vernichten" },
}

-- Strategien, die der Server von sich aus einschaltet ("co !" / "nc !" liefert sie).
-- Eigene Profile setzen jede Flagge ausdruecklich; fehlt eine in einem frueher gespeicherten
-- Profil, gilt dort der Standard des Servers -- sonst wuerde ein neues "-potions" still
-- abschalten, was bisher lief.
B.FlagDefaults = { potions = true }

-- Zustand einer Flagge in einem eigenen Profil (nicht gesetzt = Standard des Servers).
function B.FlagState(map, flag)
   local st = map and map[flag]
   if st == nil then st = B.FlagDefaults[flag] end
   return st and true or false
end

-- Haltung des Begleiters. Der Server kennt "pet aggressive|defensive|passive".
B.PetStances = {
   { "aggressive", "aggressiv" },
   { "defensive",  "defensiv" },
   { "passive",    "passiv" },
}

-- Gueltige Haltung oder nil (nicht gesetzt: der Begleiter bleibt, wie er ist).
function B.ValidPet(v)
   if type(v) ~= "string" then return nil end
   for _, s in ipairs(B.PetStances) do
      if s[1] == v then return v end
   end
   return nil
end

function B.PetLabel(v)
   v = B.ValidPet(v)
   for _, s in ipairs(B.PetStances) do
      if s[1] == v then return s[2] end
   end
   return "unveraendert"
end

-- Verbrauchsgueter aus den Taschen (AT_Consumables.lua). Das ist KEINE Strategie des
-- Servers, sondern eine Eigenschaft des Profils im Addon: der Bot kennt Schriftrollen,
-- Elixiere und Flaeschchen nicht von sich aus, das Addon liest die Taschen und fluestert
-- "u <Gegenstand>". Jede Art ist an oder aus; in den festen Profilen ist nichts gesetzt.
B.ConsFlags = {
   { "flask",  "Flaeschchen",   "Flaeschchen (Flask): belegen Kampf- und Waechterplatz und halten bis zu zwei Stunden." },
   { "elixir", "Elixiere",      "Kampf- und Waechterelixiere: je ein Elixier pro Platz, solange kein Flaeschchen wirkt." },
   { "scroll", "Schriftrollen", "Schriftrollen: immer nur eine (der Server laesst die sechs Werte nicht nebeneinander zu). Der Wert richtet sich nach Klasse und Talentbaum; /at buffs wert stellt ihn fest ein." },
}

-- Ist die Art in dieser Tabelle gesetzt? Nur ein ausdrueckliches true zaehlt.
function B.ConsOn(map, flag)
   return type(map) == "table" and map[flag] == true
end

-- Nur bekannte Arten, nur true: beschaedigte Eintraege (von Hand bearbeitete SavedVariables)
-- fallen heraus.
function B.CleanCons(map)
   local out = {}
   if type(map) ~= "table" then return out end
   for _, f in ipairs(B.ConsFlags) do
      if map[f[1]] == true then out[f[1]] = true end
   end
   return out
end

-- ---------------------------------------------------------------------------
-- Feste Profile
-- ---------------------------------------------------------------------------

-- "co !" setzt die zum Talentbaum passende Kampfstrategie (Druide: Gleichgewicht,
-- Katze, Wiederherstellung ...). "+dps" und "+heal" wuerden sie ersetzen: beim
-- Druiden ist "dps" die Katzenform (unter Stufe 20 ohne Gestalt) und "heal" die
-- Wiederherstellung, die nicht angreift. Deshalb setzen die Profile nur
-- klassenneutrale Strategien.
B.Builtin = {
   {
      key = "minimal", name = "Minimal",
      desc = "Nur laufen. Der Bot greift nicht ein.",
      combat    = "-dps,-aoe,-boost,-grind,-heal,-tank",
      noncombat = "-grind,-new rpg,-loot,-follow,-food",
      grace = 1.5,
   },
   {
      key = "aengstlich", name = "Aengstlich",
      desc = "Weicht aus, greift nicht an.",
      combat    = "-dps,-aoe,-boost,-grind,-tank,+threat,+avoid aoe",
      noncombat = "-grind,-new rpg,-loot,-follow,+food",
      grace = 1.5,
   },
   {
      key = "verteidigen", name = "Verteidigen",
      desc = "Wehrt sich, sucht aber keinen Kampf.",
      combat    = "+dps assist,+avoid aoe,-aoe,-grind,-boost",
      noncombat = "-grind,-new rpg,-loot,-follow,+food",
      grace = 2.0,
   },
   {
      key = "normal", name = "Normal",
      desc = "Wehrt sich mit vollem Repertoire und pluendert Gegner (ohne Ressourcen).",
      combat    = "+dps assist,+aoe,+avoid aoe,-grind",
      -- Frueher stand hier "-loot": das Profil nannte sich "Normal" und lootete
      -- nie. Die nc-Strategie "loot" nimmt die Beute auf, "ll normal" legt fest,
      -- was ("ll" kennt nur all/*, gray/g und disenchant; alles andere gilt als
      -- "normal"). Die laengere Wartezeit gibt dem Bot Zeit zum Looten, bevor
      -- der Autopilot weiterlaeuft. "nc !" stellt "gather" (Beruferessourcen)
      -- als Standard an; "-gather" haelt Normal bei der Beute von Gegnern, das
      -- bleibt der Unterschied zu "Plus".
      noncombat = "+loot,-gather,-grind,-new rpg,-follow,+food",
      extra = { "ll normal" },
      loot = true, grace = 7.0,
   },
   {
      key = "aggressiv", name = "Aggressiv",
      desc = "Greift alles an und pluendert die Beute.",
      combat    = "+dps assist,+aoe,+boost,+grind",
      noncombat = "+loot,-new rpg,-follow,+food",
      extra = { "ll normal" },
      loot = true, grace = 7.0,
   },
   {
      key = "plus", name = "Plus",
      desc = "Wehrt sich, pluendert Gegner, sammelt Beruferessourcen.",
      combat    = "+dps assist,+aoe,+avoid aoe,-grind",
      -- "ll" kennt nur all/*, gray/g und disenchant; jeder andere Wert (auch
      -- "skill") wird zu "normal" (LootStrategyValue::instance). Ressourcen
      -- sammelt die nc-Strategie "gather".
      noncombat = "+loot,+gather,-grind,-new rpg,-follow,+food",
      extra = { "ll normal" },
      loot = true, grace = 7.0,
   },
}

B.CUSTOM_COUNT = 3

-- Die Strategien, die feste Profile benutzen. "gather" (Beruferessourcen) gehoert
-- nur hierher: eigene Profile setzen JEDE Flagge ausdruecklich, und ein neues
-- "-gather" in schon gespeicherten eigenen Profilen waere eine stille Aenderung.
B.BuiltinNonCombatFlags = {}
for _, f in ipairs(B.NonCombatFlags) do table.insert(B.BuiltinNonCombatFlags, f) end
table.insert(B.BuiltinNonCombatFlags, { "gather", "Beruferessourcen sammeln" })

-- ---------------------------------------------------------------------------
-- Feste Profile aendern und zuruecksetzen
-- ---------------------------------------------------------------------------
--
-- Die festen Profile bleiben unveraendert im Code (B.Builtin). Was der Spieler
-- aendert, liegt als Ueberschreibung kontoweit in AutoTravelGlobalDB.builtin[key]
-- und ersetzt beim Anwenden das Profil; Zuruecksetzen loescht sie einfach.
--
-- Jede Strategie hat drei Zustaende: nicht gesetzt (nichts wird gesendet, es
-- bleibt, was "co !" / "nc !" als Standard hinterlassen), an (+) und aus (-).
-- Die festen Profile setzen bewusst nicht alles: "Normal" aendert nichts an
-- "tank" oder "boost". Ein Editor mit nur zwei Zustaenden wuerde das beim ersten
-- Speichern in ein ausdrueckliches "-tank" verwandeln.

function B.Global()
   if type(AutoTravelGlobalDB) ~= "table" then AutoTravelGlobalDB = {} end
   if type(AutoTravelGlobalDB.custom) ~= "table" then AutoTravelGlobalDB.custom = {} end
   if type(AutoTravelGlobalDB.builtin) ~= "table" then AutoTravelGlobalDB.builtin = {} end
   return AutoTravelGlobalDB
end

-- "+dps,-aoe" -> { dps = true, aoe = false }
function B.ParseFlags(text)
   local t = {}
   for tok in string.gmatch(text or "", "[^,]+") do
      local sign, name = string.match(AT.trim(tok), "^([%+%-])%s*(.-)$")
      if sign and name and name ~= "" then t[name] = (sign == "+") end
   end
   return t
end

-- Umkehrung, in der Reihenfolge der Liste. Strategien ausserhalb der Liste gehen
-- verloren; ein Test prueft, dass alle festen Profile vollstaendig darin liegen.
function B.FormatFlags(map, list)
   local parts = {}
   for _, f in ipairs(list) do
      local st = map and map[f[1]]
      if st ~= nil then table.insert(parts, (st and "+" or "-") .. f[1]) end
   end
   return table.concat(parts, ",")
end

function B.BuiltinDefault(key)
   for _, p in ipairs(B.Builtin) do
      if p.key == key then return p end
   end
   return nil
end

function B.IsBuiltinKey(key)
   return B.BuiltinDefault(key) ~= nil
end

-- Gibt es eine gespeicherte Ueberschreibung (auch eine, die den Standard nur
-- wiederholt)?
function B.HasOverride(key)
   return type(B.Global().builtin[key]) == "table"
end

local function SameFlags(a, b)
   a, b = a or {}, b or {}
   for k, v in pairs(a) do if b[k] ~= v then return false end end
   for k, v in pairs(b) do if a[k] ~= v then return false end end
   return true
end

-- Weicht das Profil wirklich vom Standard ab? Eine Ueberschreibung, die alle
-- Werte des Standards wiederholt, zaehlt nicht: sie wird wie der Standard
-- behandelt und nicht als "geaendert" angezeigt.
function B.IsModified(key)
   local d = B.BuiltinDefault(key)
   if not d or not B.HasOverride(key) then return false end
   local o = B.BuiltinOverride(key)         -- bringt beschaedigte Felder in Ordnung

   if not SameFlags(o.combat, B.ParseFlags(d.combat)) then return true end
   if not SameFlags(o.noncombat, B.ParseFlags(d.noncombat)) then return true end

   local dx = table.concat(d.extra or {}, "; ")
   local ox = table.concat(B.SplitExtra(type(o.extra) == "string" and o.extra or ""), "; ")
   if ox ~= dx then return true end

   if (tonumber(o.grace) or d.grace) ~= (d.grace or 2.0) then return true end
   if B.ValidPet(o.pet) ~= B.ValidPet(d.pet) then return true end
   if not SameFlags(B.CleanCons(o.cons), B.CleanCons(d.cons)) then return true end
   return false
end

-- Ueberschreibung holen; gibt es noch keine, wird sie aus den Standardwerten
-- aufgebaut. Rueckgabe nil fuer einen unbekannten Schluessel.
function B.BuiltinOverride(key)
   local d = B.BuiltinDefault(key)
   if not d then return nil end
   local g = B.Global()
   local o = g.builtin[key]
   if type(o) ~= "table" then
      o = {
         combat    = B.ParseFlags(d.combat),
         noncombat = B.ParseFlags(d.noncombat),
         extra     = table.concat(d.extra or {}, "; "),
         grace     = d.grace or 2.0,
         pet       = d.pet,
         cons      = B.CleanCons(d.cons),
      }
      g.builtin[key] = o
   end
   if type(o.combat) ~= "table" then o.combat = {} end
   if type(o.noncombat) ~= "table" then o.noncombat = {} end
   if type(o.extra) ~= "string" then o.extra = "" end
   if type(o.grace) ~= "number" then o.grace = d.grace or 2.0 end
   o.pet = B.ValidPet(o.pet)
   o.cons = B.CleanCons(o.cons)
   return o
end

-- Eine Ueberschreibung, die den Standard nur wiederholt, wieder entfernen. Sonst
-- bliebe sie als Schnappschuss liegen, und eine spaetere Aenderung des Standards
-- erreichte dieses Profil nicht mehr. Rueckgabe: true, wenn etwas entfernt wurde.
function B.NormalizeBuiltin(key)
   if B.HasOverride(key) and not B.IsModified(key) then
      return B.ResetBuiltin(key)
   end
   return false
end

function B.ResetBuiltin(key)
   if not B.IsBuiltinKey(key) then return false end
   B.Global().builtin[key] = nil
   return true
end

function B.ResetAllBuiltin()
   B.Global().builtin = {}
end

-- Zusatzbefehle "a; b" -> { "a", "b" }
local function SplitExtra(text)
   local out = {}
   for line in string.gmatch(text or "", "[^;\n]+") do
      line = AT.trim(line)
      if line ~= "" then table.insert(out, line) end
   end
   return out
end
B.SplitExtra = SplitExtra

-- Das wirksame Profil: Standard, bei Aenderung mit der Ueberschreibung.
local function ResolveBuiltin(p)
   if not B.IsModified(p.key) then return p end
   local o = B.BuiltinOverride(p.key)

   local q = {}
   for k, v in pairs(p) do q[k] = v end
   q.combat    = B.FormatFlags(o.combat, B.CombatFlags)
   q.noncombat = B.FormatFlags(o.noncombat, B.BuiltinNonCombatFlags)
   q.extra     = SplitExtra(o.extra)
   q.grace     = tonumber(o.grace) or p.grace
   q.pet       = B.ValidPet(o.pet)
   q.cons      = B.CleanCons(o.cons)
   q.modified  = true
   return q
end

-- ---------------------------------------------------------------------------
-- Eigene Profile (kontoweit gespeichert)
-- ---------------------------------------------------------------------------

-- Der Platz eines eigenen Profils; beschaedigte Felder (von Hand bearbeitete
-- SavedVariables) werden dabei in Ordnung gebracht.
function B.CustomSlot(i)
   local g = B.Global()
   local c = g.custom[i]
   if type(c) ~= "table" then
      c = {}
      g.custom[i] = c
   end
   if type(c.name) ~= "string" then c.name = "Eigenes " .. i end
   if type(c.combat) ~= "table" then c.combat = {} end
   if type(c.noncombat) ~= "table" then c.noncombat = {} end
   if type(c.extra) ~= "string" then c.extra = "" end
   if type(c.grace) ~= "number" then c.grace = 2.0 end
   c.pet = B.ValidPet(c.pet)
   c.cons = B.CleanCons(c.cons)
   return c
end

function B.CustomUsed(i)
   if B.Global().custom[i] == nil then return false end
   local c = B.CustomSlot(i)
   if next(c.combat) ~= nil then return true end
   if next(c.noncombat) ~= nil then return true end
   if c.pet ~= nil then return true end
   if next(c.cons) ~= nil then return true end
   return c.extra ~= ""
end

-- Aus einem eigenen Profil ein Profilobjekt bauen
local function CustomProfile(i)
   local c = B.CustomSlot(i)
   local loot = c.noncombat and c.noncombat["loot"] or false
   return {
      key = "custom" .. i,
      name = c.name or ("Eigenes " .. i),
      desc = "Eigenes Profil " .. i,
      customIndex = i,
      loot = loot,
      grace = c.grace or (loot and 7.0 or 2.0),
      pet = c.pet,
      cons = c.cons,
   }
end

-- Vollstaendige Liste: feste Profile plus benutzte eigene
function B.List()
   local out = {}
   for _, p in ipairs(B.Builtin) do table.insert(out, ResolveBuiltin(p)) end
   for i = 1, B.CUSTOM_COUNT do
      if B.CustomUsed(i) then table.insert(out, CustomProfile(i)) end
   end
   return out
end
-- Hinweis: hier stand frueher ein Proxy "B.Profiles" mit __index/__len. ipairs()
-- beachtet beides in Lua 5.1 nicht und lief deshalb nullmal; Aufrufer nehmen
-- B.List().

function B.Find(key)
   for _, p in ipairs(B.List()) do
      if p.key == key then return p end
   end
   return ResolveBuiltin(B.Builtin[3])        -- Verteidigen
end

function B.Current()
   return B.Find(AT.Get("Profile") or "verteidigen")
end

function B.Next()
   local list = B.List()
   local cur = AT.Get("Profile") or "verteidigen"
   for i, p in ipairs(list) do
      if p.key == cur then
         local n = list[(i % #list) + 1]
         AT.Set("Profile", n.key)
         return n
      end
   end
   AT.Set("Profile", list[1].key)
   return list[1]
end

-- ---------------------------------------------------------------------------
-- Senden
-- ---------------------------------------------------------------------------

local recent = {}
local recentCount = 0

local function PruneRecent(now)
   for k, t in pairs(recent) do
      if (now - t) > 60 then recent[k] = nil end
   end
   recentCount = 0
end

-- onSent (optional) laeuft, wenn die Nachricht WIRKLICH hinausgeht -- die Warteschlange haelt
-- sie unter Umstaenden zurueck. Wer ein Ergebnis abwarten will (AT_Consumables), misst ab dann.
function B.Whisper(text, onSent)
   if not text or text == "" then return end
   local now = GetTime()
   recentCount = recentCount + 1
   if recentCount > 40 then PruneRecent(now) end   -- sonst waechst die Tabelle ohne Grenze
   recent[text] = now
   AT.Queue(function()
      SendChatMessage(text, "WHISPER", nil, UnitName("player"))
      AT.Debug("-> [Fluestern an sich] " .. text)
      if onSent then onSent() end
   end, "bot")
end

function B.IsOwnCommand(msg)
   if type(msg) ~= "string" then return false end
   local t = recent[msg]
   return t and (GetTime() - t) < 15
end

-- Lange Flaggenlisten auf mehrere Nachrichten aufteilen (Chatlimit)
local function SendFlagList(prefix, parts)
   local buf = ""
   for _, p in ipairs(parts) do
      if string.len(buf) + string.len(p) + 1 > 180 then
         B.Whisper(prefix .. " " .. buf)
         buf = ""
      end
      buf = (buf == "") and p or (buf .. "," .. p)
   end
   if buf ~= "" then B.Whisper(prefix .. " " .. buf) end
end

-- ---------------------------------------------------------------------------
-- Zustandserkennung
-- ---------------------------------------------------------------------------

B.active    = false
B.confirmed = nil

-- Zustand der Rueckmeldeueberwachung. Muss VOR OnSystemMessage stehen: ein Local,
-- das erst weiter unten deklariert wird, ist fuer eine frueher definierte
-- Funktion unsichtbar -- sie griffe auf eine globale Variable gleichen Namens
-- zu (und fand nil).
local watchUntil, watchWant = 0, nil

-- Die Meldungen von mod-playerbots haben sich geaendert. Heute (PlayerbotMgr.cpp,
-- Befehl "self"):
--     "SelfBot is now active."                       eingeschaltet
--     "SelfBot is now deactivated."                  ausgeschaltet
--     "SelfBot is disabled server-wide."             AiPlayerbot.SelfBotLevel = 0
--     "SelfBot is restricted for this account."      SelfBotLevel = 1, kein Spielleiter
-- Aeltere Staende meldeten "Enable/Disable player botAI". Beide Fassungen werden
-- erkannt.
local ENABLE_PATTERNS  = { "selfbot is now active", "enable player botai",
                           "playerbot ai enabled", "botai aktiviert" }
local DISABLE_PATTERNS = { "selfbot is now deactivated", "disable player botai",
                           "playerbot ai disabled", "botai deaktiviert" }
local REFUSE_PATTERNS  = { "selfbot is disabled server-wide",
                           "selfbot is restricted for this account",
                           "playerbot system is currently disabled",   -- AiPlayerbot.Enabled = 0
                           "you cannot control bots yet" }             -- noch kein Bot-Verwalter

-- ".playerbots bot self" ist ein Umschalter: derselbe Befehl schaltet ein und aus.
-- Ist der Zustand unbekannt (nach /reload, oder der Server hat den Selbstmodus beim
-- Anmelden selbst eingeschaltet), kehrt ein "Einschalten" ihn um. Kommt innerhalb
-- der Wartezeit die Bestaetigung des GEGENTEILS, wird einmal erneut umgeschaltet.
-- Die Strategiebefehle, die hinter dem ersten Umschalter standen, gingen an einen
-- Bot, der gar nicht lief, und werden nach dem Erfolg neu gesendet.
local watchRetried = false
local SendSelf          -- unten definiert; hier nur vorab bekannt gemacht

local function Reconcile()
   if watchUntil == 0 or watchWant == nil then return end
   if B.confirmed == watchWant then
      watchUntil = 0
      if watchRetried and watchWant then B.ApplyProfile() end
      return
   end
   if watchRetried then
      watchUntil = 0
      AT.Warn("Der Selbstmodus liess sich nicht in den gewuenschten Zustand bringen. " ..
              "Er ist " .. (B.confirmed and "an" or "aus") .. ".")
      return
   end
   watchRetried = true
   AT.Net.DropTag("bot")
   AT.Debug("Selbstmodus war nicht im erwarteten Zustand - schalte noch einmal um.")
   SendSelf(AT.Get(watchWant and "SelfOnCommand" or "SelfOffCommand"), watchWant, true)
end

local function MatchAny(low, list)
   for _, pat in ipairs(list) do
      if string.find(low, pat, 1, true) then return true end
   end
   return false
end

function B.OnSystemMessage(msg)
   if type(msg) ~= "string" then return false end
   local low = string.lower(msg)

   if MatchAny(low, REFUSE_PATTERNS) then
      -- Der Server verweigert den Selbstmodus. Das ist keine Fehlbedienung: die
      -- Rueckmeldung erklaert, warum, und die Ueberwachung muss Ruhe geben.
      B.confirmed = false
      B.active = false
      B.refused = msg
      watchUntil = 0
      -- Die Strategiebefehle hinter dem Umschalter sind sinnlos geworden.
      AT.Net.DropTag("bot")
      AT.Warn("Der Server verweigert den Playerbot-Selbstmodus: " .. msg ..
              " (AiPlayerbot.SelfBotLevel in der Serverkonfiguration)")
      if AT.UI then AT.UI.Update() end
      return true
   end

   if MatchAny(low, ENABLE_PATTERNS) then
      B.confirmed = true
      B.active = true
      AT.Debug("Selbstmodus vom Server bestaetigt: aktiv")
      Reconcile()
      if AT.UI then AT.UI.Update() end
      return true
   end
   if MatchAny(low, DISABLE_PATTERNS) then
      B.confirmed = false
      B.active = false
      AT.Debug("Selbstmodus vom Server bestaetigt: aus")
      Reconcile()
      if AT.UI then AT.UI.Update() end
      return true
   end
   return false
end

function B.IsRunning()
   if B.confirmed ~= nil then return B.confirmed end
   return B.active
end

function B.StatusText()
   if B.refused then return "|cffe8654averweigert|r" end
   if B.confirmed == true  then return "|cff53d17aaktiv|r" end
   if B.confirmed == false then return "|cff9099a8aus|r" end
   return "|cffe8c44a?|r"
end

-- ---------------------------------------------------------------------------
-- Profil anwenden
-- ---------------------------------------------------------------------------

-- Zaehlt die Anwendungen; der Editor verschickt eine Aenderung nur dann noch
-- einmal, wenn seitdem nichts angewendet wurde (die Anwendung enthaelt sie schon).
B.applyCount = 0

-- ---------------------------------------------------------------------------
-- Druiden: Strategie folgt der Gestalt
-- ---------------------------------------------------------------------------
-- Bei Druiden schliessen sich die Kampfstrategien bear / cat / balance / resto
-- gegenseitig aus (mod-playerbots entfernt beim Setzen die "Geschwister"), alle
-- gleichzeitig geht also nicht. Jede wuerde ausserdem versuchen, den Druiden in
-- ihre eigene Gestalt zu bringen. Stattdessen liest das Addon die aktuelle
-- Gestalt und setzt die dazu passende Strategie hinter die Profilstrategien.
-- Ohne Gestalt (oder Reise-/Wasser-/Flugform) bleibt die Vorgabe von "co !", die
-- zum Talentbaum und zur Stufe passt.

-- Die Symbole der Gestalten taugen nicht zur Erkennung (der Baer traegt hier
-- "Spell_Nature_WispSplode"). Verglichen wird deshalb mit den Zaubern selbst:
-- GetSpellInfo(id) liefert Name und Symbol in der Sprache des Clients.
local FORM_SPELLS = {
   { 5487,  "bear"    },       -- Baergestalt
   { 9634,  "bear"    },       -- Terrorbaergestalt
   { 768,   "cat"     },       -- Katzengestalt
   { 24858, "balance" },       -- Mondkingestalt
   { 33891, "resto"   },       -- Baum des Lebens
}

-- Strategiename der aktuellen Gestalt oder nil (kein Druide, keine Gestalt,
-- Reisegestalten).
function B.DruidForm()
   if not UnitClass or not GetNumShapeshiftForms or not GetShapeshiftFormInfo then return nil end
   local _, class = UnitClass("player")
   if class ~= "DRUID" then return nil end
   for i = 1, GetNumShapeshiftForms() do
      local icon, name, active = GetShapeshiftFormInfo(i)
      if active then
         for _, f in ipairs(FORM_SPELLS) do
            local sname, _, sicon = GetSpellInfo(f[1])
            if sname and sname == name then return f[2] end
            if sicon and icon and sicon == icon and f[2] ~= "bear" then return f[2] end
         end
         -- Baer: Symbol erst nach den Namen vergleichen, weil Katze und Baer
         -- sich in manchen Staenden ein Symbol teilen koennten.
         for _, f in ipairs(FORM_SPELLS) do
            local _, _, sicon = GetSpellInfo(f[1])
            if sicon and icon and sicon == icon then return f[2] end
         end
         return nil
      end
   end
   return nil
end

B.formStrategy = nil          -- die zuletzt gesendete Gestaltstrategie

-- Wertet der Server den Charakter als Wilden Kampf? Er nimmt ab Stufe 10 den
-- Talentbaum mit den meisten Punkten (bei Gleichstand den ersten); davor und
-- ohne Punkte gilt bei Druiden immer Gleichgewicht (AiFactory::GetPlayerSpecTab).
function B.IsFeralSpec()
   if not GetTalentTabInfo or not UnitLevel then return false end
   if UnitLevel("player") < 10 then return false end
   local best, bestPoints = nil, 0
   for i = 1, 3 do
      local _, _, points = GetTalentTabInfo(i)
      points = tonumber(points) or 0
      if points > bestPoints then best, bestPoints = i, points end
   end
   return best == 2
end

-- Der Befehl fuer die Gestalt. Bei Baer und Katze ohne Wilden-Kampf-Talentbaum
-- haengen "aoe", "cc", "boost" und "cure" an den Gleichgewichts-Triggern des
-- Servers (Hurrikan, Sternenfall, Wucherwurzeln, Heilung ...): das sind
-- Zauber, die in Tiergestalt scheitern. Jeder Fehlschlag spielt im Client den
-- Fehlerton, und die Aktion blockiert die Bearenfaehigkeiten.
function B.FormCommand(form)
   if not form then return nil end
   local cmd = "co +" .. form
   if (form == "bear" or form == "cat") and not B.IsFeralSpec() then
      cmd = cmd .. ",-aoe,-cc,-boost,-cure"
   end
   return cmd
end

-- formOnly: nur die Kampfstrategien neu senden (Gestaltwechsel); "nc", Wartezeit
-- und Meldung bleiben unberuehrt.
function B.ApplyProfile(formOnly)
   if not AT.GetBool("BotControl") then return end
   if not formOnly then B.applyCount = B.applyCount + 1 end
   local p = B.Current()

   B.Whisper("co !")
   if not formOnly then B.Whisper("nc !") end

   if p.customIndex then
      local c = B.CustomSlot(p.customIndex)

      local cparts = {}
      for _, f in ipairs(B.CombatFlags) do
         table.insert(cparts, (B.FlagState(c.combat, f[1]) and "+" or "-") .. f[1])
      end
      SendFlagList("co", cparts)

      if not formOnly then
         local nparts = {}
         for _, f in ipairs(B.NonCombatFlags) do
            table.insert(nparts, (B.FlagState(c.noncombat, f[1]) and "+" or "-") .. f[1])
         end
         SendFlagList("nc", nparts)

         if c.extra and c.extra ~= "" then
            for line in string.gmatch(c.extra, "[^;\n]+") do
               line = AT.trim(line)
               if line ~= "" then B.Whisper(line) end
            end
         end
      end
   else
      if p.combat and p.combat ~= "" then B.Whisper("co " .. p.combat) end
      if not formOnly then
         if p.noncombat and p.noncombat ~= "" then B.Whisper("nc " .. p.noncombat) end
         if p.extra then
            for _, e in ipairs(p.extra) do B.Whisper(e) end
         end
      end
   end

   if not formOnly then B.ApplyPet(p) end

   -- Druide: Strategie der aktuellen Gestalt als letztes setzen, damit sie die
   -- Profilstrategien nicht verdraengen.
   B.formStrategy = B.DruidForm()
   if B.formStrategy then B.Whisper(B.FormCommand(B.formStrategy)) end

   if formOnly then return end
   -- Wartezeit nach dem Kampf: gilt nur fuer die eigene Sitzung des Servermoduls.
   AT.SetSessionOption("grace", p.grace or 2.0)
   AT.Print("Profil: |cffffffff" .. p.name .. "|r - " .. p.desc)
end

-- Haltung des Begleiters (Jaeger, Hexenmeister, Todesritter, Magier, Priester ...). Der Befehl
-- "pet <Haltung>" gilt fuer Begleiter und Waechter des Bots. Ohne Begleiter antwortet der Bot
-- mit einer Fehlermeldung, deshalb wird nur gesendet, wenn einer da ist; ruft der Spieler ihn
-- spaeter, zieht der Ereignisrahmen unten die Haltung nach.
function B.ApplyPet(p)
   p = p or B.Current()
   local stance = p and B.ValidPet(p.pet)
   if not stance then return false end
   if not (UnitExists and UnitExists("pet")) then
      AT.Debug("Kein Begleiter da - die Haltung '" .. stance .. "' wird gesendet, sobald er erscheint.")
      return false
   end
   B.Whisper("pet " .. stance)
   return true
end

local petFrame = CreateFrame("Frame")
local petDue = 0
petFrame:RegisterEvent("UNIT_PET")
petFrame:SetScript("OnEvent", function(_, event, unit)
   if unit == "player" then petDue = GetTime() + 1.0 end
end)
petFrame:SetScript("OnUpdate", function()
   if petDue == 0 or GetTime() < petDue then return end
   petDue = 0
   if not B.IsRunning() or not AT.GetBool("BotControl") then return end
   B.ApplyPet()
end)

-- Gestaltwechsel: kurz entprellen (beim Wechsel feuern mehrere Ereignisse), dann
-- die Strategie nachziehen, wenn sie sich wirklich geaendert hat.
local formFrame = CreateFrame("Frame")
local formDue = 0
formFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
formFrame:SetScript("OnEvent", function()
   formDue = GetTime() + 0.6
end)
formFrame:SetScript("OnUpdate", function()
   if formDue == 0 or GetTime() < formDue then return end
   formDue = 0
   if not B.IsRunning() or not AT.GetBool("BotControl") then return end
   if B.DruidForm() == B.formStrategy then return end
   B.ApplyProfile(true)
end)

-- ---------------------------------------------------------------------------
-- Selbstmodus an / aus
-- ---------------------------------------------------------------------------

local watchdog = CreateFrame("Frame")

watchdog:SetScript("OnUpdate", function()
   if watchUntil == 0 then return end
   if B.confirmed == watchWant then watchUntil = 0 return end
   if GetTime() < watchUntil then return end
   watchUntil = 0
   AT.Warn("Keine Bestaetigung fuer den Selbstmodus. Verwendeter Befehl: "
           .. tostring(AT.Get(watchWant and "SelfOnCommand" or "SelfOffCommand")))
   AT.Warn("Schreibweise mit '.playerbots help' pruefen, dann /at selfon <befehl>.")
end)

function SendSelf(cmd, want, isRetry)
   if not cmd or AT.trim(cmd) == "" then return end
   -- Kein Befehl des Servermoduls, also ohne dessen Handschlag senden.
   AT.Send(string.sub(cmd, 1, 1) == "." and string.sub(cmd, 2) or cmd, { raw = true })
   B.refused = nil
   if not isRetry then watchRetried = false end
   watchWant = want
   watchUntil = GetTime() + 6
end

function B.Enable(silent)
   if not AT.GetBool("BotControl") then
      if not silent then AT.Warn("Playerbot-Steuerung ist aus (/at bot).") end
      return
   end
   if B.confirmed ~= true then
      SendSelf(AT.Get("SelfOnCommand"), true)
   else
      AT.Debug("Selbstmodus laeuft bereits - nur Profil setzen.")
   end
   B.active = true
   B.ApplyProfile()
end

function B.Disable(silent)
   if B.confirmed == false then
      B.active = false
      return
   end
   SendSelf(AT.Get("SelfOffCommand"), false)
   B.active = false
   if not silent then AT.Print("Playerbot-Selbstmodus wird ausgeschaltet.") end
end

function B.Toggle()
   if B.IsRunning() then B.Disable() else B.Enable() end
end

function B.PrintProfiles()
   AT.Print("Verfuegbare Profile:")
   local cur = AT.Get("Profile")
   for _, p in ipairs(B.List()) do
      DEFAULT_CHAT_FRAME:AddMessage(string.format("   %s%-14s|r %s%s",
         (p.key == cur) and "|cff53d17a" or "|cffaaaaaa", p.name .. (p.modified and " *" or ""),
         p.desc, p.modified and "  (geaendert, '/at profil reset " .. p.key .. "')" or ""))
   end
end
