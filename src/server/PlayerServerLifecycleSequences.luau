-- PlayerServerLifecycleSequences: the exact order in which the server's modules are told that a
-- player joined or is leaving, and that the server is shutting down (development spec v1.3 §2.1,
-- §2.2, §3.4; the order each accepted module's header requires). ServerMain connects the Roblox
-- events to these three methods; keeping the order here lets Lune check it.
--
-- Joining (Players.PlayerAdded, and every player already present when the server script starts):
--   1. keeper:startLoadingPlayerSaveData   at once (§3.4 Loading)
--   2. RoundStateChanged is sent to that player (§2.1 "to each player on joining the server"),
--      when the round clock runs.
-- Leaving (Players.PlayerRemoving; also what happens after the keeper asked for a player's
-- removal, because removing a player makes Roblox fire PlayerRemoving):
--   1. dailyProgressTracker:recordCountedPlaytimeAndStopCountingBeforeFinalSave (it must come
--      IMMEDIATELY before the final save; nothing below changes the save)
--   2. themedRoundReferee:removePlayerWhoLeftServer (it also makes the rate limiter forget them)
--   3. lobbyDanceCoordinator:forgetPlayer
--   4. every extra per-connection forgetter, in the order given (the showcase presenter's state)
--   5. keeper:startFinalSaveForLeavingPlayer
--   Per-connection state is forgotten here, on the Roblox leave event, never on the keeper's
--   "session ended" event. A step that raises is logged and the later steps still run, so the
--   final save is always started.
-- Shutdown (game:BindToClose):
--   1. themedRoundReferee:beginServerShutdown (told first: no join, draft, score or grant after it)
--   2. themedRoundClock:stopRoundCycle
--   3. dailyProgressTracker:recordCountedPlaytimeOfEveryPlayerAndStopCountingBeforeShutdown
--   4. keeper:startFinalSavesForServerShutdown(onEveryFinalSaveFinished)
--   Calling it a second time does nothing (the callback of the first call is the one called).
--
-- PUBLIC API
--   PlayerServerLifecycleSequences.new(dependencies) -> sequences
--     dependencies = { playerSaveDataKeeper, themedRoundReferee, themedRoundClock,
--       dailyProgressTracker, lobbyDanceCoordinator, logger,
--       sendRoundStateChangedToPlayer: (playerUserId, roundStateChangedMessage) -> (),
--       forgetPlayerOnLeavingServerCallbacks: { (playerUserId) -> () }? }
--   sequences:handlePlayerJoinedServer(playerUserId)
--   sequences:handlePlayerLeavingServer(playerUserId)
--   sequences:startServerShutdownSequence(onEveryFinalSaveFinished: () -> ())
--   sequences:hasServerShutdownStarted() -> boolean
-- Calls no Roblox-specific interface.

local LoggedErrorTextShortener = require("./LoggedErrorTextShortener")

local PlayerServerLifecycleSequences = {}
PlayerServerLifecycleSequences.__index = PlayerServerLifecycleSequences

local REQUIRED_DEPENDENCY_NAMES = table.freeze({
	"playerSaveDataKeeper",
	"themedRoundReferee",
	"themedRoundClock",
	"dailyProgressTracker",
	"lobbyDanceCoordinator",
	"logger",
	"sendRoundStateChangedToPlayer",
})

function PlayerServerLifecycleSequences.new(dependencies)
	for _, dependencyName in REQUIRED_DEPENDENCY_NAMES do
		if type(dependencies) ~= "table" or dependencies[dependencyName] == nil then
			error("PlayerServerLifecycleSequences: missing " .. dependencyName, 2)
		end
	end
	return setmetatable({
		dependencies = dependencies,
		forgetPlayerOnLeavingServerCallbacks = dependencies.forgetPlayerOnLeavingServerCallbacks or {},
		hasShutdownStarted = false,
	}, PlayerServerLifecycleSequences)
end

local function runStepAndLogFailure(self, stepDescription: string, playerUserId: number?, stepBody: () -> ())
	local didRun, raisedError = pcall(stepBody)
	if not didRun then
		self.dependencies.logger:logWarning(
			string.format(
				"PlayerServerLifecycleSequences: %s for player %s raised: %s",
				stepDescription,
				tostring(playerUserId),
				LoggedErrorTextShortener.shortenErrorTextForLog(raisedError)
			)
		)
	end
end

function PlayerServerLifecycleSequences:handlePlayerJoinedServer(playerUserId: number)
	local dependencies = self.dependencies
	runStepAndLogFailure(self, "starting the save load", playerUserId, function()
		dependencies.playerSaveDataKeeper:startLoadingPlayerSaveData(playerUserId)
	end)
	runStepAndLogFailure(self, "sending RoundStateChanged on joining", playerUserId, function()
		local roundStateChangedMessage = dependencies.themedRoundReferee:readRoundStateChangedMessage()
		if roundStateChangedMessage ~= nil then
			dependencies.sendRoundStateChangedToPlayer(playerUserId, roundStateChangedMessage)
		end
	end)
end

function PlayerServerLifecycleSequences:handlePlayerLeavingServer(playerUserId: number)
	local dependencies = self.dependencies
	runStepAndLogFailure(self, "recording counted playtime", playerUserId, function()
		dependencies.dailyProgressTracker:recordCountedPlaytimeAndStopCountingBeforeFinalSave(playerUserId)
	end)
	runStepAndLogFailure(self, "removing the player from the round", playerUserId, function()
		dependencies.themedRoundReferee:removePlayerWhoLeftServer(playerUserId)
	end)
	runStepAndLogFailure(self, "forgetting the lobby dancer", playerUserId, function()
		dependencies.lobbyDanceCoordinator:forgetPlayer(playerUserId)
	end)
	for _, forgetPlayer in self.forgetPlayerOnLeavingServerCallbacks do
		runStepAndLogFailure(self, "forgetting per-connection state", playerUserId, function()
			forgetPlayer(playerUserId)
		end)
	end
	runStepAndLogFailure(self, "starting the final save", playerUserId, function()
		dependencies.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(playerUserId)
	end)
end

function PlayerServerLifecycleSequences:startServerShutdownSequence(onEveryFinalSaveFinished: () -> ())
	if self.hasShutdownStarted then
		return
	end
	self.hasShutdownStarted = true
	local dependencies = self.dependencies
	runStepAndLogFailure(self, "telling the referee about the shutdown", nil, function()
		dependencies.themedRoundReferee:beginServerShutdown()
	end)
	runStepAndLogFailure(self, "stopping the round clock", nil, function()
		dependencies.themedRoundClock:stopRoundCycle()
	end)
	runStepAndLogFailure(self, "recording every player's playtime", nil, function()
		dependencies.dailyProgressTracker:recordCountedPlaytimeOfEveryPlayerAndStopCountingBeforeShutdown()
	end)
	local didStartFinalSaves = false
	runStepAndLogFailure(self, "starting every final save", nil, function()
		dependencies.playerSaveDataKeeper:startFinalSavesForServerShutdown(onEveryFinalSaveFinished)
		didStartFinalSaves = true
	end)
	if not didStartFinalSaves then
		onEveryFinalSaveFinished()
	end
end

function PlayerServerLifecycleSequences:hasServerShutdownStarted(): boolean
	return self.hasShutdownStarted
end

return PlayerServerLifecycleSequences
