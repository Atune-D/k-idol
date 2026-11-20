-- RequestStylingItemOwnership answers of MarketplaceStylingItemResolver (development spec §2.14,
-- §2.12: ownership is checked per kind), against fake Roblox answers.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeMarketplaceItemLookups = require("../Support/FakeMarketplaceItemLookups")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local MarketplaceStylingItemResolverTestHarness = require("../fixtures/MarketplaceStylingItemResolverTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local succeedWith, failWith = FakeMarketplaceItemLookups.succeedWith, FakeMarketplaceItemLookups.failWith

local PLAYER = MarketplaceStylingItemResolverTestHarness.EXAMPLE_PLAYER_USER_ID
local OTHER_PLAYER = MarketplaceStylingItemResolverTestHarness.OTHER_PLAYER_USER_ID

local UNKNOWN_STYLING_ITEM_ANSWER = { isAccepted = false, rejectionReason = "UnknownStylingItem" }
local OWNERSHIP_CHECK_FAILED_ANSWER = { isAccepted = false, rejectionReason = "OwnershipCheckFailed" }

local function createReadyResolverHarness()
	local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
	local notOnSaleDetails = FakeMarketplaceItemLookups.buildOnSaleSellableItemDetails("Asset", 9000005)
	notOnSaleDetails.isOnSale = false
	harness.fakeMarketplaceItemLookups:setItemDetailsAnswers("Asset", 9000005, { succeedWith(notOnSaleDetails) })
	harness.startAndRunEveryRetry()
	return harness
end

describe("MarketplaceStylingItemResolver ownership", function()
	it("answers whether the player owns an asset, checking the asset", function()
		local harness = createReadyResolverHarness()
		harness.fakeMarketplaceItemLookups:setOwnershipAnswers(PLAYER, "Asset", 9000001, { succeedWith(true) })
		expect(harness.askOwnership(PLAYER, "asset_9000001")).toEqual({ { isAccepted = true, isOwnedByPlayer = true } })
		expect(harness.askOwnership(OTHER_PLAYER, "asset_9000001")).toEqual({
			{ isAccepted = true, isOwnedByPlayer = false },
		})
		expect(harness.fakeMarketplaceItemLookups:countStartedLookups("ownership 8801 Asset 9000001")).toBe(1)
		expect(harness.fakeMarketplaceItemLookups:countStartedLookups("ownership 8802 Asset 9000001")).toBe(1)
	end)

	it("answers whether the player owns a bundle, checking the bundle and not its assets", function()
		local harness = createReadyResolverHarness()
		harness.fakeMarketplaceItemLookups:setOwnershipAnswers(PLAYER, "Bundle", 9000041, { succeedWith(true) })
		expect(harness.askOwnership(PLAYER, "bundle_9000041")).toEqual({ { isAccepted = true, isOwnedByPlayer = true } })
		expect(harness.askOwnership(PLAYER, "bundle_9000042")).toEqual({
			{ isAccepted = true, isOwnedByPlayer = false },
		})
		expect(harness.fakeMarketplaceItemLookups:countStartedLookups("ownership 8801 Bundle 9000041")).toBe(1)
		expect(harness.fakeMarketplaceItemLookups:countStartedLookups("ownership 8801 Asset 9000041")).toBe(0)
	end)

	it("answers a check that completes later, once", function()
		local harness = createReadyResolverHarness()
		harness.fakeMarketplaceItemLookups:setHoldsAnswersUntilReleased(true)
		harness.fakeMarketplaceItemLookups:setOwnershipAnswers(PLAYER, "Asset", 9000011, { succeedWith(true) })
		local receivedAnswers = harness.askOwnership(PLAYER, "asset_9000011")
		expect(receivedAnswers).toEqual({})
		harness.fakeMarketplaceItemLookups:releaseAllPendingAnswers()
		expect(receivedAnswers).toEqual({ { isAccepted = true, isOwnedByPlayer = true } })
	end)

	it("rejects with UnknownStylingItem, without asking Roblox, any key that is not an available item", function()
		local harness = createReadyResolverHarness()
		for _, untrustedStylingItemKey in
			{
				FakeStylingItemPool.KEY_NOT_IN_POOL,
				FakeStylingItemPool.BUNDLE_KEY_WITH_ASSET_ID_OF_POOL_ITEM,
				FakeStylingItemPool.DISABLED_HAIR_KEY,
				FakeStylingItemPool.HIDDEN_HAIR_KEY,
				"",
				42,
				{ "asset_9000001" },
			} :: { any }
		do
			expect(harness.askOwnership(PLAYER, untrustedStylingItemKey)).toEqual({ UNKNOWN_STYLING_ITEM_ANSWER })
		end
		expect(harness.askOwnership(PLAYER, nil)).toEqual({ UNKNOWN_STYLING_ITEM_ANSWER })
		for _, startedLookupName in harness.fakeMarketplaceItemLookups.startedLookupNames do
			expect(string.find(startedLookupName, "ownership", 1, true)).toBeNil()
		end
	end)

	it("never turns a check that did not report success into an owned or not-owned answer", function()
		local harness = createReadyResolverHarness()
		local lookups = harness.fakeMarketplaceItemLookups
		local nonSuccessCases = {
			{ wasLookupSuccessful = false, lookupAnswer = true },
			{ wasLookupSuccessful = false, lookupAnswer = false },
			{ wasLookupSuccessful = nil, lookupAnswer = true },
			{ wasLookupSuccessful = "yes", lookupAnswer = true },
			{ wasLookupSuccessful = 1, lookupAnswer = false },
		}
		for casePosition, nonSuccessCase in nonSuccessCases do
			local playerUserId = 9900 + casePosition
			lookups:setOwnershipAnswers(playerUserId, "Asset", 9000001, { nonSuccessCase })
			expect(harness.askOwnership(playerUserId, "asset_9000001")).toEqual({ OWNERSHIP_CHECK_FAILED_ANSWER })
		end
	end)

	it("answers once even when the check calls back a second time", function()
		local harness = createReadyResolverHarness()
		-- Replace the fake's method on this one instance with a check that calls back twice.
		harness.fakeMarketplaceItemLookups.startCheckingPlayerOwnsMarketplaceItem = function(
			_,
			_,
			_,
			_,
			onCheckFinished
		)
			onCheckFinished(true, true, nil)
			onCheckFinished(false, nil, "late second call")
		end
		expect(harness.askOwnership(PLAYER, "asset_9000001")).toEqual({ { isAccepted = true, isOwnedByPlayer = true } })
		expect(harness.countLoggedWarningsMentioning("late second call")).toBe(0)
	end)

	it("rejects with UnknownStylingItem while the catalog is not ready", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		expect(harness.askOwnership(PLAYER, "asset_9000001")).toEqual({ UNKNOWN_STYLING_ITEM_ANSWER })
		expect(harness.fakeMarketplaceItemLookups:countStartedLookups("ownership 8801 Asset 9000001")).toBe(0)
	end)

	it(
		"rejects with OwnershipCheckFailed, logs, and does not retry when the check fails, raises or answers badly",
		function()
			local harness = createReadyResolverHarness()
			local lookups = harness.fakeMarketplaceItemLookups
			lookups:setOwnershipAnswers(PLAYER, "Asset", 9000001, { failWith("ownership timeout") })
			lookups:setOwnershipAnswers(PLAYER, "Asset", 9000002, { FakeMarketplaceItemLookups.RAISE_WHILE_STARTING })
			lookups:setOwnershipAnswers(PLAYER, "Asset", 9000003, { succeedWith("yes") })
			for _, stylingItemKey in { "asset_9000001", "asset_9000002", "asset_9000003" } do
				expect(harness.askOwnership(PLAYER, stylingItemKey)).toEqual({ OWNERSHIP_CHECK_FAILED_ANSWER })
			end
			harness.advanceSeconds(60)
			expect(lookups:countStartedLookups("ownership 8801 Asset 9000001")).toBe(1)
			expect(harness.countLoggedWarningsMentioning("ownership timeout")).toBe(1)
			expect(harness.countLoggedWarningsMentioning("ownership check of asset_9000002")).toBe(1)
			expect(harness.countLoggedWarningsMentioning("isOwnedByPlayer is not a boolean")).toBe(1)
		end
	)
end)
