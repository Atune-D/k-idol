-- One game server with the REAL PlayerSaveDataKeeper and every listener of its events that exists
-- so far, all REAL and on one keeper: ThemedRoundReferee (with its real clock, rate limiter and
-- ledger, from ThemedRoundRefereeTestHarness), StoredLobbyOutfitKeeper, DailyProgressTracker,
-- FanCountLeaderboardKeeper and PlayerSaveDataSnapshotPublisher. Storage HOLDS every operation in
-- flight until the test answers it (FakePlayerSaveDataStorage plus FakePlayerSaveDataStorageAnswerOrder),
-- so a test can play a player who leaves and rejoins this same server with storage answers
-- arriving in any order. Not a spec file.
--
-- Time is the referee harness's round time (round 1 ThemeReveal starts at T = 0, Styling at 10).
-- Every keeper event is recorded with what the keeper reported at that moment (`eventRecords`);
-- the recorder is the first subscriber of every event except the referee's "session ended".

local DailyProgressTracker = require("../../src/server/DailyProgressTracker")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local FakeFanCountLeaderboardStorage = require("../Support/FakeFanCountLeaderboardStorage")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local FanCountLeaderboardKeeper = require("../../src/server/FanCountLeaderboardKeeper")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataSnapshotPublisher = require("../../src/server/PlayerSaveDataSnapshotPublisher")
local RecordingLogger = require("../Support/RecordingLogger")
local StoredLobbyOutfitKeeper = require("../../src/server/StoredLobbyOutfitKeeper")
local ThemedRoundRefereeTestHarness = require("./ThemedRoundRefereeTestHarness")

local QuickRejoinSameServerTestHarness = {}

QuickRejoinSameServerTestHarness.PLAYER_P = ThemedRoundRefereeTestHarness.PLAYER_P
QuickRejoinSameServerTestHarness.PLAYER_Q = ThemedRoundRefereeTestHarness.PLAYER_Q
QuickRejoinSameServerTestHarness.HIDDEN_HAIR_KEY = FakeStylingItemPool.HIDDEN_HAIR_KEY
QuickRejoinSameServerTestHarness.PINK_TOP_KEY = "asset_9000011"
QuickRejoinSameServerTestHarness.STORED_STAR_COIN_BALANCE = 350
QuickRejoinSameServerTestHarness.STORED_FAN_COUNT = 1200

local KEEPER_EVENT_NAMES = {
	"PlayerSaveDataLoaded",
	"InMemorySaveDataChanged",
	"SaveDataSaveSucceeded",
	"SaveDataPersistenceDelayedChanged",
	"PlayerSaveDataSessionEnded",
}

local function addListenersBesidesTheReferee(harness)
	local playerSaveDataKeeper = harness.playerSaveDataKeeper
	harness.storedLobbyOutfitKeeper = StoredLobbyOutfitKeeper.new({
		playerSaveDataKeeper = playerSaveDataKeeper,
		stylingItemByStylingItemKey = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
		marketplaceStylingItemResolver = harness.fakeResolver,
		logger = RecordingLogger.new(),
	})
	harness.storedLobbyOutfitKeeper:startLookingAfterStoredLobbyOutfits()

	harness.trackerLogger = RecordingLogger.new()
	harness.dailyProgressTracker = DailyProgressTracker.new({
		playerSaveDataKeeper = playerSaveDataKeeper,
		rewardLedger = harness.realRewardLedger,
		playerRequestRateLimiter = harness.playerRequestRateLimiter,
		clock = harness.fakeClock,
		scheduler = harness.fakeScheduler,
		logger = harness.trackerLogger,
		dailyQuestCatalogEntries = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS,
	})
	harness.dailyProgressTracker:startTrackingDailyProgress()

	harness.fakeFanCountLeaderboardStorage = FakeFanCountLeaderboardStorage.new()
	harness.fakeFanCountLeaderboardStorage:setCompletesWritesImmediately(true)
	harness.fanCountLeaderboardKeeper = FanCountLeaderboardKeeper.new({
		playerSaveDataKeeper = playerSaveDataKeeper,
		fanCountLeaderboardStorage = harness.fakeFanCountLeaderboardStorage,
		clock = harness.fakeClock,
		scheduler = harness.fakeScheduler,
		logger = RecordingLogger.new(),
		lookUpPlayerDisplayNamesByUserId = function()
			return {}
		end,
	})
	harness.fanCountLeaderboardKeeper:startSyncingAndRefreshingTopEntries()

	harness.publisherLogger = RecordingLogger.new()
	harness.sentSnapshotRecords = {}
	harness.publisher = PlayerSaveDataSnapshotPublisher.new({
		playerSaveDataKeeper = playerSaveDataKeeper,
		storedLobbyOutfitKeeper = harness.storedLobbyOutfitKeeper,
		clock = harness.fakeClock,
		scheduler = harness.fakeScheduler,
		dailyQuestCatalogEntries = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS,
		sendPlayerSaveDataSnapshotToPlayer = function(playerUserId: number, snapshotMessage)
			table.insert(
				harness.sentSnapshotRecords,
				{ playerUserId = playerUserId, snapshotMessage = snapshotMessage }
			)
		end,
		logger = harness.publisherLogger,
	})
	harness.publisher:startPublishingPlayerSaveDataSnapshots()
end

-- Records every keeper event with the keeper's own answer at that moment.
local function addKeeperEventRecorder(harness)
	harness.eventRecords = {}
	harness.hasJoinedRoundSinceLoadByPlayerUserId = {}
	local playerSaveDataKeeper = harness.playerSaveDataKeeper
	for _, keeperEventName in KEEPER_EVENT_NAMES do
		playerSaveDataKeeper["subscribeTo" .. keeperEventName](playerSaveDataKeeper, function(playerUserId, eventValue)
			if keeperEventName == "PlayerSaveDataLoaded" then
				harness.hasJoinedRoundSinceLoadByPlayerUserId[playerUserId] = false
			end
			table.insert(harness.eventRecords, {
				eventName = keeperEventName,
				playerUserId = playerUserId,
				eventValue = eventValue,
				wasLoadedAtEvent = playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId),
				storedSaveDataAtEvent = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(playerUserId),
			})
		end)
	end
end

function QuickRejoinSameServerTestHarness.createHarness()
	local harness = ThemedRoundRefereeTestHarness.createRefereeWithFakes()
	harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(false)
	-- The recorder subscribes before the tracker, whose "loaded" listener changes the save inside
	-- the "loaded" dispatch; recording first keeps "loaded" ahead of that change in the records.
	addKeeperEventRecorder(harness)
	addListenersBesidesTheReferee(harness)

	function harness.storeSaveWithHiddenLobbyItem(playerUserId: number)
		local storedSaveData = ThemedRoundRefereeTestHarness.createStoredSaveWithExampleHistory()
		storedSaveData.starCoinBalance = QuickRejoinSameServerTestHarness.STORED_STAR_COIN_BALANCE
		storedSaveData.fanCount = QuickRejoinSameServerTestHarness.STORED_FAN_COUNT
		storedSaveData.lobbyOutfitStylingItemKeys =
			{ QuickRejoinSameServerTestHarness.HIDDEN_HAIR_KEY, QuickRejoinSameServerTestHarness.PINK_TOP_KEY }
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(playerUserId, storedSaveData)
	end

	function harness.isLoaded(playerUserId: number): boolean
		return harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId)
	end

	function harness.countPendingOperations(playerUserId: number?): number
		return harness.fakePlayerSaveDataStorage:countPendingOperations(playerUserId)
	end

	-- Answers every operation in flight with success, oldest first, including ones they start.
	function harness.completeEveryPendingOperation()
		while harness.countPendingOperations() > 0 do
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation()
		end
	end

	-- The wiring's leave sequence: playtime recorded, the referee told, then the final save.
	function harness.leaveServer(playerUserId: number)
		harness.dailyProgressTracker:recordCountedPlaytimeAndStopCountingBeforeFinalSave(playerUserId)
		harness.referee:removePlayerWhoLeftServer(playerUserId)
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(playerUserId)
	end

	function harness.joinServer(playerUserId: number)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(playerUserId)
	end

	-- What the player's device does as soon as its save has loaded: join the current round.
	function harness.joinRoundOnceLoaded(playerUserId: number)
		if not harness.isLoaded(playerUserId) or harness.hasJoinedRoundSinceLoadByPlayerUserId[playerUserId] then
			return
		end
		local joinAnswer = harness.referee:admitOrRejectJoinCurrentRoundRequest(playerUserId)
		assert(
			joinAnswer.isAccepted,
			"harness: the join should be accepted, got " .. tostring(joinAnswer.rejectionReason)
		)
		harness.hasJoinedRoundSinceLoadByPlayerUserId[playerUserId] = true
	end

	-- Stores the save, joins at T = 0, loads, and joins the round at T = 3.
	function harness.loadAndJoinRound(playerUserId: number)
		harness.storeSaveWithHiddenLobbyItem(playerUserId)
		harness.joinServer(playerUserId)
		harness.completeEveryPendingOperation()
		assert(harness.isLoaded(playerUserId), "harness: the first load should succeed")
		harness.advanceToRoundSecond(3)
		harness.joinRoundOnceLoaded(playerUserId)
	end

	function harness.applyProgressChange(playerUserId: number, fieldName: string, addedAmount: number)
		return harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(
			playerUserId,
			PlayerSaveDataKeeper.PROGRESS_CHANGE_SAVED_AT_ONCE,
			"quick rejoin test grant",
			function(saveDataDraft)
				saveDataDraft[fieldName] += addedAmount
				return true
			end
		)
	end

	function harness.listEventRecordsOf(playerUserId: number)
		local playerEventRecords = {}
		for _, eventRecord in harness.eventRecords do
			if eventRecord.playerUserId == playerUserId then
				table.insert(playerEventRecords, eventRecord)
			end
		end
		return playerEventRecords
	end

	function harness.listSessionEndReasons(playerUserId: number): { string }
		local sessionEndReasons = {}
		for _, eventRecord in harness.listEventRecordsOf(playerUserId) do
			if eventRecord.eventName == "PlayerSaveDataSessionEnded" then
				table.insert(sessionEndReasons, eventRecord.eventValue)
			end
		end
		return sessionEndReasons
	end

	function harness.listSnapshotMessagesSentTo(playerUserId: number)
		local snapshotMessages = {}
		for _, sentSnapshotRecord in harness.sentSnapshotRecords do
			if sentSnapshotRecord.playerUserId == playerUserId then
				table.insert(snapshotMessages, sentSnapshotRecord.snapshotMessage)
			end
		end
		return snapshotMessages
	end

	function harness.readInMemoryPlaytimeSecondsToday(playerUserId: number): number
		return harness.playerSaveDataKeeper:readPlayerSaveDataCopy(playerUserId).dailyProgress.playtimeSecondsToday
	end

	return harness
end

-- What a listener keyed by user id can observe must never show two sessions of one player at
-- once. Returns a description of the first violation in `playerEventRecords`, or nil:
--   * "loaded" while the previous loaded session has not ended;
--   * "session ended" while the keeper reports a loaded save (an older session ended late);
--   * "in-memory changed" or "persistence delayed changed" outside a loaded session.
-- ("save succeeded" may come without "loaded": a player who left while loading and whose load
-- still took the save hands it back with a final save.)
function QuickRejoinSameServerTestHarness.describeFirstSessionOverlap(playerEventRecords): string?
	local isLoadedSessionOpen = false
	for eventPosition, eventRecord in playerEventRecords do
		local eventName = eventRecord.eventName
		if eventName == "PlayerSaveDataLoaded" then
			if isLoadedSessionOpen then
				return string.format("event %d: loaded while the previous loaded session had not ended", eventPosition)
			end
			isLoadedSessionOpen = true
		elseif eventName == "PlayerSaveDataSessionEnded" then
			if eventRecord.wasLoadedAtEvent then
				return string.format(
					"event %d: session ended (%s) while the keeper reported a loaded save",
					eventPosition,
					tostring(eventRecord.eventValue)
				)
			end
			isLoadedSessionOpen = false
		elseif eventName ~= "SaveDataSaveSucceeded" and not isLoadedSessionOpen then
			return string.format("event %d: %s outside any loaded session", eventPosition, eventName)
		end
	end
	return nil
end

return table.freeze(QuickRejoinSameServerTestHarness)
