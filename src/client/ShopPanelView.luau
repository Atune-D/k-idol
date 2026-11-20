-- ShopPanelView (development spec §1.7, §2.8): the shop panel of the lobby menu. It shows
-- ShopPanelModelBuilder's model: the balance line, then the four groups (Dances, Titles, Nameplate
-- styles, Stage entrance effects), each item as a card with its name, price, ownership, preview, Buy
-- and Equip buttons, the missing Star Coins and the latest answer. It decides nothing: Buy and Equip
-- hand the row to a callback.
-- The cards are built once per set of items (the 47 cosmetics and their previews are not rebuilt five
-- times a second); texts, visibility and enabled state are updated in place on every render.
--
-- PUBLIC API
--   ShopPanelView.create(contentFrame, { onBuyShopItem(itemRow), onEquipShopItem(itemRow) }, playerDisplayName) -> view
--   view:render(shopPanelModel)
--   Instances (for checks in a playtest): <contentFrame>.ShopList with BalanceLabel, LoadingLabel and
--   Group<N>.{GroupTitle, EmptyGroupLabel, Item_<itemId>.{NameLabel, PriceLabel, OwnershipLabel, Preview,
--   BuyButton, MissingStarCoinsLabel, EquipButton, FeedbackLabel}}. Each card carries the attributes
--   ItemId, IsOwned and IsEquipped (from the model, i.e. the latest snapshot).
--
-- Roblox API used: see DeviceInterfaceElementFactory and ShopItemPreviewView; Instance:SetAttribute
--   https://create.roblox.com/docs/reference/engine/classes/Instance

local DeviceInterfaceElementFactory = require("./DeviceInterfaceElementFactory")
local ShopItemPreviewView = require("./ShopItemPreviewView")

local ShopPanelView = {}
ShopPanelView.__index = ShopPanelView

local COLORS = DeviceInterfaceElementFactory.COLORS
local createLabel = DeviceInterfaceElementFactory.createTextLabel
local setLabelText = DeviceInterfaceElementFactory.setLabelText

function ShopPanelView.create(contentFrame: Frame, callbacks, playerDisplayName: string)
	local shopList = DeviceInterfaceElementFactory.createScrollingList("ShopList", contentFrame)
	shopList.Size = UDim2.fromScale(1, 1)
	DeviceInterfaceElementFactory.createVerticalList(shopList, 8)
	local balanceLabel = createLabel("BalanceLabel", shopList, 20, 1)
	local loadingLabel = createLabel("LoadingLabel", shopList, 18, 2)
	return setmetatable({
		shopList = shopList,
		balanceLabel = balanceLabel,
		loadingLabel = loadingLabel,
		callbacks = callbacks,
		playerDisplayName = playerDisplayName,
		cardPartsByItemId = {},
		groupPartsByPosition = {},
		renderedStructureSignature = nil,
		latestItemRowByItemId = {},
	}, ShopPanelView)
end

local function buildStructureSignature(model): string
	local parts = {}
	for _, group in model.groups do
		table.insert(parts, "#" .. group.groupTitleText)
		for _, itemRow in group.itemRows do
			table.insert(parts, itemRow.itemId .. "|" .. itemRow.nameText .. "|" .. itemRow.priceText)
		end
	end
	return table.concat(parts, "\n")
end

function ShopPanelView:buildCard(groupFrame: Frame, itemRow, layoutOrder: number)
	local itemId = itemRow.itemId
	local card = DeviceInterfaceElementFactory.createItemCard("Item_" .. itemId, groupFrame, layoutOrder)
	card:SetAttribute("ItemId", itemId)
	local nameLabel = createLabel("NameLabel", card, 20, 1)
	nameLabel.Text = itemRow.nameText
	local priceLabel = createLabel("PriceLabel", card, 16, 2)
	priceLabel.Text = itemRow.priceText
	local ownershipLabel = createLabel("OwnershipLabel", card, 16, 3)
	ownershipLabel.TextColor3 = COLORS.mutedText
	ShopItemPreviewView.createPreview(card, itemRow.preview, self.playerDisplayName, 4)
	local buyButton = DeviceInterfaceElementFactory.createTextButton("BuyButton", card, "", 5, function()
		self.callbacks.onBuyShopItem(self.latestItemRowByItemId[itemId])
	end)
	local missingLabel = createLabel("MissingStarCoinsLabel", card, 16, 6)
	missingLabel.TextColor3 = COLORS.noticeText
	local equipButton = DeviceInterfaceElementFactory.createTextButton("EquipButton", card, "", 7, function()
		self.callbacks.onEquipShopItem(self.latestItemRowByItemId[itemId])
	end)
	local feedbackLabel = createLabel("FeedbackLabel", card, 16, 8)
	feedbackLabel.TextColor3 = COLORS.noticeText
	self.cardPartsByItemId[itemId] = {
		card = card,
		ownershipLabel = ownershipLabel,
		buyButton = buyButton,
		missingLabel = missingLabel,
		equipButton = equipButton,
		feedbackLabel = feedbackLabel,
	}
end

function ShopPanelView:rebuildStructure(model)
	for _, groupParts in self.groupPartsByPosition do
		groupParts.groupFrame:Destroy()
	end
	table.clear(self.groupPartsByPosition)
	table.clear(self.cardPartsByItemId)
	for groupPosition, group in model.groups do
		local groupFrame = DeviceInterfaceElementFactory.createRowContainer(
			"Group" .. groupPosition,
			self.shopList,
			10 + groupPosition,
			8
		)
		local groupTitle = createLabel("GroupTitle", groupFrame, 22, 0)
		groupTitle.Text = group.groupTitleText
		groupTitle.TextColor3 = COLORS.mutedText
		local emptyLabel = createLabel("EmptyGroupLabel", groupFrame, 16, 1)
		self.groupPartsByPosition[groupPosition] = { groupFrame = groupFrame, emptyLabel = emptyLabel }
		for rowPosition, itemRow in group.itemRows do
			self:buildCard(groupFrame, itemRow, 1 + rowPosition)
		end
	end
end

function ShopPanelView:render(model)
	setLabelText(self.balanceLabel, model.balanceText)
	setLabelText(self.loadingLabel, model.loadingText)
	local structureSignature = buildStructureSignature(model)
	if structureSignature ~= self.renderedStructureSignature then
		self.renderedStructureSignature = structureSignature
		self:rebuildStructure(model)
	end
	for groupPosition, group in model.groups do
		setLabelText(self.groupPartsByPosition[groupPosition].emptyLabel, group.emptyGroupText)
		for _, itemRow in group.itemRows do
			self.latestItemRowByItemId[itemRow.itemId] = itemRow
			local parts = self.cardPartsByItemId[itemRow.itemId]
			setLabelText(parts.ownershipLabel, itemRow.ownershipText)
			parts.buyButton.Visible = itemRow.isBuyButtonVisible
			parts.buyButton.Text = itemRow.buyButtonText
			DeviceInterfaceElementFactory.setButtonEnabled(parts.buyButton, itemRow.isBuyButtonEnabled)
			setLabelText(parts.missingLabel, itemRow.missingStarCoinsText)
			parts.equipButton.Visible = itemRow.isEquipButtonVisible
			parts.equipButton.Text = itemRow.equipButtonText
			setLabelText(parts.feedbackLabel, itemRow.feedbackText)
			parts.card:SetAttribute("IsOwned", itemRow.isOwned)
			parts.card:SetAttribute("IsEquipped", itemRow.isEquipped)
		end
	end
end

return ShopPanelView
