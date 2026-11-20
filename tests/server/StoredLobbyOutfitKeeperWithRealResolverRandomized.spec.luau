-- The REAL MarketplaceStylingItemResolver wired to the REAL StoredLobbyOutfitKeeper and the REAL
-- PlayerSaveDataKeeper, over random lookup outcomes (development spec §1.2, §1.5 table, §2.6,
-- §2.14). Every enabled item of the fake pool gets a random fate: available, available after 1-3
-- failed attempts, hidden after 4 failed or timed-out attempts, not on sale, not sellable here,
-- or (a bundle) contents timed out. One or two players with random stored outfits load either
-- before any lookup has answered or after every retry has run.
-- The expectations are worked out here from the scripted fates and the §1.5 table, never by
-- asking the resolver or StoredLobbyOutfitResolver. A failure names the seed (SeededRandomTrials).

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeMarketplaceItemLookups = require("../Support/FakeMarketplaceItemLookups")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local RandomValidOutfitGenerator = require("../fixtures/RandomValidOutfitGenerator")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local StoredLobbyOutfitKeeperWithRealResolverTestHarness =
	require("../fixtures/StoredLobbyOutfitKeeperWithRealResolverTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

type SeededRandomNumberGenerator = SeededRandomTrials.SeededRandomNumberGenerator

local RANDOM_TRIAL_COUNT = 120
local SECONDS_AFTER_WHICH_EVERY_RETRY_AND_TIMEOUT_HAS_RUN = 300

local PLAYER_USER_IDS = table.freeze({
	StoredLobbyOutfitKeeperWithRealResolverTestHarness.EXAMPLE_PLAYER_USER_ID,
	StoredLobbyOutfitKeeperWithRealResolverTestHarness.OTHER_PLAYER_USER_ID,
})

-- Stored entries that §1.5 row 1 removes at load: not in the pool, disabled rows, not a string.
local REMOVABLE_STORED_ENTRIES = table.freeze({
	FakeStylingItemPool.KEY_NOT_IN_POOL,
	FakeStylingItemPool.DISABLED_HAIR_KEY,
	FakeStylingItemPool.DISABLED_DRESS_KEY,
	9000011,
})

local ASSET_LOOKUP_FATES = table.freeze({
	"Available",
	"Available",
	"Available",
	"AvailableAfterFailedAttempts",
	"DetailsFailEveryAttempt",
	"DetailsTimeOutEveryAttempt",
	"NotOnSale",
	"NotSellableInThisGame",
})
local BUNDLE_ONLY_LOOKUP_FATES = table.freeze({ "BundleContentsTimeOutEveryAttempt" })

local HIDDEN_LOOKUP_FATES = table.freeze({
	DetailsFailEveryAttempt = true,
	DetailsTimeOutEveryAttempt = true,
	NotOnSale = true,
	NotSellableInThisGame = true,
	BundleContentsTimeOutEveryAttempt = true,
})

-- Scripts one item's lookups for its fate; returns true when the fate hides the item.
local function scriptLookupFate(
	fakeMarketplaceItemLookups,
	seededRandomNumberGenerator: SeededRandomNumberGenerator,
	stylingItem,
	lookupFate: string
): boolean
	local marketplaceItemKind, marketplaceItemId = stylingItem.marketplaceItemKind, stylingItem.marketplaceItemId
	local onSaleSellableItemDetails =
		FakeMarketplaceItemLookups.buildOnSaleSellableItemDetails(marketplaceItemKind, marketplaceItemId)
	if lookupFate == "AvailableAfterFailedAttempts" then
		local scriptedAnswers = {}
		for _ = 1, seededRandomNumberGenerator.nextWholeNumberInRange(1, 3) do
			table.insert(
				scriptedAnswers,
				if seededRandomNumberGenerator.nextWholeNumberInRange(1, 2) == 1
					then FakeMarketplaceItemLookups.failWith("random failure")
					else FakeMarketplaceItemLookups.NEVER_ANSWER
			)
		end
		table.insert(scriptedAnswers, FakeMarketplaceItemLookups.succeedWith(onSaleSellableItemDetails))
		fakeMarketplaceItemLookups:setItemDetailsAnswers(marketplaceItemKind, marketplaceItemId, scriptedAnswers)
	elseif lookupFate == "DetailsFailEveryAttempt" then
		fakeMarketplaceItemLookups:setItemDetailsAnswers(
			marketplaceItemKind,
			marketplaceItemId,
			{ FakeMarketplaceItemLookups.failWith("random failure") }
		)
	elseif lookupFate == "DetailsTimeOutEveryAttempt" then
		fakeMarketplaceItemLookups:setItemDetailsAnswers(
			marketplaceItemKind,
			marketplaceItemId,
			{ FakeMarketplaceItemLookups.NEVER_ANSWER }
		)
	elseif lookupFate == "NotOnSale" or lookupFate == "NotSellableInThisGame" then
		local refusingItemDetails = table.clone(onSaleSellableItemDetails)
		if lookupFate == "NotOnSale" then
			refusingItemDetails.isOnSale = false
		else
			refusingItemDetails.canBeSoldInThisGame = false
		end
		fakeMarketplaceItemLookups:setItemDetailsAnswers(
			marketplaceItemKind,
			marketplaceItemId,
			{ FakeMarketplaceItemLookups.succeedWith(refusingItemDetails) }
		)
	elseif lookupFate == "BundleContentsTimeOutEveryAttempt" then
		fakeMarketplaceItemLookups:setBundleContentsAnswers(
			marketplaceItemId,
			{ FakeMarketplaceItemLookups.NEVER_ANSWER }
		)
	end
	return HIDDEN_LOOKUP_FATES[lookupFate] == true
end

local function scriptRandomLookupFates(fakeMarketplaceItemLookups, seededRandomNumberGenerator): { [string]: boolean }
	local expectedHiddenStylingItemKeySet = {}
	for _, stylingItem in FakeStylingItemPool.FAKE_STYLING_ITEMS do
		if stylingItem.isEnabled then
			local candidateFates = table.clone(ASSET_LOOKUP_FATES)
			if stylingItem.marketplaceItemKind == "Bundle" then
				table.move(BUNDLE_ONLY_LOOKUP_FATES, 1, #BUNDLE_ONLY_LOOKUP_FATES, #candidateFates + 1, candidateFates)
			end
			local lookupFate = seededRandomNumberGenerator.pickRandomListElement(candidateFates)
			if scriptLookupFate(fakeMarketplaceItemLookups, seededRandomNumberGenerator, stylingItem, lookupFate) then
				expectedHiddenStylingItemKeySet[stylingItem.stylingItemKey] = true
			end
		end
	end
	return expectedHiddenStylingItemKeySet
end

-- A valid outfit of enabled items with zero to three removable entries inserted at random places.
local function generateRandomStoredLobbyOutfit(seededRandomNumberGenerator): { any }
	local storedLobbyOutfit =
		RandomValidOutfitGenerator.generateRandomValidOutfitStylingItemKeys(seededRandomNumberGenerator)
	for _ = 1, seededRandomNumberGenerator.nextWholeNumberInRange(0, 3) do
		table.insert(
			storedLobbyOutfit,
			seededRandomNumberGenerator.nextWholeNumberInRange(1, #storedLobbyOutfit + 1),
			seededRandomNumberGenerator.pickRandomListElement(REMOVABLE_STORED_ENTRIES)
		)
	end
	return storedLobbyOutfit
end

local function listKeptStoredEntries(storedLobbyOutfit: { any }): { string }
	local keptStoredEntries = {}
	for _, storedEntry in storedLobbyOutfit do
		if not table.find(REMOVABLE_STORED_ENTRIES, storedEntry) then
			table.insert(keptStoredEntries, storedEntry)
		end
	end
	return keptStoredEntries
end

-- §1.5 table and §2.6, worked out from the scripted fates. The kept part of a valid outfit stays
-- valid, so every kept key that is not hidden is worn.
local function buildExpectedReadyAvailability(keptStoredEntries: { string }, expectedHiddenStylingItemKeySet)
	local unavailableStylingItemKeys, wearableStylingItemKeys = {}, {}
	for _, keptStylingItemKey in keptStoredEntries do
		if expectedHiddenStylingItemKeySet[keptStylingItemKey] then
			table.insert(unavailableStylingItemKeys, keptStylingItemKey)
		else
			table.insert(wearableStylingItemKeys, keptStylingItemKey)
		end
	end
	return {
		isWardrobeCatalogReady = true,
		lobbyOutfitStylingItemKeys = keptStoredEntries,
		unavailableLobbyOutfitStylingItemKeys = unavailableStylingItemKeys,
		wearableLobbyOutfitStylingItemKeys = wearableStylingItemKeys,
	}
end

local function runOneRandomTrial(seededRandomNumberGenerator: SeededRandomNumberGenerator)
	local harness = StoredLobbyOutfitKeeperWithRealResolverTestHarness.createWiredKeepersWithRealResolver()
	local lookups = harness.fakeMarketplaceItemLookups
	local expectedHiddenStylingItemKeySet = scriptRandomLookupFates(lookups, seededRandomNumberGenerator)
	lookups:setHoldsAnswersUntilReleased(true)
	harness.marketplaceStylingItemResolver:startResolvingWardrobeCatalog()

	local onlinePlayerUserIds = table.clone(PLAYER_USER_IDS)
	if seededRandomNumberGenerator.nextWholeNumberInRange(1, 2) == 1 then
		table.remove(onlinePlayerUserIds)
	end
	local storedLobbyOutfitByPlayerUserId, loadsBeforeAnyAnswerByPlayerUserId = {}, {}
	for _, playerUserId in onlinePlayerUserIds do
		storedLobbyOutfitByPlayerUserId[playerUserId] = generateRandomStoredLobbyOutfit(seededRandomNumberGenerator)
		loadsBeforeAnyAnswerByPlayerUserId[playerUserId] = seededRandomNumberGenerator.nextWholeNumberInRange(1, 2) == 1
	end

	-- Loads before any lookup has answered: nothing lost, nothing reported (§1.5 row 2).
	for _, playerUserId in onlinePlayerUserIds do
		if loadsBeforeAnyAnswerByPlayerUserId[playerUserId] then
			harness.loadPlayerWithStoredLobbyOutfit(playerUserId, storedLobbyOutfitByPlayerUserId[playerUserId])
			local keptStoredEntries = listKeptStoredEntries(storedLobbyOutfitByPlayerUserId[playerUserId])
			expect(harness.readInMemoryLobbyOutfit(playerUserId)).toEqual(keptStoredEntries)
			expect(harness.readAvailability(playerUserId)).toEqual({
				isWardrobeCatalogReady = false,
				lobbyOutfitStylingItemKeys = keptStoredEntries,
				unavailableLobbyOutfitStylingItemKeys = {},
				wearableLobbyOutfitStylingItemKeys = {},
			})
		end
	end

	lookups:setHoldsAnswersUntilReleased(false)
	lookups:releaseAllPendingAnswers()
	harness.advanceSeconds(SECONDS_AFTER_WHICH_EVERY_RETRY_AND_TIMEOUT_HAS_RUN)
	expect(harness.marketplaceStylingItemResolver:isWardrobeCatalogReady()).toBeTrue()
	local hiddenStylingItemKeySet = {}
	for hiddenStylingItemKey in harness.marketplaceStylingItemResolver:readHiddenStylingItemReasonByStylingItemKey() do
		hiddenStylingItemKeySet[hiddenStylingItemKey] = true
	end
	expect(hiddenStylingItemKeySet).toEqual(expectedHiddenStylingItemKeySet)

	for _, playerUserId in onlinePlayerUserIds do
		if not loadsBeforeAnyAnswerByPlayerUserId[playerUserId] then
			harness.loadPlayerWithStoredLobbyOutfit(playerUserId, storedLobbyOutfitByPlayerUserId[playerUserId])
		end
	end

	expect(#harness.catalogChangedRecords).toBe(1)
	for _, playerUserId in onlinePlayerUserIds do
		local keptStoredEntries = listKeptStoredEntries(storedLobbyOutfitByPlayerUserId[playerUserId])
		local expectedReadyAvailability =
			buildExpectedReadyAvailability(keptStoredEntries, expectedHiddenStylingItemKeySet)
		expect(harness.readAvailability(playerUserId)).toEqual(expectedReadyAvailability)
		expect(harness.readInMemoryLobbyOutfit(playerUserId)).toEqual(keptStoredEntries)

		-- Listeners were told once at load and, for an early load, once more when the catalog
		-- became ready, from inside that notification and already with the correct lists.
		local playerAvailabilityRecords = harness.listAvailabilityChangedRecordsForPlayer(playerUserId)
		local lastAvailabilityRecord = playerAvailabilityRecords[#playerAvailabilityRecords]
		expect(lastAvailabilityRecord.wasResolverReadyWhenTold).toBeTrue()
		expect(lastAvailabilityRecord.availability).toEqual(expectedReadyAvailability)
		if loadsBeforeAnyAnswerByPlayerUserId[playerUserId] then
			expect(#playerAvailabilityRecords).toBe(2)
			expect(harness.catalogChangedRecords[1].availabilityByPlayerUserIdWhenHeard[playerUserId]).toEqual(
				expectedReadyAvailability
			)
		else
			expect(#playerAvailabilityRecords).toBe(1)
		end

		-- Hidden keys survive a later save; removed entries do not reach storage again.
		harness.completeLaterProgressSave(playerUserId)
		expect(harness.readStoredLobbyOutfit(playerUserId)).toEqual(keptStoredEntries)
	end
end

describe("Stored outfits with the real resolver over random lookup outcomes", function()
	it("never loses a hidden key, reports exactly the hidden ones, and removes only keys that left the pool", function()
		SeededRandomTrials.runSeededRandomTrials(RANDOM_TRIAL_COUNT, function(seededRandomNumberGenerator)
			runOneRandomTrial(seededRandomNumberGenerator)
		end)
	end)
end)
