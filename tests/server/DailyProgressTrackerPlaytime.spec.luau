-- DailyProgressTracker playtime (development spec §1.8, §2.9 "counted by the server while the
-- player is connected", §3.4 spacing, §3.6 budgets, §6.2 "Unit: daily content"): counting while
-- the save is loaded, the write cadence into the in-memory save, leave and rejoin on the same day,
-- the UTC day boundary while online and at load.

local DailyProgressTrackerTestHarness = require("./DailyProgressTrackerTestHarness")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = DailyProgressTrackerTestHarness.PLAYER
local OTHER_PLAYER = DailyProgressTrackerTestHarness.OTHER_PLAYER
local TEST_DAILY_DATE_KEY = "2026-11-19"
local NEXT_DAILY_DATE_KEY = "2026-11-20"

local function countInMemoryChangeEvents(harness, playerUserId: number)
	local recordedDailyProgresses = {}
	harness.playerSaveDataKeeper:subscribeToInMemorySaveDataChanged(function(changedPlayerUserId, saveDataCopy)
		if changedPlayerUserId == playerUserId then
			table.insert(recordedDailyProgresses, saveDataCopy.dailyProgress)
		end
	end)
	return recordedDailyProgresses
end

describe("DailyProgressTracker playtime counting", function()
	it("counts nothing before the save has loaded and starts at 0 when it loads", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.advanceSeconds(600)
		harness.loadPlayer(PLAYER)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(0)
		harness.advanceSeconds(60)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(60)
	end)

	it("writes playtime into the in-memory save each time it reaches a whole minute, and not between", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(59)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(0)
		harness.advanceSeconds(1)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(60)
		harness.advanceSeconds(119)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(120)
		harness.advanceSeconds(1)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(180)
	end)

	it("aligns recordings to whole minutes of playtime when a rejoining player brings seconds with them", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.storeExistingPlayerSaveData(PLAYER, function(saveData)
			saveData.dailyProgress.playtimeSecondsToday = 250
		end)
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(49)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(250)
		harness.advanceSeconds(1)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(300)
	end)

	it("never requests a save of its own: only the load and the 120 s periodic saves reach storage", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(600)
		-- 1 load + periodic saves at 120, 240, 360, 480 and 600 s.
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(6)
		-- The 600 s periodic save was scheduled before the 600 s recording, so it holds 540 s.
		expect(harness.readStoredSaveData(PLAYER).dailyProgress.playtimeSecondsToday).toBe(540)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(600)
	end)

	it("makes one in-memory change (one snapshot) per minute of play, none at load for a current save", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		local changedDailyProgresses = countInMemoryChangeEvents(harness, PLAYER)
		harness.loadPlayer(PLAYER)
		expect(harness.readInMemoryChangeRevision(PLAYER)).toBe(0)
		harness.advanceSeconds(600)
		expect(harness.readInMemoryChangeRevision(PLAYER)).toBe(10)
		expect(#changedDailyProgresses).toBe(10)
		expect(changedDailyProgresses[10].playtimeSecondsToday).toBe(600)
	end)

	it("counts each player separately", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(120)
		harness.loadPlayer(OTHER_PLAYER)
		harness.advanceSeconds(60)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(180)
		expect(harness.readInMemoryDailyProgress(OTHER_PLAYER).playtimeSecondsToday).toBe(60)
	end)

	it("never schedules recordings closer than 1 s apart, even just below a whole minute", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.storeExistingPlayerSaveData(PLAYER, function(saveData)
			saveData.dailyProgress.playtimeSecondsToday = 119.5
		end)
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(0.5)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(119.5)
		harness.advanceSeconds(0.5)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(120.5)
	end)

	it("logs a recording that raises and keeps counting; the seconds are recorded next time", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ wrapsTrackerKeeperForFaults = true })
		harness.loadPlayer(PLAYER)
		harness.trackerKeeperWrapper.raisesOnNextChange = true
		harness.advanceSeconds(60)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(0)
		expect(#harness.trackerLogger.loggedWarnings).toBe(1)
		expect(
			string.find(harness.trackerLogger.loggedWarnings[1], "recording playtime for player 8801 raised", 1, true)
				~= nil
		).toBeTrue()
		harness.advanceSeconds(60)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(120)
	end)

	it("restarts counting on a repeated load event without leaving the earlier timer running", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ wrapsTrackerKeeperForFaults = true })
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(30)
		for _, trackerLoadedListener in harness.trackerKeeperWrapper.trackerLoadedListeners do
			trackerLoadedListener(PLAYER, harness.readInMemorySaveData(PLAYER))
		end
		local revisionAfterRestart = harness.readInMemoryChangeRevision(PLAYER)
		harness.advanceSeconds(120)
		-- One timer: recordings at 90 s and 150 s only.
		expect(harness.readInMemoryChangeRevision(PLAYER)).toBe(revisionAfterRestart + 2)
	end)

	it("raises when startTrackingDailyProgress is called twice", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		expect(function()
			harness.dailyProgressTracker:startTrackingDailyProgress()
		end).toThrow("already called")
	end)
end)

describe("DailyProgressTracker playtime across leaving and rejoining", function()
	it(
		"puts every counted second into the final save, so playtime survives a leave and rejoin on the same day",
		function()
			local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
			harness.loadPlayer(PLAYER)
			harness.advanceSeconds(450)
			harness.leavePlayer(PLAYER)
			expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()
			expect(harness.readStoredSaveData(PLAYER).dailyProgress.playtimeSecondsToday).toBe(450)

			harness.advanceSeconds(3600)
			harness.loadPlayer(PLAYER)
			expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(450)
			harness.advanceSeconds(30)
			expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(480)
		end
	)

	it("stops counting a player who left: nothing stays scheduled and the time away is not counted", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(90)
		harness.leavePlayer(PLAYER)
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
		harness.advanceSeconds(1000)
		harness.loadPlayer(PLAYER)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(90)
	end)

	it("does nothing when asked to record playtime of a player who is not being counted", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.dailyProgressTracker:recordCountedPlaytimeAndStopCountingBeforeFinalSave(PLAYER)
		harness.loadPlayer(OTHER_PLAYER)
		harness.dailyProgressTracker:recordCountedPlaytimeAndStopCountingBeforeFinalSave(PLAYER)
		expect(harness.readInMemoryChangeRevision(OTHER_PLAYER)).toBe(0)
		expect(harness.trackerLogger.loggedWarnings).toEqual({})
	end)

	it("records every counted player before the shutdown final saves", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(30)
		harness.loadPlayer(OTHER_PLAYER)
		harness.advanceSeconds(45)
		harness.dailyProgressTracker:recordCountedPlaytimeOfEveryPlayerAndStopCountingBeforeShutdown()
		local didEveryFinalSaveFinish = false
		harness.playerSaveDataKeeper:startFinalSavesForServerShutdown(function()
			didEveryFinalSaveFinish = true
		end)
		expect(didEveryFinalSaveFinish).toBeTrue()
		expect(harness.readStoredSaveData(PLAYER).dailyProgress.playtimeSecondsToday).toBe(75)
		expect(harness.readStoredSaveData(OTHER_PLAYER).dailyProgress.playtimeSecondsToday).toBe(45)
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
	end)

	it("stops counting when the keeper ends the session on its own (save lost to another server)", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(60)
		local storedSaveData = harness.readStoredSaveData(PLAYER)
		storedSaveData.gameServerSessionLock = { sessionLockId = "other-server", lockRefreshedAtUnixSeconds = 0 }
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(PLAYER, storedSaveData)
		harness.advanceSeconds(60) -- the periodic save at 120 s finds the lock is not ours
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()
		-- A recording still running would find no save and log "not recorded".
		harness.advanceSeconds(600)
		expect(harness.trackerLogger.loggedWarnings).toEqual({})
	end)

	it("logs and stops when the save is no longer loaded at a scheduled recording", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ isStorageHeldInFlight = true })
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(30)
		-- The wiring forgot to record first: the final save starts while counting still runs.
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
		harness.advanceSeconds(30)
		expect(#harness.trackerLogger.loggedWarnings).toBe(1)
		expect(
			string.find(harness.trackerLogger.loggedWarnings[1], "not recorded: save data not loaded", 1, true) ~= nil
		).toBeTrue()
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
	end)
end)

describe("DailyProgressTracker playtime and the UTC day boundary", function()
	it("does not carry playtime into the next day: a save from yesterday loads with 0", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ secondsAfterMidnight = 23 * 3600 })
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(1800)
		harness.leavePlayer(PLAYER)
		expect(harness.readStoredSaveData(PLAYER).dailyProgress.playtimeSecondsToday).toBe(1800)
		harness.advanceToTimeOfDay(1, 600)
		harness.loadPlayer(PLAYER)
		local dailyProgress = harness.readInMemoryDailyProgress(PLAYER)
		expect(dailyProgress.dailyDateKey).toBe(NEXT_DAILY_DATE_KEY)
		expect(dailyProgress.playtimeSecondsToday).toBe(0)
	end)

	it("replaces dailyProgress exactly at UTC midnight while the player is online; old seconds stay behind", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ secondsAfterMidnight = 86400 - 90 })
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(60)
		harness.advanceSeconds(29)
		local dailyProgressBeforeMidnight = harness.readInMemoryDailyProgress(PLAYER)
		expect(dailyProgressBeforeMidnight.dailyDateKey).toBe(TEST_DAILY_DATE_KEY)
		expect(dailyProgressBeforeMidnight.playtimeSecondsToday).toBe(60)

		harness.advanceSeconds(1) -- exactly 00:00:00
		local dailyProgressAtMidnight = harness.readInMemoryDailyProgress(PLAYER)
		expect(dailyProgressAtMidnight.dailyDateKey).toBe(NEXT_DAILY_DATE_KEY)
		expect(dailyProgressAtMidnight.playtimeSecondsToday).toBe(0)

		harness.advanceSeconds(60)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(60)
	end)

	it("counts only the seconds after midnight when the last recording was the day before", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ secondsAfterMidnight = 86400 - 40 })
		harness.loadPlayer(PLAYER)
		-- Move the clock without running scheduled work: the midnight recording has not run yet.
		harness.fakeClock:advanceBySeconds(100)
		harness.dailyProgressTracker:recordCountedPlaytimeAndStopCountingBeforeFinalSave(PLAYER)
		local dailyProgress = harness.readInMemoryDailyProgress(PLAYER)
		expect(dailyProgress.dailyDateKey).toBe(NEXT_DAILY_DATE_KEY)
		expect(dailyProgress.playtimeSecondsToday).toBe(60)
	end)

	it("random sessions: playtime equals the seconds played on that UTC day, across leaves and midnights", function()
		SeededRandomTrials.runSeededRandomTrials(40, function(randomNumberGenerator)
			local harness = DailyProgressTrackerTestHarness.createTrackerHarness({
				secondsAfterMidnight = randomNumberGenerator.nextWholeNumberInRange(0, 86399),
			})
			local expectedPlaytimeByDailyDateKey = {}
			-- Books the seconds of [sessionStartUnixSeconds, sessionEndUnixSeconds) to their UTC days.
			local function bookSessionSecondsByDay(sessionStartUnixSeconds: number, sessionEndUnixSeconds: number)
				local bookedUpToUnixSeconds = sessionStartUnixSeconds
				while bookedUpToUnixSeconds < sessionEndUnixSeconds do
					local nextMidnightUnixSeconds = (bookedUpToUnixSeconds // 86400 + 1) * 86400
					local bookedUntilUnixSeconds = math.min(nextMidnightUnixSeconds, sessionEndUnixSeconds)
					local dailyDateKey = PlayerSaveDataSchema.formatUtcDailyDateKey(bookedUpToUnixSeconds)
					expectedPlaytimeByDailyDateKey[dailyDateKey] = (expectedPlaytimeByDailyDateKey[dailyDateKey] or 0)
						+ bookedUntilUnixSeconds
						- bookedUpToUnixSeconds
					bookedUpToUnixSeconds = bookedUntilUnixSeconds
				end
			end
			for _ = 1, randomNumberGenerator.nextWholeNumberInRange(1, 4) do
				harness.advanceSeconds(randomNumberGenerator.nextWholeNumberInRange(0, 100000))
				harness.loadPlayer(PLAYER)
				local sessionStartUnixSeconds = harness.fakeClock:getCurrentUnixSeconds()
				for _ = 1, randomNumberGenerator.nextWholeNumberInRange(1, 8) do
					harness.advanceSeconds(randomNumberGenerator.nextWholeNumberInRange(1, 20000))
				end
				bookSessionSecondsByDay(sessionStartUnixSeconds, harness.fakeClock:getCurrentUnixSeconds())
				harness.leavePlayer(PLAYER)
				local storedDailyProgress = harness.readStoredSaveData(PLAYER).dailyProgress
				expect(storedDailyProgress.dailyDateKey).toBe(
					PlayerSaveDataSchema.formatUtcDailyDateKey(harness.fakeClock:getCurrentUnixSeconds())
				)
				expect(storedDailyProgress.playtimeSecondsToday).toBe(
					expectedPlaytimeByDailyDateKey[storedDailyProgress.dailyDateKey] or 0
				)
			end
		end)
	end)
end)
