-- ThemedRoundDeviceSession (development spec §2.1 to §2.5, §2.14): the device's view of the themed
-- round it is in, and the player's actions in it. It ties together the round state the server
-- sends, joining, the wardrobe selection, the outfit draft sender and the round results. Screens
-- read it through ThemedRoundScreenModelBuilder; they never decide anything themselves.
--
-- Round state:
--   * Each RoundStateChanged replaces the held round state and feeds the countdown estimator.
--   * A NEW roundId ends everything of the previous round on the device: participation, the draft
--     sender's sending, the selection, the join feedback and the results. Nothing leaks into the
--     next round, and the draft numbering restarts at 1 when the player joins it.
--   * Leaving Styling (to Showcase or later) ends the draft sender's sending: the server ignores
--     drafts after the cut-off (§2.3). The selection stays for display.
-- Joining (§2.2): askToJoinCurrentRound sends one request at a time, during ThemeReveal and Styling,
--   while not a participant. The answer is matched to the round it was asked for. Accepted, or
--   rejected as AlreadyParticipating (the server knows best; an earlier answer may have been
--   lost), makes the player a participant of that round with an empty selection; the draft sender
--   starts at sequence number 1. Any other rejection is kept for the screen to explain. A
--   participantUserIds list naming the local player also counts as participation.
-- Wardrobe (§2.3, §2.14): tapWardrobeItem applies WardrobeSelectionRules to the selection, but
--   only for a participant while the wardrobe is unlocked: during Styling with more than
--   WARDROBE_LOCK_BEFORE_STYLING_END_SECONDS remaining by the countdown estimator. Every accepted
--   change is handed to the draft sender. A new wardrobe catalog drops selected items it no longer
--   lists (and sends the result while unlocked). A draft the server rejects puts the selection
--   back to the last kept draft and keeps a notice for the screen.
-- Results (§2.5): RoundResultsPublished for the held round is kept until the next round; it may
--   arrive before the RoundStateChanged of Results (README "the device must not assume
--   RoundStateChanged comes first"), and one for another round is ignored.
-- Pure logic: clock, scheduler and the channel senders are injected.
--
-- PUBLIC API
--   ThemedRoundDeviceSession.new({ localPlayerUserId, clock, scheduler, stylingItemByStylingItemKey,
--       sendOutfitDraftToServer(message), requestJoinCurrentRound(onAnswer(answer?)),
--       onSessionChanged() }) -> session
--   session:receiveRoundStateChanged(message)            raw server message (read and checked here)
--   session:receiveRoundOutfitDraftAcknowledged(message)
--   session:receiveRoundResultsPublished(message)
--   session:applyWardrobeCatalogView(wardrobeCatalogView)
--   session:askToJoinCurrentRound() -> boolean   false when no request was sent
--   session:tapWardrobeItem(stylingItemKey) -> selectionOutcome?   nil when the wardrobe is not usable
--   session:isWardrobeUsableNow() -> boolean
--   session:readSessionSnapshot() -> plain table for ThemedRoundScreenModelBuilder (fresh copies)

local RoundOutfitDraftSender = require("./RoundOutfitDraftSender")
local RoundPhaseCountdownEstimator = require("./RoundPhaseCountdownEstimator")
local ServerSentMessageShapeReader = require("./ServerSentMessageShapeReader")
local ThemedRoundProtocol = require("../shared/ThemedRoundProtocol")
local WardrobeSelectionRules = require("./WardrobeSelectionRules")

local ROUND_PHASES = ThemedRoundProtocol.ROUND_PHASES

local ThemedRoundDeviceSession = {}
ThemedRoundDeviceSession.__index = ThemedRoundDeviceSession

function ThemedRoundDeviceSession.new(dependencies)
	local self = setmetatable({
		localPlayerUserId = dependencies.localPlayerUserId,
		clock = dependencies.clock,
		stylingItemByStylingItemKey = dependencies.stylingItemByStylingItemKey,
		requestJoinCurrentRound = dependencies.requestJoinCurrentRound,
		onSessionChanged = dependencies.onSessionChanged,
		countdownEstimator = RoundPhaseCountdownEstimator.new(),
		roundState = nil,
		wardrobeCatalogView = nil,
		participatingRoundId = nil,
		selectedStylingItemKeys = {},
		joinRequestRoundId = nil, -- the round a join request in flight was sent for
		joinRejection = nil, -- { roundId, rejectionReason? }
		outfitPutBackNotice = nil, -- { roundId, rejectionReason? }
		selectionRefusal = nil, -- { selectionRefusalReason }
		roundResults = nil, -- as ServerSentMessageShapeReader reads it, for the held round
	}, ThemedRoundDeviceSession)
	self.draftSender = RoundOutfitDraftSender.new({
		clock = dependencies.clock,
		scheduler = dependencies.scheduler,
		sendOutfitDraftToServer = dependencies.sendOutfitDraftToServer,
		onSelectionPutBack = function(lastKeptStylingItemKeys, rejectionReason)
			self.selectedStylingItemKeys = lastKeptStylingItemKeys
			self.outfitPutBackNotice = { roundId = self.participatingRoundId, rejectionReason = rejectionReason }
			self:notifySessionChanged()
		end,
		onDraftSavingStatusChanged = function()
			self:notifySessionChanged()
		end,
	})
	return self
end

function ThemedRoundDeviceSession:notifySessionChanged()
	if self.onSessionChanged ~= nil then
		self.onSessionChanged()
	end
end

function ThemedRoundDeviceSession:readCurrentRoundId(): string?
	return if self.roundState ~= nil then self.roundState.roundId else nil
end

function ThemedRoundDeviceSession:forgetPreviousRound()
	self.draftSender:forgetRound()
	self.participatingRoundId = nil
	self.selectedStylingItemKeys = {}
	self.joinRejection = nil
	self.outfitPutBackNotice = nil
	self.selectionRefusal = nil
	self.roundResults = nil
end

function ThemedRoundDeviceSession:beginParticipation(roundId: string)
	if self.participatingRoundId == roundId then
		return
	end
	self.participatingRoundId = roundId
	self.selectedStylingItemKeys = {}
	self.joinRejection = nil
	if self.roundState ~= nil and self.roundState.roundPhase ~= ROUND_PHASES.Showcase then
		self.draftSender:beginRoundParticipation(roundId)
	end
end

function ThemedRoundDeviceSession:receiveRoundStateChanged(message: any)
	local roundState = ServerSentMessageShapeReader.readRoundStateChangedMessage(message)
	if roundState == nil then
		return
	end
	if roundState.roundId ~= self:readCurrentRoundId() then
		self:forgetPreviousRound()
	end
	self.roundState = roundState
	self.countdownEstimator:noteRoundStateReceived(roundState, self.clock:getCurrentUnixMilliseconds())
	local isListedAsParticipant = table.find(roundState.participantUserIds, self.localPlayerUserId) ~= nil
	local isBeforeShowcase = roundState.roundPhase == ROUND_PHASES.ThemeReveal
		or roundState.roundPhase == ROUND_PHASES.Styling
	if isListedAsParticipant and self.participatingRoundId ~= roundState.roundId then
		if isBeforeShowcase then
			self:beginParticipation(roundState.roundId)
		else
			self.participatingRoundId = roundState.roundId
		end
	end
	if not isBeforeShowcase then
		self.draftSender:endRoundParticipation()
	end
	self:notifySessionChanged()
end

function ThemedRoundDeviceSession:receiveRoundOutfitDraftAcknowledged(message: any)
	local acknowledgement = ServerSentMessageShapeReader.readRoundOutfitDraftAcknowledgedMessage(message)
	if acknowledgement ~= nil then
		self.draftSender:receiveOutfitDraftAcknowledgement(acknowledgement)
	end
end

function ThemedRoundDeviceSession:receiveRoundResultsPublished(message: any)
	local roundResults = ServerSentMessageShapeReader.readRoundResultsPublishedMessage(message)
	if roundResults == nil or roundResults.roundId ~= self:readCurrentRoundId() then
		return
	end
	self.roundResults = roundResults
	self:notifySessionChanged()
end

function ThemedRoundDeviceSession:readRemainingSecondsInPhase(): number?
	if self.roundState == nil then
		return nil
	end
	return self.countdownEstimator:readRemainingSecondsInPhase(self.roundState, self.clock:getCurrentUnixMilliseconds())
end

function ThemedRoundDeviceSession:isWardrobeUsableNow(): boolean
	local roundState = self.roundState
	if roundState == nil or roundState.roundPhase ~= ROUND_PHASES.Styling then
		return false
	end
	if self.participatingRoundId ~= roundState.roundId or self.wardrobeCatalogView == nil then
		return false
	end
	local remainingSeconds = self:readRemainingSecondsInPhase()
	return remainingSeconds ~= nil and remainingSeconds > ThemedRoundProtocol.WARDROBE_LOCK_BEFORE_STYLING_END_SECONDS
end

function ThemedRoundDeviceSession:applyWardrobeCatalogView(wardrobeCatalogView)
	self.wardrobeCatalogView = wardrobeCatalogView
	local keptKeys =
		WardrobeSelectionRules.keepOnlyListedStylingItems(self.selectedStylingItemKeys, wardrobeCatalogView)
	if #keptKeys ~= #self.selectedStylingItemKeys then
		self.selectedStylingItemKeys = keptKeys
		if self:isWardrobeUsableNow() then
			self.draftSender:submitCurrentOutfit(keptKeys)
		end
	end
	self:notifySessionChanged()
end

function ThemedRoundDeviceSession:tapWardrobeItem(stylingItemKey: string)
	if not self:isWardrobeUsableNow() then
		return nil
	end
	local selectionOutcome = WardrobeSelectionRules.toggleStylingItemInSelection(
		self.selectedStylingItemKeys,
		stylingItemKey,
		self.wardrobeCatalogView,
		self.stylingItemByStylingItemKey
	)
	self.selectionRefusal = if selectionOutcome.isSelectionChanged
		then nil
		else { selectionRefusalReason = selectionOutcome.selectionRefusalReason }
	if selectionOutcome.isSelectionChanged then
		self.selectedStylingItemKeys = selectionOutcome.outfitStylingItemKeys
		self.outfitPutBackNotice = nil
		self.draftSender:submitCurrentOutfit(selectionOutcome.outfitStylingItemKeys)
	end
	self:notifySessionChanged()
	return selectionOutcome
end

function ThemedRoundDeviceSession:canAskToJoinNow(): boolean
	local roundState = self.roundState
	if roundState == nil or self.joinRequestRoundId ~= nil or self.participatingRoundId == roundState.roundId then
		return false
	end
	return roundState.roundPhase == ROUND_PHASES.ThemeReveal or roundState.roundPhase == ROUND_PHASES.Styling
end

function ThemedRoundDeviceSession:receiveJoinAnswer(askedRoundId: string, answer: any)
	self.joinRequestRoundId = nil
	if askedRoundId ~= self:readCurrentRoundId() then
		self:notifySessionChanged()
		return
	end
	local isAccepted = type(answer) == "table" and answer.isAccepted == true
	local rejectionReason = if type(answer) == "table" and type(answer.rejectionReason) == "string"
		then answer.rejectionReason
		else nil
	if isAccepted or rejectionReason == "AlreadyParticipating" then
		self:beginParticipation(askedRoundId)
	end
	if not isAccepted then
		self.joinRejection = { roundId = askedRoundId, rejectionReason = rejectionReason }
	end
	self:notifySessionChanged()
end

function ThemedRoundDeviceSession:askToJoinCurrentRound(): boolean
	if not self:canAskToJoinNow() then
		return false
	end
	local askedRoundId = self.roundState.roundId
	self.joinRequestRoundId = askedRoundId
	self.joinRejection = nil
	self:notifySessionChanged()
	self.requestJoinCurrentRound(function(answer)
		self:receiveJoinAnswer(askedRoundId, answer)
	end)
	return true
end

function ThemedRoundDeviceSession:readSessionSnapshot()
	local roundState = self.roundState
	local currentRoundId = self:readCurrentRoundId()
	return {
		localPlayerUserId = self.localPlayerUserId,
		roundState = roundState,
		remainingSecondsInPhase = self:readRemainingSecondsInPhase(),
		isParticipant = currentRoundId ~= nil and self.participatingRoundId == currentRoundId,
		isJoinRequestInFlight = self.joinRequestRoundId ~= nil,
		canAskToJoinNow = self:canAskToJoinNow(),
		joinRejection = self.joinRejection,
		wardrobeCatalogView = self.wardrobeCatalogView,
		isWardrobeUsableNow = self:isWardrobeUsableNow(),
		selectedStylingItemKeys = table.clone(self.selectedStylingItemKeys),
		draftSavingStatus = self.draftSender:readDraftSavingStatus(),
		latestSentOutfitDraftSequenceNumber = self.draftSender:readLatestSentOutfitDraftSequenceNumber(),
		lastKeptStylingItemKeys = self.draftSender:readLastKeptStylingItemKeys(),
		outfitPutBackNotice = self.outfitPutBackNotice,
		selectionRefusal = self.selectionRefusal,
		roundResults = self.roundResults,
	}
end

return ThemedRoundDeviceSession
