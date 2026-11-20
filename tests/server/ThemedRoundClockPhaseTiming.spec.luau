-- ThemedRoundClock phases, timing, round ids, subscriptions and stopping (development spec
-- §2.1, §6.2 "Unit: round clock", §6.3 gate 1D). Durations are written here as the spec's
-- literal numbers on purpose, so a wrong shared constant also fails these tests.

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local ThemedRoundClock = require("../../src/server/ThemedRoundClock")
local ThemedRoundClockTestHarness = require("./ThemedRoundClockTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local START_UNIX_MILLISECONDS = ThemedRoundClockTestHarness.EXAMPLE_STARTING_UNIX_MILLISECONDS
local WHOLE_ROUND_MILLISECONDS = 280_000

-- §2.1: each phase's start within a round and its duration, in seconds.
local SPEC_PHASE_PLAN = {
	{ roundPhase = "ThemeReveal", startOffsetSeconds = 0, durationSeconds = 10 },
	{ roundPhase = "Styling", startOffsetSeconds = 10, durationSeconds = 180 },
	{ roundPhase = "Showcase", startOffsetSeconds = 190, durationSeconds = 60 },
	{ roundPhase = "Results", startOffsetSeconds = 250, durationSeconds = 20 },
	{ roundPhase = "Intermission", startOffsetSeconds = 270, durationSeconds = 10 },
}

-- The independent oracle: which round and phase a clock started at START_UNIX_MILLISECONDS must
-- be in at `currentUnixMilliseconds`, and when that phase ends.
local function computeExpectedRoundPositionAt(currentUnixMilliseconds: number)
	local elapsedMilliseconds = currentUnixMilliseconds - START_UNIX_MILLISECONDS
	local completedRoundCount = elapsedMilliseconds // WHOLE_ROUND_MILLISECONDS
	local millisecondsIntoRound = elapsedMilliseconds % WHOLE_ROUND_MILLISECONDS
	for _, phasePlan in SPEC_PHASE_PLAN do
		local phaseEndOffsetMilliseconds = (phasePlan.startOffsetSeconds + phasePlan.durationSeconds) * 1000
		if millisecondsIntoRound < phaseEndOffsetMilliseconds then
			return {
				roundNumber = completedRoundCount + 1,
				roundPhase = phasePlan.roundPhase,
				phaseEndsAtUnixMilliseconds = START_UNIX_MILLISECONDS
					+ completedRoundCount * WHOLE_ROUND_MILLISECONDS
					+ phaseEndOffsetMilliseconds,
			}
		end
	end
	error("unreachable: the phase plan covers the whole round")
end

local function expectStateToMatchOracle(harness)
	local currentUnixMilliseconds = harness.fakeClock:getCurrentUnixMilliseconds()
	local expectedRoundPosition = computeExpectedRoundPositionAt(currentUnixMilliseconds)
	local currentRoundState = harness.themedRoundClock:readCurrentRoundState()
	expect({
		atUnixMilliseconds = currentUnixMilliseconds,
		roundId = currentRoundState.roundId,
		roundPhase = currentRoundState.roundPhase,
		phaseEndsAtUnixMilliseconds = currentRoundState.phaseEndsAtUnixMilliseconds,
	}).toEqual({
		atUnixMilliseconds = currentUnixMilliseconds,
		roundId = "round-" .. tostring(expectedRoundPosition.roundNumber),
		roundPhase = expectedRoundPosition.roundPhase,
		phaseEndsAtUnixMilliseconds = expectedRoundPosition.phaseEndsAtUnixMilliseconds,
	})
end

local function millisecondsUntilCurrentPhaseEnds(harness): number
	return harness.themedRoundClock:readCurrentRoundState().phaseEndsAtUnixMilliseconds
		- harness.fakeClock:getCurrentUnixMilliseconds()
end

describe("ThemedRoundClock phase order and durations", function()
	it("does nothing until started", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		expect(harness.themedRoundClock:readCurrentRoundState()).toBeNil()
		expect(harness.themedRoundClock:isRoundCycleRunning()).toBeFalse()
		harness.advanceSeconds(1000)
		expect(#harness.observedPhaseChanges).toBe(0)
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
		expect(#harness.generatedRoundIds).toBe(0)
	end)

	it("starts round 1 at once with a ThemeReveal ending 10 seconds later", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:startRoundCycle()
		expect(harness.themedRoundClock:isRoundCycleRunning()).toBeTrue()
		expect(#harness.observedPhaseChanges).toBe(1)
		local firstRoundState = harness.observedPhaseChanges[1].roundState
		expect(firstRoundState.roundPhase).toBe("ThemeReveal")
		expect(firstRoundState.roundId).toBe("round-1")
		expect(firstRoundState.phaseEndsAtUnixMilliseconds).toBe(START_UNIX_MILLISECONDS + 10_000)
		expect(harness.observedPhaseChanges[1].announcedAtUnixMilliseconds).toBe(START_UNIX_MILLISECONDS)
		expect(harness.themedRoundClock:readCurrentRoundState()).toBe(firstRoundState)
	end)

	it("announces every phase in the §2.1 order, each exactly at the previous end, for three rounds", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:startRoundCycle()
		harness.advanceSeconds(3 * 280)

		local expectedPhaseChanges = {}
		for completedRoundCount = 0, 2 do
			local roundStartUnixMilliseconds = START_UNIX_MILLISECONDS + completedRoundCount * WHOLE_ROUND_MILLISECONDS
			for _, phasePlan in SPEC_PHASE_PLAN do
				local phaseStartUnixMilliseconds = roundStartUnixMilliseconds + phasePlan.startOffsetSeconds * 1000
				table.insert(expectedPhaseChanges, {
					roundPhase = phasePlan.roundPhase,
					announcedAtUnixMilliseconds = phaseStartUnixMilliseconds,
					phaseEndsAtUnixMilliseconds = phaseStartUnixMilliseconds + phasePlan.durationSeconds * 1000,
				})
			end
		end
		table.insert(expectedPhaseChanges, {
			roundPhase = "ThemeReveal",
			announcedAtUnixMilliseconds = START_UNIX_MILLISECONDS + 3 * WHOLE_ROUND_MILLISECONDS,
			phaseEndsAtUnixMilliseconds = START_UNIX_MILLISECONDS + 3 * WHOLE_ROUND_MILLISECONDS + 10_000,
		})

		local actualPhaseChanges = {}
		for _, observedPhaseChange in harness.observedPhaseChanges do
			table.insert(actualPhaseChanges, {
				roundPhase = observedPhaseChange.roundState.roundPhase,
				announcedAtUnixMilliseconds = observedPhaseChange.announcedAtUnixMilliseconds,
				phaseEndsAtUnixMilliseconds = observedPhaseChange.roundState.phaseEndsAtUnixMilliseconds,
			})
		end
		expect(actualPhaseChanges).toEqual(expectedPhaseChanges)
	end)

	it("changes phase exactly at the planned end and not one millisecond earlier", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:startRoundCycle()
		for phaseChangeNumber = 1, 6 do
			local phaseBeforeChange = harness.themedRoundClock:readCurrentRoundState().roundPhase
			harness.advanceSeconds((millisecondsUntilCurrentPhaseEnds(harness) - 1) / 1000)
			expect(harness.themedRoundClock:readCurrentRoundState().roundPhase).toBe(phaseBeforeChange)
			expect(#harness.observedPhaseChanges).toBe(phaseChangeNumber)
			harness.advanceSeconds(0.001)
			expect(#harness.observedPhaseChanges).toBe(phaseChangeNumber + 1)
			expect(harness.themedRoundClock:readCurrentRoundState().roundPhase ~= phaseBeforeChange).toBeTrue()
		end
	end)

	it("reports the right phase and phaseEndsAtUnixMilliseconds at random moments of every phase", function()
		SeededRandomTrials.runSeededRandomTrials(20, function(seededRandomNumberGenerator)
			local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
			harness.themedRoundClock:startRoundCycle()
			expectStateToMatchOracle(harness)
			for _ = 1, 60 do
				harness.advanceSeconds(seededRandomNumberGenerator.nextWholeNumberInRange(1, 25_000) / 1000)
				expectStateToMatchOracle(harness)
			end
		end)
	end)
end)

describe("ThemedRoundClock round ids", function()
	it("creates a new roundId at each ThemeReveal and keeps it through all five phases", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:startRoundCycle()
		harness.advanceSeconds(5 * 280 - 1)
		expect(harness.generatedRoundIds).toEqual({ "round-1", "round-2", "round-3", "round-4", "round-5" })
		expect(#harness.observedPhaseChanges).toBe(25)
		for phaseChangeIndex, observedPhaseChange in harness.observedPhaseChanges do
			local expectedRoundNumber = (phaseChangeIndex - 1) // 5 + 1
			expect(observedPhaseChange.roundState.roundId).toBe("round-" .. tostring(expectedRoundNumber))
		end
	end)

	it("keeps the theme and the very same bonus rule through all five phases of a round", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:startRoundCycle()
		harness.advanceSeconds(4 * 280 - 1)
		for phaseChangeIndex, observedPhaseChange in harness.observedPhaseChanges do
			local roundStartState =
				harness.observedPhaseChanges[phaseChangeIndex - (phaseChangeIndex - 1) % 5].roundState
			expect(observedPhaseChange.roundState.themeId).toBe(roundStartState.themeId)
			expect(observedPhaseChange.roundState.roundBonusRule).toBe(roundStartState.roundBonusRule)
		end
	end)

	it("hands out a deeply frozen state that a listener cannot change", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:startRoundCycle()
		local roundState = harness.themedRoundClock:readCurrentRoundState()
		expect(table.isfrozen(roundState)).toBeTrue()
		expect(table.isfrozen(roundState.roundBonusRule)).toBeTrue()
		expect(function()
			(roundState :: any).roundPhase = "Results"
		end).toThrow()
	end)
end)

describe("ThemedRoundClock without participants (gate 1D)", function()
	it("cycles for 30 simulated minutes in 1-second steps with no warning and no drift", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:startRoundCycle()
		for _ = 1, 30 * 60 do
			harness.advanceSeconds(1)
			expectStateToMatchOracle(harness)
			expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(1)
		end
		-- Round starts at 0, 280, …, 1680 s: 7 rounds; phase starts up to 1800 s: 6 × 5 + 2.
		expect(#harness.generatedRoundIds).toBe(7)
		expect(#harness.observedPhaseChanges).toBe(32)
		expect(harness.loggedWarnings).toEqual({})
	end)

	it("is still exactly on the 280-second grid after 24 simulated hours", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:startRoundCycle()
		harness.advanceSeconds(24 * 60 * 60)
		expectStateToMatchOracle(harness)
		expect(#harness.generatedRoundIds).toBe(24 * 60 * 60 // 280 + 1)
		expect(harness.loggedWarnings).toEqual({})
	end)

	it("plans from the previous planned end, so late-running callbacks never accumulate drift", function()
		SeededRandomTrials.runSeededRandomTrials(10, function(seededRandomNumberGenerator)
			local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
			harness.themedRoundClock:startRoundCycle()
			for _ = 1, 3 * 5 do
				local plannedPhaseEndUnixMilliseconds =
					harness.themedRoundClock:readCurrentRoundState().phaseEndsAtUnixMilliseconds
				local latenessMilliseconds = seededRandomNumberGenerator.nextWholeNumberInRange(1, 900)
				harness.advanceSeconds((millisecondsUntilCurrentPhaseEnds(harness) - 1) / 1000)
				-- Time passes without the scheduler running anything: the callback runs late.
				harness.fakeClock:advanceBySeconds((1 + latenessMilliseconds) / 1000)
				harness.advanceSeconds(0)
				local lastPhaseChange = harness.observedPhaseChanges[#harness.observedPhaseChanges]
				expect(lastPhaseChange.announcedAtUnixMilliseconds).toBe(
					plannedPhaseEndUnixMilliseconds + latenessMilliseconds
				)
				local expectedRoundPosition = computeExpectedRoundPositionAt(plannedPhaseEndUnixMilliseconds)
				expect(lastPhaseChange.roundState.phaseEndsAtUnixMilliseconds).toBe(
					expectedRoundPosition.phaseEndsAtUnixMilliseconds
				)
			end
			expect(harness.loggedWarnings).toEqual({})
		end)
	end)

	it("after a stall longer than a whole phase, re-plans that phase from now, warns, and skips nothing", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:startRoundCycle()
		harness.advanceSeconds(9.999)
		harness.fakeClock:advanceBySeconds(200) -- Styling (180 s) would already be over
		harness.advanceSeconds(0)
		local stalledUntilUnixMilliseconds = harness.fakeClock:getCurrentUnixMilliseconds()
		expect(#harness.observedPhaseChanges).toBe(2)
		local stylingState = harness.themedRoundClock:readCurrentRoundState()
		expect(stylingState.roundPhase).toBe("Styling")
		expect(stylingState.phaseEndsAtUnixMilliseconds).toBe(stalledUntilUnixMilliseconds + 180_000)
		expect(#harness.loggedWarnings).toBe(1)
		expect(string.find(harness.loggedWarnings[1], "late", 1, true) ~= nil).toBeTrue()
		harness.advanceSeconds(180)
		expect(harness.themedRoundClock:readCurrentRoundState().roundPhase).toBe("Showcase")
		expect(harness.themedRoundClock:readCurrentRoundState().phaseEndsAtUnixMilliseconds).toBe(
			stalledUntilUnixMilliseconds + 240_000
		)
	end)
end)

describe("ThemedRoundClock phase-change listeners", function()
	it("calls listeners synchronously, in subscription order, with the new state already current", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		local listenerCallRecords = {}
		for _, listenerName in { "first", "second", "third" } do
			harness.themedRoundClock:subscribeToRoundPhaseChanged(function(roundState)
				table.insert(listenerCallRecords, {
					listenerName = listenerName,
					roundPhase = roundState.roundPhase,
					isAlreadyCurrent = harness.themedRoundClock:readCurrentRoundState() == roundState,
				})
			end)
		end
		harness.themedRoundClock:startRoundCycle()
		harness.advanceSeconds(10)
		expect(listenerCallRecords).toEqual({
			{ listenerName = "first", roundPhase = "ThemeReveal", isAlreadyCurrent = true },
			{ listenerName = "second", roundPhase = "ThemeReveal", isAlreadyCurrent = true },
			{ listenerName = "third", roundPhase = "ThemeReveal", isAlreadyCurrent = true },
			{ listenerName = "first", roundPhase = "Styling", isAlreadyCurrent = true },
			{ listenerName = "second", roundPhase = "Styling", isAlreadyCurrent = true },
			{ listenerName = "third", roundPhase = "Styling", isAlreadyCurrent = true },
		})
	end)

	it("announces Showcase and Results exactly at the planned end of the phase before", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		local announcementTimeByRoundPhase = {}
		harness.themedRoundClock:subscribeToRoundPhaseChanged(function(roundState)
			announcementTimeByRoundPhase[roundState.roundPhase] = harness.fakeClock:getCurrentUnixMilliseconds()
		end)
		harness.themedRoundClock:startRoundCycle()
		harness.advanceSeconds(279)
		expect(announcementTimeByRoundPhase.Showcase).toBe(START_UNIX_MILLISECONDS + 190_000)
		expect(announcementTimeByRoundPhase.Results).toBe(START_UNIX_MILLISECONDS + 250_000)
	end)

	it("logs a raising listener and keeps the cycle and the other listeners going", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:subscribeToRoundPhaseChanged(function()
			error("listener exploded on purpose")
		end)
		local laterListenerPhases = {}
		harness.themedRoundClock:subscribeToRoundPhaseChanged(function(roundState)
			table.insert(laterListenerPhases, roundState.roundPhase)
		end)
		harness.themedRoundClock:startRoundCycle()
		harness.advanceSeconds(2 * 280)
		expect(#laterListenerPhases).toBe(11)
		expect(#harness.loggedWarnings).toBe(11)
		expect(string.find(harness.loggedWarnings[1], "listener exploded on purpose", 1, true) ~= nil).toBeTrue()
		expect(harness.themedRoundClock:isRoundCycleRunning()).toBeTrue()
		expectStateToMatchOracle(harness)
	end)

	it("stops calling a listener once it has unsubscribed", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		local unsubscribedListenerCallCount = 0
		local unsubscribe = harness.themedRoundClock:subscribeToRoundPhaseChanged(function()
			unsubscribedListenerCallCount += 1
		end)
		harness.themedRoundClock:startRoundCycle()
		unsubscribe()
		harness.advanceSeconds(280)
		expect(unsubscribedListenerCallCount).toBe(1)
		expect(#harness.observedPhaseChanges).toBe(6)
	end)
end)

describe("ThemedRoundClock starting and stopping", function()
	it("stops for good: no pending callback, no state, no further phase or round", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:startRoundCycle()
		harness.advanceSeconds(100)
		harness.themedRoundClock:stopRoundCycle()
		expect(harness.themedRoundClock:isRoundCycleRunning()).toBeFalse()
		expect(harness.themedRoundClock:readCurrentRoundState()).toBeNil()
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
		harness.advanceSeconds(3600)
		expect(#harness.observedPhaseChanges).toBe(2)
		expect(#harness.generatedRoundIds).toBe(1)
	end)

	it("ignores a phase change callback that escaped cancellation after a stop", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		local uncancellableScheduler = {}
		function uncancellableScheduler.scheduleCallbackAfterSeconds(_, delaySeconds, callback)
			harness.fakeScheduler:scheduleCallbackAfterSeconds(delaySeconds, callback)
			return function() end -- cancelling does nothing
		end
		local stoppedClock = ThemedRoundClock.new({
			themeCatalogThemes = ThemedRoundClockTestHarness.createFixtureThemeCatalogThemes(6),
			clock = harness.fakeClock,
			scheduler = uncancellableScheduler,
			randomNumberGenerator = SeededRandomTrials.createSeededRandomNumberGenerator(1),
			generateUniqueRoundId = function()
				return "only-round"
			end,
			logger = { logInformation = function() end, logWarning = function() end },
		})
		local phaseChangeCount = 0
		stoppedClock:subscribeToRoundPhaseChanged(function()
			phaseChangeCount += 1
		end)
		stoppedClock:startRoundCycle()
		stoppedClock:stopRoundCycle()
		harness.advanceSeconds(600)
		expect(phaseChangeCount).toBe(1)
		expect(stoppedClock:readCurrentRoundState()).toBeNil()
	end)

	it("lets a listener stop the clock: the change in progress finishes, nothing follows", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:subscribeToRoundPhaseChanged(function(roundState)
			if roundState.roundPhase == "Showcase" then
				harness.themedRoundClock:stopRoundCycle()
			end
		end)
		local laterListenerPhases = {}
		harness.themedRoundClock:subscribeToRoundPhaseChanged(function(roundState)
			table.insert(laterListenerPhases, roundState.roundPhase)
		end)
		harness.themedRoundClock:startRoundCycle()
		harness.advanceSeconds(190) -- Showcase starts and the listener stops the clock
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
		harness.advanceSeconds(2 * 280)
		expect(laterListenerPhases).toEqual({ "ThemeReveal", "Styling", "Showcase" })
		expect(harness.themedRoundClock:readCurrentRoundState()).toBeNil()
	end)

	it("refuses a second start, and a start after a stop; a second stop does nothing", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:startRoundCycle()
		expect(function()
			harness.themedRoundClock:startRoundCycle()
		end).toThrow("already started")
		harness.themedRoundClock:stopRoundCycle()
		harness.themedRoundClock:stopRoundCycle()
		expect(function()
			harness.themedRoundClock:startRoundCycle()
		end).toThrow("already started")
		expect(#harness.observedPhaseChanges).toBe(1)
	end)

	it("refuses a start that comes after a stop made before starting (shutdown racing start-up)", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:stopRoundCycle()
		expect(function()
			harness.themedRoundClock:startRoundCycle()
		end).toThrow("never restarted")
		harness.advanceSeconds(600)
		expect(#harness.observedPhaseChanges).toBe(0)
		expect(harness.themedRoundClock:isRoundCycleRunning()).toBeFalse()
	end)

	it("raises when a dependency is missing", function()
		local completeDependencies = {
			themeCatalogThemes = ThemedRoundClockTestHarness.createFixtureThemeCatalogThemes(6),
			clock = {},
			scheduler = {},
			randomNumberGenerator = {},
			generateUniqueRoundId = function()
				return "round"
			end,
			logger = {},
		}
		for missingDependencyName in completeDependencies do
			local incompleteDependencies = table.clone(completeDependencies)
			incompleteDependencies[missingDependencyName] = nil
			expect(function()
				ThemedRoundClock.new(incompleteDependencies)
			end).toThrow("missing dependency " .. missingDependencyName)
		end
	end)

	it("raises at start when the round id generator returns no id", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		local clockWithBrokenRoundIds = ThemedRoundClock.new({
			themeCatalogThemes = ThemedRoundClockTestHarness.createFixtureThemeCatalogThemes(6),
			clock = harness.fakeClock,
			scheduler = harness.fakeScheduler,
			randomNumberGenerator = SeededRandomTrials.createSeededRandomNumberGenerator(1),
			generateUniqueRoundId = function()
				return ""
			end,
			logger = { logInformation = function() end, logWarning = function() end },
		})
		expect(function()
			clockWithBrokenRoundIds:startRoundCycle()
		end).toThrow("generateUniqueRoundId")
	end)
end)
