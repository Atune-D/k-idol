-- WardrobePanelView: the wardrobe during Styling (spec §2.3, §2.14): the saving status, the notices,
-- and the items grouped by slot, one large button per item showing its name and price. Tapping an
-- item hands its stylingItemKey to onWardrobeItemActivated; WHAT that does is decided by
-- ThemedRoundDeviceSession and WardrobeSelectionRules, never here. It only shows
-- ThemedRoundScreenModelBuilder's wardrobePanel model.
-- Item buttons are rebuilt only when the listed items change; otherwise their text, colour and
-- enabled state are updated in place.
--
-- PUBLIC API
--   WardrobePanelView.create(screenGui, onWardrobeItemActivated(stylingItemKey)) -> view
--   view:render(wardrobePanelModel)
--   Instances (for checks in a playtest): <screenGui>.WardrobePanel with SavingStatusLabel,
--   WardrobeNoticeLabel, PutBackNoticeLabel, SelectionRefusalLabel, SelectedItemCountLabel, and
--   ItemList.SlotGroupN.{SlotTitle, Item_<stylingItemKey>}. Each item button carries the attributes
--   StylingItemKey, IsSelected and IsEnabled; the panel carries IsLocked.
--
-- Roblox API used: see DeviceInterfaceElementFactory; Instance:SetAttribute, :Destroy
--   https://create.roblox.com/docs/reference/engine/classes/Instance
--   GuiObject.AbsoluteSize (GuiBase2d)   https://create.roblox.com/docs/reference/engine/classes/GuiBase2d

local DeviceInterfaceElementFactory = require("./DeviceInterfaceElementFactory")

local WardrobePanelView = {}
WardrobePanelView.__index = WardrobePanelView

local COLORS = DeviceInterfaceElementFactory.COLORS

function WardrobePanelView.create(screenGui: ScreenGui, onWardrobeItemActivated: (string) -> ())
	local panel = DeviceInterfaceElementFactory.createPanel("WardrobePanel", screenGui)
	panel.Position = UDim2.fromOffset(10, 130)
	panel.Size = UDim2.new(0.3, 0, 1, -140)
	panel.Visible = false
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.fromScale(1, 0)
	header.AutomaticSize = Enum.AutomaticSize.Y
	header.Parent = panel
	DeviceInterfaceElementFactory.createVerticalList(header, 4)
	local create = DeviceInterfaceElementFactory.createTextLabel
	local view = setmetatable({
		panel = panel,
		header = header,
		onWardrobeItemActivated = onWardrobeItemActivated,
		itemButtonByStylingItemKey = {},
		renderedItemSignature = nil,
	}, WardrobePanelView)
	create("WardrobeTitle", header, 22, 1).Text = "Wardrobe"
	view.savingStatusLabel = create("SavingStatusLabel", header, 18, 2)
	view.wardrobeNoticeLabel = create("WardrobeNoticeLabel", header, 18, 3)
	view.wardrobeNoticeLabel.TextColor3 = COLORS.noticeText
	view.putBackNoticeLabel = create("PutBackNoticeLabel", header, 16, 4)
	view.putBackNoticeLabel.TextColor3 = COLORS.noticeText
	view.selectionRefusalLabel = create("SelectionRefusalLabel", header, 16, 5)
	view.selectionRefusalLabel.TextColor3 = COLORS.noticeText
	view.selectedItemCountLabel = create("SelectedItemCountLabel", header, 16, 6)
	view.itemList = DeviceInterfaceElementFactory.createScrollingList("ItemList", panel)
	view.itemList.Position = UDim2.fromOffset(0, 150)
	view.itemList.Size = UDim2.new(1, 0, 1, -150)
	DeviceInterfaceElementFactory.createVerticalList(view.itemList, 8)
	return view
end

local function setLabelText(label: TextLabel, text: string)
	label.Text = text
	label.Visible = text ~= ""
end

local function buildItemSignature(slotGroups): string
	local parts = {}
	for _, slotGroup in slotGroups do
		table.insert(parts, slotGroup.slotTitleText)
		for _, itemButton in slotGroup.itemButtons do
			table.insert(
				parts,
				itemButton.stylingItemKey .. "=" .. itemButton.itemNameText .. "=" .. itemButton.itemPriceText
			)
		end
	end
	return table.concat(parts, "\n")
end

function WardrobePanelView:rebuildItemButtons(slotGroups)
	for _, child in self.itemList:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	table.clear(self.itemButtonByStylingItemKey)
	for slotGroupPosition, slotGroup in slotGroups do
		local groupFrame = Instance.new("Frame")
		groupFrame.Name = "SlotGroup" .. slotGroupPosition
		groupFrame.BackgroundTransparency = 1
		groupFrame.Size = UDim2.new(1, -12, 0, 0)
		groupFrame.AutomaticSize = Enum.AutomaticSize.Y
		groupFrame.LayoutOrder = slotGroupPosition
		groupFrame.Parent = self.itemList
		DeviceInterfaceElementFactory.createVerticalList(groupFrame, 6)
		local title = DeviceInterfaceElementFactory.createTextLabel("SlotTitle", groupFrame, 18, 0)
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextColor3 = COLORS.mutedText
		title.Text = slotGroup.slotTitleText
		for itemPosition, itemButtonModel in slotGroup.itemButtons do
			local stylingItemKey = itemButtonModel.stylingItemKey
			local button = DeviceInterfaceElementFactory.createTextButton(
				"Item_" .. stylingItemKey,
				groupFrame,
				"",
				itemPosition,
				function()
					self.onWardrobeItemActivated(stylingItemKey)
				end
			)
			button.Size = UDim2.new(1, 0, 0, DeviceInterfaceElementFactory.MINIMUM_TOUCH_TARGET_HEIGHT_PIXELS + 8)
			button.TextSize = 18
			button:SetAttribute("StylingItemKey", stylingItemKey)
			self.itemButtonByStylingItemKey[stylingItemKey] = button
		end
	end
end

function WardrobePanelView:render(wardrobePanelModel)
	self.panel.Visible = wardrobePanelModel.isVisible
	self.panel:SetAttribute("IsLocked", wardrobePanelModel.isLocked)
	if not wardrobePanelModel.isVisible then
		return
	end
	setLabelText(self.savingStatusLabel, wardrobePanelModel.savingStatusText)
	setLabelText(self.wardrobeNoticeLabel, wardrobePanelModel.wardrobeNoticeText)
	setLabelText(self.putBackNoticeLabel, wardrobePanelModel.putBackNoticeText)
	setLabelText(self.selectionRefusalLabel, wardrobePanelModel.selectionRefusalText)
	setLabelText(self.selectedItemCountLabel, wardrobePanelModel.selectedItemCountText)
	-- The header grows with its notices; the list starts below it (AbsoluteSize is the header's
	-- size from the last layout pass, so this settles on the next render).
	local listTop = self.header.AbsoluteSize.Y + 8
	self.itemList.Position = UDim2.fromOffset(0, listTop)
	self.itemList.Size = UDim2.new(1, 0, 1, -listTop)
	local signature = buildItemSignature(wardrobePanelModel.slotGroups)
	if signature ~= self.renderedItemSignature then
		self.renderedItemSignature = signature
		self:rebuildItemButtons(wardrobePanelModel.slotGroups)
	end
	local listedPosition = 0
	for _, slotGroup in wardrobePanelModel.slotGroups do
		for _, itemButtonModel in slotGroup.itemButtons do
			listedPosition += 1
			local button = self.itemButtonByStylingItemKey[itemButtonModel.stylingItemKey]
			-- Keys 1 to 9 tap the first nine listed items (DeviceKeyboardShortcutDecision).
			local keyHint = if listedPosition <= 9 then string.format("(%d) ", listedPosition) else ""
			local wearingMark = if itemButtonModel.isSelected then "Wearing: " else ""
			button.Text = string.format(
				"%s%s%s\n%s",
				keyHint,
				wearingMark,
				itemButtonModel.itemNameText,
				itemButtonModel.itemPriceText
			)
			DeviceInterfaceElementFactory.setButtonEnabled(button, itemButtonModel.isEnabled)
			if itemButtonModel.isSelected and itemButtonModel.isEnabled then
				button.BackgroundColor3 = COLORS.selectedItemBackground
			elseif itemButtonModel.isEnabled then
				button.BackgroundColor3 = COLORS.itemBackground
			end
			button:SetAttribute("IsSelected", itemButtonModel.isSelected)
		end
	end
end

return WardrobePanelView
