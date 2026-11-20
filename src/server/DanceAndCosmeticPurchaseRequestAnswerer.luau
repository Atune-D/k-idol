-- DanceAndCosmeticPurchaseRequestAnswerer (development spec v1.3 §0.2 "How players spend", §1.7,
-- §2.8 rows `RequestPurchaseDanceWithStarCoins` and `RequestPurchaseCosmeticWithStarCoins`, §2.13,
-- §3.3 "Dance or cosmetic purchase", §3.4): buys a dance or a cosmetic with Star Coins.
--
-- Each accepted purchase is ONE RewardLedger spend (purchaseKind "Dance" or "Cosmetic"): inside
-- that one save change the ledger runs this module's "AlreadyOwned" check, takes the catalog
-- price off `starCoinBalance` (refusing "InsufficientStarCoins" if it would go below 0), and this
-- module adds the id to `ownedDanceIds` or `ownedCosmeticIds`. A save therefore never holds the
-- payment without the ownership or the ownership without the payment, and buying an owned item
-- is refused and costs nothing. The price always comes from the catalog, never from the device.
--
-- Calls no Roblox-specific interface. Everything external is injected (see `new`).
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (the server wiring is written from this)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- DanceAndCosmeticPurchaseRequestAnswerer.new(dependencies) -> purchaseRequestAnswerer
--   dependencies = {
--     playerSaveDataKeeper: PlayerSaveDataKeeper   (only isPlayerSaveDataLoaded is used),
--     rewardLedger: RewardLedger                   (only spendStarCoins is used),
--     playerRequestRateLimiter: PlayerRequestRateLimiter (only admitOrRefusePlayerRequest is used),
--     danceCatalog: DanceCatalogForShop,           -- see DanceAndCosmeticCatalogEntryFinder;
--     cosmeticCatalog: CosmeticCatalogForShop,     -- normally src/shared/DanceCatalog / CosmeticCatalog
--     logger: { logInformation: (self, message: string) -> (), logWarning: (self, message: string) -> () },
--   }
--   Raises, naming it, when any dependency is missing, or when a catalog lacks its lookup
--   function (DanceAndCosmeticRequestScreening.checkDanceAndCosmeticDependenciesPresent).
--
-- DanceAndCosmeticPurchaseRequestAnswerer.PURCHASE_REJECTION_REASONS (frozen):
--   UnknownDance, UnknownCosmetic, AlreadyOwned, InsufficientStarCoins, SaveDataNotLoaded,
--   TooManyRequests.
--
-- purchaseRequestAnswerer:purchaseDanceWithStarCoinsAndBuildAnswer(playerUserId, untrustedDanceId) -> answer
--   Answers `RequestPurchaseDanceWithStarCoins`. `untrustedDanceId` may be ANY Luau value.
-- purchaseRequestAnswerer:purchaseCosmeticWithStarCoinsAndBuildAnswer(playerUserId, untrustedCosmeticId) -> answer
--   Answers `RequestPurchaseCosmeticWithStarCoins`, by the same steps.
--
--   Steps, in order; the first that refuses gives the answer and nothing after it runs
--   (steps 1-3 are DanceAndCosmeticRequestScreening):
--     1. playerRequestRateLimiter:admitOrRefusePlayerRequest(playerUserId, <the request's channel
--        name from RemoteNames>). On refusal: its rejectionReason ("TooManyRequests"); the id is
--        not looked at and nothing else is asked.
--     2. Save not loaded (playerSaveDataKeeper:isPlayerSaveDataLoaded false): "SaveDataNotLoaded".
--     3. The id names no catalog entry usable for a purchase (any non-string, empty or over-long
--        value counts; see DanceAndCosmeticCatalogEntryFinder, use "Purchase"):
--        "UnknownDance" / "UnknownCosmetic". Dances granted to new players are in the catalog
--        with starCoinPrice 0 and can be bought (for 0) by a player who lacks one.
--     4. rewardLedger:spendStarCoins with the catalog's starCoinPrice:
--          already in ownedDanceIds / ownedCosmeticIds  -> "AlreadyOwned" (checked before the
--                                                           balance, so it costs nothing)
--          balance below the price                      -> "InsufficientStarCoins"
--          the ledger finds the save not loaded         -> "SaveDataNotLoaded"
--          spent                                        -> accepted; the id is appended to
--                                                          ownedDanceIds / ownedCosmeticIds and a
--                                                          save is requested at once (§3.4)
--   answer = { isAccepted = true }
--          | { isAccepted = false, rejectionReason = <one of PURCHASE_REJECTION_REASONS> }
--   A fresh table every time; the caller may change it. A purchase changes only starCoinBalance
--   and the one owned list; nothing is equipped.
--   Logging: this module logs nothing itself. The finder warns about an unusable catalog entry and
--   the ledger logs every spend and decline (its description is "dance <id>" / "cosmetic <id>").
--   A device value therefore reaches a log line only when it is a string of at most 64 bytes that
--   names a catalog entry. Nothing the device sent is echoed back.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local DanceAndCosmeticCatalogEntryFinder = require("./DanceAndCosmeticCatalogEntryFinder")
local DanceAndCosmeticRequestScreening = require("./DanceAndCosmeticRequestScreening")
local RemoteNames = require("../shared/RemoteNames")
local RewardLedger = require("./RewardLedger")

local REMOTE_CHANNEL_NAMES = RemoteNames.REMOTE_CHANNEL_NAMES
local SCREENING_OUTCOMES = DanceAndCosmeticRequestScreening.SCREENING_OUTCOMES
local buildRejectedAnswer = DanceAndCosmeticRequestScreening.buildRejectedAnswer

local DanceAndCosmeticPurchaseRequestAnswerer = {}
DanceAndCosmeticPurchaseRequestAnswerer.__index = DanceAndCosmeticPurchaseRequestAnswerer

DanceAndCosmeticPurchaseRequestAnswerer.PURCHASE_REJECTION_REASONS = table.freeze({
	UnknownDance = "UnknownDance",
	UnknownCosmetic = "UnknownCosmetic",
	AlreadyOwned = "AlreadyOwned",
	InsufficientStarCoins = "InsufficientStarCoins",
	SaveDataNotLoaded = "SaveDataNotLoaded",
	TooManyRequests = "TooManyRequests",
})

local PURCHASE_REJECTION_REASONS = DanceAndCosmeticPurchaseRequestAnswerer.PURCHASE_REJECTION_REASONS

local REQUIRED_DEPENDENCY_NAMES = table.freeze({
	"playerSaveDataKeeper",
	"rewardLedger",
	"playerRequestRateLimiter",
	"danceCatalog",
	"cosmeticCatalog",
	"logger",
})

-- Everything that differs between the two purchase requests.
type DanceOrCosmeticPurchaseRequestSettings = {
	remoteChannelName: string,
	ledgerPurchaseKind: string,
	danceOrCosmeticFamily: DanceAndCosmeticRequestScreening.DanceOrCosmeticFamily,
	unknownIdRejectionReason: string,
}

local DANCE_PURCHASE_REQUEST_SETTINGS: DanceOrCosmeticPurchaseRequestSettings = table.freeze({
	remoteChannelName = REMOTE_CHANNEL_NAMES.RequestPurchaseDanceWithStarCoins,
	ledgerPurchaseKind = RewardLedger.PURCHASE_KINDS.Dance,
	danceOrCosmeticFamily = DanceAndCosmeticRequestScreening.DANCE_FAMILY,
	unknownIdRejectionReason = PURCHASE_REJECTION_REASONS.UnknownDance,
})

local COSMETIC_PURCHASE_REQUEST_SETTINGS: DanceOrCosmeticPurchaseRequestSettings = table.freeze({
	remoteChannelName = REMOTE_CHANNEL_NAMES.RequestPurchaseCosmeticWithStarCoins,
	ledgerPurchaseKind = RewardLedger.PURCHASE_KINDS.Cosmetic,
	danceOrCosmeticFamily = DanceAndCosmeticRequestScreening.COSMETIC_FAMILY,
	unknownIdRejectionReason = PURCHASE_REJECTION_REASONS.UnknownCosmetic,
})

function DanceAndCosmeticPurchaseRequestAnswerer.new(dependencies)
	DanceAndCosmeticRequestScreening.checkDanceAndCosmeticDependenciesPresent(
		"DanceAndCosmeticPurchaseRequestAnswerer",
		dependencies,
		REQUIRED_DEPENDENCY_NAMES
	)
	return setmetatable({
		playerSaveDataKeeper = dependencies.playerSaveDataKeeper,
		rewardLedger = dependencies.rewardLedger,
		playerRequestRateLimiter = dependencies.playerRequestRateLimiter,
		danceCatalog = dependencies.danceCatalog,
		cosmeticCatalog = dependencies.cosmeticCatalog,
		logger = dependencies.logger,
	}, DanceAndCosmeticPurchaseRequestAnswerer)
end

local function purchaseDanceOrCosmeticAndBuildAnswer(
	self,
	purchaseRequestSettings: DanceOrCosmeticPurchaseRequestSettings,
	playerUserId: number,
	untrustedDanceOrCosmeticId: any
)
	local danceOrCosmeticFamily = purchaseRequestSettings.danceOrCosmeticFamily
	local screeningOutcome, rejectionReasonOrCatalogEntry =
		DanceAndCosmeticRequestScreening.screenRequestAndFindCatalogEntry(
			self,
			danceOrCosmeticFamily,
			purchaseRequestSettings.remoteChannelName,
			DanceAndCosmeticCatalogEntryFinder.CATALOG_ENTRY_USES.Purchase,
			playerUserId,
			untrustedDanceOrCosmeticId
		)
	if screeningOutcome == SCREENING_OUTCOMES.RequestRefused then
		return buildRejectedAnswer(rejectionReasonOrCatalogEntry)
	end
	if screeningOutcome == SCREENING_OUTCOMES.NoUsableCatalogEntry then
		return buildRejectedAnswer(purchaseRequestSettings.unknownIdRejectionReason)
	end

	local catalogEntry = rejectionReasonOrCatalogEntry
	local purchasedDanceOrCosmeticId = catalogEntry[danceOrCosmeticFamily.catalogEntryIdFieldName]
	local ownedIdsFieldName = danceOrCosmeticFamily.ownedIdsFieldName
	local ledgerPurchaseKind = purchaseRequestSettings.ledgerPurchaseKind
	local spendOutcome = self.rewardLedger:spendStarCoins(playerUserId, {
		purchaseKind = ledgerPurchaseKind,
		starCoinPrice = catalogEntry.starCoinPrice,
		purchaseDescriptionForLogs = string.format(
			"%s %s",
			string.lower(ledgerPurchaseKind),
			purchasedDanceOrCosmeticId
		),
		checkPurchaseEligibility = function(saveDataReadOnlyView)
			if table.find(saveDataReadOnlyView[ownedIdsFieldName], purchasedDanceOrCosmeticId) ~= nil then
				return false, PURCHASE_REJECTION_REASONS.AlreadyOwned
			end
			return true
		end,
		writePurchaseRecordThatPreventsRepeat = function(saveDataDraft)
			table.insert(saveDataDraft[ownedIdsFieldName], purchasedDanceOrCosmeticId)
		end,
	})
	if spendOutcome.rewardLedgerOutcome == "Spent" then
		return { isAccepted = true }
	end
	if spendOutcome.rewardLedgerOutcome == "SaveDataNotLoaded" then
		return buildRejectedAnswer(PURCHASE_REJECTION_REASONS.SaveDataNotLoaded)
	end
	-- "Declined": only "AlreadyOwned" (above) or the ledger's "InsufficientStarCoins" can arrive.
	return buildRejectedAnswer(spendOutcome.declineReason)
end

function DanceAndCosmeticPurchaseRequestAnswerer:purchaseDanceWithStarCoinsAndBuildAnswer(
	playerUserId: number,
	untrustedDanceId: any
)
	return purchaseDanceOrCosmeticAndBuildAnswer(self, DANCE_PURCHASE_REQUEST_SETTINGS, playerUserId, untrustedDanceId)
end

function DanceAndCosmeticPurchaseRequestAnswerer:purchaseCosmeticWithStarCoinsAndBuildAnswer(
	playerUserId: number,
	untrustedCosmeticId: any
)
	return purchaseDanceOrCosmeticAndBuildAnswer(
		self,
		COSMETIC_PURCHASE_REQUEST_SETTINGS,
		playerUserId,
		untrustedCosmeticId
	)
end

return DanceAndCosmeticPurchaseRequestAnswerer
