-- WardrobeCatalogView (development spec §2.14 wardrobe catalog, gate 1H): turns the server's answer
-- to RequestWardrobeCatalogSnapshot into what the wardrobe shows and what the device's selection
-- rules and preview read.
--
-- Gate 1H: the wardrobe lists EXACTLY the items the server's snapshot lists as available, with the
-- server's names and prices, and no other item. Slot and tags are read from the shared styling item
-- pool by stylingItemKey (§2.14 "Slot and tags are not repeated here"). An item the snapshot lists
-- but the device's pool does not know, or knows as disabled, cannot be placed in a slot and is NOT
-- listed; it is reported in `unlistableStylingItemKeys` (it would mean the device and the server run
-- different builds; the server would reject a draft holding it anyway).
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   WardrobeCatalogView.ITEM_SLOT_DISPLAY_ORDER        StylingTagVocabulary.ITEM_SLOTS (wardrobe order)
--   WardrobeCatalogView.ITEM_SLOT_DISPLAY_NAME_BY_ITEM_SLOT   frozen { [itemSlot]: plain words }
--   WardrobeCatalogView.buildWardrobeCatalogView(snapshotAnswer, stylingItemByStylingItemKey) -> view?
--     snapshotAnswer: the RequestWardrobeCatalogSnapshot answer. nil when it is not an accepted
--     answer of the documented shape. A not-ready answer gives a view with isWardrobeCatalogReady =
--     false and no items.
--     view = {
--       isWardrobeCatalogReady: boolean, wardrobeCatalogVersion: number,
--       wardrobeItemByStylingItemKey: { [key]: wardrobeItem },
--       availableStylingItemKeySet: { [key]: true },   exactly the listed items
--       wardrobeSlotGroups: { { itemSlot, itemSlotDisplayName, wardrobeItems = { wardrobeItem } } },
--           only slots that hold an item, in ITEM_SLOT_DISPLAY_ORDER; items in snapshot order
--       listedStylingItemKeys: { key }   every listed key, in slot group order
--       unlistableStylingItemKeys: { key },
--     }
--     wardrobeItem = { stylingItemKey, itemSlot, itemDisplayName, priceInRobux,
--                      wornAssets = { { wornAssetId, robloxAssetTypeName } } }
--   WardrobeCatalogView.readResolvedStylingItemDetailsFromView(view) -> (stylingItemKey) -> { wornAssets }?
--     The worn-asset reader CharacterOutfitAppearancePlanner takes, answering from the snapshot.

local StylingTagVocabulary = require("../shared/StylingTagVocabulary")

local WardrobeCatalogView = {}

-- The §1.1 item slot order, which is also the wardrobe's order.
WardrobeCatalogView.ITEM_SLOT_DISPLAY_ORDER = StylingTagVocabulary.ITEM_SLOTS

WardrobeCatalogView.ITEM_SLOT_DISPLAY_NAME_BY_ITEM_SLOT = table.freeze({
	hair = "Hair",
	top = "Tops",
	bottom = "Bottoms",
	dress = "Dresses",
	shoes = "Shoes",
	accessory = "Accessories (up to 3)",
	makeup_eyes = "Eye makeup",
	makeup_lips = "Lip makeup",
	makeup_face = "Face makeup",
	eyelashes = "Eyelashes",
	eyebrows = "Eyebrows",
})

local function isFiniteNumber(candidate: any): boolean
	return type(candidate) == "number" and candidate == candidate and math.abs(candidate) ~= math.huge
end

local function readWornAssets(candidateWornAssets: any)
	if type(candidateWornAssets) ~= "table" then
		return nil
	end
	local wornAssets = {}
	for listPosition = 1, #candidateWornAssets do
		local wornAsset = candidateWornAssets[listPosition]
		if
			type(wornAsset) ~= "table"
			or not isFiniteNumber(wornAsset.wornAssetId)
			or type(wornAsset.robloxAssetTypeName) ~= "string"
		then
			return nil
		end
		wornAssets[listPosition] =
			{ wornAssetId = wornAsset.wornAssetId, robloxAssetTypeName = wornAsset.robloxAssetTypeName }
	end
	return wornAssets
end

local function readSnapshotItem(snapshotItem: any)
	if type(snapshotItem) ~= "table" or type(snapshotItem.stylingItemKey) ~= "string" then
		return nil
	end
	if type(snapshotItem.itemDisplayName) ~= "string" or not isFiniteNumber(snapshotItem.priceInRobux) then
		return nil
	end
	local wornAssets = readWornAssets(snapshotItem.wornAssets)
	if wornAssets == nil then
		return nil
	end
	return {
		stylingItemKey = snapshotItem.stylingItemKey,
		itemDisplayName = snapshotItem.itemDisplayName,
		priceInRobux = snapshotItem.priceInRobux,
		wornAssets = wornAssets,
	}
end

function WardrobeCatalogView.buildWardrobeCatalogView(snapshotAnswer: any, stylingItemByStylingItemKey)
	if type(snapshotAnswer) ~= "table" or snapshotAnswer.isAccepted ~= true then
		return nil
	end
	if
		type(snapshotAnswer.isWardrobeCatalogReady) ~= "boolean"
		or not isFiniteNumber(snapshotAnswer.wardrobeCatalogVersion)
	then
		return nil
	end
	if type(snapshotAnswer.wardrobeItems) ~= "table" then
		return nil
	end
	local view = {
		isWardrobeCatalogReady = snapshotAnswer.isWardrobeCatalogReady,
		wardrobeCatalogVersion = snapshotAnswer.wardrobeCatalogVersion,
		wardrobeItemByStylingItemKey = {},
		availableStylingItemKeySet = {},
		wardrobeSlotGroups = {},
		listedStylingItemKeys = {},
		unlistableStylingItemKeys = {},
	}
	if not view.isWardrobeCatalogReady then
		return view
	end
	local wardrobeItemsByItemSlot = {}
	for listPosition = 1, #snapshotAnswer.wardrobeItems do
		local wardrobeItem = readSnapshotItem(snapshotAnswer.wardrobeItems[listPosition])
		if wardrobeItem == nil then
			return nil
		end
		local poolItem = stylingItemByStylingItemKey[wardrobeItem.stylingItemKey]
		local isAlreadyListed = view.wardrobeItemByStylingItemKey[wardrobeItem.stylingItemKey] ~= nil
		if poolItem == nil or poolItem.isEnabled ~= true or isAlreadyListed then
			table.insert(view.unlistableStylingItemKeys, wardrobeItem.stylingItemKey)
			continue
		end
		wardrobeItem.itemSlot = poolItem.itemSlot
		view.wardrobeItemByStylingItemKey[wardrobeItem.stylingItemKey] = wardrobeItem
		view.availableStylingItemKeySet[wardrobeItem.stylingItemKey] = true
		wardrobeItemsByItemSlot[poolItem.itemSlot] = wardrobeItemsByItemSlot[poolItem.itemSlot] or {}
		table.insert(wardrobeItemsByItemSlot[poolItem.itemSlot], wardrobeItem)
	end
	for _, itemSlot in WardrobeCatalogView.ITEM_SLOT_DISPLAY_ORDER do
		local slotItems = wardrobeItemsByItemSlot[itemSlot]
		if slotItems ~= nil then
			table.insert(view.wardrobeSlotGroups, {
				itemSlot = itemSlot,
				itemSlotDisplayName = WardrobeCatalogView.ITEM_SLOT_DISPLAY_NAME_BY_ITEM_SLOT[itemSlot],
				wardrobeItems = slotItems,
			})
			for _, slotItem in slotItems do
				table.insert(view.listedStylingItemKeys, slotItem.stylingItemKey)
			end
		end
	end
	return view
end

function WardrobeCatalogView.readResolvedStylingItemDetailsFromView(view)
	return function(stylingItemKey: string)
		local wardrobeItem = view.wardrobeItemByStylingItemKey[stylingItemKey]
		if wardrobeItem == nil then
			return nil
		end
		return { wornAssets = wardrobeItem.wornAssets }
	end
end

return table.freeze(WardrobeCatalogView)
