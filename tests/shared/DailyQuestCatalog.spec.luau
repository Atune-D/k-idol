-- Daily quest catalog rules (development spec §1.8), checked for every entry.

local UnitTestFramework = require("../Support/UnitTestFramework")
local DailyQuestCatalog = require("../../src/shared/DailyQuestCatalog")
local OutfitScoreCalculator = require("../../src/shared/OutfitScoreCalculator")
local StylingTagVocabulary = require("../../src/shared/StylingTagVocabulary")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function describeDailyQuest(dailyQuest): string
	return "daily quest " .. tostring(dailyQuest.dailyQuestId)
end

local function isPositiveWholeNumber(candidateNumber: any): boolean
	return type(candidateNumber) == "number" and candidateNumber >= 1 and candidateNumber % 1 == 0
end

-- Lowercase words of letters and digits, joined by single underscores ("complete_rounds_5").
local function isSnakeCaseIdentifier(candidateText: any): boolean
	if type(candidateText) ~= "string" or string.match(candidateText, "^[a-z]") == nil then
		return false
	end
	for _, identifierWord in string.split(candidateText, "_") do
		if string.match(identifierWord, "^[a-z0-9]+$") == nil then
			return false
		end
	end
	return true
end

local function isStarCountAwardedByScoring(candidateStarCount: any): boolean
	for _, starRewardTier in OutfitScoreCalculator.STAR_REWARD_TIERS do
		if starRewardTier.starCount == candidateStarCount then
			return true
		end
	end
	return false
end

-- Expects `isRuleMet` and names the quest in the failure.
local function expectRuleMetForDailyQuest(dailyQuest, ruleDescription: string, isRuleMet: boolean)
	local failureLabel = describeDailyQuest(dailyQuest) .. ": " .. ruleDescription
	expect({ failureLabel, isRuleMet }).toEqual({ failureLabel, true })
end

describe("DailyQuestCatalog", function()
	it("contains complete_rounds_5 exactly as in the spec §1.8 example", function()
		expect(DailyQuestCatalog.findDailyQuestByDailyQuestId("complete_rounds_5")).toEqual({
			dailyQuestId = "complete_rounds_5",
			dailyQuestKind = "CompleteRounds",
			targetCount = 5,
			starCoinReward = 100,
		})
	end)

	it("holds at least three quests, so three distinct ones can be chosen each day", function()
		expect(DailyQuestCatalog.DAILY_QUEST_COUNT_PER_DAY).toBe(3)
		expect(#DailyQuestCatalog.DAILY_QUESTS >= DailyQuestCatalog.DAILY_QUEST_COUNT_PER_DAY).toBeTrue()
	end)

	it("offers every quest kind at least once", function()
		local seenDailyQuestKindSet = {}
		for _, dailyQuest in DailyQuestCatalog.DAILY_QUESTS do
			seenDailyQuestKindSet[dailyQuest.dailyQuestKind] = true
		end
		for dailyQuestKind in DailyQuestCatalog.DAILY_QUEST_KINDS do
			expect({ dailyQuestKind, seenDailyQuestKindSet[dailyQuestKind] }).toEqual({ dailyQuestKind, true })
		end
	end)

	it("every quest id is unique snake_case", function()
		local seenDailyQuestIdSet = {}
		for _, dailyQuest in DailyQuestCatalog.DAILY_QUESTS do
			expectRuleMetForDailyQuest(dailyQuest, "snake_case id", isSnakeCaseIdentifier(dailyQuest.dailyQuestId))
			expectRuleMetForDailyQuest(dailyQuest, "unique id", seenDailyQuestIdSet[dailyQuest.dailyQuestId] == nil)
			seenDailyQuestIdSet[dailyQuest.dailyQuestId] = true
		end
	end)

	it("every quest has a known kind and positive whole target and reward", function()
		for _, dailyQuest in DailyQuestCatalog.DAILY_QUESTS do
			expectRuleMetForDailyQuest(
				dailyQuest,
				"known kind",
				DailyQuestCatalog.DAILY_QUEST_KINDS[dailyQuest.dailyQuestKind] == dailyQuest.dailyQuestKind
			)
			expectRuleMetForDailyQuest(dailyQuest, "targetCount", isPositiveWholeNumber(dailyQuest.targetCount))
			expectRuleMetForDailyQuest(dailyQuest, "starCoinReward", isPositiveWholeNumber(dailyQuest.starCoinReward))
		end
	end)

	it("the snake_case rule refuses doubled, leading and trailing underscores and capitals", function()
		for _, wellFormedIdentifier in { "complete_rounds_5", "quest", "earn_at_least_3_stars_in_2_rounds" } do
			expect({ wellFormedIdentifier, isSnakeCaseIdentifier(wellFormedIdentifier) }).toEqual({
				wellFormedIdentifier,
				true,
			})
		end
		for _, malformedIdentifier in
			{ "complete__rounds_3", "complete_rounds_3_", "_quest", "Quest_a", "5_rounds", "" }
		do
			expect({ malformedIdentifier, isSnakeCaseIdentifier(malformedIdentifier) }).toEqual({
				malformedIdentifier,
				false,
			})
		end
	end)

	it("EarnStarsAtLeast ids name the per-round minimum and the round count", function()
		for _, dailyQuest in DailyQuestCatalog.DAILY_QUESTS do
			if dailyQuest.dailyQuestKind == "EarnStarsAtLeast" then
				local expectedDailyQuestId = string.format(
					"earn_at_least_%d_stars_in_%d_%s",
					dailyQuest.minimumStarCount :: number,
					dailyQuest.targetCount,
					if dailyQuest.targetCount == 1 then "round" else "rounds"
				)
				expectRuleMetForDailyQuest(
					dailyQuest,
					"id " .. expectedDailyQuestId,
					dailyQuest.dailyQuestId == expectedDailyQuestId
				)
			end
		end
	end)

	it("minimumStarCount is a star count scoring can award, exactly on EarnStarsAtLeast quests", function()
		for _, dailyQuest in DailyQuestCatalog.DAILY_QUESTS do
			if dailyQuest.dailyQuestKind == "EarnStarsAtLeast" then
				expectRuleMetForDailyQuest(
					dailyQuest,
					"minimumStarCount awarded by OutfitScoreCalculator.STAR_REWARD_TIERS",
					isStarCountAwardedByScoring(dailyQuest.minimumStarCount)
				)
			else
				expectRuleMetForDailyQuest(dailyQuest, "no minimumStarCount", dailyQuest.minimumStarCount == nil)
			end
		end
	end)

	it("requiredColorTag is a vocabulary colour tag exactly on UseColorInRatedOutfit quests", function()
		for _, dailyQuest in DailyQuestCatalog.DAILY_QUESTS do
			if dailyQuest.dailyQuestKind == "UseColorInRatedOutfit" then
				expectRuleMetForDailyQuest(
					dailyQuest,
					"vocabulary colour tag",
					StylingTagVocabulary.isKnownColorTag(dailyQuest.requiredColorTag)
				)
			else
				expectRuleMetForDailyQuest(dailyQuest, "no requiredColorTag", dailyQuest.requiredColorTag == nil)
			end
		end
	end)

	it("every quest holds only the fields of spec §1.8", function()
		local allowedFieldSet = {
			dailyQuestId = true,
			dailyQuestKind = true,
			targetCount = true,
			minimumStarCount = true,
			requiredColorTag = true,
			starCoinReward = true,
		}
		for _, dailyQuest in DailyQuestCatalog.DAILY_QUESTS do
			for fieldName in dailyQuest do
				expectRuleMetForDailyQuest(
					dailyQuest,
					"field " .. tostring(fieldName),
					allowedFieldSet[fieldName] == true
				)
			end
		end
	end)

	it("is frozen, quest by quest", function()
		expect(table.isfrozen(DailyQuestCatalog)).toBeTrue()
		expect(table.isfrozen(DailyQuestCatalog.DAILY_QUESTS)).toBeTrue()
		expect(table.isfrozen(DailyQuestCatalog.DAILY_QUEST_KINDS)).toBeTrue()
		for _, dailyQuest in DailyQuestCatalog.DAILY_QUESTS do
			expect(table.isfrozen(dailyQuest)).toBeTrue()
		end
	end)
end)

describe("DailyQuestCatalog lookups", function()
	it("finds every quest by id and returns nil for unknown or non-string ids", function()
		for _, dailyQuest in DailyQuestCatalog.DAILY_QUESTS do
			expect(DailyQuestCatalog.findDailyQuestByDailyQuestId(dailyQuest.dailyQuestId)).toBe(dailyQuest)
		end
		expect(DailyQuestCatalog.findDailyQuestByDailyQuestId("COMPLETE_ROUNDS_5")).toBeNil()
		expect(DailyQuestCatalog.findDailyQuestByDailyQuestId("no_such_quest")).toBeNil()
		for _, nonStringDailyQuestId in { 5, nil, 0 / 0, true, {} } do
			expect(DailyQuestCatalog.findDailyQuestByDailyQuestId(nonStringDailyQuestId)).toBeNil()
		end
	end)
end)
