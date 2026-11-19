-- Unit: scoring (development spec §1.4, §1.6, §6.2).

local UnitTestFramework = require("../Support/UnitTestFramework")
local OutfitScoreCalculator = require("../../src/shared/OutfitScoreCalculator")
local ThemeCatalog = require("../../src/shared/ThemeCatalog")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local Y2K_POP_THEME = assert(ThemeCatalog.findThemeByThemeId("y2k_pop"))
local PINK_COLOR_BONUS = table.freeze({ roundBonusKind = "ColorBonus", bonusColorTag = "pink" })
local RETRO_STYLE_BONUS = table.freeze({ roundBonusKind = "StyleBonus", bonusStyleTag = "retro" })

-- A theme that weights every style tag 1.0 makes every item a perfect match. It is built here
-- rather than taken from the catalog, so the maximum can be reached on purpose.
local EVERY_STYLE_PERFECT_THEME = table.freeze({
	themeId = "test_every_style_perfect",
	themeDisplayName = "Test: every style perfect",
	styleTagWeights = table.freeze({
		y2k = 1,
		streetwear = 1,
		cute = 1,
		elegant = 1,
		gothic = 1,
		sporty = 1,
		retro = 1,
		fantasy = 1,
		beach = 1,
		formal = 1,
		punk = 1,
		preppy = 1,
	}),
})

local function scoreFakeOutfit(outfitStylingItemKeys: { string }, theme, roundBonusRule)
	return OutfitScoreCalculator.calculateOutfitScore(
		outfitStylingItemKeys,
		FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
		theme or Y2K_POP_THEME,
		roundBonusRule or PINK_COLOR_BONUS
	)
end

local function fakeItem(stylingItemKey: string)
	return FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY[stylingItemKey]
end

describe("OutfitScoreCalculator §1.6 worked example", function()
	it("scores player 8801's Y2K Pop outfit with a pink bonus exactly as the spec computes", function()
		local breakdown = scoreFakeOutfit(FakeStylingItemPool.WORKED_EXAMPLE_STYLING_ITEM_KEYS)
		expect(breakdown.themeMatchPoints).toBeCloseTo(33.33, 0.01)
		expect(breakdown.themeMatchPoints).toBeCloseTo(50 * 4.0 / 6, 1e-9)
		expect(breakdown.completenessPoints).toBe(20)
		expect(breakdown.colorHarmonyPoints).toBe(15)
		expect(breakdown.roundBonusPoints).toBe(15)
		expect(breakdown.outfitScore).toBe(83)
		expect(breakdown.starCount).toBe(4)
		expect(breakdown.starCoinsGranted).toBe(80)
		expect(breakdown.fanCountGained).toBe(40)
	end)

	it("matches the per-slot item match table of §1.6", function()
		local breakdown = scoreFakeOutfit(FakeStylingItemPool.WORKED_EXAMPLE_STYLING_ITEM_KEYS)
		expect(breakdown.bestItemMatchByScoringSlot).toEqual({
			hair = 1.0,
			upperBody = 1.0,
			lowerBody = 0.4,
			shoes = 0.6,
			accessory = 1.0,
			makeup = 0,
		})
		expect(breakdown.filledScoringSlotCount).toBe(6)
		expect(breakdown.distinctNonNeutralColorCount).toBe(1)
		expect(breakdown.roundBonusQualifyingItemCount).toBe(3)
	end)

	it("gives the same result whatever the order of the keys", function()
		local reversedKeys = table.clone(FakeStylingItemPool.WORKED_EXAMPLE_STYLING_ITEM_KEYS)
		for leftPosition = 1, #reversedKeys // 2 do
			local rightPosition = #reversedKeys - leftPosition + 1
			reversedKeys[leftPosition], reversedKeys[rightPosition] =
				reversedKeys[rightPosition], reversedKeys[leftPosition]
		end
		expect(scoreFakeOutfit(reversedKeys)).toEqual(
			scoreFakeOutfit(FakeStylingItemPool.WORKED_EXAMPLE_STYLING_ITEM_KEYS)
		)
	end)

	it("contains every field RoundResultsPublished (§2.5) takes from scoring", function()
		local breakdown = scoreFakeOutfit(FakeStylingItemPool.WORKED_EXAMPLE_STYLING_ITEM_KEYS)
		for _, fieldName in
			{
				"outfitScore",
				"themeMatchPoints",
				"completenessPoints",
				"colorHarmonyPoints",
				"roundBonusPoints",
				"starCount",
				"starCoinsGranted",
				"fanCountGained",
			}
		do
			expect(type(breakdown[fieldName])).toBe("number")
		end
		expect(table.isfrozen(breakdown)).toBeTrue()
	end)
end)

describe("OutfitScoreCalculator item match", function()
	it("is the largest theme weight among the item's style tags, 0 if none is listed", function()
		expect(OutfitScoreCalculator.calculateItemMatchForTheme(fakeItem("asset_9000062"), Y2K_POP_THEME)).toBe(1.0) -- y2k, cute
		expect(OutfitScoreCalculator.calculateItemMatchForTheme(fakeItem("asset_9000003"), Y2K_POP_THEME)).toBe(0.6) -- cute, fantasy
		expect(OutfitScoreCalculator.calculateItemMatchForTheme(fakeItem("asset_9000012"), Y2K_POP_THEME)).toBe(0.4) -- streetwear, sporty
		expect(OutfitScoreCalculator.calculateItemMatchForTheme(fakeItem("asset_9000031"), Y2K_POP_THEME)).toBe(0) -- elegant, formal
	end)

	it("takes the best item when several feed one scoring slot", function()
		-- Accessories: retro (0) and y2k (1.0); makeup: elegant (0) and cute lips (0.6).
		local breakdown = scoreFakeOutfit({ "asset_9000052", "asset_9000051", "asset_9000061", "asset_9000071" })
		expect(breakdown.bestItemMatchByScoringSlot.accessory).toBe(1.0)
		expect(breakdown.bestItemMatchByScoringSlot.makeup).toBe(0.6)
	end)

	it("takes the best item even when it comes first in the list", function()
		local breakdown = scoreFakeOutfit({ "asset_9000051", "asset_9000052", "asset_9000071", "asset_9000061" })
		expect(breakdown.bestItemMatchByScoringSlot.accessory).toBe(1.0)
		expect(breakdown.bestItemMatchByScoringSlot.makeup).toBe(0.6)
	end)

	it("uses the best-matching tag even when it is not the item's first tag", function()
		-- Bottom 9000022 is tagged preppy (0.4) then retro (1.0); Vintage Diner weights retro 1.0.
		local vintageDinerTheme = assert(ThemeCatalog.findThemeByThemeId("vintage_diner"))
		expect(OutfitScoreCalculator.calculateItemMatchForTheme(fakeItem("asset_9000022"), vintageDinerTheme)).toBe(1.0)
	end)
end)

describe("OutfitScoreCalculator theme match points", function()
	it("is 0 at its minimum (nothing matches the theme)", function()
		local breakdown = scoreFakeOutfit({ "asset_9000031", "asset_9000061" }) -- elegant/formal dress, elegant makeup
		expect(breakdown.themeMatchPoints).toBe(0)
	end)

	it("is 50 at its maximum (six perfect slots)", function()
		local fullOutfit =
			{ "asset_9000001", "asset_9000011", "asset_9000021", "bundle_9000041", "asset_9000051", "asset_9000061" }
		expect(scoreFakeOutfit(fullOutfit, EVERY_STYLE_PERFECT_THEME).themeMatchPoints).toBe(50)
	end)

	it("counts an empty slot as 0", function()
		-- One perfect hair item: 50 x 1 / 6.
		expect(scoreFakeOutfit({ "asset_9000001" }).themeMatchPoints).toBeCloseTo(50 / 6, 1e-9)
	end)
end)

describe("OutfitScoreCalculator completeness points", function()
	it("is 20 x filled scoring slots / 6", function()
		expect(scoreFakeOutfit({ "asset_9000001" }).completenessPoints).toBeCloseTo(20 / 6, 1e-9)
		expect(scoreFakeOutfit({ "asset_9000001", "asset_9000011", "asset_9000021" }).completenessPoints).toBeCloseTo(
			10,
			1e-9
		)
	end)

	it("is 0 at its minimum and 20 at its maximum", function()
		expect(scoreFakeOutfit({}).completenessPoints).toBe(0)
		expect(scoreFakeOutfit(FakeStylingItemPool.WORKED_EXAMPLE_STYLING_ITEM_KEYS).completenessPoints).toBe(20)
	end)

	it("lets a dress fill both upperBody and lowerBody", function()
		local breakdown = scoreFakeOutfit({ "asset_9000032" }) -- cute pink dress, Y2K Pop weight 0.6
		expect(breakdown.filledScoringSlotCount).toBe(2)
		expect(breakdown.bestItemMatchByScoringSlot.upperBody).toBe(0.6)
		expect(breakdown.bestItemMatchByScoringSlot.lowerBody).toBe(0.6)
		expect(breakdown.completenessPoints).toBeCloseTo(20 * 2 / 6, 1e-9)
		expect(breakdown.themeMatchPoints).toBeCloseTo(50 * 1.2 / 6, 1e-9)
	end)

	it("lets a dress outfit reach full completeness", function()
		local dressOutfit = { "asset_9000001", "asset_9000032", "bundle_9000043", "asset_9000053", "asset_9000081" }
		expect(scoreFakeOutfit(dressOutfit).completenessPoints).toBe(20)
	end)

	it("lets a pair of shoes (one bundle) fill the shoes slot once", function()
		local breakdown = scoreFakeOutfit({ "bundle_9000041" })
		expect(breakdown.filledScoringSlotCount).toBe(1)
		expect(breakdown.completenessPoints).toBeCloseTo(20 / 6, 1e-9)
		expect(breakdown.bestItemMatchByScoringSlot.shoes).toBe(0.6)
	end)

	it("lets any of the five makeup item slots fill the makeup scoring slot", function()
		for _, makeupStylingItemKey in
			{ "asset_9000061", "asset_9000071", "asset_9000081", "asset_9000091", "asset_9000095" }
		do
			local breakdown = scoreFakeOutfit({ makeupStylingItemKey })
			expect(breakdown.filledScoringSlotCount).toBe(1)
			expect(breakdown.bestItemMatchByScoringSlot.makeup ~= nil).toBeTrue()
		end
	end)
end)

describe("OutfitScoreCalculator colour harmony points", function()
	it("is 15 for 0, 1 or 2 distinct non-neutral colours", function()
		expect(scoreFakeOutfit({ "asset_9000002" }).colorHarmonyPoints).toBe(15) -- black only: 0 colours
		expect(scoreFakeOutfit({ "asset_9000001", "asset_9000011" }).colorHarmonyPoints).toBe(15) -- pink, pink
		expect(scoreFakeOutfit({ "asset_9000001", "asset_9000012" }).colorHarmonyPoints).toBe(15) -- pink, blue
	end)

	it("is 8 for 3 distinct non-neutral colours", function()
		expect(scoreFakeOutfit({ "asset_9000001", "asset_9000012", "asset_9000022" }).colorHarmonyPoints).toBe(8)
	end)

	it("is 0 for 4 or more distinct non-neutral colours", function()
		local fourColors = { "asset_9000001", "asset_9000012", "asset_9000022", "bundle_9000042" }
		expect(scoreFakeOutfit(fourColors).colorHarmonyPoints).toBe(0)
		local fiveColors = { "asset_9000001", "asset_9000012", "asset_9000022", "bundle_9000042", "asset_9000053" }
		expect(scoreFakeOutfit(fiveColors).colorHarmonyPoints).toBe(0)
	end)

	it("ignores neutral colours (black, white, gray, beige)", function()
		-- Black hair, white top, white shoes and beige eye makeup add nothing to the three
		-- non-neutral colours green, pink and purple.
		local breakdown = scoreFakeOutfit({
			"asset_9000002",
			"asset_9000013",
			"asset_9000022",
			"bundle_9000041",
			"asset_9000051",
			"asset_9000061",
			"asset_9000053",
		})
		expect(breakdown.distinctNonNeutralColorCount).toBe(3) -- green, pink, purple
		expect(breakdown.colorHarmonyPoints).toBe(8)
	end)

	it("is 0 for an empty outfit", function()
		expect(scoreFakeOutfit({}).colorHarmonyPoints).toBe(0)
	end)
end)

describe("OutfitScoreCalculator round bonus", function()
	it("is 5 per qualifying item, at 0, 5, 10 and 15", function()
		expect(scoreFakeOutfit({ "asset_9000002" }).roundBonusPoints).toBe(0)
		expect(scoreFakeOutfit({ "asset_9000001" }).roundBonusPoints).toBe(5)
		expect(scoreFakeOutfit({ "asset_9000001", "asset_9000011" }).roundBonusPoints).toBe(10)
		expect(scoreFakeOutfit({ "asset_9000001", "asset_9000011", "asset_9000051" }).roundBonusPoints).toBe(15)
	end)

	it("counts at most 3 items (15 points maximum)", function()
		local fourPinkItems = { "asset_9000001", "asset_9000011", "asset_9000051", "asset_9000081" }
		local breakdown = scoreFakeOutfit(fourPinkItems)
		expect(breakdown.roundBonusQualifyingItemCount).toBe(4)
		expect(breakdown.roundBonusPoints).toBe(15)
	end)

	it("counts a StyleBonus by style tag", function()
		-- retro: bottom 9000022 (preppy, retro), accessory 9000052, eyebrows 9000095.
		local breakdown = scoreFakeOutfit(
			{ "asset_9000022", "asset_9000052", "asset_9000095", "asset_9000001" },
			nil,
			RETRO_STYLE_BONUS
		)
		expect(breakdown.roundBonusPoints).toBe(15)
		expect(scoreFakeOutfit({ "asset_9000022" }, nil, RETRO_STYLE_BONUS).roundBonusPoints).toBe(5)
	end)
end)

describe("OutfitScoreCalculator.doesStylingItemSatisfyRoundBonusRule (§1.4)", function()
	it("ColorBonus: true exactly when the primary colour is the bonus colour", function()
		expect(OutfitScoreCalculator.doesStylingItemSatisfyRoundBonusRule(fakeItem("asset_9000001"), PINK_COLOR_BONUS)).toBeTrue()
		expect(OutfitScoreCalculator.doesStylingItemSatisfyRoundBonusRule(fakeItem("asset_9000012"), PINK_COLOR_BONUS)).toBeFalse()
	end)

	it("StyleBonus: true when the bonus style is any one of the item's style tags", function()
		expect(OutfitScoreCalculator.doesStylingItemSatisfyRoundBonusRule(fakeItem("asset_9000022"), RETRO_STYLE_BONUS)).toBeTrue()
		expect(OutfitScoreCalculator.doesStylingItemSatisfyRoundBonusRule(fakeItem("asset_9000052"), RETRO_STYLE_BONUS)).toBeTrue()
		expect(OutfitScoreCalculator.doesStylingItemSatisfyRoundBonusRule(fakeItem("asset_9000001"), RETRO_STYLE_BONUS)).toBeFalse()
	end)

	it("a ColorBonus ignores style and a StyleBonus ignores colour", function()
		local retroColorBonus = { roundBonusKind = "ColorBonus", bonusColorTag = "retro" }
		expect(OutfitScoreCalculator.doesStylingItemSatisfyRoundBonusRule(fakeItem("asset_9000052"), retroColorBonus)).toBeFalse()
		local pinkStyleBonus = { roundBonusKind = "StyleBonus", bonusStyleTag = "pink" }
		expect(OutfitScoreCalculator.doesStylingItemSatisfyRoundBonusRule(fakeItem("asset_9000001"), pinkStyleBonus)).toBeFalse()
	end)

	it("raises for an unknown bonus kind", function()
		expect(function()
			OutfitScoreCalculator.doesStylingItemSatisfyRoundBonusRule(
				fakeItem("asset_9000001"),
				{ roundBonusKind = "SizeBonus" }
			)
		end).toThrow("unknown roundBonusKind")
	end)
end)

describe("OutfitScoreCalculator stars and rewards", function()
	local function expectStarReward(
		outfitScore: number,
		starCount: number,
		starCoinsGranted: number,
		fanCountGained: number
	)
		local starReward = OutfitScoreCalculator.determineStarRewardForOutfitScore(outfitScore)
		expect({ outfitScore, starReward.starCount, starReward.starCoinsGranted, starReward.fanCountGained }).toEqual({
			outfitScore,
			starCount,
			starCoinsGranted,
			fanCountGained,
		})
	end

	it("follows the §1.6 table at every boundary: 39/40, 59/60, 74/75, 89/90", function()
		expectStarReward(0, 1, 20, 10)
		expectStarReward(39, 1, 20, 10)
		expectStarReward(40, 2, 40, 20)
		expectStarReward(59, 2, 40, 20)
		expectStarReward(60, 3, 60, 30)
		expectStarReward(74, 3, 60, 30)
		expectStarReward(75, 4, 80, 40)
		expectStarReward(89, 4, 80, 40)
		expectStarReward(90, 5, 100, 50)
		expectStarReward(100, 5, 100, 50)
	end)

	it("gives a non-empty outfit with the lowest possible score 1 star", function()
		-- Elegant beige eye makeup under Y2K Pop with a pink bonus: theme 0, completeness 3.33,
		-- harmony 15 (no colours), bonus 0 -> 18.
		local breakdown = scoreFakeOutfit({ "asset_9000061" })
		expect(breakdown.outfitScore).toBe(18)
		expect(breakdown.starCount).toBe(1)
		expect(breakdown.starCoinsGranted).toBe(20)
		expect(breakdown.fanCountGained).toBe(10)
	end)

	it("gives an empty outfit nothing: score 0, no stars, no reward", function()
		local breakdown = scoreFakeOutfit({})
		expect(breakdown.isOutfitEmpty).toBeTrue()
		expect(breakdown.outfitScore).toBe(0)
		expect(breakdown.themeMatchPoints).toBe(0)
		expect(breakdown.completenessPoints).toBe(0)
		expect(breakdown.colorHarmonyPoints).toBe(0)
		expect(breakdown.roundBonusPoints).toBe(0)
		expect(breakdown.starCount).toBe(0)
		expect(breakdown.starCoinsGranted).toBe(0)
		expect(breakdown.fanCountGained).toBe(0)
	end)

	it("reaches 100 and 5 stars for a perfect outfit", function()
		local perfectOutfit =
			{ "asset_9000001", "asset_9000011", "asset_9000021", "bundle_9000041", "asset_9000051", "asset_9000061" }
		local breakdown = scoreFakeOutfit(perfectOutfit, EVERY_STYLE_PERFECT_THEME)
		expect(breakdown.outfitScore).toBe(100)
		expect(breakdown.starCount).toBe(5)
		expect(breakdown.starCoinsGranted).toBe(100)
		expect(breakdown.fanCountGained).toBe(50)
	end)

	it("floors the total rather than rounding it", function()
		-- Worked example is 83.33 -> 83; a single y2k pink top is 8.33 + 3.33 + 15 + 5 = 31.67 -> 31.
		expect(scoreFakeOutfit({ "asset_9000011" }).outfitScore).toBe(31)
	end)
end)

describe("OutfitScoreCalculator preconditions", function()
	it("raises for a key that is not in the pool (validate first)", function()
		expect(function()
			scoreFakeOutfit({ FakeStylingItemPool.KEY_NOT_IN_POOL })
		end).toThrow("is not in the styling item pool")
	end)
end)
