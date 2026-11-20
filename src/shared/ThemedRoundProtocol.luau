-- The themed-round protocol values that BOTH the device and the server need (development spec
-- §2.1, §2.2, §2.3). One place, so the device's countdown, wardrobe lock and draft sending can
-- never disagree with the server's round clock and referee.
--
-- Server-only round values (for example how many recent themes are excluded) live in
-- src/server/ThemedRoundClock.luau. The round bonus kind names live in
-- OutfitScoreCalculator.ROUND_BONUS_KINDS and are not repeated here.
-- Pure data plus two lookups: no Roblox-specific interface is used.

local function freezeWithErrorOnUnknownRoundPhase(valueByRoundPhase: { [string]: any }): { [string]: any }
	setmetatable(valueByRoundPhase, {
		__index = function(_, unknownRoundPhase)
			error(string.format("ThemedRoundProtocol: unknown round phase %q", tostring(unknownRoundPhase)), 2)
		end,
	})
	return table.freeze(valueByRoundPhase)
end

local ThemedRoundProtocol = {}

-- §2.1: `roundPhase` values. Reading a name that is not listed raises instead of returning nil.
ThemedRoundProtocol.ROUND_PHASES = freezeWithErrorOnUnknownRoundPhase({
	ThemeReveal = "ThemeReveal",
	Styling = "Styling",
	Showcase = "Showcase",
	Results = "Results",
	Intermission = "Intermission",
})

-- §2.1: the cycle; after the last phase the next round starts again at the first.
ThemedRoundProtocol.ROUND_PHASE_ORDER = table.freeze({
	"ThemeReveal",
	"Styling",
	"Showcase",
	"Results",
	"Intermission",
})

-- §2.1 phase durations.
ThemedRoundProtocol.THEME_REVEAL_SECONDS = 10
ThemedRoundProtocol.STYLING_SECONDS = 180
ThemedRoundProtocol.SHOWCASE_SECONDS = 60
ThemedRoundProtocol.RESULTS_SECONDS = 20
ThemedRoundProtocol.INTERMISSION_SECONDS = 10

-- The same durations keyed by `roundPhase`. Reading an unknown phase raises.
ThemedRoundProtocol.PHASE_DURATION_SECONDS_BY_ROUND_PHASE = freezeWithErrorOnUnknownRoundPhase({
	ThemeReveal = ThemedRoundProtocol.THEME_REVEAL_SECONDS,
	Styling = ThemedRoundProtocol.STYLING_SECONDS,
	Showcase = ThemedRoundProtocol.SHOWCASE_SECONDS,
	Results = ThemedRoundProtocol.RESULTS_SECONDS,
	Intermission = ThemedRoundProtocol.INTERMISSION_SECONDS,
})

-- §0.2: one whole round, from the start of ThemeReveal to the end of Intermission (280 s).
ThemedRoundProtocol.WHOLE_ROUND_SECONDS = ThemedRoundProtocol.THEME_REVEAL_SECONDS
	+ ThemedRoundProtocol.STYLING_SECONDS
	+ ThemedRoundProtocol.SHOWCASE_SECONDS
	+ ThemedRoundProtocol.RESULTS_SECONDS
	+ ThemedRoundProtocol.INTERMISSION_SECONDS

-- §2.1
ThemedRoundProtocol.MAX_PLAYERS_PER_SERVER = 12

-- §2.2: joining is accepted during ThemeReveal, and during Styling while at least this many
-- seconds of Styling remain.
ThemedRoundProtocol.MINIMUM_STYLING_SECONDS_TO_JOIN = 60

-- §2.3 outfit drafts. The server processes at most one draft per player per this interval and
-- coalesces faster drafts instead of refusing them.
ThemedRoundProtocol.OUTFIT_DRAFT_SERVER_PROCESSING_INTERVAL_SECONDS = 0.25
-- §2.3: the device sends the current outfit at most once per this interval.
ThemedRoundProtocol.OUTFIT_DRAFT_SEND_INTERVAL_SECONDS = 0.5
-- §2.3: the device resends its latest draft (same sequence number) when it is still not
-- acknowledged after this long.
ThemedRoundProtocol.OUTFIT_DRAFT_RESEND_AFTER_SECONDS = 1
-- §2.3: the device locks the wardrobe this long before Styling's `phaseEndsAtUnixMilliseconds`.
ThemedRoundProtocol.WARDROBE_LOCK_BEFORE_STYLING_END_SECONDS = 1

local roundPhasePositionByRoundPhase: { [string]: number } = {}
for roundPhasePosition, roundPhase in ThemedRoundProtocol.ROUND_PHASE_ORDER do
	roundPhasePositionByRoundPhase[roundPhase] = roundPhasePosition
end
table.freeze(roundPhasePositionByRoundPhase)

-- Accepts any value (including nil and non-strings); true only for one of the five phase names.
function ThemedRoundProtocol.isKnownRoundPhase(candidateRoundPhase: any): boolean
	return type(candidateRoundPhase) == "string" and roundPhasePositionByRoundPhase[candidateRoundPhase] ~= nil
end

-- The phase that follows `roundPhase` in the cycle (Intermission is followed by ThemeReveal).
-- Raises for an unknown phase.
function ThemedRoundProtocol.getRoundPhaseFollowing(roundPhase: string): string
	local roundPhasePosition = if type(roundPhase) == "string" then roundPhasePositionByRoundPhase[roundPhase] else nil
	if roundPhasePosition == nil then
		error(string.format("ThemedRoundProtocol: unknown round phase %q", tostring(roundPhase)), 2)
	end
	local roundPhaseOrder = ThemedRoundProtocol.ROUND_PHASE_ORDER
	return roundPhaseOrder[roundPhasePosition % #roundPhaseOrder + 1]
end

return table.freeze(ThemedRoundProtocol)
