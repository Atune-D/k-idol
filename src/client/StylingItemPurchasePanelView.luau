-- StylingItemPurchasePanelView (development spec §2.12): the wardrobe's Buy panel, under the wardrobe
-- preview: the focused item's name, whether the player owns it, and for an item not owned a
-- "Buy for N Robux" button with, in Roblox Studio, the plain-words explanation that buying is switched
-- off there. It shows StylingItemPurchasePanelModelBuilder's model. The Buy button only calls
-- onBuyActivated(); whether a purchase prompt may open is decided by MarketplacePurchasePromptPermission
-- in the wiring, never here, and this file never asks the engine to open a prompt.
--
-- PUBLIC API
--   StylingItemPurchasePanelView.create(screenGui, onBuyActivated()) -> view
--   view:render(purchasePanelModel)
--   Instances (for checks in a playtest): <screenGui>.StylingItemPurchasePanel (attributes
--   StylingItemKey, IsBuyButtonVisible) with ItemNameLabel, OwnershipLabel, BuyButton, ExplanationLabel.
--
-- Roblox API used: see DeviceInterfaceElementFactory; Instance:SetAttribute
--   https://create.roblox.com/docs/reference/engine/classes/Instance

local DeviceInterfaceElementFactory = require("./DeviceInterfaceElementFactory")

local StylingItemPurchasePanelView = {}
StylingItemPurchasePanelView.__index = StylingItemPurchasePanelView

local COLORS = DeviceInterfaceElementFactory.COLORS

function StylingItemPurchasePanelView.create(screenGui: ScreenGui, onBuyActivated: () -> ())
	local panel = DeviceInterfaceElementFactory.createPanel("StylingItemPurchasePanel", screenGui)
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -10, 0.6, 140)
	panel.Size = UDim2.fromScale(0.24, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.Visible = false
	DeviceInterfaceElementFactory.createVerticalList(panel, 4)
	local itemNameLabel = DeviceInterfaceElementFactory.createTextLabel("ItemNameLabel", panel, 18, 1)
	local ownershipLabel = DeviceInterfaceElementFactory.createTextLabel("OwnershipLabel", panel, 16, 2)
	ownershipLabel.TextColor3 = COLORS.mutedText
	local buyButton = DeviceInterfaceElementFactory.createTextButton("BuyButton", panel, "", 3, onBuyActivated)
	local explanationLabel = DeviceInterfaceElementFactory.createTextLabel("ExplanationLabel", panel, 14, 4)
	explanationLabel.TextColor3 = COLORS.noticeText
	return setmetatable({
		panel = panel,
		itemNameLabel = itemNameLabel,
		ownershipLabel = ownershipLabel,
		buyButton = buyButton,
		explanationLabel = explanationLabel,
	}, StylingItemPurchasePanelView)
end

function StylingItemPurchasePanelView:render(model)
	self.panel.Visible = model.isVisible
	self.panel:SetAttribute("StylingItemKey", model.stylingItemKey or "")
	self.panel:SetAttribute("IsBuyButtonVisible", model.isBuyButtonVisible)
	self.itemNameLabel.Text = model.itemNameText
	self.ownershipLabel.Text = model.ownershipText
	self.buyButton.Visible = model.isBuyButtonVisible
	self.buyButton.Text = model.buyButtonText
	DeviceInterfaceElementFactory.setLabelText(self.explanationLabel, model.explanationText)
end

return StylingItemPurchasePanelView
