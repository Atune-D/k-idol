-- PromoCodeRedeemer (development spec v1.3 §1.9, §2.10, §2.13, §3.3, §3.4): answers
-- `RequestRedeemPromoCode` from a player's device and, when the typed code is redeemable, pays its
-- Star Coins through the RewardLedger in the same save change that records the redemption.
--
-- SERVER ONLY: it requires PromoCodeCatalog and therefore lives in src/server, next to it.
-- Calls no Roblox-specific interface. Everything external is injected (see `new`).
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (the server wiring is written from this)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- PromoCodeRedeemer.PROMO_CODE_REDEMPTION_REJECTION_REASONS
--   = { UnknownPromoCode, PromoCodeNotActive, AlreadyRedeemed, TooManyAttempts, SaveDataNotLoaded }
--   Frozen. The §2.10 reasons, plus SaveDataNotLoaded (§3.4).
--
-- PromoCodeRedeemer.new(promoCodeRedeemerDependencies) -> promoCodeRedeemer
--   promoCodeRedeemerDependencies = {
--     playerSaveDataKeeper: { isPlayerSaveDataLoaded: (self, playerUserId) -> boolean },
--         normally the PlayerSaveDataKeeper the reward ledger uses.
--     rewardLedger: { grantStarCoinsAndFans: (self, playerUserId, starCoinAndFanGrantRequest) -> outcome },
--     playerRequestRateLimiter: { admitOrRefusePlayerRequest: (self, playerUserId, remoteChannelName) -> decision },
--     clock: { getCurrentUnixSeconds: (self) -> number },   -- the server's clock (UTC Unix seconds)
--     logger: { logInformation: (self, message: string) -> () },
--     promoCodeEntries: { PromoCodeCatalog.PromoCode },
--         The wiring passes PromoCodeCatalog.PROMO_CODES; tests pass fixture entries. The list is
--         copied into a frozen list (later changes to the caller's list are not seen, and nothing
--         can add to or replace the redeemer's entries). Every entry must already be
--         frozen (PromoCodeCatalog.freezePromoCodeCatalog does that) and the entries must pass
--         PromoCodeCatalog.findPromoCodeCatalogProblems.
--   }
--   Raises when a dependency is missing, an entry is not frozen, or the catalog has a problem.
--
-- promoCodeRedeemer:redeemPromoCodeAndAnswerRequest(playerUserId, untrustedPromoCodeText) -> answer
--   Call for every `RequestRedeemPromoCode` that arrives. `playerUserId` comes from the server
--   (the sending player); `untrustedPromoCodeText` is whatever the device sent, any Luau value.
--   Steps, each stopping at its rejection:
--     1. playerRequestRateLimiter:admitOrRefusePlayerRequest(playerUserId, "RequestRedeemPromoCode").
--        On refusal: { isAccepted = false, rejectionReason = <the limiter's reason, TooManyAttempts> }.
--        Nothing else is looked at: not the text, the save, the clock or the catalog (§2.10).
--     2. Save not loaded (keeper:isPlayerSaveDataLoaded is false) -> SaveDataNotLoaded.
--     3. PromoCodeCatalog.decidePromoCodeMatchAtUnixSeconds(text, clock now, entries):
--        UnknownPromoCode (no match; also every non-string, empty or over-long value) or
--        PromoCodeNotActive (matched, outside validFrom <= now < validUntil).
--     4. ONE rewardLedger:grantStarCoinsAndFans with rewardSourceKind "PromoCode",
--        starCoinsToGrant = the matched entry's starCoinReward (never anything from the device),
--        fanCountToGrant = 0. Its eligibility check declines "AlreadyRedeemed" when the entry's
--        promoCodeId is already in `redeemedPromoCodeIds`; its record appends the promoCodeId.
--        Reward and record are therefore one save change (§3.3). Ledger "Declined" with
--        declineReason "AlreadyRedeemed" -> AlreadyRedeemed; ledger "SaveDataNotLoaded" ->
--        SaveDataNotLoaded. Any other ledger outcome is a programming error and raises.
--   Accepted: { isAccepted = true, starCoinsGranted = <the entry's starCoinReward> }. The new
--   balance reaches the device through PlayerSaveDataSnapshotChanged (§2.6).
--   Every answer is a new table. The typed text is never echoed in an answer and never logged.
--   Nothing the device sends makes this raise; a programming error in the injected parts does.
--
-- Logging (each line names the player, never the typed text). Every request the limiter admits
-- gets exactly ONE line, written either by the redeemer or by the RewardLedger, so the redeemer
-- and the ledger together write at most one line per player every 2 seconds:
--   SaveDataNotLoaded (step 2), UnknownPromoCode, PromoCodeNotActive -> the redeemer, through
--     logInformation, naming the reason and, for PromoCodeNotActive, the matched promoCodeId.
--   accepted, AlreadyRedeemed, ledger SaveDataNotLoaded -> the RewardLedger only ("applied",
--     "declined ...: AlreadyRedeemed" or "refused ...: save data not loaded", each naming
--     rewardSourceKind PromoCode and "promo code <id>"); the redeemer adds no second line.
--   TooManyAttempts -> nothing, so a device sending as fast as it can cannot flood the log.
--
-- Work per request is bounded: the catalog ignores typed values over
-- PromoCodeCatalog.MAXIMUM_TYPED_PROMO_CODE_TEXT_BYTE_COUNT bytes before any string work, then
-- compares against each entry once.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local PromoCodeCatalog = require("./PromoCodeCatalog")
local RemoteNames = require("../shared/RemoteNames")
local RewardLedger = require("./RewardLedger")

type PromoCode = PromoCodeCatalog.PromoCode

local PromoCodeRedeemer = {}
PromoCodeRedeemer.__index = PromoCodeRedeemer

PromoCodeRedeemer.PROMO_CODE_REDEMPTION_REJECTION_REASONS = table.freeze({
	UnknownPromoCode = PromoCodeCatalog.PROMO_CODE_REJECTION_REASONS.UnknownPromoCode,
	PromoCodeNotActive = PromoCodeCatalog.PROMO_CODE_REJECTION_REASONS.PromoCodeNotActive,
	AlreadyRedeemed = "AlreadyRedeemed",
	TooManyAttempts = "TooManyAttempts",
	SaveDataNotLoaded = "SaveDataNotLoaded",
})

local REJECTION_REASONS = PromoCodeRedeemer.PROMO_CODE_REDEMPTION_REJECTION_REASONS
local PROMO_CODE_REMOTE_CHANNEL_NAME = RemoteNames.REMOTE_CHANNEL_NAMES.RequestRedeemPromoCode

local REQUIRED_DEPENDENCY_NAMES =
	{ "playerSaveDataKeeper", "rewardLedger", "playerRequestRateLimiter", "clock", "logger", "promoCodeEntries" }

-- Raises when the caller's list breaks a rule in the header; otherwise returns a frozen copy of it.
local function validateAndCopyPromoCodeEntriesIntoFrozenList(promoCodeEntries: any): { PromoCode }
	if type(promoCodeEntries) ~= "table" then
		error("PromoCodeRedeemer.new: promoCodeEntries must be a list of promo codes", 3)
	end
	for entryPosition, promoCodeEntry in promoCodeEntries do
		if type(promoCodeEntry) == "table" and not table.isfrozen(promoCodeEntry) then
			error(
				string.format(
					"PromoCodeRedeemer.new: promoCodeEntries[%s] is not frozen (use PromoCodeCatalog.freezePromoCodeCatalog)",
					tostring(entryPosition)
				),
				3
			)
		end
	end
	local catalogProblems = PromoCodeCatalog.findPromoCodeCatalogProblems(promoCodeEntries)
	if #catalogProblems > 0 then
		error("PromoCodeRedeemer.new: invalid promoCodeEntries: " .. table.concat(catalogProblems, "; "), 3)
	end
	return table.freeze(table.clone(promoCodeEntries))
end

function PromoCodeRedeemer.new(promoCodeRedeemerDependencies)
	if type(promoCodeRedeemerDependencies) ~= "table" then
		error("PromoCodeRedeemer.new: needs a dependencies table", 2)
	end
	for _, requiredDependencyName in REQUIRED_DEPENDENCY_NAMES do
		if promoCodeRedeemerDependencies[requiredDependencyName] == nil then
			error("PromoCodeRedeemer.new: missing dependency " .. requiredDependencyName, 2)
		end
	end
	return setmetatable({
		playerSaveDataKeeper = promoCodeRedeemerDependencies.playerSaveDataKeeper,
		rewardLedger = promoCodeRedeemerDependencies.rewardLedger,
		playerRequestRateLimiter = promoCodeRedeemerDependencies.playerRequestRateLimiter,
		clock = promoCodeRedeemerDependencies.clock,
		logger = promoCodeRedeemerDependencies.logger,
		promoCodeEntries = validateAndCopyPromoCodeEntriesIntoFrozenList(
			promoCodeRedeemerDependencies.promoCodeEntries
		),
	}, PromoCodeRedeemer)
end

local function buildRejectionAnswer(rejectionReason: string)
	return { isAccepted = false, rejectionReason = rejectionReason }
end

-- Logs a rejection the redeemer itself decided after the limiter admitted the request.
local function logAdmittedRejection(self, playerUserId: number, rejectionReason: string, matchedPromoCodeId: string?)
	self.logger:logInformation(
		string.format(
			"PromoCodeRedeemer: redemption for player %s rejected: %s%s",
			tostring(playerUserId),
			rejectionReason,
			if matchedPromoCodeId then " (promoCodeId " .. matchedPromoCodeId .. ")" else ""
		)
	)
end

local function logRejectionAndBuildRejectionAnswer(
	self,
	playerUserId: number,
	rejectionReason: string,
	matchedPromoCodeId: string?
)
	logAdmittedRejection(self, playerUserId, rejectionReason, matchedPromoCodeId)
	return buildRejectionAnswer(rejectionReason)
end

-- One ledger grant: the AlreadyRedeemed check, the Star Coins and the record are one save change.
local function grantPromoCodeRewardWithRedemptionRecord(self, playerUserId: number, matchedPromoCode: PromoCode)
	local redeemedPromoCodeId = matchedPromoCode.promoCodeId
	return self.rewardLedger:grantStarCoinsAndFans(playerUserId, {
		rewardSourceKind = RewardLedger.REWARD_SOURCE_KINDS.PromoCode,
		starCoinsToGrant = matchedPromoCode.starCoinReward,
		fanCountToGrant = 0,
		grantDescriptionForLogs = "promo code " .. redeemedPromoCodeId,
		checkGrantEligibility = function(saveDataReadOnlyView)
			if table.find(saveDataReadOnlyView.redeemedPromoCodeIds, redeemedPromoCodeId) ~= nil then
				return false, REJECTION_REASONS.AlreadyRedeemed
			end
			return true
		end,
		writeGrantRecordThatPreventsRepeat = function(saveDataDraft)
			table.insert(saveDataDraft.redeemedPromoCodeIds, redeemedPromoCodeId)
		end,
	})
end

function PromoCodeRedeemer:redeemPromoCodeAndAnswerRequest(playerUserId: number, untrustedPromoCodeText: any)
	local rateLimitDecision =
		self.playerRequestRateLimiter:admitOrRefusePlayerRequest(playerUserId, PROMO_CODE_REMOTE_CHANNEL_NAME)
	if not rateLimitDecision.isRequestAllowed then
		return buildRejectionAnswer(rateLimitDecision.rejectionReason)
	end

	if not self.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId) then
		return logRejectionAndBuildRejectionAnswer(self, playerUserId, REJECTION_REASONS.SaveDataNotLoaded)
	end

	local promoCodeMatchDecision = PromoCodeCatalog.decidePromoCodeMatchAtUnixSeconds(
		untrustedPromoCodeText,
		self.clock:getCurrentUnixSeconds(),
		self.promoCodeEntries
	)
	if not promoCodeMatchDecision.isPromoCodeActiveMatch then
		local inactiveMatchedPromoCode = promoCodeMatchDecision.matchedPromoCode
		return logRejectionAndBuildRejectionAnswer(
			self,
			playerUserId,
			promoCodeMatchDecision.rejectionReason :: string,
			if inactiveMatchedPromoCode then inactiveMatchedPromoCode.promoCodeId else nil
		)
	end
	-- PromoCodeCatalog contract: an active match always carries its entry.
	local matchedPromoCode = promoCodeMatchDecision.matchedPromoCode :: PromoCode

	local grantOutcome = grantPromoCodeRewardWithRedemptionRecord(self, playerUserId, matchedPromoCode)
	if grantOutcome.rewardLedgerOutcome == "Granted" then
		return { isAccepted = true, starCoinsGranted = grantOutcome.starCoinsGranted }
	end
	-- The ledger has already logged these two outcomes; the redeemer adds no second line.
	if grantOutcome.rewardLedgerOutcome == "SaveDataNotLoaded" then
		return buildRejectionAnswer(REJECTION_REASONS.SaveDataNotLoaded)
	end
	-- The eligibility check above is the only way this grant can be declined.
	if
		grantOutcome.rewardLedgerOutcome == "Declined"
		and grantOutcome.declineReason == REJECTION_REASONS.AlreadyRedeemed
	then
		return buildRejectionAnswer(REJECTION_REASONS.AlreadyRedeemed)
	end
	error(
		string.format(
			"PromoCodeRedeemer: unexpected RewardLedger outcome %s (declineReason %s)",
			tostring(grantOutcome.rewardLedgerOutcome),
			tostring(grantOutcome.declineReason)
		)
	)
end

return table.freeze(PromoCodeRedeemer)
