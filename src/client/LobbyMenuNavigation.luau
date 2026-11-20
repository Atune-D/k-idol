-- LobbyMenuNavigation (development spec §0.2 "Lobby and dance floor", §0.3 decision 16 "touch first,
-- keyboard and mouse supported"): when the lobby menu can be used, whether it is open, and which of its
-- panels is shown.
--   * Available whenever the player is NOT busy in a round: busy = a participant of the current round
--     while its phase is Styling or Showcase (§2.7's "not allowed during round" moments; the round
--     wardrobe and the stage need the screen then). Before any round state is known it is available.
--   * Becoming busy closes the menu (it does not reopen by itself); the chosen panel is remembered.
--   * One large "Menu" button opens and closes it (touch, mouse, gamepad); the M key does the same.
--     Panels: Dances, Shop, Daily, Codes, Outfit, chosen with large tab buttons. While the Outfit
--     panel is shown, keys 1 to 9 tap its first nine wardrobe items, as in the round wardrobe.
--   * A key the game's own interface already used (typing in a text box or the chat) does nothing.
-- Opening the menu on the Outfit panel, or switching to it, is reported (wasOutfitPanelOpened) so the
-- wiring restarts the lobby outfit from the stored one.
-- Pure logic: no Roblox-specific interface is used; key names are Enum.KeyCode item names as strings.
--
-- PUBLIC API
--   LobbyMenuNavigation.LOBBY_PANEL_NAMES   frozen { "Dances", "Shop", "Daily", "Codes", "Outfit" }
--   LobbyMenuNavigation.isLobbyMenuAvailable(sessionSnapshot) -> boolean   (ThemedRoundDeviceSession's snapshot)
--   LobbyMenuNavigation.new() -> navigation
--   navigation:noteLobbyMenuAvailability(isAvailable)
--   navigation:toggleLobbyMenu() -> { wasOutfitPanelOpened }
--   navigation:openLobbyPanel(panelName) -> { wasOutfitPanelOpened }
--   navigation:readLobbyMenuModel() -> { isMenuButtonVisible, menuButtonText, isMenuOpen, openPanelName,
--       tabs = { { panelName, tabText, isSelected } } }
--   LobbyMenuNavigation.decideLobbyMenuKeyAction(keyCodeName, isKeyAlreadyUsedByInterface, lobbyMenuModel,
--       lobbyOutfitWardrobePanelModel?) -> { actionKind = "ToggleLobbyMenu" | "TapLobbyWardrobeItem", stylingItemKey? }?

local DeviceKeyboardShortcutDecision = require("./DeviceKeyboardShortcutDecision")

local LobbyMenuNavigation = {}
LobbyMenuNavigation.__index = LobbyMenuNavigation

LobbyMenuNavigation.LOBBY_PANEL_NAMES = table.freeze({ "Dances", "Shop", "Daily", "Codes", "Outfit" })

local TAB_TEXT_BY_PANEL_NAME = table.freeze({
	Dances = "Dances",
	Shop = "Shop",
	Daily = "Daily",
	Codes = "Codes",
	Outfit = "Outfit",
})

local BUSY_ROUND_PHASES = table.freeze({ Styling = true, Showcase = true })

function LobbyMenuNavigation.isLobbyMenuAvailable(sessionSnapshot): boolean
	local roundState = sessionSnapshot.roundState
	if roundState == nil or not sessionSnapshot.isParticipant then
		return true
	end
	return BUSY_ROUND_PHASES[roundState.roundPhase] ~= true
end

function LobbyMenuNavigation.new()
	return setmetatable({ isMenuOpen = false, isMenuAvailable = true, openPanelName = "Dances" }, LobbyMenuNavigation)
end

function LobbyMenuNavigation:noteLobbyMenuAvailability(isAvailable: boolean)
	self.isMenuAvailable = isAvailable
	if not isAvailable then
		self.isMenuOpen = false
	end
end

function LobbyMenuNavigation:toggleLobbyMenu()
	if not self.isMenuAvailable then
		return { wasOutfitPanelOpened = false }
	end
	self.isMenuOpen = not self.isMenuOpen
	return { wasOutfitPanelOpened = self.isMenuOpen and self.openPanelName == "Outfit" }
end

function LobbyMenuNavigation:openLobbyPanel(panelName: string)
	if table.find(LobbyMenuNavigation.LOBBY_PANEL_NAMES, panelName) == nil or not self.isMenuOpen then
		return { wasOutfitPanelOpened = false }
	end
	local wasAlreadyShown = self.openPanelName == panelName
	self.openPanelName = panelName
	return { wasOutfitPanelOpened = panelName == "Outfit" and not wasAlreadyShown }
end

function LobbyMenuNavigation:readLobbyMenuModel()
	local tabs = {}
	for _, panelName in LobbyMenuNavigation.LOBBY_PANEL_NAMES do
		table.insert(tabs, {
			panelName = panelName,
			tabText = TAB_TEXT_BY_PANEL_NAME[panelName],
			isSelected = panelName == self.openPanelName,
		})
	end
	return {
		isMenuButtonVisible = self.isMenuAvailable,
		menuButtonText = if self.isMenuOpen then "Close menu (M)" else "Menu (M)",
		isMenuOpen = self.isMenuOpen and self.isMenuAvailable,
		openPanelName = self.openPanelName,
		tabs = tabs,
	}
end

function LobbyMenuNavigation.decideLobbyMenuKeyAction(
	keyCodeName: string,
	isKeyAlreadyUsedByInterface: boolean,
	lobbyMenuModel,
	lobbyOutfitWardrobePanelModel
)
	if isKeyAlreadyUsedByInterface then
		return nil
	end
	if keyCodeName == "M" then
		return if lobbyMenuModel.isMenuButtonVisible then { actionKind = "ToggleLobbyMenu" } else nil
	end
	local isOutfitPanelShown = lobbyMenuModel.isMenuOpen and lobbyMenuModel.openPanelName == "Outfit"
	local wardrobePosition = table.find(DeviceKeyboardShortcutDecision.WARDROBE_KEY_NAMES, keyCodeName)
	if not isOutfitPanelShown or wardrobePosition == nil or lobbyOutfitWardrobePanelModel == nil then
		return nil
	end
	local reachableKeys = DeviceKeyboardShortcutDecision.listWardrobeShortcutStylingItemKeys({
		wardrobePanel = lobbyOutfitWardrobePanelModel,
	})
	local stylingItemKey = reachableKeys[wardrobePosition]
	return if stylingItemKey ~= nil
		then { actionKind = "TapLobbyWardrobeItem", stylingItemKey = stylingItemKey }
		else nil
end

return LobbyMenuNavigation
