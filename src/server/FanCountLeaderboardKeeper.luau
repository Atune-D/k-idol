-- FanCountLeaderboardKeeper (development spec v1.2 §1.11, §2.11, §3.5): keeps the global fan
-- leaderboard in step with SAVED fan counts and caches the top 100 for devices.
--
-- Calls no Roblox-specific interface. Everything external is injected (see `new`).
--
-- Rules it enforces:
--   * fanCount is taken ONLY from PlayerSaveDataKeeper's "save succeeded" event (and from the
--     "loaded" event, whose copy is exactly what storage holds), never from the in-memory save.
--   * After a player's save loads: sync once (catch-up for a server that crashed after saving
--     and before syncing). After each successful save: sync if the saved fanCount differs from
--     lastLeaderboardSyncedFanCount.
--   * A failed sync is not retried and nothing is shown to the player; it is compared again
--     after the next successful save. Nothing here ever raises into the save keeper.
--   * Each write is the storage's atomic "keep the larger" operation, so writes completing out
--     of order never lower the stored value.
--   * The top 100 are read when started and then every 60 s; devices only read the cache.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- FanCountLeaderboardKeeper.new(dependencies) -> keeper
--   dependencies = {
--     playerSaveDataKeeper: the PlayerSaveDataKeeper (only its subscribe* methods are used),
--     fanCountLeaderboardStorage: FanCountLeaderboardStorage   (interface below),
--     clock: { getCurrentUnixSeconds: (self) -> number },
--     scheduler: { scheduleCallbackAfterSeconds: (self, delaySeconds, callback) -> cancelCallback },
--     logger: { logInformation: (self, message: string) -> (), logWarning: (self, message: string) -> () },
--     lookUpPlayerDisplayNamesByUserId: (playerUserIds: { number }) -> { [number]: string },
--         May yield (it is only called from the top-entries refresh, after the storage read
--         finished). A missing name, or a lookup that raises, falls back to "Player <userId>".
--   }
-- keeper:startSyncingAndRefreshingTopEntries()
--   Subscribes to the save keeper's events and starts the top-100 refresh (now, then every 60 s).
--   Call once.
-- keeper:readTopEntriesAnswer() -> { leaderboardEntries, refreshedAtUnixSeconds }
--   The §2.11 answer from the cache (a fresh copy each call). Each entry is
--   { leaderboardRank, playerUserId, playerDisplayName, fanCount }, at most 100, highest first.
--   Before the first successful refresh: leaderboardEntries = {} and refreshedAtUnixSeconds = nil.
-- keeper:readLastLeaderboardSyncedFanCount(playerUserId) -> number?
--   The last fanCount this server successfully wrote for an online player (nil if none yet).
--
-- FanCountLeaderboardStorage interface (implemented by RobloxFanCountLeaderboardStorage and by
-- tests/Support/FakeFanCountLeaderboardStorage):
--   storage:startKeepingLargerFanCount(playerUserId, fanCountBeingWritten, onWriteFinished)
--     Starts ONE atomic operation storing max(stored value, fanCountBeingWritten); returns at once.
--     onWriteFinished(wasWriteSuccessful: boolean, storageErrorMessage: string?) is called once.
--   storage:startReadingTopFanCountEntries(maximumEntryCount, onReadFinished)
--     Starts reading the highest entries; returns at once. onReadFinished(wasReadSuccessful,
--     topFanCountEntries: { { playerUserId, fanCount } }? (highest first), storageErrorMessage?)
--     is called once.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local FanCountLeaderboardKeeper = {}
FanCountLeaderboardKeeper.__index = FanCountLeaderboardKeeper

FanCountLeaderboardKeeper.TOP_ENTRIES_REFRESH_INTERVAL_SECONDS = 60
FanCountLeaderboardKeeper.MAXIMUM_TOP_ENTRY_COUNT = 100

export type FanCountLeaderboardEntry = {
	leaderboardRank: number,
	playerUserId: number,
	playerDisplayName: string,
	fanCount: number,
}

function FanCountLeaderboardKeeper.new(dependencies)
	for _, requiredDependencyName in
		{
			"playerSaveDataKeeper",
			"fanCountLeaderboardStorage",
			"clock",
			"scheduler",
			"logger",
			"lookUpPlayerDisplayNamesByUserId",
		}
	do
		if dependencies[requiredDependencyName] == nil then
			error("FanCountLeaderboardKeeper.new: missing dependency " .. requiredDependencyName, 2)
		end
	end
	return setmetatable({
		playerSaveDataKeeper = dependencies.playerSaveDataKeeper,
		fanCountLeaderboardStorage = dependencies.fanCountLeaderboardStorage,
		clock = dependencies.clock,
		scheduler = dependencies.scheduler,
		logger = dependencies.logger,
		lookUpPlayerDisplayNamesByUserId = dependencies.lookUpPlayerDisplayNamesByUserId,

		hasStarted = false,
		-- Present for every online player whose save has loaded; false until the first successful sync.
		lastLeaderboardSyncedFanCountByPlayerUserId = {} :: { [number]: number | false },
		isTopEntriesRefreshInFlight = false,
		cachedLeaderboardEntries = {} :: { FanCountLeaderboardEntry },
		cachedRefreshedAtUnixSeconds = nil :: number?,
	}, FanCountLeaderboardKeeper)
end

local function isWholeNonNegativeNumber(candidateNumber: any): boolean
	return type(candidateNumber) == "number"
		and candidateNumber >= 0
		and candidateNumber % 1 == 0
		and candidateNumber ~= math.huge
end

local function startSyncingSavedFanCount(self, playerUserId: number, savedFanCount: any)
	if not isWholeNonNegativeNumber(savedFanCount) then
		self.logger:logWarning(
			string.format(
				"FanCountLeaderboardKeeper: not syncing player %d, saved fanCount %s is not a whole number >= 0",
				playerUserId,
				tostring(savedFanCount)
			)
		)
		return
	end
	local function onWriteFinished(wasWriteSuccessful: boolean, storageErrorMessage: string?)
		if not wasWriteSuccessful then
			-- No retry and no message to the player (spec §3.5).
			self.logger:logWarning(
				string.format(
					"FanCountLeaderboardKeeper: sync of fanCount %d for player %d failed: %s",
					savedFanCount,
					playerUserId,
					tostring(storageErrorMessage)
				)
			)
			return
		end
		local lastSyncedFanCount = self.lastLeaderboardSyncedFanCountByPlayerUserId[playerUserId]
		if lastSyncedFanCount == nil then
			return -- the player has left meanwhile
		end
		-- Fans never decrease, so a write completing late never moves this backwards.
		if lastSyncedFanCount == false or savedFanCount > lastSyncedFanCount then
			self.lastLeaderboardSyncedFanCountByPlayerUserId[playerUserId] = savedFanCount
		end
	end
	local didStart, startError = pcall(function()
		self.fanCountLeaderboardStorage:startKeepingLargerFanCount(playerUserId, savedFanCount, onWriteFinished)
	end)
	if not didStart then
		onWriteFinished(false, "storage raised while starting: " .. tostring(startError))
	end
end

local function onPlayerSaveDataLoaded(self, playerUserId: number, loadedSaveDataCopy: any)
	self.lastLeaderboardSyncedFanCountByPlayerUserId[playerUserId] = false
	startSyncingSavedFanCount(self, playerUserId, loadedSaveDataCopy.fanCount)
end

local function onSaveDataSaveSucceeded(self, playerUserId: number, savedSaveDataCopy: any)
	local lastSyncedFanCount = self.lastLeaderboardSyncedFanCountByPlayerUserId[playerUserId]
	if lastSyncedFanCount == nil then
		return -- not loaded through this keeper; nothing to compare with
	end
	if savedSaveDataCopy.fanCount ~= lastSyncedFanCount then
		startSyncingSavedFanCount(self, playerUserId, savedSaveDataCopy.fanCount)
	end
end

local function onPlayerSaveDataSessionEnded(self, playerUserId: number)
	self.lastLeaderboardSyncedFanCountByPlayerUserId[playerUserId] = nil
end

local function buildLeaderboardEntries(self, topFanCountEntries: { any }): { FanCountLeaderboardEntry }
	local keptStorageEntries = {}
	for _, storageEntry in topFanCountEntries do
		if #keptStorageEntries >= FanCountLeaderboardKeeper.MAXIMUM_TOP_ENTRY_COUNT then
			break
		end
		if type(storageEntry.playerUserId) == "number" and type(storageEntry.fanCount) == "number" then
			table.insert(keptStorageEntries, storageEntry)
		end
	end

	local playerUserIds = {}
	for _, storageEntry in keptStorageEntries do
		table.insert(playerUserIds, storageEntry.playerUserId)
	end
	local didLookUp, displayNameByPlayerUserId = pcall(self.lookUpPlayerDisplayNamesByUserId, playerUserIds)
	if not didLookUp or type(displayNameByPlayerUserId) ~= "table" then
		self.logger:logWarning(
			"FanCountLeaderboardKeeper: display name lookup failed: " .. tostring(displayNameByPlayerUserId)
		)
		displayNameByPlayerUserId = {}
	end

	local leaderboardEntries = {}
	for entryPosition, storageEntry in keptStorageEntries do
		local lookedUpDisplayName = displayNameByPlayerUserId[storageEntry.playerUserId]
		table.insert(leaderboardEntries, {
			leaderboardRank = entryPosition,
			playerUserId = storageEntry.playerUserId,
			playerDisplayName = if type(lookedUpDisplayName) == "string"
				then lookedUpDisplayName
				else "Player " .. tostring(storageEntry.playerUserId),
			fanCount = storageEntry.fanCount,
		})
	end
	return leaderboardEntries
end

local function startRefreshingTopEntries(self)
	if self.isTopEntriesRefreshInFlight then
		return
	end
	self.isTopEntriesRefreshInFlight = true
	local hasFinished = false
	local function onReadFinished(
		wasReadSuccessful: boolean,
		topFanCountEntries: { any }?,
		storageErrorMessage: string?
	)
		if hasFinished then
			return
		end
		hasFinished = true
		if not wasReadSuccessful or type(topFanCountEntries) ~= "table" then
			self.isTopEntriesRefreshInFlight = false
			self.logger:logWarning(
				"FanCountLeaderboardKeeper: top entries refresh failed; keeping the previous cache: "
					.. tostring(storageErrorMessage)
			)
			return
		end
		local leaderboardEntries = buildLeaderboardEntries(self, topFanCountEntries)
		self.cachedLeaderboardEntries = leaderboardEntries
		self.cachedRefreshedAtUnixSeconds = self.clock:getCurrentUnixSeconds()
		self.isTopEntriesRefreshInFlight = false
	end
	local didStart, startError = pcall(function()
		self.fanCountLeaderboardStorage:startReadingTopFanCountEntries(
			FanCountLeaderboardKeeper.MAXIMUM_TOP_ENTRY_COUNT,
			onReadFinished
		)
	end)
	if not didStart then
		onReadFinished(false, nil, "storage raised while starting: " .. tostring(startError))
	end
end

local function scheduleNextTopEntriesRefresh(self)
	self.scheduler:scheduleCallbackAfterSeconds(
		FanCountLeaderboardKeeper.TOP_ENTRIES_REFRESH_INTERVAL_SECONDS,
		function()
			startRefreshingTopEntries(self)
			scheduleNextTopEntriesRefresh(self)
		end
	)
end

function FanCountLeaderboardKeeper:startSyncingAndRefreshingTopEntries()
	if self.hasStarted then
		error("FanCountLeaderboardKeeper: already started", 2)
	end
	self.hasStarted = true
	local playerSaveDataKeeper = self.playerSaveDataKeeper
	playerSaveDataKeeper:subscribeToPlayerSaveDataLoaded(function(playerUserId, loadedSaveDataCopy)
		onPlayerSaveDataLoaded(self, playerUserId, loadedSaveDataCopy)
	end)
	playerSaveDataKeeper:subscribeToSaveDataSaveSucceeded(function(playerUserId, savedSaveDataCopy)
		onSaveDataSaveSucceeded(self, playerUserId, savedSaveDataCopy)
	end)
	playerSaveDataKeeper:subscribeToPlayerSaveDataSessionEnded(function(playerUserId)
		onPlayerSaveDataSessionEnded(self, playerUserId)
	end)
	startRefreshingTopEntries(self)
	scheduleNextTopEntriesRefresh(self)
end

function FanCountLeaderboardKeeper:readTopEntriesAnswer()
	local leaderboardEntries = {}
	for _, cachedEntry in self.cachedLeaderboardEntries do
		table.insert(leaderboardEntries, table.clone(cachedEntry))
	end
	return {
		leaderboardEntries = leaderboardEntries,
		refreshedAtUnixSeconds = self.cachedRefreshedAtUnixSeconds,
	}
end

function FanCountLeaderboardKeeper:readLastLeaderboardSyncedFanCount(playerUserId: number): number?
	local lastSyncedFanCount = self.lastLeaderboardSyncedFanCountByPlayerUserId[playerUserId]
	if lastSyncedFanCount == false then
		return nil
	end
	return lastSyncedFanCount
end

return FanCountLeaderboardKeeper
