-- RobloxWardrobePreviewCharacter (development spec §3.7 "Wardrobe preview"): a DEVICE-ONLY copy of
-- the player's character, shown in a ViewportFrame and dressed on the device in the current wardrobe
-- selection, with the same placement and layering rules the server uses.
--
--   * The copy is a new model built from the real character's applied appearance
--     (Players:CreateHumanoidModelFromDescriptionAsync of Humanoid:GetAppliedDescription()). The real
--     character is only READ: nothing on it is changed, cloned or re-parented (§3.7 "a device is not
--     allowed to apply an appearance to its player's real character").
--   * The copy's scripts (the engine adds an Animate LocalScript) are removed before it is shown, so
--     nothing of it runs on the device.
--   * Dressing: CharacterOutfitAppearancePlanner (src/shared, the planner the server's
--     PlayerCharacterDresser uses) plans the outfit from the catalog snapshot's worn assets; the plan
--     is written into a copy of the base appearance by src/shared/CharacterAppearancePlanDescriptionWriter,
--     the very code PlayerCharacterDresser uses (SetAccessories(entries, true),
--     Shirt/Pants/GraphicTShirt, one MakeupDescription per makeup entry), and applied with
--     Humanoid:ApplyDescriptionResetAsync. Reset, not ApplyDescriptionAsync:
--     measured in Studio on 2026-11-20, ApplyDescriptionAsync on a copy left the player's own hat and
--     eyebrows in place next to the new accessories; the Reset variant "will always ensure the
--     character reflects the passed in" description (Humanoid reference) and did.
--   * An empty selection shows the copy in the player's own appearance, as the server shows a
--     participant whose outfit is empty (spec §10 v1.4, owner decision 4).
--   * One application at a time; a newer selection arriving meanwhile is applied when the current
--     one ends (only the latest). "Updating..." shows meanwhile (§3.7 "A short updating indication").
--   * After the player's character respawns (§2.4 "the device re-applies its draft preview") the copy
--     is rebuilt from the new character and the selection applied again.
--   * The applied keys are published on the ViewportFrame's attribute "PreviewOutfitStylingItemKeys"
--     (comma-separated) for checks in a playtest.
--
-- PUBLIC API
--   RobloxWardrobePreviewCharacter.create(screenGui, localPlayer) -> preview
--   preview:showOutfit(outfitStylingItemKeys?, wardrobeCatalogView?)   nil keys hide the preview
--   preview:handleCharacterRespawned()
--
-- Roblox API used, read in the official documentation (create.roblox.com/docs/reference/engine/...):
--   Players:CreateHumanoidModelFromDescriptionAsync(description, rigType) (yields)   classes/Players
--     (its client use is not stated in the reference; measured on the playtest client 2026-11-20: works, 0.27 s)
--   Humanoid:GetAppliedDescription, :ApplyDescriptionResetAsync (yields), .DisplayDistanceType
--                                                       classes/Humanoid
--   HumanoidDescription:SetAccessories, :GetAccessories, .Shirt, .Pants, .GraphicTShirt
--                                                       classes/HumanoidDescription
--   MakeupDescription .AssetId, .MakeupType, .Order     classes/MakeupDescription
--   ViewportFrame .CurrentCamera, .Ambient, .LightColor  classes/ViewportFrame
--   WorldModel ("you can put Humanoid characters in the WorldModel")   classes/WorldModel
--   Camera .CFrame, .FieldOfView                         classes/Camera
--   Model:GetBoundingBox, :PivotTo                       classes/Model, classes/PVInstance
--   CFrame.new, CFrame.lookAt, Vector3.new               datatypes/CFrame, datatypes/Vector3
--   Enum.HumanoidRigType.R15, Enum.AccessoryType, Enum.MakeupType, Enum.HumanoidDisplayDistanceType.None
--   Instance:Clone, :Destroy, :GetDescendants, :GetChildren, :IsA, :FindFirstChildOfClass, :SetAttribute
--                                                       classes/Instance
--   task.spawn                                          libraries/task

local Players = game:GetService("Players")

local CharacterAppearancePlanDescriptionWriter = require("../shared/CharacterAppearancePlanDescriptionWriter")
local CharacterOutfitAppearancePlanner = require("../shared/CharacterOutfitAppearancePlanner")
local DeviceInterfaceElementFactory = require("./DeviceInterfaceElementFactory")
local WardrobeCatalogView = require("./WardrobeCatalogView")

local RobloxWardrobePreviewCharacter = {}
RobloxWardrobePreviewCharacter.__index = RobloxWardrobePreviewCharacter

-- The engine values the shared description writer is given (it reads no Roblox global itself).
local ROBLOX_ENGINE_TYPES_FOR_DESCRIPTION_WRITER = table.freeze({
	accessoryTypeByName = Enum.AccessoryType,
	makeupTypeByName = Enum.MakeupType,
	createInstance = Instance.new,
})

function RobloxWardrobePreviewCharacter.create(screenGui: ScreenGui, localPlayer: Player)
	local panel = DeviceInterfaceElementFactory.createPanel("WardrobePreviewPanel", screenGui)
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -10, 0, 130)
	panel.Size = UDim2.fromScale(0.24, 0.6)
	panel.Visible = false
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "WardrobePreview"
	viewport.BackgroundTransparency = 1
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.Ambient = Color3.fromRGB(200, 200, 200)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.Parent = panel
	local worldModel = Instance.new("WorldModel")
	worldModel.Parent = viewport
	local camera = Instance.new("Camera")
	camera.FieldOfView = 40
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	local updatingLabel = DeviceInterfaceElementFactory.createTextLabel("UpdatingLabel", panel, 16, 1)
	updatingLabel.Text = "Updating..."
	updatingLabel.Visible = false
	return setmetatable({
		localPlayer = localPlayer,
		panel = panel,
		viewport = viewport,
		worldModel = worldModel,
		camera = camera,
		updatingLabel = updatingLabel,
		copyModel = nil,
		baseDescription = nil,
		isApplying = false,
		wantedOutfit = nil, -- { keys, view }
		appliedSignature = nil,
	}, RobloxWardrobePreviewCharacter)
end

function RobloxWardrobePreviewCharacter:discardCopy()
	if self.copyModel ~= nil then
		self.copyModel:Destroy()
	end
	self.copyModel = nil
	self.baseDescription = nil
	self.appliedSignature = nil
end

-- Yields. Returns false when the real character is not there yet.
function RobloxWardrobePreviewCharacter:buildCopyFromRealCharacter(): boolean
	local character = self.localPlayer.Character
	local realHumanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	if realHumanoid == nil then
		return false
	end
	local baseDescription = realHumanoid:GetAppliedDescription()
	local copyModel = Players:CreateHumanoidModelFromDescriptionAsync(baseDescription, Enum.HumanoidRigType.R15)
	for _, descendant in copyModel:GetDescendants() do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end
	copyModel.Name = "PreviewCopy"
	local copyHumanoid = copyModel:FindFirstChildOfClass("Humanoid")
	if copyHumanoid ~= nil then
		copyHumanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	copyModel:PivotTo(CFrame.new(0, 0, 0))
	copyModel.Parent = self.worldModel
	local boxCFrame, boxSize = copyModel:GetBoundingBox()
	local lookAt = boxCFrame.Position
	self.camera.CFrame = CFrame.lookAt(lookAt + Vector3.new(0, boxSize.Y * 0.1, -boxSize.Y * 2.1), lookAt)
	self.copyModel = copyModel
	self.baseDescription = baseDescription
	return true
end

function RobloxWardrobePreviewCharacter:applyOutfitToCopy(outfitStylingItemKeys, wardrobeCatalogView)
	local baseDescription = self.baseDescription :: HumanoidDescription
	local description = baseDescription:Clone()
	-- An empty selection is previewed as the player's own appearance: a participant whose outfit is
	-- empty stands on stage in their lobby appearance (spec §10 v1.4, owner decision 4).
	if #outfitStylingItemKeys > 0 then
		local appearancePlan = CharacterOutfitAppearancePlanner.planCharacterAppearanceForOutfit({
			outfitStylingItemKeys = outfitStylingItemKeys,
			readResolvedStylingItemDetails = WardrobeCatalogView.readResolvedStylingItemDetailsFromView(
				wardrobeCatalogView
			),
			currentAccessoryEntries = CharacterAppearancePlanDescriptionWriter.readAccessoryEntriesForPlanner(
				baseDescription
			),
		})
		CharacterAppearancePlanDescriptionWriter.writeAppearancePlanIntoDescription(
			description,
			appearancePlan,
			ROBLOX_ENGINE_TYPES_FOR_DESCRIPTION_WRITER
		)
	end
	local copyHumanoid = (self.copyModel :: Model):FindFirstChildOfClass("Humanoid") :: Humanoid
	copyHumanoid:ApplyDescriptionResetAsync(description)
	self.viewport:SetAttribute("PreviewOutfitStylingItemKeys", table.concat(outfitStylingItemKeys, ","))
end

function RobloxWardrobePreviewCharacter:applyWantedOutfitsUntilCurrent()
	self.isApplying = true
	self.updatingLabel.Visible = true
	while self.wantedOutfit ~= nil do
		local wanted = self.wantedOutfit
		local signature = table.concat(wanted.outfitStylingItemKeys, ",")
		if signature == self.appliedSignature and self.copyModel ~= nil then
			self.wantedOutfit = nil
			break
		end
		local didSucceed, problem = pcall(function()
			if self.copyModel == nil and not self:buildCopyFromRealCharacter() then
				error("the player's character is not there yet")
			end
			self:applyOutfitToCopy(wanted.outfitStylingItemKeys, wanted.wardrobeCatalogView)
		end)
		if didSucceed then
			self.appliedSignature = signature
		else
			warn("WardrobePreview: could not dress the preview: " .. tostring(problem))
		end
		if self.wantedOutfit == wanted then
			self.wantedOutfit = nil
		end
	end
	self.isApplying = false
	self.updatingLabel.Visible = false
end

function RobloxWardrobePreviewCharacter:showOutfit(outfitStylingItemKeys: { string }?, wardrobeCatalogView)
	self.panel.Visible = outfitStylingItemKeys ~= nil
	if outfitStylingItemKeys == nil or wardrobeCatalogView == nil then
		self.wantedOutfit = nil
		return
	end
	local signature = table.concat(outfitStylingItemKeys, ",")
	if signature == self.appliedSignature and self.copyModel ~= nil and not self.isApplying then
		return
	end
	self.wantedOutfit = { outfitStylingItemKeys = outfitStylingItemKeys, wardrobeCatalogView = wardrobeCatalogView }
	if not self.isApplying then
		task.spawn(function()
			self:applyWantedOutfitsUntilCurrent()
		end)
	end
end

function RobloxWardrobePreviewCharacter:handleCharacterRespawned()
	self:discardCopy()
	-- The next showOutfit (the screens render several times a second) rebuilds the copy and
	-- applies the selection again; nothing else to do here.
	self.viewport:SetAttribute("PreviewOutfitStylingItemKeys", nil)
end

return RobloxWardrobePreviewCharacter
