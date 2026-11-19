-- The shape of one styling item (development spec §1.2), how its `stylingItemKey` is derived,
-- which Marketplace item kind each item slot must use, and a lookup table from
-- `stylingItemKey` to the item.
--
-- OutfitValidator, OutfitScoreCalculator and StoredLobbyOutfitResolver take the lookup as an
-- argument instead of requiring the generated pool, so tests can pass fixture pools. The item
-- pool tool (tools/StylingItemPoolCsvCompiler.luau) uses the same key derivation and kind rule,
-- so the tool and the game can never disagree about them.
-- Pure logic: no Roblox-specific interface is used.

export type StylingItem = {
	stylingItemKey: string,
	marketplaceItemKind: string, -- "Asset" or "Bundle"
	marketplaceItemId: number,
	itemSlot: string,
	styleTags: { string },
	primaryColorTag: string,
	isEnabled: boolean,
}

export type StylingItemByStylingItemKey = { [string]: StylingItem }

-- The keys of the styling items that are available (not hidden) this server session (§1.2).
-- Only `true` counts as available.
export type AvailableStylingItemKeySet = { [string]: boolean }

local StylingItemLookup = {}

StylingItemLookup.MARKETPLACE_ITEM_KINDS = table.freeze({
	Asset = "Asset",
	Bundle = "Bundle",
})

-- §1.2: a `shoes` row must be a Bundle (a pair of shoes is one bundle of a left and a right
-- shoe); a row in any other slot must be an Asset (§8: until the Phase 1 trial, only shoes may
-- be bundles).
StylingItemLookup.ITEM_SLOT_REQUIRING_BUNDLE = "shoes"

local STYLING_ITEM_KEY_PREFIX_BY_MARKETPLACE_ITEM_KIND = table.freeze({
	Asset = "asset_",
	Bundle = "bundle_",
})

function StylingItemLookup.isKnownMarketplaceItemKind(candidateMarketplaceItemKind: any): boolean
	return type(candidateMarketplaceItemKind) == "string"
		and STYLING_ITEM_KEY_PREFIX_BY_MARKETPLACE_ITEM_KIND[candidateMarketplaceItemKind] ~= nil
end

-- The kind a row in this item slot must have: "Bundle" for shoes, "Asset" for every other slot.
function StylingItemLookup.getRequiredMarketplaceItemKindForItemSlot(itemSlot: string): string
	if itemSlot == StylingItemLookup.ITEM_SLOT_REQUIRING_BUNDLE then
		return StylingItemLookup.MARKETPLACE_ITEM_KINDS.Bundle
	end
	return StylingItemLookup.MARKETPLACE_ITEM_KINDS.Asset
end

-- §1.2: `asset_<marketplaceItemId>` or `bundle_<marketplaceItemId>`. The id must be a positive
-- whole number; anything else is a programming error and raises.
function StylingItemLookup.deriveStylingItemKey(marketplaceItemKind: string, marketplaceItemId: number): string
	local stylingItemKeyPrefix = STYLING_ITEM_KEY_PREFIX_BY_MARKETPLACE_ITEM_KIND[marketplaceItemKind]
	if stylingItemKeyPrefix == nil then
		error(string.format("StylingItemLookup: unknown marketplaceItemKind %q", tostring(marketplaceItemKind)), 2)
	end
	if
		type(marketplaceItemId) ~= "number"
		or marketplaceItemId < 1
		or marketplaceItemId ~= math.floor(marketplaceItemId)
		or marketplaceItemId == math.huge
	then
		error(
			string.format(
				"StylingItemLookup: marketplaceItemId %s is not a positive whole number",
				tostring(marketplaceItemId)
			),
			2
		)
	end
	return stylingItemKeyPrefix .. string.format("%d", marketplaceItemId)
end

-- Builds a frozen map from `stylingItemKey` to its item. Disabled items are included, so callers
-- can tell "disabled" from "not in the pool". Raises on a duplicated key or on a key that does
-- not match the item's kind and id, because the tool already rejects both and either one here
-- means the pool was edited by hand.
function StylingItemLookup.buildStylingItemByStylingItemKey(stylingItems: { StylingItem }): StylingItemByStylingItemKey
	local stylingItemByStylingItemKey = {}
	for _, stylingItem in stylingItems do
		local stylingItemKey = stylingItem.stylingItemKey
		local expectedStylingItemKey =
			StylingItemLookup.deriveStylingItemKey(stylingItem.marketplaceItemKind, stylingItem.marketplaceItemId)
		if stylingItemKey ~= expectedStylingItemKey then
			error(
				string.format(
					"StylingItemLookup: stylingItemKey %q does not match its kind and id (expected %q)",
					tostring(stylingItemKey),
					expectedStylingItemKey
				),
				2
			)
		end
		if stylingItemByStylingItemKey[stylingItemKey] ~= nil then
			error(
				string.format(
					"StylingItemLookup: stylingItemKey %q appears more than once in the styling item pool",
					stylingItemKey
				),
				2
			)
		end
		stylingItemByStylingItemKey[stylingItemKey] = stylingItem
	end
	return table.freeze(stylingItemByStylingItemKey)
end

return table.freeze(StylingItemLookup)
