-- A fake FanCountLeaderboardStorage (interface documented in src/server/FanCountLeaderboardKeeper.luau).
--
-- Writes stay in flight until the test finishes them, in ANY order:
--   completePendingWriteAt(pendingPosition)              applies max(stored, written) NOW, reports success
--   failPendingWriteAt(pendingPosition, message?)         reports an error; nothing is written
-- `setCompletesWritesImmediately(true)` finishes writes inside the start call instead.
-- `setRaisesWhenWriteStarts(true)` makes the start call itself raise.
-- Reads finish immediately from what is stored (highest first, ties by smaller user id) unless
-- `setFailsReads(true)`.

local FakeFanCountLeaderboardStorage = {}
FakeFanCountLeaderboardStorage.__index = FakeFanCountLeaderboardStorage

local DEFAULT_STORAGE_ERROR_MESSAGE = "fake leaderboard storage error"

type PendingLeaderboardWrite = {
	playerUserId: number,
	fanCountBeingWritten: number,
	onWriteFinished: (boolean, string?) -> (),
}

function FakeFanCountLeaderboardStorage.new()
	return setmetatable({
		storedFanCountByPlayerUserId = {} :: { [number]: number },
		pendingLeaderboardWrites = {} :: { PendingLeaderboardWrite },
		completesWritesImmediately = false,
		raisesWhenWriteStarts = false,
		failsReads = false,
		-- Every write ever started, in start order: { playerUserId, fanCountBeingWritten }.
		startedWriteRecords = {} :: { { playerUserId: number, fanCountBeingWritten: number } },
		startedReadCount = 0,
	}, FakeFanCountLeaderboardStorage)
end

function FakeFanCountLeaderboardStorage:setStoredFanCount(playerUserId: number, storedFanCount: number)
	self.storedFanCountByPlayerUserId[playerUserId] = storedFanCount
end

function FakeFanCountLeaderboardStorage:readStoredFanCount(playerUserId: number): number?
	return self.storedFanCountByPlayerUserId[playerUserId]
end

function FakeFanCountLeaderboardStorage:setCompletesWritesImmediately(completesWritesImmediately: boolean)
	self.completesWritesImmediately = completesWritesImmediately
end

function FakeFanCountLeaderboardStorage:setRaisesWhenWriteStarts(raisesWhenWriteStarts: boolean)
	self.raisesWhenWriteStarts = raisesWhenWriteStarts
end

function FakeFanCountLeaderboardStorage:setFailsReads(failsReads: boolean)
	self.failsReads = failsReads
end

function FakeFanCountLeaderboardStorage:countPendingWrites(): number
	return #self.pendingLeaderboardWrites
end

local function applyKeepLargerWrite(self, pendingWrite: PendingLeaderboardWrite)
	local storedFanCount = self.storedFanCountByPlayerUserId[pendingWrite.playerUserId]
	if storedFanCount == nil or pendingWrite.fanCountBeingWritten > storedFanCount then
		self.storedFanCountByPlayerUserId[pendingWrite.playerUserId] = pendingWrite.fanCountBeingWritten
	end
end

function FakeFanCountLeaderboardStorage:startKeepingLargerFanCount(
	playerUserId: number,
	fanCountBeingWritten: number,
	onWriteFinished: (boolean, string?) -> ()
)
	if self.raisesWhenWriteStarts then
		error("fake leaderboard storage raised while starting a write")
	end
	table.insert(self.startedWriteRecords, { playerUserId = playerUserId, fanCountBeingWritten = fanCountBeingWritten })
	local pendingWrite: PendingLeaderboardWrite = {
		playerUserId = playerUserId,
		fanCountBeingWritten = fanCountBeingWritten,
		onWriteFinished = onWriteFinished,
	}
	if self.completesWritesImmediately then
		applyKeepLargerWrite(self, pendingWrite)
		onWriteFinished(true, nil)
		return
	end
	table.insert(self.pendingLeaderboardWrites, pendingWrite)
end

local function takePendingWriteAt(self, pendingPosition: number): PendingLeaderboardWrite
	local pendingWrite = self.pendingLeaderboardWrites[pendingPosition]
	if pendingWrite == nil then
		error("FakeFanCountLeaderboardStorage: no pending write at position " .. tostring(pendingPosition), 3)
	end
	table.remove(self.pendingLeaderboardWrites, pendingPosition)
	return pendingWrite
end

function FakeFanCountLeaderboardStorage:completePendingWriteAt(pendingPosition: number)
	local pendingWrite = takePendingWriteAt(self, pendingPosition)
	applyKeepLargerWrite(self, pendingWrite)
	pendingWrite.onWriteFinished(true, nil)
end

function FakeFanCountLeaderboardStorage:failPendingWriteAt(pendingPosition: number, storageErrorMessage: string?)
	local pendingWrite = takePendingWriteAt(self, pendingPosition)
	pendingWrite.onWriteFinished(false, storageErrorMessage or DEFAULT_STORAGE_ERROR_MESSAGE)
end

function FakeFanCountLeaderboardStorage:startReadingTopFanCountEntries(
	maximumEntryCount: number,
	onReadFinished: (
		boolean,
		{ { playerUserId: number, fanCount: number } }?,
		string?
	) -> ()
)
	self.startedReadCount += 1
	if self.failsReads then
		onReadFinished(false, nil, DEFAULT_STORAGE_ERROR_MESSAGE)
		return
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
	while #topFanCountEntries > maximumEntryCount do
		table.remove(topFanCountEntries)
	end
	onReadFinished(true, topFanCountEntries, nil)
end

return FakeFanCountLeaderboardStorage
