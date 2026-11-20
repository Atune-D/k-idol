-- RobloxCharacterOverheadCosmeticDisplay (development spec v1.3 §1.7): shows a player's equipped
-- Title and NameplateStyle above their character's head, built on the server from plain interface
-- instances so every device sees it (a BillboardGui in the character replicates like the
-- character). No image or asset is used. WHAT is shown is CharacterPresentationStepPlanner's
-- decision and NameplateStyleLookCatalog's data; this file only builds it.
--
-- Layout (BillboardGui named OVERHEAD_DISPLAY_NAME, parented to the Head, its Adornee):
--   * a Title line ("TitleLabel": white text with a dark outline, no background) when a Title is
--     equipped;
--   * a Nameplate ("NameplatePlate": the look's colour or gradient, frame line, rounded corners,
--     sparkle dots, with "NameLabel" showing the player's display name) when a NameplateStyle is
--     equipped. While the nameplate shows the player's name, the engine's own name display of that
--     humanoid is turned off (Humanoid.DisplayDistanceType None) so the name is not shown twice;
--     the previous value is put back when the nameplate is removed.
-- Removing (or showing anew) destroys the previous display first, so at most one exists.
--
-- PUBLIC API
--   RobloxCharacterOverheadCosmeticDisplay.OVERHEAD_DISPLAY_NAME = "IdolgrowOverheadCosmetics"
--   RobloxCharacterOverheadCosmeticDisplay.showOverheadCosmetics(character, playerDisplayName, overheadCosmetics)
--     overheadCosmetics = { titleText: string?, nameplateStyleLook: NameplateStyleLook? }.
--     Raises when the character has no Head or no Humanoid.
--   RobloxCharacterOverheadCosmeticDisplay.removeOverheadCosmetics(character)
--
-- Roblox API used, read in the official documentation while writing this file:
--   BillboardGui .Adornee, .Size ("the scale components ... set the billboard's stud size in 3D
--     space"), .StudsOffset, .AlwaysOnTop (default false), .MaxDistance, .LightInfluence (0-1)
--                       https://create.roblox.com/docs/reference/engine/classes/BillboardGui
--   Frame; GuiObject .Size, .Position, .AnchorPoint, .BackgroundColor3, .BackgroundTransparency,
--     .BorderSizePixel, .Rotation, .ZIndex
--                       https://create.roblox.com/docs/reference/engine/classes/Frame
--                       https://create.roblox.com/docs/reference/engine/classes/GuiObject
--   TextLabel .Text, .TextColor3, .TextScaled, .TextStrokeColor3, .TextStrokeTransparency,
--     .FontFace (Font is hidden; FontFace is the documented property)
--                       https://create.roblox.com/docs/reference/engine/classes/TextLabel
--   Font.fromEnum, Enum.Font.GothamBold   https://create.roblox.com/docs/reference/engine/datatypes/Font
--   UICorner.CornerRadius, UIStroke .Color/.Thickness/.ApplyStrokeMode, UIGradient .Color/.Rotation
--     ("the color blended with the parent GuiObject")
--                       https://create.roblox.com/docs/reference/engine/classes/UICorner
--                       https://create.roblox.com/docs/reference/engine/classes/UIStroke
--                       https://create.roblox.com/docs/reference/engine/classes/UIGradient
--   Enum.ApplyStrokeMode.Border   https://create.roblox.com/docs/reference/engine/enums/ApplyStrokeMode
--   ColorSequence.new, ColorSequenceKeypoint.new, UDim2.fromScale, UDim.new,
--     Vector2.new, Vector3.new, Color3.fromRGB   (engine data types, create.roblox.com/docs/reference/engine/datatypes/...)
--   Humanoid.DisplayDistanceType, Enum.HumanoidDisplayDistanceType.None ("will not have their Name
--     and healthbar displayed to other players under any circumstance")
--                       https://create.roblox.com/docs/reference/engine/classes/Humanoid
--                       https://create.roblox.com/docs/reference/engine/enums/HumanoidDisplayDistanceType
--   Instance.new, :FindFirstChild, :FindFirstChildOfClass, :Destroy, .Name, .Parent
--                       https://create.roblox.com/docs/reference/engine/classes/Instance

local RobloxCharacterOverheadCosmeticDisplay = {}

RobloxCharacterOverheadCosmeticDisplay.OVERHEAD_DISPLAY_NAME = "IdolgrowOverheadCosmetics"

local BILLBOARD_WIDTH_STUDS = 5
local TITLE_HEIGHT_STUDS = 0.6
local NAMEPLATE_HEIGHT_STUDS = 0.9
local GAP_ABOVE_HEAD_STUDS = 2.4
local MAX_VISIBLE_DISTANCE_STUDS = 80
local TEXT_FONT = Font.fromEnum(Enum.Font.GothamBold)

-- The engine name-display setting each humanoid had before a nameplate hid it.
local hiddenNameDisplayDistanceTypeByHumanoid: { [Humanoid]: Enum.HumanoidDisplayDistanceType } = setmetatable(
	{},
	{ __mode = "k" }
) :: any

local function toColor3(colorRgb): Color3
	return Color3.fromRGB(colorRgb.r, colorRgb.g, colorRgb.b)
end

local function createTextLabel(labelName: string, text: string, textColorRgb, outlineColorRgb): TextLabel
	local textLabel = Instance.new("TextLabel")
	textLabel.Name = labelName
	textLabel.BackgroundTransparency = 1
	textLabel.Text = text
	textLabel.TextScaled = true
	textLabel.FontFace = TEXT_FONT
	textLabel.TextColor3 = toColor3(textColorRgb)
	textLabel.TextStrokeColor3 = toColor3(outlineColorRgb)
	textLabel.TextStrokeTransparency = 0.2
	return textLabel
end

local function addPlateDecorations(plate: Frame, nameplateStyleLook)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, nameplateStyleLook.cornerRadiusPixels)
	corner.Parent = plate
	if nameplateStyleLook.plateGradientColorRgbs ~= nil then
		local keypoints = {}
		local colorCount = #nameplateStyleLook.plateGradientColorRgbs
		for colorIndex, colorRgb in nameplateStyleLook.plateGradientColorRgbs do
			table.insert(keypoints, ColorSequenceKeypoint.new((colorIndex - 1) / (colorCount - 1), toColor3(colorRgb)))
		end
		local gradient = Instance.new("UIGradient")
		gradient.Color = ColorSequence.new(keypoints)
		gradient.Rotation = nameplateStyleLook.plateGradientRotationDegrees
		gradient.Parent = plate
	end
	if nameplateStyleLook.frameLineColorRgb ~= nil then
		local frameLine = Instance.new("UIStroke")
		frameLine.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		frameLine.Color = toColor3(nameplateStyleLook.frameLineColorRgb)
		frameLine.Thickness = nameplateStyleLook.frameLineThicknessPixels
		frameLine.Parent = plate
	end
	for sparkleDotIndex = 1, nameplateStyleLook.sparkleDotCount do
		local sparkleDot = Instance.new("Frame")
		sparkleDot.Name = "SparkleDot" .. sparkleDotIndex
		sparkleDot.AnchorPoint = Vector2.new(0.5, 0.5)
		-- Spread along the plate's edges, alternating top and bottom; a small turned square.
		sparkleDot.Position = UDim2.fromScale(
			(sparkleDotIndex - 0.5) / nameplateStyleLook.sparkleDotCount,
			if sparkleDotIndex % 2 == 0 then 0.15 else 0.85
		)
		sparkleDot.Size = UDim2.fromScale(0.035, 0.14)
		sparkleDot.Rotation = 45
		sparkleDot.BorderSizePixel = 0
		sparkleDot.BackgroundColor3 = toColor3(nameplateStyleLook.sparkleDotColorRgb)
		sparkleDot.ZIndex = 2
		sparkleDot.Parent = plate
	end
end

local function createNameplate(playerDisplayName: string, nameplateStyleLook, topScale: number, heightScale: number)
	local plate = Instance.new("Frame")
	plate.Name = "NameplatePlate"
	plate.Position = UDim2.fromScale(0, topScale)
	plate.Size = UDim2.fromScale(1, heightScale)
	plate.BorderSizePixel = 0
	plate.BackgroundColor3 = if nameplateStyleLook.plateGradientColorRgbs
		then Color3.fromRGB(255, 255, 255)
		else toColor3(nameplateStyleLook.plateColorRgb)
	plate.BackgroundTransparency = nameplateStyleLook.plateTransparency
	addPlateDecorations(plate, nameplateStyleLook)
	local nameLabel = createTextLabel(
		"NameLabel",
		playerDisplayName,
		nameplateStyleLook.nameTextColorRgb,
		nameplateStyleLook.nameTextOutlineColorRgb
	)
	nameLabel.Position = UDim2.fromScale(0.05, 0.1)
	nameLabel.Size = UDim2.fromScale(0.9, 0.8)
	nameLabel.ZIndex = 3
	nameLabel.Parent = plate
	return plate
end

local function setEngineNameDisplayHidden(humanoid: Humanoid, shouldHide: boolean)
	local hiddenDisplayDistanceType = hiddenNameDisplayDistanceTypeByHumanoid[humanoid]
	if shouldHide and hiddenDisplayDistanceType == nil then
		hiddenNameDisplayDistanceTypeByHumanoid[humanoid] = humanoid.DisplayDistanceType
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	elseif not shouldHide and hiddenDisplayDistanceType ~= nil then
		humanoid.DisplayDistanceType = hiddenDisplayDistanceType
		hiddenNameDisplayDistanceTypeByHumanoid[humanoid] = nil
	end
end

function RobloxCharacterOverheadCosmeticDisplay.removeOverheadCosmetics(character: Model)
	local head = character:FindFirstChild("Head")
	local existingDisplay = if head
		then head:FindFirstChild(RobloxCharacterOverheadCosmeticDisplay.OVERHEAD_DISPLAY_NAME)
		else nil
	if existingDisplay ~= nil then
		existingDisplay:Destroy()
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		setEngineNameDisplayHidden(humanoid, false)
	end
end

function RobloxCharacterOverheadCosmeticDisplay.showOverheadCosmetics(
	character: Model,
	playerDisplayName: string,
	overheadCosmetics
)
	local head = character:FindFirstChild("Head")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if head == nil or humanoid == nil then
		error("RobloxCharacterOverheadCosmeticDisplay: the character has no Head or no Humanoid")
	end
	RobloxCharacterOverheadCosmeticDisplay.removeOverheadCosmetics(character)
	local titleHeightStuds = if overheadCosmetics.titleText then TITLE_HEIGHT_STUDS else 0
	local nameplateHeightStuds = if overheadCosmetics.nameplateStyleLook then NAMEPLATE_HEIGHT_STUDS else 0
	local totalHeightStuds = titleHeightStuds + nameplateHeightStuds
	local billboard = Instance.new("BillboardGui")
	billboard.Name = RobloxCharacterOverheadCosmeticDisplay.OVERHEAD_DISPLAY_NAME
	billboard.Adornee = head
	billboard.Size = UDim2.fromScale(BILLBOARD_WIDTH_STUDS, totalHeightStuds)
	billboard.StudsOffset = Vector3.new(0, GAP_ABOVE_HEAD_STUDS, 0)
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = MAX_VISIBLE_DISTANCE_STUDS
	billboard.LightInfluence = 0
	if overheadCosmetics.titleText then
		local titleLabel = createTextLabel(
			"TitleLabel",
			overheadCosmetics.titleText,
			{ r = 255, g = 255, b = 255 },
			{ r = 40, g = 30, b = 60 }
		)
		titleLabel.Size = UDim2.fromScale(1, titleHeightStuds / totalHeightStuds)
		titleLabel.Parent = billboard
	end
	if overheadCosmetics.nameplateStyleLook then
		createNameplate(
			playerDisplayName,
			overheadCosmetics.nameplateStyleLook,
			titleHeightStuds / totalHeightStuds,
			nameplateHeightStuds / totalHeightStuds
		).Parent =
			billboard
	end
	setEngineNameDisplayHidden(humanoid :: Humanoid, overheadCosmetics.nameplateStyleLook ~= nil)
	billboard.Parent = head
	return billboard
end

return RobloxCharacterOverheadCosmeticDisplay
