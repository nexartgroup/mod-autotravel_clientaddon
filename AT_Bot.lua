-- AT_Bot.lua
-- ---------------------------------------------------------------------------
-- Steuerung des Playerbot-Selbstmodus waehrend einer Reise.
--
-- Aufgabenteilung bleibt strikt:
--   AutoTravel  bewegt den Charakter (Servermodul, NavMesh)
--   Playerbot   kaempft, heilt, lootet
--
-- AutoTravel aendert am Charakter NICHTS ausser Strategien. Es werden
-- ausdruecklich keine Befehle gesendet, die Ausruestung, Talente, Faehigkeiten
-- oder Inventar anfassen: kein "e", "ue", "roll", "s", "b", "talents",
-- "new rpg". Die Strategie "new rpg" wird sogar aktiv abgeschaltet, weil sie
-- Questen und damit Ausruestungswechsel ausloesen kann.
--
-- Befehle an den eigenen Bot gehen als Fluesternachricht an den eigenen Namen,
-- so wie mod-playerbots es fuer Einzelbots vorsieht.
-- ---------------------------------------------------------------------------

AutoTravel = AutoTravel or {}
local AT = AutoTravel

AT.Bot = {}
local B = AT.Bot

-- ---------------------------------------------------------------------------
-- Profile
-- ---------------------------------------------------------------------------
-- combat / noncombat sind die Argumente fuer "co" bzw. "nc".
-- grace = Wartezeit des Servermoduls nach Kampfende, bevor weitergelaufen
-- wird. Beim Loot-Profil laenger, damit der Bot die Leichen noch pluendert.

B.Profiles = {
   {
      key = "minimal", name = "Minimal",
      desc = "Nur laufen. Der Bot greift nicht ein.",
      combat    = "-dps,-aoe,-boost,-grind,-heal,-tank",
      noncombat = "-grind,-new rpg,-loot,-follow,-food",
      extra = nil, loot = false, grace = 1.5,
   },
   {
      key = "aengstlich", name = "Aengstlich",
      desc = "Weicht aus, greift nicht an.",
      combat    = "-dps,-aoe,-boost,-grind,-tank,+threat,+avoid aoe",
      noncombat = "-grind,-new rpg,-loot,-follow,+food",
      extra = nil, loot = false, grace = 1.5,
   },
   {
      key = "verteidigen", name = "Verteidigen",
      desc = "Wehrt sich, sucht aber keinen Kampf.",
      combat    = "+dps,+assist,+avoid aoe,-aoe,-grind,-boost",
      noncombat = "-grind,-new rpg,-loot,-follow,+food",
      extra = nil, loot = false, grace = 2.0,
   },
   {
      key = "normal", name = "Normal",
      desc = "Wehrt sich mit vollem Repertoire.",
      combat    = "+dps,+assist,+aoe,+avoid aoe,+heal,-grind",
      noncombat = "-grind,-new rpg,-loot,-follow,+food",
      extra = nil, loot = false, grace = 2.0,
   },
   {
      key = "aggressiv", name = "Aggressiv",
      desc = "Greift alles an, was in Reichweite kommt.",
      combat    = "+dps,+assist,+aoe,+boost,+grind",
      noncombat = "-new rpg,-loot,-follow,+food",
      extra = nil, loot = false, grace = 2.5,
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

function B.Find(key)
   for _, p in ipairs(B.Profiles) do
      if p.key == key then return p end
   end
   return B.Profiles[4]        -- Normal
end

function B.Current()
   return B.Find(AT.Get("Profile") or "verteidigen")
end

function B.Next()
   local cur = AT.Get("Profile") or "verteidigen"
   for i, p in ipairs(B.Profiles) do
      if p.key == cur then
         local n = B.Profiles[(i % #B.Profiles) + 1]
         AT.Set("Profile", n.key)
         return n
      end
   end
   AT.Set("Profile", B.Profiles[1].key)
   return B.Profiles[1]
end

-- ---------------------------------------------------------------------------
-- Senden
-- ---------------------------------------------------------------------------

local recent = {}          -- zum Ausblenden der eigenen Fluesterechos

function B.Whisper(text)
   if not text or text == "" then return end
   recent[text] = GetTime()
   AT.Queue(function()
      SendChatMessage(text, "WHISPER", nil, UnitName("player"))
      AT.Debug("-> [Fluestern an sich] " .. text)
   end)
end

local function IsOwnCommand(msg)
   if type(msg) ~= "string" then return false end
   local t = recent[msg]
   return t and (GetTime() - t) < 15
end
B.IsOwnCommand = IsOwnCommand

-- ---------------------------------------------------------------------------
-- Zustandserkennung
-- ---------------------------------------------------------------------------
-- Der Server meldet das Umschalten im Chat:
--     Enable player botAI
--     Disable player botAI
-- Das wird mitgelesen, statt den Zustand nur zu vermuten. Damit weiss das
-- Addon, ob der Selbstmodus wirklich laeuft -- auch wenn du ihn von Hand
-- ein- oder ausschaltest.

B.active    = false      -- was wir gesendet haben
B.confirmed = nil        -- was der Server bestaetigt hat (nil = unbekannt)

local ENABLE_PATTERNS  = { "enable player botai", "playerbot ai enabled", "botai aktiviert" }
local DISABLE_PATTERNS = { "disable player botai", "playerbot ai disabled", "botai deaktiviert" }

local function MatchAny(low, list)
   for _, pat in ipairs(list) do
      if string.find(low, pat, 1, true) then return true end
   end
   return false
end

-- Rueckgabe: true, wenn die Zeile eine Zustandsmeldung war
function B.OnSystemMessage(msg)
   if type(msg) ~= "string" then return false end
   local low = string.lower(msg)

   if MatchAny(low, ENABLE_PATTERNS) then
      B.confirmed = true
      B.confirmedAt = GetTime()
      AT.Debug("Selbstmodus vom Server bestaetigt: aktiv")
      if AT.UI then AT.UI.Update() end
      return true
   end

   if MatchAny(low, DISABLE_PATTERNS) then
      B.confirmed = false
      B.confirmedAt = GetTime()
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
   if not AT.GetBool("BotControl") then return "|cff6a7080aus|r" end
   if B.confirmed == true  then return "|cff53d17aaktiv|r" end
   if B.confirmed == false then return "|cff9099a8inaktiv|r" end
   return "|cffe8c44aunbekannt|r"
end

-- ---------------------------------------------------------------------------
-- Selbstmodus an / aus
-- ---------------------------------------------------------------------------

local watchdog = CreateFrame("Frame")
local watchUntil, watchWant = 0, nil

watchdog:SetScript("OnUpdate", function()
   if watchUntil == 0 then return end
   if B.confirmed == watchWant then
      watchUntil = 0
      return
   end
   if GetTime() < watchUntil then return end
   watchUntil = 0
   AT.Warn("Keine Bestaetigung fuer den Selbstmodus. Stimmt der Befehl? Aktuell: "
           .. tostring(AT.Get(watchWant and "SelfOnCommand" or "SelfOffCommand")))
   AT.Warn("Richtige Schreibweise mit '.playerbots help' pruefen, dann /at selfon <befehl>.")
end)

local function SendSelf(cmd, want)
   if not cmd or AT.trim(cmd) == "" then return end
   AT.Send(string.sub(cmd, 1, 1) == "." and string.sub(cmd, 2) or cmd)
   watchWant = want
   watchUntil = GetTime() + 6
end

function B.Enable()
   if not AT.GetBool("BotControl") then return end

   if B.confirmed == true then
      AT.Debug("Selbstmodus laeuft bereits - nur Profil setzen.")
      B.active = true
      B.ApplyProfile()
      return
   end

   SendSelf(AT.Get("SelfOnCommand"), true)
   B.active = true
   B.ApplyProfile()
end

function B.Disable()
   if not AT.GetBool("BotControl") then return end
   if not B.active and B.confirmed ~= true then return end

   B.active = false
   if B.confirmed == false then
      AT.Debug("Selbstmodus ist bereits aus.")
      return
   end

   SendSelf(AT.Get("SelfOffCommand"), false)
   AT.Print("Playerbot-Selbstmodus wird ausgeschaltet.")
end

function B.ApplyProfile()
   if not AT.GetBool("BotControl") then return end
   local p = B.Current()

   -- Erst auf einen bekannten Stand zuruecksetzen, dann das Profil setzen.
   B.Whisper("co !")
   B.Whisper("nc !")
   if p.combat    then B.Whisper("co " .. p.combat) end
   if p.noncombat then B.Whisper("nc " .. p.noncombat) end
   if p.extra then
      for _, e in ipairs(p.extra) do B.Whisper(e) end
   end

   -- Wartezeit nach dem Kampf ans Servermodul melden, damit beim Loot-Profil
   -- Zeit zum Pluendern bleibt, bevor weitergelaufen wird.
   AT.Send(string.format("at set grace %.1f", p.grace or 2.0))

   AT.Print("Profil: |cffffffff" .. p.name .. "|r - " .. p.desc)
end

function B.PrintProfiles()
   AT.Print("Verfuegbare Profile:")
   local cur = AT.Get("Profile")
   for _, p in ipairs(B.Profiles) do
      DEFAULT_CHAT_FRAME:AddMessage(string.format("   %s%-12s|r %s",
         (p.key == cur) and "|cff33ff66" or "|cffaaaaaa", p.name, p.desc))
   end
end
