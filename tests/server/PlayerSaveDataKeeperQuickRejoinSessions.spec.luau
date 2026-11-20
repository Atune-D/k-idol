-- PlayerSaveDataKeeper when a player rejoins this server while the previous session is still
-- finishing (header "Quick rejoin"; development spec §3.4 loading and final save). The new load
-- waits inside the keeper and starts the moment the previous session has ended, so listeners
-- always hear that session end first. Covers the consequences: leaving again while waiting, a
-- third join, an abandoned final save whose lock stays in storage, the lock lost to another
-- server, shutdown while waiting, and what the public API reports meanwhile.

local UnitTestFramework = require("../Support/UnitTestFramework")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataKeeperTestHarness = require("./PlayerSaveDataKeeperTestHarness")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID
local OTHER_SERVER_SESSION_LOCK_ID = PlayerSaveDataKeeperTestHarness.OTHER_SERVER_SESSION_LOCK_ID
local createKeeperWithFakes = PlayerSaveDataKeeperTestHarness.createKeeperWithFakes
local FINAL_SAVE_MAXIMUM_RETRY_COUNT = PlayerSaveDataKeeper.FINAL_SAVE_MAXIMUM_RETRY_COUNT
local FINAL_SAVE_RETRY_DELAY_SECONDS = PlayerSaveDataKeeper.FINAL_SAVE_RETRY_DELAY_SECONDS
local LOAD_MAXIMUM_RETRY_COUNT = PlayerSaveDataKeeper.LOAD_MAXIMUM_RETRY_COUNT
local LOAD_RETRY_DELAY_SECONDS = PlayerSaveDataKeeper.LOAD_RETRY_DELAY_SECONDS

-- "PlayerSaveDataLoaded", "PlayerSaveDataSessionEnded:FinalSaveSucceeded", ... for PLAYER.
local function describePlayerEvents(recordedEvents): { string }
	local eventDescriptions = {}
	for _, recordedEvent in recordedEvents do
		if recordedEvent.playerUserId == PLAYER then
			if recordedEvent.eventName == "PlayerSaveDataSessionEnded" then
				table.insert(eventDescriptions, recordedEvent.eventName .. ":" .. recordedEvent.eventValue)
			else
				table.insert(eventDescriptions, recordedEvent.eventName)
			end
		end
	end
	return eventDescriptions
end

-- Loads PLAYER, saves 100 star coins, adds 5 unsaved ones at T = 20 and leaves: the final save
-- (writing 105) is in flight when this returns, and nothing else is.
local function loadPlayerWithProgressAndLeave(harness)
	harness.loadNewPlayer(PLAYER)
	harness.advanceSeconds(20)
	harness.grantStarCoins(PLAYER, 100)
	harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
	harness.grantStarCoins(PLAYER, 5)
	harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
	assert(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER) == 1, "the final save is in flight")
end

local function failOldestOperationAfterEachFinalSaveRetryDelay(harness)
	harness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
	for _ = 1, FINAL_SAVE_MAXIMUM_RETRY_COUNT do
		harness.advanceSeconds(FINAL_SAVE_RETRY_DELAY_SECONDS)
		harness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
	end
end

describe("PlayerSaveDataKeeper quick rejoin: the new load waits for the previous session", function()
	it("starts the new load the moment the old session ends, after its event, without a 5 s retry", function()
		local harness = createKeeperWithFakes()
		local recordedEvents = harness.recordEveryEvent()
		loadPlayerWithProgressAndLeave(harness)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.advanceSeconds(30) -- the old final save is still in flight: nothing starts meanwhile
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(3)
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()

		local startedCountSeenBySessionEndedListener = nil
		harness.playerSaveDataKeeper:subscribeToPlayerSaveDataSessionEnded(function()
			startedCountSeenBySessionEndedListener = harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)
		end)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- the old final save
		expect(startedCountSeenBySessionEndedListener).toBe(3) -- every listener heard the end first
		expect(harness.listOperationStartOffsets(PLAYER)).toEqual({ 0, 20, 20, 50 })

		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- the new load
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeTrue()
		expect(harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).starCoinBalance).toBe(105)
		expect(describePlayerEvents(recordedEvents)).toEqual({
			"PlayerSaveDataLoaded",
			"InMemorySaveDataChanged",
			"SaveDataSaveSucceeded",
			"InMemorySaveDataChanged",
			"SaveDataSaveSucceeded",
			"PlayerSaveDataSessionEnded:FinalSaveSucceeded",
			"PlayerSaveDataLoaded",
		})
		expect(harness.loggedWarnings).toEqual({})
	end)

	it("reports nothing loaded while the new load waits, even when the old session's saving is delayed", function()
		local harness = createKeeperWithFakes()
		harness.loadNewPlayer(PLAYER)
		harness.advanceSeconds(20)
		harness.grantStarCoins(PLAYER, 100)
		harness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
		for _, retryDelaySeconds in PlayerSaveDataKeeper.FAILED_SAVE_RETRY_DELAYS_SECONDS do
			harness.advanceSeconds(retryDelaySeconds)
			harness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
		end
		expect(harness.playerSaveDataKeeper:isSaveDataPersistenceDelayed(PLAYER)).toBeTrue()
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)

		local keeper = harness.playerSaveDataKeeper
		expect(keeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()
		expect(keeper:readPlayerSaveDataCopy(PLAYER)).toBeNil()
		expect(keeper:isSaveDataPersistenceDelayed(PLAYER)).toBeFalse()
		local firstRevision, secondRevision = keeper:readSaveChangeRevisions(PLAYER)
		expect(firstRevision).toBeNil()
		expect(secondRevision).toBeNil()
		expect(harness.grantStarCoins(PLAYER, 1).changeOutcome).toBe("SaveDataNotLoaded")
	end)

	it("ignores another join while the new load already waits", function()
		local harness = createKeeperWithFakes()
		loadPlayerWithProgressAndLeave(harness)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		expect(#harness.loggedWarnings).toBe(1)
		expect(string.find(harness.loggedWarnings[1], "already loading or loaded", 1, true) ~= nil).toBeTrue()
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeTrue()
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(0)
	end)

	it("a player who leaves again while the new load waits never touches storage again", function()
		local harness = createKeeperWithFakes()
		local recordedEvents = harness.recordEveryEvent()
		loadPlayerWithProgressAndLeave(harness)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
		-- Not ended yet: its end must not come before the old session's.
		expect(#describePlayerEvents(recordedEvents)).toBe(4)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)

		local playerEvents = describePlayerEvents(recordedEvents)
		expect({ playerEvents[6], playerEvents[7] }).toEqual({
			"PlayerSaveDataSessionEnded:FinalSaveSucceeded",
			"PlayerSaveDataSessionEnded:LeftBeforeLoadFinished",
		})
		expect(#playerEvents).toBe(7)
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(3)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(0)
		local storedSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
		expect(storedSaveData.gameServerSessionLock).toBeNil()
		expect(storedSaveData.starCoinBalance).toBe(105)
	end)

	it("a third join waits behind both earlier sessions and loads after both ended", function()
		local harness = createKeeperWithFakes()
		local recordedEvents = harness.recordEveryEvent()
		loadPlayerWithProgressAndLeave(harness)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER) -- second session waits
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER) -- it leaves while waiting
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER) -- third session waits too
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(3)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(4) -- only the third's load
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)

		local playerEvents = describePlayerEvents(recordedEvents)
		expect({ playerEvents[6], playerEvents[7], playerEvents[8] }).toEqual({
			"PlayerSaveDataSessionEnded:FinalSaveSucceeded",
			"PlayerSaveDataSessionEnded:LeftBeforeLoadFinished",
			"PlayerSaveDataLoaded",
		})
		expect(harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).starCoinBalance).toBe(105)
	end)
end)

describe("PlayerSaveDataKeeper quick rejoin: how the previous session ends", function()
	it("final save abandoned: its lock stays, so the new load fails as the loading table says", function()
		local harness = createKeeperWithFakes()
		local recordedEvents = harness.recordEveryEvent()
		loadPlayerWithProgressAndLeave(harness)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		local writeCountBeforeAbandoning = #harness.fakePlayerSaveDataStorage.writtenPlayerSaveDataRecords
		failOldestOperationAfterEachFinalSaveRetryDelay(harness) -- the old final save is abandoned
		local storedSaveDataAtAbandoning = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
		expect(storedSaveDataAtAbandoning.gameServerSessionLock.sessionLockId).toBe("this-server-lock-1")
		expect(storedSaveDataAtAbandoning.starCoinBalance).toBe(100)

		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- the new load: held
		for _ = 1, LOAD_MAXIMUM_RETRY_COUNT do
			harness.advanceSeconds(LOAD_RETRY_DELAY_SECONDS)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		end

		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()
		expect(harness.removedPlayerRecords).toEqual({
			{ playerUserId = PLAYER, playerFacingMessage = PlayerSaveDataKeeper.LOAD_RETRIES_EXHAUSTED_PLAYER_MESSAGE },
		})
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)).toEqual(storedSaveDataAtAbandoning)
		expect(#harness.fakePlayerSaveDataStorage.writtenPlayerSaveDataRecords).toBe(writeCountBeforeAbandoning)
		local playerEvents = describePlayerEvents(recordedEvents)
		expect({ playerEvents[#playerEvents - 1], playerEvents[#playerEvents] }).toEqual({
			"PlayerSaveDataSessionEnded:FinalSaveAbandoned",
			"PlayerSaveDataSessionEnded:LoadRetriesExhausted",
		})
	end)

	it("lock lost to another server: the player is removed, then the new load waits for that lock", function()
		local harness = createKeeperWithFakes()
		local recordedEvents = harness.recordEveryEvent()
		loadPlayerWithProgressAndLeave(harness)
		local storedSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
		storedSaveData.gameServerSessionLock = {
			sessionLockId = OTHER_SERVER_SESSION_LOCK_ID,
			lockRefreshedAtUnixSeconds = harness.fakeClock:getCurrentUnixSeconds(),
		}
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(PLAYER, storedSaveData)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- the final save: lock not ours
		expect(harness.removedPlayerRecords).toEqual({
			{ playerUserId = PLAYER, playerFacingMessage = PlayerSaveDataKeeper.SESSION_LOCK_LOST_PLAYER_MESSAGE },
		})
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- the new load: held
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER)).toBeFalse()

		storedSaveData.gameServerSessionLock = nil -- the other server hands the save back
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(PLAYER, storedSaveData)
		harness.advanceSeconds(LOAD_RETRY_DELAY_SECONDS)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).starCoinBalance).toBe(100)
		local playerEvents = describePlayerEvents(recordedEvents)
		expect({ playerEvents[#playerEvents - 1], playerEvents[#playerEvents] }).toEqual({
			"PlayerSaveDataSessionEnded:SessionLockLost",
			"PlayerSaveDataLoaded",
		})
	end)

	it("once the waiting load has started it is an ordinary load: leaving during its retry ends it at once", function()
		local harness = createKeeperWithFakes()
		local recordedEvents = harness.recordEveryEvent()
		loadPlayerWithProgressAndLeave(harness)
		local storedSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
		storedSaveData.gameServerSessionLock = {
			sessionLockId = OTHER_SERVER_SESSION_LOCK_ID,
			lockRefreshedAtUnixSeconds = harness.fakeClock:getCurrentUnixSeconds(),
		}
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(PLAYER, storedSaveData)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- the final save: SessionLockLost
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- the new load: held, retry due
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
		local playerEvents = describePlayerEvents(recordedEvents)
		expect({ playerEvents[#playerEvents - 1], playerEvents[#playerEvents] }).toEqual({
			"PlayerSaveDataSessionEnded:SessionLockLost",
			"PlayerSaveDataSessionEnded:LeftBeforeLoadFinished",
		})
		local startedCountAtLeave = harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)
		harness.advanceSeconds(LOAD_RETRY_DELAY_SECONDS)
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(startedCountAtLeave)
	end)

	it("a load in flight when the player left takes the save: its final save runs, then the new load", function()
		local harness = createKeeperWithFakes()
		local recordedEvents = harness.recordEveryEvent()
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- the old load takes the save
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1) -- its final save only
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- the new load
		expect(describePlayerEvents(recordedEvents)).toEqual({
			"SaveDataSaveSucceeded",
			"PlayerSaveDataSessionEnded:FinalSaveSucceeded",
			"PlayerSaveDataLoaded",
		})
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(3)
	end)

	it("a load in flight when the player left finds a newer schema: the waiting load then refuses it too", function()
		local harness = createKeeperWithFakes()
		local recordedEvents = harness.recordEveryEvent()
		local storedSaveData = PlayerSaveDataSchema.createStartingPlayerSaveData(
			PlayerSaveDataKeeperTestHarness.STARTER_DANCE_IDS,
			harness.fakeClock:getCurrentUnixSeconds()
		)
		storedSaveData.saveDataSchemaVersion = 99
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(PLAYER, storedSaveData)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(describePlayerEvents(recordedEvents)).toEqual({
			"PlayerSaveDataSessionEnded:StoredSchemaVersionNotUnderstood",
			"PlayerSaveDataSessionEnded:StoredSchemaVersionNotUnderstood",
		})
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)).toEqual(storedSaveData)
	end)

	it("a load waiting out another server's lock ends at the leave, so a rejoin loads without waiting", function()
		local harness = createKeeperWithFakes()
		local recordedEvents = harness.recordEveryEvent()
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(
			PLAYER,
			PlayerSaveDataKeeperTestHarness.createStoredSaveLockedByOtherServer(
				harness.fakeClock:getCurrentUnixSeconds()
			)
		)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- held; retry scheduled
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
		expect(describePlayerEvents(recordedEvents)).toEqual({ "PlayerSaveDataSessionEnded:LeftBeforeLoadFinished" })
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1)
	end)
end)

describe("PlayerSaveDataKeeper quick rejoin and server shutdown", function()
	it("a load still waiting at shutdown never starts; shutdown finishes once after both sessions ended", function()
		local harness = createKeeperWithFakes()
		local recordedEvents = harness.recordEveryEvent()
		loadPlayerWithProgressAndLeave(harness)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		local shutdownFinishedEventCounts = {}
		harness.playerSaveDataKeeper:startFinalSavesForServerShutdown(function()
			table.insert(shutdownFinishedEventCounts, #describePlayerEvents(recordedEvents))
		end)
		expect(shutdownFinishedEventCounts).toEqual({})
		expect(#describePlayerEvents(recordedEvents)).toBe(4)

		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		local playerEvents = describePlayerEvents(recordedEvents)
		expect({ playerEvents[6], playerEvents[7] }).toEqual({
			"PlayerSaveDataSessionEnded:FinalSaveSucceeded",
			"PlayerSaveDataSessionEnded:LeftBeforeLoadFinished",
		})
		expect(shutdownFinishedEventCounts).toEqual({ 7 })
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(3)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations()).toBe(0)
	end)

	it("shutdown waits for an abandoned old final save and then ends the waiting session", function()
		local harness = createKeeperWithFakes()
		local recordedEvents = harness.recordEveryEvent()
		loadPlayerWithProgressAndLeave(harness)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		local shutdownFinishedCount = 0
		harness.playerSaveDataKeeper:startFinalSavesForServerShutdown(function()
			shutdownFinishedCount += 1
		end)
		harness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
		for _ = 1, FINAL_SAVE_MAXIMUM_RETRY_COUNT do
			expect(shutdownFinishedCount).toBe(0)
			harness.advanceSeconds(FINAL_SAVE_RETRY_DELAY_SECONDS)
			harness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
		end
		expect(shutdownFinishedCount).toBe(1)
		local playerEvents = describePlayerEvents(recordedEvents)
		expect({ playerEvents[#playerEvents - 1], playerEvents[#playerEvents] }).toEqual({
			"PlayerSaveDataSessionEnded:FinalSaveAbandoned",
			"PlayerSaveDataSessionEnded:LeftBeforeLoadFinished",
		})
		harness.advanceSeconds(60)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations()).toBe(0)
	end)
end)
