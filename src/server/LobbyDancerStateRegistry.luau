-- LobbyDancerStateRegistry: the lobby dance state of every player dancing in the lobby
-- (development spec v1.3 §0.2 "Lobby and dance floor", §2.8), the follow rule, and the
-- state-changed listeners. Used only by LobbyDanceCoordinator, whose PUBLIC API block is the
-- contract for the server wiring; the request rules (rate limits, ownership, rounds) live there.
--
-- Pure logic: no Roblox-specific interface, no clock (moments are passed in).
--
-- State of one dancing player (a frozen table, replaced and never changed):
--   { dancingPlayerUserId: number, danceId: string, danceStartedAtUnixMilliseconds: number,
--     followedPlayerUserId: number? }
--   followedPlayerUserId is nil for a player dancing their own dance, and otherwise the id of
--   the player they synced with (the player they tapped). A follower's danceId and
--   danceStartedAtUnixMilliseconds are those of the player it follows, so devices play both in
--   time. A followed player may itself be a follower (a chain); the coordinator never lets a
--   player follow anyone who, directly or through a chain, follows them, so there are no cycles.
--
-- 🔴 The follow rule (§2.8 "until either of them stops"): ANY change of a player's state
-- (another dance, a new start moment, following someone, stopping) ends the lobby dance of every
-- player following them, and in turn of every player following those, down the whole chain.
-- Followers are not moved to the new dance and not re-timed: their sync was with the dance they
-- joined.
--
-- LobbyDancerStateRegistry.createLobbyDanceState(dancingPlayerUserId, danceId,
--     danceStartedAtUnixMilliseconds, followedPlayerUserId?) -> LobbyDanceState   (frozen)
-- registry = LobbyDancerStateRegistry.new(logger)
-- registry:readLobbyDanceStateOfPlayer(playerUserId: any) -> LobbyDanceState?
--   Accepts any value; nil for anything that is not a dancing player's id.
-- registry:readEveryLobbyDancerState() -> { LobbyDanceState }
--   A new frozen list of every dancer's state, sorted by dancingPlayerUserId.
-- registry:replaceLobbyDanceStateOfPlayer(playerUserId, newLobbyDanceStateOrNil)
--   nil ends the player's lobby dance. A state deeply equal to the current one changes nothing
--   and tells no listener. Otherwise every change is applied first (the player's, then the end
--   of each follower's, breadth-first down the chain, each level by ascending id), then listeners
--   are told about each change in that order.
-- registry:subscribeToLobbyDanceStateChanged(listener(playerUserId, lobbyDanceStateOrNil)) -> unsubscribe
--   Synchronous. A listener that raises is logged as a warning and does not disturb the
--   others. A listener that unsubscribes (itself or another) while being told does not make any
--   other listener miss the change in progress; an unsubscribed listener is told nothing later.
--   🔴 Re-entry: a listener may change the registry (through the coordinator) while being told.
--   That change is applied at once (reads see it) but its notifications are QUEUED behind every
--   notification already due, so each listener hears every change exactly once and in the order
--   the changes were applied; replaying the events always reproduces the registry. If the logger
--   itself raises, the queue is dropped (so later changes are told again normally) and that
--   error reaches the caller.

local PlayerSaveDataSchema = require("./PlayerSaveDataSchema")

local arePlainValuesDeeplyEqual = PlayerSaveDataSchema.arePlainValuesDeeplyEqual

export type LobbyDanceState = {
	dancingPlayerUserId: number,
	danceId: string,
	danceStartedAtUnixMilliseconds: number,
	followedPlayerUserId: number?,
}

type LobbyDanceStateChange = { playerUserId: number, lobbyDanceState: LobbyDanceState? }

local LobbyDancerStateRegistry = {}
LobbyDancerStateRegistry.__index = LobbyDancerStateRegistry

function LobbyDancerStateRegistry.createLobbyDanceState(
	dancingPlayerUserId: number,
	danceId: string,
	danceStartedAtUnixMilliseconds: number,
	followedPlayerUserId: number?
): LobbyDanceState
	return table.freeze({
		dancingPlayerUserId = dancingPlayerUserId,
		danceId = danceId,
		danceStartedAtUnixMilliseconds = danceStartedAtUnixMilliseconds,
		followedPlayerUserId = followedPlayerUserId,
	})
end

-- `logger` is LobbyDanceCoordinator's, which checks that it was given.
function LobbyDancerStateRegistry.new(logger)
	return setmetatable({
		logger = logger,
		lobbyDanceStateByPlayerUserId = {} :: { [number]: LobbyDanceState },
		stateChangedSubscriptions = {} :: { { listener: (number, LobbyDanceState?) -> () } },
		queuedLobbyDanceStateChanges = {} :: { LobbyDanceStateChange },
		isTellingListeners = false,
	}, LobbyDancerStateRegistry)
end

function LobbyDancerStateRegistry:readLobbyDanceStateOfPlayer(playerUserId: any): LobbyDanceState?
	if type(playerUserId) ~= "number" or playerUserId ~= playerUserId then
		return nil
	end
	return self.lobbyDanceStateByPlayerUserId[playerUserId]
end

function LobbyDancerStateRegistry:readEveryLobbyDancerState(): { LobbyDanceState }
	local everyLobbyDancerState = {}
	for _, lobbyDanceState in self.lobbyDanceStateByPlayerUserId do
		table.insert(everyLobbyDancerState, lobbyDanceState)
	end
	table.sort(everyLobbyDancerState, function(firstLobbyDanceState, secondLobbyDanceState)
		return firstLobbyDanceState.dancingPlayerUserId < secondLobbyDanceState.dancingPlayerUserId
	end)
	return table.freeze(everyLobbyDancerState)
end

local function listUserIdsOfPlayersFollowing(self, followedPlayerUserId: number): { number }
	local followingPlayerUserIds = {}
	for dancingPlayerUserId, lobbyDanceState in self.lobbyDanceStateByPlayerUserId do
		if lobbyDanceState.followedPlayerUserId == followedPlayerUserId then
			table.insert(followingPlayerUserIds, dancingPlayerUserId)
		end
	end
	table.sort(followingPlayerUserIds)
	return followingPlayerUserIds
end

local function tellListenersLobbyDanceStateChanged(self, lobbyDanceStateChange: LobbyDanceStateChange)
	for _, subscription in table.clone(self.stateChangedSubscriptions) do
		local didListenerSucceed, listenerError =
			pcall(subscription.listener, lobbyDanceStateChange.playerUserId, lobbyDanceStateChange.lobbyDanceState)
		if not didListenerSucceed then
			self.logger:logWarning(
				string.format(
					"LobbyDanceCoordinator: a lobby-dance-state-changed listener failed for player %d: %s",
					lobbyDanceStateChange.playerUserId,
					tostring(listenerError)
				)
			)
		end
	end
end

-- Tells every queued change, including changes queued by listeners while this runs.
local function tellListenersEveryQueuedChange(self)
	local queuedChangePosition = 1
	while queuedChangePosition <= #self.queuedLobbyDanceStateChanges do
		tellListenersLobbyDanceStateChanged(self, self.queuedLobbyDanceStateChanges[queuedChangePosition])
		queuedChangePosition += 1
	end
end

function LobbyDancerStateRegistry:replaceLobbyDanceStateOfPlayer(
	playerUserId: number,
	newLobbyDanceState: LobbyDanceState?
)
	local currentLobbyDanceState = self.lobbyDanceStateByPlayerUserId[playerUserId]
	if arePlainValuesDeeplyEqual(currentLobbyDanceState, newLobbyDanceState) then
		return
	end
	self.lobbyDanceStateByPlayerUserId[playerUserId] = newLobbyDanceState
	table.insert(
		self.queuedLobbyDanceStateChanges,
		{ playerUserId = playerUserId, lobbyDanceState = newLobbyDanceState }
	)
	local changedPlayerUserIds = { playerUserId }
	local changedPlayerPosition = 1
	while changedPlayerPosition <= #changedPlayerUserIds do
		for _, followingPlayerUserId in listUserIdsOfPlayersFollowing(self, changedPlayerUserIds[changedPlayerPosition]) do
			self.lobbyDanceStateByPlayerUserId[followingPlayerUserId] = nil
			table.insert(
				self.queuedLobbyDanceStateChanges,
				{ playerUserId = followingPlayerUserId, lobbyDanceState = nil }
			)
			table.insert(changedPlayerUserIds, followingPlayerUserId)
		end
		changedPlayerPosition += 1
	end
	if self.isTellingListeners then
		return -- the notification already running tells these changes after the ones before them
	end
	self.isTellingListeners = true
	local didTellEveryChange, tellingError = pcall(tellListenersEveryQueuedChange, self)
	self.isTellingListeners = false
	table.clear(self.queuedLobbyDanceStateChanges)
	if not didTellEveryChange then
		error(tellingError, 0)
	end
end

function LobbyDancerStateRegistry:subscribeToLobbyDanceStateChanged(
	listener: (number, LobbyDanceState?) -> ()
): () -> ()
	if type(listener) ~= "function" then
		error("LobbyDanceCoordinator: listener must be a function", 3)
	end
	local subscription = { listener = listener }
	table.insert(self.stateChangedSubscriptions, subscription)
	return function()
		local subscriptionIndex = table.find(self.stateChangedSubscriptions, subscription)
		if subscriptionIndex then
			table.remove(self.stateChangedSubscriptions, subscriptionIndex)
		end
	end
end

return LobbyDancerStateRegistry
