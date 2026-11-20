-- ThemedRoundReferee, scoring at the cut-off, rewards and RoundResultsPublished (development spec
-- §0.2 worked example, §1.6, §1.10, §2.3 "Cut-off", §2.5, §3.3). Referee audit PART 3 sections H
-- (scenarios 56, 57, 58, 60 to 63; 59 is in ThemedRoundRefereeLedgerOutcomesAndMessages.spec; 64,
-- 38 and section I are in ThemedRoundRefereeResultsFromServerState.spec), PART 1 questions 16,
-- 19, 20, 21, 22 and PART 2 items a, m, n. Runs against the REAL RewardLedger and PlayerSaveDataKeeper on fake storage.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local OutfitScoreCalculator = require("../../src/shared/OutfitScoreCalculator")
local ThemeCatalog = require("../../src/shared/ThemeCatalog")
local ThemedRoundOwnerDecisions = require("../../src/server/ThemedRoundOwnerDecisions")
local ThemedRoundRewardSettlement = require("../../src/server/ThemedRoundRewardSettlement")
local ThemedRoundRefereeTestHarness = require("./ThemedRoundRefereeTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_P = ThemedRoundRefereeTestHarness.PLAYER_P
local PLAYER_Q = ThemedRoundRefereeTestHarness.PLAYER_Q
local PLAYER_R = ThemedRoundRefereeTestHarness.PLAYER_R
local PLAYER_S = ThemedRoundRefereeTestHarness.PLAYER_S
local OUTFIT_A = ThemedRoundRefereeTestHarness.OUTFIT_A
local INVALID_OUTFIT_X = ThemedRoundRefereeTestHarness.INVALID_OUTFIT_X
local OUTFIT_E83 = ThemedRoundRefereeTestHarness.WORKED_EXAMPLE_OUTFIT_E83
local expectedAcknowledgement = ThemedRoundRefereeTestHarness.expectedAcknowledgement
local createRefereeWithFakes = ThemedRoundRefereeTestHarness.createRefereeWithFakes

-- In round 1 (y2k_pop, pink ColorBonus): 91 points / 5 stars, 65 / 3 stars, 18 / 1 star.
local OUTFIT_SCORING_91 = table.freeze({
	"asset_9000001",
	"asset_9000011",
	"asset_9000021",
	"bundle_9000041",
	"asset_9000051",
	"asset_9000062",
})
local OUTFIT_SCORING_65 = table.freeze({ "asset_9000001", "asset_9000011", "asset_9000051" })
local OUTFIT_SCORING_18_ONE_STAR = OUTFIT_A
local ROUND_ONE_BONUS_RULE = table.freeze({ roundBonusKind = "ColorBonus", bonusColorTag = "pink" })

local function scoreInRoundOne(outfitStylingItemKeys: { string })
	return OutfitScoreCalculator.calculateOutfitScore(
		outfitStylingItemKeys,
		FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
		ThemeCatalog.findThemeByThemeId("y2k_pop") :: any,
		ROUND_ONE_BONUS_RULE
	)
end

local function readRoundOneResults(harness)
	return harness.listPublishedRoundResultsMessages()[1].roundResults
end

local function listResultsPlayerUserIds(roundResults): { number }
	local playerUserIds = {}
	for _, roundResultsEntry in roundResults do
		table.insert(playerUserIds, roundResultsEntry.playerUserId)
	end
	return playerUserIds
end

describe("ThemedRoundReferee §0.2 worked example end to end (audit scenario 56)", function()
	it(
		"pays 83 points, 4 stars: balance 350 -> 430, fans 1200 -> 1240, rounds 14 -> 15, best 3 -> 4, one revision",
		function()
			local harness = createRefereeWithFakes()
			harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
			expect(harness.readCurrentRoundState().themeId).toBe("y2k_pop")
			expect(harness.readCurrentRoundState().roundBonusRule).toEqual(ROUND_ONE_BONUS_RULE)
			harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
			expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
				expectedAcknowledgement(20, "round-1", 1, true),
			})
			harness.advanceToRoundSecond(200)
			local showcaseStageEntry = harness.referee:readShowcaseStageEntry(PLAYER_P)
			expect(showcaseStageEntry.outfitScore).toBe(83)
			expect(showcaseStageEntry.stagePlaceNumber).toBe(1)
			expect(table.isfrozen(showcaseStageEntry)).toBeTrue()
			expect(showcaseStageEntry.scoredOutfitStylingItemKeys).toEqual(OUTFIT_E83)
			harness.advanceToRoundSecond(249)
			local revisionBeforeResults = harness.readInMemoryChangeRevision(PLAYER_P)
			expect(harness.readInMemorySaveData(PLAYER_P).starCoinBalance).toBe(350)
			harness.advanceToRoundSecond(250)
			local saveData = harness.readInMemorySaveData(PLAYER_P)
			expect(saveData.starCoinBalance).toBe(430)
			expect(saveData.fanCount).toBe(1240)
			expect(saveData.totalRoundsCompletedCount).toBe(15)
			expect(saveData.bestStarCountByThemeId).toEqual({ y2k_pop = 4 })
			expect(harness.readInMemoryChangeRevision(PLAYER_P)).toBe(revisionBeforeResults + 1)
			local roundResults = readRoundOneResults(harness)
			expect(#roundResults).toBe(1)
			local roundResultsEntry = roundResults[1]
			expect(roundResultsEntry.playerUserId).toBe(PLAYER_P)
			expect(roundResultsEntry.playerDisplayName).toBe("Player 8801")
			expect(roundResultsEntry.outfitScore).toBe(83)
			expect(roundResultsEntry.themeMatchPoints).toBeCloseTo(50 * 4 / 6)
			expect(roundResultsEntry.completenessPoints).toBe(20)
			expect(roundResultsEntry.colorHarmonyPoints).toBe(15)
			expect(roundResultsEntry.roundBonusPoints).toBe(15)
			expect(roundResultsEntry.starCount).toBe(4)
			expect(roundResultsEntry.starCoinsGranted).toBe(80)
			expect(roundResultsEntry.fanCountGained).toBe(40)
			expect(roundResultsEntry.isNewBestStarCountForTheme).toBeTrue()
			expect(table.isfrozen(roundResultsEntry)).toBeTrue()
			expect(table.isfrozen(roundResults)).toBeTrue()
			harness.advanceToRoundSecond(261)
			local storedSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER_P)
			expect(storedSaveData.starCoinBalance).toBe(430)
			expect(storedSaveData.fanCount).toBe(1240)
			expect(storedSaveData.totalRoundsCompletedCount).toBe(15)
		end
	)

	it("gives a stage entry only during Showcase", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
		harness.advanceToRoundSecond(189.999)
		expect(harness.referee:readShowcaseStageEntry(PLAYER_P)).toBeNil()
		harness.advanceToRoundSecond(249.999)
		expect(harness.referee:readShowcaseStageEntry(PLAYER_P).stagePlaceNumber).toBe(1)
		harness.advanceToRoundSecond(250)
		expect(harness.referee:readShowcaseStageEntry(PLAYER_P)).toBeNil()
		expect(harness.referee:isParticipantOfCurrentRound(PLAYER_P)).toBeTrue()
		harness.advanceToRoundSecond(275)
		expect(harness.referee:readShowcaseStageEntry(PLAYER_P)).toBeNil()
	end)

	it("publishes the round results message once, at the start of Results, after the grant", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
		harness.advanceToRoundSecond(249.999)
		expect(#harness.sentRoundResultsPublishedRecords).toBe(0)
		expect(harness.referee:readLastPublishedRoundResults()).toBeNil()
		harness.advanceToRoundSecond(279.999)
		expect(#harness.sentRoundResultsPublishedRecords).toBe(1)
		expect(harness.sentRoundResultsPublishedRecords[1].roundMilliseconds).toBe(250000)
		local publishedMessage = harness.sentRoundResultsPublishedRecords[1].roundResultsPublishedMessage
		expect(publishedMessage.roundId).toBe("round-1")
		expect(table.isfrozen(publishedMessage)).toBeTrue()
		expect(harness.referee:readLastPublishedRoundResults()).toBe(publishedMessage)
		harness.advanceToRoundSecond(280)
		expect(harness.referee:readLastPublishedRoundResults()).toBeNil()
	end)
end)

describe("ThemedRoundReferee isNewBestStarCountForTheme (audit scenario 57, owner question 22)", function()
	local function playRoundWithStoredBestAndOutfit(storedBestStarCountByThemeId, outfitStylingItemKeys)
		local harness = createRefereeWithFakes()
		local storedSaveData = ThemedRoundRefereeTestHarness.createStoredSaveWithExampleHistory()
		storedSaveData.bestStarCountByThemeId = storedBestStarCountByThemeId
		harness.loadPlayer(PLAYER_P, storedSaveData)
		harness.joinAtRoundSecond(3, PLAYER_P)
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, outfitStylingItemKeys)
		harness.advanceToRoundSecond(251)
		return readRoundOneResults(harness)[1], harness.readInMemorySaveData(PLAYER_P)
	end

	it("is false for an equal star count, which stays", function()
		local roundResultsEntry, saveData = playRoundWithStoredBestAndOutfit({ y2k_pop = 4 }, OUTFIT_E83)
		expect(roundResultsEntry.isNewBestStarCountForTheme).toBeFalse()
		expect(saveData.bestStarCountByThemeId).toEqual({ y2k_pop = 4 })
	end)

	it("is false for a lower star count, and the stored best never goes down", function()
		local roundResultsEntry, saveData = playRoundWithStoredBestAndOutfit({ y2k_pop = 5 }, OUTFIT_SCORING_65)
		expect(roundResultsEntry.starCount).toBe(3)
		expect(roundResultsEntry.isNewBestStarCountForTheme).toBeFalse()
		expect(saveData.bestStarCountByThemeId).toEqual({ y2k_pop = 5 })
	end)

	it("is true for a first rated round on the theme, even with 1 star", function()
		local roundResultsEntry, saveData = playRoundWithStoredBestAndOutfit({}, OUTFIT_SCORING_18_ONE_STAR)
		expect(roundResultsEntry.starCount).toBe(1)
		expect(roundResultsEntry.isNewBestStarCountForTheme).toBeTrue()
		expect(saveData.bestStarCountByThemeId).toEqual({ y2k_pop = 1 })
	end)
end)

describe("ThemedRoundReferee pays once per round (audit scenario 58, question 19)", function()
	it("a second Results notification, 1000 drafts and 1000 joins change neither balances nor results", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
		harness.advanceToRoundSecond(250)
		local resultsRoundState = harness.readCurrentRoundState()
		local publishedMessage = harness.referee:readLastPublishedRoundResults()
		harness.advanceToRoundSecond(255)
		harness.redeliverRoundPhaseChangeToReferee(resultsRoundState)
		harness.redeliverRoundPhaseChangeToReferee(resultsRoundState)
		for stepNumber = 1, 1000 do
			harness.advanceToRoundSecond(255 + stepNumber * 0.014)
			harness.referee:receiveSetRoundOutfitDraftFromDevice(
				PLAYER_P,
				harness.buildOutfitDraftMessage(1 + stepNumber, OUTFIT_SCORING_91)
			)
			harness.referee:admitOrRejectJoinCurrentRoundRequest(PLAYER_P)
		end
		expect(harness.readCurrentRoundState().roundPhase).toBe("Results")
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(1)
		expect(#harness.sentRoundResultsPublishedRecords).toBe(1)
		expect(harness.referee:readLastPublishedRoundResults()).toBe(publishedMessage)
		local saveData = harness.readInMemorySaveData(PLAYER_P)
		expect(saveData.starCoinBalance).toBe(430)
		expect(saveData.totalRoundsCompletedCount).toBe(15)
	end)

	it("a second Showcase notification neither cuts off nor scores again", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
		harness.advanceToRoundSecond(190)
		local showcaseRoundState = harness.readCurrentRoundState()
		local scoredOutfitBefore = harness.referee:readShowcaseStageEntry(PLAYER_P).scoredOutfitStylingItemKeys
		harness.redeliverRoundPhaseChangeToReferee(showcaseRoundState)
		expect(harness.referee:readShowcaseStageEntry(PLAYER_P).scoredOutfitStylingItemKeys).toBe(scoredOutfitBefore)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
		harness.advanceToRoundSecond(251)
		expect(readRoundOneResults(harness)[1].outfitScore).toBe(83)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(1)
	end)

	it("a late notification of the previous round's phase does not carry this round's participants", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.advanceToRoundSecond(250)
		local roundOneResultsState = harness.readCurrentRoundState()
		harness.advanceToRoundSecond(283)
		expect(harness.referee:admitOrRejectJoinCurrentRoundRequest(PLAYER_P)).toEqual({ isAccepted = true })
		harness.redeliverRoundPhaseChangeToReferee(roundOneResultsState)
		local lateMessage =
			harness.sentRoundStateChangedRecords[#harness.sentRoundStateChangedRecords].roundStateChangedMessage
		expect(lateMessage.roundId).toBe("round-1")
		expect(lateMessage.participantUserIds).toEqual({})
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(0)
		expect(#harness.listPublishedRoundResultsMessages()).toBe(1)
	end)

	it("a second ThemeReveal notification for the same round keeps its participants", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.redeliverRoundPhaseChangeToReferee(harness.readCurrentRoundState())
		expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({ PLAYER_P })
		expect(#harness.createdDraftKeepers).toBe(1)
	end)

	it("a second Styling notification is harmless", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.advanceToRoundSecond(10)
		harness.redeliverRoundPhaseChangeToReferee(harness.readCurrentRoundState())
		harness.sendDraftAtRoundSecond(11, PLAYER_P, 1, OUTFIT_A)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
		expect(#harness.recordingLogger.loggedWarnings).toBe(0)
	end)
end)

describe("ThemedRoundReferee empty final outfits (audit scenario 60, owner question 16)", function()
	local function playRoundWithThreeEmptyFinalOutfits(ownerDecisions)
		local harness = createRefereeWithFakes({ ownerDecisions = ownerDecisions })
		harness.loadAndJoinAtRoundSecond3({ PLAYER_Q, PLAYER_R, PLAYER_S })
		harness.sendDraftAtRoundSecond(20, PLAYER_S, 1, INVALID_OUTFIT_X)
		harness.sendDraftAtRoundSecond(20, PLAYER_Q, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(21, PLAYER_Q, 2, {})
		harness.advanceToRoundSecond(249.5)
		local savesBefore, revisionsBefore, storageOperationsBefore = {}, {}, {}
		for _, playerUserId in { PLAYER_Q, PLAYER_R, PLAYER_S } do
			savesBefore[playerUserId] = harness.readInMemorySaveData(playerUserId)
			revisionsBefore[playerUserId] = harness.readInMemoryChangeRevision(playerUserId)
			storageOperationsBefore[playerUserId] =
				harness.fakePlayerSaveDataStorage:countStartedOperations(playerUserId)
		end
		harness.advanceToRoundSecond(251)
		return harness, savesBefore, revisionsBefore, storageOperationsBefore
	end

	it("lists each with all numbers 0, calls no ledger and leaves every save exactly as it was", function()
		local harness, savesBefore, revisionsBefore, storageOperationsBefore = playRoundWithThreeEmptyFinalOutfits(nil)
		expect(harness.listAcknowledgementsSentTo(PLAYER_S)).toEqual({
			expectedAcknowledgement(20, "round-1", 1, false),
		})
		expect(#harness.recordedGrantCalls).toBe(0)
		local roundResults = readRoundOneResults(harness)
		expect(listResultsPlayerUserIds(roundResults)).toEqual({ PLAYER_Q, PLAYER_R, PLAYER_S })
		for _, roundResultsEntry in roundResults do
			local playerUserId = roundResultsEntry.playerUserId
			expect(roundResultsEntry).toEqual({
				playerUserId = playerUserId,
				playerDisplayName = "Player " .. tostring(playerUserId),
				outfitScore = 0,
				themeMatchPoints = 0,
				completenessPoints = 0,
				colorHarmonyPoints = 0,
				roundBonusPoints = 0,
				starCount = 0,
				starCoinsGranted = 0,
				fanCountGained = 0,
				isNewBestStarCountForTheme = false,
			})
			expect(harness.readInMemorySaveData(playerUserId)).toEqual(savesBefore[playerUserId])
			expect(harness.readInMemoryChangeRevision(playerUserId)).toBe(revisionsBefore[playerUserId])
			expect(harness.fakePlayerSaveDataStorage:countStartedOperations(playerUserId)).toBe(
				storageOperationsBefore[playerUserId]
			)
		end
	end)

	it("alternative answer (16 a, not listed): the empty participants are left out of roundResults", function()
		local omittingOwnerDecisions = table.clone(ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS)
		omittingOwnerDecisions.isEmptyFinalOutfitListedInRoundResults = false
		local harness = playRoundWithThreeEmptyFinalOutfits(omittingOwnerDecisions)
		expect(readRoundOneResults(harness)).toEqual({})
		expect(#harness.recordedGrantCalls).toBe(0)
	end)

	it(
		"treats only an empty outfit as not rewardable (16 b) and publishes the best-star flag only when granted (22)",
		function()
			expect(ThemedRoundRewardSettlement.isFinalOutfitRewardable(scoreInRoundOne({}))).toBeFalse()
			expect(ThemedRoundRewardSettlement.isFinalOutfitRewardable(scoreInRoundOne(OUTFIT_A))).toBeTrue()
			local decide = ThemedRoundRewardSettlement.decidePublishedIsNewBestStarCountForTheme
			expect(decide({ rewardLedgerOutcome = "Granted", isNewBestStarCountForTheme = true })).toBeTrue()
			expect(decide({ rewardLedgerOutcome = "Granted", isNewBestStarCountForTheme = false })).toBeFalse()
			expect(decide({ rewardLedgerOutcome = "Declined", isNewBestStarCountForTheme = true })).toBeFalse()
		end
	)
end)

describe("ThemedRoundReferee results order (audit scenarios 61 and 62, question 20)", function()
	it("scenario 61: sorts by outfitScore, highest first", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P, PLAYER_Q, PLAYER_R })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_SCORING_91)
		harness.sendDraftAtRoundSecond(20, PLAYER_Q, 1, OUTFIT_SCORING_65)
		harness.sendDraftAtRoundSecond(20, PLAYER_R, 1, OUTFIT_E83)
		harness.advanceToRoundSecond(251)
		local roundResults = readRoundOneResults(harness)
		expect({ roundResults[1].outfitScore, roundResults[2].outfitScore, roundResults[3].outfitScore }).toEqual({
			91,
			83,
			65,
		})
		expect(listResultsPlayerUserIds(roundResults)).toEqual({ PLAYER_P, PLAYER_R, PLAYER_Q })
	end)

	it("scenario 62: ties go by join order, then playerUserId; the order never depends on insertion", function()
		local harness = createRefereeWithFakes()
		harness.loadPlayers({ PLAYER_P, PLAYER_Q, PLAYER_R, PLAYER_S })
		harness.joinAtRoundSecond(3, PLAYER_Q)
		harness.joinAtRoundSecond(20, PLAYER_P)
		harness.joinAtRoundSecond(21, PLAYER_S)
		harness.joinAtRoundSecond(22, PLAYER_R)
		harness.sendDraftAtRoundSecond(23, PLAYER_Q, 1, OUTFIT_E83)
		harness.sendDraftAtRoundSecond(23, PLAYER_P, 1, OUTFIT_E83)
		harness.advanceToRoundSecond(251)
		expect(listResultsPlayerUserIds(readRoundOneResults(harness))).toEqual({
			PLAYER_Q,
			PLAYER_P,
			PLAYER_S,
			PLAYER_R,
		})

		local isPublishedBefore = ThemedRoundRewardSettlement.isRoundResultsRowPublishedBefore
		local orderedRows = {
			{ outfitScore = 83, joinOrderPosition = 1, playerUserId = 50 },
			{ outfitScore = 83, joinOrderPosition = 2, playerUserId = 10 },
			{ outfitScore = 0, joinOrderPosition = 3, playerUserId = 30 },
			{ outfitScore = 0, joinOrderPosition = 3, playerUserId = 40 },
			{ outfitScore = 0, joinOrderPosition = 4, playerUserId = 20 },
		}
		SeededRandomTrials.runSeededRandomTrials(100, function(seededRandomNumberGenerator)
			local shuffledRows = table.clone(orderedRows)
			seededRandomNumberGenerator.shuffleListInPlace(shuffledRows)
			table.sort(shuffledRows, isPublishedBefore)
			for rowPosition, row in orderedRows do
				expect(shuffledRows[rowPosition]).toBe(row)
			end
		end)
	end)
end)

describe("ThemedRoundReferee rounds with nobody to pay (audit scenario 63, gate 1D, question 21)", function()
	it("three rounds with nobody joining publish one empty list each and never call the ledger", function()
		local harness = createRefereeWithFakes()
		harness.advanceToRoundSecond(280 * 3)
		local publishedMessages = harness.listPublishedRoundResultsMessages()
		expect(#publishedMessages).toBe(3)
		for roundNumber, publishedMessage in publishedMessages do
			expect(publishedMessage).toEqual({ roundId = "round-" .. tostring(roundNumber), roundResults = {} })
		end
		expect(#harness.recordedGrantCalls).toBe(0)
		expect(#harness.recordingLogger.loggedWarnings).toBe(0)
		expect(#harness.sentRoundStateChangedRecords).toBe(16)
	end)

	it("variant: the only participant leaves at T=220; one publication with an empty list", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
		harness.leaveServerAtRoundSecond(220, PLAYER_P)
		harness.advanceToRoundSecond(279)
		expect(harness.listPublishedRoundResultsMessages()).toEqual({ { roundId = "round-1", roundResults = {} } })
	end)
end)
