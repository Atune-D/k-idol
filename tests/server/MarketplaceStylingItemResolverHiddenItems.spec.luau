-- The hidden-item rule (development spec §1.2), retries (§2.14) and bundle contents (§2.14,
-- §3.7) of MarketplaceStylingItemResolver, against fake Roblox answers.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local FakeMarketplaceItemLookups = require("../Support/FakeMarketplaceItemLookups")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local MarketplaceStylingItemResolverTestHarness = require("../fixtures/MarketplaceStylingItemResolverTestHarness")
local MarketplaceStylingItemResolver = require("../../src/server/MarketplaceStylingItemResolver")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local HIDDEN_REASONS = MarketplaceStylingItemResolver.HIDDEN_STYLING_ITEM_REASONS
local succeedWith, failWith = FakeMarketplaceItemLookups.succeedWith, FakeMarketplaceItemLookups.failWith

local HAIR_ASSET_ID = 9000001
local HAIR_KEY = "asset_9000001"
local SHOES_BUNDLE_ID = 9000041
local SHOES_KEY = "bundle_9000041"

local function buildItemDetailsWith(marketplaceItemKind: string, marketplaceItemId: number, changedFields)
	local itemDetails =
		FakeMarketplaceItemLookups.buildOnSaleSellableItemDetails(marketplaceItemKind, marketplaceItemId)
	for fieldName, fieldValue in changedFields do
		itemDetails[fieldName] = fieldValue
	end
	return itemDetails
end

local function expectHiddenOnlyFor(harness, expectedHiddenReasonByStylingItemKey: { [string]: string })
	local resolver = harness.marketplaceStylingItemResolver
	expect(resolver:isWardrobeCatalogReady()).toBeTrue()
	expect(resolver:readHiddenStylingItemReasonByStylingItemKey()).toEqual(expectedHiddenReasonByStylingItemKey)
	local availableStylingItemKeySet = resolver:getAvailableStylingItemKeySet()
	for _, fakeStylingItem in FakeStylingItemPool.FAKE_STYLING_ITEMS do
		local stylingItemKey = fakeStylingItem.stylingItemKey
		local isExpectedAvailable = fakeStylingItem.isEnabled
			and expectedHiddenReasonByStylingItemKey[stylingItemKey] == nil
		expect(availableStylingItemKeySet[stylingItemKey] == true).toBe(isExpectedAvailable)
	end
end

describe("MarketplaceStylingItemResolver hidden items", function()
	it("makes every enabled item available when every lookup succeeds", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.startAndRunEveryRetry()
		expectHiddenOnlyFor(harness, {})
		expect(harness.loggedWarnings).toEqual({})
	end)

	it("hides an item whose details fail to load, and logs it", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.fakeMarketplaceItemLookups:setItemDetailsAnswers("Asset", HAIR_ASSET_ID, { failWith("HTTP 500") })
		harness.startAndRunEveryRetry()
		expectHiddenOnlyFor(harness, { [HAIR_KEY] = HIDDEN_REASONS.ItemDetailsFailedToLoad })
		expect(harness.countLoggedWarningsMentioning(HAIR_KEY)).toBe(1)
		expect(harness.countLoggedWarningsMentioning("ItemDetailsFailedToLoad")).toBe(1)
		expect(harness.countLoggedWarningsMentioning("HTTP 500")).toBe(1)
	end)

	it("hides an item that is not on sale, without retrying, and logs it", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.fakeMarketplaceItemLookups:setItemDetailsAnswers("Asset", HAIR_ASSET_ID, {
			succeedWith(buildItemDetailsWith("Asset", HAIR_ASSET_ID, { isOnSale = false })),
		})
		harness.startAndRunEveryRetry()
		expectHiddenOnlyFor(harness, { [HAIR_KEY] = HIDDEN_REASONS.NotOnSale })
		expect(harness.fakeMarketplaceItemLookups:countStartedLookups("details Asset 9000001")).toBe(1)
		expect(harness.countLoggedWarningsMentioning("NotOnSale")).toBe(1)
	end)

	it("hides an item that cannot be sold in this game, without retrying, and logs it", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.fakeMarketplaceItemLookups:setItemDetailsAnswers("Asset", HAIR_ASSET_ID, {
			succeedWith(buildItemDetailsWith("Asset", HAIR_ASSET_ID, { canBeSoldInThisGame = false })),
		})
		harness.startAndRunEveryRetry()
		expectHiddenOnlyFor(harness, { [HAIR_KEY] = HIDDEN_REASONS.NotSellableInThisGame })
		expect(harness.fakeMarketplaceItemLookups:countStartedLookups("details Asset 9000001")).toBe(1)
		expect(harness.countLoggedWarningsMentioning("NotSellableInThisGame")).toBe(1)
	end)

	it("hides a bundle that is not on sale or not sellable here, judged from its item details", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.fakeMarketplaceItemLookups:setItemDetailsAnswers("Bundle", SHOES_BUNDLE_ID, {
			succeedWith(buildItemDetailsWith("Bundle", SHOES_BUNDLE_ID, { isOnSale = false })),
		})
		harness.fakeMarketplaceItemLookups:setItemDetailsAnswers("Bundle", 9000042, {
			succeedWith(buildItemDetailsWith("Bundle", 9000042, { canBeSoldInThisGame = false })),
		})
		harness.startAndRunEveryRetry()
		expectHiddenOnlyFor(harness, {
			[SHOES_KEY] = HIDDEN_REASONS.NotOnSale,
			bundle_9000042 = HIDDEN_REASONS.NotSellableInThisGame,
		})
		-- Contents are not looked up for a bundle already hidden by its details.
		expect(harness.fakeMarketplaceItemLookups:countStartedLookups("contents 9000041")).toBe(0)
		expect(harness.fakeMarketplaceItemLookups:countStartedLookups("contents 9000042")).toBe(0)
	end)

	it("hides a bundle whose contents fail to load, and logs it", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.fakeMarketplaceItemLookups:setBundleContentsAnswers(SHOES_BUNDLE_ID, { failWith("bundle timeout") })
		harness.startAndRunEveryRetry()
		expectHiddenOnlyFor(harness, { [SHOES_KEY] = HIDDEN_REASONS.BundleContentsFailedToLoad })
		expect(harness.countLoggedWarningsMentioning("BundleContentsFailedToLoad")).toBe(1)
		expect(harness.countLoggedWarningsMentioning("bundle timeout")).toBe(1)
	end)

	it("treats a lookup that raises while starting as a failed lookup", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.fakeMarketplaceItemLookups:setItemDetailsAnswers(
			"Asset",
			HAIR_ASSET_ID,
			{ FakeMarketplaceItemLookups.RAISE_WHILE_STARTING }
		)
		harness.fakeMarketplaceItemLookups:setBundleContentsAnswers(
			SHOES_BUNDLE_ID,
			{ FakeMarketplaceItemLookups.RAISE_WHILE_STARTING }
		)
		harness.startAndRunEveryRetry()
		expectHiddenOnlyFor(harness, {
			[HAIR_KEY] = HIDDEN_REASONS.ItemDetailsFailedToLoad,
			[SHOES_KEY] = HIDDEN_REASONS.BundleContentsFailedToLoad,
		})
		expect(harness.fakeMarketplaceItemLookups:countStartedLookups("details Asset 9000001")).toBe(4)
	end)

	it("never looks up a disabled row and never makes it available", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.startAndRunEveryRetry()
		for _, startedLookupName in harness.fakeMarketplaceItemLookups.startedLookupNames do
			expect(string.find(startedLookupName, "9000004", 1, true)).toBeNil()
			expect(string.find(startedLookupName, "9000033", 1, true)).toBeNil()
		end
		local availableStylingItemKeySet = harness.marketplaceStylingItemResolver:getAvailableStylingItemKeySet()
		expect(availableStylingItemKeySet[FakeStylingItemPool.DISABLED_HAIR_KEY]).toBeNil()
		expect(availableStylingItemKeySet[FakeStylingItemPool.DISABLED_DRESS_KEY]).toBeNil()
		expect(harness.marketplaceStylingItemResolver:readHiddenStylingItemReasonByStylingItemKey()).toEqual({})
	end)
end)

describe("MarketplaceStylingItemResolver retries", function()
	it("makes an item available when a later attempt succeeds, retrying 2, 4 and 8 seconds apart", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		local lookups = harness.fakeMarketplaceItemLookups
		lookups:setItemDetailsAnswers("Asset", HAIR_ASSET_ID, {
			failWith(),
			failWith(),
			failWith(),
			succeedWith(FakeMarketplaceItemLookups.buildOnSaleSellableItemDetails("Asset", HAIR_ASSET_ID)),
		})
		local resolver = harness.marketplaceStylingItemResolver
		resolver:startResolvingWardrobeCatalog()
		expect(lookups:countStartedLookups("details Asset 9000001")).toBe(1)
		harness.advanceSeconds(1.999)
		expect(lookups:countStartedLookups("details Asset 9000001")).toBe(1)
		harness.advanceSeconds(0.001)
		expect(lookups:countStartedLookups("details Asset 9000001")).toBe(2)
		harness.advanceSeconds(3.999)
		expect(lookups:countStartedLookups("details Asset 9000001")).toBe(2)
		harness.advanceSeconds(0.001)
		expect(lookups:countStartedLookups("details Asset 9000001")).toBe(3)
		expect(resolver:isWardrobeCatalogReady()).toBeFalse()
		harness.advanceSeconds(7.999)
		expect(lookups:countStartedLookups("details Asset 9000001")).toBe(3)
		expect(resolver:isWardrobeCatalogReady()).toBeFalse()
		harness.advanceSeconds(0.001)
		expect(lookups:countStartedLookups("details Asset 9000001")).toBe(4)
		expectHiddenOnlyFor(harness, {})
		expect(harness.loggedWarnings).toEqual({})
	end)

	it("hides the item after the third retry fails (four attempts in all) and never asks again", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.fakeMarketplaceItemLookups:setItemDetailsAnswers("Asset", HAIR_ASSET_ID, { failWith() })
		harness.marketplaceStylingItemResolver:startResolvingWardrobeCatalog()
		harness.advanceSeconds(13.999)
		expect(harness.marketplaceStylingItemResolver:isWardrobeCatalogReady()).toBeFalse()
		harness.advanceSeconds(0.001)
		expectHiddenOnlyFor(harness, { [HAIR_KEY] = HIDDEN_REASONS.ItemDetailsFailedToLoad })
		harness.advanceSeconds(3600)
		expect(harness.fakeMarketplaceItemLookups:countStartedLookups("details Asset 9000001")).toBe(4)
		expect(harness.countLoggedWarningsMentioning("after 4 attempts")).toBe(1)
	end)

	it("retries only the bundle contents, not the details, when the contents fail", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		local lookups = harness.fakeMarketplaceItemLookups
		lookups:setBundleContentsAnswers(SHOES_BUNDLE_ID, {
			failWith(),
			failWith(),
			succeedWith(FakeMarketplaceItemLookups.buildFakeShoeBundleContentEntries(SHOES_BUNDLE_ID)),
		})
		harness.startAndRunEveryRetry()
		expectHiddenOnlyFor(harness, {})
		expect(lookups:countStartedLookups("details Bundle 9000041")).toBe(1)
		expect(lookups:countStartedLookups("contents 9000041")).toBe(3)
	end)

	it("hides a bundle after its contents fail four times", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.fakeMarketplaceItemLookups:setBundleContentsAnswers(SHOES_BUNDLE_ID, { failWith() })
		harness.startAndRunEveryRetry()
		expectHiddenOnlyFor(harness, { [SHOES_KEY] = HIDDEN_REASONS.BundleContentsFailedToLoad })
		expect(harness.fakeMarketplaceItemLookups:countStartedLookups("contents 9000041")).toBe(4)
	end)

	it("counts a success value other than `true` (nil, a string, a number) as a failed attempt", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		local validHairDetails = FakeMarketplaceItemLookups.buildOnSaleSellableItemDetails("Asset", HAIR_ASSET_ID)
		harness.fakeMarketplaceItemLookups:setItemDetailsAnswers("Asset", HAIR_ASSET_ID, {
			{ wasLookupSuccessful = nil, lookupAnswer = validHairDetails },
			{ wasLookupSuccessful = "yes", lookupAnswer = validHairDetails },
			{ wasLookupSuccessful = 1, lookupAnswer = validHairDetails },
		})
		harness.fakeMarketplaceItemLookups:setBundleContentsAnswers(SHOES_BUNDLE_ID, {
			{
				wasLookupSuccessful = "yes",
				lookupAnswer = FakeMarketplaceItemLookups.buildFakeShoeBundleContentEntries(SHOES_BUNDLE_ID),
			},
		})
		harness.startAndRunEveryRetry()
		expectHiddenOnlyFor(harness, {
			[HAIR_KEY] = HIDDEN_REASONS.ItemDetailsFailedToLoad,
			[SHOES_KEY] = HIDDEN_REASONS.BundleContentsFailedToLoad,
		})
		expect(harness.fakeMarketplaceItemLookups:countStartedLookups("details Asset 9000001")).toBe(4)
	end)

	it("counts a malformed answer as a failed attempt and retries it", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.fakeMarketplaceItemLookups:setItemDetailsAnswers("Asset", HAIR_ASSET_ID, {
			succeedWith(buildItemDetailsWith("Asset", HAIR_ASSET_ID, { priceInRobux = "cheap" })),
			succeedWith(FakeMarketplaceItemLookups.buildOnSaleSellableItemDetails("Asset", HAIR_ASSET_ID)),
		})
		harness.startAndRunEveryRetry()
		expectHiddenOnlyFor(harness, {})
		expect(harness.fakeMarketplaceItemLookups:countStartedLookups("details Asset 9000001")).toBe(2)
	end)

	it("ignores a lookup callback that is called a second time", function()
		local deliveredCallbacks = {}
		local fakeClock = FakeClock.new(MarketplaceStylingItemResolverTestHarness.EXAMPLE_STARTING_UNIX_SECONDS)
		local fakeScheduler = FakeScheduler.new(fakeClock)
		local resolver = MarketplaceStylingItemResolver.new({
			stylingItems = { MarketplaceStylingItemResolverTestHarness.defineStylingItem(9100001, "hair", true) },
			marketplaceItemLookups = {
				startLookingUpMarketplaceItemDetails = function(_, _, _, onLookupFinished)
					table.insert(deliveredCallbacks, onLookupFinished)
					onLookupFinished(false, nil, "failed")
				end,
			},
			scheduler = fakeScheduler,
			logger = { logInformation = function() end, logWarning = function() end },
		})
		resolver:startResolvingWardrobeCatalog()
		-- A late second call saying "success" must not make the item available or settle it early.
		deliveredCallbacks[1](true, FakeMarketplaceItemLookups.buildOnSaleSellableItemDetails("Asset", 9100001), nil)
		expect(resolver:isWardrobeCatalogReady()).toBeFalse()
		fakeScheduler:advanceTimeAndRunDueCallbacks(60)
		expect(#deliveredCallbacks).toBe(4)
		expect(resolver:isWardrobeCatalogReady()).toBeTrue()
		expect(resolver:getAvailableStylingItemKeySet()).toEqual({})
	end)
end)

describe("MarketplaceStylingItemResolver bundle contents", function()
	it("resolves a shoes bundle to its left and right shoe, without the saved-outfit entry", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.startAndRunEveryRetry()
		local resolvedShoes = harness.marketplaceStylingItemResolver:readResolvedStylingItemDetails(SHOES_KEY)
		expect(resolvedShoes.wornAssets).toEqual({
			{
				wornAssetId = FakeMarketplaceItemLookups.deriveFakeLeftShoeAssetId(SHOES_BUNDLE_ID),
				robloxAssetTypeName = FakeMarketplaceItemLookups.FAKE_LEFT_SHOE_ASSET_TYPE_NAME,
			},
			{
				wornAssetId = FakeMarketplaceItemLookups.deriveFakeRightShoeAssetId(SHOES_BUNDLE_ID),
				robloxAssetTypeName = FakeMarketplaceItemLookups.FAKE_RIGHT_SHOE_ASSET_TYPE_NAME,
			},
		})
	end)

	it("resolves an asset to itself with the asset type its details report", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.fakeMarketplaceItemLookups:setItemDetailsAnswers("Asset", HAIR_ASSET_ID, {
			succeedWith(buildItemDetailsWith("Asset", HAIR_ASSET_ID, { robloxAssetTypeName = "FakeHairTypeForTests" })),
		})
		harness.startAndRunEveryRetry()
		local resolvedHair = harness.marketplaceStylingItemResolver:readResolvedStylingItemDetails(HAIR_KEY)
		expect(resolvedHair.wornAssets).toEqual({
			{ wornAssetId = HAIR_ASSET_ID, robloxAssetTypeName = "FakeHairTypeForTests" },
		})
	end)

	it("hides a bundle whose contents hold nothing wearable", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.fakeMarketplaceItemLookups:setBundleContentsAnswers(SHOES_BUNDLE_ID, {
			succeedWith({ { isWearableAsset = false, wornAssetId = 1 } }),
		})
		harness.startAndRunEveryRetry()
		expectHiddenOnlyFor(harness, { [SHOES_KEY] = HIDDEN_REASONS.BundleContentsFailedToLoad })
	end)
end)
