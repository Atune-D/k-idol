-- RobloxPlayerSaveDataStorage: the ONLY file that touches the standard data store
-- `PlayerSaveData_v1` (development spec §1.10, §3.3). Key: `player_<playerUserId>`.
--
-- A thin adapter implementing the PlayerSaveDataStorage interface documented at the top of
-- PlayerSaveDataKeeper.luau. All rules (lock, retries, spacing) live in the keeper; this file
-- only runs one atomic UpdateAsync per call. It needs the Roblox engine, so it is not covered by
-- the Lune unit tests; it is kept minimal for that reason.
--
-- Roblox API used, each read in the official documentation while writing this file:
--   game:GetService                https://create.roblox.com/docs/reference/engine/classes/ServiceProvider
--   DataStoreService:GetDataStore  https://create.roblox.com/docs/reference/engine/classes/DataStoreService
--   GlobalDataStore:UpdateAsync    https://create.roblox.com/docs/reference/engine/classes/GlobalDataStore
--     (transform gets (currentValue, DataStoreKeyInfo); returning nil cancels the write; it may be
--     called more than once; it cannot yield; it returns value, userIds, metadata, and metadata
--     not passed back is cleared)
--   DataStoreKeyInfo:GetMetadata   https://create.roblox.com/docs/reference/engine/classes/DataStoreKeyInfo
--   task.spawn                     https://create.roblox.com/docs/reference/engine/libraries/task
--   Wrapping data store calls in pcall: https://create.roblox.com/docs/cloud-services/data-stores
--   Session locking through UpdateAsync: https://create.roblox.com/docs/cloud-services/data-stores/player-data-purchasing

local PLAYER_SAVE_DATA_STORE_NAME = "PlayerSaveData_v1"

local RobloxPlayerSaveDataStorage = {}
RobloxPlayerSaveDataStorage.__index = RobloxPlayerSaveDataStorage

local function formatPlayerSaveDataKey(playerUserId: number): string
	return string.format("player_%d", playerUserId)
end

function RobloxPlayerSaveDataStorage.new()
	local DataStoreService = game:GetService("DataStoreService")
	return setmetatable({
		playerSaveDataStore = DataStoreService:GetDataStore(PLAYER_SAVE_DATA_STORE_NAME),
	}, RobloxPlayerSaveDataStorage)
end

-- See the PlayerSaveDataStorage interface in PlayerSaveDataKeeper.luau.
function RobloxPlayerSaveDataStorage:startAtomicPlayerSaveDataUpdate(
	playerUserId: number,
	decideNewStoredPlayerSaveData: (any) -> any,
	onUpdateFinished: (boolean, string?) -> ()
)
	local playerSaveDataKey = formatPlayerSaveDataKey(playerUserId)
	task.spawn(function()
		local didUpdateSucceed, updateError = pcall(function()
			self.playerSaveDataStore:UpdateAsync(playerSaveDataKey, function(storedPlayerSaveData, storedKeyInfo)
				local newStoredPlayerSaveData = decideNewStoredPlayerSaveData(storedPlayerSaveData)
				if newStoredPlayerSaveData == nil then
					return nil -- cancels the write; the stored value stays as it is
				end
				-- Pass the existing metadata back so it is not cleared; associate the key with
				-- the player's user id.
				local storedMetadata = if storedKeyInfo then storedKeyInfo:GetMetadata() else nil
				return newStoredPlayerSaveData, { playerUserId }, storedMetadata
			end)
		end)
		onUpdateFinished(didUpdateSucceed, if didUpdateSucceed then nil else tostring(updateError))
	end)
end

return RobloxPlayerSaveDataStorage
