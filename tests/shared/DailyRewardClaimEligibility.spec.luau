-- Claim decisions for playtime milestones and daily quest rewards (development spec §2.9, §6.2
-- "milestones cannot be claimed early or twice"). Every randomized failure names its seed; rerun
-- with IDOLGROW_RANDOM_TEST_SEED=<seed> to repeat it.

local UnitTestFramework = require("../Support/UnitTestFramework")
local DailyRewardClaimEligibility = require("../../src/shared/DailyRewardClaimEligibility")
local DailyQuestCatalog = require("../../src/shared/DailyQuestCatalog")
local DailyQuestOfTheDaySelector = require("../../src/shared/DailyQuestOfTheDaySelector")
local PlaytimeMilestoneCatalog = require("../../src/shared/PlaytimeMilestoneCatalog")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local TEST_DAILY_DATE_KEY = DailyQuestTestCatalog.TEST_DAILY_DATE_KEY
local SIX_TEST_DAILY_QUESTS = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS
local TODAYS_TEST_DAILY_QUEST_IDS = DailyQuestTestCatalog.TODAYS_TEST_DAILY_QUEST_IDS -- quest_a, quest_d, quest_e
local createDailyProgress = DailyQuestTestCatalog.createTestDailyProgress
local freezeDeeply = DailyQuestTestCatalog.freezeDeeply

local function findTestDailyQuest(dailyQuestId: string)
	for _, dailyQuest in SIX_TEST_DAILY_QUESTS do
		if dailyQuest.dailyQuestId == dailyQuestId then
			return dailyQuest
		end
	end
	error("no test quest " .. dailyQuestId)
end

local function decideMilestoneClaim(dailyProgress, requestedMilestoneMinutes: any)
	return DailyRewardClaimEligibility.decidePlaytimeMilestoneClaim(
		dailyProgress,
		dailyProgress.dailyDateKey,
		requestedMilestoneMinutes
	)
end

local function decideTestQuestClaim(dailyProgress, requestedDailyQuestId: any)
	return DailyRewardClaimEligibility.decideDailyQuestRewardClaim(
		dailyProgress,
		dailyProgress.dailyDateKey,
		requestedDailyQuestId,
		SIX_TEST_DAILY_QUESTS
	)
end

local function expectRefused(claimDecision, expectedRejectionReason: string)
	expect(claimDecision).toEqual({ isClaimAllowed = false, rejectionReason = expectedRejectionReason })
end

local function expectAllowed(claimDecision, expectedStarCoinReward: number)
	expect(claimDecision).toEqual({ isClaimAllowed = true, starCoinReward = expectedStarCoinReward })
end

describe("DailyRewardClaimEligibility playtime milestones", function()
	it("refuses every milestone with MilestoneNotReached at the start of the day", function()
		local freshDailyProgress = createDailyProgress()
		for _, playtimeMilestone in PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES do
			expectRefused(
				decideMilestoneClaim(freshDailyProgress, playtimeMilestone.milestoneMinutes),
				"MilestoneNotReached"
			)
		end
	end)

	it("allows each milestone at exactly its minutes and not one second earlier", function()
		for _, playtimeMilestone in PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES do
			local requiredPlaytimeSeconds = playtimeMilestone.milestoneMinutes * 60
			expectRefused(
				decideMilestoneClaim(
					createDailyProgress({ playtimeSecondsToday = requiredPlaytimeSeconds - 1 }),
					playtimeMilestone.milestoneMinutes
				),
				"MilestoneNotReached"
			)
			expectRefused(
				decideMilestoneClaim(
					createDailyProgress({ playtimeSecondsToday = requiredPlaytimeSeconds - 0.001 }),
					playtimeMilestone.milestoneMinutes
				),
				"MilestoneNotReached"
			)
			expectAllowed(
				decideMilestoneClaim(
					createDailyProgress({ playtimeSecondsToday = requiredPlaytimeSeconds }),
					playtimeMilestone.milestoneMinutes
				),
				playtimeMilestone.starCoinReward
			)
		end
	end)

	it("refuses a milestone already claimed today with AlreadyClaimed", function()
		local dailyProgress = createDailyProgress({ playtimeSecondsToday = 3600 })
		expectAllowed(decideMilestoneClaim(dailyProgress, 10), 30)
		table.insert(dailyProgress.claimedPlaytimeMilestoneMinutes, 10) -- what the ledger records
		expectRefused(decideMilestoneClaim(dailyProgress, 10), "AlreadyClaimed")
		expectAllowed(decideMilestoneClaim(dailyProgress, 5), 20)
	end)

	it("refuses anything that is not a defined milestone with UnknownMilestone, however long the play", function()
		local dailyProgress = createDailyProgress({ playtimeSecondsToday = 100000 })
		for _, unknownMilestoneMinutes in { 0, 1, 15, 5.5, 120, -5, 0 / 0, math.huge, "5", nil, {}, true } do
			expectRefused(decideMilestoneClaim(dailyProgress, unknownMilestoneMinutes), "UnknownMilestone")
		end
	end)

	it("checks in the spec order: unknown, then not reached, then already claimed", function()
		local inconsistentDailyProgress =
			createDailyProgress({ playtimeSecondsToday = 0, claimedPlaytimeMilestoneMinutes = { 5, 7 } })
		expectRefused(decideMilestoneClaim(inconsistentDailyProgress, 7), "UnknownMilestone")
		expectRefused(decideMilestoneClaim(inconsistentDailyProgress, 5), "MilestoneNotReached")
	end)

	it("changes nothing: deciding on a deeply frozen dailyProgress works and leaves it equal", function()
		local dailyProgress =
			freezeDeeply(createDailyProgress({ playtimeSecondsToday = 1900, claimedPlaytimeMilestoneMinutes = { 5 } }))
		local dailyProgressBefore = PlayerSaveDataSchema.createDeepCopyOfPlainTable(dailyProgress)
		for _, playtimeMilestone in PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES do
			decideMilestoneClaim(dailyProgress, playtimeMilestone.milestoneMinutes)
		end
		expect(dailyProgress).toEqual(dailyProgressBefore)
	end)

	it("over random days, a milestone is never claimed early or twice, and a day pays at most 430", function()
		SeededRandomTrials.runSeededRandomTrials(200, function(trialRandomNumberGenerator)
			local dailyProgress = createDailyProgress()
			local claimedStarCoinTotal = 0
			for _ = 1, 60 do
				dailyProgress.playtimeSecondsToday += trialRandomNumberGenerator.nextWholeNumberInRange(0, 120)
				local requestedMilestoneMinutes = if trialRandomNumberGenerator.nextWholeNumberInRange(1, 4) == 1
					then trialRandomNumberGenerator.nextWholeNumberInRange(0, 70)
					else trialRandomNumberGenerator.pickRandomListElement(
						PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES
					).milestoneMinutes
				local claimDecision = decideMilestoneClaim(dailyProgress, requestedMilestoneMinutes)
				local requestedPlaytimeMilestone =
					PlaytimeMilestoneCatalog.findPlaytimeMilestoneByMilestoneMinutes(requestedMilestoneMinutes)
				local expectedRejectionReason = if requestedPlaytimeMilestone == nil
					then "UnknownMilestone"
					elseif
						dailyProgress.playtimeSecondsToday < requestedMilestoneMinutes * 60
					then "MilestoneNotReached"
					elseif
						table.find(dailyProgress.claimedPlaytimeMilestoneMinutes, requestedMilestoneMinutes)
					then "AlreadyClaimed"
					else nil
				expect({ requestedMilestoneMinutes, dailyProgress.playtimeSecondsToday, claimDecision.rejectionReason }).toEqual({
					requestedMilestoneMinutes,
					dailyProgress.playtimeSecondsToday,
					expectedRejectionReason,
				})
				if claimDecision.isClaimAllowed then
					table.insert(dailyProgress.claimedPlaytimeMilestoneMinutes, requestedMilestoneMinutes)
					claimedStarCoinTotal += claimDecision.starCoinReward :: number
				end
			end
			expect(claimedStarCoinTotal <= 430).toBeTrue()
			local seenClaimedMinutesSet = {}
			for _, claimedMilestoneMinutes in dailyProgress.claimedPlaytimeMilestoneMinutes do
				expect(seenClaimedMinutesSet[claimedMilestoneMinutes]).toBeNil()
				seenClaimedMinutesSet[claimedMilestoneMinutes] = true
			end
		end)
	end)
end)

describe("DailyRewardClaimEligibility daily quests", function()
	it("refuses a quest that is not one of today's with NotTodaysQuest, even when complete", function()
		local dailyProgress = createDailyProgress({
			dailyQuestProgressCountByQuestId = { quest_b = 1, quest_c = 1, quest_f = 1 },
		})
		for _, notTodaysDailyQuestId in { "quest_b", "quest_c", "quest_f", "no_such_quest", "QUEST_A", 1, nil, {} } do
			expectRefused(decideTestQuestClaim(dailyProgress, notTodaysDailyQuestId), "NotTodaysQuest")
		end
	end)

	it("refuses one of today's quests below its target with QuestNotCompleted", function()
		expectRefused(decideTestQuestClaim(createDailyProgress(), "quest_a"), "QuestNotCompleted")
		expectRefused(
			decideTestQuestClaim(createDailyProgress({ dailyQuestProgressCountByQuestId = { quest_a = 2 } }), "quest_a"),
			"QuestNotCompleted"
		)
	end)

	it("a quest with no progress entry has made no progress, even one with targetCount 1", function()
		local freshDailyProgress = createDailyProgress()
		expect(findTestDailyQuest("quest_e").targetCount).toBe(1)
		for _, todaysDailyQuestId in TODAYS_TEST_DAILY_QUEST_IDS do
			expectRefused(decideTestQuestClaim(freshDailyProgress, todaysDailyQuestId), "QuestNotCompleted")
		end
	end)

	it("allows one of today's quests at exactly its target, paying its reward", function()
		local dailyProgress =
			createDailyProgress({ dailyQuestProgressCountByQuestId = { quest_a = 3, quest_d = 2, quest_e = 1 } })
		expectAllowed(decideTestQuestClaim(dailyProgress, "quest_a"), 60)
		expectAllowed(decideTestQuestClaim(dailyProgress, "quest_d"), 120)
		expectAllowed(decideTestQuestClaim(dailyProgress, "quest_e"), 70)
	end)

	it("allows a quest whose stored progress is above its target (a release lowered the target)", function()
		local dailyProgress =
			createDailyProgress({ dailyQuestProgressCountByQuestId = { quest_a = 4, quest_d = 7, quest_e = 2 } })
		expectAllowed(decideTestQuestClaim(dailyProgress, "quest_a"), 60)
		expectAllowed(decideTestQuestClaim(dailyProgress, "quest_d"), 120)
		expectAllowed(decideTestQuestClaim(dailyProgress, "quest_e"), 70)
	end)

	it("refuses a quest already claimed today with AlreadyClaimed, wherever it is in the claimed list", function()
		local dailyProgress =
			createDailyProgress({ dailyQuestProgressCountByQuestId = { quest_a = 3, quest_d = 2, quest_e = 1 } })
		local claimOrder = { "quest_d", "quest_a", "quest_e" }
		for claimPosition, claimedDailyQuestId in claimOrder do
			expectAllowed(
				decideTestQuestClaim(dailyProgress, claimedDailyQuestId),
				findTestDailyQuest(claimedDailyQuestId).starCoinReward
			)
			table.insert(dailyProgress.claimedDailyQuestIds, claimedDailyQuestId) -- what the ledger records
			for earlierClaimPosition = 1, claimPosition do
				expectRefused(decideTestQuestClaim(dailyProgress, claimOrder[earlierClaimPosition]), "AlreadyClaimed")
			end
		end
	end)

	it("checks in the spec order: not today's, then not completed, then already claimed", function()
		local inconsistentDailyProgress = createDailyProgress({ claimedDailyQuestIds = { "quest_a", "quest_b" } })
		expectRefused(decideTestQuestClaim(inconsistentDailyProgress, "quest_b"), "NotTodaysQuest")
		expectRefused(decideTestQuestClaim(inconsistentDailyProgress, "quest_a"), "QuestNotCompleted")
	end)

	it("changes nothing: deciding on a deeply frozen dailyProgress works and leaves it equal", function()
		local dailyProgress = freezeDeeply(createDailyProgress({
			dailyQuestProgressCountByQuestId = { quest_a = 3, quest_e = 1 },
			claimedDailyQuestIds = { "quest_e" },
		}))
		local dailyProgressBefore = PlayerSaveDataSchema.createDeepCopyOfPlainTable(dailyProgress)
		for _, requestedDailyQuestId in { "quest_a", "quest_b", "quest_d", "quest_e" } do
			decideTestQuestClaim(dailyProgress, requestedDailyQuestId)
		end
		expect(dailyProgress).toEqual(dailyProgressBefore)
	end)

	it("treats the same three quests as today's for every player on a date, for random dates", function()
		SeededRandomTrials.runSeededRandomTrials(100, function(trialRandomNumberGenerator)
			local dailyDateKey = DailyQuestTestCatalog.pickRandomDailyDateKey(trialRandomNumberGenerator)
			local todaysDailyQuestIds = DailyQuestOfTheDaySelector.selectDailyQuestIdsForDailyDateKey(dailyDateKey)
			for _ = 1, 5 do -- five players with different playtime and no quest progress yet
				local playerDailyProgress = PlayerSaveDataSchema.createFreshDailyProgress(dailyDateKey)
				playerDailyProgress.playtimeSecondsToday = trialRandomNumberGenerator.nextWholeNumberInRange(0, 5000)
				for _, dailyQuest in DailyQuestCatalog.DAILY_QUESTS do
					local claimDecision = DailyRewardClaimEligibility.decideDailyQuestRewardClaim(
						playerDailyProgress,
						dailyDateKey,
						dailyQuest.dailyQuestId
					)
					local expectedRejectionReason = if table.find(todaysDailyQuestIds, dailyQuest.dailyQuestId)
						then "QuestNotCompleted"
						else "NotTodaysQuest"
					expect({ dailyDateKey, dailyQuest.dailyQuestId, claimDecision }).toEqual({
						dailyDateKey,
						dailyQuest.dailyQuestId,
						{ isClaimAllowed = false, rejectionReason = expectedRejectionReason },
					})
				end
			end
		end)
	end)

	it("over random claim sequences, each quest pays once at most and only when completed", function()
		SeededRandomTrials.runSeededRandomTrials(200, function(trialRandomNumberGenerator)
			local dailyDateKey = DailyQuestTestCatalog.pickRandomDailyDateKey(trialRandomNumberGenerator)
			local todaysDailyQuests = DailyQuestOfTheDaySelector.selectDailyQuestsForDailyDateKey(dailyDateKey)
			local dailyProgress = PlayerSaveDataSchema.createFreshDailyProgress(dailyDateKey)
			local paidStarCoinTotal = 0
			for _ = 1, 30 do
				-- Progress moves on (sometimes past the target), then a claim for a random quest arrives.
				local advancedDailyQuest = trialRandomNumberGenerator.pickRandomListElement(todaysDailyQuests)
				dailyProgress.dailyQuestProgressCountByQuestId[advancedDailyQuest.dailyQuestId] = (
					dailyProgress.dailyQuestProgressCountByQuestId[advancedDailyQuest.dailyQuestId] or 0
				) + trialRandomNumberGenerator.nextWholeNumberInRange(0, 2)
				local requestedDailyQuest =
					trialRandomNumberGenerator.pickRandomListElement(DailyQuestCatalog.DAILY_QUESTS)
				local requestedDailyQuestId = requestedDailyQuest.dailyQuestId

				-- Independent statement of §2.9, written without the module's code.
				local isTodaysQuest = false
				for _, todaysDailyQuest in todaysDailyQuests do
					isTodaysQuest = isTodaysQuest or todaysDailyQuest.dailyQuestId == requestedDailyQuestId
				end
				local storedProgressCount = dailyProgress.dailyQuestProgressCountByQuestId[requestedDailyQuestId]
				local isClaimedAlready = false
				for _, claimedDailyQuestId in dailyProgress.claimedDailyQuestIds do
					isClaimedAlready = isClaimedAlready or claimedDailyQuestId == requestedDailyQuestId
				end
				local expectedDecision = if not isTodaysQuest
					then { isClaimAllowed = false, rejectionReason = "NotTodaysQuest" }
					elseif storedProgressCount == nil or storedProgressCount < requestedDailyQuest.targetCount then {
						isClaimAllowed = false,
						rejectionReason = "QuestNotCompleted",
					}
					elseif isClaimedAlready then { isClaimAllowed = false, rejectionReason = "AlreadyClaimed" }
					else { isClaimAllowed = true, starCoinReward = requestedDailyQuest.starCoinReward }

				local claimDecision = DailyRewardClaimEligibility.decideDailyQuestRewardClaim(
					dailyProgress,
					dailyDateKey,
					requestedDailyQuestId
				)
				expect({ dailyDateKey, requestedDailyQuestId, storedProgressCount, claimDecision }).toEqual({
					dailyDateKey,
					requestedDailyQuestId,
					storedProgressCount,
					expectedDecision,
				})
				if claimDecision.isClaimAllowed then
					table.insert(dailyProgress.claimedDailyQuestIds, requestedDailyQuestId)
					paidStarCoinTotal += claimDecision.starCoinReward :: number
				end
			end
			local largestPossibleTotal = 0
			for _, todaysDailyQuest in todaysDailyQuests do
				largestPossibleTotal += todaysDailyQuest.starCoinReward
			end
			expect({ dailyDateKey, paidStarCoinTotal <= largestPossibleTotal }).toEqual({ dailyDateKey, true })
		end)
	end)
end)

describe("DailyRewardClaimEligibility decisions and constants", function()
	it("names exactly the five rejection reasons of spec §2.9", function()
		expect(DailyRewardClaimEligibility.DAILY_REWARD_CLAIM_REJECTION_REASONS).toEqual({
			UnknownMilestone = "UnknownMilestone",
			MilestoneNotReached = "MilestoneNotReached",
			NotTodaysQuest = "NotTodaysQuest",
			QuestNotCompleted = "QuestNotCompleted",
			AlreadyClaimed = "AlreadyClaimed",
		})
	end)

	it("returns frozen decisions and is itself frozen", function()
		expect(table.isfrozen(DailyRewardClaimEligibility)).toBeTrue()
		expect(table.isfrozen(DailyRewardClaimEligibility.DAILY_REWARD_CLAIM_REJECTION_REASONS)).toBeTrue()
		local dailyProgress = createDailyProgress({
			playtimeSecondsToday = 600,
			dailyQuestProgressCountByQuestId = { quest_a = 3 },
		})
		expect(table.isfrozen(decideMilestoneClaim(dailyProgress, 5))).toBeTrue()
		expect(table.isfrozen(decideMilestoneClaim(dailyProgress, 60))).toBeTrue()
		expect(table.isfrozen(decideTestQuestClaim(dailyProgress, "quest_a"))).toBeTrue()
		expect(table.isfrozen(decideTestQuestClaim(dailyProgress, "quest_b"))).toBeTrue()
	end)
end)

describe("DailyRewardClaimEligibility stale or malformed dailyProgress", function()
	it("raises an error when dailyProgress is not today's (the daily reset was not applied)", function()
		local yesterdaysDailyProgress = createDailyProgress({
			playtimeSecondsToday = 3600,
			dailyQuestProgressCountByQuestId = { quest_a = 3 },
		})
		local nextDailyDateKey = DailyQuestTestCatalog.NEXT_TEST_DAILY_DATE_KEY
		expect(function()
			DailyRewardClaimEligibility.decidePlaytimeMilestoneClaim(yesterdaysDailyProgress, nextDailyDateKey, 60)
		end).toThrow("apply the daily reset first")
		expect(function()
			DailyRewardClaimEligibility.decideDailyQuestRewardClaim(
				yesterdaysDailyProgress,
				nextDailyDateKey,
				"quest_a",
				SIX_TEST_DAILY_QUESTS
			)
		end).toThrow("apply the daily reset first")
	end)

	it("raises an error naming the field for a malformed dailyProgress or current date key", function()
		local malformedOverridesByFieldName = {
			dailyDateKey = { dailyDateKey = 20261119 },
			playtimeSecondsToday = { playtimeSecondsToday = 0 / 0 },
			claimedPlaytimeMilestoneMinutes = { claimedPlaytimeMilestoneMinutes = { "5" } },
			dailyQuestProgressCountByQuestId = { dailyQuestProgressCountByQuestId = { quest_a = "3" } },
			claimedDailyQuestIds = { claimedDailyQuestIds = false },
		}
		for malformedFieldName, malformedOverrides in malformedOverridesByFieldName do
			local malformedDailyProgress = createDailyProgress(malformedOverrides)
			expect(function()
				DailyRewardClaimEligibility.decidePlaytimeMilestoneClaim(malformedDailyProgress, TEST_DAILY_DATE_KEY, 5)
			end).toThrow("malformed at " .. malformedFieldName)
			expect(function()
				DailyRewardClaimEligibility.decideDailyQuestRewardClaim(
					malformedDailyProgress,
					TEST_DAILY_DATE_KEY,
					"quest_a"
				)
			end).toThrow("malformed at " .. malformedFieldName)
		end
		expect(function()
			DailyRewardClaimEligibility.decidePlaytimeMilestoneClaim(createDailyProgress(), "2026/11/19", 5)
		end).toThrow("currentDailyDateKey must be a YYYY-MM-DD string")
	end)
end)

describe("DailyRewardClaimEligibility after the day boundary", function()
	it("a new day's fresh dailyProgress makes yesterday's claims and progress count for nothing", function()
		local lastSecondOfDay = 1795132799 -- 2026-11-19 23:59:59 UTC
		local saveData = PlayerSaveDataSchema.createStartingPlayerSaveData({ "starter_groove" }, lastSecondOfDay)
		expect(saveData.dailyProgress.dailyDateKey).toBe(TEST_DAILY_DATE_KEY)
		saveData.dailyProgress.playtimeSecondsToday = 3600
		saveData.dailyProgress.claimedPlaytimeMilestoneMinutes = { 5, 10 }
		saveData.dailyProgress.dailyQuestProgressCountByQuestId = { quest_a = 3, quest_d = 2 }
		expectRefused(decideMilestoneClaim(saveData.dailyProgress, 5), "AlreadyClaimed")
		expectAllowed(decideTestQuestClaim(saveData.dailyProgress, "quest_a"), 60)

		expect(PlayerSaveDataSchema.replaceDailyProgressIfDailyDateKeyChanged(saveData, lastSecondOfDay + 1)).toBeTrue()
		expect(saveData.dailyProgress.dailyDateKey).toBe(DailyQuestTestCatalog.NEXT_TEST_DAILY_DATE_KEY)
		expectRefused(decideMilestoneClaim(saveData.dailyProgress, 5), "MilestoneNotReached")
		saveData.dailyProgress.playtimeSecondsToday = 300
		expectAllowed(decideMilestoneClaim(saveData.dailyProgress, 5), 20)
		-- quest_a is still one of the 2026-11-20 test quests (quest_f, quest_e, quest_a) but starts again at 0.
		expectRefused(decideTestQuestClaim(saveData.dailyProgress, "quest_a"), "QuestNotCompleted")
		expectRefused(decideTestQuestClaim(saveData.dailyProgress, "quest_d"), "NotTodaysQuest")
	end)
end)
