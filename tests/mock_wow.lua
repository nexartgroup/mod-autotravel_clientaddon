-- tests/mock_wow.lua
-- ---------------------------------------------------------------------------
-- Eine kleine Attrappe der WoW-3.3.5a-Umgebung, gerade gross genug, um das Addon
-- unter einem gewoehnlichen Lua 5.1 zu laden und zu betreiben:
--
--     lua5.1 tests/run.lua
--
-- Was sie leistet
--   * jede Datei des Addons laedt in TOC-Reihenfolge, ohne dass eine Funktion
--     fehlt, die es in 3.3.5a gar nicht gibt (die Attrappe kennt nur echte API)
--   * Frames merken sich Skripte, Ereignisse, Text, Sichtbarkeit, Aktivierung
--   * der Test steuert Zeit, Ereignisse und die gesendeten Chatzeilen
--
-- Was sie NICHT leistet
--   * Sie rendert nichts. Ob ein Fenster gut aussieht, zeigt nur das Spiel.
--   * Layoutaufrufe (SetPoint, SetWidth ...) werden angenommen und vergessen.
-- ---------------------------------------------------------------------------

local M = {}

M.now = 1000.0
M.sent = {}              -- gesendete Chatzeilen { text, channel, target }
M.frames = {}            -- alle erzeugten Frames
M.messages = {}          -- Zeilen, die ins Chatfenster geschrieben wurden
M.filters = {}           -- ChatFrame_AddMessageEventFilter

-- Zustand, den der Test setzen kann
M.world = {
   dead = false, combat = false, speed = 0, falling = false, mouselook = false,
   mouse = {}, shift = false, ctrl = false, alt = false,
   casting = false, channel = false, chatOpen = false, onTaxi = false, vehicle = false,
   cursor = { 100, 100 }, cursorItem = false, shown = {},
}

-- ---------------------------------------------------------------------------
-- Bausteine
-- ---------------------------------------------------------------------------

local Obj = {}
Obj.__index = function(t, k)
   local v = rawget(Obj, k)
   if v ~= nil then return v end
   -- WoW-Methoden beginnen mit einem Grossbuchstaben (SetPoint, CreateTexture ...).
   -- Alles Unbekannte, das so heisst, ist ein Layout-/Darstellungsaufruf: annehmen,
   -- verwerfen. Alles andere sind Felder, die das Addon selbst anlegt (pending, tip,
   -- label ...) und die an einem echten Frame nil waeren, solange niemand sie setzt.
   if type(k) == "string" and k:match("^%u") and k ~= "Load" then
      return function(self) return self end
   end
   return nil
end

local function NewObject(kind, name)
   local o = setmetatable({}, Obj)
   o.__kind = kind
   o.__name = name
   o.__shown = true
   o.__enabled = true
   o.__text = ""
   o.__checked = false
   o.__value = 0
   o.__min, o.__max = 0, 1
   o.__scripts = {}
   o.__events = {}
   o.__alpha = 1
   if name then _G[name] = o end
   return o
end

function Obj.SetScript(self, name, fn) self.__scripts[name] = fn end
function Obj.GetScript(self, name) return self.__scripts[name] end
function Obj.RegisterEvent(self, e) self.__events[e] = true end
function Obj.UnregisterEvent(self, e) self.__events[e] = nil end
function Obj.RegisterForClicks() end
function Obj.RegisterForDrag() end
function Obj.IsObjectType(self, t) return self.__kind == t end
function Obj.GetName(self) return self.__name end

function Obj.Show(self) self.__shown = true end
function Obj.Hide(self) self.__shown = false end
function Obj.IsShown(self) return self.__shown end
function Obj.Enable(self) self.__enabled = true end
function Obj.Disable(self) self.__enabled = false end
function Obj.IsEnabled(self) return self.__enabled and 1 or nil end
function Obj.SetAlpha(self, a) self.__alpha = a end
function Obj.GetAlpha(self) return self.__alpha end

function Obj.SetText(self, t) self.__text = tostring(t or "") end
function Obj.GetText(self) return self.__text end
function Obj.SetChecked(self, v) self.__checked = v and true or false end
function Obj.GetChecked(self) return self.__checked and 1 or nil end
function Obj.SetValue(self, v)
   self.__value = v
   local fn = self.__scripts.OnValueChanged
   if fn then fn(self, v) end
end
function Obj.GetValue(self) return self.__value end
function Obj.SetMinMaxValues(self, a, b) self.__min, self.__max = a, b end

function Obj.GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
function Obj.GetCenter() return 0, 0 end
function Obj.GetEffectiveScale() return 1 end

function Obj.CreateFontString(self) return NewObject("FontString") end
function Obj.CreateTexture(self) return NewObject("Texture") end
function Obj.GetChildren() return end

local function WithTemplate(o, name, inherits)
   if not inherits or not name then return end
   if inherits:find("UICheckButtonTemplate") then
      _G[name .. "Text"] = NewObject("FontString")
   elseif inherits:find("OptionsSliderTemplate") then
      _G[name .. "Text"] = NewObject("FontString")
      _G[name .. "Low"]  = NewObject("FontString")
      _G[name .. "High"] = NewObject("FontString")
   elseif inherits:find("UIDropDownMenuTemplate") then
      _G[name .. "Text"] = NewObject("FontString")
   elseif inherits:find("UIPanelScrollFrameTemplate") then
      _G[name .. "ScrollBar"] = NewObject("Slider", name .. "ScrollBar")
   end
end

function M.CreateFrame(kind, name, parent, inherits)
   local o = NewObject(kind, name)
   o.__parent = parent
   WithTemplate(o, name, inherits)
   table.insert(M.frames, o)
   return o
end

-- ---------------------------------------------------------------------------
-- Zeit und Ereignisse
-- ---------------------------------------------------------------------------

function M.Fire(event, ...)
   for _, f in ipairs(M.frames) do
      if f.__events[event] and f.__scripts.OnEvent then
         f.__scripts.OnEvent(f, event, ...)
      end
   end
end

-- Zeit um dt Sekunden vorstellen, in Schritten von 'step', und OnUpdate rufen.
function M.Advance(dt, step)
   step = step or 0.05
   local done = 0
   while done < dt - 1e-9 do
      local d = math.min(step, dt - done)
      M.now = M.now + d
      done = done + d
      for _, f in ipairs(M.frames) do
         local fn = f.__scripts.OnUpdate
         if fn and f.__shown ~= false then fn(f, d) end
      end
   end
end

function M.ClearSent() M.sent = {} end

function M.SentCommands()
   local out = {}
   for _, s in ipairs(M.sent) do out[#out + 1] = s.text end
   return out
end

function M.SentContains(prefix)
   for _, s in ipairs(M.sent) do
      if s.text:sub(1, #prefix) == prefix then return true end
   end
   return false
end

-- Zeile vom Server, wie sie als CHAT_MSG_SYSTEM ankommt. Laeuft zuerst durch die
-- Filter (wie in WoW) und geht danach an die Ereignisfunktionen.
function M.ServerLine(line)
   M.Fire("CHAT_MSG_SYSTEM", line)
end

-- ---------------------------------------------------------------------------
-- Installation der Globals
-- ---------------------------------------------------------------------------

function M.Install()
   M.now = 1000.0
   M.sent, M.frames, M.messages, M.filters = {}, {}, {}, {}
   M.world = {
      dead = false, combat = false, speed = 0, falling = false, mouselook = false,
      mouse = {}, shift = false, ctrl = false, alt = false,
      casting = false, channel = false, chatOpen = false, onTaxi = false, vehicle = false,
      cursor = { 100, 100 }, cursorItem = false, shown = {},
   }

   local W = M.world

   _G.CreateFrame = M.CreateFrame
   _G.UIParent = NewObject("Frame", "UIParent")
   _G.Minimap = NewObject("Frame", "Minimap")
   _G.GameTooltip = NewObject("Frame", "GameTooltip")
   _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) M.messages[#M.messages + 1] = text end }

   _G.GetTime = function() return M.now end
   _G.SendChatMessage = function(text, channel, _, target)
      M.sent[#M.sent + 1] = { text = text, channel = channel, target = target }
   end
   _G.UnitName = function() return "Testspieler" end
   _G.strsplit = function(delim, str, pieces)
      local out, pos = {}, 1
      str = str or ""
      while true do
         if pieces and #out >= pieces - 1 then out[#out + 1] = str:sub(pos) break end
         local s, e = str:find(delim, pos, true)
         if not s then out[#out + 1] = str:sub(pos) break end
         out[#out + 1] = str:sub(pos, s - 1)
         pos = e + 1
      end
      return unpack(out)
   end

   -- Einheiten und Eingabe
   _G.UnitIsDeadOrGhost = function() return W.dead end
   _G.UnitAffectingCombat = function() return W.combat end
   _G.UnitCastingInfo = function() return W.casting and "Zauber" or nil end
   _G.UnitChannelInfo = function() return W.channel and "Kanal" or nil end
   _G.GetUnitSpeed = function() return W.speed end
   _G.IsFalling = function() return W.falling end
   _G.IsMouselooking = function() return W.mouselook end
   _G.IsMouseButtonDown = function(b) return W.mouse[b] or false end
   _G.IsShiftKeyDown = function() return W.shift end
   _G.IsControlKeyDown = function() return W.ctrl end
   _G.IsAltKeyDown = function() return W.alt end
   _G.GetCursorPosition = function() return W.cursor[1], W.cursor[2] end
   _G.CursorHasItem = function() return W.cursorItem end
   _G.CursorHasSpell = function() return false end
   _G.ChatEdit_GetActiveWindow = function() return W.chatOpen and {} or nil end
   _G.UnitOnTaxi = function() return W.onTaxi end
   _G.UnitHasVehicleUI = function() return W.vehicle end

   -- Blizzard-Fenster: nur die, die der Test als offen markiert
   for _, n in ipairs({ "LootFrame", "MerchantFrame", "QuestFrame", "GossipFrame", "TaxiFrame",
                        "BankFrame", "MailFrame", "SendMailFrame", "TradeFrame", "AuctionFrame",
                        "TradeSkillFrame", "CraftFrame", "ClassTrainerFrame", "PetStableFrame",
                        "CharacterFrame", "SpellBookFrame", "PlayerTalentFrame", "QuestLogFrame",
                        "WorldMapFrame", "GameMenuFrame", "InterfaceOptionsFrame", "GuildBankFrame",
                        "FriendsFrame", "LFDParentFrame", "AchievementFrame", "PVPParentFrame",
                        "CinematicFrame", "MovieFrame",
                        "StaticPopup1", "StaticPopup2", "StaticPopup3", "StaticPopup4" }) do
      local f = NewObject("Frame", n)
      f.__shown = false
   end

   _G.ChatFrame_AddMessageEventFilter = function(event, fn)
      M.filters[event] = M.filters[event] or {}
      table.insert(M.filters[event], fn)
   end
   _G.InterfaceOptions_AddCategory = function() end
   _G.InterfaceOptionsFrame_OpenToCategory = function() end
   _G.StaticPopup_Show = function(which, text) M.popup = { which = which, text = text } end
   _G.StaticPopupDialogs = {}
   _G.SlashCmdList = {}
   _G.YES, _G.NO = "Ja", "Nein"

   -- Karten (leer: das Addon muss damit umgehen koennen)
   _G.GetMapContinents = function() return end
   _G.GetMapZones = function() return end
   _G.SetMapZoom = function() end
   _G.GetCurrentMapAreaID = function() return 0 end
   _G.SetMapToCurrentZone = function() end
   _G.SetMapByID = function() end
   _G.GetPlayerMapPosition = function() return 0, 0 end

   -- Inventar
   _G.GetInventoryItemQuality = function() return nil end
   _G.GetInventoryItemLink = function() return nil end
   _G.GetContainerNumSlots = function() return 0 end
   _G.GetContainerItemLink = function() return nil end

   -- Aufrufe, die in der echten Umgebung nur unter dem UIDropDownMenu-System
   -- existieren (BotPad)
   _G.UIDropDownMenu_Initialize = function() end
   _G.UIDropDownMenu_CreateInfo = function() return {} end
   _G.UIDropDownMenu_AddButton = function() end
   _G.UIDropDownMenu_SetSelectedValue = function() end
   _G.UIDropDownMenu_SetWidth = function() end
   _G.UIDropDownMenu_SetText = function() end

   _G.Nx = nil     -- Carbonite fehlt, solange der Test es nicht installiert

   _G.AutoTravel, _G.AutoTravelDB, _G.AutoTravelGlobalDB = nil, nil, nil
   _G.Botpad, _G.BotpadDB = nil, nil
end

-- Einen Blizzard-Frame als offen oder zu markieren
function M.SetFrameShown(name, shown)
   local f = _G[name]
   if f then f.__shown = shown end
end

-- Eine Zeile durch die Chatfilter schicken. Rueckgabe: true = verborgen.
function M.Filtered(event, msg)
   for _, fn in ipairs(M.filters[event] or {}) do
      if fn({}, event, msg) then return true end
   end
   return false
end

-- Dateien in TOC-Reihenfolge laden
function M.LoadToc(dir, tocName)
   local files = {}
   for line in io.lines(dir .. "/" .. tocName) do
      local f = line:match("^([%w_]+%.lua)%s*$")
      if f then files[#files + 1] = f end
   end
   for _, f in ipairs(files) do
      local chunk, err = loadfile(dir .. "/" .. f)
      if not chunk then error("Syntaxfehler in " .. f .. ": " .. tostring(err)) end
      chunk("AutoTravel", {})      -- WoW uebergibt Addonname und -tabelle
   end
   return files
end

return M
