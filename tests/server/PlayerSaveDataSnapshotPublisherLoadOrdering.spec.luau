-- PlayerSaveDataSnapshotPublisher at load and around the wardrobe catalog (development spec v1.3
-- §1.5 stored outfits, §2.6, §2.14): how many messages a load produces, in both subscription
-- orders, with and without keys removed at load, with the catalog ready or not; and that every
-- message, at the moment it is sent, equals the server's state at that moment.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local PlayerSaveDataSnapshotPublisher = require("../../src/server/PlayerSaveDataSnapshotPublisher")
local PlayerSaveDataSnapshotPublisherTestHarness = require("./PlayerSaveDataSnapshotPublisherTestHarness")
local RewardLedgerPhaseTwoTestCallers = require("./RewardLedgerPhaseTwoTestCallers")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local createHarness = PlayerSaveDataSnapshotPublisherTestHarness.createHarness
local PLAYER_USER_ID = PlayerSaveDataSnapshotPublisherTestHarness.PLAYER_USER_ID
local OTHER_PLAYER_USER_ID = PlayerSaveDataSnapshotPublisherTestHarness.OTHER_PLAYER_USER_ID
local PINK_TOP_KEY = PlayerSaveDataSnapshotPublisherTestHarness.PINK_TOP_KEY
local WHITE_SHOES_KEY = PlayerSaveDataSnapshotPublisherTestHarness.WHITE_SHOES_KEY
local PINK_BAG_KEY = PlayerSaveDataSnapshotPublisherTestHarness.PINK_BAG_KEY
local KEY_NOT_IN_POOL = FakeStylingItemPool.KEY_NOT_IN_POOL
local DISABLED_HAIR_KEY = FakeStylingItemPool.DISABLED_HAIR_KEY
local HIDDEN_HAIR_KEY = FakeStylingItemPool.HIDDEN_HAIR_KEY
local FAKE_AVAILABLE_STYLING_ITEM_KEY_SET = FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET

local SUBSCRIPTION_ORDERS = { "PublisherFirst", "StoredLobbyOutfitKeeperFirst" }

local function createCatalogKeySetWith(extraAvailableKeys: { string })
	local availableStylingItemKeySet = table.clone(FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
	for _, extraAvailableKey in extraAvailableKeys do
		availableStylingItemKeySet[extraAvailableKey] = true
	end
	return availableStylingItemKeySet
end

-- Each case: the stored outfit, whether the catalog is ready at load, the expected messages at
-- load (lobby keys, unavailable keys), then after the catalog is published (if it was not ready).
local LOAD_CASES = {
	{
		caseName = "catalog ready, nothing to remove",
		storedLobbyOutfit = { PINK_TOP_KEY, WHITE_SHOES_KEY },
		isCatalogLeftNotReady = false,
		expectedMessages = { { { PINK_TOP_KEY, WHITE_SHOES_KEY }, {} } },
	},
	{
		caseName = "catalog ready, keys that left the pool removed at load",
		storedLobbyOutfit = { PINK_TOP_KEY, KEY_NOT_IN_POOL, DISABLED_HAIR_KEY, WHITE_SHOES_KEY },
		isCatalogLeftNotReady = false,
		expectedMessages = { { { PINK_TOP_KEY, WHITE_SHOES_KEY }, {} } },
	},
	{
		caseName = "catalog ready, a hidden key kept and reported",
		storedLobbyOutfit = { HIDDEN_HAIR_KEY, PINK_TOP_KEY },
		isCatalogLeftNotReady = false,
		expectedMessages = { { { HIDDEN_HAIR_KEY, PINK_TOP_KEY }, { HIDDEN_HAIR_KEY } } },
	},
	{
		caseName = "catalog ready, removal and a hidden key together",
		storedLobbyOutfit = { KEY_NOT_IN_POOL, HIDDEN_HAIR_KEY, PINK_TOP_KEY },
		isCatalogLeftNotReady = false,
		expectedMessages = { { { HIDDEN_HAIR_KEY, PINK_TOP_KEY }, { HIDDEN_HAIR_KEY } } },
	},
	{
		caseName = "catalog not ready, nothing hidden: readiness sends nothing more",
		storedLobbyOutfit = { PINK_TOP_KEY },
		isCatalogLeftNotReady = true,
		expectedMessages = { { { PINK_TOP_KEY }, {} } },
	},
	{
		caseName = "catalog not ready, a hidden key: reported once the catalog is ready",
		storedLobbyOutfit = { HIDDEN_HAIR_KEY, PINK_TOP_KEY },
		isCatalogLeftNotReady = true,
		expectedMessages = {
			{ { HIDDEN_HAIR_KEY, PINK_TOP_KEY }, {} },
			{ { HIDDEN_HAIR_KEY, PINK_TOP_KEY }, { HIDDEN_HAIR_KEY } },
		},
	},
	{
		caseName = "catalog not ready, removal and a hidden key",
		storedLobbyOutfit = { DISABLED_HAIR_KEY, HIDDEN_HAIR_KEY, KEY_NOT_IN_POOL },
		isCatalogLeftNotReady = true,
		expectedMessages = {
			{ { HIDDEN_HAIR_KEY }, {} },
			{ { HIDDEN_HAIR_KEY }, { HIDDEN_HAIR_KEY } },
		},
	},
}

local function listLobbyAndUnavailableKeysOfEveryMessage(harness, playerUserId: number)
	local lobbyAndUnavailableKeysPerMessage = {}
	for _, snapshotMessage in harness.listSnapshotMessagesSentTo(playerUserId) do
		table.insert(
			lobbyAndUnavailableKeysPerMessage,
			{ snapshotMessage.lobbyOutfitStylingItemKeys, snapshotMessage.unavailableLobbyOutfitStylingItemKeys }
		)
	end
	return lobbyAndUnavailableKeysPerMessage
end

describe("PlayerSaveDataSnapshotPublisher messages per load", function()
	for _, subscriptionOrder in SUBSCRIPTION_ORDERS do
		for _, loadCase in LOAD_CASES do
			it(string.format("%s (%s)", loadCase.caseName, subscriptionOrder), function()
				local harness = createHarness({
					subscriptionOrder = subscriptionOrder :: any,
					isCatalogLeftNotReady = loadCase.isCatalogLeftNotReady,
				})
				local inconsistencyDescriptions = harness.recordMessagesInconsistentWithServerStateAtSendTime()
				harness.loadPlayerWithStoredLobbyOutfit(PLAYER_USER_ID, loadCase.storedLobbyOutfit)
				if loadCase.isCatalogLeftNotReady then
					harness.fakeResolver:publishWardrobeCatalog(FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
				end
				-- A message held back at load must not turn into an extra one after the wait.
				harness.advanceSeconds(PlayerSaveDataSnapshotPublisher.STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS)
				expect(listLobbyAndUnavailableKeysOfEveryMessage(harness, PLAYER_USER_ID)).toEqual(
					loadCase.expectedMessages
				)
				expect(inconsistencyDescriptions).toEqual({})
				expect(harness.publisherLogger.loggedWarnings).toEqual({})
			end)
		end
	end
end)

describe("PlayerSaveDataSnapshotPublisher and the wardrobe catalog", function()
	for _, subscriptionOrder in SUBSCRIPTION_ORDERS do
		it("unavailable keys disappear and reappear with the catalog (" .. subscriptionOrder .. ")", function()
			local harness = createHarness({ subscriptionOrder = subscriptionOrder :: any })
			local inconsistencyDescriptions = harness.recordMessagesInconsistentWithServerStateAtSendTime()
			harness.loadPlayerWithStoredLobbyOutfit(PLAYER_USER_ID, { HIDDEN_HAIR_KEY, PINK_BAG_KEY })
			harness.fakeResolver:publishWardrobeCatalog(createCatalogKeySetWith({ HIDDEN_HAIR_KEY }))
			harness.fakeResolver:publishWardrobeCatalog(FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
			local unavailableKeysPerMessage = {}
			for _, snapshotMessage in harness.listSnapshotMessagesSentTo(PLAYER_USER_ID) do
				table.insert(unavailableKeysPerMessage, snapshotMessage.unavailableLobbyOutfitStylingItemKeys)
			end
			expect(unavailableKeysPerMessage).toEqual({ { HIDDEN_HAIR_KEY }, {}, { HIDDEN_HAIR_KEY } })
			expect(inconsistencyDescriptions).toEqual({})
		end)

		it(
			"a new catalog version that changes nothing for a player sends that player nothing ("
				.. subscriptionOrder
				.. ")",
			function()
				local harness = createHarness({ subscriptionOrder = subscriptionOrder :: any })
				harness.loadPlayerWithStoredLobbyOutfit(PLAYER_USER_ID, { PINK_TOP_KEY })
				harness.loadPlayerWithStoredLobbyOutfit(OTHER_PLAYER_USER_ID, { HIDDEN_HAIR_KEY })
				harness.fakeResolver:publishWardrobeCatalog(createCatalogKeySetWith({ HIDDEN_HAIR_KEY }))
				expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
				expect(harness.countSnapshotMessagesSentTo(OTHER_PLAYER_USER_ID)).toBe(2)
			end
		)

		it("a lobby outfit change sends one consistent message (" .. subscriptionOrder .. ")", function()
			local harness = createHarness({ subscriptionOrder = subscriptionOrder :: any })
			local inconsistencyDescriptions = harness.recordMessagesInconsistentWithServerStateAtSendTime()
			harness.loadPlayerWithStoredLobbyOutfit(PLAYER_USER_ID, { PINK_TOP_KEY })
			harness.setLobbyOutfit(PLAYER_USER_ID, { HIDDEN_HAIR_KEY, PINK_TOP_KEY })
			harness.setLobbyOutfit(PLAYER_USER_ID, { PINK_BAG_KEY })
			expect(listLobbyAndUnavailableKeysOfEveryMessage(harness, PLAYER_USER_ID)).toEqual({
				{ { PINK_TOP_KEY }, {} },
				{ { HIDDEN_HAIR_KEY, PINK_TOP_KEY }, { HIDDEN_HAIR_KEY } },
				{ { PINK_BAG_KEY }, {} },
			})
			expect(inconsistencyDescriptions).toEqual({})
		end)
	end

	it("a change made by another 'loaded' listener before the outfit keeper ran is not shown half-done", function()
		-- Listener order: publisher, a listener that grants at load, then the stored-outfit keeper.
		local harness = createHarness({
			subscriptionOrder = "PublisherFirst",
			subscribeBeforeStoredLobbyOutfitKeeperStarts = function(playerSaveDataKeeper, rewardLedger)
				playerSaveDataKeeper:subscribeToPlayerSaveDataLoaded(function(playerUserId)
					RewardLedgerPhaseTwoTestCallers.redeemPromoCode(rewardLedger, playerUserId, "welcome_code", 25)
				end)
			end,
		})
		local inconsistencyDescriptions = harness.recordMessagesInconsistentWithServerStateAtSendTime()
		harness.loadPlayerWithStoredLobbyOutfit(PLAYER_USER_ID, { KEY_NOT_IN_POOL, HIDDEN_HAIR_KEY })
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
		local snapshotMessage = harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID)
		expect(snapshotMessage.starCoinBalance).toBe(25)
		expect(snapshotMessage.lobbyOutfitStylingItemKeys).toEqual({ HIDDEN_HAIR_KEY })
		expect(snapshotMessage.unavailableLobbyOutfitStylingItemKeys).toEqual({ HIDDEN_HAIR_KEY })
		expect(inconsistencyDescriptions).toEqual({})
		expect(harness.publisherLogger.loggedWarnings).toEqual({})
	end)

	it("never shows a key that is removed at load, in either order", function()
		for _, subscriptionOrder in SUBSCRIPTION_ORDERS do
			local harness = createHarness({ subscriptionOrder = subscriptionOrder :: any })
			harness.loadPlayerWithStoredLobbyOutfit(PLAYER_USER_ID, { KEY_NOT_IN_POOL, PINK_TOP_KEY })
			for _, snapshotMessage in harness.listSnapshotMessagesSentTo(PLAYER_USER_ID) do
				expect(table.find(snapshotMessage.lobbyOutfitStylingItemKeys, KEY_NOT_IN_POOL)).toBeNil()
			end
		end
	end)
end)

describe("PlayerSaveDataSnapshotPublisher with a damaged stored lobby outfit", function()
	-- The outfit keeper reads the stored list with ipairs; the publisher compares the same way,
	-- so a damaged list can never make the two disagree forever (and the device get nothing).
	local DAMAGED_STORED_LOBBY_OUTFITS = {
		{ caseName = "a list with a hole", storedLobbyOutfit = { [1] = PINK_TOP_KEY, [3] = PINK_BAG_KEY } },
		{ caseName = "not a table", storedLobbyOutfit = "garbage" },
	}
	for _, subscriptionOrder in SUBSCRIPTION_ORDERS do
		for _, damagedCase in DAMAGED_STORED_LOBBY_OUTFITS do
			it(
				string.format("%s still gives one message at load (%s)", damagedCase.caseName, subscriptionOrder),
				function()
					local harness = createHarness({ subscriptionOrder = subscriptionOrder :: any })
					harness.loadPlayer(PLAYER_USER_ID, function(storedSaveData)
						storedSaveData.lobbyOutfitStylingItemKeys = damagedCase.storedLobbyOutfit
					end)
					expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
					expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID).lobbyOutfitStylingItemKeys).toEqual(
						damagedCase.storedLobbyOutfit
					)
				end
			)
		end
	end
end)
