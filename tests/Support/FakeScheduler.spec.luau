local UnitTestFramework = require("./UnitTestFramework")
local FakeClock = require("./FakeClock")
local FakeScheduler = require("./FakeScheduler")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local EXAMPLE_STARTING_UNIX_SECONDS = 1_763_510_400

local function createFakeClockAndScheduler()
	local fakeClock = FakeClock.new(EXAMPLE_STARTING_UNIX_SECONDS)
	return fakeClock, FakeScheduler.new(fakeClock)
end

describe("FakeScheduler", function()
	it("does not run a callback before its delay has fully elapsed", function()
		local fakeClock, fakeScheduler = createFakeClockAndScheduler()
		local callbackRunCount = 0
		fakeScheduler:scheduleCallbackAfterSeconds(10, function()
			callbackRunCount += 1
		end)
		fakeScheduler:advanceTimeAndRunDueCallbacks(9.999)
		expect(callbackRunCount).toBe(0)
		fakeScheduler:advanceTimeAndRunDueCallbacks(0.001)
		expect(callbackRunCount).toBe(1)
		fakeScheduler:advanceTimeAndRunDueCallbacks(100)
		expect(callbackRunCount).toBe(1)
		expect(fakeClock:getCurrentUnixSeconds()).toBe(EXAMPLE_STARTING_UNIX_SECONDS + 110)
	end)

	it("runs due callbacks in due-time order, ties in scheduling order, with the clock at each due time", function()
		local fakeClock, fakeScheduler = createFakeClockAndScheduler()
		local observedRuns = {}
		local function recordRun(callbackLabel: string)
			return function()
				table.insert(
					observedRuns,
					{ callbackLabel, fakeClock:getCurrentUnixSeconds() - EXAMPLE_STARTING_UNIX_SECONDS }
				)
			end
		end
		fakeScheduler:scheduleCallbackAfterSeconds(20, recordRun("results"))
		fakeScheduler:scheduleCallbackAfterSeconds(10, recordRun("styling-first"))
		fakeScheduler:scheduleCallbackAfterSeconds(10, recordRun("styling-second"))
		fakeScheduler:advanceTimeAndRunDueCallbacks(60)
		expect(observedRuns).toEqual({ { "styling-first", 10 }, { "styling-second", 10 }, { "results", 20 } })
		expect(fakeClock:getCurrentUnixSeconds()).toBe(EXAMPLE_STARTING_UNIX_SECONDS + 60)
	end)

	it("runs callbacks scheduled by other callbacks when they fall due in the same advance", function()
		local fakeClock, fakeScheduler = createFakeClockAndScheduler()
		local phaseStartOffsets = {}
		local function startNextPhaseAfterSeconds(phaseDurationSeconds: number)
			fakeScheduler:scheduleCallbackAfterSeconds(phaseDurationSeconds, function()
				table.insert(phaseStartOffsets, fakeClock:getCurrentUnixSeconds() - EXAMPLE_STARTING_UNIX_SECONDS)
				startNextPhaseAfterSeconds(phaseDurationSeconds)
			end)
		end
		startNextPhaseAfterSeconds(10)
		fakeScheduler:advanceTimeAndRunDueCallbacks(35)
		expect(phaseStartOffsets).toEqual({ 10, 20, 30 })
		expect(fakeScheduler:getPendingCallbackCount()).toBe(1)
	end)

	it("does not run a cancelled callback, and cancelling twice is harmless", function()
		local _, fakeScheduler = createFakeClockAndScheduler()
		local callbackRunCount = 0
		local cancelScheduledCallback = fakeScheduler:scheduleCallbackAfterSeconds(5, function()
			callbackRunCount += 1
		end)
		expect(fakeScheduler:getPendingCallbackCount()).toBe(1)
		cancelScheduledCallback()
		cancelScheduledCallback()
		expect(fakeScheduler:getPendingCallbackCount()).toBe(0)
		fakeScheduler:advanceTimeAndRunDueCallbacks(10)
		expect(callbackRunCount).toBe(0)
	end)

	it("runs a zero-delay callback on the next advance, even an advance of zero seconds", function()
		local fakeClock, fakeScheduler = createFakeClockAndScheduler()
		local callbackRunCount = 0
		fakeScheduler:scheduleCallbackAfterSeconds(0, function()
			callbackRunCount += 1
		end)
		expect(callbackRunCount).toBe(0)
		fakeScheduler:advanceTimeAndRunDueCallbacks(0)
		expect(callbackRunCount).toBe(1)
		expect(fakeClock:getCurrentUnixSeconds()).toBe(EXAMPLE_STARTING_UNIX_SECONDS)
	end)

	it("never moves the clock backwards for a callback made overdue by advancing the clock directly", function()
		local fakeClock, fakeScheduler = createFakeClockAndScheduler()
		local observedRunOffset = nil
		fakeScheduler:scheduleCallbackAfterSeconds(5, function()
			observedRunOffset = fakeClock:getCurrentUnixSeconds() - EXAMPLE_STARTING_UNIX_SECONDS
		end)
		fakeClock:advanceBySeconds(30)
		fakeScheduler:advanceTimeAndRunDueCallbacks(0)
		expect(observedRunOffset).toBe(30)
	end)

	it("stops a callback that reschedules itself forever instead of hanging", function()
		local _, fakeScheduler = createFakeClockAndScheduler()
		local function rescheduleForever()
			fakeScheduler:scheduleCallbackAfterSeconds(0, rescheduleForever)
		end
		rescheduleForever()
		expect(function()
			fakeScheduler:advanceTimeAndRunDueCallbacks(1)
		end).toThrow("reschedules itself forever")
	end)

	it("rejects negative or non-number delays", function()
		local _, fakeScheduler = createFakeClockAndScheduler()
		expect(function()
			fakeScheduler:scheduleCallbackAfterSeconds(-1, function() end)
		end).toThrow("delaySeconds must be a finite number >= 0")
		expect(function()
			fakeScheduler:scheduleCallbackAfterSeconds("5" :: any, function() end)
		end).toThrow("delaySeconds must be a finite number >= 0")
		expect(function()
			fakeScheduler:advanceTimeAndRunDueCallbacks(-1)
		end).toThrow("elapsedSeconds must be a finite number >= 0")
	end)
end)
