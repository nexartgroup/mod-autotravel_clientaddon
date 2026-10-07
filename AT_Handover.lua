-- AT_Handover.lua
-- ---------------------------------------------------------------------------
-- Uebergabe zwischen Autopilot und Spieler -- die Clientseite.
--
-- Das Servermodul haelt die Clientkontrolle nur, solange es faehrt. Es gibt sie
-- sofort zurueck bei Kampf, Tod, Kartenwechsel, Taxiflug oder wenn der Spieler
-- auf den Pausenknopf drueckt (".at pause"). Zurueck uebernimmt es NUR auf
-- Ansage (".at resume"): nach einem Kampf wartet es auf die Ruhemeldung dieses
-- Addons, statt dem Spieler die Steuerung mitten im Pluendern wieder
-- wegzunehmen.
--
-- Diese Datei liefert die beiden Haelften:
--
--   Uebernehmen   ein Knopf, eine Taste, ein Mittelklick auf den Minimap-Knopf
--   Zurueckgeben  beobachtend: ist der Spieler eine Weile ruhig, laeuft ein
--                 sichtbarer Countdown, den jede Eingabe abbricht
--
-- Warum kein Haken auf WASD
--
--   3.3.5a meldet Tastendruecke nicht an Addons. SetPropagateKeyboardInput gibt
--   es erst ab Cataclysm: ein Frame mit EnableKeyboard(true) schluckt jede
--   Taste. SetOverrideBindingClick leitet eine Taste auf einen Addonknopf um --
--   dann bewegt sie nicht mehr. Und MoveForwardStart() ist protected.
--   Also: uebernommen wird per Knopf, zurueckgegeben wird beobachtend. Das
--   kostet keinen einzigen Tastendruck.
--
-- Beobachtet werden die AUSWIRKUNGEN von Eingaben: Bewegung, Fallen, Mausblick,
-- Maustasten, Mausbewegung, Zaubern, Kampf, ein offenes Fenster, ein offener
-- Chat, ein Gegenstand am Mauszeiger.
-- ---------------------------------------------------------------------------

AutoTravel = AutoTravel or {}
local AT = AutoTravel

AT.Handover = {}
local H = AT.Handover

H.countdown = nil        -- verbleibende Sekunden bis zur Uebernahme, nil = keiner
H.reason    = nil        -- Anlass der letzten Aktivitaet (fuer die Anzeige)

local lastActive   = 0
local lastCursorX, lastCursorY = nil, nil
local manualPending = false   -- Pause angefordert, Server hat noch nicht geantwortet
local manualPendingAt = 0
local lastResumeAt = -1000    -- Zeitpunkt des letzten ".at resume"

-- Mindestabstand zwischen zwei Rueckgaben. Mit kleiner Ruhezeit und ohne
-- Countdown wuerde sonst alle zwei Sekunden ein ".at resume" hinausgehen, wenn der
-- Server nie antwortet.
local MIN_RESUME_GAP = 6

-- Zustaende des Servers, in denen ein Uebernehmen sinnvoll ist. In allen
-- anderen (Flug, Transport, Warten auf Portal) steuert ohnehin niemand.
local PAUSABLE = { REPATHING = true, TRAVELING = true, MOUNTING = true, TAKEOFF = true }

-- ---------------------------------------------------------------------------
-- Abfragen fuer die Oberflaeche
-- ---------------------------------------------------------------------------

function H.CanPause()
   return AT.active and PAUSABLE[AT.status.state] == true and AT.Net.Can("HANDOVER")
end

function H.CanResume()
   return AT.active and AT.status.state == "PLAYER" and AT.Net.Can("HANDOVER")
end

-- Hat der Spieler ausdruecklich pausiert? Dann endet es nur durch Knopfdruck.
function H.IsManual()
   if manualPending then return true end
   return AT.status.state == "PLAYER" and AT.status.paused == true
end

-- ---------------------------------------------------------------------------
-- Befehle
-- ---------------------------------------------------------------------------

function H.Pause()
   if not H.CanPause() then return false end
   manualPending = true
   manualPendingAt = GetTime()
   H.countdown = nil
   AT.Net.SendNow("at pause", "pause")
   if AT.UI then AT.UI.Update() end
   return true
end

function H.Resume()
   if not H.CanResume() then return false end
   manualPending = false
   H.countdown = nil
   lastActive = GetTime()
   lastResumeAt = lastActive
   AT.Net.SendNow("at resume", "resume")
   return true
end

-- Taste und Knopf: je nach Lage uebernehmen oder zurueckgeben.
function H.Toggle()
   if not AT.active then
      AT.Print("Keine Reise aktiv.")
   elseif AT.status.state == "COMBAT" then
      AT.Print("Im Kampf hast du ohnehin die Kontrolle. Danach geht es von selbst weiter.")
   elseif H.CanResume() then
      H.Resume()
   elseif H.CanPause() then
      H.Pause()
   else
      AT.Print("Gerade nicht moeglich (" .. tostring(AT.status.state) .. ").")
   end
end

-- Vom Netzwerkteil bei jeder Statusmeldung des Servers gerufen.
function H.OnStatus(old, new)
   if new ~= "PLAYER" then
      manualPending = false
      H.countdown = nil
   elseif manualPending and AT.status.paused then
      manualPending = false              -- Server hat die Pause bestaetigt
   end

   -- Eintritt in die Uebergabe: die Ruhezeit beginnt jetzt, nicht erst mit der
   -- naechsten Eingabe.
   if new == "PLAYER" and old ~= "PLAYER" then
      lastActive = GetTime()
   end
end

-- ---------------------------------------------------------------------------
-- Beobachtung
-- ---------------------------------------------------------------------------

-- Fenster, die eine Uebernahme verhindern, solange sie offen sind. Einige
-- (AuctionFrame, PlayerTalentFrame ...) sind nachladbar und fehlen als Global,
-- bis sie zum ersten Mal geoeffnet wurden.
local BLOCKING = {
   "LootFrame", "MerchantFrame", "QuestFrame", "GossipFrame", "TaxiFrame",
   "BankFrame", "MailFrame", "SendMailFrame", "TradeFrame", "AuctionFrame",
   "TradeSkillFrame", "CraftFrame", "ClassTrainerFrame", "PetStableFrame",
   "CharacterFrame", "SpellBookFrame", "PlayerTalentFrame", "QuestLogFrame",
   "WorldMapFrame", "GameMenuFrame", "InterfaceOptionsFrame", "GuildBankFrame",
   "FriendsFrame", "LFDParentFrame", "AchievementFrame", "PVPParentFrame",
   "CinematicFrame", "MovieFrame",
   "StaticPopup1", "StaticPopup2", "StaticPopup3", "StaticPopup4",
}

local MOUSE_BUTTONS = { "LeftButton", "RightButton", "MiddleButton" }

local function FrameShown(name)
   local f = _G[name]
   return f and f.IsShown and f:IsShown()
end

-- Rueckgabe: aktiv (bool), Anlass (Text)
local function Activity()
   -- Den Mauszeiger IMMER abtasten, auch wenn unten vorher etwas anschlaegt:
   -- sonst wuerde die naechste Abtastung gegen einen alten Stand rechnen und
   -- eine Mausbewegung melden, die es nie gab.
   local cursorMoved = false
   if GetCursorPosition then
      local x, y = GetCursorPosition()
      -- Erst nach einem merklichen Stueck, damit ein zitternder Zeiger nicht
      -- dauernd abbricht.
      if lastCursorX and (math.abs(x - lastCursorX) + math.abs(y - lastCursorY)) > 4 then
         cursorMoved = true
      end
      lastCursorX, lastCursorY = x, y
   end

   if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return true, "tot" end
   if UnitAffectingCombat and UnitAffectingCombat("player") then return true, "Kampf" end

   if GetUnitSpeed and (GetUnitSpeed("player") or 0) > 0 then return true, "Bewegung" end
   if IsFalling and IsFalling() then return true, "Fallen" end

   if IsMouselooking and IsMouselooking() then return true, "Mausblick" end
   if IsMouseButtonDown then
      for i = 1, #MOUSE_BUTTONS do
         if IsMouseButtonDown(MOUSE_BUTTONS[i]) then return true, "Maustaste" end
      end
   end
   if (IsShiftKeyDown and IsShiftKeyDown()) or (IsControlKeyDown and IsControlKeyDown())
      or (IsAltKeyDown and IsAltKeyDown()) then
      return true, "Taste"
   end

   if UnitCastingInfo and UnitCastingInfo("player") then return true, "Zaubern" end
   if UnitChannelInfo and UnitChannelInfo("player") then return true, "Zaubern" end

   -- Fahrzeug und Flug: dort steuert der Spieler (oder niemand) auf andere Weise,
   -- und Bewegung laesst sich nicht an der eigenen Geschwindigkeit ablesen.
   if UnitHasVehicleUI and UnitHasVehicleUI("player") then return true, "Fahrzeug" end
   if UnitOnTaxi and UnitOnTaxi("player") then return true, "Flug" end

   -- Offener Chat: der Spieler tippt gerade.
   if ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then return true, "Chat" end

   for i = 1, #BLOCKING do
      if FrameShown(BLOCKING[i]) then return true, "Fenster" end
   end
   if (CursorHasItem and CursorHasItem()) or (CursorHasSpell and CursorHasSpell()) then
      return true, "Mauszeiger"
   end

   if cursorMoved then return true, "Maus" end

   return false
end
H.Activity = Activity     -- fuer Tests

-- Soll die Ruhe-Erkennung gerade laufen?
local function WantsCheck()
   if not AT.active or AT.status.state ~= "PLAYER" then return false end
   if not AT.GetBool("AutoResume") then return false end
   if H.IsManual() then return false end
   if not AT.Net.IsReady() then return false end
   return true
end

local function CheckIdle(now)
   local active, why = Activity()

   if active then
      lastActive = now
      H.reason = why
      if H.countdown then
         H.countdown = nil
         if AT.UI then AT.UI.Update() end
      end
      return
   end

   H.reason = nil
   local quiet = tonumber(AT.Get("QuietSeconds")) or 8
   local count = tonumber(AT.Get("CountdownSeconds")) or 3
   local idleFor = now - lastActive

   if idleFor < quiet then
      if H.countdown then H.countdown = nil if AT.UI then AT.UI.Update() end end
      return
   end

   local remaining = quiet + count - idleFor
   if count <= 0 or remaining <= 0 then
      H.countdown = nil
      if (now - lastResumeAt) >= MIN_RESUME_GAP then
         H.Resume()              -- setzt lastActive neu: der naechste Versuch braucht wieder Ruhe
      end
      return
   end

   H.countdown = remaining
   if AT.UI then AT.UI.Update() end
end

local frame = CreateFrame("Frame", "AutoTravelHandover")
local acc = 0
frame:SetScript("OnUpdate", function(self, elapsed)
   acc = acc + elapsed
   if acc < 0.2 then return end
   acc = 0

   local now = GetTime()

   -- Eine angeforderte Pause, die der Server nie bestaetigt (Befehl verloren,
   -- Verbindung weg), soll die Anzeige nicht dauerhaft verfaelschen.
   if manualPending and (now - manualPendingAt) > 5 then
      manualPending = false
      if AT.UI then AT.UI.Update() end
   end

   if not WantsCheck() then
      if H.countdown then H.countdown = nil if AT.UI then AT.UI.Update() end end
      return
   end
   CheckIdle(now)
end)

-- Fuer Tests: Zustand zuruecksetzen.
function H.Reset()
   H.countdown = nil
   H.reason = nil
   lastActive = 0
   lastResumeAt = -1000
   lastCursorX, lastCursorY = nil, nil
   manualPending = false
end

-- ---------------------------------------------------------------------------
-- Anzeige
-- ---------------------------------------------------------------------------

function H.StatusText()
   local st = AT.status.state
   if st == "COMBAT" then return "Kampf - du hast die Kontrolle" end
   if st ~= "PLAYER" and not manualPending then return nil end
   if H.IsManual() then return "Pause - du hast die Kontrolle" end
   if H.countdown then
      return string.format("Autopilot in %d s", math.ceil(H.countdown))
   end
   if H.reason then return "Du hast die Kontrolle (" .. H.reason .. ")" end
   return "Du hast die Kontrolle"
end
