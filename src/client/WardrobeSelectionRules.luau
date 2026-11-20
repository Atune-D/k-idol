-- WardrobeSelectionRules (development spec §1.5 outfit validity, §2.14 "the device must show exactly
-- that set"): what tapping an item in the wardrobe does to the current selection, so that the
-- selection is ALWAYS a valid outfit made only of items the server's catalog lists.
--
-- Tapping an item:
--   * that is selected removes it;
--   * that the catalog view does not list is refused (NotInWardrobe), the selection unchanged;
--   * in a single-item slot (§1.5 rule 3) replaces the item already in that slot;
--   * that is a dress removes any top and any bottom; a top or a bottom removes any dress (rule 5);
--   * that is a fourth accessory is refused (AccessoryLimitReached): the device never chooses for the
--     player which accessory to drop.
--   Selected items the catalog view no longer lists are dropped by any accepted tap.
-- The result is then checked with the shared OutfitValidator against the catalog's available set;
-- if it is somehow not valid, the tap is refused (WouldNotBeValidOutfit) and nothing changes.
-- Pure logic: no Roblox-specific interface is used; every list returned is fresh.
--
-- PUBLIC API
--   WardrobeSelectionRules.SELECTION_REFUSAL_REASONS   frozen
--   WardrobeSelectionRules.toggleStylingItemInSelection(currentStylingItemKeys, tappedStylingItemKey,
--       wardrobeCatalogView, stylingItemByStylingItemKey) -> selectionOutcome
--     selectionOutcome = { isSelectionChanged, outfitStylingItemKeys (fresh), removedStylingItemKeys,
--                          selectionRefusalReason? }
--   WardrobeSelectionRules.keepOnlyListedStylingItems(currentStylingItemKeys, wardrobeCatalogView)
--       -> { string }   the selection without items the (new) catalog no longer lists, order kept

local OutfitValidator = require("../shared/OutfitValidator")

local WardrobeSelectionRules = {}

WardrobeSelectionRules.SELECTION_REFUSAL_REASONS = table.freeze({
	NotInWardrobe = "NotInWardrobe",
	AccessoryLimitReached = "AccessoryLimitReached",
	WouldNotBeValidOutfit = "WouldNotBeValidOutfit",
})

local REFUSALS = WardrobeSelectionRules.SELECTION_REFUSAL_REASONS
local ACCESSORY_ITEM_SLOT = "accessory"

-- The slots a newly selected item pushes out, besides its own single slot.
local DISPLACED_ITEM_SLOTS_BY_ITEM_SLOT = table.freeze({
	dress = table.freeze({ top = true, bottom = true }),
	top = table.freeze({ dress = true }),
	bottom = table.freeze({ dress = true }),
})

local isSingleItemSlot: { [string]: boolean } = {}
for _, singleItemSlot in OutfitValidator.SINGLE_ITEM_SLOTS do
	isSingleItemSlot[singleItemSlot] = true
end

local function refuse(currentStylingItemKeys: { string }, selectionRefusalReason: string)
	return {
		isSelectionChanged = false,
		outfitStylingItemKeys = table.clone(currentStylingItemKeys),
		removedStylingItemKeys = {},
		selectionRefusalReason = selectionRefusalReason,
	}
end

local function readItemSlot(wardrobeCatalogView, stylingItemKey: string): string?
	local wardrobeItem = wardrobeCatalogView.wardrobeItemByStylingItemKey[stylingItemKey]
	return if wardrobeItem ~= nil then wardrobeItem.itemSlot else nil
end

function WardrobeSelectionRules.toggleStylingItemInSelection(
	currentStylingItemKeys: { string },
	tappedStylingItemKey: string,
	wardrobeCatalogView,
	stylingItemByStylingItemKey
)
	if table.find(currentStylingItemKeys, tappedStylingItemKey) ~= nil then
		local remainingKeys = table.clone(currentStylingItemKeys)
		table.remove(remainingKeys, table.find(remainingKeys, tappedStylingItemKey))
		return {
			isSelectionChanged = true,
			outfitStylingItemKeys = remainingKeys,
			removedStylingItemKeys = { tappedStylingItemKey },
		}
	end
	local tappedItemSlot = readItemSlot(wardrobeCatalogView, tappedStylingItemKey)
	if tappedItemSlot == nil then
		return refuse(currentStylingItemKeys, REFUSALS.NotInWardrobe)
	end
	local displacedItemSlots = DISPLACED_ITEM_SLOTS_BY_ITEM_SLOT[tappedItemSlot] or {}
	local keptKeys, removedKeys, keptAccessoryCount = {}, {}, 0
	for _, selectedKey in currentStylingItemKeys do
		local selectedItemSlot = readItemSlot(wardrobeCatalogView, selectedKey)
		local isPushedOut = selectedItemSlot == nil
			or displacedItemSlots[selectedItemSlot] == true
			or (selectedItemSlot == tappedItemSlot and isSingleItemSlot[tappedItemSlot] == true)
		if isPushedOut then
			table.insert(removedKeys, selectedKey)
		else
			table.insert(keptKeys, selectedKey)
			if selectedItemSlot == ACCESSORY_ITEM_SLOT then
				keptAccessoryCount += 1
			end
		end
	end
	if tappedItemSlot == ACCESSORY_ITEM_SLOT and keptAccessoryCount >= OutfitValidator.MAX_ACCESSORY_ITEM_COUNT then
		return refuse(currentStylingItemKeys, REFUSALS.AccessoryLimitReached)
	end
	table.insert(keptKeys, tappedStylingItemKey)
	local verdict = OutfitValidator.validateOutfit(
		keptKeys,
		stylingItemByStylingItemKey,
		wardrobeCatalogView.availableStylingItemKeySet
	)
	if not verdict.isOutfitValid then
		return refuse(currentStylingItemKeys, REFUSALS.WouldNotBeValidOutfit)
	end
	return { isSelectionChanged = true, outfitStylingItemKeys = keptKeys, removedStylingItemKeys = removedKeys }
end

function WardrobeSelectionRules.keepOnlyListedStylingItems(currentStylingItemKeys: { string }, wardrobeCatalogView)
	local keptKeys = {}
	for _, selectedKey in currentStylingItemKeys do
		if wardrobeCatalogView.availableStylingItemKeySet[selectedKey] == true then
			table.insert(keptKeys, selectedKey)
		end
	end
	return keptKeys
end

return table.freeze(WardrobeSelectionRules)
