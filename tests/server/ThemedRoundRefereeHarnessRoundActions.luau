-- The round-time actions and reads of ThemedRoundRefereeTestHarness: moving time, loading,
-- joining, sending drafts, leaving, losing the session lock, and reading what was sent or
-- granted. ThemedRoundRefereeTestHarness.createRefereeWithFakes builds the fakes and calls
-- addRoundActionsToHarness; tests use the functions through the harness. Not a spec file.
--
--   ThemedRoundRefereeHarnessRoundActions.STARTER_DANCE_IDS
--   ThemedRoundRefereeHarnessRoundActions.createStoredSaveWithExampleHistory() -> PlayerSaveData
--   ThemedRoundRefereeHarnessRoundActions.addRoundActionsToHarness(harness, roundStartUnixMilliseconds)
--     Needs harness.referee, fakeClock, fakeScheduler, themedRoundClock, playerSaveDataKeeper,
--     fakePlayerSaveDataStorage, fakeResolver, recordedGrantCalls, draftsReachingKeeperRecords,
--     recordingAcknowledgementSender, sentRoundStateChangedRecords,
--     sentRoundResultsPublishedRecords and refereePhaseChangeListeners. Adds the functions below.

local RoundOutfitDraftTestMessages = require("../Support/RoundOutfitDraftTestMessages")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")

local ThemedRoundRefereeHarnessRoundActions = {}

ThemedRoundRefereeHarnessRoundActions.ROUND_START_UNIX_SECONDS = 1_763_510_400
ThemedRoundRefereeHarnessRoundActions.STARTER_DANCE_IDS = { "starter_wave" }

-- The §1.10 "before" column for the worked example.
function ThemedRoundRefereeHarnessRoundActions.createStoredSaveWithExampleHistory()
	local storedSaveData = PlayerSaveDataSchema.createStartingPlayerSaveData(
		ThemedRoundRefereeHarnessRoundActions.STARTER_DANCE_IDS,
		ThemedRoundRefereeHarnessRoundActions.ROUND_START_UNIX_SECONDS - 86400
	)
	storedSaveData.starCoinBalance = 350
	storedSaveData.fanCount = 1200
	storedSaveData.totalRoundsCompletedCount = 14
	storedSaveData.bestStarCountByThemeId = { y2k_pop = 3 }
	return storedSaveData
end

local function countRecordsForPlayer(records, playerUserId: number): number
	local recordCount = 0
	for _, record in records do
		if record.playerUserId == playerUserId then
			recordCount += 1
		end
	end
	return recordCount
end

local function addTimeAndRoundStateActions(harness, roundStartUnixMilliseconds: number)
	function harness.readCurrentRoundMilliseconds(): number
		return harness.fakeClock:getCurrentUnixMilliseconds() - roundStartUnixMilliseconds
	end

	-- Moves time forward through the scheduler (running due phase changes and timers) to T.
	function harness.advanceToRoundSecond(roundSeconds: number)
		local elapsedMilliseconds = math.round(roundSeconds * 1000) - harness.readCurrentRoundMilliseconds()
		assert(elapsedMilliseconds >= 0, "advanceToRoundSecond cannot move time backwards")
		harness.fakeScheduler:advanceTimeAndRunDueCallbacks(elapsedMilliseconds / 1000)
	end

	-- Delivers a phase change to the referee again, as a duplicated clock notification would.
	function harness.redeliverRoundPhaseChangeToReferee(roundState)
		for _, refereePhaseChangeListener in harness.refereePhaseChangeListeners do
			refereePhaseChangeListener(roundState)
		end
	end

	function harness.readCurrentRoundState()
		return harness.themedRoundClock:readCurrentRoundState()
	end

	function harness.readCurrentRoundId(): string?
		local roundState = harness.themedRoundClock:readCurrentRoundState()
		return if roundState then roundState.roundId else nil
	end

	function harness.hideStylingItemKeyFromNowOn(hiddenStylingItemKey: string)
		harness.fakeResolver:publishWardrobeCatalog(
			RoundOutfitDraftTestMessages.copyAvailableStylingItemKeySetWithout(
				harness.fakeResolver:getAvailableStylingItemKeySet(),
				hiddenStylingItemKey
			)
		)
	end
end

local function addSaveActions(harness)
	-- Loads again what storage holds now (for example after the player's final save).
	function harness.loadPlayerFromWhatStorageHolds(playerUserId: number)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(playerUserId)
		assert(
			harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId),
			"harness: the reload should have succeeded"
		)
	end

	-- Stores a save (the §1.10 example history unless one is given) and loads it now.
	function harness.loadPlayer(playerUserId: number, storedSaveData: any?)
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(
			playerUserId,
			storedSaveData or ThemedRoundRefereeHarnessRoundActions.createStoredSaveWithExampleHistory()
		)
		harness.loadPlayerFromWhatStorageHolds(playerUserId)
	end

	function harness.loadPlayers(playerUserIds: { number })
		for _, playerUserId in playerUserIds do
			harness.loadPlayer(playerUserId)
		end
	end

	-- Another server takes the save over; the next save of this server finds out and ends the
	-- session with "SessionLockLost" while the player is still connected.
	function harness.loseSessionLockAtRoundSecond(roundSeconds: number, playerUserId: number)
		harness.advanceToRoundSecond(roundSeconds)
		local storedSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(playerUserId)
		storedSaveData.gameServerSessionLock = {
			sessionLockId = "another-server-lock",
			lockRefreshedAtUnixSeconds = harness.fakeClock:getCurrentUnixSeconds(),
		}
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(playerUserId, storedSaveData)
		harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(
			playerUserId,
			PlayerSaveDataKeeper.PROGRESS_CHANGE_SAVED_AT_ONCE,
			"harness: trigger a save",
			function(saveDataDraft)
				saveDataDraft.redeemedPromoCodeIds = { "harness_trigger_" .. tostring(roundSeconds) }
				return true
			end
		)
		-- A save spaced by MINIMUM_SECONDS_BETWEEN_SAVE_STARTS may wait; run it now if due.
		harness.fakeScheduler:advanceTimeAndRunDueCallbacks(0)
	end

	function harness.readInMemorySaveData(playerUserId: number)
		return harness.playerSaveDataKeeper:readPlayerSaveDataCopy(playerUserId)
	end

	function harness.readInMemoryChangeRevision(playerUserId: number): number?
		local inMemoryChangeRevision = harness.playerSaveDataKeeper:readSaveChangeRevisions(playerUserId)
		return inMemoryChangeRevision
	end
end

local function addPlayerRequestActions(harness)
	function harness.joinAtRoundSecond(roundSeconds: number, playerUserId: number)
		harness.advanceToRoundSecond(roundSeconds)
		return harness.referee:admitOrRejectJoinCurrentRoundRequest(playerUserId)
	end

	-- Loads the players at T = 0 (now) and joins them at T = 3; leaves time at T = 3.
	function harness.loadAndJoinAtRoundSecond3(playerUserIds: { number })
		harness.loadPlayers(playerUserIds)
		harness.advanceToRoundSecond(3)
		for _, playerUserId in playerUserIds do
			local joinAnswer = harness.referee:admitOrRejectJoinCurrentRoundRequest(playerUserId)
			assert(joinAnswer.isAccepted, "harness: the join at T = 3 should have been accepted")
		end
	end

	-- A SetRoundOutfitDraft for the clock's current round unless a roundId is given.
	function harness.buildOutfitDraftMessage(outfitDraftSequenceNumber: any, outfitStylingItemKeys: any, roundId: any?)
		return RoundOutfitDraftTestMessages.buildOutfitDraftMessage(
			if roundId == nil then harness.readCurrentRoundId() else roundId,
			outfitDraftSequenceNumber,
			outfitStylingItemKeys
		)
	end

	function harness.sendDraftAtRoundSecond(
		roundSeconds: number,
		playerUserId: number,
		outfitDraftSequenceNumber: any,
		outfitStylingItemKeys: any,
		roundId: any?
	)
		harness.advanceToRoundSecond(roundSeconds)
		harness.referee:receiveSetRoundOutfitDraftFromDevice(
			playerUserId,
			harness.buildOutfitDraftMessage(outfitDraftSequenceNumber, outfitStylingItemKeys, roundId)
		)
	end

	-- What the wiring does when a player leaves the server: the referee first, then the final save.
	function harness.leaveServerAtRoundSecond(roundSeconds: number, playerUserId: number)
		harness.advanceToRoundSecond(roundSeconds)
		harness.referee:removePlayerWhoLeftServer(playerUserId)
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(playerUserId)
	end
end

local function addSentMessageReads(harness, roundStartUnixMilliseconds: number)
	function harness.countGrantCallsFor(playerUserId: number): number
		return countRecordsForPlayer(harness.recordedGrantCalls, playerUserId)
	end

	function harness.countDraftsReachingKeeperFrom(playerUserId: number): number
		return countRecordsForPlayer(harness.draftsReachingKeeperRecords, playerUserId)
	end

	-- { { roundMilliseconds, roundId, outfitDraftSequenceNumber, isKept, rejectionReason } }
	function harness.listAcknowledgementsSentTo(playerUserId: number)
		return RoundOutfitDraftTestMessages.summarizeAcknowledgementsSentTo(
			harness.recordingAcknowledgementSender,
			playerUserId,
			roundStartUnixMilliseconds
		)
	end

	function harness.listPublishedRoundResultsMessages()
		local publishedMessages = {}
		for _, sentRecord in harness.sentRoundResultsPublishedRecords do
			table.insert(publishedMessages, sentRecord.roundResultsPublishedMessage)
		end
		return publishedMessages
	end

	-- The participantUserIds of the last RoundStateChanged sent at or before now.
	function harness.readLastBroadcastParticipantUserIds()
		local sentRoundStateChangedRecords = harness.sentRoundStateChangedRecords
		local lastRecord = sentRoundStateChangedRecords[#sentRoundStateChangedRecords]
		return if lastRecord then lastRecord.roundStateChangedMessage.participantUserIds else nil
	end
end

function ThemedRoundRefereeHarnessRoundActions.addRoundActionsToHarness(harness, roundStartUnixMilliseconds: number)
	addTimeAndRoundStateActions(harness, roundStartUnixMilliseconds)
	addSaveActions(harness)
	addPlayerRequestActions(harness)
	addSentMessageReads(harness, roundStartUnixMilliseconds)
end

return table.freeze(ThemedRoundRefereeHarnessRoundActions)
