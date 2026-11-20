-- ThemedRoundReferee, server shutdown in the middle of a round (development spec §3.4 "Server
-- shuts down", §2.5). Referee audit PART 3 section L, scenarios 75 and 76, and owner question 24
-- in both of its answers (ThemedRoundOwnerDecisions.shouldForfeitUnsettledRoundAtServerShutdown).

local UnitTestFramework = require("../Support/UnitTestFramework")
local ThemedRoundOwnerDecisions = require("../../src/server/ThemedRoundOwnerDecisions")
local ThemedRoundRefereeTestHarness = require("./ThemedRoundRefereeTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_P = ThemedRoundRefereeTestHarness.PLAYER_P
local PLAYER_Q = ThemedRoundRefereeTestHarness.PLAYER_Q
local PLAYER_R = ThemedRoundRefereeTestHarness.PLAYER_R
local OUTFIT_A = ThemedRoundRefereeTestHarness.OUTFIT_A
local OUTFIT_B = ThemedRoundRefereeTestHarness.OUTFIT_B
local OUTFIT_E83 = ThemedRoundRefereeTestHarness.WORKED_EXAMPLE_OUTFIT_E83
local createRefereeWithFakes = ThemedRoundRefereeTestHarness.createRefereeWithFakes

local function createOwnerDecisionsSettlingEarlyAtShutdown()
	local settlingOwnerDecisions = table.clone(ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS)
	settlingOwnerDecisions.shouldForfeitUnsettledRoundAtServerShutdown = false
	return settlingOwnerDecisions
end

local function playUntilBothScoredAtRoundSecond220(ownerDecisions)
	local harness = createRefereeWithFakes({ ownerDecisions = ownerDecisions })
	harness.loadAndJoinAtRoundSecond3({ PLAYER_P, PLAYER_Q })
	harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
	harness.sendDraftAtRoundSecond(20, PLAYER_Q, 1, OUTFIT_A)
	harness.advanceToRoundSecond(220)
	return harness
end

describe(
	"ThemedRoundReferee shutdown before Results (audit scenario 75, default answer to owner question 24)",
	function()
		it("accepts no join or draft afterwards and grants and publishes nothing", function()
			local harness = playUntilBothScoredAtRoundSecond220(nil)
			harness.referee:beginServerShutdown()
			expect(harness.referee:isServerShuttingDown()).toBeTrue()
			harness.loadPlayer(PLAYER_R)
			expect(harness.joinAtRoundSecond(221, PLAYER_R)).toEqual({
				isAccepted = false,
				rejectionReason = "RoundNotJoinableNow",
			})
			local draftsReachingKeeperBefore = #harness.draftsReachingKeeperRecords
			harness.sendDraftAtRoundSecond(221, PLAYER_P, 2, OUTFIT_B)
			expect(#harness.draftsReachingKeeperRecords).toBe(draftsReachingKeeperBefore)
			local broadcastCountAtShutdown = #harness.sentRoundStateChangedRecords
			harness.advanceToRoundSecond(300)
			expect(#harness.recordedGrantCalls).toBe(0)
			expect(#harness.sentRoundResultsPublishedRecords).toBe(0)
			expect(#harness.sentRoundStateChangedRecords).toBe(broadcastCountAtShutdown)
			expect(harness.readInMemorySaveData(PLAYER_P).starCoinBalance).toBe(350)
		end)

		it("refuses a join that would otherwise be accepted (ThemeReveal and early Styling)", function()
			local harness = createRefereeWithFakes()
			harness.loadPlayers({ PLAYER_P, PLAYER_Q })
			harness.advanceToRoundSecond(5)
			harness.referee:beginServerShutdown()
			expect(harness.referee:admitOrRejectJoinCurrentRoundRequest(PLAYER_P)).toEqual({
				isAccepted = false,
				rejectionReason = "RoundNotJoinableNow",
			})
			expect(harness.joinAtRoundSecond(20, PLAYER_Q)).toEqual({
				isAccepted = false,
				rejectionReason = "RoundNotJoinableNow",
			})
			expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({})
		end)

		it("during Styling: the waiting draft's timer is dropped and nothing is acknowledged afterwards", function()
			local harness = createRefereeWithFakes()
			harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
			harness.sendDraftAtRoundSecond(50.00, PLAYER_P, 1, OUTFIT_A)
			harness.sendDraftAtRoundSecond(50.10, PLAYER_P, 2, OUTFIT_B)
			expect(harness.createdDraftKeepers[1]:countPendingOutfitDraftProcessingTimers()).toBe(1)
			harness.referee:beginServerShutdown()
			expect(harness.createdDraftKeepers[1]:countPendingOutfitDraftProcessingTimers()).toBe(0)
			harness.advanceToRoundSecond(300)
			expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
			expect(#harness.recordedGrantCalls).toBe(0)
		end)

		it("logs the start of shutdown once; a second call changes nothing", function()
			local harness = playUntilBothScoredAtRoundSecond220(nil)
			harness.referee:beginServerShutdown()
			harness.referee:beginServerShutdown()
			local shutdownLines = 0
			for _, loggedInformation in harness.recordingLogger.loggedInformation do
				if string.find(loggedInformation, "shutdown", 1, true) then
					shutdownLines += 1
				end
			end
			expect(shutdownLines).toBe(1)
			expect(
				string.find(
					harness.recordingLogger.loggedInformation[#harness.recordingLogger.loggedInformation],
					"round-1",
					1,
					true
				) ~= nil
			).toBeTrue()
		end)

		it("still answers reads for the character dresser after shutdown", function()
			local harness = playUntilBothScoredAtRoundSecond220(nil)
			harness.referee:beginServerShutdown()
			expect(harness.referee:readShowcaseStageEntry(PLAYER_P).outfitScore).toBe(83)
			expect(harness.referee:readCharacterSpawnRoundFacts(PLAYER_P).isParticipant).toBeTrue()
		end)

		it("once the clock has moved on to the next round, nothing of the shut-down round is answered", function()
			local harness = playUntilBothScoredAtRoundSecond220(nil)
			harness.referee:beginServerShutdown()
			harness.advanceToRoundSecond(480) -- round-2 Showcase
			expect(harness.readCurrentRoundState().roundId).toBe("round-2")
			expect(harness.referee:readShowcaseStageEntry(PLAYER_P)).toBeNil()
			expect(harness.referee:readCharacterSpawnRoundFacts(PLAYER_P)).toEqual({
				roundPhase = "Showcase",
				isParticipant = false,
			})
			expect(harness.referee:isParticipantOfCurrentRound(PLAYER_P)).toBeFalse()
			expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({})
			expect(harness.referee:readRoundStateChangedMessage().participantUserIds).toEqual({})
			harness.sendDraftAtRoundSecond(481, PLAYER_P, 2, OUTFIT_B, "round-1")
			expect(harness.countDraftsReachingKeeperFrom(PLAYER_P)).toBe(1)
			expect(harness.joinAtRoundSecond(485, PLAYER_P)).toEqual({
				isAccepted = false,
				rejectionReason = "RoundNotJoinableNow",
			})
		end)

		it("before any round exists, shutdown is harmless", function()
			local harness = createRefereeWithFakes({ doNotStartRoundClock = true })
			harness.referee:beginServerShutdown()
			expect(harness.referee:isServerShuttingDown()).toBeTrue()
			harness.themedRoundClock:startRoundCycle()
			expect(#harness.sentRoundStateChangedRecords).toBe(0)
			expect(#harness.createdDraftKeepers).toBe(0)
		end)
	end
)

describe("ThemedRoundReferee shutdown after the grants (audit scenario 76)", function()
	it("makes no second grant, and the final save writes the amounts granted at T=250", function()
		local harness = playUntilBothScoredAtRoundSecond220(nil)
		harness.advanceToRoundSecond(255)
		harness.referee:beginServerShutdown()
		local finalSavesFinishedCount = 0
		harness.playerSaveDataKeeper:startFinalSavesForServerShutdown(function()
			finalSavesFinishedCount += 1
		end)
		harness.advanceToRoundSecond(285)
		expect(finalSavesFinishedCount).toBe(1)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(1)
		expect(harness.countGrantCallsFor(PLAYER_Q)).toBe(1)
		local storedSaveOfP = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER_P)
		expect({ storedSaveOfP.starCoinBalance, storedSaveOfP.fanCount, storedSaveOfP.totalRoundsCompletedCount }).toEqual({
			430,
			1240,
			15,
		})
		expect(storedSaveOfP.gameServerSessionLock).toBeNil()
		local storedSaveOfQ = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER_Q)
		expect(storedSaveOfQ.starCoinBalance).toBe(370)
	end)
end)

describe("ThemedRoundReferee alternative answer to owner question 24 (settle a scored round at shutdown)", function()
	it("settles and publishes at once when shutdown begins during Showcase, then nothing more", function()
		local harness = playUntilBothScoredAtRoundSecond220(createOwnerDecisionsSettlingEarlyAtShutdown())
		harness.referee:beginServerShutdown()
		expect(#harness.sentRoundResultsPublishedRecords).toBe(1)
		expect(harness.sentRoundResultsPublishedRecords[1].roundMilliseconds).toBe(220000)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(1)
		expect(harness.readInMemorySaveData(PLAYER_P).starCoinBalance).toBe(430)
		harness.advanceToRoundSecond(300)
		expect(#harness.sentRoundResultsPublishedRecords).toBe(1)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(1)
	end)

	it("pays nothing when shutdown begins during Styling (nothing was scored yet)", function()
		local harness = createRefereeWithFakes({ ownerDecisions = createOwnerDecisionsSettlingEarlyAtShutdown() })
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
		harness.referee:beginServerShutdown()
		harness.advanceToRoundSecond(300)
		expect(#harness.recordedGrantCalls).toBe(0)
		expect(#harness.sentRoundResultsPublishedRecords).toBe(0)
	end)

	it("does not settle a second time when shutdown begins after Results", function()
		local harness = playUntilBothScoredAtRoundSecond220(createOwnerDecisionsSettlingEarlyAtShutdown())
		harness.advanceToRoundSecond(255)
		harness.referee:beginServerShutdown()
		expect(#harness.sentRoundResultsPublishedRecords).toBe(1)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(1)
	end)
end)
