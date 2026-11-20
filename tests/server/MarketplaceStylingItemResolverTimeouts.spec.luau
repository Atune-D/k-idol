-- Lookups and ownership checks that never answer (a Roblox call that hangs). The spec does not
-- cover this; the resolver counts a lookup attempt without an answer after 15 seconds as failed,
-- and answers an ownership check without an answer after 10 seconds with OwnershipCheckFailed.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeMarketplaceItemLookups = require("../Support/FakeMarketplaceItemLookups")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local MarketplaceStylingItemResolverTestHarness = require("../fixtures/MarketplaceStylingItemResolverTestHarness")
local MarketplaceItemLookupRetryQueue = require("../../src/server/MarketplaceItemLookupRetryQueue")
local StylingItemOwnershipRequestAnswerer = require("../../src/server/StylingItemOwnershipRequestAnswerer")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local NEVER_ANSWER = FakeMarketplaceItemLookups.NEVER_ANSWER
local LOOKUP_TIMEOUT_SECONDS = MarketplaceItemLookupRetryQueue.LOOKUP_ATTEMPT_TIMEOUT_SECONDS
local OWNERSHIP_TIMEOUT_SECONDS = StylingItemOwnershipRequestAnswerer.OWNERSHIP_CHECK_TIMEOUT_SECONDS
local PLAYER = MarketplaceStylingItemResolverTestHarness.EXAMPLE_PLAYER_USER_ID

describe("MarketplaceStylingItemResolver lookups that never answer", function()
	it("uses the documented time limits", function()
		expect(LOOKUP_TIMEOUT_SECONDS).toBe(15)
		expect(OWNERSHIP_TIMEOUT_SECONDS).toBe(10)
	end)

	it(
		"retries a details lookup that never answers after the limit and hides the item after the last attempt",
		function()
			local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
			local lookups = harness.fakeMarketplaceItemLookups
			lookups:setItemDetailsAnswers("Asset", 9000001, { NEVER_ANSWER })
			local resolver = harness.marketplaceStylingItemResolver
			resolver:startResolvingWardrobeCatalog()
			harness.advanceSeconds(LOOKUP_TIMEOUT_SECONDS + 1.999)
			expect(lookups:countStartedLookups("details Asset 9000001")).toBe(1)
			harness.advanceSeconds(0.001)
			expect(lookups:countStartedLookups("details Asset 9000001")).toBe(2)
			-- Attempts start at 0, 17, 36 and 59 s; the last one times out at 74 s.
			harness.advanceSeconds(74 - 17 - 0.001)
			expect(lookups:countStartedLookups("details Asset 9000001")).toBe(4)
			expect(resolver:isWardrobeCatalogReady()).toBeFalse()
			harness.advanceSeconds(0.001)
			expect(resolver:isWardrobeCatalogReady()).toBeTrue()
			expect(resolver:readHiddenStylingItemReasonByStylingItemKey()).toEqual({
				asset_9000001 = "ItemDetailsFailedToLoad",
			})
			expect(harness.countLoggedWarningsMentioning("no answer within 15 seconds")).toBe(1)
		end
	)

	it("hides a bundle whose contents lookup never answers", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.fakeMarketplaceItemLookups:setBundleContentsAnswers(9000041, { NEVER_ANSWER })
		harness.marketplaceStylingItemResolver:startResolvingWardrobeCatalog()
		harness.advanceSeconds(300)
		expect(harness.marketplaceStylingItemResolver:readHiddenStylingItemReasonByStylingItemKey()).toEqual({
			bundle_9000041 = "BundleContentsFailedToLoad",
		})
		expect(harness.fakeMarketplaceItemLookups:countStartedLookups("contents 9000041")).toBe(4)
	end)

	it("becomes ready, with nothing available, even when every lookup hangs", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		for _, fakeStylingItem in FakeStylingItemPool.FAKE_STYLING_ITEMS do
			harness.fakeMarketplaceItemLookups:setItemDetailsAnswers(
				fakeStylingItem.marketplaceItemKind,
				fakeStylingItem.marketplaceItemId,
				{ NEVER_ANSWER }
			)
		end
		harness.marketplaceStylingItemResolver:startResolvingWardrobeCatalog()
		harness.advanceSeconds(3600)
		expect(harness.marketplaceStylingItemResolver:isWardrobeCatalogReady()).toBeTrue()
		expect(harness.marketplaceStylingItemResolver:getAvailableStylingItemKeySet()).toEqual({})
		expect(harness.receivedWardrobeCatalogChangedMessages).toEqual({
			{ isWardrobeCatalogReady = true, wardrobeCatalogVersion = 1 },
		})
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
	end)

	it("ignores a late answer after the timeout: no change, no extra lookup, no early readiness", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		local lookups = harness.fakeMarketplaceItemLookups
		lookups:setItemDetailsAnswers("Asset", 9000001, { NEVER_ANSWER })
		local resolver = harness.marketplaceStylingItemResolver
		resolver:startResolvingWardrobeCatalog()
		harness.advanceSeconds(LOOKUP_TIMEOUT_SECONDS + 2) -- attempt 1 timed out; attempt 2 started
		local startedLookupCountBefore = #lookups.startedLookupNames
		lookups:answerNeverAnsweredLookupLate(
			1,
			true,
			FakeMarketplaceItemLookups.buildOnSaleSellableItemDetails("Asset", 9000001)
		)
		expect(resolver:isWardrobeCatalogReady()).toBeFalse()
		expect(#lookups.startedLookupNames).toBe(startedLookupCountBefore)
		expect(resolver.lookupRetryQueue:countLookupAttemptsInFlight()).toBe(1)
		harness.advanceSeconds(3600)
		expect(resolver:readHiddenStylingItemReasonByStylingItemKey()).toEqual({
			asset_9000001 = "ItemDetailsFailedToLoad",
		})
		expect(resolver.lookupRetryQueue:countLookupAttemptsInFlight()).toBe(0)
	end)

	it("uses a late-but-in-time answer, and its timer never fires", function()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes({
			MarketplaceStylingItemResolverTestHarness.defineStylingItem(9100001, "hair", true),
		})
		local lookups = harness.fakeMarketplaceItemLookups
		lookups:setHoldsAnswersUntilReleased(true)
		harness.marketplaceStylingItemResolver:startResolvingWardrobeCatalog()
		harness.advanceSeconds(LOOKUP_TIMEOUT_SECONDS - 0.001)
		lookups:releaseAllPendingAnswers()
		expect(harness.marketplaceStylingItemResolver:getAvailableStylingItemKeySet()).toEqual({ asset_9100001 = true })
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
		harness.advanceSeconds(3600)
		expect(lookups:countStartedLookups("details Asset 9100001")).toBe(1)
		expect(harness.loggedWarnings).toEqual({})
	end)
end)

describe("MarketplaceStylingItemResolver ownership checks that never answer", function()
	local function createReadyHarness()
		local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes()
		harness.startAndRunEveryRetry()
		return harness
	end

	it("answers OwnershipCheckFailed once after the limit and ignores a later answer", function()
		local harness = createReadyHarness()
		harness.fakeMarketplaceItemLookups:setOwnershipAnswers(PLAYER, "Asset", 9000001, { NEVER_ANSWER })
		local receivedAnswers = harness.askOwnership(PLAYER, "asset_9000001")
		harness.advanceSeconds(OWNERSHIP_TIMEOUT_SECONDS - 0.001)
		expect(receivedAnswers).toEqual({})
		harness.advanceSeconds(0.001)
		expect(receivedAnswers).toEqual({ { isAccepted = false, rejectionReason = "OwnershipCheckFailed" } })
		harness.fakeMarketplaceItemLookups:answerNeverAnsweredLookupLate(1, true, true)
		harness.advanceSeconds(3600)
		expect(#receivedAnswers).toBe(1)
		expect(harness.countLoggedWarningsMentioning("no answer within 10 seconds")).toBe(1)
	end)

	it("uses an answer just before the limit, and its timer never fires", function()
		local harness = createReadyHarness()
		harness.fakeMarketplaceItemLookups:setHoldsAnswersUntilReleased(true)
		harness.fakeMarketplaceItemLookups:setOwnershipAnswers(PLAYER, "Asset", 9000001, {
			FakeMarketplaceItemLookups.succeedWith(true),
		})
		local receivedAnswers = harness.askOwnership(PLAYER, "asset_9000001")
		harness.advanceSeconds(OWNERSHIP_TIMEOUT_SECONDS - 0.001)
		harness.fakeMarketplaceItemLookups:releaseAllPendingAnswers()
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
		harness.advanceSeconds(3600)
		expect(receivedAnswers).toEqual({ { isAccepted = true, isOwnedByPlayer = true } })
	end)
end)
