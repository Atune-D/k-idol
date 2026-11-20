-- Wires the REAL MarketplaceStylingItemResolver (FakeMarketplaceItemLookups behind it) to the
-- REAL StoredLobbyOutfitKeeper and the REAL PlayerSaveDataKeeper on fake storage. All three share
-- one FakeClock and one FakeScheduler, so a single `advanceSeconds` moves the lookups' retries and
-- timeouts and the saves together. Not a spec file; the integration spec files require it.
--
-- createWiredKeepersWithRealResolver(stylingItems?) -> harness
--   stylingItems defaults to FakeStylingItemPool.FAKE_STYLING_ITEMS; the keeper is given the
--   lookup built from the same list, as the server wiring does with the generated pool.
--   The stored-outfit keeper is started; the resolver is NOT, so a test can script lookup answers
--   first and then call `harness.marketplaceStylingItemResolver:startResolvingWardrobeCatalog()`.
--   harness fields:
--     playerSaveDataKeeper, fakePlayerSaveDataStorage, fakeScheduler, fakeClock,
--     fakeMarketplaceItemLookups, marketplaceStylingItemResolver, storedLobbyOutfitKeeper
--     resolverWarnings, resolverInformation, outfitKeeperWarnings, outfitKeeperInformation
--       every line each module logged, in order
--     availabilityChangedRecords   every availability-changed call, in order:
--       { playerUserId, availability, wasResolverReadyWhenTold, resolverVersionWhenTold }
--     catalogChangedRecords   every WardrobeCatalogChanged call heard by a listener subscribed
--       AFTER the keeper: { wardrobeCatalogChangedMessage, availabilityByPlayerUserIdWhenHeard }
--   harness.listAvailabilityChangedRecordsForPlayer(playerUserId) -> the availabilityChangedRecords
--     entries of that player, in order (a new list)
--   harness.countLoggedLinesMentioning(loggedLines, text) -> number of lines in loggedLines
--     (any of the four logged-line lists above) that contain text, matched literally
--   harness.advanceSeconds(seconds)
--   harness.loadPlayerWithStoredLobbyOutfit(playerUserId, storedLobbyOutfitStylingItemKeys)
--   harness.readInMemoryLobbyOutfit(playerUserId) / harness.readStoredLobbyOutfit(playerUserId)
--   harness.readAvailability(playerUserId)
--   harness.completeLaterProgressSave(playerUserId)   a grant, past the save spacing, written
--   harness.leaveAndCompleteFinalSave(playerUserId)

local FakeStylingItemPool = require("./FakeStylingItemPool")
local FakeMarketplaceItemLookups = require("../Support/FakeMarketplaceItemLookups")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local MarketplaceStylingItemResolver = require("../../src/server/MarketplaceStylingItemResolver")
local StoredLobbyOutfitKeeper = require("../../src/server/StoredLobbyOutfitKeeper")
local StylingItemLookup = require("../../src/shared/StylingItemLookup")
local PlayerSaveDataKeeperTestHarness = require("../server/PlayerSaveDataKeeperTestHarness")

local StoredLobbyOutfitKeeperWithRealResolverTestHarness = {}

StoredLobbyOutfitKeeperWithRealResolverTestHarness.EXAMPLE_PLAYER_USER_ID =
	PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID
StoredLobbyOutfitKeeperWithRealResolverTestHarness.OTHER_PLAYER_USER_ID =
	PlayerSaveDataKeeperTestHarness.OTHER_PLAYER_USER_ID

local function createRecordingLogger(loggedInformation: { string }, loggedWarnings: { string })
	return {
		logInformation = function(_, message: string)
			table.insert(loggedInformation, message)
		end,
		logWarning = function(_, message: string)
			table.insert(loggedWarnings, message)
		end,
	}
end

function StoredLobbyOutfitKeeperWithRealResolverTestHarness.createWiredKeepersWithRealResolver(stylingItems: { any }?)
	local wiredStylingItems = stylingItems or FakeStylingItemPool.FAKE_STYLING_ITEMS
	local saveKeeperHarness = PlayerSaveDataKeeperTestHarness.createKeeperWithFakes()
	local fakeMarketplaceItemLookups = FakeMarketplaceItemLookups.new()
	local resolverWarnings, resolverInformation = {}, {}
	local outfitKeeperWarnings, outfitKeeperInformation = {}, {}

	local marketplaceStylingItemResolver = MarketplaceStylingItemResolver.new({
		stylingItems = wiredStylingItems,
		marketplaceItemLookups = fakeMarketplaceItemLookups,
		scheduler = saveKeeperHarness.fakeScheduler,
		logger = createRecordingLogger(resolverInformation, resolverWarnings),
	})
	local storedLobbyOutfitKeeper = StoredLobbyOutfitKeeper.new({
		playerSaveDataKeeper = saveKeeperHarness.playerSaveDataKeeper,
		stylingItemByStylingItemKey = StylingItemLookup.buildStylingItemByStylingItemKey(wiredStylingItems),
		marketplaceStylingItemResolver = marketplaceStylingItemResolver,
		logger = createRecordingLogger(outfitKeeperInformation, outfitKeeperWarnings),
	})
	storedLobbyOutfitKeeper:startLookingAfterStoredLobbyOutfits()

	local availabilityChangedRecords = {}
	storedLobbyOutfitKeeper:subscribeToStoredLobbyOutfitAvailabilityChanged(function(playerUserId, availability)
		table.insert(availabilityChangedRecords, {
			playerUserId = playerUserId,
			availability = availability,
			wasResolverReadyWhenTold = marketplaceStylingItemResolver:isWardrobeCatalogReady(),
			resolverVersionWhenTold = marketplaceStylingItemResolver:getWardrobeCatalogVersion(),
		})
	end)

	local harness = {
		playerSaveDataKeeper = saveKeeperHarness.playerSaveDataKeeper,
		fakePlayerSaveDataStorage = saveKeeperHarness.fakePlayerSaveDataStorage,
		fakeScheduler = saveKeeperHarness.fakeScheduler,
		fakeClock = saveKeeperHarness.fakeClock,
		fakeMarketplaceItemLookups = fakeMarketplaceItemLookups,
		marketplaceStylingItemResolver = marketplaceStylingItemResolver,
		storedLobbyOutfitKeeper = storedLobbyOutfitKeeper,
		resolverWarnings = resolverWarnings,
		resolverInformation = resolverInformation,
		outfitKeeperWarnings = outfitKeeperWarnings,
		outfitKeeperInformation = outfitKeeperInformation,
		availabilityChangedRecords = availabilityChangedRecords,
		catalogChangedRecords = {},
	}

	-- Subscribed after the keeper, as any later module (the device message sender) would be.
	marketplaceStylingItemResolver:subscribeToWardrobeCatalogChanged(function(wardrobeCatalogChangedMessage)
		local availabilityByPlayerUserIdWhenHeard = {}
		for _, playerUserId in
			{
				StoredLobbyOutfitKeeperWithRealResolverTestHarness.EXAMPLE_PLAYER_USER_ID,
				StoredLobbyOutfitKeeperWithRealResolverTestHarness.OTHER_PLAYER_USER_ID,
			}
		do
			availabilityByPlayerUserIdWhenHeard[playerUserId] =
				storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(playerUserId)
		end
		table.insert(harness.catalogChangedRecords, {
			wardrobeCatalogChangedMessage = wardrobeCatalogChangedMessage,
			availabilityByPlayerUserIdWhenHeard = availabilityByPlayerUserIdWhenHeard,
		})
	end)

	function harness.listAvailabilityChangedRecordsForPlayer(playerUserId: number)
		local playerAvailabilityChangedRecords = {}
		for _, availabilityChangedRecord in availabilityChangedRecords do
			if availabilityChangedRecord.playerUserId == playerUserId then
				table.insert(playerAvailabilityChangedRecords, availabilityChangedRecord)
			end
		end
		return playerAvailabilityChangedRecords
	end

	function harness.countLoggedLinesMentioning(loggedLines: { string }, mentionedText: string): number
		local mentioningLineCount = 0
		for _, loggedLine in loggedLines do
			if string.find(loggedLine, mentionedText, 1, true) ~= nil then
				mentioningLineCount += 1
			end
		end
		return mentioningLineCount
	end

	function harness.advanceSeconds(elapsedSeconds: number)
		saveKeeperHarness.advanceSeconds(elapsedSeconds)
	end

	function harness.loadPlayerWithStoredLobbyOutfit(playerUserId: number, storedLobbyOutfitStylingItemKeys: { any })
		local storedSaveData = PlayerSaveDataSchema.createStartingPlayerSaveData(
			PlayerSaveDataKeeperTestHarness.STARTER_DANCE_IDS,
			saveKeeperHarness.fakeClock:getCurrentUnixSeconds() - 86400
		)
		storedSaveData.lobbyOutfitStylingItemKeys = storedLobbyOutfitStylingItemKeys
		saveKeeperHarness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(playerUserId, storedSaveData)
		saveKeeperHarness.playerSaveDataKeeper:startLoadingPlayerSaveData(playerUserId)
		saveKeeperHarness.fakePlayerSaveDataStorage:completeOldestPendingOperation(playerUserId)
		assert(
			saveKeeperHarness.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId),
			"the load should have succeeded"
		)
	end

	function harness.readInMemoryLobbyOutfit(playerUserId: number)
		return saveKeeperHarness.playerSaveDataKeeper:readPlayerSaveDataCopy(playerUserId).lobbyOutfitStylingItemKeys
	end

	function harness.readStoredLobbyOutfit(playerUserId: number)
		return saveKeeperHarness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(playerUserId).lobbyOutfitStylingItemKeys
	end

	function harness.readAvailability(playerUserId: number)
		return storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(playerUserId)
	end

	function harness.completeLaterProgressSave(playerUserId: number)
		saveKeeperHarness.grantStarCoins(playerUserId, 20)
		saveKeeperHarness.advanceSeconds(PlayerSaveDataKeeper.MINIMUM_SECONDS_BETWEEN_SAVE_STARTS)
		assert(
			saveKeeperHarness.fakePlayerSaveDataStorage:completeOldestPendingOperation(playerUserId),
			"the later save should have written"
		)
	end

	function harness.leaveAndCompleteFinalSave(playerUserId: number)
		saveKeeperHarness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(playerUserId)
		assert(
			saveKeeperHarness.fakePlayerSaveDataStorage:completeOldestPendingOperation(playerUserId),
			"the final save should have written"
		)
	end

	return harness
end

return table.freeze(StoredLobbyOutfitKeeperWithRealResolverTestHarness)
