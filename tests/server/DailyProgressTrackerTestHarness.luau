-- Builds a DailyProgressTracker on the REAL PlayerSaveDataKeeper (fake storage, clock and
-- scheduler), the REAL RewardLedger carrying the tracker's round record writer, and by default the
-- REAL PlayerRequestRateLimiter. The quest catalog is DailyQuestTestCatalog's six-quest fixture and
-- the styling item pool is FakeStylingItemPool. Not a spec file; the DailyProgressTracker spec
-- files require it.
--
-- The clock starts on DailyQuestTestCatalog.TEST_DAILY_DATE_KEY (2026-11-19), whose pinned quests
-- are quest_a (CompleteRounds, target 3, 60 coins), quest_d (at least 4 stars, target 2, 120
-- coins) and quest_e (pink, target 1, 70 coins). Storage completes every operation at once unless
-- `isStorageHeldInFlight` is set.

local DailyProgressTracker = require("../../src/server/DailyProgressTracker")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local PlayerRequestRateLimiter = require("../../src/server/PlayerRequestRateLimiter")
local PlayerSaveDataKeeperTestHarness = require("./PlayerSaveDataKeeperTestHarness")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local RewardLedger = require("../../src/server/RewardLedger")

local DailyProgressTrackerTestHarness = {}

DailyProgressTrackerTestHarness.PLAYER = PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID
DailyProgressTrackerTestHarness.OTHER_PLAYER = PlayerSaveDataKeeperTestHarness.OTHER_PLAYER_USER_ID
DailyProgressTrackerTestHarness.SECONDS_PER_DAY = 86400
-- 2026-11-19 00:00:00 UTC.
DailyProgressTrackerTestHarness.TEST_DAY_START_UNIX_SECONDS = PlayerSaveDataKeeperTestHarness.EXAMPLE_STARTING_UNIX_SECONDS
	+ 365 * 86400
-- By default the clock starts at 10:00 UTC on the test day.
DailyProgressTrackerTestHarness.DEFAULT_SECONDS_AFTER_MIDNIGHT = 10 * 3600

-- Keys of FakeStylingItemPool by primary colour, for building scored outfits.
DailyProgressTrackerTestHarness.PINK_HAIR_KEY = "asset_9000001"
DailyProgressTrackerTestHarness.BLUE_TOP_KEY = "asset_9000012"
DailyProgressTrackerTestHarness.BLACK_BOTTOM_KEY = "asset_9000021"
DailyProgressTrackerTestHarness.WHITE_SHOES_KEY = "bundle_9000041"

export type TrackerHarnessOptions = {
	secondsAfterMidnight: number?,
	isStorageHeldInFlight: boolean?,
	-- Replaces the real rate limiter with one that admits every request and records each call.
	admitsEveryRequest: boolean?,
	dailyQuestCatalogEntries: { any }?,
	stylingItemByStylingItemKey: { [string]: any }?,
	-- Leaves startTrackingDailyProgress uncalled: no playtime counting and no repair at load.
	isTrackingNotStarted: boolean?,
	-- Gives the tracker (not the ledger) a FaultInjectingKeeperWrapper around the real keeper.
	wrapsTrackerKeeperForFaults: boolean?,
}

function DailyProgressTrackerTestHarness.createRecordingLogger()
	local recordingLogger = { loggedInformation = {}, loggedWarnings = {} }
	function recordingLogger.logInformation(self, message: string)
		table.insert(self.loggedInformation, message)
	end
	function recordingLogger.logWarning(self, message: string)
		table.insert(self.loggedWarnings, message)
	end
	return recordingLogger
end

function DailyProgressTrackerTestHarness.createAdmittingRateLimiter()
	local admittingRateLimiter = { admittedRequests = {} }
	function admittingRateLimiter.admitOrRefusePlayerRequest(self, playerUserId: number, remoteChannelName: string)
		table.insert(self.admittedRequests, { playerUserId = playerUserId, remoteChannelName = remoteChannelName })
		return { isRequestAllowed = true }
	end
	return admittingRateLimiter
end

-- Passes every call the tracker makes on to the real keeper, except that a test can make the next
-- applyChangeToPlayerSaveData raise, and can fire the tracker's "loaded" listeners again by hand.
function DailyProgressTrackerTestHarness.createFaultInjectingKeeperWrapper(realPlayerSaveDataKeeper)
	local keeperWrapper = { raisesOnNextChange = false, trackerLoadedListeners = {} }
	function keeperWrapper.subscribeToPlayerSaveDataLoaded(_, listener)
		table.insert(keeperWrapper.trackerLoadedListeners, listener)
		return realPlayerSaveDataKeeper:subscribeToPlayerSaveDataLoaded(listener)
	end
	function keeperWrapper.subscribeToPlayerSaveDataSessionEnded(_, listener)
		return realPlayerSaveDataKeeper:subscribeToPlayerSaveDataSessionEnded(listener)
	end
	function keeperWrapper.isPlayerSaveDataLoaded(_, playerUserId: number)
		return realPlayerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId)
	end
	function keeperWrapper.applyChangeToPlayerSaveData(_, ...)
		if keeperWrapper.raisesOnNextChange then
			keeperWrapper.raisesOnNextChange = false
			error("injected keeper fault")
		end
		return realPlayerSaveDataKeeper:applyChangeToPlayerSaveData(...)
	end
	return keeperWrapper
end

function DailyProgressTrackerTestHarness.createTrackerHarness(harnessOptions: TrackerHarnessOptions?)
	local options: TrackerHarnessOptions = harnessOptions or {}
	local keeperHarness = PlayerSaveDataKeeperTestHarness.createKeeperWithFakes()
	local fakeClock = keeperHarness.fakeClock
	fakeClock:advanceBySeconds(
		DailyProgressTrackerTestHarness.TEST_DAY_START_UNIX_SECONDS
			- fakeClock:getCurrentUnixSeconds()
			+ (options.secondsAfterMidnight or DailyProgressTrackerTestHarness.DEFAULT_SECONDS_AFTER_MIDNIGHT)
	)
	keeperHarness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(not options.isStorageHeldInFlight)

	local trackerLogger = DailyProgressTrackerTestHarness.createRecordingLogger()
	local ledgerLogger = DailyProgressTrackerTestHarness.createRecordingLogger()
	local dailyQuestCatalogEntries = options.dailyQuestCatalogEntries or DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS
	local roundRecordWriter = DailyProgressTracker.createDailyQuestProgressRoundRecordWriter({
		clock = fakeClock,
		stylingItemByStylingItemKey = options.stylingItemByStylingItemKey
			or FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
		dailyQuestCatalogEntries = dailyQuestCatalogEntries,
		logger = trackerLogger,
	})
	local rewardLedger = RewardLedger.new({
		playerSaveDataKeeper = keeperHarness.playerSaveDataKeeper,
		logger = ledgerLogger,
		themedRoundCompletionRecordWriters = { roundRecordWriter },
	})
	local playerRequestRateLimiter = if options.admitsEveryRequest
		then DailyProgressTrackerTestHarness.createAdmittingRateLimiter()
		else PlayerRequestRateLimiter.new({ clock = fakeClock })
	local trackerKeeperWrapper = if options.wrapsTrackerKeeperForFaults
		then DailyProgressTrackerTestHarness.createFaultInjectingKeeperWrapper(keeperHarness.playerSaveDataKeeper)
		else nil
	local dailyProgressTracker = DailyProgressTracker.new({
		playerSaveDataKeeper = trackerKeeperWrapper or keeperHarness.playerSaveDataKeeper,
		rewardLedger = rewardLedger,
		playerRequestRateLimiter = playerRequestRateLimiter,
		clock = fakeClock,
		scheduler = keeperHarness.fakeScheduler,
		logger = trackerLogger,
		dailyQuestCatalogEntries = dailyQuestCatalogEntries,
	})
	if not options.isTrackingNotStarted then
		dailyProgressTracker:startTrackingDailyProgress()
	end

	local harness = {
		keeperHarness = keeperHarness,
		fakeClock = fakeClock,
		fakeScheduler = keeperHarness.fakeScheduler,
		fakePlayerSaveDataStorage = keeperHarness.fakePlayerSaveDataStorage,
		playerSaveDataKeeper = keeperHarness.playerSaveDataKeeper,
		rewardLedger = rewardLedger,
		playerRequestRateLimiter = playerRequestRateLimiter,
		trackerKeeperWrapper = trackerKeeperWrapper,
		dailyProgressTracker = dailyProgressTracker,
		roundRecordWriter = roundRecordWriter,
		trackerLogger = trackerLogger,
		ledgerLogger = ledgerLogger,
	}

	function harness.advanceSeconds(elapsedSeconds: number)
		keeperHarness.fakeScheduler:advanceTimeAndRunDueCallbacks(elapsedSeconds)
	end

	-- Moves time (through the scheduler) to `secondsAfterMidnight` on the day `dayOffset` days
	-- after the test day.
	function harness.advanceToTimeOfDay(dayOffset: number, secondsAfterMidnight: number)
		local targetUnixSeconds = DailyProgressTrackerTestHarness.TEST_DAY_START_UNIX_SECONDS
			+ dayOffset * DailyProgressTrackerTestHarness.SECONDS_PER_DAY
			+ secondsAfterMidnight
		harness.advanceSeconds(targetUnixSeconds - fakeClock:getCurrentUnixSeconds())
	end

	-- Starts loading; with storage completing at once, the save is loaded when this returns.
	function harness.loadPlayer(playerUserId: number)
		keeperHarness.playerSaveDataKeeper:startLoadingPlayerSaveData(playerUserId)
		if options.isStorageHeldInFlight then
			keeperHarness.fakePlayerSaveDataStorage:completeOldestPendingOperation(playerUserId)
		end
		assert(
			keeperHarness.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId),
			"harness: the load should succeed"
		)
	end

	-- The tracker's leave sequence, as the server wiring performs it.
	function harness.leavePlayer(playerUserId: number)
		dailyProgressTracker:recordCountedPlaytimeAndStopCountingBeforeFinalSave(playerUserId)
		keeperHarness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(playerUserId)
	end

	-- Stores a returning player's save (built for the current time) before it is loaded.
	function harness.storeExistingPlayerSaveData(playerUserId: number, adjustStoredSaveData: (any) -> ())
		local storedSaveData = PlayerSaveDataSchema.createStartingPlayerSaveData(
			PlayerSaveDataKeeperTestHarness.STARTER_DANCE_IDS,
			fakeClock:getCurrentUnixSeconds()
		)
		adjustStoredSaveData(storedSaveData)
		keeperHarness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(playerUserId, storedSaveData)
	end

	function harness.readInMemorySaveData(playerUserId: number)
		return keeperHarness.playerSaveDataKeeper:readPlayerSaveDataCopy(playerUserId)
	end

	function harness.readInMemoryDailyProgress(playerUserId: number)
		return harness.readInMemorySaveData(playerUserId).dailyProgress
	end

	function harness.readStoredSaveData(playerUserId: number)
		return keeperHarness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(playerUserId)
	end

	function harness.readInMemoryChangeRevision(playerUserId: number): number?
		local inMemoryChangeRevision = keeperHarness.playerSaveDataKeeper:readSaveChangeRevisions(playerUserId)
		return inMemoryChangeRevision
	end

	function harness.grantRoundReward(playerUserId: number, roundId: string, starCount: number, scoredKeys: { string })
		return rewardLedger:grantThemedRoundReward(playerUserId, {
			roundId = roundId,
			themeId = "y2k_pop",
			starCount = starCount,
			scoredOutfitStylingItemKeys = scoredKeys,
		})
	end

	-- Claims with one second between requests, so the real rate limiter admits each of them.
	function harness.claimPlaytimeMilestoneAfterOneSecond(playerUserId: number, milestoneMinutes: any)
		harness.advanceSeconds(1)
		return dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(playerUserId, milestoneMinutes)
	end

	function harness.claimDailyQuestRewardAfterOneSecond(playerUserId: number, dailyQuestId: any)
		harness.advanceSeconds(1)
		return dailyProgressTracker:answerClaimDailyQuestRewardRequest(playerUserId, dailyQuestId)
	end

	return harness
end

return DailyProgressTrackerTestHarness
