-- RobloxLobbyDancerReader (development spec §2.8, README "What the Phase 2 device screens can rely on"):
-- reads, from the characters the device can see, which animations every player's character is
-- playing, and hands them to LobbyDancerObservation (pure) to tell who dances what in the lobby. The
-- server plays lobby and stage dances on the server; Animator replication shows them on every device.
-- Only reads: nothing on any character is changed.
--
-- PUBLIC API
--   RobloxLobbyDancerReader.readLobbyDancers(localPlayer, roundObservation, danceCatalogDances)
--     -> { localLobbyDanceId: string?, otherPlayers = { { playerUserId, playerDisplayName, lobbyDanceId? } } }
--     roundObservation = { roundPhase?, participantUserIds }   (from the round session's state)
--     Other players are in Players:GetPlayers() order.
--
-- Roblox API used, read in the official documentation (create.roblox.com/docs/reference/engine/...):
--   Players:GetPlayers() ("A table containing all the players in the server")   classes/Players
--   Player.Character, .UserId, .DisplayName                                      classes/Player
--   Instance:FindFirstChildOfClass("Humanoid" / "Animator")                       classes/Instance
--   Animator:GetPlayingAnimationTracks() ("Returns the list of currently active AnimationTracks";
--     "All replication of playing AnimationTracks is handled through the Animator instance")  classes/Animator
--   AnimationTrack.Animation (read only)                                          classes/AnimationTrack
--   Animation.AnimationId ("Asset ID of the animation", a ContentId)              classes/Animation

local Players = game:GetService("Players")

local LobbyDancerObservation = require("./LobbyDancerObservation")

local RobloxLobbyDancerReader = {}

local function readPlayingAnimationIds(player: Player): { string }
	local playingAnimationIds = {}
	local character = player.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	local animator = if humanoid ~= nil then humanoid:FindFirstChildOfClass("Animator") else nil
	if animator == nil then
		return playingAnimationIds
	end
	for _, animationTrack in animator:GetPlayingAnimationTracks() do
		local animation = animationTrack.Animation
		if animation ~= nil then
			table.insert(playingAnimationIds, tostring(animation.AnimationId))
		end
	end
	return playingAnimationIds
end

function RobloxLobbyDancerReader.readLobbyDancers(localPlayer: Player, roundObservation, danceCatalogDances)
	local lobbyDancers = { localLobbyDanceId = nil, otherPlayers = {} }
	for _, player in Players:GetPlayers() do
		local lobbyDanceId = LobbyDancerObservation.findLobbyDanceIdOfPlayer({
			playerUserId = player.UserId,
			playingAnimationIds = readPlayingAnimationIds(player),
		}, roundObservation, danceCatalogDances)
		if player == localPlayer then
			lobbyDancers.localLobbyDanceId = lobbyDanceId
		else
			table.insert(lobbyDancers.otherPlayers, {
				playerUserId = player.UserId,
				playerDisplayName = player.DisplayName,
				lobbyDanceId = lobbyDanceId,
			})
		end
	end
	return lobbyDancers
end

return table.freeze(RobloxLobbyDancerReader)
