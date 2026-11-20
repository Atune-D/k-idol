-- Round-protocol values shared by device and server, pinned to development spec §0.2, §2.1–§2.3.

local UnitTestFramework = require("../Support/UnitTestFramework")
local ThemedRoundProtocol = require("../../src/shared/ThemedRoundProtocol")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

describe("ThemedRoundProtocol phases", function()
	it("lists the five phases in the §2.1 order", function()
		expect(ThemedRoundProtocol.ROUND_PHASE_ORDER).toEqual({
			"ThemeReveal",
			"Styling",
			"Showcase",
			"Results",
			"Intermission",
		})
	end)

	it("names each phase by itself and raises for an unknown phase name", function()
		for _, roundPhase in { "ThemeReveal", "Styling", "Showcase", "Results", "Intermission" } do
			expect(ThemedRoundProtocol.ROUND_PHASES[roundPhase]).toBe(roundPhase)
		end
		expect(function()
			return ThemedRoundProtocol.ROUND_PHASES.Lobby
		end).toThrow("unknown round phase")
	end)

	it("cycles ThemeReveal → Styling → Showcase → Results → Intermission → ThemeReveal", function()
		expect(ThemedRoundProtocol.getRoundPhaseFollowing("ThemeReveal")).toBe("Styling")
		expect(ThemedRoundProtocol.getRoundPhaseFollowing("Styling")).toBe("Showcase")
		expect(ThemedRoundProtocol.getRoundPhaseFollowing("Showcase")).toBe("Results")
		expect(ThemedRoundProtocol.getRoundPhaseFollowing("Results")).toBe("Intermission")
		expect(ThemedRoundProtocol.getRoundPhaseFollowing("Intermission")).toBe("ThemeReveal")
	end)

	it("raises when asked for the phase after an unknown phase", function()
		expect(function()
			ThemedRoundProtocol.getRoundPhaseFollowing("Lobby")
		end).toThrow("unknown round phase")
		expect(function()
			ThemedRoundProtocol.getRoundPhaseFollowing(nil :: any)
		end).toThrow("unknown round phase")
	end)

	it("recognises exactly the five phase names", function()
		for _, roundPhase in ThemedRoundProtocol.ROUND_PHASE_ORDER do
			expect(ThemedRoundProtocol.isKnownRoundPhase(roundPhase)).toBeTrue()
		end
		for _, notARoundPhase in { "themereveal", "Lobby", "", 1, true, {} } do
			expect(ThemedRoundProtocol.isKnownRoundPhase(notARoundPhase)).toBeFalse()
		end
		expect(ThemedRoundProtocol.isKnownRoundPhase(nil)).toBeFalse()
	end)
end)

describe("ThemedRoundProtocol durations", function()
	it("pins each §2.1 phase duration", function()
		expect(ThemedRoundProtocol.THEME_REVEAL_SECONDS).toBe(10)
		expect(ThemedRoundProtocol.STYLING_SECONDS).toBe(180)
		expect(ThemedRoundProtocol.SHOWCASE_SECONDS).toBe(60)
		expect(ThemedRoundProtocol.RESULTS_SECONDS).toBe(20)
		expect(ThemedRoundProtocol.INTERMISSION_SECONDS).toBe(10)
	end)

	it("gives the same durations keyed by phase, and raises for an unknown phase", function()
		local phaseDurationSecondsByRoundPhase = ThemedRoundProtocol.PHASE_DURATION_SECONDS_BY_ROUND_PHASE
		expect(phaseDurationSecondsByRoundPhase.ThemeReveal).toBe(10)
		expect(phaseDurationSecondsByRoundPhase.Styling).toBe(180)
		expect(phaseDurationSecondsByRoundPhase.Showcase).toBe(60)
		expect(phaseDurationSecondsByRoundPhase.Results).toBe(20)
		expect(phaseDurationSecondsByRoundPhase.Intermission).toBe(10)
		expect(function()
			return phaseDurationSecondsByRoundPhase.Lobby
		end).toThrow("unknown round phase")
	end)

	it("makes one whole round 280 seconds (§0.2)", function()
		local summedPhaseSeconds = 0
		for _, roundPhase in ThemedRoundProtocol.ROUND_PHASE_ORDER do
			summedPhaseSeconds += ThemedRoundProtocol.PHASE_DURATION_SECONDS_BY_ROUND_PHASE[roundPhase]
		end
		expect(summedPhaseSeconds).toBe(280)
		expect(ThemedRoundProtocol.WHOLE_ROUND_SECONDS).toBe(280)
	end)
end)

describe("ThemedRoundProtocol joining and outfit drafts", function()
	it("pins MAX_PLAYERS_PER_SERVER (§2.1) and MINIMUM_STYLING_SECONDS_TO_JOIN (§2.2)", function()
		expect(ThemedRoundProtocol.MAX_PLAYERS_PER_SERVER).toBe(12)
		expect(ThemedRoundProtocol.MINIMUM_STYLING_SECONDS_TO_JOIN).toBe(60)
	end)

	it("pins the §2.3 outfit draft and wardrobe lock timings", function()
		expect(ThemedRoundProtocol.OUTFIT_DRAFT_SERVER_PROCESSING_INTERVAL_SECONDS).toBe(0.25)
		expect(ThemedRoundProtocol.OUTFIT_DRAFT_SEND_INTERVAL_SECONDS).toBe(0.5)
		expect(ThemedRoundProtocol.OUTFIT_DRAFT_RESEND_AFTER_SECONDS).toBe(1)
		expect(ThemedRoundProtocol.WARDROBE_LOCK_BEFORE_STYLING_END_SECONDS).toBe(1)
	end)

	it("cannot be changed at run time", function()
		expect(table.isfrozen(ThemedRoundProtocol)).toBeTrue()
		expect(table.isfrozen(ThemedRoundProtocol.ROUND_PHASES)).toBeTrue()
		expect(table.isfrozen(ThemedRoundProtocol.ROUND_PHASE_ORDER)).toBeTrue()
		expect(table.isfrozen(ThemedRoundProtocol.PHASE_DURATION_SECONDS_BY_ROUND_PHASE)).toBeTrue()
	end)
end)
