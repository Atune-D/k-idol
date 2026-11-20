-- RobloxCharacterDancePlayer (development spec v1.3 §2.4, §2.8, §3.8): plays a dance animation on a
-- character from the server, looping, so every device sees it, and stops it again. A lobby dance
-- is played IN TIME with its start moment (LobbyDanceCoordinator's danceStartedAtUnixMilliseconds),
-- so a follower and its leader show the same pose.
--
-- PUBLIC API
--   RobloxCharacterDancePlayer.startLoopingDance(character, danceAnimationAssetId) -> AnimationTrack
--     Loads the animation on the character's Animator (child of its Humanoid) with priority Action
--     (above the default idle and walk animations) and plays it looped from the start of its loop.
--     Raises when the character has no Humanoid or Animator.
--   RobloxCharacterDancePlayer.startLoopingDanceInTime(character, danceAnimationAssetId,
--       danceStartedAtUnixMilliseconds, clock, logger) -> AnimationTrack
--     The same, then moves the track to the loop position LobbyDanceLoopTimePositionCalculator
--     gives for this moment. The loop length is known only once the engine has loaded the
--     animation (Length is 0 before): until then the track plays from the start of its loop, and
--     a separate thread (never yielding the caller) waits up to
--     LobbyDanceLoopTimePositionCalculator.LOOP_LENGTH_WAIT_TIMEOUT_SECONDS for the length, then
--     jumps to the position computed at that moment and logs it ("aligned"); if the track was
--     stopped meanwhile it does nothing; if the length never arrives it logs a warning and the
--     dance stays where it is. clock: { getCurrentUnixMilliseconds } (the coordinator's clock).
--   RobloxCharacterDancePlayer.stopDance(animationTrack?)   stops and destroys it; nil does nothing.
--
-- Roblox API used, read in the official documentation while writing this file:
--   Animation.AnimationId           https://create.roblox.com/docs/reference/engine/classes/Animation
--   Animator:LoadAnimation          https://create.roblox.com/docs/reference/engine/classes/Animator
--     (Humanoid:LoadAnimation is deprecated in its favour, Humanoid page; the Animator page:
--     "All replication of playing AnimationTracks is handled through the Animator instance")
--   AnimationTrack.Looped, .Priority, :Play, :Stop, .IsPlaying, .Length ("will return 0 until the
--     animation has fully loaded"), .TimePosition ("Can be set to make the track jump to a
--     specific moment ... the AnimationTrack must be playing to do so"; tagged NotReplicated)
--                                   https://create.roblox.com/docs/reference/engine/classes/AnimationTrack
--   Enum.AnimationPriority.Action   https://create.roblox.com/docs/reference/engine/enums/AnimationPriority
--   Instance:FindFirstChildOfClass, :Destroy  https://create.roblox.com/docs/reference/engine/classes/Instance
--   task.spawn, task.wait, os.clock  https://create.roblox.com/docs/reference/engine/libraries/task
-- Verified in Studio 0.748 on 2026-11-19 (playtest): a track loaded and played on the server on
-- the player's character Animator (rbxassetid://507771019) was listed as playing by the client's
-- Animator:GetPlayingAnimationTracks, i.e. it replicates to devices.
-- Measured in Studio 0.748 on 2026-11-20 (playtest, rbxassetid://507776043 on the player's
-- character, played on the server): Length was 0 right after LoadAnimation and after Play, and
-- 2.0417 s 0.233 s later. The documentation tags TimePosition NotReplicated, but a TimePosition set
-- on the server DID reach the client: set to 1.867 at server ms ...371967, the client read 1.967 at
-- ...372100 (expected 2.000, 33 ms off) and the server 0.092 at ...372233 (expected 0.091).

local LobbyDanceLoopTimePositionCalculator = require("./LobbyDanceLoopTimePositionCalculator")

local RobloxCharacterDancePlayer = {}

function RobloxCharacterDancePlayer.startLoopingDance(character: Model, danceAnimationAssetId: string): AnimationTrack
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = if humanoid then humanoid:FindFirstChildOfClass("Animator") else nil
	if animator == nil then
		error("RobloxCharacterDancePlayer: the character has no Humanoid with an Animator")
	end
	local danceAnimation = Instance.new("Animation")
	danceAnimation.AnimationId = danceAnimationAssetId
	local danceTrack = animator:LoadAnimation(danceAnimation)
	danceTrack.Priority = Enum.AnimationPriority.Action
	danceTrack.Looped = true
	danceTrack:Play()
	return danceTrack
end

local function alignDanceTrackWithStartMomentOnceLengthIsKnown(
	danceTrack: AnimationTrack,
	danceAnimationAssetId: string,
	danceStartedAtUnixMilliseconds: number,
	clock,
	logger
)
	local waitStartedAtClock = os.clock()
	while
		danceTrack.Length <= 0
		and os.clock() - waitStartedAtClock < LobbyDanceLoopTimePositionCalculator.LOOP_LENGTH_WAIT_TIMEOUT_SECONDS
	do
		task.wait()
	end
	if not danceTrack.IsPlaying then
		return
	end
	local loopTimePositionSeconds = LobbyDanceLoopTimePositionCalculator.computeLoopTimePositionSeconds(
		danceStartedAtUnixMilliseconds,
		clock:getCurrentUnixMilliseconds(),
		danceTrack.Length
	)
	if loopTimePositionSeconds == nil then
		logger:logWarning(
			string.format(
				"RobloxCharacterDancePlayer: the loop length of %s did not become known within %d s; the dance is not in time",
				danceAnimationAssetId,
				LobbyDanceLoopTimePositionCalculator.LOOP_LENGTH_WAIT_TIMEOUT_SECONDS
			)
		)
		return
	end
	danceTrack.TimePosition = loopTimePositionSeconds
	logger:logInformation(
		string.format(
			"RobloxCharacterDancePlayer: %s aligned to %.3f s of its %.3f s loop (start moment %d ms, after waiting %.3f s for the length)",
			danceAnimationAssetId,
			loopTimePositionSeconds,
			danceTrack.Length,
			danceStartedAtUnixMilliseconds,
			os.clock() - waitStartedAtClock
		)
	)
end

function RobloxCharacterDancePlayer.startLoopingDanceInTime(
	character: Model,
	danceAnimationAssetId: string,
	danceStartedAtUnixMilliseconds: number,
	clock,
	logger
): AnimationTrack
	local danceTrack = RobloxCharacterDancePlayer.startLoopingDance(character, danceAnimationAssetId)
	task.spawn(
		alignDanceTrackWithStartMomentOnceLengthIsKnown,
		danceTrack,
		danceAnimationAssetId,
		danceStartedAtUnixMilliseconds,
		clock,
		logger
	)
	return danceTrack
end

function RobloxCharacterDancePlayer.stopDance(danceTrack: AnimationTrack?)
	if danceTrack == nil then
		return
	end
	danceTrack:Stop()
	danceTrack:Destroy()
end

return RobloxCharacterDancePlayer
