-- Decides which of today's daily quests one finished, rated round advances (development spec
-- §1.8, §6.2 "quest progress counts only qualifying rounds").
--
-- Who calls it: the code that grants a round reward. The returned progress is written in the same
-- change as the round reward (spec §3.3, row "Round reward"). This module only decides; it changes
-- nothing.
--
-- The facts of the round are passed in explicitly (see RatedRoundFactsForDailyQuests). `starCount`
-- and `isOutfitEmpty` are the fields of the same names in the round's OutfitScoreCalculator
-- breakdown, so this module needs neither the referee nor the styling item pool.
--
-- Rules:
--   * A round whose scored outfit is empty earns no stars and no reward (spec §1.6), so it never
--     counts for any quest, not even CompleteRounds.
--   * A qualifying round adds exactly 1 to a quest, however many items or stars qualify it:
--       CompleteRounds:        any rated round with a non-empty scored outfit;
--       EarnStarsAtLeast:      starCount >= minimumStarCount;
--       UseColorInRatedOutfit: at least one scored item's primary colour tag is requiredColorTag.
--   * Progress is capped at targetCount: a quest already at or above its target, or already
--     claimed, is not advanced. So this module never raises a stored count above targetCount.
--
-- The caller passes `currentDailyDateKey`; `dailyProgress` must be that day's table (the daily
-- reset has been applied), otherwise an error is raised (DailyProgressReader). "Today's quests" are
-- those selected for `currentDailyDateKey`. Inconsistent round facts are a programming error and
-- raise an error too. The star range comes from OutfitScoreCalculator.STAR_REWARD_TIERS, so tuning
-- the tiers there needs no change here.
-- Pure logic: no Roblox-specific interface is used.

local DailyProgressReader = require("./DailyProgressReader")
local DailyQuestCatalog = require("./DailyQuestCatalog")
local DailyQuestOfTheDaySelector = require("./DailyQuestOfTheDaySelector")
local OutfitScoreCalculator = require("./OutfitScoreCalculator")

type DailyQuest = DailyQuestCatalog.DailyQuest
type DailyProgress = DailyProgressReader.DailyProgress

-- The facts of one finished, rated round for one participant.
export type RatedRoundFactsForDailyQuests = {
	-- OutfitScoreBreakdown.isOutfitEmpty.
	isOutfitEmpty: boolean,
	-- OutfitScoreBreakdown.starCount: 0 when the outfit is empty, otherwise a star count of a tier.
	starCount: number,
	-- The primaryColorTag of every styling item in the scored outfit (repeats allowed).
	scoredOutfitPrimaryColorTags: { string },
}

export type DailyQuestProgressAdvance = {
	dailyQuestId: string,
	-- The quest's count after this round: one more than before, never above its targetCount.
	progressCountAfterRound: number,
}

local DailyQuestProgressFromRatedRound = {}

local DAILY_QUEST_KINDS = DailyQuestCatalog.DAILY_QUEST_KINDS

local function findAwardedStarCountRange(): (number, number)
	local smallestAwardedStarCount, largestAwardedStarCount = math.huge, -math.huge
	for _, starRewardTier in OutfitScoreCalculator.STAR_REWARD_TIERS do
		smallestAwardedStarCount = math.min(smallestAwardedStarCount, starRewardTier.starCount)
		largestAwardedStarCount = math.max(largestAwardedStarCount, starRewardTier.starCount)
	end
	return smallestAwardedStarCount, largestAwardedStarCount
end

local SMALLEST_AWARDED_STAR_COUNT, LARGEST_AWARDED_STAR_COUNT = findAwardedStarCountRange()

-- Raises an error (blaming the caller of the public function) for inconsistent round facts.
local function assertRatedRoundFactsAreConsistent(ratedRoundFacts: RatedRoundFactsForDailyQuests)
	if type(ratedRoundFacts) ~= "table" or type(ratedRoundFacts.isOutfitEmpty) ~= "boolean" then
		error("DailyQuestProgressFromRatedRound: isOutfitEmpty must be a boolean", 3)
	end
	local starCount = ratedRoundFacts.starCount
	if type(starCount) ~= "number" or starCount % 1 ~= 0 then
		error("DailyQuestProgressFromRatedRound: starCount must be a whole number", 3)
	end
	local scoredOutfitPrimaryColorTags = ratedRoundFacts.scoredOutfitPrimaryColorTags
	if type(scoredOutfitPrimaryColorTags) ~= "table" then
		error("DailyQuestProgressFromRatedRound: scoredOutfitPrimaryColorTags must be a list", 3)
	end
	if ratedRoundFacts.isOutfitEmpty then
		if starCount ~= 0 or #scoredOutfitPrimaryColorTags ~= 0 then
			error("DailyQuestProgressFromRatedRound: an empty outfit has 0 stars and no colour tags", 3)
		end
	elseif
		starCount < SMALLEST_AWARDED_STAR_COUNT
		or starCount > LARGEST_AWARDED_STAR_COUNT
		or #scoredOutfitPrimaryColorTags == 0
	then
		error("DailyQuestProgressFromRatedRound: a non-empty outfit has an awarded star count and colour tags", 3)
	end
end

-- The qualifying rule itself, for facts already checked.
local function doesCheckedRatedRoundQualifyForDailyQuest(
	dailyQuest: DailyQuest,
	ratedRoundFacts: RatedRoundFactsForDailyQuests
): boolean
	if ratedRoundFacts.isOutfitEmpty then
		return false
	end
	local dailyQuestKind = dailyQuest.dailyQuestKind
	if dailyQuestKind == DAILY_QUEST_KINDS.CompleteRounds then
		return true
	elseif dailyQuestKind == DAILY_QUEST_KINDS.EarnStarsAtLeast then
		return ratedRoundFacts.starCount >= (dailyQuest.minimumStarCount :: number)
	elseif dailyQuestKind == DAILY_QUEST_KINDS.UseColorInRatedOutfit then
		return table.find(ratedRoundFacts.scoredOutfitPrimaryColorTags, dailyQuest.requiredColorTag) ~= nil
	end
	error("DailyQuestProgressFromRatedRound: unknown dailyQuestKind " .. tostring(dailyQuestKind), 3)
end

-- True when the round counts toward this quest (before any cap).
function DailyQuestProgressFromRatedRound.doesRatedRoundQualifyForDailyQuest(
	dailyQuest: DailyQuest,
	ratedRoundFacts: RatedRoundFactsForDailyQuests
): boolean
	assertRatedRoundFactsAreConsistent(ratedRoundFacts)
	return doesCheckedRatedRoundQualifyForDailyQuest(dailyQuest, ratedRoundFacts)
end

-- Which of today's quests this round advances, in today's quest order, as a frozen list; quests it
-- does not advance are left out. `dailyQuestCatalogEntries` defaults to the real catalog; tests
-- pass their own.
function DailyQuestProgressFromRatedRound.determineDailyQuestProgressFromRatedRound(
	dailyProgress: DailyProgress,
	currentDailyDateKey: string,
	ratedRoundFacts: RatedRoundFactsForDailyQuests,
	dailyQuestCatalogEntries: { DailyQuest }?
): { DailyQuestProgressAdvance }
	DailyProgressReader.assertDailyProgressIsCurrentAndWellFormed(dailyProgress, currentDailyDateKey, 2)
	assertRatedRoundFactsAreConsistent(ratedRoundFacts)

	local dailyQuestProgressAdvances = {}
	for _, todaysDailyQuest in
		DailyQuestOfTheDaySelector.selectDailyQuestsForDailyDateKey(currentDailyDateKey, dailyQuestCatalogEntries)
	do
		local dailyQuestId = todaysDailyQuest.dailyQuestId
		if
			not DailyProgressReader.isDailyQuestClaimed(dailyProgress, dailyQuestId)
			and not DailyProgressReader.hasDailyQuestReachedTarget(dailyProgress, todaysDailyQuest)
			and doesCheckedRatedRoundQualifyForDailyQuest(todaysDailyQuest, ratedRoundFacts)
		then
			table.insert(
				dailyQuestProgressAdvances,
				table.freeze({
					dailyQuestId = dailyQuestId,
					progressCountAfterRound = DailyProgressReader.readDailyQuestProgressCount(
						dailyProgress,
						dailyQuestId
					) + 1,
				})
			)
		end
	end
	return table.freeze(dailyQuestProgressAdvances)
end

return table.freeze(DailyQuestProgressFromRatedRound)
