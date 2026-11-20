-- ThemedRoundRewardSettlement (development spec v1.3 §1.6, §2.5, §3.3; referee audit PART 1
-- questions 16, 17, 18, 19, 20, 22, PART 2 items m, n): at the start of Results, grants each
-- scored participant's round reward through RewardLedger and builds the roundResults list of
-- RoundResultsPublished from what was ACTUALLY applied. ThemedRoundReferee calls it once per
-- round and publishes the list.
-- Calls no Roblox-specific interface; the ledger, display names and logger are passed in.
--
-- Rules it enforces:
--   * Grant first, then build the entry from the ledger's answer. Published amounts are never
--     the computed ones unless the ledger answered "Granted".
--   * At most one ledger call per player per round: the player is marked settled in the
--     caller's `settledPlayerUserIdSet` BEFORE the ledger is called, whatever the outcome
--     (audit question 19). RewardLedger has its own duplicate-round guard as well; both stay.
--   * An empty final outfit gets no ledger call at all (§1.6; audit question 16): no coins, no
--     fans, no round count, no best-star entry, no save request.
--   * Each participant's grant is isolated: a ledger call that raises is logged and that
--     participant's entry shows the true score and stars with 0 coins, 0 fans and false. One
--     failure never stops the others. Nothing is retried.
--   * "SaveDataNotLoaded" means the player is leaving or lost the save: treat as left (question
--     18). No entry here, and the player is handed back so the caller removes them from the
--     round before anything else (the Results RoundStateChanged) lists them.
--   * "Declined" (or any answer other than the three documented): entry with the true score and
--     stars, 0 coins, 0 fans, isNewBestStarCountForTheme false.
--   * Sorted by outfitScore, highest first; ties by order of accepted join, then playerUserId
--     ascending (question 20). A total order, because table.sort is not stable.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- ThemedRoundRewardSettlement.settleRoundRewardsAndBuildRoundResults(roundRewardSettlementRequest)
--   -> (roundResults: { RoundResultsEntry }, playerUserIdsWhoseSaveDataWasNotLoaded: { number })
--   roundResults: frozen list of frozen entries, already sorted.
--   playerUserIdsWhoseSaveDataWasNotLoaded: frozen, in settlement order; the players the ledger
--   answered "SaveDataNotLoaded" for, whom the caller must treat as left.
--   roundRewardSettlementRequest = {
--     roundId: string, themeId: string,
--     scoredParticipantsStillPresent: { ThemedRoundFinalOutfitScorer.ScoredParticipant },
--     rewardLedger: { grantThemedRoundReward: (self, playerUserId, themedRoundCompletion) -> outcome },
--     readPlayerDisplayName: (playerUserId) -> string,   a raise or a non-string is logged and
--         the entry carries tostring(playerUserId) instead
--     ownerDecisions: ThemedRoundOwnerDecisions.OwnerDecisions,
--     logger: { logInformation, logWarning },
--     settledPlayerUserIdSet: { [number]: true },   the round's settlement markers; a player
--         already in it is skipped entirely (no ledger call, no entry)
--   }
--   Logs one information line per settlement and one warning per raising ledger call.
--
-- RoundResultsEntry (§2.5) = { playerUserId, playerDisplayName, outfitScore, themeMatchPoints,
--   completenessPoints, colorHarmonyPoints, roundBonusPoints, starCount, starCoinsGranted,
--   fanCountGained, isNewBestStarCountForTheme }
--
-- ThemedRoundRewardSettlement.isFinalOutfitRewardable(outfitScoreBreakdown) -> boolean
--   False for an empty final outfit (owner question 16 (b) lives here).
-- ThemedRoundRewardSettlement.decidePublishedIsNewBestStarCountForTheme(themedRoundRewardOutcome)
--   -> boolean   true only for a "Granted" outcome whose flag is true (owner question 22).
-- ThemedRoundRewardSettlement.isRoundResultsRowPublishedBefore(firstRow, secondRow) -> boolean
--   The sort order above, for rows { outfitScore, joinOrderPosition, playerUserId }.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local ThemedRoundRewardSettlement = {}

local REWARD_LEDGER_OUTCOME_GRANTED = "Granted"
local REWARD_LEDGER_OUTCOME_SAVE_DATA_NOT_LOADED = "SaveDataNotLoaded"

function ThemedRoundRewardSettlement.isFinalOutfitRewardable(outfitScoreBreakdown): boolean
	return not outfitScoreBreakdown.isOutfitEmpty
end

function ThemedRoundRewardSettlement.decidePublishedIsNewBestStarCountForTheme(themedRoundRewardOutcome): boolean
	return themedRoundRewardOutcome.rewardLedgerOutcome == REWARD_LEDGER_OUTCOME_GRANTED
		and themedRoundRewardOutcome.isNewBestStarCountForTheme == true
end

function ThemedRoundRewardSettlement.isRoundResultsRowPublishedBefore(firstRow, secondRow): boolean
	if firstRow.outfitScore ~= secondRow.outfitScore then
		return firstRow.outfitScore > secondRow.outfitScore
	end
	if firstRow.joinOrderPosition ~= secondRow.joinOrderPosition then
		return firstRow.joinOrderPosition < secondRow.joinOrderPosition
	end
	return firstRow.playerUserId < secondRow.playerUserId
end

local function readPlayerDisplayNameOrFallback(roundRewardSettlementRequest, playerUserId: number): string
	local didRead, playerDisplayName = pcall(roundRewardSettlementRequest.readPlayerDisplayName, playerUserId)
	if didRead and type(playerDisplayName) == "string" then
		return playerDisplayName
	end
	roundRewardSettlementRequest.logger:logWarning(
		string.format(
			"ThemedRoundRewardSettlement: no display name for player %d in round %s; the user id is shown instead",
			playerUserId,
			roundRewardSettlementRequest.roundId
		)
	)
	return tostring(playerUserId)
end

-- Returns the ledger's answer, or nil when the call raised (already logged).
local function grantRoundRewardIsolated(roundRewardSettlementRequest, scoredParticipant)
	local outfitScoreBreakdown = scoredParticipant.outfitScoreBreakdown
	local didGrantCallReturn, themedRoundRewardOutcomeOrError = pcall(
		roundRewardSettlementRequest.rewardLedger.grantThemedRoundReward,
		roundRewardSettlementRequest.rewardLedger,
		scoredParticipant.playerUserId,
		{
			roundId = roundRewardSettlementRequest.roundId,
			themeId = roundRewardSettlementRequest.themeId,
			starCount = outfitScoreBreakdown.starCount,
			scoredOutfitStylingItemKeys = scoredParticipant.scoredOutfitStylingItemKeys,
		}
	)
	if didGrantCallReturn and type(themedRoundRewardOutcomeOrError) == "table" then
		return themedRoundRewardOutcomeOrError
	end
	roundRewardSettlementRequest.logger:logWarning(
		string.format(
			"ThemedRoundRewardSettlement: the round reward of player %d in round %s was not applied: %s",
			scoredParticipant.playerUserId,
			roundRewardSettlementRequest.roundId,
			if didGrantCallReturn then "the ledger gave no answer" else tostring(themedRoundRewardOutcomeOrError)
		)
	)
	return nil
end

local function buildRoundResultsRow(roundRewardSettlementRequest, scoredParticipant, appliedRoundReward)
	local outfitScoreBreakdown = scoredParticipant.outfitScoreBreakdown
	return {
		joinOrderPosition = scoredParticipant.joinOrderPosition,
		playerUserId = scoredParticipant.playerUserId,
		playerDisplayName = readPlayerDisplayNameOrFallback(
			roundRewardSettlementRequest,
			scoredParticipant.playerUserId
		),
		outfitScore = outfitScoreBreakdown.outfitScore,
		themeMatchPoints = outfitScoreBreakdown.themeMatchPoints,
		completenessPoints = outfitScoreBreakdown.completenessPoints,
		colorHarmonyPoints = outfitScoreBreakdown.colorHarmonyPoints,
		roundBonusPoints = outfitScoreBreakdown.roundBonusPoints,
		starCount = outfitScoreBreakdown.starCount,
		starCoinsGranted = appliedRoundReward.starCoinsGranted,
		fanCountGained = appliedRoundReward.fanCountGained,
		isNewBestStarCountForTheme = appliedRoundReward.isNewBestStarCountForTheme,
	}
end

local NOTHING_APPLIED_ROUND_REWARD =
	table.freeze({ starCoinsGranted = 0, fanCountGained = 0, isNewBestStarCountForTheme = false })

-- The row for one participant (nil when they get no entry), and whether the ledger answered
-- that their save data is not loaded.
local function settleOneParticipant(roundRewardSettlementRequest, scoredParticipant)
	if not ThemedRoundRewardSettlement.isFinalOutfitRewardable(scoredParticipant.outfitScoreBreakdown) then
		if not roundRewardSettlementRequest.ownerDecisions.isEmptyFinalOutfitListedInRoundResults then
			return nil
		end
		return buildRoundResultsRow(roundRewardSettlementRequest, scoredParticipant, NOTHING_APPLIED_ROUND_REWARD)
	end
	local themedRoundRewardOutcome = grantRoundRewardIsolated(roundRewardSettlementRequest, scoredParticipant)
	if themedRoundRewardOutcome == nil then
		return buildRoundResultsRow(roundRewardSettlementRequest, scoredParticipant, NOTHING_APPLIED_ROUND_REWARD)
	end
	local rewardLedgerOutcome = themedRoundRewardOutcome.rewardLedgerOutcome
	if rewardLedgerOutcome == REWARD_LEDGER_OUTCOME_SAVE_DATA_NOT_LOADED then
		return nil, true
	end
	if rewardLedgerOutcome ~= REWARD_LEDGER_OUTCOME_GRANTED then
		return buildRoundResultsRow(roundRewardSettlementRequest, scoredParticipant, NOTHING_APPLIED_ROUND_REWARD)
	end
	return buildRoundResultsRow(roundRewardSettlementRequest, scoredParticipant, {
		starCoinsGranted = themedRoundRewardOutcome.starCoinsGranted,
		fanCountGained = themedRoundRewardOutcome.fanCountGained,
		isNewBestStarCountForTheme = ThemedRoundRewardSettlement.decidePublishedIsNewBestStarCountForTheme(
			themedRoundRewardOutcome
		),
	})
end

function ThemedRoundRewardSettlement.settleRoundRewardsAndBuildRoundResults(roundRewardSettlementRequest)
	local settledPlayerUserIdSet = roundRewardSettlementRequest.settledPlayerUserIdSet
	local roundResultsRows = {}
	local playerUserIdsWhoseSaveDataWasNotLoaded = {}
	for _, scoredParticipant in roundRewardSettlementRequest.scoredParticipantsStillPresent do
		local playerUserId = scoredParticipant.playerUserId
		if not settledPlayerUserIdSet[playerUserId] then
			settledPlayerUserIdSet[playerUserId] = true
			local roundResultsRow, wasSaveDataNotLoaded =
				settleOneParticipant(roundRewardSettlementRequest, scoredParticipant)
			if roundResultsRow ~= nil then
				table.insert(roundResultsRows, roundResultsRow)
			end
			if wasSaveDataNotLoaded then
				table.insert(playerUserIdsWhoseSaveDataWasNotLoaded, playerUserId)
			end
		end
	end
	table.sort(roundResultsRows, ThemedRoundRewardSettlement.isRoundResultsRowPublishedBefore)

	local roundResults = {}
	for _, roundResultsRow in roundResultsRows do
		roundResultsRow.joinOrderPosition = nil
		table.insert(roundResults, table.freeze(roundResultsRow))
	end
	roundRewardSettlementRequest.logger:logInformation(
		string.format(
			"ThemedRoundRewardSettlement: round %s settled with %d results entries",
			roundRewardSettlementRequest.roundId,
			#roundResults
		)
	)
	return table.freeze(roundResults), table.freeze(playerUserIdsWhoseSaveDataWasNotLoaded)
end

return table.freeze(ThemedRoundRewardSettlement)
