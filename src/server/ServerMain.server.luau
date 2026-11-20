-- ServerMain (development spec v1.3 §3.2): the game server's entry script. WIRING ONLY: it builds
-- the Roblox implementations of time, delayed work, storage, Marketplace lookups, remote channels,
-- the stage and the character presenter, hands them to ServerGameModuleAssembly, and connects the
-- Roblox player, character and shutdown events to the modules. Every rule lives in the modules.
--
-- Start order:
--   1. logger, clock, scheduler; the storages (PlayerDataStorageSelectionRule decides; in an
--      unpublished Studio place the in-memory development storages, with one loud warning)
--   2. ReplicatedStorage.Remotes with every channel; the stage in Workspace
--   3. every module (ServerGameModuleAssembly), then started (the round clock last)
--   4. the device-sent channels connected to the request router
--   5. players: PlayerAdded and every player already present; CharacterAdded; PlayerRemoving
--   6. game:BindToClose: the shutdown sequence, waiting for every final save
--
-- Roblox API used, read in the official documentation while writing this file:
--   game:GetService                   https://create.roblox.com/docs/reference/engine/classes/ServiceProvider
--   Players.PlayerAdded, .PlayerRemoving, :GetPlayers, :GetPlayerByUserId (PlayerAdded "does not
--     work as expected in a solo playtest ... call for each existing player" too)
--                                     https://create.roblox.com/docs/reference/engine/classes/Players
--   Player.UserId, .Character, .CharacterAdded, :Kick(message) (server side, at most 500 bytes)
--                                     https://create.roblox.com/docs/reference/engine/classes/Player
--   DataModel:BindToClose ("waits 30 seconds for all bound functions")
--                                     https://create.roblox.com/docs/reference/engine/classes/DataModel
--   HttpService:GenerateGUID ("can be used regardless of whether HTTP requests are enabled")
--                                     https://create.roblox.com/docs/reference/engine/classes/HttpService
--   Random.new, Random:NextInteger (inclusive of both ends)
--                                     https://create.roblox.com/docs/reference/engine/datatypes/Random
--   RBXScriptSignal:Connect           https://create.roblox.com/docs/reference/engine/datatypes/RBXScriptSignal
--   task.wait, os.clock               https://create.roblox.com/docs/reference/engine/libraries/task

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local PlayerCharacterDresser = require("./PlayerCharacterDresser")
local RobloxCharacterShowcasePresenter = require("./RobloxCharacterShowcasePresenter")
local RobloxDeviceRemoteChannelConnections = require("./RobloxDeviceRemoteChannelConnections")
local RobloxMarketplaceItemLookups = require("./RobloxMarketplaceItemLookups")
local RobloxPlayerDataStorageSelection = require("./RobloxPlayerDataStorageSelection")
local RobloxPlayerDisplayNameLookups = require("./RobloxPlayerDisplayNameLookups")
local RobloxRemoteChannelInstances = require("./RobloxRemoteChannelInstances")
local RobloxServerClock = require("./RobloxServerClock")
local RobloxServerLogger = require("./RobloxServerLogger")
local RobloxTaskScheduler = require("./RobloxTaskScheduler")
local RobloxThemedRoundStageBuilder = require("./RobloxThemedRoundStageBuilder")
local ServerGameModuleAssembly = require("./ServerGameModuleAssembly")

-- Roblox gives BindToClose 30 s in all; the wait stops a little earlier so the log line is written.
local SHUTDOWN_FINAL_SAVE_WAIT_SECONDS = 28

local logger = RobloxServerLogger.newForThisServer()
local serverClock = RobloxServerClock.newForThisServer()
local scheduler = RobloxTaskScheduler.newForThisServer()
local playerSaveDataStorage, fanCountLeaderboardStorage =
	RobloxPlayerDataStorageSelection.createPlayerDataStorages(scheduler, logger)

local remoteInstanceByRemoteChannelName = RobloxRemoteChannelInstances.createRemoteChannelInstances()
RobloxThemedRoundStageBuilder.buildThemedRoundStage()

local serverGameModules -- assigned below; the dresser reads the resolver's cache through it
local characterShowcasePresenter = RobloxCharacterShowcasePresenter.new({
	playerCharacterDresser = PlayerCharacterDresser.new({
		readResolvedStylingItemDetails = function(stylingItemKey: string)
			return serverGameModules.marketplaceStylingItemResolver:readResolvedStylingItemDetails(stylingItemKey)
		end,
		logger = logger,
	}),
	logger = logger,
	-- The same clock the lobby dance coordinator stamps start moments with (lobby dances in time).
	clock = serverClock,
})

local roundRandomGenerator = Random.new()
local serverDependencies = {
	clock = serverClock,
	scheduler = scheduler,
	logger = logger,
	playerSaveDataStorage = playerSaveDataStorage,
	fanCountLeaderboardStorage = fanCountLeaderboardStorage,
	marketplaceItemLookups = RobloxMarketplaceItemLookups.newForThisServer(),
	randomNumberGenerator = {
		nextWholeNumberInRange = function(smallestWholeNumber: number, largestWholeNumber: number): number
			return roundRandomGenerator:NextInteger(smallestWholeNumber, largestWholeNumber)
		end,
	},
	generateUniqueId = function(): string
		return HttpService:GenerateGUID(false)
	end,
	removePlayerFromGameWithMessage = function(playerUserId: number, playerFacingMessage: string)
		local player = Players:GetPlayerByUserId(playerUserId)
		if player ~= nil then
			player:Kick(playerFacingMessage)
		end
	end,
	lookUpPlayerDisplayNamesByUserId = RobloxPlayerDisplayNameLookups.lookUpPlayerDisplayNamesByUserId,
	readPlayerDisplayName = RobloxPlayerDisplayNameLookups.readPlayerDisplayName,
	deviceMessageSenders = RobloxRemoteChannelInstances.buildDeviceMessageSenders(remoteInstanceByRemoteChannelName),
	characterAppearancePresenter = characterShowcasePresenter,
}

serverGameModules = ServerGameModuleAssembly.assembleServerGameModules(serverDependencies)
ServerGameModuleAssembly.startServerGameModules(serverGameModules, serverDependencies)
RobloxDeviceRemoteChannelConnections.connectDeviceRemoteChannels(
	remoteInstanceByRemoteChannelName,
	serverGameModules.deviceRequestChannelAnswerRouter
)

local lifecycleSequences = serverGameModules.playerServerLifecycleSequences
local characterDirector = serverGameModules.characterAppearanceAndStageDirector

local function connectPlayerJoinedServer(player: Player)
	local playerUserId = player.UserId
	lifecycleSequences:handlePlayerJoinedServer(playerUserId)
	player.CharacterAdded:Connect(function()
		characterDirector:handleCharacterSpawned(playerUserId)
	end)
	if player.Character ~= nil then
		characterDirector:handleCharacterSpawned(playerUserId)
	end
end

Players.PlayerAdded:Connect(connectPlayerJoinedServer)
for _, alreadyPresentPlayer in Players:GetPlayers() do
	connectPlayerJoinedServer(alreadyPresentPlayer)
end
Players.PlayerRemoving:Connect(function(leavingPlayer: Player)
	lifecycleSequences:handlePlayerLeavingServer(leavingPlayer.UserId)
end)

game:BindToClose(function()
	local haveFinalSavesFinished = false
	local shutdownStartedAtClock = os.clock()
	lifecycleSequences:startServerShutdownSequence(function()
		haveFinalSavesFinished = true
	end)
	while not haveFinalSavesFinished and os.clock() - shutdownStartedAtClock < SHUTDOWN_FINAL_SAVE_WAIT_SECONDS do
		task.wait(0.1)
	end
	logger:logInformation(
		string.format(
			"ServerMain: shutdown sequence %s after %.2f s",
			if haveFinalSavesFinished then "finished every final save" else "stopped waiting for final saves",
			os.clock() - shutdownStartedAtClock
		)
	)
end)

logger:logInformation("ServerMain: server started; every module is running")
