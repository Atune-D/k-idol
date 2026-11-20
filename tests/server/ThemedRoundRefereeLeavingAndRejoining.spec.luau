-- ThemedRoundReferee, leaving, losing the save session and rejoining (development spec §2.2
-- "A participant who leaves the server is removed from the round and gets no reward for it",
-- §3.4 "Writing"). Referee audit PART 3 section G, scenarios 49 to 55, and PART 1 questions 11,
-- 12, 17 (owner question 11 in both of its answers).

local UnitTestFramework = require("../Support/UnitTestFramework")
local ThemedRoundOwnerDecisions = require("../../src/server/ThemedRoundOwnerDecisions")
local ThemedRoundRefereeTestHarness = require("./ThemedRoundRefereeTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_P = ThemedRoundRefereeTestHarness.PLAYER_P
local PLAYER_Q = ThemedRoundRefereeTestHarness.PLAYER_Q
local OUTFIT_A = ThemedRoundRefereeTestHarness.OUTFIT_A
local OUTFIT_B = ThemedRoundRefereeTestHarness.OUTFIT_B
local OUTFIT_C = ThemedRoundRefereeTestHarness.OUTFIT_C
local OUTFIT_D = ThemedRoundRefereeTestHarness.OUTFIT_D
local OUTFIT_E83 = ThemedRoundRefereeTestHarness.WORKED_EXAMPLE_OUTFIT_E83
local expectedAcknowledgement = ThemedRoundRefereeTestHarness.expectedAcknowledgement
local createRefereeWithFakes = ThemedRoundRefereeTestHarness.createRefereeWithFakes

local function findBroadcastAt(harness, roundSeconds: number)
	for _, sentRecord in harness.sentRoundStateChangedRecords do
		if sentRecord.roundMilliseconds == roundSeconds * 1000 then
			return sentRecord.roundStateChangedMessage
		end
	end
	error("no RoundStateChanged at " .. tostring(roundSeconds))
end

local function listResultsPlayerUserIds(harness): { number }
	local playerUserIds = {}
	for _, roundResultsEntry in harness.listPublishedRoundResultsMessages()[1].roundResults do
		table.insert(playerUserIds, roundResultsEntry.playerUserId)
	end
	return playerUserIds
end

describe("ThemedRoundReferee leaving the server (audit scenarios 49 to 52)", function()
	it("scenario 49: a player who leaves during ThemeReveal is gone before Styling and gets nothing", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.leaveServerAtRoundSecond(6, PLAYER_P)
		harness.advanceToRoundSecond(251)
		expect(findBroadcastAt(harness, 10).participantUserIds).toEqual({})
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(0)
		expect(harness.listPublishedRoundResultsMessages()[1].roundResults).toEqual({})
	end)

	it("scenario 50: leaving with a draft waiting cancels it; nothing is acknowledged, scored or paid", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(44.90, PLAYER_P, 7, OUTFIT_B)
		harness.sendDraftAtRoundSecond(44.95, PLAYER_P, 8, OUTFIT_C)
		expect(harness.createdDraftKeepers[1]:countPendingOutfitDraftProcessingTimers()).toBe(1)
		harness.leaveServerAtRoundSecond(45, PLAYER_P)
		expect(harness.createdDraftKeepers[1]:countPendingOutfitDraftProcessingTimers()).toBe(0)
		harness.advanceToRoundSecond(46)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(44.90, "round-1", 7, true),
		})
		harness.advanceToRoundSecond(200)
		expect(harness.referee:readShowcaseStageEntry(PLAYER_P)).toBeNil()
		harness.advanceToRoundSecond(251)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(0)
		expect(harness.listPublishedRoundResultsMessages()[1].roundResults).toEqual({})
	end)

	it(
		"scenario 51: leaving between scoring and reward: no ledger call and no entry; the other player is paid",
		function()
			local harness = createRefereeWithFakes()
			harness.loadAndJoinAtRoundSecond3({ PLAYER_P, PLAYER_Q })
			harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
			harness.sendDraftAtRoundSecond(20, PLAYER_Q, 1, OUTFIT_E83)
			harness.advanceToRoundSecond(200)
			expect(harness.referee:readShowcaseStageEntry(PLAYER_P).outfitScore).toBe(83)
			harness.leaveServerAtRoundSecond(220, PLAYER_P)
			expect(harness.referee:readShowcaseStageEntry(PLAYER_P)).toBeNil()
			harness.advanceToRoundSecond(251)
			expect(#harness.recordedGrantCalls).toBe(1)
			expect(harness.recordedGrantCalls[1].playerUserId).toBe(PLAYER_Q)
			expect(harness.recordedGrantCalls[1].themedRoundCompletion.starCount).toBe(4)
			expect(listResultsPlayerUserIds(harness)).toEqual({ PLAYER_Q })
			local storedSaveOfP = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER_P)
			expect(storedSaveOfP.starCoinBalance).toBe(350)
			expect(storedSaveOfP.fanCount).toBe(1200)
			expect(storedSaveOfP.totalRoundsCompletedCount).toBe(14)
		end
	)

	it("scenario 52: leaving after the grant changes nothing: no second call, the published entry stays", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
		harness.advanceToRoundSecond(250)
		local publishedBeforeLeaving = harness.referee:readLastPublishedRoundResults()
		harness.leaveServerAtRoundSecond(255, PLAYER_P)
		harness.advanceToRoundSecond(279)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(1)
		expect(harness.referee:readLastPublishedRoundResults()).toBe(publishedBeforeLeaving)
		expect(publishedBeforeLeaving.roundResults[1].starCoinsGranted).toBe(80)
		local storedSaveOfP = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER_P)
		expect(storedSaveOfP.starCoinBalance).toBe(430)
		expect(storedSaveOfP.fanCount).toBe(1240)
		expect(#harness.listPublishedRoundResultsMessages()).toBe(1)
	end)

	it("forgets the player in the rate limiter when they leave the server", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		expect(harness.playerRequestRateLimiter:countRememberedPlayers()).toBe(1)
		harness.leaveServerAtRoundSecond(4, PLAYER_P)
		expect(harness.playerRequestRateLimiter:countRememberedPlayers()).toBe(0)
	end)

	it("tolerates a leave notification for a non-participant and a second one for the same player", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.advanceToRoundSecond(5)
		harness.referee:removePlayerWhoLeftServer(PLAYER_Q)
		harness.referee:removePlayerWhoLeftServer(PLAYER_P)
		harness.referee:removePlayerWhoLeftServer(PLAYER_P)
		expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({})
	end)
end)

describe("ThemedRoundReferee losing the save session (audit scenario 54, question 12)", function()
	it("removes the player at once on SessionLockLost while still connected, and tolerates the later leave", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P, PLAYER_Q })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 4, OUTFIT_E83)
		harness.sendDraftAtRoundSecond(20, PLAYER_Q, 1, OUTFIT_A)
		harness.loseSessionLockAtRoundSecond(185, PLAYER_P)
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER_P)).toBeFalse()
		expect(harness.referee:isParticipantOfCurrentRound(PLAYER_P)).toBeFalse()
		local draftsReachingKeeperBefore = harness.countDraftsReachingKeeperFrom(PLAYER_P)
		harness.sendDraftAtRoundSecond(186, PLAYER_P, 5, OUTFIT_B)
		expect(harness.countDraftsReachingKeeperFrom(PLAYER_P)).toBe(draftsReachingKeeperBefore)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
		harness.advanceToRoundSecond(190)
		expect(findBroadcastAt(harness, 190).participantUserIds).toEqual({ PLAYER_Q })
		harness.advanceToRoundSecond(192)
		harness.referee:removePlayerWhoLeftServer(PLAYER_P)
		harness.advanceToRoundSecond(251)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(0)
		expect(listResultsPlayerUserIds(harness)).toEqual({ PLAYER_Q })
	end)

	it("removes the player when the session ends for any reason, also between scoring and reward", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
		harness.advanceToRoundSecond(200)
		-- The final save ends the session ("FinalSaveSucceeded") without the referee being told first.
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER_P)
		harness.advanceToRoundSecond(201)
		expect(harness.referee:isParticipantOfCurrentRound(PLAYER_P)).toBeFalse()
		expect(harness.referee:readShowcaseStageEntry(PLAYER_P)).toBeNil()
		harness.referee:removePlayerWhoLeftServer(PLAYER_P)
		harness.advanceToRoundSecond(251)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(0)
		expect(harness.listPublishedRoundResultsMessages()[1].roundResults).toEqual({})
	end)
end)

describe("ThemedRoundReferee rejoining the same round (audit scenario 53, owner question 11)", function()
	local function playUntilRejoinAtRoundSecond95(ownerDecisions)
		local harness = createRefereeWithFakes({ ownerDecisions = ownerDecisions })
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(30, PLAYER_P, 7, OUTFIT_B)
		harness.leaveServerAtRoundSecond(45, PLAYER_P)
		harness.advanceToRoundSecond(90)
		harness.loadPlayerFromWhatStorageHolds(PLAYER_P)
		harness.advanceToRoundSecond(95)
		return harness, harness.referee:admitOrRejectJoinCurrentRoundRequest(PLAYER_P)
	end

	it("default: accepted as a brand-new participant; a fresh seq 1 is acknowledged and scored", function()
		local harness, joinAnswer = playUntilRejoinAtRoundSecond95(nil)
		expect(joinAnswer).toEqual({ isAccepted = true })
		harness.sendDraftAtRoundSecond(96, PLAYER_P, 1, OUTFIT_C)
		local acknowledgements = harness.listAcknowledgementsSentTo(PLAYER_P)
		expect(acknowledgements[#acknowledgements]).toEqual(expectedAcknowledgement(96, "round-1", 1, true))
		harness.advanceToRoundSecond(200)
		expect(harness.referee:readShowcaseStageEntry(PLAYER_P).scoredOutfitStylingItemKeys).toEqual(OUTFIT_C)
		harness.advanceToRoundSecond(251)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(1)
		expect(harness.recordedGrantCalls[1].themedRoundCompletion.scoredOutfitStylingItemKeys).toEqual(OUTFIT_C)
	end)

	it("default, variant: the rejoined player sends nothing; the final outfit is empty, not the old B", function()
		local harness = playUntilRejoinAtRoundSecond95(nil)
		harness.advanceToRoundSecond(200)
		expect(harness.referee:readShowcaseStageEntry(PLAYER_P).scoredOutfitStylingItemKeys).toEqual({})
		harness.advanceToRoundSecond(251)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(0)
		expect(harness.listPublishedRoundResultsMessages()[1].roundResults[1].outfitScore).toBe(0)
	end)

	it("alternative answer (refuse): RoundNotJoinableNow for the rest of the round, and B is never scored", function()
		local refusingOwnerDecisions = table.clone(ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS)
		refusingOwnerDecisions.isRejoiningSameRoundAfterLeavingAllowed = false
		local harness, joinAnswer = playUntilRejoinAtRoundSecond95(refusingOwnerDecisions)
		expect(joinAnswer).toEqual({ isAccepted = false, rejectionReason = "RoundNotJoinableNow" })
		harness.loadPlayer(PLAYER_Q)
		expect(harness.joinAtRoundSecond(96, PLAYER_Q)).toEqual({ isAccepted = true })
		harness.sendDraftAtRoundSecond(97, PLAYER_P, 8, OUTFIT_D)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
		harness.advanceToRoundSecond(251)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(0)
		expect(listResultsPlayerUserIds(harness)).toEqual({ PLAYER_Q })
		harness.advanceToRoundSecond(281)
		expect(harness.joinAtRoundSecond(282, PLAYER_P)).toEqual({ isAccepted = true })
	end)
end)

describe("ThemedRoundReferee round isolation (audit scenario 55)", function()
	it("keeps draft state per round: R1 numbers and ids do nothing in R2, and B is not paid again", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 40, OUTFIT_B)
		harness.advanceToRoundSecond(280)
		local acknowledgementCountAfterRoundOne = #harness.listAcknowledgementsSentTo(PLAYER_P)
		harness.sendDraftAtRoundSecond(291, PLAYER_P, 1, OUTFIT_C, "round-2")
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(acknowledgementCountAfterRoundOne)
		expect(harness.joinAtRoundSecond(292, PLAYER_P)).toEqual({ isAccepted = true })
		harness.sendDraftAtRoundSecond(293, PLAYER_P, 41, OUTFIT_D, "round-1")
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(acknowledgementCountAfterRoundOne)
		harness.sendDraftAtRoundSecond(294, PLAYER_P, 1, OUTFIT_C, "round-2")
		local acknowledgements = harness.listAcknowledgementsSentTo(PLAYER_P)
		expect(acknowledgements[#acknowledgements]).toEqual(expectedAcknowledgement(294, "round-2", 1, true))
	end)

	it("variant: joining R2 and sending nothing gives an empty final outfit and no second payment", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 40, OUTFIT_A)
		harness.advanceToRoundSecond(285)
		expect(harness.referee:admitOrRejectJoinCurrentRoundRequest(PLAYER_P)).toEqual({ isAccepted = true })
		harness.advanceToRoundSecond(531)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(1)
		local roundTwoResults = harness.listPublishedRoundResultsMessages()[2]
		expect(roundTwoResults.roundId).toBe("round-2")
		expect(roundTwoResults.roundResults[1].starCount).toBe(0)
		expect(roundTwoResults.roundResults[1].starCoinsGranted).toBe(0)
	end)

	it("ends the previous round's draft keeper at the next ThemeReveal", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.advanceToRoundSecond(279)
		expect(harness.createdDraftKeepers[1]:countParticipants()).toBe(1)
		harness.advanceToRoundSecond(280)
		expect(#harness.createdDraftKeepers).toBe(2)
		expect(harness.createdDraftKeepers[1]:countParticipants()).toBe(0)
		expect(function()
			harness.createdDraftKeepers[1]:addParticipant(PLAYER_Q)
		end).toThrow("RoundEnded")
	end)
end)
