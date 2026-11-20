-- RewardLedger (development spec v1.3 §0.2 "Three shared foundations", §3.3): the single place
-- where Star Coins and fans are granted or spent.
--
-- Every grant and every spend is ONE call to PlayerSaveDataKeeper:applyChangeToPlayerSaveData,
-- and inside that one change it (1) runs the caller's eligibility check against the current save,
-- (2) changes `starCoinBalance` and/or `fanCount`, (3) lets the caller write the record that makes
-- the operation non-repeatable. Nothing can run in between, so a save never holds a reward without
-- its record or a record without its reward (spec §3.3 "A reward and its record are one change").
-- No caller can grant first and record afterwards: there is no other way in.
--
-- Calls no Roblox-specific interface. Everything external is injected (see `new`).
-- The single save change itself lives in RewardLedgerSingleSaveChange.luau (split for length).
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (the round referee, daily rewards, promo codes and the dance shop are written from this)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- RewardLedger.new(rewardLedgerDependencies) -> rewardLedger
--   rewardLedgerDependencies = {
--     playerSaveDataKeeper: PlayerSaveDataKeeper,
--     logger: { logInformation: (self, message: string) -> (), logWarning: (self, message: string) -> () },
--     themedRoundCompletionRecordWriters: { ThemedRoundCompletionRecordWriter }?,   -- optional, see below
--   }
--
-- RewardLedger.REWARD_SOURCE_KINDS = { ThemedRound, PlaytimeMilestone, DailyQuest, PromoCode }
-- RewardLedger.PURCHASE_KINDS      = { Dance, Cosmetic }
--
-- rewardLedger:grantStarCoinsAndFans(playerUserId, starCoinAndFanGrantRequest) -> StarCoinAndFanGrantOutcome
--   starCoinAndFanGrantRequest = {
--     rewardSourceKind: "PlaytimeMilestone" | "DailyQuest" | "PromoCode",
--         "ThemedRound" is refused here: round rewards go through grantThemedRoundReward, which
--         takes the amounts from OutfitScoreCalculator. Any unknown kind raises.
--     starCoinsToGrant: number, fanCountToGrant: number,   -- whole numbers >= 0, else it raises
--     grantDescriptionForLogs: string,                      -- e.g. "playtime milestone 10 min"
--     checkGrantEligibility: (saveDataReadOnlyView) -> (isEligible: boolean, declineReason: string?)
--         Runs first, on a deeply frozen copy of the current save (writing to it raises). Return
--         false plus a non-empty reason string (e.g. "AlreadyClaimed") to decline.
--     writeGrantRecordThatPreventsRepeat: (saveDataDraft) -> ()
--         Runs after the ledger has added the amounts. Must write the record (e.g. add the
--         milestone to `dailyProgress.claimedPlaytimeMilestoneMinutes`). It must change the save,
--         and must not change `starCoinBalance` or `fanCount`; otherwise the call raises.
--   }
--
-- rewardLedger:spendStarCoins(playerUserId, starCoinSpendRequest) -> StarCoinSpendOutcome
--   starCoinSpendRequest = {
--     purchaseKind: "Dance" | "Cosmetic",                   -- any other value raises
--     starCoinPrice: number,                                 -- whole number >= 0, else it raises
--     purchaseDescriptionForLogs: string,                    -- e.g. "dance neon_spin"
--     checkPurchaseEligibility: (saveDataReadOnlyView) -> (isEligible: boolean, declineReason: string?)
--         Same rules as checkGrantEligibility (e.g. decline "AlreadyOwned"). Runs BEFORE the
--         balance check, so an owned item is refused as "AlreadyOwned" even when unaffordable.
--     writePurchaseRecordThatPreventsRepeat: (saveDataDraft) -> ()
--         Same rules as writeGrantRecordThatPreventsRepeat (e.g. add the id to `ownedDanceIds`).
--   }
--   A spend that would take `starCoinBalance` below 0 is declined with "InsufficientStarCoins"
--   and changes nothing.
--
-- rewardLedger:grantThemedRoundReward(playerUserId, themedRoundCompletion) -> ThemedRoundRewardOutcome
--   themedRoundCompletion = {
--     roundId: string, themeId: string,
--     starCount: number,                     -- 1..5; an empty outfit gets no reward, so do not call
--     scoredOutfitStylingItemKeys: { string },  -- the outfit that was scored (for Phase 2 daily quests)
--   }
--   One change that grants the §1.6 Star Coins and fans for `starCount`, adds 1 to
--   `totalRoundsCompletedCount`, raises `bestStarCountByThemeId[themeId]` if beaten, and runs every
--   themedRoundCompletionRecordWriter. A second call for the same roundId and player on this ledger
--   is declined with "RoundRewardAlreadyGranted".
--
-- ThemedRoundCompletionRecordWriter = (saveDataDraft, themedRoundCompletion) -> ()
--   Extension point for Phase 2 daily quest progress: each writer runs inside the SAME change as
--   the round reward, after the ledger's own record. It must not change `starCoinBalance` or
--   `fanCount` and must not yield; if it raises, the whole round reward is not applied and the
--   error is passed on. Callers of grantThemedRoundReward never change when writers are added.
--
-- Outcomes. `rewardLedgerOutcome` is always present:
--   StarCoinAndFanGrantOutcome =
--       { rewardLedgerOutcome = "Granted", starCoinsGranted, fanCountGained,
--         starCoinBalanceAfterChange, fanCountAfterChange, inMemoryChangeRevision }
--     | { rewardLedgerOutcome = "Declined", declineReason: string }
--     | { rewardLedgerOutcome = "SaveDataNotLoaded" }   -- answer requests with `SaveDataNotLoaded`
--   StarCoinSpendOutcome =
--       { rewardLedgerOutcome = "Spent", starCoinsSpent, starCoinBalanceAfterChange, inMemoryChangeRevision }
--     | "Declined" / "SaveDataNotLoaded" as above
--   ThemedRoundRewardOutcome = StarCoinAndFanGrantOutcome plus `isNewBestStarCountForTheme`.
--     On "Declined" and "SaveDataNotLoaded" it also carries starCoinsGranted = 0,
--     fanCountGained = 0 and isNewBestStarCountForTheme = false, so §2.5 results can always read them.
--
-- Logging (spec §3.3: every grant and spend is logged; each line names the player and the kind):
--   applied, and declined by an eligibility check or "InsufficientStarCoins" -> logInformation
--   declined as "RoundRewardAlreadyGranted", SaveDataNotLoaded, programming errors -> logWarning
--   (programming errors also raise). A decline line also names its reason.
--
-- An applied grant or spend is a "ProgressChangeSavedAtOnce": the keeper requests a save at once.
-- The change is in memory only until that save succeeds (spec §3.4).
-- ════════════════════════════════════════════════════════════════════════════════════════════

local OutfitScoreCalculator = require("../shared/OutfitScoreCalculator")
local RewardLedgerSingleSaveChange = require("./RewardLedgerSingleSaveChange")

local createDeeplyFrozenCopy = RewardLedgerSingleSaveChange.createDeeplyFrozenCopy
local applyBalanceChangeWithRecordAsOneSaveChange =
	RewardLedgerSingleSaveChange.applyBalanceChangeWithRecordAsOneSaveChange

type BalanceChangeReport = RewardLedgerSingleSaveChange.BalanceChangeReport

local RewardLedger = {}
RewardLedger.__index = RewardLedger

-- Phase 3-4 kinds (StylingCommission, Tournament, HiddenQuest) are added with their contracts.
RewardLedger.REWARD_SOURCE_KINDS = table.freeze({
	ThemedRound = "ThemedRound",
	PlaytimeMilestone = "PlaytimeMilestone",
	DailyQuest = "DailyQuest",
	PromoCode = "PromoCode",
})
RewardLedger.PURCHASE_KINDS = table.freeze({
	Dance = "Dance",
	Cosmetic = "Cosmetic",
})

RewardLedger.INSUFFICIENT_STAR_COINS_DECLINE_REASON =
	RewardLedgerSingleSaveChange.INSUFFICIENT_STAR_COINS_DECLINE_REASON
RewardLedger.ROUND_REWARD_ALREADY_GRANTED_DECLINE_REASON = "RoundRewardAlreadyGranted"

-- The duplicate-round guard remembers this many most recent round ids. A referee only ever
-- rewards the round that just ended, so a small window is plenty and memory stays bounded.
RewardLedger.REMEMBERED_ROUND_ID_COUNT_FOR_DUPLICATE_GUARD = 16

export type RewardLedgerOutcomeKind = "Granted" | "Spent" | "Declined" | "SaveDataNotLoaded"

-- ── checks ──────────────────────────────────────────────────────────────────────────────────

local function raiseLoudly(self, message: string): never
	self.logger:logWarning(message)
	error(message, 3)
end

local function isWholeNonNegativeNumber(candidateAmount: any): boolean
	return type(candidateAmount) == "number"
		and candidateAmount == candidateAmount -- not NaN
		and candidateAmount >= 0
		and candidateAmount ~= math.huge
		and candidateAmount % 1 == 0
end

local function requireWholeNonNegativeAmount(self, candidateAmount: any, amountName: string)
	if not isWholeNonNegativeNumber(candidateAmount) then
		raiseLoudly(
			self,
			string.format("RewardLedger: %s must be a whole number >= 0, got %s", amountName, tostring(candidateAmount))
		)
	end
end

local function requireFunction(self, candidateFunction: any, functionName: string)
	if type(candidateFunction) ~= "function" then
		raiseLoudly(self, string.format("RewardLedger: %s must be a function", functionName))
	end
end

local function requireNonEmptyString(self, candidateText: any, textName: string)
	if type(candidateText) ~= "string" or candidateText == "" then
		raiseLoudly(self, string.format("RewardLedger: %s must be a non-empty string", textName))
	end
end

local function logNotAppliedOutcome(self, playerUserId: number, changeDescription: string, report: BalanceChangeReport)
	if report.keeperChangeOutcome == "SaveDataNotLoaded" then
		self.logger:logWarning(
			string.format(
				"RewardLedger: %s refused for player %d: save data not loaded",
				changeDescription,
				playerUserId
			)
		)
		return
	end
	self.logger:logInformation(
		string.format(
			"RewardLedger: %s declined for player %d: %s",
			changeDescription,
			playerUserId,
			tostring(report.declineReason)
		)
	)
end

local function buildNotAppliedOutcome(report: BalanceChangeReport)
	if report.keeperChangeOutcome == "SaveDataNotLoaded" then
		return { rewardLedgerOutcome = "SaveDataNotLoaded" }
	end
	return { rewardLedgerOutcome = "Declined", declineReason = report.declineReason }
end

-- ── public API ──────────────────────────────────────────────────────────────────────────────

function RewardLedger.new(rewardLedgerDependencies)
	for _, requiredDependencyName in { "playerSaveDataKeeper", "logger" } do
		if rewardLedgerDependencies[requiredDependencyName] == nil then
			error("RewardLedger.new: missing dependency " .. requiredDependencyName, 2)
		end
	end
	local themedRoundCompletionRecordWriters = rewardLedgerDependencies.themedRoundCompletionRecordWriters or {}
	for writerPosition, themedRoundCompletionRecordWriter in themedRoundCompletionRecordWriters do
		if type(themedRoundCompletionRecordWriter) ~= "function" then
			error(
				string.format(
					"RewardLedger.new: themedRoundCompletionRecordWriters[%d] is not a function",
					writerPosition
				),
				2
			)
		end
	end
	return setmetatable({
		playerSaveDataKeeper = rewardLedgerDependencies.playerSaveDataKeeper,
		logger = rewardLedgerDependencies.logger,
		themedRoundCompletionRecordWriters = table.freeze(table.clone(themedRoundCompletionRecordWriters)),
		-- Duplicate-round guard: [roundId] = { [playerUserId] = true }, oldest round ids first.
		rewardedPlayerUserIdsByRoundId = {} :: { [string]: { [number]: boolean } },
		rememberedRoundIdsInGrantOrder = {} :: { string },
	}, RewardLedger)
end

-- Shared by grantStarCoinsAndFans and grantThemedRoundReward once the request has been checked.
local function grantAfterRequestChecked(self, playerUserId: number, starCoinAndFanGrantRequest)
	local changeDescription = string.format(
		"grant %d Star Coins and %d fans (rewardSourceKind %s: %s)",
		starCoinAndFanGrantRequest.starCoinsToGrant,
		starCoinAndFanGrantRequest.fanCountToGrant,
		starCoinAndFanGrantRequest.rewardSourceKind,
		starCoinAndFanGrantRequest.grantDescriptionForLogs
	)
	local report = applyBalanceChangeWithRecordAsOneSaveChange(self.playerSaveDataKeeper, playerUserId, {
		changeDescriptionForLogs = changeDescription,
		starCoinBalanceDifference = starCoinAndFanGrantRequest.starCoinsToGrant,
		fanCountDifference = starCoinAndFanGrantRequest.fanCountToGrant,
		checkEligibility = starCoinAndFanGrantRequest.checkGrantEligibility,
		writeRecordThatPreventsRepeat = starCoinAndFanGrantRequest.writeGrantRecordThatPreventsRepeat,
	})
	if report.keeperChangeOutcome ~= "Applied" then
		logNotAppliedOutcome(self, playerUserId, changeDescription, report)
		return buildNotAppliedOutcome(report)
	end
	self.logger:logInformation(
		string.format(
			"RewardLedger: %s applied for player %d; starCoinBalance %d -> %d, fanCount %d -> %d",
			changeDescription,
			playerUserId,
			report.starCoinBalanceBeforeChange :: number,
			report.starCoinBalanceAfterChange :: number,
			report.fanCountBeforeChange :: number,
			report.fanCountAfterChange :: number
		)
	)
	return {
		rewardLedgerOutcome = "Granted",
		starCoinsGranted = starCoinAndFanGrantRequest.starCoinsToGrant,
		fanCountGained = starCoinAndFanGrantRequest.fanCountToGrant,
		starCoinBalanceAfterChange = report.starCoinBalanceAfterChange,
		fanCountAfterChange = report.fanCountAfterChange,
		inMemoryChangeRevision = report.inMemoryChangeRevision,
	}
end

local function requireValidGrantRequest(self, starCoinAndFanGrantRequest)
	if type(starCoinAndFanGrantRequest) ~= "table" then
		raiseLoudly(self, "RewardLedger: a grant needs a starCoinAndFanGrantRequest table")
	end
	local rewardSourceKind = starCoinAndFanGrantRequest.rewardSourceKind
	if type(rewardSourceKind) ~= "string" or RewardLedger.REWARD_SOURCE_KINDS[rewardSourceKind] == nil then
		raiseLoudly(self, "RewardLedger: unknown rewardSourceKind " .. tostring(rewardSourceKind))
	end
	requireWholeNonNegativeAmount(self, starCoinAndFanGrantRequest.starCoinsToGrant, "starCoinsToGrant")
	requireWholeNonNegativeAmount(self, starCoinAndFanGrantRequest.fanCountToGrant, "fanCountToGrant")
	requireNonEmptyString(self, starCoinAndFanGrantRequest.grantDescriptionForLogs, "grantDescriptionForLogs")
	requireFunction(self, starCoinAndFanGrantRequest.checkGrantEligibility, "checkGrantEligibility")
	requireFunction(
		self,
		starCoinAndFanGrantRequest.writeGrantRecordThatPreventsRepeat,
		"writeGrantRecordThatPreventsRepeat"
	)
end

function RewardLedger:grantStarCoinsAndFans(playerUserId: number, starCoinAndFanGrantRequest)
	requireValidGrantRequest(self, starCoinAndFanGrantRequest)
	if starCoinAndFanGrantRequest.rewardSourceKind == RewardLedger.REWARD_SOURCE_KINDS.ThemedRound then
		raiseLoudly(self, "RewardLedger: ThemedRound rewards must go through grantThemedRoundReward")
	end
	return grantAfterRequestChecked(self, playerUserId, starCoinAndFanGrantRequest)
end

function RewardLedger:spendStarCoins(playerUserId: number, starCoinSpendRequest)
	if type(starCoinSpendRequest) ~= "table" then
		raiseLoudly(self, "RewardLedger: a spend needs a starCoinSpendRequest table")
	end
	local purchaseKind = starCoinSpendRequest.purchaseKind
	if type(purchaseKind) ~= "string" or RewardLedger.PURCHASE_KINDS[purchaseKind] == nil then
		raiseLoudly(self, "RewardLedger: unknown purchaseKind " .. tostring(purchaseKind))
	end
	requireWholeNonNegativeAmount(self, starCoinSpendRequest.starCoinPrice, "starCoinPrice")
	requireNonEmptyString(self, starCoinSpendRequest.purchaseDescriptionForLogs, "purchaseDescriptionForLogs")
	requireFunction(self, starCoinSpendRequest.checkPurchaseEligibility, "checkPurchaseEligibility")
	requireFunction(
		self,
		starCoinSpendRequest.writePurchaseRecordThatPreventsRepeat,
		"writePurchaseRecordThatPreventsRepeat"
	)

	local changeDescription = string.format(
		"spend %d Star Coins (purchaseKind %s: %s)",
		starCoinSpendRequest.starCoinPrice,
		purchaseKind,
		starCoinSpendRequest.purchaseDescriptionForLogs
	)
	local report = applyBalanceChangeWithRecordAsOneSaveChange(self.playerSaveDataKeeper, playerUserId, {
		changeDescriptionForLogs = changeDescription,
		starCoinBalanceDifference = -starCoinSpendRequest.starCoinPrice,
		fanCountDifference = 0,
		checkEligibility = starCoinSpendRequest.checkPurchaseEligibility,
		writeRecordThatPreventsRepeat = starCoinSpendRequest.writePurchaseRecordThatPreventsRepeat,
	})
	if report.keeperChangeOutcome ~= "Applied" then
		logNotAppliedOutcome(self, playerUserId, changeDescription, report)
		return buildNotAppliedOutcome(report)
	end
	self.logger:logInformation(
		string.format(
			"RewardLedger: %s applied for player %d; starCoinBalance %d -> %d",
			changeDescription,
			playerUserId,
			report.starCoinBalanceBeforeChange :: number,
			report.starCoinBalanceAfterChange :: number
		)
	)
	return {
		rewardLedgerOutcome = "Spent",
		starCoinsSpent = starCoinSpendRequest.starCoinPrice,
		starCoinBalanceAfterChange = report.starCoinBalanceAfterChange,
		inMemoryChangeRevision = report.inMemoryChangeRevision,
	}
end

-- ── themed-round reward ─────────────────────────────────────────────────────────────────────

local function findStarRewardTierForStarCount(starCount: number)
	for _, starRewardTier in OutfitScoreCalculator.STAR_REWARD_TIERS do
		if starRewardTier.starCount == starCount then
			return starRewardTier
		end
	end
	return nil
end

local function wasRoundRewardAlreadyGranted(self, roundId: string, playerUserId: number): boolean
	local rewardedPlayerUserIds = self.rewardedPlayerUserIdsByRoundId[roundId]
	return rewardedPlayerUserIds ~= nil and rewardedPlayerUserIds[playerUserId] == true
end

local function rememberRoundRewardGranted(self, roundId: string, playerUserId: number)
	if self.rewardedPlayerUserIdsByRoundId[roundId] == nil then
		self.rewardedPlayerUserIdsByRoundId[roundId] = {}
		table.insert(self.rememberedRoundIdsInGrantOrder, roundId)
		if #self.rememberedRoundIdsInGrantOrder > RewardLedger.REMEMBERED_ROUND_ID_COUNT_FOR_DUPLICATE_GUARD then
			local forgottenRoundId = table.remove(self.rememberedRoundIdsInGrantOrder, 1)
			self.rewardedPlayerUserIdsByRoundId[forgottenRoundId :: string] = nil
		end
	end
	self.rewardedPlayerUserIdsByRoundId[roundId][playerUserId] = true
end

local function requireValidThemedRoundCompletion(self, themedRoundCompletion)
	if type(themedRoundCompletion) ~= "table" then
		raiseLoudly(self, "RewardLedger: a round reward needs a themedRoundCompletion table")
	end
	requireNonEmptyString(self, themedRoundCompletion.roundId, "roundId")
	requireNonEmptyString(self, themedRoundCompletion.themeId, "themeId")
	local starCount = themedRoundCompletion.starCount
	if type(starCount) ~= "number" or findStarRewardTierForStarCount(starCount) == nil then
		raiseLoudly(
			self,
			"RewardLedger: starCount must be one of the §1.6 star counts (an empty outfit gets no reward), got "
				.. tostring(starCount)
		)
	end
	if type(themedRoundCompletion.scoredOutfitStylingItemKeys) ~= "table" then
		raiseLoudly(self, "RewardLedger: scoredOutfitStylingItemKeys must be a list of styling item keys")
	end
end

local function buildThemedRoundRewardNotGrantedOutcome(notGrantedOutcome)
	notGrantedOutcome.starCoinsGranted = 0
	notGrantedOutcome.fanCountGained = 0
	notGrantedOutcome.isNewBestStarCountForTheme = false
	return notGrantedOutcome
end

function RewardLedger:grantThemedRoundReward(playerUserId: number, themedRoundCompletion)
	requireValidThemedRoundCompletion(self, themedRoundCompletion)
	local roundId = themedRoundCompletion.roundId
	local themeId = themedRoundCompletion.themeId
	local starCount = themedRoundCompletion.starCount
	if wasRoundRewardAlreadyGranted(self, roundId, playerUserId) then
		self.logger:logWarning(
			string.format(
				"RewardLedger: grant (rewardSourceKind %s: round %s, theme %s) declined for player %d: %s",
				RewardLedger.REWARD_SOURCE_KINDS.ThemedRound,
				roundId,
				themeId,
				playerUserId,
				RewardLedger.ROUND_REWARD_ALREADY_GRANTED_DECLINE_REASON
			)
		)
		return buildThemedRoundRewardNotGrantedOutcome({
			rewardLedgerOutcome = "Declined",
			declineReason = RewardLedger.ROUND_REWARD_ALREADY_GRANTED_DECLINE_REASON,
		})
	end

	local starRewardTier = findStarRewardTierForStarCount(starCount)
	-- Writers get a deeply frozen copy, so no writer can alter what a later writer sees.
	local frozenThemedRoundCompletion = createDeeplyFrozenCopy(themedRoundCompletion)
	local isNewBestStarCountForTheme = false

	local function writeThemedRoundCompletionRecord(saveDataDraft)
		local previousBestStarCount = saveDataDraft.bestStarCountByThemeId[themeId]
		isNewBestStarCountForTheme = previousBestStarCount == nil or starCount > previousBestStarCount
		if isNewBestStarCountForTheme then
			saveDataDraft.bestStarCountByThemeId[themeId] = starCount
		end
		saveDataDraft.totalRoundsCompletedCount += 1
		for _, themedRoundCompletionRecordWriter in self.themedRoundCompletionRecordWriters do
			themedRoundCompletionRecordWriter(saveDataDraft, frozenThemedRoundCompletion)
		end
	end

	local grantOutcome = grantAfterRequestChecked(self, playerUserId, {
		rewardSourceKind = RewardLedger.REWARD_SOURCE_KINDS.ThemedRound,
		starCoinsToGrant = starRewardTier.starCoinsGranted,
		fanCountToGrant = starRewardTier.fanCountGained,
		grantDescriptionForLogs = string.format("round %s, theme %s, %d stars", roundId, themeId, starCount),
		checkGrantEligibility = function()
			return true
		end,
		writeGrantRecordThatPreventsRepeat = writeThemedRoundCompletionRecord,
	})
	if grantOutcome.rewardLedgerOutcome ~= "Granted" then
		return buildThemedRoundRewardNotGrantedOutcome(grantOutcome)
	end
	rememberRoundRewardGranted(self, roundId, playerUserId)
	grantOutcome.isNewBestStarCountForTheme = isNewBestStarCountForTheme
	return grantOutcome
end

return RewardLedger
