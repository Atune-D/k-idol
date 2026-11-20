-- ThemedRoundFinalOutfitScorer (development spec v1.3 §1.6, §2.3 "Cut-off", §2.4; referee audit
-- PART 2 item a): scores every participant's final outfit ONCE at the end of Styling, freezes
-- the result and gives each participant a stage place in join order. ThemedRoundReferee calls it
-- right after the draft cut-off; nothing ever re-scores.
-- Pure logic: no Roblox-specific interface is used.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- ThemedRoundFinalOutfitScorer.scoreFinalOutfitsAndAssignStagePlaces(finalOutfitScoringRequest)
--   -> (scoredParticipants: { ScoredParticipant }, playerUserIdsWhoseScoringRaised: { number })
--   scoredParticipants: frozen, in join order (= stage place order).
--   playerUserIdsWhoseScoringRaised: frozen, in join order; see "Raises" below.
--   finalOutfitScoringRequest = {
--     participantsInJoinOrder: { { playerUserId: number, joinOrderPosition: number } },
--     finalOutfitStylingItemKeysByPlayerUserId: { [number]: { string } },   from the cut-off
--     stylingItemByStylingItemKey, theme, roundBonusRule,   as OutfitScoreCalculator takes them
--   }
--   Each listed participant that has a final outfit is scored with
--   OutfitScoreCalculator.calculateOutfitScore. A listed participant missing from the final
--   outfits is skipped (the draft module no longer knows them). Stage places are 1, 2, 3 … over
--   the scored participants in join order. The final outfit lists come frozen from the cut-off
--   and are kept as they are (never re-validated or reduced, audit question 10); a list that is
--   not frozen is copied first, so the caller's list can never change what was scored.
--   Never raises for one participant's outfit: when OutfitScoreCalculator raises (a key missing
--   from the pool, which a kept draft validated against that same pool cannot contain), that
--   participant is left out of scoredParticipants (no stage place, no score, so no reward) and
--   listed in playerUserIdsWhoseScoringRaised for the caller to log; everyone else is scored.
--
-- ScoredParticipant = {   frozen
--   playerUserId: number,
--   joinOrderPosition: number,
--   stagePlaceNumber: number,
--   scoredOutfitStylingItemKeys: { string },                       frozen
--   outfitScoreBreakdown: OutfitScoreCalculator.OutfitScoreBreakdown,   frozen
-- }
-- ════════════════════════════════════════════════════════════════════════════════════════════

local OutfitScoreCalculator = require("../shared/OutfitScoreCalculator")

export type ScoredParticipant = {
	playerUserId: number,
	joinOrderPosition: number,
	stagePlaceNumber: number,
	scoredOutfitStylingItemKeys: { string },
	outfitScoreBreakdown: OutfitScoreCalculator.OutfitScoreBreakdown,
}

local ThemedRoundFinalOutfitScorer = {}

function ThemedRoundFinalOutfitScorer.scoreFinalOutfitsAndAssignStagePlaces(
	finalOutfitScoringRequest
): ({ ScoredParticipant }, { number })
	local scoredParticipants = {}
	local playerUserIdsWhoseScoringRaised = {}
	for _, participant in finalOutfitScoringRequest.participantsInJoinOrder do
		local finalOutfitStylingItemKeys =
			finalOutfitScoringRequest.finalOutfitStylingItemKeysByPlayerUserId[participant.playerUserId]
		if finalOutfitStylingItemKeys ~= nil then
			local scoredOutfitStylingItemKeys = if table.isfrozen(finalOutfitStylingItemKeys)
				then finalOutfitStylingItemKeys
				else table.freeze(table.clone(finalOutfitStylingItemKeys))
			local didScore, outfitScoreBreakdown = pcall(
				OutfitScoreCalculator.calculateOutfitScore,
				scoredOutfitStylingItemKeys,
				finalOutfitScoringRequest.stylingItemByStylingItemKey,
				finalOutfitScoringRequest.theme,
				finalOutfitScoringRequest.roundBonusRule
			)
			if not didScore then
				table.insert(playerUserIdsWhoseScoringRaised, participant.playerUserId)
				continue
			end
			table.insert(
				scoredParticipants,
				table.freeze({
					playerUserId = participant.playerUserId,
					joinOrderPosition = participant.joinOrderPosition,
					stagePlaceNumber = #scoredParticipants + 1,
					scoredOutfitStylingItemKeys = scoredOutfitStylingItemKeys,
					outfitScoreBreakdown = outfitScoreBreakdown,
				})
			)
		end
	end
	return table.freeze(scoredParticipants), table.freeze(playerUserIdsWhoseScoringRaised)
end

return table.freeze(ThemedRoundFinalOutfitScorer)
