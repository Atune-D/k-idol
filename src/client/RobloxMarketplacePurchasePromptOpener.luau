-- RobloxMarketplacePurchasePromptOpener (development spec §2.12): the ONE place that asks the engine to
-- open Roblox's own purchase prompt for a styling item: the asset prompt for kind Asset, the bundle
-- prompt for kind Bundle. Roblox completes the purchase and delivers the item; the game grants and
-- stores nothing.
-- 🔴 It is called only when MarketplacePurchasePromptPermission allowed it, which never happens in
-- Roblox Studio; as a second lock it also refuses by itself whenever RunService:IsStudio() is not
-- false, so no prompt can open from a Studio session even if a caller is wrong.
--
-- PUBLIC API
--   RobloxMarketplacePurchasePromptOpener.openPurchasePromptForStylingItem(localPlayer, purchasePromptKind,
--       marketplaceItemId) -> boolean   true when a prompt was asked for
--
-- Roblox API used, read in the official documentation (create.roblox.com/docs/reference/engine/...):
--   MarketplaceService:PromptPurchase(player, assetId) ("Prompts a user to purchase an item with the
--     given assetId"), :PromptBundlePurchase(player, bundleId)   classes/MarketplaceService
--   RunService:IsStudio() ("Returns whether the current environment is running in Studio")   classes/RunService

local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

local RobloxMarketplacePurchasePromptOpener = {}

function RobloxMarketplacePurchasePromptOpener.openPurchasePromptForStylingItem(
	localPlayer: Player,
	purchasePromptKind: string,
	marketplaceItemId: number
): boolean
	if RunService:IsStudio() ~= false then
		return false
	end
	if purchasePromptKind == "Asset" then
		MarketplaceService:PromptPurchase(localPlayer, marketplaceItemId)
		return true
	elseif purchasePromptKind == "Bundle" then
		MarketplaceService:PromptBundlePurchase(localPlayer, marketplaceItemId)
		return true
	end
	return false
end

return table.freeze(RobloxMarketplacePurchasePromptOpener)
