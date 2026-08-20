-- AT_Input.lua
-- ---------------------------------------------------------------------------
-- Zentrale Quelle fuer die Frage: "Was hat der Mensch gerade getan?"
--
-- Vorher lag diese Logik verstreut in AT_Override. Hier gibt es genau einen
-- Eingang -- AT.Input.Activity(reason) -- und genau eine Stelle, die
-- entscheidet, ob der Mensch noch aktiv ist.
--
-- WICHTIG zur Ehrlichkeit: 3.3.5a meldet Tastendruecke nicht an Addons. Was
-- hier erfasst wird, sind AUSWIRKUNGEN von Eingaben (gewirkter Zauber,
-- bewegter Gegenstand, geoeffnetes Fenster) plus die Tasten, die AutoTravel
-- selbst abfaengt. Ein vollstaendiger Tastaturmitschnitt ist nicht moeglich.
--
-- Unterschiedliche Aktivitaeten haben unterschiedliche Ruhezeiten: nach einem
-- kurzen Tastendruck soll die Reise schneller weitermachen als nach einem
-- Kampfzauber. Offene Fenster halten die Uebernahme auf, solange sie offen
-- sind -- unabhaengig von jeder Uhr.
-- ---------------------------------------------------------------------------

AutoTravel = AutoTravel or {}
local AT = AutoTravel

AT.Input = {}
local I = AT.Input

I.lastActivity = 0
I.lastReason   = nil
I.heldKeys     = {}

-- Ruhezeit je Art der Aktivitaet, in Sekunden. Der Wert aus den Einstellungen
-- gilt als Grundmass; die Faktoren machen kurze Eingaben schneller wieder frei.
local CLASS = {
   MOVE      = 0.6,    -- Bewegungstaste: kurz
   ACTION    = 1.0,    -- Zauber, Faehigkeit
   ITEM      = 1.0,    -- Gegenstand bewegt oder angelegt
   UI        = 1.0,    -- Fenster (zusaetzlich: haelt an, solange offen)
   MANUAL    = 1.0,    -- ausdrueckliche Pause (eigene Behandlung)
}

local REASON_CLASS = {
   KEY_MOVE            = "MOVE",
   UNIT_SPELLCAST_SENT = "ACTION",
   ITEM_LOCK_CHANGED   = "ITEM",
   LOOT_OPENED         = "UI",
   MERCHANT_SHOW       = "UI",
   BANKFRAME_OPENED    = "UI",
   MAIL_SHOW           = "UI",
   TRADE_SHOW          = "UI",
   QUEST_DETAIL        = "UI",
   QUEST_PROGRESS      = "UI",
   GOSSIP_SHOW         = "UI",
   TAXIMAP_OPENED      = "UI",
   AUCTION_HOUSE_SHOW  = "UI",
   MANUAL              = "MANUAL",
}

local REASON_TEXT = {
   KEY_MOVE            = "Bewegungstaste",
   UNIT_SPELLCAST_SENT = "eigener Zauber",
   ITEM_LOCK_CHANGED   = "Gegenstand bewegt",
   LOOT_OPENED         = "Beute",
   MERCHANT_SHOW       = "Haendler",
   BANKFRAME_OPENED    = "Bank",
   MAIL_SHOW           = "Post",
   TRADE_SHOW          = "Handel",
   QUEST_DETAIL        = "Quest",
   QUEST_PROGRESS      = "Quest",
   GOSSIP_SHOW         = "Gespraech",
   TAXIMAP_OPENED      = "Flugmeister",
   AUCTION_HOUSE_SHOW  = "Auktionshaus",
   MANUAL              = "von Hand",
}

function I.ReasonText(r)
   return REASON_TEXT[r] or tostring(r or "?")
end

-- ---------------------------------------------------------------------------

function I.Activity(reason)
   I.lastActivity = GetTime()
   I.lastReason   = reason
   if AT.Human then AT.Human.OnActivity(reason) end
end

-- Wie lange muss nach dieser Aktivitaet Ruhe sein?
function I.QuietTime()
   local base = tonumber(AT.Get("OverrideSeconds")) or 5
   local factor = CLASS[REASON_CLASS[I.lastReason or ""] or "ACTION"] or 1.0
   return base * factor
end

-- Fenster, die eine Uebernahme verhindern, solange sie offen sind.
local BLOCKING = {
   "MerchantFrame", "LootFrame", "BankFrame", "TradeFrame", "MailFrame",
   "GameMenuFrame", "CharacterFrame", "SpellBookFrame", "QuestLogFrame",
   "TaxiFrame", "AuctionFrame", "TradeSkillFrame", "CraftFrame",
   "QuestFrame", "GossipFrame", "PetStableFrame", "TalentFrame",
}

function I.IsUIBlocking()
   for _, name in ipairs(BLOCKING) do
      local f = _G[name]
      if f and f.IsShown and f:IsShown() then return true, name end
   end
   if CursorHasItem and CursorHasItem() then return true, "Mauszeiger" end
   return false
end

function I.IsKeyHeld()
   return next(I.heldKeys) ~= nil
end

function I.KeyDown(key)
   I.heldKeys[key] = true
   I.Activity("KEY_MOVE")
end

function I.KeyUp(key)
   I.heldKeys[key] = nil
   I.Activity("KEY_MOVE")
end

-- Darf die Reise wieder uebernehmen? Alle drei Bedingungen muessen gelten.
function I.MayResume()
   if (GetTime() - I.lastActivity) < I.QuietTime() then return false, "Ruhezeit" end
   local blocked, what = I.IsUIBlocking()
   if blocked then return false, what end
   if I.IsKeyHeld() then return false, "Taste gehalten" end
   return true
end

function I.SecondsLeft()
   return math.max(0, I.QuietTime() - (GetTime() - I.lastActivity))
end

-- ---------------------------------------------------------------------------
-- Ereignisse
-- ---------------------------------------------------------------------------

local EVENTS = {
   "LOOT_OPENED", "MERCHANT_SHOW", "BANKFRAME_OPENED", "MAIL_SHOW",
   "TRADE_SHOW", "QUEST_DETAIL", "QUEST_PROGRESS", "GOSSIP_SHOW",
   "TAXIMAP_OPENED", "AUCTION_HOUSE_SHOW", "ITEM_LOCK_CHANGED",
   "UNIT_SPELLCAST_SENT",
}

local f = CreateFrame("Frame", "AutoTravelInput")
for _, e in ipairs(EVENTS) do f:RegisterEvent(e) end

f:SetScript("OnEvent", function(self, event, arg1)
   if event == "UNIT_SPELLCAST_SENT" and arg1 ~= "player" then return end
   I.Activity(event)
end)
