-- A small daily quest catalog with a known choice of quests, shared by the daily content specs,
-- plus helpers for dailyProgress tables and random dates.
--
-- The pinned choices below were computed by an independent Python implementation of the
-- documented selection (FNV-1a + mulberry32 day ranks, three smallest). The test
-- "the shared test catalog's pinned choices hold" in DailyQuestOfTheDaySelector.spec.luau keeps
-- them honest; every spec that relies on them depends on that test.

local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")

local DailyQuestTestCatalog = {}

DailyQuestTestCatalog.SECONDS_PER_DAY = 86400
-- Day numbers (days since 1970-01-01) from 2020-01-01 to about 2060.
DailyQuestTestCatalog.FIRST_SAMPLED_DAY_NUMBER = 18262
DailyQuestTestCatalog.LAST_SAMPLED_DAY_NUMBER = 32872

DailyQuestTestCatalog.TEST_DAILY_DATE_KEY = "2026-11-19"
DailyQuestTestCatalog.NEXT_TEST_DAILY_DATE_KEY = "2026-11-20"

-- One quest of each kind is picked on TEST_DAILY_DATE_KEY: quest_a (CompleteRounds, target 3),
-- quest_d (EarnStarsAtLeast 4, target 2) and quest_e (pink, target 1).
DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS = table.freeze({
	table.freeze({ dailyQuestId = "quest_a", dailyQuestKind = "CompleteRounds", targetCount = 3, starCoinReward = 60 }),
	table.freeze({ dailyQuestId = "quest_b", dailyQuestKind = "CompleteRounds", targetCount = 1, starCoinReward = 10 }),
	table.freeze({ dailyQuestId = "quest_c", dailyQuestKind = "CompleteRounds", targetCount = 1, starCoinReward = 10 }),
	table.freeze({
		dailyQuestId = "quest_d",
		dailyQuestKind = "EarnStarsAtLeast",
		targetCount = 2,
		minimumStarCount = 4,
		starCoinReward = 120,
	}),
	table.freeze({
		dailyQuestId = "quest_e",
		dailyQuestKind = "UseColorInRatedOutfit",
		targetCount = 1,
		requiredColorTag = "pink",
		starCoinReward = 70,
	}),
	table.freeze({ dailyQuestId = "quest_f", dailyQuestKind = "CompleteRounds", targetCount = 1, starCoinReward = 10 }),
})

-- Pinned choices of SIX_TEST_DAILY_QUESTS, in the selector's order.
DailyQuestTestCatalog.PINNED_TEST_DAILY_QUEST_IDS_BY_DAILY_DATE_KEY = table.freeze({
	["2026-11-19"] = table.freeze({ "quest_a", "quest_d", "quest_e" }),
	["2026-11-20"] = table.freeze({ "quest_f", "quest_e", "quest_a" }),
	["2027-01-01"] = table.freeze({ "quest_f", "quest_a", "quest_b" }),
})
DailyQuestTestCatalog.TODAYS_TEST_DAILY_QUEST_IDS =
	DailyQuestTestCatalog.PINNED_TEST_DAILY_QUEST_IDS_BY_DAILY_DATE_KEY[DailyQuestTestCatalog.TEST_DAILY_DATE_KEY]

-- A fresh dailyProgress for TEST_DAILY_DATE_KEY with the given fields replaced.
function DailyQuestTestCatalog.createTestDailyProgress(dailyProgressOverrides: { [string]: any }?)
	local dailyProgress = PlayerSaveDataSchema.createFreshDailyProgress(DailyQuestTestCatalog.TEST_DAILY_DATE_KEY)
	for fieldName, overrideValue in dailyProgressOverrides or {} do
		dailyProgress[fieldName] = overrideValue
	end
	return dailyProgress
end

-- A random UTC date key between 2020 and about 2060.
function DailyQuestTestCatalog.pickRandomDailyDateKey(trialRandomNumberGenerator): string
	local dayNumber = trialRandomNumberGenerator.nextWholeNumberInRange(
		DailyQuestTestCatalog.FIRST_SAMPLED_DAY_NUMBER,
		DailyQuestTestCatalog.LAST_SAMPLED_DAY_NUMBER
	)
	return PlayerSaveDataSchema.formatUtcDailyDateKey(dayNumber * DailyQuestTestCatalog.SECONDS_PER_DAY)
end

-- Freezes a plain table and every table inside it; returns it.
function DailyQuestTestCatalog.freezeDeeply(plainTable)
	for _, nestedValue in plainTable do
		if type(nestedValue) == "table" then
			DailyQuestTestCatalog.freezeDeeply(nestedValue)
		end
	end
	if not table.isfrozen(plainTable) then
		table.freeze(plainTable)
	end
	return plainTable
end

return table.freeze(DailyQuestTestCatalog)
