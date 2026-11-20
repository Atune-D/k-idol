-- Unit: RobloxServerClock and RobloxTaskScheduler with injected time and thread functions (the
-- engine's DateTime, task.delay and task.cancel were exercised in Studio; see the file headers).

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local RobloxServerClock = require("../../src/server/RobloxServerClock")
local RobloxTaskScheduler = require("../../src/server/RobloxTaskScheduler")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

describe("RobloxServerClock", function()
	it("reads milliseconds and the same reading in seconds, freshly on every call", function()
		local currentUnixMilliseconds = 1795137980118
		local clock = RobloxServerClock.new(function()
			return currentUnixMilliseconds
		end)
		expect(clock:getCurrentUnixMilliseconds()).toBe(1795137980118)
		expect(clock:getCurrentUnixSeconds()).toBe(1795137980.118)
		currentUnixMilliseconds += 2500
		expect(clock:getCurrentUnixMilliseconds()).toBe(1795137982618)
		expect(clock:getCurrentUnixSeconds()).toBe(1795137982.618)
	end)

	it("keeps the two readings in agreement for random times", function()
		SeededRandomTrials.runSeededRandomTrials(200, function(randomNumberGenerator)
			local currentUnixMilliseconds = randomNumberGenerator.nextWholeNumberInRange(0, 2 ^ 31) * 1000
				+ randomNumberGenerator.nextWholeNumberInRange(0, 999)
			local clock = RobloxServerClock.new(function()
				return currentUnixMilliseconds
			end)
			expect(math.round(clock:getCurrentUnixSeconds() * 1000)).toBe(clock:getCurrentUnixMilliseconds())
		end)
	end)
end)

-- A fake task library: delayed threads run only when the test runs them.
local function createSchedulerWithFakeThreads()
	local fakeThreads = { started = {}, cancelled = {}, shouldCancelRaise = false }
	local scheduler = RobloxTaskScheduler.new({
		startDelayedThread = function(delaySeconds, threadBody)
			local fakeThread = { delaySeconds = delaySeconds, threadBody = threadBody }
			table.insert(fakeThreads.started, fakeThread)
			return fakeThread
		end,
		cancelThread = function(fakeThread)
			table.insert(fakeThreads.cancelled, fakeThread)
			if fakeThreads.shouldCancelRaise then
				error("cannot cancel thread")
			end
		end,
	})
	return scheduler, fakeThreads
end

describe("RobloxTaskScheduler", function()
	it("starts one delayed thread with the asked delay and runs the callback when it resumes", function()
		local scheduler, fakeThreads = createSchedulerWithFakeThreads()
		local callbackCount = 0
		scheduler:scheduleCallbackAfterSeconds(2.5, function()
			callbackCount += 1
		end)
		expect(#fakeThreads.started).toBe(1)
		expect(fakeThreads.started[1].delaySeconds).toBe(2.5)
		expect(callbackCount).toBe(0)
		fakeThreads.started[1].threadBody()
		expect(callbackCount).toBe(1)
	end)

	it("runs the callback at most once even if its thread were resumed twice", function()
		local scheduler, fakeThreads = createSchedulerWithFakeThreads()
		local callbackCount = 0
		scheduler:scheduleCallbackAfterSeconds(0, function()
			callbackCount += 1
		end)
		fakeThreads.started[1].threadBody()
		fakeThreads.started[1].threadBody()
		expect(callbackCount).toBe(1)
	end)

	it("never runs a cancelled callback, and cancels its thread once", function()
		local scheduler, fakeThreads = createSchedulerWithFakeThreads()
		local callbackCount = 0
		local cancelScheduledCallback = scheduler:scheduleCallbackAfterSeconds(1, function()
			callbackCount += 1
		end)
		cancelScheduledCallback()
		cancelScheduledCallback()
		expect(fakeThreads.cancelled).toEqual({ fakeThreads.started[1] })
		fakeThreads.started[1].threadBody()
		expect(callbackCount).toBe(0)
	end)

	it("keeps a cancelled callback from running even when the engine cannot cancel the thread", function()
		local scheduler, fakeThreads = createSchedulerWithFakeThreads()
		fakeThreads.shouldCancelRaise = true
		local callbackCount = 0
		local cancelScheduledCallback = scheduler:scheduleCallbackAfterSeconds(1, function()
			callbackCount += 1
		end)
		cancelScheduledCallback() -- the raising cancelThread must not escape
		fakeThreads.started[1].threadBody()
		expect(callbackCount).toBe(0)
	end)

	it("does nothing when cancelled after the callback ran or from inside the callback", function()
		local scheduler, fakeThreads = createSchedulerWithFakeThreads()
		local cancelScheduledCallback
		cancelScheduledCallback = scheduler:scheduleCallbackAfterSeconds(0, function()
			cancelScheduledCallback()
		end)
		fakeThreads.started[1].threadBody()
		cancelScheduledCallback()
		expect(fakeThreads.cancelled).toEqual({})
	end)

	it("keeps callbacks independent: cancelling one leaves the others", function()
		local scheduler, fakeThreads = createSchedulerWithFakeThreads()
		local ranCallbackNames = {}
		scheduler:scheduleCallbackAfterSeconds(1, function()
			table.insert(ranCallbackNames, "first")
		end)
		local cancelSecond = scheduler:scheduleCallbackAfterSeconds(1, function()
			table.insert(ranCallbackNames, "second")
		end)
		cancelSecond()
		for _, fakeThread in fakeThreads.started do
			fakeThread.threadBody()
		end
		expect(ranCallbackNames).toEqual({ "first" })
	end)

	it("raises for a delay that is not a finite number >= 0, or a callback that is not a function", function()
		local scheduler, fakeThreads = createSchedulerWithFakeThreads()
		for _, badDelaySeconds in { -1, -0.001, math.huge, 0 / 0, "1", nil } do
			expect(function()
				scheduler:scheduleCallbackAfterSeconds(badDelaySeconds, function() end)
			end).toThrow("delaySeconds must be a finite number >= 0")
		end
		expect(function()
			scheduler:scheduleCallbackAfterSeconds(1, "not a function")
		end).toThrow("callback must be a function")
		expect(#fakeThreads.started).toBe(0)
	end)

	it("runs exactly the callbacks not cancelled before their thread resumed, in random sequences", function()
		SeededRandomTrials.runSeededRandomTrials(200, function(randomNumberGenerator)
			local scheduler, fakeThreads = createSchedulerWithFakeThreads()
			local scheduledEntries = {}
			for _ = 1, randomNumberGenerator.nextWholeNumberInRange(1, 12) do
				local scheduledEntry = { runCount = 0, wasCancelledBeforeRun = false, hasResumed = false }
				scheduledEntry.cancel = scheduler:scheduleCallbackAfterSeconds(
					randomNumberGenerator.nextWholeNumberInRange(0, 10),
					function()
						scheduledEntry.runCount += 1
					end
				)
				scheduledEntry.fakeThread = fakeThreads.started[#fakeThreads.started]
				table.insert(scheduledEntries, scheduledEntry)
			end
			for _ = 1, randomNumberGenerator.nextWholeNumberInRange(0, 30) do
				local scheduledEntry = randomNumberGenerator.pickRandomListElement(scheduledEntries)
				if randomNumberGenerator.nextWholeNumberInRange(1, 2) == 1 then
					if not scheduledEntry.hasResumed then
						scheduledEntry.wasCancelledBeforeRun = true
					end
					scheduledEntry.cancel()
				else
					scheduledEntry.hasResumed = true
					scheduledEntry.fakeThread.threadBody()
				end
			end
			for _, scheduledEntry in scheduledEntries do
				local expectedRunCount = if scheduledEntry.hasResumed and not scheduledEntry.wasCancelledBeforeRun
					then 1
					else 0
				expect(scheduledEntry.runCount).toBe(expectedRunCount)
			end
		end)
	end)
end)
