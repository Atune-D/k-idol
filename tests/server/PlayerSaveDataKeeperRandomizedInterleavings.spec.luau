-- Random interleavings of changes, time, save completions and failures. The seed is printed on
-- failure; rerun with IDOLGROW_RANDOM_TEST_SEED=<seed> to reproduce.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeFanCountLeaderboardStorage = require("../Support/FakeFanCountLeaderboardStorage")
local FanCountLeaderboardKeeper = require("../../src/server/FanCountLeaderboardKeeper")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataKeeperTestHarness = require("./PlayerSaveDataKeeperTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID
local PROGRESS = PlayerSaveDataKeeper.PROGRESS_CHANGE_SAVED_AT_ONCE
local APPEARANCE = PlayerSaveDataKeeper.APPEARANCE_CHANGE_SAVED_LATER
local TRIAL_COUNT = 150
local STEPS_PER_TRIAL = 80
local SPACING_TOLERANCE_SECONDS = 1e-6

local DANCE_IDS = { "starter_wave", "starter_step" }

local function removeKeeperManagedFields(saveData)
	local comparableSaveData = table.clone(saveData)
	comparableSaveData.gameServerSessionLock = nil
	comparableSaveData.lastSavedAtUnixSeconds = nil
	return comparableSaveData
end

-- One random step. Records how every storage operation ended, in start order (at most one is
-- ever in flight, so completion order equals start order).
local function runOneRandomStep(harness, operationOutcomes)
	local playerSaveDataKeeper = harness.playerSaveDataKeeper
	local fakeStorage = harness.fakePlayerSaveDataStorage
	local stepKind = math.random(1, 9)
	if stepKind == 1 then
		harness.grantStarCoins(PLAYER, math.random(1, 100))
	elseif stepKind == 2 then
		harness.grantFans(PLAYER, math.random(1, 50))
	elseif stepKind == 3 then
		harness.equipDance(PLAYER, DANCE_IDS[math.random(1, #DANCE_IDS)])
	elseif stepKind == 4 then
		local changeKind = if math.random() < 0.5 then PROGRESS else APPEARANCE
		playerSaveDataKeeper:applyChangeToPlayerSaveData(PLAYER, changeKind, "random decline", function(saveDataDraft)
			saveDataDraft.starCoinBalance += 1000
			return false, "RandomDecline"
		end)
	elseif stepKind == 5 then
		harness.advanceSeconds(math.random(0, 15000) / 1000)
	elseif stepKind <= 7 then
		if fakeStorage:countPendingOperations(PLAYER) > 0 then
			fakeStorage:completeOldestPendingOperation(PLAYER)
			table.insert(operationOutcomes, { outcome = "Succeeded", finishedAtOffset = harness.secondsSinceStart() })
		end
	elseif stepKind == 8 then
		if fakeStorage:countPendingOperations(PLAYER) > 0 then
			fakeStorage:failOldestPendingOperation(PLAYER)
			table.insert(operationOutcomes, { outcome = "Failed", finishedAtOffset = harness.secondsSinceStart() })
		end
	else
		if fakeStorage:countPendingOperations(PLAYER) > 0 then
			fakeStorage:completeOldestPendingOperationButReportFailure(PLAYER)
			table.insert(operationOutcomes, { outcome = "Failed", finishedAtOffset = harness.secondsSinceStart() })
		end
	end
end

local function isRetryDelay(secondsAfterFailure: number): boolean
	for _, retryDelaySeconds in PlayerSaveDataKeeper.FAILED_SAVE_RETRY_DELAYS_SECONDS do
		if math.abs(secondsAfterFailure - retryDelaySeconds) < SPACING_TOLERANCE_SECONDS then
			return true
		end
	end
	return false
end

-- A save start closer than 10 s to the previous start is allowed only as a retry: the previous
-- operation failed and this start came exactly 2, 4 or 8 s after that failure. (The final save
-- is checked separately.)
local function expectSpacingRespected(harness, operationOutcomes, startOffsetsToCheckCount: number)
	local startOffsets = harness.listOperationStartOffsets(PLAYER)
	for startPosition = 2, startOffsetsToCheckCount do
		local gapSeconds = startOffsets[startPosition] - startOffsets[startPosition - 1]
		if gapSeconds < PlayerSaveDataKeeper.MINIMUM_SECONDS_BETWEEN_SAVE_STARTS - SPACING_TOLERANCE_SECONDS then
			local previousOperation = operationOutcomes[startPosition - 1]
			local isRetry = previousOperation.outcome == "Failed"
				and isRetryDelay(startOffsets[startPosition] - previousOperation.finishedAtOffset)
			if not isRetry then
				error(
					string.format(
						"save start %d came %.3f s after start %d, and is not a retry",
						startPosition,
						gapSeconds,
						startPosition - 1
					)
				)
			end
		end
	end
end

describe("PlayerSaveDataKeeper randomized interleavings", function()
	it(
		"never has two saves in flight, spaces starts 10 s apart except retries, and ends with storage equal to memory",
		function()
			PlayerSaveDataKeeperTestHarness.runSeededRandomTrials(TRIAL_COUNT, function()
				local harness = PlayerSaveDataKeeperTestHarness.createKeeperWithFakes()
				if math.random() < 0.5 then
					harness.fakePlayerSaveDataStorage:setRunsEveryDecisionTwice(true)
				end
				local fakeLeaderboardStorage = FakeFanCountLeaderboardStorage.new()
				fakeLeaderboardStorage:setCompletesWritesImmediately(true)
				FanCountLeaderboardKeeper.new({
					playerSaveDataKeeper = harness.playerSaveDataKeeper,
					fanCountLeaderboardStorage = fakeLeaderboardStorage,
					clock = harness.fakeClock,
					scheduler = harness.fakeScheduler,
					logger = { logInformation = function() end, logWarning = function() end },
					lookUpPlayerDisplayNamesByUserId = function()
						return {}
					end,
				}):startSyncingAndRefreshingTopEntries()

				local operationOutcomes = { { outcome = "Succeeded", finishedAtOffset = 0 } } -- the load
				harness.loadNewPlayer(PLAYER)
				for _ = 1, STEPS_PER_TRIAL do
					runOneRandomStep(harness, operationOutcomes)
					expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER) <= 1).toBeTrue()
					local inMemoryRevision, lastSavedRevision =
						harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)
					expect(lastSavedRevision <= inMemoryRevision).toBeTrue()
				end
				-- Finish what is in flight, then let a periodic save (a trigger of any kind) catch up.
				while harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER) > 0 do
					harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
					table.insert(
						operationOutcomes,
						{ outcome = "Succeeded", finishedAtOffset = harness.secondsSinceStart() }
					)
				end
				harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(true)
				local startCountBeforeQuiescing = harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)
				harness.advanceSeconds(PlayerSaveDataKeeper.PERIODIC_SAVE_INTERVAL_SECONDS + 15)
				local quiescingStartOffsets = harness.listOperationStartOffsets(PLAYER)
				for startPosition = startCountBeforeQuiescing + 1, #quiescingStartOffsets do
					-- immediate mode: each finished when it started
					table.insert(
						operationOutcomes,
						{ outcome = "Succeeded", finishedAtOffset = quiescingStartOffsets[startPosition] }
					)
				end
				expectSpacingRespected(harness, operationOutcomes, #operationOutcomes)

				local inMemorySaveData = harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
				local storedSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
				expect(removeKeeperManagedFields(storedSaveData)).toEqual(removeKeeperManagedFields(inMemorySaveData))
				local inMemoryRevision, lastSavedRevision = harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)
				expect(lastSavedRevision).toBe(inMemoryRevision)
				expect(harness.playerSaveDataKeeper:isSaveDataPersistenceDelayed(PLAYER)).toBeFalse()

				-- The final save hands the lock back and stores exactly the in-memory save.
				harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
				local finalStoredSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
				expect(finalStoredSaveData.gameServerSessionLock).toBeNil()
				expect(removeKeeperManagedFields(finalStoredSaveData)).toEqual(
					removeKeeperManagedFields(inMemorySaveData)
				)

				-- The leaderboard only ever received fan counts that were written to the save store.
				local savedFanCounts = {}
				for _, writtenRecord in harness.fakePlayerSaveDataStorage.writtenPlayerSaveDataRecords do
					savedFanCounts[writtenRecord.writtenPlayerSaveData.fanCount] = true
				end
				for _, leaderboardWrite in fakeLeaderboardStorage.startedWriteRecords do
					expect(savedFanCounts[leaderboardWrite.fanCountBeingWritten]).toBeTrue()
				end
				expect(fakeLeaderboardStorage:readStoredFanCount(PLAYER)).toBe(finalStoredSaveData.fanCount)
			end)
		end
	)
end)
