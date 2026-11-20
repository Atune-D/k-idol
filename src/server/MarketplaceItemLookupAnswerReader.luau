-- Checks the answers of the injected Marketplace item lookups (the interface is documented in
-- MarketplaceStylingItemResolver.luau) and turns them into plain, trusted tables.
--
-- An answer that does not have the documented shape is treated exactly like a lookup that
-- failed: the resolver retries it and, after the last retry, hides the item. This keeps a
-- half-filled answer from ever reaching the wardrobe catalog or the character dresser.
-- Pure logic: no Roblox-specific interface is used.

local MarketplaceItemLookupAnswerReader = {}

export type MarketplaceItemDetails = {
	itemDisplayName: string,
	priceInRobux: number,
	isOnSale: boolean,
	canBeSoldInThisGame: boolean,
	-- Set for kind "Asset" only: the Roblox asset type of the asset itself.
	robloxAssetTypeName: string?,
}

export type WornAsset = {
	wornAssetId: number,
	robloxAssetTypeName: string,
}

local function isPositiveWholeNumber(candidateNumber: any): boolean
	return type(candidateNumber) == "number"
		and candidateNumber >= 1
		and candidateNumber % 1 == 0
		and candidateNumber ~= math.huge
end

local function isWholeNonNegativeNumber(candidateNumber: any): boolean
	return type(candidateNumber) == "number"
		and candidateNumber >= 0
		and candidateNumber % 1 == 0
		and candidateNumber ~= math.huge
end

local function isNonEmptyString(candidateString: any): boolean
	return type(candidateString) == "string" and candidateString ~= ""
end

-- Returns the checked details, or nil plus a description of what is wrong with the answer.
function MarketplaceItemLookupAnswerReader.readMarketplaceItemDetailsAnswer(
	marketplaceItemKind: string,
	untrustedMarketplaceItemDetails: any
): (MarketplaceItemDetails?, string?)
	if type(untrustedMarketplaceItemDetails) ~= "table" then
		return nil, "the item details answer is not a table"
	end
	local itemDisplayName = untrustedMarketplaceItemDetails.itemDisplayName
	local priceInRobux = untrustedMarketplaceItemDetails.priceInRobux
	local isOnSale = untrustedMarketplaceItemDetails.isOnSale
	local canBeSoldInThisGame = untrustedMarketplaceItemDetails.canBeSoldInThisGame
	local robloxAssetTypeName = untrustedMarketplaceItemDetails.robloxAssetTypeName
	if not isNonEmptyString(itemDisplayName) then
		return nil, "itemDisplayName is not a non-empty string"
	end
	if not isWholeNonNegativeNumber(priceInRobux) then
		return nil, "priceInRobux is not a whole number >= 0"
	end
	if type(isOnSale) ~= "boolean" then
		return nil, "isOnSale is not a boolean"
	end
	if type(canBeSoldInThisGame) ~= "boolean" then
		return nil, "canBeSoldInThisGame is not a boolean"
	end
	if marketplaceItemKind == "Asset" and not isNonEmptyString(robloxAssetTypeName) then
		return nil, "robloxAssetTypeName of an asset is not a non-empty string"
	end
	return {
		itemDisplayName = itemDisplayName,
		priceInRobux = priceInRobux,
		isOnSale = isOnSale,
		canBeSoldInThisGame = canBeSoldInThisGame,
		robloxAssetTypeName = if marketplaceItemKind == "Asset" then robloxAssetTypeName else nil,
	},
		nil
end

-- Returns the bundle's wearable assets in the order the answer lists them, leaving out every
-- entry marked not wearable (the saved-outfit entry, spec §2.14). Returns nil plus a description
-- when the answer is malformed, when a wearable entry lacks its id or asset type, when an asset
-- id repeats, or when nothing in the bundle is wearable (a bundle that dresses nothing cannot be
-- worn, so it counts as contents that failed to load).
function MarketplaceItemLookupAnswerReader.readBundleWornAssetsAnswer(
	untrustedBundleContentEntries: any
): ({ WornAsset }?, string?)
	if type(untrustedBundleContentEntries) ~= "table" then
		return nil, "the bundle contents answer is not a table"
	end
	local wornAssets: { WornAsset } = {}
	local isWornAssetIdAlreadyListed: { [number]: boolean } = {}
	for entryPosition, untrustedBundleContentEntry in ipairs(untrustedBundleContentEntries) do
		if type(untrustedBundleContentEntry) ~= "table" then
			return nil, string.format("bundle content entry %d is not a table", entryPosition)
		end
		local isWearableAsset = untrustedBundleContentEntry.isWearableAsset
		if type(isWearableAsset) ~= "boolean" then
			return nil, string.format("isWearableAsset of bundle content entry %d is not a boolean", entryPosition)
		end
		if isWearableAsset then
			local wornAssetId = untrustedBundleContentEntry.wornAssetId
			local robloxAssetTypeName = untrustedBundleContentEntry.robloxAssetTypeName
			if not isPositiveWholeNumber(wornAssetId) then
				return nil,
					string.format(
						"wornAssetId of bundle content entry %d is not a positive whole number",
						entryPosition
					)
			end
			if not isNonEmptyString(robloxAssetTypeName) then
				return nil,
					string.format(
						"robloxAssetTypeName of bundle content entry %d is not a non-empty string",
						entryPosition
					)
			end
			if isWornAssetIdAlreadyListed[wornAssetId] then
				return nil, string.format("wornAssetId %d is listed twice in the bundle contents", wornAssetId)
			end
			isWornAssetIdAlreadyListed[wornAssetId] = true
			table.insert(wornAssets, { wornAssetId = wornAssetId, robloxAssetTypeName = robloxAssetTypeName })
		end
	end
	if #wornAssets == 0 then
		return nil, "the bundle contains no wearable asset"
	end
	return wornAssets, nil
end

-- Returns the ownership answer, or nil plus a description when it is not a boolean.
function MarketplaceItemLookupAnswerReader.readOwnershipAnswer(untrustedIsOwnedByPlayer: any): (boolean?, string?)
	if type(untrustedIsOwnedByPlayer) ~= "boolean" then
		return nil, "isOwnedByPlayer is not a boolean"
	end
	return untrustedIsOwnedByPlayer, nil
end

return table.freeze(MarketplaceItemLookupAnswerReader)
