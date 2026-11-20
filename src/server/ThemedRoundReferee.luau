-- ThemedRoundReferee (development spec v1.3 §0.2, §2.1–§2.5, §2.13, §3.3, §3.4): runs the
-- themed round on the server side. It follows ThemedRoundClock's phases and decides who takes
-- part, routes outfit drafts to the round's RoundOutfitDraftKeeper, cuts drafts off and scores
-- each final outfit once at the end of Styling, grants rewards through RewardLedger and
-- publishes the results at the start of Results.
--
-- 🔴 It never accepts a score, star count or reward amount from a device (§3.3): a device sends
-- only a join request (its arguments are ignored) and drafts (handed to the draft keeper as
-- untrusted values). Calls no Roblox-specific interface; everything external is injected.
-- Parts: RefereedThemedRound (one round's state: ThemedRoundParticipantRoster,
-- ThemedRoundFinalOutfitScorer, ThemedRoundRewardSettlement), ThemedRoundJoinRequestDecision,
-- ThemedRoundOwnerDecisions, ThemedRoundRefereeDependencyCheck.
--
-- What happens at each phase change (inside the clock's phase change, so the end of Styling and
-- the start of Showcase are one step), and then RoundStateChanged is sent to every device:
--   ThemeReveal  the previous round's draft keeper is ended; a new round starts with no
--                participants and a new draft keeper. Last round's published results are dropped.
--                Only for the clock's current round: a late ThemeReveal of another round changes
--                nothing (like a late notification of any other phase).
--   Styling      the draft keeper starts accepting drafts.
--   Showcase     FIRST the draft cut-off (waiting drafts processed and acknowledged), THEN each
--                remaining participant's final outfit is scored once against the round's theme
--                and bonus rule, frozen, and given a stage place in join order.
--   Results      rewards are granted (ThemedRoundRewardSettlement), then RoundResultsPublished is
--                sent exactly once, built from what the ledger actually applied. A player the
--                ledger answers "SaveDataNotLoaded" for is treated as left (audit question 18).
--   A phase change for a round this referee does not run (for example the round that was in
--   progress when the referee was created) only sends RoundStateChanged with no participants.
--   A step that raises (a server dependency failed) is logged as a warning and RoundStateChanged
--   is still sent; the cut-off, scoring and grants are also isolated per participant inside.
-- Leaving: a player leaving the server, and the save keeper's session-ended event for any
-- reason, both remove the player from the round at once: no score, no entry, no reward (audit
-- questions 11, 12, 17). Both may arrive, in either order. A reward already granted stays.
-- Shutdown (audit question 24, see ThemedRoundOwnerDecisions): after beginServerShutdown no
-- join is accepted, no draft is taken, nothing is scored, granted or published, and phase
-- changes are ignored.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (the server wiring and the character dresser are written from this)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- ThemedRoundReferee.new(dependencies) -> referee
--   Subscribes at once to the clock's phase changes and to the save keeper's session-ended
--   event, so create it BEFORE themedRoundClock:startRoundCycle(). Raises when a dependency is
--   missing or of the wrong kind.
--   dependencies = {
--     clock: { getCurrentUnixMilliseconds: (self) -> number },   the SAME clock the rate limiter uses
--     scheduler: { scheduleCallbackAfterSeconds: (self, delaySeconds, callback) -> cancelCallback },
--     themedRoundClock: ThemedRoundClock   (subscribeToRoundPhaseChanged, readCurrentRoundState)
--     playerRequestRateLimiter: PlayerRequestRateLimiter   (admitOrRefusePlayerRequest for joins,
--         the two outfit draft methods through the draft keeper, forgetPlayer on leaving)
--     rewardLedger: RewardLedger   (grantThemedRoundReward only)
--     playerSaveDataKeeper: PlayerSaveDataKeeper   (isPlayerSaveDataLoaded,
--         subscribeToPlayerSaveDataSessionEnded)
--     marketplaceStylingItemResolver: { isWardrobeCatalogReady: (self) -> boolean,
--         getAvailableStylingItemKeySet: (self) -> AvailableStylingItemKeySet }
--     stylingItemByStylingItemKey: the styling item pool lookup
--     findThemeByThemeId: (themeId) -> Theme?,   normally ThemeCatalog.findThemeByThemeId
--     sendRoundStateChangedToEveryDevice: (roundStateChangedMessage) -> (),
--     sendRoundResultsPublishedToEveryDevice: (roundResultsPublishedMessage) -> (),
--     sendRoundOutfitDraftAcknowledged: (playerUserId, acknowledgement) -> (),   to that device
--         only; must not yield (see RoundOutfitDraftKeeper)
--     readPlayerDisplayName: (playerUserId) -> string,
--     logger: { logInformation: (self, message) -> (), logWarning: (self, message) -> () },
--     validateOutfit: optional, passed to each draft keeper (default OutfitValidator.validateOutfit)
--     ownerDecisions: optional, ThemedRoundOwnerDecisions shape (default DEFAULT_OWNER_DECISIONS)
--     createRoundOutfitDraftKeeper: optional (keeperDependencies) -> keeper, default
--         RoundOutfitDraftKeeper.new (tests wrap it)
--   }
--   A sender that raises is caught and logged as a warning; it never stops the referee's work.
--
-- Device requests (playerUserId is the server's identity of the sender; every method that takes
-- one raises when it is not a number or is NaN, a server wiring error):
-- referee:admitOrRejectJoinCurrentRoundRequest(playerUserId) -> answer
--   NOT a pure question: it records the request with the limiter and, when accepted, adds the
--   participant. The wiring may pass whatever the device sent after playerUserId; it is never
--   read. Asks PlayerRequestRateLimiter:admitOrRefusePlayerRequest FIRST, then answers per
--   ThemedRoundJoinRequestDecision: { isAccepted = true } or { isAccepted = false,
--   rejectionReason }, a fresh frozen table. The window is measured at arrival in milliseconds
--   (§2.2). Accepted: the player becomes a participant of the current round with a clean draft
--   state. A rejected join changes nothing in the round. After shutdown, an unrefereed round
--   or a stopped clock: RoundNotJoinableNow. A player who left this round is accepted again
--   only when ownerDecisions.isRejoiningSameRoundAfterLeavingAllowed (else RoundNotJoinableNow).
-- referee:receiveSetRoundOutfitDraftFromDevice(playerUserId, untrustedSetRoundOutfitDraftMessage)
--   Call for every SetRoundOutfitDraft, WITHOUT admitOrRefusePlayerRequest (§2.13). Handed to
--   the round's draft keeper only when the sender is a participant of the round the referee runs,
--   that round is still the clock's current round, and shutdown has not begun; otherwise
--   ignored without acknowledgement. Returns nothing.
--
-- Players:
-- referee:removePlayerWhoLeftServer(playerUserId)
--   Call when a player leaves the server. Removes them from the current round (as above) and
--   calls playerRequestRateLimiter:forgetPlayer. Harmless for a non-participant or a repeat.
--   (The session-ended event is subscribed in `new` and needs no wiring.)
--
-- Shutdown:
-- referee:beginServerShutdown()
--   Call when the server starts shutting down. Ends the current draft keeper (no timer fires
--   afterwards). With the default owner decision an unsettled round is forfeited; otherwise a
--   round already scored is settled and published first. Calling it again does nothing.
-- referee:isServerShuttingDown() -> boolean
--
-- Reads (never change anything):
-- referee:readRoundStateChangedMessage() -> RoundStateChangedMessage?
--   §2.1, for a player who has just joined the server: { roundId, roundPhase,
--   phaseEndsAtUnixMilliseconds, themeId, roundBonusRule, participantUserIds } (frozen). nil
--   while the clock is not running. The same message the referee broadcasts at each phase change.
-- referee:isParticipantOfCurrentRound(playerUserId) -> boolean
-- referee:listCurrentRoundParticipantUserIds() -> { number }   frozen, in join order (audit q. 15)
--   Both, like every read below, answer only for the clock's current round: once the clock has
--   moved past the round the referee runs (after shutdown), false and the empty list.
-- referee:readShowcaseStageEntry(playerUserId) -> ShowcaseStageEntry?
--   During Showcase, for a current participant who was scored: frozen { stagePlaceNumber,
--   scoredOutfitStylingItemKeys (frozen), outfitScore }. nil otherwise. Stage places are given
--   once at the start of Showcase and never change when someone leaves.
-- referee:readCharacterSpawnRoundFacts(playerUserId) -> CharacterSpawnRoundFacts
--   For CharacterSpawnAppearanceDecider: frozen { roundPhase: string?, isParticipant: boolean,
--   showcaseStageEntry: ShowcaseStageEntry? } as of now.
-- referee:readLastPublishedRoundResults() -> RoundResultsPublishedMessage?
--   The frozen { roundId, roundResults } sent at the start of this round's Results; nil before
--   that and from the next ThemeReveal on.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local PlayerUserIdArgumentCheck = require("./PlayerUserIdArgumentCheck")
local RemoteNames = require("../shared/RemoteNames")
local RefereedThemedRound = require("./RefereedThemedRound")
local RoundOutfitDraftKeeper = require("./RoundOutfitDraftKeeper")
local ThemedRoundJoinRequestDecision = require("./ThemedRoundJoinRequestDecision")
local ThemedRoundOwnerDecisions = require("./ThemedRoundOwnerDecisions")
local ThemedRoundRefereeDependencyCheck = require("./ThemedRoundRefereeDependencyCheck")
local ThemedRoundProtocol = require("../shared/ThemedRoundProtocol")

local ROUND_PHASES = ThemedRoundProtocol.ROUND_PHASES
local REQUEST_JOIN_CURRENT_ROUND_CHANNEL_NAME = RemoteNames.REMOTE_CHANNEL_NAMES.RequestJoinCurrentRound
local EMPTY_PARTICIPANT_USER_IDS = table.freeze({})
local assertIsPlayerUserId = PlayerUserIdArgumentCheck.assertIsPlayerUserId
local CALLING_MODULE_NAME = "ThemedRoundReferee"

local ThemedRoundReferee = {}
ThemedRoundReferee.__index = ThemedRoundReferee

-- Calls a device sender; a raise is logged and contained.
local function sendThroughContainedSender(self, senderName: string, ...)
	local didSend, sendError = pcall(self[senderName], ...)
	if not didSend then
		self.logger:logWarning(string.format("ThemedRoundReferee: %s failed: %s", senderName, tostring(sendError)))
	end
end

-- The round this referee runs, when it is also the clock's current round.
local function findRefereedRoundMatchingClock(self)
	local clockRoundState = self.themedRoundClock:readCurrentRoundState()
	local refereedRound = self.currentRefereedRound
	if clockRoundState == nil or refereedRound == nil or refereedRound.roundId ~= clockRoundState.roundId then
		return nil, clockRoundState
	end
	return refereedRound, clockRoundState
end

-- ── phase changes ───────────────────────────────────────────────────────────────────────────

local function beginRefereeingNewRound(self, roundState)
	local previousRefereedRound = self.currentRefereedRound
	if previousRefereedRound ~= nil and previousRefereedRound.roundId == roundState.roundId then
		return -- the same ThemeReveal delivered twice
	end
	if previousRefereedRound ~= nil then
		previousRefereedRound:endOutfitDrafts()
	end
	self.currentRefereedRound = nil
	self.lastPublishedRoundResultsMessage = nil

	local theme = self.findThemeByThemeId(roundState.themeId)
	if theme == nil then
		self.logger:logWarning(
			string.format(
				"ThemedRoundReferee: round %s is not refereed: theme %s is not in the theme catalog",
				roundState.roundId,
				tostring(roundState.themeId)
			)
		)
		return
	end
	self.currentRefereedRound = RefereedThemedRound.new({
		roundId = roundState.roundId,
		themeId = roundState.themeId,
		theme = theme,
		roundBonusRule = roundState.roundBonusRule,
		stylingItemByStylingItemKey = self.stylingItemByStylingItemKey,
		logger = self.logger,
		roundOutfitDraftKeeper = self.createRoundOutfitDraftKeeper({
			roundId = roundState.roundId,
			clock = self.clock,
			scheduler = self.scheduler,
			playerRequestRateLimiter = self.playerRequestRateLimiter,
			readAvailableStylingItemKeySet = function()
				return self.marketplaceStylingItemResolver:getAvailableStylingItemKeySet()
			end,
			stylingItemByStylingItemKey = self.stylingItemByStylingItemKey,
			sendRoundOutfitDraftAcknowledged = self.sendRoundOutfitDraftAcknowledged,
			logger = self.logger,
			validateOutfit = self.validateOutfit,
		}),
	})
end

local function settleRoundAndPublishResults(self, refereedRound)
	local roundResults = refereedRound:settleRewardsOnce({
		rewardLedger = self.rewardLedger,
		readPlayerDisplayName = self.readPlayerDisplayName,
		ownerDecisions = self.ownerDecisions,
		logger = self.logger,
	})
	if roundResults == nil then
		return -- at most one settlement and one publication per round
	end
	local roundResultsPublishedMessage = table.freeze({
		roundId = refereedRound.roundId,
		roundResults = roundResults,
	})
	self.lastPublishedRoundResultsMessage = roundResultsPublishedMessage
	sendThroughContainedSender(self, "sendRoundResultsPublishedToEveryDevice", roundResultsPublishedMessage)
end

local function buildRoundStateChangedMessage(self, roundState)
	local refereedRound = self.currentRefereedRound
	local participantUserIds = if refereedRound ~= nil and refereedRound.roundId == roundState.roundId
		then refereedRound:listParticipantUserIdsInJoinOrder()
		else EMPTY_PARTICIPANT_USER_IDS
	return table.freeze({
		roundId = roundState.roundId,
		roundPhase = roundState.roundPhase,
		phaseEndsAtUnixMilliseconds = roundState.phaseEndsAtUnixMilliseconds,
		themeId = roundState.themeId,
		roundBonusRule = roundState.roundBonusRule,
		participantUserIds = participantUserIds,
	})
end

-- The referee's own step for one phase change (everything except the broadcast).
local function runRoundPhaseStep(self, roundState)
	local roundPhase = roundState.roundPhase
	local refereedRound = self.currentRefereedRound
	if roundPhase == ROUND_PHASES.ThemeReveal then
		local clockRoundState = self.themedRoundClock:readCurrentRoundState()
		-- A late ThemeReveal of a round that is no longer the clock's must not replace the round
		-- in progress (the same guard the other phases get from the roundId comparison below).
		if clockRoundState ~= nil and clockRoundState.roundId == roundState.roundId then
			beginRefereeingNewRound(self, roundState)
		end
	elseif refereedRound ~= nil and refereedRound.roundId == roundState.roundId then
		if roundPhase == ROUND_PHASES.Styling then
			refereedRound:startAcceptingOutfitDraftsOnce()
		elseif roundPhase == ROUND_PHASES.Showcase then
			refereedRound:cutOffDraftsAndScoreFinalOutfitsOnce()
		elseif roundPhase == ROUND_PHASES.Results then
			settleRoundAndPublishResults(self, refereedRound)
		end
	end
end

local function refereeRoundPhaseChange(self, roundState)
	if self.isShutdownBegun then
		return
	end
	local didRunStep, stepError = pcall(runRoundPhaseStep, self, roundState)
	if not didRunStep then
		self.logger:logWarning(
			string.format(
				"ThemedRoundReferee: the %s step of round %s raised: %s",
				tostring(roundState.roundPhase),
				tostring(roundState.roundId),
				tostring(stepError)
			)
		)
	end
	sendThroughContainedSender(
		self,
		"sendRoundStateChangedToEveryDevice",
		buildRoundStateChangedMessage(self, roundState)
	)
end

local function removePlayerFromCurrentRound(self, playerUserId: number)
	local refereedRound = self.currentRefereedRound
	if refereedRound ~= nil then
		refereedRound:removeParticipant(playerUserId)
	end
end

function ThemedRoundReferee.new(dependencies)
	ThemedRoundRefereeDependencyCheck.assertRefereeDependenciesHaveTheirKinds(dependencies)
	local self = setmetatable({
		clock = dependencies.clock,
		scheduler = dependencies.scheduler,
		themedRoundClock = dependencies.themedRoundClock,
		playerRequestRateLimiter = dependencies.playerRequestRateLimiter,
		rewardLedger = dependencies.rewardLedger,
		playerSaveDataKeeper = dependencies.playerSaveDataKeeper,
		marketplaceStylingItemResolver = dependencies.marketplaceStylingItemResolver,
		stylingItemByStylingItemKey = dependencies.stylingItemByStylingItemKey,
		findThemeByThemeId = dependencies.findThemeByThemeId,
		sendRoundStateChangedToEveryDevice = dependencies.sendRoundStateChangedToEveryDevice,
		sendRoundResultsPublishedToEveryDevice = dependencies.sendRoundResultsPublishedToEveryDevice,
		sendRoundOutfitDraftAcknowledged = dependencies.sendRoundOutfitDraftAcknowledged,
		readPlayerDisplayName = dependencies.readPlayerDisplayName,
		logger = dependencies.logger,
		validateOutfit = dependencies.validateOutfit,
		ownerDecisions = dependencies.ownerDecisions or ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS,
		createRoundOutfitDraftKeeper = dependencies.createRoundOutfitDraftKeeper or RoundOutfitDraftKeeper.new,

		currentRefereedRound = nil,
		lastPublishedRoundResultsMessage = nil,
		isShutdownBegun = false,
	}, ThemedRoundReferee)

	self.themedRoundClock:subscribeToRoundPhaseChanged(function(roundState)
		refereeRoundPhaseChange(self, roundState)
	end)
	self.playerSaveDataKeeper:subscribeToPlayerSaveDataSessionEnded(function(playerUserId)
		removePlayerFromCurrentRound(self, playerUserId)
	end)
	return self
end

-- ── device requests ─────────────────────────────────────────────────────────────────────────

function ThemedRoundReferee:admitOrRejectJoinCurrentRoundRequest(playerUserId: number)
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	local rateLimitDecision =
		self.playerRequestRateLimiter:admitOrRefusePlayerRequest(playerUserId, REQUEST_JOIN_CURRENT_ROUND_CHANNEL_NAME)
	local refereedRound, clockRoundState = findRefereedRoundMatchingClock(self)
	local isRoundJoinableNow = not self.isShutdownBegun
		and refereedRound ~= nil
		and ThemedRoundJoinRequestDecision.isRoundPhaseOpenForJoining(
			clockRoundState.roundPhase,
			clockRoundState.phaseEndsAtUnixMilliseconds,
			self.clock:getCurrentUnixMilliseconds()
		)
		and (
			self.ownerDecisions.isRejoiningSameRoundAfterLeavingAllowed
			or not refereedRound:hasLeftThisRound(playerUserId)
		)
	local joinAnswer = ThemedRoundJoinRequestDecision.decideJoinCurrentRoundAnswer({
		isAdmittedByRateLimiter = rateLimitDecision.isRequestAllowed == true,
		isAlreadyParticipating = refereedRound ~= nil and refereedRound:isParticipant(playerUserId),
		isPlayerSaveDataLoaded = self.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId),
		isWardrobeCatalogReady = self.marketplaceStylingItemResolver:isWardrobeCatalogReady(),
		isRoundJoinableNow = isRoundJoinableNow,
	})
	if joinAnswer.isAccepted then
		refereedRound:addParticipant(playerUserId)
	end
	return joinAnswer
end

function ThemedRoundReferee:receiveSetRoundOutfitDraftFromDevice(
	playerUserId: number,
	untrustedSetRoundOutfitDraftMessage: any
)
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	local refereedRound = findRefereedRoundMatchingClock(self)
	if self.isShutdownBegun or refereedRound == nil then
		return
	end
	refereedRound:receiveOutfitDraftFromParticipant(playerUserId, untrustedSetRoundOutfitDraftMessage)
end

-- ── players and shutdown ────────────────────────────────────────────────────────────────────

function ThemedRoundReferee:removePlayerWhoLeftServer(playerUserId: number)
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	removePlayerFromCurrentRound(self, playerUserId)
	self.playerRequestRateLimiter:forgetPlayer(playerUserId)
end

function ThemedRoundReferee:beginServerShutdown()
	if self.isShutdownBegun then
		return
	end
	local refereedRound = self.currentRefereedRound
	if
		refereedRound ~= nil
		and not self.ownerDecisions.shouldForfeitUnsettledRoundAtServerShutdown
		and refereedRound:hasBeenScored()
	then
		settleRoundAndPublishResults(self, refereedRound)
	end
	self.isShutdownBegun = true
	if refereedRound ~= nil then
		refereedRound:endOutfitDrafts()
	end
	self.logger:logInformation(
		string.format(
			"ThemedRoundReferee: server shutdown began during round %s; no further joins, drafts, scores or rewards",
			if refereedRound then refereedRound.roundId else "(none)"
		)
	)
end

function ThemedRoundReferee:isServerShuttingDown(): boolean
	return self.isShutdownBegun
end

-- ── reads ───────────────────────────────────────────────────────────────────────────────────

function ThemedRoundReferee:readRoundStateChangedMessage()
	local clockRoundState = self.themedRoundClock:readCurrentRoundState()
	if clockRoundState == nil then
		return nil
	end
	return buildRoundStateChangedMessage(self, clockRoundState)
end

function ThemedRoundReferee:isParticipantOfCurrentRound(playerUserId: number): boolean
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	local refereedRound = findRefereedRoundMatchingClock(self)
	return refereedRound ~= nil and refereedRound:isParticipant(playerUserId)
end

function ThemedRoundReferee:listCurrentRoundParticipantUserIds(): { number }
	local refereedRound = findRefereedRoundMatchingClock(self)
	if refereedRound == nil then
		return EMPTY_PARTICIPANT_USER_IDS
	end
	return refereedRound:listParticipantUserIdsInJoinOrder()
end

function ThemedRoundReferee:readShowcaseStageEntry(playerUserId: number)
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	local refereedRound, clockRoundState = findRefereedRoundMatchingClock(self)
	if refereedRound == nil or clockRoundState.roundPhase ~= ROUND_PHASES.Showcase then
		return nil
	end
	local scoredParticipant = refereedRound:readScoredParticipantStillPresent(playerUserId)
	if scoredParticipant == nil then
		return nil
	end
	return table.freeze({
		stagePlaceNumber = scoredParticipant.stagePlaceNumber,
		scoredOutfitStylingItemKeys = scoredParticipant.scoredOutfitStylingItemKeys,
		outfitScore = scoredParticipant.outfitScoreBreakdown.outfitScore,
	})
end

function ThemedRoundReferee:readCharacterSpawnRoundFacts(playerUserId: number)
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	local refereedRound, clockRoundState = findRefereedRoundMatchingClock(self)
	return table.freeze({
		roundPhase = if clockRoundState then clockRoundState.roundPhase else nil,
		isParticipant = refereedRound ~= nil and refereedRound:isParticipant(playerUserId),
		showcaseStageEntry = self:readShowcaseStageEntry(playerUserId),
	})
end

function ThemedRoundReferee:readLastPublishedRoundResults()
	return self.lastPublishedRoundResultsMessage
end

return table.freeze(ThemedRoundReferee)
