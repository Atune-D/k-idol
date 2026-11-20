-- Cosmetics a player can buy with Star Coins (development spec §0.2, §1.7). Cosmetics are generated
-- in code, so they can be produced in bulk and keep the shop larger than an active player's
-- earnings (spec §0.2). Buying, owning, equipping and drawing them are other modules.
--
-- FIRST DRAFT for the owner to review. Only `title_rising_star` is fixed by the spec (§1.7);
-- every other cosmetic, display name and price is a proposal.
--
-- Pricing guide (spec §1.7, starting values): a themed round pays about 60 Star Coins on average.
-- This draft uses three price points: cheap = 5 rounds (300), standard = 15 rounds (900),
-- premium = 50 rounds (3000).
--
-- Rules every cosmetic follows (enforced by tests/shared/CosmeticCatalog.spec.luau):
--   * `cosmeticId` is unique snake_case and starts with its kind's prefix:
--     `title_` for Title, `nameplate_` for NameplateStyle, `entrance_` for StageEntranceEffect.
--   * `cosmeticKind` is one of COSMETIC_KINDS (the keys of `equippedCosmeticIdByKind`, §1.10).
--   * `cosmeticDisplayName` is non-empty, trimmed, single-spaced, free of control characters, at
--     most 32 characters (a draft limit) and unique across the catalog ignoring letter case.
--   * `starCoinPrice` is a whole number close to one of the three guide price points (within 15%),
--     and each price point is used; nothing is free, so every cosmetic must be bought (a new save
--     owns none, §1.10).
--   * Every kind has entries, and the whole catalog costs more than a heavily active player
--     earning the top round reward can earn in three weeks (§0.2).
-- Not checkable by a test, reviewed by the owner: no real brand, idol, group, artist or song
-- names (spec §5.2).
-- Pure data: no Roblox-specific interface is used.

export type CosmeticKind = "Title" | "NameplateStyle" | "StageEntranceEffect"

export type Cosmetic = {
	cosmeticId: string,
	cosmeticKind: CosmeticKind,
	cosmeticDisplayName: string,
	starCoinPrice: number,
}

local AVERAGE_STAR_COINS_PER_THEMED_ROUND = 60
local CHEAP_STAR_COIN_PRICE = 5 * AVERAGE_STAR_COINS_PER_THEMED_ROUND
local STANDARD_STAR_COIN_PRICE = 15 * AVERAGE_STAR_COINS_PER_THEMED_ROUND
local PREMIUM_STAR_COIN_PRICE = 50 * AVERAGE_STAR_COINS_PER_THEMED_ROUND

local function defineCosmetic(
	cosmeticId: string,
	cosmeticKind: CosmeticKind,
	cosmeticDisplayName: string,
	starCoinPrice: number
): Cosmetic
	return table.freeze({
		cosmeticId = cosmeticId,
		cosmeticKind = cosmeticKind,
		cosmeticDisplayName = cosmeticDisplayName,
		starCoinPrice = starCoinPrice,
	})
end

local CosmeticCatalog = {}

-- Every cosmetic kind, in the order spec §1.7 lists them.
CosmeticCatalog.COSMETIC_KINDS = table.freeze({ "Title", "NameplateStyle", "StageEntranceEffect" })

CosmeticCatalog.COSMETICS = table.freeze({
	-- Where each kind is shown or played is not defined by the spec yet; the modules that draw
	-- cosmetics decide that later with the owner.

	-- Titles.
	defineCosmetic("title_rising_star", "Title", "Rising Star", CHEAP_STAR_COIN_PRICE), -- spec §1.7
	defineCosmetic("title_fresh_face", "Title", "Fresh Face", CHEAP_STAR_COIN_PRICE),
	defineCosmetic("title_stage_rookie", "Title", "Stage Rookie", CHEAP_STAR_COIN_PRICE),
	defineCosmetic("title_style_explorer", "Title", "Style Explorer", CHEAP_STAR_COIN_PRICE),
	defineCosmetic("title_color_lover", "Title", "Color Lover", CHEAP_STAR_COIN_PRICE),
	defineCosmetic("title_dance_floor_regular", "Title", "Dance Floor Regular", CHEAP_STAR_COIN_PRICE),
	defineCosmetic("title_runway_ready", "Title", "Runway Ready", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("title_trendsetter", "Title", "Trendsetter", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("title_spotlight_seeker", "Title", "Spotlight Seeker", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("title_encore_favorite", "Title", "Encore Favorite", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("title_crowd_pleaser", "Title", "Crowd Pleaser", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("title_center_stage", "Title", "Center Stage", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("title_fashion_icon", "Title", "Fashion Icon", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("title_showstopper", "Title", "Showstopper", PREMIUM_STAR_COIN_PRICE),
	defineCosmetic("title_living_legend", "Title", "Living Legend", PREMIUM_STAR_COIN_PRICE),
	defineCosmetic("title_superstar", "Title", "Superstar", PREMIUM_STAR_COIN_PRICE),
	defineCosmetic("title_dazzling_headliner", "Title", "Dazzling Headliner", PREMIUM_STAR_COIN_PRICE),

	-- Nameplate styles.
	defineCosmetic("nameplate_bubblegum_pink", "NameplateStyle", "Bubblegum Pink", CHEAP_STAR_COIN_PRICE),
	defineCosmetic("nameplate_mint_fresh", "NameplateStyle", "Mint Fresh", CHEAP_STAR_COIN_PRICE),
	defineCosmetic("nameplate_sky_blue", "NameplateStyle", "Sky Blue", CHEAP_STAR_COIN_PRICE),
	defineCosmetic("nameplate_lemon_pop", "NameplateStyle", "Lemon Pop", CHEAP_STAR_COIN_PRICE),
	defineCosmetic("nameplate_sunset_gradient", "NameplateStyle", "Sunset Gradient", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("nameplate_ocean_wave", "NameplateStyle", "Ocean Wave", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("nameplate_glitter_sparkle", "NameplateStyle", "Glitter Sparkle", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("nameplate_neon_glow", "NameplateStyle", "Neon Glow", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("nameplate_starlit_night", "NameplateStyle", "Starlit Night", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("nameplate_crystal_frame", "NameplateStyle", "Crystal Frame", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("nameplate_holographic_shine", "NameplateStyle", "Holographic Shine", PREMIUM_STAR_COIN_PRICE),
	defineCosmetic("nameplate_golden_frame", "NameplateStyle", "Golden Frame", PREMIUM_STAR_COIN_PRICE),
	defineCosmetic("nameplate_rainbow_shift", "NameplateStyle", "Rainbow Shift", PREMIUM_STAR_COIN_PRICE),
	defineCosmetic("nameplate_aurora_shimmer", "NameplateStyle", "Aurora Shimmer", PREMIUM_STAR_COIN_PRICE),
	defineCosmetic("nameplate_diamond_frame", "NameplateStyle", "Diamond Frame", PREMIUM_STAR_COIN_PRICE),
	defineCosmetic("nameplate_galaxy_swirl", "NameplateStyle", "Galaxy Swirl", PREMIUM_STAR_COIN_PRICE),

	-- Stage entrance effects.
	defineCosmetic("entrance_confetti_pop", "StageEntranceEffect", "Confetti Pop", CHEAP_STAR_COIN_PRICE),
	defineCosmetic("entrance_soft_spotlight", "StageEntranceEffect", "Soft Spotlight", CHEAP_STAR_COIN_PRICE),
	defineCosmetic("entrance_sparkle_trail", "StageEntranceEffect", "Sparkle Trail", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("entrance_bubble_burst", "StageEntranceEffect", "Bubble Burst", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("entrance_heart_shower", "StageEntranceEffect", "Heart Shower", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("entrance_star_burst", "StageEntranceEffect", "Star Burst", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("entrance_petal_swirl", "StageEntranceEffect", "Petal Swirl", STANDARD_STAR_COIN_PRICE),
	defineCosmetic("entrance_fireworks_finale", "StageEntranceEffect", "Fireworks Finale", PREMIUM_STAR_COIN_PRICE),
	defineCosmetic("entrance_neon_laser_sweep", "StageEntranceEffect", "Neon Laser Sweep", PREMIUM_STAR_COIN_PRICE),
	defineCosmetic(
		"entrance_golden_glitter_rain",
		"StageEntranceEffect",
		"Golden Glitter Rain",
		PREMIUM_STAR_COIN_PRICE
	),
	defineCosmetic("entrance_comet_arrival", "StageEntranceEffect", "Comet Arrival", PREMIUM_STAR_COIN_PRICE),
	defineCosmetic("entrance_aurora_curtain", "StageEntranceEffect", "Aurora Curtain", PREMIUM_STAR_COIN_PRICE),
	defineCosmetic("entrance_starfall_cascade", "StageEntranceEffect", "Starfall Cascade", PREMIUM_STAR_COIN_PRICE),
	defineCosmetic("entrance_spotlight_parade", "StageEntranceEffect", "Spotlight Parade", PREMIUM_STAR_COIN_PRICE),
})

local cosmeticByCosmeticId: { [string]: Cosmetic } = {}
local cosmeticsByCosmeticKind: { [string]: { Cosmetic } } = {}
for _, cosmeticKind in CosmeticCatalog.COSMETIC_KINDS do
	cosmeticsByCosmeticKind[cosmeticKind] = {}
end
for _, cosmetic in CosmeticCatalog.COSMETICS do
	cosmeticByCosmeticId[cosmetic.cosmeticId] = cosmetic
	local cosmeticsOfSameKind = cosmeticsByCosmeticKind[cosmetic.cosmeticKind]
	if cosmeticsOfSameKind ~= nil then
		table.insert(cosmeticsOfSameKind, cosmetic)
	end
end
table.freeze(cosmeticByCosmeticId)
for _, cosmeticsOfSameKind in cosmeticsByCosmeticKind do
	table.freeze(cosmeticsOfSameKind)
end
table.freeze(cosmeticsByCosmeticKind)

-- Returns the cosmetic with this id, or nil for an unknown id (including non-string values), so
-- it can check an untrusted `cosmeticId` from a device request directly (§2.8 `UnknownCosmetic`).
-- The type check is defensive: indexing the string-keyed map with a non-string already gives nil.
function CosmeticCatalog.findCosmeticByCosmeticId(cosmeticId: any): Cosmetic?
	if type(cosmeticId) ~= "string" then
		return nil
	end
	return cosmeticByCosmeticId[cosmeticId]
end

-- True only for exactly one of COSMETIC_KINDS; accepts any value (including nil and non-strings).
function CosmeticCatalog.isKnownCosmeticKind(candidateCosmeticKind: any): boolean
	return type(candidateCosmeticKind) == "string" and cosmeticsByCosmeticKind[candidateCosmeticKind] ~= nil
end

-- Every cosmetic of one kind, in catalog order, as a fresh list the caller may change.
-- An unknown kind (including non-string values) gives an empty list.
function CosmeticCatalog.listCosmeticsOfKind(cosmeticKind: any): { Cosmetic }
	if not CosmeticCatalog.isKnownCosmeticKind(cosmeticKind) then
		return {}
	end
	return table.clone(cosmeticsByCosmeticKind[cosmeticKind])
end

return table.freeze(CosmeticCatalog)
