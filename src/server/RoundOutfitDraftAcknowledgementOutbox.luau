-- RoundOutfitDraftAcknowledgementOutbox (development spec v1.3 §2.3): builds, stores and sends
-- `RoundOutfitDraftAcknowledged` for ONE round. RoundOutfitDraftKeeper is its only user.
--
-- Rules it enforces:
--   * An acknowledgement is a frozen `{ roundId, outfitDraftSequenceNumber, isKept,
--     rejectionReason }` whose roundId is always the server's own; rejectionReason is
--     "OutfitInvalid" when not kept and absent when kept (§2.3 defines no other reason).
--   * The acknowledgement of a player's highest processed draft is stored in that player's
--     RoundOutfitDraftParticipantState, and re-sent unchanged (the same frozen table) under check
--     2, at most once per player per 0.25 s (audit question 3). Further duplicates in that
--     window are dropped silently.
--   * A sender that raises never breaks the caller (the cut-off must finish for everyone); the
--     first failure in the round is logged as a warning, later ones are not (no log line per
--     draft).
--
-- No Roblox-specific interface: the sender, the clock and the logger are injected.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- RoundOutfitDraftAcknowledgementOutbox.OUTFIT_DRAFT_REJECTION_REASON_OUTFIT_INVALID = "OutfitInvalid"
-- RoundOutfitDraftAcknowledgementOutbox.ACKNOWLEDGEMENT_RESEND_MINIMUM_INTERVAL_MILLISECONDS = 250
-- RoundOutfitDraftAcknowledgementOutbox.new({ roundId, clock, sendRoundOutfitDraftAcknowledged,
--     logger }) -> outbox   (the keeper has already checked each dependency)
-- outbox:storeAndSendFreshAcknowledgement(playerUserId, participantState, outfitDraftSequenceNumber, isKept)
--   For a draft just processed: builds the acknowledgement, stores it as the participant's
--   acknowledgementForHighestProcessedOutfitDraft BEFORE sending it (a sender that calls back
--   in with a duplicate already sees the new one), then sends it.
-- outbox:resendStoredAcknowledgementAndRecordResendTimeWhenAllowed(playerUserId, participantState)
--   For a draft that failed check 2 (so a processed draft, and its stored acknowledgement,
--   exists): sends the stored acknowledgement again unless one was re-sent to this player less
--   than 0.25 s ago, and then records the time of this re-send as the participant's
--   lastAcknowledgementResentAtUnixMilliseconds.
-- Both write only those two fields of the RoundOutfitDraftParticipantState they are given.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local ThemedRoundProtocol = require("../shared/ThemedRoundProtocol")
local RoundOutfitDraftParticipantState = require("./RoundOutfitDraftParticipantState")

type ParticipantState = RoundOutfitDraftParticipantState.ParticipantState

local RoundOutfitDraftAcknowledgementOutbox = {}
RoundOutfitDraftAcknowledgementOutbox.__index = RoundOutfitDraftAcknowledgementOutbox

RoundOutfitDraftAcknowledgementOutbox.OUTFIT_DRAFT_REJECTION_REASON_OUTFIT_INVALID = "OutfitInvalid"
RoundOutfitDraftAcknowledgementOutbox.ACKNOWLEDGEMENT_RESEND_MINIMUM_INTERVAL_MILLISECONDS =
	math.round(ThemedRoundProtocol.OUTFIT_DRAFT_SERVER_PROCESSING_INTERVAL_SECONDS * 1000)

local ACKNOWLEDGEMENT_RESEND_MINIMUM_INTERVAL_MILLISECONDS =
	RoundOutfitDraftAcknowledgementOutbox.ACKNOWLEDGEMENT_RESEND_MINIMUM_INTERVAL_MILLISECONDS

function RoundOutfitDraftAcknowledgementOutbox.new(outboxDependencies: {
	roundId: string,
	clock: { getCurrentUnixMilliseconds: (any) -> number },
	sendRoundOutfitDraftAcknowledged: (number, any) -> (),
	logger: { logWarning: (any, string) -> () },
})
	return setmetatable({
		roundId = outboxDependencies.roundId,
		clock = outboxDependencies.clock,
		sendRoundOutfitDraftAcknowledged = outboxDependencies.sendRoundOutfitDraftAcknowledged,
		logger = outboxDependencies.logger,
		hasLoggedAcknowledgementSendFailure = false,
	}, RoundOutfitDraftAcknowledgementOutbox)
end

local function sendAcknowledgementContainingFailure(self, playerUserId: number, acknowledgement)
	local didSend, sendError = pcall(self.sendRoundOutfitDraftAcknowledged, playerUserId, acknowledgement)
	if not didSend and not self.hasLoggedAcknowledgementSendFailure then
		self.hasLoggedAcknowledgementSendFailure = true
		self.logger:logWarning(
			string.format(
				"RoundOutfitDraftKeeper: sending RoundOutfitDraftAcknowledged failed in round %s (%s); "
					.. "later failures this round are not logged",
				self.roundId,
				tostring(sendError)
			)
		)
	end
end

function RoundOutfitDraftAcknowledgementOutbox.storeAndSendFreshAcknowledgement(
	self,
	playerUserId: number,
	participantState: ParticipantState,
	outfitDraftSequenceNumber: number,
	isKept: boolean
)
	local acknowledgement = table.freeze({
		roundId = self.roundId,
		outfitDraftSequenceNumber = outfitDraftSequenceNumber,
		isKept = isKept,
		rejectionReason = if isKept
			then nil
			else RoundOutfitDraftAcknowledgementOutbox.OUTFIT_DRAFT_REJECTION_REASON_OUTFIT_INVALID,
	})
	participantState.acknowledgementForHighestProcessedOutfitDraft = acknowledgement
	sendAcknowledgementContainingFailure(self, playerUserId, acknowledgement)
end

function RoundOutfitDraftAcknowledgementOutbox.resendStoredAcknowledgementAndRecordResendTimeWhenAllowed(
	self,
	playerUserId: number,
	participantState: ParticipantState
)
	local currentUnixMilliseconds = self.clock:getCurrentUnixMilliseconds()
	local lastResentAtUnixMilliseconds = participantState.lastAcknowledgementResentAtUnixMilliseconds
	if
		lastResentAtUnixMilliseconds ~= nil
		and currentUnixMilliseconds - lastResentAtUnixMilliseconds
			< ACKNOWLEDGEMENT_RESEND_MINIMUM_INTERVAL_MILLISECONDS
	then
		return
	end
	participantState.lastAcknowledgementResentAtUnixMilliseconds = currentUnixMilliseconds
	sendAcknowledgementContainingFailure(
		self,
		playerUserId,
		participantState.acknowledgementForHighestProcessedOutfitDraft
	)
end

return table.freeze(RoundOutfitDraftAcknowledgementOutbox)
