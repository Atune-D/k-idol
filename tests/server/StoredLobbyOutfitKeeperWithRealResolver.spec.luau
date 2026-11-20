-- The REAL MarketplaceStylingItemResolver (FakeMarketplaceItemLookups behind it) wired to the REAL
-- StoredLobbyOutfitKeeper and the REAL PlayerSaveDataKeeper on fake storage (development spec
-- §1.5 "Stored outfits that contain unavailable items", §2.4, §2.6, §2.14). The keeper's own spec
-- files use a small fake of the resolver; this file proves the two real modules fit together.
--
-- In every example one lookup never answers (the details lookup of HIDDEN_HAIR_KEY, or in the
-- bundle example the contents lookup of WHITE_SHOES_KEY's bundle), so the resolver's first pass
-- only finishes when that lookup's last attempt has timed out (§2.14: up to 3 retries).

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeMarketplaceItemLookups = require("../Support/FakeMarketplaceItemLookups")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local StoredLobbyOutfitKeeperWithRealResolverTestHarness =
	require("../fixtures/StoredLobbyOutfitKeeperWithRealResolverTestHarness")
local MarketplaceItemLookupRetryQueue = require("../../src/server/MarketplaceItemLookupRetryQueue")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = StoredLobbyOutfitKeeperWithRealResolverTestHarness.EXAMPLE_PLAYER_USER_ID
local OTHER_PLAYER = StoredLobbyOutfitKeeperWithRealResolverTestHarness.OTHER_PLAYER_USER_ID

local KEY_NOT_IN_POOL = FakeStylingItemPool.KEY_NOT_IN_POOL
local DISABLED_DRESS_KEY = FakeStylingItemPool.DISABLED_DRESS_KEY
local HIDDEN_HAIR_KEY = FakeStylingItemPool.HIDDEN_HAIR_KEY -- asset 9000005
local HIDDEN_HAIR_ASSET_ID = 9000005
local PINK_TOP_KEY = "asset_9000011"
local WHITE_SHOES_KEY = "bundle_9000041"
local PINK_BAG_KEY = "asset_9000051"

-- First attempt, then each retry after its delay; every attempt waits the full time limit.
local function computeSecondsUntilEveryAttemptHasTimedOut(): number
	local totalSeconds = MarketplaceItemLookupRetryQueue.LOOKUP_ATTEMPT_TIMEOUT_SECONDS
	for _, retryDelaySeconds in MarketplaceItemLookupRetryQueue.RETRY_DELAY_SECONDS_BY_RETRY_NUMBER do
		totalSeconds += retryDelaySeconds + MarketplaceItemLookupRetryQueue.LOOKUP_ATTEMPT_TIMEOUT_SECONDS
	end
	return totalSeconds
end

local SECONDS_UNTIL_FIRST_PASS_FINISHES = computeSecondsUntilEveryAttemptHasTimedOut() -- 74
local LAST_MILLISECOND_BEFORE_FIRST_PASS_FINISHES = SECONDS_UNTIL_FIRST_PASS_FINISHES - 0.001

-- A wired harness whose resolver has started; HIDDEN_HAIR_KEY's details lookup never answers.
local function createHarnessWithTimingOutHairLookup()
	local harness = StoredLobbyOutfitKeeperWithRealResolverTestHarness.createWiredKeepersWithRealResolver()
	harness.fakeMarketplaceItemLookups:setItemDetailsAnswers(
		"Asset",
		HIDDEN_HAIR_ASSET_ID,
		{ FakeMarketplaceItemLookups.NEVER_ANSWER }
	)
	harness.marketplaceStylingItemResolver:startResolvingWardrobeCatalog()
	return harness
end

local NOT_READY_AVAILABILITY_OF_FOUR_KEYS = {
	isWardrobeCatalogReady = false,
	lobbyOutfitStylingItemKeys = { HIDDEN_HAIR_KEY, PINK_TOP_KEY, WHITE_SHOES_KEY, PINK_BAG_KEY },
	unavailableLobbyOutfitStylingItemKeys = {},
	wearableLobbyOutfitStylingItemKeys = {},
}
local READY_AVAILABILITY_OF_FOUR_KEYS = {
	isWardrobeCatalogReady = true,
	lobbyOutfitStylingItemKeys = { HIDDEN_HAIR_KEY, PINK_TOP_KEY, WHITE_SHOES_KEY, PINK_BAG_KEY },
	unavailableLobbyOutfitStylingItemKeys = { HIDDEN_HAIR_KEY },
	wearableLobbyOutfitStylingItemKeys = { PINK_TOP_KEY, WHITE_SHOES_KEY, PINK_BAG_KEY },
}

describe("Stored outfits with the real resolver: a save loading before the catalog is ready", function()
	it("loses nothing, reports nothing unavailable and touches neither the save nor storage", function()
		local harness = createHarnessWithTimingOutHairLookup()
		harness.loadPlayerWithStoredLobbyOutfit(
			PLAYER,
			{ HIDDEN_HAIR_KEY, PINK_TOP_KEY, WHITE_SHOES_KEY, PINK_BAG_KEY }
		)
		expect(harness.marketplaceStylingItemResolver:isWardrobeCatalogReady()).toBeFalse()
		expect(harness.readAvailability(PLAYER)).toEqual(NOT_READY_AVAILABILITY_OF_FOUR_KEYS)
		expect(harness.readInMemoryLobbyOutfit(PLAYER)).toEqual(
			NOT_READY_AVAILABILITY_OF_FOUR_KEYS.lobbyOutfitStylingItemKeys
		)
		expect(harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)).toBe(0)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(0)
		expect(#harness.outfitKeeperInformation).toBe(0)
		expect(#harness.outfitKeeperWarnings).toBe(0)
		-- Time passes, still before the first pass finishes: still nothing lost or reported.
		harness.advanceSeconds(LAST_MILLISECOND_BEFORE_FIRST_PASS_FINISHES)
		expect(harness.readAvailability(PLAYER)).toEqual(NOT_READY_AVAILABILITY_OF_FOUR_KEYS)
		expect(#harness.listAvailabilityChangedRecordsForPlayer(PLAYER)).toBe(1)
	end)
end)

describe("Stored outfits with the real resolver: when the first pass finishes", function()
	it("makes the lists correct in the same step the catalog-changed event fires", function()
		local harness = createHarnessWithTimingOutHairLookup()
		harness.loadPlayerWithStoredLobbyOutfit(
			PLAYER,
			{ HIDDEN_HAIR_KEY, PINK_TOP_KEY, WHITE_SHOES_KEY, PINK_BAG_KEY }
		)
		harness.advanceSeconds(LAST_MILLISECOND_BEFORE_FIRST_PASS_FINISHES)
		expect(#harness.catalogChangedRecords).toBe(0)
		expect(harness.countLoggedLinesMentioning(harness.resolverInformation, "wardrobe catalog ready")).toBe(0)

		harness.advanceSeconds(0.001)
		expect(harness.countLoggedLinesMentioning(harness.resolverInformation, "wardrobe catalog ready")).toBe(1)
		expect(harness.marketplaceStylingItemResolver:isWardrobeCatalogReady()).toBeTrue()
		expect(#harness.catalogChangedRecords).toBe(1)
		expect(harness.catalogChangedRecords[1].wardrobeCatalogChangedMessage).toEqual({
			isWardrobeCatalogReady = true,
			wardrobeCatalogVersion = 1,
		})
		-- A module told about the catalog after the keeper already sees the correct lists.
		expect(harness.catalogChangedRecords[1].availabilityByPlayerUserIdWhenHeard[PLAYER]).toEqual(
			READY_AVAILABILITY_OF_FOUR_KEYS
		)
		-- The keeper told its listeners exactly once, from inside the resolver's notification, and
		-- never published a ready availability built from an empty or stale available set.
		local playerAvailabilityRecords = harness.listAvailabilityChangedRecordsForPlayer(PLAYER)
		expect(#playerAvailabilityRecords).toBe(2)
		expect(playerAvailabilityRecords[2].wasResolverReadyWhenTold).toBeTrue()
		expect(playerAvailabilityRecords[2].resolverVersionWhenTold).toBe(1)
		expect(playerAvailabilityRecords[2].availability).toEqual(READY_AVAILABILITY_OF_FOUR_KEYS)
		expect(harness.readAvailability(PLAYER)).toEqual(READY_AVAILABILITY_OF_FOUR_KEYS)
	end)

	it("works out every online player again, each from their own save", function()
		local harness = createHarnessWithTimingOutHairLookup()
		harness.loadPlayerWithStoredLobbyOutfit(PLAYER, { PINK_TOP_KEY, HIDDEN_HAIR_KEY })
		harness.loadPlayerWithStoredLobbyOutfit(OTHER_PLAYER, { WHITE_SHOES_KEY })
		harness.advanceSeconds(SECONDS_UNTIL_FIRST_PASS_FINISHES)
		expect(harness.catalogChangedRecords[1].availabilityByPlayerUserIdWhenHeard).toEqual({
			[PLAYER] = {
				isWardrobeCatalogReady = true,
				lobbyOutfitStylingItemKeys = { PINK_TOP_KEY, HIDDEN_HAIR_KEY },
				unavailableLobbyOutfitStylingItemKeys = { HIDDEN_HAIR_KEY },
				wearableLobbyOutfitStylingItemKeys = { PINK_TOP_KEY },
			},
			[OTHER_PLAYER] = {
				isWardrobeCatalogReady = true,
				lobbyOutfitStylingItemKeys = { WHITE_SHOES_KEY },
				unavailableLobbyOutfitStylingItemKeys = {},
				wearableLobbyOutfitStylingItemKeys = { WHITE_SHOES_KEY },
			},
		})
	end)

	it("gives a player whose save loads after the first pass the correct lists at once", function()
		local harness = createHarnessWithTimingOutHairLookup()
		harness.advanceSeconds(SECONDS_UNTIL_FIRST_PASS_FINISHES)
		harness.loadPlayerWithStoredLobbyOutfit(
			PLAYER,
			{ HIDDEN_HAIR_KEY, PINK_TOP_KEY, WHITE_SHOES_KEY, PINK_BAG_KEY }
		)
		local playerAvailabilityRecords = harness.listAvailabilityChangedRecordsForPlayer(PLAYER)
		expect(#playerAvailabilityRecords).toBe(1)
		expect(playerAvailabilityRecords[1].availability).toEqual(READY_AVAILABILITY_OF_FOUR_KEYS)
	end)
end)

describe("Stored outfits with the real resolver: an item hidden because its lookups timed out", function()
	it("is hidden by the resolver, reported as unavailable, and kept in the save through save and reload", function()
		local harness = createHarnessWithTimingOutHairLookup()
		harness.loadPlayerWithStoredLobbyOutfit(
			PLAYER,
			{ HIDDEN_HAIR_KEY, PINK_TOP_KEY, WHITE_SHOES_KEY, PINK_BAG_KEY }
		)
		harness.advanceSeconds(SECONDS_UNTIL_FIRST_PASS_FINISHES)
		expect(harness.marketplaceStylingItemResolver:readHiddenStylingItemReasonByStylingItemKey()).toEqual({
			[HIDDEN_HAIR_KEY] = "ItemDetailsFailedToLoad",
		})
		-- §1.2: an item that cannot be resolved is hidden for the server session and logged.
		expect(
			harness.countLoggedLinesMentioning(
				harness.resolverWarnings,
				"hiding styling item " .. HIDDEN_HAIR_KEY .. " for this server session: ItemDetailsFailedToLoad"
			)
		).toBe(1)
		-- Only the hidden item is logged as hidden.
		local pinkTopHidingLine = "hiding styling item " .. PINK_TOP_KEY
		expect(harness.countLoggedLinesMentioning(harness.resolverWarnings, pinkTopHidingLine)).toBe(0)
		expect(
			harness.fakeMarketplaceItemLookups:countStartedLookups("details Asset " .. tostring(HIDDEN_HAIR_ASSET_ID))
		).toBe(MarketplaceItemLookupRetryQueue.MAXIMUM_RETRY_COUNT + 1)
		expect(harness.readAvailability(PLAYER).unavailableLobbyOutfitStylingItemKeys).toEqual({ HIDDEN_HAIR_KEY })

		harness.completeLaterProgressSave(PLAYER)
		harness.leaveAndCompleteFinalSave(PLAYER)
		expect(harness.readStoredLobbyOutfit(PLAYER)).toEqual(
			READY_AVAILABILITY_OF_FOUR_KEYS.lobbyOutfitStylingItemKeys
		)
		expect(harness.readAvailability(PLAYER)).toBeNil()

		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.readAvailability(PLAYER)).toEqual(READY_AVAILABILITY_OF_FOUR_KEYS)
		expect(harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)).toBe(0)
	end)

	it("stays hidden and reported when a timed-out lookup answers very late", function()
		local harness = createHarnessWithTimingOutHairLookup()
		harness.loadPlayerWithStoredLobbyOutfit(
			PLAYER,
			{ HIDDEN_HAIR_KEY, PINK_TOP_KEY, WHITE_SHOES_KEY, PINK_BAG_KEY }
		)
		harness.advanceSeconds(SECONDS_UNTIL_FIRST_PASS_FINISHES)
		local availabilityRecordCountBeforeLateAnswers = #harness.availabilityChangedRecords
		for neverAnsweredPosition in harness.fakeMarketplaceItemLookups.neverAnsweredLookups do
			harness.fakeMarketplaceItemLookups:answerNeverAnsweredLookupLate(
				neverAnsweredPosition,
				true,
				FakeMarketplaceItemLookups.buildOnSaleSellableItemDetails("Asset", HIDDEN_HAIR_ASSET_ID)
			)
		end
		expect(harness.marketplaceStylingItemResolver:getAvailableStylingItemKeySet()[HIDDEN_HAIR_KEY]).toBeNil()
		expect(#harness.availabilityChangedRecords).toBe(availabilityRecordCountBeforeLateAnswers)
		expect(harness.readAvailability(PLAYER)).toEqual(READY_AVAILABILITY_OF_FOUR_KEYS)
	end)

	it("treats a bundle whose contents lookup timed out the same way", function()
		local harness = StoredLobbyOutfitKeeperWithRealResolverTestHarness.createWiredKeepersWithRealResolver()
		harness.fakeMarketplaceItemLookups:setBundleContentsAnswers(
			9000041,
			{ FakeMarketplaceItemLookups.NEVER_ANSWER }
		)
		harness.marketplaceStylingItemResolver:startResolvingWardrobeCatalog()
		harness.loadPlayerWithStoredLobbyOutfit(PLAYER, { WHITE_SHOES_KEY, PINK_TOP_KEY })
		harness.advanceSeconds(SECONDS_UNTIL_FIRST_PASS_FINISHES)
		expect(harness.marketplaceStylingItemResolver:readHiddenStylingItemReasonByStylingItemKey()).toEqual({
			[WHITE_SHOES_KEY] = "BundleContentsFailedToLoad",
		})
		expect(
			harness.countLoggedLinesMentioning(
				harness.resolverWarnings,
				"hiding styling item " .. WHITE_SHOES_KEY .. " for this server session: BundleContentsFailedToLoad"
			)
		).toBe(1)
		expect(harness.readAvailability(PLAYER)).toEqual({
			isWardrobeCatalogReady = true,
			lobbyOutfitStylingItemKeys = { WHITE_SHOES_KEY, PINK_TOP_KEY },
			unavailableLobbyOutfitStylingItemKeys = { WHITE_SHOES_KEY },
			wearableLobbyOutfitStylingItemKeys = { PINK_TOP_KEY },
		})
		expect(harness.readInMemoryLobbyOutfit(PLAYER)).toEqual({ WHITE_SHOES_KEY, PINK_TOP_KEY })
	end)
end)

describe("Stored outfits with the real resolver: a key that left the pool", function()
	it("is removed once at load, before the catalog is ready, and the removal reaches storage", function()
		local harness = createHarnessWithTimingOutHairLookup()
		harness.loadPlayerWithStoredLobbyOutfit(
			PLAYER,
			{ KEY_NOT_IN_POOL, HIDDEN_HAIR_KEY, DISABLED_DRESS_KEY, PINK_TOP_KEY }
		)
		expect(harness.readInMemoryLobbyOutfit(PLAYER)).toEqual({ HIDDEN_HAIR_KEY, PINK_TOP_KEY })
		expect(harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)).toBe(1)
		expect(harness.readAvailability(PLAYER)).toEqual({
			isWardrobeCatalogReady = false,
			lobbyOutfitStylingItemKeys = { HIDDEN_HAIR_KEY, PINK_TOP_KEY },
			unavailableLobbyOutfitStylingItemKeys = {},
			wearableLobbyOutfitStylingItemKeys = {},
		})

		harness.advanceSeconds(SECONDS_UNTIL_FIRST_PASS_FINISHES)
		expect(harness.readAvailability(PLAYER)).toEqual({
			isWardrobeCatalogReady = true,
			lobbyOutfitStylingItemKeys = { HIDDEN_HAIR_KEY, PINK_TOP_KEY },
			unavailableLobbyOutfitStylingItemKeys = { HIDDEN_HAIR_KEY },
			wearableLobbyOutfitStylingItemKeys = { PINK_TOP_KEY },
		})
		-- The catalog becoming ready removes nothing more.
		expect(harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)).toBe(1)
		expect(#harness.outfitKeeperInformation).toBe(1)

		harness.completeLaterProgressSave(PLAYER)
		expect(harness.readStoredLobbyOutfit(PLAYER)).toEqual({ HIDDEN_HAIR_KEY, PINK_TOP_KEY })
	end)

	it("is removed the same way when the save loads after the catalog is ready", function()
		local harness = createHarnessWithTimingOutHairLookup()
		harness.advanceSeconds(SECONDS_UNTIL_FIRST_PASS_FINISHES)
		harness.loadPlayerWithStoredLobbyOutfit(PLAYER, { PINK_TOP_KEY, KEY_NOT_IN_POOL, HIDDEN_HAIR_KEY })
		expect(harness.readInMemoryLobbyOutfit(PLAYER)).toEqual({ PINK_TOP_KEY, HIDDEN_HAIR_KEY })
		expect(harness.readAvailability(PLAYER)).toEqual({
			isWardrobeCatalogReady = true,
			lobbyOutfitStylingItemKeys = { PINK_TOP_KEY, HIDDEN_HAIR_KEY },
			unavailableLobbyOutfitStylingItemKeys = { HIDDEN_HAIR_KEY },
			wearableLobbyOutfitStylingItemKeys = { PINK_TOP_KEY },
		})
		expect(#harness.listAvailabilityChangedRecordsForPlayer(PLAYER)).toBe(1)
	end)
end)
