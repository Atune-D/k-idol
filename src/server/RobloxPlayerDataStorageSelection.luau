-- RobloxPlayerDataStorageSelection: reads the publishing facts of this server from the engine,
-- lets PlayerDataStorageSelectionRule decide, and creates the chosen pair of storages.
--   RobloxDataStores            -> RobloxPlayerSaveDataStorage.new(), RobloxFanCountLeaderboardStorage.new()
--   InMemoryDevelopmentStorage  -> the two in-memory development storages, and ONE loud warning
--                                  that nothing is saved.
-- The Roblox storage modules are required, and their `new` called, only when they are chosen, so
-- in an unpublished Studio place DataStoreService is never even asked for a data store (their
-- module bodies only define functions; GetDataStore runs inside `new`).
--
-- PUBLIC API
--   RobloxPlayerDataStorageSelection.readServerPublishingFacts() -> { isRunningInStudio, placeId, gameId, placeVersion }
--   RobloxPlayerDataStorageSelection.createPlayerDataStorages(scheduler, logger)
--     -> (playerSaveDataStorage, fanCountLeaderboardStorage, chosenStorageKind)
--     logger must have logLoudWarning (RobloxServerLogger).
--
-- Roblox API used, read in the official documentation while writing this file:
--   RunService:IsStudio          https://create.roblox.com/docs/reference/engine/classes/RunService
--   DataModel.PlaceId, .GameId, .PlaceVersion
--                                https://create.roblox.com/docs/reference/engine/classes/DataModel

local RunService = game:GetService("RunService")

local InMemoryDevelopmentFanCountLeaderboardStorage = require("./InMemoryDevelopmentFanCountLeaderboardStorage")
local InMemoryDevelopmentPlayerSaveDataStorage = require("./InMemoryDevelopmentPlayerSaveDataStorage")
local PlayerDataStorageSelectionRule = require("./PlayerDataStorageSelectionRule")

local RobloxPlayerDataStorageSelection = {}

function RobloxPlayerDataStorageSelection.readServerPublishingFacts()
	return {
		isRunningInStudio = RunService:IsStudio(),
		placeId = game.PlaceId,
		gameId = game.GameId,
		placeVersion = game.PlaceVersion,
	}
end

function RobloxPlayerDataStorageSelection.createPlayerDataStorages(scheduler, logger)
	local serverPublishingFacts = RobloxPlayerDataStorageSelection.readServerPublishingFacts()
	local chosenStorageKind = PlayerDataStorageSelectionRule.decidePlayerDataStorageKind(serverPublishingFacts)
	if chosenStorageKind == PlayerDataStorageSelectionRule.PLAYER_DATA_STORAGE_KINDS.InMemoryDevelopmentStorage then
		logger:logLoudWarning(
			string.format(
				"%s (IsStudio=%s PlaceId=%s GameId=%s PlaceVersion=%s)",
				PlayerDataStorageSelectionRule.DEVELOPMENT_STORAGE_WARNING_TEXT,
				tostring(serverPublishingFacts.isRunningInStudio),
				tostring(serverPublishingFacts.placeId),
				tostring(serverPublishingFacts.gameId),
				tostring(serverPublishingFacts.placeVersion)
			)
		)
		return InMemoryDevelopmentPlayerSaveDataStorage.new({ scheduler = scheduler }),
			InMemoryDevelopmentFanCountLeaderboardStorage.new({ scheduler = scheduler }),
			chosenStorageKind
	end
	local RobloxPlayerSaveDataStorage = require("./RobloxPlayerSaveDataStorage")
	local RobloxFanCountLeaderboardStorage = require("./RobloxFanCountLeaderboardStorage")
	return RobloxPlayerSaveDataStorage.new(), RobloxFanCountLeaderboardStorage.new(), chosenStorageKind
end

return RobloxPlayerDataStorageSelection
