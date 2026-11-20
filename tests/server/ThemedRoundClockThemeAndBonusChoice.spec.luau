-- ThemedRoundClock theme choice and round bonus rule choice (development spec §1.4 🔴, §2.1,
-- §6.2 "Unit: round clock"). Randomized through SeededRandomTrials, so a failure prints its seed.

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local StylingTagVocabulary = require("../../src/shared/StylingTagVocabulary")
local ThemeCatalog = require("../../src/shared/ThemeCatalog")
local ThemedRoundClock = require("../../src/server/ThemedRoundClock")
local ThemedRoundClockTestHarness = require("./ThemedRoundClockTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function listRoundThemeIds(harness): { string }
	local roundThemeIds = {}
	for _, roundStartState in harness.listObservedRoundStartStates() do
		table.insert(roundThemeIds, roundStartState.themeId)
	end
	return roundThemeIds
end

-- Raises (through expect) unless the rule obeys §1.4 for `theme`: exactly the field of its kind,
-- a known non-neutral colour for a ColorBonus, a known style tag of weight 0 for a StyleBonus.
local function expectRoundBonusRuleToObeyConstraintsForTheme(roundBonusRule, theme)
	local ruleLabel = string.format(
		"theme %s, %s %s / %s",
		theme.themeId,
		tostring(roundBonusRule.roundBonusKind),
		tostring(roundBonusRule.bonusColorTag),
		tostring(roundBonusRule.bonusStyleTag)
	)
	local isRuleAllowed
	if roundBonusRule.roundBonusKind == "ColorBonus" then
		isRuleAllowed = roundBonusRule.bonusStyleTag == nil
			and StylingTagVocabulary.isKnownColorTag(roundBonusRule.bonusColorTag)
			and not StylingTagVocabulary.isNeutralColorTag(roundBonusRule.bonusColorTag)
	elseif roundBonusRule.roundBonusKind == "StyleBonus" then
		isRuleAllowed = roundBonusRule.bonusColorTag == nil
			and StylingTagVocabulary.isKnownStyleTag(roundBonusRule.bonusStyleTag)
			and ThemeCatalog.getStyleTagWeightForTheme(theme, roundBonusRule.bonusStyleTag) == 0
	else
		isRuleAllowed = false
	end
	expect({ ruleLabel, isRuleAllowed }).toEqual({ ruleLabel, true })
end

describe("ThemedRoundClock theme choice", function()
	it("never repeats a theme of the real catalog within the last 5 rounds", function()
		SeededRandomTrials.runSeededRandomTrials(10, function(seededRandomNumberGenerator)
			local harness = ThemedRoundClockTestHarness.runRoundClockForWholeRounds(60, seededRandomNumberGenerator)
			local roundThemeIds = listRoundThemeIds(harness)
			expect(#roundThemeIds).toBe(60)
			for roundIndex, themeId in roundThemeIds do
				expect(ThemeCatalog.findThemeByThemeId(themeId) ~= nil).toBeTrue()
				for earlierRoundIndex = math.max(1, roundIndex - 5), roundIndex - 1 do
					local repeatLabel = string.format("rounds %d and %d", earlierRoundIndex, roundIndex)
					expect({ repeatLabel, roundThemeIds[earlierRoundIndex] ~= themeId }).toEqual({ repeatLabel, true })
				end
			end
		end)
	end)

	it("eventually uses every theme of the real catalog", function()
		SeededRandomTrials.runSeededRandomTrials(2, function(seededRandomNumberGenerator)
			local harness = ThemedRoundClockTestHarness.runRoundClockForWholeRounds(600, seededRandomNumberGenerator)
			local usedThemeIdSet = {}
			for _, themeId in listRoundThemeIds(harness) do
				usedThemeIdSet[themeId] = true
			end
			for _, theme in ThemeCatalog.THEMES do
				expect({ theme.themeId, usedThemeIdSet[theme.themeId] == true }).toEqual({ theme.themeId, true })
			end
		end)
	end)

	it("with exactly 6 themes, every 6 consecutive rounds use all six (the only choice left)", function()
		SeededRandomTrials.runSeededRandomTrials(10, function(seededRandomNumberGenerator)
			local fixtureThemes = ThemedRoundClockTestHarness.createFixtureThemeCatalogThemes(6)
			local harness =
				ThemedRoundClockTestHarness.runRoundClockForWholeRounds(30, seededRandomNumberGenerator, fixtureThemes)
			local roundThemeIds = listRoundThemeIds(harness)
			expect(#roundThemeIds).toBe(30)
			for windowStartIndex = 1, #roundThemeIds - 5 do
				local windowThemeIdSet = {}
				local distinctThemeCount = 0
				for roundIndex = windowStartIndex, windowStartIndex + 5 do
					local themeId = roundThemeIds[roundIndex]
					expect(string.sub(themeId, 1, #"fixture_theme_")).toBe("fixture_theme_")
					if not windowThemeIdSet[themeId] then
						windowThemeIdSet[themeId] = true
						distinctThemeCount += 1
					end
				end
				expect({ windowStartIndex, distinctThemeCount }).toEqual({ windowStartIndex, 6 })
			end
		end)
	end)

	it("refuses a catalog too small to honour the 5-round exclusion (5 themes or fewer)", function()
		for _, tooSmallThemeCount in { 0, 1, 5 } do
			expect(function()
				ThemedRoundClockTestHarness.createRoundClockWithFakes({
					themeCatalogThemes = ThemedRoundClockTestHarness.createFixtureThemeCatalogThemes(
						tooSmallThemeCount
					),
				})
			end).toThrow("more than 5 are needed")
		end
	end)

	it("refuses a catalog with a duplicate themeId", function()
		local fixtureThemes = ThemedRoundClockTestHarness.createFixtureThemeCatalogThemes(6)
		table.insert(fixtureThemes, fixtureThemes[1])
		expect(function()
			ThemedRoundClockTestHarness.createRoundClockWithFakes({ themeCatalogThemes = fixtureThemes })
		end).toThrow("not unique")
	end)

	it("refuses a catalog with a theme that weights every style tag (no StyleBonus possible)", function()
		local fixtureThemes = ThemedRoundClockTestHarness.createFixtureThemeCatalogThemes(6)
		local everyStyleTagWeights = {}
		for _, styleTag in StylingTagVocabulary.STYLE_TAGS do
			everyStyleTagWeights[styleTag] = 0.5
		end
		table.insert(fixtureThemes, {
			themeId = "fixture_theme_weighting_everything",
			themeDisplayName = "Everything",
			styleTagWeights = everyStyleTagWeights,
		})
		expect(function()
			ThemedRoundClockTestHarness.createRoundClockWithFakes({ themeCatalogThemes = fixtureThemes })
		end).toThrow("weights every style tag")
	end)
end)

describe("ThemedRoundClock round bonus rule choice", function()
	it("obeys §1.4 for every theme of the real catalog, and every allowed tag and both kinds occur", function()
		SeededRandomTrials.runSeededRandomTrials(2, function(seededRandomNumberGenerator)
			for _, theme in ThemeCatalog.THEMES do
				local chosenTagCountByKindAndTag = {}
				for _ = 1, 600 do
					local roundBonusRule =
						ThemedRoundClock.chooseRoundBonusRuleForTheme(theme, seededRandomNumberGenerator)
					expectRoundBonusRuleToObeyConstraintsForTheme(roundBonusRule, theme)
					local kindAndTag = roundBonusRule.roundBonusKind
						.. ":"
						.. tostring(roundBonusRule.bonusColorTag or roundBonusRule.bonusStyleTag)
					chosenTagCountByKindAndTag[kindAndTag] = (chosenTagCountByKindAndTag[kindAndTag] or 0) + 1
				end
				for _, colorTag in StylingTagVocabulary.COLOR_TAGS do
					if not StylingTagVocabulary.isNeutralColorTag(colorTag) then
						local kindAndTag = "ColorBonus:" .. colorTag
						expect({ theme.themeId, kindAndTag, chosenTagCountByKindAndTag[kindAndTag] ~= nil }).toEqual({
							theme.themeId,
							kindAndTag,
							true,
						})
					end
				end
				for _, styleTag in StylingTagVocabulary.STYLE_TAGS do
					if ThemeCatalog.getStyleTagWeightForTheme(theme, styleTag) == 0 then
						local kindAndTag = "StyleBonus:" .. styleTag
						expect({ theme.themeId, kindAndTag, chosenTagCountByKindAndTag[kindAndTag] ~= nil }).toEqual({
							theme.themeId,
							kindAndTag,
							true,
						})
					end
				end
			end
		end)
	end)

	it("picks each bonus kind about half of the time", function()
		SeededRandomTrials.runSeededRandomTrials(3, function(seededRandomNumberGenerator)
			local colorBonusCount = 0
			local drawCount = 2000
			local y2kPopTheme = ThemeCatalog.findThemeByThemeId("y2k_pop")
			for _ = 1, drawCount do
				local roundBonusRule =
					ThemedRoundClock.chooseRoundBonusRuleForTheme(y2kPopTheme :: any, seededRandomNumberGenerator)
				if roundBonusRule.roundBonusKind == "ColorBonus" then
					colorBonusCount += 1
				end
			end
			expect({ colorBonusCount, colorBonusCount > 0.4 * drawCount and colorBonusCount < 0.6 * drawCount }).toEqual({
				colorBonusCount,
				true,
			})
		end)
	end)

	it("gives every round of a running clock an allowed rule for its theme, with both kinds occurring", function()
		SeededRandomTrials.runSeededRandomTrials(5, function(seededRandomNumberGenerator)
			local harness = ThemedRoundClockTestHarness.runRoundClockForWholeRounds(100, seededRandomNumberGenerator)
			local roundCountByBonusKind = { ColorBonus = 0, StyleBonus = 0 }
			for _, roundStartState in harness.listObservedRoundStartStates() do
				local roundTheme = ThemeCatalog.findThemeByThemeId(roundStartState.themeId)
				expectRoundBonusRuleToObeyConstraintsForTheme(roundStartState.roundBonusRule, roundTheme)
				roundCountByBonusKind[roundStartState.roundBonusRule.roundBonusKind] += 1
			end
			expect(roundCountByBonusKind.ColorBonus > 0).toBeTrue()
			expect(roundCountByBonusKind.StyleBonus > 0).toBeTrue()
		end)
	end)

	it("takes all its randomness from the injected generator (same seed, same rounds)", function()
		SeededRandomTrials.runSeededRandomTrials(1, function(seededRandomNumberGenerator)
			local sharedSeed = seededRandomNumberGenerator.nextWholeNumberInRange(1, 2_000_000_000)
			local function describeRoundsForSeed(randomSeed: number): { string }
				local harness = ThemedRoundClockTestHarness.runRoundClockForWholeRounds(
					40,
					SeededRandomTrials.createSeededRandomNumberGenerator(randomSeed)
				)
				local roundDescriptions = {}
				for _, roundStartState in harness.listObservedRoundStartStates() do
					local roundBonusRule = roundStartState.roundBonusRule
					table.insert(
						roundDescriptions,
						string.format(
							"%s %s %s",
							roundStartState.themeId,
							roundBonusRule.roundBonusKind,
							tostring(roundBonusRule.bonusColorTag or roundBonusRule.bonusStyleTag)
						)
					)
				end
				return roundDescriptions
			end
			expect(describeRoundsForSeed(sharedSeed)).toEqual(describeRoundsForSeed(sharedSeed))
		end)
	end)

	it("raises when the injected generator returns a number outside the asked range", function()
		local outOfRangeGenerator = {
			nextWholeNumberInRange = function(_, largestWholeNumber: number)
				return largestWholeNumber + 1
			end,
		}
		expect(function()
			ThemedRoundClock.chooseRoundBonusRuleForTheme(ThemeCatalog.THEMES[1], outOfRangeGenerator :: any)
		end).toThrow("outside")
	end)
end)
