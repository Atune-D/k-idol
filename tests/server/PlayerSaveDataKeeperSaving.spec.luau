local UnitTestFramework = require("../Support/UnitTestFramework")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataKeeperTestHarness = require("./PlayerSaveDataKeeperTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID
local OTHER_PLAYER = PlayerSaveDataKeeperTestHarness.OTHER_PLAYER_USER_ID
local START = PlayerSaveDataKeeperTestHarness.EXAMPLE_STARTING_UNIX_SECONDS
local createKeeperWithFakes = PlayerSaveDataKeeperTestHarness.createKeeperWithFakes

-- A loaded player, 20 s after the load, so the 10 s spacing does not hold the next save back.
local function createHarnessWithLoadedPlayer()
	local harness = createKeeperWithFakes()
	harness.loadNewPlayer(PLAYER)
	harness.advanceSeconds(20)
	return harness
end

local function countEventsNamed(recordedEvents, eventName: string): number
	local matchingCount = 0
	for _, recordedEvent in recordedEvents do
		if recordedEvent.eventName == eventName then
			matchingCount += 1
		end
	end
	return matchingCount
end

describe("PlayerSaveDataKeeper writing", function()
	it("saves a progress change at once and refreshes the lock time and last-saved time", function()
		local harness = createHarnessWithLoadedPlayer()
		harness.grantStarCoins(PLAYER, 80)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1)
		harness.advanceSeconds(3) -- the write completes later than it started
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)

		local storedSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
		expect(storedSaveData.starCoinBalance).toBe(80)
		expect(storedSaveData.gameServerSessionLock).toEqual({
			sessionLockId = "this-server-lock-1",
			lockRefreshedAtUnixSeconds = START + 23,
		})
		expect(storedSaveData.lastSavedAtUnixSeconds).toBe(START + 23)
		expect({ harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER) }).toEqual({ 1, 1 })
	end)

	it("does not request a save for an appearance change; the next save of any kind writes it", function()
		local harness = createHarnessWithLoadedPlayer()
		local changeResult = harness.equipDance(PLAYER, "starter_step")
		expect(changeResult.changeOutcome).toBe("Applied")
		harness.advanceSeconds(60)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(0)
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).equippedDanceId).toBe("starter_wave")

		harness.grantStarCoins(PLAYER, 20)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		local storedSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
		expect(storedSaveData.equippedDanceId).toBe("starter_step")
		expect(storedSaveData.starCoinBalance).toBe(20)
	end)

	it("writes an appearance change with the periodic save, and saves every 120 s even with no changes", function()
		local harness = createKeeperWithFakes()
		harness.loadNewPlayer(PLAYER)
		harness.equipDance(PLAYER, "starter_step")
		harness.advanceSeconds(119.999)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(0)
		harness.advanceSeconds(0.001)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).equippedDanceId).toBe("starter_step")

		harness.advanceSeconds(120)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(
			harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).gameServerSessionLock.lockRefreshedAtUnixSeconds
		).toBe(START + 240)
	end)

	it(
		"abandons a write when the stored lock is not ours: storage untouched, player removed, saving stopped",
		function()
			local harness = createHarnessWithLoadedPlayer()
			local recordedEvents = harness.recordEveryEvent()
			local takenOverSave = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
			takenOverSave.gameServerSessionLock = {
				sessionLockId = PlayerSaveDataKeeperTestHarness.OTHER_SERVER_SESSION_LOCK_ID,
				lockRefreshedAtUnixSeconds = START + 19,
			}
			takenOverSave.starCoinBalance = 999
			harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(PLAYER, takenOverSave)
			local writtenCountBefore = #harness.fakePlayerSaveDataStorage.writtenPlayerSaveDataRecords

			harness.grantStarCoins(PLAYER, 80)
			local wasWritten = harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)

			expect(wasWritten).toBeFalse()
			expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)).toEqual(takenOverSave)
			expect(#harness.fakePlayerSaveDataStorage.writtenPlayerSaveDataRecords).toBe(writtenCountBefore)
			expect(harness.removedPlayerRecords).toEqual({
				{ playerUserId = PLAYER, playerFacingMessage = PlayerSaveDataKeeper.SESSION_LOCK_LOST_PLAYER_MESSAGE },
			})
			expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()
			expect(countEventsNamed(recordedEvents, "SaveDataSaveSucceeded")).toBe(0)
			expect(recordedEvents[#recordedEvents].eventValue).toBe("SessionLockLost")
			expect(harness.grantStarCoins(PLAYER, 5).changeOutcome).toBe("SaveDataNotLoaded")
			harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
			harness.advanceSeconds(600)
			expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(0)
			local didLogDiscardedProgress = false
			for _, loggedWarning in harness.loggedWarnings do
				if string.find(loggedWarning, "1 unsaved change(s)", 1, true) then
					didLogDiscardedProgress = true
				end
			end
			expect(didLogDiscardedProgress).toBeTrue()
		end
	)

	it("abandons a write when the stored lock has disappeared", function()
		local harness = createHarnessWithLoadedPlayer()
		local unlockedSave = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
		unlockedSave.gameServerSessionLock = nil
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(PLAYER, unlockedSave)
		harness.grantStarCoins(PLAYER, 80)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)).toEqual(unlockedSave)
		expect(#harness.removedPlayerRecords).toBe(1)
	end)

	it("keeps a failed save pending and retries it after 2, 4 and 8 seconds, ignoring the spacing", function()
		local harness = createHarnessWithLoadedPlayer()
		harness.grantStarCoins(PLAYER, 80)
		harness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
		expect({ harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER) }).toEqual({ 1, 0 })
		harness.advanceSeconds(2)
		harness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
		harness.advanceSeconds(4)
		harness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
		harness.advanceSeconds(7.999)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(0)
		harness.advanceSeconds(0.001)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)

		expect(harness.listOperationStartOffsets(PLAYER)).toEqual({ 0, 20, 22, 26, 34 })
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).starCoinBalance).toBe(80)
		expect({ harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER) }).toEqual({ 1, 1 })
		expect(harness.playerSaveDataKeeper:isSaveDataPersistenceDelayed(PLAYER)).toBeFalse()
	end)

	it(
		"sets the delayed flag after a full failed retry round, waits for the next trigger, and clears it on success",
		function()
			local harness = createHarnessWithLoadedPlayer()
			local recordedEvents = harness.recordEveryEvent()
			harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(true)
			harness.fakePlayerSaveDataStorage:failNextStartedOperations(4)
			harness.grantStarCoins(PLAYER, 80)
			harness.advanceSeconds(13.999)
			expect(harness.playerSaveDataKeeper:isSaveDataPersistenceDelayed(PLAYER)).toBeFalse()
			harness.advanceSeconds(0.001)
			expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(5) -- load + 4 attempts
			expect(harness.playerSaveDataKeeper:isSaveDataPersistenceDelayed(PLAYER)).toBeTrue()
			expect(recordedEvents[#recordedEvents]).toEqual({
				eventName = "SaveDataPersistenceDelayedChanged",
				playerUserId = PLAYER,
				eventValue = true,
			})

			-- Nothing more happens until the next trigger.
			harness.advanceSeconds(30)
			expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(5)
			harness.grantStarCoins(PLAYER, 1)
			expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(6)
			expect(harness.playerSaveDataKeeper:isSaveDataPersistenceDelayed(PLAYER)).toBeFalse()
			expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).starCoinBalance).toBe(81)
			local delayedFlagValues = {}
			for _, recordedEvent in recordedEvents do
				if recordedEvent.eventName == "SaveDataPersistenceDelayedChanged" then
					table.insert(delayedFlagValues, recordedEvent.eventValue)
				end
			end
			expect(delayedFlagValues).toEqual({ true, false })
		end
	)

	it("does not lose a change made while a save is in flight (revision noted at save start)", function()
		local harness = createHarnessWithLoadedPlayer()
		harness.grantStarCoins(PLAYER, 80)
		harness.grantStarCoins(PLAYER, 20) -- while the first save is in flight
		expect({ harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER) }).toEqual({ 2, 0 })
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).starCoinBalance).toBe(80)
		expect({ harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER) }).toEqual({ 2, 1 })

		harness.advanceSeconds(10)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).starCoinBalance).toBe(100)
		expect({ harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER) }).toEqual({ 2, 2 })
	end)

	it("never runs two saves for one player in parallel; overlapping requests become one more save", function()
		local harness = createHarnessWithLoadedPlayer()
		harness.grantStarCoins(PLAYER, 1)
		for _ = 1, 5 do
			harness.grantStarCoins(PLAYER, 1)
			harness.advanceSeconds(3)
			expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1)
		end
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		harness.advanceSeconds(60)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		harness.advanceSeconds(20)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(0)
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).starCoinBalance).toBe(6)
	end)

	it(
		"spaces two save requests within 10 s so the starts are 10 s apart, writing memory as of the later start",
		function()
			local harness = createHarnessWithLoadedPlayer()
			harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(true)
			harness.grantStarCoins(PLAYER, 1) -- starts at 20
			harness.advanceSeconds(3)
			harness.grantStarCoins(PLAYER, 1) -- requested at 23, must wait until 30
			harness.advanceSeconds(4)
			harness.equipDance(PLAYER, "starter_step") -- at 27: no request, but in memory when the save starts
			harness.advanceSeconds(2.999)
			expect(harness.listOperationStartOffsets(PLAYER)).toEqual({ 0, 20 })
			harness.advanceSeconds(0.001)
			expect(harness.listOperationStartOffsets(PLAYER)).toEqual({ 0, 20, 30 })
			local storedSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
			expect(storedSaveData.starCoinBalance).toBe(2)
			expect(storedSaveData.equippedDanceId).toBe("starter_step")
		end
	)

	it("counts the load's write as a save start for spacing", function()
		local harness = createKeeperWithFakes()
		harness.loadNewPlayer(PLAYER)
		harness.grantStarCoins(PLAYER, 1)
		harness.advanceSeconds(9.999)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(0)
		harness.advanceSeconds(0.001)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1)
	end)
end)

describe("PlayerSaveDataKeeper final save", function()
	it("ignores the spacing, clears the lock in the same write and ends the session", function()
		local harness = createHarnessWithLoadedPlayer()
		local recordedEvents = harness.recordEveryEvent()
		harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(true)
		harness.grantStarCoins(PLAYER, 80) -- save starts at 20
		harness.advanceSeconds(1)
		harness.grantStarCoins(PLAYER, 20)
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER) -- at 21

		expect(harness.listOperationStartOffsets(PLAYER)).toEqual({ 0, 20, 21 })
		local storedSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
		expect(storedSaveData.gameServerSessionLock).toBeNil()
		expect(storedSaveData.starCoinBalance).toBe(100)
		expect(storedSaveData.lastSavedAtUnixSeconds).toBe(START + 21)
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()
		expect(recordedEvents[#recordedEvents].eventValue).toBe("FinalSaveSucceeded")
		harness.advanceSeconds(600)
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(3)
	end)

	it("waits for a save already in flight, then writes the final save", function()
		local harness = createHarnessWithLoadedPlayer()
		harness.grantStarCoins(PLAYER, 80)
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1)
		expect(harness.grantStarCoins(PLAYER, 1).changeOutcome).toBe("SaveDataNotLoaded")
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).gameServerSessionLock).toBeNil()
	end)

	it("retries a failed final save up to 5 times, then abandons it and leaves the lock to expire", function()
		local harness = createHarnessWithLoadedPlayer()
		local recordedEvents = harness.recordEveryEvent()
		harness.grantStarCoins(PLAYER, 80)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		harness.grantStarCoins(PLAYER, 20)
		harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(true)
		harness.fakePlayerSaveDataStorage:failNextStartedOperations(100)
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
		harness.advanceSeconds(600)

		expect(harness.listOperationStartOffsets(PLAYER)).toEqual({ 0, 20, 20, 21, 22, 23, 24, 25 })
		local storedSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
		expect(storedSaveData.starCoinBalance).toBe(80)
		expect(storedSaveData.gameServerSessionLock.sessionLockId).toBe("this-server-lock-1")
		expect(recordedEvents[#recordedEvents].eventValue).toBe("FinalSaveAbandoned")
	end)

	it("abandons a final save whose lock was taken over and removes the player", function()
		local harness = createHarnessWithLoadedPlayer()
		local takenOverSave = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
		takenOverSave.gameServerSessionLock.sessionLockId = PlayerSaveDataKeeperTestHarness.OTHER_SERVER_SESSION_LOCK_ID
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(PLAYER, takenOverSave)
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)).toEqual(takenOverSave)
		expect(#harness.removedPlayerRecords).toBe(1)
	end)

	it("saves every player in parallel at shutdown and reports when all have finished", function()
		local harness = createKeeperWithFakes()
		harness.loadNewPlayer(PLAYER)
		harness.loadNewPlayer(OTHER_PLAYER)
		harness.advanceSeconds(1)
		harness.grantStarCoins(PLAYER, 80) -- waits for spacing; the final save makes that unnecessary
		local finishedCallbackCount = 0
		harness.playerSaveDataKeeper:startFinalSavesForServerShutdown(function()
			finishedCallbackCount += 1
		end)

		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(OTHER_PLAYER)).toBe(1)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(OTHER_PLAYER)
		expect(finishedCallbackCount).toBe(0)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(finishedCallbackCount).toBe(1)

		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).starCoinBalance).toBe(80)
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).gameServerSessionLock).toBeNil()
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(OTHER_PLAYER).gameServerSessionLock).toBeNil()
		harness.advanceSeconds(600)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations()).toBe(0)

		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(9999)
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations(9999)).toBe(0)
	end)

	it("reports shutdown finished at once when nobody is online", function()
		local harness = createKeeperWithFakes()
		local finishedCallbackCount = 0
		harness.playerSaveDataKeeper:startFinalSavesForServerShutdown(function()
			finishedCallbackCount += 1
		end)
		expect(finishedCallbackCount).toBe(1)
	end)
end)
