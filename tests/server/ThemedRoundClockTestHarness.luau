-- Builds a ThemedRoundClock wired to fakes (FakeClock, FakeScheduler, a seeded random number
-- generator, a counting round id generator, a recording logger) and records every phase change
-- it announces. Also builds small fixture theme catalogs. Not a spec file; the round clock spec
-- files require it.

local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local ThemeCatalog = require("../../src/shared/ThemeCatalog")
local ThemedRoundClock = require("../../src/server/ThemedRoundClock")

local ThemedRoundClockTestHarness = {}

-- 2025-11-19 00:00:00 UTC; a whole number so integer advances give exact times.
ThemedRoundClockTestHarness.EXAMPLE_STARTING_UNIX_SECONDS = 1_763_510_400
ThemedRoundClockTestHarness.EXAMPLE_STARTING_UNIX_MILLISECONDS = 1_763_510_400_000
-- Used by the tests that are not randomized trials, so they behave the same on every run.
ThemedRoundClockTestHarness.FIXED_RANDOM_SEED_FOR_NON_RANDOMIZED_TESTS = 20261119

-- Fixture themes "fixture_theme_1" … "fixture_theme_<themeCount>", each weighting one style tag,
-- so every theme leaves style tags unweighted.
function ThemedRoundClockTestHarness.createFixtureThemeCatalogThemes(themeCount: number): { ThemeCatalog.Theme }
	local fixtureThemes = {}
	for themeNumber = 1, themeCount do
		table.insert(
			fixtureThemes,
			table.freeze({
				themeId = "fixture_theme_" .. tostring(themeNumber),
				themeDisplayName = "Fixture Theme " .. tostring(themeNumber),
				styleTagWeights = table.freeze({ y2k = 1.0 }),
			})
		)
	end
	return fixtureThemes
end

export type ThemedRoundClockHarnessOptions = {
	themeCatalogThemes: { ThemeCatalog.Theme }?,
	randomNumberGenerator: SeededRandomTrials.SeededRandomNumberGenerator?,
	-- Replaces the counting "round-<n>" generator (then generatedRoundIds stays empty).
	generateUniqueRoundId: (() -> any)?,
	-- When given, every clock reading the round clock makes is the fake time plus this many
	-- (fractional) milliseconds, like a real clock that is not on whole milliseconds.
	addFractionalMillisecondsToClockReading: (() -> number)?,
}

-- Returns a NOT yet started clock with a recording subscription already in place, so the first
-- ThemeReveal is recorded too. Every delay the clock asks the scheduler for is recorded in
-- `requestedDelaySeconds`. A test may set `harness.runWhenInformationLogged` to make something
-- happen while the clock is logging (for example, time passing during a slow call).
function ThemedRoundClockTestHarness.createRoundClockWithFakes(harnessOptions: ThemedRoundClockHarnessOptions?)
	local chosenHarnessOptions: ThemedRoundClockHarnessOptions = harnessOptions or {}
	local fakeClock = FakeClock.new(ThemedRoundClockTestHarness.EXAMPLE_STARTING_UNIX_SECONDS)
	local fakeScheduler = FakeScheduler.new(fakeClock)
	local loggedWarnings = {}
	local loggedInformation = {}
	local generatedRoundIds = {}
	local requestedDelaySeconds = {}
	local harness = {}

	local recordingLogger = {}
	function recordingLogger.logInformation(_, message: string)
		table.insert(loggedInformation, message)
		if harness.runWhenInformationLogged then
			harness.runWhenInformationLogged()
		end
	end
	function recordingLogger.logWarning(_, message: string)
		table.insert(loggedWarnings, message)
	end

	local recordingScheduler = {}
	function recordingScheduler.scheduleCallbackAfterSeconds(_, delaySeconds: number, callback: () -> ())
		table.insert(requestedDelaySeconds, delaySeconds)
		return fakeScheduler:scheduleCallbackAfterSeconds(math.max(0, delaySeconds), callback)
	end

	local roundClockTimeSource = fakeClock
	local addFractionalMillisecondsToClockReading = chosenHarnessOptions.addFractionalMillisecondsToClockReading
	if addFractionalMillisecondsToClockReading then
		roundClockTimeSource = {
			getCurrentUnixMilliseconds = function()
				return fakeClock:getCurrentUnixMilliseconds() + addFractionalMillisecondsToClockReading()
			end,
		} :: any
	end

	local themedRoundClock = ThemedRoundClock.new({
		themeCatalogThemes = chosenHarnessOptions.themeCatalogThemes or ThemeCatalog.THEMES,
		clock = roundClockTimeSource,
		scheduler = recordingScheduler,
		randomNumberGenerator = chosenHarnessOptions.randomNumberGenerator
			or SeededRandomTrials.createSeededRandomNumberGenerator(
				ThemedRoundClockTestHarness.FIXED_RANDOM_SEED_FOR_NON_RANDOMIZED_TESTS
			),
		generateUniqueRoundId = chosenHarnessOptions.generateUniqueRoundId or function()
			local roundId = "round-" .. tostring(#generatedRoundIds + 1)
			table.insert(generatedRoundIds, roundId)
			return roundId
		end,
		logger = recordingLogger,
	})

	-- Every announced state, with the fake time at which the listener was called.
	local observedPhaseChanges = {}
	themedRoundClock:subscribeToRoundPhaseChanged(function(roundState)
		table.insert(observedPhaseChanges, {
			roundState = roundState,
			announcedAtUnixMilliseconds = fakeClock:getCurrentUnixMilliseconds(),
		})
	end)

	harness.themedRoundClock = themedRoundClock
	harness.fakeClock = fakeClock
	harness.fakeScheduler = fakeScheduler
	harness.loggedWarnings = loggedWarnings
	harness.loggedInformation = loggedInformation
	harness.generatedRoundIds = generatedRoundIds
	harness.observedPhaseChanges = observedPhaseChanges
	harness.requestedDelaySeconds = requestedDelaySeconds

	function harness.advanceSeconds(elapsedSeconds: number)
		fakeScheduler:advanceTimeAndRunDueCallbacks(elapsedSeconds)
	end

	-- The announced states that began a round (ThemeReveal), in order.
	function harness.listObservedRoundStartStates()
		local roundStartStates = {}
		for _, observedPhaseChange in observedPhaseChanges do
			if observedPhaseChange.roundState.roundPhase == "ThemeReveal" then
				table.insert(roundStartStates, observedPhaseChange.roundState)
			end
		end
		return roundStartStates
	end

	return harness
end

-- Starts a clock with a seeded generator and runs it for `roundCount` whole rounds; returns the
-- harness. Used by the randomized theme and bonus tests.
function ThemedRoundClockTestHarness.runRoundClockForWholeRounds(
	roundCount: number,
	randomNumberGenerator: SeededRandomTrials.SeededRandomNumberGenerator,
	themeCatalogThemes: { ThemeCatalog.Theme }?
)
	local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes({
		themeCatalogThemes = themeCatalogThemes,
		randomNumberGenerator = randomNumberGenerator,
	})
	harness.themedRoundClock:startRoundCycle()
	-- 280 s per round; stop just short of the next round's ThemeReveal.
	harness.advanceSeconds(280 * roundCount - 1)
	return harness
end

return table.freeze(ThemedRoundClockTestHarness)
