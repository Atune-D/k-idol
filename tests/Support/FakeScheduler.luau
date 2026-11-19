-- A "do X after N seconds" scheduler driven by a FakeClock. Nothing runs until the test calls
-- `advanceTimeAndRunDueCallbacks`; no test ever really waits.
--
-- Game modules that need delayed work receive a scheduler object with
-- `scheduleCallbackAfterSeconds(delaySeconds, callback) -> cancelScheduledCallback`.
--
-- Ordering guarantees while advancing:
--   * callbacks run in order of their due time; equal due times run in scheduling order;
--   * the clock reads exactly a callback's due time while that callback runs;
--   * a callback scheduled by another callback runs in the same advance if it falls due in it;
--   * a callback that became overdue because the test moved the FakeClock directly runs at the
--     current time (the clock never moves backwards).
-- When a test uses a FakeScheduler, it should move time through the scheduler, not the clock.

local FakeScheduler = {}
FakeScheduler.__index = FakeScheduler

-- Protects against a callback that keeps rescheduling itself with zero delay.
local MAXIMUM_CALLBACKS_RUN_PER_ADVANCE = 100000

type ScheduledCallback = {
	dueAtUnixMilliseconds: number,
	schedulingSequenceNumber: number,
	callback: () -> (),
}

type FakeClockLike = {
	getCurrentUnixMilliseconds: (any) -> number,
	moveForwardToUnixMilliseconds: (any, number) -> (),
}

export type FakeScheduler = typeof(setmetatable(
	{} :: {
		fakeClock: FakeClockLike,
		pendingScheduledCallbacks: { ScheduledCallback },
		nextSchedulingSequenceNumber: number,
	},
	FakeScheduler
))

-- Error level 3 points at the code that called the scheduler method.
local function assertIsFiniteNonNegativeSeconds(candidateSeconds: any, argumentName: string)
	local isFiniteNonNegativeNumber = type(candidateSeconds) == "number"
		and candidateSeconds >= 0
		and candidateSeconds ~= math.huge
	if not isFiniteNonNegativeNumber then
		error(
			string.format(
				"FakeScheduler: %s must be a finite number >= 0, got %s",
				argumentName,
				tostring(candidateSeconds)
			),
			3
		)
	end
end

function FakeScheduler.new(fakeClock: FakeClockLike): FakeScheduler
	local self = setmetatable({
		fakeClock = fakeClock,
		pendingScheduledCallbacks = {},
		nextSchedulingSequenceNumber = 1,
	}, FakeScheduler)
	return self
end

-- Returns a function that cancels the callback if it has not run yet. Cancelling twice, or
-- after the callback ran, does nothing.
function FakeScheduler.scheduleCallbackAfterSeconds(
	self: FakeScheduler,
	delaySeconds: number,
	callback: () -> ()
): () -> ()
	assertIsFiniteNonNegativeSeconds(delaySeconds, "delaySeconds")
	if type(callback) ~= "function" then
		error("FakeScheduler: callback must be a function", 2)
	end

	local scheduledCallback: ScheduledCallback = {
		dueAtUnixMilliseconds = self.fakeClock:getCurrentUnixMilliseconds() + math.round(delaySeconds * 1000),
		schedulingSequenceNumber = self.nextSchedulingSequenceNumber,
		callback = callback,
	}
	self.nextSchedulingSequenceNumber += 1
	table.insert(self.pendingScheduledCallbacks, scheduledCallback)

	return function()
		local pendingIndex = table.find(self.pendingScheduledCallbacks, scheduledCallback)
		if pendingIndex then
			table.remove(self.pendingScheduledCallbacks, pendingIndex)
		end
	end
end

function FakeScheduler.getPendingCallbackCount(self: FakeScheduler): number
	return #self.pendingScheduledCallbacks
end

local function findIndexOfEarliestPendingCallback(pendingScheduledCallbacks: { ScheduledCallback }): number?
	local earliestIndex: number? = nil
	for candidateIndex, candidate in pendingScheduledCallbacks do
		local earliest = if earliestIndex then pendingScheduledCallbacks[earliestIndex] else nil
		local isEarlier = earliest == nil
			or candidate.dueAtUnixMilliseconds < earliest.dueAtUnixMilliseconds
			or (
				candidate.dueAtUnixMilliseconds == earliest.dueAtUnixMilliseconds
				and candidate.schedulingSequenceNumber < earliest.schedulingSequenceNumber
			)
		if isEarlier then
			earliestIndex = candidateIndex
		end
	end
	return earliestIndex
end

function FakeScheduler.advanceTimeAndRunDueCallbacks(self: FakeScheduler, elapsedSeconds: number)
	assertIsFiniteNonNegativeSeconds(elapsedSeconds, "elapsedSeconds")
	local targetUnixMilliseconds = self.fakeClock:getCurrentUnixMilliseconds() + math.round(elapsedSeconds * 1000)
	local callbacksRunCount = 0

	while true do
		local earliestIndex = findIndexOfEarliestPendingCallback(self.pendingScheduledCallbacks)
		if earliestIndex == nil then
			break
		end
		local earliestCallback = self.pendingScheduledCallbacks[earliestIndex]
		if earliestCallback.dueAtUnixMilliseconds > targetUnixMilliseconds then
			break
		end

		callbacksRunCount += 1
		if callbacksRunCount > MAXIMUM_CALLBACKS_RUN_PER_ADVANCE then
			error("FakeScheduler: too many callbacks in one advance; a callback probably reschedules itself forever", 2)
		end

		table.remove(self.pendingScheduledCallbacks, earliestIndex)
		local callbackRunsAtUnixMilliseconds =
			math.max(earliestCallback.dueAtUnixMilliseconds, self.fakeClock:getCurrentUnixMilliseconds())
		self.fakeClock:moveForwardToUnixMilliseconds(callbackRunsAtUnixMilliseconds)
		earliestCallback.callback()
	end

	self.fakeClock:moveForwardToUnixMilliseconds(targetUnixMilliseconds)
end

return FakeScheduler
