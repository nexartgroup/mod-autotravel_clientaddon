-- luacheck-Einstellungen fuer ein WoW-3.3.5a-Addon (Lua 5.1).
--
--     luacheck .
--
-- Die Liste der erlaubten globalen Namen enthaelt NUR API, die es in 3.3.5a gibt.
-- Alles andere meldet luacheck als "undefined variable" -- genau so wurden ein
-- Aufruf vor der Deklaration und ein Zugriff auf eine nicht vorhandene Variable
-- gefunden, die jeden Klick auf die Optionen bzw. jede Panelaktualisierung zum
-- Fehler machten.
std = "lua51"
max_line_length = false

globals = {
   "AutoTravel", "AutoTravelDB", "AutoTravelGlobalDB",
   "SlashCmdList", "StaticPopupDialogs",
   "SLASH_AUTOTRAVEL1", "SLASH_AUTOTRAVEL2", "SLASH_BOTPAD1", "SLASH_BOTPAD2",
   "BINDING_HEADER_AUTOTRAVEL", "BINDING_NAME_AUTOTRAVEL_TOGGLE",
   "BINDING_NAME_AUTOTRAVEL_PAUSE", "BINDING_NAME_AUTOTRAVEL_BOT",
}

read_globals = {
   -- Frames und Oberflaeche
   "CreateFrame", "UIParent", "Minimap", "GameTooltip", "DEFAULT_CHAT_FRAME",
   "ChatFrame_AddMessageEventFilter", "InterfaceOptions_AddCategory",
   "InterfaceOptionsFrame_OpenToCategory", "StaticPopup_Show",
   "UIDropDownMenu_Initialize", "UIDropDownMenu_CreateInfo", "UIDropDownMenu_AddButton",
   "UIDropDownMenu_SetSelectedValue", "UIDropDownMenu_SetWidth", "UIDropDownMenu_SetText",
   "ChatEdit_GetActiveWindow", "_G", "YES", "NO", "IsAddOnLoaded", "UnitOnTaxi", "UnitHasVehicleUI",
   -- Zeit, Einheiten, Eingabe
   "GetTime", "UnitName", "UnitIsDeadOrGhost", "UnitAffectingCombat", "UnitCastingInfo",
   "UnitChannelInfo", "GetUnitSpeed", "IsFalling", "IsMouselooking", "IsMouseButtonDown",
   "IsShiftKeyDown", "IsControlKeyDown", "IsAltKeyDown", "GetCursorPosition",
   "CursorHasItem", "CursorHasSpell",
   -- Chat
   "SendChatMessage", "strsplit",
   -- Karten
   "GetMapContinents", "GetMapZones", "SetMapZoom", "GetCurrentMapAreaID",
   "SetMapToCurrentZone", "SetMapByID", "GetPlayerMapPosition",
   -- Inventar
   "GetInventoryItemQuality", "GetInventoryItemLink", "GetContainerNumSlots",
   "GetContainerItemLink",
   -- Carbonite
   "Nx",
}

-- Unbenutzte Funktionsargumente und Schleifenvariablen sind in WoW-Skripten
-- (OnEvent(self, event, ...)) der Normalfall.
ignore = { "212", "213" }

-- Die Tests setzen absichtlich Attrappen fuer die WoW-API.
exclude_files = { "tests/" }
