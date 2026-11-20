-- Spec §2.1: the device's countdown from phaseEndsAtUnixMilliseconds and a device clock that may be
-- wrong: never negative, never longer than the phase, corrected by what the messages prove.

local UnitTestFramework = require("../Support/UnitTestFramework")
local RoundPhaseCountdownEstimator = require("../../src/client/RoundPhaseCountdownEstimator")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local SERVER_PHASE_START = 1_800_000_000_000
local STYLING_ENDS = SERVER_PHASE_START + 180_000

local function stylingState()
	return { roundPhase = "Styling", phaseEndsAtUnixMilliseconds = STYLING_ENDS }
end

describe("RoundPhaseCountdownEstimator", function()
	it("counts down from the phase end with an exact device clock", function()
		local estimator = RoundPhaseCountdownEstimator.new()
		estimator:noteRoundStateReceived(stylingState(), SERVER_PHASE_START + 50)
		expect(estimator:readRemainingSecondsInPhase(stylingState(), SERVER_PHASE_START + 50)).toBeCloseTo(179.95)
		expect(estimator:readRemainingSecondsInPhase(stylingState(), SERVER_PHASE_START + 120_000)).toBeCloseTo(60)
		expect(estimator:readDeviceClockAheadOfServerMilliseconds()).toBe(0)
	end)

	it("starts at the full phase length, never at a negative time, when the device clock runs far ahead", function()
		local estimator = RoundPhaseCountdownEstimator.new()
		local deviceAhead = 10 * 60_000
		estimator:noteRoundStateReceived(stylingState(), SERVER_PHASE_START + deviceAhead)
		local remaining = estimator:readRemainingSecondsInPhase(stylingState(), SERVER_PHASE_START + deviceAhead)
		expect(remaining).toBeCloseTo(180) -- the phase message is taken as sent the moment it arrived
		expect(estimator:readDeviceClockAheadOfServerMilliseconds()).toBe(deviceAhead)
		expect(estimator:readRemainingSecondsInPhase(stylingState(), SERVER_PHASE_START + deviceAhead + 179_500)).toBeCloseTo(
			0.5
		)
		expect(estimator:readRemainingSecondsInPhase(stylingState(), SERVER_PHASE_START + deviceAhead + 400_000)).toBe(
			0
		)
	end)

	it("believes the device clock while it agrees with every message (a mid-phase join)", function()
		local estimator = RoundPhaseCountdownEstimator.new()
		estimator:noteRoundStateReceived(stylingState(), SERVER_PHASE_START + 150_000)
		expect(estimator:readRemainingSecondsInPhase(stylingState(), SERVER_PHASE_START + 150_000)).toBeCloseTo(30)
	end)

	it("corrects a device clock 30 s ahead within one round, as the short phases narrow the window", function()
		local estimator = RoundPhaseCountdownEstimator.new()
		local deviceAhead = 30_000
		local resultsEnds = STYLING_ENDS + 60_000 + 20_000
		estimator:noteRoundStateReceived(stylingState(), SERVER_PHASE_START + deviceAhead)
		expect(estimator:readDeviceClockAheadOfServerMilliseconds()).toBe(0) -- not yet provable
		local results = { roundPhase = "Results", phaseEndsAtUnixMilliseconds = resultsEnds }
		estimator:noteRoundStateReceived(results, resultsEnds - 20_000 + deviceAhead)
		expect(estimator:readDeviceClockAheadOfServerMilliseconds()).toBe(deviceAhead)
	end)

	it("corrects a device clock running ahead once a later message proves it", function()
		local estimator = RoundPhaseCountdownEstimator.new()
		local deviceAhead = 300_000
		local themeReveal = { roundPhase = "ThemeReveal", phaseEndsAtUnixMilliseconds = SERVER_PHASE_START }
		-- ThemeReveal began 10 s before Styling; the device receives it at its start.
		estimator:noteRoundStateReceived(themeReveal, SERVER_PHASE_START - 10_000 + deviceAhead)
		estimator:noteRoundStateReceived(stylingState(), SERVER_PHASE_START + deviceAhead)
		-- Windows: [deviceAhead - 10 s, deviceAhead] and [deviceAhead, deviceAhead + 180 s]: exactly deviceAhead.
		expect(estimator:readDeviceClockAheadOfServerMilliseconds()).toBe(deviceAhead)
		local remaining = estimator:readRemainingSecondsInPhase(stylingState(), SERVER_PHASE_START + deviceAhead)
		expect(remaining).toBeCloseTo(180)
		local laterRemaining =
			estimator:readRemainingSecondsInPhase(stylingState(), SERVER_PHASE_START + deviceAhead + 100_000)
		expect(laterRemaining).toBeCloseTo(80)
	end)

	it("never shows more than the phase can last when the device clock runs behind", function()
		local estimator = RoundPhaseCountdownEstimator.new()
		local deviceBehind = 3 * 3600_000
		estimator:noteRoundStateReceived(stylingState(), SERVER_PHASE_START - deviceBehind)
		local remaining = estimator:readRemainingSecondsInPhase(stylingState(), SERVER_PHASE_START - deviceBehind)
		expect(remaining).toBeCloseTo(180)
		-- and it then counts down at the device clock's rate
		expect(estimator:readRemainingSecondsInPhase(stylingState(), SERVER_PHASE_START - deviceBehind + 30_000)).toBeCloseTo(
			150
		)
	end)

	it("clamps to [0, phase duration] even without any message seen", function()
		local estimator = RoundPhaseCountdownEstimator.new()
		expect(estimator:readRemainingSecondsInPhase(stylingState(), STYLING_ENDS + 5000)).toBe(0)
		expect(estimator:readRemainingSecondsInPhase(stylingState(), SERVER_PHASE_START - 900_000)).toBe(180)
	end)

	it("lets the newest message win when it contradicts everything seen (the device clock jumped)", function()
		local estimator = RoundPhaseCountdownEstimator.new()
		estimator:noteRoundStateReceived(stylingState(), SERVER_PHASE_START)
		local jump = 3600_000
		estimator:noteRoundStateReceived(stylingState(), SERVER_PHASE_START + jump + 1000)
		expect(estimator:readDeviceClockAheadOfServerMilliseconds()).toBe(jump + 1000)
		local showcase = { roundPhase = "Showcase", phaseEndsAtUnixMilliseconds = STYLING_ENDS + 60_000 }
		estimator:noteRoundStateReceived(showcase, STYLING_ENDS + jump)
		expect(estimator:readRemainingSecondsInPhase(showcase, STYLING_ENDS + jump)).toBeCloseTo(60)
	end)

	it("answers nil for an unknown phase or a non-finite number and ignores such messages", function()
		local estimator = RoundPhaseCountdownEstimator.new()
		local badStates = {
			{ roundPhase = "Dancing", phaseEndsAtUnixMilliseconds = STYLING_ENDS },
			{ roundPhase = "Styling", phaseEndsAtUnixMilliseconds = 0 / 0 },
			{ roundPhase = "Styling", phaseEndsAtUnixMilliseconds = math.huge },
		}
		for _, badState in badStates do
			estimator:noteRoundStateReceived(badState, SERVER_PHASE_START)
			expect(estimator:readRemainingSecondsInPhase(badState, SERVER_PHASE_START)).toBeNil()
		end
		expect(estimator:readRemainingSecondsInPhase(stylingState(), 0 / 0)).toBeNil()
		estimator:noteRoundStateReceived(stylingState(), 0 / 0) -- a broken device clock reading
		estimator:noteRoundStateReceived(stylingState(), math.huge)
		expect(estimator:readDeviceClockAheadOfServerMilliseconds()).toBe(0)
	end)
end)
