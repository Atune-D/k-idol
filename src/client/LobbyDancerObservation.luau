-- LobbyDancerObservation (development spec §2.8, README "What the Phase 2 device screens can rely on"):
-- tells, from what the device can see, which dance each player is performing in the lobby.
--
-- The server sends no message about who is dancing in the lobby, and no channel may be added. What
-- the device CAN see: every character's playing animation tracks (Animator replication; the server
-- plays a lobby or stage dance as the only Action-priority track). So a player counts as "seen
-- dancing" a dance when one of their character's playing animation ids is the animation of a
-- DanceCatalog dance. A player seen dancing during Showcase who is a participant of the round is on
-- stage, not in the lobby (§2.4), so they are NOT counted as dancing in the lobby.
-- This is a hint for the screen only: the server alone decides (RequestSyncDanceWithPlayer answers
-- TargetNotDancing when the hint is wrong).
--
-- Animation ids are compared by their asset number, so "rbxassetid://507771019" and an engine form
-- such as "http://www.roblox.com/asset/?id=507771019" are the same dance. An id with no number, or a
-- catalog dance without an animation id, matches nothing.
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   LobbyDancerObservation.readAnimationAssetNumber(animationId: any) -> string?   the digits, or nil
--   LobbyDancerObservation.findDanceIdForPlayingAnimationIds(playingAnimationIds, danceCatalogDances)
--     -> string?   the first catalog dance (catalog order) whose animation is among the ids
--   LobbyDancerObservation.findLobbyDanceIdOfPlayer(observedPlayer, roundObservation, danceCatalogDances)
--     -> string?
--     observedPlayer = { playerUserId, playingAnimationIds = { string } }
--     roundObservation = { roundPhase: string?, participantUserIds: { number } }

local LobbyDancerObservation = {}

function LobbyDancerObservation.readAnimationAssetNumber(animationId: any): string?
	if type(animationId) ~= "string" then
		return nil
	end
	return string.match(animationId, "(%d+)%D*$")
end

function LobbyDancerObservation.findDanceIdForPlayingAnimationIds(playingAnimationIds: { string }, danceCatalogDances)
	local playingAssetNumberSet = {}
	for _, playingAnimationId in playingAnimationIds do
		local assetNumber = LobbyDancerObservation.readAnimationAssetNumber(playingAnimationId)
		if assetNumber ~= nil then
			playingAssetNumberSet[assetNumber] = true
		end
	end
	for _, dance in danceCatalogDances do
		local danceAssetNumber = LobbyDancerObservation.readAnimationAssetNumber(dance.danceAnimationAssetId)
		if danceAssetNumber ~= nil and playingAssetNumberSet[danceAssetNumber] then
			return dance.danceId
		end
	end
	return nil
end

function LobbyDancerObservation.findLobbyDanceIdOfPlayer(observedPlayer, roundObservation, danceCatalogDances): string?
	local isOnStage = roundObservation.roundPhase == "Showcase"
		and table.find(roundObservation.participantUserIds, observedPlayer.playerUserId) ~= nil
	if isOnStage then
		return nil
	end
	return LobbyDancerObservation.findDanceIdForPlayingAnimationIds(
		observedPlayer.playingAnimationIds,
		danceCatalogDances
	)
end

return table.freeze(LobbyDancerObservation)
