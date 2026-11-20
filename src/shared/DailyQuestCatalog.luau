-- Daily quests the game can offer (development spec §1.8). Three of them are chosen each UTC day
-- by DailyQuestOfTheDaySelector; progress rules are in DailyQuestProgressFromRatedRound.
--
-- FIRST DRAFT for the owner to review. Only the shape and the example `complete_rounds_5`
-- (target 5, 100 Star Coins) come from the spec; every other quest, target and reward is a
-- proposal, sized against the pricing guide of §1.7 (a themed round pays about 60 Star Coins).
-- Ids are stored in saves (dailyQuestProgressCountByQuestId, claimedDailyQuestIds), so settle
-- them before the first release. The catalog's order does not affect which quests a day gets;
-- adding or removing one quest changes at most one of a day's three (DailyQuestOfTheDaySelector).
--
-- Open questions for the owner:
--   1. Overlapping quests. Some quests are finished by finishing another: complete_rounds_8 >
--      complete_rounds_5 > complete_rounds_3; earn_at_least_3_stars_in_4_rounds >
--      earn_at_least_3_stars_in_2_rounds and > complete_rounds_3; earn_at_least_4_stars_in_2_rounds
--      > earn_at_least_3_stars_in_2_rounds. With a uniform choice, 54 of the 220 possible sets of
--      three (about a quarter of days) contain such a pair, so those days offer fewer than "three
--      small goals" (spec §0.2). If three independent goals are wanted: keep one quest per ladder
--      here, or have the selector pick at most one quest per kind (that needs a spec sentence).
--   2. Release day. Servers on an old and a new game version can disagree on one of the day's
--      three quests after a catalog change, so a player who moves between them could claim four
--      quest rewards that day. Spec §2.9 has no reason to refuse "three already claimed"; adding
--      one is a spec decision.
--
-- What each kind counts (one per qualifying rated round; see DailyQuestProgressFromRatedRound):
--   * CompleteRounds:        a rated round with a non-empty scored outfit.
--   * EarnStarsAtLeast:      a rated round whose star count is at least `minimumStarCount`.
--   * UseColorInRatedOutfit: a rated round whose scored outfit has at least one item whose
--                            primary colour tag is `requiredColorTag`.
--
-- Rules every quest follows (enforced by tests/shared/DailyQuestCatalog.spec.luau):
--   * `dailyQuestId` is unique snake_case: lowercase words of letters and digits joined by single
--     underscores. EarnStarsAtLeast ids say "at_least_N_stars_in_M_rounds": N is a minimum per
--     round, not a total across rounds.
--   * `dailyQuestKind` is one of DAILY_QUEST_KINDS.
--   * `targetCount` and `starCoinReward` are positive whole numbers.
--   * `minimumStarCount` is set (a star count OutfitScoreCalculator.STAR_REWARD_TIERS can award)
--     exactly when the kind is EarnStarsAtLeast.
--   * `requiredColorTag` is set (a colour tag of StylingTagVocabulary) exactly when the kind is
--     UseColorInRatedOutfit.
--   * The catalog holds at least DAILY_QUEST_COUNT_PER_DAY quests.
--   * No real brand, idol, group, artist or song names (spec §5.2).
-- Pure data: no Roblox-specific interface is used.

export type DailyQuestKind = "CompleteRounds" | "EarnStarsAtLeast" | "UseColorInRatedOutfit"

export type DailyQuest = {
	dailyQuestId: string,
	dailyQuestKind: DailyQuestKind,
	targetCount: number,
	minimumStarCount: number?, -- EarnStarsAtLeast only
	requiredColorTag: string?, -- UseColorInRatedOutfit only
	starCoinReward: number,
}

local function defineDailyQuest(dailyQuest: DailyQuest): DailyQuest
	return table.freeze(dailyQuest)
end

local DailyQuestCatalog = {}

DailyQuestCatalog.DAILY_QUEST_KINDS = table.freeze({
	CompleteRounds = "CompleteRounds",
	EarnStarsAtLeast = "EarnStarsAtLeast",
	UseColorInRatedOutfit = "UseColorInRatedOutfit",
})

-- Spec §1.8: three quests per day.
DailyQuestCatalog.DAILY_QUEST_COUNT_PER_DAY = 3

DailyQuestCatalog.DAILY_QUESTS = table.freeze({
	defineDailyQuest({
		dailyQuestId = "complete_rounds_3",
		dailyQuestKind = "CompleteRounds",
		targetCount = 3,
		starCoinReward = 60,
	}),
	defineDailyQuest({
		dailyQuestId = "complete_rounds_5", -- spec §1.8 example
		dailyQuestKind = "CompleteRounds",
		targetCount = 5,
		starCoinReward = 100,
	}),
	defineDailyQuest({
		dailyQuestId = "complete_rounds_8",
		dailyQuestKind = "CompleteRounds",
		targetCount = 8,
		starCoinReward = 150,
	}),
	defineDailyQuest({
		dailyQuestId = "earn_at_least_3_stars_in_2_rounds",
		dailyQuestKind = "EarnStarsAtLeast",
		targetCount = 2,
		minimumStarCount = 3,
		starCoinReward = 80,
	}),
	defineDailyQuest({
		dailyQuestId = "earn_at_least_3_stars_in_4_rounds",
		dailyQuestKind = "EarnStarsAtLeast",
		targetCount = 4,
		minimumStarCount = 3,
		starCoinReward = 120,
	}),
	defineDailyQuest({
		dailyQuestId = "earn_at_least_4_stars_in_2_rounds",
		dailyQuestKind = "EarnStarsAtLeast",
		targetCount = 2,
		minimumStarCount = 4,
		starCoinReward = 120,
	}),
	defineDailyQuest({
		dailyQuestId = "earn_at_least_5_stars_in_1_round",
		dailyQuestKind = "EarnStarsAtLeast",
		targetCount = 1,
		minimumStarCount = 5,
		starCoinReward = 150,
	}),
	defineDailyQuest({
		dailyQuestId = "wear_pink_in_2_rated_rounds",
		dailyQuestKind = "UseColorInRatedOutfit",
		targetCount = 2,
		requiredColorTag = "pink",
		starCoinReward = 60,
	}),
	defineDailyQuest({
		dailyQuestId = "wear_blue_in_2_rated_rounds",
		dailyQuestKind = "UseColorInRatedOutfit",
		targetCount = 2,
		requiredColorTag = "blue",
		starCoinReward = 60,
	}),
	defineDailyQuest({
		dailyQuestId = "wear_purple_in_2_rated_rounds",
		dailyQuestKind = "UseColorInRatedOutfit",
		targetCount = 2,
		requiredColorTag = "purple",
		starCoinReward = 60,
	}),
	defineDailyQuest({
		dailyQuestId = "wear_red_in_2_rated_rounds",
		dailyQuestKind = "UseColorInRatedOutfit",
		targetCount = 2,
		requiredColorTag = "red",
		starCoinReward = 60,
	}),
	defineDailyQuest({
		dailyQuestId = "wear_yellow_in_2_rated_rounds",
		dailyQuestKind = "UseColorInRatedOutfit",
		targetCount = 2,
		requiredColorTag = "yellow",
		starCoinReward = 60,
	}),
})

local dailyQuestByDailyQuestId: { [string]: DailyQuest } = {}
for _, dailyQuest in DailyQuestCatalog.DAILY_QUESTS do
	dailyQuestByDailyQuestId[dailyQuest.dailyQuestId] = dailyQuest
end
table.freeze(dailyQuestByDailyQuestId)

-- Returns the catalog quest with this id, or nil for anything else (including untrusted
-- non-string values sent by a device, nil and NaN). Reading a table with any key only returns nil,
-- and the table's keys are strings, so no guard is needed (as in PlaytimeMilestoneCatalog).
function DailyQuestCatalog.findDailyQuestByDailyQuestId(dailyQuestId: any): DailyQuest?
	return dailyQuestByDailyQuestId[dailyQuestId]
end

return table.freeze(DailyQuestCatalog)
