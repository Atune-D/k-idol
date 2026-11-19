-- Randomized invariant tests for outfit validity and scoring (development spec §1.5, §1.6).
-- Every failure names the random seed; rerun with IDOLGROW_RANDOM_TEST_SEED=<seed> to repeat it
-- (see tests/fixtures/SeededRandomTrials.luau).

local UnitTestFramework = require("../Support/UnitTestFramework")
local OutfitValidator = require("../../src/shared/OutfitValidator")
local OutfitScoreCalculator = require("../../src/shared/OutfitScoreCalculator")
local ThemeCatalog = require("../../src/shared/ThemeCatalog")
local StylingTagVocabulary = require("../../src/shared/StylingTagVocabulary")
local StoredLobbyOutfitResolver = require("../../src/shared/StoredLobbyOutfitResolver")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local RandomValidOutfitGenerator = require("../fixtures/RandomValidOutfitGenerator")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local RANDOM_TRIAL_COUNT = 500

local FAKE_POOL = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY
local FAKE_AVAILABLE_SET = FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET

local function validateFakeOutfit(outfitStylingItemKeys: { string })
	return OutfitValidator.validateOutfit(outfitStylingItemKeys, FAKE_POOL, FAKE_AVAILABLE_SET)
end

local function pickRandomRoundBonusRule(seededRandomNumberGenerator, theme)
	if seededRandomNumberGenerator.nextWholeNumberInRange(1, 2) == 1 then
		local nonNeutralColorTags = {}
		for _, colorTag in StylingTagVocabulary.COLOR_TAGS do
			if not StylingTagVocabulary.isNeutralColorTag(colorTag) then
				table.insert(nonNeutralColorTags, colorTag)
			end
		end
		return {
			roundBonusKind = "ColorBonus",
			bonusColorTag = seededRandomNumberGenerator.pickRandomListElement(nonNeutralColorTags),
		}
	end
	local unweightedStyleTags = {}
	for _, styleTag in StylingTagVocabulary.STYLE_TAGS do
		if theme.styleTagWeights[styleTag] == nil then
			table.insert(unweightedStyleTags, styleTag)
		end
	end
	return {
		roundBonusKind = "StyleBonus",
		bonusStyleTag = seededRandomNumberGenerator.pickRandomListElement(unweightedStyleTags),
	}
end

local function expectedStarRewardForScore(outfitScore: number): { number }
	if outfitScore >= 90 then
		return { 5, 100, 50 }
	elseif outfitScore >= 75 then
		return { 4, 80, 40 }
	elseif outfitScore >= 60 then
		return { 3, 60, 30 }
	elseif outfitScore >= 40 then
		return { 2, 40, 20 }
	end
	return { 1, 20, 10 }
end

local function pickRandomSubset(seededRandomNumberGenerator, outfitStylingItemKeys: { string }): { string }
	local subsetKeys = {}
	for _, outfitStylingItemKey in outfitStylingItemKeys do
		if seededRandomNumberGenerator.nextWholeNumberInRange(0, 1) == 1 then
			table.insert(subsetKeys, outfitStylingItemKey)
		end
	end
	return subsetKeys
end

describe("randomized outfits (seed " .. tostring(SeededRandomTrials.RANDOM_TEST_SEED) .. ")", function()
	it("the validator accepts every outfit the generator builds", function()
		SeededRandomTrials.runSeededRandomTrials(RANDOM_TRIAL_COUNT, function(seededRandomNumberGenerator)
			local outfitStylingItemKeys =
				RandomValidOutfitGenerator.generateRandomValidOutfitStylingItemKeys(seededRandomNumberGenerator)
			local verdict = validateFakeOutfit(outfitStylingItemKeys)
			expect({ outfitStylingItemKeys, verdict.outfitRejectionReason }).toEqual({ outfitStylingItemKeys, nil })
		end)
	end)

	it("removing any items from a valid outfit keeps it valid", function()
		SeededRandomTrials.runSeededRandomTrials(RANDOM_TRIAL_COUNT, function(seededRandomNumberGenerator)
			local outfitStylingItemKeys =
				RandomValidOutfitGenerator.generateRandomValidOutfitStylingItemKeys(seededRandomNumberGenerator)
			local subsetKeys = pickRandomSubset(seededRandomNumberGenerator, outfitStylingItemKeys)
			expect({ subsetKeys, validateFakeOutfit(subsetKeys).isOutfitValid }).toEqual({ subsetKeys, true })
		end)
	end)

	it("adding a second item to a filled single-item slot, or a repeated key, makes it invalid", function()
		SeededRandomTrials.runSeededRandomTrials(RANDOM_TRIAL_COUNT, function(seededRandomNumberGenerator)
			local outfitStylingItemKeys =
				RandomValidOutfitGenerator.generateRandomValidOutfitStylingItemKeys(seededRandomNumberGenerator)
			if #outfitStylingItemKeys == 0 then
				return
			end
			local repeatedKey = seededRandomNumberGenerator.pickRandomListElement(outfitStylingItemKeys)
			local withRepeat = table.clone(outfitStylingItemKeys)
			table.insert(withRepeat, repeatedKey)
			expect({ withRepeat, validateFakeOutfit(withRepeat).isOutfitValid }).toEqual({ withRepeat, false })

			local filledItemSlot = FAKE_POOL[repeatedKey].itemSlot
			if filledItemSlot == "accessory" then
				return
			end
			for _, fakeStylingItem in FakeStylingItemPool.FAKE_STYLING_ITEMS do
				if
					fakeStylingItem.itemSlot == filledItemSlot
					and fakeStylingItem.stylingItemKey ~= repeatedKey
					and FAKE_AVAILABLE_SET[fakeStylingItem.stylingItemKey]
				then
					local withSecondItem = table.clone(outfitStylingItemKeys)
					table.insert(withSecondItem, fakeStylingItem.stylingItemKey)
					expect({ withSecondItem, validateFakeOutfit(withSecondItem).isOutfitValid }).toEqual({
						withSecondItem,
						false,
					})
				end
			end
		end)
	end)

	it("the stored-outfit resolver wears a fully available valid outfit unchanged", function()
		SeededRandomTrials.runSeededRandomTrials(RANDOM_TRIAL_COUNT, function(seededRandomNumberGenerator)
			local outfitStylingItemKeys =
				RandomValidOutfitGenerator.generateRandomValidOutfitStylingItemKeys(seededRandomNumberGenerator)
			local resolution = StoredLobbyOutfitResolver.resolveStoredLobbyOutfitStylingItemKeys(
				outfitStylingItemKeys,
				FAKE_POOL,
				FAKE_AVAILABLE_SET
			)
			expect(resolution.wearableStylingItemKeys).toEqual(outfitStylingItemKeys)
			expect(resolution.stylingItemKeysToRemoveFromSave).toEqual({})
		end)
	end)

	it("scores stay in range and stars and rewards agree with the §1.6 table", function()
		SeededRandomTrials.runSeededRandomTrials(RANDOM_TRIAL_COUNT, function(seededRandomNumberGenerator)
			local outfitStylingItemKeys =
				RandomValidOutfitGenerator.generateRandomValidOutfitStylingItemKeys(seededRandomNumberGenerator)
			local theme = seededRandomNumberGenerator.pickRandomListElement(ThemeCatalog.THEMES)
			local roundBonusRule = pickRandomRoundBonusRule(seededRandomNumberGenerator, theme)
			local breakdown =
				OutfitScoreCalculator.calculateOutfitScore(outfitStylingItemKeys, FAKE_POOL, theme, roundBonusRule)
			local context = { outfitStylingItemKeys, theme.themeId, roundBonusRule }

			local function expectHolds(invariantName: string, doesInvariantHold: boolean)
				expect({ invariantName, context, doesInvariantHold }).toEqual({ invariantName, context, true })
			end

			expectHolds(
				"score is a whole number 0..100",
				breakdown.outfitScore == math.floor(breakdown.outfitScore)
					and breakdown.outfitScore >= 0
					and breakdown.outfitScore <= 100
			)
			expectHolds("theme match 0..50", breakdown.themeMatchPoints >= 0 and breakdown.themeMatchPoints <= 50)
			expectHolds(
				"completeness is 20 x filled / 6",
				math.abs(breakdown.completenessPoints - 20 * breakdown.filledScoringSlotCount / 6) < 1e-9
			)
			expectHolds("completeness 0..20", breakdown.completenessPoints >= 0 and breakdown.completenessPoints <= 20)
			expectHolds("harmony is 0, 8 or 15", table.find({ 0, 8, 15 }, breakdown.colorHarmonyPoints) ~= nil)
			expectHolds("bonus is 0, 5, 10 or 15", table.find({ 0, 5, 10, 15 }, breakdown.roundBonusPoints) ~= nil)
			local componentSum = breakdown.themeMatchPoints
				+ breakdown.completenessPoints
				+ breakdown.colorHarmonyPoints
				+ breakdown.roundBonusPoints
			expectHolds("score is the floored component sum", breakdown.outfitScore == math.floor(componentSum + 1e-9))

			if #outfitStylingItemKeys == 0 then
				expectHolds(
					"empty outfit gets nothing",
					breakdown.starCount == 0
						and breakdown.starCoinsGranted == 0
						and breakdown.fanCountGained == 0
						and breakdown.outfitScore == 0
				)
			else
				local expectedStarReward = expectedStarRewardForScore(breakdown.outfitScore)
				expect({ context, breakdown.starCount, breakdown.starCoinsGranted, breakdown.fanCountGained }).toEqual({
					context,
					expectedStarReward[1],
					expectedStarReward[2],
					expectedStarReward[3],
				})
			end
		end)
	end)

	it("filling an empty scoring slot never lowers completeness (it raises it by 20/6)", function()
		SeededRandomTrials.runSeededRandomTrials(RANDOM_TRIAL_COUNT, function(seededRandomNumberGenerator)
			local outfitStylingItemKeys =
				RandomValidOutfitGenerator.generateRandomValidOutfitStylingItemKeys(seededRandomNumberGenerator)
			local theme = seededRandomNumberGenerator.pickRandomListElement(ThemeCatalog.THEMES)
			local roundBonusRule = pickRandomRoundBonusRule(seededRandomNumberGenerator, theme)
			local breakdownBefore =
				OutfitScoreCalculator.calculateOutfitScore(outfitStylingItemKeys, FAKE_POOL, theme, roundBonusRule)

			local emptyScoringSlots = {}
			for _, scoringSlot in OutfitScoreCalculator.SCORING_SLOTS do
				if breakdownBefore.bestItemMatchByScoringSlot[scoringSlot] == nil then
					table.insert(emptyScoringSlots, scoringSlot)
				end
			end
			if #emptyScoringSlots == 0 then
				return
			end
			local filledScoringSlot = seededRandomNumberGenerator.pickRandomListElement(emptyScoringSlots)
			local fillingItemSlot = seededRandomNumberGenerator.pickRandomListElement(
				RandomValidOutfitGenerator.ITEM_SLOTS_THAT_CAN_FILL_EMPTY_SCORING_SLOT[filledScoringSlot]
			)
			local filledOutfit = table.clone(outfitStylingItemKeys)
			table.insert(
				filledOutfit,
				RandomValidOutfitGenerator.pickRandomAvailableStylingItemKeyForItemSlot(
					seededRandomNumberGenerator,
					fillingItemSlot
				)
			)
			expect({ filledOutfit, validateFakeOutfit(filledOutfit).isOutfitValid }).toEqual({ filledOutfit, true })
			local breakdownAfter =
				OutfitScoreCalculator.calculateOutfitScore(filledOutfit, FAKE_POOL, theme, roundBonusRule)
			expect({ filledOutfit, breakdownAfter.completenessPoints >= breakdownBefore.completenessPoints }).toEqual({
				filledOutfit,
				true,
			})
			expect(breakdownAfter.completenessPoints - breakdownBefore.completenessPoints).toBeCloseTo(20 / 6, 1e-9)
			expect(breakdownAfter.themeMatchPoints >= breakdownBefore.themeMatchPoints).toBeTrue()
		end)
	end)
end)

describe("every subset of the largest valid outfit", function()
	it("is valid (exhaustive, 4096 subsets)", function()
		local largestValidOutfit = {
			"asset_9000001",
			"asset_9000011",
			"asset_9000021",
			"bundle_9000041",
			"asset_9000051",
			"asset_9000052",
			"asset_9000053",
			"asset_9000061",
			"asset_9000071",
			"asset_9000081",
			"asset_9000091",
			"asset_9000095",
		}
		for subsetMask = 0, 2 ^ #largestValidOutfit - 1 do
			local subsetKeys = {}
			for keyPosition, outfitStylingItemKey in largestValidOutfit do
				if bit32.extract(subsetMask, keyPosition - 1) == 1 then
					table.insert(subsetKeys, outfitStylingItemKey)
				end
			end
			if not validateFakeOutfit(subsetKeys).isOutfitValid then
				expect(subsetKeys).toBe("a valid outfit")
			end
		end
	end)
end)
