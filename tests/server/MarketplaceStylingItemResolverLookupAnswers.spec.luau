-- How MarketplaceItemLookupAnswerReader checks the answers of the injected Roblox lookups: an
-- answer of the wrong shape must count as a failed lookup, never reach the wardrobe catalog.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeMarketplaceItemLookups = require("../Support/FakeMarketplaceItemLookups")
local MarketplaceItemLookupAnswerReader = require("../../src/server/MarketplaceItemLookupAnswerReader")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function buildAssetDetailsWith(changedFieldName: string, changedFieldValue: any)
	local itemDetails = FakeMarketplaceItemLookups.buildOnSaleSellableItemDetails("Asset", 9000001)
	itemDetails[changedFieldName] = changedFieldValue
	return itemDetails
end

describe("MarketplaceStylingItemResolver lookup answers: item details", function()
	it("accepts well-formed details of an asset and of a bundle, a free item included", function()
		local assetDetails, assetProblem = MarketplaceItemLookupAnswerReader.readMarketplaceItemDetailsAnswer(
			"Asset",
			buildAssetDetailsWith("priceInRobux", 0)
		)
		expect(assetProblem).toBeNil()
		expect(assetDetails).toEqual({
			itemDisplayName = "Fake Asset 9000001",
			priceInRobux = 0,
			isOnSale = true,
			canBeSoldInThisGame = true,
			robloxAssetTypeName = FakeMarketplaceItemLookups.FAKE_ASSET_TYPE_NAME,
		})
		local bundleDetails = MarketplaceItemLookupAnswerReader.readMarketplaceItemDetailsAnswer(
			"Bundle",
			FakeMarketplaceItemLookups.buildOnSaleSellableItemDetails("Bundle", 9000041)
		)
		expect(bundleDetails and bundleDetails.robloxAssetTypeName).toBeNil()
		expect(bundleDetails and bundleDetails.priceInRobux).toBe(41)
	end)

	it("rejects details with a missing or wrongly typed field", function()
		local malformedFieldCases = {
			{ "itemDisplayName", nil },
			{ "itemDisplayName", "" },
			{ "priceInRobux", nil },
			{ "priceInRobux", -1 },
			{ "priceInRobux", 1.5 },
			{ "priceInRobux", math.huge },
			{ "isOnSale", nil },
			{ "isOnSale", "true" },
			{ "canBeSoldInThisGame", nil },
			{ "canBeSoldInThisGame", 1 },
			{ "robloxAssetTypeName", nil },
			{ "robloxAssetTypeName", "" },
		}
		for _, malformedFieldCase in malformedFieldCases do
			local itemDetails, problemDescription = MarketplaceItemLookupAnswerReader.readMarketplaceItemDetailsAnswer(
				"Asset",
				buildAssetDetailsWith(malformedFieldCase[1], malformedFieldCase[2])
			)
			expect(itemDetails).toBeNil()
			expect(string.find(problemDescription :: string, malformedFieldCase[1], 1, true) ~= nil).toBeTrue()
		end
		expect(MarketplaceItemLookupAnswerReader.readMarketplaceItemDetailsAnswer("Asset", "details")).toBeNil()
	end)
end)

describe("MarketplaceStylingItemResolver lookup answers: bundle contents", function()
	it("keeps the wearable assets in order and leaves out every non-wearable entry", function()
		local wornAssets = MarketplaceItemLookupAnswerReader.readBundleWornAssetsAnswer({
			{ isWearableAsset = false },
			{ isWearableAsset = true, wornAssetId = 11, robloxAssetTypeName = "FakeLeft" },
			{ isWearableAsset = false, wornAssetId = 19, robloxAssetTypeName = "FakeOutfit" },
			{ isWearableAsset = true, wornAssetId = 12, robloxAssetTypeName = "FakeRight" },
		})
		expect(wornAssets).toEqual({
			{ wornAssetId = 11, robloxAssetTypeName = "FakeLeft" },
			{ wornAssetId = 12, robloxAssetTypeName = "FakeRight" },
		})
	end)

	it("rejects malformed contents, a repeated asset and contents with nothing wearable", function()
		local malformedContentsCases = {
			"contents",
			{ "entry" },
			{ { isWearableAsset = "yes", wornAssetId = 11, robloxAssetTypeName = "FakeLeft" } },
			{ { isWearableAsset = true, robloxAssetTypeName = "FakeLeft" } },
			{ { isWearableAsset = true, wornAssetId = 0, robloxAssetTypeName = "FakeLeft" } },
			{ { isWearableAsset = true, wornAssetId = 11 } },
			{
				{ isWearableAsset = true, wornAssetId = 11, robloxAssetTypeName = "FakeLeft" },
				{ isWearableAsset = true, wornAssetId = 11, robloxAssetTypeName = "FakeLeft" },
			},
			{},
			{ { isWearableAsset = false, wornAssetId = 19 } },
		}
		for _, malformedContents in malformedContentsCases do
			local wornAssets, problemDescription =
				MarketplaceItemLookupAnswerReader.readBundleWornAssetsAnswer(malformedContents)
			expect(wornAssets).toBeNil()
			expect(type(problemDescription)).toBe("string")
		end
	end)
end)

describe("MarketplaceStylingItemResolver lookup answers: ownership", function()
	it("accepts only a boolean", function()
		expect(MarketplaceItemLookupAnswerReader.readOwnershipAnswer(true)).toBe(true)
		expect(MarketplaceItemLookupAnswerReader.readOwnershipAnswer(false)).toBe(false)
		for _, malformedOwnership in { "true", 1, {} } :: { any } do
			expect(MarketplaceItemLookupAnswerReader.readOwnershipAnswer(malformedOwnership)).toBeNil()
		end
		expect(MarketplaceItemLookupAnswerReader.readOwnershipAnswer(nil)).toBeNil()
	end)
end)
