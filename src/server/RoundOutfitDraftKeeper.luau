-- RoundOutfitDraftKeeper (development spec v1.3 §2.3, §2.13, §1.5): the server side of the
-- outfit draft protocol for ONE themed round. It holds each participant's drafts, applies the
-- four checks of §2.3 to every arriving `SetRoundOutfitDraft`, sends `RoundOutfitDraftAcknowledged`,
-- and at the end of Styling performs the cut-off and hands back each participant's final outfit.
--
-- It does NOT decide who may join, follow the round clock, score, publish results, grant
-- rewards, detect leaving or dress characters: ThemedRoundReferee does those and drives this
-- keeper. Calls no Roblox-specific interface; everything external is injected (see `new`).
-- Internal parts: SetRoundOutfitDraftMessageReader (untrusted message, private copy),
-- RoundOutfitDraftParticipantState (per-player state), RoundOutfitDraftAcknowledgementOutbox.
--
-- Rules it enforces (spec §2.3 and the referee audit defaults, questions 1 to 10 and 25):
--   * Check 1. A draft is ignored, with no acknowledgement and no state change, unless drafts are
--     being accepted (between startAcceptingOutfitDrafts and the cut-off), the sender is a
--     participant, the message is a table without a metatable, its roundId is this round's
--     (rawequal: same type and value) and its outfitDraftSequenceNumber is legal (a whole number
--     in 1 .. 2^53 - 1). Ignored drafts are not "processed": no use of the 0.25 s interval.
--   * Check 2. A number not higher than the highest PROCESSED one is not processed again; the
--     stored acknowledgement of the highest processed draft is sent again unchanged, at most
--     once per player per 0.25 s (later duplicates in that window are dropped silently). A
--     re-send never validates and changes nothing else.
--   * Check 3. Processing to processing, at least 0.25 s apart per player, measured by the
--     injected PlayerRequestRateLimiter. A draft arriving sooner is never refused: it waits in a
--     one-place buffer with ONE timer. Only a strictly higher number replaces the waiting draft;
--     a lower or equal number is dropped (the first-arrived content of a number stays). A newer
--     draft that arrives once the interval has passed is processed at once and the waiting one
--     is discarded unprocessed, so the highest processed number never decreases. A replaced
--     waiting draft is never acknowledged.
--   * Check 4. Judged at processing, against the available key set current at that moment, on
--     the private copy taken on arrival (SetRoundOutfitDraftMessageReader: at most 12 entries,
--     each a string of at most 40 characters, otherwise a small marker). A valid copy
--     is frozen and becomes the kept draft: what is validated is exactly what is kept. An
--     invalid one is acknowledged `isKept = false, rejectionReason = "OutfitInvalid"` (never the
--     validator's detailed reason) and the previous kept draft stays. An invalid draft still
--     counts as processed: it becomes the highest processed number and restarts the interval.
--   * Every participant starts with the empty outfit as kept draft and highest processed 0.
--   * Bounded work whatever a device sends: constant work and no allocation before a draft is
--     known to be either re-sent, dropped or worth buffering; at most one pending timer per
--     participant; at most one validation per participant per 0.25 s plus one at the cut-off;
--     state only for current participants; no log line per draft; no raise caused by a device
--     value.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (ThemedRoundReferee is written from this)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- RoundOutfitDraftKeeper.new(dependencies) -> roundOutfitDraftKeeper
--   One keeper per round: create it when the round's ThemeReveal begins. Raises when a
--   dependency is missing or of the wrong kind.
--   dependencies = {
--     roundId: string,   the round's own id (ThemedRoundClock RoundState.roundId), non-empty
--     clock: { getCurrentUnixMilliseconds: (self) -> number },   the SAME clock the limiter uses
--     scheduler: { scheduleCallbackAfterSeconds: (self, delaySeconds, callback) -> cancelCallback },
--     playerRequestRateLimiter: PlayerRequestRateLimiter   (only its two outfit draft methods are
--         used: readMillisecondsUntilOutfitDraftMayBeProcessed, recordOutfitDraftProcessed),
--     readAvailableStylingItemKeySet: () -> AvailableStylingItemKeySet,   called once per
--         validation, normally `function() return resolver:getAvailableStylingItemKeySet() end`
--     stylingItemByStylingItemKey: StylingItemByStylingItemKey,   the styling item pool lookup
--     sendRoundOutfitDraftAcknowledged: (playerUserId, acknowledgement) -> (),   sends to THAT
--         player's device only. Must not yield. The acknowledgement is a frozen table:
--         { roundId = <this round's id>, outfitDraftSequenceNumber, isKept: boolean,
--           rejectionReason: "OutfitInvalid"? }   (rejectionReason absent when kept)
--         A sender that raises is caught; the first failure of the round is logged as a warning.
--     logger: { logInformation: (self, message) -> (), logWarning: (self, message) -> () },
--     validateOutfit: optional, same signature as OutfitValidator.validateOutfit (the default);
--         tests pass a counting wrapper around the real validator.
--   }
--
-- Round lifecycle, in this order (each step raises when called out of order, except as noted):
-- keeper:startAcceptingOutfitDrafts()
--   Call when Styling begins. Before it, every draft is ignored (check 1). Raises unless the
--   keeper is still waiting for Styling.
-- keeper:cutOffOutfitDraftsAndFreezeFinalOutfits() -> { [playerUserId]: { stylingItemKey } }?
--   The §2.3 cut-off, ONE non-yielding step: drafts stop being accepted, then every waiting draft
--   is processed (ignoring the interval, in join order, recorded with the limiter) and
--   acknowledged, every timer is cancelled, and the final kept outfit of every current
--   participant is handed back, frozen (the map and each list). A participant with no kept draft
--   has the frozen empty list. Kept outfits are never re-validated, even if the available set
--   changed (audit question 10). Anything arriving later is ignored without acknowledgement.
--   Call it at the end of Styling, before anything reads the outfits. Runs once: every later
--   call, and any call after endRound, returns nil and does nothing. Also allowed before
--   startAcceptingOutfitDrafts (then nobody has a draft). Logs one information line per round.
--   A participant removed during the cut-off (for example by the sender) is skipped. When
--   processing one participant's waiting draft raises (a server dependency such as the
--   validator or the available-set read failed), that draft is dropped without acknowledgement,
--   their previous kept draft is handed back, the others are processed as usual, and one warning
--   per cut-off counts the failures.
-- keeper:endRound()
--   Drops all state and cancels every timer; afterwards drafts are ignored, removeParticipant
--   does nothing, addParticipant and startAcceptingOutfitDrafts raise, cut-off returns nil, and a
--   stale timer that still fires does nothing. Call it when the round's drafts are no longer
--   needed (at the latest when the next round begins). Calling it again does nothing.
-- keeper:isAcceptingOutfitDrafts() -> boolean
--   True from startAcceptingOutfitDrafts until the cut-off or endRound.
-- keeper:getRoundId() -> string
--
-- Participants:
-- keeper:addParticipant(playerUserId)
--   A clean state: empty kept outfit, highest processed 0, nothing waiting, nothing stored. Allowed
--   before the cut-off. Raises when the player is already a participant, after the cut-off or
--   after endRound. A player removed earlier this round may be added again and starts clean
--   (audit question 11 default; whether to allow that is the referee's decision).
-- keeper:removeParticipant(playerUserId)
--   Erases everything held for the player and cancels the timer: nothing is ever acknowledged or
--   handed back for them afterwards. Does nothing for a non-participant (a second "left"
--   notification is tolerated). Does NOT call limiter:forgetPlayer: ThemedRoundReferee's
--   removePlayerWhoLeftServer does that when the player leaves the server.
-- keeper:isParticipant(playerUserId) -> boolean
--
-- Drafts:
-- keeper:receiveOutfitDraftFromDevice(playerUserId, untrustedSetRoundOutfitDraftMessage)
--   Call for every arriving SetRoundOutfitDraft, WITHOUT the generic request rate limiter (§2.13:
--   drafts are coalesced, never refused). `playerUserId` is the server's identity of the sender;
--   the message may be any value and is never trusted. Returns nothing. Acknowledgements go out
--   through the injected sender, synchronously when the draft is processed or re-sent now, or
--   later from the draft's timer.
--
-- Reading (state is never exposed mutable; for the referee, tests and diagnostics):
-- keeper:readKeptOutfitStylingItemKeys(playerUserId) -> { stylingItemKey }?   frozen; nil for a
--   non-participant
-- keeper:readHighestProcessedOutfitDraftSequenceNumber(playerUserId) -> number?   nil for a
--   non-participant
-- keeper:countPendingOutfitDraftProcessingTimers() -> number   never more than the participants
-- keeper:countParticipants() -> number
--
-- RoundOutfitDraftKeeper.OUTFIT_DRAFT_REJECTION_REASON_OUTFIT_INVALID = "OutfitInvalid"
-- RoundOutfitDraftKeeper.ACKNOWLEDGEMENT_RESEND_MINIMUM_INTERVAL_MILLISECONDS = 250
-- RoundOutfitDraftKeeper.EMPTY_OUTFIT_STYLING_ITEM_KEYS = {} (frozen)
--
-- Every method that takes a playerUserId raises when it is not a number or is NaN.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local OutfitValidator = require("../shared/OutfitValidator")
local PlayerUserIdArgumentCheck = require("./PlayerUserIdArgumentCheck")
local RoundOutfitDraftKeeperDependencyCheck = require("./RoundOutfitDraftKeeperDependencyCheck")
local RoundOutfitDraftAcknowledgementOutbox = require("./RoundOutfitDraftAcknowledgementOutbox")
local RoundOutfitDraftParticipantState = require("./RoundOutfitDraftParticipantState")
local SetRoundOutfitDraftMessageReader = require("./SetRoundOutfitDraftMessageReader")

type ParticipantState = RoundOutfitDraftParticipantState.ParticipantState
type OutfitSnapshot = SetRoundOutfitDraftMessageReader.OutfitSnapshot

local RoundOutfitDraftKeeper = {}
RoundOutfitDraftKeeper.__index = RoundOutfitDraftKeeper

RoundOutfitDraftKeeper.OUTFIT_DRAFT_REJECTION_REASON_OUTFIT_INVALID =
	RoundOutfitDraftAcknowledgementOutbox.OUTFIT_DRAFT_REJECTION_REASON_OUTFIT_INVALID
RoundOutfitDraftKeeper.ACKNOWLEDGEMENT_RESEND_MINIMUM_INTERVAL_MILLISECONDS =
	RoundOutfitDraftAcknowledgementOutbox.ACKNOWLEDGEMENT_RESEND_MINIMUM_INTERVAL_MILLISECONDS
RoundOutfitDraftKeeper.EMPTY_OUTFIT_STYLING_ITEM_KEYS = RoundOutfitDraftParticipantState.EMPTY_OUTFIT_STYLING_ITEM_KEYS

local MILLISECONDS_PER_SECOND = 1000

local KEEPER_LIFECYCLE_STAGES = table.freeze({
	WaitingForStyling = "WaitingForStyling",
	AcceptingOutfitDrafts = "AcceptingOutfitDrafts",
	OutfitDraftsCutOff = "OutfitDraftsCutOff",
	RoundEnded = "RoundEnded",
})

local readOutfitDraftSequenceNumberForThisRound =
	SetRoundOutfitDraftMessageReader.readOutfitDraftSequenceNumberForThisRound
local takeBoundedOutfitStylingItemKeysSnapshot =
	SetRoundOutfitDraftMessageReader.takeBoundedOutfitStylingItemKeysSnapshot

local assertIsPlayerUserId = PlayerUserIdArgumentCheck.assertIsPlayerUserId
local CALLING_MODULE_NAME = "RoundOutfitDraftKeeper"

function RoundOutfitDraftKeeper.new(dependencies: any)
	RoundOutfitDraftKeeperDependencyCheck.assertKeeperDependenciesHaveTheirKinds(dependencies)
	return setmetatable({
		roundId = dependencies.roundId,
		scheduler = dependencies.scheduler,
		playerRequestRateLimiter = dependencies.playerRequestRateLimiter,
		readAvailableStylingItemKeySet = dependencies.readAvailableStylingItemKeySet,
		stylingItemByStylingItemKey = dependencies.stylingItemByStylingItemKey,
		logger = dependencies.logger,
		validateOutfit = dependencies.validateOutfit or OutfitValidator.validateOutfit,
		acknowledgementOutbox = RoundOutfitDraftAcknowledgementOutbox.new({
			roundId = dependencies.roundId,
			clock = dependencies.clock,
			sendRoundOutfitDraftAcknowledged = dependencies.sendRoundOutfitDraftAcknowledged,
			logger = dependencies.logger,
		}),
		keeperLifecycleStage = KEEPER_LIFECYCLE_STAGES.WaitingForStyling,
		participantStateByPlayerUserId = {} :: { [number]: ParticipantState },
		participantsAddedCount = 0,
	}, RoundOutfitDraftKeeper)
end

-- Check 4 and what follows: validate the private copy now, record the processing for the
-- interval, keep the copy when valid, store and send the acknowledgement.
local function processOutfitDraft(
	self,
	playerUserId: number,
	participantState: ParticipantState,
	outfitDraftSequenceNumber: number,
	outfitStylingItemKeysSnapshot: OutfitSnapshot
)
	local outfitValidationVerdict = self.validateOutfit(
		outfitStylingItemKeysSnapshot,
		self.stylingItemByStylingItemKey,
		self.readAvailableStylingItemKeySet()
	)
	self.playerRequestRateLimiter:recordOutfitDraftProcessed(playerUserId)
	participantState.highestProcessedOutfitDraftSequenceNumber = outfitDraftSequenceNumber
	local isKept = outfitValidationVerdict.isOutfitValid
	if isKept then
		participantState.keptOutfitStylingItemKeys = table.freeze(outfitStylingItemKeysSnapshot :: { any })
	end
	self.acknowledgementOutbox:storeAndSendFreshAcknowledgement(
		playerUserId,
		participantState,
		outfitDraftSequenceNumber,
		isKept
	)
end

-- Only called while a draft waits (a pending timer always has one; the cut-off checks first).
local function processWaitingOutfitDraft(self, playerUserId: number, participantState: ParticipantState)
	local waitingOutfitDraftSequenceNumber, waitingOutfitStylingItemKeysSnapshot =
		RoundOutfitDraftParticipantState.takeWaitingOutfitDraft(participantState)
	processOutfitDraft(
		self,
		playerUserId,
		participantState,
		waitingOutfitDraftSequenceNumber :: number,
		waitingOutfitStylingItemKeysSnapshot :: OutfitSnapshot
	)
end

local scheduleWaitingOutfitDraftProcessing

-- The waiting draft's timer. Does nothing unless it is still the participant's current timer.
-- Every way a timer stops mattering (a newer draft processed at once, removal, the cut-off,
-- endRound) goes through cancelPendingProcessingTimer, which forgets the token even when the
-- scheduler cannot really cancel, so this one comparison is the whole stale-timer guard.
local function runWaitingOutfitDraftProcessingTimer(
	self,
	playerUserId: number,
	participantState: ParticipantState,
	processingTimerToken: {}
)
	if participantState.pendingProcessingTimerToken ~= processingTimerToken then
		return
	end
	participantState.pendingProcessingTimerToken = nil
	participantState.cancelPendingProcessingTimer = nil
	local millisecondsUntilProcessingAllowed =
		self.playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(playerUserId)
	if millisecondsUntilProcessingAllowed > 0 then
		-- The scheduler ran early or the clock moved back: wait for the rest, still one timer.
		scheduleWaitingOutfitDraftProcessing(self, playerUserId, participantState, millisecondsUntilProcessingAllowed)
		return
	end
	processWaitingOutfitDraft(self, playerUserId, participantState)
end

function scheduleWaitingOutfitDraftProcessing(
	self,
	playerUserId: number,
	participantState: ParticipantState,
	delayMilliseconds: number
)
	local processingTimerToken = {}
	participantState.pendingProcessingTimerToken = processingTimerToken
	participantState.cancelPendingProcessingTimer = self.scheduler:scheduleCallbackAfterSeconds(
		delayMilliseconds / MILLISECONDS_PER_SECOND,
		function()
			runWaitingOutfitDraftProcessingTimer(self, playerUserId, participantState, processingTimerToken)
		end
	)
end

function RoundOutfitDraftKeeper.receiveOutfitDraftFromDevice(
	self,
	playerUserId: number,
	untrustedSetRoundOutfitDraftMessage: any
)
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	-- Check 1: drafts accepted now, a participant, this round, a legal number.
	if self.keeperLifecycleStage ~= KEEPER_LIFECYCLE_STAGES.AcceptingOutfitDrafts then
		return
	end
	local participantState = self.participantStateByPlayerUserId[playerUserId]
	if participantState == nil then
		return
	end
	local outfitDraftSequenceNumber =
		readOutfitDraftSequenceNumberForThisRound(untrustedSetRoundOutfitDraftMessage, self.roundId)
	if outfitDraftSequenceNumber == nil then
		return
	end

	-- Check 2: not higher than the highest processed number (so one was processed: legal
	-- numbers start at 1 and the highest starts at 0).
	if outfitDraftSequenceNumber <= participantState.highestProcessedOutfitDraftSequenceNumber then
		self.acknowledgementOutbox:resendStoredAcknowledgementAndRecordResendTimeWhenAllowed(
			playerUserId,
			participantState
		)
		return
	end

	-- Check 3: only a strictly higher number replaces the waiting draft.
	local waitingOutfitDraftSequenceNumber = participantState.waitingOutfitDraftSequenceNumber
	if waitingOutfitDraftSequenceNumber ~= nil and outfitDraftSequenceNumber <= waitingOutfitDraftSequenceNumber then
		return
	end

	local outfitStylingItemKeysSnapshot = takeBoundedOutfitStylingItemKeysSnapshot(untrustedSetRoundOutfitDraftMessage)
	local millisecondsUntilProcessingAllowed =
		self.playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(playerUserId)
	if millisecondsUntilProcessingAllowed > 0 then
		RoundOutfitDraftParticipantState.putOutfitDraftInWaitingPlace(
			participantState,
			outfitDraftSequenceNumber,
			outfitStylingItemKeysSnapshot
		)
		if participantState.pendingProcessingTimerToken == nil then
			scheduleWaitingOutfitDraftProcessing(
				self,
				playerUserId,
				participantState,
				millisecondsUntilProcessingAllowed
			)
		end
		return
	end

	-- The interval has passed: this newer draft supersedes any waiting one, which is discarded.
	RoundOutfitDraftParticipantState.cancelPendingProcessingTimer(participantState)
	RoundOutfitDraftParticipantState.takeWaitingOutfitDraft(participantState)
	processOutfitDraft(self, playerUserId, participantState, outfitDraftSequenceNumber, outfitStylingItemKeysSnapshot)
end

local function raiseForCallInWrongStage(self, methodName: string)
	error(
		string.format(
			"RoundOutfitDraftKeeper: %s called in stage %s of round %s",
			methodName,
			self.keeperLifecycleStage,
			self.roundId
		),
		3
	)
end

local function isBeforeCutOff(self): boolean
	return self.keeperLifecycleStage == KEEPER_LIFECYCLE_STAGES.WaitingForStyling
		or self.keeperLifecycleStage == KEEPER_LIFECYCLE_STAGES.AcceptingOutfitDrafts
end

function RoundOutfitDraftKeeper.startAcceptingOutfitDrafts(self)
	if self.keeperLifecycleStage ~= KEEPER_LIFECYCLE_STAGES.WaitingForStyling then
		raiseForCallInWrongStage(self, "startAcceptingOutfitDrafts")
	end
	self.keeperLifecycleStage = KEEPER_LIFECYCLE_STAGES.AcceptingOutfitDrafts
end

function RoundOutfitDraftKeeper.isAcceptingOutfitDrafts(self): boolean
	return self.keeperLifecycleStage == KEEPER_LIFECYCLE_STAGES.AcceptingOutfitDrafts
end

function RoundOutfitDraftKeeper.getRoundId(self): string
	return self.roundId
end

function RoundOutfitDraftKeeper.cutOffOutfitDraftsAndFreezeFinalOutfits(self): { [number]: { string } }?
	if not isBeforeCutOff(self) then
		return nil
	end
	-- Stop accepting first, so nothing (not even a sender that calls back in) slips in.
	self.keeperLifecycleStage = KEEPER_LIFECYCLE_STAGES.OutfitDraftsCutOff

	local waitingOutfitDraftsProcessedCount, waitingOutfitDraftFlushFailureCount = 0, 0
	for _, participant in
		RoundOutfitDraftParticipantState.listParticipantsInJoinOrder(self.participantStateByPlayerUserId)
	do
		local playerUserId, participantState = participant.playerUserId, participant.participantState
		-- Skipped when a sender removed this participant earlier in this loop.
		if self.participantStateByPlayerUserId[playerUserId] == participantState then
			RoundOutfitDraftParticipantState.cancelPendingProcessingTimer(participantState)
			if participantState.waitingOutfitDraftSequenceNumber ~= nil then
				waitingOutfitDraftsProcessedCount += 1
				-- A raising server dependency (validator, available set, limiter) costs only this
				-- participant's waiting draft: their previous kept draft stays and everyone else
				-- is still flushed and handed back.
				if not pcall(processWaitingOutfitDraft, self, playerUserId, participantState) then
					waitingOutfitDraftFlushFailureCount += 1
				end
			end
		end
	end
	if waitingOutfitDraftFlushFailureCount > 0 then
		self.logger:logWarning(
			string.format(
				"RoundOutfitDraftKeeper: %d waiting drafts of round %s raised at the cut-off; their previous kept drafts stay",
				waitingOutfitDraftFlushFailureCount,
				self.roundId
			)
		)
	end

	local finalOutfitStylingItemKeysByPlayerUserId = {}
	local finalOutfitCount = 0
	for playerUserId, participantState in self.participantStateByPlayerUserId do
		finalOutfitStylingItemKeysByPlayerUserId[playerUserId] = participantState.keptOutfitStylingItemKeys
		finalOutfitCount += 1
	end
	self.logger:logInformation(
		string.format(
			"RoundOutfitDraftKeeper: outfit drafts of round %s cut off with %d participants; %d waiting drafts processed",
			self.roundId,
			finalOutfitCount,
			waitingOutfitDraftsProcessedCount
		)
	)
	return table.freeze(finalOutfitStylingItemKeysByPlayerUserId)
end

function RoundOutfitDraftKeeper.endRound(self)
	for _, participantState in self.participantStateByPlayerUserId do
		RoundOutfitDraftParticipantState.cancelPendingProcessingTimer(participantState)
	end
	table.clear(self.participantStateByPlayerUserId)
	self.keeperLifecycleStage = KEEPER_LIFECYCLE_STAGES.RoundEnded
end

function RoundOutfitDraftKeeper.addParticipant(self, playerUserId: number)
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	if not isBeforeCutOff(self) then
		raiseForCallInWrongStage(self, "addParticipant")
	end
	if self.participantStateByPlayerUserId[playerUserId] ~= nil then
		error(string.format("RoundOutfitDraftKeeper: player %d is already a participant", playerUserId), 2)
	end
	self.participantsAddedCount += 1
	self.participantStateByPlayerUserId[playerUserId] =
		RoundOutfitDraftParticipantState.createCleanParticipantState(self.participantsAddedCount)
end

function RoundOutfitDraftKeeper.removeParticipant(self, playerUserId: number)
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	local participantState = self.participantStateByPlayerUserId[playerUserId]
	if participantState == nil then
		return
	end
	RoundOutfitDraftParticipantState.cancelPendingProcessingTimer(participantState)
	self.participantStateByPlayerUserId[playerUserId] = nil
end

function RoundOutfitDraftKeeper.isParticipant(self, playerUserId: number): boolean
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	return self.participantStateByPlayerUserId[playerUserId] ~= nil
end

function RoundOutfitDraftKeeper.readKeptOutfitStylingItemKeys(self, playerUserId: number): { string }?
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	local participantState = self.participantStateByPlayerUserId[playerUserId]
	return if participantState then participantState.keptOutfitStylingItemKeys else nil
end

function RoundOutfitDraftKeeper.readHighestProcessedOutfitDraftSequenceNumber(self, playerUserId: number): number?
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	local participantState = self.participantStateByPlayerUserId[playerUserId]
	return if participantState then participantState.highestProcessedOutfitDraftSequenceNumber else nil
end

function RoundOutfitDraftKeeper.countPendingOutfitDraftProcessingTimers(self): number
	local pendingTimerCount = 0
	for _, participantState in self.participantStateByPlayerUserId do
		if participantState.pendingProcessingTimerToken ~= nil then
			pendingTimerCount += 1
		end
	end
	return pendingTimerCount
end

function RoundOutfitDraftKeeper.countParticipants(self): number
	local participantCount = 0
	for _ in self.participantStateByPlayerUserId do
		participantCount += 1
	end
	return participantCount
end

return table.freeze(RoundOutfitDraftKeeper)
