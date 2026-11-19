local UnitTestFramework = require("../Support/UnitTestFramework")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataKeeperTestHarness = require("./PlayerSaveDataKeeperTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID
local OTHER_PLAYER = PlayerSaveDataKeeperTestHarness.OTHER_PLAYER_USER_ID
local PROGRESS = PlayerSaveDataKeeper.PROGRESS_CHANGE_SAVED_AT_ONCE
local APPEARANCE = PlayerSaveDataKeeper.APPEARANCE_CHANGE_SAVED_LATER
local createKeeperWithFakes = PlayerSaveDataKeeperTestHarness.createKeeperWithFakes

local function createHarnessWithLoadedPlayer()
	local harness = createKeeperWithFakes()
	harness.loadNewPlayer(PLAYER)
	harness.advanceSeconds(20)
	return harness
end

-- Asserts that nothing at all changed: memory, revisions, storage activity and events.
local function captureObservableState(harness)
	return {
		inMemorySaveData = harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER),
		changeRevisions = { harness.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER) },
		startedOperationCount = harness.fakePlayerSaveDataStorage:countStartedOperations(),
	}
end

describe("PlayerSaveDataKeeper event isolation", function()
	local function subscribeTamperingThenObservingListeners(subscribeToEvent)
		local secondListenerSeenValues = {}
		subscribeToEvent(function(_, eventValue)
			eventValue.fanCount = -1
			eventValue.ownedDanceIds[1] = "tampered"
			table.insert(eventValue.ownedDanceIds, "added_by_listener")
		end)
		subscribeToEvent(function(_, eventValue)
			table.insert(secondListenerSeenValues, eventValue)
		end)
		return secondListenerSeenValues
	end

	local function expectUntampered(seenSaveData)
		expect(seenSaveData.fanCount == -1).toBeFalse()
		expect(seenSaveData.ownedDanceIds).toEqual(PlayerSaveDataKeeperTestHarness.STARTER_DANCE_IDS)
	end

	it("gives each loaded-event listener its own copy", function()
		local harness = createKeeperWithFakes()
		local seenValues = subscribeTamperingThenObservingListeners(function(listener)
			harness.playerSaveDataKeeper:subscribeToPlayerSaveDataLoaded(listener)
		end)
		harness.loadNewPlayer(PLAYER)
		expectUntampered(seenValues[1])
		expectUntampered(harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER))
	end)

	it("gives each in-memory-changed listener its own copy, and the keeper's save is unaffected", function()
		local harness = createHarnessWithLoadedPlayer()
		local seenValues = subscribeTamperingThenObservingListeners(function(listener)
			harness.playerSaveDataKeeper:subscribeToInMemorySaveDataChanged(listener)
		end)
		harness.grantStarCoins(PLAYER, 80)
		expectUntampered(seenValues[1])
		expect(seenValues[1].starCoinBalance).toBe(80)
		expectUntampered(harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER))
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expectUntampered(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER))
	end)

	it("gives each save-succeeded listener its own copy", function()
		local harness = createHarnessWithLoadedPlayer()
		local seenValues = subscribeTamperingThenObservingListeners(function(listener)
			harness.playerSaveDataKeeper:subscribeToSaveDataSaveSucceeded(listener)
		end)
		harness.grantStarCoins(PLAYER, 80)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expectUntampered(seenValues[1])
		expect(seenValues[1].starCoinBalance).toBe(80)
		expectUntampered(harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER))
	end)

	it("keeps saving when a listener raises", function()
		local harness = createHarnessWithLoadedPlayer()
		harness.playerSaveDataKeeper:subscribeToInMemorySaveDataChanged(function()
			error("listener exploded")
		end)
		expect(harness.grantStarCoins(PLAYER, 80).changeOutcome).toBe("Applied")
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).starCoinBalance).toBe(80)
		expect(#harness.loggedWarnings > 0).toBeTrue()
	end)

	it("hands out read copies that cannot change the keeper's save", function()
		local harness = createHarnessWithLoadedPlayer()
		local readCopy = harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
		readCopy.starCoinBalance = 5000
		expect(harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).starCoinBalance).toBe(0)
	end)
end)

describe("PlayerSaveDataKeeper.applyChangeToPlayerSaveData", function()
	it("applies an indivisible eligibility check + balance change + record, and reports the revision", function()
		local harness = createHarnessWithLoadedPlayer()
		local function claimMilestoneFive(saveDataDraft)
			if table.find(saveDataDraft.dailyProgress.claimedPlaytimeMilestoneMinutes, 5) then
				return false, "AlreadyClaimed"
			end
			saveDataDraft.starCoinBalance += 20
			table.insert(saveDataDraft.dailyProgress.claimedPlaytimeMilestoneMinutes, 5)
			return true
		end
		local firstResult =
			harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(PLAYER, PROGRESS, "claim", claimMilestoneFive)
		expect(firstResult).toEqual({ changeOutcome = "Applied", inMemoryChangeRevision = 1 })
		local secondResult =
			harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(PLAYER, PROGRESS, "claim", claimMilestoneFive)
		expect(secondResult).toEqual({ changeOutcome = "Declined", declineReason = "AlreadyClaimed" })
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		local storedSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER)
		expect(storedSaveData.starCoinBalance).toBe(20)
		expect(storedSaveData.dailyProgress.claimedPlaytimeMilestoneMinutes).toEqual({ 5 })
	end)

	it("changes nothing when the change is declined: no revision, no save, no event", function()
		local harness = createHarnessWithLoadedPlayer()
		local recordedEvents = harness.recordEveryEvent()
		local stateBefore = captureObservableState(harness)
		local changeResult = harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(
			PLAYER,
			PROGRESS,
			"spend",
			function(saveDataDraft)
				saveDataDraft.starCoinBalance -= 900 -- edits made before declining are thrown away
				return false, "InsufficientStarCoins"
			end
		)
		expect(changeResult).toEqual({ changeOutcome = "Declined", declineReason = "InsufficientStarCoins" })
		harness.advanceSeconds(60)
		expect(captureObservableState(harness)).toEqual(stateBefore)
		expect(#recordedEvents).toBe(0)
	end)

	it("treats a change that leaves the save exactly as it was as no change: no revision, no save, no event", function()
		local harness = createHarnessWithLoadedPlayer()
		local recordedEvents = harness.recordEveryEvent()
		local stateBefore = captureObservableState(harness)
		local equipResult = harness.equipDance(PLAYER, "starter_wave") -- already equipped
		local progressResult = harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(
			PLAYER,
			PROGRESS,
			"add zero",
			function(saveDataDraft)
				saveDataDraft.starCoinBalance += 0
				saveDataDraft.lobbyOutfitStylingItemKeys = {}
				return true
			end
		)
		expect(equipResult).toEqual({ changeOutcome = "AppliedWithoutAnyDifference" })
		expect(progressResult).toEqual({ changeOutcome = "AppliedWithoutAnyDifference" })
		harness.advanceSeconds(60)
		expect(captureObservableState(harness)).toEqual(stateBefore)
		expect(#recordedEvents).toBe(0)
	end)

	it("changes nothing and passes the error on when the change raises", function()
		local harness = createHarnessWithLoadedPlayer()
		local stateBefore = captureObservableState(harness)
		expect(function()
			harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(PLAYER, PROGRESS, "broken", function(saveDataDraft)
				saveDataDraft.starCoinBalance += 50
				error("ledger bug")
			end)
		end).toThrow("ledger bug")
		expect(captureObservableState(harness)).toEqual(stateBefore)
		expect(harness.grantStarCoins(PLAYER, 1).changeOutcome).toBe("Applied") -- not left stuck
	end)

	it("refuses a change that yields, and changes nothing", function()
		local harness = createHarnessWithLoadedPlayer()
		local stateBefore = captureObservableState(harness)
		expect(function()
			harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(PLAYER, PROGRESS, "yields", function(saveDataDraft)
				saveDataDraft.starCoinBalance += 50
				coroutine.yield()
				return true
			end)
		end).toThrow("must not yield")
		expect(captureObservableState(harness)).toEqual(stateBefore)
	end)

	it("refuses a change that returns something other than true or false", function()
		local harness = createHarnessWithLoadedPlayer()
		local stateBefore = captureObservableState(harness)
		expect(function()
			harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(
				PLAYER,
				PROGRESS,
				"forgot to return",
				function(saveDataDraft)
					saveDataDraft.starCoinBalance += 50
				end :: any
			)
		end).toThrow("must return true")
		expect(captureObservableState(harness)).toEqual(stateBefore)
	end)

	it("refuses a change that edits the lock, the last-saved time or the schema version", function()
		local harness = createHarnessWithLoadedPlayer()
		local stateBefore = captureObservableState(harness)
		for _, keeperManagedFieldName in { "gameServerSessionLock", "lastSavedAtUnixSeconds", "saveDataSchemaVersion" } do
			expect(function()
				harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(
					PLAYER,
					PROGRESS,
					"tamper",
					function(saveDataDraft)
						saveDataDraft[keeperManagedFieldName] = 7
						return true
					end
				)
			end).toThrow(keeperManagedFieldName)
		end
		expect(captureObservableState(harness)).toEqual(stateBefore)
	end)

	it("refuses a change started inside another change of the same player", function()
		local harness = createHarnessWithLoadedPlayer()
		expect(function()
			harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(PLAYER, PROGRESS, "outer", function()
				harness.grantStarCoins(PLAYER, 1)
				return true
			end)
		end).toThrow("inside another change")
		expect(harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).starCoinBalance).toBe(0)
	end)

	it("refuses an unknown change kind", function()
		local harness = createHarnessWithLoadedPlayer()
		expect(function()
			harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(PLAYER, "Whatever" :: any, "x", function()
				return true
			end)
		end).toThrow("unknown playerSaveDataChangeKind")
	end)

	it("answers SaveDataNotLoaded without calling the change for a player not loaded", function()
		local harness = createKeeperWithFakes()
		local wasChangeCalled = false
		local changeResult = harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(
			OTHER_PLAYER,
			APPEARANCE,
			"x",
			function()
				wasChangeCalled = true
				return true
			end
		)
		expect(changeResult).toEqual({ changeOutcome = "SaveDataNotLoaded" })
		expect(wasChangeCalled).toBeFalse()
	end)

	it("fires the in-memory-changed event once per applied change, before the save is written", function()
		local harness = createHarnessWithLoadedPlayer()
		local recordedEvents = harness.recordEveryEvent()
		harness.grantStarCoins(PLAYER, 80)
		expect(#recordedEvents).toBe(1)
		expect(recordedEvents[1].eventName).toBe("InMemorySaveDataChanged")
		expect(recordedEvents[1].eventValue.starCoinBalance).toBe(80)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(recordedEvents[2].eventName).toBe("SaveDataSaveSucceeded")
	end)
end)
