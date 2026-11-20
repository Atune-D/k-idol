-- The referee's parts on their own: ThemedRoundParticipantRoster, ThemedRoundFinalOutfitScorer,
-- ThemedRoundRewardSettlement and ThemedRoundOwnerDecisions. Covers what the referee-level spec
-- files cannot reach directly (guards that the referee never trips in normal use), plus stage
-- places when someone leaves before the cut-off (development spec §2.4, audit question 23).

local UnitTestFramework = require("../Support/UnitTestFramework")
local RecordingLogger = require("../Support/RecordingLogger")
local ScriptableFakeThemedRoundRewardLedger = require("../Support/ScriptableFakeThemedRoundRewardLedger")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local ThemeCatalog = require("../../src/shared/ThemeCatalog")
local ThemedRoundFinalOutfitScorer = require("../../src/server/ThemedRoundFinalOutfitScorer")
local ThemedRoundOwnerDecisions = require("../../src/server/ThemedRoundOwnerDecisions")
local ThemedRoundParticipantRoster = require("../../src/server/ThemedRoundParticipantRoster")
local ThemedRoundRewardSettlement = require("../../src/server/ThemedRoundRewardSettlement")
local ThemedRoundRefereeTestHarness = require("./ThemedRoundRefereeTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local OUTFIT_A = ThemedRoundRefereeTestHarness.OUTFIT_A
local OUTFIT_E83 = ThemedRoundRefereeTestHarness.WORKED_EXAMPLE_OUTFIT_E83
local ROUND_ONE_BONUS_RULE = table.freeze({ roundBonusKind = "ColorBonus", bonusColorTag = "pink" })

describe("ThemedRoundParticipantRoster", function()
	it("lists participants in join order, never reuses a position, and remembers who left", function()
		local roster = ThemedRoundParticipantRoster.new()
		expect(roster:addParticipant(30)).toBe(1)
		expect(roster:addParticipant(10)).toBe(2)
		expect(roster:addParticipant(20)).toBe(3)
		expect(roster:listParticipantUserIdsInJoinOrder()).toEqual({ 30, 10, 20 })
		expect(roster:removeParticipant(30)).toBeTrue()
		expect(roster:removeParticipant(30)).toBeFalse()
		expect(roster:removeParticipant(99)).toBeFalse()
		expect(roster:hasLeftThisRound(30)).toBeTrue()
		expect(roster:hasLeftThisRound(10)).toBeFalse()
		expect(roster:hasLeftThisRound(99)).toBeFalse()
		expect(roster:addParticipant(30)).toBe(4)
		expect(roster:hasLeftThisRound(30)).toBeTrue()
		expect(roster:listParticipantUserIdsInJoinOrder()).toEqual({ 10, 20, 30 })
		expect(roster:readJoinOrderPosition(30)).toBe(4)
		expect(roster:readJoinOrderPosition(99)).toBeNil()
		expect(roster:countParticipants()).toBe(3)
		expect(roster:isParticipant(10)).toBeTrue()
		expect(roster:isParticipant(99)).toBeFalse()
		expect(table.isfrozen(roster:listParticipantUserIdsInJoinOrder())).toBeTrue()
	end)

	it("hands out a fresh list each time, so a caller cannot change the roster", function()
		local roster = ThemedRoundParticipantRoster.new()
		roster:addParticipant(10)
		local firstList = roster:listParticipantUserIdsInJoinOrder()
		expect(firstList == roster:listParticipantUserIdsInJoinOrder()).toBeFalse()
	end)

	it("raises for a duplicate and for a playerUserId that is not a number or is NaN", function()
		local roster = ThemedRoundParticipantRoster.new()
		roster:addParticipant(10)
		expect(function()
			roster:addParticipant(10)
		end).toThrow("already a participant")
		for _, methodName in
			{ "addParticipant", "removeParticipant", "isParticipant", "hasLeftThisRound", "readJoinOrderPosition" }
		do
			for _, badPlayerUserId in { "10", 0 / 0 } do
				expect(function()
					(roster :: any)[methodName](roster, badPlayerUserId)
				end).toThrow("ThemedRoundParticipantRoster: playerUserId must be a number")
			end
		end
	end)
end)

describe("ThemedRoundFinalOutfitScorer", function()
	local function scoreParticipants(participantsInJoinOrder, finalOutfitStylingItemKeysByPlayerUserId)
		return ThemedRoundFinalOutfitScorer.scoreFinalOutfitsAndAssignStagePlaces({
			participantsInJoinOrder = participantsInJoinOrder,
			finalOutfitStylingItemKeysByPlayerUserId = finalOutfitStylingItemKeysByPlayerUserId,
			stylingItemByStylingItemKey = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
			theme = ThemeCatalog.findThemeByThemeId("y2k_pop"),
			roundBonusRule = ROUND_ONE_BONUS_RULE,
		})
	end

	it(
		"gives stage places 1, 2, 3 over the scored participants in join order, skipping one without an outfit",
		function()
			local scoredParticipants = scoreParticipants({
				{ playerUserId = 30, joinOrderPosition = 2 },
				{ playerUserId = 40, joinOrderPosition = 3 },
				{ playerUserId = 10, joinOrderPosition = 5 },
				{ playerUserId = 20, joinOrderPosition = 6 },
			}, { [30] = OUTFIT_E83, [10] = {}, [20] = OUTFIT_A })
			expect(#scoredParticipants).toBe(3)
			expect({
				scoredParticipants[1].playerUserId,
				scoredParticipants[2].playerUserId,
				scoredParticipants[3].playerUserId,
			}).toEqual({
				30,
				10,
				20,
			})
			expect({
				scoredParticipants[1].stagePlaceNumber,
				scoredParticipants[2].stagePlaceNumber,
				scoredParticipants[3].stagePlaceNumber,
			}).toEqual({ 1, 2, 3 })
			expect(scoredParticipants[1].joinOrderPosition).toBe(2)
			expect(scoredParticipants[1].outfitScoreBreakdown.outfitScore).toBe(83)
			expect(scoredParticipants[2].outfitScoreBreakdown.isOutfitEmpty).toBeTrue()
			expect(table.isfrozen(scoredParticipants)).toBeTrue()
			expect(table.isfrozen(scoredParticipants[1])).toBeTrue()
		end
	)

	it("copies an outfit list that is not frozen, so the caller's later change cannot alter what was scored", function()
		local callerOwnedOutfit = table.clone(OUTFIT_E83)
		local scoredParticipants = scoreParticipants(
			{ { playerUserId = 10, joinOrderPosition = 1 } },
			{ [10] = callerOwnedOutfit }
		)
		callerOwnedOutfit[1] = "asset_9000002"
		expect(scoredParticipants[1].scoredOutfitStylingItemKeys).toEqual(OUTFIT_E83)
		expect(table.isfrozen(scoredParticipants[1].scoredOutfitStylingItemKeys)).toBeTrue()
		expect(table.isfrozen(callerOwnedOutfit)).toBeFalse()
	end)

	it("leaves out only the participant whose scoring raises and hands them back; places stay 1, 2", function()
		local scoredParticipants, playerUserIdsWhoseScoringRaised = scoreParticipants({
			{ playerUserId = 30, joinOrderPosition = 1 },
			{ playerUserId = 40, joinOrderPosition = 2 },
			{ playerUserId = 10, joinOrderPosition = 3 },
		}, { [30] = OUTFIT_E83, [40] = { "key_missing_from_the_pool" }, [10] = OUTFIT_A })
		expect(#scoredParticipants).toBe(2)
		expect({ scoredParticipants[1].playerUserId, scoredParticipants[2].playerUserId }).toEqual({ 30, 10 })
		expect({ scoredParticipants[1].stagePlaceNumber, scoredParticipants[2].stagePlaceNumber }).toEqual({ 1, 2 })
		expect(playerUserIdsWhoseScoringRaised).toEqual({ 40 })
		expect(table.isfrozen(playerUserIdsWhoseScoringRaised)).toBeTrue()
	end)

	it("keeps an already frozen outfit list as it is", function()
		local scoredParticipants = scoreParticipants(
			{ { playerUserId = 10, joinOrderPosition = 1 } },
			{ [10] = OUTFIT_E83 }
		)
		expect(scoredParticipants[1].scoredOutfitStylingItemKeys).toBe(OUTFIT_E83)
	end)
end)

describe("ThemedRoundRewardSettlement on its own", function()
	local function buildScoredParticipant(playerUserId: number, joinOrderPosition: number, outfitStylingItemKeys)
		return ThemedRoundFinalOutfitScorer.scoreFinalOutfitsAndAssignStagePlaces({
			participantsInJoinOrder = { { playerUserId = playerUserId, joinOrderPosition = joinOrderPosition } },
			finalOutfitStylingItemKeysByPlayerUserId = { [playerUserId] = outfitStylingItemKeys },
			stylingItemByStylingItemKey = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
			theme = ThemeCatalog.findThemeByThemeId("y2k_pop"),
			roundBonusRule = ROUND_ONE_BONUS_RULE,
		})[1]
	end

	it("never calls the ledger twice for a player already marked settled, and logs one line per settlement", function()
		local fakeLedger = ScriptableFakeThemedRoundRewardLedger.new()
		local logger = RecordingLogger.new()
		local settledPlayerUserIdSet = {}
		local roundRewardSettlementRequest = {
			roundId = "round-7",
			themeId = "y2k_pop",
			scoredParticipantsStillPresent = { buildScoredParticipant(10, 1, OUTFIT_E83) },
			rewardLedger = fakeLedger,
			readPlayerDisplayName = function(playerUserId: number)
				return "Player " .. tostring(playerUserId)
			end,
			ownerDecisions = ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS,
			logger = logger,
			settledPlayerUserIdSet = settledPlayerUserIdSet,
		}
		local firstRoundResults =
			ThemedRoundRewardSettlement.settleRoundRewardsAndBuildRoundResults(roundRewardSettlementRequest)
		expect(#firstRoundResults).toBe(1)
		expect(settledPlayerUserIdSet[10]).toBeTrue()
		local secondRoundResults =
			ThemedRoundRewardSettlement.settleRoundRewardsAndBuildRoundResults(roundRewardSettlementRequest)
		expect(secondRoundResults).toEqual({})
		expect(fakeLedger:countGrantCallsFor(10)).toBe(1)
		expect(logger.loggedInformation).toEqual({
			"ThemedRoundRewardSettlement: round round-7 settled with 1 results entries",
			"ThemedRoundRewardSettlement: round round-7 settled with 0 results entries",
		})
	end)

	it("marks a player settled before calling the ledger, so a raising call still counts as settled", function()
		local fakeLedger = ScriptableFakeThemedRoundRewardLedger.new()
		fakeLedger:scriptGrantOutcomeForPlayer(10, "Raise")
		local settledPlayerUserIdSet = {}
		ThemedRoundRewardSettlement.settleRoundRewardsAndBuildRoundResults({
			roundId = "round-7",
			themeId = "y2k_pop",
			scoredParticipantsStillPresent = { buildScoredParticipant(10, 1, OUTFIT_E83) },
			rewardLedger = fakeLedger,
			readPlayerDisplayName = tostring,
			ownerDecisions = ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS,
			logger = RecordingLogger.new(),
			settledPlayerUserIdSet = settledPlayerUserIdSet,
		})
		expect(settledPlayerUserIdSet[10]).toBeTrue()
	end)

	it(
		"the marker is already set while the ledger is being called, so a re-entrant settlement skips the player",
		function()
			local settledPlayerUserIdSet = {}
			local markerSeenDuringGrantCall = nil
			local grantCallCount = 0
			local roundRewardSettlementRequest
			local reenteringLedger = {
				grantThemedRoundReward = function(_, playerUserId: number)
					grantCallCount += 1
					markerSeenDuringGrantCall = settledPlayerUserIdSet[playerUserId]
					ThemedRoundRewardSettlement.settleRoundRewardsAndBuildRoundResults(roundRewardSettlementRequest)
					return { rewardLedgerOutcome = "Granted", starCoinsGranted = 80, fanCountGained = 40 }
				end,
			}
			roundRewardSettlementRequest = {
				roundId = "round-7",
				themeId = "y2k_pop",
				scoredParticipantsStillPresent = { buildScoredParticipant(10, 1, OUTFIT_E83) },
				rewardLedger = reenteringLedger,
				readPlayerDisplayName = tostring,
				ownerDecisions = ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS,
				logger = RecordingLogger.new(),
				settledPlayerUserIdSet = settledPlayerUserIdSet,
			}
			ThemedRoundRewardSettlement.settleRoundRewardsAndBuildRoundResults(roundRewardSettlementRequest)
			expect(markerSeenDuringGrantCall).toBe(true)
			expect(grantCallCount).toBe(1)
		end
	)

	it("hands back, frozen and in settlement order, the players whose save data was not loaded", function()
		local fakeLedger = ScriptableFakeThemedRoundRewardLedger.new()
		fakeLedger:scriptGrantOutcomeForPlayer(20, "SaveDataNotLoaded")
		fakeLedger:scriptGrantOutcomeForPlayer(30, "SaveDataNotLoaded")
		fakeLedger:scriptGrantOutcomeForPlayer(40, "Declined")
		local roundResults, playerUserIdsWhoseSaveDataWasNotLoaded =
			ThemedRoundRewardSettlement.settleRoundRewardsAndBuildRoundResults({
				roundId = "round-7",
				themeId = "y2k_pop",
				scoredParticipantsStillPresent = {
					buildScoredParticipant(30, 1, OUTFIT_E83),
					buildScoredParticipant(10, 2, OUTFIT_E83),
					buildScoredParticipant(20, 3, OUTFIT_E83),
					buildScoredParticipant(40, 4, OUTFIT_E83),
				},
				rewardLedger = fakeLedger,
				readPlayerDisplayName = tostring,
				ownerDecisions = ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS,
				logger = RecordingLogger.new(),
				settledPlayerUserIdSet = {},
			})
		expect(#roundResults).toBe(2)
		expect(playerUserIdsWhoseSaveDataWasNotLoaded).toEqual({ 30, 20 })
		expect(table.isfrozen(playerUserIdsWhoseSaveDataWasNotLoaded)).toBeTrue()
	end)
end)

describe("ThemedRoundOwnerDecisions", function()
	it("holds the audit's recommended defaults, frozen", function()
		expect(ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS).toEqual({
			isRejoiningSameRoundAfterLeavingAllowed = true,
			isEmptyFinalOutfitListedInRoundResults = true,
			shouldShowLobbyAppearanceOnStageForEmptyScoredOutfit = true,
			shouldForfeitUnsettledRoundAtServerShutdown = true,
		})
		expect(table.isfrozen(ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS)).toBeTrue()
		ThemedRoundOwnerDecisions.assertIsOwnerDecisions(ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS)
	end)

	it("refuses a decisions table with a missing or non-boolean answer", function()
		for _, fieldName in
			{
				"isRejoiningSameRoundAfterLeavingAllowed",
				"isEmptyFinalOutfitListedInRoundResults",
				"shouldShowLobbyAppearanceOnStageForEmptyScoredOutfit",
				"shouldForfeitUnsettledRoundAtServerShutdown",
			}
		do
			local wrongOwnerDecisions = table.clone(ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS) :: any
			wrongOwnerDecisions[fieldName] = "yes"
			expect(function()
				ThemedRoundOwnerDecisions.assertIsOwnerDecisions(wrongOwnerDecisions)
			end).toThrow(fieldName)
		end
	end)
end)

describe("ThemedRoundReferee stage places when a participant leaves before the cut-off", function()
	it("numbers the stage places over the participants still present, in join order", function()
		local harness = ThemedRoundRefereeTestHarness.createRefereeWithFakes()
		local playerP, playerQ, playerR =
			ThemedRoundRefereeTestHarness.PLAYER_P,
			ThemedRoundRefereeTestHarness.PLAYER_Q,
			ThemedRoundRefereeTestHarness.PLAYER_R
		harness.loadAndJoinAtRoundSecond3({ playerP, playerQ, playerR })
		harness.leaveServerAtRoundSecond(100, playerQ)
		harness.advanceToRoundSecond(200)
		expect(harness.referee:readShowcaseStageEntry(playerP).stagePlaceNumber).toBe(1)
		expect(harness.referee:readShowcaseStageEntry(playerR).stagePlaceNumber).toBe(2)
	end)
end)
