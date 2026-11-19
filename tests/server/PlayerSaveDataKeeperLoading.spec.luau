local UnitTestFramework = require("../Support/UnitTestFramework")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataKeeperTestHarness = require("./PlayerSaveDataKeeperTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID
local START = PlayerSaveDataKeeperTestHarness.EXAMPLE_STARTING_UNIX_SECONDS
local createKeeperWithFakes = PlayerSaveDataKeeperTestHarness.createKeeperWithFakes
local createStoredSaveLockedByOtherServer = PlayerSaveDataKeeperTestHarness.createStoredSaveLockedByOtherServer

describe("PlayerSaveDataKeeper loading", function()
	it("creates, locks and stores a starting save for a player with no stored save", function()
		local harness = createKeeperWithFakes()
		local recordedEvents = harness.recordEveryEvent()
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)

		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeTrue()
		local storedSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
		expect(storedSaveData.gameServerSessionLock).toEqual({
			sessionLockId = "this-server-lock-1",
			lockRefreshedAtUnixSeconds = START,
		})
		expect(storedSaveData.ownedDanceIds).toEqual(PlayerSaveDataKeeperTestHarness.STARTER_DANCE_IDS)
		expect(recordedEvents[1].eventName).toBe("PlayerSaveDataLoaded")
		expect(recordedEvents[1].eventValue).toEqual(storedSaveData)
		expect(harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)).toBe(0)
	end)

	it("waits while another server holds an unexpired lock and succeeds after it is released", function()
		local harness = createKeeperWithFakes()
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(
			PLAYER,
			createStoredSaveLockedByOtherServer(START - 10)
		)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).gameServerSessionLock.sessionLockId).toBe(
			PlayerSaveDataKeeperTestHarness.OTHER_SERVER_SESSION_LOCK_ID
		)

		-- The retry comes 5 seconds later, not sooner.
		harness.advanceSeconds(4.999)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(0)
		harness.advanceSeconds(0.001)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- still held
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()

		-- The other server's final save hands the lock back.
		local releasedSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
		releasedSaveData.gameServerSessionLock = nil
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(PLAYER, releasedSaveData)
		harness.advanceSeconds(5)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)

		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeTrue()
		local loadedSaveData = harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
		expect(loadedSaveData.fanCount).toBe(1200)
		expect(loadedSaveData.starCoinBalance).toBe(350)
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).gameServerSessionLock.sessionLockId).toBe(
			"this-server-lock-1"
		)
	end)

	it("treats a lock not refreshed for 360 seconds as expired and takes the save over", function()
		local harness = createKeeperWithFakes()
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(
			PLAYER,
			createStoredSaveLockedByOtherServer(START - 360)
		)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeTrue()
		expect(harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).fanCount).toBe(1200)
	end)

	it("still respects a lock refreshed 359.999 seconds ago", function()
		local harness = createKeeperWithFakes()
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(
			PLAYER,
			createStoredSaveLockedByOtherServer(START - 359.999)
		)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()
	end)

	it("retries at most 6 times, then removes the player and leaves the stored save untouched", function()
		local harness = createKeeperWithFakes()
		local recordedEvents = harness.recordEveryEvent()
		local otherServerSave = createStoredSaveLockedByOtherServer(START)
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(PLAYER, otherServerSave)
		harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(true)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.advanceSeconds(29)
		expect(#harness.removedPlayerRecords).toBe(0)
		harness.advanceSeconds(1)

		expect(harness.listOperationStartOffsets(PLAYER)).toEqual({ 0, 5, 10, 15, 20, 25, 30 })
		expect(harness.removedPlayerRecords).toEqual({
			{ playerUserId = PLAYER, playerFacingMessage = PlayerSaveDataKeeper.LOAD_RETRIES_EXHAUSTED_PLAYER_MESSAGE },
		})
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)).toEqual(otherServerSave)
		expect(#harness.fakePlayerSaveDataStorage.writtenPlayerSaveDataRecords).toBe(0)
		expect(recordedEvents[#recordedEvents].eventValue).toBe("LoadRetriesExhausted")
		harness.advanceSeconds(60)
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(7)
	end)

	it("retries after a storage error and never substitutes a starting save when loading keeps failing", function()
		local harness = createKeeperWithFakes()
		local recordedEvents = harness.recordEveryEvent()
		harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(true)
		harness.fakePlayerSaveDataStorage:failNextStartedOperations(7)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.advanceSeconds(60)

		expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(7)
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()
		expect(harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)).toBeNil()
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)).toBeNil()
		for _, recordedEvent in recordedEvents do
			expect(recordedEvent.eventName == "PlayerSaveDataLoaded").toBeFalse()
		end
		expect(harness.removedPlayerRecords[1].playerUserId).toBe(PLAYER)
		local changeResult = harness.grantStarCoins(PLAYER, 10)
		expect(changeResult.changeOutcome).toBe("SaveDataNotLoaded")
	end)

	it("loads on a later attempt after storage errors", function()
		local harness = createKeeperWithFakes()
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(
			PLAYER,
			createStoredSaveLockedByOtherServer(START - 400)
		)
		harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(true)
		harness.fakePlayerSaveDataStorage:failNextStartedOperations(2)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.advanceSeconds(10)
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeTrue()
		expect(harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).fanCount).toBe(1200)
	end)

	it("refuses a save with a newer schema version without overwriting it, and removes the player", function()
		local harness = createKeeperWithFakes()
		local newerSave: any = createStoredSaveLockedByOtherServer(START - 400)
		newerSave.saveDataSchemaVersion = 2
		newerSave.fieldFromTheFuture = { "kept" }
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(PLAYER, newerSave)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)

		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)).toEqual(newerSave)
		expect(#harness.fakePlayerSaveDataStorage.writtenPlayerSaveDataRecords).toBe(0)
		expect(harness.removedPlayerRecords).toEqual({
			{
				playerUserId = PLAYER,
				playerFacingMessage = PlayerSaveDataKeeper.STORED_SCHEMA_VERSION_NOT_UNDERSTOOD_PLAYER_MESSAGE,
			},
		})
		harness.advanceSeconds(60)
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(1)
	end)

	it("replaces yesterday's daily progress when it loads the save, and keeps today's", function()
		local harness = createKeeperWithFakes()
		local storedSave: any = createStoredSaveLockedByOtherServer(START - 400)
		storedSave.dailyProgress.dailyDateKey = "2025-11-18"
		storedSave.dailyProgress.playtimeSecondsToday = 1800
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(PLAYER, storedSave)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		local loadedProgress = harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).dailyProgress
		expect(loadedProgress.dailyDateKey).toBe("2025-11-19")
		expect(loadedProgress.playtimeSecondsToday).toBe(0)

		local sameDayHarness = createKeeperWithFakes()
		storedSave.dailyProgress.dailyDateKey = "2025-11-19"
		sameDayHarness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(PLAYER, storedSave)
		sameDayHarness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		sameDayHarness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(sameDayHarness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).dailyProgress.playtimeSecondsToday).toBe(
			1800
		)
	end)

	it("takes a save whose stored lock is its own (a load whose answer was lost)", function()
		local harness = createKeeperWithFakes()
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperationButReportFailure(PLAYER)
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()
		harness.advanceSeconds(5)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeTrue()
	end)

	it("hands the lock straight back when the player leaves while the load is in flight", function()
		local harness = createKeeperWithFakes()
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- the load
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- the final save
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).gameServerSessionLock).toBeNil()
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations()).toBe(0)
	end)

	it("stops retrying when the player leaves while waiting for a held lock", function()
		local harness = createKeeperWithFakes()
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(PLAYER, createStoredSaveLockedByOtherServer(START))
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
		harness.advanceSeconds(60)
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(1)
		expect(#harness.removedPlayerRecords).toBe(0)
	end)
end)
