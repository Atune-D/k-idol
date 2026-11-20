-- DailyProgressTracker when the server clock moves backwards (a real clock can be corrected): a
-- second of playtime is never counted twice. FakeClock cannot move backwards, so this spec drives
-- the real keeper, ledger and tracker with a hand-set clock and a scheduler whose callbacks the
-- test runs by hand.

local DailyProgressTracker = require("../../src/server/DailyProgressTracker")
local DailyProgressTrackerTestHarness = require("./DailyProgressTrackerTestHarness")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local FakePlayerSaveDataStorage = require("../Support/FakePlayerSaveDataStorage")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local RewardLedger = require("../../src/server/RewardLedger")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = DailyProgressTrackerTestHarness.PLAYER
local TEST_MORNING_UNIX_SECONDS = DailyProgressTrackerTestHarness.TEST_DAY_START_UNIX_SECONDS + 36000

local function createHandSetClock(startingUnixSeconds: number)
	local handSetClock = { currentUnixSeconds = startingUnixSeconds }
	function handSetClock.getCurrentUnixSeconds(self): number
		return self.currentUnixSeconds
	end
	return handSetClock
end

-- Holds scheduled callbacks until the test runs them; time plays no part.
local function createHandRunScheduler()
	local handRunScheduler = { pendingCallbacks = {} }
	function handRunScheduler.scheduleCallbackAfterSeconds(self, _delaySeconds: number, callback: () -> ())
		local scheduledEntry = { callback = callback }
		table.insert(self.pendingCallbacks, scheduledEntry)
		return function()
			local pendingIndex = table.find(self.pendingCallbacks, scheduledEntry)
			if pendingIndex then
				table.remove(self.pendingCallbacks, pendingIndex)
			end
		end
	end
	function handRunScheduler.runOnlyCallbackOfKind(self, isWantedCallback: (any) -> boolean)
		for pendingIndex, scheduledEntry in self.pendingCallbacks do
			if isWantedCallback(scheduledEntry) then
				table.remove(self.pendingCallbacks, pendingIndex)
				scheduledEntry.callback()
				return
			end
		end
		error("no matching scheduled callback")
	end
	return handRunScheduler
end

describe("DailyProgressTracker with a clock that moves backwards", function()
	it("never counts a second twice after the clock moved back past the last recording", function()
		local handSetClock = createHandSetClock(TEST_MORNING_UNIX_SECONDS)
		local handRunScheduler = createHandRunScheduler()
		local fakePlayerSaveDataStorage = FakePlayerSaveDataStorage.new()
		fakePlayerSaveDataStorage:setCompletesOperationsImmediately(true)
		local recordingLogger = DailyProgressTrackerTestHarness.createRecordingLogger()
		local playerSaveDataKeeper = PlayerSaveDataKeeper.new({
			playerSaveDataStorage = fakePlayerSaveDataStorage,
			clock = handSetClock,
			scheduler = handRunScheduler,
			removePlayerFromGameWithMessage = function() end,
			logger = recordingLogger,
			generateUniqueSessionLockId = function()
				return "hand-set-clock-lock"
			end,
			buildStartingPlayerSaveDataForNewPlayer = function(currentUnixSeconds: number)
				return PlayerSaveDataSchema.createStartingPlayerSaveData({ "starter_wave" }, currentUnixSeconds)
			end,
		})
		local dailyProgressTracker = DailyProgressTracker.new({
			playerSaveDataKeeper = playerSaveDataKeeper,
			rewardLedger = RewardLedger.new({ playerSaveDataKeeper = playerSaveDataKeeper, logger = recordingLogger }),
			playerRequestRateLimiter = DailyProgressTrackerTestHarness.createAdmittingRateLimiter(),
			clock = handSetClock,
			scheduler = handRunScheduler,
			logger = recordingLogger,
			dailyQuestCatalogEntries = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS,
		})
		dailyProgressTracker:startTrackingDailyProgress()
		playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		-- The keeper scheduled its periodic save first; the tracker's recording came second.
		expect(#handRunScheduler.pendingCallbacks).toBe(2)
		local trackerRecordingEntry = handRunScheduler.pendingCallbacks[2]

		handSetClock.currentUnixSeconds = TEST_MORNING_UNIX_SECONDS + 300
		expect(dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 5).isAccepted).toBeTrue()

		handSetClock.currentUnixSeconds = TEST_MORNING_UNIX_SECONDS + 250
		handRunScheduler:runOnlyCallbackOfKind(function(scheduledEntry)
			return scheduledEntry == trackerRecordingEntry
		end)
		expect(playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).dailyProgress.playtimeSecondsToday).toBe(300)

		handSetClock.currentUnixSeconds = TEST_MORNING_UNIX_SECONDS + 310
		dailyProgressTracker:recordCountedPlaytimeAndStopCountingBeforeFinalSave(PLAYER)
		expect(playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).dailyProgress.playtimeSecondsToday).toBe(310)
	end)
end)
