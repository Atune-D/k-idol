-- PlayerSaveDataKeeper ("the archivist", development spec v1.2 §3.4): loads, holds and saves
-- every online player's save, protected across servers by a session lock stored inside the save.
--
-- Calls no Roblox-specific interface. Everything external is injected (see `new`).
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (the reward ledger, round referee and server wiring are written from this)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- PlayerSaveDataKeeper.new(dependencies) -> keeper
--   dependencies = {
--     playerSaveDataStorage: PlayerSaveDataStorage   (interface at the end of this block),
--     clock: { getCurrentUnixSeconds: (self) -> number },
--     scheduler: { scheduleCallbackAfterSeconds: (self, delaySeconds, callback) -> cancelCallback },
--     removePlayerFromGameWithMessage: (playerUserId: number, playerFacingMessage: string) -> (),
--         May be called for a player who is already leaving; must tolerate that.
--     logger: { logInformation: (self, message: string) -> (), logWarning: (self, message: string) -> () },
--     generateUniqueSessionLockId: () -> string,   -- a new globally unique id per load
--     buildStartingPlayerSaveDataForNewPlayer: (currentUnixSeconds: number) -> PlayerSaveData,
--         normally `function(now) return PlayerSaveDataSchema.createStartingPlayerSaveData(starterDanceIds, now) end`
--   }
--
-- keeper:startLoadingPlayerSaveData(playerUserId)
--   Call when a player joins. Loads and locks the save in the background (retry every 5 s, at most
--   6 retries). On success the "loaded" event fires. If loading never succeeds the player is
--   removed from the game; a starting save is NEVER substituted for a save that failed to load.
-- keeper:isPlayerSaveDataLoaded(playerUserId) -> boolean
--   True from the moment loading succeeds until the player starts leaving. When false, requests
--   must be refused with `SaveDataNotLoaded`.
-- keeper:readPlayerSaveDataCopy(playerUserId) -> PlayerSaveData?
--   A deep copy of the in-memory save (nil when not loaded). Editing the copy changes nothing.
--
-- keeper:applyChangeToPlayerSaveData(playerUserId, playerSaveDataChangeKind, changeDescription,
--                                    decideAndApplyChange) -> PlayerSaveDataChangeResult
--   The ONLY way to change a save, and one indivisible change (spec §3.3): nothing (no save, no
--   other change, no event) can run between the decision and the commit.
--   * playerSaveDataChangeKind:
--       "ProgressChangeSavedAtOnce"  grants, spends, claims, redemptions: a save is requested at once
--                                    (still subject to the 10 s spacing between save starts).
--       "AppearanceChangeSavedLater" equip, lobby outfit: no save is requested; the change is
--                                    written by the next save of any kind.
--     Any other value raises.
--   * changeDescription: a short text used only in logs.
--   * decideAndApplyChange(saveDataDraft) -> (wasChangeAccepted: boolean, declineReason: string?)
--       Runs exactly once, on a private deep copy of the current save. It may read the draft to
--       check eligibility and edit it in place. It must NOT yield and must not change
--       `gameServerSessionLock`, `lastSavedAtUnixSeconds` or `saveDataSchemaVersion`.
--       Return true to commit the draft, or false plus a reason to decline (nothing changes).
--       Raising, yielding, returning a non-boolean or touching a keeper-managed field makes the
--       call raise; nothing changes in any of those cases.
--       It must not call applyChangeToPlayerSaveData for the same player (that raises).
--   Result: { changeOutcome = "Applied", inMemoryChangeRevision = number }
--         | { changeOutcome = "AppliedWithoutAnyDifference" }   draft equals the save exactly:
--                                                               no revision bump, no save, no event
--         | { changeOutcome = "Declined", declineReason = string? }
--         | { changeOutcome = "SaveDataNotLoaded" }             not loaded, or the player is leaving;
--                                                               the function is not called
--   On "Applied": inMemoryChangeRevision += 1, then the "in-memory save changed" event fires,
--   then (for a progress change) a save is requested.
--
-- keeper:isSaveDataPersistenceDelayed(playerUserId) -> boolean
--   True after a full round of failed save retries; false again after any successful save.
-- keeper:readSaveChangeRevisions(playerUserId) -> (inMemoryChangeRevision?, lastSavedChangeRevision?)
--   Both start at 0 when the save loads. Unsaved work exists while the first exceeds the second.
-- keeper:startFinalSaveForLeavingPlayer(playerUserId)
--   Call when a player leaves. Writes the save one last time (no spacing; up to 5 retries,
--   1 s apart) and hands the lock back in the same write.
-- keeper:startFinalSavesForServerShutdown(onEveryFinalSaveFinished: () -> ())
--   Starts the final save of every player in parallel; calls the callback once all of them have
--   finished (succeeded, been abandoned, or ended otherwise). New loads are refused afterwards.
--
-- Subscriptions. Each returns an `unsubscribe` function. Listeners are called synchronously, and
-- EACH listener receives its own deep copy of the event value: nothing one listener does to
-- what it received can change what another listener, or the keeper, sees. A listener that raises
-- is logged and never disturbs saving or other listeners.
-- keeper:subscribeToPlayerSaveDataLoaded(listener(playerUserId, loadedSaveDataCopy))
--   The save loaded and is locked by this server. The copy is exactly what storage now holds.
-- keeper:subscribeToInMemorySaveDataChanged(listener(playerUserId, inMemorySaveDataCopy))
--   Fired after each "Applied" change. The change is NOT yet saved.
-- keeper:subscribeToSaveDataSaveSucceeded(listener(playerUserId, savedSaveDataCopy))
--   A write succeeded. `savedSaveDataCopy` is exactly what was written (including a final save).
--   This is the only source the leaderboard may take `fanCount` from (spec §3.5).
-- keeper:subscribeToSaveDataPersistenceDelayedChanged(listener(playerUserId, isSaveDataPersistenceDelayed))
-- keeper:subscribeToPlayerSaveDataSessionEnded(listener(playerUserId, sessionEndReason))
--   The keeper has forgotten this player. Reasons: "FinalSaveSucceeded", "FinalSaveAbandoned",
--   "SessionLockLost", "LoadRetriesExhausted", "StoredSchemaVersionNotUnderstood",
--   "LeftBeforeLoadFinished".
--
-- PlayerSaveDataStorage interface (implemented by RobloxPlayerSaveDataStorage and by
-- tests/Support/FakePlayerSaveDataStorage):
--   storage:startAtomicPlayerSaveDataUpdate(playerUserId, decideNewStoredPlayerSaveData, onUpdateFinished)
--     Starts ONE atomic "read current value -> decide -> write back" operation and returns at once
--     (it never yields the caller). `decideNewStoredPlayerSaveData(storedPlayerSaveDataOrNil)
--     -> newPlayerSaveDataOrNil` runs inside the atomic operation, does not yield, and may be
--     called more than once (Roblox re-runs it if another server wrote in between); returning
--     nil cancels the write. `onUpdateFinished(wasStorageCallSuccessful: boolean,
--     storageErrorMessage: string?)` is called exactly once, later or before the start call
--     returns. `true` also covers "decide returned nil, nothing was written".
-- ════════════════════════════════════════════════════════════════════════════════════════════

local PlayerSaveDataSchema = require("./PlayerSaveDataSchema")

local createDeepCopyOfPlainTable = PlayerSaveDataSchema.createDeepCopyOfPlainTable
local arePlainValuesDeeplyEqual = PlayerSaveDataSchema.arePlainValuesDeeplyEqual

local PlayerSaveDataKeeper = {}
PlayerSaveDataKeeper.__index = PlayerSaveDataKeeper

PlayerSaveDataKeeper.SESSION_LOCK_EXPIRY_SECONDS = 360
PlayerSaveDataKeeper.LOAD_RETRY_DELAY_SECONDS = 5
PlayerSaveDataKeeper.LOAD_MAXIMUM_RETRY_COUNT = 6
PlayerSaveDataKeeper.PERIODIC_SAVE_INTERVAL_SECONDS = 120
PlayerSaveDataKeeper.MINIMUM_SECONDS_BETWEEN_SAVE_STARTS = 10
PlayerSaveDataKeeper.FAILED_SAVE_RETRY_DELAYS_SECONDS = table.freeze({ 2, 4, 8 })
PlayerSaveDataKeeper.FINAL_SAVE_MAXIMUM_RETRY_COUNT = 5
-- The spec gives no delay between final-save retries; it must fit Roblox's 30 s shutdown window.
PlayerSaveDataKeeper.FINAL_SAVE_RETRY_DELAY_SECONDS = 1

PlayerSaveDataKeeper.LOAD_RETRIES_EXHAUSTED_PLAYER_MESSAGE =
	"Your save is still being written. Please rejoin in a moment."
-- The spec gives no wording for these two cases.
PlayerSaveDataKeeper.SESSION_LOCK_LOST_PLAYER_MESSAGE =
	"Your save was opened on another server. Please rejoin in a moment."
PlayerSaveDataKeeper.STORED_SCHEMA_VERSION_NOT_UNDERSTOOD_PLAYER_MESSAGE =
	"Your save needs a newer version of the game. Please rejoin in a moment."

PlayerSaveDataKeeper.PROGRESS_CHANGE_SAVED_AT_ONCE = "ProgressChangeSavedAtOnce"
PlayerSaveDataKeeper.APPEARANCE_CHANGE_SAVED_LATER = "AppearanceChangeSavedLater"

-- Fields only the keeper may change; a change function that edits them is refused.
local KEEPER_MANAGED_SAVE_DATA_FIELD_NAMES =
	{ "gameServerSessionLock", "lastSavedAtUnixSeconds", "saveDataSchemaVersion" }

export type PlayerSaveDataChangeKind = "ProgressChangeSavedAtOnce" | "AppearanceChangeSavedLater"

export type PlayerSaveDataChangeResult = {
	changeOutcome: "Applied" | "AppliedWithoutAnyDifference" | "Declined" | "SaveDataNotLoaded",
	inMemoryChangeRevision: number?,
	declineReason: string?,
}

type SessionPhase = "Loading" | "Loaded" | "Ended"
type SaveAttemptKind = "RegularSave" | "FailedSaveRetry" | "FinalSave"

type PlayerSaveDataSession = {
	playerUserId: number,
	sessionLockId: string,
	sessionPhase: SessionPhase,
	-- loading
	loadAttemptCount: number,
	isLoadInFlight: boolean,
	isLeaveRequestedWhileLoading: boolean,
	cancelPendingLoadRetry: (() -> ())?,
	-- loaded
	inMemorySaveData: any,
	inMemoryChangeRevision: number,
	lastSavedChangeRevision: number,
	isChangeBeingApplied: boolean,
	isSaveInFlight: boolean,
	isAnotherSaveRequested: boolean,
	lastSaveStartedAtUnixSeconds: number,
	cancelPendingSpacedSaveStart: (() -> ())?,
	failedSaveRetriesUsedInCurrentRound: number,
	cancelPendingFailedSaveRetry: (() -> ())?,
	cancelPendingPeriodicSave: (() -> ())?,
	isSaveDataPersistenceDelayed: boolean,
	isFinalSaveRequested: boolean,
	finalSaveRetriesUsedCount: number,
	cancelPendingFinalSaveRetry: (() -> ())?,
}

function PlayerSaveDataKeeper.new(dependencies)
	for _, requiredDependencyName in
		{
			"playerSaveDataStorage",
			"clock",
			"scheduler",
			"removePlayerFromGameWithMessage",
			"logger",
			"generateUniqueSessionLockId",
			"buildStartingPlayerSaveDataForNewPlayer",
		}
	do
		if dependencies[requiredDependencyName] == nil then
			error("PlayerSaveDataKeeper.new: missing dependency " .. requiredDependencyName, 2)
		end
	end
	local self = setmetatable({
		playerSaveDataStorage = dependencies.playerSaveDataStorage,
		clock = dependencies.clock,
		scheduler = dependencies.scheduler,
		removePlayerFromGameWithMessage = dependencies.removePlayerFromGameWithMessage,
		logger = dependencies.logger,
		generateUniqueSessionLockId = dependencies.generateUniqueSessionLockId,
		buildStartingPlayerSaveDataForNewPlayer = dependencies.buildStartingPlayerSaveDataForNewPlayer,

		-- The session the public API addresses for each player.
		activeSessionByPlayerUserId = {} :: { [number]: PlayerSaveDataSession },
		-- Every session not yet ended, including one replaced by a quick rejoin to this server.
		unfinishedSessions = {} :: { [PlayerSaveDataSession]: boolean },

		isShuttingDown = false,
		onEveryShutdownFinalSaveFinished = nil :: (() -> ())?,
		hasReportedShutdownFinished = false,

		listenersByEventName = {
			PlayerSaveDataLoaded = {},
			InMemorySaveDataChanged = {},
			SaveDataSaveSucceeded = {},
			SaveDataPersistenceDelayedChanged = {},
			PlayerSaveDataSessionEnded = {},
		},
	}, PlayerSaveDataKeeper)
	return self
end

-- ── events ──────────────────────────────────────────────────────────────────────────────────

local function subscribe(self, eventName: string, listener: (...any) -> ()): () -> ()
	if type(listener) ~= "function" then
		error("PlayerSaveDataKeeper: listener must be a function", 3)
	end
	local listeners = self.listenersByEventName[eventName]
	local subscription = { listener = listener }
	table.insert(listeners, subscription)
	return function()
		local subscriptionIndex = table.find(listeners, subscription)
		if subscriptionIndex then
			table.remove(listeners, subscriptionIndex)
		end
	end
end

-- Spec §3.3: each listener gets its OWN deep copy of `eventValue`, made just before it is called,
-- so nothing an earlier listener did to its copy can reach a later listener or the keeper.
local function fireEvent(self, eventName: string, playerUserId: number, eventValue: any)
	for _, subscription in table.clone(self.listenersByEventName[eventName]) do
		local isolatedEventValueForThisListener = createDeepCopyOfPlainTable(eventValue)
		local didListenerSucceed, listenerError =
			pcall(subscription.listener, playerUserId, isolatedEventValueForThisListener)
		if not didListenerSucceed then
			self.logger:logWarning(
				string.format(
					"PlayerSaveDataKeeper: a %s listener failed for player %d: %s",
					eventName,
					playerUserId,
					tostring(listenerError)
				)
			)
		end
	end
end

function PlayerSaveDataKeeper:subscribeToPlayerSaveDataLoaded(listener)
	return subscribe(self, "PlayerSaveDataLoaded", listener)
end

function PlayerSaveDataKeeper:subscribeToInMemorySaveDataChanged(listener)
	return subscribe(self, "InMemorySaveDataChanged", listener)
end

function PlayerSaveDataKeeper:subscribeToSaveDataSaveSucceeded(listener)
	return subscribe(self, "SaveDataSaveSucceeded", listener)
end

function PlayerSaveDataKeeper:subscribeToSaveDataPersistenceDelayedChanged(listener)
	return subscribe(self, "SaveDataPersistenceDelayedChanged", listener)
end

function PlayerSaveDataKeeper:subscribeToPlayerSaveDataSessionEnded(listener)
	return subscribe(self, "PlayerSaveDataSessionEnded", listener)
end

-- ── helpers ─────────────────────────────────────────────────────────────────────────────────

local function getCurrentUnixSeconds(self): number
	return self.clock:getCurrentUnixSeconds()
end

local function scheduleAfterSeconds(self, delaySeconds: number, callback: () -> ()): () -> ()
	return self.scheduler:scheduleCallbackAfterSeconds(delaySeconds, callback)
end

local function cancelIfPresent(cancelCallback: (() -> ())?)
	if cancelCallback then
		cancelCallback()
	end
end

local function cancelPendingRegularSaveTimers(session: PlayerSaveDataSession)
	cancelIfPresent(session.cancelPendingSpacedSaveStart)
	cancelIfPresent(session.cancelPendingFailedSaveRetry)
	cancelIfPresent(session.cancelPendingPeriodicSave)
	session.cancelPendingSpacedSaveStart = nil
	session.cancelPendingFailedSaveRetry = nil
	session.cancelPendingPeriodicSave = nil
end

local function cancelEveryPendingTimer(session: PlayerSaveDataSession)
	cancelPendingRegularSaveTimers(session)
	cancelIfPresent(session.cancelPendingLoadRetry)
	cancelIfPresent(session.cancelPendingFinalSaveRetry)
	session.cancelPendingLoadRetry = nil
	session.cancelPendingFinalSaveRetry = nil
end

-- Starts one storage operation; guarantees `onUpdateFinished` runs exactly once even if the
-- storage object raises while starting or reports completion twice.
local function startAtomicStorageUpdate(
	self,
	playerUserId: number,
	decideNewStoredPlayerSaveData: (any) -> any,
	onUpdateFinished: (boolean, string?) -> ()
)
	local hasFinished = false
	local function finishOnce(wasStorageCallSuccessful: boolean, storageErrorMessage: string?)
		if hasFinished then
			return
		end
		hasFinished = true
		onUpdateFinished(wasStorageCallSuccessful, storageErrorMessage)
	end
	local didStart, startError = pcall(function()
		self.playerSaveDataStorage:startAtomicPlayerSaveDataUpdate(
			playerUserId,
			decideNewStoredPlayerSaveData,
			finishOnce
		)
	end)
	if not didStart then
		finishOnce(false, "storage raised while starting: " .. tostring(startError))
	end
end

local function reportShutdownFinishedIfEverySessionEnded(self)
	if not self.isShuttingDown or self.hasReportedShutdownFinished then
		return
	end
	if next(self.unfinishedSessions) ~= nil then
		return
	end
	self.hasReportedShutdownFinished = true
	local onEveryShutdownFinalSaveFinished = self.onEveryShutdownFinalSaveFinished
	if onEveryShutdownFinalSaveFinished then
		onEveryShutdownFinalSaveFinished()
	end
end

local function describeUnsavedRevisionCount(session: PlayerSaveDataSession): string
	return string.format(
		"%d unsaved change(s) (inMemoryChangeRevision %d, lastSavedChangeRevision %d)",
		session.inMemoryChangeRevision - session.lastSavedChangeRevision,
		session.inMemoryChangeRevision,
		session.lastSavedChangeRevision
	)
end

local function endSession(self, session: PlayerSaveDataSession, sessionEndReason: string)
	if session.sessionPhase == "Ended" then
		return
	end
	session.sessionPhase = "Ended"
	cancelEveryPendingTimer(session)
	self.unfinishedSessions[session] = nil
	if self.activeSessionByPlayerUserId[session.playerUserId] == session then
		self.activeSessionByPlayerUserId[session.playerUserId] = nil
	end
	self.logger:logInformation(
		string.format("PlayerSaveDataKeeper: session for player %d ended: %s", session.playerUserId, sessionEndReason)
	)
	fireEvent(self, "PlayerSaveDataSessionEnded", session.playerUserId, sessionEndReason)
	reportShutdownFinishedIfEverySessionEnded(self)
end

local function setSaveDataPersistenceDelayed(self, session: PlayerSaveDataSession, isDelayed: boolean)
	if session.isSaveDataPersistenceDelayed == isDelayed then
		return
	end
	session.isSaveDataPersistenceDelayed = isDelayed
	fireEvent(self, "SaveDataPersistenceDelayedChanged", session.playerUserId, isDelayed)
end

local function isStoredLockHeldByAnotherServer(
	storedSessionLock: any,
	ourSessionLockId: string,
	currentUnixSeconds: number
): boolean
	if type(storedSessionLock) ~= "table" then
		return false
	end
	if storedSessionLock.sessionLockId == ourSessionLockId then
		return false
	end
	-- A lock without a readable refresh time is treated as refreshed at time 0, i.e. expired.
	local lockRefreshedAtUnixSeconds = if type(storedSessionLock.lockRefreshedAtUnixSeconds) == "number"
		then storedSessionLock.lockRefreshedAtUnixSeconds
		else 0
	local secondsSinceLockRefresh = currentUnixSeconds - lockRefreshedAtUnixSeconds
	return secondsSinceLockRefresh < PlayerSaveDataKeeper.SESSION_LOCK_EXPIRY_SECONDS
end

-- ── saving ──────────────────────────────────────────────────────────────────────────────────

local startSaveWrite -- forward declaration

local function isAcceptingRegularSaves(session: PlayerSaveDataSession): boolean
	return session.sessionPhase == "Loaded" and not session.isFinalSaveRequested
end

-- Every regular save request goes through here: at most one save in flight, and save starts
-- spaced MINIMUM_SECONDS_BETWEEN_SAVE_STARTS apart (spec §3.4). A request that has to wait
-- writes whatever is in memory when the save finally starts.
local function requestSaveWrite(self, session: PlayerSaveDataSession)
	if not isAcceptingRegularSaves(session) then
		return
	end
	if session.isSaveInFlight then
		session.isAnotherSaveRequested = true
		return
	end
	if session.cancelPendingFailedSaveRetry ~= nil or session.cancelPendingSpacedSaveStart ~= nil then
		-- A save start is already scheduled; it will write the latest in-memory save.
		return
	end
	local earliestAllowedSaveStartUnixSeconds = session.lastSaveStartedAtUnixSeconds
		+ PlayerSaveDataKeeper.MINIMUM_SECONDS_BETWEEN_SAVE_STARTS
	local secondsUntilSaveMayStart = earliestAllowedSaveStartUnixSeconds - getCurrentUnixSeconds(self)
	if secondsUntilSaveMayStart <= 0 then
		startSaveWrite(self, session, "RegularSave")
		return
	end
	session.cancelPendingSpacedSaveStart = scheduleAfterSeconds(self, secondsUntilSaveMayStart, function()
		session.cancelPendingSpacedSaveStart = nil
		-- Started directly: this moment IS the spacing point (re-checking could loop on rounding).
		if isAcceptingRegularSaves(session) and not session.isSaveInFlight then
			startSaveWrite(self, session, "RegularSave")
		end
	end)
end

local function schedulePeriodicSave(self, session: PlayerSaveDataSession)
	session.cancelPendingPeriodicSave = scheduleAfterSeconds(
		self,
		PlayerSaveDataKeeper.PERIODIC_SAVE_INTERVAL_SECONDS,
		function()
			session.cancelPendingPeriodicSave = nil
			if not isAcceptingRegularSaves(session) then
				return
			end
			requestSaveWrite(self, session)
			schedulePeriodicSave(self, session)
		end
	)
end

local function handleStoredLockNotOurs(self, session: PlayerSaveDataSession)
	self.logger:logWarning(
		string.format(
			"PlayerSaveDataKeeper: stored session lock for player %d is no longer ours; write abandoned, "
				.. "saving stopped, %s discarded",
			session.playerUserId,
			describeUnsavedRevisionCount(session)
		)
	)
	self.removePlayerFromGameWithMessage(session.playerUserId, PlayerSaveDataKeeper.SESSION_LOCK_LOST_PLAYER_MESSAGE)
	endSession(self, session, "SessionLockLost")
end

local function handleFailedFinalSave(self, session: PlayerSaveDataSession)
	if session.finalSaveRetriesUsedCount >= PlayerSaveDataKeeper.FINAL_SAVE_MAXIMUM_RETRY_COUNT then
		self.logger:logWarning(
			string.format(
				"PlayerSaveDataKeeper: final save for player %d abandoned after %d retries; %s lost; "
					.. "the lock will expire by itself",
				session.playerUserId,
				session.finalSaveRetriesUsedCount,
				describeUnsavedRevisionCount(session)
			)
		)
		endSession(self, session, "FinalSaveAbandoned")
		return
	end
	session.finalSaveRetriesUsedCount += 1
	session.cancelPendingFinalSaveRetry = scheduleAfterSeconds(
		self,
		PlayerSaveDataKeeper.FINAL_SAVE_RETRY_DELAY_SECONDS,
		function()
			session.cancelPendingFinalSaveRetry = nil
			if session.sessionPhase ~= "Loaded" then
				return
			end
			startSaveWrite(self, session, "FinalSave")
		end
	)
end

local function handleFailedRegularSave(self, session: PlayerSaveDataSession)
	if session.isFinalSaveRequested then
		startSaveWrite(self, session, "FinalSave")
		return
	end
	local retriesUsed = session.failedSaveRetriesUsedInCurrentRound
	local retryDelaysSeconds = PlayerSaveDataKeeper.FAILED_SAVE_RETRY_DELAYS_SECONDS
	if retriesUsed < #retryDelaysSeconds then
		session.failedSaveRetriesUsedInCurrentRound = retriesUsed + 1
		session.cancelPendingFailedSaveRetry = scheduleAfterSeconds(
			self,
			retryDelaysSeconds[retriesUsed + 1],
			function()
				session.cancelPendingFailedSaveRetry = nil
				if not isAcceptingRegularSaves(session) then
					return
				end
				-- Retries are exempt from the spacing rule (spec §3.4).
				startSaveWrite(self, session, "FailedSaveRetry")
			end
		)
		return
	end
	-- A full round of retries failed: stay pending and wait for the next trigger.
	session.failedSaveRetriesUsedInCurrentRound = 0
	session.isAnotherSaveRequested = false
	self.logger:logWarning(
		string.format(
			"PlayerSaveDataKeeper: a full round of save retries failed for player %d; %s pending",
			session.playerUserId,
			describeUnsavedRevisionCount(session)
		)
	)
	setSaveDataPersistenceDelayed(self, session, true)
end

local function continueAfterSuccessfulRegularSave(self, session: PlayerSaveDataSession)
	if session.sessionPhase ~= "Loaded" or session.isSaveInFlight then
		return
	end
	if session.isFinalSaveRequested then
		startSaveWrite(self, session, "FinalSave")
		return
	end
	-- Only a save request made while the save was in flight causes another save. An appearance
	-- change made meanwhile is left for the next save of any kind (spec §3.4).
	if session.isAnotherSaveRequested then
		requestSaveWrite(self, session)
	end
end

startSaveWrite = function(self, session: PlayerSaveDataSession, saveAttemptKind: SaveAttemptKind)
	local isFinalSave = saveAttemptKind == "FinalSave"
	cancelIfPresent(session.cancelPendingSpacedSaveStart)
	session.cancelPendingSpacedSaveStart = nil
	session.isSaveInFlight = true
	session.isAnotherSaveRequested = false
	session.lastSaveStartedAtUnixSeconds = getCurrentUnixSeconds(self)
	-- Spec §3.4: note the revision when the save STARTS.
	local changeRevisionAtSaveStart = session.inMemoryChangeRevision
	local saveDataSnapshotAtSaveStart = createDeepCopyOfPlainTable(session.inMemorySaveData)

	local saveWriteDecision: ("Written" | "StoredLockNotOurs")? = nil
	local writtenSaveData = nil

	local function decideSaveWrite(storedSaveData: any): any
		-- May run more than once; every run starts from a clean decision.
		saveWriteDecision = nil
		writtenSaveData = nil
		local storedSessionLock = if type(storedSaveData) == "table" then storedSaveData.gameServerSessionLock else nil
		if type(storedSessionLock) ~= "table" or storedSessionLock.sessionLockId ~= session.sessionLockId then
			saveWriteDecision = "StoredLockNotOurs"
			return nil
		end
		local currentUnixSeconds = getCurrentUnixSeconds(self)
		local newStoredSaveData = createDeepCopyOfPlainTable(saveDataSnapshotAtSaveStart)
		newStoredSaveData.lastSavedAtUnixSeconds = currentUnixSeconds
		newStoredSaveData.gameServerSessionLock = if isFinalSave
			then nil
			else {
				sessionLockId = session.sessionLockId,
				lockRefreshedAtUnixSeconds = currentUnixSeconds,
			}
		saveWriteDecision = "Written"
		writtenSaveData = createDeepCopyOfPlainTable(newStoredSaveData)
		return newStoredSaveData
	end

	local function onSaveWriteFinished(wasStorageCallSuccessful: boolean, storageErrorMessage: string?)
		session.isSaveInFlight = false
		if session.sessionPhase ~= "Loaded" then
			return
		end

		if wasStorageCallSuccessful and saveWriteDecision == "StoredLockNotOurs" then
			handleStoredLockNotOurs(self, session)
			return
		end

		if wasStorageCallSuccessful and saveWriteDecision == "Written" then
			session.lastSavedChangeRevision = changeRevisionAtSaveStart
			session.inMemorySaveData.lastSavedAtUnixSeconds = writtenSaveData.lastSavedAtUnixSeconds
			session.inMemorySaveData.gameServerSessionLock =
				createDeepCopyOfPlainTable(writtenSaveData.gameServerSessionLock)
			session.failedSaveRetriesUsedInCurrentRound = 0
			setSaveDataPersistenceDelayed(self, session, false)
			fireEvent(self, "SaveDataSaveSucceeded", session.playerUserId, writtenSaveData)
			if isFinalSave then
				endSession(self, session, "FinalSaveSucceeded")
				return
			end
			continueAfterSuccessfulRegularSave(self, session)
			return
		end

		self.logger:logWarning(
			string.format(
				"PlayerSaveDataKeeper: %s for player %d failed: %s",
				saveAttemptKind,
				session.playerUserId,
				if wasStorageCallSuccessful
					then "storage reported success but no write decision was made"
					else tostring(storageErrorMessage)
			)
		)
		if isFinalSave then
			handleFailedFinalSave(self, session)
		else
			handleFailedRegularSave(self, session)
		end
	end

	startAtomicStorageUpdate(self, session.playerUserId, decideSaveWrite, onSaveWriteFinished)
end

local function startFinalSaveForSession(self, session: PlayerSaveDataSession)
	if session.sessionPhase == "Ended" then
		return
	end
	if session.sessionPhase == "Loading" then
		session.isLeaveRequestedWhileLoading = true
		if not session.isLoadInFlight then
			endSession(self, session, "LeftBeforeLoadFinished")
		end
		-- Otherwise the in-flight load finishes first; see onLoadAttemptFinished.
		return
	end
	if session.isFinalSaveRequested then
		return
	end
	session.isFinalSaveRequested = true
	cancelPendingRegularSaveTimers(session)
	if session.isSaveInFlight then
		-- At most one save in flight: the final save starts when the current one finishes.
		return
	end
	startSaveWrite(self, session, "FinalSave")
end

-- ── loading ─────────────────────────────────────────────────────────────────────────────────

local startLoadAttempt -- forward declaration

local function handleLoadAttemptNotTaken(self, session: PlayerSaveDataSession, whyNotTaken: string)
	self.logger:logInformation(
		string.format(
			"PlayerSaveDataKeeper: load attempt %d for player %d did not succeed: %s",
			session.loadAttemptCount,
			session.playerUserId,
			whyNotTaken
		)
	)
	if session.isLeaveRequestedWhileLoading then
		endSession(self, session, "LeftBeforeLoadFinished")
		return
	end
	local retriesUsed = session.loadAttemptCount - 1
	if retriesUsed >= PlayerSaveDataKeeper.LOAD_MAXIMUM_RETRY_COUNT then
		self.logger:logWarning(
			string.format(
				"PlayerSaveDataKeeper: load retries exhausted for player %d; removing the player",
				session.playerUserId
			)
		)
		self.removePlayerFromGameWithMessage(
			session.playerUserId,
			PlayerSaveDataKeeper.LOAD_RETRIES_EXHAUSTED_PLAYER_MESSAGE
		)
		endSession(self, session, "LoadRetriesExhausted")
		return
	end
	session.cancelPendingLoadRetry = scheduleAfterSeconds(
		self,
		PlayerSaveDataKeeper.LOAD_RETRY_DELAY_SECONDS,
		function()
			session.cancelPendingLoadRetry = nil
			if session.sessionPhase ~= "Loading" then
				return
			end
			startLoadAttempt(self, session)
		end
	)
end

startLoadAttempt = function(self, session: PlayerSaveDataSession)
	session.loadAttemptCount += 1
	session.isLoadInFlight = true
	local loadAttemptStartedAtUnixSeconds = getCurrentUnixSeconds(self)

	local loadDecision: ("TookExistingSave" | "CreatedStartingSave" | "HeldByAnotherServer" | "SchemaNotUnderstood")? =
		nil
	local schemaRefusalReason: string? = nil
	local loadedSaveData = nil

	local function decideLoadWrite(storedSaveData: any): any
		-- May run more than once; every run starts from a clean decision.
		loadDecision = nil
		schemaRefusalReason = nil
		loadedSaveData = nil
		local currentUnixSeconds = getCurrentUnixSeconds(self)
		local newStoredSaveData
		if storedSaveData == nil then
			newStoredSaveData = self.buildStartingPlayerSaveDataForNewPlayer(currentUnixSeconds)
			loadDecision = "CreatedStartingSave"
		else
			local storedSessionLock = if type(storedSaveData) == "table"
				then storedSaveData.gameServerSessionLock
				else nil
			if isStoredLockHeldByAnotherServer(storedSessionLock, session.sessionLockId, currentUnixSeconds) then
				loadDecision = "HeldByAnotherServer"
				return nil
			end
			local upgradedSaveData, refusalReason =
				PlayerSaveDataSchema.upgradeStoredPlayerSaveDataToCurrentSchema(storedSaveData)
			if upgradedSaveData == nil then
				-- Returning nil cancels the write: a save this code does not understand is never overwritten.
				loadDecision = "SchemaNotUnderstood"
				schemaRefusalReason = refusalReason
				return nil
			end
			newStoredSaveData = upgradedSaveData
			loadDecision = "TookExistingSave"
		end
		PlayerSaveDataSchema.replaceDailyProgressIfDailyDateKeyChanged(newStoredSaveData, currentUnixSeconds)
		newStoredSaveData.lastSavedAtUnixSeconds = currentUnixSeconds
		newStoredSaveData.gameServerSessionLock = {
			sessionLockId = session.sessionLockId,
			lockRefreshedAtUnixSeconds = currentUnixSeconds,
		}
		loadedSaveData = createDeepCopyOfPlainTable(newStoredSaveData)
		return newStoredSaveData
	end

	local function onLoadAttemptFinished(wasStorageCallSuccessful: boolean, storageErrorMessage: string?)
		session.isLoadInFlight = false
		if session.sessionPhase ~= "Loading" then
			return
		end

		local didTakeSave = wasStorageCallSuccessful
			and (loadDecision == "TookExistingSave" or loadDecision == "CreatedStartingSave")
		if didTakeSave then
			session.sessionPhase = "Loaded"
			session.inMemorySaveData = loadedSaveData
			session.inMemoryChangeRevision = 0
			session.lastSavedChangeRevision = 0
			-- The load wrote the save (our lock), so it counts as a save start for spacing.
			session.lastSaveStartedAtUnixSeconds = loadAttemptStartedAtUnixSeconds
			self.logger:logInformation(
				string.format(
					"PlayerSaveDataKeeper: player %d save loaded (%s) on attempt %d",
					session.playerUserId,
					tostring(loadDecision),
					session.loadAttemptCount
				)
			)
			if session.isLeaveRequestedWhileLoading then
				-- We now hold the lock; hand it back straight away.
				startFinalSaveForSession(self, session)
				return
			end
			schedulePeriodicSave(self, session)
			fireEvent(self, "PlayerSaveDataLoaded", session.playerUserId, loadedSaveData)
			return
		end

		if wasStorageCallSuccessful and loadDecision == "SchemaNotUnderstood" then
			self.logger:logWarning(
				string.format(
					"PlayerSaveDataKeeper: refusing to load player %d save: %s; the stored save is left untouched",
					session.playerUserId,
					tostring(schemaRefusalReason)
				)
			)
			self.removePlayerFromGameWithMessage(
				session.playerUserId,
				PlayerSaveDataKeeper.STORED_SCHEMA_VERSION_NOT_UNDERSTOOD_PLAYER_MESSAGE
			)
			endSession(self, session, "StoredSchemaVersionNotUnderstood")
			return
		end

		if wasStorageCallSuccessful and loadDecision == "HeldByAnotherServer" then
			handleLoadAttemptNotTaken(self, session, "save is locked by another server")
		elseif wasStorageCallSuccessful then
			handleLoadAttemptNotTaken(self, session, "storage reported success but no load decision was made")
		else
			handleLoadAttemptNotTaken(self, session, "storage error: " .. tostring(storageErrorMessage))
		end
	end

	startAtomicStorageUpdate(self, session.playerUserId, decideLoadWrite, onLoadAttemptFinished)
end

-- ── public API ──────────────────────────────────────────────────────────────────────────────

function PlayerSaveDataKeeper:startLoadingPlayerSaveData(playerUserId: number)
	if self.isShuttingDown then
		self.logger:logWarning(
			string.format("PlayerSaveDataKeeper: not loading player %d, the server is shutting down", playerUserId)
		)
		return
	end
	local existingSession = self.activeSessionByPlayerUserId[playerUserId]
	if
		existingSession
		and not existingSession.isFinalSaveRequested
		and not existingSession.isLeaveRequestedWhileLoading
	then
		self.logger:logWarning(
			string.format("PlayerSaveDataKeeper: player %d is already loading or loaded; ignored", playerUserId)
		)
		return
	end
	-- A previous session still finishing its final save keeps running on its own; the new one
	-- will find that session's lock and wait for it like any other server's lock.
	local session: PlayerSaveDataSession = {
		playerUserId = playerUserId,
		sessionLockId = self.generateUniqueSessionLockId(),
		sessionPhase = "Loading",
		loadAttemptCount = 0,
		isLoadInFlight = false,
		isLeaveRequestedWhileLoading = false,
		cancelPendingLoadRetry = nil,
		inMemorySaveData = nil,
		inMemoryChangeRevision = 0,
		lastSavedChangeRevision = 0,
		isChangeBeingApplied = false,
		isSaveInFlight = false,
		isAnotherSaveRequested = false,
		lastSaveStartedAtUnixSeconds = -math.huge,
		cancelPendingSpacedSaveStart = nil,
		failedSaveRetriesUsedInCurrentRound = 0,
		cancelPendingFailedSaveRetry = nil,
		cancelPendingPeriodicSave = nil,
		isSaveDataPersistenceDelayed = false,
		isFinalSaveRequested = false,
		finalSaveRetriesUsedCount = 0,
		cancelPendingFinalSaveRetry = nil,
	}
	self.activeSessionByPlayerUserId[playerUserId] = session
	self.unfinishedSessions[session] = true
	startLoadAttempt(self, session)
end

local function findLoadedSessionAcceptingChanges(self, playerUserId: number): PlayerSaveDataSession?
	local session = self.activeSessionByPlayerUserId[playerUserId]
	if session == nil or not isAcceptingRegularSaves(session) then
		return nil
	end
	return session
end

function PlayerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId: number): boolean
	return findLoadedSessionAcceptingChanges(self, playerUserId) ~= nil
end

function PlayerSaveDataKeeper:readPlayerSaveDataCopy(playerUserId: number)
	local session = findLoadedSessionAcceptingChanges(self, playerUserId)
	if session == nil then
		return nil
	end
	return createDeepCopyOfPlainTable(session.inMemorySaveData)
end

-- Runs the caller's decision once, on the draft, refusing to let it yield. Returns the decision.
local function runChangeDecisionWithoutYielding(
	playerUserId: number,
	changeDescription: string,
	decideAndApplyChange: (any) -> (boolean, string?),
	saveDataDraft: any
): (boolean, string?)
	local changeDecisionThread = coroutine.create(decideAndApplyChange)
	local didRunWithoutError, wasChangeAccepted, declineReason = coroutine.resume(changeDecisionThread, saveDataDraft)
	if not didRunWithoutError then
		error(
			string.format(
				"PlayerSaveDataKeeper: change %q for player %d raised: %s",
				changeDescription,
				playerUserId,
				tostring(wasChangeAccepted)
			),
			0
		)
	end
	if coroutine.status(changeDecisionThread) ~= "dead" then
		coroutine.close(changeDecisionThread)
		error(
			string.format(
				"PlayerSaveDataKeeper: change %q for player %d yielded; a change must not yield",
				changeDescription,
				playerUserId
			),
			0
		)
	end
	if type(wasChangeAccepted) ~= "boolean" then
		error(
			string.format(
				"PlayerSaveDataKeeper: change %q for player %d must return true (apply) or false (decline), got %s",
				changeDescription,
				playerUserId,
				tostring(wasChangeAccepted)
			),
			0
		)
	end
	return wasChangeAccepted, declineReason
end

function PlayerSaveDataKeeper:applyChangeToPlayerSaveData(
	playerUserId: number,
	playerSaveDataChangeKind: PlayerSaveDataChangeKind,
	changeDescription: string,
	decideAndApplyChange: (saveDataDraft: any) -> (boolean, string?)
): PlayerSaveDataChangeResult
	if
		playerSaveDataChangeKind ~= PlayerSaveDataKeeper.PROGRESS_CHANGE_SAVED_AT_ONCE
		and playerSaveDataChangeKind ~= PlayerSaveDataKeeper.APPEARANCE_CHANGE_SAVED_LATER
	then
		error("PlayerSaveDataKeeper: unknown playerSaveDataChangeKind " .. tostring(playerSaveDataChangeKind), 2)
	end
	if type(decideAndApplyChange) ~= "function" then
		error("PlayerSaveDataKeeper: decideAndApplyChange must be a function", 2)
	end
	local session = findLoadedSessionAcceptingChanges(self, playerUserId)
	if session == nil then
		self.logger:logWarning(
			string.format(
				"PlayerSaveDataKeeper: change %q refused for player %d: save not loaded or player leaving",
				tostring(changeDescription),
				playerUserId
			)
		)
		return { changeOutcome = "SaveDataNotLoaded" }
	end
	if session.isChangeBeingApplied then
		error(
			string.format(
				"PlayerSaveDataKeeper: change %q for player %d started inside another change of the same player",
				tostring(changeDescription),
				playerUserId
			),
			2
		)
	end

	local saveDataDraft = createDeepCopyOfPlainTable(session.inMemorySaveData)
	session.isChangeBeingApplied = true
	local didDecide, wasChangeAccepted, declineReason = pcall(
		runChangeDecisionWithoutYielding,
		playerUserId,
		tostring(changeDescription),
		decideAndApplyChange,
		saveDataDraft
	)
	session.isChangeBeingApplied = false
	if not didDecide then
		error(wasChangeAccepted, 0) -- nothing has changed
	end

	if not wasChangeAccepted then
		return { changeOutcome = "Declined", declineReason = declineReason }
	end
	for _, keeperManagedFieldName in KEEPER_MANAGED_SAVE_DATA_FIELD_NAMES do
		if
			not arePlainValuesDeeplyEqual(
				saveDataDraft[keeperManagedFieldName],
				session.inMemorySaveData[keeperManagedFieldName]
			)
		then
			error(
				string.format(
					"PlayerSaveDataKeeper: change %q for player %d edited the keeper-managed field %s",
					tostring(changeDescription),
					playerUserId,
					keeperManagedFieldName
				),
				2
			)
		end
	end
	-- Spec §2.13: a change that leaves the save exactly as it was is not a change.
	if arePlainValuesDeeplyEqual(saveDataDraft, session.inMemorySaveData) then
		return { changeOutcome = "AppliedWithoutAnyDifference" }
	end

	session.inMemorySaveData = saveDataDraft
	session.inMemoryChangeRevision += 1
	local inMemoryChangeRevisionAfterChange = session.inMemoryChangeRevision
	fireEvent(self, "InMemorySaveDataChanged", playerUserId, saveDataDraft)
	if playerSaveDataChangeKind == PlayerSaveDataKeeper.PROGRESS_CHANGE_SAVED_AT_ONCE then
		requestSaveWrite(self, session)
	end
	return { changeOutcome = "Applied", inMemoryChangeRevision = inMemoryChangeRevisionAfterChange }
end

function PlayerSaveDataKeeper:isSaveDataPersistenceDelayed(playerUserId: number): boolean
	local session = self.activeSessionByPlayerUserId[playerUserId]
	return session ~= nil and session.isSaveDataPersistenceDelayed
end

function PlayerSaveDataKeeper:readSaveChangeRevisions(playerUserId: number): (number?, number?)
	local session = self.activeSessionByPlayerUserId[playerUserId]
	if session == nil or session.sessionPhase ~= "Loaded" then
		return nil, nil
	end
	return session.inMemoryChangeRevision, session.lastSavedChangeRevision
end

function PlayerSaveDataKeeper:startFinalSaveForLeavingPlayer(playerUserId: number)
	local session = self.activeSessionByPlayerUserId[playerUserId]
	if session == nil then
		return
	end
	startFinalSaveForSession(self, session)
end

function PlayerSaveDataKeeper:startFinalSavesForServerShutdown(onEveryFinalSaveFinished: () -> ())
	if self.isShuttingDown then
		error("PlayerSaveDataKeeper: shutdown final saves were already started", 2)
	end
	self.isShuttingDown = true
	self.onEveryShutdownFinalSaveFinished = onEveryFinalSaveFinished
	local sessionsToFinish = {}
	for session in self.unfinishedSessions do
		table.insert(sessionsToFinish, session)
	end
	for _, session in sessionsToFinish do
		startFinalSaveForSession(self, session)
	end
	reportShutdownFinishedIfEverySessionEnded(self)
end

return PlayerSaveDataKeeper
