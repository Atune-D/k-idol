-- Builds the RequestStylingItemOwnership answer (development spec §2.14) for
-- MarketplaceStylingItemResolver, which documents the answers in its PUBLIC API block and is the
-- only caller. Ownership is checked per kind: the asset for kind Asset, the bundle for kind
-- Bundle (§2.12). A failed check is not retried; the device asks again when the player selects
-- the item again. A check that reports anything but success (`wasCheckSuccessful == true`) with a
-- boolean answer is answered OwnershipCheckFailed, and so is a check that has not answered within
-- OWNERSHIP_CHECK_TIMEOUT_SECONDS (a value the spec does not give); a late answer is then ignored.
-- `TooManyRequests` belongs to the request rate limiter and is never produced here.
-- Pure logic: the Roblox check is the injected `marketplaceItemLookups`.

local MarketplaceItemLookupAnswerReader = require("./MarketplaceItemLookupAnswerReader")
local StylingItemLookup = require("../shared/StylingItemLookup")

type StylingItemByStylingItemKey = StylingItemLookup.StylingItemByStylingItemKey
type AvailableStylingItemKeySet = StylingItemLookup.AvailableStylingItemKeySet

local StylingItemOwnershipRequestAnswerer = {}

StylingItemOwnershipRequestAnswerer.STYLING_ITEM_OWNERSHIP_REJECTION_REASONS = table.freeze({
	UnknownStylingItem = "UnknownStylingItem",
	OwnershipCheckFailed = "OwnershipCheckFailed",
})

StylingItemOwnershipRequestAnswerer.OWNERSHIP_CHECK_TIMEOUT_SECONDS = 10

local OWNERSHIP_REJECTION_REASONS = StylingItemOwnershipRequestAnswerer.STYLING_ITEM_OWNERSHIP_REJECTION_REASONS

export type OwnershipRequestContext = {
	stylingItemByStylingItemKey: StylingItemByStylingItemKey,
	-- The available key set of the published catalog; only these keys are known items.
	availableStylingItemKeySet: AvailableStylingItemKeySet,
	marketplaceItemLookups: any,
	scheduler: any,
	logger: any,
}

-- Calls `onOwnershipAnswerReady` exactly once, possibly before returning.
function StylingItemOwnershipRequestAnswerer.startAnsweringStylingItemOwnershipRequest(
	ownershipRequestContext: OwnershipRequestContext,
	playerUserId: number,
	untrustedStylingItemKey: any,
	onOwnershipAnswerReady: (
		ownershipAnswer: { [string]: any }
	) -> ()
)
	local isKnownStylingItem = type(untrustedStylingItemKey) == "string"
		and rawget(ownershipRequestContext.availableStylingItemKeySet, untrustedStylingItemKey) == true
	if not isKnownStylingItem then
		onOwnershipAnswerReady({
			isAccepted = false,
			rejectionReason = OWNERSHIP_REJECTION_REASONS.UnknownStylingItem,
		})
		return
	end
	local stylingItem = ownershipRequestContext.stylingItemByStylingItemKey[untrustedStylingItemKey]
	local hasAnswered = false
	local cancelOwnershipCheckTimeout: (() -> ())? = nil
	local function onCheckFinished(
		wasCheckSuccessful: boolean,
		untrustedIsOwnedByPlayer: any,
		checkErrorMessage: string?
	)
		if hasAnswered then
			return
		end
		hasAnswered = true
		if cancelOwnershipCheckTimeout ~= nil then
			cancelOwnershipCheckTimeout()
			cancelOwnershipCheckTimeout = nil
		end
		local isOwnedByPlayer, answerProblemDescription =
			MarketplaceItemLookupAnswerReader.readOwnershipAnswer(untrustedIsOwnedByPlayer)
		if wasCheckSuccessful ~= true or isOwnedByPlayer == nil then
			ownershipRequestContext.logger:logWarning(
				string.format(
					"MarketplaceStylingItemResolver: ownership check of %s for player %s failed: %s",
					stylingItem.stylingItemKey,
					tostring(playerUserId),
					if wasCheckSuccessful == true
						then tostring(answerProblemDescription)
						else tostring(checkErrorMessage)
				)
			)
			onOwnershipAnswerReady({
				isAccepted = false,
				rejectionReason = OWNERSHIP_REJECTION_REASONS.OwnershipCheckFailed,
			})
			return
		end
		onOwnershipAnswerReady({ isAccepted = true, isOwnedByPlayer = isOwnedByPlayer })
	end
	-- Scheduled before starting, so a check that answers inside its start call cancels it.
	cancelOwnershipCheckTimeout = ownershipRequestContext.scheduler:scheduleCallbackAfterSeconds(
		StylingItemOwnershipRequestAnswerer.OWNERSHIP_CHECK_TIMEOUT_SECONDS,
		function()
			cancelOwnershipCheckTimeout = nil -- it has run; never cancel it afterwards
			onCheckFinished(
				false,
				nil,
				string.format(
					"no answer within %d seconds",
					StylingItemOwnershipRequestAnswerer.OWNERSHIP_CHECK_TIMEOUT_SECONDS
				)
			)
		end
	)
	local didStart, startError = pcall(function()
		ownershipRequestContext.marketplaceItemLookups:startCheckingPlayerOwnsMarketplaceItem(
			playerUserId,
			stylingItem.marketplaceItemKind,
			stylingItem.marketplaceItemId,
			onCheckFinished
		)
	end)
	if not didStart then
		onCheckFinished(false, nil, "the ownership check raised while starting: " .. tostring(startError))
	end
end

return table.freeze(StylingItemOwnershipRequestAnswerer)
