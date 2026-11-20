-- LobbyDanceLoopTimePositionCalculator (development spec v1.3 §2.8 "A synced player performs the
-- target's dance, in time with the target"; LobbyDanceCoordinator's `danceStartedAtUnixMilliseconds`):
-- where in its loop a lobby dance must be, right now, so that every character dancing it since the
-- same start moment shows the same pose. A follower carries its leader's start moment (the
-- coordinator's registry invariant), so leader and follower get the same position.
--
-- 🔴 The length of a dance's loop is not in DanceCatalog: the server learns it only from the engine
-- (AnimationTrack.Length, "0 until the animation has fully loaded"). Decision for a length that is
-- not known (yet): the position is UNKNOWN (nil). The caller then starts the dance at the start of
-- its loop at once, so the character dances without waiting, waits up to
-- LOOP_LENGTH_WAIT_TIMEOUT_SECONDS for the length, and jumps to the position computed at THAT
-- moment. If the length never becomes known, the dance stays where it started (not in time) and
-- a warning is logged. Nothing is guessed: a wrong guessed length would put a follower visibly out
-- of time with no way to notice.
--
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   LobbyDanceLoopTimePositionCalculator.LOOP_LENGTH_WAIT_TIMEOUT_SECONDS = 10
--   LobbyDanceLoopTimePositionCalculator.computeLoopTimePositionSeconds(
--       danceStartedAtUnixMilliseconds, currentUnixMilliseconds, danceLoopLengthSeconds) -> number?
--     nil when the loop length is not a finite number above 0, or when either moment is not a
--     finite number. Otherwise (elapsed seconds since the start moment) modulo the loop length,
--     always in [0, loop length). A start moment in the future (a clock that stepped back) counts
--     as just started: 0.

local LobbyDanceLoopTimePositionCalculator = {}

LobbyDanceLoopTimePositionCalculator.LOOP_LENGTH_WAIT_TIMEOUT_SECONDS = 10

local function isFiniteNumber(candidateNumber: any): boolean
	return type(candidateNumber) == "number"
		and candidateNumber == candidateNumber
		and candidateNumber ~= math.huge
		and candidateNumber ~= -math.huge
end

function LobbyDanceLoopTimePositionCalculator.computeLoopTimePositionSeconds(
	danceStartedAtUnixMilliseconds: any,
	currentUnixMilliseconds: any,
	danceLoopLengthSeconds: any
): number?
	if not isFiniteNumber(danceLoopLengthSeconds) or danceLoopLengthSeconds <= 0 then
		return nil
	end
	if not isFiniteNumber(danceStartedAtUnixMilliseconds) or not isFiniteNumber(currentUnixMilliseconds) then
		return nil
	end
	local elapsedSeconds = math.max(0, currentUnixMilliseconds - danceStartedAtUnixMilliseconds) / 1000
	local loopTimePositionSeconds = elapsedSeconds % danceLoopLengthSeconds
	-- Floating-point modulo (a - floor(a / b) * b) can land a hair below 0 or exactly on the
	-- length; both are the loop's start, the same pose.
	if loopTimePositionSeconds < 0 or loopTimePositionSeconds >= danceLoopLengthSeconds then
		return 0
	end
	return loopTimePositionSeconds
end

return table.freeze(LobbyDanceLoopTimePositionCalculator)
