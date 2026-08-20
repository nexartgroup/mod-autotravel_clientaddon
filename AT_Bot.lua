-- AT_Bot.lua
-- ---------------------------------------------------------------------------
-- Steuerung des Playerbot-Selbstmodus.
--
-- Aufgabenteilung bleibt strikt:
--   AutoTravel  bewegt den Charakter (Servermodul, NavMesh)
--   Playerbot   kaempft, heilt, lootet
--
-- Gesendet werden ausschliesslich Strategiebefehle (co / nc / ll). Nie "e",
-- "ue", "roll", "s", "b", "talents", "destroy". Die Strategie "new rpg" wird
-- in den festen Profilen aktiv abgeschaltet, weil sie Questen ausloest und
-- darueber Ausruestung wechseln kann.
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
   { "dps",             "Schadenszauber und -faehigkeiten benutzen" },
   { "assist",          "ein Ziel nach dem anderen" },
   { "aoe",             "mehrere Ziele gleichzeitig" },
   { "tank",            "Bedrohung aufbauen" },
   { "tank assist",     "Gegner von anderen wegziehen" },
   { "heal",            "Gruppe heilen" },
   { "healer dps",      "Heiler zaubern Schaden bei genug Mana" },
   { "save mana",       "Heiler sparen Mana unter einem Schwellwert" },
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
   { "wait for attack", "vor dem Angriff warten (Zeit: 'wait for attack time 5')" },
}

B.NonCombatFlags = {
   { "loot",            "Beute aufnehmen" },
   { "food",            "essen und trinken" },
   { "follow",          "dem Meister folgen" },
   { "grind",           "selbst Ziele suchen" },
   { "new rpg",         "questen (aendert Ausruestung!)" },
   { "pvp",             "PvP-Modus" },
}

-- ---------------------------------------------------------------------------
-- Feste Profile
-- ---------------------------------------------------------------------------

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
      combat    = "+dps,+assist,+avoid aoe,-aoe,-grind,-boost",
      noncombat = "-grind,-new rpg,-loot,-follow,+food",
      grace = 2.0,
   },
   {
      key = "normal", name = "Normal",
      desc = "Wehrt sich mit vollem Repertoire.",
      combat    = "+dps,+assist,+aoe,+avoid aoe,+heal,-grind",
      noncombat = "-grind,-new rpg,-loot,-follow,+food",
      grace = 2.0,
   },
   {
      key = "aggressiv", name = "Aggressiv",
      desc = "Greift alles an und pluendert die Beute.",
      combat    = "+dps,+assist,+aoe,+boost,+grind",
      noncombat = "+loot,-new rpg,-follow,+food",
      extra = { "ll normal" },
      loot = true, grace = 7.0,
   },
   {
      key = "plus", name = "Plus",
      desc = "Wehrt sich, pluendert Gegner, sammelt Beruferessourcen.",
      combat    = "+dps,+assist,+aoe,+avoid aoe,+heal,-grind",
      noncombat = "+loot,-grind,-new rpg,-follow,+food",
      extra = { "ll normal", "ll skill" },
      loot = true, grace = 7.0,
   },
}

B.CUSTOM_COUNT = 3

-- ---------------------------------------------------------------------------
-- Eigene Profile (kontoweit gespeichert)
-- ---------------------------------------------------------------------------

function B.Global()
   AutoTravelGlobalDB = AutoTravelGlobalDB or {}
   AutoTravelGlobalDB.custom = AutoTravelGlobalDB.custom or {}
   return AutoTravelGlobalDB
end

function B.CustomSlot(i)
   local g = B.Global()
   g.custom[i] = g.custom[i] or {
      name = "Eigenes " .. i,
      combat = {},        -- ["dps"] = true
      noncombat = {},
      extra = "",
      grace = 2.0,
   }
   return g.custom[i]
end

function B.CustomUsed(i)
   local c = B.Global().custom[i]
   if not c then return false end
   for _ in pairs(c.combat or {}) do return true end
   for _ in pairs(c.noncombat or {}) do return true end
   return (c.extra or "") ~= ""
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
   }
end

-- Vollstaendige Liste: feste Profile plus benutzte eigene
function B.List()
   local out = {}
   for _, p in ipairs(B.Builtin) do table.insert(out, p) end
   for i = 1, B.CUSTOM_COUNT do
      if B.CustomUsed(i) then table.insert(out, CustomProfile(i)) end
   end
   return out
end
B.Profiles = setmetatable({}, { __index = function(_, k) return B.List()[k] end,
                                __len = function() return #B.List() end })

function B.Find(key)
   for _, p in ipairs(B.List()) do
      if p.key == key then return p end
   end
   return B.Builtin[3]        -- Verteidigen
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

function B.Whisper(text)
   if not text or text == "" then return end
   recent[text] = GetTime()
   AT.Queue(function()
      SendChatMessage(text, "WHISPER", nil, UnitName("player"))
      AT.Debug("-> [Fluestern an sich] " .. text)
   end)
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

local ENABLE_PATTERNS  = { "enable player botai", "playerbot ai enabled", "botai aktiviert" }
local DISABLE_PATTERNS = { "disable player botai", "playerbot ai disabled", "botai deaktiviert" }

local function MatchAny(low, list)
   for _, pat in ipairs(list) do
      if string.find(low, pat, 1, true) then return true end
   end
   return false
end

function B.OnSystemMessage(msg)
   if type(msg) ~= "string" then return false end
   local low = string.lower(msg)

   if MatchAny(low, ENABLE_PATTERNS) then
      B.confirmed = true
      B.active = true
      AT.Debug("Selbstmodus vom Server bestaetigt: aktiv")
      if AT.UI then AT.UI.Update() end
      return true
   end
   if MatchAny(low, DISABLE_PATTERNS) then
      B.confirmed = false
      B.active = false
      AT.Debug("Selbstmodus vom Server bestaetigt: aus")
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
   if B.confirmed == true  then return "|cff53d17aaktiv|r" end
   if B.confirmed == false then return "|cff9099a8aus|r" end
   return "|cffe8c44a?|r"
end

-- ---------------------------------------------------------------------------
-- Profil anwenden
-- ---------------------------------------------------------------------------

function B.ApplyProfile()
   if not AT.GetBool("BotControl") then return end
   local p = B.Current()

   B.Whisper("co !")
   B.Whisper("nc !")

   if p.customIndex then
      local c = B.CustomSlot(p.customIndex)

      local cparts = {}
      for _, f in ipairs(B.CombatFlags) do
         table.insert(cparts, (c.combat[f[1]] and "+" or "-") .. f[1])
      end
      SendFlagList("co", cparts)

      local nparts = {}
      for _, f in ipairs(B.NonCombatFlags) do
         table.insert(nparts, (c.noncombat[f[1]] and "+" or "-") .. f[1])
      end
      SendFlagList("nc", nparts)

      if c.extra and c.extra ~= "" then
         for line in string.gmatch(c.extra, "[^;\n]+") do
            line = AT.trim(line)
            if line ~= "" then B.Whisper(line) end
         end
      end
   else
      if p.combat    then B.Whisper("co " .. p.combat) end
      if p.noncombat then B.Whisper("nc " .. p.noncombat) end
      if p.extra then
         for _, e in ipairs(p.extra) do B.Whisper(e) end
      end
   end

   AT.Send(string.format("at set grace %.1f", p.grace or 2.0))
   AT.Print("Profil: |cffffffff" .. p.name .. "|r - " .. p.desc)
end

-- ---------------------------------------------------------------------------
-- Selbstmodus an / aus
-- ---------------------------------------------------------------------------

local watchdog = CreateFrame("Frame")
local watchUntil, watchWant = 0, nil

watchdog:SetScript("OnUpdate", function()
   if watchUntil == 0 then return end
   if B.confirmed == watchWant then watchUntil = 0 return end
   if GetTime() < watchUntil then return end
   watchUntil = 0
   AT.Warn("Keine Bestaetigung fuer den Selbstmodus. Verwendeter Befehl: "
           .. tostring(AT.Get(watchWant and "SelfOnCommand" or "SelfOffCommand")))
   AT.Warn("Schreibweise mit '.playerbots help' pruefen, dann /at selfon <befehl>.")
end)

local function SendSelf(cmd, want)
   if not cmd or AT.trim(cmd) == "" then return end
   AT.Send(string.sub(cmd, 1, 1) == "." and string.sub(cmd, 2) or cmd)
   watchWant = want
   watchUntil = GetTime() + 6
end

function B.Enable(silent)
   B.pauseReason = nil
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
   B.pauseReason = "USER"          -- vom Menschen abgeschaltet
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

-- ---------------------------------------------------------------------------
-- Pause fuer den Spielervorrang
-- ---------------------------------------------------------------------------
-- Pausieren heisst hier: den Selbstmodus wirklich ausschalten. Nur die
-- Strategien abzuwaehlen wuerde den Bot weiterlaufen lassen, und er koennte
-- dem Spieler weiterhin ins Handwerk pfuschen.

-- Wer den Bot abgeschaltet hat, entscheidet, wer ihn wieder einschalten darf.
-- Vorher war das ein einzelnes Boolean: hatte der Spieler den Bot von Hand
-- ausgeschaltet und danach eine Uebernahme stattgefunden, konnte das
-- Fortsetzen ihn ungefragt wieder anschalten.
B.pauseReason = nil        -- nil | "HUMAN_OVERRIDE" | "USER" | "ERROR"

function B.Pause(reason)
   if not AT.GetBool("BotControl") then return end
   if not B.IsRunning() then return end
   B.pauseReason = reason or "HUMAN_OVERRIDE"
   SendSelf(AT.Get("SelfOffCommand"), false)
   B.active = false
   AT.Debug("Bot pausiert (" .. B.pauseReason .. ").")
end

-- Fortsetzen darf nur, wer auch pausiert hat.
function B.Resume(reason)
   if not B.pauseReason then return end
   if reason and B.pauseReason ~= reason then
      AT.Debug("Bot bleibt aus: pausiert durch " .. B.pauseReason ..
               ", Anfrage von " .. tostring(reason) .. ".")
      return
   end
   B.pauseReason = nil
   if not AT.GetBool("BotControl") then return end
   AT.Debug("Bot wird fortgesetzt.")
   B.Enable(true)
end

function B.PrintProfiles()
   AT.Print("Verfuegbare Profile:")
   local cur = AT.Get("Profile")
   for _, p in ipairs(B.List()) do
      DEFAULT_CHAT_FRAME:AddMessage(string.format("   %s%-14s|r %s",
         (p.key == cur) and "|cff53d17a" or "|cffaaaaaa", p.name, p.desc))
   end
end
