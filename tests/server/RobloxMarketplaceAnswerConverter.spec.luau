-- Unit: RobloxMarketplaceAnswerConverter, fed the real engine answers captured in Studio.

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local CapturedRobloxMarketplaceAnswers = require("../fixtures/CapturedRobloxMarketplaceAnswers")
local RobloxMarketplaceAnswerConverter = require("../../src/server/RobloxMarketplaceAnswerConverter")
local MarketplaceItemLookupAnswerReader = require("../../src/server/MarketplaceItemLookupAnswerReader")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local CAPTURED_DETAILS = CapturedRobloxMarketplaceAnswers.AVATAR_ITEM_DETAILS_BY_KIND_AND_ID
local HAIR_ASSET_ID = 7259123616
local SHOES_BUNDLE_ID = 98186475028072

local function copyCapturedDetails(marketplaceItemKind: string, marketplaceItemId: number)
	return CapturedRobloxMarketplaceAnswers.copyAnswer(CAPTURED_DETAILS[marketplaceItemKind][marketplaceItemId])
end

local function copyCapturedBundleDetails()
	return CapturedRobloxMarketplaceAnswers.copyAnswer(
		CapturedRobloxMarketplaceAnswers.BUNDLE_DETAILS_BY_BUNDLE_ID[SHOES_BUNDLE_ID]
	)
end

local function expectProblemContaining(convertedAnswer, problemDescription, expectedFragment: string)
	expect(convertedAnswer).toBeNil()
	if type(problemDescription) ~= "string" or not string.find(problemDescription, expectedFragment, 1, true) then
		expect(problemDescription).toBe(expectedFragment)
	end
end

describe("RobloxMarketplaceAnswerConverter item details (captured answers)", function()
	it("converts every captured asset answer into the interface shape", function()
		local expectedAssetTypeById = {
			[7259123616] = "HairAccessory",
			[9122110415] = "JacketAccessory",
			[9438759973] = "DressSkirtAccessory",
			[4378579302] = "NeckAccessory",
			[11884330] = "FaceAccessory",
			[106390919006817] = "LipMakeup",
		}
		for assetId, capturedAnswer in CAPTURED_DETAILS.Asset do
			local itemDetails, problemDescription =
				RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer("Asset", assetId, capturedAnswer)
			expect(problemDescription).toBeNil()
			expect(itemDetails).toEqual({
				itemDisplayName = capturedAnswer.Name,
				priceInRobux = capturedAnswer.Price,
				isOnSale = true,
				canBeSoldInThisGame = true,
				robloxAssetTypeName = expectedAssetTypeById[assetId],
			})
		end
	end)

	it("converts the captured bundle answer without an asset type", function()
		local itemDetails = RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer(
			"Bundle",
			SHOES_BUNDLE_ID,
			copyCapturedDetails("Bundle", SHOES_BUNDLE_ID)
		)
		expect(itemDetails).toEqual({
			itemDisplayName = "Y2K Fur Boots",
			priceInRobux = 60,
			isOnSale = true,
			canBeSoldInThisGame = true,
		})
	end)

	it("never gives a bundle an asset type, even when the answer carries one", function()
		local rawAnswer = copyCapturedDetails("Bundle", SHOES_BUNDLE_ID)
		rawAnswer.AssetType = "Hat"
		local itemDetails =
			RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer("Bundle", SHOES_BUNDLE_ID, rawAnswer)
		expect(itemDetails.robloxAssetTypeName).toBeNil()
	end)

	it("reports IsPurchasable false as not on sale (an answer, not a problem)", function()
		local rawAnswer = copyCapturedDetails("Asset", HAIR_ASSET_ID)
		rawAnswer.IsPurchasable = false
		local itemDetails =
			RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer("Asset", HAIR_ASSET_ID, rawAnswer)
		expect(itemDetails.isOnSale).toBeFalse()
		expect(itemDetails.canBeSoldInThisGame).toBeTrue()
	end)

	it("reports each captured off-sale item as not on sale", function()
		for assetId, capturedAnswer in CapturedRobloxMarketplaceAnswers.OFF_SALE_AVATAR_ITEM_DETAILS_BY_ASSET_ID do
			local itemDetails, problemDescription = RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer(
				"Asset",
				assetId,
				CapturedRobloxMarketplaceAnswers.copyAnswer(capturedAnswer)
			)
			expect(problemDescription).toBeNil()
			expect(itemDetails.isOnSale).toBeFalse()
		end
	end)

	it("reports PriceStatus Off Sale as not on sale even when IsPurchasable is true", function()
		local rawAnswer = copyCapturedDetails("Asset", HAIR_ASSET_ID)
		rawAnswer.PriceStatus = "Off Sale"
		local itemDetails =
			RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer("Asset", HAIR_ASSET_ID, rawAnswer)
		expect(itemDetails.isOnSale).toBeFalse()
		rawAnswer.PriceStatus = "Free"
		expect(
			RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer("Asset", HAIR_ASSET_ID, rawAnswer).isOnSale
		).toBeTrue()
	end)

	it(
		"reports a limited of any kind (any item restriction) as not on sale, even when IsPurchasable is true",
		function()
			for _, itemRestriction in { "Limited", "LimitedUnique", "Collectible", "SomeFutureRestriction" } do
				local rawAnswer = copyCapturedDetails("Asset", HAIR_ASSET_ID)
				rawAnswer.ItemRestrictions = { itemRestriction }
				local itemDetails =
					RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer("Asset", HAIR_ASSET_ID, rawAnswer)
				expect(itemDetails.isOnSale).toBeFalse()
			end
		end
	)

	it("reports every documented sale location other than ShopAndAllExperiences as not sellable here", function()
		for _, saleLocationType in
			{
				"NotApplicable",
				"ShopOnly",
				"MyExperiencesOnly",
				"ShopAndMyExperiences",
				"ExperiencesById",
				"ExperiencesDevApiOnly",
				"ShopAndExperiencesById",
				"SomeFutureValue",
			}
		do
			local rawAnswer = copyCapturedDetails("Asset", HAIR_ASSET_ID)
			rawAnswer.SaleLocationType = saleLocationType
			local itemDetails =
				RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer("Asset", HAIR_ASSET_ID, rawAnswer)
			expect(itemDetails.canBeSoldInThisGame).toBeFalse()
			expect(itemDetails.isOnSale).toBeTrue()
		end
	end)

	it("rejects an answer that is not a table", function()
		local itemDetails, problemDescription =
			RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer("Asset", HAIR_ASSET_ID, "nope")
		expectProblemContaining(itemDetails, problemDescription, "not a table")
	end)

	it("rejects an answer for the other kind or another id", function()
		local itemDetails, problemDescription = RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer(
			"Bundle",
			HAIR_ASSET_ID,
			copyCapturedDetails("Asset", HAIR_ASSET_ID)
		)
		expectProblemContaining(itemDetails, problemDescription, "ItemType is Asset, expected Bundle")
		itemDetails, problemDescription = RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer(
			"Asset",
			9122110415,
			copyCapturedDetails("Asset", HAIR_ASSET_ID)
		)
		expectProblemContaining(itemDetails, problemDescription, "Id is 7259123616, expected 9122110415")
	end)

	it("rejects each malformed field", function()
		local malformedFieldCases = {
			{ fieldName = "Name", badValue = "", expectedFragment = "Name" },
			{ fieldName = "Name", badValue = 5, expectedFragment = "Name" },
			{ fieldName = "Price", badValue = -1, expectedFragment = "Price" },
			{ fieldName = "Price", badValue = 1.5, expectedFragment = "Price" },
			{ fieldName = "Price", badValue = math.huge, expectedFragment = "Price" },
			{ fieldName = "Price", badValue = "65", expectedFragment = "Price" },
			{ fieldName = "Price", badValue = nil, expectedFragment = "Price" },
			{ fieldName = "IsPurchasable", badValue = nil, expectedFragment = "IsPurchasable" },
			{ fieldName = "IsPurchasable", badValue = "true", expectedFragment = "IsPurchasable" },
			{ fieldName = "SaleLocationType", badValue = nil, expectedFragment = "SaleLocationType" },
			{ fieldName = "SaleLocationType", badValue = 5, expectedFragment = "SaleLocationType" },
			{ fieldName = "ItemRestrictions", badValue = nil, expectedFragment = "ItemRestrictions" },
			{ fieldName = "ItemRestrictions", badValue = "Limited", expectedFragment = "ItemRestrictions" },
			{ fieldName = "ItemRestrictions", badValue = { 5 }, expectedFragment = "ItemRestrictions" },
			{ fieldName = "ItemRestrictions", badValue = { x = "Limited" }, expectedFragment = "ItemRestrictions" },
			{ fieldName = "PriceStatus", badValue = 5, expectedFragment = "PriceStatus" },
			{ fieldName = "PriceStatus", badValue = false, expectedFragment = "PriceStatus" },
			{ fieldName = "AssetType", badValue = nil, expectedFragment = "AssetType" },
			{ fieldName = "AssetType", badValue = "", expectedFragment = "AssetType" },
		}
		for _, malformedFieldCase in malformedFieldCases do
			local rawAnswer = copyCapturedDetails("Asset", HAIR_ASSET_ID)
			rawAnswer[malformedFieldCase.fieldName] = malformedFieldCase.badValue
			local itemDetails, problemDescription =
				RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer("Asset", HAIR_ASSET_ID, rawAnswer)
			expectProblemContaining(itemDetails, problemDescription, malformedFieldCase.expectedFragment)
		end
	end)

	it("accepts a free item (Price 0)", function()
		local rawAnswer = copyCapturedDetails("Asset", HAIR_ASSET_ID)
		rawAnswer.Price = 0
		expect(
			RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer("Asset", HAIR_ASSET_ID, rawAnswer).priceInRobux
		).toBe(0)
	end)
end)

describe("RobloxMarketplaceAnswerConverter bundle details (captured answer)", function()
	it("lists both shoes as wearable and the saved outfit as not wearable, in Roblox's order", function()
		local bundleContentEntries, problemDescription =
			RobloxMarketplaceAnswerConverter.convertBundleDetailsAnswer(SHOES_BUNDLE_ID, copyCapturedBundleDetails())
		expect(problemDescription).toBeNil()
		expect(bundleContentEntries).toEqual({
			{ isWearableAsset = true, wornAssetId = 84885203198436, robloxAssetTypeName = "LeftShoeAccessory" },
			{ isWearableAsset = true, wornAssetId = 90774383444285, robloxAssetTypeName = "RightShoeAccessory" },
			{ isWearableAsset = false },
		})
	end)

	it("marks every item whose Type is not Asset as not wearable, whatever it carries", function()
		local rawBundleDetails = copyCapturedBundleDetails()
		rawBundleDetails.Items[3] = { Type = "Animation", Id = 5, AssetType = "RunAnimation" }
		local bundleContentEntries =
			RobloxMarketplaceAnswerConverter.convertBundleDetailsAnswer(SHOES_BUNDLE_ID, rawBundleDetails)
		expect(bundleContentEntries[3]).toEqual({ isWearableAsset = false })
	end)

	it("rejects a non-table answer, another bundle's answer and missing Items", function()
		local entries, problemDescription =
			RobloxMarketplaceAnswerConverter.convertBundleDetailsAnswer(SHOES_BUNDLE_ID, nil)
		expectProblemContaining(entries, problemDescription, "not a table")
		entries, problemDescription =
			RobloxMarketplaceAnswerConverter.convertBundleDetailsAnswer(1, copyCapturedBundleDetails())
		expectProblemContaining(entries, problemDescription, "Id is 98186475028072, expected 1")
		local rawBundleDetails = copyCapturedBundleDetails()
		rawBundleDetails.Items = nil
		entries, problemDescription =
			RobloxMarketplaceAnswerConverter.convertBundleDetailsAnswer(SHOES_BUNDLE_ID, rawBundleDetails)
		expectProblemContaining(entries, problemDescription, "Items")
	end)

	it("rejects an item without a Type, and an asset item without a whole Id or an AssetType", function()
		local brokenItemCases = {
			{ brokenItem = "not a table", expectedFragment = "bundle item 2 has no Type" },
			{ brokenItem = { Id = 5, AssetType = "Hat" }, expectedFragment = "bundle item 2 has no Type" },
			{
				brokenItem = { Type = "Asset", AssetType = "Hat" },
				expectedFragment = "bundle item 2 is an asset without",
			},
			{ brokenItem = { Type = "Asset", Id = 0, AssetType = "Hat" }, expectedFragment = "positive whole Id" },
			{ brokenItem = { Type = "Asset", Id = 2.5, AssetType = "Hat" }, expectedFragment = "positive whole Id" },
			{
				brokenItem = { Type = "Asset", Id = 5 },
				expectedFragment = "bundle item 2 is an asset without an AssetType",
			},
			{ brokenItem = { Type = "Asset", Id = 5, AssetType = "" }, expectedFragment = "without an AssetType" },
		}
		for _, brokenItemCase in brokenItemCases do
			local rawBundleDetails = copyCapturedBundleDetails()
			rawBundleDetails.Items[2] = brokenItemCase.brokenItem
			local entries, problemDescription =
				RobloxMarketplaceAnswerConverter.convertBundleDetailsAnswer(SHOES_BUNDLE_ID, rawBundleDetails)
			expectProblemContaining(entries, problemDescription, brokenItemCase.expectedFragment)
		end
	end)
end)

describe("RobloxMarketplaceAnswerConverter randomized answers", function()
	local CANDIDATE_FIELD_VALUES = {
		"",
		"text",
		0,
		-3,
		7,
		2.5,
		true,
		false,
		{},
		{ "Limited" },
		"Off Sale",
		"ShopAndAllExperiences",
		"Asset",
	}
	local DETAIL_FIELD_NAMES = {
		"Id",
		"ItemType",
		"Name",
		"Price",
		"IsPurchasable",
		"SaleLocationType",
		"AssetType",
		"ItemRestrictions",
		"PriceStatus",
	}

	it("either reports a problem or returns details the resolver's answer reader accepts unchanged", function()
		SeededRandomTrials.runSeededRandomTrials(300, function(randomNumberGenerator)
			local marketplaceItemKind = randomNumberGenerator.pickRandomListElement({ "Asset", "Bundle" })
			local requestedId = if marketplaceItemKind == "Asset" then HAIR_ASSET_ID else SHOES_BUNDLE_ID
			local rawAnswer = copyCapturedDetails(marketplaceItemKind, requestedId)
			for _ = 1, randomNumberGenerator.nextWholeNumberInRange(0, 3) do
				local fieldName = randomNumberGenerator.pickRandomListElement(DETAIL_FIELD_NAMES)
				rawAnswer[fieldName] = randomNumberGenerator.pickRandomListElement(CANDIDATE_FIELD_VALUES)
			end
			local itemDetails, problemDescription = RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer(
				marketplaceItemKind,
				requestedId,
				rawAnswer
			)
			if itemDetails == nil then
				expect(type(problemDescription)).toBe("string")
				return
			end
			expect(problemDescription).toBeNil()
			local checkedDetails =
				MarketplaceItemLookupAnswerReader.readMarketplaceItemDetailsAnswer(marketplaceItemKind, itemDetails)
			expect(checkedDetails).toEqual(itemDetails)
			expect(itemDetails.canBeSoldInThisGame).toBe(rawAnswer.SaleLocationType == "ShopAndAllExperiences")
			expect(itemDetails.isOnSale).toBe(
				rawAnswer.IsPurchasable == true
					and rawAnswer.PriceStatus ~= "Off Sale"
					and next(rawAnswer.ItemRestrictions) == nil
			)
		end)
	end)
end)
