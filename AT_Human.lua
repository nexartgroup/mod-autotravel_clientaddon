-- AT_Human.lua
-- ---------------------------------------------------------------------------
-- Wer hat die Kontrolle: Mensch oder AutoTravel?
--
-- Dies ersetzt das vermischte O.active aus AT_Override. Zwei Dinge, die
-- vorher denselben Zustand geteilt haben, sind jetzt getrennt:
--
--   HUMAN    -- automatische Uebernahme, endet nach Ruhezeit von selbst
--   MANUAL   -- ausdrueckliche Pause, endet NUR auf Anweisung
--
-- Vorher konnte "/at pause" nach acht Sekunden von selbst auslaufen. Das ist
-- nicht, was jemand erwartet, der ausdruecklich pausiert.
--
-- Der Uebergang laeuft in klaren Schritten, damit nichts halb passiert:
--
--   BOT -> HUMAN     Reise anhalten, Steuerung freigeben, Tastenabfang loesen
--   HUMAN -> BOT     Ruhezeit + kein Fenster + keine Taste, dann Ausruestung
--                    erfassen, Server neu pathen lassen, Tastenabfang setzen
-- ---------------------------------------------------------------------------

AutoTravel = AutoTravel or {}
local AT = AutoTravel

AT.Human = {}
local H = AT.Human

H.owner  = "BOT"       -- BOT | HUMAN | MANUAL
H.reason = nil

function H.IsHuman()   return H.owner ~= "BOT" end
function H.IsManual()  return H.owner == "MANUAL" end

-- ---------------------------------------------------------------------------

local function Takeover(owner, reason)
   if H.owner == owner then return end

   local wasBot = (H.owner == "BOT")
   H.owner  = owner
   H.reason = reason

   if wasBot then
      -- 1. Tastenabfang loesen, damit die naechste Eingabe normal durchgeht
      if AT.Override then AT.Override.ReleaseGrab() end
      -- 2. Reise anhalten und Steuerung zurueckgeben (hohe Dringlichkeit)
      if AT.active then AT.SendNow("at pause 1") end
      -- 3. Playerbot nur auf Wunsch
      if AT.GetBool("OverridePausesBot") and AT.Bot then
         AT.Bot.Pause("HUMAN_OVERRIDE")
      end
   end

   AT.Print("|cffe8c44a" .. (owner == "MANUAL" and "Pause" or "Du hast die Kontrolle") ..
            "|r (" .. AT.Input.ReasonText(reason) .. ")")
   if AT.UI then AT.UI.Update() end
end

function H.OnActivity(reason)
   -- Eine Handpause laesst sich nicht durch Aktivitaet aufheben.
   if H.owner == "MANUAL" then return end
   if reason == "MANUAL" then Takeover("MANUAL", reason) return end
   Takeover("HUMAN", reason)
end

function H.ManualPause()
   Takeover("MANUAL", "MANUAL")
end

function H.Resume(silent)
   if H.owner == "BOT" then return end

   H.owner  = "BOT"
   H.reason = nil

   if not silent then AT.Print("Reise uebernimmt wieder.") end

   -- Was der Mensch angezogen hat, gilt jetzt als gewollt.
   if AT.Gear then AT.Gear.Snapshot(true) end
   if AT.Bot then AT.Bot.Resume("HUMAN_OVERRIDE") end
   if AT.active then AT.SendNow("at pause 0") end   -- Server pathet neu
   if AT.Override then AT.Override.UpdateGrab() end
   if AT.UI then AT.UI.Update() end
end

function H.Toggle()
   if H.owner == "MANUAL" then H.Resume()
   elseif H.owner == "HUMAN" then Takeover("MANUAL", "MANUAL")
   else H.ManualPause() end
end

-- ---------------------------------------------------------------------------

local ticker = CreateFrame("Frame", "AutoTravelHuman")
local acc = 0

ticker:SetScript("OnUpdate", function(self, elapsed)
   acc = acc + elapsed
   if acc < 0.3 then return end
   acc = 0

   if AT.Override then AT.Override.UpdateGrab() end

   if H.owner ~= "HUMAN" then return end        -- MANUAL laeuft nie ab
   if AT.Input.MayResume() then H.Resume() end
end)

function H.StatusText()
   if H.owner == "MANUAL" then return "|cffe8c44aPause|r" end
   if H.owner == "HUMAN" then
      local blocked, what = AT.Input.IsUIBlocking()
      if blocked then return "|cffe8c44aDu (" .. what .. ")|r" end
      if AT.Input.IsKeyHeld() then return "|cffe8c44aDu (Taste)|r" end
      return string.format("|cffe8c44aDu (%.0fs)|r", AT.Input.SecondsLeft())
   end
   return "|cff53d17aReise|r"
end
