-- StylingItemPurchasePanelModelBuilder (development spec §2.12, §2.14): decides what the wardrobe's Buy
-- panel shows for the focused styling item (StylingItemOwnershipRequester), as plain data.
--   * Shown only while a wardrobe (round or lobby) is shown and the focused item is in the outfit it
--     shows; the item's name and Robux price come from the server's catalog snapshot.
--   * "Checking whether you own it..." until the server answers RequestStylingItemOwnership.
--   * Owned: "You own this item." and no Buy action.
--   * Not owned: a "Buy for N Robux" button. Whether pressing it may open Roblox's purchase prompt is
--     MarketplacePurchasePromptPermission's decision; in Roblox Studio it never may, and the panel
--     says so in plain words (STUDIO_PURCHASE_SWITCHED_OFF_TEXT) next to the button.
--   * A failed or refused check is explained (LobbyRequestAnswerTexts) and offers no Buy action;
--     selecting the item again asks again.
-- The game grants nothing and stores nothing about a purchase (§2.12): Roblox delivers the item, and
-- the device asks ownership again after the prompt closes.
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   StylingItemPurchasePanelModelBuilder.STUDIO_PURCHASE_SWITCHED_OFF_TEXT
--   StylingItemPurchasePanelModelBuilder.buildStylingItemPurchasePanelModel(purchaseInputs) -> model
--   purchaseInputs = { focusedOwnership?, shownOutfitStylingItemKeys?, wardrobeCatalogView?,
--     stylingItemByStylingItemKey, isRunningInStudio }
--   model = { isVisible, stylingItemKey?, itemNameText, ownershipText, isBuyButtonVisible, buyButtonText,
--     explanationText, purchasePromptPermission? }

local LobbyRequestAnswerTexts = require("./LobbyRequestAnswerTexts")
local MarketplacePurchasePromptPermission = require("./MarketplacePurchasePromptPermission")
local PlayerFacingTexts = require("./PlayerFacingTexts")

local StylingItemPurchasePanelModelBuilder = {}

StylingItemPurchasePanelModelBuilder.STUDIO_PURCHASE_SWITCHED_OFF_TEXT =
	"Buying is switched off in Roblox Studio. In the published game this button opens Roblox's own purchase window."

local OWNERSHIP_REASON_TEXTS =
	LobbyRequestAnswerTexts.REJECTION_TEXT_BY_REASON_BY_REMOTE_CHANNEL_NAME.RequestStylingItemOwnership

local function buildHiddenModel()
	return {
		isVisible = false,
		stylingItemKey = nil,
		itemNameText = "",
		ownershipText = "",
		isBuyButtonVisible = false,
		buyButtonText = "",
		explanationText = "",
		purchasePromptPermission = nil,
	}
end

function StylingItemPurchasePanelModelBuilder.buildStylingItemPurchasePanelModel(purchaseInputs)
	local model = buildHiddenModel()
	local focusedOwnership = purchaseInputs.focusedOwnership
	local shownKeys = purchaseInputs.shownOutfitStylingItemKeys
	local view = purchaseInputs.wardrobeCatalogView
	if focusedOwnership == nil or shownKeys == nil or view == nil then
		return model
	end
	local stylingItemKey = focusedOwnership.stylingItemKey
	local wardrobeItem = view.wardrobeItemByStylingItemKey[stylingItemKey]
	local stylingItem = purchaseInputs.stylingItemByStylingItemKey[stylingItemKey]
	if table.find(shownKeys, stylingItemKey) == nil or wardrobeItem == nil or stylingItem == nil then
		return model
	end
	model.isVisible = true
	model.stylingItemKey = stylingItemKey
	model.itemNameText = wardrobeItem.itemDisplayName
	model.buyButtonText =
		string.format("Buy for %s Robux", PlayerFacingTexts.formatWholeNumber(wardrobeItem.priceInRobux))
	local ownershipStatus = focusedOwnership.ownershipStatus
	if ownershipStatus == "Checking" then
		model.ownershipText = "Checking whether you own it..."
	elseif ownershipStatus == "Owned" then
		model.ownershipText = "You own this item."
	elseif ownershipStatus == "NotOwned" then
		model.ownershipText = "You don't own this item yet."
		model.isBuyButtonVisible = true
		local permission = MarketplacePurchasePromptPermission.decidePurchasePromptPermission({
			isRunningInStudio = purchaseInputs.isRunningInStudio,
			marketplaceItemKind = stylingItem.marketplaceItemKind,
			marketplaceItemId = stylingItem.marketplaceItemId,
			ownershipStatus = ownershipStatus,
		})
		model.purchasePromptPermission = permission
		if permission.refusalReason == MarketplacePurchasePromptPermission.REFUSAL_REASONS.RunningInStudio then
			model.explanationText = StylingItemPurchasePanelModelBuilder.STUDIO_PURCHASE_SWITCHED_OFF_TEXT
		elseif not permission.mayOpenPurchasePrompt then
			model.explanationText = "This item can't be bought here."
		end
	else
		model.ownershipText = (
			focusedOwnership.rejectionReason and OWNERSHIP_REASON_TEXTS[focusedOwnership.rejectionReason]
		) or OWNERSHIP_REASON_TEXTS.OwnershipCheckFailed
		model.explanationText = "Take the item off and put it on again to check again."
	end
	return model
end

return table.freeze(StylingItemPurchasePanelModelBuilder)
