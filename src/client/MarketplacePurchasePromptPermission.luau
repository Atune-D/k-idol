-- MarketplacePurchasePromptPermission (development spec §2.12 "Buying a Marketplace item"): THE decision
-- "may the wardrobe's Buy action open Roblox's purchase prompt now". 🔴 It answers NO whenever the game
-- runs in Roblox Studio: nothing may start a purchase from a Studio session (project owner's rule), so
-- in Studio the Buy action only explains that buying is switched off there.
--
-- A pure function of facts the caller reads from the engine and the wardrobe:
--   isRunningInStudio   RunService:IsStudio() as read by the caller. Only the boolean `false` counts
--                       as "not in Studio"; anything else (true, nil, a non-boolean) answers no, so a
--                       missing or wrong fact can never open a prompt.
--   marketplaceItemKind "Asset" -> the asset prompt, "Bundle" -> the bundle prompt (§2.12); any other
--                       value answers no.
--   marketplaceItemId   a positive whole number, otherwise no.
--   ownershipStatus     only "NotOwned" (the server's answer to RequestStylingItemOwnership) allows
--                       it; "Owned", "Checking", "CheckFailed", "UnknownItem", "Refused" or nil answer no.
-- Checked in this order; the first that fails is the refusal reason.
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   MarketplacePurchasePromptPermission.REFUSAL_REASONS   frozen: RunningInStudio, UnknownMarketplaceItemKind,
--     InvalidMarketplaceItemId, NotKnownToBeUnowned
--   MarketplacePurchasePromptPermission.decidePurchasePromptPermission(purchaseFacts)
--     -> { mayOpenPurchasePrompt: true, purchasePromptKind: "Asset" | "Bundle" }
--      | { mayOpenPurchasePrompt: false, refusalReason }
--   purchaseFacts = { isRunningInStudio, marketplaceItemKind, marketplaceItemId, ownershipStatus }

local MarketplacePurchasePromptPermission = {}

MarketplacePurchasePromptPermission.REFUSAL_REASONS = table.freeze({
	RunningInStudio = "RunningInStudio",
	UnknownMarketplaceItemKind = "UnknownMarketplaceItemKind",
	InvalidMarketplaceItemId = "InvalidMarketplaceItemId",
	NotKnownToBeUnowned = "NotKnownToBeUnowned",
})

local REFUSALS = MarketplacePurchasePromptPermission.REFUSAL_REASONS

local function refuse(refusalReason: string)
	return table.freeze({ mayOpenPurchasePrompt = false, refusalReason = refusalReason })
end

function MarketplacePurchasePromptPermission.decidePurchasePromptPermission(purchaseFacts)
	if type(purchaseFacts) ~= "table" or purchaseFacts.isRunningInStudio ~= false then
		return refuse(REFUSALS.RunningInStudio)
	end
	local marketplaceItemKind = purchaseFacts.marketplaceItemKind
	if marketplaceItemKind ~= "Asset" and marketplaceItemKind ~= "Bundle" then
		return refuse(REFUSALS.UnknownMarketplaceItemKind)
	end
	local marketplaceItemId = purchaseFacts.marketplaceItemId
	if type(marketplaceItemId) ~= "number" or marketplaceItemId < 1 or marketplaceItemId % 1 ~= 0 then
		return refuse(REFUSALS.InvalidMarketplaceItemId)
	end
	if purchaseFacts.ownershipStatus ~= "NotOwned" then
		return refuse(REFUSALS.NotKnownToBeUnowned)
	end
	return table.freeze({ mayOpenPurchasePrompt = true, purchasePromptKind = marketplaceItemKind })
end

return table.freeze(MarketplacePurchasePromptPermission)
