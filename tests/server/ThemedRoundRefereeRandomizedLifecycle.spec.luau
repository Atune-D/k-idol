-- ThemedRoundReferee randomized lifecycle (referee audit PART 3 scenario 78): 200 seeded rounds
-- (20 trials of 10 consecutive rounds) with random joins, leaves, rejoins, save-session losses,
-- drafts and respawns, against the REAL clock, limiter, save keeper, ledger and draft keeper.
-- A failure names the seed (IDOLGROW_RANDOM_TEST_SEED reproduces it).
--
-- Invariants checked at every Results step and at the end:
--   * The ledger is called at most once per (roundId, playerUserId).
--   * It is called exactly for the participants whose kept outfit is not empty, with exactly
--     that outfit. The kept outfit is the TEST's own model: each (round, player, number) carries
--     one fixed content, and a kept acknowledgement makes the content sent under its number the
--     kept one. Never for a player who left, lost the save session, or a non-participant.
--   * A path the run never took fails the test with the seed in the message.
--   * Every entry's starCoinsGranted and fanCountGained equal what the save actually gained.
--   * Entries are sorted by outfitScore, highest first, ties by join order then playerUserId.
--   * The listed players are exactly the participants at T=250 (empty outfits are listed).
--   * A spawn decision puts a player on stage only during Showcase and only as a participant.

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local CharacterSpawnAppearanceDecider = require("../../src/server/CharacterSpawnAppearanceDecider")
local ThemedRoundRefereeTestHarness = require("./ThemedRoundRefereeTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_USER_IDS = { 9301, 9302, 9303, 9304, 9305, 9306 }
local ROUNDS_PER_TRIAL = 10
local TRIAL_COUNT = 20
local EVENTS_PER_ROUND = 30
local WHOLE_ROUND_SECONDS = 280
local OUTFIT_CHOICES = {
	ThemedRoundRefereeTestHarness.OUTFIT_A,
	ThemedRoundRefereeTestHarness.OUTFIT_B,
	ThemedRoundRefereeTestHarness.OUTFIT_C,
	ThemedRoundRefereeTestHarness.OUTFIT_D,
	ThemedRoundRefereeTestHarness.WORKED_EXAMPLE_OUTFIT_E83,
	ThemedRoundRefereeTestHarness.INVALID_OUTFIT_X,
	{},
}
local EVENT_KINDS = { "join", "join", "draft", "draft", "draft", "draft", "leave", "connect", "loseLock", "respawn" }

-- How often each interesting path was taken over the whole run, so the test proves it covered them.
local coveredPathCountByName = {}
local function countCoveredPath(coveredPathName: string)
	coveredPathCountByName[coveredPathName] = (coveredPathCountByName[coveredPathName] or 0) + 1
end

local function createLifecycleModel(harness)
	local lifecycleModel = {
		participantJoinSequenceByPlayerUserId = {} :: { [number]: number },
		lastJoinSequence = 0,
		isConnectedByPlayerUserId = {} :: { [number]: boolean },
		nextSequenceNumberByPlayerUserId = {} :: { [number]: number },
		-- This round's outfit per player per sequence number, fixed at its first use.
		sentOutfitBySequenceNumberByPlayerUserId = {} :: { [number]: { [number]: { string } } },
		-- This round's kept outfit per participant, from kept acknowledgements only.
		keptOutfitByPlayerUserId = {} :: { [number]: { string } },
	}
	harness.playerSaveDataKeeper:subscribeToPlayerSaveDataSessionEnded(function(playerUserId: number, sessionEndReason)
		if
			sessionEndReason == "SessionLockLost" and lifecycleModel.participantJoinSequenceByPlayerUserId[playerUserId]
		then
			countCoveredPath("participantLostSaveSession")
		end
		lifecycleModel.participantJoinSequenceByPlayerUserId[playerUserId] = nil
	end)
	return lifecycleModel
end

-- Called for every acknowledgement the referee sends (through the harness option).
local function recordAcknowledgementInModel(lifecycleModel, harness, playerUserId: number, acknowledgement)
	if not acknowledgement.isKept or acknowledgement.roundId ~= harness.readCurrentRoundId() then
		return
	end
	local sentOutfitBySequenceNumber = lifecycleModel.sentOutfitBySequenceNumberByPlayerUserId[playerUserId] or {}
	local sentOutfit = sentOutfitBySequenceNumber[acknowledgement.outfitDraftSequenceNumber]
	expect(sentOutfit ~= nil).toBeTrue()
	lifecycleModel.keptOutfitByPlayerUserId[playerUserId] = sentOutfit
end

local function pickOutfitForSequenceNumber(lifecycleModel, seededRandomNumberGenerator, playerUserId, sequenceNumber)
	local sentOutfitBySequenceNumber = lifecycleModel.sentOutfitBySequenceNumberByPlayerUserId[playerUserId] or {}
	lifecycleModel.sentOutfitBySequenceNumberByPlayerUserId[playerUserId] = sentOutfitBySequenceNumber
	if sentOutfitBySequenceNumber[sequenceNumber] == nil then
		sentOutfitBySequenceNumber[sequenceNumber] = seededRandomNumberGenerator.pickRandomListElement(OUTFIT_CHOICES)
	end
	return sentOutfitBySequenceNumber[sequenceNumber]
end

local function runRandomEvent(harness, lifecycleModel, seededRandomNumberGenerator, roundSecond: number)
	local referee = harness.referee
	local playerSaveDataKeeper = harness.playerSaveDataKeeper
	local playerUserId = seededRandomNumberGenerator.pickRandomListElement(PLAYER_USER_IDS)
	local eventKind = seededRandomNumberGenerator.pickRandomListElement(EVENT_KINDS)
	harness.advanceToRoundSecond(roundSecond)
	local isLoaded = playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId)

	if eventKind == "join" then
		local joinAnswer = referee:admitOrRejectJoinCurrentRoundRequest(playerUserId)
		if joinAnswer.isAccepted then
			expect(isLoaded).toBeTrue()
			expect(lifecycleModel.participantJoinSequenceByPlayerUserId[playerUserId]).toBeNil()
			lifecycleModel.lastJoinSequence += 1
			lifecycleModel.participantJoinSequenceByPlayerUserId[playerUserId] = lifecycleModel.lastJoinSequence
			lifecycleModel.nextSequenceNumberByPlayerUserId[playerUserId] = 1
			lifecycleModel.keptOutfitByPlayerUserId[playerUserId] = nil -- a clean draft state
		end
	elseif eventKind == "draft" then
		local nextSequenceNumber = lifecycleModel.nextSequenceNumberByPlayerUserId[playerUserId] or 1
		local sentSequenceNumber =
			math.max(1, nextSequenceNumber + seededRandomNumberGenerator.nextWholeNumberInRange(-2, 1))
		lifecycleModel.nextSequenceNumberByPlayerUserId[playerUserId] =
			math.max(nextSequenceNumber, sentSequenceNumber + 1)
		referee:receiveSetRoundOutfitDraftFromDevice(
			playerUserId,
			harness.buildOutfitDraftMessage(
				sentSequenceNumber,
				pickOutfitForSequenceNumber(
					lifecycleModel,
					seededRandomNumberGenerator,
					playerUserId,
					sentSequenceNumber
				)
			)
		)
	elseif eventKind == "leave" then
		if lifecycleModel.isConnectedByPlayerUserId[playerUserId] then
			if lifecycleModel.participantJoinSequenceByPlayerUserId[playerUserId] then
				countCoveredPath("participantLeftServer")
			end
			referee:removePlayerWhoLeftServer(playerUserId)
			if isLoaded then
				playerSaveDataKeeper:startFinalSaveForLeavingPlayer(playerUserId)
			end
			lifecycleModel.participantJoinSequenceByPlayerUserId[playerUserId] = nil
			lifecycleModel.isConnectedByPlayerUserId[playerUserId] = false
		end
	elseif eventKind == "connect" then
		if not isLoaded then
			-- A player the keeper dropped (lost lock) has left; the other server hands the save back.
			referee:removePlayerWhoLeftServer(playerUserId)
			local storedSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(playerUserId)
			storedSaveData.gameServerSessionLock = nil
			harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(playerUserId, storedSaveData)
			harness.loadPlayerFromWhatStorageHolds(playerUserId)
			lifecycleModel.isConnectedByPlayerUserId[playerUserId] = true
			countCoveredPath("reconnected")
		end
	elseif eventKind == "loseLock" then
		if isLoaded then
			harness.loseSessionLockAtRoundSecond(roundSecond, playerUserId)
		end
	else
		local characterSpawnAppearance = CharacterSpawnAppearanceDecider.decideCharacterSpawnAppearance({
			isPlayerSaveDataLoaded = isLoaded,
			wearableLobbyOutfitStylingItemKeys = {},
			characterSpawnRoundFacts = referee:readCharacterSpawnRoundFacts(playerUserId),
		})
		if characterSpawnAppearance.stagePlaceNumber ~= nil then
			countCoveredPath("spawnedOnStage")
			expect(harness.readCurrentRoundState().roundPhase).toBe("Showcase")
			expect(lifecycleModel.participantJoinSequenceByPlayerUserId[playerUserId] ~= nil).toBeTrue()
		end
	end
end

local function snapshotBalancesOfLoadedPlayers(harness)
	local balancesByPlayerUserId = {}
	for _, playerUserId in PLAYER_USER_IDS do
		local saveData = harness.readInMemorySaveData(playerUserId)
		if saveData then
			balancesByPlayerUserId[playerUserId] =
				{ starCoinBalance = saveData.starCoinBalance, fanCount = saveData.fanCount }
		end
	end
	return balancesByPlayerUserId
end

-- `modelParticipantSet` is the model's participants (with join sequence) just before Results.
-- A grant's own save can find the session lock lost and end the session within the Results
-- step, so the entry is checked against who was a participant when the step began.
local function checkResultsStep(
	harness,
	modelParticipantSet,
	keptOutfitsBeforeResults,
	balancesBeforeResults,
	roundId: string,
	grantCallCountBefore: number
)
	local publishedMessage = harness.referee:readLastPublishedRoundResults()
	expect(publishedMessage.roundId).toBe(roundId)
	local entryByPlayerUserId = {}
	for entryPosition, roundResultsEntry in publishedMessage.roundResults do
		local playerUserId = roundResultsEntry.playerUserId
		expect(modelParticipantSet[playerUserId] ~= nil).toBeTrue()
		entryByPlayerUserId[playerUserId] = roundResultsEntry
		local previousEntry = publishedMessage.roundResults[entryPosition - 1]
		if previousEntry then
			local isInOrder = previousEntry.outfitScore > roundResultsEntry.outfitScore
				or (
					previousEntry.outfitScore == roundResultsEntry.outfitScore
					and modelParticipantSet[previousEntry.playerUserId] < modelParticipantSet[playerUserId]
				)
			expect(isInOrder).toBeTrue()
		end
	end
	for playerUserId in modelParticipantSet do
		expect(entryByPlayerUserId[playerUserId] ~= nil).toBeTrue()
	end

	local grantedPlayerUserIdSet = {}
	for grantCallPosition = grantCallCountBefore + 1, #harness.recordedGrantCalls do
		local grantCall = harness.recordedGrantCalls[grantCallPosition]
		local themedRoundCompletion = grantCall.themedRoundCompletion
		expect(themedRoundCompletion.roundId).toBe(roundId)
		expect(grantedPlayerUserIdSet[grantCall.playerUserId]).toBeNil()
		grantedPlayerUserIdSet[grantCall.playerUserId] = true
		expect(modelParticipantSet[grantCall.playerUserId] ~= nil).toBeTrue()
		expect(themedRoundCompletion.scoredOutfitStylingItemKeys).toEqual(
			keptOutfitsBeforeResults[grantCall.playerUserId]
		)
		expect(themedRoundCompletion.starCount >= 1).toBeTrue()
		countCoveredPath("granted")
	end
	for playerUserId in modelParticipantSet do
		local keptOutfit = keptOutfitsBeforeResults[playerUserId]
		expect({ playerUserId, grantedPlayerUserIdSet[playerUserId] == true }).toEqual({
			playerUserId,
			keptOutfit ~= nil and #keptOutfit > 0,
		})
	end

	for playerUserId, balanceBefore in balancesBeforeResults do
		local saveDataAfter = harness.readInMemorySaveData(playerUserId)
		local roundResultsEntry = entryByPlayerUserId[playerUserId]
		if saveDataAfter == nil then
			-- The grant's save lost the session: the in-memory change is discarded (§3.4).
			countCoveredPath("sessionLostDuringResults")
			continue
		end
		local starCoinsGained = saveDataAfter.starCoinBalance - balanceBefore.starCoinBalance
		local fansGained = saveDataAfter.fanCount - balanceBefore.fanCount
		expect(starCoinsGained).toBe(if roundResultsEntry then roundResultsEntry.starCoinsGranted else 0)
		expect(fansGained).toBe(if roundResultsEntry then roundResultsEntry.fanCountGained else 0)
		if roundResultsEntry and roundResultsEntry.starCount == 0 then
			expect(grantedPlayerUserIdSet[playerUserId]).toBeNil()
			countCoveredPath("listedWithEmptyOutfit")
		end
	end
end

local function chooseEventRoundSeconds(seededRandomNumberGenerator, roundStartSecond: number): { number }
	local eventRoundSeconds = {}
	for _ = 1, EVENTS_PER_ROUND do
		local offsetMilliseconds = seededRandomNumberGenerator.nextWholeNumberInRange(1, 279899)
		if offsetMilliseconds >= 249900 and offsetMilliseconds <= 250100 then
			offsetMilliseconds += 300
		end
		table.insert(eventRoundSeconds, roundStartSecond + offsetMilliseconds / 1000)
	end
	table.sort(eventRoundSeconds)
	return eventRoundSeconds
end

describe("ThemedRoundReferee randomized lifecycle (audit scenario 78)", function()
	it("keeps every payment, listing and ordering invariant over 200 seeded rounds", function()
		SeededRandomTrials.runSeededRandomTrials(TRIAL_COUNT, function(seededRandomNumberGenerator)
			local lifecycleModel
			local harness
			harness = ThemedRoundRefereeTestHarness.createRefereeWithFakes({
				onRoundOutfitDraftAcknowledged = function(playerUserId: number, acknowledgement)
					recordAcknowledgementInModel(lifecycleModel, harness, playerUserId, acknowledgement)
				end,
			})
			lifecycleModel = createLifecycleModel(harness)
			for _, playerUserId in PLAYER_USER_IDS do
				harness.loadPlayer(playerUserId)
				lifecycleModel.isConnectedByPlayerUserId[playerUserId] = true
			end
			for roundNumber = 1, ROUNDS_PER_TRIAL do
				local roundStartSecond = (roundNumber - 1) * WHOLE_ROUND_SECONDS
				harness.advanceToRoundSecond(roundStartSecond)
				table.clear(lifecycleModel.participantJoinSequenceByPlayerUserId)
				table.clear(lifecycleModel.sentOutfitBySequenceNumberByPlayerUserId)
				table.clear(lifecycleModel.keptOutfitByPlayerUserId)
				local roundId = "round-" .. tostring(roundNumber)
				expect(harness.readCurrentRoundId()).toBe(roundId)
				local hasCheckedResults = false
				local function checkResultsWhenReached(nextRoundSecond: number)
					if hasCheckedResults or nextRoundSecond < roundStartSecond + 250 then
						return
					end
					hasCheckedResults = true
					harness.advanceToRoundSecond(roundStartSecond + 249.999)
					local balancesBeforeResults = snapshotBalancesOfLoadedPlayers(harness)
					local grantCallCountBefore = #harness.recordedGrantCalls
					local participantsBeforeResults = table.clone(lifecycleModel.participantJoinSequenceByPlayerUserId)
					local listedParticipantSet = {}
					for _, playerUserId in harness.referee:listCurrentRoundParticipantUserIds() do
						listedParticipantSet[playerUserId] = true
					end
					local modelParticipantSet = {}
					for playerUserId in participantsBeforeResults do
						modelParticipantSet[playerUserId] = true
					end
					expect(listedParticipantSet).toEqual(modelParticipantSet)
					local keptOutfitsBeforeResults = table.clone(lifecycleModel.keptOutfitByPlayerUserId)
					harness.advanceToRoundSecond(roundStartSecond + 250)
					checkResultsStep(
						harness,
						participantsBeforeResults,
						keptOutfitsBeforeResults,
						balancesBeforeResults,
						roundId,
						grantCallCountBefore
					)
				end
				for _, eventRoundSecond in chooseEventRoundSeconds(seededRandomNumberGenerator, roundStartSecond) do
					checkResultsWhenReached(eventRoundSecond)
					runRandomEvent(harness, lifecycleModel, seededRandomNumberGenerator, eventRoundSecond)
				end
				checkResultsWhenReached(roundStartSecond + WHOLE_ROUND_SECONDS)
			end
			local grantCountByRoundAndPlayer = {}
			for _, grantCall in harness.recordedGrantCalls do
				local grantKey = grantCall.themedRoundCompletion.roundId .. "/" .. tostring(grantCall.playerUserId)
				grantCountByRoundAndPlayer[grantKey] = (grantCountByRoundAndPlayer[grantKey] or 0) + 1
				expect(grantCountByRoundAndPlayer[grantKey]).toBe(1)
			end
			expect(#harness.listPublishedRoundResultsMessages()).toBe(ROUNDS_PER_TRIAL)
		end)
		for _, coveredPathName in
			{
				"granted",
				"listedWithEmptyOutfit",
				"participantLeftServer",
				"participantLostSaveSession",
				"reconnected",
				"spawnedOnStage",
			}
		do
			-- The message names the path and the seed, so a run that missed a path can be repeated.
			expect({
				coveredPathName = coveredPathName,
				wasTaken = (coveredPathCountByName[coveredPathName] or 0) > 0,
				randomTestSeed = SeededRandomTrials.RANDOM_TEST_SEED,
			}).toEqual({
				coveredPathName = coveredPathName,
				wasTaken = true,
				randomTestSeed = SeededRandomTrials.RANDOM_TEST_SEED,
			})
		end
	end)
end)
