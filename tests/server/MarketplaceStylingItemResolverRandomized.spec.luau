-- Randomized tests of MarketplaceStylingItemResolver: random pools, random fake Roblox answers
-- (failures, raising lookups, lookups that never answer, non-`true` success values, malformed
-- answers, off-sale and unsellable items, bundles), and
-- answers delivered either at once or held and released in random order. Every outcome is
-- checked against an independent statement of the rules (spec §1.2, §2.14).
-- Every failure names the random seed; rerun with IDOLGROW_RANDOM_TEST_SEED=<seed> to repeat it.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeMarketplaceItemLookups = require("../Support/FakeMarketplaceItemLookups")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local MarketplaceStylingItemResolverTestHarness = require("../fixtures/MarketplaceStylingItemResolverTestHarness")
local StylingItemLookup = require("../../src/shared/StylingItemLookup")
local OutfitValidator = require("../../src/shared/OutfitValidator")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local RANDOM_TRIAL_COUNT = 300
local MAXIMUM_ATTEMPTS_PER_LOOKUP = 4
local MAXIMUM_LOOKUPS_IN_FLIGHT = 10
local NEVER_SUCCEEDS = math.huge
-- Far more than every hanging attempt (15 s each) and retry delay of a pool of 25 needs.
local SECONDS_AFTER_WHICH_EVERY_TIMEOUT_AND_RETRY_HAS_RUN = 3600

local RANDOM_ITEM_SLOTS = { "hair", "top", "bottom", "dress", "shoes", "accessory", "makeup_lips" }

local function pickRandomFailedAttemptAnswer(seededRandomNumberGenerator)
	local failureKind = seededRandomNumberGenerator.nextWholeNumberInRange(1, 5)
	if failureKind == 1 then
		return FakeMarketplaceItemLookups.failWith("random failure")
	elseif failureKind == 2 then
		return FakeMarketplaceItemLookups.RAISE_WHILE_STARTING
	elseif failureKind == 3 then
		return FakeMarketplaceItemLookups.NEVER_ANSWER -- a hanging Roblox call: times out
	elseif failureKind == 4 then
		return { wasLookupSuccessful = "yes", lookupAnswer = { itemDisplayName = 42 } } -- not `true`
	end
	return FakeMarketplaceItemLookups.succeedWith({ itemDisplayName = 42 }) -- malformed for both lookups
end

local function isTrueWithChance(seededRandomNumberGenerator, chanceOfTrue: number): boolean
	return seededRandomNumberGenerator.nextFractionBetweenZeroAndOne() < chanceOfTrue
end

-- One random styling item with its scripted answers and the outcome the rules demand.
local function buildRandomStylingItemScenario(seededRandomNumberGenerator, marketplaceItemId: number)
	local itemSlot = seededRandomNumberGenerator.pickRandomListElement(RANDOM_ITEM_SLOTS)
	local marketplaceItemKind = StylingItemLookup.getRequiredMarketplaceItemKindForItemSlot(itemSlot)
	local scenario = {
		stylingItem = MarketplaceStylingItemResolverTestHarness.defineStylingItem(
			marketplaceItemId,
			itemSlot,
			isTrueWithChance(seededRandomNumberGenerator, 0.8)
		),
		failedDetailsAttemptCount = seededRandomNumberGenerator.nextWholeNumberInRange(0, 5),
		isOnSale = isTrueWithChance(seededRandomNumberGenerator, 0.8),
		canBeSoldInThisGame = isTrueWithChance(seededRandomNumberGenerator, 0.8),
		failedContentsAttemptCount = seededRandomNumberGenerator.nextWholeNumberInRange(0, 5),
		bundleContentEntries = {},
		expectedWornAssets = {},
	}
	local finalDetails =
		FakeMarketplaceItemLookups.buildOnSaleSellableItemDetails(marketplaceItemKind, marketplaceItemId)
	finalDetails.isOnSale = scenario.isOnSale
	finalDetails.canBeSoldInThisGame = scenario.canBeSoldInThisGame
	scenario.finalDetails = finalDetails

	if marketplaceItemKind == "Asset" then
		scenario.expectedWornAssets = {
			{ wornAssetId = marketplaceItemId, robloxAssetTypeName = FakeMarketplaceItemLookups.FAKE_ASSET_TYPE_NAME },
		}
		return scenario
	end
	-- Random contents: 0-3 wearable assets and 0-2 non-wearable entries, in random order.
	for wearablePosition = 1, seededRandomNumberGenerator.nextWholeNumberInRange(0, 3) do
		table.insert(scenario.bundleContentEntries, {
			isWearableAsset = true,
			wornAssetId = marketplaceItemId * 10 + wearablePosition,
			robloxAssetTypeName = "FakeRandomAssetType" .. tostring(wearablePosition),
		})
	end
	for _ = 1, seededRandomNumberGenerator.nextWholeNumberInRange(0, 2) do
		table.insert(
			scenario.bundleContentEntries,
			{ isWearableAsset = false, wornAssetId = marketplaceItemId * 10 + 9 }
		)
	end
	seededRandomNumberGenerator.shuffleListInPlace(scenario.bundleContentEntries)
	for _, bundleContentEntry in scenario.bundleContentEntries do
		if bundleContentEntry.isWearableAsset then
			table.insert(scenario.expectedWornAssets, {
				wornAssetId = bundleContentEntry.wornAssetId,
				robloxAssetTypeName = bundleContentEntry.robloxAssetTypeName,
			})
		end
	end
	if #scenario.expectedWornAssets == 0 then
		scenario.failedContentsAttemptCount = NEVER_SUCCEEDS -- nothing wearable: every attempt is unusable
	end
	return scenario
end

local function scriptScenarioAnswers(seededRandomNumberGenerator, fakeMarketplaceItemLookups, scenario)
	local stylingItem = scenario.stylingItem
	local detailsAnswers = {}
	for _ = 1, scenario.failedDetailsAttemptCount do
		table.insert(detailsAnswers, pickRandomFailedAttemptAnswer(seededRandomNumberGenerator))
	end
	table.insert(detailsAnswers, FakeMarketplaceItemLookups.succeedWith(scenario.finalDetails))
	fakeMarketplaceItemLookups:setItemDetailsAnswers(
		stylingItem.marketplaceItemKind,
		stylingItem.marketplaceItemId,
		detailsAnswers
	)
	local contentsAnswers = {}
	for _ = 1, math.min(scenario.failedContentsAttemptCount, MAXIMUM_ATTEMPTS_PER_LOOKUP + 1) do
		table.insert(contentsAnswers, pickRandomFailedAttemptAnswer(seededRandomNumberGenerator))
	end
	if scenario.failedContentsAttemptCount ~= NEVER_SUCCEEDS then
		table.insert(contentsAnswers, FakeMarketplaceItemLookups.succeedWith(scenario.bundleContentEntries))
	end
	fakeMarketplaceItemLookups:setBundleContentsAnswers(stylingItem.marketplaceItemId, contentsAnswers)
end

-- The rules of §1.2, stated independently of the resolver: the expected hidden reason (nil when
-- available) and how many times each lookup must have been started.
local function decideExpectedOutcome(scenario)
	local stylingItem = scenario.stylingItem
	if not stylingItem.isEnabled then
		return { isExpectedAvailable = false, expectedDetailsAttempts = 0, expectedContentsAttempts = 0 }
	end
	if scenario.failedDetailsAttemptCount >= MAXIMUM_ATTEMPTS_PER_LOOKUP then
		return {
			expectedHiddenReason = "ItemDetailsFailedToLoad",
			expectedDetailsAttempts = MAXIMUM_ATTEMPTS_PER_LOOKUP,
			expectedContentsAttempts = 0,
		}
	end
	local expectedDetailsAttempts = scenario.failedDetailsAttemptCount + 1
	local function hiddenWithoutContents(expectedHiddenReason: string)
		return {
			expectedHiddenReason = expectedHiddenReason,
			expectedDetailsAttempts = expectedDetailsAttempts,
			expectedContentsAttempts = 0,
		}
	end
	if not scenario.isOnSale then
		return hiddenWithoutContents("NotOnSale")
	end
	if not scenario.canBeSoldInThisGame then
		return hiddenWithoutContents("NotSellableInThisGame")
	end
	if stylingItem.marketplaceItemKind == "Asset" then
		return {
			isExpectedAvailable = true,
			expectedDetailsAttempts = expectedDetailsAttempts,
			expectedContentsAttempts = 0,
		}
	end
	if scenario.failedContentsAttemptCount >= MAXIMUM_ATTEMPTS_PER_LOOKUP then
		return {
			expectedHiddenReason = "BundleContentsFailedToLoad",
			expectedDetailsAttempts = expectedDetailsAttempts,
			expectedContentsAttempts = MAXIMUM_ATTEMPTS_PER_LOOKUP,
		}
	end
	return {
		isExpectedAvailable = true,
		expectedDetailsAttempts = expectedDetailsAttempts,
		expectedContentsAttempts = scenario.failedContentsAttemptCount + 1,
	}
end

-- Delivers held answers in random order, moving time forward only when nothing is pending, and
-- checks that the catalog is announced only once everything has settled.
local function driveHeldAnswersInRandomOrder(seededRandomNumberGenerator, harness)
	local lookups = harness.fakeMarketplaceItemLookups
	local resolver = harness.marketplaceStylingItemResolver
	for _ = 1, 100000 do
		if resolver:isWardrobeCatalogReady() then
			return
		end
		expect(#harness.receivedWardrobeCatalogChangedMessages).toBe(0)
		expect(resolver:readWardrobeCatalogSnapshotAnswer().wardrobeItems).toEqual({})
		if lookups:countPendingAnswers() > 0 then
			lookups:releasePendingAnswerAt(
				seededRandomNumberGenerator.nextWholeNumberInRange(1, lookups:countPendingAnswers())
			)
		else
			harness.advanceSeconds(seededRandomNumberGenerator.nextWholeNumberInRange(1, 9))
		end
	end
	error("the wardrobe catalog never became ready")
end

local function runRandomResolverTrial(seededRandomNumberGenerator)
	local scenarios = {}
	local stylingItems = {}
	local firstMarketplaceItemId = 9400000 + seededRandomNumberGenerator.nextWholeNumberInRange(0, 1000) * 100
	for itemNumber = 1, seededRandomNumberGenerator.nextWholeNumberInRange(0, 25) do
		local scenario =
			buildRandomStylingItemScenario(seededRandomNumberGenerator, firstMarketplaceItemId + itemNumber)
		table.insert(scenarios, scenario)
		table.insert(stylingItems, scenario.stylingItem)
	end
	local harness = MarketplaceStylingItemResolverTestHarness.createResolverWithFakes(stylingItems)
	local lookups = harness.fakeMarketplaceItemLookups
	for _, scenario in scenarios do
		scriptScenarioAnswers(seededRandomNumberGenerator, lookups, scenario)
	end
	local isHoldingAnswers = isTrueWithChance(seededRandomNumberGenerator, 0.5)
	lookups:setHoldsAnswersUntilReleased(isHoldingAnswers)
	local resolver = harness.marketplaceStylingItemResolver
	resolver:startResolvingWardrobeCatalog()
	if isHoldingAnswers then
		driveHeldAnswersInRandomOrder(seededRandomNumberGenerator, harness)
	else
		harness.advanceSeconds(SECONDS_AFTER_WHICH_EVERY_TIMEOUT_AND_RETRY_HAS_RUN)
	end

	expect(resolver:isWardrobeCatalogReady()).toBeTrue()
	expect(harness.receivedWardrobeCatalogChangedMessages).toEqual({
		{ isWardrobeCatalogReady = true, wardrobeCatalogVersion = 1 },
	})
	expect(lookups.largestPendingLookupCount <= MAXIMUM_LOOKUPS_IN_FLIGHT).toBeTrue()
	-- Every attempt timer was cancelled or has fired; no retry is left waiting.
	expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
	expect(harness.marketplaceStylingItemResolver.lookupRetryQueue:countLookupAttemptsInFlight()).toBe(0)

	local expectedAvailableKeySet = {}
	local expectedHiddenReasonByStylingItemKey = {}
	local expectedWardrobeItems = {}
	local stylingItemByStylingItemKey = StylingItemLookup.buildStylingItemByStylingItemKey(stylingItems)
	local availableStylingItemKeySet = resolver:getAvailableStylingItemKeySet()
	for _, scenario in scenarios do
		local stylingItem = scenario.stylingItem
		local expectedOutcome = decideExpectedOutcome(scenario)
		local kind, id = stylingItem.marketplaceItemKind, stylingItem.marketplaceItemId
		expect(lookups:countStartedLookups(string.format("details %s %d", kind, id))).toBe(
			expectedOutcome.expectedDetailsAttempts
		)
		expect(lookups:countStartedLookups(string.format("contents %d", id))).toBe(
			expectedOutcome.expectedContentsAttempts
		)
		if expectedOutcome.expectedHiddenReason then
			expectedHiddenReasonByStylingItemKey[stylingItem.stylingItemKey] = expectedOutcome.expectedHiddenReason
		end
		if expectedOutcome.isExpectedAvailable then
			expectedAvailableKeySet[stylingItem.stylingItemKey] = true
			table.insert(expectedWardrobeItems, {
				stylingItemKey = stylingItem.stylingItemKey,
				marketplaceItemKind = kind,
				marketplaceItemId = id,
				itemDisplayName = scenario.finalDetails.itemDisplayName,
				priceInRobux = scenario.finalDetails.priceInRobux,
				wornAssets = scenario.expectedWornAssets,
			})
		end
		-- A one-item outfit is valid exactly when the item is available (§1.5 rule 1).
		local verdict = OutfitValidator.validateOutfit(
			{ stylingItem.stylingItemKey },
			stylingItemByStylingItemKey,
			availableStylingItemKeySet
		)
		expect(verdict.isOutfitValid).toBe(expectedOutcome.isExpectedAvailable == true)
	end
	expect(availableStylingItemKeySet).toEqual(expectedAvailableKeySet)
	expect(resolver:readHiddenStylingItemReasonByStylingItemKey()).toEqual(expectedHiddenReasonByStylingItemKey)
	expect(resolver:readWardrobeCatalogSnapshotAnswer()).toEqual({
		isAccepted = true,
		isWardrobeCatalogReady = true,
		wardrobeCatalogVersion = 1,
		wardrobeItems = expectedWardrobeItems,
	})
	local hiddenItemCount = 0
	for _ in expectedHiddenReasonByStylingItemKey do
		hiddenItemCount += 1
	end
	expect(#harness.loggedWarnings).toBe(hiddenItemCount)
end

describe("MarketplaceStylingItemResolver randomized", function()
	it("hides and publishes exactly what the rules demand for random pools and random Roblox answers", function()
		SeededRandomTrials.runSeededRandomTrials(RANDOM_TRIAL_COUNT, runRandomResolverTrial)
	end)
end)
