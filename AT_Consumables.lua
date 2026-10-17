-- AT_Consumables.lua
-- ---------------------------------------------------------------------------
-- Flaeschchen, Elixiere und Schriftrollen aus den Taschen, im Kampf.
--
-- Warum im Addon und nicht als Strategie des Bots: mod-playerbots benutzt von sich aus nur
-- Heil- und Manatraenke ("potions"); Schriftrollen, Elixiere und Flaeschchen kennt es nicht.
-- Es kennt aber den Befehl "u <Gegenstand>", der einen Gegenstand aus den Taschen benutzt --
-- derselbe Weg wie bei "e <Erbstueck>" in AT_Gear.lua: eine Fluesternachricht an sich selbst.
--
-- Warum nicht UseContainerItem: das ist eine geschuetzte Funktion; ein Addon darf sie im
-- Kampf nicht aufrufen. Eine Chatnachricht darf es -- und im Kampf soll ja gerade benutzt werden.
--
-- Ablauf (alle 0,5 s, nur im Kampf, nur im Selbstmodus, nur wenn das Profil die Art erlaubt):
--
--   1. Taschen lesen: jeder Gegenstand, den die Tabelle AT.ConsData kennt (AT_ConsumableData.lua,
--      erzeugt aus der Datenbank des Servers; unabhaengig von der Sprache des Clients).
--   2. Buffs des Charakters lesen und mit den Zaubern der Gegenstaende vergleichen.
--   3. Fehlt ein Buff und liegt ein passender Gegenstand in den Taschen: "u <Link>" fluestern.
--   4. Das Ergebnis pruefen: ist der Gegenstand weniger geworden oder der Buff da? Sonst erneut
--      versuchen, nach mehreren Fehlschlaegen den Gegenstand eine Weile sperren.
--
-- Ist der Buff abgelaufen, fehlt er wieder, und der naechste Gegenstand derselben Art kommt dran:
-- solange der Vorrat reicht. Es gibt keine Zeitschaltuhr; der Zustand ist der Buff selbst.
--
-- Plaetze, die der SERVER vorgibt (spell_group der Datenbank, siehe tools/gen_consumables.py):
--   Kampfelixier    (battle)    Gruppe 1: je Charakter wirkt eines
--   Waechterelixier (guardian)  Gruppe 2: ebenso
--   Flaeschchen     (flask)     belegt BEIDE Plaetze und ersetzt Elixiere
--   Schriftrolle    (scroll)    Gruppe 1087, "exklusiv": die sechs Werte (Staerke, Beweglichkeit,
--                               Intelligenz, Ausdauer, Willenskraft, Schutz) teilen sich EINEN Platz.
--                               Eine neue Schriftrolle ENTFERNT die alte, auch die eines anderen Werts.
--   Runenschriftrolle der Seelenstaerke (fortitude): steht nicht in dieser Gruppe. Ihr Zauber ist nur ein
--                               Script, der Buff auf dem Charakter ist Zauber 72590 (Gruppe 1084, "Single
--                               Stamina Buffs", Regel 4: der staerkste gewinnt). Wirkt schon ein Ausdauerbuff
--                               (Machtwort: Seelenstaerke, Schriftrolle der Ausdauer ...), ist die Rolle
--                               umsonst: der Kern verwirft den schwaecheren Buff, NACHDEM sie verbraucht ist.
-- Daraus folgt: ein Flaeschchen wird nur benutzt, wenn keiner der beiden Plaetze belegt ist, und ein
-- Elixier nur, wenn sein Platz frei ist; eine Schriftrolle nur, wenn KEINE Schriftrolle wirkt. Sonst
-- ersetzte das Addon einen Buff durch den anderen, fand den ersten wieder fehlend und benutzte ihn
-- erneut -- und verbrauchte den ganzen Vorrat. Belegt wird ein Platz auch von Zaubern, die kein Elixier
-- sind (Juju, Zanza, R.O.I.D.S., Wasserwandeln ...): AT.ConsGroups nennt die ganzen Gruppen.
--
-- Schriftrollen: welcher Wert, bestimmt die Klasse (bei Krieger, Paladin, Schamane und Druide auch der
-- Talentbaum): ein Magier bekommt Intelligenz, kein Krieger. '/at buffs wert <Wert>' stellt einen Wert
-- fest ein. Gewaehlt wird die hoechste Stufe dieses Werts, die der Charakter tragen darf.
-- Schriftrollen wirken auf ein freundliches Ziel (so steht es in ihrem Tooltip; die Zauberdaten liegen
-- hier nicht vor). UseItemAction schickt keinen Zielwunsch, der Server nimmt dann die Auswahl des
-- Spielers, wenn sie ein gueltiges Ziel ist, und sonst den Charakter selbst. Ist im Client ein
-- Verbuendeter ausgewaehlt, wartet das Addon deshalb: die Schriftrolle ginge an ihn.
--
-- Der Server benutzt nur, wenn der Charakter steht und nicht zaubert (UseItemAction::UseItem). Als
-- "bewegt" gilt dort jedes Bewegungsflag: laufen, strafen, FALLEN, steigen und sinken. Als "zaubert" gilt
-- auch ein Kanalzauber (er wird sofort abgewiesen; nur ein Zauber mit Zauberzeit laesst den Befehl bis zu
-- seinem Ende warten) und ein Dauerzauber: Automatisches Schiessen des Jaegers, ebenso das Schiessen mit
-- dem Zauberstab. Das Addon sendet deshalb nichts, solange der Charakter laeuft, faellt oder zaubert.
-- Jaeger bekommen ihre Gegenstaende in den 25 s nach dem Kampf.
--
-- Ein Befehl, waehrend dessen Wartezeit sich der Charakter bewegt oder zaubert, kann aus diesem Grund
-- abgewiesen worden sein: das sagt nichts ueber den Gegenstand und zaehlt nicht als Fehlschlag (hoechstens
-- MAX_UNCLEAR Mal in Folge).
--
-- Geht ein Gegenstand trotzdem nicht (ob ein Elixier im Kampf erlaubt ist, haengt vom Zauber ab; ein
-- staerkerer Buff derselben Art weist ihn ab; den Grund meldet der Server dem Client in der Regel nicht):
-- nach MAX_TRIES Fehlschlaegen im Kampf wird er in den 25 s NACH dem Kampf versucht, nach weiteren ohne
-- Erfolg gesperrt -- mit wachsender Pause (90 s, 5 min, 15 min, 1 h), damit ein dauerhaft abgewiesener
-- Gegenstand nicht bei jedem Kampf Befehle und Meldungen erzeugt. Die Meldung kommt je Gegenstand einmal.
--
-- Sicherungen gegen Verschwendung (das sind Gegenstaende, die der Spieler gesammelt hat):
--
--   * Mindestabstand je Platz nach einer Benutzung: 45 s, wenn der Buff danach zu sehen war;
--     10 min, wenn nicht (dann ist die Erkennung unsicher, und es wird gewarnt).
--   * hoechstens 10 Benutzungen in 2 Minuten, in der Summe aller Gegenstaende.
--   * je Gegenstand wenige Versuche, dann eine wachsende Sperre.
--   * 7 s Geduld, bevor ein Befehl als abgewiesen gilt: hinter einem Zauber mit Zauberzeit wartet er auf
--     dessen Ende (PlayerbotAI::UpdateAI), und mit 3,5 s galt er dann faelschlich als abgewiesen.
--   * Nach einer Benutzung 3,1 s ab dem Zeitpunkt, an dem sie zu sehen war: die Abklingzeit der Kategorie
--     (Elixiere und Flaeschchen) laeuft ab der AUSFUEHRUNG, nicht ab dem Senden.
--   * "/at buffs ignorieren <Link>" nimmt einen Gegenstand dauerhaft aus der Auswahl.
-- ---------------------------------------------------------------------------

AutoTravel = AutoTravel or {}
local AT = AutoTravel
local B = AT.Bot

AT.Cons = {}
local C = AT.Cons

-- Die Zeiten. Der Server benutzt einen Gegenstand nur, wenn der Charakter steht und nicht zaubert
-- (UseItemAction::UseItem): der erste Versuch beim Laufen bleibt stehen und scheitert, der zweite
-- gelingt. Deshalb mehrere Versuche je Gegenstand.
local TICK                = 0.5     -- Takt der Pruefung (s)
local VERIFY_AFTER        = 1.2     -- fruehestens so lange nach dem Senden wird das Ergebnis gelesen
local VERIFY_UNTIL        = 7.0     -- spaetestens so lange wird abgewartet (ein Befehl wartet auf das Ende eines Zaubers)
local QUEUE_TIMEOUT       = 20      -- ein Befehl, der so lange in der Warteschlange haengt, gilt als verloren
local MAX_TRIES           = 3       -- Fehlschlaege je Gegenstand in Folge, dann Sperre
local MAX_UNCLEAR         = 5       -- unklare Versuche (Charakter bewegte sich oder zauberte) in Folge, dann zaehlt es doch
local AFTER_SEEN          = 3.1     -- Abstand zur naechsten Benutzung ab dem Zeitpunkt, an dem die letzte zu sehen war
local BLOCK_STEPS         = { 90, 300, 900, 3600 }   -- Dauer der 1., 2., 3., 4. und jeder weiteren Sperre in Folge (s)
local PEACE_DECAY         = 1800    -- so lange gilt "im Kampf ging es nicht", dann wird neu geprueft
local GAP_VERIFIED        = 45      -- Mindestabstand je Platz, Buff nach der Benutzung gesehen
local GAP_UNVERIFIED      = 600     -- ... nicht gesehen
local RATE_WINDOW         = 120
local RATE_MAX            = 10
local AFTER_WINDOW        = 25      -- so lange nach dem Kampf werden Gegenstaende nachgeholt, die im Kampf nicht gingen

C.TICK = TICK
C.VERIFY_UNTIL, C.MAX_TRIES, C.BLOCK_STEPS, C.PEACE_DECAY = VERIFY_UNTIL, MAX_TRIES, BLOCK_STEPS, PEACE_DECAY
C.MAX_UNCLEAR, C.AFTER_SEEN = MAX_UNCLEAR, AFTER_SEEN

-- Anzeige
local KIND_LABEL = {
   flask = "Flaeschchen", battle = "Kampfelixier", guardian = "Waechterelixier",
}
local FAMILY_LABEL = {
   strength = "Staerke", agility = "Beweglichkeit", intellect = "Intelligenz",
   stamina = "Ausdauer", spirit = "Willenskraft", protection = "Schutz", fortitude = "Seelenstaerke",
}
-- Die sechs Werte, die sich beim Server einen Platz teilen (spell_group 1087). Die Runenschriftrolle der
-- Seelenstaerke (fortitude) gehoert nicht dazu.
local SCROLL_STATS = { "strength", "agility", "intellect", "stamina", "spirit", "protection" }
C.SCROLL_STATS = SCROLL_STATS
-- Wenn die Klasse nicht zu erkennen ist: Werte, die jedem etwas bringen
local SAFE_STATS = { "stamina", "protection" }

-- Zustand
C.state = {
   pending = nil,       -- { id, key, link, queuedAt, sentAt, countBefore, mode }
   nextAt = 0,          -- fruehester Zeitpunkt der naechsten Benutzung
   slot = {},           -- key -> { lastUse, verified }
   item = {},           -- id -> { tries, blocks, blockedUntil }
   peace = {},          -- id -> Zeitpunkt (oder true): im Kampf nicht benutzbar, wird nach dem Kampf versucht
   combatEndedAt = nil, -- Ende des letzten Kampfes
   uses = {},           -- Zeitpunkte gelungener Benutzungen (fuer die Obergrenze)
   warned = {},         -- Schluessel -> true: jede Meldung je Gegenstand nur einmal
   total = 0,           -- gelungene Benutzungen in dieser Sitzung
   last = nil,          -- Text der letzten Handlung, fuer '/at buffs'
}

-- ---------------------------------------------------------------------------
-- Die Tabelle, nach Plaetzen geordnet
-- ---------------------------------------------------------------------------

-- Die Tabelle kommt aus AT_ConsumableData.lua; fehlt die Datei, ist sie leer, und nichts geschieht.
local function Data() return AT.ConsData or {} end

local index

local function Index()
   if index then return index end
   index = { battle = {}, guardian = {}, flask = {}, family = {}, scroll = {}, stamina = {} }
   for _, d in pairs(Data()) do
      local kind, spell, fam = d[1], d[2], d[5]
      if kind == "flask" then
         index.flask[spell] = true
         index.battle[spell] = true
         index.guardian[spell] = true
      elseif kind == "battle" then
         index.battle[spell] = true
      elseif kind == "guardian" then
         index.guardian[spell] = true
      elseif kind == "scroll" and fam then
         index.family[fam] = index.family[fam] or {}
         index.family[fam][spell] = true
         -- die sechs Werte teilen sich einen Platz; die Runenschriftrolle nicht
         if fam ~= "fortitude" then index.scroll[spell] = true end
      end
   end
   -- Die ganzen Elixiergruppen des Servers: auch Juju, Zanza und andere belegen den Platz.
   local groups = AT.ConsGroups
   if type(groups) == "table" then
      for _, spell in ipairs(groups.battle or {}) do index.battle[spell] = true end
      for _, spell in ipairs(groups.guardian or {}) do index.guardian[spell] = true end
      for _, spell in ipairs(groups.stamina or {}) do index.stamina[spell] = true end
   end
   return index
end

-- Nur fuer Tests: die Tabelle wurde ausgetauscht.
function C.ResetIndex() index = nil end

local function ItemId(link)
   if type(link) ~= "string" then return nil end
   local id = string.match(link, "item:(%d+)")
   return id and tonumber(id) or nil
end
C.ItemId = ItemId

-- Platz eines Gegenstands: "flask", "battle", "guardian", "scroll" (die sechs Werte) oder "fortitude"
local function KeyOf(d)
   if d[1] == "scroll" then return d[5] == "fortitude" and "fortitude" or "scroll" end
   return d[1]
end

-- ---------------------------------------------------------------------------
-- Taschen und Buffs lesen
-- ---------------------------------------------------------------------------

-- Alle bekannten Gegenstaende in den Taschen (Rucksack und vier Taschen), nach Kennung
-- zusammengezaehlt. Rueckgabe: { [id] = { id, link, count, d, bag, slot } }
function C.Scan()
   local stock = {}
   local data = Data()
   for bag = 0, 4 do
      local slots = GetContainerNumSlots(bag) or 0
      for slot = 1, slots do
         local link = GetContainerItemLink(bag, slot)
         local id = link and ItemId(link)
         local d = id and data[id]
         if d then
            local _, count = GetContainerItemInfo(bag, slot)
            count = tonumber(count) or 1
            local e = stock[id]
            if e then
               e.count = e.count + count
            else
               stock[id] = { id = id, link = link, count = count, d = d, bag = bag, slot = slot }
            end
         end
      end
   end
   return stock
end

-- Buffs des Charakters: ids[Zauber] = Ablaufzeit (oder true), names[Name] = true.
-- Rueckgabe: ids, names, hasIds. Liefert der Client keine Zauberkennung (aeltere Staende), gilt
-- der Name; sonst nur die Kennung: Namen wiederholen sich ("Agility" bei Elixier und Schriftrolle).
function C.Auras()
   local ids, names, hasIds = {}, {}, false
   for i = 1, 40 do
      local name, _, _, _, _, _, expires, _, _, _, spellId = UnitBuff("player", i)
      if not name then break end
      names[name] = true
      if spellId then
         hasIds = true
         ids[spellId] = (type(expires) == "number" and expires > 0) and expires or true
      end
   end
   return { ids = ids, names = names, hasIds = hasIds }
end

local spellNames = {}
local function SpellName(id)
   local n = spellNames[id]
   if n == nil then
      n = (GetSpellInfo and GetSpellInfo(id)) or false
      spellNames[id] = n
   end
   return n or nil
end

-- Wirkt einer der Zauber der Menge auf dem Charakter?
local function AnyActive(set, auras)
   if not set then return false end
   for spell in pairs(set) do
      if auras.ids[spell] then return true end
      if not auras.hasIds then
         local n = SpellName(spell)
         if n and auras.names[n] then return true end
      end
   end
   return false
end

-- Wirkt genau der Zauber dieses Gegenstands?
local function SpellActive(spell, auras)
   if auras.ids[spell] then return true end
   if not auras.hasIds then
      local n = SpellName(spell)
      return n ~= nil and auras.names[n] == true
   end
   return false
end

-- ---------------------------------------------------------------------------
-- Auswahl
-- ---------------------------------------------------------------------------

-- Ist a der bessere Gegenstand? Hoehere Stufe, dann hoeherer Rang (Schriftrollen), dann
-- hoehere Kennung: eine Gesamtordnung, damit die Wahl nie vom Zufall der Tabelle abhaengt.
local function Better(a, b)
   local da, db = a.d, b.d
   if da[1] == "scroll" and db[1] == "scroll" and (da[6] or 0) ~= (db[6] or 0) then
      return (da[6] or 0) > (db[6] or 0)
   end
   if da[4] ~= db[4] then return da[4] > db[4] end
   if da[3] ~= db[3] then return da[3] > db[3] end
   return a.id > b.id
end

-- Geht der Gegenstand im Kampf nicht? Der Eintrag traegt den Zeitpunkt, zu dem das gemerkt wurde;
-- nach PEACE_DECAY wird neu geprueft (Lage, Buffs und Stufe aendern sich). 'true' verfaellt nicht.
local function PeaceOn(st, id, now)
   local v = st.peace and st.peace[id]
   if v == nil or v == false then return false end
   if type(v) == "number" and (now - v) > PEACE_DECAY then return false end
   return true
end

-- Welcher Gegenstand ist als naechster dran? Reine Funktion: alles Noetige kommt aus 'o',
-- sie ruft kein Spiel und sendet nichts.
--
--   stock   C.Scan()
--   auras   C.Auras()
--   o.level    Stufe des Charakters
--   o.wanted   { flask = bool, elixir = bool, scroll = bool }
--   o.ignore   { [id] = true }
--   o.state    C.state (Sperren und Mindestabstaende)
--   o.now      Zeit
--   o.mode     "combat" (im Kampf: ohne die, die dort nicht gingen), "after" (nach dem Kampf: nur diese)
--              oder "now" (alle; '/at buffs jetzt' und die Anzeige)
--   o.afterAll nach dem Kampf ALLE Gegenstaende (Klassen, bei denen im Kampf nichts geht: Jaeger)
--   o.stats    Werte, die dem Charakter etwas bringen, in der Reihenfolge der Vorliebe (C.PreferredStats)
--   o.friendly ein Verbuendeter ist ausgewaehlt: eine Schriftrolle ginge an ihn
--
-- Rueckgabe: Eintrag und Platz, oder nil und eine Liste von Gruenden (fuer die Anzeige).
function C.Decide(stock, auras, o)
   local idx = Index()
   local st, now = o.state, o.now
   local why = {}

   local mode = o.mode or "now"

   local function usable(e)
      if o.ignore and o.ignore[e.id] then return false end
      if (e.d[3] or 0) > (o.level or 1) then return false end
      local it = st.item[e.id]
      if it and it.blockedUntil and it.blockedUntil > now then return false end
      local peace = PeaceOn(st, e.id, now)
      if mode == "combat" and peace then return false end                  -- im Kampf ging es nicht
      if mode == "after" and not peace and not o.afterAll then return false end   -- nach dem Kampf nur das Nachzuholende
      return true
   end

   local function gapOk(key)
      local s = st.slot[key]
      if not s or not s.lastUse then return true end
      return (now - s.lastUse) >= (s.verified and GAP_VERIFIED or GAP_UNVERIFIED)
   end

   local function best(filter)
      local b
      for _, e in pairs(stock) do
         if filter(e) and usable(e) and (not b or Better(e, b)) then b = e end
      end
      return b
   end

   local battleOn = AnyActive(idx.battle, auras)
   local guardOn = AnyActive(idx.guardian, auras)

   if o.wanted.flask then
      if battleOn or guardOn then
         why[#why + 1] = "Flaeschchen: ein Elixier- oder Flaeschchenplatz ist belegt"
      elseif not (gapOk("flask") and gapOk("battle") and gapOk("guardian")) then
         -- Auch die Elixierplaetze zaehlen: ein eben benutztes Elixier, dessen Buff nicht zu sehen ist,
         -- wuerde sonst vom Flaeschchen ersetzt.
         why[#why + 1] = "Flaeschchen: Mindestabstand nach der letzten Benutzung"
      else
         local e = best(function(x) return x.d[1] == "flask" end)
         if e then return e, "flask", why end
         why[#why + 1] = "Flaeschchen: keines in den Taschen"
      end
   end

   if o.wanted.elixir then
      for _, key in ipairs({ "battle", "guardian" }) do
         local on
         if key == "battle" then on = battleOn else on = guardOn end
         if on then
            why[#why + 1] = KIND_LABEL[key] .. ": Platz belegt"
         elseif not gapOk(key) then
            why[#why + 1] = KIND_LABEL[key] .. ": Mindestabstand nach der letzten Benutzung"
         else
            local e = best(function(x) return x.d[1] == key end)
            if e then return e, key, why end
            why[#why + 1] = KIND_LABEL[key] .. ": keines in den Taschen"
         end
      end
   end

   if o.wanted.scroll then
      -- EIN Platz fuer die sechs Werte (spell_group 1087, exklusiv): wirkt irgendeine Schriftrolle, ist er
      -- belegt; eine zweite eines anderen Werts ersetzte die erste, und die erste fehlte wieder.
      if AnyActive(idx.scroll, auras) then
         why[#why + 1] = "Schriftrolle: eine wirkt bereits (der Server erlaubt nur eine)"
      elseif not gapOk("scroll") then
         why[#why + 1] = "Schriftrolle: Mindestabstand nach der letzten Benutzung"
      elseif o.friendly then
         why[#why + 1] = "Schriftrolle: ein Verbuendeter ist ausgewaehlt, sie ginge an ihn"
      else
         local wantedStat = {}
         for _, fam in ipairs(o.stats or SCROLL_STATS) do wantedStat[fam] = true end
         local picked
         for _, fam in ipairs(o.stats or SCROLL_STATS) do
            picked = best(function(x) return x.d[1] == "scroll" and x.d[5] == fam end)
            if picked then break end
         end
         if picked then return picked, "scroll", why end
         -- Keine Schriftrolle in den Taschen ist der Normalfall (keine Meldung). Liegen aber nur Rollen fuer
         -- Werte da, die dem Charakter nichts bringen, soll die Anzeige das sagen.
         local other, names = {}, {}
         for _, e in pairs(stock) do
            local fam = e.d[1] == "scroll" and e.d[5]
            if fam and fam ~= "fortitude" and not wantedStat[fam] and not other[fam] then
               other[fam] = true
               names[#names + 1] = FAMILY_LABEL[fam] or tostring(fam)
            end
         end
         if #names > 0 then
            table.sort(names)
            why[#why + 1] = "Schriftrolle: nur fuer " .. table.concat(names, ", ") ..
                            " in den Taschen, das bringt dem Charakter nichts ('/at buffs wert' aendert die Wahl)"
         end
      end

      -- Die Runenschriftrolle der Seelenstaerke steht nicht in der Gruppe der sechs Werte. Ihr Buff gehoert
      -- aber zu den Ausdauerbuffs (Regel 4, der staerkste gewinnt): neben einem anderen waere sie umsonst.
      if AnyActive(idx.family.fortitude, auras) then
         why[#why + 1] = "Runenschriftrolle: wirkt"
      elseif AnyActive(idx.stamina, auras) then
         why[#why + 1] = "Runenschriftrolle: ein anderer Ausdauerbuff wirkt (der staerkere bleibt, die Rolle waere umsonst)"
      elseif not gapOk("fortitude") then
         why[#why + 1] = "Runenschriftrolle: Mindestabstand nach der letzten Benutzung"
      elseif not o.friendly then
         local e = best(function(x) return x.d[1] == "scroll" and x.d[5] == "fortitude" end)
         if e then return e, "fortitude", why end
      end
   end

   return nil, nil, why
end

-- ---------------------------------------------------------------------------
-- Zustand: Profil, Ausschlussliste
-- ---------------------------------------------------------------------------

-- Welche Arten erlaubt das aktuelle Profil?
function C.Wanted()
   local p = B.Current()
   local t = p and p.cons
   return {
      flask  = B.ConsOn(t, "flask"),
      elixir = B.ConsOn(t, "elixir"),
      scroll = B.ConsOn(t, "scroll"),
   }
end

local function AnyWanted(w) return w.flask or w.elixir or w.scroll end

function C.IgnoreList()
   local g = B.Global()
   if type(g.consIgnore) ~= "table" then g.consIgnore = {} end
   return g.consIgnore
end

-- ---------------------------------------------------------------------------
-- Welcher Wert, und wann darf gesendet werden
-- ---------------------------------------------------------------------------

-- Werte, die der Klasse im Kampf etwas bringen, in der Reihenfolge der Vorliebe. Eine Annahme, keine
-- Messung: '/at buffs wert <Wert>' stellt einen Wert fest ein. Jede Liste endet mit Werten, die jedem
-- helfen (Ausdauer, Schutz), damit liegende Schriftrollen nicht ungenutzt bleiben.
local CLASS_STATS = {
   WARRIOR     = { "strength", "stamina", "protection" },
   PALADIN     = { "strength", "intellect", "stamina", "protection" },
   HUNTER      = { "agility", "stamina", "protection" },
   ROGUE       = { "agility", "stamina", "protection" },
   PRIEST      = { "intellect", "spirit", "stamina" },
   DEATHKNIGHT = { "strength", "stamina", "protection" },
   SHAMAN      = { "intellect", "agility", "stamina" },
   MAGE        = { "intellect", "stamina", "spirit" },
   WARLOCK     = { "intellect", "stamina", "spirit" },
   DRUID       = { "intellect", "agility", "stamina" },
}

-- Talentbaum (1 bis 3) -> Wert, der dort vorgeht. Nur, wo er vom Standard der Klasse abweicht.
local SPEC_STATS = {
   WARRIOR = { [3] = "stamina" },                                        -- Schutz
   PALADIN = { [1] = "intellect", [2] = "stamina", [3] = "strength" },   -- Heilig, Schutz, Vergeltung
   SHAMAN  = { [2] = "agility" },                                        -- Verstaerkung
   DRUID   = { [2] = "agility" },                                        -- Wilder Kampf
}

-- Der Talentbaum mit den meisten Punkten (bei Gleichstand der erste), wie ihn auch der Server waehlt
-- (siehe B.IsFeralSpec). nil ohne Punkte.
local function SpecTab()
   if not GetTalentTabInfo then return nil end
   local best, bestPoints = nil, 0
   for i = 1, 3 do
      local _, _, points = GetTalentTabInfo(i)
      points = tonumber(points) or 0
      if points > bestPoints then best, bestPoints = i, points end
   end
   return best
end

-- Rueckgabe: Liste der Werte (beste zuerst) und woher sie kommt.
function C.PreferredStats()
   local g = B.Global()
   local forced = g and g.consStat
   if type(forced) == "string" and FAMILY_LABEL[forced] and forced ~= "fortitude" then
      return { forced }, "eingestellt"
   end

   local class
   if UnitClass then
      local _
      _, class = UnitClass("player")
   end
   local list = class and CLASS_STATS[class]
   if not list then return SAFE_STATS, "Klasse unbekannt" end

   local spec = SPEC_STATS[class]
   local first = spec and spec[SpecTab() or 0]
   if first then
      local out = { first }
      for _, fam in ipairs(list) do
         if fam ~= first then out[#out + 1] = fam end
      end
      return out, "Klasse und Talentbaum"
   end
   return list, "Klasse"
end

-- Der Server benutzt im Kampf nichts, solange ein Dauerzauber laeuft: UseItemAction::UseItem fragt
-- IsNonMeleeSpellCast(false), und das zaehlt Automatisches Schiessen mit. Der Client sieht es nicht
-- (UnitCastingInfo meldet es nicht). Fuer diese Klassen gilt: erst nach dem Kampf.
local NO_COMBAT_USE = { HUNTER = true }

function C.NoCombatUse()
   if not UnitClass then return false end
   local _, class = UnitClass("player")
   return NO_COMBAT_USE[class] == true
end

-- Ist im Client ein Verbuendeter (nicht man selbst) ausgewaehlt? UseItemAction schickt keinen
-- Zielwunsch; der Server nimmt fuer eine Schriftrolle die Auswahl des Spielers, wenn sie ein gueltiges
-- Ziel ist, und sonst den Charakter selbst.
function C.FriendlyTarget()
   if not (UnitExists and UnitExists("target")) then return false end
   if not (UnitIsFriend and UnitIsFriend("player", "target")) then return false end
   if UnitIsUnit and UnitIsUnit("target", "player") then return false end
   return true
end

-- Laeuft, faellt oder zaubert der Charakter? Das sind die Zustaende, in denen der Server den Befehl abweist
-- (UseItemAction::UseItem: isMoving() zaehlt laufen, strafen, fallen, steigen und sinken; IsNonMeleeSpellCast
-- zaehlt auch Kanalzauber). nil, wenn nichts davon zutrifft; sonst der Grund als Text.
local function Disturbance()
   if UnitCastingInfo and UnitCastingInfo("player") then return "der Charakter zaubert" end
   if UnitChannelInfo and UnitChannelInfo("player") then return "der Charakter kanalisiert einen Zauber" end
   if GetUnitSpeed and (GetUnitSpeed("player") or 0) > 0 then return "der Charakter bewegt sich" end
   if IsFalling and IsFalling() then return "der Charakter faellt" end
   return nil
end
C.Disturbance = Disturbance

-- Warum kann gerade nichts gesendet werden? nil, wenn nichts im Weg steht. Wer sendet, waehrend sich der
-- Charakter bewegt oder zaubert, bekommt eine Absage, die wie ein Fehlschlag des Gegenstands aussaehe.
function C.Blocker()
   if not B or not AT.GetBool("BotControl") or not B.IsRunning() then
      return "der Selbstmodus laeuft nicht"
   end
   if UnitIsDeadOrGhost("player") then return "der Charakter ist tot" end
   if UnitOnTaxi and UnitOnTaxi("player") then return "der Charakter fliegt" end
   if IsMounted and IsMounted() then return "der Charakter reitet" end
   if UnitHasVehicleUI and UnitHasVehicleUI("player") then return "der Charakter sitzt in einem Fahrzeug" end
   return Disturbance()
end

-- ---------------------------------------------------------------------------
-- Benutzen und Ergebnis pruefen
-- ---------------------------------------------------------------------------

local function Describe(d)
   if d[1] == "scroll" then
      return "Schriftrolle " .. (FAMILY_LABEL[d[5]] or tostring(d[5]))
   end
   return KIND_LABEL[d[1]] or d[1]
end

local function NoteLast(text)
   C.state.last = text
   AT.Debug("Verbrauchsgut: " .. text)
end

-- Eine gelungene Benutzung vermerken. 'seen': der Buff war danach zu sehen.
local function OnSuccess(p, seen, now)
   local S = C.state
   local d = Data()[p.id]
   S.item[p.id] = nil
   -- Die Abklingzeit der Kategorie (3 s fuer Elixiere und Flaeschchen) laeuft ab der Ausfuehrung, und die kann
   -- nach dem Senden liegen, wenn der Charakter zauberte. Erst wenn die Benutzung zu sehen ist, steht fest,
   -- dass sie ausgefuehrt wurde.
   S.nextAt = now + AFTER_SEEN
   S.total = S.total + 1
   S.uses[#S.uses + 1] = now

   local rec = { lastUse = now, verified = seen }
   S.slot[p.key] = rec
   -- Ein Flaeschchen belegt beide Plaetze: auch sie bekommen den Mindestabstand, damit ein
   -- unsichtbarer Buff nicht zu einem Elixier fuehrt, das ihn ersetzt.
   if d and d[1] == "flask" then
      S.slot.battle = { lastUse = now, verified = seen }
      S.slot.guardian = { lastUse = now, verified = seen }
   end

   local left = math.max(0, (p.countBefore or 1) - 1)
   AT.Print("Benutzt: " .. (p.link or "?") .. " (" .. (d and Describe(d) or "?") .. ", noch " .. left .. ")")
   NoteLast("benutzt " .. (p.link or "?") .. (seen and ", Buff sichtbar" or ", Buff NICHT sichtbar"))

   if not seen and not S.warned[p.id] then
      S.warned[p.id] = true
      AT.Warn((p.link or "Der Gegenstand") .. " wurde verbraucht, aber sein Buff ist nicht zu sehen. " ..
              "Das Addon benutzt diese Art deshalb fruehestens in 10 Minuten wieder.")
   end
end

-- Jede Meldung je Gegenstand nur einmal: ein dauerhaft abgewiesener Gegenstand soll nicht bei jedem
-- Kampf den Chat fuellen. '/at buffs' zeigt den Zustand jederzeit.
local function WarnOnce(key, text)
   local S = C.state
   if S.warned[key] then return end
   S.warned[key] = true
   AT.Warn(text)
end

local function OnFailure(p, now)
   local S = C.state
   local it = S.item[p.id] or { tries = 0, blocks = 0 }
   S.item[p.id] = it
   it.unclear = 0
   it.tries = (it.tries or 0) + 1

   if it.tries < MAX_TRIES then
      NoteLast("kein Erfolg bei " .. (p.link or "?") .. " (Versuch " .. it.tries .. " von " .. MAX_TRIES .. ")")
      return
   end

   it.tries = 0
   if p.mode == "combat" then
      -- Im Kampf geht es nicht: nach dem Kampf noch einmal, ohne den Gegenstand zu sperren.
      S.peace[p.id] = now
      WarnOnce("p" .. p.id, (p.link or "Der Gegenstand") .. " liess sich im Kampf nicht benutzen (" .. MAX_TRIES ..
               " Versuche). Das Addon versucht es nach dem Kampf. Gruende koennen ein staerkerer Buff derselben " ..
               "Art, eine Abklingzeit oder die Regeln des Servers sein.")
      NoteLast("nur noch nach dem Kampf: " .. (p.link or "?"))
   else
      -- Auch ausserhalb des Kampfes nicht: es liegt nicht am Kampf. Die Pause waechst mit jeder Wiederholung.
      it.blocks = (it.blocks or 0) + 1
      local secs = BLOCK_STEPS[math.min(it.blocks, #BLOCK_STEPS)]
      it.blockedUntil = now + secs
      WarnOnce("b" .. p.id, (p.link or "Der Gegenstand") .. " liess sich nicht benutzen (" .. MAX_TRIES ..
               " Versuche). Pause: " .. secs .. " s, bei weiteren Fehlschlaegen laenger. Stufe, Abklingzeit oder " ..
               "ein staerkerer Buff derselben Art koennen im Weg sein.")
      NoteLast("gesperrt fuer " .. secs .. " s: " .. (p.link or "?"))
   end
end

-- Der Charakter bewegte sich oder zauberte, waehrend der Befehl unterwegs war: der Server kann ihn aus diesem
-- Grund abgewiesen haben. Das sagt nichts ueber den Gegenstand und zaehlt nicht als Fehlschlag -- sonst
-- machten drei solche Zufaelle in Folge aus einem brauchbaren Gegenstand einen, der eine halbe Stunde
-- nur nach dem Kampf benutzt wird. Wiederholt es sich MAX_UNCLEAR Mal, zaehlt es doch.
local function OnUnclear(p, now)
   local S = C.state
   local it = S.item[p.id] or { tries = 0, blocks = 0 }
   S.item[p.id] = it
   it.unclear = (it.unclear or 0) + 1
   if it.unclear >= MAX_UNCLEAR then
      it.unclear = 0
      OnFailure(p, now)
      return
   end
   NoteLast("keine Wirkung bei " .. (p.link or "?") .. ", der Charakter bewegte sich oder zauberte (zaehlt nicht)")
end

-- Hat die letzte Benutzung gewirkt? true, wenn die Pruefung abgeschlossen ist.
local function Settle(now)
   local S = C.state
   local p = S.pending
   if not p then return true end

   if not p.sentAt then
      -- Noch nicht hinausgegangen. Haengt der Befehl zu lange, ist er verloren.
      if now - p.queuedAt > QUEUE_TIMEOUT then
         S.pending = nil
         return true
      end
      return false
   end

   local dt = now - p.sentAt
   if dt < VERIFY_AFTER then return false end

   local d = Data()[p.id]
   local stock = C.Scan()
   local count = stock[p.id] and stock[p.id].count or 0
   local consumed = count < (p.countBefore or 0)
   local seen = d ~= nil and SpellActive(d[2], C.Auras())

   if consumed or seen then
      S.pending = nil
      OnSuccess(p, seen, now)
      return true
   end
   if dt >= VERIFY_UNTIL then
      S.pending = nil
      if p.disturbed then OnUnclear(p, now) else OnFailure(p, now) end
      return true
   end
   return false
end

local function RecentUses(now)
   local S = C.state
   for i = #S.uses, 1, -1 do
      if now - S.uses[i] > RATE_WINDOW then table.remove(S.uses, i) end
   end
   return #S.uses
end

-- Ein Schritt: wertet die letzte Benutzung aus und beginnt, falls noetig, die naechste.
-- 'force': auch ausserhalb des Kampfes ("/at buffs jetzt"). Rueckgabe: der Gegenstand, den dieser
-- Schritt anstiess, oder nil -- und, wenn etwas im Weg stand, der Grund.
function C.Tick(now, force)
   local S = C.state

   -- Das Ergebnis der letzten Benutzung wird immer ausgewertet, auch nach dem Kampf.
   if S.pending then
      if not (B and AT.GetBool("BotControl") and B.IsRunning()) then
         S.pending = nil
      else
         -- Hat sich der Charakter waehrend des Wartens bewegt oder gezaubert, kann der Server den Befehl aus
         -- diesem Grund abgewiesen haben (siehe OnUnclear).
         if S.pending.sentAt and Disturbance() then S.pending.disturbed = true end
         if not Settle(now) then return nil, "ein Befehl ist noch unterwegs" end
      end
   end

   -- Im Kampf; danach noch kurz fuer das, was im Kampf nicht ging; "jetzt" erlaubt alles.
   -- Klassen mit Dauerzauber (Jaeger): im Kampf nichts, danach alles.
   local noCombat = C.NoCombatUse()
   local mode
   if force then
      mode = "now"
   elseif UnitAffectingCombat("player") then
      if noCombat then return nil end
      mode = "combat"
   elseif S.combatEndedAt and (now - S.combatEndedAt) <= AFTER_WINDOW and (noCombat or next(S.peace) ~= nil) then
      mode = "after"
   else
      return nil
   end
   if now < S.nextAt then
      return nil, string.format("Mindestabstand zur letzten Benutzung (noch %d s)", math.ceil(S.nextAt - now))
   end

   local wanted = C.Wanted()
   if not AnyWanted(wanted) then return nil end

   local blocked = C.Blocker()
   if blocked then return nil, blocked end

   if RecentUses(now) >= RATE_MAX then
      NoteLast("Obergrenze erreicht (" .. RATE_MAX .. " Benutzungen in " .. RATE_WINDOW .. " s)")
      return nil, "Obergrenze erreicht (" .. RATE_MAX .. " Benutzungen in " .. RATE_WINDOW .. " s)"
   end

   local stats = C.PreferredStats()
   local e, key, why = C.Decide(C.Scan(), C.Auras(), {
      level = UnitLevel("player"), wanted = wanted, ignore = C.IgnoreList(), state = S, now = now, mode = mode,
      stats = stats, friendly = C.FriendlyTarget(), afterAll = noCombat,
   })
   if not e then
      if why and #why > 0 then return nil, table.concat(why, "; ") end
      return nil
   end

   local p = { id = e.id, key = key, link = e.link, queuedAt = now, countBefore = e.count, mode = mode }
   S.pending = p                   -- bis das Ergebnis da ist, wird nichts weiter gesendet
   NoteLast("versuche " .. e.link .. " (" .. Describe(e.d) .. ")")
   B.Whisper("u " .. e.link, function() p.sentAt = GetTime() end)
   return e
end

-- ---------------------------------------------------------------------------
-- Takt und Ereignisse
-- ---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
local acc = 0

frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

frame:SetScript("OnEvent", function(_, event)
   local S = C.state
   if event == "PLAYER_REGEN_DISABLED" then
      acc = TICK                       -- gleich pruefen, nicht erst nach dem Takt
   elseif event == "PLAYER_REGEN_ENABLED" then
      S.combatEndedAt = GetTime()
      acc = TICK
   elseif event == "PLAYER_DEAD" then
      -- Mit dem Tod sind die Buffs weg (Flaeschchen bleiben, aber auch die erkennt der naechste Blick):
      -- die Mindestabstaende gelten nicht mehr.
      S.slot = {}
      S.pending = nil
   elseif event == "PLAYER_ENTERING_WORLD" then
      S.pending = nil
      S.nextAt = 0
   end
end)

frame:SetScript("OnUpdate", function(_, elapsed)
   acc = acc + elapsed
   if acc < TICK then return end
   acc = 0
   C.Tick(GetTime(), false)
end)

-- ---------------------------------------------------------------------------
-- Anzeige und Befehle
-- ---------------------------------------------------------------------------

-- "Staerke", "staerke", Staerke mit Umlaut (UTF-8), "str" ... -> Familie; "auto" -> "auto"; sonst nil
local STAT_ALIASES = {
   staerke = "strength", strength = "strength", str = "strength",
   beweglichkeit = "agility", agility = "agility", agi = "agility",
   intelligenz = "intellect", intellect = "intellect", int = "intellect",
   ausdauer = "stamina", stamina = "stamina", sta = "stamina",
   willenskraft = "spirit", spirit = "spirit", wille = "spirit",
   schutz = "protection", protection = "protection", ruestung = "protection",
   auto = "auto", automatisch = "auto",
}

local function StatFromText(text)
   text = string.lower(AT.trim(text or ""))
   text = string.gsub(text, "\195\164", "ae")        -- Umlaute des Clients (UTF-8)
   text = string.gsub(text, "\195\182", "oe")
   text = string.gsub(text, "\195\188", "ue")
   text = string.gsub(text, "\195\159", "ss")
   return STAT_ALIASES[text]
end

local function Say(text) DEFAULT_CHAT_FRAME:AddMessage("   " .. text) end

function C.Report()
   local S = C.state
   local now = GetTime()
   local p = B.Current()
   local w = C.Wanted()
   local function onoff(v) return v and "|cff53d17aan|r" or "|cff9099a8aus|r" end

   AT.Print("Verbrauchsgueter im Kampf  |  Profil: " .. tostring(p and p.name or "?") .. "  |  Selbstmodus: " ..
            B.StatusText())
   Say("Flaeschchen " .. onoff(w.flask) .. ", Elixiere " .. onoff(w.elixir) .. ", Schriftrollen " ..
       onoff(w.scroll) .. "   (Einstellung: /at profil bearbeiten)")

   local stats, source = C.PreferredStats()
   local labels = {}
   for _, f in ipairs(stats) do labels[#labels + 1] = FAMILY_LABEL[f] or f end
   Say("Schriftrolle: ein Platz fuer alle Werte (der Server erlaubt nur eine). Gewaehlt wird: " ..
       table.concat(labels, ", ") .. "  (" .. source .. "; '/at buffs wert <Wert>' stellt ihn fest ein)")
   if C.NoCombatUse() then
      Say("Im Kampf wird nichts benutzt: der Server zaehlt das Automatische Schiessen als Zauber. " ..
          "Die Gegenstaende kommen in den " .. AFTER_WINDOW .. " s nach dem Kampf.")
   end
   local blocked = C.Blocker()
   if blocked then Say("Gerade geht nichts: " .. blocked .. ".") end
   local friendly = C.FriendlyTarget()
   if friendly then Say("Ein Verbuendeter ist ausgewaehlt: Schriftrollen warten.") end

   local stock = C.Scan()
   local auras = C.Auras()
   local ignore = C.IgnoreList()
   local list = {}
   for _, e in pairs(stock) do list[#list + 1] = e end
   table.sort(list, function(a, b)
      local ka, kb = KeyOf(a.d), KeyOf(b.d)
      if ka ~= kb then return ka < kb end
      return Better(a, b)
   end)

   if #list == 0 then
      Say("In den Taschen liegt nichts, was das Addon kennt (Flaeschchen, Kampf- und Waechterelixiere, Schriftrollen).")
   end

   local level = UnitLevel("player")
   for _, e in ipairs(list) do
      local flags = {}
      if SpellActive(e.d[2], auras) then flags[#flags + 1] = "|cff53d17aBuff wirkt|r" end
      if ignore[e.id] then flags[#flags + 1] = "|cffe8c44aignoriert|r" end
      if PeaceOn(S, e.id, now) then flags[#flags + 1] = "|cffe8c44anur nach dem Kampf|r" end
      if (e.d[3] or 0) > (level or 1) then flags[#flags + 1] = "|cffe8654aab Stufe " .. e.d[3] .. "|r" end
      local it = S.item[e.id]
      if it and it.blockedUntil and it.blockedUntil > now then
         flags[#flags + 1] = "|cffe8654agesperrt noch " .. math.ceil(it.blockedUntil - now) .. " s|r"
      end
      Say(string.format("%s x%d  [%s]  %s", e.link, e.count, Describe(e.d), table.concat(flags, ", ")))
   end

   local e, _, why = C.Decide(stock, auras, {
      level = level, wanted = w, ignore = ignore, state = S, now = now, mode = "now",
      stats = stats, friendly = friendly,
   })
   if e then
      Say("Als Naechstes (im Kampf): " .. e.link .. "  [" .. Describe(e.d) .. "]")
   else
      Say("Als Naechstes: nichts.")
      for _, line in ipairs(why or {}) do Say("  - " .. line) end
   end
   if S.last then Say("Zuletzt: " .. S.last) end
   Say("Benutzt in dieser Sitzung: " .. S.total .. "  |  Befehle: /at buffs jetzt | wert <Wert> | ignorieren <Link> | erlauben <Link> | liste")
end

-- Zeit zurueck auf Null: Sperren, Mindestabstaende, ausstehende Benutzung.
function C.Reset()
   local S = C.state
   S.pending, S.nextAt, S.slot, S.item, S.uses, S.warned, S.peace = nil, 0, {}, {}, {}, {}, {}
end

-- '/at buffs ...'
function C.Command(rest)
   rest = AT.trim(rest or "")
   local sub, arg = string.match(rest, "^(%S*)%s*(.-)$")
   sub = string.lower(sub or "")

   if sub == "" or sub == "status" then
      C.Report()

   elseif sub == "jetzt" or sub == "now" then
      if not (AT.GetBool("BotControl") and B.IsRunning()) then
         AT.Warn("Der Selbstmodus laeuft nicht - ohne ihn gibt es niemanden, der den Befehl ausfuehrt (/at botan).")
         return
      end
      local w = C.Wanted()
      if not AnyWanted(w) then
         AT.Warn("Das aktuelle Profil erlaubt keine Verbrauchsgueter (/at profil bearbeiten).")
         return
      end
      local e, why = C.Tick(GetTime(), true)
      if e then
         AT.Print("Versuche: " .. e.link)
      elseif why then
         AT.Print("Nichts getan: " .. why .. ".")
      else
         AT.Print("Nichts zu tun.")
      end

   elseif sub == "ignorieren" or sub == "ignore" then
      local id = ItemId(arg)
      if not id then AT.Warn("Bitte einen Gegenstand angeben: /at buffs ignorieren [Link] (mit Umschalt+Klick einfuegen).") return end
      C.IgnoreList()[id] = true
      AT.Print(arg .. " wird nicht mehr benutzt.")

   elseif sub == "erlauben" or sub == "allow" then
      local id = ItemId(arg)
      if not id then AT.Warn("Bitte einen Gegenstand angeben: /at buffs erlauben [Link].") return end
      C.IgnoreList()[id] = nil
      AT.Print(arg .. " ist wieder erlaubt.")

   elseif sub == "liste" or sub == "list" then
      local n = 0
      for id in pairs(C.IgnoreList()) do
         n = n + 1
         local name = GetItemInfo and GetItemInfo(id) or nil
         Say("Gegenstand " .. id .. (name and (" (" .. name .. ")") or ""))
      end
      AT.Print(n == 0 and "Es ist nichts ausgeschlossen." or (n .. " Gegenstand/Gegenstaende ausgeschlossen."))

   elseif sub == "wert" or sub == "stat" then
      local g = B.Global()
      if arg == "" then
         local stats, source = C.PreferredStats()
         local labels = {}
         for _, f in ipairs(stats) do labels[#labels + 1] = FAMILY_LABEL[f] or f end
         AT.Print("Schriftrollen-Wert: " .. table.concat(labels, ", ") .. " (" .. source .. "). " ..
                  "Aendern: /at buffs wert <staerke | beweglichkeit | intelligenz | ausdauer | willenskraft | schutz | auto>")
      else
         local fam = StatFromText(arg)
         if fam == "auto" then
            g.consStat = nil
            AT.Print("Schriftrollen-Wert: automatisch (nach Klasse und Talentbaum).")
         elseif fam then
            g.consStat = fam
            AT.Print("Schriftrollen-Wert: " .. FAMILY_LABEL[fam] .. " (fest eingestellt).")
         else
            AT.Warn("Unbekannter Wert '" .. arg .. "'. Moeglich: staerke, beweglichkeit, intelligenz, ausdauer, " ..
                    "willenskraft, schutz, auto.")
         end
      end

   elseif sub == "zuruecksetzen" or sub == "reset" then
      C.Reset()
      AT.Print("Sperren und Mindestabstaende der Verbrauchsgueter zurueckgesetzt.")

   else
      AT.Print("Verwendung: /at buffs [jetzt | wert <Wert> | ignorieren <Link> | erlauben <Link> | liste | zuruecksetzen]")
   end
end
