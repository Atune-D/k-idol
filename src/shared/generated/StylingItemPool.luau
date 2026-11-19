-- GENERATED FILE. DO NOT EDIT BY HAND.
-- Source: data/styling-item-pool.csv. Regenerate with: lune run tools/GenerateStylingItemPool.luau
-- Each entry is one row of the styling item pool (development spec §1.2), in CSV order.
-- stylingItemKey is derived by the tool: asset_<marketplaceItemId> or bundle_<marketplaceItemId>.
-- Disabled rows are kept with isEnabled = false so they stay out of outfits without being lost.

local StylingItemPool = {}

StylingItemPool.STYLING_ITEMS = table.freeze({})

return table.freeze(StylingItemPool)
