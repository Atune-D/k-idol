-- CosmeticPresentationCatalog, NameplateStyleLookCatalog and StageEntranceEffectLookCatalog
-- (development spec §0.2, §1.7): every catalog cosmetic has a presentation, no look names a
-- cosmetic that is not in the catalog (or one of another kind), every look stays within its
-- documented limits, and effects stay gentle.

local UnitTestFramework = require("../Support/UnitTestFramework")
local CosmeticCatalog = require("../../src/shared/CosmeticCatalog")
local CosmeticPresentationCatalog = require("../../src/shared/CosmeticPresentationCatalog")
local NameplateStyleLookCatalog = require("../../src/shared/NameplateStyleLookCatalog")
local StageEntranceEffectLookCatalog = require("../../src/shared/StageEntranceEffectLookCatalog")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function isWholeNumberInRange(candidate: any, smallest: number, largest: number): boolean
	return type(candidate) == "number"
		and candidate == math.floor(candidate)
		and candidate >= smallest
		and candidate <= largest
end

local function isNumberInRange(candidate: any, smallest: number, largest: number): boolean
	return type(candidate) == "number" and candidate == candidate and candidate >= smallest and candidate <= largest
end

local function isRgb(candidate: any): boolean
	return type(candidate) == "table"
		and isWholeNumberInRange(candidate.r, 0, 255)
		and isWholeNumberInRange(candidate.g, 0, 255)
		and isWholeNumberInRange(candidate.b, 0, 255)
end

-- Returns the ids of `cosmeticCatalogEntries` that have no presentation (the check the catalog
-- test runs, also run against a catalog with an extra cosmetic to see it fail).
local function listCosmeticIdsWithoutPresentation(cosmeticCatalogEntries, cosmeticCatalog)
	local missingCosmeticIds = {}
	for _, cosmetic in cosmeticCatalogEntries do
		local presentation = CosmeticPresentationCatalog.findCosmeticPresentation(cosmetic.cosmeticId, cosmeticCatalog)
		if presentation == nil or presentation.cosmeticKind ~= cosmetic.cosmeticKind then
			table.insert(missingCosmeticIds, cosmetic.cosmeticId)
		end
	end
	return missingCosmeticIds
end

-- Returns every look id that is not a catalog cosmetic of the look's kind.
local function listLookCosmeticIdsNotInCatalog(lookCosmeticIdsByKind, cosmeticCatalog)
	local strayCosmeticIds = {}
	for cosmeticKind, lookCosmeticIds in lookCosmeticIdsByKind do
		for _, lookCosmeticId in lookCosmeticIds do
			local cosmetic = cosmeticCatalog.findCosmeticByCosmeticId(lookCosmeticId)
			if cosmetic == nil or cosmetic.cosmeticKind ~= cosmeticKind then
				table.insert(strayCosmeticIds, lookCosmeticId)
			end
		end
	end
	return strayCosmeticIds
end

local function buildCatalogWith(extraCosmetic)
	return {
		findCosmeticByCosmeticId = function(cosmeticId)
			if cosmeticId == extraCosmetic.cosmeticId then
				return extraCosmetic
			end
			return CosmeticCatalog.findCosmeticByCosmeticId(cosmeticId)
		end,
	}
end

describe("CosmeticPresentationCatalog coverage", function()
	it("has a presentation of the right kind for every cosmetic of CosmeticCatalog", function()
		expect(listCosmeticIdsWithoutPresentation(CosmeticCatalog.COSMETICS, CosmeticCatalog)).toEqual({})
	end)

	it("names no cosmetic that is not in the catalog, or that is of another kind", function()
		expect(
			listLookCosmeticIdsNotInCatalog(CosmeticPresentationCatalog.listLookCosmeticIdsByKind(), CosmeticCatalog)
		).toEqual({})
	end)

	it("has exactly one look per catalog cosmetic of each look kind (no duplicates)", function()
		local lookCosmeticIdsByKind = CosmeticPresentationCatalog.listLookCosmeticIdsByKind()
		for _, cosmeticKind in { "NameplateStyle", "StageEntranceEffect" } do
			local catalogIds = {}
			for _, cosmetic in CosmeticCatalog.listCosmeticsOfKind(cosmeticKind) do
				table.insert(catalogIds, cosmetic.cosmeticId)
			end
			local lookIds = table.clone(lookCosmeticIdsByKind[cosmeticKind])
			table.sort(catalogIds)
			table.sort(lookIds)
			expect(lookIds).toEqual(catalogIds)
		end
	end)

	it("detects a catalog cosmetic without a look (the coverage check can fail)", function()
		local extraNameplate = table.freeze({
			cosmeticId = "nameplate_not_drawn_yet",
			cosmeticKind = "NameplateStyle",
			cosmeticDisplayName = "Not Drawn Yet",
			starCoinPrice = 300,
		})
		local entries = table.clone(CosmeticCatalog.COSMETICS)
		table.insert(entries, extraNameplate)
		expect(listCosmeticIdsWithoutPresentation(entries, buildCatalogWith(extraNameplate))).toEqual({
			"nameplate_not_drawn_yet",
		})
	end)

	it("detects a look that names a cosmetic missing from the catalog or of another kind", function()
		local lookCosmeticIdsByKind = CosmeticPresentationCatalog.listLookCosmeticIdsByKind()
		table.insert(lookCosmeticIdsByKind.NameplateStyle, "nameplate_removed_from_catalog")
		table.insert(lookCosmeticIdsByKind.StageEntranceEffect, "title_rising_star")
		expect(listLookCosmeticIdsNotInCatalog(lookCosmeticIdsByKind, CosmeticCatalog)).toEqual({
			"nameplate_removed_from_catalog",
			"title_rising_star",
		})
	end)
end)

describe("CosmeticPresentationCatalog lookups", function()
	it("gives a title its display name as text", function()
		for _, title in CosmeticCatalog.listCosmeticsOfKind("Title") do
			local presentation = CosmeticPresentationCatalog.findCosmeticPresentation(title.cosmeticId)
			expect(presentation.cosmeticKind).toBe("Title")
			expect(presentation.titleText).toBe(title.cosmeticDisplayName)
		end
		expect(CosmeticPresentationCatalog.findCosmeticPresentation("title_rising_star").titleText).toBe("Rising Star")
	end)

	it("gives each nameplate style and entrance effect the look with its own id", function()
		for _, cosmetic in CosmeticCatalog.COSMETICS do
			local presentation = CosmeticPresentationCatalog.findCosmeticPresentation(cosmetic.cosmeticId)
			if cosmetic.cosmeticKind == "NameplateStyle" then
				expect(presentation.nameplateStyleLook.nameplateStyleCosmeticId).toBe(cosmetic.cosmeticId)
			elseif cosmetic.cosmeticKind == "StageEntranceEffect" then
				expect(presentation.stageEntranceEffectLook.stageEntranceEffectCosmeticId).toBe(cosmetic.cosmeticId)
			end
		end
	end)

	it("answers nil for anything that is not a catalog cosmetic", function()
		for _, unknownId in { "nameplate_unknown", "", 42, true, {}, "starter_groove" } do
			expect(CosmeticPresentationCatalog.findCosmeticPresentation(unknownId)).toBeNil()
		end
		expect(CosmeticPresentationCatalog.findCosmeticPresentation(nil)).toBeNil()
	end)

	it("answers nil for a catalog cosmetic of a kind that has no presentation", function()
		local oddCosmetic = table.freeze({
			cosmeticId = "photo_filter_sepia",
			cosmeticKind = "PhotoFilter",
			cosmeticDisplayName = "Sepia",
			starCoinPrice = 300,
		})
		expect(
			CosmeticPresentationCatalog.findCosmeticPresentation("photo_filter_sepia", buildCatalogWith(oddCosmetic))
		).toBeNil()
	end)

	it("returns frozen presentations", function()
		expect(table.isfrozen(CosmeticPresentationCatalog.findCosmeticPresentation("title_superstar"))).toBeTrue()
		expect(table.isfrozen(CosmeticPresentationCatalog.findCosmeticPresentation("nameplate_neon_glow"))).toBeTrue()
	end)
end)

describe("NameplateStyleLookCatalog limits", function()
	it("keeps every nameplate look within its documented limits", function()
		for _, look in NameplateStyleLookCatalog.NAMEPLATE_STYLE_LOOKS do
			expect(isRgb(look.plateColorRgb)).toBeTrue()
			expect(isRgb(look.nameTextColorRgb)).toBeTrue()
			expect(isRgb(look.nameTextOutlineColorRgb)).toBeTrue()
			expect(isNumberInRange(look.plateTransparency, 0, 0.5)).toBeTrue()
			expect(isNumberInRange(look.plateGradientRotationDegrees, 0, 359)).toBeTrue()
			expect(isWholeNumberInRange(look.cornerRadiusPixels, 0, 16)).toBeTrue()
			if look.plateGradientColorRgbs ~= nil then
				expect(#look.plateGradientColorRgbs >= 2 and #look.plateGradientColorRgbs <= 4).toBeTrue()
				for _, colorRgb in look.plateGradientColorRgbs do
					expect(isRgb(colorRgb)).toBeTrue()
				end
			end
			if look.frameLineColorRgb == nil then
				expect(look.frameLineThicknessPixels).toBe(0)
			else
				expect(isRgb(look.frameLineColorRgb)).toBeTrue()
				expect(isWholeNumberInRange(look.frameLineThicknessPixels, 1, 4)).toBeTrue()
			end
			if look.sparkleDotColorRgb == nil then
				expect(look.sparkleDotCount).toBe(0)
			else
				expect(isRgb(look.sparkleDotColorRgb)).toBeTrue()
				expect(isWholeNumberInRange(look.sparkleDotCount, 1, 8)).toBeTrue()
			end
			expect(table.isfrozen(look)).toBeTrue()
		end
	end)

	it("gives every nameplate style its own look", function()
		local seenLookTexts = {}
		for _, look in NameplateStyleLookCatalog.NAMEPLATE_STYLE_LOOKS do
			local lookText = tostring(look.plateColorRgb.r)
				.. "/"
				.. tostring(look.plateColorRgb.g)
				.. "/"
				.. tostring(look.plateColorRgb.b)
				.. "/"
				.. tostring(look.plateGradientColorRgbs and #look.plateGradientColorRgbs)
				.. "/"
				.. tostring(look.frameLineColorRgb and look.frameLineColorRgb.r)
				.. "/"
				.. tostring(look.sparkleDotCount)
			expect(seenLookTexts[lookText]).toBeNil()
			seenLookTexts[lookText] = true
		end
	end)
end)

local ALLOWED_PIECE_SHAPES = { Ball = true, Block = true, Cylinder = true }
local ALLOWED_PIECE_MATERIALS = { Neon = true, SmoothPlastic = true, Glass = true, Foil = true }

describe("StageEntranceEffectLookCatalog limits (gentle effects)", function()
	it("keeps every entrance effect look within its documented limits", function()
		for _, look in StageEntranceEffectLookCatalog.STAGE_ENTRANCE_EFFECT_LOOKS do
			expect(table.find(StageEntranceEffectLookCatalog.PIECE_MOTIONS, look.pieceMotion) ~= nil).toBeTrue()
			expect(ALLOWED_PIECE_SHAPES[look.pieceShape]).toBeTrue()
			expect(ALLOWED_PIECE_MATERIALS[look.pieceMaterial]).toBeTrue()
			for _, axisName in { "x", "y", "z" } do
				expect(isNumberInRange(look.pieceSizeStuds[axisName], 0.05, 12)).toBeTrue()
			end
			expect(#look.pieceColorRgbs >= 1 and #look.pieceColorRgbs <= 6).toBeTrue()
			for _, colorRgb in look.pieceColorRgbs do
				expect(isRgb(colorRgb)).toBeTrue()
			end
			expect(isNumberInRange(look.pieceTransparency, 0, 0.8)).toBeTrue()
			expect(isWholeNumberInRange(look.pieceCount, 1, 40)).toBeTrue()
			expect(isNumberInRange(look.effectDurationSeconds, 2, 6)).toBeTrue()
			if look.light ~= nil then
				expect(look.light.lightKind == "PointLight" or look.light.lightKind == "SpotLight").toBeTrue()
				expect(isRgb(look.light.colorRgb)).toBeTrue()
				expect(isNumberInRange(look.light.peakBrightness, 0.5, 3)).toBeTrue()
				expect(isNumberInRange(look.light.rangeStuds, 4, 24)).toBeTrue()
				expect(isNumberInRange(look.light.heightAboveFeetStuds, 0, 14)).toBeTrue()
			end
			expect(table.isfrozen(look)).toBeTrue()
		end
	end)

	it("uses every piece motion at least once", function()
		local usedMotionSet = {}
		for _, look in StageEntranceEffectLookCatalog.STAGE_ENTRANCE_EFFECT_LOOKS do
			usedMotionSet[look.pieceMotion] = true
		end
		for _, pieceMotion in StageEntranceEffectLookCatalog.PIECE_MOTIONS do
			expect(usedMotionSet[pieceMotion]).toBeTrue()
		end
	end)
end)
