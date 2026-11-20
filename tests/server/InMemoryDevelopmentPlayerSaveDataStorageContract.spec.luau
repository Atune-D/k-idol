-- The PlayerSaveDataStorage contract (PlayerSaveDataKeeper.luau header) checked the SAME way
-- against tests/Support/FakePlayerSaveDataStorage (the storage every keeper test uses) and the
-- in-memory development storage the server runs on in an unpublished Studio place: atomic
-- read-decide-write, the decision may run more than once, nil cancels, the callback is called
-- exactly once. Then the real keeper is run on the in-memory storage.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local FakePlayerSaveDataStorage = require("../Support/FakePlayerSaveDataStorage")
local RecordingLogger = require("../Support/RecordingLogger")
local InMemoryDevelopmentPlayerSaveDataStorage = require("../../src/server/InMemoryDevelopmentPlayerSaveDataStorage")
local InMemoryDevelopmentStorageValueCopier = require("../../src/server/InMemoryDevelopmentStorageValueCopier")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_ID = 8801
local OTHER_PLAYER_ID = 8802

-- Each storage under test, built fresh: { storage, finishPendingCallbacks() }.
local STORAGE_BUILDERS = {
	{
		storageName = "FakePlayerSaveDataStorage (tests/Support)",
		build = function(decisionRunCount: number)
			local fakeClock = FakeClock.new(1_800_000_000)
			local storage = FakePlayerSaveDataStorage.new(fakeClock)
			storage:setCompletesOperationsImmediately(true)
			storage:setRunsEveryDecisionTwice(decisionRunCount == 2)
			return storage, function() end
		end,
	},
	{
		storageName = "InMemoryDevelopmentPlayerSaveDataStorage",
		build = function(decisionRunCount: number)
			local fakeClock = FakeClock.new(1_800_000_000)
			local fakeScheduler = FakeScheduler.new(fakeClock)
			local storage = InMemoryDevelopmentPlayerSaveDataStorage.new({
				scheduler = fakeScheduler,
				decisionRunCountPerUpdate = decisionRunCount,
			})
			return storage, function()
				fakeScheduler:advanceTimeAndRunDueCallbacks(0)
			end
		end,
	},
}

-- Starts one update and returns the list of (wasSuccessful, message) the callback received.
local function startUpdateAndRecordFinishes(storage, playerUserId: number, decide)
	local recordedFinishes = {}
	storage:startAtomicPlayerSaveDataUpdate(playerUserId, decide, function(wasSuccessful, storageErrorMessage)
		table.insert(recordedFinishes, { wasSuccessful = wasSuccessful, storageErrorMessage = storageErrorMessage })
	end)
	return recordedFinishes
end

local function readStored(storage, playerUserId: number)
	if storage.readStoredPlayerSaveDataCopy then
		return storage:readStoredPlayerSaveDataCopy(playerUserId)
	end
	return storage:readStoredPlayerSaveData(playerUserId)
end

for _, storageBuilder in STORAGE_BUILDERS do
	describe("PlayerSaveDataStorage contract: " .. storageBuilder.storageName, function()
		it(
			"hands the decision nil for a new key, stores what it returns, and hands that to the next decision",
			function()
				local storage, finishPendingCallbacks = storageBuilder.build(1)
				local seenStoredValues = {}
				startUpdateAndRecordFinishes(storage, PLAYER_ID, function(storedValue)
					table.insert(seenStoredValues, storedValue == nil)
					return { starCoinBalance = 5 }
				end)
				finishPendingCallbacks()
				startUpdateAndRecordFinishes(storage, PLAYER_ID, function(storedValue)
					table.insert(seenStoredValues, storedValue.starCoinBalance)
					return { starCoinBalance = storedValue.starCoinBalance + 1 }
				end)
				finishPendingCallbacks()
				expect(seenStoredValues).toEqual({ true, 5 })
				expect(readStored(storage, PLAYER_ID)).toEqual({ starCoinBalance = 6 })
				expect(readStored(storage, OTHER_PLAYER_ID)).toBeNil()
			end
		)

		it("cancels the write when the decision returns nil and still reports success once", function()
			local storage, finishPendingCallbacks = storageBuilder.build(1)
			startUpdateAndRecordFinishes(storage, PLAYER_ID, function()
				return { fanCount = 3 }
			end)
			finishPendingCallbacks()
			local recordedFinishes = startUpdateAndRecordFinishes(storage, PLAYER_ID, function()
				return nil
			end)
			finishPendingCallbacks()
			expect(readStored(storage, PLAYER_ID)).toEqual({ fanCount = 3 })
			expect(recordedFinishes).toEqual({ { wasSuccessful = true } })
		end)

		it("calls the finish callback exactly once per update, and only once even after more time passes", function()
			local storage, finishPendingCallbacks = storageBuilder.build(1)
			local recordedFinishes = startUpdateAndRecordFinishes(storage, PLAYER_ID, function()
				return { fanCount = 1 }
			end)
			finishPendingCallbacks()
			finishPendingCallbacks()
			expect(#recordedFinishes).toBe(1)
			expect(recordedFinishes[1].wasSuccessful).toBeTrue()
		end)

		it("isolates the stored value from what the decision received and returned", function()
			local storage, finishPendingCallbacks = storageBuilder.build(1)
			local returnedValue = { ownedDanceIds = { "starter_groove" } }
			startUpdateAndRecordFinishes(storage, PLAYER_ID, function()
				return returnedValue
			end)
			finishPendingCallbacks()
			returnedValue.ownedDanceIds[1] = "changed after the write"
			startUpdateAndRecordFinishes(storage, PLAYER_ID, function(storedValue)
				storedValue.ownedDanceIds[1] = "changed by a decision that then cancels"
				return nil
			end)
			finishPendingCallbacks()
			expect(readStored(storage, PLAYER_ID)).toEqual({ ownedDanceIds = { "starter_groove" } })
		end)

		it("may run the decision more than once on the same stored value and keeps exactly one write", function()
			local storage, finishPendingCallbacks = storageBuilder.build(2)
			startUpdateAndRecordFinishes(storage, PLAYER_ID, function()
				return { totalRoundsCompletedCount = 10 }
			end)
			finishPendingCallbacks()
			local seenRoundCounts = {}
			local recordedFinishes = startUpdateAndRecordFinishes(storage, PLAYER_ID, function(storedValue)
				table.insert(seenRoundCounts, storedValue.totalRoundsCompletedCount)
				return { totalRoundsCompletedCount = storedValue.totalRoundsCompletedCount + 1 }
			end)
			finishPendingCallbacks()
			expect(seenRoundCounts).toEqual({ 10, 10 })
			expect(readStored(storage, PLAYER_ID)).toEqual({ totalRoundsCompletedCount = 11 })
			expect(#recordedFinishes).toBe(1)
		end)

		it("returns from the start call without yielding", function()
			local storage, finishPendingCallbacks = storageBuilder.build(1)
			local startThread = coroutine.create(function()
				storage:startAtomicPlayerSaveDataUpdate(PLAYER_ID, function()
					return { fanCount = 1 }
				end, function() end)
			end)
			coroutine.resume(startThread)
			expect(coroutine.status(startThread)).toBe("dead")
			finishPendingCallbacks()
		end)
	end)
end

describe("InMemoryDevelopmentPlayerSaveDataStorage beyond the shared contract", function()
	local function buildInMemoryStorage(decisionRunCount: number?)
		local fakeClock = FakeClock.new(1_800_000_000)
		local fakeScheduler = FakeScheduler.new(fakeClock)
		local storage = InMemoryDevelopmentPlayerSaveDataStorage.new({
			scheduler = fakeScheduler,
			decisionRunCountPerUpdate = decisionRunCount,
		})
		return storage, fakeScheduler, fakeClock
	end

	it("reports the result only after the start call has returned (through the scheduler)", function()
		local storage, fakeScheduler = buildInMemoryStorage()
		local recordedFinishes = startUpdateAndRecordFinishes(storage, PLAYER_ID, function()
			return { fanCount = 1 }
		end)
		expect(#recordedFinishes).toBe(0)
		fakeScheduler:advanceTimeAndRunDueCallbacks(0)
		expect(#recordedFinishes).toBe(1)
	end)

	it("reports failure and writes nothing when the decision raises", function()
		local storage, fakeScheduler = buildInMemoryStorage()
		startUpdateAndRecordFinishes(storage, PLAYER_ID, function()
			return { fanCount = 2 }
		end)
		local recordedFinishes = startUpdateAndRecordFinishes(storage, PLAYER_ID, function()
			error("decision failed on purpose")
		end)
		fakeScheduler:advanceTimeAndRunDueCallbacks(0)
		expect(recordedFinishes[1].wasSuccessful).toBeFalse()
		expect(string.find(recordedFinishes[1].storageErrorMessage, "decision failed on purpose", 1, true) ~= nil).toBeTrue()
		expect(storage:readStoredPlayerSaveDataCopy(PLAYER_ID)).toEqual({ fanCount = 2 })
		expect(storage:countWrittenSaves()).toBe(1)
	end)

	it("refuses to store what a data store could not hold, and writes nothing", function()
		local storage, fakeScheduler = buildInMemoryStorage()
		local cyclicSave = {}
		cyclicSave.itself = cyclicSave
		for _, unstorableSave in { { callback = function() end }, setmetatable({}, {}), cyclicSave, { 0 / 0 } } do
			local recordedFinishes = startUpdateAndRecordFinishes(storage, PLAYER_ID, function()
				return unstorableSave
			end)
			fakeScheduler:advanceTimeAndRunDueCallbacks(0)
			expect(recordedFinishes[1].wasSuccessful).toBeFalse()
		end
		expect(storage:readStoredPlayerSaveDataCopy(PLAYER_ID)).toBeNil()
		expect(storage:countWrittenSaves()).toBe(0)
	end)

	it("refuses tables nested deeper than the copier's limit, and a key that is not a string or a number", function()
		local storage, fakeScheduler = buildInMemoryStorage()
		local deeplyNestedSave = {}
		local innermostTable = deeplyNestedSave
		for _ = 1, InMemoryDevelopmentStorageValueCopier.MAXIMUM_NESTING_DEPTH do
			innermostTable.nested = {}
			innermostTable = innermostTable.nested
		end
		for _, unstorableSave in { deeplyNestedSave, { [true] = 1 } } do
			local recordedFinishes = startUpdateAndRecordFinishes(storage, PLAYER_ID, function()
				return unstorableSave
			end)
			fakeScheduler:advanceTimeAndRunDueCallbacks(0)
			expect(recordedFinishes[1].wasSuccessful).toBeFalse()
		end
		local nestedJustWithinLimit = {}
		innermostTable = nestedJustWithinLimit
		for _ = 1, InMemoryDevelopmentStorageValueCopier.MAXIMUM_NESTING_DEPTH - 1 do
			innermostTable.nested = {}
			innermostTable = innermostTable.nested
		end
		local acceptedFinishes = startUpdateAndRecordFinishes(storage, PLAYER_ID, function()
			return nestedJustWithinLimit
		end)
		fakeScheduler:advanceTimeAndRunDueCallbacks(0)
		expect(acceptedFinishes[1].wasSuccessful).toBeTrue()
	end)

	it("raises for wiring errors", function()
		expect(function()
			InMemoryDevelopmentPlayerSaveDataStorage.new({})
		end).toThrow("a scheduler is required")
		expect(function()
			buildInMemoryStorage(0)
		end).toThrow("decisionRunCountPerUpdate")
		local storage = buildInMemoryStorage()
		expect(function()
			storage:startAtomicPlayerSaveDataUpdate("8801", function() end, function() end)
		end).toThrow("playerUserId must be a number")
	end)

	for _, decisionRunCount in { 1, 2 } do
		it(
			string.format(
				"runs the real PlayerSaveDataKeeper (decision run %d time(s) per update): load, change, save, final save",
				decisionRunCount
			),
			function()
				local storage, fakeScheduler, fakeClock = buildInMemoryStorage(decisionRunCount)
				local endedSessionReasons = {}
				local keeper = PlayerSaveDataKeeper.new({
					playerSaveDataStorage = storage,
					clock = fakeClock,
					scheduler = fakeScheduler,
					removePlayerFromGameWithMessage = function() end,
					logger = RecordingLogger.new(),
					generateUniqueSessionLockId = function()
						return "development-lock-1"
					end,
					buildStartingPlayerSaveDataForNewPlayer = function(currentUnixSeconds: number)
						return PlayerSaveDataSchema.createStartingPlayerSaveData(
							{ "starter_groove" },
							currentUnixSeconds
						)
					end,
				})
				keeper:subscribeToPlayerSaveDataSessionEnded(function(_, sessionEndReason)
					table.insert(endedSessionReasons, sessionEndReason)
				end)
				keeper:startLoadingPlayerSaveData(PLAYER_ID)
				fakeScheduler:advanceTimeAndRunDueCallbacks(0)
				expect(keeper:isPlayerSaveDataLoaded(PLAYER_ID)).toBeTrue()
				expect(storage:readStoredPlayerSaveDataCopy(PLAYER_ID).gameServerSessionLock.sessionLockId).toBe(
					"development-lock-1"
				)

				keeper:applyChangeToPlayerSaveData(PLAYER_ID, "ProgressChangeSavedAtOnce", "test grant", function(draft)
					draft.starCoinBalance += 80
					return true
				end)
				fakeScheduler:advanceTimeAndRunDueCallbacks(10)
				expect(storage:readStoredPlayerSaveDataCopy(PLAYER_ID).starCoinBalance).toBe(80)
				local inMemoryRevision, lastSavedRevision = keeper:readSaveChangeRevisions(PLAYER_ID)
				expect(lastSavedRevision).toBe(inMemoryRevision)

				keeper:startFinalSaveForLeavingPlayer(PLAYER_ID)
				fakeScheduler:advanceTimeAndRunDueCallbacks(0)
				expect(endedSessionReasons).toEqual({ "FinalSaveSucceeded" })
				expect(storage:readStoredPlayerSaveDataCopy(PLAYER_ID).gameServerSessionLock).toBeNil()
				expect(storage:readStoredPlayerSaveDataCopy(PLAYER_ID).starCoinBalance).toBe(80)
			end
		)
	end
end)
