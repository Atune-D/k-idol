-- DeviceKeyboardShortcutDecision (decision 16: "touch first, keyboard and mouse supported"): what a
-- key press does. Every action also has a large on-screen button (touch, mouse); the keys are the
-- keyboard's way to the same actions:
--   J            join the current round (only while the Join button is shown and enabled)
--   L            open or close the leaderboard
--   1 to 9       tap the 1st to 9th wardrobe item, in the order the wardrobe lists them (only while
--                the wardrobe is shown; a locked wardrobe still refuses inside the session)
-- A key the game's own interface already used (typing in the chat box) does nothing; the wiring
-- passes that flag in. Pure logic: key names are Enum.KeyCode item names as plain strings.
--
-- PUBLIC API
--   DeviceKeyboardShortcutDecision.WARDROBE_KEY_NAMES   frozen { "One", ..., "Nine" }
--   DeviceKeyboardShortcutDecision.decideKeyAction(keyCodeName, isKeyAlreadyUsedByInterface, screenModel)
--     -> { actionKind = "JoinCurrentRound" | "ToggleLeaderboard" | "TapWardrobeItem", stylingItemKey? }?
--   DeviceKeyboardShortcutDecision.listWardrobeShortcutStylingItemKeys(screenModel) -> { string }
--     the keys reachable by 1 to 9, in order

local DeviceKeyboardShortcutDecision = {}

DeviceKeyboardShortcutDecision.WARDROBE_KEY_NAMES =
	table.freeze({ "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" })

function DeviceKeyboardShortcutDecision.listWardrobeShortcutStylingItemKeys(screenModel): { string }
	local stylingItemKeys = {}
	if not screenModel.wardrobePanel.isVisible then
		return stylingItemKeys
	end
	for _, slotGroup in screenModel.wardrobePanel.slotGroups do
		for _, itemButton in slotGroup.itemButtons do
			if #stylingItemKeys < #DeviceKeyboardShortcutDecision.WARDROBE_KEY_NAMES then
				table.insert(stylingItemKeys, itemButton.stylingItemKey)
			end
		end
	end
	return stylingItemKeys
end

function DeviceKeyboardShortcutDecision.decideKeyAction(
	keyCodeName: string,
	isKeyAlreadyUsedByInterface: boolean,
	screenModel
)
	if isKeyAlreadyUsedByInterface then
		return nil
	end
	if keyCodeName == "L" then
		return { actionKind = "ToggleLeaderboard" }
	end
	if keyCodeName == "J" then
		local joinPanel = screenModel.joinPanel
		if joinPanel.isVisible and joinPanel.isJoinButtonVisible and joinPanel.isJoinButtonEnabled then
			return { actionKind = "JoinCurrentRound" }
		end
		return nil
	end
	local wardrobePosition = table.find(DeviceKeyboardShortcutDecision.WARDROBE_KEY_NAMES, keyCodeName)
	if wardrobePosition == nil then
		return nil
	end
	local stylingItemKey =
		DeviceKeyboardShortcutDecision.listWardrobeShortcutStylingItemKeys(screenModel)[wardrobePosition]
	if stylingItemKey == nil then
		return nil
	end
	return { actionKind = "TapWardrobeItem", stylingItemKey = stylingItemKey }
end

return table.freeze(DeviceKeyboardShortcutDecision)
