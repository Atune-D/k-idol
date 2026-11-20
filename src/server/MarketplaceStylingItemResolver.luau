-- MarketplaceStylingItemResolver (development spec v1.3 §1.2, §2.12, §2.14, §3.3, §3.7): decides
-- which styling items of the pool are available in the wardrobe this server session, publishes
-- the wardrobe catalog, caches each available item's worn assets for the character dresser, and
-- answers ownership requests.
--
-- 🔴 This is the only module that asks Roblox about Marketplace items and bundles (§3.3).
-- Everything else reads its cached answers. This rule part itself calls no Roblox-specific
-- interface: the Roblox lookups are injected (interface at the end of this block), so tests pass
-- fakes and never wait.
--
-- Rules it enforces:
--   * Only enabled rows are looked up. A disabled row is never looked up and never available.
--   * 🔴 An item is HIDDEN for the server session, and logged as a warning, when: its details
--     fail to load; it is not on sale; it cannot be sold in this game; or it is a bundle whose
--     contents fail to load (§1.2). A hidden item is not in the available key set, so
--     OutfitValidator rejects any outfit containing it.
--   * A failed lookup (the lookup reported anything but `true` as its success value, raised
--     while starting, answered in a shape other than the one documented below, or did not answer
--     within 15 seconds) is retried up to 3 times, 2, 4 and 8 seconds
--     apart, before the item is hidden: at most 4 attempts per lookup. "Not on sale" and "not
--     sellable in this game" are answers, not failures: they hide the item at once.
--   * A bundle's contents are looked up only after its details showed it on sale and sellable
--     here. Its worn assets are its wearable contents; the non-wearable saved-outfit entry is
--     left out (§2.14).
--   * The catalog is resolved once per server session (§1.2). It becomes ready, with
--     wardrobeCatalogVersion 1, when the first pass over the pool has finished; before that it
--     is not ready and has version 0. Nothing is looked up again afterwards, so the version
--     does not change again during the session.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- MarketplaceStylingItemResolver.new(dependencies) -> resolver
--   dependencies = {
--     stylingItems: { StylingItem }   the styling item pool, normally
--         StylingItemPool.STYLING_ITEMS; raises on a duplicated or mismatched stylingItemKey.
--     marketplaceItemLookups: MarketplaceItemLookups   (interface at the end of this block),
--     scheduler: { scheduleCallbackAfterSeconds: (self, delaySeconds, callback) -> cancelCallback },
--     logger: { logInformation: (self, message: string) -> (), logWarning: (self, message: string) -> () },
--   }
-- resolver:startResolvingWardrobeCatalog()
--   Starts the first pass over the pool: every enabled styling item is looked up (at most 10
--   lookups in flight at once). Returns at once. Call once; a second call raises. A pool with no
--   enabled item makes the catalog ready inside this call.
--
-- resolver:isWardrobeCatalogReady() -> boolean
--   False from creation until the first pass has finished (§2.14).
-- resolver:getWardrobeCatalogVersion() -> number
--   0 until ready, then 1.
-- resolver:getAvailableStylingItemKeySet() -> StylingItemLookup.AvailableStylingItemKeySet
--   A frozen set holding `true` for every available item (enabled and not hidden). An empty
--   frozen set while the catalog is not ready. The shape OutfitValidator.validateOutfit and
--   StoredLobbyOutfitResolver take.
-- resolver:subscribeToWardrobeCatalogChanged(listener(wardrobeCatalogChangedMessage)) -> unsubscribe
--   Called synchronously when readiness or the version changes, with a fresh
--   `{ isWardrobeCatalogReady, wardrobeCatalogVersion }` per listener: the WardrobeCatalogChanged
--   payload of §2.14. A listener that raises is logged and does not disturb other listeners.
-- resolver:readWardrobeCatalogSnapshotAnswer() -> answer
--   The RequestWardrobeCatalogSnapshot answer of §2.14, a fresh copy each call:
--   { isAccepted = true, isWardrobeCatalogReady, wardrobeCatalogVersion, wardrobeItems }, each
--   item { stylingItemKey, marketplaceItemKind, marketplaceItemId, itemDisplayName, priceInRobux,
--   wornAssets }, each worn asset { wornAssetId, robloxAssetTypeName }. Items in pool order.
--   wardrobeItems is empty while the catalog is not ready. (Rate limiting is not done here.)
-- resolver:readResolvedStylingItemDetails(stylingItemKey) -> ResolvedStylingItemDetails?
--   For the character dresser (§3.7): a fresh copy of one available item's wardrobe entry (same
--   fields as a snapshot item). Nil for an unknown, disabled or hidden key, and for every key
--   while the catalog is not ready.
-- resolver:readHiddenStylingItemReasonByStylingItemKey() -> { [stylingItemKey]: hiddenReason }
--   A copy, for diagnostics. Reasons: HIDDEN_STYLING_ITEM_REASONS.
-- resolver:startAnsweringStylingItemOwnershipRequest(playerUserId, untrustedStylingItemKey,
--                                                    onOwnershipAnswerReady(answer))
--   The RequestStylingItemOwnership answer of §2.14. Returns at once; the callback is called
--   exactly once, possibly before this returns. `untrustedStylingItemKey` may be any value.
--     { isAccepted = true, isOwnedByPlayer }
--     { isAccepted = false, rejectionReason = "UnknownStylingItem" }   the key is not an available
--         item of the published catalog (not a string, not in the pool, disabled, hidden, or the
--         catalog is not ready). Answered without asking Roblox.
--     { isAccepted = false, rejectionReason = "OwnershipCheckFailed" }  the Roblox check failed,
--         answered badly, or did not answer within 10 seconds (not retried; the device asks again when the player selects the item again).
--   Ownership is checked per kind: an asset for kind Asset, a bundle for kind Bundle (§2.12).
--   `TooManyRequests` is the request rate limiter's answer and is never produced here.
--
-- MarketplaceItemLookups interface (implemented later by the Roblox-side file, and by
-- tests/Support/FakeMarketplaceItemLookups). Every method returns at once without yielding the
-- caller and should call its callback exactly once, later or before returning. A callback called
-- again is ignored; a method that raises counts as a failed lookup; a lookup that has not called
-- back within 15 seconds (an ownership check: 10 seconds) counts as failed and a later answer is
-- ignored. Describe WHAT is answered;
-- the implementation maps it onto Roblox from the official documentation (§8 records that
-- avatar item details report sale status and sale location for both assets and bundles, while
-- bundle product info reports neither).
--   lookups:startLookingUpMarketplaceItemDetails(marketplaceItemKind, marketplaceItemId, onLookupFinished)
--     marketplaceItemKind is "Asset" or "Bundle"; the id is the asset id or the bundle id.
--     onLookupFinished(wasLookupSuccessful: boolean, marketplaceItemDetails?, lookupErrorMessage: string?)
--     marketplaceItemDetails = {
--       itemDisplayName: string,       the item's name as shown on the Marketplace; not empty
--       priceInRobux: number,          its current price in Robux, a whole number >= 0
--       isOnSale: boolean,             whether it can currently be bought at all
--       canBeSoldInThisGame: boolean,  whether its sale location / creator settings allow it to be
--                                      bought inside THIS game (false for items restricted to the
--                                      Marketplace or to the creator's own games)
--       robloxAssetTypeName: string,   kind "Asset" only: the Roblox asset type of the asset, as
--                                      the name the character dresser and device preview use
--                                      (for example the type of a hair accessory or of lip makeup)
--     }
--   lookups:startLookingUpBundleContents(bundleId, onLookupFinished)
--     onLookupFinished(wasLookupSuccessful: boolean, bundleContentEntries?, lookupErrorMessage: string?)
--     bundleContentEntries = every entry the bundle lists, in Roblox's order, each
--       { isWearableAsset: boolean, wornAssetId: number?, robloxAssetTypeName: string? }.
--       isWearableAsset is false for the bundle's saved-outfit entry (and anything else that is
--       not an asset a character wears); wornAssetId and robloxAssetTypeName are then ignored.
--       For a wearable asset both are required: its asset id and its Roblox asset type (for a
--       shoes bundle, a left shoe and a right shoe). If the type of any wearable asset cannot be
--       determined, the whole lookup must report failure.
--   lookups:startCheckingPlayerOwnsMarketplaceItem(playerUserId, marketplaceItemKind,
--                                                   marketplaceItemId, onCheckFinished)
--     onCheckFinished(wasCheckSuccessful: boolean, isOwnedByPlayer: boolean?, checkErrorMessage: string?)
--     Whether that player's account owns the asset (kind "Asset") or the bundle (kind "Bundle").
-- ════════════════════════════════════════════════════════════════════════════════════════════

local StylingItemLookup = require("../shared/StylingItemLookup")
local MarketplaceItemLookupAnswerReader = require("./MarketplaceItemLookupAnswerReader")
local MarketplaceItemLookupRetryQueue = require("./MarketplaceItemLookupRetryQueue")
local StylingItemOwnershipRequestAnswerer = require("./StylingItemOwnershipRequestAnswerer")

type StylingItem = StylingItemLookup.StylingItem
type AvailableStylingItemKeySet = StylingItemLookup.AvailableStylingItemKeySet
type WornAsset = MarketplaceItemLookupAnswerReader.WornAsset

export type ResolvedStylingItemDetails = {
	stylingItemKey: string,
	marketplaceItemKind: string,
	marketplaceItemId: number,
	itemDisplayName: string,
	priceInRobux: number,
	wornAssets: { WornAsset },
}

export type WardrobeCatalogChangedMessage = {
	isWardrobeCatalogReady: boolean,
	wardrobeCatalogVersion: number,
}

local MarketplaceStylingItemResolver = {}
MarketplaceStylingItemResolver.__index = MarketplaceStylingItemResolver

MarketplaceStylingItemResolver.WARDROBE_CATALOG_VERSION_BEFORE_READY = 0
MarketplaceStylingItemResolver.WARDROBE_CATALOG_VERSION_AFTER_FIRST_PASS = 1

MarketplaceStylingItemResolver.HIDDEN_STYLING_ITEM_REASONS = table.freeze({
	ItemDetailsFailedToLoad = "ItemDetailsFailedToLoad",
	NotOnSale = "NotOnSale",
	NotSellableInThisGame = "NotSellableInThisGame",
	BundleContentsFailedToLoad = "BundleContentsFailedToLoad",
})

MarketplaceStylingItemResolver.STYLING_ITEM_OWNERSHIP_REJECTION_REASONS =
	StylingItemOwnershipRequestAnswerer.STYLING_ITEM_OWNERSHIP_REJECTION_REASONS

local HIDDEN_REASONS = MarketplaceStylingItemResolver.HIDDEN_STYLING_ITEM_REASONS
local EMPTY_AVAILABLE_STYLING_ITEM_KEY_SET: AvailableStylingItemKeySet = table.freeze({})

function MarketplaceStylingItemResolver.new(dependencies)
	for _, requiredDependencyName in { "stylingItems", "marketplaceItemLookups", "scheduler", "logger" } do
		if dependencies[requiredDependencyName] == nil then
			error("MarketplaceStylingItemResolver.new: missing dependency " .. requiredDependencyName, 2)
		end
	end
	return setmetatable({
		stylingItems = dependencies.stylingItems,
		stylingItemByStylingItemKey = StylingItemLookup.buildStylingItemByStylingItemKey(dependencies.stylingItems),
		marketplaceItemLookups = dependencies.marketplaceItemLookups,
		logger = dependencies.logger,
		scheduler = dependencies.scheduler,
		lookupRetryQueue = MarketplaceItemLookupRetryQueue.new(dependencies.scheduler),

		hasStartedResolving = false,
		unsettledStylingItemCount = 0,
		resolvedStylingItemDetailsByStylingItemKey = {} :: { [string]: ResolvedStylingItemDetails },
		hiddenReasonByStylingItemKey = {} :: { [string]: string },

		isCatalogReady = false,
		wardrobeCatalogVersion = MarketplaceStylingItemResolver.WARDROBE_CATALOG_VERSION_BEFORE_READY,
		availableStylingItemKeySet = EMPTY_AVAILABLE_STYLING_ITEM_KEY_SET,
		publishedWardrobeItems = {} :: { ResolvedStylingItemDetails },
		wardrobeCatalogChangedListeners = {} :: { (WardrobeCatalogChangedMessage) -> () },
	}, MarketplaceStylingItemResolver)
end

local function copyResolvedStylingItemDetails(resolvedDetails: ResolvedStylingItemDetails): ResolvedStylingItemDetails
	local copiedWornAssets = {}
	for _, wornAsset in resolvedDetails.wornAssets do
		table.insert(copiedWornAssets, table.clone(wornAsset))
	end
	local copiedDetails = table.clone(resolvedDetails)
	copiedDetails.wornAssets = copiedWornAssets
	return copiedDetails
end

local function notifyWardrobeCatalogChangedListeners(self)
	-- Iterate over a copy so a listener that unsubscribes does not skip another listener.
	for _, listener in table.clone(self.wardrobeCatalogChangedListeners) do
		local didRun, listenerError = pcall(listener, {
			isWardrobeCatalogReady = self.isCatalogReady,
			wardrobeCatalogVersion = self.wardrobeCatalogVersion,
		})
		if not didRun then
			self.logger:logWarning(
				"MarketplaceStylingItemResolver: a WardrobeCatalogChanged listener raised: " .. tostring(listenerError)
			)
		end
	end
end

-- Publishes a new catalog state; listeners hear about it only when readiness or version changed.
local function publishWardrobeCatalogState(self, isCatalogReady: boolean, wardrobeCatalogVersion: number)
	local hasCatalogStateChanged = self.isCatalogReady ~= isCatalogReady
		or self.wardrobeCatalogVersion ~= wardrobeCatalogVersion
	self.isCatalogReady = isCatalogReady
	self.wardrobeCatalogVersion = wardrobeCatalogVersion
	if hasCatalogStateChanged then
		notifyWardrobeCatalogChangedListeners(self)
	end
end

local function finishFirstPassOverPool(self)
	local availableStylingItemKeySet = {}
	local publishedWardrobeItems = {}
	for _, stylingItem in self.stylingItems do
		local resolvedDetails = self.resolvedStylingItemDetailsByStylingItemKey[stylingItem.stylingItemKey]
		if resolvedDetails ~= nil then
			availableStylingItemKeySet[stylingItem.stylingItemKey] = true
			table.insert(publishedWardrobeItems, resolvedDetails)
		end
	end
	self.availableStylingItemKeySet = table.freeze(availableStylingItemKeySet)
	self.publishedWardrobeItems = publishedWardrobeItems
	local hiddenStylingItemCount = 0
	for _ in self.hiddenReasonByStylingItemKey do
		hiddenStylingItemCount += 1
	end
	self.logger:logInformation(
		string.format(
			"MarketplaceStylingItemResolver: wardrobe catalog ready with %d available and %d hidden styling items",
			#publishedWardrobeItems,
			hiddenStylingItemCount
		)
	)
	publishWardrobeCatalogState(self, true, MarketplaceStylingItemResolver.WARDROBE_CATALOG_VERSION_AFTER_FIRST_PASS)
end

local function settleStylingItem(self)
	self.unsettledStylingItemCount -= 1
	if self.unsettledStylingItemCount == 0 then
		finishFirstPassOverPool(self)
	end
end

local function hideStylingItem(self, stylingItem: StylingItem, hiddenReason: string, problemDescription: string?)
	self.hiddenReasonByStylingItemKey[stylingItem.stylingItemKey] = hiddenReason
	self.logger:logWarning(
		string.format(
			"MarketplaceStylingItemResolver: hiding styling item %s for this server session: %s%s",
			stylingItem.stylingItemKey,
			hiddenReason,
			if problemDescription then " (" .. problemDescription .. ")" else ""
		)
	)
	settleStylingItem(self)
end

local function makeStylingItemAvailable(self, stylingItem: StylingItem, itemDetails, wornAssets: { WornAsset })
	self.resolvedStylingItemDetailsByStylingItemKey[stylingItem.stylingItemKey] = {
		stylingItemKey = stylingItem.stylingItemKey,
		marketplaceItemKind = stylingItem.marketplaceItemKind,
		marketplaceItemId = stylingItem.marketplaceItemId,
		itemDisplayName = itemDetails.itemDisplayName,
		priceInRobux = itemDetails.priceInRobux,
		wornAssets = wornAssets,
	}
	settleStylingItem(self)
end

-- Wraps a lookup method so that an answer of the wrong shape counts as a failed attempt.
local function buildCheckedLookupAttempt(
	startUncheckedLookup: (onLookupFinished: (boolean, any, string?) -> ()) -> (),
	readLookupAnswer: (untrustedLookupAnswer: any) -> (any, string?)
)
	return function(onAttemptFinished)
		startUncheckedLookup(
			function(wasLookupSuccessful: boolean, untrustedLookupAnswer: any, lookupErrorMessage: string?)
				if wasLookupSuccessful ~= true then
					onAttemptFinished(false, nil, tostring(lookupErrorMessage))
					return
				end
				local checkedLookupAnswer, answerProblemDescription = readLookupAnswer(untrustedLookupAnswer)
				if checkedLookupAnswer == nil then
					onAttemptFinished(false, nil, "malformed answer: " .. tostring(answerProblemDescription))
					return
				end
				onAttemptFinished(true, checkedLookupAnswer, nil)
			end
		)
	end
end

local function describeAttempts(attemptCount: number, lastLookupErrorMessage: string?): string
	return string.format("after %d attempts; last error: %s", attemptCount, tostring(lastLookupErrorMessage))
end

local function resolveBundleWornAssets(self, stylingItem: StylingItem, itemDetails)
	local marketplaceItemLookups = self.marketplaceItemLookups
	self.lookupRetryQueue:runLookupWithRetries(
		buildCheckedLookupAttempt(function(onLookupFinished)
			marketplaceItemLookups:startLookingUpBundleContents(stylingItem.marketplaceItemId, onLookupFinished)
		end, MarketplaceItemLookupAnswerReader.readBundleWornAssetsAnswer),
		function(wasLookupSuccessful: boolean, wornAssets, lastLookupErrorMessage: string?, attemptCount: number)
			if not wasLookupSuccessful then
				hideStylingItem(
					self,
					stylingItem,
					HIDDEN_REASONS.BundleContentsFailedToLoad,
					describeAttempts(attemptCount, lastLookupErrorMessage)
				)
				return
			end
			makeStylingItemAvailable(self, stylingItem, itemDetails, wornAssets)
		end
	)
end

local function onStylingItemDetailsSettled(
	self,
	stylingItem: StylingItem,
	wasLookupSuccessful: boolean,
	itemDetails,
	lastLookupErrorMessage: string?,
	attemptCount: number
)
	if not wasLookupSuccessful then
		hideStylingItem(
			self,
			stylingItem,
			HIDDEN_REASONS.ItemDetailsFailedToLoad,
			describeAttempts(attemptCount, lastLookupErrorMessage)
		)
		return
	end
	if not itemDetails.isOnSale then
		hideStylingItem(self, stylingItem, HIDDEN_REASONS.NotOnSale)
		return
	end
	if not itemDetails.canBeSoldInThisGame then
		hideStylingItem(self, stylingItem, HIDDEN_REASONS.NotSellableInThisGame)
		return
	end
	if stylingItem.marketplaceItemKind == StylingItemLookup.MARKETPLACE_ITEM_KINDS.Bundle then
		resolveBundleWornAssets(self, stylingItem, itemDetails)
		return
	end
	makeStylingItemAvailable(self, stylingItem, itemDetails, {
		{ wornAssetId = stylingItem.marketplaceItemId, robloxAssetTypeName = itemDetails.robloxAssetTypeName },
	})
end

local function resolveStylingItem(self, stylingItem: StylingItem)
	local marketplaceItemLookups = self.marketplaceItemLookups
	self.lookupRetryQueue:runLookupWithRetries(
		buildCheckedLookupAttempt(function(onLookupFinished)
			marketplaceItemLookups:startLookingUpMarketplaceItemDetails(
				stylingItem.marketplaceItemKind,
				stylingItem.marketplaceItemId,
				onLookupFinished
			)
		end, function(untrustedItemDetails)
			return MarketplaceItemLookupAnswerReader.readMarketplaceItemDetailsAnswer(
				stylingItem.marketplaceItemKind,
				untrustedItemDetails
			)
		end),
		function(wasLookupSuccessful: boolean, itemDetails, lastLookupErrorMessage: string?, attemptCount: number)
			onStylingItemDetailsSettled(
				self,
				stylingItem,
				wasLookupSuccessful,
				itemDetails,
				lastLookupErrorMessage,
				attemptCount
			)
		end
	)
end

function MarketplaceStylingItemResolver:startResolvingWardrobeCatalog()
	if self.hasStartedResolving then
		error("MarketplaceStylingItemResolver: the wardrobe catalog is already being resolved", 2)
	end
	self.hasStartedResolving = true
	local enabledStylingItems = {}
	for _, stylingItem in self.stylingItems do
		if stylingItem.isEnabled == true then
			table.insert(enabledStylingItems, stylingItem)
		end
	end
	if #enabledStylingItems == 0 then
		finishFirstPassOverPool(self)
		return
	end
	-- Counted in full before any lookup starts, so lookups that finish inside their start call
	-- cannot bring the count to zero early.
	self.unsettledStylingItemCount = #enabledStylingItems
	for _, enabledStylingItem in enabledStylingItems do
		resolveStylingItem(self, enabledStylingItem)
	end
end

function MarketplaceStylingItemResolver:isWardrobeCatalogReady(): boolean
	return self.isCatalogReady
end

function MarketplaceStylingItemResolver:getWardrobeCatalogVersion(): number
	return self.wardrobeCatalogVersion
end

function MarketplaceStylingItemResolver:getAvailableStylingItemKeySet(): AvailableStylingItemKeySet
	return self.availableStylingItemKeySet
end

function MarketplaceStylingItemResolver:subscribeToWardrobeCatalogChanged(
	listener: (WardrobeCatalogChangedMessage) -> ()
): () -> ()
	if type(listener) ~= "function" then
		error("MarketplaceStylingItemResolver: listener must be a function", 2)
	end
	table.insert(self.wardrobeCatalogChangedListeners, listener)
	return function()
		local listenerPosition = table.find(self.wardrobeCatalogChangedListeners, listener)
		if listenerPosition then
			table.remove(self.wardrobeCatalogChangedListeners, listenerPosition)
		end
	end
end

function MarketplaceStylingItemResolver:readWardrobeCatalogSnapshotAnswer()
	local wardrobeItems = {}
	for _, publishedWardrobeItem in self.publishedWardrobeItems do
		table.insert(wardrobeItems, copyResolvedStylingItemDetails(publishedWardrobeItem))
	end
	return {
		isAccepted = true,
		isWardrobeCatalogReady = self.isCatalogReady,
		wardrobeCatalogVersion = self.wardrobeCatalogVersion,
		wardrobeItems = wardrobeItems,
	}
end

function MarketplaceStylingItemResolver:readResolvedStylingItemDetails(
	stylingItemKey: string
): ResolvedStylingItemDetails?
	if self.availableStylingItemKeySet[stylingItemKey] ~= true then
		return nil
	end
	return copyResolvedStylingItemDetails(self.resolvedStylingItemDetailsByStylingItemKey[stylingItemKey])
end

function MarketplaceStylingItemResolver:readHiddenStylingItemReasonByStylingItemKey(): { [string]: string }
	return table.clone(self.hiddenReasonByStylingItemKey)
end

function MarketplaceStylingItemResolver:startAnsweringStylingItemOwnershipRequest(
	playerUserId: number,
	untrustedStylingItemKey: any,
	onOwnershipAnswerReady: (
		ownershipAnswer: { [string]: any }
	) -> ()
)
	StylingItemOwnershipRequestAnswerer.startAnsweringStylingItemOwnershipRequest({
		stylingItemByStylingItemKey = self.stylingItemByStylingItemKey,
		availableStylingItemKeySet = self.availableStylingItemKeySet,
		marketplaceItemLookups = self.marketplaceItemLookups,
		scheduler = self.scheduler,
		logger = self.logger,
	}, playerUserId, untrustedStylingItemKey, onOwnershipAnswerReady)
end

return MarketplaceStylingItemResolver
