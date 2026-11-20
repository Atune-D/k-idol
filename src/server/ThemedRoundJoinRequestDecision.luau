-- ThemedRoundJoinRequestDecision (development spec v1.3 §2, §2.2, §2.13; referee audit PART 1
-- question 13, PART 2 item k): the pure decision of how to answer one RequestJoinCurrentRound.
-- ThemedRoundReferee gathers the facts and acts on the answer; this module only decides.
-- Pure logic: no Roblox-specific interface is used.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- ThemedRoundJoinRequestDecision.JOIN_REJECTION_REASONS   frozen; the five reasons of §2.2:
--   SaveDataNotLoaded, WardrobeCatalogNotReady, RoundNotJoinableNow, AlreadyParticipating,
--   TooManyRequests
--
-- ThemedRoundJoinRequestDecision.isRoundPhaseOpenForJoining(roundPhase, phaseEndsAtUnixMilliseconds,
--                                                           arrivalUnixMilliseconds) -> boolean
--   §2.2: true during ThemeReveal, and during Styling while at least
--   MINIMUM_STYLING_SECONDS_TO_JOIN (60 s) remain, measured in milliseconds at the request's
--   arrival on the server against the published phaseEndsAtUnixMilliseconds. Exactly 60 000 ms
--   left is accepted; 59 999 ms is not. False in every other phase.
--
-- ThemedRoundJoinRequestDecision.decideJoinCurrentRoundAnswer(joinRequestFacts) -> answer
--   joinRequestFacts = {
--     isAdmittedByRateLimiter: boolean,   PlayerRequestRateLimiter admitted the request
--     isAlreadyParticipating: boolean,    the sender is a participant of the current round
--     isPlayerSaveDataLoaded: boolean,
--     isWardrobeCatalogReady: boolean,
--     isRoundJoinableNow: boolean,        the window above holds and nothing else closes it
--   }
--   The first failing check in this order gives the answer (audit question 13):
--     TooManyRequests, AlreadyParticipating, SaveDataNotLoaded, WardrobeCatalogNotReady,
--     RoundNotJoinableNow.
--   AlreadyParticipating comes before the phase check, so a participant asking again late is
--   never told RoundNotJoinableNow (a device could read that as "you are not in this round").
--   answer: a fresh frozen table of exactly the §2 shape,
--     { isAccepted = true } or { isAccepted = false, rejectionReason = <one of the five> }.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local ThemedRoundProtocol = require("../shared/ThemedRoundProtocol")

local ThemedRoundJoinRequestDecision = {}

ThemedRoundJoinRequestDecision.JOIN_REJECTION_REASONS = table.freeze({
	SaveDataNotLoaded = "SaveDataNotLoaded",
	WardrobeCatalogNotReady = "WardrobeCatalogNotReady",
	RoundNotJoinableNow = "RoundNotJoinableNow",
	AlreadyParticipating = "AlreadyParticipating",
	TooManyRequests = "TooManyRequests",
})

local JOIN_REJECTION_REASONS = ThemedRoundJoinRequestDecision.JOIN_REJECTION_REASONS
local ROUND_PHASES = ThemedRoundProtocol.ROUND_PHASES
local MINIMUM_STYLING_MILLISECONDS_TO_JOIN = ThemedRoundProtocol.MINIMUM_STYLING_SECONDS_TO_JOIN * 1000

function ThemedRoundJoinRequestDecision.isRoundPhaseOpenForJoining(
	roundPhase: string,
	phaseEndsAtUnixMilliseconds: number,
	arrivalUnixMilliseconds: number
): boolean
	if roundPhase == ROUND_PHASES.ThemeReveal then
		return true
	end
	if roundPhase == ROUND_PHASES.Styling then
		return phaseEndsAtUnixMilliseconds - arrivalUnixMilliseconds >= MINIMUM_STYLING_MILLISECONDS_TO_JOIN
	end
	return false
end

local function buildRejectedJoinAnswer(rejectionReason: string)
	return table.freeze({ isAccepted = false, rejectionReason = rejectionReason })
end

function ThemedRoundJoinRequestDecision.decideJoinCurrentRoundAnswer(joinRequestFacts)
	if not joinRequestFacts.isAdmittedByRateLimiter then
		return buildRejectedJoinAnswer(JOIN_REJECTION_REASONS.TooManyRequests)
	end
	if joinRequestFacts.isAlreadyParticipating then
		return buildRejectedJoinAnswer(JOIN_REJECTION_REASONS.AlreadyParticipating)
	end
	if not joinRequestFacts.isPlayerSaveDataLoaded then
		return buildRejectedJoinAnswer(JOIN_REJECTION_REASONS.SaveDataNotLoaded)
	end
	if not joinRequestFacts.isWardrobeCatalogReady then
		return buildRejectedJoinAnswer(JOIN_REJECTION_REASONS.WardrobeCatalogNotReady)
	end
	if not joinRequestFacts.isRoundJoinableNow then
		return buildRejectedJoinAnswer(JOIN_REJECTION_REASONS.RoundNotJoinableNow)
	end
	return table.freeze({ isAccepted = true })
end

return table.freeze(ThemedRoundJoinRequestDecision)
