-- StageEntranceEffectLookCatalog (development spec §0.2 "Stage and entrance effects ... generated in
-- code", §1.7, §2.4): how each StageEntranceEffect cosmetic of CosmeticCatalog looks, as plain data.
-- The effect plays once around a participant when they are placed on stage at the start of
-- Showcase. StageEntranceEffectPiecePlanner turns a look into timed piece positions; the server
-- builds the pieces from plain parts and an optional light (RobloxStageEntranceEffectPlayer). No
-- image, texture, particle emitter or asset is used.
--
-- 🔴 Gentle by construction: a piece fades in and out once; a light rises once and fades once;
-- nothing blinks, strobes or repeats (tests/shared/CosmeticPresentationCatalog.spec.luau checks the
-- limits below for every look).
-- Pure data: no Roblox-specific interface is used. Colours are { r, g, b } with whole numbers 0-255.
--
-- StageEntranceEffectLook = {   frozen
--   stageEntranceEffectCosmeticId: string,
--   pieceMotion: one of PIECE_MOTIONS (see StageEntranceEffectPiecePlanner for each path),
--   pieceShape: "Ball" | "Block" | "Cylinder"   (Enum.PartType item names),
--   pieceMaterial: "Neon" | "SmoothPlastic" | "Glass" | "Foil"   (Enum.Material item names),
--   pieceSizeStuds: { x, y, z }   each 0.05-12; a Cylinder stands upright, so its x (the length
--                                 of a Roblox cylinder) is its height,
--   pieceColorRgbs: { Rgb }       1-6 colours, used in turn,
--   pieceTransparency: number     0-0.8 while visible,
--   pieceCount: number            1-40,
--   effectDurationSeconds: number 2-6,
--   light: { lightKind: "PointLight" | "SpotLight", colorRgb, peakBrightness (0.5-3),
--            rangeStuds (4-24), heightAboveFeetStuds (0-14) }?   nil = no light
-- }
--
-- PUBLIC API
--   StageEntranceEffectLookCatalog.PIECE_MOTIONS   frozen list of motion names
--   StageEntranceEffectLookCatalog.STAGE_ENTRANCE_EFFECT_LOOKS   frozen list, catalog order
--   StageEntranceEffectLookCatalog.findStageEntranceEffectLook(cosmeticId: any) -> StageEntranceEffectLook?

local StageEntranceEffectLookCatalog = {}

StageEntranceEffectLookCatalog.PIECE_MOTIONS = table.freeze({
	"BurstOutward",
	"FallFromAbove",
	"RiseFromFloor",
	"SwirlAround",
	"SweepAcross",
	"DescendFromSky",
	"RiseAsCurtain",
})

local function rgb(r: number, g: number, b: number)
	return table.freeze({ r = r, g = g, b = b })
end

local function size(x: number, y: number, z: number)
	return table.freeze({ x = x, y = y, z = z })
end

local function defineStageEntranceEffectLook(look)
	look.pieceColorRgbs = table.freeze(look.pieceColorRgbs)
	if look.light then
		look.light = table.freeze(look.light)
	end
	return table.freeze(look)
end

local CONFETTI_COLORS = { rgb(255, 110, 160), rgb(255, 220, 90), rgb(110, 200, 255), rgb(150, 230, 140) }
local FIREWORK_COLORS = { rgb(255, 120, 120), rgb(255, 210, 100), rgb(140, 220, 255), rgb(220, 150, 255) }

StageEntranceEffectLookCatalog.STAGE_ENTRANCE_EFFECT_LOOKS = table.freeze({
	defineStageEntranceEffectLook({
		stageEntranceEffectCosmeticId = "entrance_confetti_pop",
		pieceMotion = "BurstOutward",
		pieceShape = "Block",
		pieceMaterial = "SmoothPlastic",
		pieceSizeStuds = size(0.4, 0.1, 0.25),
		pieceColorRgbs = CONFETTI_COLORS,
		pieceTransparency = 0,
		pieceCount = 24,
		effectDurationSeconds = 3,
	}),
	defineStageEntranceEffectLook({
		stageEntranceEffectCosmeticId = "entrance_soft_spotlight",
		pieceMotion = "RiseAsCurtain",
		pieceShape = "Cylinder",
		pieceMaterial = "Neon",
		pieceSizeStuds = size(9, 3.5, 3.5),
		pieceColorRgbs = { rgb(255, 240, 210) },
		pieceTransparency = 0.8,
		pieceCount = 1,
		effectDurationSeconds = 4,
		light = {
			lightKind = "SpotLight",
			colorRgb = rgb(255, 240, 210),
			peakBrightness = 2,
			rangeStuds = 18,
			heightAboveFeetStuds = 12,
		},
	}),
	defineStageEntranceEffectLook({
		stageEntranceEffectCosmeticId = "entrance_sparkle_trail",
		pieceMotion = "SwirlAround",
		pieceShape = "Ball",
		pieceMaterial = "Neon",
		pieceSizeStuds = size(0.3, 0.3, 0.3),
		pieceColorRgbs = { rgb(255, 255, 255), rgb(255, 230, 150) },
		pieceTransparency = 0.1,
		pieceCount = 12,
		effectDurationSeconds = 3.5,
	}),
	defineStageEntranceEffectLook({
		stageEntranceEffectCosmeticId = "entrance_bubble_burst",
		pieceMotion = "RiseFromFloor",
		pieceShape = "Ball",
		pieceMaterial = "Glass",
		pieceSizeStuds = size(0.8, 0.8, 0.8),
		pieceColorRgbs = { rgb(170, 225, 255), rgb(210, 245, 255) },
		pieceTransparency = 0.5,
		pieceCount = 14,
		effectDurationSeconds = 3.5,
	}),
	defineStageEntranceEffectLook({
		stageEntranceEffectCosmeticId = "entrance_heart_shower",
		pieceMotion = "FallFromAbove",
		pieceShape = "Ball",
		pieceMaterial = "Neon",
		pieceSizeStuds = size(0.45, 0.45, 0.45),
		pieceColorRgbs = { rgb(255, 90, 140), rgb(255, 150, 190), rgb(230, 60, 110) },
		pieceTransparency = 0.1,
		pieceCount = 20,
		effectDurationSeconds = 3.5,
		light = {
			lightKind = "PointLight",
			colorRgb = rgb(255, 140, 190),
			peakBrightness = 1,
			rangeStuds = 10,
			heightAboveFeetStuds = 4,
		},
	}),
	defineStageEntranceEffectLook({
		stageEntranceEffectCosmeticId = "entrance_star_burst",
		pieceMotion = "BurstOutward",
		pieceShape = "Block",
		pieceMaterial = "Neon",
		pieceSizeStuds = size(0.35, 0.35, 0.35),
		pieceColorRgbs = { rgb(255, 230, 110), rgb(255, 250, 200) },
		pieceTransparency = 0,
		pieceCount = 16,
		effectDurationSeconds = 3,
		light = {
			lightKind = "PointLight",
			colorRgb = rgb(255, 230, 140),
			peakBrightness = 1.5,
			rangeStuds = 12,
			heightAboveFeetStuds = 3,
		},
	}),
	defineStageEntranceEffectLook({
		stageEntranceEffectCosmeticId = "entrance_petal_swirl",
		pieceMotion = "SwirlAround",
		pieceShape = "Block",
		pieceMaterial = "SmoothPlastic",
		pieceSizeStuds = size(0.45, 0.06, 0.3),
		pieceColorRgbs = { rgb(255, 190, 215), rgb(255, 235, 240), rgb(250, 160, 200) },
		pieceTransparency = 0,
		pieceCount = 18,
		effectDurationSeconds = 4,
	}),
	defineStageEntranceEffectLook({
		stageEntranceEffectCosmeticId = "entrance_fireworks_finale",
		pieceMotion = "BurstOutward",
		pieceShape = "Ball",
		pieceMaterial = "Neon",
		pieceSizeStuds = size(0.3, 0.3, 0.3),
		pieceColorRgbs = FIREWORK_COLORS,
		pieceTransparency = 0,
		pieceCount = 36,
		effectDurationSeconds = 4,
		light = {
			lightKind = "PointLight",
			colorRgb = rgb(255, 220, 180),
			peakBrightness = 2,
			rangeStuds = 16,
			heightAboveFeetStuds = 8,
		},
	}),
	defineStageEntranceEffectLook({
		stageEntranceEffectCosmeticId = "entrance_neon_laser_sweep",
		pieceMotion = "SweepAcross",
		pieceShape = "Block",
		pieceMaterial = "Neon",
		pieceSizeStuds = size(0.2, 10, 0.2),
		pieceColorRgbs = { rgb(90, 240, 255), rgb(255, 90, 220) },
		pieceTransparency = 0.3,
		pieceCount = 4,
		effectDurationSeconds = 4,
	}),
	defineStageEntranceEffectLook({
		stageEntranceEffectCosmeticId = "entrance_golden_glitter_rain",
		pieceMotion = "FallFromAbove",
		pieceShape = "Block",
		pieceMaterial = "Foil",
		pieceSizeStuds = size(0.2, 0.2, 0.2),
		pieceColorRgbs = { rgb(240, 200, 80), rgb(255, 230, 140) },
		pieceTransparency = 0,
		pieceCount = 40,
		effectDurationSeconds = 4,
		light = {
			lightKind = "PointLight",
			colorRgb = rgb(255, 210, 120),
			peakBrightness = 1,
			rangeStuds = 10,
			heightAboveFeetStuds = 6,
		},
	}),
	defineStageEntranceEffectLook({
		stageEntranceEffectCosmeticId = "entrance_comet_arrival",
		pieceMotion = "DescendFromSky",
		pieceShape = "Ball",
		pieceMaterial = "Neon",
		pieceSizeStuds = size(0.9, 0.9, 0.9),
		pieceColorRgbs = { rgb(255, 250, 230), rgb(180, 220, 255), rgb(140, 190, 255) },
		pieceTransparency = 0,
		pieceCount = 8,
		effectDurationSeconds = 3,
		light = {
			lightKind = "PointLight",
			colorRgb = rgb(200, 225, 255),
			peakBrightness = 1.5,
			rangeStuds = 12,
			heightAboveFeetStuds = 2,
		},
	}),
	defineStageEntranceEffectLook({
		stageEntranceEffectCosmeticId = "entrance_aurora_curtain",
		pieceMotion = "RiseAsCurtain",
		pieceShape = "Block",
		pieceMaterial = "Neon",
		pieceSizeStuds = size(1.6, 7, 0.2),
		pieceColorRgbs = { rgb(80, 230, 170), rgb(80, 180, 230), rgb(170, 110, 230) },
		pieceTransparency = 0.6,
		pieceCount = 6,
		effectDurationSeconds = 5,
	}),
	defineStageEntranceEffectLook({
		stageEntranceEffectCosmeticId = "entrance_starfall_cascade",
		pieceMotion = "FallFromAbove",
		pieceShape = "Ball",
		pieceMaterial = "Neon",
		pieceSizeStuds = size(0.35, 0.35, 0.35),
		pieceColorRgbs = { rgb(255, 250, 210), rgb(255, 235, 150), rgb(210, 230, 255) },
		pieceTransparency = 0,
		pieceCount = 28,
		effectDurationSeconds = 4.5,
	}),
	defineStageEntranceEffectLook({
		stageEntranceEffectCosmeticId = "entrance_spotlight_parade",
		pieceMotion = "SweepAcross",
		pieceShape = "Cylinder",
		pieceMaterial = "Neon",
		pieceSizeStuds = size(9, 1.6, 1.6),
		pieceColorRgbs = { rgb(255, 245, 220), rgb(255, 210, 240), rgb(220, 235, 255) },
		pieceTransparency = 0.75,
		pieceCount = 3,
		effectDurationSeconds = 5,
		light = {
			lightKind = "SpotLight",
			colorRgb = rgb(255, 245, 225),
			peakBrightness = 1.5,
			rangeStuds = 18,
			heightAboveFeetStuds = 12,
		},
	}),
})

local stageEntranceEffectLookByCosmeticId = {}
for _, stageEntranceEffectLook in StageEntranceEffectLookCatalog.STAGE_ENTRANCE_EFFECT_LOOKS do
	stageEntranceEffectLookByCosmeticId[stageEntranceEffectLook.stageEntranceEffectCosmeticId] = stageEntranceEffectLook
end
table.freeze(stageEntranceEffectLookByCosmeticId)

function StageEntranceEffectLookCatalog.findStageEntranceEffectLook(cosmeticId: any)
	if type(cosmeticId) ~= "string" then
		return nil
	end
	return stageEntranceEffectLookByCosmeticId[cosmeticId]
end

return table.freeze(StageEntranceEffectLookCatalog)
