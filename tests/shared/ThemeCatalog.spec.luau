-- Theme catalog rules (development spec §1.3, §1.4), checked for every entry.

local UnitTestFramework = require("../Support/UnitTestFramework")
local ThemeCatalog = require("../../src/shared/ThemeCatalog")
local StylingTagVocabulary = require("../../src/shared/StylingTagVocabulary")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function describeTheme(theme): string
	return "theme " .. tostring(theme.themeId)
end

describe("ThemeCatalog", function()
	it("contains y2k_pop exactly as in spec §1.3", function()
		expect(ThemeCatalog.findThemeByThemeId("y2k_pop")).toEqual({
			themeId = "y2k_pop",
			themeDisplayName = "Y2K Pop",
			styleTagWeights = { y2k = 1.0, cute = 0.6, streetwear = 0.4 },
		})
	end)

	it("holds about 30 themes (spec §9 item 7)", function()
		expect(#ThemeCatalog.THEMES >= 25 and #ThemeCatalog.THEMES <= 35).toBeTrue()
	end)

	it("every theme id is unique snake_case and every display name is non-empty", function()
		local seenThemeIdSet = {}
		for _, theme in ThemeCatalog.THEMES do
			expect({ describeTheme(theme), string.match(theme.themeId, "^[a-z][a-z0-9]*[_a-z0-9]*$") ~= nil }).toEqual({
				describeTheme(theme),
				true,
			})
			expect({ describeTheme(theme), seenThemeIdSet[theme.themeId] }).toEqual({ describeTheme(theme), nil })
			seenThemeIdSet[theme.themeId] = true
			expect(type(theme.themeDisplayName) == "string" and #theme.themeDisplayName > 0).toBeTrue()
		end
	end)

	it("every weight uses a vocabulary style tag and lies in (0, 1]", function()
		for _, theme in ThemeCatalog.THEMES do
			for styleTag, styleTagWeight in theme.styleTagWeights do
				local label = describeTheme(theme) .. " tag " .. tostring(styleTag)
				expect({ label, StylingTagVocabulary.isKnownStyleTag(styleTag) }).toEqual({ label, true })
				expect({ label, type(styleTagWeight) == "number" and styleTagWeight > 0 and styleTagWeight <= 1 }).toEqual({
					label,
					true,
				})
			end
		end
	end)

	it("every theme has at least one weight of 1.0", function()
		for _, theme in ThemeCatalog.THEMES do
			local hasFullWeight = false
			for _, styleTagWeight in theme.styleTagWeights do
				if styleTagWeight == 1 then
					hasFullWeight = true
				end
			end
			expect({ describeTheme(theme), hasFullWeight }).toEqual({ describeTheme(theme), true })
		end
	end)

	it("every theme leaves at least one style tag unweighted, so a StyleBonus (§1.4) is always possible", function()
		for _, theme in ThemeCatalog.THEMES do
			local unweightedStyleTagCount = 0
			for _, styleTag in StylingTagVocabulary.STYLE_TAGS do
				if theme.styleTagWeights[styleTag] == nil then
					unweightedStyleTagCount += 1
				end
			end
			expect({ describeTheme(theme), unweightedStyleTagCount > 0 }).toEqual({ describeTheme(theme), true })
		end
	end)

	it("is frozen, theme by theme", function()
		expect(table.isfrozen(ThemeCatalog)).toBeTrue()
		expect(table.isfrozen(ThemeCatalog.THEMES)).toBeTrue()
		for _, theme in ThemeCatalog.THEMES do
			expect(table.isfrozen(theme)).toBeTrue()
			expect(table.isfrozen(theme.styleTagWeights)).toBeTrue()
		end
	end)
end)

describe("ThemeCatalog lookups", function()
	it("finds every theme by id and returns nil for unknown or non-string ids", function()
		for _, theme in ThemeCatalog.THEMES do
			expect(ThemeCatalog.findThemeByThemeId(theme.themeId)).toBe(theme)
		end
		expect(ThemeCatalog.findThemeByThemeId("Y2K_POP")).toBeNil()
		expect(ThemeCatalog.findThemeByThemeId("no_such_theme")).toBeNil()
		expect(ThemeCatalog.findThemeByThemeId(1)).toBeNil()
		expect(ThemeCatalog.findThemeByThemeId(nil)).toBeNil()
	end)

	it("gives an unlisted style tag weight 0 (§1.3)", function()
		local y2kPopTheme = assert(ThemeCatalog.findThemeByThemeId("y2k_pop"))
		expect(ThemeCatalog.getStyleTagWeightForTheme(y2kPopTheme, "cute")).toBe(0.6)
		expect(ThemeCatalog.getStyleTagWeightForTheme(y2kPopTheme, "gothic")).toBe(0)
	end)
end)
