-- ThemedRoundOwnerDecisions: the themed-round questions the development spec (v1.3) leaves open
-- and that are put to the product owner (referee audit PART 1, questions 11, 16, 22, 23, 24).
-- Each answer lives here and nowhere else, so changing one is a one-line edit plus its tests.
-- Every value below is the audit's recommended default.
--
-- Who reads it: ThemedRoundReferee (and its parts) and CharacterSpawnAppearanceDecider. Both
-- take an optional `ownerDecisions` dependency of this exact shape, so tests can run the
-- alternative answer without editing this file.
-- Pure data: no Roblox-specific interface is used.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS = {   frozen
--   isRejoiningSameRoundAfterLeavingAllowed: boolean,                         question 11
--   isEmptyFinalOutfitListedInRoundResults: boolean,                          question 16 (a)
--   shouldShowLobbyAppearanceOnStageForEmptyScoredOutfit: boolean,            question 23
--   shouldForfeitUnsettledRoundAtServerShutdown: boolean,                     question 24
-- }
-- ThemedRoundOwnerDecisions.assertIsOwnerDecisions(candidateOwnerDecisions)
--   Raises unless every field above is present and a boolean (a wiring error).
--
-- The two remaining owner points are NOT switches here, because the alternative needs a change
-- in RewardLedger, not a flag:
--   * Question 16 (b), "does an empty final outfit count as a completed round or quest
--     progress": the default is no. The referee never calls the ledger for an empty final
--     outfit (ThemedRoundRewardSettlement.isFinalOutfitRewardable). RewardLedger raises for
--     starCount 0, so "yes" needs a new ledger operation that writes the round record without
--     paying.
--   * Question 22, "isNewBestStarCountForTheme": the default is "strictly greater than the stored
--     value, a missing entry counting as 0". RewardLedger.grantThemedRoundReward computes it
--     inside the same save change that writes bestStarCountByThemeId; the referee publishes it
--     only for a "Granted" outcome and publishes false otherwise
--     (ThemedRoundRewardSettlement.decidePublishedIsNewBestStarCountForTheme).
-- ════════════════════════════════════════════════════════════════════════════════════════════

local ThemedRoundOwnerDecisions = {}

export type OwnerDecisions = {
	isRejoiningSameRoundAfterLeavingAllowed: boolean,
	isEmptyFinalOutfitListedInRoundResults: boolean,
	shouldShowLobbyAppearanceOnStageForEmptyScoredOutfit: boolean,
	shouldForfeitUnsettledRoundAtServerShutdown: boolean,
}

ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS = table.freeze({
	-- Q11. A participant who left (or lost the save session) and asks again while the join window
	-- is open is accepted as a brand-new participant with a clean state. Alternative (false): the
	-- request is answered RoundNotJoinableNow for the rest of that round.
	isRejoiningSameRoundAfterLeavingAllowed = true,
	-- Q16 (a). A participant whose final outfit is empty is listed in roundResults with every
	-- number 0 and isNewBestStarCountForTheme false. Alternative (false): left out of the list.
	isEmptyFinalOutfitListedInRoundResults = true,
	-- Q23. A participant on stage during Showcase whose scored outfit is empty stands at their
	-- place and dances in their lobby appearance. Alternative (false): the empty scored outfit is
	-- applied, which under §3.7 strips clothing, accessories, hair and makeup.
	shouldShowLobbyAppearanceOnStageForEmptyScoredOutfit = true,
	-- Q24. Once shutdown begins, a round that has not been settled pays nothing and publishes
	-- nothing. Alternative (false): a round already scored (Showcase reached) is settled at once
	-- when shutdown begins, so its grants are in memory for the final save. A round still in
	-- Styling pays nothing either way.
	shouldForfeitUnsettledRoundAtServerShutdown = true,
} :: OwnerDecisions)

local OWNER_DECISION_FIELD_NAMES = table.freeze({
	"isRejoiningSameRoundAfterLeavingAllowed",
	"isEmptyFinalOutfitListedInRoundResults",
	"shouldShowLobbyAppearanceOnStageForEmptyScoredOutfit",
	"shouldForfeitUnsettledRoundAtServerShutdown",
})

function ThemedRoundOwnerDecisions.assertIsOwnerDecisions(candidateOwnerDecisions: any)
	if type(candidateOwnerDecisions) ~= "table" then
		error("ThemedRoundOwnerDecisions: ownerDecisions must be a table", 3)
	end
	for _, ownerDecisionFieldName in OWNER_DECISION_FIELD_NAMES do
		if type(candidateOwnerDecisions[ownerDecisionFieldName]) ~= "boolean" then
			error(
				string.format("ThemedRoundOwnerDecisions: ownerDecisions.%s must be a boolean", ownerDecisionFieldName),
				3
			)
		end
	end
end

return table.freeze(ThemedRoundOwnerDecisions)
