-- The FanCountLeaderboardStorage contract (FanCountLeaderboardKeeper.luau header) checked the SAME
-- way against tests/Support/FakeFanCountLeaderboardStorage and the in-memory development storage.
-- (The real FanCountLeaderboardKeeper runs on the in-memory storage in ServerGameAssemblyTestHarness.)

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local FakeFanCountLeaderboardStorage = require("../Support/FakeFanCountLeaderboardStorage")
local InMemoryDevelopmentFanCountLeaderboardStorage =
	require("../../src/server/InMemoryDevelopmentFanCountLeaderboardStorage")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local STORAGE_BUILDERS = {
	{
		storageName = "FakeFanCountLeaderboardStorage (tests/Support)",
		build = function()
			local storage = FakeFanCountLeaderboardStorage.new()
			storage:setCompletesWritesImmediately(true)
			return storage, function() end
		end,
	},
	{
		storageName = "InMemoryDevelopmentFanCountLeaderboardStorage",
		build = function()
			local fakeScheduler = FakeScheduler.new(FakeClock.new(1_800_000_000))
			return InMemoryDevelopmentFanCountLeaderboardStorage.new({ scheduler = fakeScheduler }),
				function()
					fakeScheduler:advanceTimeAndRunDueCallbacks(0)
				end
		end,
	},
}

local function writeAndRecordFinishes(storage, playerUserId: number, fanCount: number)
	local recordedFinishes = {}
	storage:startKeepingLargerFanCount(playerUserId, fanCount, function(wasWriteSuccessful)
		table.insert(recordedFinishes, wasWriteSuccessful)
	end)
	return recordedFinishes
end

local function readTopEntries(storage, finishPendingCallbacks, maximumEntryCount: number)
	local recordedReads = {}
	storage:startReadingTopFanCountEntries(maximumEntryCount, function(wasReadSuccessful, topEntries)
		table.insert(recordedReads, { wasReadSuccessful = wasReadSuccessful, topEntries = topEntries })
	end)
	finishPendingCallbacks()
	expect(#recordedReads).toBe(1)
	return recordedReads[1]
end

for _, storageBuilder in STORAGE_BUILDERS do
	describe("FanCountLeaderboardStorage contract: " .. storageBuilder.storageName, function()
		it("keeps the larger value: a smaller write never lowers what is stored", function()
			local storage, finishPendingCallbacks = storageBuilder.build()
			writeAndRecordFinishes(storage, 1, 40)
			writeAndRecordFinishes(storage, 1, 25)
			finishPendingCallbacks()
			expect(storage:readStoredFanCount(1)).toBe(40)
			writeAndRecordFinishes(storage, 1, 41)
			finishPendingCallbacks()
			expect(storage:readStoredFanCount(1)).toBe(41)
		end)

		it("calls the write callback exactly once, with success", function()
			local storage, finishPendingCallbacks = storageBuilder.build()
			local recordedFinishes = writeAndRecordFinishes(storage, 1, 3)
			finishPendingCallbacks()
			finishPendingCallbacks()
			expect(recordedFinishes).toEqual({ true })
		end)

		it("reads the highest entries first, smaller user id first on a tie, at most the asked number", function()
			local storage, finishPendingCallbacks = storageBuilder.build()
			writeAndRecordFinishes(storage, 30, 500)
			writeAndRecordFinishes(storage, 10, 900)
			writeAndRecordFinishes(storage, 20, 500)
			writeAndRecordFinishes(storage, 40, 1)
			finishPendingCallbacks()
			local topRead = readTopEntries(storage, finishPendingCallbacks, 3)
			expect(topRead.wasReadSuccessful).toBeTrue()
			expect(topRead.topEntries).toEqual({
				{ playerUserId = 10, fanCount = 900 },
				{ playerUserId = 20, fanCount = 500 },
				{ playerUserId = 30, fanCount = 500 },
			})
		end)

		it("reads an empty list when nothing was written", function()
			local storage, finishPendingCallbacks = storageBuilder.build()
			expect(readTopEntries(storage, finishPendingCallbacks, 100).topEntries).toEqual({})
		end)
	end)
end

describe("InMemoryDevelopmentFanCountLeaderboardStorage beyond the shared contract", function()
	it("reports a write only after the start call returned, and refuses values an ordered store cannot hold", function()
		local fakeScheduler = FakeScheduler.new(FakeClock.new(1_800_000_000))
		local storage = InMemoryDevelopmentFanCountLeaderboardStorage.new({ scheduler = fakeScheduler })
		local recordedFinishes = writeAndRecordFinishes(storage, 1, 7)
		expect(#recordedFinishes).toBe(0)
		fakeScheduler:advanceTimeAndRunDueCallbacks(0)
		expect(recordedFinishes).toEqual({ true })
		for _, unstorableFanCount in { 7.5, -1, 0 / 0, math.huge } do
			local refusedFinishes = writeAndRecordFinishes(storage, 1, unstorableFanCount)
			fakeScheduler:advanceTimeAndRunDueCallbacks(0)
			expect(refusedFinishes).toEqual({ false })
		end
		expect(storage:readStoredFanCount(1)).toBe(7)
	end)

	it("raises without a scheduler", function()
		expect(function()
			InMemoryDevelopmentFanCountLeaderboardStorage.new({})
		end).toThrow("a scheduler is required")
	end)
end)
