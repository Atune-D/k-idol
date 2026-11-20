-- ThemedRoundClock: failed phase changes, boundaries and the smaller promises of the header
-- comment in src/server/ThemedRoundClock.luau (re-planning boundary, whole milliseconds, no
-- negative delays, the private copy of the catalog, subscribing and unsubscribing from inside
-- a listener, round-start logging, argument checks).

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local StylingTagVocabulary = require("../../src/shared/StylingTagVocabulary")
local ThemeCatalog = require("../../src/shared/ThemeCatalog")
local ThemedRoundClock = require("../../src/server/ThemedRoundClock")
local ThemedRoundClockTestHarness = require("./ThemedRoundClockTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local START_UNIX_MILLISECONDS = ThemedRoundClockTestHarness.EXAMPLE_STARTING_UNIX_MILLISECONDS

local function containsText(fullText: string, expectedFragment: string): boolean
	return string.find(fullText, expectedFragment, 1, true) ~= nil
end

-- The state stopRoundCycle leaves behind.
local function expectClockToBeStoppedForGood(harness)
	expect(harness.themedRoundClock:isRoundCycleRunning()).toBeFalse()
	expect(harness.themedRoundClock:readCurrentRoundState()).toBeNil()
	expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
end

describe("ThemedRoundClock when a phase change fails", function()
	it("at start: logs that the cycle stopped, leaves the clock stopped, and raises to the caller", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes({
			generateUniqueRoundId = function()
				return ""
			end,
		})
		expect(function()
			harness.themedRoundClock:startRoundCycle()
		end).toThrow("round cycle has stopped")
		expectClockToBeStoppedForGood(harness)
		expect(#harness.observedPhaseChanges).toBe(0)
		expect(#harness.loggedWarnings).toBe(1)
		expect(containsText(harness.loggedWarnings[1], "round cycle has stopped")).toBeTrue()
		expect(containsText(harness.loggedWarnings[1], "generateUniqueRoundId")).toBeTrue()
		expect(function()
			harness.themedRoundClock:startRoundCycle()
		end).toThrow("never restarted")
	end)

	it("at a later ThemeReveal (bad round id): logs, stops honestly, calls no listener, raises nothing", function()
		local issuedRoundIdCount = 0
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes({
			generateUniqueRoundId = function()
				issuedRoundIdCount += 1
				return if issuedRoundIdCount == 1 then "round-1" else nil
			end,
		})
		harness.themedRoundClock:startRoundCycle()
		harness.advanceSeconds(279)
		expect(harness.themedRoundClock:readCurrentRoundState().roundPhase).toBe("Intermission")
		harness.advanceSeconds(1) -- round 2's ThemeReveal fails; the advance itself does not raise
		expectClockToBeStoppedForGood(harness)
		expect(#harness.observedPhaseChanges).toBe(5)
		expect(#harness.loggedWarnings).toBe(1)
		expect(containsText(harness.loggedWarnings[1], "round cycle has stopped")).toBeTrue()
		expect(containsText(harness.loggedWarnings[1], "ThemeReveal")).toBeTrue()
		harness.advanceSeconds(3600)
		expect(#harness.observedPhaseChanges).toBe(5)
		expect(issuedRoundIdCount).toBe(2)
	end)

	it("at a later ThemeReveal (random number out of range): stops honestly in the same way", function()
		local workingRandomNumberGenerator = SeededRandomTrials.createSeededRandomNumberGenerator(7)
		local isRandomNumberGeneratorBroken = false
		local switchableRandomNumberGenerator = {
			nextWholeNumberInRange = function(smallestWholeNumber: number, largestWholeNumber: number)
				if isRandomNumberGeneratorBroken then
					return largestWholeNumber + 1
				end
				return workingRandomNumberGenerator.nextWholeNumberInRange(smallestWholeNumber, largestWholeNumber)
			end,
		}
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes({
			randomNumberGenerator = switchableRandomNumberGenerator :: any,
		})
		harness.themedRoundClock:startRoundCycle()
		isRandomNumberGeneratorBroken = true
		harness.advanceSeconds(280)
		expectClockToBeStoppedForGood(harness)
		expect(#harness.observedPhaseChanges).toBe(5)
		expect(#harness.loggedWarnings).toBe(1)
		expect(containsText(harness.loggedWarnings[1], "outside")).toBeTrue()
	end)
end)

describe("ThemedRoundClock re-planning boundary", function()
	it("re-plans a phase whose callback runs exactly at that phase's planned end", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:startRoundCycle()
		harness.advanceSeconds(9.999)
		harness.fakeClock:advanceBySeconds(180.001) -- now = Styling's planned end (190 s)
		harness.advanceSeconds(0)
		local stylingState = harness.themedRoundClock:readCurrentRoundState()
		expect(stylingState.roundPhase).toBe("Styling")
		expect(stylingState.phaseEndsAtUnixMilliseconds).toBe(START_UNIX_MILLISECONDS + 190_000 + 180_000)
		expect(#harness.loggedWarnings).toBe(1)
	end)

	it("keeps the planned end when the callback runs 1 ms before it (a 1 ms phase, no warning)", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:startRoundCycle()
		harness.advanceSeconds(9.999)
		harness.fakeClock:advanceBySeconds(180) -- now = 1 ms before Styling's planned end
		harness.advanceSeconds(0)
		local stylingState = harness.themedRoundClock:readCurrentRoundState()
		expect(stylingState.roundPhase).toBe("Styling")
		expect(stylingState.phaseEndsAtUnixMilliseconds).toBe(START_UNIX_MILLISECONDS + 190_000)
		expect(harness.loggedWarnings).toEqual({})
		expect(harness.requestedDelaySeconds[#harness.requestedDelaySeconds]).toBe(0.001)
	end)
end)

describe("ThemedRoundClock time handling", function()
	it("never asks the scheduler for a negative delay, even when time passes during a phase change", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:startRoundCycle()
		-- From round 2 on, the round-start log call is slow: 11 s pass, longer than ThemeReveal.
		harness.runWhenInformationLogged = function()
			harness.fakeClock:advanceBySeconds(11)
		end
		-- Advance to 291 s so the fake clock never has to move backwards after the jump.
		harness.advanceSeconds(291)
		harness.runWhenInformationLogged = nil
		for _, requestedDelaySeconds in harness.requestedDelaySeconds do
			expect({ requestedDelaySeconds, requestedDelaySeconds >= 0 }).toEqual({ requestedDelaySeconds, true })
		end
		expect(harness.themedRoundClock:readCurrentRoundState().roundPhase).toBe("Styling")
	end)

	it("keeps every phase end and requested delay on whole milliseconds with a fractional clock", function()
		SeededRandomTrials.runSeededRandomTrials(5, function(seededRandomNumberGenerator)
			local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes({
				addFractionalMillisecondsToClockReading = function()
					return seededRandomNumberGenerator.nextWholeNumberInRange(1, 999) / 1000
				end,
			})
			harness.themedRoundClock:startRoundCycle()
			-- One extra second: a reading rounded up puts the whole grid 1 ms later.
			harness.advanceSeconds(2 * 280 + 1)
			expect(#harness.observedPhaseChanges).toBe(11)
			for _, observedPhaseChange in harness.observedPhaseChanges do
				local phaseEndsAtUnixMilliseconds = observedPhaseChange.roundState.phaseEndsAtUnixMilliseconds
				expect({ phaseEndsAtUnixMilliseconds, phaseEndsAtUnixMilliseconds % 1 == 0 }).toEqual({
					phaseEndsAtUnixMilliseconds,
					true,
				})
			end
			for _, requestedDelaySeconds in harness.requestedDelaySeconds do
				local requestedDelayMilliseconds = requestedDelaySeconds * 1000
				local isWholeMilliseconds = math.abs(
					requestedDelayMilliseconds - math.round(requestedDelayMilliseconds)
				) < 1e-6
				expect({ requestedDelaySeconds, isWholeMilliseconds }).toEqual({ requestedDelaySeconds, true })
			end
		end)
	end)
end)

describe("ThemedRoundClock theme catalog checks", function()
	it("keeps its own copy of the catalog: changing the caller's list after new has no effect", function()
		local callerThemeList = ThemedRoundClockTestHarness.createFixtureThemeCatalogThemes(6)
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes({ themeCatalogThemes = callerThemeList })
		table.clear(callerThemeList)
		for _, replacementTheme in ThemeCatalog.THEMES do
			table.insert(callerThemeList, replacementTheme)
		end
		harness.themedRoundClock:startRoundCycle()
		harness.advanceSeconds(12 * 280 - 1)
		local roundStartStates = harness.listObservedRoundStartStates()
		expect(#roundStartStates).toBe(12)
		for _, roundStartState in roundStartStates do
			expect(string.sub(roundStartState.themeId, 1, #"fixture_theme_")).toBe("fixture_theme_")
		end
	end)

	it("refuses an empty or non-string themeId", function()
		for _, badThemeId in { "", 42 } do
			local fixtureThemes = ThemedRoundClockTestHarness.createFixtureThemeCatalogThemes(6)
			table.insert(
				fixtureThemes,
				{
					themeId = badThemeId,
					themeDisplayName = "Bad",
					styleTagWeights = { y2k = 1.0 },
				} :: any
			)
			expect(function()
				ThemedRoundClockTestHarness.createRoundClockWithFakes({ themeCatalogThemes = fixtureThemes })
			end).toThrow("missing or not unique")
		end
	end)
end)

describe("ThemedRoundClock listeners changed from inside a listener", function()
	it("a listener that unsubscribes itself does not make the next listener miss the change", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		local selfRemovingListenerCallCount = 0
		local unsubscribeSelfRemovingListener
		unsubscribeSelfRemovingListener = harness.themedRoundClock:subscribeToRoundPhaseChanged(function()
			selfRemovingListenerCallCount += 1
			unsubscribeSelfRemovingListener()
		end)
		local nextListenerPhases = {}
		harness.themedRoundClock:subscribeToRoundPhaseChanged(function(roundState)
			table.insert(nextListenerPhases, roundState.roundPhase)
		end)
		harness.themedRoundClock:startRoundCycle()
		harness.advanceSeconds(10)
		expect(selfRemovingListenerCallCount).toBe(1)
		expect(nextListenerPhases).toEqual({ "ThemeReveal", "Styling" })
	end)

	it("a listener subscribed from inside a listener starts with the next change, not this one", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		local lateListenerPhases = {}
		local hasSubscribedLateListener = false
		harness.themedRoundClock:subscribeToRoundPhaseChanged(function()
			if hasSubscribedLateListener then
				return
			end
			hasSubscribedLateListener = true
			harness.themedRoundClock:subscribeToRoundPhaseChanged(function(roundState)
				table.insert(lateListenerPhases, roundState.roundPhase)
			end)
		end)
		harness.themedRoundClock:startRoundCycle()
		expect(lateListenerPhases).toEqual({})
		harness.advanceSeconds(10)
		expect(lateListenerPhases).toEqual({ "Styling" })
	end)
end)

describe("ThemedRoundClock smaller promises", function()
	it("logs each round start once with its round id, theme and bonus", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		harness.themedRoundClock:startRoundCycle()
		harness.advanceSeconds(3 * 280 - 1)
		local roundStartStates = harness.listObservedRoundStartStates()
		expect(#harness.loggedInformation).toBe(3)
		for roundIndex, roundStartState in roundStartStates do
			local loggedLine = harness.loggedInformation[roundIndex]
			local roundBonusRule = roundStartState.roundBonusRule
			expect(containsText(loggedLine, roundStartState.roundId)).toBeTrue()
			expect(containsText(loggedLine, roundStartState.themeId)).toBeTrue()
			expect(containsText(loggedLine, roundBonusRule.roundBonusKind)).toBeTrue()
			expect(containsText(loggedLine, roundBonusRule.bonusColorTag or roundBonusRule.bonusStyleTag)).toBeTrue()
		end
	end)

	it("refuses a listener that is not a function", function()
		local harness = ThemedRoundClockTestHarness.createRoundClockWithFakes()
		for _, notAFunction in { "listener", 42, {} } do
			expect(function()
				harness.themedRoundClock:subscribeToRoundPhaseChanged(notAFunction :: any)
			end).toThrow("listener must be a function")
		end
	end)

	it("returns a frozen bonus rule from chooseRoundBonusRuleForTheme", function()
		SeededRandomTrials.runSeededRandomTrials(1, function(seededRandomNumberGenerator)
			for _ = 1, 50 do
				local roundBonusRule =
					ThemedRoundClock.chooseRoundBonusRuleForTheme(ThemeCatalog.THEMES[1], seededRandomNumberGenerator)
				expect(table.isfrozen(roundBonusRule)).toBeTrue()
			end
		end)
	end)

	it("raises from chooseRoundBonusRuleForTheme for a StyleBonus on a theme that weights every tag", function()
		local everyStyleTagWeights = {}
		for _, styleTag in StylingTagVocabulary.STYLE_TAGS do
			everyStyleTagWeights[styleTag] = 0.5
		end
		local alwaysPickLastGenerator = {
			nextWholeNumberInRange = function(_, largestWholeNumber: number)
				return largestWholeNumber -- the second kind is StyleBonus
			end,
		}
		expect(function()
			ThemedRoundClock.chooseRoundBonusRuleForTheme({
				themeId = "fixture_theme_weighting_everything",
				themeDisplayName = "Everything",
				styleTagWeights = everyStyleTagWeights,
			}, alwaysPickLastGenerator :: any)
		end).toThrow("weights every style tag")
	end)
end)
