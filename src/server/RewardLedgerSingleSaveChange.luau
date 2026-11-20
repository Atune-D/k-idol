-- The one save change behind every RewardLedger grant and spend (development spec §3.3 "A reward
-- and its record are one change"). Split out of RewardLedger.luau only to keep files short; use
-- RewardLedger, never this module directly. Its public API is documented in RewardLedger.luau.
--
-- Calls no Roblox-specific interface.

local PlayerSaveDataKeeper = require("./PlayerSaveDataKeeper")
local PlayerSaveDataSchema = require("./PlayerSaveDataSchema")

local createDeepCopyOfPlainTable = PlayerSaveDataSchema.createDeepCopyOfPlainTable
local arePlainValuesDeeplyEqual = PlayerSaveDataSchema.arePlainValuesDeeplyEqual

local RewardLedgerSingleSaveChange = {}

RewardLedgerSingleSaveChange.INSUFFICIENT_STAR_COINS_DECLINE_REASON = "InsufficientStarCoins"

-- A read-only view of a save for eligibility checks: writing to it raises.
function RewardLedgerSingleSaveChange.createDeeplyFrozenCopy(originalPlainValue: any): any
	if type(originalPlainValue) ~= "table" then
		return originalPlainValue
	end
	local frozenCopy = {}
	for copiedKey, copiedValue in originalPlainValue do
		frozenCopy[copiedKey] = RewardLedgerSingleSaveChange.createDeeplyFrozenCopy(copiedValue)
	end
	return table.freeze(frozenCopy)
end

export type BalanceChangeInsideOneSaveChange = {
	changeDescriptionForLogs: string,
	starCoinBalanceDifference: number, -- negative for a spend
	fanCountDifference: number,
	checkEligibility: (any) -> (boolean, string?),
	writeRecordThatPreventsRepeat: (any) -> (),
}

export type BalanceChangeReport = {
	keeperChangeOutcome: string,
	declineReason: string?,
	inMemoryChangeRevision: number?,
	starCoinBalanceBeforeChange: number?,
	starCoinBalanceAfterChange: number?,
	fanCountBeforeChange: number?,
	fanCountAfterChange: number?,
}

-- Runs eligibility check -> balance change -> record as ONE keeper change and reports what happened.
-- Raises (and nothing changes) when the caller's check or record breaks the rules in RewardLedger.
function RewardLedgerSingleSaveChange.applyBalanceChangeWithRecordAsOneSaveChange(
	playerSaveDataKeeper,
	playerUserId: number,
	balanceChange: BalanceChangeInsideOneSaveChange
): BalanceChangeReport
	local balanceChangeReport: BalanceChangeReport = { keeperChangeOutcome = "NotStarted" }

	local function decideAndApplyBalanceChangeWithRecord(saveDataDraft): (boolean, string?)
		local isEligible, eligibilityDeclineReason =
			balanceChange.checkEligibility(RewardLedgerSingleSaveChange.createDeeplyFrozenCopy(saveDataDraft))
		if type(isEligible) ~= "boolean" then
			error("RewardLedger: the eligibility check must return true or false", 0)
		end
		if not isEligible then
			if type(eligibilityDeclineReason) ~= "string" or eligibilityDeclineReason == "" then
				error("RewardLedger: a declined eligibility check must give a non-empty reason string", 0)
			end
			return false, eligibilityDeclineReason
		end

		local starCoinBalanceAfterChange = saveDataDraft.starCoinBalance + balanceChange.starCoinBalanceDifference
		if starCoinBalanceAfterChange < 0 then
			return false, RewardLedgerSingleSaveChange.INSUFFICIENT_STAR_COINS_DECLINE_REASON
		end
		local fanCountAfterChange = saveDataDraft.fanCount + balanceChange.fanCountDifference
		balanceChangeReport.starCoinBalanceBeforeChange = saveDataDraft.starCoinBalance
		balanceChangeReport.fanCountBeforeChange = saveDataDraft.fanCount
		balanceChangeReport.starCoinBalanceAfterChange = starCoinBalanceAfterChange
		balanceChangeReport.fanCountAfterChange = fanCountAfterChange
		saveDataDraft.starCoinBalance = starCoinBalanceAfterChange
		saveDataDraft.fanCount = fanCountAfterChange

		local saveDataBeforeRecord = createDeepCopyOfPlainTable(saveDataDraft)
		balanceChange.writeRecordThatPreventsRepeat(saveDataDraft)
		if
			saveDataDraft.starCoinBalance ~= starCoinBalanceAfterChange
			or saveDataDraft.fanCount ~= fanCountAfterChange
		then
			error("RewardLedger: a record writer changed starCoinBalance or fanCount; only the ledger may", 0)
		end
		if arePlainValuesDeeplyEqual(saveDataBeforeRecord, saveDataDraft) then
			error("RewardLedger: the record writer wrote no record; the operation would be repeatable", 0)
		end
		return true
	end

	local keeperChangeResult = playerSaveDataKeeper:applyChangeToPlayerSaveData(
		playerUserId,
		PlayerSaveDataKeeper.PROGRESS_CHANGE_SAVED_AT_ONCE,
		balanceChange.changeDescriptionForLogs,
		decideAndApplyBalanceChangeWithRecord
	)
	balanceChangeReport.keeperChangeOutcome = keeperChangeResult.changeOutcome
	balanceChangeReport.declineReason = keeperChangeResult.declineReason
	balanceChangeReport.inMemoryChangeRevision = keeperChangeResult.inMemoryChangeRevision
	if keeperChangeResult.changeOutcome == "AppliedWithoutAnyDifference" then
		-- Impossible: a record must change the save. Nothing was applied, so raising is safe.
		error("RewardLedger: the keeper reported no difference for a change that wrote a record", 0)
	end
	return balanceChangeReport
end

return table.freeze(RewardLedgerSingleSaveChange)
