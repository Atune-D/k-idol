-- NameplateStyleLookCatalog (development spec §0.2 "Effects, titles and nameplates are generated in
-- code", §1.7): how each NameplateStyle cosmetic of CosmeticCatalog looks, as plain data. The
-- server draws the plate above a character's head from this (RobloxCharacterOverheadCosmeticDisplay);
-- a device may draw a shop preview from the same data. No image or asset is used: a plate is a
-- rounded rectangle with a colour or a colour gradient, an optional frame line and optional
-- sparkle dots, with the player's display name on it.
--
-- 🔴 Gentle by construction: every look is still (nothing moves, blinks or changes colour over
-- time). Names that suggest motion ("Rainbow Shift", "Galaxy Swirl", "Ocean Wave") are shown by the
-- colours and the angle of their gradient.
-- Pure data: no Roblox-specific interface is used. Colours are { r, g, b } with whole numbers 0-255.
--
-- NameplateStyleLook = {   frozen
--   nameplateStyleCosmeticId: string,
--   plateColorRgb: Rgb,                  the plate colour when there is no gradient
--   plateGradientColorRgbs: { Rgb }?,    2 to 4 colours spread evenly left to right; when set the
--                                        plate is drawn white under the gradient so the colours show
--                                        exactly
--   plateGradientRotationDegrees: number,   0-359, clockwise from left-to-right
--   plateTransparency: number,           0-0.5
--   nameTextColorRgb: Rgb,
--   nameTextOutlineColorRgb: Rgb,
--   frameLineColorRgb: Rgb?,             nil = no frame line
--   frameLineThicknessPixels: number,    0 when there is no frame line, else 1-4
--   cornerRadiusPixels: number,          0-16
--   sparkleDotColorRgb: Rgb?,            nil = no sparkle dots
--   sparkleDotCount: number,             0 when there are no dots, else 1-8
-- }
--
-- PUBLIC API
--   NameplateStyleLookCatalog.NAMEPLATE_STYLE_LOOKS   frozen list, catalog order
--   NameplateStyleLookCatalog.findNameplateStyleLook(cosmeticId: any) -> NameplateStyleLook?

export type Rgb = { r: number, g: number, b: number }

local function rgb(r: number, g: number, b: number): Rgb
	return table.freeze({ r = r, g = g, b = b })
end

local WHITE = rgb(255, 255, 255)
local INK = rgb(40, 30, 60)

local function defineNameplateStyleLook(look)
	look.plateTransparency = look.plateTransparency or 0.1
	look.plateGradientRotationDegrees = look.plateGradientRotationDegrees or 0
	look.frameLineThicknessPixels = if look.frameLineColorRgb then look.frameLineThicknessPixels or 2 else 0
	look.cornerRadiusPixels = look.cornerRadiusPixels or 10
	look.sparkleDotCount = if look.sparkleDotColorRgb then look.sparkleDotCount or 4 else 0
	if look.plateGradientColorRgbs then
		look.plateGradientColorRgbs = table.freeze(look.plateGradientColorRgbs)
	end
	return table.freeze(look)
end

local NameplateStyleLookCatalog = {}

NameplateStyleLookCatalog.NAMEPLATE_STYLE_LOOKS = table.freeze({
	defineNameplateStyleLook({
		nameplateStyleCosmeticId = "nameplate_bubblegum_pink",
		plateColorRgb = rgb(255, 170, 210),
		nameTextColorRgb = WHITE,
		nameTextOutlineColorRgb = rgb(200, 70, 140),
	}),
	defineNameplateStyleLook({
		nameplateStyleCosmeticId = "nameplate_mint_fresh",
		plateColorRgb = rgb(170, 240, 210),
		nameTextColorRgb = rgb(20, 90, 70),
		nameTextOutlineColorRgb = WHITE,
	}),
	defineNameplateStyleLook({
		nameplateStyleCosmeticId = "nameplate_sky_blue",
		plateColorRgb = rgb(150, 205, 255),
		nameTextColorRgb = WHITE,
		nameTextOutlineColorRgb = rgb(40, 100, 180),
	}),
	defineNameplateStyleLook({
		nameplateStyleCosmeticId = "nameplate_lemon_pop",
		plateColorRgb = rgb(255, 238, 120),
		nameTextColorRgb = rgb(110, 80, 0),
		nameTextOutlineColorRgb = WHITE,
	}),
	defineNameplateStyleLook({
		nameplateStyleCosmeticId = "nameplate_sunset_gradient",
		plateColorRgb = rgb(255, 150, 100),
		plateGradientColorRgbs = { rgb(255, 200, 90), rgb(255, 120, 110), rgb(190, 90, 170) },
		nameTextColorRgb = WHITE,
		nameTextOutlineColorRgb = rgb(120, 40, 70),
	}),
	defineNameplateStyleLook({
		nameplateStyleCosmeticId = "nameplate_ocean_wave",
		plateColorRgb = rgb(60, 140, 200),
		plateGradientColorRgbs = { rgb(30, 90, 170), rgb(70, 190, 220), rgb(30, 90, 170) },
		plateGradientRotationDegrees = 20,
		nameTextColorRgb = WHITE,
		nameTextOutlineColorRgb = rgb(10, 40, 90),
	}),
	defineNameplateStyleLook({
		nameplateStyleCosmeticId = "nameplate_glitter_sparkle",
		plateColorRgb = rgb(240, 200, 240),
		plateGradientColorRgbs = { rgb(250, 220, 250), rgb(220, 180, 245) },
		nameTextColorRgb = rgb(120, 50, 140),
		nameTextOutlineColorRgb = WHITE,
		sparkleDotColorRgb = WHITE,
		sparkleDotCount = 6,
	}),
	defineNameplateStyleLook({
		nameplateStyleCosmeticId = "nameplate_neon_glow",
		plateColorRgb = rgb(25, 20, 45),
		nameTextColorRgb = rgb(120, 255, 240),
		nameTextOutlineColorRgb = rgb(255, 60, 200),
		frameLineColorRgb = rgb(120, 255, 240),
		frameLineThicknessPixels = 3,
	}),
	defineNameplateStyleLook({
		nameplateStyleCosmeticId = "nameplate_starlit_night",
		plateColorRgb = rgb(20, 25, 70),
		plateGradientColorRgbs = { rgb(15, 15, 50), rgb(40, 50, 120) },
		plateGradientRotationDegrees = 90,
		nameTextColorRgb = rgb(255, 245, 200),
		nameTextOutlineColorRgb = rgb(10, 10, 30),
		sparkleDotColorRgb = rgb(255, 240, 170),
		sparkleDotCount = 5,
	}),
	defineNameplateStyleLook({
		nameplateStyleCosmeticId = "nameplate_crystal_frame",
		plateColorRgb = rgb(215, 240, 255),
		plateTransparency = 0.35,
		nameTextColorRgb = rgb(40, 80, 120),
		nameTextOutlineColorRgb = WHITE,
		frameLineColorRgb = rgb(240, 250, 255),
		frameLineThicknessPixels = 3,
	}),
	defineNameplateStyleLook({
		nameplateStyleCosmeticId = "nameplate_holographic_shine",
		plateColorRgb = rgb(200, 220, 255),
		plateGradientColorRgbs = { rgb(190, 255, 240), rgb(210, 200, 255), rgb(255, 200, 235), rgb(200, 240, 255) },
		plateGradientRotationDegrees = 35,
		nameTextColorRgb = INK,
		nameTextOutlineColorRgb = WHITE,
		frameLineColorRgb = WHITE,
		frameLineThicknessPixels = 2,
	}),
	defineNameplateStyleLook({
		nameplateStyleCosmeticId = "nameplate_golden_frame",
		plateColorRgb = rgb(60, 40, 20),
		nameTextColorRgb = rgb(255, 225, 130),
		nameTextOutlineColorRgb = rgb(40, 25, 5),
		frameLineColorRgb = rgb(235, 190, 70),
		frameLineThicknessPixels = 4,
		cornerRadiusPixels = 6,
	}),
	defineNameplateStyleLook({
		nameplateStyleCosmeticId = "nameplate_rainbow_shift",
		plateColorRgb = rgb(255, 200, 200),
		plateGradientColorRgbs = { rgb(255, 120, 120), rgb(255, 220, 110), rgb(120, 220, 140), rgb(130, 160, 255) },
		nameTextColorRgb = WHITE,
		nameTextOutlineColorRgb = INK,
	}),
	defineNameplateStyleLook({
		nameplateStyleCosmeticId = "nameplate_aurora_shimmer",
		plateColorRgb = rgb(60, 160, 150),
		plateGradientColorRgbs = { rgb(60, 200, 150), rgb(70, 150, 210), rgb(150, 90, 200) },
		plateGradientRotationDegrees = 160,
		nameTextColorRgb = WHITE,
		nameTextOutlineColorRgb = rgb(20, 40, 60),
		sparkleDotColorRgb = rgb(210, 255, 240),
		sparkleDotCount = 3,
	}),
	defineNameplateStyleLook({
		nameplateStyleCosmeticId = "nameplate_diamond_frame",
		plateColorRgb = rgb(235, 245, 255),
		nameTextColorRgb = rgb(60, 90, 140),
		nameTextOutlineColorRgb = WHITE,
		frameLineColorRgb = rgb(170, 210, 255),
		frameLineThicknessPixels = 4,
		cornerRadiusPixels = 2,
		sparkleDotColorRgb = WHITE,
		sparkleDotCount = 4,
	}),
	defineNameplateStyleLook({
		nameplateStyleCosmeticId = "nameplate_galaxy_swirl",
		plateColorRgb = rgb(70, 40, 120),
		plateGradientColorRgbs = { rgb(30, 20, 70), rgb(120, 60, 170), rgb(230, 120, 200), rgb(30, 20, 70) },
		plateGradientRotationDegrees = 315,
		nameTextColorRgb = WHITE,
		nameTextOutlineColorRgb = rgb(20, 10, 40),
		sparkleDotColorRgb = rgb(255, 230, 255),
		sparkleDotCount = 6,
	}),
})

local nameplateStyleLookByCosmeticId = {}
for _, nameplateStyleLook in NameplateStyleLookCatalog.NAMEPLATE_STYLE_LOOKS do
	nameplateStyleLookByCosmeticId[nameplateStyleLook.nameplateStyleCosmeticId] = nameplateStyleLook
end
table.freeze(nameplateStyleLookByCosmeticId)

function NameplateStyleLookCatalog.findNameplateStyleLook(cosmeticId: any)
	if type(cosmeticId) ~= "string" then
		return nil
	end
	return nameplateStyleLookByCosmeticId[cosmeticId]
end

return table.freeze(NameplateStyleLookCatalog)
