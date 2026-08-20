-- AT_Override.lua
-- ---------------------------------------------------------------------------
-- Nur noch die Tastenabfangung. Die Frage "war das der Mensch?" beantwortet
-- AT_Input, die Frage "wer hat die Kontrolle?" beantwortet AT_Human.
--
-- Frueher steckte alles drei in dieser Datei, mit einem gemeinsamen Zustand
-- fuer automatische Uebernahme und ausdrueckliche Pause. Das war die Ursache
-- dafuer, dass "/at pause" von selbst auslaufen konnte.
-- ---------------------------------------------------------------------------

AutoTravel = AutoTravel or {}
local AT = AutoTravel

AT.Override = {}
local O = AT.Override

-- Vertraeglichkeit mit aelteren Aufrufen
function O.Note(reason)   AT.Input.Activity(reason or "MANUAL") end
function O.Release(sil)   AT.Human.Resume(sil) end
function O.Toggle()       AT.Human.Toggle() end
function O.StatusText()   return AT.Human.StatusText() end

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

-- Der abgefangene Tastendruck wird als Bewegungseingabe gemeldet.
function O.OnGrabbedKey()
   AT.Input.Activity("KEY_MOVE")
end

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
            if pcall(SetOverrideBinding, keyOwner, true, key, "AUTOTRAVEL_GRAB") then
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
   if not AT.active then ReleaseGrab() return end
   if AT.Human.IsHuman() then ReleaseGrab() return end
   if not AT.GetBool("TakeControl") then ReleaseGrab() return end

   -- Frueher stand hier ein Vergleich mit dem deutschen Anzeigetext
   -- "PAUSED - SPIELER". Wer die Sprache wechselt oder den Text aendert,
   -- haette die Tastenabfangung stillschweigend kaputtgemacht. Jetzt kommt
   -- der Kontrollbesitz als eigenes Protokollfeld vom Server.
   if AT.status and AT.status.owner == "PLAYER" then ReleaseGrab() return end

   ApplyGrab()
end


-- ---------------------------------------------------------------------------
-- Takt fuer die Tastenabfangung
-- ---------------------------------------------------------------------------
-- Bewusst ganz unten: keyOwner und O.UpdateGrab muessen zu diesem Zeitpunkt
-- bereits angelegt sein. Stand der Block weiter oben, war keyOwner beim Laden
-- der Datei noch nil.

local grabAcc = 0
keyOwner:SetScript("OnUpdate", function(self, elapsed)
   grabAcc = grabAcc + elapsed
   if grabAcc < 0.5 then return end
   grabAcc = 0
   O.UpdateGrab()
end)
