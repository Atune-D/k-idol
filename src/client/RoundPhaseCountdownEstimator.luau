-- RoundPhaseCountdownEstimator (development spec §2.1 round clock, §2.3 wardrobe lock): how many
-- seconds remain in the current round phase, as the DEVICE can best tell.
--
-- The server publishes `phaseEndsAtUnixMilliseconds` read from ITS clock. The device reads its own
-- clock (on Roblox, Workspace:GetServerTimeNow(), already an estimate of the server's time; see
-- RobloxDeviceClockAndScheduler). That clock can still differ from the server's, so the device
-- never trusts it blindly:
--
--   * Every RoundStateChanged tells the device something sure: when the message arrived, between 0
--     and the phase's whole duration (ThemedRoundProtocol.PHASE_DURATION_SECONDS_BY_ROUND_PHASE)
--     remained. So "how far the device clock runs ahead of the server's" lies in
--       [deviceNow - phaseEnds, deviceNow - phaseEnds + phaseDuration]   (milliseconds).
--   * The estimator keeps the intersection of these windows over all messages. The estimated
--     offset is 0 (the device clock is believed) when 0 lies inside the window. Otherwise the device
--     clock is proven wrong and the window's UPPER bound is used: "the newest phase message was sent
--     the moment it arrived". That is true for every phase-change message (the server sends one at
--     each phase start, so the countdown then starts at the phase's full length, short only by the
--     message's travel time); it is the only message kind most devices ever see. (The lower bound
--     would claim the phase is already over and lock the wardrobe for the whole of Styling on a
--     device whose clock runs ahead.)
--   * A message whose window does not overlap the kept one (the device clock jumped, or the server
--     re-planned a late phase) replaces the kept window with its own: the newest fact wins.
--   * The remaining time is phaseEnds - (deviceNow - offset), clamped to [0, phaseDuration]. It is
--     never negative and never more than the phase can last, whatever the clock says.
-- So a device clock that is wrong by minutes, either way, still shows a countdown that starts at the
-- phase's full length when a phase-change message arrives, and counts down at the device clock's rate.
-- What it cannot correct: a device clock wrong by less than the phase's length on a device that
-- joined mid-phase (0 then lies inside the window, so the device clock is believed). The short
-- phases (Results 20 s, Intermission 10 s, ThemeReveal 10 s) narrow the window to their length, so
-- an error of more than about 10 s is corrected within one round.
-- Pure logic: the clock reading is passed in; no Roblox-specific interface is used.
--
-- PUBLIC API
--   RoundPhaseCountdownEstimator.new() -> estimator
--   estimator:noteRoundStateReceived(roundState, deviceNowUnixMilliseconds)
--     roundState: { roundPhase, phaseEndsAtUnixMilliseconds } (as RoundStateChangedMessageReader
--     reads it). Ignored when the phase is unknown or either number is not finite.
--   estimator:readDeviceClockAheadOfServerMilliseconds() -> number   (0 before any message)
--   estimator:readRemainingSecondsInPhase(roundState, deviceNowUnixMilliseconds) -> number?
--     Fractional seconds in [0, phase duration]; nil for an unknown phase or a non-finite number.

local ThemedRoundProtocol = require("../shared/ThemedRoundProtocol")

local RoundPhaseCountdownEstimator = {}
RoundPhaseCountdownEstimator.__index = RoundPhaseCountdownEstimator

local function isFiniteNumber(candidate: any): boolean
	return type(candidate) == "number" and candidate == candidate and math.abs(candidate) ~= math.huge
end

local function readPhaseDurationMilliseconds(roundState): number?
	if type(roundState) ~= "table" or not ThemedRoundProtocol.isKnownRoundPhase(roundState.roundPhase) then
		return nil
	end
	if not isFiniteNumber(roundState.phaseEndsAtUnixMilliseconds) then
		return nil
	end
	return ThemedRoundProtocol.PHASE_DURATION_SECONDS_BY_ROUND_PHASE[roundState.roundPhase] * 1000
end

function RoundPhaseCountdownEstimator.new()
	return setmetatable({
		-- The kept window for "device clock ahead of server", in milliseconds; nil before any message.
		smallestPossibleAheadMilliseconds = nil :: number?,
		largestPossibleAheadMilliseconds = nil :: number?,
	}, RoundPhaseCountdownEstimator)
end

function RoundPhaseCountdownEstimator:noteRoundStateReceived(roundState, deviceNowUnixMilliseconds: number)
	local phaseDurationMilliseconds = readPhaseDurationMilliseconds(roundState)
	if phaseDurationMilliseconds == nil or not isFiniteNumber(deviceNowUnixMilliseconds) then
		return
	end
	local messageSmallest = deviceNowUnixMilliseconds - roundState.phaseEndsAtUnixMilliseconds
	local messageLargest = messageSmallest + phaseDurationMilliseconds
	local keptSmallest, keptLargest = self.smallestPossibleAheadMilliseconds, self.largestPossibleAheadMilliseconds
	if keptSmallest == nil or keptLargest == nil or messageSmallest > keptLargest or messageLargest < keptSmallest then
		self.smallestPossibleAheadMilliseconds = messageSmallest
		self.largestPossibleAheadMilliseconds = messageLargest
		return
	end
	self.smallestPossibleAheadMilliseconds = math.max(keptSmallest, messageSmallest)
	self.largestPossibleAheadMilliseconds = math.min(keptLargest, messageLargest)
end

function RoundPhaseCountdownEstimator:readDeviceClockAheadOfServerMilliseconds(): number
	local keptSmallest, keptLargest = self.smallestPossibleAheadMilliseconds, self.largestPossibleAheadMilliseconds
	if keptSmallest == nil or keptLargest == nil then
		return 0
	end
	if keptSmallest <= 0 and 0 <= keptLargest then
		return 0
	end
	return keptLargest
end

function RoundPhaseCountdownEstimator:readRemainingSecondsInPhase(
	roundState,
	deviceNowUnixMilliseconds: number
): number?
	local phaseDurationMilliseconds = readPhaseDurationMilliseconds(roundState)
	if phaseDurationMilliseconds == nil or not isFiniteNumber(deviceNowUnixMilliseconds) then
		return nil
	end
	local estimatedServerNow = deviceNowUnixMilliseconds - self:readDeviceClockAheadOfServerMilliseconds()
	local remainingMilliseconds = roundState.phaseEndsAtUnixMilliseconds - estimatedServerNow
	return math.clamp(remainingMilliseconds, 0, phaseDurationMilliseconds) / 1000
end

return RoundPhaseCountdownEstimator
