-- Builds a PlayerSaveDataKeeper wired to fakes (FakeClock, FakeScheduler, FakePlayerSaveDataStorage)
-- and records everything the keeper tells the outside world: removed players, log lines, events.
-- Not a spec file; the archivist and leaderboard spec files require it.

local process = require("@lune/process")

local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local FakePlayerSaveDataStorage = require("../Support/FakePlayerSaveDataStorage")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local UnitTestExpectations = require("../Support/UnitTestExpectations")

local PlayerSaveDataKeeperTestHarness = {}

-- 2025-11-19 00:00:00 UTC; a whole number so integer advances give exact times.
PlayerSaveDataKeeperTestHarness.EXAMPLE_STARTING_UNIX_SECONDS = 1_763_510_400
PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID = 8801
PlayerSaveDataKeeperTestHarness.OTHER_PLAYER_USER_ID = 8802
PlayerSaveDataKeeperTestHarness.STARTER_DANCE_IDS = { "starter_wave", "starter_step" }
PlayerSaveDataKeeperTestHarness.OTHER_SERVER_SESSION_LOCK_ID = "other-server-lock"

local PROGRESS = PlayerSaveDataKeeper.PROGRESS_CHANGE_SAVED_AT_ONCE
local APPEARANCE = PlayerSaveDataKeeper.APPEARANCE_CHANGE_SAVED_LATER

function PlayerSaveDataKeeperTestHarness.createKeeperWithFakes()
	local fakeClock = FakeClock.new(PlayerSaveDataKeeperTestHarness.EXAMPLE_STARTING_UNIX_SECONDS)
	local fakeScheduler = FakeScheduler.new(fakeClock)
	local fakePlayerSaveDataStorage = FakePlayerSaveDataStorage.new(fakeClock)
	local removedPlayerRecords = {}
	local loggedWarnings = {}
	local loggedInformation = {}
	local nextSessionLockNumber = 0

	local recordingLogger = {}
	function recordingLogger.logInformation(_, message: string)
		table.insert(loggedInformation, message)
	end
	function recordingLogger.logWarning(_, message: string)
		table.insert(loggedWarnings, message)
	end

	local playerSaveDataKeeper = PlayerSaveDataKeeper.new({
		playerSaveDataStorage = fakePlayerSaveDataStorage,
		clock = fakeClock,
		scheduler = fakeScheduler,
		removePlayerFromGameWithMessage = function(playerUserId: number, playerFacingMessage: string)
			table.insert(
				removedPlayerRecords,
				{ playerUserId = playerUserId, playerFacingMessage = playerFacingMessage }
			)
		end,
		logger = recordingLogger,
		generateUniqueSessionLockId = function()
			nextSessionLockNumber += 1
			return "this-server-lock-" .. tostring(nextSessionLockNumber)
		end,
		buildStartingPlayerSaveDataForNewPlayer = function(currentUnixSeconds: number)
			return PlayerSaveDataSchema.createStartingPlayerSaveData(
				PlayerSaveDataKeeperTestHarness.STARTER_DANCE_IDS,
				currentUnixSeconds
			)
		end,
	})

	local harness = {
		fakeClock = fakeClock,
		fakeScheduler = fakeScheduler,
		fakePlayerSaveDataStorage = fakePlayerSaveDataStorage,
		playerSaveDataKeeper = playerSaveDataKeeper,
		removedPlayerRecords = removedPlayerRecords,
		loggedWarnings = loggedWarnings,
		loggedInformation = loggedInformation,
	}

	function harness.secondsSinceStart(): number
		return fakeClock:getCurrentUnixSeconds() - PlayerSaveDataKeeperTestHarness.EXAMPLE_STARTING_UNIX_SECONDS
	end

	function harness.advanceSeconds(elapsedSeconds: number)
		fakeScheduler:advanceTimeAndRunDueCallbacks(elapsedSeconds)
	end

	-- Start times (seconds since the harness started) of every storage operation for a player.
	function harness.listOperationStartOffsets(playerUserId: number): { number }
		local startOffsets = {}
		for _, startedRecord in fakePlayerSaveDataStorage.startedOperationRecords do
			if startedRecord.playerUserId == playerUserId then
				table.insert(
					startOffsets,
					startedRecord.startedAtUnixSeconds - PlayerSaveDataKeeperTestHarness.EXAMPLE_STARTING_UNIX_SECONDS
				)
			end
		end
		return startOffsets
	end

	-- Records every event of every kind, as { eventName, playerUserId, eventValue }.
	function harness.recordEveryEvent()
		local recordedEvents = {}
		local function recordInto(eventName: string)
			return function(playerUserId, eventValue)
				table.insert(
					recordedEvents,
					{ eventName = eventName, playerUserId = playerUserId, eventValue = eventValue }
				)
			end
		end
		playerSaveDataKeeper:subscribeToPlayerSaveDataLoaded(recordInto("PlayerSaveDataLoaded"))
		playerSaveDataKeeper:subscribeToInMemorySaveDataChanged(recordInto("InMemorySaveDataChanged"))
		playerSaveDataKeeper:subscribeToSaveDataSaveSucceeded(recordInto("SaveDataSaveSucceeded"))
		playerSaveDataKeeper:subscribeToSaveDataPersistenceDelayedChanged(
			recordInto("SaveDataPersistenceDelayedChanged")
		)
		playerSaveDataKeeper:subscribeToPlayerSaveDataSessionEnded(recordInto("PlayerSaveDataSessionEnded"))
		return recordedEvents
	end

	-- Loads a new player with the storage completing the load at once; leaves the storage in
	-- "hold operations in flight" mode afterwards.
	function harness.loadNewPlayer(playerUserId: number)
		playerSaveDataKeeper:startLoadingPlayerSaveData(playerUserId)
		fakePlayerSaveDataStorage:completeOldestPendingOperation(playerUserId)
		assert(playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId), "harness: the load should have succeeded")
	end

	function harness.grantStarCoins(playerUserId: number, starCoinAmount: number)
		return playerSaveDataKeeper:applyChangeToPlayerSaveData(
			playerUserId,
			PROGRESS,
			"test grant",
			function(saveDataDraft)
				saveDataDraft.starCoinBalance += starCoinAmount
				return true
			end
		)
	end

	function harness.grantFans(playerUserId: number, fanAmount: number)
		return playerSaveDataKeeper:applyChangeToPlayerSaveData(
			playerUserId,
			PROGRESS,
			"test fan grant",
			function(saveDataDraft)
				saveDataDraft.fanCount += fanAmount
				return true
			end
		)
	end

	function harness.equipDance(playerUserId: number, danceId: string)
		return playerSaveDataKeeper:applyChangeToPlayerSaveData(
			playerUserId,
			APPEARANCE,
			"test equip",
			function(saveDataDraft)
				saveDataDraft.equippedDanceId = danceId
				return true
			end
		)
	end

	return harness
end

-- A save as another server would have stored it, holding that server's lock.
function PlayerSaveDataKeeperTestHarness.createStoredSaveLockedByOtherServer(lockRefreshedAtUnixSeconds: number)
	local storedSaveData = PlayerSaveDataSchema.createStartingPlayerSaveData(
		PlayerSaveDataKeeperTestHarness.STARTER_DANCE_IDS,
		PlayerSaveDataKeeperTestHarness.EXAMPLE_STARTING_UNIX_SECONDS - 86400 * 30
	)
	storedSaveData.fanCount = 1200
	storedSaveData.starCoinBalance = 350
	storedSaveData.gameServerSessionLock = {
		sessionLockId = PlayerSaveDataKeeperTestHarness.OTHER_SERVER_SESSION_LOCK_ID,
		lockRefreshedAtUnixSeconds = lockRefreshedAtUnixSeconds,
	}
	return storedSaveData
end

-- Randomized tests: one seed per run (or IDOLGROW_RANDOM_TEST_SEED), printed on failure.
local RANDOM_TEST_SEED_ENVIRONMENT_VARIABLE = "IDOLGROW_RANDOM_TEST_SEED"

local function chooseRandomTestSeed(): number
	local seedOverrideText = process.env[RANDOM_TEST_SEED_ENVIRONMENT_VARIABLE]
	if seedOverrideText ~= nil and seedOverrideText ~= "" then
		local seedOverride = tonumber(seedOverrideText)
		assert(
			seedOverride ~= nil and seedOverride % 1 == 0,
			RANDOM_TEST_SEED_ENVIRONMENT_VARIABLE .. " must be a whole number"
		)
		return seedOverride :: number
	end
	return (os.time() * 1000 + math.floor(os.clock() * 1000000)) % 2147483647 + 1
end

PlayerSaveDataKeeperTestHarness.RANDOM_TEST_SEED = chooseRandomTestSeed()

-- Runs `trialBody(trialNumber)` `trialCount` times after seeding math.random with this run's seed.
-- A failure message is prefixed with the seed so the run can be reproduced exactly.
function PlayerSaveDataKeeperTestHarness.runSeededRandomTrials(trialCount: number, trialBody: (number) -> ())
	local randomTestSeed = PlayerSaveDataKeeperTestHarness.RANDOM_TEST_SEED
	math.randomseed(randomTestSeed)
	for trialNumber = 1, trialCount do
		local didTrialPass, trialError = pcall(trialBody, trialNumber)
		if not didTrialPass then
			local reproductionHint = string.format(
				"[random trial %d of %d failed with seed %d; reproduce with %s=%d] ",
				trialNumber,
				trialCount,
				randomTestSeed,
				RANDOM_TEST_SEED_ENVIRONMENT_VARIABLE,
				randomTestSeed
			)
			print("        " .. reproductionHint)
			if UnitTestExpectations.isExpectationFailure(trialError) then
				trialError.failureMessage = reproductionHint .. trialError.failureMessage
				error(trialError, 0)
			end
			error(reproductionHint .. tostring(trialError), 0)
		end
	end
end

return PlayerSaveDataKeeperTestHarness
