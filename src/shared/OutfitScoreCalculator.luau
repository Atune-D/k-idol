-- Scores an outfit against a theme and a round bonus rule (development spec §1.4 and §1.6).
--
-- Every scoring number of §1.6 lives in this file; they are starting values to be tuned after
-- playtests. The score is always computed on the server from the outfit the server holds.
--
-- Precondition: the outfit is a list of `stylingItemKey` values that has passed
-- OutfitValidator.validateOutfit with the same pool. A key missing from the pool is a programming
-- error and raises an error.
-- Pure logic: no Roblox-specific interface is used.

local StylingItemLookup = require("./StylingItemLookup")
local StylingTagVocabulary = require("./StylingTagVocabulary")
local ThemeCatalog = require("./ThemeCatalog")

type StylingItem = StylingItemLookup.StylingItem
type StylingItemByStylingItemKey = StylingItemLookup.StylingItemByStylingItemKey
type Theme = ThemeCatalog.Theme

export type RoundBonusRule = {
	roundBonusKind: string, -- "ColorBonus" or "StyleBonus"
	bonusColorTag: string?, -- set when roundBonusKind is ColorBonus
	bonusStyleTag: string?, -- set when roundBonusKind is StyleBonus
}

export type StarReward = {
	starCount: number,
	starCoinsGranted: number,
	fanCountGained: number,
}

-- Everything RoundResultsPublished (§2.5) needs from scoring, plus the intermediate counts so a
-- results screen or a test can explain the score.
export type OutfitScoreBreakdown = {
	outfitScore: number,
	themeMatchPoints: number, -- unrounded, 0..50 (e.g. 33.333...)
	completenessPoints: number, -- unrounded, 0..20
	colorHarmonyPoints: number, -- 0, 8 or 15
	roundBonusPoints: number, -- 0, 5, 10 or 15
	starCount: number, -- 0 for an empty outfit, otherwise 1..5
	starCoinsGranted: number,
	fanCountGained: number,
	isOutfitEmpty: boolean,
	filledScoringSlotCount: number,
	bestItemMatchByScoringSlot: { [string]: number }, -- only filled scoring slots appear
	distinctNonNeutralColorCount: number,
	roundBonusQualifyingItemCount: number,
}

local OutfitScoreCalculator = {}

OutfitScoreCalculator.ROUND_BONUS_KINDS = table.freeze({
	ColorBonus = "ColorBonus",
	StyleBonus = "StyleBonus",
})

OutfitScoreCalculator.SCORING_SLOTS = table.freeze({
	"hair",
	"upperBody",
	"lowerBody",
	"shoes",
	"accessory",
	"makeup",
})

-- Which scoring slots each item slot feeds. A dress fills both upperBody and lowerBody.
OutfitScoreCalculator.SCORING_SLOTS_FED_BY_ITEM_SLOT = table.freeze({
	hair = table.freeze({ "hair" }),
	top = table.freeze({ "upperBody" }),
	bottom = table.freeze({ "lowerBody" }),
	dress = table.freeze({ "upperBody", "lowerBody" }),
	shoes = table.freeze({ "shoes" }),
	accessory = table.freeze({ "accessory" }),
	makeup_eyes = table.freeze({ "makeup" }),
	makeup_lips = table.freeze({ "makeup" }),
	makeup_face = table.freeze({ "makeup" }),
	eyelashes = table.freeze({ "makeup" }),
	eyebrows = table.freeze({ "makeup" }),
})

OutfitScoreCalculator.MAXIMUM_THEME_MATCH_POINTS = 50
OutfitScoreCalculator.MAXIMUM_COMPLETENESS_POINTS = 20

-- Colour harmony by number of distinct non-neutral colours worn.
OutfitScoreCalculator.COLOR_HARMONY_POINTS_FOR_AT_MOST_TWO_COLORS = 15
OutfitScoreCalculator.COLOR_HARMONY_POINTS_FOR_THREE_COLORS = 8
OutfitScoreCalculator.COLOR_HARMONY_POINTS_FOR_FOUR_OR_MORE_COLORS = 0

OutfitScoreCalculator.ROUND_BONUS_POINTS_PER_QUALIFYING_ITEM = 5
OutfitScoreCalculator.MAXIMUM_COUNTED_ROUND_BONUS_ITEMS = 3

-- Star tiers, highest first: the first tier whose minimum the score reaches applies.
OutfitScoreCalculator.STAR_REWARD_TIERS = table.freeze({
	table.freeze({ minimumOutfitScore = 90, starCount = 5, starCoinsGranted = 100, fanCountGained = 50 }),
	table.freeze({ minimumOutfitScore = 75, starCount = 4, starCoinsGranted = 80, fanCountGained = 40 }),
	table.freeze({ minimumOutfitScore = 60, starCount = 3, starCoinsGranted = 60, fanCountGained = 30 }),
	table.freeze({ minimumOutfitScore = 40, starCount = 2, starCoinsGranted = 40, fanCountGained = 20 }),
	table.freeze({ minimumOutfitScore = 0, starCount = 1, starCoinsGranted = 20, fanCountGained = 10 }),
})

-- Slack added before flooring the total, so a sum that is mathematically a whole number but
-- lands a hair below it in floating point (e.g. 59.99999999999999) is not floored one point low.
-- Far smaller than any real difference between scores.
local FLOATING_POINT_FLOOR_TOLERANCE = 1e-9

local NO_STAR_REWARD: StarReward = table.freeze({ starCount = 0, starCoinsGranted = 0, fanCountGained = 0 })

-- Item match (§1.6): the largest theme weight among the item's style tags, 0 if none is listed.
function OutfitScoreCalculator.calculateItemMatchForTheme(stylingItem: StylingItem, theme: Theme): number
	local bestStyleTagWeight = 0
	for _, styleTag in stylingItem.styleTags do
		bestStyleTagWeight = math.max(bestStyleTagWeight, ThemeCatalog.getStyleTagWeightForTheme(theme, styleTag))
	end
	return bestStyleTagWeight
end

-- §1.4: a worn item satisfies a ColorBonus when its primary colour is the bonus colour, and a
-- StyleBonus when the bonus style is one of its style tags. Raises an error for an unknown kind.
function OutfitScoreCalculator.doesStylingItemSatisfyRoundBonusRule(
	stylingItem: StylingItem,
	roundBonusRule: RoundBonusRule
): boolean
	if roundBonusRule.roundBonusKind == OutfitScoreCalculator.ROUND_BONUS_KINDS.ColorBonus then
		return stylingItem.primaryColorTag == roundBonusRule.bonusColorTag
	end
	if roundBonusRule.roundBonusKind == OutfitScoreCalculator.ROUND_BONUS_KINDS.StyleBonus then
		return table.find(stylingItem.styleTags, roundBonusRule.bonusStyleTag) ~= nil
	end
	error(string.format("OutfitScoreCalculator: unknown roundBonusKind %q", tostring(roundBonusRule.roundBonusKind)), 2)
end

-- Stars and rewards for a non-empty outfit's score (§1.6 table). An empty outfit gets nothing;
-- that rule is applied in calculateOutfitScore, not here.
function OutfitScoreCalculator.determineStarRewardForOutfitScore(outfitScore: number): StarReward
	for _, starRewardTier in OutfitScoreCalculator.STAR_REWARD_TIERS do
		if outfitScore >= starRewardTier.minimumOutfitScore then
			return table.freeze({
				starCount = starRewardTier.starCount,
				starCoinsGranted = starRewardTier.starCoinsGranted,
				fanCountGained = starRewardTier.fanCountGained,
			})
		end
	end
	error(string.format("OutfitScoreCalculator: outfit score %s is below every star tier", tostring(outfitScore)), 2)
end

local function calculateColorHarmonyPoints(distinctNonNeutralColorCount: number, isOutfitEmpty: boolean): number
	if isOutfitEmpty then
		return 0
	end
	if distinctNonNeutralColorCount <= 2 then
		return OutfitScoreCalculator.COLOR_HARMONY_POINTS_FOR_AT_MOST_TWO_COLORS
	end
	if distinctNonNeutralColorCount == 3 then
		return OutfitScoreCalculator.COLOR_HARMONY_POINTS_FOR_THREE_COLORS
	end
	return OutfitScoreCalculator.COLOR_HARMONY_POINTS_FOR_FOUR_OR_MORE_COLORS
end

-- Scores one outfit (§1.6). `outfitStylingItemKeys` must already be valid (see the precondition
-- above). A pair of shoes is one styling item (a bundle) and fills the shoes scoring slot once.
function OutfitScoreCalculator.calculateOutfitScore(
	outfitStylingItemKeys: { string },
	stylingItemByStylingItemKey: StylingItemByStylingItemKey,
	theme: Theme,
	roundBonusRule: RoundBonusRule
): OutfitScoreBreakdown
	local bestItemMatchByScoringSlot: { [string]: number } = {}
	local isNonNeutralColorWorn: { [string]: boolean } = {}
	local distinctNonNeutralColorCount = 0
	local roundBonusQualifyingItemCount = 0

	for _, outfitStylingItemKey in outfitStylingItemKeys do
		local stylingItem = stylingItemByStylingItemKey[outfitStylingItemKey]
		if stylingItem == nil then
			error(
				string.format(
					"OutfitScoreCalculator: stylingItemKey %s is not in the styling item pool; validate the outfit first",
					tostring(outfitStylingItemKey)
				),
				2
			)
		end

		local itemMatch = OutfitScoreCalculator.calculateItemMatchForTheme(stylingItem, theme)
		local fedScoringSlots = OutfitScoreCalculator.SCORING_SLOTS_FED_BY_ITEM_SLOT[stylingItem.itemSlot]
		if fedScoringSlots == nil then
			error(string.format("OutfitScoreCalculator: unknown item slot %q", tostring(stylingItem.itemSlot)), 2)
		end
		for _, scoringSlot in fedScoringSlots do
			bestItemMatchByScoringSlot[scoringSlot] = math.max(bestItemMatchByScoringSlot[scoringSlot] or 0, itemMatch)
		end

		local primaryColorTag = stylingItem.primaryColorTag
		if
			not StylingTagVocabulary.isNeutralColorTag(primaryColorTag) and not isNonNeutralColorWorn[primaryColorTag]
		then
			isNonNeutralColorWorn[primaryColorTag] = true
			distinctNonNeutralColorCount += 1
		end

		if OutfitScoreCalculator.doesStylingItemSatisfyRoundBonusRule(stylingItem, roundBonusRule) then
			roundBonusQualifyingItemCount += 1
		end
	end

	local scoringSlotCount = #OutfitScoreCalculator.SCORING_SLOTS
	local filledScoringSlotCount = 0
	local bestItemMatchSum = 0
	for _, scoringSlot in OutfitScoreCalculator.SCORING_SLOTS do
		local bestItemMatch = bestItemMatchByScoringSlot[scoringSlot]
		if bestItemMatch ~= nil then
			filledScoringSlotCount += 1
			bestItemMatchSum += bestItemMatch
		end
	end

	local isOutfitEmpty = #outfitStylingItemKeys == 0
	local themeMatchPoints = OutfitScoreCalculator.MAXIMUM_THEME_MATCH_POINTS * bestItemMatchSum / scoringSlotCount
	local completenessPoints = OutfitScoreCalculator.MAXIMUM_COMPLETENESS_POINTS
		* filledScoringSlotCount
		/ scoringSlotCount
	local colorHarmonyPoints = calculateColorHarmonyPoints(distinctNonNeutralColorCount, isOutfitEmpty)
	local roundBonusPoints = OutfitScoreCalculator.ROUND_BONUS_POINTS_PER_QUALIFYING_ITEM
		* math.min(OutfitScoreCalculator.MAXIMUM_COUNTED_ROUND_BONUS_ITEMS, roundBonusQualifyingItemCount)

	local outfitScore = math.floor(
		themeMatchPoints + completenessPoints + colorHarmonyPoints + roundBonusPoints + FLOATING_POINT_FLOOR_TOLERANCE
	)
	-- An empty final outfit receives no stars and no reward (§1.6).
	local starReward = if isOutfitEmpty
		then NO_STAR_REWARD
		else OutfitScoreCalculator.determineStarRewardForOutfitScore(outfitScore)

	return table.freeze({
		outfitScore = outfitScore,
		themeMatchPoints = themeMatchPoints,
		completenessPoints = completenessPoints,
		colorHarmonyPoints = colorHarmonyPoints,
		roundBonusPoints = roundBonusPoints,
		starCount = starReward.starCount,
		starCoinsGranted = starReward.starCoinsGranted,
		fanCountGained = starReward.fanCountGained,
		isOutfitEmpty = isOutfitEmpty,
		filledScoringSlotCount = filledScoringSlotCount,
		bestItemMatchByScoringSlot = table.freeze(bestItemMatchByScoringSlot),
		distinctNonNeutralColorCount = distinctNonNeutralColorCount,
		roundBonusQualifyingItemCount = roundBonusQualifyingItemCount,
	})
end

return table.freeze(OutfitScoreCalculator)
