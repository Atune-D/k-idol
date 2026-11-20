-- Daily quest claims and the UTC day boundary (development spec §1.8, §1.10, §3.3, §6.2 "progress
-- resets when dailyDateKey changes"): yesterday's quest claims never carry into today, a quest
-- claim's record always lands in today's table, and a dailyProgress dated in the future is
-- replaced so a round still writes quest progress.
--
-- quest_e (pink, target 1, 70 coins) is a quest on both 2026-11-19 and 2026-11-20.

local DailyProgressTracker = require("../../src/server/DailyProgressTracker")
local DailyProgressTrackerTestHarness = require("./DailyProgressTrackerTestHarness")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = DailyProgressTrackerTestHarness.PLAYER
local PINK_HAIR_KEY = DailyProgressTrackerTestHarness.PINK_HAIR_KEY
local NEXT_DAILY_DATE_KEY = "2026-11-20"

local function completeAndClaimQuestEOnTheTestDay(harness)
	harness.grantRoundReward(PLAYER, "round-day-1", 2, { PINK_HAIR_KEY })
	expect(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_e").isAccepted).toBeTrue()
	expect(harness.readInMemoryDailyProgress(PLAYER).claimedDailyQuestIds).toEqual({ "quest_e" })
end

describe("Quest claims do not carry over UTC midnight", function()
	local midnightCrossings = {
		{
			crossingName = "through the scheduler (the midnight recording rolls the day)",
			crossMidnight = function(harness)
				harness.advanceToTimeOfDay(1, 120)
				expect(harness.readInMemoryDailyProgress(PLAYER).dailyDateKey).toBe(NEXT_DAILY_DATE_KEY)
			end,
		},
		{
			crossingName = "clock only (the next round reward rolls the day)",
			crossMidnight = function(harness)
				harness.fakeClock:advanceBySeconds(720)
				expect(harness.readInMemoryDailyProgress(PLAYER).dailyDateKey).toBe("2026-11-19")
			end,
		},
	}
	for _, midnightCrossing in midnightCrossings do
		it(
			"a quest claimed yesterday can be completed and claimed again today, " .. midnightCrossing.crossingName,
			function()
				local harness =
					DailyProgressTrackerTestHarness.createTrackerHarness({ secondsAfterMidnight = 86400 - 600 })
				harness.loadPlayer(PLAYER)
				completeAndClaimQuestEOnTheTestDay(harness)
				midnightCrossing.crossMidnight(harness)
				harness.grantRoundReward(PLAYER, "round-day-2", 2, { PINK_HAIR_KEY })
				local balanceBeforeSecondClaim = harness.readInMemorySaveData(PLAYER).starCoinBalance

				expect(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_e")).toEqual({
					isAccepted = true,
					starCoinsGranted = 70,
				})
				local dailyProgress = harness.readInMemoryDailyProgress(PLAYER)
				expect(dailyProgress.dailyDateKey).toBe(NEXT_DAILY_DATE_KEY)
				expect(dailyProgress.claimedDailyQuestIds).toEqual({ "quest_e" })
				expect(harness.readInMemorySaveData(PLAYER).starCoinBalance).toBe(balanceBeforeSecondClaim + 70)
			end
		)
	end
end)

describe("A quest claim's record lands in today's table", function()
	it("even for a quest whose target is 0, claimed after midnight before any recording ran: paid once", function()
		local catalogWithZeroTarget = table.clone(DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS)
		local questEWithZeroTarget = table.clone(catalogWithZeroTarget[5])
		expect(questEWithZeroTarget.dailyQuestId).toBe("quest_e")
		questEWithZeroTarget.targetCount = 0
		catalogWithZeroTarget[5] = questEWithZeroTarget
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({
			secondsAfterMidnight = 86400 - 100,
			admitsEveryRequest = true,
			dailyQuestCatalogEntries = catalogWithZeroTarget,
		})
		harness.loadPlayer(PLAYER)
		-- 23:58:20 -> 00:01:40 without running scheduled work: the save still holds 2026-11-19.
		harness.fakeClock:advanceBySeconds(200)
		expect(harness.dailyProgressTracker:answerClaimDailyQuestRewardRequest(PLAYER, "quest_e").isAccepted).toBeTrue()
		local dailyProgress = harness.readInMemoryDailyProgress(PLAYER)
		expect(dailyProgress.dailyDateKey).toBe(NEXT_DAILY_DATE_KEY)
		expect(dailyProgress.claimedDailyQuestIds).toEqual({ "quest_e" })

		harness.advanceSeconds(0) -- the overdue midnight recording runs now
		expect(harness.dailyProgressTracker:answerClaimDailyQuestRewardRequest(PLAYER, "quest_e")).toEqual({
			isAccepted = false,
			rejectionReason = "AlreadyClaimed",
		})
		expect(harness.readInMemorySaveData(PLAYER).starCoinBalance).toBe(70)
	end)
end)

describe("A dailyProgress dated in the future (the server clock moved back)", function()
	it("is replaced inside the round change, so the round still writes today's quest progress", function()
		local roundRecordWriter = DailyProgressTracker.createDailyQuestProgressRoundRecordWriter({
			clock = {
				getCurrentUnixSeconds = function()
					return DailyProgressTrackerTestHarness.TEST_DAY_START_UNIX_SECONDS + 3600
				end,
			},
			stylingItemByStylingItemKey = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
			dailyQuestCatalogEntries = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS,
			logger = DailyProgressTrackerTestHarness.createRecordingLogger(),
		})
		local saveDataDraft = PlayerSaveDataSchema.createStartingPlayerSaveData({ "starter_wave" }, 0)
		saveDataDraft.dailyProgress = PlayerSaveDataSchema.createFreshDailyProgress(NEXT_DAILY_DATE_KEY)
		saveDataDraft.dailyProgress.playtimeSecondsToday = 900
		saveDataDraft.dailyProgress.claimedDailyQuestIds = { "quest_e" }
		roundRecordWriter(saveDataDraft, {
			roundId = "round-1",
			themeId = "y2k_pop",
			starCount = 2,
			scoredOutfitStylingItemKeys = { PINK_HAIR_KEY },
		})
		expect(saveDataDraft.dailyProgress.dailyDateKey).toBe("2026-11-19")
		expect(saveDataDraft.dailyProgress.playtimeSecondsToday).toBe(0)
		expect(saveDataDraft.dailyProgress.claimedDailyQuestIds).toEqual({})
		expect(saveDataDraft.dailyProgress.dailyQuestProgressCountByQuestId).toEqual({ quest_a = 1, quest_e = 1 })
	end)
end)
