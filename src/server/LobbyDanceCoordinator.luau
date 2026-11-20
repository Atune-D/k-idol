-- LobbyDanceCoordinator, the rule part (development spec v1.3 §0.2 "Lobby and dance floor",
-- §2.8 the last three rows and the sync paragraph, §2.13, §3.4): decides who dances what in the
-- lobby, since when, and whom they follow. No animation is played here: the server wiring
-- subscribes to the state changes and plays or stops animations, and a device that has just
-- joined reads every dancer's state once.
--
-- Calls no Roblox-specific interface. Everything external is injected (see `new`).
--
-- Rules it enforces:
--   * A player dances their own dance only when they own it (`ownedDanceIds` of the loaded save)
--     and the dance is in the dance catalog.
--   * 🔴 A synced player (a FOLLOWER) performs the dance of the player they tapped (the TARGET)
--     WITHOUT owning it, with the target's start moment, so devices play both in time, until
--     either of them stops (§2.8).
--   * Open cases, decided conservatively:
--     - Syncing with oneself is refused `TargetNotDancing`, also while dancing.
--     - Syncing with a player who is themselves a follower is accepted: the requester follows
--       THAT player (followedPlayerUserId = the tapped target), with the same dance and start
--       moment the target shows. When the target stops or changes, the requester's lobby dance
--       ends, and so on down the chain ("until either of them stops").
--     - Syncing with a player who follows the requester, directly or through a chain, is
--       refused `TargetNotDancing` (it would end the target's own dance and make a cycle).
--     - Syncing with a target that is on stage, whose save is not loaded (leaving), or who
--       follows (through any chain) such a player is refused `TargetNotDancing`, even when the
--       wiring has not yet called endLobbyDanceOfPlayerGoingOnStage or forgetPlayer.
--     - Syncing with the player one already follows is accepted and changes nothing.
--     - 🔴 Followers stop (their lobby dance ends, they do NOT switch) whenever the lobby dance
--       state of the player they follow changes in any way: another dance, stopping, starting
--       to follow someone, leaving the server, or going on stage. This repeats down the chain.
--     - Starting the dance one is already dancing on one's own is accepted and changes nothing
--       (same start moment, followers keep following). Starting any dance while following
--       someone ends the follow and starts one's own dance now.
--     - Joining a round does NOT end a lobby dance: §2.8 refuses dancing only "on stage". A
--       Styling participant may dance in the lobby. Going on stage (Showcase) ends it; the server
--       wiring calls endLobbyDanceOfPlayerGoingOnStage for each participant then.
--     - Stopping is never refused for an unloaded save (§2.8 "Always"): a leaving dancer can
--       still stop.
--     - A player who leaves the server is forgotten (forgetPlayer); their followers stop.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (the server wiring is written from this)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- LobbyDanceCoordinator.START_DANCE_IN_LOBBY_REJECTION_REASONS
--   { DanceNotOwned, NotAllowedDuringRound, SaveDataNotLoaded, TooManyRequests }, frozen.
-- LobbyDanceCoordinator.SYNC_DANCE_WITH_PLAYER_REJECTION_REASONS
--   { TargetNotDancing, NotAllowedDuringRound, SaveDataNotLoaded, TooManyRequests }, frozen.
-- LobbyDanceCoordinator.STOP_DANCE_IN_LOBBY_REJECTION_REASONS
--   { TooManyRequests }, frozen.
-- LobbyDanceCoordinator.MAX_DANCE_ID_LENGTH (= 64)   a longer danceId is never looked at.
--
-- LobbyDanceCoordinator.new(dependencies) -> coordinator
--   dependencies = {
--     playerSaveDataKeeper: the PlayerSaveDataKeeper (isPlayerSaveDataLoaded and
--         readPlayerSaveDataCopy are used; nothing is ever written to a save here),
--     playerRequestRateLimiter: the PlayerRequestRateLimiter (admitOrRefusePlayerRequest),
--     danceCatalog: { findDanceByDanceId: (danceId: string) -> Dance? }   called with a dot;
--         normally src/shared/DanceCatalog.luau,
--     clock: { getCurrentUnixMilliseconds: (self) -> number }   the server's clock; the start
--         moments handed to devices are read from it,
--     isPlayerOnThemedRoundStage: (playerUserId: number) -> boolean,
--         Must answer `true` exactly when the player is a participant of the CURRENT themed round
--         AND that round's `roundPhase` is `Showcase` (§2.4: participants are on stage for the
--         whole Showcase); `false` otherwise (not a participant, or any other phase, including
--         Styling). Normally answered by the themed-round referee. Any answer other than `false`
--         is treated as "on stage", so a faulty answer refuses rather than allows. If it raises,
--         the error reaches the caller (a wiring bug, not device input).
--     logger: { logWarning: (self, message: string) -> () },
--   }
--   Raises when a dependency is missing.
--
-- Requests. `playerUserId` is the server's own id of the sending player (trusted); every other
-- argument is whatever the device sent: ANY value is accepted and nothing in it makes these
-- raise. Each answer is a new table: { isAccepted = true } or
-- { isAccepted = false, rejectionReason = <one of that request's reasons> }. Checks run in the
-- order listed; the first that fails answers. Every request first asks the rate limiter on its
-- own channel (0.5 s, §2.13) and, when refused, answers its rejectionReason (`TooManyRequests`)
-- without looking at anything else.
--
-- coordinator:answerStartDanceInLobbyRequest(playerUserId, untrustedDanceId) -> answer
--   rate limit; save not loaded -> SaveDataNotLoaded; on stage -> NotAllowedDuringRound; the
--   save is no longer readable after the stage question (the player started leaving) ->
--   SaveDataNotLoaded; danceId not a string of at most MAX_DANCE_ID_LENGTH, not in the catalog, or not in
--   ownedDanceIds -> DanceNotOwned. Accepted: the player dances that dance from now, following
--   nobody (no change if they already dance it on their own).
-- coordinator:answerSyncDanceWithPlayerRequest(playerUserId, untrustedTargetPlayerUserId) -> answer
--   rate limit; save not loaded -> SaveDataNotLoaded; the requester on stage ->
--   NotAllowedDuringRound; the target is not a number, is not dancing in the lobby, or the
--   target or any player up its follow chain is the requester, has a save that is not loaded,
--   or is on stage -> TargetNotDancing. Accepted: the requester performs the target's dance with
--   the target's start moment, `followedPlayerUserId` = the target. Owning it is not needed.
-- coordinator:answerStopDanceInLobbyRequest(playerUserId) -> answer
--   rate limit; otherwise always accepted (§2.8), also when not dancing or not loaded (then
--   nothing changes). Ends the player's lobby dance and their followers' (down the chain).
--
-- Server events (called by the server wiring, never by a device):
-- coordinator:endLobbyDanceOfPlayerGoingOnStage(playerUserId)
--   Call for each participant when `Showcase` starts. Ends their lobby dance and their
--   followers'. Doing nothing when they are not dancing.
-- coordinator:forgetPlayer(playerUserId)
--   Call when a player leaves the server. Ends their lobby dance and their followers', and
--   drops everything held for them.
--
-- Reads:
-- coordinator:readLobbyDanceStateOfPlayer(playerUserId) -> LobbyDanceState?
--   nil when the player is not dancing in the lobby. Otherwise a frozen table
--   { dancingPlayerUserId, danceId, danceStartedAtUnixMilliseconds, followedPlayerUserId? }:
--   followedPlayerUserId is nil for a player dancing their own dance, else the player they
--   synced with (who may follow someone too). A device plays `danceId`
--   at offset (server now - danceStartedAtUnixMilliseconds) to stay in time.
-- coordinator:readEveryLobbyDancerState() -> { LobbyDanceState }
--   For a device that has just joined: a new frozen list of every dancer's state, sorted by
--   dancingPlayerUserId.
-- coordinator:subscribeToLobbyDanceStateChanged(listener(playerUserId, lobbyDanceStateOrNil)) -> unsubscribe
--   Called synchronously for every change of a player's lobby dance state, with the new frozen
--   state, or nil when the player stopped dancing in the lobby (stopped, the followed player
--   changed, went on stage, left). Not called when nothing changed. When one request changes
--   several players (a followed player and their followers), every change is applied first and
--   listeners are then told the followed player's change, then each follower's (breadth-first
--   down the chain, ascending id within a level). A listener that raises is logged as a warning
--   and does not disturb the others; a listener may unsubscribe itself (or another) while being
--   told without making any other listener miss that change. A listener MAY call a request or
--   server-event method while being told: that change applies at once and is told to every
--   listener after the changes already due, so every listener hears every change once, in the
--   order applied, and replaying the events reproduces readEveryLobbyDancerState.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local LobbyDancerStateRegistry = require("./LobbyDancerStateRegistry")
local RemoteNames = require("../shared/RemoteNames")

local LobbyDanceCoordinator = {}
LobbyDanceCoordinator.__index = LobbyDanceCoordinator

LobbyDanceCoordinator.START_DANCE_IN_LOBBY_REJECTION_REASONS = table.freeze({
	DanceNotOwned = "DanceNotOwned",
	NotAllowedDuringRound = "NotAllowedDuringRound",
	SaveDataNotLoaded = "SaveDataNotLoaded",
	TooManyRequests = "TooManyRequests",
})

LobbyDanceCoordinator.SYNC_DANCE_WITH_PLAYER_REJECTION_REASONS = table.freeze({
	TargetNotDancing = "TargetNotDancing",
	NotAllowedDuringRound = "NotAllowedDuringRound",
	SaveDataNotLoaded = "SaveDataNotLoaded",
	TooManyRequests = "TooManyRequests",
})

LobbyDanceCoordinator.STOP_DANCE_IN_LOBBY_REJECTION_REASONS = table.freeze({
	TooManyRequests = "TooManyRequests",
})

-- Every catalog danceId is far shorter; a longer string is refused before any lookup.
LobbyDanceCoordinator.MAX_DANCE_ID_LENGTH = 64

local REMOTE_CHANNEL_NAMES = RemoteNames.REMOTE_CHANNEL_NAMES

function LobbyDanceCoordinator.new(dependencies)
	for _, requiredDependencyName in
		{
			"playerSaveDataKeeper",
			"playerRequestRateLimiter",
			"danceCatalog",
			"clock",
			"isPlayerOnThemedRoundStage",
			"logger",
		}
	do
		if dependencies[requiredDependencyName] == nil then
			error("LobbyDanceCoordinator.new: missing dependency " .. requiredDependencyName, 2)
		end
	end
	return setmetatable({
		playerSaveDataKeeper = dependencies.playerSaveDataKeeper,
		playerRequestRateLimiter = dependencies.playerRequestRateLimiter,
		danceCatalog = dependencies.danceCatalog,
		clock = dependencies.clock,
		isPlayerOnThemedRoundStage = dependencies.isPlayerOnThemedRoundStage,
		lobbyDancerStateRegistry = LobbyDancerStateRegistry.new(dependencies.logger),
	}, LobbyDanceCoordinator)
end

local function acceptLobbyDanceRequest()
	return { isAccepted = true }
end

local function rejectLobbyDanceRequest(rejectionReason: string)
	return { isAccepted = false, rejectionReason = rejectionReason }
end

-- Asks the rate limiter, which RECORDS an admitted request. Returns its rejection reason, or nil
-- when the request is admitted.
local function admitRequestOrReadRateLimitRejectionReason(
	self,
	playerUserId: number,
	remoteChannelName: string
): string?
	local rateLimitDecision = self.playerRequestRateLimiter:admitOrRefusePlayerRequest(playerUserId, remoteChannelName)
	if rateLimitDecision.isRequestAllowed then
		return nil
	end
	return rateLimitDecision.rejectionReason
end

local function isPlayerOnStage(self, playerUserId: number): boolean
	return self.isPlayerOnThemedRoundStage(playerUserId) ~= false
end

local function isCatalogDanceInOwnedDanceIds(self, untrustedDanceId: any, ownedDanceIds: { string }): boolean
	if type(untrustedDanceId) ~= "string" or #untrustedDanceId > LobbyDanceCoordinator.MAX_DANCE_ID_LENGTH then
		return false
	end
	if self.danceCatalog.findDanceByDanceId(untrustedDanceId) == nil then
		return false
	end
	return table.find(ownedDanceIds, untrustedDanceId) ~= nil
end

function LobbyDanceCoordinator:answerStartDanceInLobbyRequest(playerUserId: number, untrustedDanceId: any)
	local rateLimitRejectionReason =
		admitRequestOrReadRateLimitRejectionReason(self, playerUserId, REMOTE_CHANNEL_NAMES.RequestStartDanceInLobby)
	if rateLimitRejectionReason ~= nil then
		return rejectLobbyDanceRequest(rateLimitRejectionReason)
	end
	if not self.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId) then
		return rejectLobbyDanceRequest(LobbyDanceCoordinator.START_DANCE_IN_LOBBY_REJECTION_REASONS.SaveDataNotLoaded)
	end
	if isPlayerOnStage(self, playerUserId) then
		return rejectLobbyDanceRequest(
			LobbyDanceCoordinator.START_DANCE_IN_LOBBY_REJECTION_REASONS.NotAllowedDuringRound
		)
	end
	-- Read after the injected stage question, which may have let the player start leaving.
	local playerSaveDataCopy = self.playerSaveDataKeeper:readPlayerSaveDataCopy(playerUserId)
	if playerSaveDataCopy == nil then
		return rejectLobbyDanceRequest(LobbyDanceCoordinator.START_DANCE_IN_LOBBY_REJECTION_REASONS.SaveDataNotLoaded)
	end
	if not isCatalogDanceInOwnedDanceIds(self, untrustedDanceId, playerSaveDataCopy.ownedDanceIds) then
		return rejectLobbyDanceRequest(LobbyDanceCoordinator.START_DANCE_IN_LOBBY_REJECTION_REASONS.DanceNotOwned)
	end
	local ownedDanceId: string = untrustedDanceId
	local currentLobbyDanceState = self.lobbyDancerStateRegistry:readLobbyDanceStateOfPlayer(playerUserId)
	local isAlreadyDancingItOnOwn = currentLobbyDanceState ~= nil
		and currentLobbyDanceState.followedPlayerUserId == nil
		and currentLobbyDanceState.danceId == ownedDanceId
	if not isAlreadyDancingItOnOwn then
		self.lobbyDancerStateRegistry:replaceLobbyDanceStateOfPlayer(
			playerUserId,
			LobbyDancerStateRegistry.createLobbyDanceState(
				playerUserId,
				ownedDanceId,
				self.clock:getCurrentUnixMilliseconds(),
				nil
			)
		)
	end
	return acceptLobbyDanceRequest()
end

-- True when the target dances in the lobby and the requester can follow it: neither the target
-- nor any player it follows (up the chain) is the requester, has stopped being loaded (leaving),
-- or is on stage. The chain is finite and acyclic (registry invariant).
local function canRequesterFollowDancingTarget(self, requesterPlayerUserId: number, targetLobbyDanceState): boolean
	local chainLobbyDanceState = targetLobbyDanceState
	while chainLobbyDanceState ~= nil do
		local chainPlayerUserId = chainLobbyDanceState.dancingPlayerUserId
		if chainPlayerUserId == requesterPlayerUserId then
			return false
		end
		if not self.playerSaveDataKeeper:isPlayerSaveDataLoaded(chainPlayerUserId) then
			return false
		end
		if isPlayerOnStage(self, chainPlayerUserId) then
			return false
		end
		chainLobbyDanceState =
			self.lobbyDancerStateRegistry:readLobbyDanceStateOfPlayer(chainLobbyDanceState.followedPlayerUserId)
	end
	return true
end

function LobbyDanceCoordinator:answerSyncDanceWithPlayerRequest(playerUserId: number, untrustedTargetPlayerUserId: any)
	local rateLimitRejectionReason =
		admitRequestOrReadRateLimitRejectionReason(self, playerUserId, REMOTE_CHANNEL_NAMES.RequestSyncDanceWithPlayer)
	if rateLimitRejectionReason ~= nil then
		return rejectLobbyDanceRequest(rateLimitRejectionReason)
	end
	if not self.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId) then
		return rejectLobbyDanceRequest(LobbyDanceCoordinator.SYNC_DANCE_WITH_PLAYER_REJECTION_REASONS.SaveDataNotLoaded)
	end
	if isPlayerOnStage(self, playerUserId) then
		return rejectLobbyDanceRequest(
			LobbyDanceCoordinator.SYNC_DANCE_WITH_PLAYER_REJECTION_REASONS.NotAllowedDuringRound
		)
	end
	-- The registry reads only numbers that are not NaN; anything else is "not dancing".
	local targetLobbyDanceState = self.lobbyDancerStateRegistry:readLobbyDanceStateOfPlayer(untrustedTargetPlayerUserId)
	if
		targetLobbyDanceState == nil or not canRequesterFollowDancingTarget(self, playerUserId, targetLobbyDanceState)
	then
		return rejectLobbyDanceRequest(LobbyDanceCoordinator.SYNC_DANCE_WITH_PLAYER_REJECTION_REASONS.TargetNotDancing)
	end
	-- A follower always carries the dance and start moment of the player it follows (registry
	-- invariant), so the target's state holds the dance being shown, in time.
	self.lobbyDancerStateRegistry:replaceLobbyDanceStateOfPlayer(
		playerUserId,
		LobbyDancerStateRegistry.createLobbyDanceState(
			playerUserId,
			targetLobbyDanceState.danceId,
			targetLobbyDanceState.danceStartedAtUnixMilliseconds,
			targetLobbyDanceState.dancingPlayerUserId
		)
	)
	return acceptLobbyDanceRequest()
end

function LobbyDanceCoordinator:answerStopDanceInLobbyRequest(playerUserId: number)
	local rateLimitRejectionReason =
		admitRequestOrReadRateLimitRejectionReason(self, playerUserId, REMOTE_CHANNEL_NAMES.RequestStopDanceInLobby)
	if rateLimitRejectionReason ~= nil then
		return rejectLobbyDanceRequest(rateLimitRejectionReason)
	end
	self.lobbyDancerStateRegistry:replaceLobbyDanceStateOfPlayer(playerUserId, nil)
	return acceptLobbyDanceRequest()
end

function LobbyDanceCoordinator:endLobbyDanceOfPlayerGoingOnStage(playerUserId: number)
	self.lobbyDancerStateRegistry:replaceLobbyDanceStateOfPlayer(playerUserId, nil)
end

function LobbyDanceCoordinator:forgetPlayer(playerUserId: number)
	-- The lobby dance state is everything the coordinator holds for a player.
	self.lobbyDancerStateRegistry:replaceLobbyDanceStateOfPlayer(playerUserId, nil)
end

function LobbyDanceCoordinator:readLobbyDanceStateOfPlayer(playerUserId: number)
	return self.lobbyDancerStateRegistry:readLobbyDanceStateOfPlayer(playerUserId)
end

function LobbyDanceCoordinator:readEveryLobbyDancerState()
	return self.lobbyDancerStateRegistry:readEveryLobbyDancerState()
end

function LobbyDanceCoordinator:subscribeToLobbyDanceStateChanged(listener)
	return self.lobbyDancerStateRegistry:subscribeToLobbyDanceStateChanged(listener)
end

return LobbyDanceCoordinator
