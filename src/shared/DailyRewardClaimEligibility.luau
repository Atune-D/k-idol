-- Decides whether a daily reward may be claimed now (development spec §2.9):
--   * RequestClaimPlaytimeMilestone: UnknownMilestone, MilestoneNotReached, AlreadyClaimed.
--   * RequestClaimDailyQuestReward:  NotTodaysQuest, QuestNotCompleted, AlreadyClaimed.
-- Checks run in that order and the first failing one is the answer.
--
-- These functions only decide. They change nothing and grant nothing: the future daily tracker
-- passes the decision to RewardLedger, which checks, grants and records in one change (§3.3).
--
-- The caller passes `currentDailyDateKey`, the UTC day of the server's clock. `dailyProgress`
-- (shape in PlayerSaveDataSchema, spec §1.10) must be that day's table, i.e. the daily reset has
-- been applied; a stale or malformed table raises an error (DailyProgressReader). "Today's
-- quests" are the quests selected for `currentDailyDateKey`.
--
-- The requested milestone minutes and quest id come from a device and may be any value; anything
-- that is not exactly a defined milestone or one of today's quest ids is rejected, never an error.
-- Pure logic: no Roblox-specific interface is used.

local DailyProgressReader = require("./DailyProgressReader")
local DailyQuestCatalog = require("./DailyQuestCatalog")
local DailyQuestOfTheDaySelector = require("./DailyQuestOfTheDaySelector")
local PlaytimeMilestoneCatalog = require("./PlaytimeMilestoneCatalog")

type DailyQuest = DailyQuestCatalog.DailyQuest
type DailyProgress = DailyProgressReader.DailyProgress

export type DailyRewardClaimDecision = {
	isClaimAllowed: boolean,
	-- Set only when the claim is refused: one of DAILY_REWARD_CLAIM_REJECTION_REASONS.
	rejectionReason: string?,
	-- Set only when the claim is allowed: the Star Coins the claim would pay.
	starCoinReward: number?,
}

local DailyRewardClaimEligibility = {}

local DAILY_REWARD_CLAIM_REJECTION_REASONS = table.freeze({
	UnknownMilestone = "UnknownMilestone",
	MilestoneNotReached = "MilestoneNotReached",
	NotTodaysQuest = "NotTodaysQuest",
	QuestNotCompleted = "QuestNotCompleted",
	AlreadyClaimed = "AlreadyClaimed",
})
DailyRewardClaimEligibility.DAILY_REWARD_CLAIM_REJECTION_REASONS = DAILY_REWARD_CLAIM_REJECTION_REASONS

-- Errors raised for a stale or malformed dailyProgress blame the caller of the decide function.
local BLAME_CALLER_OF_DECIDE_FUNCTION = 2

local function refuseClaim(rejectionReason: string): DailyRewardClaimDecision
	return table.freeze({ isClaimAllowed = false, rejectionReason = rejectionReason })
end

local function allowClaim(starCoinReward: number): DailyRewardClaimDecision
	return table.freeze({ isClaimAllowed = true, starCoinReward = starCoinReward })
end

-- RequestClaimPlaytimeMilestone: allowed when `requestedMilestoneMinutes` is a defined milestone,
-- `playtimeSecondsToday` has reached it (at or above milestone minutes × 60) and it is not yet in
-- `claimedPlaytimeMilestoneMinutes`.
function DailyRewardClaimEligibility.decidePlaytimeMilestoneClaim(
	dailyProgress: DailyProgress,
	currentDailyDateKey: string,
	requestedMilestoneMinutes: any
): DailyRewardClaimDecision
	DailyProgressReader.assertDailyProgressIsCurrentAndWellFormed(
		dailyProgress,
		currentDailyDateKey,
		BLAME_CALLER_OF_DECIDE_FUNCTION
	)
	local requestedPlaytimeMilestone =
		PlaytimeMilestoneCatalog.findPlaytimeMilestoneByMilestoneMinutes(requestedMilestoneMinutes)
	if requestedPlaytimeMilestone == nil then
		return refuseClaim(DAILY_REWARD_CLAIM_REJECTION_REASONS.UnknownMilestone)
	end
	local requiredPlaytimeSeconds =
		PlaytimeMilestoneCatalog.calculateRequiredPlaytimeSecondsForMilestone(requestedPlaytimeMilestone)
	if dailyProgress.playtimeSecondsToday < requiredPlaytimeSeconds then
		return refuseClaim(DAILY_REWARD_CLAIM_REJECTION_REASONS.MilestoneNotReached)
	end
	if DailyProgressReader.isPlaytimeMilestoneClaimed(dailyProgress, requestedPlaytimeMilestone.milestoneMinutes) then
		return refuseClaim(DAILY_REWARD_CLAIM_REJECTION_REASONS.AlreadyClaimed)
	end
	return allowClaim(requestedPlaytimeMilestone.starCoinReward)
end

-- RequestClaimDailyQuestReward: allowed when `requestedDailyQuestId` is one of the quests selected
-- for `currentDailyDateKey`, its progress count has reached `targetCount` and it is not yet in
-- `claimedDailyQuestIds`. `dailyQuestCatalogEntries` defaults to the real catalog; tests pass
-- their own.
function DailyRewardClaimEligibility.decideDailyQuestRewardClaim(
	dailyProgress: DailyProgress,
	currentDailyDateKey: string,
	requestedDailyQuestId: any,
	dailyQuestCatalogEntries: { DailyQuest }?
): DailyRewardClaimDecision
	DailyProgressReader.assertDailyProgressIsCurrentAndWellFormed(
		dailyProgress,
		currentDailyDateKey,
		BLAME_CALLER_OF_DECIDE_FUNCTION
	)
	local requestedDailyQuest: DailyQuest? = nil
	for _, todaysDailyQuest in
		DailyQuestOfTheDaySelector.selectDailyQuestsForDailyDateKey(currentDailyDateKey, dailyQuestCatalogEntries)
	do
		if todaysDailyQuest.dailyQuestId == requestedDailyQuestId then
			requestedDailyQuest = todaysDailyQuest
		end
	end
	if requestedDailyQuest == nil then
		return refuseClaim(DAILY_REWARD_CLAIM_REJECTION_REASONS.NotTodaysQuest)
	end
	if not DailyProgressReader.hasDailyQuestReachedTarget(dailyProgress, requestedDailyQuest) then
		return refuseClaim(DAILY_REWARD_CLAIM_REJECTION_REASONS.QuestNotCompleted)
	end
	if DailyProgressReader.isDailyQuestClaimed(dailyProgress, requestedDailyQuest.dailyQuestId) then
		return refuseClaim(DAILY_REWARD_CLAIM_REJECTION_REASONS.AlreadyClaimed)
	end
	return allowClaim(requestedDailyQuest.starCoinReward)
end

return table.freeze(DailyRewardClaimEligibility)
