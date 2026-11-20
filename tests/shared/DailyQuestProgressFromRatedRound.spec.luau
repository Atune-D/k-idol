-- Daily quest progress from a finished, rated round (development spec §1.8, §6.2 "quest progress
-- counts only qualifying rounds"). Every randomized failure names its seed; rerun with
-- IDOLGROW_RANDOM_TEST_SEED=<seed> to repeat it.

local UnitTestFramework = require("../Support/UnitTestFramework")
local DailyQuestProgressFromRatedRound = require("../../src/shared/DailyQuestProgressFromRatedRound")
local DailyQuestOfTheDaySelector = require("../../src/shared/DailyQuestOfTheDaySelector")
local OutfitScoreCalculator = require("../../src/shared/OutfitScoreCalculator")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local StylingTagVocabulary = require("../../src/shared/StylingTagVocabulary")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local TEST_DAILY_DATE_KEY = DailyQuestTestCatalog.TEST_DAILY_DATE_KEY
-- Today's test quests, in the selector's order: quest_a (CompleteRounds, target 3),
-- quest_d (EarnStarsAtLeast 4, target 2), quest_e (pink, target 1).
local SIX_TEST_DAILY_QUESTS = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS
local TODAYS_TEST_DAILY_QUEST_IDS = DailyQuestTestCatalog.TODAYS_TEST_DAILY_QUEST_IDS

local COMPLETE_ROUNDS_QUEST =
	{ dailyQuestId = "complete_rounds_test", dailyQuestKind = "CompleteRounds", targetCount = 5, starCoinReward = 1 }
local EARN_3_STARS_QUEST = {
	dailyQuestId = "earn_at_least_3_stars_test",
	dailyQuestKind = "EarnStarsAtLeast",
	targetCount = 2,
	minimumStarCount = 3,
	starCoinReward = 1,
}
local WEAR_PINK_QUEST = {
	dailyQuestId = "wear_pink_test",
	dailyQuestKind = "UseColorInRatedOutfit",
	targetCount = 2,
	requiredColorTag = "pink",
	starCoinReward = 1,
}

local EMPTY_OUTFIT_ROUND_FACTS =
	table.freeze({ isOutfitEmpty = true, starCount = 0, scoredOutfitPrimaryColorTags = {} })

local function findLargestAwardedStarCount(): number
	local largestAwardedStarCount = 0
	for _, starRewardTier in OutfitScoreCalculator.STAR_REWARD_TIERS do
		largestAwardedStarCount = math.max(largestAwardedStarCount, starRewardTier.starCount)
	end
	return largestAwardedStarCount
end
local LARGEST_AWARDED_STAR_COUNT = findLargestAwardedStarCount()

local function createRatedRoundFacts(starCount: number, scoredOutfitPrimaryColorTags: { string })
	return {
		isOutfitEmpty = false,
		starCount = starCount,
		scoredOutfitPrimaryColorTags = scoredOutfitPrimaryColorTags,
	}
end

local function doesRoundQualify(dailyQuest, ratedRoundFacts): boolean
	return DailyQuestProgressFromRatedRound.doesRatedRoundQualifyForDailyQuest(dailyQuest, ratedRoundFacts)
end

local function createDailyProgress(dailyQuestProgressCountByQuestId, claimedDailyQuestIds)
	return DailyQuestTestCatalog.createTestDailyProgress({
		dailyQuestProgressCountByQuestId = dailyQuestProgressCountByQuestId or {},
		claimedDailyQuestIds = claimedDailyQuestIds or {},
	})
end

local function determineTestProgress(dailyProgress, ratedRoundFacts)
	return DailyQuestProgressFromRatedRound.determineDailyQuestProgressFromRatedRound(
		dailyProgress,
		dailyProgress.dailyDateKey,
		ratedRoundFacts,
		SIX_TEST_DAILY_QUESTS
	)
end

describe("DailyQuestProgressFromRatedRound qualifying rounds per kind", function()
	it("CompleteRounds counts every rated round with a non-empty outfit, whatever its stars", function()
		for starCount = 1, LARGEST_AWARDED_STAR_COUNT do
			expect(doesRoundQualify(COMPLETE_ROUNDS_QUEST, createRatedRoundFacts(starCount, { "black" }))).toBeTrue()
		end
		expect(doesRoundQualify(COMPLETE_ROUNDS_QUEST, EMPTY_OUTFIT_ROUND_FACTS)).toBeFalse()
	end)

	it("EarnStarsAtLeast counts a round at exactly minimumStarCount and above, not below", function()
		expect(doesRoundQualify(EARN_3_STARS_QUEST, createRatedRoundFacts(1, { "pink" }))).toBeFalse()
		expect(doesRoundQualify(EARN_3_STARS_QUEST, createRatedRoundFacts(2, { "pink" }))).toBeFalse()
		expect(doesRoundQualify(EARN_3_STARS_QUEST, createRatedRoundFacts(3, { "pink" }))).toBeTrue()
		expect(doesRoundQualify(EARN_3_STARS_QUEST, createRatedRoundFacts(5, { "pink" }))).toBeTrue()
		expect(doesRoundQualify(EARN_3_STARS_QUEST, EMPTY_OUTFIT_ROUND_FACTS)).toBeFalse()
	end)

	it("UseColorInRatedOutfit counts a round when any scored item has the colour, not otherwise", function()
		expect(doesRoundQualify(WEAR_PINK_QUEST, createRatedRoundFacts(1, { "pink" }))).toBeTrue()
		expect(doesRoundQualify(WEAR_PINK_QUEST, createRatedRoundFacts(2, { "black", "white", "pink" }))).toBeTrue()
		expect(doesRoundQualify(WEAR_PINK_QUEST, createRatedRoundFacts(5, { "red", "purple", "black" }))).toBeFalse()
		expect(doesRoundQualify(WEAR_PINK_QUEST, EMPTY_OUTFIT_ROUND_FACTS)).toBeFalse()
		local wearBlackQuest = table.clone(WEAR_PINK_QUEST)
		wearBlackQuest.requiredColorTag = "black"
		expect(doesRoundQualify(wearBlackQuest, createRatedRoundFacts(1, { "black" }))).toBeTrue()
		expect(doesRoundQualify(wearBlackQuest, createRatedRoundFacts(1, { "pink" }))).toBeFalse()
	end)

	it("raises an error for a quest of unknown kind", function()
		local unknownKindQuest = table.clone(COMPLETE_ROUNDS_QUEST)
		unknownKindQuest.dailyQuestKind = "WinTournament"
		expect(function()
			doesRoundQualify(unknownKindQuest, createRatedRoundFacts(3, { "pink" }))
		end).toThrow("unknown dailyQuestKind")
	end)

	it("takes the star range from OutfitScoreCalculator's tiers: the top tier is fine, one above is not", function()
		expect(doesRoundQualify(COMPLETE_ROUNDS_QUEST, createRatedRoundFacts(LARGEST_AWARDED_STAR_COUNT, { "pink" }))).toBeTrue()
		expect(function()
			doesRoundQualify(COMPLETE_ROUNDS_QUEST, createRatedRoundFacts(LARGEST_AWARDED_STAR_COUNT + 1, { "pink" }))
		end).toThrow("DailyQuestProgressFromRatedRound")
	end)

	it("raises an error for inconsistent round facts", function()
		local inconsistentRoundFactsList = {
			{ isOutfitEmpty = true, starCount = 1, scoredOutfitPrimaryColorTags = {} },
			{ isOutfitEmpty = true, starCount = 0, scoredOutfitPrimaryColorTags = { "pink" } },
			{ isOutfitEmpty = false, starCount = 0, scoredOutfitPrimaryColorTags = { "pink" } },
			{ isOutfitEmpty = false, starCount = 2.5, scoredOutfitPrimaryColorTags = { "pink" } },
			{ isOutfitEmpty = false, starCount = 3, scoredOutfitPrimaryColorTags = {} },
			{ isOutfitEmpty = false, starCount = 3 },
			{ starCount = 3, scoredOutfitPrimaryColorTags = { "pink" } },
		}
		for _, inconsistentRoundFacts in inconsistentRoundFactsList do
			expect(function()
				doesRoundQualify(COMPLETE_ROUNDS_QUEST, inconsistentRoundFacts)
			end).toThrow("DailyQuestProgressFromRatedRound")
			expect(function()
				determineTestProgress(createDailyProgress(), inconsistentRoundFacts)
			end).toThrow("DailyQuestProgressFromRatedRound")
		end
	end)

	it("checks the round facts even when no quest of today would look at them", function()
		-- Every one of today's quests is claimed, so no quest is evaluated; bad facts still raise.
		local everythingClaimedDailyProgress = createDailyProgress({}, table.clone(TODAYS_TEST_DAILY_QUEST_IDS))
		expect(function()
			determineTestProgress(
				everythingClaimedDailyProgress,
				{ isOutfitEmpty = false, starCount = 0, scoredOutfitPrimaryColorTags = { "pink" } }
			)
		end).toThrow("DailyQuestProgressFromRatedRound")
	end)
end)

describe("DailyQuestProgressFromRatedRound today's quests", function()
	it("a 4-star round with pink advances all three of today's quests by 1, in today's order", function()
		expect(determineTestProgress(createDailyProgress(), createRatedRoundFacts(4, { "pink", "black" }))).toEqual({
			{ dailyQuestId = "quest_a", progressCountAfterRound = 1 },
			{ dailyQuestId = "quest_d", progressCountAfterRound = 1 },
			{ dailyQuestId = "quest_e", progressCountAfterRound = 1 },
		})
	end)

	it("a 3-star round without pink advances only the CompleteRounds quest", function()
		expect(determineTestProgress(createDailyProgress({ quest_a = 1 }), createRatedRoundFacts(3, { "red", "red" }))).toEqual({
			{ dailyQuestId = "quest_a", progressCountAfterRound = 2 },
		})
	end)

	it("an empty outfit advances nothing", function()
		expect(determineTestProgress(createDailyProgress(), EMPTY_OUTFIT_ROUND_FACTS)).toEqual({})
	end)

	it("never advances a quest that is not one of today's", function()
		-- quest_b, quest_c and quest_f are CompleteRounds quests the test catalog does not pick today.
		for _, dailyQuestProgressAdvance in
			determineTestProgress(createDailyProgress(), createRatedRoundFacts(5, { "pink" }))
		do
			expect(table.find(TODAYS_TEST_DAILY_QUEST_IDS, dailyQuestProgressAdvance.dailyQuestId) ~= nil).toBeTrue()
		end
	end)

	it("caps progress at targetCount: a quest at its target is not advanced, one below it is", function()
		local almostDoneDailyProgress = createDailyProgress({ quest_e = 1, quest_a = 2, quest_d = 2 })
		expect(determineTestProgress(almostDoneDailyProgress, createRatedRoundFacts(5, { "pink" }))).toEqual({
			{ dailyQuestId = "quest_a", progressCountAfterRound = 3 },
		})
		local doneDailyProgress = createDailyProgress({ quest_e = 1, quest_a = 3, quest_d = 2 })
		expect(determineTestProgress(doneDailyProgress, createRatedRoundFacts(5, { "pink" }))).toEqual({})
	end)

	it("does not advance a quest whose stored progress is already above its target", function()
		local beyondTargetDailyProgress = createDailyProgress({ quest_e = 2, quest_a = 4, quest_d = 9 })
		expect(determineTestProgress(beyondTargetDailyProgress, createRatedRoundFacts(5, { "pink" }))).toEqual({})
	end)

	it("does not advance a quest already claimed today, wherever it is in the claimed list", function()
		local claimedFirstDailyProgress = createDailyProgress({ quest_a = 1 }, { "quest_a", "quest_e" })
		expect(determineTestProgress(claimedFirstDailyProgress, createRatedRoundFacts(3, { "red" }))).toEqual({})
		local claimedSecondDailyProgress = createDailyProgress({ quest_a = 1 }, { "quest_e", "quest_a" })
		expect(determineTestProgress(claimedSecondDailyProgress, createRatedRoundFacts(3, { "red" }))).toEqual({})
		local claimedMiddleDailyProgress = createDailyProgress({ quest_a = 1 }, { "quest_e", "quest_a", "quest_d" })
		expect(determineTestProgress(claimedMiddleDailyProgress, createRatedRoundFacts(3, { "red" }))).toEqual({})
	end)

	it("changes nothing: works on a frozen dailyProgress and leaves it equal; returns frozen results", function()
		local dailyProgress = DailyQuestTestCatalog.freezeDeeply(createDailyProgress({ quest_a = 1 }, { "quest_e" }))
		local dailyProgressBefore = PlayerSaveDataSchema.createDeepCopyOfPlainTable(dailyProgress)
		local dailyQuestProgressAdvances = determineTestProgress(dailyProgress, createRatedRoundFacts(5, { "pink" }))
		expect(dailyProgress).toEqual(dailyProgressBefore)
		expect(#dailyQuestProgressAdvances > 0).toBeTrue()
		expect(table.isfrozen(dailyQuestProgressAdvances)).toBeTrue()
		for _, dailyQuestProgressAdvance in dailyQuestProgressAdvances do
			expect(table.isfrozen(dailyQuestProgressAdvance)).toBeTrue()
		end
		expect(table.isfrozen(DailyQuestProgressFromRatedRound)).toBeTrue()
	end)

	it("uses the real catalog and the date's quests by default", function()
		local realTodaysDailyQuestIds =
			DailyQuestOfTheDaySelector.selectDailyQuestIdsForDailyDateKey(TEST_DAILY_DATE_KEY)
		for _, dailyQuestProgressAdvance in
			DailyQuestProgressFromRatedRound.determineDailyQuestProgressFromRatedRound(
				createDailyProgress(),
				TEST_DAILY_DATE_KEY,
				createRatedRoundFacts(5, StylingTagVocabulary.COLOR_TAGS)
			)
		do
			expect(table.find(realTodaysDailyQuestIds, dailyQuestProgressAdvance.dailyQuestId) ~= nil).toBeTrue()
		end
	end)

	it("raises an error for a dailyProgress that is not today's or is malformed", function()
		expect(function()
			DailyQuestProgressFromRatedRound.determineDailyQuestProgressFromRatedRound(
				createDailyProgress({ quest_a = 1 }),
				DailyQuestTestCatalog.NEXT_TEST_DAILY_DATE_KEY,
				createRatedRoundFacts(5, { "pink" }),
				SIX_TEST_DAILY_QUESTS
			)
		end).toThrow("apply the daily reset first")
		local malformedDailyProgress = createDailyProgress({ quest_a = 1 })
		malformedDailyProgress.claimedDailyQuestIds = nil :: any
		expect(function()
			determineTestProgress(malformedDailyProgress, createRatedRoundFacts(5, { "pink" }))
		end).toThrow("malformed at claimedDailyQuestIds")
	end)
end)

describe("DailyQuestProgressFromRatedRound randomized rounds", function()
	local function pickRandomRatedRoundFacts(trialRandomNumberGenerator)
		if trialRandomNumberGenerator.nextWholeNumberInRange(1, 6) == 1 then
			return EMPTY_OUTFIT_ROUND_FACTS
		end
		local scoredOutfitPrimaryColorTags = {}
		for _ = 1, trialRandomNumberGenerator.nextWholeNumberInRange(1, 8) do
			table.insert(
				scoredOutfitPrimaryColorTags,
				trialRandomNumberGenerator.pickRandomListElement(StylingTagVocabulary.COLOR_TAGS)
			)
		end
		return createRatedRoundFacts(
			trialRandomNumberGenerator.nextWholeNumberInRange(1, LARGEST_AWARDED_STAR_COUNT),
			scoredOutfitPrimaryColorTags
		)
	end

	-- Independent statement of the §1.8 rules, written without the module's code.
	local function isQualifyingRoundByIndependentRule(dailyQuest, ratedRoundFacts): boolean
		if ratedRoundFacts.isOutfitEmpty then
			return false
		end
		if dailyQuest.dailyQuestKind == "EarnStarsAtLeast" then
			return ratedRoundFacts.starCount >= dailyQuest.minimumStarCount
		end
		if dailyQuest.dailyQuestKind == "UseColorInRatedOutfit" then
			for _, primaryColorTag in ratedRoundFacts.scoredOutfitPrimaryColorTags do
				if primaryColorTag == dailyQuest.requiredColorTag then
					return true
				end
			end
			return false
		end
		return true
	end

	it("over a random day of rounds, each quest reaches min(target, qualifying rounds) and never more", function()
		SeededRandomTrials.runSeededRandomTrials(300, function(trialRandomNumberGenerator)
			local dailyDateKey = DailyQuestTestCatalog.pickRandomDailyDateKey(trialRandomNumberGenerator)
			local dailyProgress = PlayerSaveDataSchema.createFreshDailyProgress(dailyDateKey)
			local todaysDailyQuests = DailyQuestOfTheDaySelector.selectDailyQuestsForDailyDateKey(dailyDateKey)
			local qualifyingRoundCountByQuestId = {}
			for _ = 1, trialRandomNumberGenerator.nextWholeNumberInRange(0, 15) do
				local ratedRoundFacts = pickRandomRatedRoundFacts(trialRandomNumberGenerator)
				for _, todaysDailyQuest in todaysDailyQuests do
					if isQualifyingRoundByIndependentRule(todaysDailyQuest, ratedRoundFacts) then
						qualifyingRoundCountByQuestId[todaysDailyQuest.dailyQuestId] = (
							qualifyingRoundCountByQuestId[todaysDailyQuest.dailyQuestId] or 0
						) + 1
					end
				end
				-- Apply the advances as the round-reward change would.
				for _, dailyQuestProgressAdvance in
					DailyQuestProgressFromRatedRound.determineDailyQuestProgressFromRatedRound(
						dailyProgress,
						dailyDateKey,
						ratedRoundFacts
					)
				do
					local dailyQuestId = dailyQuestProgressAdvance.dailyQuestId
					local progressCountBeforeRound = dailyProgress.dailyQuestProgressCountByQuestId[dailyQuestId] or 0
					expect(dailyQuestProgressAdvance.progressCountAfterRound).toBe(progressCountBeforeRound + 1)
					dailyProgress.dailyQuestProgressCountByQuestId[dailyQuestId] =
						dailyQuestProgressAdvance.progressCountAfterRound
				end
			end
			for _, todaysDailyQuest in todaysDailyQuests do
				local dailyQuestId = todaysDailyQuest.dailyQuestId
				local expectedProgressCount =
					math.min(todaysDailyQuest.targetCount, qualifyingRoundCountByQuestId[dailyQuestId] or 0)
				expect({ dailyDateKey, dailyQuestId, dailyProgress.dailyQuestProgressCountByQuestId[dailyQuestId] or 0 }).toEqual({
					dailyDateKey,
					dailyQuestId,
					expectedProgressCount,
				})
			end
		end)
	end)
end)
