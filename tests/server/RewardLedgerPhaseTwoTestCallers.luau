-- Test-side stand-ins for the Phase 2 modules of the spec §3.3 table (milestone claim, daily quest
-- claim, promo redemption, dance and cosmetic purchase). They call the ledger exactly the way the
-- real modules will: the eligibility check and the record that makes the operation non-repeatable
-- go into the same grant or spend. Not a spec file; the RewardLedger spec files require it.
--
-- They deliberately check only "already claimed / already owned". The real modules add their own
-- checks (milestone reached, quest completed, code active, item exists) in the same place.

local RewardLedger = require("../../src/server/RewardLedger")

local RewardLedgerPhaseTwoTestCallers = {}

RewardLedgerPhaseTwoTestCallers.ALREADY_CLAIMED_DECLINE_REASON = "AlreadyClaimed"
RewardLedgerPhaseTwoTestCallers.ALREADY_REDEEMED_DECLINE_REASON = "AlreadyRedeemed"
RewardLedgerPhaseTwoTestCallers.ALREADY_OWNED_DECLINE_REASON = "AlreadyOwned"

function RewardLedgerPhaseTwoTestCallers.claimPlaytimeMilestone(
	rewardLedger,
	playerUserId: number,
	milestoneMinutes: number,
	starCoinReward: number
)
	return rewardLedger:grantStarCoinsAndFans(playerUserId, {
		rewardSourceKind = RewardLedger.REWARD_SOURCE_KINDS.PlaytimeMilestone,
		starCoinsToGrant = starCoinReward,
		fanCountToGrant = 0,
		grantDescriptionForLogs = string.format("playtime milestone %d min", milestoneMinutes),
		checkGrantEligibility = function(saveDataReadOnlyView)
			if table.find(saveDataReadOnlyView.dailyProgress.claimedPlaytimeMilestoneMinutes, milestoneMinutes) then
				return false, RewardLedgerPhaseTwoTestCallers.ALREADY_CLAIMED_DECLINE_REASON
			end
			return true
		end,
		writeGrantRecordThatPreventsRepeat = function(saveDataDraft)
			table.insert(saveDataDraft.dailyProgress.claimedPlaytimeMilestoneMinutes, milestoneMinutes)
		end,
	})
end

function RewardLedgerPhaseTwoTestCallers.claimDailyQuestReward(
	rewardLedger,
	playerUserId: number,
	dailyQuestId: string,
	starCoinReward: number
)
	return rewardLedger:grantStarCoinsAndFans(playerUserId, {
		rewardSourceKind = RewardLedger.REWARD_SOURCE_KINDS.DailyQuest,
		starCoinsToGrant = starCoinReward,
		fanCountToGrant = 0,
		grantDescriptionForLogs = "daily quest " .. dailyQuestId,
		checkGrantEligibility = function(saveDataReadOnlyView)
			if table.find(saveDataReadOnlyView.dailyProgress.claimedDailyQuestIds, dailyQuestId) then
				return false, RewardLedgerPhaseTwoTestCallers.ALREADY_CLAIMED_DECLINE_REASON
			end
			return true
		end,
		writeGrantRecordThatPreventsRepeat = function(saveDataDraft)
			table.insert(saveDataDraft.dailyProgress.claimedDailyQuestIds, dailyQuestId)
		end,
	})
end

function RewardLedgerPhaseTwoTestCallers.redeemPromoCode(
	rewardLedger,
	playerUserId: number,
	promoCodeId: string,
	starCoinReward: number
)
	return rewardLedger:grantStarCoinsAndFans(playerUserId, {
		rewardSourceKind = RewardLedger.REWARD_SOURCE_KINDS.PromoCode,
		starCoinsToGrant = starCoinReward,
		fanCountToGrant = 0,
		grantDescriptionForLogs = "promo code " .. promoCodeId,
		checkGrantEligibility = function(saveDataReadOnlyView)
			if table.find(saveDataReadOnlyView.redeemedPromoCodeIds, promoCodeId) then
				return false, RewardLedgerPhaseTwoTestCallers.ALREADY_REDEEMED_DECLINE_REASON
			end
			return true
		end,
		writeGrantRecordThatPreventsRepeat = function(saveDataDraft)
			table.insert(saveDataDraft.redeemedPromoCodeIds, promoCodeId)
		end,
	})
end

local function purchaseOwnableItem(
	rewardLedger,
	playerUserId: number,
	purchaseKind: string,
	ownedIdsFieldName: string,
	purchasedItemId: string,
	starCoinPrice: number
)
	return rewardLedger:spendStarCoins(playerUserId, {
		purchaseKind = purchaseKind,
		starCoinPrice = starCoinPrice,
		purchaseDescriptionForLogs = string.format("%s %s", purchaseKind, purchasedItemId),
		checkPurchaseEligibility = function(saveDataReadOnlyView)
			if table.find(saveDataReadOnlyView[ownedIdsFieldName], purchasedItemId) then
				return false, RewardLedgerPhaseTwoTestCallers.ALREADY_OWNED_DECLINE_REASON
			end
			return true
		end,
		writePurchaseRecordThatPreventsRepeat = function(saveDataDraft)
			table.insert(saveDataDraft[ownedIdsFieldName], purchasedItemId)
		end,
	})
end

function RewardLedgerPhaseTwoTestCallers.purchaseDance(
	rewardLedger,
	playerUserId: number,
	danceId: string,
	starCoinPrice: number
)
	return purchaseOwnableItem(
		rewardLedger,
		playerUserId,
		RewardLedger.PURCHASE_KINDS.Dance,
		"ownedDanceIds",
		danceId,
		starCoinPrice
	)
end

function RewardLedgerPhaseTwoTestCallers.purchaseCosmetic(
	rewardLedger,
	playerUserId: number,
	cosmeticId: string,
	starCoinPrice: number
)
	return purchaseOwnableItem(
		rewardLedger,
		playerUserId,
		RewardLedger.PURCHASE_KINDS.Cosmetic,
		"ownedCosmeticIds",
		cosmeticId,
		starCoinPrice
	)
end

return RewardLedgerPhaseTwoTestCallers
