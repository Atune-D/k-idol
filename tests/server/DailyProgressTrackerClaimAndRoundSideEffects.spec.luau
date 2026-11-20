-- What exactly the daily claims and the round record writer change in the save (development spec
-- §1.8 "daily rewards pay Star Coins", §3.3 "a reward and its record are one change"): a claim
-- changes only the balance and its own record, a round changes only quest progress in
-- dailyProgress, so neither can make an earlier claim payable again.
--
-- Today's test quests: quest_a (CompleteRounds, target 3, 60), quest_d (at least 4 stars, target
-- 2, 120), quest_e (pink, target 1, 70).

local DailyProgressTrackerTestHarness = require("./DailyProgressTrackerTestHarness")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local PlaytimeMilestoneCatalog = require("../../src/shared/PlaytimeMilestoneCatalog")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = DailyProgressTrackerTestHarness.PLAYER
local PINK_HAIR_KEY = DailyProgressTrackerTestHarness.PINK_HAIR_KEY
local BLACK_BOTTOM_KEY = DailyProgressTrackerTestHarness.BLACK_BOTTOM_KEY
local BLUE_TOP_KEY = DailyProgressTrackerTestHarness.BLUE_TOP_KEY

local function copySave(harness)
	return PlayerSaveDataSchema.createDeepCopyOfPlainTable(harness.readInMemorySaveData(PLAYER))
end

-- The whole save after the claim must equal `expectedSaveData`, except the two fields the keeper
-- itself stamps when the claim's save-at-once is written.
local function expectSaveToEqualApartFromKeeperSaveStamps(harness, expectedSaveData)
	local actualSaveData = harness.readInMemorySaveData(PLAYER)
	expectedSaveData.lastSavedAtUnixSeconds = actualSaveData.lastSavedAtUnixSeconds
	expectedSaveData.gameServerSessionLock = actualSaveData.gameServerSessionLock
	expect(actualSaveData).toEqual(expectedSaveData)
end

describe("A daily claim changes only the balance and its own record", function()
	it("a milestone claim: starCoinBalance and claimedPlaytimeMilestoneMinutes, nothing else", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ admitsEveryRequest = true })
		harness.loadPlayer(PLAYER)
		harness.grantRoundReward(PLAYER, "round-1", 4, { PINK_HAIR_KEY })
		harness.advanceSeconds(300)
		local expectedSaveData = copySave(harness)
		expectedSaveData.starCoinBalance += 20
		table.insert(expectedSaveData.dailyProgress.claimedPlaytimeMilestoneMinutes, 5)

		expect(harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 5).isAccepted).toBeTrue()
		expectSaveToEqualApartFromKeeperSaveStamps(harness, expectedSaveData)
	end)

	it("a quest claim: starCoinBalance and claimedDailyQuestIds, nothing else (no fans)", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ admitsEveryRequest = true })
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(300)
		expect(harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 5).isAccepted).toBeTrue()
		harness.grantRoundReward(PLAYER, "round-1", 4, { PINK_HAIR_KEY })
		local expectedSaveData = copySave(harness)
		expectedSaveData.starCoinBalance += 70
		table.insert(expectedSaveData.dailyProgress.claimedDailyQuestIds, "quest_e")

		expect(harness.dailyProgressTracker:answerClaimDailyQuestRewardRequest(PLAYER, "quest_e")).toEqual({
			isAccepted = true,
			starCoinsGranted = 70,
		})
		expectSaveToEqualApartFromKeeperSaveStamps(harness, expectedSaveData)
	end)
end)

describe("A round reward leaves the rest of dailyProgress alone", function()
	it("changes only dailyQuestProgressCountByQuestId in dailyProgress", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ admitsEveryRequest = true })
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(330)
		expect(harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 5).isAccepted).toBeTrue()
		harness.grantRoundReward(PLAYER, "round-1", 2, { PINK_HAIR_KEY })
		expect(harness.dailyProgressTracker:answerClaimDailyQuestRewardRequest(PLAYER, "quest_e").isAccepted).toBeTrue()
		local expectedDailyProgress = copySave(harness).dailyProgress
		expectedDailyProgress.dailyQuestProgressCountByQuestId.quest_a = 2
		expectedDailyProgress.dailyQuestProgressCountByQuestId.quest_d = 1

		harness.grantRoundReward(PLAYER, "round-2", 5, { PINK_HAIR_KEY, BLACK_BOTTOM_KEY })
		expect(harness.readInMemoryDailyProgress(PLAYER)).toEqual(expectedDailyProgress)
	end)

	it("claim, then another qualifying round, then claim again: both refused, nothing more paid", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(300)
		harness.grantRoundReward(PLAYER, "round-1", 2, { PINK_HAIR_KEY })
		expect(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 5).isAccepted).toBeTrue()
		expect(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_e").isAccepted).toBeTrue()
		local roundOutcome = harness.grantRoundReward(PLAYER, "round-2", 2, { PINK_HAIR_KEY })
		local balanceAfterSecondRound = harness.readInMemorySaveData(PLAYER).starCoinBalance
		expect(roundOutcome.rewardLedgerOutcome).toBe("Granted")

		expect(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 5)).toEqual({
			isAccepted = false,
			rejectionReason = "AlreadyClaimed",
		})
		expect(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_e")).toEqual({
			isAccepted = false,
			rejectionReason = "AlreadyClaimed",
		})
		expect(harness.readInMemorySaveData(PLAYER).starCoinBalance).toBe(balanceAfterSecondRound)
	end)

	it("random interleavings of rounds and claims: every claim pays at most once, coins add up", function()
		local todaysDailyQuestIds = DailyQuestTestCatalog.TODAYS_TEST_DAILY_QUEST_IDS
		local scoredKeyChoices = { PINK_HAIR_KEY, BLACK_BOTTOM_KEY, BLUE_TOP_KEY }
		SeededRandomTrials.runSeededRandomTrials(25, function(randomNumberGenerator)
			local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ admitsEveryRequest = true })
			harness.loadPlayer(PLAYER)
			local expectedStarCoinBalance = 0
			local paidClaimKeys = {}
			for actionNumber = 1, 40 do
				harness.advanceSeconds(randomNumberGenerator.nextWholeNumberInRange(0, 120))
				local actionKind = randomNumberGenerator.nextWholeNumberInRange(1, 3)
				if actionKind == 1 then
					local roundOutcome = harness.grantRoundReward(
						PLAYER,
						"round-" .. actionNumber,
						randomNumberGenerator.nextWholeNumberInRange(1, 5),
						{ scoredKeyChoices[randomNumberGenerator.nextWholeNumberInRange(1, #scoredKeyChoices)] }
					)
					expectedStarCoinBalance += roundOutcome.starCoinsGranted
				else
					local claimKey, claimAnswer
					if actionKind == 2 then
						local playtimeMilestone =
							PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES[randomNumberGenerator.nextWholeNumberInRange(
								1,
								#PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES
							)]
						claimKey = "milestone " .. playtimeMilestone.milestoneMinutes
						claimAnswer = harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(
							PLAYER,
							playtimeMilestone.milestoneMinutes
						)
					else
						local dailyQuestId = todaysDailyQuestIds[randomNumberGenerator.nextWholeNumberInRange(1, 3)]
						claimKey = "quest " .. dailyQuestId
						claimAnswer =
							harness.dailyProgressTracker:answerClaimDailyQuestRewardRequest(PLAYER, dailyQuestId)
					end
					if claimAnswer.isAccepted then
						expect(paidClaimKeys[claimKey]).toBe(nil)
						paidClaimKeys[claimKey] = true
						expectedStarCoinBalance += claimAnswer.starCoinsGranted
					elseif paidClaimKeys[claimKey] then
						expect(claimAnswer.rejectionReason).toBe("AlreadyClaimed")
					end
				end
			end
			local saveData = harness.readInMemorySaveData(PLAYER)
			expect(saveData.starCoinBalance).toBe(expectedStarCoinBalance)
			for _, claimedMilestoneMinutes in saveData.dailyProgress.claimedPlaytimeMilestoneMinutes do
				expect(paidClaimKeys["milestone " .. claimedMilestoneMinutes]).toBe(true)
			end
			for _, claimedDailyQuestId in saveData.dailyProgress.claimedDailyQuestIds do
				expect(paidClaimKeys["quest " .. claimedDailyQuestId]).toBe(true)
			end
		end)
	end)
end)
