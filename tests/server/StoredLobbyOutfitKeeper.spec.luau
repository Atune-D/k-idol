-- StoredLobbyOutfitKeeper: the stored-outfit share of the §6.2 row "Unit: wardrobe catalog and
-- stored outfits" (development spec §1.5 table, §2.4, §2.6, §2.13), with the REAL
-- PlayerSaveDataKeeper on fake storage, clock and scheduler, and a fake catalog resolver.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeMarketplaceStylingItemResolver = require("../Support/FakeMarketplaceStylingItemResolver")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local StoredLobbyOutfitKeeper = require("../../src/server/StoredLobbyOutfitKeeper")
local PlayerSaveDataKeeperTestHarness = require("./PlayerSaveDataKeeperTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID
local OTHER_PLAYER = PlayerSaveDataKeeperTestHarness.OTHER_PLAYER_USER_ID
local START = PlayerSaveDataKeeperTestHarness.EXAMPLE_STARTING_UNIX_SECONDS

local KEY_NOT_IN_POOL = FakeStylingItemPool.KEY_NOT_IN_POOL
local DISABLED_HAIR_KEY = FakeStylingItemPool.DISABLED_HAIR_KEY
local DISABLED_DRESS_KEY = FakeStylingItemPool.DISABLED_DRESS_KEY
local HIDDEN_HAIR_KEY = FakeStylingItemPool.HIDDEN_HAIR_KEY
local PINK_TOP_KEY = "asset_9000011"
local BLACK_BOTTOM_KEY = "asset_9000021"
local WHITE_SHOES_KEY = "bundle_9000041"
local PINK_BAG_KEY = "asset_9000051"

-- A save keeper and a started stored-outfit keeper; the catalog is ready (with the fixture's
-- available set, in which HIDDEN_HAIR_KEY is hidden) unless `isCatalogLeftNotReady`.
local function createStoredLobbyOutfitHarness(isCatalogLeftNotReady: boolean?)
	local harness = PlayerSaveDataKeeperTestHarness.createKeeperWithFakes()
	local fakeResolver = FakeMarketplaceStylingItemResolver.new()
	if not isCatalogLeftNotReady then
		fakeResolver:publishWardrobeCatalog(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
	end
	local outfitKeeperWarnings, outfitKeeperInformation = {}, {}
	local storedLobbyOutfitKeeper = StoredLobbyOutfitKeeper.new({
		playerSaveDataKeeper = harness.playerSaveDataKeeper,
		stylingItemByStylingItemKey = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
		marketplaceStylingItemResolver = fakeResolver,
		logger = {
			logInformation = function(_, message: string)
				table.insert(outfitKeeperInformation, message)
			end,
			logWarning = function(_, message: string)
				table.insert(outfitKeeperWarnings, message)
			end,
		},
	})
	storedLobbyOutfitKeeper:startLookingAfterStoredLobbyOutfits()
	local availabilityChangedRecords = {}
	storedLobbyOutfitKeeper:subscribeToStoredLobbyOutfitAvailabilityChanged(function(playerUserId, availability)
		table.insert(availabilityChangedRecords, { playerUserId = playerUserId, availability = availability })
	end)
	harness.recordedSaveKeeperEvents = harness.recordEveryEvent()
	harness.fakeResolver = fakeResolver
	harness.storedLobbyOutfitKeeper = storedLobbyOutfitKeeper
	harness.availabilityChangedRecords = availabilityChangedRecords
	harness.outfitKeeperWarnings = outfitKeeperWarnings
	harness.outfitKeeperInformation = outfitKeeperInformation
	return harness
end

-- Puts a save holding `storedLobbyOutfitStylingItemKeys` in storage and loads it.
local function loadPlayerWithStoredLobbyOutfit(harness, playerUserId: number, storedLobbyOutfitStylingItemKeys: { any })
	local storedSaveData = PlayerSaveDataSchema.createStartingPlayerSaveData(
		PlayerSaveDataKeeperTestHarness.STARTER_DANCE_IDS,
		START - 86400
	)
	storedSaveData.lobbyOutfitStylingItemKeys = storedLobbyOutfitStylingItemKeys
	harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(playerUserId, storedSaveData)
	harness.playerSaveDataKeeper:startLoadingPlayerSaveData(playerUserId)
	harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(playerUserId)
	assert(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId), "the load should have succeeded")
end

local function readInMemoryLobbyOutfit(harness, playerUserId: number)
	return harness.playerSaveDataKeeper:readPlayerSaveDataCopy(playerUserId).lobbyOutfitStylingItemKeys
end

local function readStoredLobbyOutfit(harness, playerUserId: number)
	return harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(playerUserId).lobbyOutfitStylingItemKeys
end

local function countSaveKeeperEvents(harness, eventName: string): number
	local eventCount = 0
	for _, recordedEvent in harness.recordedSaveKeeperEvents do
		if recordedEvent.eventName == eventName then
			eventCount += 1
		end
	end
	return eventCount
end

-- A later save of another kind (a grant), past the 10 s spacing, completed by storage.
local function completeLaterProgressSave(harness, playerUserId: number)
	harness.grantStarCoins(playerUserId, 20)
	harness.advanceSeconds(PlayerSaveDataKeeper.MINIMUM_SECONDS_BETWEEN_SAVE_STARTS)
	expect(harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(playerUserId)).toBeTrue()
end

local function leaveAndCompleteFinalSave(harness, playerUserId: number)
	harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(playerUserId)
	expect(harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(playerUserId)).toBeTrue()
end

local function expectAvailability(harness, playerUserId: number, expectedAvailability)
	expect(harness.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(playerUserId)).toEqual(
		expectedAvailability
	)
end

describe("StoredLobbyOutfitKeeper removal at load (§1.5 table, row 1)", function()
	it("removes a stored key that left the pool, once, without requesting a save", function()
		local harness = createStoredLobbyOutfitHarness()
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { PINK_TOP_KEY, KEY_NOT_IN_POOL, WHITE_SHOES_KEY })
		expect(readInMemoryLobbyOutfit(harness, PLAYER)).toEqual({ PINK_TOP_KEY, WHITE_SHOES_KEY })
		expect(harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)).toBe(1)
		harness.advanceSeconds(60) -- an appearance change requests no save
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(0)
		expect(readStoredLobbyOutfit(harness, PLAYER)).toEqual({ PINK_TOP_KEY, KEY_NOT_IN_POOL, WHITE_SHOES_KEY })
		expect(#harness.outfitKeeperInformation).toBe(1)
		expect(string.find(harness.outfitKeeperInformation[1], KEY_NOT_IN_POOL, 1, true) ~= nil).toBeTrue()
	end)

	it("the removal reaches storage with a later save", function()
		local harness = createStoredLobbyOutfitHarness()
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { PINK_TOP_KEY, KEY_NOT_IN_POOL, WHITE_SHOES_KEY })
		completeLaterProgressSave(harness, PLAYER)
		expect(readStoredLobbyOutfit(harness, PLAYER)).toEqual({ PINK_TOP_KEY, WHITE_SHOES_KEY })
	end)

	it("treats a disabled row the same: removed at load and written by a later save", function()
		local harness = createStoredLobbyOutfitHarness()
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { DISABLED_HAIR_KEY, PINK_TOP_KEY, DISABLED_DRESS_KEY })
		expect(readInMemoryLobbyOutfit(harness, PLAYER)).toEqual({ PINK_TOP_KEY })
		completeLaterProgressSave(harness, PLAYER)
		expect(readStoredLobbyOutfit(harness, PLAYER)).toEqual({ PINK_TOP_KEY })
	end)

	it("removes entries that are not strings (they cannot be keys)", function()
		local harness = createStoredLobbyOutfitHarness()
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { 9000011, PINK_TOP_KEY })
		expect(readInMemoryLobbyOutfit(harness, PLAYER)).toEqual({ PINK_TOP_KEY })
	end)

	it("removes only once: later catalog versions and later changes do not remove again", function()
		local harness = createStoredLobbyOutfitHarness()
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { KEY_NOT_IN_POOL, PINK_TOP_KEY })
		expect(countSaveKeeperEvents(harness, "InMemorySaveDataChanged")).toBe(1)
		harness.fakeResolver:publishWardrobeCatalog(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
		harness.equipDance(PLAYER, "starter_step")
		-- A later change that stores a key outside the pool is not this module's to undo.
		harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(
			PLAYER,
			PlayerSaveDataKeeper.APPEARANCE_CHANGE_SAVED_LATER,
			"test lobby outfit",
			function(saveDataDraft)
				saveDataDraft.lobbyOutfitStylingItemKeys = { KEY_NOT_IN_POOL }
				return true
			end
		)
		expect(readInMemoryLobbyOutfit(harness, PLAYER)).toEqual({ KEY_NOT_IN_POOL })
		expect(harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)).toBe(3)
		expect(#harness.outfitKeeperInformation).toBe(1)
	end)
end)

describe("StoredLobbyOutfitKeeper hidden keys (§1.5 table, row 2; §2.6)", function()
	it("skips a hidden key when dressing, keeps it in the save and reports it as unavailable", function()
		local harness = createStoredLobbyOutfitHarness()
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { HIDDEN_HAIR_KEY, PINK_TOP_KEY, PINK_BAG_KEY })
		expectAvailability(harness, PLAYER, {
			isWardrobeCatalogReady = true,
			lobbyOutfitStylingItemKeys = { HIDDEN_HAIR_KEY, PINK_TOP_KEY, PINK_BAG_KEY },
			unavailableLobbyOutfitStylingItemKeys = { HIDDEN_HAIR_KEY },
			wearableLobbyOutfitStylingItemKeys = { PINK_TOP_KEY, PINK_BAG_KEY },
		})
		expect(readInMemoryLobbyOutfit(harness, PLAYER)).toEqual({ HIDDEN_HAIR_KEY, PINK_TOP_KEY, PINK_BAG_KEY })
		expect(harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)).toBe(0)
	end)

	it("keeps the hidden key after saving and reloading", function()
		local harness = createStoredLobbyOutfitHarness()
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { HIDDEN_HAIR_KEY, KEY_NOT_IN_POOL, PINK_TOP_KEY })
		completeLaterProgressSave(harness, PLAYER)
		leaveAndCompleteFinalSave(harness, PLAYER)
		expect(readStoredLobbyOutfit(harness, PLAYER)).toEqual({ HIDDEN_HAIR_KEY, PINK_TOP_KEY })

		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(readInMemoryLobbyOutfit(harness, PLAYER)).toEqual({ HIDDEN_HAIR_KEY, PINK_TOP_KEY })
		expect(
			harness.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(PLAYER).unavailableLobbyOutfitStylingItemKeys
		).toEqual({ HIDDEN_HAIR_KEY })
		completeLaterProgressSave(harness, PLAYER)
		expect(readStoredLobbyOutfit(harness, PLAYER)).toEqual({ HIDDEN_HAIR_KEY, PINK_TOP_KEY })
	end)

	it("a key hidden by a later catalog version is reported and skipped, and the save is untouched", function()
		local harness = createStoredLobbyOutfitHarness()
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { PINK_TOP_KEY, BLACK_BOTTOM_KEY })
		local availableSetWithoutTop = table.clone(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
		availableSetWithoutTop[PINK_TOP_KEY] = nil
		harness.fakeResolver:publishWardrobeCatalog(availableSetWithoutTop)
		expectAvailability(harness, PLAYER, {
			isWardrobeCatalogReady = true,
			lobbyOutfitStylingItemKeys = { PINK_TOP_KEY, BLACK_BOTTOM_KEY },
			unavailableLobbyOutfitStylingItemKeys = { PINK_TOP_KEY },
			wearableLobbyOutfitStylingItemKeys = { BLACK_BOTTOM_KEY },
		})
		expect(harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)).toBe(0)
		expect(#harness.availabilityChangedRecords).toBe(2)
	end)
end)

describe("StoredLobbyOutfitKeeper no-op (§2.13)", function()
	it("does not change a save with nothing to remove: no revision bump, no event, no save", function()
		for _, storedLobbyOutfitStylingItemKeys in { { PINK_TOP_KEY, WHITE_SHOES_KEY, HIDDEN_HAIR_KEY }, {} } do
			local harness = createStoredLobbyOutfitHarness()
			loadPlayerWithStoredLobbyOutfit(harness, PLAYER, storedLobbyOutfitStylingItemKeys)
			expect(harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)).toBe(0)
			expect(countSaveKeeperEvents(harness, "InMemorySaveDataChanged")).toBe(0)
			expect(readInMemoryLobbyOutfit(harness, PLAYER)).toEqual(storedLobbyOutfitStylingItemKeys)
			expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(0)
			expect(#harness.outfitKeeperInformation).toBe(0)
			expect(#harness.outfitKeeperWarnings).toBe(0)
		end
	end)

	it("an empty stored outfit means the player's own avatar", function()
		local harness = createStoredLobbyOutfitHarness()
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, {})
		expectAvailability(harness, PLAYER, {
			isWardrobeCatalogReady = true,
			lobbyOutfitStylingItemKeys = {},
			unavailableLobbyOutfitStylingItemKeys = {},
			wearableLobbyOutfitStylingItemKeys = {},
		})
	end)
end)

describe("StoredLobbyOutfitKeeper before the wardrobe catalog is ready", function()
	it("loses nothing, reports nothing as unavailable, and is correct once the catalog is ready", function()
		local harness = createStoredLobbyOutfitHarness(true)
		local storedKeys = { HIDDEN_HAIR_KEY, PINK_TOP_KEY, WHITE_SHOES_KEY }
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, storedKeys)
		expect(readInMemoryLobbyOutfit(harness, PLAYER)).toEqual(storedKeys)
		expect(harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)).toBe(0)
		expectAvailability(harness, PLAYER, {
			isWardrobeCatalogReady = false,
			lobbyOutfitStylingItemKeys = storedKeys,
			unavailableLobbyOutfitStylingItemKeys = {},
			wearableLobbyOutfitStylingItemKeys = {},
		})

		harness.fakeResolver:publishWardrobeCatalog(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
		local expectedReadyAvailability = {
			isWardrobeCatalogReady = true,
			lobbyOutfitStylingItemKeys = storedKeys,
			unavailableLobbyOutfitStylingItemKeys = { HIDDEN_HAIR_KEY },
			wearableLobbyOutfitStylingItemKeys = { PINK_TOP_KEY, WHITE_SHOES_KEY },
		}
		expectAvailability(harness, PLAYER, expectedReadyAvailability)
		expect(#harness.availabilityChangedRecords).toBe(2)
		expect(harness.availabilityChangedRecords[2].availability).toEqual(expectedReadyAvailability)
		expect(readInMemoryLobbyOutfit(harness, PLAYER)).toEqual(storedKeys)
		completeLaterProgressSave(harness, PLAYER)
		expect(readStoredLobbyOutfit(harness, PLAYER)).toEqual(storedKeys)
	end)

	it("still removes keys that left the pool, since that depends on the pool alone", function()
		local harness = createStoredLobbyOutfitHarness(true)
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { HIDDEN_HAIR_KEY, KEY_NOT_IN_POOL, PINK_TOP_KEY })
		expect(readInMemoryLobbyOutfit(harness, PLAYER)).toEqual({ HIDDEN_HAIR_KEY, PINK_TOP_KEY })
	end)
end)

describe("StoredLobbyOutfitKeeper availability and its subscription", function()
	it("is nil before the save loads, and tells listeners once at load", function()
		local harness = createStoredLobbyOutfitHarness()
		expect(harness.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(PLAYER)).toBeNil()
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		expect(harness.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(PLAYER)).toBeNil()
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(#harness.availabilityChangedRecords).toBe(1)
		expect(harness.availabilityChangedRecords[1].playerUserId).toBe(PLAYER)
	end)

	it("tells listeners after a removal exactly once, with the save as it is after the removal", function()
		local harness = createStoredLobbyOutfitHarness()
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { KEY_NOT_IN_POOL, PINK_TOP_KEY })
		expect(#harness.availabilityChangedRecords).toBe(1)
		expect(harness.availabilityChangedRecords[1].availability.lobbyOutfitStylingItemKeys).toEqual({ PINK_TOP_KEY })
	end)

	it("does not tell listeners when nothing changed (same catalog again, an unrelated change)", function()
		local harness = createStoredLobbyOutfitHarness()
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { HIDDEN_HAIR_KEY, PINK_TOP_KEY })
		harness.fakeResolver:publishWardrobeCatalog(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
		harness.grantStarCoins(PLAYER, 20)
		expect(#harness.availabilityChangedRecords).toBe(1)
	end)

	it("follows a later change of the stored outfit (e.g. SetLobbyOutfit) and tells listeners", function()
		local harness = createStoredLobbyOutfitHarness()
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, {})
		harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(
			PLAYER,
			PlayerSaveDataKeeper.APPEARANCE_CHANGE_SAVED_LATER,
			"test lobby outfit",
			function(saveDataDraft)
				saveDataDraft.lobbyOutfitStylingItemKeys = { PINK_TOP_KEY, HIDDEN_HAIR_KEY }
				return true
			end
		)
		local expectedAvailability = {
			isWardrobeCatalogReady = true,
			lobbyOutfitStylingItemKeys = { PINK_TOP_KEY, HIDDEN_HAIR_KEY },
			unavailableLobbyOutfitStylingItemKeys = { HIDDEN_HAIR_KEY },
			wearableLobbyOutfitStylingItemKeys = { PINK_TOP_KEY },
		}
		expectAvailability(harness, PLAYER, expectedAvailability)
		expect(#harness.availabilityChangedRecords).toBe(2)
		expect(harness.availabilityChangedRecords[2].availability).toEqual(expectedAvailability)
	end)

	it("hands out deeply frozen availability, and a listener that raises does not stop the next one", function()
		local harness = createStoredLobbyOutfitHarness()
		harness.storedLobbyOutfitKeeper:subscribeToStoredLobbyOutfitAvailabilityChanged(function()
			error("listener exploded")
		end)
		local laterListenerCallCount = 0
		harness.storedLobbyOutfitKeeper:subscribeToStoredLobbyOutfitAvailabilityChanged(function()
			laterListenerCallCount += 1
		end)
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { PINK_TOP_KEY })
		expect(laterListenerCallCount).toBe(1)
		expect(#harness.outfitKeeperWarnings).toBe(1)
		local availability = harness.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(PLAYER)
		expect(table.isfrozen(availability)).toBeTrue()
		expect(table.isfrozen(availability.lobbyOutfitStylingItemKeys)).toBeTrue()
		expect(table.isfrozen(availability.unavailableLobbyOutfitStylingItemKeys)).toBeTrue()
		expect(table.isfrozen(availability.wearableLobbyOutfitStylingItemKeys)).toBeTrue()
	end)

	it("an unsubscribed listener is no longer told", function()
		local harness = createStoredLobbyOutfitHarness()
		local listenerCallCount = 0
		local unsubscribe = harness.storedLobbyOutfitKeeper:subscribeToStoredLobbyOutfitAvailabilityChanged(function()
			listenerCallCount += 1
		end)
		unsubscribe()
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { PINK_TOP_KEY })
		expect(listenerCallCount).toBe(0)
	end)

	it("keeps players apart", function()
		local harness = createStoredLobbyOutfitHarness()
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { KEY_NOT_IN_POOL, PINK_TOP_KEY })
		loadPlayerWithStoredLobbyOutfit(harness, OTHER_PLAYER, { HIDDEN_HAIR_KEY })
		expect(readInMemoryLobbyOutfit(harness, PLAYER)).toEqual({ PINK_TOP_KEY })
		expect(readInMemoryLobbyOutfit(harness, OTHER_PLAYER)).toEqual({ HIDDEN_HAIR_KEY })
		expect(harness.playerSaveDataKeeper:readSaveChangeRevisions(OTHER_PLAYER)).toBe(0)
		expectAvailability(harness, PLAYER, {
			isWardrobeCatalogReady = true,
			lobbyOutfitStylingItemKeys = { PINK_TOP_KEY },
			unavailableLobbyOutfitStylingItemKeys = {},
			wearableLobbyOutfitStylingItemKeys = { PINK_TOP_KEY },
		})
		expect(
			harness.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(OTHER_PLAYER).unavailableLobbyOutfitStylingItemKeys
		).toEqual({ HIDDEN_HAIR_KEY })
	end)
end)

describe("StoredLobbyOutfitKeeper forgetting and setup", function()
	it("forgets a player who leaves, and a later catalog change does not tell anyone about them", function()
		local harness = createStoredLobbyOutfitHarness(true)
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { HIDDEN_HAIR_KEY })
		leaveAndCompleteFinalSave(harness, PLAYER)
		expect(harness.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(PLAYER)).toBeNil()
		harness.fakeResolver:publishWardrobeCatalog(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
		expect(#harness.availabilityChangedRecords).toBe(1)
		expect(harness.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(PLAYER)).toBeNil()
	end)

	it("raises on a missing dependency and on starting twice", function()
		expect(function()
			StoredLobbyOutfitKeeper.new({ logger = {} })
		end).toThrow("missing dependency")
		local harness = createStoredLobbyOutfitHarness()
		expect(function()
			harness.storedLobbyOutfitKeeper:startLookingAfterStoredLobbyOutfits()
		end).toThrow("already called")
		expect(harness.fakeResolver:countCatalogChangedSubscriptions()).toBe(1)
	end)
end)
