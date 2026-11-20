-- GENERATED FILE. DO NOT EDIT BY HAND.
-- Source: data/styling-item-pool.csv. Regenerate with: lune run tools/GenerateStylingItemPool.luau
-- Each entry is one row of the styling item pool (development spec §1.2), in CSV order.
-- stylingItemKey is derived by the tool: asset_<marketplaceItemId> or bundle_<marketplaceItemId>.
-- Disabled rows are kept with isEnabled = false so they stay out of outfits without being lost.

local StylingItemPool = {}

StylingItemPool.STYLING_ITEMS = table.freeze({
	table.freeze({
		stylingItemKey = "asset_7259123616",
		marketplaceItemKind = "Asset",
		marketplaceItemId = 7259123616,
		itemSlot = "hair",
		styleTags = table.freeze({ "streetwear", "punk" }),
		primaryColorTag = "black",
		isEnabled = true,
	}),
	table.freeze({
		stylingItemKey = "asset_9122110415",
		marketplaceItemKind = "Asset",
		marketplaceItemId = 9122110415,
		itemSlot = "top",
		styleTags = table.freeze({ "streetwear", "y2k" }),
		primaryColorTag = "white",
		isEnabled = true,
	}),
	table.freeze({
		stylingItemKey = "asset_9438759973",
		marketplaceItemKind = "Asset",
		marketplaceItemId = 9438759973,
		itemSlot = "dress",
		styleTags = table.freeze({ "cute", "fantasy" }),
		primaryColorTag = "pink",
		isEnabled = true,
	}),
	table.freeze({
		stylingItemKey = "asset_4378579302",
		marketplaceItemKind = "Asset",
		marketplaceItemId = 4378579302,
		itemSlot = "accessory",
		styleTags = table.freeze({ "preppy", "elegant" }),
		primaryColorTag = "black",
		isEnabled = true,
	}),
	table.freeze({
		stylingItemKey = "asset_11884330",
		marketplaceItemKind = "Asset",
		marketplaceItemId = 11884330,
		itemSlot = "accessory",
		styleTags = table.freeze({ "preppy", "retro" }),
		primaryColorTag = "black",
		isEnabled = true,
	}),
	table.freeze({
		stylingItemKey = "bundle_98186475028072",
		marketplaceItemKind = "Bundle",
		marketplaceItemId = 98186475028072,
		itemSlot = "shoes",
		styleTags = table.freeze({ "y2k", "cute" }),
		primaryColorTag = "black",
		isEnabled = true,
	}),
	table.freeze({
		stylingItemKey = "asset_106390919006817",
		marketplaceItemKind = "Asset",
		marketplaceItemId = 106390919006817,
		itemSlot = "makeup_lips",
		styleTags = table.freeze({ "cute", "elegant" }),
		primaryColorTag = "pink",
		isEnabled = true,
	}),
})

return table.freeze(StylingItemPool)
