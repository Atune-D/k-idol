-- StoredLobbyOutfitKeeper: catalog changes with several online players, listeners that change the
-- subscription list while being told, other "loaded" listeners that act before this keeper, a
-- save change that is not applied or raises, and a damaged stored value that is not a list.
-- Uses the REAL PlayerSaveDataKeeper; a stand-in forwards to it only where the real keeper
-- cannot produce the situation on demand (named in the test).

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeMarketplaceStylingItemResolver = require("../Support/FakeMarketplaceStylingItemResolver")
local StandInPlayerSaveDataKeeper = require("../Support/StandInPlayerSaveDataKeeper")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local StoredLobbyOutfitKeeper = require("../../src/server/StoredLobbyOutfitKeeper")
local PlayerSaveDataKeeperTestHarness = require("./PlayerSaveDataKeeperTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID
local SECOND_PLAYER = PLAYER + 1
local THIRD_PLAYER = PLAYER + 2
local START = PlayerSaveDataKeeperTestHarness.EXAMPLE_STARTING_UNIX_SECONDS

local KEY_NOT_IN_POOL = FakeStylingItemPool.KEY_NOT_IN_POOL
local HIDDEN_HAIR_KEY = FakeStylingItemPool.HIDDEN_HAIR_KEY
local PINK_TOP_KEY = "asset_9000011"
local BLACK_BOTTOM_KEY = "asset_9000021"
local WHITE_SHOES_KEY = "bundle_9000041"
local PINK_BAG_KEY = "asset_9000051"

-- options: isCatalogLeftNotReady, subscribeBeforeOutfitKeeper(harness) (runs before this keeper
-- subscribes), replacementSaveKeeperMethodsByName (wraps the real keeper in a stand-in).
local function createStoredLobbyOutfitHarness(options)
	local harness = PlayerSaveDataKeeperTestHarness.createKeeperWithFakes()
	local fakeResolver = FakeMarketplaceStylingItemResolver.new()
	if not options.isCatalogLeftNotReady then
		fakeResolver:publishWardrobeCatalog(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
	end
	if options.subscribeBeforeOutfitKeeper then
		options.subscribeBeforeOutfitKeeper(harness)
	end
	local saveKeeperSeenByOutfitKeeper = harness.playerSaveDataKeeper
	if options.replacementSaveKeeperMethodsByName then
		saveKeeperSeenByOutfitKeeper =
			StandInPlayerSaveDataKeeper.new(harness.playerSaveDataKeeper, options.replacementSaveKeeperMethodsByName)
	end
	local outfitKeeperWarnings, outfitKeeperInformation = {}, {}
	local storedLobbyOutfitKeeper = StoredLobbyOutfitKeeper.new({
		playerSaveDataKeeper = saveKeeperSeenByOutfitKeeper,
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
	local availabilityChangedCountByPlayerUserId = {}
	storedLobbyOutfitKeeper:subscribeToStoredLobbyOutfitAvailabilityChanged(function(playerUserId)
		availabilityChangedCountByPlayerUserId[playerUserId] = (
			availabilityChangedCountByPlayerUserId[playerUserId] or 0
		) + 1
	end)
	harness.fakeResolver = fakeResolver
	harness.storedLobbyOutfitKeeper = storedLobbyOutfitKeeper
	harness.availabilityChangedCountByPlayerUserId = availabilityChangedCountByPlayerUserId
	harness.outfitKeeperWarnings = outfitKeeperWarnings
	harness.outfitKeeperInformation = outfitKeeperInformation
	return harness
end

local function putStoredLobbyOutfitInStorage(harness, playerUserId: number, storedLobbyOutfitStylingItemKeys: any)
	local storedSaveData = PlayerSaveDataSchema.createStartingPlayerSaveData(
		PlayerSaveDataKeeperTestHarness.STARTER_DANCE_IDS,
		START - 86400
	)
	storedSaveData.lobbyOutfitStylingItemKeys = storedLobbyOutfitStylingItemKeys
	harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(playerUserId, storedSaveData)
end

local function loadPlayerWithStoredLobbyOutfit(harness, playerUserId: number, storedLobbyOutfitStylingItemKeys: any)
	putStoredLobbyOutfitInStorage(harness, playerUserId, storedLobbyOutfitStylingItemKeys)
	harness.playerSaveDataKeeper:startLoadingPlayerSaveData(playerUserId)
	harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(playerUserId)
end

local function expectAvailability(harness, playerUserId: number, expectedAvailability)
	expect(harness.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(playerUserId)).toEqual(
		expectedAvailability
	)
end

local function readyAvailability(storedKeys, unavailableKeys, wearableKeys)
	return {
		isWardrobeCatalogReady = true,
		lobbyOutfitStylingItemKeys = storedKeys,
		unavailableLobbyOutfitStylingItemKeys = unavailableKeys,
		wearableLobbyOutfitStylingItemKeys = wearableKeys,
	}
end

describe("StoredLobbyOutfitKeeper catalog changes with several online players", function()
	it("refreshes every player when the catalog becomes ready and when its version changes", function()
		local harness = createStoredLobbyOutfitHarness({ isCatalogLeftNotReady = true })
		local firstStoredKeys = { HIDDEN_HAIR_KEY, PINK_TOP_KEY }
		local secondStoredKeys = { PINK_TOP_KEY, BLACK_BOTTOM_KEY }
		local thirdStoredKeys = { PINK_BAG_KEY }
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, firstStoredKeys)
		loadPlayerWithStoredLobbyOutfit(harness, SECOND_PLAYER, secondStoredKeys)
		loadPlayerWithStoredLobbyOutfit(harness, THIRD_PLAYER, thirdStoredKeys)

		harness.fakeResolver:publishWardrobeCatalog(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
		expectAvailability(harness, PLAYER, readyAvailability(firstStoredKeys, { HIDDEN_HAIR_KEY }, { PINK_TOP_KEY }))
		expectAvailability(harness, SECOND_PLAYER, readyAvailability(secondStoredKeys, {}, secondStoredKeys))
		expectAvailability(harness, THIRD_PLAYER, readyAvailability(thirdStoredKeys, {}, thirdStoredKeys))
		expect(harness.availabilityChangedCountByPlayerUserId).toEqual({
			[PLAYER] = 2,
			[SECOND_PLAYER] = 2,
			[THIRD_PLAYER] = 2,
		})

		local availableSetWithoutTop = table.clone(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
		availableSetWithoutTop[PINK_TOP_KEY] = nil
		harness.fakeResolver:publishWardrobeCatalog(availableSetWithoutTop)
		expectAvailability(harness, PLAYER, readyAvailability(firstStoredKeys, firstStoredKeys, {}))
		expectAvailability(
			harness,
			SECOND_PLAYER,
			readyAvailability(secondStoredKeys, { PINK_TOP_KEY }, { BLACK_BOTTOM_KEY })
		)
		expectAvailability(harness, THIRD_PLAYER, readyAvailability(thirdStoredKeys, {}, thirdStoredKeys))
		-- The third player's outfit does not involve the top, so they are not told again.
		expect(harness.availabilityChangedCountByPlayerUserId).toEqual({
			[PLAYER] = 3,
			[SECOND_PLAYER] = 3,
			[THIRD_PLAYER] = 2,
		})
	end)
end)

describe("StoredLobbyOutfitKeeper listeners that change the subscription list", function()
	it("a listener that unsubscribes itself while being told does not make a later listener be skipped", function()
		local harness = createStoredLobbyOutfitHarness({})
		local unsubscribeSelf
		local selfUnsubscribingCallCount, laterListenerCallCount = 0, 0
		unsubscribeSelf = harness.storedLobbyOutfitKeeper:subscribeToStoredLobbyOutfitAvailabilityChanged(function()
			selfUnsubscribingCallCount += 1
			unsubscribeSelf()
		end)
		harness.storedLobbyOutfitKeeper:subscribeToStoredLobbyOutfitAvailabilityChanged(function()
			laterListenerCallCount += 1
		end)
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { PINK_TOP_KEY })
		loadPlayerWithStoredLobbyOutfit(harness, SECOND_PLAYER, { PINK_TOP_KEY })
		expect(selfUnsubscribingCallCount).toBe(1)
		expect(laterListenerCallCount).toBe(2)
	end)

	it("refuses a listener that is not a function", function()
		local harness = createStoredLobbyOutfitHarness({})
		expect(function()
			harness.storedLobbyOutfitKeeper:subscribeToStoredLobbyOutfitAvailabilityChanged("not a function" :: any)
		end).toThrow("listener must be a function")
	end)
end)

describe("StoredLobbyOutfitKeeper and other 'loaded' listeners that act first", function()
	it("an earlier 'loaded' listener that changes the save does not make listeners be told twice or early", function()
		local harness = createStoredLobbyOutfitHarness({
			subscribeBeforeOutfitKeeper = function(harnessBeingBuilt)
				harnessBeingBuilt.playerSaveDataKeeper:subscribeToPlayerSaveDataLoaded(function(playerUserId)
					harnessBeingBuilt.equipDance(playerUserId, "starter_step")
				end)
			end,
		})
		local toldAvailabilities = {}
		harness.storedLobbyOutfitKeeper:subscribeToStoredLobbyOutfitAvailabilityChanged(function(_, availability)
			table.insert(toldAvailabilities, availability)
		end)
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { KEY_NOT_IN_POOL, PINK_TOP_KEY })
		expect(toldAvailabilities).toEqual({ readyAvailability({ PINK_TOP_KEY }, {}, { PINK_TOP_KEY }) })
		expect(harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)).toBe(2)
	end)

	it(
		"a player removed by an earlier 'loaded' listener is not reported, nor logged as cleaned, and loses nothing",
		function()
			local harness = createStoredLobbyOutfitHarness({
				subscribeBeforeOutfitKeeper = function(harnessBeingBuilt)
					harnessBeingBuilt.playerSaveDataKeeper:subscribeToPlayerSaveDataLoaded(function(playerUserId)
						harnessBeingBuilt.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(playerUserId)
					end)
				end,
			})
			local storedKeys = { KEY_NOT_IN_POOL, PINK_TOP_KEY }
			loadPlayerWithStoredLobbyOutfit(harness, PLAYER, storedKeys)
			expect(harness.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(PLAYER)).toBeNil()
			expect(harness.availabilityChangedCountByPlayerUserId[PLAYER]).toBeNil()
			expect(#harness.outfitKeeperInformation).toBe(0)
			expect(#harness.outfitKeeperWarnings).toBe(1)
			expect(string.find(harness.outfitKeeperWarnings[1], "SaveDataNotLoaded", 1, true) ~= nil).toBeTrue()
			expect(harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)).toBeTrue()
			expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).lobbyOutfitStylingItemKeys).toEqual(
				storedKeys
			)
		end
	)
end)

describe("StoredLobbyOutfitKeeper when the removal change raises", function()
	it(
		"stand-in save keeper whose change raises (the real one raises only on programming errors): logged, nothing removed, availability still worked out",
		function()
			local harness = createStoredLobbyOutfitHarness({
				replacementSaveKeeperMethodsByName = {
					applyChangeToPlayerSaveData = function()
						error("stand-in: change refused by raising")
					end,
				},
			})
			loadPlayerWithStoredLobbyOutfit(harness, PLAYER, { KEY_NOT_IN_POOL, PINK_TOP_KEY })
			expect(#harness.outfitKeeperWarnings).toBe(1)
			expect(string.find(harness.outfitKeeperWarnings[1], "stand-in: change refused", 1, true) ~= nil).toBeTrue()
			expect(#harness.outfitKeeperInformation).toBe(0)
			expectAvailability(
				harness,
				PLAYER,
				readyAvailability({ KEY_NOT_IN_POOL, PINK_TOP_KEY }, {}, { PINK_TOP_KEY })
			)
			expect(harness.availabilityChangedCountByPlayerUserId[PLAYER]).toBe(1)
			expect(harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)).toBe(0)
		end
	)
end)

describe("StoredLobbyOutfitKeeper with a damaged stored value", function()
	it("reads a stored value that is not a plain list the same way the resolver does (ipairs)", function()
		local harness = createStoredLobbyOutfitHarness({})
		-- A hole at position 2 and a stray named field, as a damaged save could hold.
		local damagedStoredValue: { [any]: string } = { PINK_TOP_KEY }
		damagedStoredValue[3] = WHITE_SHOES_KEY
		damagedStoredValue.strayField = PINK_BAG_KEY
		loadPlayerWithStoredLobbyOutfit(harness, PLAYER, damagedStoredValue)
		expectAvailability(harness, PLAYER, readyAvailability({ PINK_TOP_KEY }, {}, { PINK_TOP_KEY }))
		-- Nothing in it left the pool, so the save is not changed (and nothing is erased).
		expect(harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)).toBe(0)
	end)
end)
