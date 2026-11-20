-- CharacterAppearancePlanDescriptionWriter (development spec §3.7 "Dressing characters", "the device
-- preview and the server use the same rules"): writes a CharacterOutfitAppearancePlanner plan into a
-- HumanoidDescription, and reads a description's accessories in the shape the planner takes. ONE
-- home for these steps, used by the server's PlayerCharacterDresser (the real character) and the
-- device's RobloxWardrobePreviewCharacter (the device-only copy), so what the player previews is
-- written exactly as the server later writes it.
--
-- Writing, in this order (§3.7 🔴 "start from the character's currently applied appearance and
-- replace only clothing, accessories, hair and makeup"):
--   1. description:SetAccessories(plan entries, true): every rigid and layered accessory is replaced;
--      a layered entry carries Order, a rigid entry carries none (an Order on a rigid accessory makes
--      the whole appearance fail to apply, §3.7);
--   2. Shirt / Pants / GraphicTShirt set from the plan (0 = none);
--   3. every MakeupDescription child is destroyed, then one is added per planned makeup entry.
-- Applying the description (ApplyDescriptionAsync on the server, ApplyDescriptionResetAsync on the
-- device copy) stays with each caller.
--
-- Stateless, and it reads no Roblox global: the engine's enums and its instance constructor are
-- passed in (`robloxEngineTypes`), so Lune tests pass stand-ins and check every call. It changes
-- only the description it is given.
--
-- PUBLIC API
--   CharacterAppearancePlanDescriptionWriter.readAccessoryEntriesForPlanner(description)
--     -> { { accessoryTypeName, assetId, isLayered, layeredClothingOrder? } }
--     from description:GetAccessories(true) (rigid accessories included).
--   CharacterAppearancePlanDescriptionWriter.writeAppearancePlanIntoDescription(description,
--       appearancePlan, robloxEngineTypes)
--     appearancePlan: CharacterOutfitAppearancePlanner's plan (accessoryEntries,
--       classicClothingAssetIdByDescriptionPropertyName, makeupEntries).
--     robloxEngineTypes = { accessoryTypeByName = Enum.AccessoryType, makeupTypeByName = Enum.MakeupType,
--       createInstance = Instance.new }   (in Roblox, exactly these engine values)
--
-- Roblox API the callers' description must offer (documented on
-- https://create.roblox.com/docs/reference/engine/classes/HumanoidDescription and
-- .../classes/MakeupDescription): HumanoidDescription:GetAccessories(includeRigidAccessories),
-- :SetAccessories(accessories, includeRigidAccessories) ("any table entry that does not have an Order
-- will be considered a rigid accessory"), .Shirt, .Pants, .GraphicTShirt, Instance:GetChildren,
-- :IsA, :Destroy, .Parent; MakeupDescription .AssetId, .MakeupType, .Order. Enum.AccessoryType and
-- Enum.MakeupType are indexed by item name (.../enums/AccessoryType, .../enums/MakeupType).

local CharacterAppearancePlanDescriptionWriter = {}

function CharacterAppearancePlanDescriptionWriter.readAccessoryEntriesForPlanner(description)
	local accessoryEntries = {}
	for _, engineEntry in description:GetAccessories(true) do
		table.insert(accessoryEntries, {
			accessoryTypeName = engineEntry.AccessoryType.Name,
			assetId = engineEntry.AssetId,
			isLayered = engineEntry.IsLayered == true,
			layeredClothingOrder = engineEntry.Order,
		})
	end
	return accessoryEntries
end

local function convertPlanEntriesToEngineEntries(plannedAccessoryEntries, robloxEngineTypes)
	local engineEntries = {}
	for _, plannedEntry in plannedAccessoryEntries do
		local engineEntry = {
			AccessoryType = robloxEngineTypes.accessoryTypeByName[plannedEntry.accessoryTypeName],
			AssetId = plannedEntry.assetId,
			IsLayered = plannedEntry.isLayered,
		}
		if plannedEntry.layeredClothingOrder ~= nil then
			engineEntry.Order = plannedEntry.layeredClothingOrder
		end
		table.insert(engineEntries, engineEntry)
	end
	return engineEntries
end

local function replaceMakeupDescriptions(description, plannedMakeupEntries, robloxEngineTypes)
	for _, child in description:GetChildren() do
		if child:IsA("MakeupDescription") then
			child:Destroy()
		end
	end
	for _, plannedMakeupEntry in plannedMakeupEntries do
		local makeupDescription = robloxEngineTypes.createInstance("MakeupDescription")
		makeupDescription.AssetId = plannedMakeupEntry.assetId
		makeupDescription.MakeupType = robloxEngineTypes.makeupTypeByName[plannedMakeupEntry.makeupTypeName]
		makeupDescription.Order = plannedMakeupEntry.makeupOrder
		makeupDescription.Parent = description
	end
end

function CharacterAppearancePlanDescriptionWriter.writeAppearancePlanIntoDescription(
	description,
	appearancePlan,
	robloxEngineTypes
)
	description:SetAccessories(
		convertPlanEntriesToEngineEntries(appearancePlan.accessoryEntries, robloxEngineTypes),
		true
	)
	for descriptionPropertyName, assetId in appearancePlan.classicClothingAssetIdByDescriptionPropertyName do
		description[descriptionPropertyName] = assetId
	end
	replaceMakeupDescriptions(description, appearancePlan.makeupEntries, robloxEngineTypes)
end

return table.freeze(CharacterAppearancePlanDescriptionWriter)
