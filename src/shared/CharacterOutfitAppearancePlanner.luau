-- CharacterOutfitAppearancePlanner (development spec v1.3 §3.7 "Dressing characters", §2.14 worn
-- assets): decides, for a list of styling item keys, WHICH worn asset goes WHERE in a character's
-- appearance and in WHICH layering order. This module only decides, so every rule below is tested
-- with Lune. It lives in src/shared because BOTH sides apply its plan (§3.7 "the device preview
-- and the server use the same rules"): the server's PlayerCharacterDresser dresses real characters
-- (it requires it through src/server/CharacterOutfitAppearancePlanner.luau, a module that only
-- forwards here), and the device's wardrobe preview (src/client/RobloxWardrobePreviewCharacter)
-- dresses its device-only copy.
--
-- Rules (§3.7):
--   * Each styling item is worn through its worn assets (readResolvedStylingItemDetails): on the
--     server as MarketplaceStylingItemResolver cached them, on the device as the wardrobe catalog
--     snapshot (§2.14) lists them, which the server builds from the same cache. A bundle contributes every wearable asset it lists
--     (a shoes bundle: the left and the right shoe). An item the resolver does not report (hidden
--     this session, unknown, catalog not ready) is skipped and listed; it is never an error.
--   * The plan REPLACES the character's clothing, accessories, hair and makeup: every rigid
--     accessory, every layered clothing piece, the classic Shirt / Pants / T-shirt and every makeup
--     entry come from the outfit only (nothing of the player's own remains in those categories).
--     Body shape, body colours, scale, head and face are not part of the plan and stay the
--     player's own.
--   * Eyebrows and eyelashes are part of the player's face: the character keeps its own
--     (currentAccessoryEntries) unless the outfit wears that type, which then replaces them.
--     (Measured 2026-11-19: the test avatar's own eyebrows are a layered Eyebrow accessory with
--     Order 0; removing them would change the face, which §3.7 says stays the player's own.)
--   * Layered clothing gets an explicit order (LAYERED_CLOTHING_ORDER_BY_ACCESSORY_TYPE_NAME):
--     shoes below bottoms and dresses, bottoms and dresses below tops, inner tops below sweaters
--     below jackets. Rigid accessories get NO order (an order on a rigid accessory makes the whole
--     appearance fail to apply, spec §3.7).
--   * Makeup entries carry their asset id, makeup type (Face, Lip, Eye) and an order
--     (MAKEUP_ORDER_BY_MAKEUP_TYPE_NAME: face below eye below lip).
--   * A worn asset whose Roblox asset type this game does not dress (EarAccessory, EyeAccessory,
--     an unknown name) is skipped and listed, so one odd asset never breaks the whole appearance.
--   * The same asset id is never listed twice (the engine rejects duplicates).
-- Pure logic: names are plain strings; PlayerCharacterDresser turns them into Enum items.
--
-- PUBLIC API
--   CharacterOutfitAppearancePlanner.planCharacterAppearanceForOutfit(appearancePlanRequest) -> CharacterAppearancePlan
--     appearancePlanRequest = {
--       outfitStylingItemKeys: { string },
--       readResolvedStylingItemDetails: (stylingItemKey) -> { wornAssets = { { wornAssetId, robloxAssetTypeName } } }?,
--       currentAccessoryEntries: { { accessoryTypeName, assetId, isLayered, layeredClothingOrder? } },
--           the character's applied accessories now (only eyebrows and eyelashes are read)
--     }
--     CharacterAppearancePlan = {   (fresh tables)
--       accessoryEntries: { { accessoryTypeName, assetId, isLayered, layeredClothingOrder? } },
--           kept eyebrows/eyelashes first, then the outfit's in outfit order; layeredClothingOrder
--           is nil exactly for rigid accessories
--       makeupEntries: { { makeupTypeName, assetId, makeupOrder } },
--       classicClothingAssetIdByDescriptionPropertyName: { Shirt, Pants, GraphicTShirt } (0 = none),
--       wornStylingItemKeys: { string },   items that contributed at least one worn asset
--       skippedStylingItemKeys: { string },   items the resolver did not report
--       skippedWornAssets: { { stylingItemKey, wornAssetId, robloxAssetTypeName } },
--     }
--   CharacterOutfitAppearancePlanner.LAYERED_CLOTHING_ORDER_BY_ACCESSORY_TYPE_NAME   frozen
--   CharacterOutfitAppearancePlanner.MAKEUP_ORDER_BY_MAKEUP_TYPE_NAME                frozen
--   CharacterOutfitAppearancePlanner.WORN_ASSET_PLACEMENT_BY_ROBLOX_ASSET_TYPE_NAME   frozen
--     { [robloxAssetTypeName]: { placementKind = "RigidAccessory" | "LayeredClothing" |
--       "FacialFeatureAccessory" | "Makeup" | "ClassicClothing", accessoryTypeName? ,
--       makeupTypeName?, descriptionPropertyName? } }
-- Names: Enum.AssetType and Enum.AccessoryType item names and Enum.MakeupType (Face, Lip, Eye),
-- listed from the engine in Studio 0.748 on 2026-11-19 and from
-- https://create.roblox.com/docs/reference/engine/enums/AssetType, .../AccessoryType, .../MakeupType.

local CharacterOutfitAppearancePlanner = {}

local function rigid(accessoryTypeName: string)
	return table.freeze({ placementKind = "RigidAccessory", accessoryTypeName = accessoryTypeName })
end
local function layered(accessoryTypeName: string)
	return table.freeze({ placementKind = "LayeredClothing", accessoryTypeName = accessoryTypeName })
end
local function facialFeature(accessoryTypeName: string)
	return table.freeze({ placementKind = "FacialFeatureAccessory", accessoryTypeName = accessoryTypeName })
end
local function makeup(makeupTypeName: string)
	return table.freeze({ placementKind = "Makeup", makeupTypeName = makeupTypeName })
end
local function classicClothing(descriptionPropertyName: string)
	return table.freeze({ placementKind = "ClassicClothing", descriptionPropertyName = descriptionPropertyName })
end

CharacterOutfitAppearancePlanner.WORN_ASSET_PLACEMENT_BY_ROBLOX_ASSET_TYPE_NAME = table.freeze({
	Hat = rigid("Hat"),
	HairAccessory = rigid("Hair"),
	FaceAccessory = rigid("Face"),
	NeckAccessory = rigid("Neck"),
	ShoulderAccessory = rigid("Shoulder"),
	FrontAccessory = rigid("Front"),
	BackAccessory = rigid("Back"),
	WaistAccessory = rigid("Waist"),
	TShirtAccessory = layered("TShirt"),
	ShirtAccessory = layered("Shirt"),
	PantsAccessory = layered("Pants"),
	JacketAccessory = layered("Jacket"),
	SweaterAccessory = layered("Sweater"),
	ShortsAccessory = layered("Shorts"),
	LeftShoeAccessory = layered("LeftShoe"),
	RightShoeAccessory = layered("RightShoe"),
	DressSkirtAccessory = layered("DressSkirt"),
	EyebrowAccessory = facialFeature("Eyebrow"),
	EyelashAccessory = facialFeature("Eyelash"),
	FaceMakeup = makeup("Face"),
	LipMakeup = makeup("Lip"),
	EyeMakeup = makeup("Eye"),
	Shirt = classicClothing("Shirt"),
	Pants = classicClothing("Pants"),
	TShirt = classicClothing("GraphicTShirt"),
})

-- Lower is closer to the body (§3.7: shoes below dresses and bottoms, inner tops below jackets).
CharacterOutfitAppearancePlanner.LAYERED_CLOTHING_ORDER_BY_ACCESSORY_TYPE_NAME = table.freeze({
	LeftShoe = 1,
	RightShoe = 1,
	Pants = 2,
	Shorts = 2,
	DressSkirt = 3,
	TShirt = 4,
	Shirt = 5,
	Sweater = 6,
	Jacket = 7,
})

-- The engine's own order for the test avatar's eyebrows (measured 2026-11-19) is 0; an outfit's
-- eyebrows or eyelashes use it too, below every clothing piece.
local FACIAL_FEATURE_LAYERED_ORDER = 0

-- MakeupDescription.Order: "Lower values are applied first, with higher values rendered on top."
CharacterOutfitAppearancePlanner.MAKEUP_ORDER_BY_MAKEUP_TYPE_NAME = table.freeze({
	Face = 1,
	Eye = 2,
	Lip = 3,
})

local PLACEMENTS = CharacterOutfitAppearancePlanner.WORN_ASSET_PLACEMENT_BY_ROBLOX_ASSET_TYPE_NAME
local LAYERED_ORDERS = CharacterOutfitAppearancePlanner.LAYERED_CLOTHING_ORDER_BY_ACCESSORY_TYPE_NAME
local MAKEUP_ORDERS = CharacterOutfitAppearancePlanner.MAKEUP_ORDER_BY_MAKEUP_TYPE_NAME

local function createEmptyPlan()
	return {
		accessoryEntries = {},
		makeupEntries = {},
		classicClothingAssetIdByDescriptionPropertyName = { Shirt = 0, Pants = 0, GraphicTShirt = 0 },
		wornStylingItemKeys = {},
		skippedStylingItemKeys = {},
		skippedWornAssets = {},
	}
end

-- Adds one worn asset to the outfit part of the plan; returns whether it was placed.
local function placeWornAsset(outfitPart, wornAsset, placedAssetIdSet): boolean
	local wornAssetId = wornAsset.wornAssetId
	local placement = if type(wornAsset.robloxAssetTypeName) == "string"
		then PLACEMENTS[wornAsset.robloxAssetTypeName]
		else nil
	if placement == nil or type(wornAssetId) ~= "number" or placedAssetIdSet[wornAssetId] then
		return false
	end
	placedAssetIdSet[wornAssetId] = true
	local placementKind = placement.placementKind
	if placementKind == "RigidAccessory" then
		table.insert(outfitPart.accessoryEntries, {
			accessoryTypeName = placement.accessoryTypeName,
			assetId = wornAssetId,
			isLayered = false,
		})
	elseif placementKind == "LayeredClothing" or placementKind == "FacialFeatureAccessory" then
		table.insert(outfitPart.accessoryEntries, {
			accessoryTypeName = placement.accessoryTypeName,
			assetId = wornAssetId,
			isLayered = true,
			layeredClothingOrder = if placementKind == "LayeredClothing"
				then LAYERED_ORDERS[placement.accessoryTypeName]
				else FACIAL_FEATURE_LAYERED_ORDER,
		})
		if placementKind == "FacialFeatureAccessory" then
			outfitPart.wornFacialFeatureTypeNameSet[placement.accessoryTypeName] = true
		end
	elseif placementKind == "Makeup" then
		table.insert(outfitPart.makeupEntries, {
			makeupTypeName = placement.makeupTypeName,
			assetId = wornAssetId,
			makeupOrder = MAKEUP_ORDERS[placement.makeupTypeName],
		})
	else
		outfitPart.classicClothingAssetIdByDescriptionPropertyName[placement.descriptionPropertyName] = wornAssetId
	end
	return true
end

local function collectKeptFacialFeatureEntries(currentAccessoryEntries, wornFacialFeatureTypeNameSet, placedAssetIdSet)
	local keptEntries = {}
	for _, currentEntry in currentAccessoryEntries or {} do
		local accessoryTypeName = currentEntry.accessoryTypeName
		local isFacialFeature = accessoryTypeName == "Eyebrow" or accessoryTypeName == "Eyelash"
		if
			isFacialFeature
			and not wornFacialFeatureTypeNameSet[accessoryTypeName]
			and not placedAssetIdSet[currentEntry.assetId]
		then
			placedAssetIdSet[currentEntry.assetId] = true
			table.insert(keptEntries, {
				accessoryTypeName = accessoryTypeName,
				assetId = currentEntry.assetId,
				isLayered = currentEntry.isLayered == true,
				layeredClothingOrder = if currentEntry.isLayered == true
					then (currentEntry.layeredClothingOrder or FACIAL_FEATURE_LAYERED_ORDER)
					else nil,
			})
		end
	end
	return keptEntries
end

function CharacterOutfitAppearancePlanner.planCharacterAppearanceForOutfit(appearancePlanRequest)
	local plan = createEmptyPlan()
	local outfitPart = {
		accessoryEntries = {},
		makeupEntries = plan.makeupEntries,
		classicClothingAssetIdByDescriptionPropertyName = plan.classicClothingAssetIdByDescriptionPropertyName,
		wornFacialFeatureTypeNameSet = {},
	}
	local placedAssetIdSet = {}
	for _, stylingItemKey in appearancePlanRequest.outfitStylingItemKeys do
		local resolvedDetails = appearancePlanRequest.readResolvedStylingItemDetails(stylingItemKey)
		if resolvedDetails == nil or type(resolvedDetails.wornAssets) ~= "table" then
			table.insert(plan.skippedStylingItemKeys, stylingItemKey)
			continue
		end
		local didWearAnyAsset = false
		for _, wornAsset in resolvedDetails.wornAssets do
			if placeWornAsset(outfitPart, wornAsset, placedAssetIdSet) then
				didWearAnyAsset = true
			else
				table.insert(plan.skippedWornAssets, {
					stylingItemKey = stylingItemKey,
					wornAssetId = wornAsset.wornAssetId,
					robloxAssetTypeName = wornAsset.robloxAssetTypeName,
				})
			end
		end
		if didWearAnyAsset then
			table.insert(plan.wornStylingItemKeys, stylingItemKey)
		end
	end
	local keptFacialFeatureEntries = collectKeptFacialFeatureEntries(
		appearancePlanRequest.currentAccessoryEntries,
		outfitPart.wornFacialFeatureTypeNameSet,
		placedAssetIdSet
	)
	table.move(keptFacialFeatureEntries, 1, #keptFacialFeatureEntries, 1, plan.accessoryEntries)
	table.move(
		outfitPart.accessoryEntries,
		1,
		#outfitPart.accessoryEntries,
		#plan.accessoryEntries + 1,
		plan.accessoryEntries
	)
	return plan
end

return table.freeze(CharacterOutfitAppearancePlanner)
