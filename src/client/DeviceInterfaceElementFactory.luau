-- DeviceInterfaceElementFactory (spec §3.1 🔴 "the interface is built in code"; decision 16 "touch
-- first, keyboard and mouse supported"): creates the plain interface instances every Phase 1 screen
-- is made of, with one consistent look. Only plain instances and colours: no image, no uploaded or
-- inserted asset.
-- Touch first: every button is at least MINIMUM_TOUCH_TARGET_HEIGHT_PIXELS tall and acts on
-- GuiButton.Activated (mouse click, touch release, gamepad), never on hover.
--
-- PUBLIC API
--   DeviceInterfaceElementFactory.COLORS   frozen palette (Color3)
--   DeviceInterfaceElementFactory.MINIMUM_TOUCH_TARGET_HEIGHT_PIXELS = 52
--   createPanel(name, parent) -> Frame                 rounded, padded, dark translucent
--   createVerticalList(parent, paddingPixels) -> UIListLayout   children ordered by LayoutOrder
--   createTextLabel(name, parent, textSize, layoutOrder) -> TextLabel   wraps, grows in height
--   createTextButton(name, parent, text, layoutOrder, onActivated) -> TextButton
--   createScrollingList(name, parent) -> ScrollingFrame   vertical, canvas grows with its content
--   setButtonEnabled(button, isEnabled)                greyed and inactive when disabled
--   PLAYTEST_ACTIVATION_ATTRIBUTE_NAME = "PlaytestActivationRequestCount"   ONLY when RunService:IsStudio()
--     is true, every button also acts (as a tap would, enabled check included) when this attribute
--     changes, so a Studio check can press a button from the Client datamodel when Studio's input
--     tools time out. Outside Studio the attribute does nothing.
--
-- Roblox API used, read in the official documentation (create.roblox.com/docs/reference/engine/...):
--   Instance.new, .Name, .Parent, :GetAttributeChangedSignal   classes/Instance
--   RunService:IsStudio() ("Returns whether the current environment is running in Studio")   classes/RunService
--   Frame, TextLabel, TextButton, ScrollingFrame        classes/Frame, classes/TextLabel, classes/TextButton,
--                                                      classes/ScrollingFrame
--   GuiObject.Size, .Position, .AnchorPoint, .AutomaticSize, .BackgroundColor3, .BackgroundTransparency,
--     .BorderSizePixel, .LayoutOrder, .Visible, .Active   classes/GuiObject
--   TextLabel/TextButton .Text, .TextColor3, .TextSize, .TextWrapped, .TextXAlignment, .FontFace
--     (Font is Hidden; FontFace is the documented property)   classes/TextLabel, classes/TextButton
--   GuiButton.Activated (left click press-and-release, touch release, gamepad A), .AutoButtonColor
--                                                      classes/GuiButton
--   ScrollingFrame.AutomaticCanvasSize, .CanvasSize, .ScrollBarThickness, .ScrollingDirection
--                                                      classes/ScrollingFrame
--   UIListLayout (.Padding, .FillDirection, .SortOrder = LayoutOrder, .HorizontalAlignment)
--                                                      classes/UIListLayout
--   UIPadding (.PaddingTop/Bottom/Left/Right), UICorner (.CornerRadius)   classes/UIPadding, classes/UICorner
--   UDim2.new, UDim2.fromScale, UDim2.fromOffset, UDim.new   datatypes/UDim2, datatypes/UDim
--   Color3.fromRGB                                     datatypes/Color3
--   Font.fromEnum(Enum.Font.*)                         datatypes/Font
--   Enum.AutomaticSize, Enum.TextXAlignment, Enum.ScrollingDirection, Enum.SortOrder,
--     Enum.FillDirection, Enum.HorizontalAlignment, Enum.Font   enums/...

local RunService = game:GetService("RunService")

local DeviceInterfaceElementFactory = {}

DeviceInterfaceElementFactory.PLAYTEST_ACTIVATION_ATTRIBUTE_NAME = "PlaytestActivationRequestCount"

DeviceInterfaceElementFactory.COLORS = table.freeze({
	panelBackground = Color3.fromRGB(30, 24, 48),
	panelText = Color3.fromRGB(245, 240, 255),
	mutedText = Color3.fromRGB(190, 180, 215),
	noticeText = Color3.fromRGB(255, 214, 102),
	buttonBackground = Color3.fromRGB(235, 92, 160),
	buttonText = Color3.fromRGB(255, 255, 255),
	disabledButtonBackground = Color3.fromRGB(90, 84, 110),
	itemBackground = Color3.fromRGB(58, 48, 86),
	selectedItemBackground = Color3.fromRGB(120, 200, 150),
	localPlayerRowBackground = Color3.fromRGB(80, 64, 120),
})

DeviceInterfaceElementFactory.MINIMUM_TOUCH_TARGET_HEIGHT_PIXELS = 52

local COLORS = DeviceInterfaceElementFactory.COLORS
local BODY_FONT = Font.fromEnum(Enum.Font.Gotham)
local BUTTON_FONT = Font.fromEnum(Enum.Font.GothamBold)

local function addCorner(parent: Instance, radiusPixels: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radiusPixels)
	corner.Parent = parent
end

local function addPadding(parent: Instance, paddingPixels: number)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, paddingPixels)
	padding.PaddingBottom = UDim.new(0, paddingPixels)
	padding.PaddingLeft = UDim.new(0, paddingPixels)
	padding.PaddingRight = UDim.new(0, paddingPixels)
	padding.Parent = parent
end

function DeviceInterfaceElementFactory.createPanel(name: string, parent: Instance): Frame
	local panel = Instance.new("Frame")
	panel.Name = name
	panel.BackgroundColor3 = COLORS.panelBackground
	panel.BackgroundTransparency = 0.12
	panel.BorderSizePixel = 0
	addCorner(panel, 12)
	addPadding(panel, 10)
	panel.Parent = parent
	return panel
end

function DeviceInterfaceElementFactory.createVerticalList(parent: Instance, paddingPixels: number): UIListLayout
	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.Padding = UDim.new(0, paddingPixels)
	listLayout.Parent = parent
	return listLayout
end

function DeviceInterfaceElementFactory.createTextLabel(
	name: string,
	parent: Instance,
	textSize: number,
	layoutOrder: number
): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.FontFace = BODY_FONT
	label.TextSize = textSize
	label.TextWrapped = true
	label.TextColor3 = COLORS.panelText
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.Text = ""
	label.LayoutOrder = layoutOrder
	label.Parent = parent
	return label
end

function DeviceInterfaceElementFactory.setButtonEnabled(button: TextButton, isEnabled: boolean)
	button.Active = isEnabled
	button.AutoButtonColor = isEnabled
	button.BackgroundColor3 = if isEnabled then COLORS.buttonBackground else COLORS.disabledButtonBackground
	button:SetAttribute("IsEnabled", isEnabled)
end

function DeviceInterfaceElementFactory.createTextButton(
	name: string,
	parent: Instance,
	text: string,
	layoutOrder: number,
	onActivated: () -> ()
): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = UDim2.new(1, 0, 0, DeviceInterfaceElementFactory.MINIMUM_TOUCH_TARGET_HEIGHT_PIXELS)
	button.BorderSizePixel = 0
	button.FontFace = BUTTON_FONT
	button.TextSize = 20
	button.TextWrapped = true
	button.TextColor3 = COLORS.buttonText
	button.Text = text
	button.LayoutOrder = layoutOrder
	addCorner(button, 10)
	DeviceInterfaceElementFactory.setButtonEnabled(button, true)
	local function activateIfEnabled()
		-- A disabled button ignores activation (Active only stops input sinking, not Activated).
		if button:GetAttribute("IsEnabled") == true then
			onActivated()
		end
	end
	button.Activated:Connect(activateIfEnabled)
	if RunService:IsStudio() then
		-- Studio-only playtest hook: changing this attribute from the Client datamodel acts exactly as a
		-- tap (same enabled check, same callback), for checks where Studio's input tools time out.
		button
			:GetAttributeChangedSignal(DeviceInterfaceElementFactory.PLAYTEST_ACTIVATION_ATTRIBUTE_NAME)
			:Connect(activateIfEnabled)
	end
	button.Parent = parent
	return button
end

function DeviceInterfaceElementFactory.createScrollingList(name: string, parent: Instance): ScrollingFrame
	local scrollingList = Instance.new("ScrollingFrame")
	scrollingList.Name = name
	scrollingList.BackgroundTransparency = 1
	scrollingList.BorderSizePixel = 0
	scrollingList.ScrollingDirection = Enum.ScrollingDirection.Y
	scrollingList.ScrollBarThickness = 8
	scrollingList.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollingList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollingList.Parent = parent
	return scrollingList
end

-- Phase 2 additions (lobby screens).

function DeviceInterfaceElementFactory.setLabelText(label: TextLabel, text: string)
	label.Text = text
	label.Visible = text ~= ""
end

-- A transparent frame that stacks its children vertically and grows with them (one list row).
function DeviceInterfaceElementFactory.createRowContainer(
	name: string,
	parent: Instance,
	layoutOrder: number,
	paddingPixels: number
): Frame
	local rowContainer = Instance.new("Frame")
	rowContainer.Name = name
	rowContainer.BackgroundTransparency = 1
	rowContainer.BorderSizePixel = 0
	rowContainer.Size = UDim2.new(1, -12, 0, 0)
	rowContainer.AutomaticSize = Enum.AutomaticSize.Y
	rowContainer.LayoutOrder = layoutOrder
	DeviceInterfaceElementFactory.createVerticalList(rowContainer, paddingPixels)
	rowContainer.Parent = parent
	return rowContainer
end

-- A boxed row (item background, rounded, padded) that grows with its children.
function DeviceInterfaceElementFactory.createItemCard(name: string, parent: Instance, layoutOrder: number): Frame
	local itemCard = DeviceInterfaceElementFactory.createRowContainer(name, parent, layoutOrder, 4)
	itemCard.BackgroundTransparency = 0
	itemCard.BackgroundColor3 = COLORS.itemBackground
	addCorner(itemCard, 10)
	addPadding(itemCard, 8)
	return itemCard
end

-- A text entry box (TextBox), one line, touch-sized. TextBox .PlaceholderText, .ClearTextOnFocus,
-- .Text: https://create.roblox.com/docs/reference/engine/classes/TextBox
function DeviceInterfaceElementFactory.createTextBox(
	name: string,
	parent: Instance,
	placeholderText: string,
	layoutOrder: number
): TextBox
	local textBox = Instance.new("TextBox")
	textBox.Name = name
	textBox.Size = UDim2.new(1, 0, 0, DeviceInterfaceElementFactory.MINIMUM_TOUCH_TARGET_HEIGHT_PIXELS)
	textBox.BackgroundColor3 = Color3.fromRGB(250, 248, 255)
	textBox.BorderSizePixel = 0
	textBox.FontFace = BODY_FONT
	textBox.TextSize = 20
	textBox.TextColor3 = Color3.fromRGB(30, 24, 48)
	textBox.PlaceholderText = placeholderText
	textBox.PlaceholderColor3 = Color3.fromRGB(120, 112, 140)
	textBox.ClearTextOnFocus = false
	textBox.Text = ""
	textBox.LayoutOrder = layoutOrder
	addCorner(textBox, 10)
	textBox.Parent = parent
	return textBox
end

-- Destroys every child of `parent` that is a GuiObject (the list layout and other modifiers stay).
function DeviceInterfaceElementFactory.destroyGuiChildren(parent: Instance)
	for _, child in parent:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

return table.freeze(DeviceInterfaceElementFactory)
