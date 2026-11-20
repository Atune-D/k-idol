-- Daily claims across a server crash (development spec §3.3 "A reward and its record are one
-- change", §6.2 "Unit: daily content" and "Unit: ledger"), on RewardLedgerCrashableServerTestHarness:
-- a real keeper and ledger on a server that can crash, with this tracker on every server. After the
-- crash the reloaded save holds the reward together with its record, or neither, and the claim can
-- never be paid a second time.

local DailyProgressTracker = require("../../src/server/DailyProgressTracker")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local PlayerRequestRateLimiter = require("../../src/server/PlayerRequestRateLimiter")
local RewardLedgerCrashableServerTestHarness = require("./RewardLedgerCrashableServerTestHarness")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = RewardLedgerCrashableServerTestHarness.EXAMPLE_PLAYER_USER_ID
local PINK_HAIR_KEY = "asset_9000001"
-- The harness clock starts on 2025-11-19 00:00 UTC; one year plus ten hours later it is
-- 2026-11-19 10:00, the date whose test quests are pinned (quest_e: pink, target 1, 70 coins).
local SECONDS_FROM_HARNESS_START_TO_TEST_MORNING = 365 * 86400 + 10 * 3600

local function createCrashableHarnessWithTracker()
	local harnessReference = {}
	local clockThatFollowsTheHarness = {}
	function clockThatFollowsTheHarness.getCurrentUnixSeconds()
		return harnessReference.harness.fakeClock:getCurrentUnixSeconds()
	end
	local trackerLogger = { loggedWarnings = {} }
	function trackerLogger.logInformation() end
	function trackerLogger.logWarning(self, message: string)
		table.insert(self.loggedWarnings, message)
	end
	local harness = RewardLedgerCrashableServerTestHarness.createHarness({
		themedRoundCompletionRecordWriters = {
			DailyProgressTracker.createDailyQuestProgressRoundRecordWriter({
				clock = clockThatFollowsTheHarness,
				stylingItemByStylingItemKey = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
				dailyQuestCatalogEntries = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS,
				logger = trackerLogger,
			}),
		},
	})
	harnessReference.harness = harness
	harness.fakeClock:advanceBySeconds(SECONDS_FROM_HARNESS_START_TO_TEST_MORNING)

	-- Starts a server with a started tracker on it, then loads the player there.
	function harness.startServerWithTrackerAndLoadPlayer()
		local server = harness.startNewServer()
		server.dailyProgressTracker = DailyProgressTracker.new({
			playerSaveDataKeeper = server.playerSaveDataKeeper,
			rewardLedger = server.rewardLedger,
			playerRequestRateLimiter = PlayerRequestRateLimiter.new({ clock = harness.fakeClock }),
			clock = harness.fakeClock,
			scheduler = server.fakeScheduler,
			logger = trackerLogger,
			dailyQuestCatalogEntries = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS,
		})
		server.dailyProgressTracker:startTrackingDailyProgress()
		harness.startServerAndLoadPlayer(PLAYER)
		return server
	end

	-- Advances time on the running server, completing every storage operation as it starts.
	function harness.advanceSecondsWithStorageAnswering(elapsedSeconds: number)
		harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(true)
		harness.advanceSeconds(elapsedSeconds)
		harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(false)
	end

	return harness
end

-- Each claim: how to earn it (on the first server, and again after a reload when the save holds
-- no record), how to claim it, the coins it pays and how to see its record.
local DAILY_CLAIM_SCENARIOS = {
	{
		claimName = "playtime milestone 5 min",
		earnClaim = function(harness)
			harness.advanceSecondsWithStorageAnswering(310)
		end,
		earnClaimAgainAfterReload = function(harness)
			harness.advanceSecondsWithStorageAnswering(310)
		end,
		claim = function(server)
			return server.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 5)
		end,
		starCoinsPaidByClaim = 20,
		isRecordPresent = function(saveData)
			return table.find(saveData.dailyProgress.claimedPlaytimeMilestoneMinutes, 5) ~= nil
		end,
	},
	{
		claimName = "daily quest quest_e",
		earnClaim = function(harness, server)
			-- The round reward's own save completes, so only the claim's save is left in flight.
			harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(true)
			server.rewardLedger:grantThemedRoundReward(PLAYER, {
				roundId = "round-1",
				themeId = "y2k_pop",
				starCount = 1,
				scoredOutfitStylingItemKeys = { PINK_HAIR_KEY },
			})
			harness.advanceSecondsWithStorageAnswering(30)
		end,
		earnClaimAgainAfterReload = function(harness)
			-- The completed quest's progress was saved with its round reward.
			harness.advanceSecondsWithStorageAnswering(30)
		end,
		claim = function(server)
			return server.dailyProgressTracker:answerClaimDailyQuestRewardRequest(PLAYER, "quest_e")
		end,
		starCoinsPaidByClaim = 70,
		isRecordPresent = function(saveData)
			return table.find(saveData.dailyProgress.claimedDailyQuestIds, "quest_e") ~= nil
		end,
	},
}

local CRASH_POINTS = {
	{
		crashPointName = "the claim's save write is in flight and never arrives",
		prepareCrash = function() end,
		inFlightWriteFate = "InFlightWritesLost",
		expectedReloadedState = "Neither",
	},
	{
		crashPointName = "the claim's save write arrived but its answer was lost",
		prepareCrash = function() end,
		inFlightWriteFate = "InFlightWritesLanded",
		expectedReloadedState = "Both",
	},
	{
		crashPointName = "the claim's save succeeded",
		prepareCrash = function(harness)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		end,
		inFlightWriteFate = "InFlightWritesLost",
		expectedReloadedState = "Both",
	},
	{
		crashPointName = "the claim's save failed and the retry has not started",
		prepareCrash = function(harness)
			harness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
		end,
		inFlightWriteFate = "InFlightWritesLost",
		expectedReloadedState = "Neither",
	},
	{
		crashPointName = "the player left and the final save succeeded",
		prepareCrash = function(harness, server)
			server.dailyProgressTracker:recordCountedPlaytimeAndStopCountingBeforeFinalSave(PLAYER)
			server.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		end,
		inFlightWriteFate = "InFlightWritesLost",
		expectedReloadedState = "Both",
	},
}

describe("Daily claims across a server crash", function()
	for _, dailyClaimScenario in DAILY_CLAIM_SCENARIOS do
		for _, crashPoint in CRASH_POINTS do
			it(dailyClaimScenario.claimName .. ": " .. crashPoint.crashPointName, function()
				local harness = createCrashableHarnessWithTracker()
				local server = harness.startServerWithTrackerAndLoadPlayer()
				dailyClaimScenario.earnClaim(harness, server)
				local balanceBeforeClaim = server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).starCoinBalance
				expect(dailyClaimScenario.claim(server).isAccepted).toBeTrue()
				expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1)
				crashPoint.prepareCrash(harness, server)
				harness.crashCurrentServer(crashPoint.inFlightWriteFate)

				local reloadedServer = harness.startServerWithTrackerAndLoadPlayer()
				local reloadedSaveData = reloadedServer.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
				local hasRecord = dailyClaimScenario.isRecordPresent(reloadedSaveData)
				if crashPoint.expectedReloadedState == "Both" then
					expect(hasRecord).toBeTrue()
					expect(reloadedSaveData.starCoinBalance).toBe(
						balanceBeforeClaim + dailyClaimScenario.starCoinsPaidByClaim
					)
				else
					expect(hasRecord).toBeFalse()
					expect(reloadedSaveData.starCoinBalance).toBe(balanceBeforeClaim)
				end

				-- Whatever survived, the claim pays exactly once in all.
				dailyClaimScenario.earnClaimAgainAfterReload(harness)
				local claimAnswerAfterReload = dailyClaimScenario.claim(reloadedServer)
				expect(claimAnswerAfterReload.isAccepted).toBe(crashPoint.expectedReloadedState == "Neither")
				harness.advanceSecondsWithStorageAnswering(2)
				expect(dailyClaimScenario.claim(reloadedServer)).toEqual({
					isAccepted = false,
					rejectionReason = "AlreadyClaimed",
				})
				expect(reloadedServer.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).starCoinBalance).toBe(
					balanceBeforeClaim + dailyClaimScenario.starCoinsPaidByClaim
				)
			end)
		end
	end
end)
