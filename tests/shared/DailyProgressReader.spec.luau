-- Reading a dailyProgress table for the daily rules (development spec §1.8, §1.10, §2.9).

local UnitTestFramework = require("../Support/UnitTestFramework")
local DailyProgressReader = require("../../src/shared/DailyProgressReader")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local TEST_DAILY_DATE_KEY = DailyQuestTestCatalog.TEST_DAILY_DATE_KEY
local createDailyProgress = DailyQuestTestCatalog.createTestDailyProgress

local TARGET_3_QUEST =
	table.freeze({ dailyQuestId = "quest_a", dailyQuestKind = "CompleteRounds", targetCount = 3, starCoinReward = 60 })

local function checkDailyProgress(dailyProgress, currentDailyDateKey)
	DailyProgressReader.assertDailyProgressIsCurrentAndWellFormed(dailyProgress, currentDailyDateKey)
end

describe("DailyProgressReader checks", function()
	it("accepts a fresh dailyProgress and a filled one for the current day", function()
		checkDailyProgress(createDailyProgress(), TEST_DAILY_DATE_KEY)
		checkDailyProgress(
			createDailyProgress({
				playtimeSecondsToday = 1234.5,
				claimedPlaytimeMilestoneMinutes = { 5, 10 },
				dailyQuestProgressCountByQuestId = { quest_a = 3, quest_b = 0 },
				claimedDailyQuestIds = { "quest_a" },
			}),
			TEST_DAILY_DATE_KEY
		)
	end)

	it("raises an error for a dailyProgress of another day, naming both days", function()
		expect(function()
			checkDailyProgress(createDailyProgress(), DailyQuestTestCatalog.NEXT_TEST_DAILY_DATE_KEY)
		end).toThrow("dailyProgress is for 2026-11-19, not today 2026-11-20; apply the daily reset first")
	end)

	it("raises an error naming the first malformed field", function()
		local malformedCases = {
			{ "dailyDateKey", { dailyDateKey = "2026/11/19" } },
			{ "playtimeSecondsToday", { playtimeSecondsToday = "60" } },
			{ "playtimeSecondsToday", { playtimeSecondsToday = 0 / 0 } },
			{ "claimedPlaytimeMilestoneMinutes", { claimedPlaytimeMilestoneMinutes = "5" } },
			{ "claimedPlaytimeMilestoneMinutes", { claimedPlaytimeMilestoneMinutes = { 5, "10" } } },
			{ "dailyQuestProgressCountByQuestId", { dailyQuestProgressCountByQuestId = { quest_a = "2" } } },
			{ "dailyQuestProgressCountByQuestId", { dailyQuestProgressCountByQuestId = { quest_a = 0 / 0 } } },
			{ "dailyQuestProgressCountByQuestId", { dailyQuestProgressCountByQuestId = { [1] = 2 } } },
			{ "claimedDailyQuestIds", { claimedDailyQuestIds = { "quest_a", 7 } } },
		}
		for _, malformedCase in malformedCases do
			local malformedFieldName, malformedOverrides = malformedCase[1], malformedCase[2]
			expect(function()
				checkDailyProgress(createDailyProgress(malformedOverrides), TEST_DAILY_DATE_KEY)
			end).toThrow("dailyProgress is malformed at " .. malformedFieldName)
		end
		for _, missingFieldName in
			{
				"dailyDateKey",
				"playtimeSecondsToday",
				"claimedPlaytimeMilestoneMinutes",
				"dailyQuestProgressCountByQuestId",
				"claimedDailyQuestIds",
			}
		do
			local dailyProgressWithMissingField = createDailyProgress()
			dailyProgressWithMissingField[missingFieldName] = nil
			expect(function()
				checkDailyProgress(dailyProgressWithMissingField, TEST_DAILY_DATE_KEY)
			end).toThrow("dailyProgress is malformed at " .. missingFieldName)
		end
		expect(function()
			checkDailyProgress(nil, TEST_DAILY_DATE_KEY)
		end).toThrow("dailyProgress is malformed at dailyProgress")
	end)

	it("raises an error for a current date key that is not YYYY-MM-DD", function()
		for _, malformedDailyDateKey in { "2026/11/19", "", 20261119, nil } do
			expect(function()
				checkDailyProgress(createDailyProgress(), malformedDailyDateKey)
			end).toThrow("currentDailyDateKey must be a YYYY-MM-DD string")
		end
	end)
end)

describe("DailyProgressReader quest and milestone state", function()
	it("a quest with no progress entry has a count of 0; a stored count is read as stored", function()
		local dailyProgress = createDailyProgress({ dailyQuestProgressCountByQuestId = { quest_b = 2 } })
		expect(DailyProgressReader.readDailyQuestProgressCount(dailyProgress, "quest_a")).toBe(0)
		expect(DailyProgressReader.readDailyQuestProgressCount(dailyProgress, "quest_b")).toBe(2)
	end)

	it("a quest has reached its target at or above targetCount, not below", function()
		for storedProgressCount, expectedHasReachedTarget in { [0] = false, [2] = false, [3] = true, [4] = true } do
			local dailyProgress =
				createDailyProgress({ dailyQuestProgressCountByQuestId = { quest_a = storedProgressCount } })
			expect({
				storedProgressCount,
				DailyProgressReader.hasDailyQuestReachedTarget(dailyProgress, TARGET_3_QUEST),
			}).toEqual({
				storedProgressCount,
				expectedHasReachedTarget,
			})
		end
		expect(DailyProgressReader.hasDailyQuestReachedTarget(createDailyProgress(), TARGET_3_QUEST)).toBeFalse()
	end)

	it("finds a claimed quest or milestone at any position of its list", function()
		local dailyProgress = createDailyProgress({
			claimedDailyQuestIds = { "quest_c", "quest_a", "quest_b" },
			claimedPlaytimeMilestoneMinutes = { 20, 5, 60 },
		})
		for _, claimedDailyQuestId in { "quest_c", "quest_a", "quest_b" } do
			expect(DailyProgressReader.isDailyQuestClaimed(dailyProgress, claimedDailyQuestId)).toBeTrue()
		end
		expect(DailyProgressReader.isDailyQuestClaimed(dailyProgress, "quest_d")).toBeFalse()
		for _, claimedMilestoneMinutes in { 20, 5, 60 } do
			expect(DailyProgressReader.isPlaytimeMilestoneClaimed(dailyProgress, claimedMilestoneMinutes)).toBeTrue()
		end
		expect(DailyProgressReader.isPlaytimeMilestoneClaimed(dailyProgress, 10)).toBeFalse()
	end)

	it("is frozen", function()
		expect(table.isfrozen(DailyProgressReader)).toBeTrue()
	end)
end)
