-- PlayerDataStorageSelectionRule: decides which storage the save keeper and the leaderboard
-- keeper are given (development spec §1.10, §1.11, §3.3, §6.1).
--
-- In a published game they get RobloxPlayerSaveDataStorage and RobloxFanCountLeaderboardStorage
-- (the real data stores). A place that has never been published cannot use data stores, and the
-- project owner forbids touching any data store from it, so there the server runs on the
-- in-memory development storages, which save NOTHING.
--
-- 🔴 The development storage is chosen ONLY when every fact says "Studio, never published":
--   isRunningInStudio == true, and placeId, gameId and placeVersion are all exactly the number 0.
-- Any other combination, including a fact that is missing, not a number, NaN or not a boolean,
-- chooses the real data stores. Choosing the real stores by mistake in an unpublished place only
-- makes loading fail (the player is removed with the keeper's message, nothing is written);
-- choosing the in-memory storage by mistake in a published game would silently lose every
-- player's progress, so every doubt goes to the real stores.
--
-- Why these facts (official documentation, read 2026-11-19):
--   RunService:IsStudio  https://create.roblox.com/docs/reference/engine/classes/RunService
--   DataModel.PlaceId, DataModel.GameId, DataModel.PlaceVersion
--                        https://create.roblox.com/docs/reference/engine/classes/DataModel
--     PlaceVersion "is 0 for all unpublished experiences". PlaceId of an unpublished place
--     "will correspond with the template being used", so PlaceId alone cannot say "unpublished".
--   Measured in Studio 0.748 on 2026-11-19 in the unpublished Place1 (Edit and playtest server):
--   PlaceId 0, GameId 0, PlaceVersion 0, IsStudio true.
-- Pure logic: the facts are read by ServerMain and passed in.
--
-- PUBLIC API
--   PlayerDataStorageSelectionRule.PLAYER_DATA_STORAGE_KINDS = { RobloxDataStores, InMemoryDevelopmentStorage }
--   PlayerDataStorageSelectionRule.decidePlayerDataStorageKind(serverPublishingFacts) -> kind
--     serverPublishingFacts = { isRunningInStudio: boolean, placeId: number, gameId: number,
--                               placeVersion: number }   (any value is accepted; see above)
--   PlayerDataStorageSelectionRule.DEVELOPMENT_STORAGE_WARNING_TEXT   the one loud warning the
--     server logs when the development storage is chosen.

local PlayerDataStorageSelectionRule = {}

PlayerDataStorageSelectionRule.PLAYER_DATA_STORAGE_KINDS = table.freeze({
	RobloxDataStores = "RobloxDataStores",
	InMemoryDevelopmentStorage = "InMemoryDevelopmentStorage",
})

PlayerDataStorageSelectionRule.DEVELOPMENT_STORAGE_WARNING_TEXT = "DEVELOPMENT STORAGE IN USE: this place runs in "
	.. "Roblox Studio and has never been published, so player saves and the fan leaderboard are kept in "
	.. "server memory only. NOTHING IS SAVED: every save and leaderboard entry is lost when this server stops."

local function isExactlyZero(candidateFact: any): boolean
	return type(candidateFact) == "number" and candidateFact == 0
end

function PlayerDataStorageSelectionRule.decidePlayerDataStorageKind(serverPublishingFacts: any): string
	local kinds = PlayerDataStorageSelectionRule.PLAYER_DATA_STORAGE_KINDS
	if type(serverPublishingFacts) ~= "table" then
		return kinds.RobloxDataStores
	end
	local isNeverPublishedStudioPlace = rawequal(rawget(serverPublishingFacts, "isRunningInStudio"), true)
		and isExactlyZero(rawget(serverPublishingFacts, "placeId"))
		and isExactlyZero(rawget(serverPublishingFacts, "gameId"))
		and isExactlyZero(rawget(serverPublishingFacts, "placeVersion"))
	if isNeverPublishedStudioPlace then
		return kinds.InMemoryDevelopmentStorage
	end
	return kinds.RobloxDataStores
end

return table.freeze(PlayerDataStorageSelectionRule)
