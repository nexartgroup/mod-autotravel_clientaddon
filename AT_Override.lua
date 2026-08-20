-- AT_Override.lua
-- ---------------------------------------------------------------------------
-- Spielervorrang.
--
-- Idee: Sobald du selbst eingreifst, geht der Bot in Pause und macht erst
-- weiter, wenn du eine Weile nichts mehr tust. Damit lassen sich Ausruestung
-- wechseln, ein Zauber wirken oder die Flucht ergreifen, ohne den Bot vorher
-- abzuschalten.
--
-- WAS ERKANNT WIRD -- und was nicht:
--
--   erkannt: eigene Zauber (UNIT_SPELLCAST_SENT feuert nur fuer Aktionen, die
--            der Client selbst ausgeloest hat -- Botzauber laufen ueber den
--            Server und tauchen dort nicht auf)
--            Gegenstaende bewegen, Beute-, Haendler-, Bank-, Post-,
--            Handels-, Quest- und Flugmeisterfenster
--            Tastenbelegung "AutoTravel: Pause" und /at pause
--
--   erkannt: Bewegungstasten (WASD, Leertaste, Drehen) -- siehe unten.
--
-- Angehalten wird standardmaessig nur die FAHRT. Sie ist es, die das Steuern
-- verhindert: solange das Servermodul die Kontrolle haelt, laesst sich weder
-- Ausruestung wechseln noch zaubern. Der Bot stoert dabei nicht und darf
-- weiterlaufen -- er kaempft und heilt ja weiter, waehrend du umziehst.
--
-- Wer auch den Bot stillstellen will, schaltet das in den Einstellungen ein
-- ("Auch den Bot pausieren").
--
-- Nach der Pause berechnet das Servermodul den Weg von der aktuellen Position
-- neu und setzt die Reise fort.
--
-- Waehrend der Pause ruht auch der Erbstueckschutz. Danach wird die
-- Ausruestung neu erfasst -- was du selbst angezogen hast, gilt dann als
-- gewollt und wird nicht zurueckgetauscht.
-- ---------------------------------------------------------------------------

AutoTravel = AutoTravel or {}
local AT = AutoTravel

AT.Override = {}
local O = AT.Override

O.active = false
O.lastActivity = 0
O.reason = nil

local ACTIVITY_EVENTS = {
   "LOOT_OPENED", "MERCHANT_SHOW", "BANKFRAME_OPENED", "MAIL_SHOW",
   "TRADE_SHOW", "QUEST_DETAIL", "QUEST_PROGRESS", "GOSSIP_SHOW",
   "TAXIMAP_OPENED", "AUCTION_HOUSE_SHOW", "ITEM_LOCK_CHANGED",
}

local REASON = {
   LOOT_OPENED        = "Beute",
   MERCHANT_SHOW      = "Haendler",
   BANKFRAME_OPENED   = "Bank",
   MAIL_SHOW          = "Post",
   TRADE_SHOW         = "Handel",
   QUEST_DETAIL       = "Quest",
   QUEST_PROGRESS     = "Quest",
   GOSSIP_SHOW        = "Gespraech",
   TAXIMAP_OPENED     = "Flugmeister",
   AUCTION_HOUSE_SHOW = "Auktionshaus",
   ITEM_LOCK_CHANGED  = "Gegenstand bewegt",
   UNIT_SPELLCAST_SENT = "eigener Zauber",
   MANUAL             = "Taste",
}

-- ---------------------------------------------------------------------------

function O.Enabled()
   return AT.GetBool("PlayerOverride")
end

function O.Note(reason)
   if not O.Enabled() then return end
   O.lastActivity = GetTime()

   if not O.active then
      O.active = true
      O.reason = reason

      local what = "Fahrt"
      -- Die Fahrt ist das Hindernis: sie haelt die Steuerung.
      if AT.active then AT.Send("at pause 1") end

      if AT.GetBool("OverridePausesBot") and AT.Bot then
         AT.Bot.Pause()
         what = "Fahrt und Bot"
      end

      AT.Print("|cffe8c44aSpielervorrang|r (" .. (REASON[reason] or reason or "?") ..
               ") - " .. what .. " pausiert.")
      if AT.UI then AT.UI.Update() end
   end
end

function O.Release(silent)
   if not O.active then return end
   O.active = false
   O.reason = nil
   if not silent then
      AT.Print("Spielervorrang beendet - Weg wird neu berechnet, dann geht es weiter.")
   end
   if AT.active then AT.Send("at pause 0") end   -- Server pathet selbst neu
   if AT.Gear then AT.Gear.Snapshot(true) end    -- eigene Wahl uebernehmen
   if AT.Bot then AT.Bot.Resume() end            -- nur wenn zuvor pausiert
   O.UpdateGrab()
   if AT.UI then AT.UI.Update() end
end

function O.Toggle()
   if O.active then O.Release() else O.Note("MANUAL") end
end

-- ---------------------------------------------------------------------------

local f = CreateFrame("Frame", "AutoTravelOverride")
for _, e in ipairs(ACTIVITY_EVENTS) do f:RegisterEvent(e) end
f:RegisterEvent("UNIT_SPELLCAST_SENT")

f:SetScript("OnEvent", function(self, event, arg1)
   if not O.Enabled() then return end
   if event == "UNIT_SPELLCAST_SENT" and arg1 ~= "player" then return end
   O.Note(event)
end)

local acc = 0
f:SetScript("OnUpdate", function(self, elapsed)
   if not O.active then return end
   acc = acc + elapsed
   if acc < 0.5 then return end
   acc = 0

   -- Offene Fenster halten die Pause aufrecht, solange sie offen sind.
   if (MerchantFrame and MerchantFrame:IsShown())
      or (LootFrame and LootFrame:IsShown())
      or (BankFrame and BankFrame:IsShown())
      or (TradeFrame and TradeFrame:IsShown())
      or (MailFrame and MailFrame:IsShown())
      or (CursorHasItem and CursorHasItem()) then
      O.lastActivity = GetTime()
      return
   end

   local wait = tonumber(AT.Get("OverrideSeconds")) or 8
   if (GetTime() - O.lastActivity) >= wait then
      O.Release()
   end
end)

-- Zustand der Tastenabfangung regelmaessig nachziehen
local grabAcc = 0
keyOwner:SetScript("OnUpdate", function(self, elapsed)
   grabAcc = grabAcc + elapsed
   if grabAcc < 0.5 then return end
   grabAcc = 0
   O.UpdateGrab()
end)

-- ---------------------------------------------------------------------------
-- Bewegungstasten abfangen
-- ---------------------------------------------------------------------------
-- Solange das Servermodul die Steuerung haelt, bewirken WASD und Leertaste
-- ohnehin NICHTS -- der Client blockiert die Bewegung selbst. Genau das laesst
-- sich ausnutzen: fuer die Dauer der Fahrt werden die Bewegungstasten per
-- Ueberschreibung auf den Spielervorrang gelegt.
--
--   Fahrt laeuft  -> W liegt auf "Spielervorrang"   (bewegt sowieso nicht)
--   Taste gedrueckt -> Pause, Steuerung kommt zurueck, Ueberschreibung faellt weg
--   ab jetzt      -> W bewegt wieder ganz normal
--
-- Der erste Tastendruck loest also die Pause aus statt zu laufen, jeder
-- weitere laeuft. Das ist der Preis dafuer, dass 3.3.5a Tastendruecke fuer
-- Bewegung nicht an Addons meldet und die Bewegungsfunktionen geschuetzt sind.

local MOVE_COMMANDS = {
   "MOVEFORWARD", "MOVEBACKWARD", "STRAFELEFT", "STRAFERIGHT",
   "TURNLEFT", "TURNRIGHT", "JUMP", "SITORSTAND",
}

local keyOwner = CreateFrame("Frame", "AutoTravelKeyGrab")
O.armed = false

local function ApplyGrab()
   if O.armed then return end
   if not SetOverrideBinding then return end
   if InCombatLockdown and InCombatLockdown() then return end   -- spaeter erneut

   local n = 0
   for _, cmd in ipairs(MOVE_COMMANDS) do
      local k1, k2 = GetBindingKey(cmd)
      for _, key in ipairs({ k1, k2 }) do
         if key then
            if pcall(SetOverrideBinding, keyOwner, true, key, "AUTOTRAVEL_PAUSE") then
               n = n + 1
            end
         end
      end
   end

   if n > 0 then
      O.armed = true
      AT.Debug("Bewegungstasten abgefangen (" .. n .. ").")
   end
end

local function ReleaseGrab()
   if not O.armed then return end
   O.armed = false
   if ClearOverrideBindings then pcall(ClearOverrideBindings, keyOwner) end
   AT.Debug("Bewegungstasten wieder frei.")
end

O.ApplyGrab = ApplyGrab
O.ReleaseGrab = ReleaseGrab

-- Abfangen nur, wenn die Fahrt laeuft UND der Server die Steuerung haelt.
-- Ohne Kontrolluebernahme wuerden wir echte Bewegung blockieren.
function O.UpdateGrab()
   if not AT.GetBool("GrabMoveKeys") then ReleaseGrab() return end
   if not AT.active or O.active then ReleaseGrab() return end
   if not AT.GetBool("TakeControl") then ReleaseGrab() return end
   local st = AT.status and AT.status.state
   if st == "PAUSED - SPIELER" or st == "IDLE" then ReleaseGrab() return end
   ApplyGrab()
end

function O.StatusText()
   if not O.Enabled() then return "|cff6a7080aus|r" end
   if O.active then
      local rest = math.max(0, (tonumber(AT.Get("OverrideSeconds")) or 8)
                               - (GetTime() - O.lastActivity))
      return string.format("|cffe8c44aaktiv|r |cff8a90a0(%.0fs)|r", rest)
   end
   return "|cff53d17abereit|r"
end
