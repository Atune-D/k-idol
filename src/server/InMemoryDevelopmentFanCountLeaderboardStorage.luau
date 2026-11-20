-- InMemoryDevelopmentFanCountLeaderboardStorage: a FanCountLeaderboardStorage (interface
-- documented at the top of FanCountLeaderboardKeeper.luau) that keeps the fan leaderboard in this
-- server's memory. 🔴 NOTHING IS SAVED: it is lost when the server stops. Used only in a Studio
-- place that has never been published (PlayerDataStorageSelectionRule). It touches no data store
-- and no Roblox interface (the scheduler is injected).
--
-- How it keeps the interface contract:
--   * startKeepingLargerFanCount returns at once; inside the start call it stores
--     max(stored value, fanCountBeingWritten) in one step (atomic: nothing can run in between),
--     so a smaller value never lowers the stored one. onWriteFinished(true, nil) is called exactly
--     once, through the scheduler after 0 seconds. A fanCount that is not a whole number >= 0
--     (an ordered data store holds only integers) is not stored and reported as
--     onWriteFinished(false, reason).
--   * startReadingTopFanCountEntries returns at once; onReadFinished(true, entries, nil) is called
--     exactly once, through the scheduler after 0 seconds, with at most maximumEntryCount entries
--     { playerUserId, fanCount }, highest first, equal counts by smaller user id first. The list is
--     taken when the read starts.
--
-- PUBLIC API
--   InMemoryDevelopmentFanCountLeaderboardStorage.new({ scheduler }) -> storage
--   storage:startKeepingLargerFanCount(playerUserId, fanCountBeingWritten, onWriteFinished)
--   storage:startReadingTopFanCountEntries(maximumEntryCount, onReadFinished)
--   storage:readStoredFanCount(playerUserId) -> number?   for tests and diagnostics

local InMemoryDevelopmentFanCountLeaderboardStorage = {}
InMemoryDevelopmentFanCountLeaderboardStorage.__index = InMemoryDevelopmentFanCountLeaderboardStorage

function InMemoryDevelopmentFanCountLeaderboardStorage.new(dependencies)
	if type(dependencies) ~= "table" or dependencies.scheduler == nil then
		error("InMemoryDevelopmentFanCountLeaderboardStorage: a scheduler is required", 2)
	end
	return setmetatable({
		scheduler = dependencies.scheduler,
		storedFanCountByPlayerUserId = {} :: { [number]: number },
	}, InMemoryDevelopmentFanCountLeaderboardStorage)
end

local function isWholeNumberAtLeastZero(candidateNumber: any): boolean
	return type(candidateNumber) == "number"
		and candidateNumber >= 0
		and candidateNumber == math.floor(candidateNumber)
		and candidateNumber ~= math.huge
end

function InMemoryDevelopmentFanCountLeaderboardStorage:startKeepingLargerFanCount(
	playerUserId: number,
	fanCountBeingWritten: number,
	onWriteFinished: (boolean, string?) -> ()
)
	if type(playerUserId) ~= "number" or type(onWriteFinished) ~= "function" then
		error("InMemoryDevelopmentFanCountLeaderboardStorage: a numeric playerUserId and a callback are required", 2)
	end
	local wasWriteSuccessful, failureReason = true, nil
	if not isWholeNumberAtLeastZero(fanCountBeingWritten) then
		wasWriteSuccessful, failureReason = false, "an ordered data store holds only whole numbers >= 0"
	else
		local storedFanCount = self.storedFanCountByPlayerUserId[playerUserId]
		if storedFanCount == nil or fanCountBeingWritten > storedFanCount then
			self.storedFanCountByPlayerUserId[playerUserId] = fanCountBeingWritten
		end
	end
	self.scheduler:scheduleCallbackAfterSeconds(0, function()
		onWriteFinished(wasWriteSuccessful, failureReason)
	end)
end

function InMemoryDevelopmentFanCountLeaderboardStorage:startReadingTopFanCountEntries(
	maximumEntryCount: number,
	onReadFinished: (
		boolean,
		{ { playerUserId: number, fanCount: number } }?,
		string?
	) -> ()
)
	if type(maximumEntryCount) ~= "number" or type(onReadFinished) ~= "function" then
		error("InMemoryDevelopmentFanCountLeaderboardStorage: a maximum entry count and a callback are required", 2)
	end
	local topFanCountEntries = {}
	for playerUserId, storedFanCount in self.storedFanCountByPlayerUserId do
		table.insert(topFanCountEntries, { playerUserId = playerUserId, fanCount = storedFanCount })
	end
	table.sort(topFanCountEntries, function(firstEntry, secondEntry)
		if firstEntry.fanCount ~= secondEntry.fanCount then
			return firstEntry.fanCount > secondEntry.fanCount
		end
		return firstEntry.playerUserId < secondEntry.playerUserId
	end)
	while #topFanCountEntries > math.max(0, maximumEntryCount) do
		table.remove(topFanCountEntries)
	end
	self.scheduler:scheduleCallbackAfterSeconds(0, function()
		onReadFinished(true, topFanCountEntries, nil)
	end)
end

function InMemoryDevelopmentFanCountLeaderboardStorage:readStoredFanCount(playerUserId: number): number?
	return self.storedFanCountByPlayerUserId[playerUserId]
end

return InMemoryDevelopmentFanCountLeaderboardStorage
