-- Random joins, leaves, quick rejoins, progress, round joins, time, and storage answers released
-- in random order (successes, failures, lost answers, answers held back and delivered late, kicks
-- turned into leaves, sometimes a shutdown), for two players on one server with the REAL keeper
-- and every REAL listener (QuickRejoinSameServerTestHarness). The seed is printed on failure;
-- rerun with IDOLGROW_RANDOM_TEST_SEED=<seed> to reproduce.
--
-- Invariants, checked after every step and at the end of each trial:
--   * listeners never see anything about a player's newer session before the older one ended
--     (QuickRejoinSameServerTestHarness.describeFirstSessionOverlap), and the keeper reports no
--     loaded save while it announces a session's end;
--   * at most one storage operation per player is unanswered at any time;
--   * no listener state of a live (loaded) session is discarded: stored-outfit availability,
--     leaderboard sync state, snapshot publishing with the right unavailable keys, round
--     participation, playtime counting;
--   * no progress is lost: a session that ends with "FinalSaveSucceeded" stored exactly what it
--     held, every load holds exactly what storage held, and stored balances never go down;
--   * a starting save never replaces a real one (every write keeps firstJoinedAtUnixSeconds).

local FakePlayerSaveDataStorageAnswerOrder = require("../Support/FakePlayerSaveDataStorageAnswerOrder")
local QuickRejoinSameServerTestHarness = require("./QuickRejoinSameServerTestHarness")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYERS = { QuickRejoinSameServerTestHarness.PLAYER_P, QuickRejoinSameServerTestHarness.PLAYER_Q }
local HIDDEN_HAIR_KEY = QuickRejoinSameServerTestHarness.HIDDEN_HAIR_KEY
local TRIAL_COUNT = 40
local STEPS_PER_TRIAL = 70
local SHUTDOWN_TRIAL_FRACTION = 0.2

local function expectInvariant(isHolding: boolean, failureDescription: string)
	if not isHolding then
		error(failureDescription, 0)
	end
end

-- Test-side bookkeeping, fed by keeper listeners subscribed after every real listener.
local function startWatchingSessions(harness, trialState)
	local keeper = harness.playerSaveDataKeeper
	local fakeStorage = harness.fakePlayerSaveDataStorage
	keeper:subscribeToPlayerSaveDataLoaded(function(playerUserId, loadedSaveDataCopy)
		local storedSaveData = fakeStorage:readStoredPlayerSaveData(playerUserId)
		expectInvariant(
			loadedSaveDataCopy.starCoinBalance == storedSaveData.starCoinBalance,
			"a load does not hold what storage holds"
		)
		trialState.expectedBalanceByPlayerUserId[playerUserId] = loadedSaveDataCopy.starCoinBalance
		trialState.joinedRoundIdByPlayerUserId[playerUserId] = nil
	end)
	keeper:subscribeToPlayerSaveDataSessionEnded(function(playerUserId, sessionEndReason)
		expectInvariant(not keeper:isPlayerSaveDataLoaded(playerUserId), "a session ended while a save is loaded")
		local expectedBalance = trialState.expectedBalanceByPlayerUserId[playerUserId]
		if sessionEndReason == "FinalSaveSucceeded" and expectedBalance ~= nil then
			expectInvariant(
				fakeStorage:readStoredPlayerSaveData(playerUserId).starCoinBalance == expectedBalance,
				"a successful final save did not store the session's balance"
			)
		end
		trialState.expectedBalanceByPlayerUserId[playerUserId] = nil
	end)
end

local function countUnansweredOperations(harness, trialState, playerUserId: number): number
	local unansweredCount = harness.countPendingOperations(playerUserId)
	for _, heldAnswerRecord in trialState.heldAnswerRecords do
		if heldAnswerRecord.playerUserId == playerUserId then
			unansweredCount += 1
		end
	end
	return unansweredCount
end

local function leaveIfConnected(harness, trialState, playerUserId: number)
	if trialState.isConnectedByPlayerUserId[playerUserId] then
		trialState.isConnectedByPlayerUserId[playerUserId] = false
		harness.leaveServer(playerUserId)
	end
end

-- Answers the pending operation at a random position, in one of four ways.
local function answerRandomPendingOperation(harness, trialState, randomGenerator, answerKind: string)
	local fakeStorage = harness.fakePlayerSaveDataStorage
	local pendingCount = harness.countPendingOperations()
	if pendingCount == 0 then
		return
	end
	FakePlayerSaveDataStorageAnswerOrder.movePendingOperationToFront(
		fakeStorage,
		randomGenerator.nextWholeNumberInRange(1, pendingCount)
	)
	if answerKind == "Succeed" then
		fakeStorage:completeOldestPendingOperation()
	elseif answerKind == "Fail" then
		fakeStorage:failOldestPendingOperation()
	elseif answerKind == "LandAndLoseAnswer" then
		fakeStorage:completeOldestPendingOperationButReportFailure()
	else
		local playerUserId = fakeStorage.pendingStorageOperations[1].playerUserId
		local heldStorageAnswer =
			FakePlayerSaveDataStorageAnswerOrder.landOldestPendingWriteAndHoldItsAnswer(fakeStorage)
		table.insert(
			trialState.heldAnswerRecords,
			{ playerUserId = playerUserId, heldStorageAnswer = heldStorageAnswer }
		)
	end
end

local function deliverRandomHeldAnswer(trialState, randomGenerator)
	if #trialState.heldAnswerRecords == 0 then
		return
	end
	local heldAnswerRecord = table.remove(
		trialState.heldAnswerRecords,
		randomGenerator.nextWholeNumberInRange(1, #trialState.heldAnswerRecords)
	)
	heldAnswerRecord.heldStorageAnswer:deliverAnswer(randomGenerator.nextFractionBetweenZeroAndOne() < 0.85)
end

local function startShutdown(harness, trialState)
	trialState.isShutdownStarted = true
	harness.dailyProgressTracker:recordCountedPlaytimeOfEveryPlayerAndStopCountingBeforeShutdown()
	harness.referee:beginServerShutdown()
	harness.playerSaveDataKeeper:startFinalSavesForServerShutdown(function()
		trialState.shutdownFinishedCount += 1
	end)
end

local function runOneRandomStep(harness, trialState, randomGenerator)
	local playerUserId = randomGenerator.pickRandomListElement(PLAYERS)
	local stepKind = randomGenerator.nextWholeNumberInRange(1, 12)
	if stepKind == 1 and not trialState.isConnectedByPlayerUserId[playerUserId] then
		trialState.isConnectedByPlayerUserId[playerUserId] = true
		harness.joinServer(playerUserId)
	elseif stepKind == 2 then
		leaveIfConnected(harness, trialState, playerUserId)
	elseif stepKind == 3 then
		local grantedAmount = randomGenerator.nextWholeNumberInRange(1, 50)
		local changeResult = harness.applyProgressChange(playerUserId, "starCoinBalance", grantedAmount)
		if changeResult.changeOutcome == "Applied" then
			local expectedBalance = trialState.expectedBalanceByPlayerUserId[playerUserId]
			expectInvariant(expectedBalance ~= nil, "a change was applied to a session listeners never saw load")
			trialState.expectedBalanceByPlayerUserId[playerUserId] = expectedBalance + grantedAmount
		end
	elseif stepKind == 4 then
		if harness.referee:admitOrRejectJoinCurrentRoundRequest(playerUserId).isAccepted then
			trialState.joinedRoundIdByPlayerUserId[playerUserId] = harness.readCurrentRoundId()
		end
	elseif stepKind == 5 then
		harness.fakeScheduler:advanceTimeAndRunDueCallbacks(randomGenerator.nextWholeNumberInRange(0, 6000) / 1000)
	elseif stepKind <= 8 then
		answerRandomPendingOperation(harness, trialState, randomGenerator, "Succeed")
	elseif stepKind == 9 then
		answerRandomPendingOperation(harness, trialState, randomGenerator, "Fail")
	elseif stepKind == 10 then
		answerRandomPendingOperation(harness, trialState, randomGenerator, "LandAndLoseAnswer")
	elseif stepKind == 11 then
		answerRandomPendingOperation(harness, trialState, randomGenerator, "LandAndHoldAnswer")
	else
		deliverRandomHeldAnswer(trialState, randomGenerator)
	end
	-- A player the keeper removed from the game is disconnected: the wiring's leave sequence runs.
	while trialState.processedRemovalCount < #harness.removedFromGamePlayerUserIds do
		trialState.processedRemovalCount += 1
		leaveIfConnected(harness, trialState, harness.removedFromGamePlayerUserIds[trialState.processedRemovalCount])
	end
end

local function checkInvariantsAfterStep(harness, trialState)
	for _, playerUserId in PLAYERS do
		expectInvariant(
			countUnansweredOperations(harness, trialState, playerUserId) <= 1,
			"two storage operations of one player are unanswered at once"
		)
		local overlapDescription =
			QuickRejoinSameServerTestHarness.describeFirstSessionOverlap(harness.listEventRecordsOf(playerUserId))
		expectInvariant(
			overlapDescription == nil,
			"listeners saw two sessions at once: " .. tostring(overlapDescription)
		)
		if harness.isLoaded(playerUserId) then
			local availability = harness.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(playerUserId)
			expectInvariant(availability ~= nil, "StoredLobbyOutfitKeeper forgot a loaded player")
			expectInvariant(
				harness.fanCountLeaderboardKeeper:readLastLeaderboardSyncedFanCount(playerUserId) ~= nil,
				"FanCountLeaderboardKeeper forgot a loaded player"
			)
			expectInvariant(
				harness.publisher:isPublishingToPlayer(playerUserId),
				"the publisher forgot a loaded player"
			)
			local snapshotMessages = harness.listSnapshotMessagesSentTo(playerUserId)
			expectInvariant(
				table.concat(snapshotMessages[#snapshotMessages].unavailableLobbyOutfitStylingItemKeys, ",")
					== HIDDEN_HAIR_KEY,
				"the last snapshot message lacks the unavailable stored key"
			)
			local joinedRoundId = trialState.joinedRoundIdByPlayerUserId[playerUserId]
			if joinedRoundId ~= nil and joinedRoundId == harness.readCurrentRoundId() then
				expectInvariant(
					harness.referee:isParticipantOfCurrentRound(playerUserId),
					"the referee dropped a loaded player from the round they joined"
				)
			end
		end
	end
	expectInvariant(
		#harness.publisherLogger.loggedWarnings == 0,
		"the publisher fell back: " .. tostring(harness.publisherLogger.loggedWarnings[1])
	)
end

local function checkPlaytimeIsCountedForLoadedPlayers(harness)
	local playtimeBeforeByPlayerUserId = {}
	for _, playerUserId in PLAYERS do
		if harness.isLoaded(playerUserId) then
			playtimeBeforeByPlayerUserId[playerUserId] = harness.readInMemoryPlaytimeSecondsToday(playerUserId)
		end
	end
	harness.fakeScheduler:advanceTimeAndRunDueCallbacks(61)
	for playerUserId, playtimeBefore in playtimeBeforeByPlayerUserId do
		if harness.isLoaded(playerUserId) then
			expectInvariant(
				harness.readInMemoryPlaytimeSecondsToday(playerUserId) > playtimeBefore,
				"DailyProgressTracker stopped counting a loaded player"
			)
		end
	end
end

-- Every held answer is delivered and every operation succeeds, with time passing for retries.
local function letStorageRecover(harness, trialState)
	for _ = 1, 40 do
		while #trialState.heldAnswerRecords > 0 do
			table.remove(trialState.heldAnswerRecords, 1).heldStorageAnswer:deliverAnswer(true)
		end
		harness.completeEveryPendingOperation()
		harness.fakeScheduler:advanceTimeAndRunDueCallbacks(5)
	end
end

local function checkEveryWriteOfThePlayer(harness, playerUserId: number, firstJoinedAtUnixSeconds: number)
	local previousStoredBalance = QuickRejoinSameServerTestHarness.STORED_STAR_COIN_BALANCE
	for _, writtenRecord in harness.fakePlayerSaveDataStorage.writtenPlayerSaveDataRecords do
		if writtenRecord.playerUserId == playerUserId then
			local writtenSaveData = writtenRecord.writtenPlayerSaveData
			expectInvariant(
				writtenSaveData.firstJoinedAtUnixSeconds == firstJoinedAtUnixSeconds,
				"a starting save replaced the real one"
			)
			expectInvariant(writtenSaveData.starCoinBalance >= previousStoredBalance, "a stored balance went down")
			previousStoredBalance = writtenSaveData.starCoinBalance
		end
	end
end

local function runOneTrial(randomGenerator)
	local harness = QuickRejoinSameServerTestHarness.createHarness()
	local trialState = {
		isConnectedByPlayerUserId = {},
		expectedBalanceByPlayerUserId = {},
		joinedRoundIdByPlayerUserId = {},
		heldAnswerRecords = {},
		processedRemovalCount = 0,
		isShutdownStarted = false,
		shutdownFinishedCount = 0,
	}
	for _, playerUserId in PLAYERS do
		harness.storeSaveWithHiddenLobbyItem(playerUserId)
	end
	local firstJoinedAtUnixSeconds =
		harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYERS[1]).firstJoinedAtUnixSeconds
	startWatchingSessions(harness, trialState)
	local shutdownStep = if randomGenerator.nextFractionBetweenZeroAndOne() < SHUTDOWN_TRIAL_FRACTION
		then randomGenerator.nextWholeNumberInRange(1, STEPS_PER_TRIAL)
		else nil
	for stepNumber = 1, STEPS_PER_TRIAL do
		if stepNumber == shutdownStep then
			startShutdown(harness, trialState)
		end
		runOneRandomStep(harness, trialState, randomGenerator)
		checkInvariantsAfterStep(harness, trialState)
	end
	checkPlaytimeIsCountedForLoadedPlayers(harness)

	for _, playerUserId in PLAYERS do
		leaveIfConnected(harness, trialState, playerUserId)
	end
	letStorageRecover(harness, trialState)
	checkInvariantsAfterStep(harness, trialState)
	for _, playerUserId in PLAYERS do
		expectInvariant(not harness.isLoaded(playerUserId), "a player who left is still loaded")
		checkEveryWriteOfThePlayer(harness, playerUserId, firstJoinedAtUnixSeconds)
	end
	expectInvariant(harness.countPendingOperations() == 0, "storage operations were left in flight")
	if trialState.isShutdownStarted then
		expectInvariant(trialState.shutdownFinishedCount == 1, "shutdown did not report finishing exactly once")
	end
end

describe("PlayerSaveDataKeeper quick rejoin, randomized", function()
	it("keeps sessions apart for listeners, keeps live listener state, loses no progress", function()
		SeededRandomTrials.runSeededRandomTrials(TRIAL_COUNT, function(randomGenerator)
			runOneTrial(randomGenerator)
		end)
		expect(true).toBeTrue()
	end)
end)
