-- A small, clearly fake styling item pool for tests. Every marketplaceItemId starts with 900
-- and is NOT a real Marketplace item or bundle. Covers every item slot, every scoring slot,
-- neutral and non-neutral colours, multi-tag items, disabled rows and one item that is enabled
-- but hidden this server session. Shoes are bundles (spec §1.2); everything else is an asset.
--
-- WORKED_EXAMPLE_STYLING_ITEM_KEYS is the outfit of player 8801 in development spec §0.2 / §1.6.

local StylingItemLookup = require("../../src/shared/StylingItemLookup")

type StylingItem = StylingItemLookup.StylingItem

local function defineFakeStylingItem(
	marketplaceItemId: number,
	itemSlot: string,
	styleTags: { string },
	primaryColorTag: string,
	isEnabled: boolean
): StylingItem
	local marketplaceItemKind = StylingItemLookup.getRequiredMarketplaceItemKindForItemSlot(itemSlot)
	return table.freeze({
		stylingItemKey = StylingItemLookup.deriveStylingItemKey(marketplaceItemKind, marketplaceItemId),
		marketplaceItemKind = marketplaceItemKind,
		marketplaceItemId = marketplaceItemId,
		itemSlot = itemSlot,
		styleTags = table.freeze(styleTags),
		primaryColorTag = primaryColorTag,
		isEnabled = isEnabled,
	})
end

local FakeStylingItemPool = {}

FakeStylingItemPool.FAKE_STYLING_ITEMS = table.freeze({
	defineFakeStylingItem(9000001, "hair", { "y2k" }, "pink", true),
	defineFakeStylingItem(9000002, "hair", { "gothic" }, "black", true),
	defineFakeStylingItem(9000003, "hair", { "cute", "fantasy" }, "purple", true),
	defineFakeStylingItem(9000004, "hair", { "elegant" }, "brown", false),
	defineFakeStylingItem(9000005, "hair", { "sporty" }, "red", true), -- hidden this session

	defineFakeStylingItem(9000011, "top", { "y2k" }, "pink", true),
	defineFakeStylingItem(9000012, "top", { "streetwear", "sporty" }, "blue", true),
	defineFakeStylingItem(9000013, "top", { "formal" }, "white", true),

	defineFakeStylingItem(9000021, "bottom", { "streetwear" }, "black", true),
	defineFakeStylingItem(9000022, "bottom", { "preppy", "retro" }, "green", true),
	defineFakeStylingItem(9000023, "bottom", { "beach" }, "yellow", true),

	defineFakeStylingItem(9000031, "dress", { "elegant", "formal" }, "red", true),
	defineFakeStylingItem(9000032, "dress", { "cute" }, "pink", true),
	defineFakeStylingItem(9000033, "dress", { "fantasy" }, "blue", false),

	defineFakeStylingItem(9000041, "shoes", { "cute" }, "white", true),
	defineFakeStylingItem(9000042, "shoes", { "sporty" }, "orange", true),
	defineFakeStylingItem(9000043, "shoes", { "punk" }, "black", true),

	defineFakeStylingItem(9000051, "accessory", { "y2k" }, "pink", true),
	defineFakeStylingItem(9000052, "accessory", { "retro" }, "yellow", true),
	defineFakeStylingItem(9000053, "accessory", { "gothic" }, "purple", true),
	defineFakeStylingItem(9000054, "accessory", { "beach" }, "orange", true),
	defineFakeStylingItem(9000055, "accessory", { "preppy" }, "green", true),

	defineFakeStylingItem(9000061, "makeup_eyes", { "elegant" }, "beige", true),
	defineFakeStylingItem(9000062, "makeup_eyes", { "y2k", "cute" }, "purple", true),
	defineFakeStylingItem(9000071, "makeup_lips", { "cute" }, "red", true),
	defineFakeStylingItem(9000072, "makeup_lips", { "punk" }, "black", true),
	defineFakeStylingItem(9000081, "makeup_face", { "fantasy" }, "pink", true),
	defineFakeStylingItem(9000091, "eyelashes", { "elegant" }, "black", true),
	defineFakeStylingItem(9000095, "eyebrows", { "retro" }, "brown", true),
})

FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY =
	StylingItemLookup.buildStylingItemByStylingItemKey(FakeStylingItemPool.FAKE_STYLING_ITEMS)

-- Keys that are not in the pool at all, of disabled rows, and of the one enabled item that the
-- fixture marks as hidden this server session (§1.2: lookup failed, off sale or not sellable here).
FakeStylingItemPool.KEY_NOT_IN_POOL = "asset_9099999"
FakeStylingItemPool.BUNDLE_KEY_WITH_ASSET_ID_OF_POOL_ITEM = "bundle_9000001" -- asset_9000001 exists
FakeStylingItemPool.DISABLED_HAIR_KEY = "asset_9000004"
FakeStylingItemPool.DISABLED_DRESS_KEY = "asset_9000033"
FakeStylingItemPool.HIDDEN_HAIR_KEY = "asset_9000005"

-- Every enabled key except HIDDEN_HAIR_KEY. Disabled keys are deliberately absent too, as the
-- server's catalog never lists them.
local function buildFakeAvailableStylingItemKeySet(): { [string]: boolean }
	local availableStylingItemKeySet = {}
	for _, fakeStylingItem in FakeStylingItemPool.FAKE_STYLING_ITEMS do
		if fakeStylingItem.isEnabled and fakeStylingItem.stylingItemKey ~= FakeStylingItemPool.HIDDEN_HAIR_KEY then
			availableStylingItemKeySet[fakeStylingItem.stylingItemKey] = true
		end
	end
	return table.freeze(availableStylingItemKeySet)
end

FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET = buildFakeAvailableStylingItemKeySet()

-- Spec §0.2: y2k pink hair, y2k pink top, streetwear black trousers, cute white shoes (a bundle),
-- y2k pink bag, elegant beige eye makeup.
FakeStylingItemPool.WORKED_EXAMPLE_STYLING_ITEM_KEYS = table.freeze({
	"asset_9000001",
	"asset_9000011",
	"asset_9000021",
	"bundle_9000041",
	"asset_9000051",
	"asset_9000061",
})

-- Enabled, available fake items grouped by item slot, in pool order.
function FakeStylingItemPool.groupAvailableFakeStylingItemsByItemSlot(): { [string]: { StylingItem } }
	local availableStylingItemsByItemSlot: { [string]: { StylingItem } } = {}
	for _, fakeStylingItem in FakeStylingItemPool.FAKE_STYLING_ITEMS do
		if FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET[fakeStylingItem.stylingItemKey] then
			local itemSlot = fakeStylingItem.itemSlot
			availableStylingItemsByItemSlot[itemSlot] = availableStylingItemsByItemSlot[itemSlot] or {}
			table.insert(availableStylingItemsByItemSlot[itemSlot], fakeStylingItem)
		end
	end
	return availableStylingItemsByItemSlot
end

return table.freeze(FakeStylingItemPool)
