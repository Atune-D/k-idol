-- When the lobby menu is available (not busy in a round), open, on which panel, and its keys (decision 16).

local UnitTestFramework = require("../Support/UnitTestFramework")
local LobbyMenuNavigation = require("../../src/client/LobbyMenuNavigation")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function sessionSnapshot(roundPhase, isParticipant)
	return {
		roundState = if roundPhase ~= nil then { roundPhase = roundPhase } else nil,
		isParticipant = isParticipant,
	}
end

describe("LobbyMenuNavigation.isLobbyMenuAvailable", function()
	it("is unavailable only to a participant during Styling or Showcase", function()
		local isAvailable = LobbyMenuNavigation.isLobbyMenuAvailable
		for _, roundPhase in { "ThemeReveal", "Styling", "Showcase", "Results", "Intermission" } do
			expect(isAvailable(sessionSnapshot(roundPhase, false))).toBe(true)
			local isBusy = roundPhase == "Styling" or roundPhase == "Showcase"
			expect(isAvailable(sessionSnapshot(roundPhase, true))).toBe(not isBusy)
		end
		expect(isAvailable(sessionSnapshot(nil, false))).toBe(true)
	end)
end)

describe("LobbyMenuNavigation", function()
	it("opens and closes with the menu button, starting on Dances", function()
		local navigation = LobbyMenuNavigation.new()
		local closed = navigation:readLobbyMenuModel()
		expect(closed.isMenuOpen).toBe(false)
		expect(closed.isMenuButtonVisible).toBe(true)
		expect(closed.menuButtonText).toBe("Menu (M)")
		navigation:toggleLobbyMenu()
		local opened = navigation:readLobbyMenuModel()
		expect(opened.isMenuOpen).toBe(true)
		expect(opened.openPanelName).toBe("Dances")
		expect(opened.menuButtonText).toBe("Close menu (M)")
		expect(#opened.tabs).toBe(5)
		expect(opened.tabs[1].isSelected).toBe(true)
	end)

	it("closes when the player becomes busy, hides the button, and does not reopen by itself", function()
		local navigation = LobbyMenuNavigation.new()
		navigation:toggleLobbyMenu()
		navigation:noteLobbyMenuAvailability(false)
		local busy = navigation:readLobbyMenuModel()
		expect(busy.isMenuOpen).toBe(false)
		expect(busy.isMenuButtonVisible).toBe(false)
		expect(navigation:toggleLobbyMenu().wasOutfitPanelOpened).toBe(false)
		navigation:noteLobbyMenuAvailability(true)
		expect(navigation:readLobbyMenuModel().isMenuOpen).toBe(false)
	end)

	it("switches panels only while open, reports opening the Outfit panel, ignores unknown names", function()
		local navigation = LobbyMenuNavigation.new()
		expect(navigation:openLobbyPanel("Shop").wasOutfitPanelOpened).toBe(false)
		expect(navigation:readLobbyMenuModel().openPanelName).toBe("Dances")
		navigation:toggleLobbyMenu()
		navigation:openLobbyPanel("Shop")
		expect(navigation:readLobbyMenuModel().openPanelName).toBe("Shop")
		expect(navigation:openLobbyPanel("Outfit").wasOutfitPanelOpened).toBe(true)
		expect(navigation:openLobbyPanel("Outfit").wasOutfitPanelOpened).toBe(false)
		navigation:openLobbyPanel("Nonsense")
		expect(navigation:readLobbyMenuModel().openPanelName).toBe("Outfit")
		navigation:toggleLobbyMenu()
		expect(navigation:toggleLobbyMenu().wasOutfitPanelOpened).toBe(true)
	end)
end)

describe("LobbyMenuNavigation.decideLobbyMenuKeyAction", function()
	local wardrobePanel = {
		isVisible = true,
		slotGroups = { { itemButtons = { { stylingItemKey = "a" }, { stylingItemKey = "b" } } } },
	}

	it("toggles the menu with M while it is available, never while typing", function()
		local decide = LobbyMenuNavigation.decideLobbyMenuKeyAction
		local menuModel = LobbyMenuNavigation.new():readLobbyMenuModel()
		expect(decide("M", false, menuModel, nil)).toEqual({ actionKind = "ToggleLobbyMenu" })
		expect(decide("M", true, menuModel, nil)).toBeNil()
		local busyNavigation = LobbyMenuNavigation.new()
		busyNavigation:noteLobbyMenuAvailability(false)
		expect(decide("M", false, busyNavigation:readLobbyMenuModel(), nil)).toBeNil()
	end)

	it("taps the lobby wardrobe's items with 1 to 9 only while the Outfit panel is shown", function()
		local decide = LobbyMenuNavigation.decideLobbyMenuKeyAction
		local navigation = LobbyMenuNavigation.new()
		navigation:toggleLobbyMenu()
		expect(decide("Two", false, navigation:readLobbyMenuModel(), wardrobePanel)).toBeNil()
		navigation:openLobbyPanel("Outfit")
		local menuModel = navigation:readLobbyMenuModel()
		expect(decide("Two", false, menuModel, wardrobePanel)).toEqual({
			actionKind = "TapLobbyWardrobeItem",
			stylingItemKey = "b",
		})
		expect(decide("Three", false, menuModel, wardrobePanel)).toBeNil()
		expect(decide("Two", true, menuModel, wardrobePanel)).toBeNil()
	end)
end)
