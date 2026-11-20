-- LobbyOutfitSelection (development spec §1.5 "Stored outfits that contain unavailable items", §2.7,
-- §2.14, §10 v1.4 owner decision 7): the wardrobe reused outside a round to choose the outfit worn in
-- the lobby, and what that wardrobe shows.
--   * Opening it (beginEditing) starts from the STORED lobby outfit of the latest save snapshot, minus
--     the items the server's catalog does not list now (they cannot be worn or sent, §1.5); an empty
--     stored outfit means the player's own avatar.
--   * Tapping an item follows exactly the round wardrobe's rules (WardrobeSelectionRules: one per
--     slot, dress versus top/bottom, at most 3 accessories, only listed items), so the selection is
--     always a valid outfit (§1.5). The preview shows the selection.
--   * "Wear this in the lobby" sends SetLobbyOutfit { outfitStylingItemKeys } through
--     DeviceLobbyRequestSender (2 s, §2.13). The server dresses the real character and stores it;
--     the stored outfit shown comes back only in the snapshot. Sending the unchanged outfit again is
--     allowed (the server accepts it and changes nothing, §2.13).
--   * "Back to saved outfit" restarts from the stored outfit; "Clear" empties the selection (own avatar).
--   * Notices: while the snapshot lists unavailable stored items (§2.6) the panel says "Some items of
--     your saved outfit are unavailable right now." and, conservatively (owner decision 7: a new
--     outfit replaces the whole stored list), that wearing a new outfit replaces them.
--   * The catalog is not ready: a loading notice and no items; before the first snapshot: a loading
--     notice.
-- The wardrobe model has the shape WardrobePanelView renders (as ThemedRoundScreenModelBuilder's
-- wardrobePanel), so the same view draws both wardrobes.
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   LobbyOutfitSelection.new({ stylingItemByStylingItemKey, lobbyRequestSender }) -> selection
--   selection:beginEditing(lobbySnapshot?, wardrobeCatalogView?)
--   selection:tapWardrobeItem(stylingItemKey, wardrobeCatalogView?) -> selectionOutcome?
--   selection:restoreStoredOutfit(lobbySnapshot?, wardrobeCatalogView?)
--   selection:clearSelection()
--   selection:confirmLobbyOutfit() -> boolean   true when SetLobbyOutfit was sent
--   selection:readSelectedStylingItemKeys() -> { string }   fresh
--   selection:buildLobbyOutfitPanelModel(lobbySnapshot?, wardrobeCatalogView?) -> model
--   model = { wardrobePanel = <WardrobePanelView model>, confirmFeedbackText, isStoredOutfitSelected,
--             storedOutfitText }

local LobbyRequestAnswerTexts = require("./LobbyRequestAnswerTexts")
local PlayerFacingTexts = require("./PlayerFacingTexts")
local WardrobeSelectionRules = require("./WardrobeSelectionRules")

local LobbyOutfitSelection = {}
LobbyOutfitSelection.__index = LobbyOutfitSelection

LobbyOutfitSelection.LOADING_SAVE_TEXT = "Loading your saved outfit..."
LobbyOutfitSelection.REPLACES_UNAVAILABLE_ITEMS_TEXT =
	"Wearing a new lobby outfit replaces your whole saved outfit, unavailable items included."

local SET_LOBBY_OUTFIT_CHANNEL_NAME = "SetLobbyOutfit"

function LobbyOutfitSelection.new(dependencies)
	return setmetatable({
		stylingItemByStylingItemKey = dependencies.stylingItemByStylingItemKey,
		lobbyRequestSender = dependencies.lobbyRequestSender,
		selectedStylingItemKeys = {},
		selectionRefusalReason = nil,
	}, LobbyOutfitSelection)
end

function LobbyOutfitSelection:restoreStoredOutfit(lobbySnapshot, wardrobeCatalogView)
	self.selectionRefusalReason = nil
	if lobbySnapshot == nil or wardrobeCatalogView == nil then
		self.selectedStylingItemKeys = {}
		return
	end
	self.selectedStylingItemKeys =
		WardrobeSelectionRules.keepOnlyListedStylingItems(lobbySnapshot.lobbyOutfitStylingItemKeys, wardrobeCatalogView)
end

function LobbyOutfitSelection:beginEditing(lobbySnapshot, wardrobeCatalogView)
	self:restoreStoredOutfit(lobbySnapshot, wardrobeCatalogView)
	self.lobbyRequestSender:forgetLatestLobbyRequestOutcome(SET_LOBBY_OUTFIT_CHANNEL_NAME)
end

function LobbyOutfitSelection:clearSelection()
	self.selectedStylingItemKeys = {}
	self.selectionRefusalReason = nil
end

function LobbyOutfitSelection:tapWardrobeItem(stylingItemKey: string, wardrobeCatalogView)
	if wardrobeCatalogView == nil or not wardrobeCatalogView.isWardrobeCatalogReady then
		return nil
	end
	local selectionOutcome = WardrobeSelectionRules.toggleStylingItemInSelection(
		self.selectedStylingItemKeys,
		stylingItemKey,
		wardrobeCatalogView,
		self.stylingItemByStylingItemKey
	)
	self.selectionRefusalReason = selectionOutcome.selectionRefusalReason
	if selectionOutcome.isSelectionChanged then
		self.selectedStylingItemKeys = selectionOutcome.outfitStylingItemKeys
	end
	return selectionOutcome
end

function LobbyOutfitSelection:confirmLobbyOutfit(): boolean
	return self.lobbyRequestSender:sendLobbyRequest(
		SET_LOBBY_OUTFIT_CHANNEL_NAME,
		{ outfitStylingItemKeys = table.clone(self.selectedStylingItemKeys) },
		"lobbyOutfit"
	)
end

function LobbyOutfitSelection:readSelectedStylingItemKeys(): { string }
	return table.clone(self.selectedStylingItemKeys)
end

local function isSameKeySet(firstKeys: { string }, secondKeys: { string }): boolean
	if #firstKeys ~= #secondKeys then
		return false
	end
	for _, key in firstKeys do
		if table.find(secondKeys, key) == nil then
			return false
		end
	end
	return true
end

local function buildSlotGroups(selectedKeys: { string }, wardrobeCatalogView)
	local slotGroups = {}
	for _, wardrobeSlotGroup in wardrobeCatalogView.wardrobeSlotGroups do
		local itemButtons = {}
		for _, wardrobeItem in wardrobeSlotGroup.wardrobeItems do
			table.insert(itemButtons, {
				stylingItemKey = wardrobeItem.stylingItemKey,
				itemNameText = wardrobeItem.itemDisplayName,
				itemPriceText = string.format(
					"%s Robux",
					PlayerFacingTexts.formatWholeNumber(wardrobeItem.priceInRobux)
				),
				isSelected = table.find(selectedKeys, wardrobeItem.stylingItemKey) ~= nil,
				isEnabled = true,
			})
		end
		table.insert(slotGroups, { slotTitleText = wardrobeSlotGroup.itemSlotDisplayName, itemButtons = itemButtons })
	end
	return slotGroups
end

function LobbyOutfitSelection:buildLobbyOutfitPanelModel(lobbySnapshot, wardrobeCatalogView)
	local selectedCount = #self.selectedStylingItemKeys
	local wardrobePanel = {
		isVisible = true,
		isLocked = false,
		wardrobeNoticeText = "",
		savingStatusText = "",
		putBackNoticeText = "",
		selectionRefusalText = if self.selectionRefusalReason ~= nil
			then PlayerFacingTexts.describeSelectionRefusalReason(self.selectionRefusalReason)
			else "",
		selectedItemCountText = if selectedCount == 0
			then "Wearing your own avatar"
			else string.format("Wearing %d item%s", selectedCount, if selectedCount == 1 then "" else "s"),
		slotGroups = {},
	}
	local model = {
		wardrobePanel = wardrobePanel,
		confirmFeedbackText = LobbyRequestAnswerTexts.describeLobbyRequestOutcome(
			self.lobbyRequestSender:readLatestLobbyRequestOutcome(SET_LOBBY_OUTFIT_CHANNEL_NAME)
		),
		isStoredOutfitSelected = false,
		storedOutfitText = "",
	}
	if lobbySnapshot == nil then
		wardrobePanel.wardrobeNoticeText = LobbyOutfitSelection.LOADING_SAVE_TEXT
		return model
	end
	if wardrobeCatalogView == nil or not wardrobeCatalogView.isWardrobeCatalogReady then
		wardrobePanel.wardrobeNoticeText = PlayerFacingTexts.WARDROBE_LOADING_NOTICE
		return model
	end
	if #lobbySnapshot.unavailableLobbyOutfitStylingItemKeys > 0 then
		wardrobePanel.putBackNoticeText = PlayerFacingTexts.UNAVAILABLE_SAVED_OUTFIT_ITEMS_NOTICE
			.. " "
			.. LobbyOutfitSelection.REPLACES_UNAVAILABLE_ITEMS_TEXT
	end
	model.isStoredOutfitSelected = isSameKeySet(self.selectedStylingItemKeys, lobbySnapshot.lobbyOutfitStylingItemKeys)
	model.storedOutfitText = if model.isStoredOutfitSelected then "This is your saved lobby outfit." else ""
	wardrobePanel.slotGroups = buildSlotGroups(self.selectedStylingItemKeys, wardrobeCatalogView)
	return model
end

return LobbyOutfitSelection
