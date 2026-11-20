-- The wardrobe catalog of MarketplaceStylingItemResolver (development spec §2.14): readiness,
-- the RequestWardrobeCatalogSnapshot answer, WardrobeCatalogChanged, the available key set
-- used by OutfitValidator (§1.5 rule 1), and the cached details for the character dresser (§3.7).

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeMarketplaceItemLookups = require("../Support/FakeMarketplaceItemLookups")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local MarketplaceStylingItemResolverTestHarness = require("../fixtures/MarketplaceStylingItemResolverTestHarness")
local OutfitValidator = require("../../src/shared/OutfitValidator")
local MarketplaceStylingItemResolver = require("../../src/server/MarketplaceStylingItemResolver")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local failWith, succeedWith = FakeMarketplaceItemLookups.failWith, FakeMarketplaceItemLookups.succeedWith
local defineStylingItem = MarketplaceStylingItemResolverTestHarness.defineStylingItem

local HIDDEN_HAIR_ASSET_ID = 9000005 -- FakeStylingItemPool.HIDDEN_HAIR_KEY

local function hideTheFixtureHiddenHair(harness)
	local notOnSaleDetails = FakeMarketplaceItemLookups.buildOnSaleSellableItemDetails("Asset", HIDDEN_HAIR_ASSET_ID)
	notOnSaleDetails.isOnSale = false
	harness.fakeMarketplaceItemLookups:setItemDetailsAnswers("Asset", HIDDEN_HAIR_ASSET_ID, {
		succeedWith(notOnSaleDetails),
	})
end

local function collectWardrobeItemKeys(wardrobeItems): { string }
	local wardrobeItemKeys = {}
	for _, wardrobeItem in wardrobeItems do
		table.insert(wardrobeItemKeys, wardrobeItem.stylingItemKey)
	end
	return wardrobeItemKeys
end

describe("MarketplaceStylingItemResolver readiness", function()
	it("is not ready, has version 0 and an empty snapshot and key set until the first pass finishes", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		local resolver = harness.marketplaceStylingItemResolver
		local function expectNotReady()
			expect(resolver:isWardrobeCatalogReady()).toBeFalse()
			expect(resolver:getWardrobeCatalogVersion()).toBe(0)
			expect(resolver:getAvailableStylingItemKeySet()).toEqual({})
			expect(resolver:readWardrobeCatalogSnapshotAnswer()).toEqual({
				isAccepted = true,
				isWardrobeCatalogReady = false,
				wardrobeCatalogVersion = 0,
				wardrobeItems = {},
			})
			expect(resolver:readResolvedStylingItemDetails("asset_9000001")).toBeNil()
		end
		expectNotReady()
		harness.fakeMarketplaceItemLookups:setHoldsAnswersUntilReleased(true)
		resolver:startResolvingWardrobeCatalog()
		expectNotReady()
		-- Release all but the very last answer: still not ready.
		while harness.fakeMarketplaceItemLookups:countPendingAnswers() > 1 do
			harness.fakeMarketplaceItemLookups:releasePendingAnswerAt(1)
			if harness.fakeMarketplaceItemLookups:countPendingAnswers() > 1 then
				expectNotReady()
			end
		end
		expectNotReady()
		harness.fakeMarketplaceItemLookups:releaseAllPendingAnswers()
		expect(resolver:isWardrobeCatalogReady()).toBeTrue()
		expect(resolver:getWardrobeCatalogVersion()).toBe(1)
	end)

	it("stays not ready while a retry is waiting", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.fakeMarketplaceItemLookups:setItemDetailsAnswers("Asset", 9000001, { failWith() })
		harness.marketplaceStylingItemResolver:startResolvingWardrobeCatalog()
		harness.advanceSeconds(13)
		expect(harness.marketplaceStylingItemResolver:isWardrobeCatalogReady()).toBeFalse()
		expect(harness.marketplaceStylingItemResolver:readWardrobeCatalogSnapshotAnswer().wardrobeItems).toEqual({})
		harness.advanceSeconds(1)
		expect(harness.marketplaceStylingItemResolver:isWardrobeCatalogReady()).toBeTrue()
	end)

	it("is ready at once for a pool with no enabled item, and for an empty pool", function()
		for _, stylingItems in { {}, { defineStylingItem(9100001, "hair", false) } } do
			local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes(stylingItems)
			harness.marketplaceStylingItemResolver:startResolvingWardrobeCatalog()
			expect(harness.marketplaceStylingItemResolver:isWardrobeCatalogReady()).toBeTrue()
			expect(harness.receivedWardrobeCatalogChangedMessages).toEqual({
				{ isWardrobeCatalogReady = true, wardrobeCatalogVersion = 1 },
			})
			expect(harness.fakeMarketplaceItemLookups.startedLookupNames).toEqual({})
		end
	end)

	it("refuses to start twice", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.marketplaceStylingItemResolver:startResolvingWardrobeCatalog()
		expect(function()
			harness.marketplaceStylingItemResolver:startResolvingWardrobeCatalog()
		end).toThrow("already")
	end)
end)

describe("MarketplaceStylingItemResolver WardrobeCatalogChanged", function()
	it("fires exactly once, when the catalog becomes ready, with readiness and version", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.fakeMarketplaceItemLookups:setHoldsAnswersUntilReleased(true)
		harness.fakeMarketplaceItemLookups:setItemDetailsAnswers("Asset", 9000002, { failWith() })
		harness.marketplaceStylingItemResolver:startResolvingWardrobeCatalog()
		expect(harness.receivedWardrobeCatalogChangedMessages).toEqual({})
		for _ = 1, 3 do
			harness.fakeMarketplaceItemLookups:releaseAllPendingAnswers()
			expect(harness.receivedWardrobeCatalogChangedMessages).toEqual({})
			harness.advanceSeconds(8)
		end
		harness.fakeMarketplaceItemLookups:releaseAllPendingAnswers()
		expect(harness.receivedWardrobeCatalogChangedMessages).toEqual({
			{ isWardrobeCatalogReady = true, wardrobeCatalogVersion = 1 },
		})
		harness.advanceSeconds(3600)
		expect(#harness.receivedWardrobeCatalogChangedMessages).toBe(1)
	end)

	it("gives each listener its own message, survives a raising listener, and honours unsubscribe", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		local resolver = harness.marketplaceStylingItemResolver
		local unsubscribedListenerCallCount = 0
		local unsubscribe = resolver:subscribeToWardrobeCatalogChanged(function()
			unsubscribedListenerCallCount += 1
		end)
		unsubscribe()
		resolver:subscribeToWardrobeCatalogChanged(function(wardrobeCatalogChangedMessage)
			wardrobeCatalogChangedMessage.wardrobeCatalogVersion = 999
			error("listener failure")
		end)
		local laterListenerMessages = {}
		resolver:subscribeToWardrobeCatalogChanged(function(wardrobeCatalogChangedMessage)
			table.insert(laterListenerMessages, wardrobeCatalogChangedMessage)
		end)
		harness.startAndRunEveryRetry()
		expect(unsubscribedListenerCallCount).toBe(0)
		expect(laterListenerMessages).toEqual({ { isWardrobeCatalogReady = true, wardrobeCatalogVersion = 1 } })
		expect(resolver:getWardrobeCatalogVersion()).toBe(1)
		expect(harness.countLoggedWarningsMentioning("listener failure")).toBe(1)
	end)
end)

describe("MarketplaceStylingItemResolver snapshot", function()
	it(
		"lists every available item in pool order with name, price and worn assets, and no hidden or disabled one",
		function()
			local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
			hideTheFixtureHiddenHair(harness)
			harness.startAndRunEveryRetry()
			local snapshotAnswer = harness.marketplaceStylingItemResolver:readWardrobeCatalogSnapshotAnswer()
			expect(snapshotAnswer.isAccepted).toBeTrue()
			expect(snapshotAnswer.isWardrobeCatalogReady).toBeTrue()
			expect(snapshotAnswer.wardrobeCatalogVersion).toBe(1)

			local expectedWardrobeItems = {}
			for _, fakeStylingItem in FakeStylingItemPool.FAKE_STYLING_ITEMS do
				if FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET[fakeStylingItem.stylingItemKey] then
					local kind, id = fakeStylingItem.marketplaceItemKind, fakeStylingItem.marketplaceItemId
					local fakeDetails = FakeMarketplaceItemLookups.buildOnSaleSellableItemDetails(kind, id)
					local expectedWornAssets = if kind == "Bundle"
						then {
							{
								wornAssetId = FakeMarketplaceItemLookups.deriveFakeLeftShoeAssetId(id),
								robloxAssetTypeName = FakeMarketplaceItemLookups.FAKE_LEFT_SHOE_ASSET_TYPE_NAME,
							},
							{
								wornAssetId = FakeMarketplaceItemLookups.deriveFakeRightShoeAssetId(id),
								robloxAssetTypeName = FakeMarketplaceItemLookups.FAKE_RIGHT_SHOE_ASSET_TYPE_NAME,
							},
						}
						else {
							{ wornAssetId = id, robloxAssetTypeName = FakeMarketplaceItemLookups.FAKE_ASSET_TYPE_NAME },
						}
					table.insert(expectedWardrobeItems, {
						stylingItemKey = fakeStylingItem.stylingItemKey,
						marketplaceItemKind = kind,
						marketplaceItemId = id,
						itemDisplayName = fakeDetails.itemDisplayName,
						priceInRobux = fakeDetails.priceInRobux,
						wornAssets = expectedWornAssets,
					})
				end
			end
			expect(snapshotAnswer.wardrobeItems).toEqual(expectedWardrobeItems)
			expect(
				table.find(collectWardrobeItemKeys(snapshotAnswer.wardrobeItems), FakeStylingItemPool.HIDDEN_HAIR_KEY)
			).toBeNil()
		end
	)

	it("matches the available key set exactly", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		hideTheFixtureHiddenHair(harness)
		harness.startAndRunEveryRetry()
		local resolver = harness.marketplaceStylingItemResolver
		expect(resolver:getAvailableStylingItemKeySet()).toEqual(
			FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET
		)
		local keySetFromSnapshot = {}
		for _, wardrobeItemKey in collectWardrobeItemKeys(resolver:readWardrobeCatalogSnapshotAnswer().wardrobeItems) do
			keySetFromSnapshot[wardrobeItemKey] = true
		end
		expect(keySetFromSnapshot).toEqual(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
	end)

	it("hands out a fresh copy each time, so editing an answer changes nothing", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.startAndRunEveryRetry()
		local resolver = harness.marketplaceStylingItemResolver
		local firstSnapshot = resolver:readWardrobeCatalogSnapshotAnswer()
		firstSnapshot.wardrobeItems[1].itemDisplayName = "edited"
		firstSnapshot.wardrobeItems[1].wornAssets[1].wornAssetId = -1
		table.remove(firstSnapshot.wardrobeItems)
		local resolvedDetails = resolver:readResolvedStylingItemDetails("bundle_9000041")
		resolvedDetails.wornAssets[1].robloxAssetTypeName = "edited"
		local secondSnapshot = resolver:readWardrobeCatalogSnapshotAnswer()
		expect(secondSnapshot.wardrobeItems[1].itemDisplayName).toBe("Fake Asset 9000001")
		expect(secondSnapshot.wardrobeItems[1].wornAssets[1].wornAssetId).toBe(9000001)
		expect(#secondSnapshot.wardrobeItems).toBe(#firstSnapshot.wardrobeItems + 1)
		expect(resolver:readResolvedStylingItemDetails("bundle_9000041").wornAssets[1].robloxAssetTypeName).toBe(
			FakeMarketplaceItemLookups.FAKE_LEFT_SHOE_ASSET_TYPE_NAME
		)
	end)
end)

describe("MarketplaceStylingItemResolver cached details for dressing", function()
	it("returns an available item's details and nil for hidden, disabled and unknown keys", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		hideTheFixtureHiddenHair(harness)
		harness.startAndRunEveryRetry()
		local resolver = harness.marketplaceStylingItemResolver
		expect(resolver:readResolvedStylingItemDetails("asset_9000011")).toEqual({
			stylingItemKey = "asset_9000011",
			marketplaceItemKind = "Asset",
			marketplaceItemId = 9000011,
			itemDisplayName = "Fake Asset 9000011",
			priceInRobux = 11,
			wornAssets = {
				{ wornAssetId = 9000011, robloxAssetTypeName = FakeMarketplaceItemLookups.FAKE_ASSET_TYPE_NAME },
			},
		})
		expect(resolver:readResolvedStylingItemDetails(FakeStylingItemPool.HIDDEN_HAIR_KEY)).toBeNil()
		expect(resolver:readResolvedStylingItemDetails(FakeStylingItemPool.DISABLED_HAIR_KEY)).toBeNil()
		expect(resolver:readResolvedStylingItemDetails(FakeStylingItemPool.KEY_NOT_IN_POOL)).toBeNil()
	end)
end)

describe("MarketplaceStylingItemResolver available key set with OutfitValidator", function()
	it("makes OutfitValidator reject an outfit containing an item hidden by the resolver", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		hideTheFixtureHiddenHair(harness)
		harness.startAndRunEveryRetry()
		local availableStylingItemKeySet = harness.marketplaceStylingItemResolver:getAvailableStylingItemKeySet()
		local verdict = OutfitValidator.validateOutfit(
			{ FakeStylingItemPool.HIDDEN_HAIR_KEY, "asset_9000011" },
			FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
			availableStylingItemKeySet
		)
		expect(verdict.isOutfitValid).toBeFalse()
		expect(verdict.outfitRejectionReason).toBe(
			OutfitValidator.OUTFIT_REJECTION_REASONS.StylingItemHiddenThisSession
		)
		expect(verdict.offendingStylingItemKey).toBe(FakeStylingItemPool.HIDDEN_HAIR_KEY)
		local workedExampleVerdict = OutfitValidator.validateOutfit(
			FakeStylingItemPool.WORKED_EXAMPLE_STYLING_ITEM_KEYS,
			FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
			availableStylingItemKeySet
		)
		expect(workedExampleVerdict.isOutfitValid).toBeTrue()
	end)

	it("makes OutfitValidator reject every non-empty outfit while the catalog is not ready", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		local verdict = OutfitValidator.validateOutfit(
			FakeStylingItemPool.WORKED_EXAMPLE_STYLING_ITEM_KEYS,
			FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
			harness.marketplaceStylingItemResolver:getAvailableStylingItemKeySet()
		)
		expect(verdict.isOutfitValid).toBeFalse()
		expect(verdict.outfitRejectionReason).toBe(
			OutfitValidator.OUTFIT_REJECTION_REASONS.StylingItemHiddenThisSession
		)
	end)
end)

describe("MarketplaceStylingItemResolver lookup load", function()
	it("never has more than 10 lookups in flight at once and still looks up every enabled item", function()
		local stylingItems = {}
		for itemNumber = 1, 35 do
			table.insert(stylingItems, defineStylingItem(9200000 + itemNumber, "accessory", true))
		end
		for itemNumber = 1, 10 do
			table.insert(stylingItems, defineStylingItem(9300000 + itemNumber, "shoes", true))
		end
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes(stylingItems)
		local lookups = harness.fakeMarketplaceItemLookups
		lookups:setHoldsAnswersUntilReleased(true)
		harness.marketplaceStylingItemResolver:startResolvingWardrobeCatalog()
		expect(lookups:countPendingAnswers()).toBe(10)
		lookups:releaseAllPendingAnswers()
		expect(lookups.largestPendingLookupCount).toBe(10)
		expect(#lookups.startedLookupNames).toBe(45 + 10)
		expect(harness.marketplaceStylingItemResolver:isWardrobeCatalogReady()).toBeTrue()
		local availableKeyCount = 0
		for _ in harness.marketplaceStylingItemResolver:getAvailableStylingItemKeySet() do
			availableKeyCount += 1
		end
		expect(availableKeyCount).toBe(45)
	end)
end)

describe("MarketplaceStylingItemResolver header promises", function()
	it("still tells the next listener when a listener unsubscribes itself while being told", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		local resolver = harness.marketplaceStylingItemResolver
		local unsubscribeSelf
		unsubscribeSelf = resolver:subscribeToWardrobeCatalogChanged(function()
			unsubscribeSelf()
		end)
		local nextListenerMessages = {}
		resolver:subscribeToWardrobeCatalogChanged(function(wardrobeCatalogChangedMessage)
			table.insert(nextListenerMessages, wardrobeCatalogChangedMessage)
		end)
		harness.startAndRunEveryRetry()
		expect(nextListenerMessages).toEqual({ { isWardrobeCatalogReady = true, wardrobeCatalogVersion = 1 } })
	end)

	it("refuses a listener that is not a function", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		for _, notAFunction in { "listener", 1, {} } :: { any } do
			expect(function()
				harness.marketplaceStylingItemResolver:subscribeToWardrobeCatalogChanged(notAFunction)
			end).toThrow("listener must be a function")
		end
	end)

	it("hands out a frozen available key set, both before and after the catalog is ready", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		hideTheFixtureHiddenHair(harness)
		local resolver = harness.marketplaceStylingItemResolver
		local function expectFrozenAndUnwritable()
			local availableStylingItemKeySet: any = resolver:getAvailableStylingItemKeySet()
			expect(table.isfrozen(availableStylingItemKeySet)).toBeTrue()
			expect(function()
				availableStylingItemKeySet[FakeStylingItemPool.HIDDEN_HAIR_KEY] = true
			end).toThrow()
			expect(resolver:getAvailableStylingItemKeySet()[FakeStylingItemPool.HIDDEN_HAIR_KEY]).toBeNil()
		end
		expectFrozenAndUnwritable()
		harness.startAndRunEveryRetry()
		expectFrozenAndUnwritable()
	end)

	it("logs that the catalog is ready, with the available and hidden counts", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		hideTheFixtureHiddenHair(harness)
		harness.startAndRunEveryRetry()
		expect(harness.loggedInformation).toEqual({
			"MarketplaceStylingItemResolver: wardrobe catalog ready with 26 available and 1 hidden styling items",
		})
	end)

	it("hands out a copy of the hidden reasons, so editing it changes nothing", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		hideTheFixtureHiddenHair(harness)
		harness.startAndRunEveryRetry()
		local resolver = harness.marketplaceStylingItemResolver
		local hiddenReasons = resolver:readHiddenStylingItemReasonByStylingItemKey()
		hiddenReasons[FakeStylingItemPool.HIDDEN_HAIR_KEY] = nil
		hiddenReasons.asset_9000001 = "NotOnSale"
		expect(resolver:readHiddenStylingItemReasonByStylingItemKey()).toEqual({
			[FakeStylingItemPool.HIDDEN_HAIR_KEY] = "NotOnSale",
		})
	end)

	it("refuses to be created without a dependency or from a pool with a duplicated key", function()
		local fullDependencies = { stylingItems = {}, marketplaceItemLookups = {}, scheduler = {}, logger = {} }
		for dependencyName in fullDependencies do
			local incompleteDependencies = table.clone(fullDependencies)
			incompleteDependencies[dependencyName] = nil
			expect(function()
				MarketplaceStylingItemResolver.new(incompleteDependencies)
			end).toThrow("missing dependency " .. dependencyName)
		end
		local duplicatedPoolDependencies = table.clone(fullDependencies)
		duplicatedPoolDependencies.stylingItems = {
			defineStylingItem(9100001, "hair", true),
			defineStylingItem(9100001, "hair", true),
		}
		expect(function()
			MarketplaceStylingItemResolver.new(duplicatedPoolDependencies)
		end).toThrow("more than once")
	end)
end)
