-- A MarketplaceItemLookups (interface at the top of MarketplaceStylingItemResolver.luau) that
-- answers from the engine answers captured in Studio (CapturedRobloxMarketplaceAnswers), passed
-- through the REAL RobloxMarketplaceAnswerConverter, so the resolver sees exactly what it saw in
-- Studio for the seven development items of data/styling-item-pool.csv. Answers are given inside
-- the start call. Ownership: nobody owns anything unless `setOwnedMarketplaceItem` says so.
-- Not a spec file.

local CapturedRobloxMarketplaceAnswers = require("./CapturedRobloxMarketplaceAnswers")
local RobloxMarketplaceAnswerConverter = require("../../src/server/RobloxMarketplaceAnswerConverter")

local CapturedAnswerMarketplaceItemLookups = {}
CapturedAnswerMarketplaceItemLookups.__index = CapturedAnswerMarketplaceItemLookups

function CapturedAnswerMarketplaceItemLookups.new()
	return setmetatable({
		ownedItemSet = {} :: { [string]: boolean },
		startedOwnershipCheckCount = 0,
		heldOwnershipCallbacks = nil :: { () -> () }?,
	}, CapturedAnswerMarketplaceItemLookups)
end

function CapturedAnswerMarketplaceItemLookups:setOwnedMarketplaceItem(
	playerUserId: number,
	marketplaceItemKind: string,
	marketplaceItemId: number
)
	self.ownedItemSet[string.format("%d/%s/%d", playerUserId, marketplaceItemKind, marketplaceItemId)] = true
end

-- While holding, ownership answers wait until releaseHeldOwnershipAnswers().
function CapturedAnswerMarketplaceItemLookups:holdOwnershipAnswers()
	self.heldOwnershipCallbacks = {}
end

function CapturedAnswerMarketplaceItemLookups:releaseHeldOwnershipAnswers()
	local heldOwnershipCallbacks = self.heldOwnershipCallbacks or {}
	self.heldOwnershipCallbacks = nil
	for _, heldCallback in heldOwnershipCallbacks do
		heldCallback()
	end
end

function CapturedAnswerMarketplaceItemLookups:startLookingUpMarketplaceItemDetails(
	marketplaceItemKind,
	marketplaceItemId,
	onLookupFinished
)
	local capturedAnswers = CapturedRobloxMarketplaceAnswers.AVATAR_ITEM_DETAILS_BY_KIND_AND_ID[marketplaceItemKind]
	local capturedAnswer = capturedAnswers and capturedAnswers[marketplaceItemId]
	if capturedAnswer == nil then
		onLookupFinished(false, nil, CapturedRobloxMarketplaceAnswers.ITEM_DETAILS_HTTP_400_ERROR_MESSAGE)
		return
	end
	local convertedDetails, problemDescription = RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer(
		marketplaceItemKind,
		marketplaceItemId,
		CapturedRobloxMarketplaceAnswers.copyAnswer(capturedAnswer)
	)
	onLookupFinished(convertedDetails ~= nil, convertedDetails, problemDescription)
end

function CapturedAnswerMarketplaceItemLookups:startLookingUpBundleContents(bundleId, onLookupFinished)
	local capturedAnswer = CapturedRobloxMarketplaceAnswers.BUNDLE_DETAILS_BY_BUNDLE_ID[bundleId]
	if capturedAnswer == nil then
		onLookupFinished(false, nil, "no captured answer")
		return
	end
	local convertedEntries, problemDescription = RobloxMarketplaceAnswerConverter.convertBundleDetailsAnswer(
		bundleId,
		CapturedRobloxMarketplaceAnswers.copyAnswer(capturedAnswer)
	)
	onLookupFinished(convertedEntries ~= nil, convertedEntries, problemDescription)
end

function CapturedAnswerMarketplaceItemLookups:startCheckingPlayerOwnsMarketplaceItem(
	playerUserId,
	marketplaceItemKind,
	marketplaceItemId,
	onCheckFinished
)
	self.startedOwnershipCheckCount += 1
	local isOwned = self.ownedItemSet[string.format("%d/%s/%d", playerUserId, marketplaceItemKind, marketplaceItemId)]
		== true
	local function answerOwnership()
		onCheckFinished(true, isOwned, nil)
	end
	if self.heldOwnershipCallbacks ~= nil then
		table.insert(self.heldOwnershipCallbacks, answerOwnership)
		return
	end
	answerOwnership()
end

return CapturedAnswerMarketplaceItemLookups
