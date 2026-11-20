-- CosmeticPresentationCatalog (development spec §0.2, §1.7 "Stage effects, titles, nameplates:
-- generated in code"): what every cosmetic of CosmeticCatalog looks like when shown.
--   * Title: its text is the cosmetic's display name (shown above the character's head).
--   * NameplateStyle: a look from NameplateStyleLookCatalog (the plate with the player's name,
--     above the head).
--   * StageEntranceEffect: a look from StageEntranceEffectLookCatalog (played once when the
--     participant is placed on stage at the start of Showcase).
-- 🔴 Every catalog cosmetic must have a presentation, and no presentation may name a cosmetic
-- that is not in the catalog (or one of another kind): tests/shared/CosmeticPresentationCatalog.spec.luau
-- fails otherwise. Adding a NameplateStyle or StageEntranceEffect to CosmeticCatalog therefore
-- needs its look added here too; a Title needs nothing more.
-- Pure data and pure functions: no Roblox-specific interface is used.
--
-- PUBLIC API
--   CosmeticPresentationCatalog.findCosmeticPresentation(cosmeticId: any, cosmeticCatalog?) -> presentation?
--     nil for an id that is not a catalog cosmetic, or a catalog cosmetic without a look. Otherwise
--     a frozen table, one of:
--       { cosmeticKind = "Title", cosmeticId, titleText }
--       { cosmeticKind = "NameplateStyle", cosmeticId, nameplateStyleLook }
--       { cosmeticKind = "StageEntranceEffect", cosmeticId, stageEntranceEffectLook }
--     `cosmeticCatalog` (default src/shared/CosmeticCatalog) needs findCosmeticByCosmeticId.
--   CosmeticPresentationCatalog.listLookCosmeticIdsByKind() -> { NameplateStyle = {..}, StageEntranceEffect = {..} }
--     Every cosmetic id that has a look, for the catalog check (a new table each call).

local CosmeticCatalog = require("./CosmeticCatalog")
local NameplateStyleLookCatalog = require("./NameplateStyleLookCatalog")
local StageEntranceEffectLookCatalog = require("./StageEntranceEffectLookCatalog")

local CosmeticPresentationCatalog = {}

function CosmeticPresentationCatalog.findCosmeticPresentation(cosmeticId: any, cosmeticCatalog: any?)
	local chosenCosmeticCatalog = cosmeticCatalog or CosmeticCatalog
	local cosmetic = chosenCosmeticCatalog.findCosmeticByCosmeticId(cosmeticId)
	if cosmetic == nil then
		return nil
	end
	if cosmetic.cosmeticKind == "Title" then
		if type(cosmetic.cosmeticDisplayName) ~= "string" or cosmetic.cosmeticDisplayName == "" then
			return nil
		end
		return table.freeze({
			cosmeticKind = "Title",
			cosmeticId = cosmetic.cosmeticId,
			titleText = cosmetic.cosmeticDisplayName,
		})
	elseif cosmetic.cosmeticKind == "NameplateStyle" then
		local nameplateStyleLook = NameplateStyleLookCatalog.findNameplateStyleLook(cosmetic.cosmeticId)
		if nameplateStyleLook == nil then
			return nil
		end
		return table.freeze({
			cosmeticKind = "NameplateStyle",
			cosmeticId = cosmetic.cosmeticId,
			nameplateStyleLook = nameplateStyleLook,
		})
	elseif cosmetic.cosmeticKind == "StageEntranceEffect" then
		local stageEntranceEffectLook = StageEntranceEffectLookCatalog.findStageEntranceEffectLook(cosmetic.cosmeticId)
		if stageEntranceEffectLook == nil then
			return nil
		end
		return table.freeze({
			cosmeticKind = "StageEntranceEffect",
			cosmeticId = cosmetic.cosmeticId,
			stageEntranceEffectLook = stageEntranceEffectLook,
		})
	end
	return nil
end

function CosmeticPresentationCatalog.listLookCosmeticIdsByKind()
	local nameplateStyleCosmeticIds = {}
	for _, nameplateStyleLook in NameplateStyleLookCatalog.NAMEPLATE_STYLE_LOOKS do
		table.insert(nameplateStyleCosmeticIds, nameplateStyleLook.nameplateStyleCosmeticId)
	end
	local stageEntranceEffectCosmeticIds = {}
	for _, stageEntranceEffectLook in StageEntranceEffectLookCatalog.STAGE_ENTRANCE_EFFECT_LOOKS do
		table.insert(stageEntranceEffectCosmeticIds, stageEntranceEffectLook.stageEntranceEffectCosmeticId)
	end
	return { NameplateStyle = nameplateStyleCosmeticIds, StageEntranceEffect = stageEntranceEffectCosmeticIds }
end

return table.freeze(CosmeticPresentationCatalog)
