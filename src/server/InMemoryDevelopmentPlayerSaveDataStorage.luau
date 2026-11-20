-- InMemoryDevelopmentPlayerSaveDataStorage: a PlayerSaveDataStorage (interface documented at the
-- top of PlayerSaveDataKeeper.luau) that keeps every save in this server's memory. 🔴 NOTHING IS
-- SAVED: everything is lost when the server stops. It exists only so the game can run in a Studio
-- place that has never been published, where data stores cannot and must not be used;
-- PlayerDataStorageSelectionRule decides when it is used. It touches no data store and no Roblox
-- interface at all (the scheduler is injected), so Lune tests run it exactly as the server does.
--
-- How it keeps the interface contract:
--   * startAtomicPlayerSaveDataUpdate returns at once and never yields its caller. The whole
--     "read the current value -> decide -> write back" runs INSIDE the start call, with nothing
--     able to run in between (Luau runs one thread at a time and the decision must not yield),
--     so it is atomic.
--   * The decision receives a private deep copy of the stored value (nil for a key never
--     written). What it returns is deep-copied before it is stored, so later edits of either table
--     change nothing stored. Returning nil cancels the write.
--   * The decision may run more than once: `decisionRunCountPerUpdate` (default 1) runs it that
--     many times on fresh copies of the same stored value and keeps only the LAST answer, the way
--     Roblox re-runs an UpdateAsync transform function. Tests use 2 to prove callers tolerate it.
--   * onUpdateFinished is called exactly once, through the scheduler with a delay of 0 seconds
--     (so always after the start call has returned, as a real storage call would):
--     (true, nil) after a write or a cancelled write; (false, reason) when the decision raised or
--     returned a value a data store could not hold (InMemoryDevelopmentStorageValueCopier). After
--     a failure nothing is written.
--
-- PUBLIC API
--   InMemoryDevelopmentPlayerSaveDataStorage.new({ scheduler, decisionRunCountPerUpdate: number? }) -> storage
--     scheduler: { scheduleCallbackAfterSeconds: (self, delaySeconds, callback) -> cancelCallback }
--     decisionRunCountPerUpdate: a whole number >= 1 (default 1). Anything else raises.
--   storage:startAtomicPlayerSaveDataUpdate(playerUserId, decideNewStoredPlayerSaveData, onUpdateFinished)
--     As the interface says. A playerUserId that is not a number, or callbacks that are not
--     functions, raise (wiring errors).
--   storage:readStoredPlayerSaveDataCopy(playerUserId) -> any   a deep copy, for tests and diagnostics
--   storage:countWrittenSaves() -> number   writes so far (cancelled and failed ones not counted)

local InMemoryDevelopmentStorageValueCopier = require("./InMemoryDevelopmentStorageValueCopier")

local InMemoryDevelopmentPlayerSaveDataStorage = {}
InMemoryDevelopmentPlayerSaveDataStorage.__index = InMemoryDevelopmentPlayerSaveDataStorage

local copyStorableValue = InMemoryDevelopmentStorageValueCopier.copyStorableValue

function InMemoryDevelopmentPlayerSaveDataStorage.new(dependencies)
	if type(dependencies) ~= "table" or dependencies.scheduler == nil then
		error("InMemoryDevelopmentPlayerSaveDataStorage: a scheduler is required", 2)
	end
	local decisionRunCountPerUpdate = dependencies.decisionRunCountPerUpdate or 1
	if
		type(decisionRunCountPerUpdate) ~= "number"
		or decisionRunCountPerUpdate < 1
		or decisionRunCountPerUpdate ~= math.floor(decisionRunCountPerUpdate)
	then
		error("InMemoryDevelopmentPlayerSaveDataStorage: decisionRunCountPerUpdate must be a whole number >= 1", 2)
	end
	return setmetatable({
		scheduler = dependencies.scheduler,
		decisionRunCountPerUpdate = decisionRunCountPerUpdate,
		storedPlayerSaveDataByPlayerUserId = {} :: { [number]: any },
		writtenSaveCount = 0,
	}, InMemoryDevelopmentPlayerSaveDataStorage)
end

-- Runs the decision the configured number of times; returns (true, lastAnswer) or (false, reason).
local function runDecisionOnFreshCopies(self, playerUserId: number, decideNewStoredPlayerSaveData): (boolean, any)
	local lastAnswer = nil
	for _ = 1, self.decisionRunCountPerUpdate do
		local storedValueCopy = copyStorableValue(self.storedPlayerSaveDataByPlayerUserId[playerUserId])
		local didDecide, answerOrError = pcall(decideNewStoredPlayerSaveData, storedValueCopy)
		if not didDecide then
			return false, "the decide function raised: " .. tostring(answerOrError)
		end
		lastAnswer = answerOrError
	end
	return true, lastAnswer
end

function InMemoryDevelopmentPlayerSaveDataStorage:startAtomicPlayerSaveDataUpdate(
	playerUserId: number,
	decideNewStoredPlayerSaveData: (any) -> any,
	onUpdateFinished: (boolean, string?) -> ()
)
	if type(playerUserId) ~= "number" then
		error("InMemoryDevelopmentPlayerSaveDataStorage: playerUserId must be a number", 2)
	end
	if type(decideNewStoredPlayerSaveData) ~= "function" or type(onUpdateFinished) ~= "function" then
		error("InMemoryDevelopmentPlayerSaveDataStorage: the decide function and the finish callback are required", 2)
	end
	local wasUpdateSuccessful, failureReason = true, nil
	local didDecide, newStoredPlayerSaveData =
		runDecisionOnFreshCopies(self, playerUserId, decideNewStoredPlayerSaveData)
	if not didDecide then
		wasUpdateSuccessful, failureReason = false, newStoredPlayerSaveData
	elseif newStoredPlayerSaveData ~= nil then
		local storedCopy, refusalReason = copyStorableValue(newStoredPlayerSaveData)
		if refusalReason ~= nil then
			wasUpdateSuccessful, failureReason = false, "the decided save cannot be stored: " .. refusalReason
		else
			self.storedPlayerSaveDataByPlayerUserId[playerUserId] = storedCopy
			self.writtenSaveCount += 1
		end
	end
	self.scheduler:scheduleCallbackAfterSeconds(0, function()
		onUpdateFinished(wasUpdateSuccessful, failureReason)
	end)
end

function InMemoryDevelopmentPlayerSaveDataStorage:readStoredPlayerSaveDataCopy(playerUserId: number): any
	return (copyStorableValue(self.storedPlayerSaveDataByPlayerUserId[playerUserId]))
end

function InMemoryDevelopmentPlayerSaveDataStorage:countWrittenSaves(): number
	return self.writtenSaveCount
end

return InMemoryDevelopmentPlayerSaveDataStorage
