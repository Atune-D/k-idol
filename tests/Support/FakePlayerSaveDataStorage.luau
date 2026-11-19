-- A fake PlayerSaveDataStorage (interface documented in src/server/PlayerSaveDataKeeper.luau).
--
-- By default every operation started by the keeper stays "in flight" until the test finishes it,
-- so a test can hold a save in flight deterministically without ever really waiting:
--   completeOldestPendingOperation(playerUserId?)       runs the atomic read-decide-write NOW
--                                                       against what is stored NOW, then reports success
--   failOldestPendingOperation(playerUserId?, message?) reports a storage error; nothing is written
--   completeOldestPendingOperationButReportFailure(...) writes, then reports an error (a lost answer)
-- `setCompletesOperationsImmediately(true)` finishes every operation inside the start call instead;
-- `failNextStartedOperations(count)` makes the next `count` operations fail in that mode.
-- `setRunsEveryDecisionTwice(true)` imitates Roblox re-running the transform function: the decision
-- runs once with its answer thrown away, then again for real.
--
-- Stored values are always deep copies, so neither the keeper nor the test can change what is
-- stored except through an operation or `setStoredPlayerSaveData`.

local FakePlayerSaveDataStorage = {}
FakePlayerSaveDataStorage.__index = FakePlayerSaveDataStorage

local DEFAULT_STORAGE_ERROR_MESSAGE = "fake storage error"

type PendingStorageOperation = {
	playerUserId: number,
	decideNewStoredPlayerSaveData: (any) -> any,
	onUpdateFinished: (boolean, string?) -> (),
}

local function createDeepCopy(originalValue: any): any
	if type(originalValue) ~= "table" then
		return originalValue
	end
	local copiedTable = {}
	for copiedKey, copiedValue in originalValue do
		copiedTable[createDeepCopy(copiedKey)] = createDeepCopy(copiedValue)
	end
	return copiedTable
end

-- `clock` is optional; when given, the start time of every operation is recorded.
function FakePlayerSaveDataStorage.new(clock: { getCurrentUnixSeconds: (any) -> number }?)
	return setmetatable({
		clock = clock,
		storedPlayerSaveDataByPlayerUserId = {} :: { [number]: any },
		pendingStorageOperations = {} :: { PendingStorageOperation },
		completesOperationsImmediately = false,
		remainingImmediateFailureCount = 0,
		runsEveryDecisionTwice = false,
		-- Every operation ever started: { playerUserId, startedAtUnixSeconds? }.
		startedOperationRecords = {} :: { { playerUserId: number, startedAtUnixSeconds: number? } },
		-- Every value ever written: { playerUserId, writtenPlayerSaveData }.
		writtenPlayerSaveDataRecords = {} :: { { playerUserId: number, writtenPlayerSaveData: any } },
	}, FakePlayerSaveDataStorage)
end

function FakePlayerSaveDataStorage:setStoredPlayerSaveData(playerUserId: number, storedPlayerSaveData: any)
	self.storedPlayerSaveDataByPlayerUserId[playerUserId] = createDeepCopy(storedPlayerSaveData)
end

function FakePlayerSaveDataStorage:readStoredPlayerSaveData(playerUserId: number): any
	return createDeepCopy(self.storedPlayerSaveDataByPlayerUserId[playerUserId])
end

function FakePlayerSaveDataStorage:setCompletesOperationsImmediately(completesOperationsImmediately: boolean)
	self.completesOperationsImmediately = completesOperationsImmediately
end

function FakePlayerSaveDataStorage:failNextStartedOperations(failureCount: number)
	self.remainingImmediateFailureCount = failureCount
end

function FakePlayerSaveDataStorage:setRunsEveryDecisionTwice(runsEveryDecisionTwice: boolean)
	self.runsEveryDecisionTwice = runsEveryDecisionTwice
end

function FakePlayerSaveDataStorage:countPendingOperations(playerUserId: number?): number
	local pendingCount = 0
	for _, pendingOperation in self.pendingStorageOperations do
		if playerUserId == nil or pendingOperation.playerUserId == playerUserId then
			pendingCount += 1
		end
	end
	return pendingCount
end

function FakePlayerSaveDataStorage:countStartedOperations(playerUserId: number?): number
	local startedCount = 0
	for _, startedRecord in self.startedOperationRecords do
		if playerUserId == nil or startedRecord.playerUserId == playerUserId then
			startedCount += 1
		end
	end
	return startedCount
end

local function runAtomicReadDecideWrite(self, pendingOperation: PendingStorageOperation): boolean
	local playerUserId = pendingOperation.playerUserId
	if self.runsEveryDecisionTwice then
		pendingOperation.decideNewStoredPlayerSaveData(
			createDeepCopy(self.storedPlayerSaveDataByPlayerUserId[playerUserId])
		)
	end
	local newStoredPlayerSaveData = pendingOperation.decideNewStoredPlayerSaveData(
		createDeepCopy(self.storedPlayerSaveDataByPlayerUserId[playerUserId])
	)
	if newStoredPlayerSaveData == nil then
		return false
	end
	self.storedPlayerSaveDataByPlayerUserId[playerUserId] = createDeepCopy(newStoredPlayerSaveData)
	table.insert(self.writtenPlayerSaveDataRecords, {
		playerUserId = playerUserId,
		writtenPlayerSaveData = createDeepCopy(newStoredPlayerSaveData),
	})
	return true
end

function FakePlayerSaveDataStorage:startAtomicPlayerSaveDataUpdate(
	playerUserId: number,
	decideNewStoredPlayerSaveData: (any) -> any,
	onUpdateFinished: (boolean, string?) -> ()
)
	table.insert(self.startedOperationRecords, {
		playerUserId = playerUserId,
		startedAtUnixSeconds = if self.clock then self.clock:getCurrentUnixSeconds() else nil,
	})
	local pendingOperation: PendingStorageOperation = {
		playerUserId = playerUserId,
		decideNewStoredPlayerSaveData = decideNewStoredPlayerSaveData,
		onUpdateFinished = onUpdateFinished,
	}
	if not self.completesOperationsImmediately then
		table.insert(self.pendingStorageOperations, pendingOperation)
		return
	end
	if self.remainingImmediateFailureCount > 0 then
		self.remainingImmediateFailureCount -= 1
		onUpdateFinished(false, DEFAULT_STORAGE_ERROR_MESSAGE)
		return
	end
	runAtomicReadDecideWrite(self, pendingOperation)
	onUpdateFinished(true, nil)
end

local function takeOldestPendingOperation(self, playerUserId: number?): PendingStorageOperation
	for pendingIndex, pendingOperation in self.pendingStorageOperations do
		if playerUserId == nil or pendingOperation.playerUserId == playerUserId then
			table.remove(self.pendingStorageOperations, pendingIndex)
			return pendingOperation
		end
	end
	error("FakePlayerSaveDataStorage: no pending operation for player " .. tostring(playerUserId), 3)
end

-- Returns whether a value was written (false when the decision cancelled the write).
function FakePlayerSaveDataStorage:completeOldestPendingOperation(playerUserId: number?): boolean
	local pendingOperation = takeOldestPendingOperation(self, playerUserId)
	local wasWritten = runAtomicReadDecideWrite(self, pendingOperation)
	pendingOperation.onUpdateFinished(true, nil)
	return wasWritten
end

function FakePlayerSaveDataStorage:failOldestPendingOperation(playerUserId: number?, storageErrorMessage: string?)
	local pendingOperation = takeOldestPendingOperation(self, playerUserId)
	pendingOperation.onUpdateFinished(false, storageErrorMessage or DEFAULT_STORAGE_ERROR_MESSAGE)
end

function FakePlayerSaveDataStorage:completeOldestPendingOperationButReportFailure(
	playerUserId: number?,
	storageErrorMessage: string?
)
	local pendingOperation = takeOldestPendingOperation(self, playerUserId)
	runAtomicReadDecideWrite(self, pendingOperation)
	pendingOperation.onUpdateFinished(false, storageErrorMessage or DEFAULT_STORAGE_ERROR_MESSAGE)
end

return FakePlayerSaveDataStorage
