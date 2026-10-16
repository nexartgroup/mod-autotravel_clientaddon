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
-- Plaetze, die der SERVER vorgibt (spell_group 1 und 2 der Datenbank):
--   Kampfelixier   (battle)    je Charakter wirkt eines
--   Waechterelixier (guardian)  ebenso
--   Flaeschchen     (flask)     belegt BEIDE Plaetze und ersetzt Elixiere
-- Daraus folgt: ein Flaeschchen wird nur benutzt, wenn keiner der beiden Plaetze belegt ist, und ein
-- Elixier nur, wenn sein Platz frei ist. Sonst ersetzte das Addon einen Buff durch den anderen,
-- fand den ersten wieder fehlend und benutzte ihn erneut -- und verbrauchte den ganzen Vorrat.
--
-- Schriftrollen: je Wert (Staerke ...) wirkt die hoechste Stufe; gewaehlt wird die hoechste,
-- die der Charakter tragen darf. Ist irgendeine Stufe desselben Werts aktiv, ist er erledigt.
--
-- Geht ein Gegenstand im Kampf nicht (der Server weist ihn fuenfmal ab -- ob ein Elixier im Kampf
-- erlaubt ist, haengt vom Zauber ab und laesst sich vom Client aus nicht lesen), merkt sich das Addon
-- das fuer diese Sitzung und benutzt ihn stattdessen in den 25 s NACH dem Kampf.
--
-- Sicherungen gegen Verschwendung (das sind Gegenstaende, die der Spieler gesammelt hat):
--
--   * Mindestabstand je Platz nach einer Benutzung: 45 s, wenn der Buff danach zu sehen war;
--     10 min, wenn nicht (dann ist die Erkennung unsicher, und es wird gewarnt).
--   * hoechstens 10 Benutzungen in 2 Minuten, in der Summe aller Gegenstaende.
--   * je Gegenstand mehrere Versuche, dann eine Sperre von 90 s.
--   * 3,5 s zwischen zwei Benutzungen (Abklingzeit der Kategorie: 3 s).
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
local USE_GAP             = 3.5     -- zwischen zwei Benutzungen, vom Senden an gerechnet
local VERIFY_AFTER        = 1.2     -- fruehestens so lange nach dem Senden wird das Ergebnis gelesen
local VERIFY_UNTIL        = 3.5     -- spaetestens so lange wird abgewartet
local QUEUE_TIMEOUT       = 20      -- ein Befehl, der so lange in der Warteschlange haengt, gilt als verloren
local MAX_TRIES           = 5       -- Versuche je Gegenstand, dann Sperre
local BLOCK_SECONDS       = 90
local GAP_VERIFIED        = 45      -- Mindestabstand je Platz, Buff nach der Benutzung gesehen
local GAP_UNVERIFIED      = 600     -- ... nicht gesehen
local RATE_WINDOW         = 120
local RATE_MAX            = 10
local AFTER_WINDOW        = 25      -- so lange nach dem Kampf werden Gegenstaende nachgeholt, die im Kampf nicht gingen

C.TICK, C.USE_GAP = TICK, USE_GAP

-- Anzeige
local KIND_LABEL = {
   flask = "Flaeschchen", battle = "Kampfelixier", guardian = "Waechterelixier",
}
local FAMILY_LABEL = {
   strength = "Staerke", agility = "Beweglichkeit", intellect = "Intelligenz",
   stamina = "Ausdauer", spirit = "Willenskraft", protection = "Schutz", fortitude = "Seelenstaerke",
}
-- Reihenfolge, in der Schriftrollen geprueft werden (festgelegt: die Auswahl ist wiederholbar)
local FAMILY_ORDER = { "strength", "agility", "intellect", "stamina", "spirit", "protection", "fortitude" }

-- Zustand
C.state = {
   pending = nil,       -- { id, key, link, queuedAt, sentAt, countBefore, mode }
   nextAt = 0,          -- fruehester Zeitpunkt der naechsten Benutzung
   slot = {},           -- key -> { lastUse, verified }
   item = {},           -- id -> { tries, blockedUntil }
   peace = {},          -- id -> true: im Kampf nicht benutzbar, wird nach dem Kampf versucht
   combatEndedAt = nil, -- Ende des letzten Kampfes
   uses = {},           -- Zeitpunkte gelungener Benutzungen (fuer die Obergrenze)
   warned = {},         -- id -> true: "Buff nicht gesehen" nur einmal melden
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
   index = { battle = {}, guardian = {}, flask = {}, family = {} }
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
      end
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

-- Platz eines Gegenstands: "flask", "battle", "guardian" oder "scroll:<Wert>"
local function KeyOf(d)
   if d[1] == "scroll" then return "scroll:" .. tostring(d[5]) end
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
      local peace = st.peace and st.peace[e.id]
      if mode == "combat" and peace then return false end        -- im Kampf ging es nicht
      if mode == "after" and not peace then return false end     -- nach dem Kampf nur das Nachzuholende
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
      elseif not gapOk("flask") then
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
      for _, fam in ipairs(FAMILY_ORDER) do
         local key = "scroll:" .. fam
         local label = "Schriftrolle " .. FAMILY_LABEL[fam]
         if AnyActive(idx.family[fam], auras) then
            why[#why + 1] = label .. ": wirkt"
         elseif not gapOk(key) then
            why[#why + 1] = label .. ": Mindestabstand nach der letzten Benutzung"
         else
            local e = best(function(x) return x.d[1] == "scroll" and x.d[5] == fam end)
            if e then return e, key, why end
            -- Keine Schriftrolle dieses Werts: das ist der Normalfall, keine Meldung.
         end
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
   S.nextAt = math.max(now, (p.sentAt or now) + USE_GAP)
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

local function OnFailure(p, now)
   local S = C.state
   local it = S.item[p.id] or { tries = 0 }
   S.item[p.id] = it
   it.tries = (it.tries or 0) + 1
   S.nextAt = math.max(now, (p.sentAt or now) + USE_GAP)

   if it.tries >= MAX_TRIES then
      it.tries = 0
      if p.mode == "combat" then
         -- Im Kampf geht es nicht: nach dem Kampf noch einmal, ohne den Gegenstand zu sperren.
         S.peace[p.id] = true
         AT.Warn((p.link or "Der Gegenstand") .. " liess sich im Kampf nicht benutzen (" .. MAX_TRIES ..
                 " Versuche). Das Addon versucht es in dieser Sitzung nach dem Kampf.")
         NoteLast("nur noch nach dem Kampf: " .. (p.link or "?"))
      else
         it.blockedUntil = now + BLOCK_SECONDS
         AT.Warn((p.link or "Der Gegenstand") .. " liess sich nicht benutzen (" .. MAX_TRIES ..
                 " Versuche). Pause: " .. BLOCK_SECONDS .. " s. Der Server benutzt nichts, solange der " ..
                 "Charakter zaubert; Stufe, Abklingzeit oder ein staerkerer Buff koennen ebenfalls im Weg sein.")
         NoteLast("gesperrt " .. (p.link or "?"))
      end
   else
      NoteLast("kein Erfolg bei " .. (p.link or "?") .. " (Versuch " .. it.tries .. " von " .. MAX_TRIES .. ")")
   end
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
      OnFailure(p, now)
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

-- Voraussetzungen, unabhaengig vom Kampf
local function CanAct()
   if not B or not AT.GetBool("BotControl") or not B.IsRunning() then return false end
   if UnitIsDeadOrGhost("player") then return false end
   if UnitOnTaxi and UnitOnTaxi("player") then return false end
   if IsMounted and IsMounted() then return false end
   if UnitHasVehicleUI and UnitHasVehicleUI("player") then return false end
   return true
end

-- Ein Schritt: wertet die letzte Benutzung aus und beginnt, falls noetig, die naechste.
-- 'force': auch ausserhalb des Kampfes ("/at buffs jetzt"). Rueckgabe: der Gegenstand, den dieser
-- Schritt anstiess, oder nil.
function C.Tick(now, force)
   local S = C.state

   -- Das Ergebnis der letzten Benutzung wird immer ausgewertet, auch nach dem Kampf.
   if S.pending then
      if not (B and AT.GetBool("BotControl") and B.IsRunning()) then
         S.pending = nil
      elseif not Settle(now) then
         return nil
      end
   end

   -- Im Kampf; danach noch kurz fuer das, was im Kampf nicht ging; "jetzt" erlaubt alles.
   local mode
   if force then
      mode = "now"
   elseif UnitAffectingCombat("player") then
      mode = "combat"
   elseif S.combatEndedAt and (now - S.combatEndedAt) <= AFTER_WINDOW and next(S.peace) ~= nil then
      mode = "after"
   else
      return nil
   end
   if not CanAct() then return nil end
   if now < S.nextAt then return nil end

   local wanted = C.Wanted()
   if not AnyWanted(wanted) then return nil end

   -- Wer zaubert, kann nichts benutzen: der Server weist den Befehl ab.
   if (UnitCastingInfo and UnitCastingInfo("player")) or (UnitChannelInfo and UnitChannelInfo("player")) then
      return nil
   end

   if RecentUses(now) >= RATE_MAX then
      NoteLast("Obergrenze erreicht (" .. RATE_MAX .. " Benutzungen in " .. RATE_WINDOW .. " s)")
      return nil
   end

   local e, key = C.Decide(C.Scan(), C.Auras(), {
      level = UnitLevel("player"), wanted = wanted, ignore = C.IgnoreList(), state = S, now = now, mode = mode,
   })
   if not e then return nil end

   local p = { id = e.id, key = key, link = e.link, queuedAt = now, countBefore = e.count, mode = mode }
   S.pending = p
   S.nextAt = now + USE_GAP        -- bis das Ergebnis da ist, wird nichts weiter gesendet
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
      if S.peace[e.id] then flags[#flags + 1] = "|cffe8c44anur nach dem Kampf|r" end
      if (e.d[3] or 0) > (level or 1) then flags[#flags + 1] = "|cffe8654aab Stufe " .. e.d[3] .. "|r" end
      local it = S.item[e.id]
      if it and it.blockedUntil and it.blockedUntil > now then
         flags[#flags + 1] = "|cffe8654agesperrt noch " .. math.ceil(it.blockedUntil - now) .. " s|r"
      end
      Say(string.format("%s x%d  [%s]  %s", e.link, e.count, Describe(e.d), table.concat(flags, ", ")))
   end

   local e, _, why = C.Decide(stock, auras, {
      level = level, wanted = w, ignore = ignore, state = S, now = now, mode = "now",
   })
   if e then
      Say("Als Naechstes (im Kampf): " .. e.link .. "  [" .. Describe(e.d) .. "]")
   else
      Say("Als Naechstes: nichts.")
      for _, line in ipairs(why or {}) do Say("  - " .. line) end
   end
   if S.last then Say("Zuletzt: " .. S.last) end
   Say("Benutzt in dieser Sitzung: " .. S.total .. "  |  Befehle: /at buffs jetzt | ignorieren <Link> | erlauben <Link> | liste")
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
      local e = C.Tick(GetTime(), true)
      if e then AT.Print("Versuche: " .. e.link) else AT.Print("Nichts zu tun.") end

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

   elseif sub == "zuruecksetzen" or sub == "reset" then
      C.Reset()
      AT.Print("Sperren und Mindestabstaende der Verbrauchsgueter zurueckgesetzt.")

   else
      AT.Print("Verwendung: /at buffs [jetzt | ignorieren <Link> | erlauben <Link> | liste | zuruecksetzen]")
   end
end
