-- RoundOutfitDraftParticipantState (development spec v1.3 §2.3): the outfit draft state of ONE
-- participant in ONE round, and the small operations on its one-place waiting buffer and its
-- single processing timer. RoundOutfitDraftKeeper is its only user; it holds one per participant
-- and drops it when the participant leaves or the round ends.
--
-- Pure data, no Roblox-specific interface.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- RoundOutfitDraftParticipantState.EMPTY_OUTFIT_STYLING_ITEM_KEYS   a frozen empty list; the kept
--   draft every participant starts with.
-- RoundOutfitDraftParticipantState.createCleanParticipantState(joinOrderNumber) -> ParticipantState
--   Empty kept outfit, highest processed 0, nothing waiting, no timer, no stored acknowledgement.
--   joinOrderNumber orders participants by when they were added (the cut-off goes in that order).
-- RoundOutfitDraftParticipantState.putOutfitDraftInWaitingPlace(state, sequenceNumber, snapshot)
--   Replaces whatever waits (the caller has checked the number is strictly higher).
-- RoundOutfitDraftParticipantState.takeWaitingOutfitDraft(state) -> (sequenceNumber?, snapshot)
--   Empties the waiting place and returns what was in it (nil number when it was empty).
-- RoundOutfitDraftParticipantState.cancelPendingProcessingTimer(state)
--   Cancels the timer, if any, and forgets it. Safe to call when there is none.
-- RoundOutfitDraftParticipantState.listParticipantsInJoinOrder(participantStateByPlayerUserId)
--     -> { { playerUserId, participantState } }   a fresh list, earliest joined first
-- ════════════════════════════════════════════════════════════════════════════════════════════

local SetRoundOutfitDraftMessageReader = require("./SetRoundOutfitDraftMessageReader")

type OutfitSnapshot = SetRoundOutfitDraftMessageReader.OutfitSnapshot

export type RoundOutfitDraftAcknowledgement = {
	roundId: string,
	outfitDraftSequenceNumber: number,
	isKept: boolean,
	rejectionReason: string?,
}

export type ParticipantState = {
	joinOrderNumber: number,
	-- Frozen. What the cut-off hands back for scoring.
	keptOutfitStylingItemKeys: { string },
	-- 0 until the first draft is processed (valid or not).
	highestProcessedOutfitDraftSequenceNumber: number,
	-- The frozen acknowledgement sent for the highest processed draft; re-sent under check 2.
	acknowledgementForHighestProcessedOutfitDraft: RoundOutfitDraftAcknowledgement?,
	lastAcknowledgementResentAtUnixMilliseconds: number?,
	-- The one-place buffer of check 3. The number is nil when nothing waits.
	waitingOutfitDraftSequenceNumber: number?,
	waitingOutfitStylingItemKeysSnapshot: OutfitSnapshot?,
	-- Identifies the single pending timer; a timer whose token is no longer this one is stale.
	pendingProcessingTimerToken: {}?,
	cancelPendingProcessingTimer: (() -> ())?,
}

local RoundOutfitDraftParticipantState = {}

RoundOutfitDraftParticipantState.EMPTY_OUTFIT_STYLING_ITEM_KEYS = table.freeze({}) :: { string }

function RoundOutfitDraftParticipantState.createCleanParticipantState(joinOrderNumber: number): ParticipantState
	return {
		joinOrderNumber = joinOrderNumber,
		keptOutfitStylingItemKeys = RoundOutfitDraftParticipantState.EMPTY_OUTFIT_STYLING_ITEM_KEYS,
		highestProcessedOutfitDraftSequenceNumber = 0,
		acknowledgementForHighestProcessedOutfitDraft = nil,
		lastAcknowledgementResentAtUnixMilliseconds = nil,
		waitingOutfitDraftSequenceNumber = nil,
		waitingOutfitStylingItemKeysSnapshot = nil,
		pendingProcessingTimerToken = nil,
		cancelPendingProcessingTimer = nil,
	}
end

function RoundOutfitDraftParticipantState.putOutfitDraftInWaitingPlace(
	participantState: ParticipantState,
	outfitDraftSequenceNumber: number,
	outfitStylingItemKeysSnapshot: OutfitSnapshot
)
	participantState.waitingOutfitDraftSequenceNumber = outfitDraftSequenceNumber
	participantState.waitingOutfitStylingItemKeysSnapshot = outfitStylingItemKeysSnapshot
end

function RoundOutfitDraftParticipantState.takeWaitingOutfitDraft(
	participantState: ParticipantState
): (number?, OutfitSnapshot?)
	local waitingOutfitDraftSequenceNumber = participantState.waitingOutfitDraftSequenceNumber
	local waitingOutfitStylingItemKeysSnapshot = participantState.waitingOutfitStylingItemKeysSnapshot
	participantState.waitingOutfitDraftSequenceNumber = nil
	participantState.waitingOutfitStylingItemKeysSnapshot = nil
	return waitingOutfitDraftSequenceNumber, waitingOutfitStylingItemKeysSnapshot
end

function RoundOutfitDraftParticipantState.cancelPendingProcessingTimer(participantState: ParticipantState)
	local cancelPendingProcessingTimer = participantState.cancelPendingProcessingTimer
	participantState.pendingProcessingTimerToken = nil
	participantState.cancelPendingProcessingTimer = nil
	if cancelPendingProcessingTimer ~= nil then
		cancelPendingProcessingTimer()
	end
end

function RoundOutfitDraftParticipantState.listParticipantsInJoinOrder(
	participantStateByPlayerUserId: { [number]: ParticipantState }
): {
	{
		playerUserId: number,
		participantState: ParticipantState,
	}
}
	local participantsInJoinOrder = {}
	for playerUserId, participantState in participantStateByPlayerUserId do
		table.insert(participantsInJoinOrder, { playerUserId = playerUserId, participantState = participantState })
	end
	table.sort(participantsInJoinOrder, function(earlierParticipant, laterParticipant)
		return earlierParticipant.participantState.joinOrderNumber < laterParticipant.participantState.joinOrderNumber
	end)
	return participantsInJoinOrder
end

return table.freeze(RoundOutfitDraftParticipantState)
