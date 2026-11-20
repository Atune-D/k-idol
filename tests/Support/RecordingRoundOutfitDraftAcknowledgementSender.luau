-- A test double for the `sendRoundOutfitDraftAcknowledged(playerUserId, acknowledgement)`
-- dependency of RoundOutfitDraftKeeper: records every acknowledgement with the fake time it was
-- sent, and can be told to raise (to test that a failing send is contained).
--
--   RecordingRoundOutfitDraftAcknowledgementSender.new(clock) -> recordingSender
--   recordingSender.sendRoundOutfitDraftAcknowledged   pass this to the keeper
--   recordingSender.sentAcknowledgementRecords   list of { playerUserId, acknowledgement,
--       sentAtUnixMilliseconds }, in sending order
--   recordingSender.shouldRaiseWhenSending   set true to make every later send raise (the
--       attempt is still recorded)
--   recordingSender.listAcknowledgementRecordsSentTo(playerUserId) -> records
--   recordingSender.countAcknowledgements() -> number

local RecordingRoundOutfitDraftAcknowledgementSender = {}

function RecordingRoundOutfitDraftAcknowledgementSender.new(clock: { getCurrentUnixMilliseconds: (any) -> number })
	local recordingSender = {
		sentAcknowledgementRecords = {},
		shouldRaiseWhenSending = false,
	}

	function recordingSender.sendRoundOutfitDraftAcknowledged(playerUserId: number, acknowledgement)
		table.insert(recordingSender.sentAcknowledgementRecords, {
			playerUserId = playerUserId,
			acknowledgement = acknowledgement,
			sentAtUnixMilliseconds = clock:getCurrentUnixMilliseconds(),
		})
		if recordingSender.shouldRaiseWhenSending then
			error("RecordingRoundOutfitDraftAcknowledgementSender: deliberate send failure")
		end
	end

	function recordingSender.listAcknowledgementRecordsSentTo(playerUserId: number)
		local acknowledgementRecordsForPlayer = {}
		for _, sentAcknowledgementRecord in recordingSender.sentAcknowledgementRecords do
			if sentAcknowledgementRecord.playerUserId == playerUserId then
				table.insert(acknowledgementRecordsForPlayer, sentAcknowledgementRecord)
			end
		end
		return acknowledgementRecordsForPlayer
	end

	function recordingSender.countAcknowledgements(): number
		return #recordingSender.sentAcknowledgementRecords
	end

	return recordingSender
end

return table.freeze(RecordingRoundOutfitDraftAcknowledgementSender)
