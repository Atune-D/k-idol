-- RobloxFanCountLeaderboardStorage: the ONLY file that touches the ordered data store
-- `FanCountLeaderboard_v1` (development spec §1.11, §3.3). Key: `tostring(playerUserId)`,
-- value: fanCount (ordered data store values must be integers).
--
-- A thin adapter implementing the FanCountLeaderboardStorage interface documented at the top of
-- FanCountLeaderboardKeeper.luau. It needs the Roblox engine, so it is not covered by the Lune
-- unit tests; it is kept minimal for that reason.
--
-- The keep-the-larger write (spec §3.5) is ONE OrderedDataStore:UpdateAsync call: the transform
-- returns nil (cancel, stored value kept) when the stored value is already at least as large.
--
-- Roblox API used, each read in the official documentation while writing this file:
--   game:GetService                        https://create.roblox.com/docs/reference/engine/classes/ServiceProvider
--   DataStoreService:GetOrderedDataStore   https://create.roblox.com/docs/reference/engine/classes/DataStoreService
--   OrderedDataStore:UpdateAsync (inherited from GlobalDataStore; listed for ordered data stores in
--     https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits)
--                                          https://create.roblox.com/docs/reference/engine/classes/OrderedDataStore
--                                          https://create.roblox.com/docs/reference/engine/classes/GlobalDataStore
--   OrderedDataStore:GetSortedAsync        https://create.roblox.com/docs/reference/engine/classes/OrderedDataStore
--   DataStorePages:GetCurrentPage (entries have `key` and `value`)
--                                          https://create.roblox.com/docs/reference/engine/classes/DataStorePages
--   task.spawn                             https://create.roblox.com/docs/reference/engine/libraries/task
--   Wrapping data store calls in pcall: https://create.roblox.com/docs/cloud-services/data-stores

local FAN_COUNT_LEADERBOARD_STORE_NAME = "FanCountLeaderboard_v1"
local GET_SORTED_ASYNC_MAXIMUM_PAGE_SIZE = 100

local RobloxFanCountLeaderboardStorage = {}
RobloxFanCountLeaderboardStorage.__index = RobloxFanCountLeaderboardStorage

function RobloxFanCountLeaderboardStorage.new()
	local DataStoreService = game:GetService("DataStoreService")
	return setmetatable({
		fanCountLeaderboardStore = DataStoreService:GetOrderedDataStore(FAN_COUNT_LEADERBOARD_STORE_NAME),
	}, RobloxFanCountLeaderboardStorage)
end

-- See the FanCountLeaderboardStorage interface in FanCountLeaderboardKeeper.luau.
function RobloxFanCountLeaderboardStorage:startKeepingLargerFanCount(
	playerUserId: number,
	fanCountBeingWritten: number,
	onWriteFinished: (boolean, string?) -> ()
)
	task.spawn(function()
		local didWriteSucceed, writeError = pcall(function()
			self.fanCountLeaderboardStore:UpdateAsync(tostring(playerUserId), function(storedFanCount)
				if type(storedFanCount) == "number" and storedFanCount >= fanCountBeingWritten then
					return nil -- cancels the write; the larger stored value stays
				end
				return fanCountBeingWritten
			end)
		end)
		onWriteFinished(didWriteSucceed, if didWriteSucceed then nil else tostring(writeError))
	end)
end

-- See the FanCountLeaderboardStorage interface in FanCountLeaderboardKeeper.luau.
function RobloxFanCountLeaderboardStorage:startReadingTopFanCountEntries(
	maximumEntryCount: number,
	onReadFinished: (
		boolean,
		{ { playerUserId: number, fanCount: number } }?,
		string?
	) -> ()
)
	task.spawn(function()
		local topFanCountEntries = {}
		local didReadSucceed, readError = pcall(function()
			local sortedPages = self.fanCountLeaderboardStore:GetSortedAsync(
				false,
				math.min(maximumEntryCount, GET_SORTED_ASYNC_MAXIMUM_PAGE_SIZE)
			)
			for _, sortedEntry in sortedPages:GetCurrentPage() do
				local playerUserId = tonumber(sortedEntry.key)
				if playerUserId ~= nil and type(sortedEntry.value) == "number" then
					table.insert(topFanCountEntries, { playerUserId = playerUserId, fanCount = sortedEntry.value })
				end
			end
		end)
		if didReadSucceed then
			onReadFinished(true, topFanCountEntries, nil)
		else
			onReadFinished(false, nil, tostring(readError))
		end
	end)
end

return RobloxFanCountLeaderboardStorage
