-- Runs the REAL PlayerSaveDataKeeper and RewardLedger on a simulated game server that can crash,
-- over one FakePlayerSaveDataStorage that outlives every server (it plays Roblox cloud storage).
-- Not a spec file; the RewardLedger spec files require it.
--
-- A crash is simulated exactly as a dead server behaves:
--   * the dead server's keeper never runs again: its timers live on its own FakeScheduler, which
--     nobody advances any more, and its storage connection drops every later request and answer;
--   * each storage write it had in flight either never arrives ("InFlightWritesLost") or arrives
--     with its answer lost ("InFlightWritesLanded");
--   * its session lock is left in storage, so time moves past SESSION_LOCK_EXPIRY_SECONDS before
--     the next server loads the player.
-- The next server is a fresh keeper and ledger over the same storage and clock.

local FakeClock = require("../Support/FakeClock")
local FakePlayerSaveDataStorage = require("../Support/FakePlayerSaveDataStorage")
local FakeScheduler = require("../Support/FakeScheduler")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataKeeperTestHarness = require("./PlayerSaveDataKeeperTestHarness")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local RewardLedger = require("../../src/server/RewardLedger")

local RewardLedgerCrashableServerTestHarness = {}

RewardLedgerCrashableServerTestHarness.EXAMPLE_PLAYER_USER_ID = PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID
RewardLedgerCrashableServerTestHarness.OTHER_PLAYER_USER_ID = PlayerSaveDataKeeperTestHarness.OTHER_PLAYER_USER_ID
RewardLedgerCrashableServerTestHarness.STARTER_DANCE_IDS = PlayerSaveDataKeeperTestHarness.STARTER_DANCE_IDS

export type InFlightWriteFate = "InFlightWritesLost" | "InFlightWritesLanded"

-- Forwards to the shared storage while its server is alive; afterwards drops requests and answers.
local function createStorageConnectionThatDiesWithItsServer(sharedFakePlayerSaveDataStorage)
	local storageConnection = { isServerAlive = true }
	function storageConnection.startAtomicPlayerSaveDataUpdate(
		_,
		playerUserId: number,
		decideNewStoredPlayerSaveData,
		onUpdateFinished
	)
		if not storageConnection.isServerAlive then
			return
		end
		sharedFakePlayerSaveDataStorage:startAtomicPlayerSaveDataUpdate(
			playerUserId,
			decideNewStoredPlayerSaveData,
			function(wasStorageCallSuccessful: boolean, storageErrorMessage: string?)
				if storageConnection.isServerAlive then
					onUpdateFinished(wasStorageCallSuccessful, storageErrorMessage)
				end
			end
		)
	end
	return storageConnection
end

local function createRecordingLogger()
	local recordingLogger = { loggedInformation = {}, loggedWarnings = {} }
	function recordingLogger.logInformation(self, message: string)
		table.insert(self.loggedInformation, message)
	end
	function recordingLogger.logWarning(self, message: string)
		table.insert(self.loggedWarnings, message)
	end
	return recordingLogger
end

-- `options.themedRoundCompletionRecordWriters` is passed to every server's ledger.
function RewardLedgerCrashableServerTestHarness.createHarness(options: { themedRoundCompletionRecordWriters: any? }?)
	local fakeClock = FakeClock.new(PlayerSaveDataKeeperTestHarness.EXAMPLE_STARTING_UNIX_SECONDS)
	local fakePlayerSaveDataStorage = FakePlayerSaveDataStorage.new(fakeClock)
	local nextSessionLockNumber = 0
	local harness = {
		fakeClock = fakeClock,
		fakePlayerSaveDataStorage = fakePlayerSaveDataStorage,
		currentServer = nil :: any,
		crashedServerCount = 0,
	}

	function harness.startNewServer()
		assert(harness.currentServer == nil, "harness: crash the current server before starting another")
		local storageConnection = createStorageConnectionThatDiesWithItsServer(fakePlayerSaveDataStorage)
		local fakeScheduler = FakeScheduler.new(fakeClock)
		local keeperLogger = createRecordingLogger()
		local ledgerLogger = createRecordingLogger()
		local playerSaveDataKeeper = PlayerSaveDataKeeper.new({
			playerSaveDataStorage = storageConnection,
			clock = fakeClock,
			scheduler = fakeScheduler,
			removePlayerFromGameWithMessage = function() end,
			logger = keeperLogger,
			generateUniqueSessionLockId = function()
				nextSessionLockNumber += 1
				return "server-lock-" .. tostring(nextSessionLockNumber)
			end,
			buildStartingPlayerSaveDataForNewPlayer = function(currentUnixSeconds: number)
				return PlayerSaveDataSchema.createStartingPlayerSaveData(
					RewardLedgerCrashableServerTestHarness.STARTER_DANCE_IDS,
					currentUnixSeconds
				)
			end,
		})
		local rewardLedger = RewardLedger.new({
			playerSaveDataKeeper = playerSaveDataKeeper,
			logger = ledgerLogger,
			themedRoundCompletionRecordWriters = if options then options.themedRoundCompletionRecordWriters else nil,
		})
		harness.currentServer = {
			storageConnection = storageConnection,
			fakeScheduler = fakeScheduler,
			playerSaveDataKeeper = playerSaveDataKeeper,
			rewardLedger = rewardLedger,
			keeperLogger = keeperLogger,
			ledgerLogger = ledgerLogger,
		}
		return harness.currentServer
	end

	-- Starts a server (if none is running) and loads the player, storage answering at once.
	function harness.startServerAndLoadPlayer(playerUserId: number)
		local server = harness.currentServer or harness.startNewServer()
		server.playerSaveDataKeeper:startLoadingPlayerSaveData(playerUserId)
		fakePlayerSaveDataStorage:completeOldestPendingOperation(playerUserId)
		assert(server.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId), "harness: the load should succeed")
		return server
	end

	function harness.crashCurrentServer(inFlightWriteFate: InFlightWriteFate)
		local server = harness.currentServer
		assert(server ~= nil, "harness: no server is running")
		server.storageConnection.isServerAlive = false
		while fakePlayerSaveDataStorage:countPendingOperations() > 0 do
			if inFlightWriteFate == "InFlightWritesLanded" then
				fakePlayerSaveDataStorage:completeOldestPendingOperation()
			else
				fakePlayerSaveDataStorage:failOldestPendingOperation()
			end
		end
		harness.currentServer = nil
		harness.crashedServerCount += 1
		-- The dead server's lock must expire before another server may load the player.
		fakeClock:advanceBySeconds(PlayerSaveDataKeeper.SESSION_LOCK_EXPIRY_SECONDS + 1)
	end

	function harness.advanceSeconds(elapsedSeconds: number)
		harness.currentServer.fakeScheduler:advanceTimeAndRunDueCallbacks(elapsedSeconds)
	end

	function harness.readStoredSaveData(playerUserId: number)
		return fakePlayerSaveDataStorage:readStoredPlayerSaveData(playerUserId)
	end

	function harness.readInMemorySaveData(playerUserId: number)
		return harness.currentServer.playerSaveDataKeeper:readPlayerSaveDataCopy(playerUserId)
	end

	-- Puts a returning player's save into storage before any server loads it.
	function harness.storeExistingPlayerSaveData(playerUserId: number, adjustStartingSaveData: (any) -> ())
		local existingSaveData = PlayerSaveDataSchema.createStartingPlayerSaveData(
			RewardLedgerCrashableServerTestHarness.STARTER_DANCE_IDS,
			fakeClock:getCurrentUnixSeconds()
		)
		adjustStartingSaveData(existingSaveData)
		fakePlayerSaveDataStorage:setStoredPlayerSaveData(playerUserId, existingSaveData)
	end

	return harness
end

-- A harness with the example player loaded on a running server, 20 s after loading (so a save
-- requested now starts at once). Returns harness, server.
function RewardLedgerCrashableServerTestHarness.createHarnessWithLoadedPlayer(
	adjustStartingSaveData: ((any) -> ())?,
	options: {
		themedRoundCompletionRecordWriters: any?,
	}?
)
	local harness = RewardLedgerCrashableServerTestHarness.createHarness(options)
	if adjustStartingSaveData then
		harness.storeExistingPlayerSaveData(
			RewardLedgerCrashableServerTestHarness.EXAMPLE_PLAYER_USER_ID,
			adjustStartingSaveData
		)
	end
	local server = harness.startServerAndLoadPlayer(RewardLedgerCrashableServerTestHarness.EXAMPLE_PLAYER_USER_ID)
	harness.advanceSeconds(20)
	return harness, server
end

return RewardLedgerCrashableServerTestHarness
