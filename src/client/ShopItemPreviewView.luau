-- ShopItemPreviewView (development spec §0.2 "generated in code", §1.7): draws a shop item's preview
-- from ShopPanelModelBuilder's preview model, with plain interface instances only (no image or asset).
-- Everything is still: nothing moves, blinks or changes colour.
--   * Title: the title text, white with a dark outline (as the server shows it above the head).
--   * NameplateStyle: a plate drawn from the shared NameplateStyleLook exactly as the server's
--     RobloxCharacterOverheadCosmeticDisplay draws it (colour or gradient, frame line, rounded corners,
--     sparkle dots), with the player's own display name on it.
--   * StageEntranceEffect: a small dark stage box with a plain silhouette for the performer, a soft
--     glow when the effect has a light, and one dot per piece where StageEntranceEffectPreviewDotPlanner
--     places it.
--
-- PUBLIC API
--   ShopItemPreviewView.createPreview(parent, preview, playerDisplayName, layoutOrder) -> GuiObject?
--     nil for a nil preview. The created instance is named "Preview" and carries the attribute
--     PreviewKind.
--
-- Roblox API used, read in the official documentation (create.roblox.com/docs/reference/engine/...):
--   Frame, TextLabel (.TextScaled, .TextStrokeColor3, .TextStrokeTransparency, .FontFace), GuiObject
--     (.Size, .Position, .AnchorPoint, .BackgroundColor3, .BackgroundTransparency, .BorderSizePixel,
--     .Rotation, .ZIndex, .ClipsDescendants, .LayoutOrder)   classes/TextLabel, classes/GuiObject
--   UICorner.CornerRadius, UIStroke .Color/.Thickness/.ApplyStrokeMode, UIGradient .Color/.Rotation
--                                                    classes/UICorner, classes/UIStroke, classes/UIGradient
--   Enum.ApplyStrokeMode.Border   enums/ApplyStrokeMode
--   ColorSequence.new, ColorSequenceKeypoint.new, Color3.fromRGB, UDim2, UDim, Vector2, Font.fromEnum
--                                                    datatypes/...
--   Instance.new, :SetAttribute                      classes/Instance

local ShopItemPreviewView = {}

local TEXT_FONT = Font.fromEnum(Enum.Font.GothamBold)
local NAMEPLATE_SIZE = UDim2.fromOffset(220, 40)
local ENTRANCE_BOX_SIZE = UDim2.fromOffset(120, 120)

local function toColor3(colorRgb): Color3
	return Color3.fromRGB(colorRgb.r, colorRgb.g, colorRgb.b)
end

local function createOutlinedText(name: string, text: string, textColorRgb, outlineColorRgb): TextLabel
	local textLabel = Instance.new("TextLabel")
	textLabel.Name = name
	textLabel.BackgroundTransparency = 1
	textLabel.Text = text
	textLabel.TextScaled = true
	textLabel.FontFace = TEXT_FONT
	textLabel.TextColor3 = toColor3(textColorRgb)
	textLabel.TextStrokeColor3 = toColor3(outlineColorRgb)
	textLabel.TextStrokeTransparency = 0.2
	return textLabel
end

local function createTitlePreview(titleText: string): GuiObject
	local holder = Instance.new("Frame")
	holder.BackgroundColor3 = Color3.fromRGB(70, 62, 96)
	holder.BorderSizePixel = 0
	holder.Size = NAMEPLATE_SIZE
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = holder
	local titleLabel = createOutlinedText(
		"TitleLabel",
		titleText,
		{ r = 255, g = 255, b = 255 },
		{ r = 40, g = 30, b = 60 }
	)
	titleLabel.Size = UDim2.fromScale(0.9, 0.7)
	titleLabel.Position = UDim2.fromScale(0.05, 0.15)
	titleLabel.Parent = holder
	return holder
end

local function decorateNameplate(plate: Frame, look)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, look.cornerRadiusPixels)
	corner.Parent = plate
	if look.plateGradientColorRgbs ~= nil then
		local keypoints = {}
		local colorCount = #look.plateGradientColorRgbs
		for colorIndex, colorRgb in look.plateGradientColorRgbs do
			table.insert(keypoints, ColorSequenceKeypoint.new((colorIndex - 1) / (colorCount - 1), toColor3(colorRgb)))
		end
		local gradient = Instance.new("UIGradient")
		gradient.Color = ColorSequence.new(keypoints)
		gradient.Rotation = look.plateGradientRotationDegrees
		gradient.Parent = plate
	end
	if look.frameLineColorRgb ~= nil then
		local frameLine = Instance.new("UIStroke")
		frameLine.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		frameLine.Color = toColor3(look.frameLineColorRgb)
		frameLine.Thickness = look.frameLineThicknessPixels
		frameLine.Parent = plate
	end
	for sparkleDotIndex = 1, look.sparkleDotCount do
		local sparkleDot = Instance.new("Frame")
		sparkleDot.Name = "SparkleDot" .. sparkleDotIndex
		sparkleDot.AnchorPoint = Vector2.new(0.5, 0.5)
		sparkleDot.Position = UDim2.fromScale(
			(sparkleDotIndex - 0.5) / look.sparkleDotCount,
			if sparkleDotIndex % 2 == 0 then 0.15 else 0.85
		)
		sparkleDot.Size = UDim2.fromScale(0.035, 0.14)
		sparkleDot.Rotation = 45
		sparkleDot.BorderSizePixel = 0
		sparkleDot.BackgroundColor3 = toColor3(look.sparkleDotColorRgb)
		sparkleDot.ZIndex = 2
		sparkleDot.Parent = plate
	end
end

local function createNameplatePreview(look, playerDisplayName: string): GuiObject
	local plate = Instance.new("Frame")
	plate.Size = NAMEPLATE_SIZE
	plate.BorderSizePixel = 0
	plate.BackgroundColor3 = if look.plateGradientColorRgbs
		then Color3.fromRGB(255, 255, 255)
		else toColor3(look.plateColorRgb)
	plate.BackgroundTransparency = look.plateTransparency
	decorateNameplate(plate, look)
	local nameLabel =
		createOutlinedText("NameLabel", playerDisplayName, look.nameTextColorRgb, look.nameTextOutlineColorRgb)
	nameLabel.Position = UDim2.fromScale(0.05, 0.1)
	nameLabel.Size = UDim2.fromScale(0.9, 0.8)
	nameLabel.ZIndex = 3
	nameLabel.Parent = plate
	return plate
end

local function createScaledFrame(
	name: string,
	parent: Instance,
	centerX: number,
	centerY: number,
	width: number,
	height: number
)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(centerX, centerY)
	frame.Size = UDim2.fromScale(width, height)
	frame.BorderSizePixel = 0
	frame.Parent = parent
	return frame
end

local function createEntranceEffectPreview(entranceEffectPreview): GuiObject
	local performerBox = entranceEffectPreview.performerBox
	local stageBox = Instance.new("Frame")
	stageBox.Size = ENTRANCE_BOX_SIZE
	stageBox.BackgroundColor3 = Color3.fromRGB(22, 18, 36)
	stageBox.BorderSizePixel = 0
	stageBox.ClipsDescendants = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = stageBox
	local performerCenterY = performerBox.bottomYScale - performerBox.heightScale / 2
	if entranceEffectPreview.hasLight then
		local glow = createScaledFrame("Glow", stageBox, performerBox.centerXScale, performerCenterY, 0.6, 0.6)
		glow.BackgroundColor3 = toColor3(entranceEffectPreview.lightColorRgb)
		glow.BackgroundTransparency = 0.75
		local glowCorner = Instance.new("UICorner")
		glowCorner.CornerRadius = UDim.new(0.5, 0)
		glowCorner.Parent = glow
	end
	local performer = createScaledFrame(
		"Performer",
		stageBox,
		performerBox.centerXScale,
		performerCenterY,
		performerBox.widthScale,
		performerBox.heightScale
	)
	performer.BackgroundColor3 = Color3.fromRGB(150, 140, 175)
	performer.ZIndex = 2
	for dotPosition, dot in entranceEffectPreview.dots do
		local dotFrame = createScaledFrame(
			"Piece" .. dotPosition,
			stageBox,
			dot.centerXScale,
			dot.centerYScale,
			dot.widthScale,
			dot.heightScale
		)
		dotFrame.BackgroundColor3 = toColor3(dot.colorRgb)
		dotFrame.BackgroundTransparency = dot.transparency
		dotFrame.ZIndex = 3
	end
	return stageBox
end

function ShopItemPreviewView.createPreview(parent: Instance, preview, playerDisplayName: string, layoutOrder: number)
	if preview == nil then
		return nil
	end
	local previewObject
	if preview.previewKind == "Title" then
		previewObject = createTitlePreview(preview.titleText)
	elseif preview.previewKind == "NameplateStyle" then
		previewObject = createNameplatePreview(preview.nameplateStyleLook, playerDisplayName)
	else
		previewObject = createEntranceEffectPreview(preview.entranceEffectPreview)
	end
	previewObject.Name = "Preview"
	previewObject.LayoutOrder = layoutOrder
	previewObject:SetAttribute("PreviewKind", preview.previewKind)
	previewObject.Parent = parent
	return previewObject
end

return ShopItemPreviewView
