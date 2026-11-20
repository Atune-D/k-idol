-- Decision 16 "keyboard and mouse supported": J joins, L toggles the leaderboard, 1-9 tap wardrobe items.

local UnitTestFramework = require("../Support/UnitTestFramework")
local DeviceKeyboardShortcutDecision = require("../../src/client/DeviceKeyboardShortcutDecision")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function screenModel(overrides)
	local itemButtons = {}
	for itemNumber = 1, 11 do
		table.insert(itemButtons, { stylingItemKey = "asset_" .. itemNumber })
	end
	local model = {
		joinPanel = { isVisible = true, isJoinButtonVisible = true, isJoinButtonEnabled = true },
		wardrobePanel = {
			isVisible = true,
			slotGroups = {
				{ itemButtons = { itemButtons[1], itemButtons[2] } },
				{ itemButtons = table.move(itemButtons, 3, 11, 1, {}) },
			},
		},
	}
	for key, value in overrides or {} do
		model[key] = value
	end
	return model
end

describe("DeviceKeyboardShortcutDecision", function()
	it("joins with J only while the Join button is shown and enabled", function()
		expect(DeviceKeyboardShortcutDecision.decideKeyAction("J", false, screenModel())).toEqual({
			actionKind = "JoinCurrentRound",
		})
		local disabled = screenModel({
			joinPanel = { isVisible = true, isJoinButtonVisible = true, isJoinButtonEnabled = false },
		})
		expect(DeviceKeyboardShortcutDecision.decideKeyAction("J", false, disabled)).toBeNil()
		local hidden = screenModel({
			joinPanel = { isVisible = true, isJoinButtonVisible = false, isJoinButtonEnabled = true },
		})
		expect(DeviceKeyboardShortcutDecision.decideKeyAction("J", false, hidden)).toBeNil()
	end)

	it("toggles the leaderboard with L", function()
		expect(DeviceKeyboardShortcutDecision.decideKeyAction("L", false, screenModel())).toEqual({
			actionKind = "ToggleLeaderboard",
		})
	end)

	it("taps the n-th listed wardrobe item with keys 1 to 9, across slot groups", function()
		expect(DeviceKeyboardShortcutDecision.decideKeyAction("One", false, screenModel())).toEqual({
			actionKind = "TapWardrobeItem",
			stylingItemKey = "asset_1",
		})
		expect(DeviceKeyboardShortcutDecision.decideKeyAction("Three", false, screenModel()).stylingItemKey).toBe(
			"asset_3"
		)
		expect(DeviceKeyboardShortcutDecision.decideKeyAction("Nine", false, screenModel()).stylingItemKey).toBe(
			"asset_9"
		)
		expect(#DeviceKeyboardShortcutDecision.listWardrobeShortcutStylingItemKeys(screenModel())).toBe(9)
		local hidden = screenModel()
		hidden.wardrobePanel.isVisible = false -- items still listed, but the wardrobe is not shown
		expect(DeviceKeyboardShortcutDecision.decideKeyAction("One", false, hidden)).toBeNil()
	end)

	it("does nothing for a key the interface already used, or an unknown key", function()
		expect(DeviceKeyboardShortcutDecision.decideKeyAction("L", true, screenModel())).toBeNil()
		expect(DeviceKeyboardShortcutDecision.decideKeyAction("J", true, screenModel())).toBeNil()
		expect(DeviceKeyboardShortcutDecision.decideKeyAction("Q", false, screenModel())).toBeNil()
		expect(DeviceKeyboardShortcutDecision.decideKeyAction("Zero", false, screenModel())).toBeNil()
	end)
end)
