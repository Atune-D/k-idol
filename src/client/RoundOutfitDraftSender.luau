-- RoundOutfitDraftSender (development spec §2.3 "What the device does"): sends the participant's
-- current outfit to the server as numbered drafts and follows the server's acknowledgements.
--
-- Rules, exactly as §2.3 states them for the device:
--   * After each wardrobe change (submitCurrentOutfit) the current outfit is sent, at most once every
--     OUTFIT_DRAFT_SEND_INTERVAL_SECONDS (0.5). A change inside the interval is sent when the
--     interval ends; several changes inside one interval are sent once, as the latest outfit.
--   * Sequence numbers start at 1 for each round (beginRoundParticipation) and rise by 1 per new
--     draft.
--   * If the latest sent draft is not acknowledged after OUTFIT_DRAFT_RESEND_AFTER_SECONDS (1), it is
--     sent again with the SAME sequence number, and again every second until acknowledged or until
--     the round's sending ends. A resend counts as a send for the 0.5 s interval.
--   * The outfit shows as saved only when the LATEST draft is acknowledged with isKept = true and no
--     newer change is waiting to be sent.
--   * On isKept = false for the latest draft, the selection goes back to the last kept draft (the
--     server keeps that one, §2.3 check 4), any waiting change is dropped, and the player is told
--     (status PutBackToLastSaved; onSelectionPutBack is called).
-- Acknowledgements that do not concern the latest draft:
--   * for another round, before participation, or with a number never sent: ignored;
--   * for an OLDER number (late, or overtaken by coalescing on the server): isKept = true records
--     that draft as the last kept one when it is newer than the one recorded (the server keeps it
--     until the newer draft is processed); isKept = false changes nothing (a newer draft is already
--     on its way and the player's newer choice is not thrown away);
--   * the same acknowledgement arriving twice (the server re-sends, §2.3 check 2): handled once.
-- The wardrobe lock (§2.3, one second before Styling ends) is not decided here:
-- ThemedRoundDeviceSession does not call submitCurrentOutfit while locked. A change already
-- waiting when the lock starts is still sent at the end of its interval.
-- Before any draft is kept, the last kept outfit is the empty outfit (a new participant starts
-- from an empty outfit on the server, spec §10 v1.4 owner decision 1).
-- Pure logic: clock and scheduler are injected (FakeClock / FakeScheduler in tests).
--
-- PUBLIC API
--   RoundOutfitDraftSender.DRAFT_SAVING_STATUSES  frozen: NothingSentYet, Saving, Saved, PutBackToLastSaved
--   RoundOutfitDraftSender.new({ clock, scheduler, sendOutfitDraftToServer, onSelectionPutBack?,
--       onDraftSavingStatusChanged? }) -> sender
--     clock: { getCurrentUnixMilliseconds }   scheduler: { scheduleCallbackAfterSeconds -> cancel }
--     sendOutfitDraftToServer({ roundId, outfitDraftSequenceNumber, outfitStylingItemKeys })
--       receives a fresh table each call.
--     onSelectionPutBack(lastKeptStylingItemKeys (fresh), rejectionReason?)
--     onDraftSavingStatusChanged(draftSavingStatus)
--   sender:beginRoundParticipation(roundId)   resets everything; numbering restarts at 1
--   sender:endRoundParticipation()            stops sending and resending; state kept for reading
--   sender:forgetRound()                      stops everything and forgets the round (no participation)
--   sender:submitCurrentOutfit(outfitStylingItemKeys)   ignored when not participating
--   sender:receiveOutfitDraftAcknowledgement(acknowledgement)   (as ServerSentMessageShapeReader reads it)
--   sender:readDraftSavingStatus() -> string
--   sender:readLastKeptStylingItemKeys() -> { string }   fresh
--   sender:readLatestSentOutfitDraftSequenceNumber() -> number   (0 before the first send)
--   sender:readParticipatingRoundId() -> string?

local ThemedRoundProtocol = require("../shared/ThemedRoundProtocol")

local RoundOutfitDraftSender = {}
RoundOutfitDraftSender.__index = RoundOutfitDraftSender

RoundOutfitDraftSender.DRAFT_SAVING_STATUSES = table.freeze({
	NothingSentYet = "NothingSentYet",
	Saving = "Saving",
	Saved = "Saved",
	PutBackToLastSaved = "PutBackToLastSaved",
})

local STATUSES = RoundOutfitDraftSender.DRAFT_SAVING_STATUSES
local SEND_INTERVAL_MILLISECONDS = ThemedRoundProtocol.OUTFIT_DRAFT_SEND_INTERVAL_SECONDS * 1000
local RESEND_AFTER_SECONDS = ThemedRoundProtocol.OUTFIT_DRAFT_RESEND_AFTER_SECONDS

function RoundOutfitDraftSender.new(dependencies)
	local self = setmetatable({
		clock = dependencies.clock,
		scheduler = dependencies.scheduler,
		sendOutfitDraftToServer = dependencies.sendOutfitDraftToServer,
		onSelectionPutBack = dependencies.onSelectionPutBack,
		onDraftSavingStatusChanged = dependencies.onDraftSavingStatusChanged,
	}, RoundOutfitDraftSender)
	self:resetRoundState(nil)
	return self
end

function RoundOutfitDraftSender:cancelTimers()
	if self.cancelWaitingSend ~= nil then
		self.cancelWaitingSend()
		self.cancelWaitingSend = nil
	end
	if self.cancelResend ~= nil then
		self.cancelResend()
		self.cancelResend = nil
	end
end

function RoundOutfitDraftSender:resetRoundState(roundId: string?)
	self:cancelTimers()
	self.participatingRoundId = roundId
	self.isSendingActive = roundId ~= nil
	self.nextOutfitDraftSequenceNumber = 1
	self.latestSentDraft = nil -- { outfitDraftSequenceNumber, outfitStylingItemKeys, isAcknowledged }
	-- Every draft sent this round (at most one per 0.5 s of Styling, so a few hundred at most).
	self.sentStylingItemKeysBySequenceNumber = {}
	self.lastKeptDraft = { outfitDraftSequenceNumber = 0, outfitStylingItemKeys = {} }
	self.waitingOutfitStylingItemKeys = nil
	self.lastSendAtUnixMilliseconds = nil
	self.draftSavingStatus = STATUSES.NothingSentYet
end

function RoundOutfitDraftSender:setDraftSavingStatus(draftSavingStatus: string)
	if self.draftSavingStatus == draftSavingStatus then
		return
	end
	self.draftSavingStatus = draftSavingStatus
	if self.onDraftSavingStatusChanged ~= nil then
		self.onDraftSavingStatusChanged(draftSavingStatus)
	end
end

function RoundOutfitDraftSender:beginRoundParticipation(roundId: string)
	self:resetRoundState(roundId)
end

function RoundOutfitDraftSender:forgetRound()
	self:resetRoundState(nil)
end

function RoundOutfitDraftSender:endRoundParticipation()
	self:cancelTimers()
	self.isSendingActive = false
	self.waitingOutfitStylingItemKeys = nil
end

function RoundOutfitDraftSender:fireDraft(outfitDraftSequenceNumber: number, outfitStylingItemKeys: { string })
	self.lastSendAtUnixMilliseconds = self.clock:getCurrentUnixMilliseconds()
	self.sendOutfitDraftToServer({
		roundId = self.participatingRoundId,
		outfitDraftSequenceNumber = outfitDraftSequenceNumber,
		outfitStylingItemKeys = table.clone(outfitStylingItemKeys),
	})
	if self.cancelResend ~= nil then
		self.cancelResend()
	end
	self.cancelResend = self.scheduler:scheduleCallbackAfterSeconds(RESEND_AFTER_SECONDS, function()
		self.cancelResend = nil
		local latestSentDraft = self.latestSentDraft
		if self.isSendingActive and latestSentDraft ~= nil and not latestSentDraft.isAcknowledged then
			self:fireDraft(latestSentDraft.outfitDraftSequenceNumber, latestSentDraft.outfitStylingItemKeys)
		end
	end)
end

function RoundOutfitDraftSender:sendWaitingOutfit()
	local waitingKeys = self.waitingOutfitStylingItemKeys
	if not self.isSendingActive or waitingKeys == nil then
		return
	end
	self.waitingOutfitStylingItemKeys = nil
	local outfitDraftSequenceNumber = self.nextOutfitDraftSequenceNumber
	self.nextOutfitDraftSequenceNumber += 1
	self.latestSentDraft = {
		outfitDraftSequenceNumber = outfitDraftSequenceNumber,
		outfitStylingItemKeys = waitingKeys,
		isAcknowledged = false,
	}
	self.sentStylingItemKeysBySequenceNumber[outfitDraftSequenceNumber] = waitingKeys
	self:fireDraft(outfitDraftSequenceNumber, waitingKeys)
end

function RoundOutfitDraftSender:submitCurrentOutfit(outfitStylingItemKeys: { string })
	if not self.isSendingActive then
		return
	end
	self.waitingOutfitStylingItemKeys = table.clone(outfitStylingItemKeys)
	self:setDraftSavingStatus(STATUSES.Saving)
	if self.cancelWaitingSend ~= nil then
		return -- the waiting send at the end of the interval will carry this latest outfit
	end
	local nowMilliseconds = self.clock:getCurrentUnixMilliseconds()
	local lastSendAt = self.lastSendAtUnixMilliseconds
	local waitMilliseconds = if lastSendAt == nil then 0 else lastSendAt + SEND_INTERVAL_MILLISECONDS - nowMilliseconds
	if waitMilliseconds <= 0 then
		self:sendWaitingOutfit()
		return
	end
	self.cancelWaitingSend = self.scheduler:scheduleCallbackAfterSeconds(waitMilliseconds / 1000, function()
		self.cancelWaitingSend = nil
		self:sendWaitingOutfit()
	end)
end

function RoundOutfitDraftSender:recordKeptDraftIfNewer(outfitDraftSequenceNumber: number, outfitStylingItemKeys)
	if outfitDraftSequenceNumber > self.lastKeptDraft.outfitDraftSequenceNumber then
		self.lastKeptDraft = {
			outfitDraftSequenceNumber = outfitDraftSequenceNumber,
			outfitStylingItemKeys = outfitStylingItemKeys,
		}
	end
end

function RoundOutfitDraftSender:receiveOutfitDraftAcknowledgement(acknowledgement)
	local latestSentDraft = self.latestSentDraft
	if self.participatingRoundId == nil or acknowledgement.roundId ~= self.participatingRoundId then
		return
	end
	if
		latestSentDraft == nil
		or acknowledgement.outfitDraftSequenceNumber > latestSentDraft.outfitDraftSequenceNumber
	then
		return
	end
	local acknowledgedNumber = acknowledgement.outfitDraftSequenceNumber
	if acknowledgedNumber < latestSentDraft.outfitDraftSequenceNumber then
		-- An older draft (late, or the server coalesced past it): only a kept one matters.
		local olderKeys = self.sentStylingItemKeysBySequenceNumber[acknowledgedNumber]
		if acknowledgement.isKept and olderKeys ~= nil then
			self:recordKeptDraftIfNewer(acknowledgedNumber, olderKeys)
		end
		return
	end
	if latestSentDraft.isAcknowledged then
		return -- the same acknowledgement again
	end
	latestSentDraft.isAcknowledged = true
	if self.cancelResend ~= nil then
		self.cancelResend()
		self.cancelResend = nil
	end
	if acknowledgement.isKept then
		self:recordKeptDraftIfNewer(acknowledgedNumber, latestSentDraft.outfitStylingItemKeys)
		if self.waitingOutfitStylingItemKeys == nil then
			self:setDraftSavingStatus(STATUSES.Saved)
		end
		return
	end
	if self.cancelWaitingSend ~= nil then
		self.cancelWaitingSend()
		self.cancelWaitingSend = nil
	end
	self.waitingOutfitStylingItemKeys = nil
	self:setDraftSavingStatus(STATUSES.PutBackToLastSaved)
	if self.onSelectionPutBack ~= nil then
		self.onSelectionPutBack(table.clone(self.lastKeptDraft.outfitStylingItemKeys), acknowledgement.rejectionReason)
	end
end

function RoundOutfitDraftSender:readDraftSavingStatus(): string
	return self.draftSavingStatus
end

function RoundOutfitDraftSender:readLastKeptStylingItemKeys(): { string }
	return table.clone(self.lastKeptDraft.outfitStylingItemKeys)
end

function RoundOutfitDraftSender:readLatestSentOutfitDraftSequenceNumber(): number
	return if self.latestSentDraft ~= nil then self.latestSentDraft.outfitDraftSequenceNumber else 0
end

function RoundOutfitDraftSender:readParticipatingRoundId(): string?
	return self.participatingRoundId
end

return RoundOutfitDraftSender
