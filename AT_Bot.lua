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
-- Selbstmodus an / aus
-- ---------------------------------------------------------------------------

B.active = false

function B.Enable()
   if not AT.GetBool("BotControl") then return end
   local cmd = AT.Get("SelfOnCommand")
   if cmd and AT.trim(cmd) ~= "" then
      AT.Send(string.sub(cmd, 1, 1) == "." and string.sub(cmd, 2) or cmd)
   end
   B.active = true
   B.ApplyProfile()
end

function B.Disable()
   if not B.active then return end
   B.active = false
   if not AT.GetBool("BotControl") then return end
   local cmd = AT.Get("SelfOffCommand")
   if cmd and AT.trim(cmd) ~= "" then
      AT.Send(string.sub(cmd, 1, 1) == "." and string.sub(cmd, 2) or cmd)
   end
   AT.Print("Playerbot-Selbstmodus wieder ausgeschaltet.")
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
