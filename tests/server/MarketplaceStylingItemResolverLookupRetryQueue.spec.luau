-- The contract of MarketplaceItemLookupRetryQueue, tested directly (not only through the
-- resolver): what counts as success, retries, the in-flight limit, the attempt timeout and
-- answers that arrive twice or too late.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local MarketplaceItemLookupRetryQueue = require("../../src/server/MarketplaceItemLookupRetryQueue")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local TIMEOUT_SECONDS = MarketplaceItemLookupRetryQueue.LOOKUP_ATTEMPT_TIMEOUT_SECONDS

local function createQueueWithFakeScheduler()
	local fakeScheduler = FakeScheduler.new(FakeClock.new(1_763_510_400))
	return MarketplaceItemLookupRetryQueue.new(fakeScheduler), fakeScheduler
end

-- Runs one lookup whose attempts are handled by `handleAttempt(attemptNumber, onAttemptFinished)`
-- and records every settlement.
local function runRecordedLookup(lookupRetryQueue, handleAttempt)
	local recording = { startedAttemptCount = 0, settlements = {} }
	lookupRetryQueue:runLookupWithRetries(function(onAttemptFinished)
		recording.startedAttemptCount += 1
		handleAttempt(recording.startedAttemptCount, onAttemptFinished)
	end, function(wasLookupSuccessful, lookupAnswer, lastLookupErrorMessage, attemptCount)
		table.insert(recording.settlements, {
			wasLookupSuccessful = wasLookupSuccessful,
			lookupAnswer = lookupAnswer,
			lastLookupErrorMessage = lastLookupErrorMessage,
			attemptCount = attemptCount,
		})
	end)
	return recording
end

describe("MarketplaceStylingItemResolver lookup retry queue", function()
	it("raises when created without a scheduler", function()
		expect(function()
			MarketplaceItemLookupRetryQueue.new(nil)
		end).toThrow("missing scheduler")
	end)

	it("counts only `true` as success: nil, a string and a number are failed attempts", function()
		for _, nonTrueSuccessValue in { "yes", 1, false } :: { any } do
			local lookupRetryQueue, fakeScheduler = createQueueWithFakeScheduler()
			local recording = runRecordedLookup(lookupRetryQueue, function(_, onAttemptFinished)
				onAttemptFinished(nonTrueSuccessValue, "answer", "error")
			end)
			fakeScheduler:advanceTimeAndRunDueCallbacks(60)
			expect(recording.startedAttemptCount).toBe(4)
			expect(recording.settlements).toEqual({
				{ wasLookupSuccessful = false, lastLookupErrorMessage = "error", attemptCount = 4 },
			})
		end
		local lookupRetryQueue, fakeScheduler = createQueueWithFakeScheduler()
		local recording = runRecordedLookup(lookupRetryQueue, function(_, onAttemptFinished)
			onAttemptFinished(nil, "answer", nil)
		end)
		fakeScheduler:advanceTimeAndRunDueCallbacks(60)
		expect(recording.settlements[1].wasLookupSuccessful).toBe(false)
	end)

	it("settles once with the answer of the first successful attempt", function()
		local lookupRetryQueue, fakeScheduler = createQueueWithFakeScheduler()
		local recording = runRecordedLookup(lookupRetryQueue, function(attemptNumber, onAttemptFinished)
			onAttemptFinished(attemptNumber == 2, "answer " .. tostring(attemptNumber), "error")
		end)
		fakeScheduler:advanceTimeAndRunDueCallbacks(60)
		expect(recording.settlements).toEqual({
			{ wasLookupSuccessful = true, lookupAnswer = "answer 2", attemptCount = 2 },
		})
	end)

	it("does not count a waiting retry as in flight", function()
		local lookupRetryQueue, fakeScheduler = createQueueWithFakeScheduler()
		local recording = runRecordedLookup(lookupRetryQueue, function(_, onAttemptFinished)
			onAttemptFinished(false, nil, "error")
		end)
		expect(recording.startedAttemptCount).toBe(1)
		expect(lookupRetryQueue:countLookupAttemptsInFlight()).toBe(0)
		-- The waiting retry leaves room for a full set of new attempts.
		local heldAttemptCallbacks = {}
		for _ = 1, MarketplaceItemLookupRetryQueue.MAXIMUM_LOOKUP_ATTEMPTS_IN_FLIGHT do
			runRecordedLookup(lookupRetryQueue, function(_, onAttemptFinished)
				table.insert(heldAttemptCallbacks, onAttemptFinished)
			end)
		end
		expect(#heldAttemptCallbacks).toBe(MarketplaceItemLookupRetryQueue.MAXIMUM_LOOKUP_ATTEMPTS_IN_FLIGHT)
		expect(lookupRetryQueue:countLookupAttemptsInFlight()).toBe(10)
		fakeScheduler:advanceTimeAndRunDueCallbacks(2)
		expect(recording.startedAttemptCount).toBe(1) -- the retry is due but must wait for a slot
		heldAttemptCallbacks[1](true, "answer", nil)
		expect(recording.startedAttemptCount).toBe(2)
	end)

	it("keeps an attempt that reported success and then raised while starting", function()
		local lookupRetryQueue = createQueueWithFakeScheduler()
		local recording = runRecordedLookup(lookupRetryQueue, function(_, onAttemptFinished)
			onAttemptFinished(true, "answer", nil)
			error("raised after answering")
		end)
		expect(recording.settlements).toEqual({
			{ wasLookupSuccessful = true, lookupAnswer = "answer", attemptCount = 1 },
		})
		expect(lookupRetryQueue:countLookupAttemptsInFlight()).toBe(0)
	end)

	it("settles thousands of lookups that answer inside their start call without a deep call stack", function()
		local lookupRetryQueue = createQueueWithFakeScheduler()
		local function measureCallStackDepth(): number
			local callStackDepth = 0
			while debug.info(callStackDepth + 1, "f") ~= nil do
				callStackDepth += 1
			end
			return callStackDepth
		end
		-- Hold ten attempts so that the remaining ones queue up, then free one slot: every queued
		-- attempt answers inside its start call, and each must start at the same stack depth.
		local heldAttemptCallbacks = {}
		for _ = 1, MarketplaceItemLookupRetryQueue.MAXIMUM_LOOKUP_ATTEMPTS_IN_FLIGHT do
			lookupRetryQueue:runLookupWithRetries(function(onAttemptFinished)
				table.insert(heldAttemptCallbacks, onAttemptFinished)
			end, function() end)
		end
		local settledLookupCount = 0
		local smallestStartDepth, largestStartDepth = math.huge, 0
		for _ = 1, 3000 do
			lookupRetryQueue:runLookupWithRetries(function(onAttemptFinished)
				local startDepth = measureCallStackDepth()
				smallestStartDepth = math.min(smallestStartDepth, startDepth)
				largestStartDepth = math.max(largestStartDepth, startDepth)
				onAttemptFinished(true, "answer", nil)
			end, function()
				settledLookupCount += 1
			end)
		end
		expect(settledLookupCount).toBe(0)
		for _, heldAttemptCallback in heldAttemptCallbacks do
			heldAttemptCallback(true, "answer", nil)
		end
		expect(settledLookupCount).toBe(3000)
		expect(largestStartDepth - smallestStartDepth).toBe(0)
		expect(lookupRetryQueue:countLookupAttemptsInFlight()).toBe(0)
	end)
end)

describe("MarketplaceStylingItemResolver lookup retry queue timeouts", function()
	it("counts an attempt that never answers as failed after the time limit, then retries", function()
		local lookupRetryQueue, fakeScheduler = createQueueWithFakeScheduler()
		local recording = runRecordedLookup(lookupRetryQueue, function() end)
		fakeScheduler:advanceTimeAndRunDueCallbacks(TIMEOUT_SECONDS - 0.001)
		expect(lookupRetryQueue:countLookupAttemptsInFlight()).toBe(1)
		expect(recording.startedAttemptCount).toBe(1)
		fakeScheduler:advanceTimeAndRunDueCallbacks(0.001)
		expect(lookupRetryQueue:countLookupAttemptsInFlight()).toBe(0)
		fakeScheduler:advanceTimeAndRunDueCallbacks(2)
		expect(recording.startedAttemptCount).toBe(2)
		fakeScheduler:advanceTimeAndRunDueCallbacks(3600)
		expect(recording.startedAttemptCount).toBe(4)
		expect(recording.settlements).toEqual({
			{
				wasLookupSuccessful = false,
				lastLookupErrorMessage = "no answer within 15 seconds",
				attemptCount = 4,
			},
		})
		expect(fakeScheduler:getPendingCallbackCount()).toBe(0)
	end)

	it("ignores a late answer after the timeout and frees the in-flight slot only once", function()
		local lookupRetryQueue, fakeScheduler = createQueueWithFakeScheduler()
		local firstAttemptCallbacks = {}
		local recording = runRecordedLookup(lookupRetryQueue, function(attemptNumber, onAttemptFinished)
			if attemptNumber == 1 then
				table.insert(firstAttemptCallbacks, onAttemptFinished)
			end
		end)
		fakeScheduler:advanceTimeAndRunDueCallbacks(TIMEOUT_SECONDS + 2) -- timed out; retry now in flight
		expect(recording.startedAttemptCount).toBe(2)
		expect(lookupRetryQueue:countLookupAttemptsInFlight()).toBe(1)
		firstAttemptCallbacks[1](true, "late answer", nil)
		expect(recording.settlements).toEqual({})
		expect(lookupRetryQueue:countLookupAttemptsInFlight()).toBe(1)
	end)

	it("uses an answer that arrives just before the limit, and its timer never fires", function()
		local lookupRetryQueue, fakeScheduler = createQueueWithFakeScheduler()
		local heldAttemptCallbacks = {}
		local recording = runRecordedLookup(lookupRetryQueue, function(_, onAttemptFinished)
			table.insert(heldAttemptCallbacks, onAttemptFinished)
		end)
		expect(fakeScheduler:getPendingCallbackCount()).toBe(1)
		fakeScheduler:advanceTimeAndRunDueCallbacks(TIMEOUT_SECONDS - 0.001)
		heldAttemptCallbacks[1](true, "just in time", nil)
		expect(fakeScheduler:getPendingCallbackCount()).toBe(0)
		fakeScheduler:advanceTimeAndRunDueCallbacks(3600)
		expect(recording.settlements).toEqual({
			{ wasLookupSuccessful = true, lookupAnswer = "just in time", attemptCount = 1 },
		})
		expect(lookupRetryQueue:countLookupAttemptsInFlight()).toBe(0)
	end)

	it("starts the timer only when the attempt gets an in-flight slot", function()
		local lookupRetryQueue, fakeScheduler = createQueueWithFakeScheduler()
		local heldAttemptCallbacks = {}
		for _ = 1, MarketplaceItemLookupRetryQueue.MAXIMUM_LOOKUP_ATTEMPTS_IN_FLIGHT do
			runRecordedLookup(lookupRetryQueue, function(_, onAttemptFinished)
				table.insert(heldAttemptCallbacks, onAttemptFinished)
			end)
		end
		local queuedRecording = runRecordedLookup(lookupRetryQueue, function() end)
		fakeScheduler:advanceTimeAndRunDueCallbacks(10)
		heldAttemptCallbacks[1](true, "answer", nil) -- the queued attempt starts now, at 10 s
		expect(queuedRecording.startedAttemptCount).toBe(1)
		-- At 15 s the nine other held attempts time out; their retries start at 17 s and hold again.
		-- The queued attempt, started at 10 s, must still be in flight at 24.999 s.
		fakeScheduler:advanceTimeAndRunDueCallbacks(TIMEOUT_SECONDS - 0.001)
		expect(lookupRetryQueue:countLookupAttemptsInFlight()).toBe(10)
		fakeScheduler:advanceTimeAndRunDueCallbacks(0.001)
		expect(lookupRetryQueue:countLookupAttemptsInFlight()).toBe(9) -- the queued attempt timed out at 25 s
		fakeScheduler:advanceTimeAndRunDueCallbacks(2)
		expect(queuedRecording.startedAttemptCount).toBe(2)
	end)
end)
