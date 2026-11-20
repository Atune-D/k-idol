-- LobbyOutfitPanelView (development spec §2.7): the Outfit panel of the lobby menu: the round's
-- wardrobe view reused outside a round (WardrobePanelView: the same item buttons, slot groups and
-- notices), under three large buttons: "Wear in lobby" (sends SetLobbyOutfit), "Saved outfit" (back to
-- the stored one) and "Own avatar" (empty outfit), and the answer in plain words. It shows
-- LobbyOutfitSelection's model; every decision is made there.
--
-- PUBLIC API
--   LobbyOutfitPanelView.create(contentFrame, { onWardrobeItemActivated(stylingItemKey),
--       onConfirmActivated(), onRestoreActivated(), onClearActivated() }) -> view
--   view:render(lobbyOutfitPanelModel)
--   Instances (for checks in a playtest): <contentFrame>.OutfitControls with Buttons.{ConfirmButton,
--   RestoreButton, ClearButton}, ConfirmFeedbackLabel, StoredOutfitLabel; <contentFrame>.WardrobePanel
--   (WardrobePanelView's instances: ItemList.SlotGroupN.Item_<stylingItemKey> with IsSelected).
--
-- Roblox API used: see DeviceInterfaceElementFactory and WardrobePanelView; UIGridLayout .CellSize,
--   .CellPadding, .SortOrder   https://create.roblox.com/docs/reference/engine/classes/UIGridLayout

local DeviceInterfaceElementFactory = require("./DeviceInterfaceElementFactory")
local WardrobePanelView = require("./WardrobePanelView")

local LobbyOutfitPanelView = {}
LobbyOutfitPanelView.__index = LobbyOutfitPanelView

local COLORS = DeviceInterfaceElementFactory.COLORS
local CONTROLS_HEIGHT_PIXELS = 124

function LobbyOutfitPanelView.create(contentFrame: Frame, callbacks)
	local controls = Instance.new("Frame")
	controls.Name = "OutfitControls"
	controls.BackgroundTransparency = 1
	controls.Size = UDim2.new(1, 0, 0, CONTROLS_HEIGHT_PIXELS)
	controls.Parent = contentFrame
	DeviceInterfaceElementFactory.createVerticalList(controls, 4)
	local buttons = Instance.new("Frame")
	buttons.Name = "Buttons"
	buttons.BackgroundTransparency = 1
	buttons.Size = UDim2.new(1, 0, 0, DeviceInterfaceElementFactory.MINIMUM_TOUCH_TARGET_HEIGHT_PIXELS)
	buttons.LayoutOrder = 1
	buttons.Parent = controls
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(1 / 3, -4, 0, DeviceInterfaceElementFactory.MINIMUM_TOUCH_TARGET_HEIGHT_PIXELS)
	grid.CellPadding = UDim2.fromOffset(4, 0)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = buttons
	for buttonPosition, buttonSpec in
		{
			{ "ConfirmButton", "Wear in lobby", callbacks.onConfirmActivated },
			{ "RestoreButton", "Saved outfit", callbacks.onRestoreActivated },
			{ "ClearButton", "Own avatar", callbacks.onClearActivated },
		}
	do
		local button = DeviceInterfaceElementFactory.createTextButton(
			buttonSpec[1],
			buttons,
			buttonSpec[2],
			buttonPosition,
			buttonSpec[3]
		)
		button.TextSize = 16
	end
	local feedbackLabel = DeviceInterfaceElementFactory.createTextLabel("ConfirmFeedbackLabel", controls, 16, 2)
	feedbackLabel.TextColor3 = COLORS.noticeText
	local storedOutfitLabel = DeviceInterfaceElementFactory.createTextLabel("StoredOutfitLabel", controls, 16, 3)
	storedOutfitLabel.TextColor3 = COLORS.mutedText
	local wardrobePanelView = WardrobePanelView.create(contentFrame, callbacks.onWardrobeItemActivated)
	wardrobePanelView.panel.Position = UDim2.fromOffset(0, CONTROLS_HEIGHT_PIXELS)
	wardrobePanelView.panel.Size = UDim2.new(1, 0, 1, -CONTROLS_HEIGHT_PIXELS)
	return setmetatable({
		feedbackLabel = feedbackLabel,
		storedOutfitLabel = storedOutfitLabel,
		wardrobePanelView = wardrobePanelView,
	}, LobbyOutfitPanelView)
end

function LobbyOutfitPanelView:render(model)
	DeviceInterfaceElementFactory.setLabelText(self.feedbackLabel, model.confirmFeedbackText)
	DeviceInterfaceElementFactory.setLabelText(self.storedOutfitLabel, model.storedOutfitText)
	self.wardrobePanelView:render(model.wardrobePanel)
end

return LobbyOutfitPanelView
