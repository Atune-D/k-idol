-- Builders shared by the RoundOutfitDraftKeeper and ThemedRoundReferee test harnesses: the
-- SetRoundOutfitDraft message a device would send, the acknowledgement summaries tests compare
-- against, and a reduced available styling item key set. Not a spec file.
--
--   RoundOutfitDraftTestMessages.buildOutfitDraftMessage(roundId, outfitDraftSequenceNumber,
--       outfitStylingItemKeys) -> message   a list is copied, so the caller's (often frozen)
--       fixture is never the table the keeper receives; any other value is passed through
--   RoundOutfitDraftTestMessages.summarizeAcknowledgementsSentTo(recordingSender, playerUserId,
--       roundStartUnixMilliseconds) -> { { roundMilliseconds, roundId, outfitDraftSequenceNumber,
--       isKept, rejectionReason } }   in send order
--   RoundOutfitDraftTestMessages.buildExpectedAcknowledgementSummary(roundSeconds, roundId,
--       outfitDraftSequenceNumber, isKept) -> one summary as above ("OutfitInvalid" when not kept)
--   RoundOutfitDraftTestMessages.copyAvailableStylingItemKeySetWithout(availableStylingItemKeySet,
--       hiddenStylingItemKey) -> a frozen copy without that key

local RoundOutfitDraftTestMessages = {}

function RoundOutfitDraftTestMessages.buildOutfitDraftMessage(
	roundId: any,
	outfitDraftSequenceNumber: any,
	outfitStylingItemKeys: any
)
	return {
		roundId = roundId,
		outfitDraftSequenceNumber = outfitDraftSequenceNumber,
		outfitStylingItemKeys = if type(outfitStylingItemKeys) == "table"
			then table.move(outfitStylingItemKeys, 1, #outfitStylingItemKeys, 1, {})
			else outfitStylingItemKeys,
	}
end

function RoundOutfitDraftTestMessages.summarizeAcknowledgementsSentTo(
	recordingSender,
	playerUserId: number,
	roundStartUnixMilliseconds: number
)
	local acknowledgementSummaries = {}
	for _, sentRecord in recordingSender.listAcknowledgementRecordsSentTo(playerUserId) do
		local acknowledgement = sentRecord.acknowledgement
		table.insert(acknowledgementSummaries, {
			roundMilliseconds = sentRecord.sentAtUnixMilliseconds - roundStartUnixMilliseconds,
			roundId = acknowledgement.roundId,
			outfitDraftSequenceNumber = acknowledgement.outfitDraftSequenceNumber,
			isKept = acknowledgement.isKept,
			rejectionReason = acknowledgement.rejectionReason,
		})
	end
	return acknowledgementSummaries
end

function RoundOutfitDraftTestMessages.buildExpectedAcknowledgementSummary(
	roundSeconds: number,
	roundId: string,
	outfitDraftSequenceNumber: number,
	isKept: boolean
)
	return {
		roundMilliseconds = math.round(roundSeconds * 1000),
		roundId = roundId,
		outfitDraftSequenceNumber = outfitDraftSequenceNumber,
		isKept = isKept,
		rejectionReason = if isKept then nil else "OutfitInvalid",
	}
end

function RoundOutfitDraftTestMessages.copyAvailableStylingItemKeySetWithout(
	availableStylingItemKeySet: { [string]: boolean },
	hiddenStylingItemKey: string
)
	local reducedAvailableStylingItemKeySet = table.clone(availableStylingItemKeySet)
	reducedAvailableStylingItemKeySet[hiddenStylingItemKey] = nil
	return table.freeze(reducedAvailableStylingItemKeySet)
end

return table.freeze(RoundOutfitDraftTestMessages)
