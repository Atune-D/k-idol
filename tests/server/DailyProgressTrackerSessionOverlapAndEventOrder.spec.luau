-- DailyProgressTracker and the keeper's session events (development spec §2.6, §2.9 "counted by
-- the server while the player is connected", §3.4): a player who rejoins while the OLDER session
-- is still finishing is counted in the newer session, which the keeper loads only after the older
-- one ended (all playtime of the older one kept); the two "record and stop" calls
-- stop counting on their own; and the documented order of the "changed" and "loaded" events when
-- the tracker repairs a save at load.

local DailyProgressTrackerTestHarness = require("./DailyProgressTrackerTestHarness")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = DailyProgressTrackerTestHarness.PLAYER
local OTHER_PLAYER = DailyProgressTrackerTestHarness.OTHER_PLAYER

local function recordSessionEndReasons(harness)
	local sessionEndReasons = {}
	harness.playerSaveDataKeeper:subscribeToPlayerSaveDataSessionEnded(function(endedPlayerUserId, sessionEndReason)
		if endedPlayerUserId == PLAYER then
			table.insert(sessionEndReasons, sessionEndReason)
		end
	end)
	return sessionEndReasons
end

-- Plays 100 s, leaves, lets the final save LAND but report failure (the old session keeps
-- retrying) and rejoins at once. The keeper holds the new load back until the old session has
-- ended (PlayerSaveDataKeeper header, "Quick rejoin"), so the new session is not loaded yet.
local function rejoinWhileOldSessionFinalSaveIsStillRetrying()
	local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ isStorageHeldInFlight = true })
	harness.loadPlayer(PLAYER)
	harness.advanceSeconds(100)
	harness.leavePlayer(PLAYER)
	harness.fakePlayerSaveDataStorage:completeOldestPendingOperationButReportFailure(PLAYER)
	expect(harness.readStoredSaveData(PLAYER).dailyProgress.playtimeSecondsToday).toBe(100)
	harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
	expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()
	return harness
end

-- Runs the old session's final-save retries until the keeper ends it, answering each with
-- `answerOldestPendingOperation`.
local function runOldSessionRetriesUntilItEnds(harness, sessionEndReasons, answerOldestPendingOperation)
	for _ = 1, 10 do
		if #sessionEndReasons > 0 then
			return
		end
		harness.advanceSeconds(1)
		if harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER) > 0 then
			answerOldestPendingOperation(harness.fakePlayerSaveDataStorage)
		end
	end
	error("the old session never ended")
end

describe("DailyProgressTracker when an older session of a rejoined player ends", function()
	local oldSessionEndings = {
		{
			endingName = "its final save is abandoned after failing retries",
			answerOldestPendingOperation = function(fakePlayerSaveDataStorage)
				fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
			end,
		},
		{
			endingName = "its final-save retry finds the lock it already handed back (SessionLockLost)",
			answerOldestPendingOperation = function(fakePlayerSaveDataStorage)
				fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
			end,
		},
	}
	for _, oldSessionEnding in oldSessionEndings do
		it("counts the newer session, loaded once the older one ended, when " .. oldSessionEnding.endingName, function()
			local harness = rejoinWhileOldSessionFinalSaveIsStillRetrying()
			local sessionEndReasons = recordSessionEndReasons(harness)
			runOldSessionRetriesUntilItEnds(harness, sessionEndReasons, oldSessionEnding.answerOldestPendingOperation)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- the new load
			expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeTrue()
			expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(100)
			local playtimeWhenOldSessionEnded = harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday

			harness.advanceSeconds(600)
			expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday >= playtimeWhenOldSessionEnded + 540).toBeTrue()
			expect(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 10).isAccepted).toBeTrue()
			expect(harness.trackerLogger.loggedWarnings).toEqual({})
		end)
	end
end)

describe("DailyProgressTracker record-and-stop calls", function()
	it("stops counting the player at once, even when no final save follows", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ isStorageHeldInFlight = true })
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(90)
		harness.dailyProgressTracker:recordCountedPlaytimeAndStopCountingBeforeFinalSave(PLAYER)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(90)
		local revisionAfterRecording = harness.readInMemoryChangeRevision(PLAYER)
		harness.advanceSeconds(300)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(90)
		expect(harness.readInMemoryChangeRevision(PLAYER)).toBe(revisionAfterRecording)
		expect(harness.trackerLogger.loggedWarnings).toEqual({})
	end)

	it("stops counting every player at once before shutdown, even when no final save follows", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ isStorageHeldInFlight = true })
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(30)
		harness.loadPlayer(OTHER_PLAYER)
		harness.advanceSeconds(45)
		harness.dailyProgressTracker:recordCountedPlaytimeOfEveryPlayerAndStopCountingBeforeShutdown()
		harness.advanceSeconds(300)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(75)
		expect(harness.readInMemoryDailyProgress(OTHER_PLAYER).playtimeSecondsToday).toBe(45)
		expect(harness.trackerLogger.loggedWarnings).toEqual({})
	end)
end)

describe("DailyProgressTracker event order when it repairs a save at load", function()
	it("a listener subscribed after the tracker sees the repaired save change BEFORE the loaded event", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.storeExistingPlayerSaveData(PLAYER, function(saveData)
			saveData.dailyProgress.claimedPlaytimeMilestoneMinutes = { "five" }
			saveData.dailyProgress.playtimeSecondsToday = 400
		end)
		local observedEvents = {}
		harness.playerSaveDataKeeper:subscribeToPlayerSaveDataLoaded(function(_, loadedSaveDataCopy)
			table.insert(observedEvents, "Loaded playtime=" .. loadedSaveDataCopy.dailyProgress.playtimeSecondsToday)
		end)
		harness.playerSaveDataKeeper:subscribeToInMemorySaveDataChanged(function(_, changedSaveDataCopy)
			table.insert(observedEvents, "Changed playtime=" .. changedSaveDataCopy.dailyProgress.playtimeSecondsToday)
		end)
		harness.loadPlayer(PLAYER)
		expect(observedEvents).toEqual({ "Changed playtime=0", "Loaded playtime=400" })
		-- What the header tells the snapshot sender to read for its first snapshot:
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(0)
	end)
end)
