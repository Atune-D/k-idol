-- Extra answer orders for a FakePlayerSaveDataStorage that holds operations in flight, for tests of
-- a player who leaves and rejoins the same server while storage answers arrive out of order.
--
--   landOldestPendingWriteAndHoldItsAnswer(fakeStorage, playerUserId?) -> heldStorageAnswer
--     Runs the oldest pending operation's atomic read-decide-write NOW (the write lands in
--     storage), but keeps its answer back. heldStorageAnswer:deliverAnswer(wasStorageCallSuccessful?)
--     hands the answer to the keeper later (success unless false is passed). Delivering twice raises.
--   landNewestPendingWriteAndHoldItsAnswer(fakeStorage, playerUserId) -> heldStorageAnswer
--     The same, for the player's most recently started pending operation.
--   completeNewestPendingOperation(fakeStorage, playerUserId) -> boolean
--     Like completeOldestPendingOperation, for the most recently started pending operation.
--   movePendingOperationToFront(fakeStorage, pendingPosition)
--     Makes the operation at `pendingPosition` (1 = oldest, any player) the oldest, so the fake's
--     own complete/fail methods (called with no player) answer it next.
--
-- Uses the fake's documented `pendingStorageOperations` list; the fake itself is unchanged.

local FakePlayerSaveDataStorageAnswerOrder = {}

local function findOldestPendingPosition(fakeStorage, playerUserId: number?): number
	for pendingPosition, pendingOperation in fakeStorage.pendingStorageOperations do
		if playerUserId == nil or pendingOperation.playerUserId == playerUserId then
			return pendingPosition
		end
	end
	error("FakePlayerSaveDataStorageAnswerOrder: no pending operation for player " .. tostring(playerUserId), 3)
end

function FakePlayerSaveDataStorageAnswerOrder.movePendingOperationToFront(fakeStorage, pendingPosition: number)
	local pendingOperations = fakeStorage.pendingStorageOperations
	assert(pendingOperations[pendingPosition] ~= nil, "no pending operation at position " .. tostring(pendingPosition))
	table.insert(pendingOperations, 1, table.remove(pendingOperations, pendingPosition))
end

local function findNewestPendingPosition(fakeStorage, playerUserId: number): number
	local newestPendingPosition = nil
	for pendingPosition, pendingOperation in fakeStorage.pendingStorageOperations do
		if pendingOperation.playerUserId == playerUserId then
			newestPendingPosition = pendingPosition
		end
	end
	assert(newestPendingPosition ~= nil, "no pending operation for player " .. tostring(playerUserId))
	return newestPendingPosition :: number
end

function FakePlayerSaveDataStorageAnswerOrder.completeNewestPendingOperation(fakeStorage, playerUserId: number): boolean
	FakePlayerSaveDataStorageAnswerOrder.movePendingOperationToFront(
		fakeStorage,
		findNewestPendingPosition(fakeStorage, playerUserId)
	)
	return fakeStorage:completeOldestPendingOperation(playerUserId)
end

export type HeldStorageAnswer = {
	wasWritten: boolean,
	deliverAnswer: (self: HeldStorageAnswer, wasStorageCallSuccessful: boolean?) -> (),
}

function FakePlayerSaveDataStorageAnswerOrder.landOldestPendingWriteAndHoldItsAnswer(
	fakeStorage,
	playerUserId: number?
): HeldStorageAnswer
	local pendingOperation = fakeStorage.pendingStorageOperations[findOldestPendingPosition(fakeStorage, playerUserId)]
	local keeperOnUpdateFinished = pendingOperation.onUpdateFinished
	pendingOperation.onUpdateFinished = function() end -- the answer is kept back
	local wasWritten = fakeStorage:completeOldestPendingOperation(pendingOperation.playerUserId)
	local hasDelivered = false
	local heldStorageAnswer = { wasWritten = wasWritten }
	function heldStorageAnswer.deliverAnswer(_, wasStorageCallSuccessful: boolean?)
		assert(not hasDelivered, "this held storage answer was already delivered")
		hasDelivered = true
		if wasStorageCallSuccessful == false then
			keeperOnUpdateFinished(false, "fake storage error (answer delivered late)")
		else
			keeperOnUpdateFinished(true, nil)
		end
	end
	return heldStorageAnswer :: any
end

function FakePlayerSaveDataStorageAnswerOrder.landNewestPendingWriteAndHoldItsAnswer(
	fakeStorage,
	playerUserId: number
): HeldStorageAnswer
	FakePlayerSaveDataStorageAnswerOrder.movePendingOperationToFront(
		fakeStorage,
		findNewestPendingPosition(fakeStorage, playerUserId)
	)
	return FakePlayerSaveDataStorageAnswerOrder.landOldestPendingWriteAndHoldItsAnswer(fakeStorage, playerUserId)
end

return table.freeze(FakePlayerSaveDataStorageAnswerOrder)
