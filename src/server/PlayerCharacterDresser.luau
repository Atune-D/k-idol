-- PlayerCharacterDresser (development spec v1.3 §3.7 "Dressing characters"): applies a list of
-- styling item keys to a real R15 character, or gives the character back the player's own avatar.
-- WHICH worn asset goes where and in which order is CharacterOutfitAppearancePlanner's decision
-- (tested with Lune); this file only reads the character's applied description, writes the plan
-- into it and applies it. Steps 2-4 below are src/shared/CharacterAppearancePlanDescriptionWriter,
-- the same code the device's wardrobe preview uses (one home, no copy).
--
-- How (§3.7 🔴 "start from the character's currently applied appearance and replace only
-- clothing, accessories, hair and makeup"):
--   1. description = humanoid:GetAppliedDescription()  (body parts, colours and scale stay)
--   2. description:SetAccessories(plan entries, true): every rigid and layered accessory is
--      replaced; layered entries carry Order, rigid entries carry none
--   3. Shirt / Pants / GraphicTShirt set from the plan (0 = none)
--   4. every MakeupDescription child is destroyed and one is added per planned makeup entry
--   5. humanoid:ApplyDescriptionAsync(description)
-- The worn assets come from MarketplaceStylingItemResolver's cache (readResolvedStylingItemDetails);
-- nothing here asks Roblox about Marketplace items (§3.3).
--
-- PUBLIC API
--   PlayerCharacterDresser.new({ readResolvedStylingItemDetails, logger }) -> dresser
--   dresser:dressCharacterInOutfit(character, outfitStylingItemKeys) -> CharacterAppearancePlan
--     YIELDS (ApplyDescriptionAsync). Raises when the character has no Humanoid or the engine
--     refuses the description. Logs a warning naming every skipped item or worn asset.
--   dresser:readAppliedDescriptionCopy(character) -> HumanoidDescription   (the own avatar copy
--     the presenter keeps; GetAppliedDescription already returns a copy)
--   dresser:applyOwnAvatarDescription(character, ownAvatarDescription)   YIELDS; applies a clone
--   PlayerCharacterDresser.listWornAccessoryAndClothingNames(character) -> { string }
--     For diagnostics and the Studio checks: "Accessory <Name>", "Shirt", "Pants", "ShirtGraphic".
--
-- Roblox API used, read in the official documentation while writing this file:
--   Humanoid:GetAppliedDescription, Humanoid:ApplyDescriptionAsync (ApplyDescription is deprecated)
--                       https://create.roblox.com/docs/reference/engine/classes/Humanoid
--   HumanoidDescription:SetAccessories(accessories, includeRigidAccessories),
--   HumanoidDescription:GetAccessories(includeRigidAccessories), .Shirt, .Pants, .GraphicTShirt
--                       https://create.roblox.com/docs/reference/engine/classes/HumanoidDescription
--     ("any table entry that does not have an Order will be considered a rigid accessory")
--   MakeupDescription (.AssetId, .MakeupType, .Order; "placed underneath a HumanoidDescription")
--                       https://create.roblox.com/docs/reference/engine/classes/MakeupDescription
--   Enum.AccessoryType  https://create.roblox.com/docs/reference/engine/enums/AccessoryType
--   Enum.MakeupType     https://create.roblox.com/docs/reference/engine/enums/MakeupType
--   Instance.new, :Clone, :Destroy, :GetChildren, :IsA, :FindFirstChildOfClass, .Parent, .Name
--                       https://create.roblox.com/docs/reference/engine/classes/Instance
-- Engine behaviour measured in Studio 0.748 on 2026-11-19 (unpublished Place1, playtest server,
-- R15): SetAccessories(entries, true) also emptied the rigid string property HatAccessory that the
-- avatar had; GetAccessories returns rigid entries with Order nil; the documented property
-- HumanoidDescription.AccessoryBlob raised "is not a valid member" (not used here); applying the
-- six-item dress outfit took 0.53 s and the character then wore every planned accessory.

local CharacterAppearancePlanDescriptionWriter = require("../shared/CharacterAppearancePlanDescriptionWriter")
local CharacterOutfitAppearancePlanner = require("./CharacterOutfitAppearancePlanner")

-- The engine values the shared description writer is given (it reads no Roblox global itself).
local ROBLOX_ENGINE_TYPES_FOR_DESCRIPTION_WRITER = table.freeze({
	accessoryTypeByName = Enum.AccessoryType,
	makeupTypeByName = Enum.MakeupType,
	createInstance = Instance.new,
})

local PlayerCharacterDresser = {}
PlayerCharacterDresser.__index = PlayerCharacterDresser

function PlayerCharacterDresser.new(dependencies)
	return setmetatable({
		readResolvedStylingItemDetails = dependencies.readResolvedStylingItemDetails,
		logger = dependencies.logger,
	}, PlayerCharacterDresser)
end

local function findHumanoidOrRaise(character: Model): Humanoid
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		error("PlayerCharacterDresser: the character has no Humanoid")
	end
	return humanoid
end

local function logSkippedParts(self, appearancePlan)
	for _, skippedStylingItemKey in appearancePlan.skippedStylingItemKeys do
		self.logger:logWarning(
			string.format("PlayerCharacterDresser: %s is not available this session; not worn", skippedStylingItemKey)
		)
	end
	for _, skippedWornAsset in appearancePlan.skippedWornAssets do
		self.logger:logWarning(
			string.format(
				"PlayerCharacterDresser: worn asset %s (%s) of %s is not dressed by this game",
				tostring(skippedWornAsset.wornAssetId),
				tostring(skippedWornAsset.robloxAssetTypeName),
				skippedWornAsset.stylingItemKey
			)
		)
	end
end

function PlayerCharacterDresser:dressCharacterInOutfit(character: Model, outfitStylingItemKeys: { string })
	local humanoid = findHumanoidOrRaise(character)
	local description = humanoid:GetAppliedDescription()
	local appearancePlan = CharacterOutfitAppearancePlanner.planCharacterAppearanceForOutfit({
		outfitStylingItemKeys = outfitStylingItemKeys,
		readResolvedStylingItemDetails = self.readResolvedStylingItemDetails,
		currentAccessoryEntries = CharacterAppearancePlanDescriptionWriter.readAccessoryEntriesForPlanner(description),
	})
	logSkippedParts(self, appearancePlan)
	CharacterAppearancePlanDescriptionWriter.writeAppearancePlanIntoDescription(
		description,
		appearancePlan,
		ROBLOX_ENGINE_TYPES_FOR_DESCRIPTION_WRITER
	)
	humanoid:ApplyDescriptionAsync(description)
	return appearancePlan
end

function PlayerCharacterDresser:readAppliedDescriptionCopy(character: Model): HumanoidDescription
	return findHumanoidOrRaise(character):GetAppliedDescription()
end

function PlayerCharacterDresser:applyOwnAvatarDescription(character: Model, ownAvatarDescription: HumanoidDescription)
	findHumanoidOrRaise(character):ApplyDescriptionAsync(ownAvatarDescription:Clone())
end

function PlayerCharacterDresser.listWornAccessoryAndClothingNames(character: Model): { string }
	local wornNames = {}
	for _, child in character:GetChildren() do
		if child:IsA("Accessory") then
			table.insert(wornNames, "Accessory " .. child.Name)
		elseif child:IsA("Clothing") or child:IsA("ShirtGraphic") then
			table.insert(wornNames, child.ClassName)
		end
	end
	table.sort(wornNames)
	return wornNames
end

return PlayerCharacterDresser
