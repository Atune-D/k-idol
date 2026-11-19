-- Themes a themed round can ask for (development spec §1.3).
--
-- FIRST DRAFT for the owner to review (spec §9 item 7). Only `y2k_pop` is fixed by the spec;
-- every other theme, display name and weight is a proposal.
--
-- Rules every theme follows (enforced by tests/shared/ThemeCatalog.spec.luau):
--   * `themeId` is unique snake_case; `themeDisplayName` is non-empty.
--   * `styleTagWeights` only uses style tags from StylingTagVocabulary.
--   * Every weight is in (0, 1], and at least one tag has weight 1.0.
--   * A style tag that is not listed has weight 0 for that theme.
--   * At least one style tag is left unweighted, so a StyleBonus (§1.4) is always possible.
--   * No real brand, idol, group, artist or song names (spec §5.2).
-- Pure data: no Roblox-specific interface is used.

export type Theme = {
	themeId: string,
	themeDisplayName: string,
	styleTagWeights: { [string]: number },
}

local function defineTheme(themeId: string, themeDisplayName: string, styleTagWeights: { [string]: number }): Theme
	return table.freeze({
		themeId = themeId,
		themeDisplayName = themeDisplayName,
		styleTagWeights = table.freeze(styleTagWeights),
	})
end

local ThemeCatalog = {}

ThemeCatalog.THEMES = table.freeze({
	defineTheme("y2k_pop", "Y2K Pop", { y2k = 1.0, cute = 0.6, streetwear = 0.4 }),
	defineTheme("street_style_stage", "Street Style Stage", { streetwear = 1.0, sporty = 0.5, punk = 0.4 }),
	defineTheme("sweet_candy_shop", "Sweet Candy Shop", { cute = 1.0, y2k = 0.5, fantasy = 0.3 }),
	defineTheme("red_carpet_gala", "Red Carpet Gala", { elegant = 1.0, formal = 0.8 }),
	defineTheme("midnight_gothic", "Midnight Gothic", { gothic = 1.0, punk = 0.5, elegant = 0.3 }),
	defineTheme("game_day_cheer", "Game Day Cheer", { sporty = 1.0, preppy = 0.5, cute = 0.4 }),
	defineTheme("vintage_diner", "Vintage Diner", { retro = 1.0, cute = 0.4, preppy = 0.4 }),
	defineTheme("fairy_tale_ball", "Fairy Tale Ball", { fantasy = 1.0, elegant = 0.6, cute = 0.4 }),
	defineTheme("sunny_beach_party", "Sunny Beach Party", { beach = 1.0, sporty = 0.4, cute = 0.4 }),
	defineTheme("award_night", "Award Night", { formal = 1.0, elegant = 0.7 }),
	defineTheme("garage_band_rebel", "Garage Band Rebel", { punk = 1.0, gothic = 0.5, streetwear = 0.4 }),
	defineTheme("campus_classic", "Campus Classic", { preppy = 1.0, formal = 0.4, retro = 0.3 }),
	defineTheme("disco_night", "Disco Night", { retro = 1.0, y2k = 0.5, elegant = 0.3 }),
	defineTheme("pastel_dream", "Pastel Dream", { cute = 1.0, fantasy = 0.6, elegant = 0.3 }),
	defineTheme("neon_city_night", "Neon City Night", { y2k = 1.0, streetwear = 0.7, punk = 0.3 }),
	defineTheme("royal_palace", "Royal Palace", { elegant = 1.0, fantasy = 0.6, formal = 0.6 }),
	defineTheme("dance_practice_room", "Dance Practice Room", { sporty = 1.0, streetwear = 0.8 }),
	defineTheme("haunted_mansion_party", "Haunted Mansion Party", { gothic = 1.0, fantasy = 0.6, retro = 0.3 }),
	defineTheme("tropical_vacation", "Tropical Vacation", { beach = 1.0, retro = 0.3, cute = 0.3 }),
	defineTheme("business_class", "Business Class", { formal = 1.0, preppy = 0.6, elegant = 0.5 }),
	defineTheme("skate_park", "Skate Park", { streetwear = 1.0, punk = 0.6, sporty = 0.5 }),
	defineTheme("magical_girl", "Magical Girl", { fantasy = 1.0, cute = 0.8, y2k = 0.3 }),
	defineTheme("retro_arcade", "Retro Arcade", { retro = 1.0, y2k = 0.6, streetwear = 0.4 }),
	defineTheme("snowy_holiday", "Snowy Holiday", { elegant = 1.0, cute = 0.6, fantasy = 0.5 }),
	defineTheme("rock_festival", "Rock Festival", { punk = 1.0, streetwear = 0.5, retro = 0.4 }),
	defineTheme("garden_tea_party", "Garden Tea Party", { elegant = 1.0, cute = 0.6, preppy = 0.5 }),
	defineTheme("surf_and_sun", "Surf and Sun", { beach = 1.0, sporty = 0.7 }),
	defineTheme("dark_academia", "Dark Academia", { preppy = 1.0, gothic = 0.6, retro = 0.5 }),
	defineTheme("space_explorer", "Space Explorer", { fantasy = 1.0, y2k = 0.6, sporty = 0.3 }),
	defineTheme("music_video_shoot", "Music Video Shoot", { y2k = 1.0, elegant = 0.5, streetwear = 0.5 }),
})

local themeByThemeId: { [string]: Theme } = {}
for _, theme in ThemeCatalog.THEMES do
	themeByThemeId[theme.themeId] = theme
end
table.freeze(themeByThemeId)

-- Returns the theme with this id, or nil for an unknown id (including non-string values).
function ThemeCatalog.findThemeByThemeId(themeId: any): Theme?
	if type(themeId) ~= "string" then
		return nil
	end
	return themeByThemeId[themeId]
end

-- The weight a theme gives one style tag; 0 when the tag is not listed (spec §1.3).
function ThemeCatalog.getStyleTagWeightForTheme(theme: Theme, styleTag: string): number
	return theme.styleTagWeights[styleTag] or 0
end

return table.freeze(ThemeCatalog)
