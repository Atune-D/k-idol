-- RobloxMarketplaceAnswerConverter: turns the raw dictionaries Roblox returns for a Marketplace
-- item into the answer shapes of the MarketplaceItemLookups interface (documented at the top of
-- MarketplaceStylingItemResolver.luau). Pure logic: the engine answer is a parameter, so the Lune
-- tests feed it the answers captured in Studio (tests/fixtures/CapturedRobloxMarketplaceAnswers.luau).
--
-- Any answer that is not shaped as documented is reported as a problem (the lookup then counts as
-- failed and the resolver retries, then hides the item); nothing is guessed.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (used by RobloxMarketplaceItemLookups)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer(marketplaceItemKind,
--     requestedMarketplaceItemId, rawAvatarItemDetails) -> (MarketplaceItemDetails?, problemDescription: string?)
--   rawAvatarItemDetails: what AvatarEditorService:GetItemDetailsAsync returned for that id.
--   Requires ItemType == marketplaceItemKind, Id == the requested id, a non-empty Name, Price a
--   whole number >= 0, IsPurchasable a boolean, SaleLocationType a string, ItemRestrictions an
--   array of strings, PriceStatus absent or a string and, for an asset, a non-empty AssetType. Then:
--     itemDisplayName = Name, priceInRobux = Price,
--     isOnSale = IsPurchasable is true AND PriceStatus is not "Off Sale" AND ItemRestrictions is
--         empty (the page: empty = unlimited; "Collectible", "Limited", "LimitedUnique" = limiteds;
--         any other, unknown value also counts as a limited),
--     canBeSoldInThisGame = (SaleLocationType == "ShopAndAllExperiences"); every other sale
--         location, known or not, is false (see SALE_LOCATION_TYPE_SELLABLE_IN_EVERY_GAME),
--     robloxAssetTypeName = AssetType (kind "Asset" only).
--   Why three signals for isOnSale: the page documents IsPurchasable as "whether the item can be
--   purchased by the current user", and a game server has no current user. Observed on a playtest
--   server (Studio 0.748, 2026-11-19; answers in tests/fixtures/CapturedRobloxMarketplaceAnswers):
--   the off-sale "ROBLOX Girl - Hair" (48474294) answered IsPurchasable=false, PriceStatus="Off
--   Sale", Price=0; but off-sale Roblox Limiteds (1029025, 21070012) answered IsPurchasable=true
--   with Price = their old shop price (900, 13337) while they can only be bought from resellers
--   (LowestPrice 449999, 618033988). A limited's Price is therefore not what a purchase costs, so
--   a limited of any kind counts as not on sale here (spec gap, listed for the owner).
-- RobloxMarketplaceAnswerConverter.convertBundleDetailsAnswer(requestedBundleId, rawBundleDetails)
--     -> (bundleContentEntries?, problemDescription: string?)
--   rawBundleDetails: what AssetService:GetBundleDetailsAsync returned. Requires Id == the
--   requested id and an Items array. Each item with Type "Asset" becomes
--   { isWearableAsset = true, wornAssetId = Id, robloxAssetTypeName = AssetType } and must have a
--   positive whole Id and a non-empty AssetType (otherwise the whole answer is a problem); any
--   other Type (the "UserOutfit" saved-outfit entry) becomes { isWearableAsset = false }.
--   Entries keep Roblox's order.
-- RobloxMarketplaceAnswerConverter.SALE_LOCATION_TYPE_SELLABLE_IN_EVERY_GAME = "ShopAndAllExperiences"
-- RobloxMarketplaceAnswerConverter.OFF_SALE_PRICE_STATUS = "Off Sale"
--
-- Field names and meanings were read on
--   https://create.roblox.com/docs/reference/engine/classes/AvatarEditorService ("Item Details
--   Response": PriceStatus, ItemRestrictions; GetItemDetailsAsync: Owned, IsPurchasable;
--   "SaleLocationType Values"; "itemRestrictions Values")
--   https://create.roblox.com/docs/reference/engine/classes/AssetService (GetBundleDetailsAsync)
-- and checked against the engine in Studio 0.748 on 2026-11-19. Differences from the pages:
-- PriceStatus, listed in the response format, was absent from every on-sale answer (present as
-- "Off Sale" on the off-sale one); an undocumented IsOffSale field was true on every off-sale
-- answer and absent otherwise (not used: undocumented); GetBundleDetailsAsync
-- also returned PriceDiscountDetails and UserBasePriceInRobux, which the page does not list (unused).

local RobloxMarketplaceAnswerConverter = {}

-- Spec §1.2: only items whose creator allows sale in all experiences can be bought here. The
-- documented values ShopOnly, MyExperiencesOnly, ShopAndMyExperiences, ExperiencesById and
-- ShopAndExperiencesById restrict sale to the shop, the creator's own games or listed games.
-- ExperiencesDevApiOnly ("can only be purchased in experiences via developer APIs") may well
-- include an in-game purchase prompt; it is excluded DELIBERATELY because no purchase of such an
-- item has been confirmed in this game yet (owner to confirm; the error is towards hiding).
RobloxMarketplaceAnswerConverter.SALE_LOCATION_TYPE_SELLABLE_IN_EVERY_GAME = "ShopAndAllExperiences"
RobloxMarketplaceAnswerConverter.OFF_SALE_PRICE_STATUS = "Off Sale"

export type MarketplaceItemDetails = {
	itemDisplayName: string,
	priceInRobux: number,
	isOnSale: boolean,
	canBeSoldInThisGame: boolean,
	robloxAssetTypeName: string?,
}

export type BundleContentEntry = {
	isWearableAsset: boolean,
	wornAssetId: number?,
	robloxAssetTypeName: string?,
}

-- Infinity and NaN fail `% 1 == 0` (math.huge % 1 is NaN), so they need no test of their own.
local function isWholeNumberAtLeast(candidateNumber: any, smallestAllowedNumber: number): boolean
	return type(candidateNumber) == "number" and candidateNumber >= smallestAllowedNumber and candidateNumber % 1 == 0
end

local function isNonEmptyString(candidateString: any): boolean
	return type(candidateString) == "string" and candidateString ~= ""
end

local function isArrayOfStrings(candidateArray: any): boolean
	if type(candidateArray) ~= "table" then
		return false
	end
	local elementCount = 0
	for _ in candidateArray do
		elementCount += 1
	end
	if elementCount ~= #candidateArray then
		return false
	end
	for _, candidateElement in ipairs(candidateArray) do
		if type(candidateElement) ~= "string" then
			return false
		end
	end
	return true
end

function RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer(
	marketplaceItemKind: string,
	requestedMarketplaceItemId: number,
	rawAvatarItemDetails: any
): (MarketplaceItemDetails?, string?)
	if type(rawAvatarItemDetails) ~= "table" then
		return nil, "the avatar item details answer is not a table"
	end
	if rawAvatarItemDetails.ItemType ~= marketplaceItemKind then
		return nil,
			string.format("ItemType is %s, expected %s", tostring(rawAvatarItemDetails.ItemType), marketplaceItemKind)
	end
	if rawAvatarItemDetails.Id ~= requestedMarketplaceItemId then
		return nil,
			string.format(
				"Id is %s, expected %s",
				tostring(rawAvatarItemDetails.Id),
				tostring(requestedMarketplaceItemId)
			)
	end
	if not isNonEmptyString(rawAvatarItemDetails.Name) then
		return nil, "Name is not a non-empty string"
	end
	if not isWholeNumberAtLeast(rawAvatarItemDetails.Price, 0) then
		return nil, "Price is not a whole number >= 0"
	end
	if type(rawAvatarItemDetails.IsPurchasable) ~= "boolean" then
		return nil, "IsPurchasable is not a boolean"
	end
	if type(rawAvatarItemDetails.SaleLocationType) ~= "string" then
		return nil, "SaleLocationType is not a string"
	end
	if not isArrayOfStrings(rawAvatarItemDetails.ItemRestrictions) then
		return nil, "ItemRestrictions is not an array of strings"
	end
	if rawAvatarItemDetails.PriceStatus ~= nil and type(rawAvatarItemDetails.PriceStatus) ~= "string" then
		return nil, "PriceStatus is neither absent nor a string"
	end
	local isAsset = marketplaceItemKind == "Asset"
	if isAsset and not isNonEmptyString(rawAvatarItemDetails.AssetType) then
		return nil, "AssetType of an asset is not a non-empty string"
	end
	return {
		itemDisplayName = rawAvatarItemDetails.Name,
		priceInRobux = rawAvatarItemDetails.Price,
		isOnSale = rawAvatarItemDetails.IsPurchasable
			and rawAvatarItemDetails.PriceStatus ~= RobloxMarketplaceAnswerConverter.OFF_SALE_PRICE_STATUS
			and #rawAvatarItemDetails.ItemRestrictions == 0,
		canBeSoldInThisGame = rawAvatarItemDetails.SaleLocationType
			== RobloxMarketplaceAnswerConverter.SALE_LOCATION_TYPE_SELLABLE_IN_EVERY_GAME,
		robloxAssetTypeName = if isAsset then rawAvatarItemDetails.AssetType else nil,
	},
		nil
end

function RobloxMarketplaceAnswerConverter.convertBundleDetailsAnswer(
	requestedBundleId: number,
	rawBundleDetails: any
): ({ BundleContentEntry }?, string?)
	if type(rawBundleDetails) ~= "table" then
		return nil, "the bundle details answer is not a table"
	end
	if rawBundleDetails.Id ~= requestedBundleId then
		return nil, string.format("Id is %s, expected %s", tostring(rawBundleDetails.Id), tostring(requestedBundleId))
	end
	if type(rawBundleDetails.Items) ~= "table" then
		return nil, "Items is not a table"
	end
	local bundleContentEntries: { BundleContentEntry } = {}
	for itemPosition, rawBundleItem in ipairs(rawBundleDetails.Items) do
		if type(rawBundleItem) ~= "table" or type(rawBundleItem.Type) ~= "string" then
			return nil, string.format("bundle item %d has no Type", itemPosition)
		end
		if rawBundleItem.Type == "Asset" then
			if not isWholeNumberAtLeast(rawBundleItem.Id, 1) then
				return nil, string.format("bundle item %d is an asset without a positive whole Id", itemPosition)
			end
			if not isNonEmptyString(rawBundleItem.AssetType) then
				return nil, string.format("bundle item %d is an asset without an AssetType", itemPosition)
			end
			table.insert(bundleContentEntries, {
				isWearableAsset = true,
				wornAssetId = rawBundleItem.Id,
				robloxAssetTypeName = rawBundleItem.AssetType,
			})
		else
			table.insert(bundleContentEntries, { isWearableAsset = false })
		end
	end
	return bundleContentEntries, nil
end

return table.freeze(RobloxMarketplaceAnswerConverter)
