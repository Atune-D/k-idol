-- RefereedThemedRound: everything ThemedRoundReferee holds for ONE round, from its ThemeReveal to
-- the next round's ThemeReveal (development spec v1.3 §2.2–§2.5): the participants in join
-- order, the round's RoundOutfitDraftKeeper, the frozen scores and stage places, and the
-- settlement markers. The referee creates one per round and decides WHEN each step runs; this
-- module makes each step safe to run once only.
-- Calls no Roblox-specific interface; the draft keeper, ledger and senders are passed in.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (ThemedRoundReferee only)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- RefereedThemedRound.new(refereedThemedRoundDependencies) -> refereedRound
--   refereedThemedRoundDependencies = {
--     roundId: string, themeId: string, theme: Theme, roundBonusRule: RoundBonusRule,
--     roundOutfitDraftKeeper: RoundOutfitDraftKeeper   (created for this round),
--     stylingItemByStylingItemKey,
--     logger: { logInformation, logWarning },
--   }
-- refereedRound.roundId, refereedRound.themeId   read-only fields
--
-- Participants (the roster and the draft keeper always change together):
-- refereedRound:addParticipant(playerUserId)
-- refereedRound:removeParticipant(playerUserId) -> wasParticipant
--   Also drops the player's score (no entry, no reward); the stage places of others stay.
-- refereedRound:isParticipant(playerUserId) -> boolean
-- refereedRound:hasLeftThisRound(playerUserId) -> boolean
-- refereedRound:listParticipantUserIdsInJoinOrder() -> { number }   fresh, frozen
--
-- Steps, each effective once:
-- refereedRound:startAcceptingOutfitDraftsOnce()                   at Styling
-- refereedRound:receiveOutfitDraftFromParticipant(playerUserId, untrustedMessage)
--   Handed to the draft keeper only for a current participant; ignored otherwise.
-- refereedRound:cutOffDraftsAndScoreFinalOutfitsOnce()             at Showcase: cut-off FIRST,
--   then ThemedRoundFinalOutfitScorer over the participants still listed, in join order. A
--   participant whose scoring raised is not scored (no stage place, entry or reward) and one
--   warning names them; the others are scored as usual.
-- refereedRound:hasBeenScored() -> boolean
-- refereedRound:readScoredParticipantStillPresent(playerUserId) -> ScoredParticipant?
-- refereedRound:settleRewardsOnce(roundRewardSettlementDependencies) -> roundResults?
--   At Results. roundRewardSettlementDependencies = { rewardLedger, readPlayerDisplayName,
--   ownerDecisions, logger }. Returns the sorted roundResults list (see
--   ThemedRoundRewardSettlement) the first time, nil on every later call. A round never scored
--   settles with an empty list. A player the ledger answered "SaveDataNotLoaded" for is removed
--   from the round (as removeParticipant) before this returns, so nothing built afterwards
--   lists them (audit question 18: treat as left).
-- refereedRound:endOutfitDrafts()   the draft keeper's endRound (no timer fires afterwards)
-- ════════════════════════════════════════════════════════════════════════════════════════════

local ThemedRoundFinalOutfitScorer = require("./ThemedRoundFinalOutfitScorer")
local ThemedRoundParticipantRoster = require("./ThemedRoundParticipantRoster")
local ThemedRoundRewardSettlement = require("./ThemedRoundRewardSettlement")

local RefereedThemedRound = {}
RefereedThemedRound.__index = RefereedThemedRound

function RefereedThemedRound.new(refereedThemedRoundDependencies)
	return setmetatable({
		roundId = refereedThemedRoundDependencies.roundId,
		themeId = refereedThemedRoundDependencies.themeId,
		theme = refereedThemedRoundDependencies.theme,
		roundBonusRule = refereedThemedRoundDependencies.roundBonusRule,
		roundOutfitDraftKeeper = refereedThemedRoundDependencies.roundOutfitDraftKeeper,
		stylingItemByStylingItemKey = refereedThemedRoundDependencies.stylingItemByStylingItemKey,
		logger = refereedThemedRoundDependencies.logger,
		participantRoster = ThemedRoundParticipantRoster.new(),
		hasStylingStarted = false,
		-- Set at the cut-off: every scored participant, in stage place order.
		scoredParticipantsInStagePlaceOrder = nil :: { ThemedRoundFinalOutfitScorer.ScoredParticipant }?,
		-- Scored participants still in the round (a leaver is removed here; places stay).
		scoredParticipantByPlayerUserId = {} :: { [number]: ThemedRoundFinalOutfitScorer.ScoredParticipant },
		hasSettlementRun = false,
		settledPlayerUserIdSet = {} :: { [number]: boolean },
	}, RefereedThemedRound)
end

function RefereedThemedRound:addParticipant(playerUserId: number)
	self.participantRoster:addParticipant(playerUserId)
	self.roundOutfitDraftKeeper:addParticipant(playerUserId)
end

function RefereedThemedRound:removeParticipant(playerUserId: number): boolean
	if not self.participantRoster:removeParticipant(playerUserId) then
		return false
	end
	self.roundOutfitDraftKeeper:removeParticipant(playerUserId)
	self.scoredParticipantByPlayerUserId[playerUserId] = nil
	return true
end

function RefereedThemedRound:isParticipant(playerUserId: number): boolean
	return self.participantRoster:isParticipant(playerUserId)
end

function RefereedThemedRound:hasLeftThisRound(playerUserId: number): boolean
	return self.participantRoster:hasLeftThisRound(playerUserId)
end

function RefereedThemedRound:listParticipantUserIdsInJoinOrder(): { number }
	return self.participantRoster:listParticipantUserIdsInJoinOrder()
end

function RefereedThemedRound:startAcceptingOutfitDraftsOnce()
	if self.hasStylingStarted then
		return
	end
	self.hasStylingStarted = true
	self.roundOutfitDraftKeeper:startAcceptingOutfitDrafts()
end

function RefereedThemedRound:receiveOutfitDraftFromParticipant(playerUserId: number, untrustedMessage: any)
	if not self.participantRoster:isParticipant(playerUserId) then
		return
	end
	self.roundOutfitDraftKeeper:receiveOutfitDraftFromDevice(playerUserId, untrustedMessage)
end

function RefereedThemedRound:cutOffDraftsAndScoreFinalOutfitsOnce()
	local finalOutfitStylingItemKeysByPlayerUserId =
		self.roundOutfitDraftKeeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
	if finalOutfitStylingItemKeysByPlayerUserId == nil then
		return -- the cut-off already ran (or the drafts were ended): nothing is scored twice
	end
	local participantsInJoinOrder = {}
	for _, playerUserId in self.participantRoster:listParticipantUserIdsInJoinOrder() do
		table.insert(participantsInJoinOrder, {
			playerUserId = playerUserId,
			joinOrderPosition = self.participantRoster:readJoinOrderPosition(playerUserId),
		})
	end
	local scoredParticipants, playerUserIdsWhoseScoringRaised =
		ThemedRoundFinalOutfitScorer.scoreFinalOutfitsAndAssignStagePlaces({
			participantsInJoinOrder = participantsInJoinOrder,
			finalOutfitStylingItemKeysByPlayerUserId = finalOutfitStylingItemKeysByPlayerUserId,
			stylingItemByStylingItemKey = self.stylingItemByStylingItemKey,
			theme = self.theme,
			roundBonusRule = self.roundBonusRule,
		})
	self.scoredParticipantsInStagePlaceOrder = scoredParticipants
	if #playerUserIdsWhoseScoringRaised > 0 then
		self.logger:logWarning(
			string.format(
				"RefereedThemedRound: scoring raised in round %s for players %s; they are not scored",
				self.roundId,
				table.concat(playerUserIdsWhoseScoringRaised, ", ")
			)
		)
	end
	for _, scoredParticipant in scoredParticipants do
		self.scoredParticipantByPlayerUserId[scoredParticipant.playerUserId] = scoredParticipant
	end
end

function RefereedThemedRound:hasBeenScored(): boolean
	return self.scoredParticipantsInStagePlaceOrder ~= nil
end

function RefereedThemedRound:readScoredParticipantStillPresent(playerUserId: number)
	return self.scoredParticipantByPlayerUserId[playerUserId]
end

function RefereedThemedRound:settleRewardsOnce(roundRewardSettlementDependencies)
	if self.hasSettlementRun then
		return nil -- at most one settlement per round
	end
	self.hasSettlementRun = true
	local scoredParticipantsStillPresent = {}
	for _, scoredParticipant in self.scoredParticipantsInStagePlaceOrder or {} do
		if self.scoredParticipantByPlayerUserId[scoredParticipant.playerUserId] == scoredParticipant then
			table.insert(scoredParticipantsStillPresent, scoredParticipant)
		end
	end
	local roundResults, playerUserIdsWhoseSaveDataWasNotLoaded =
		ThemedRoundRewardSettlement.settleRoundRewardsAndBuildRoundResults({
			roundId = self.roundId,
			themeId = self.themeId,
			scoredParticipantsStillPresent = scoredParticipantsStillPresent,
			rewardLedger = roundRewardSettlementDependencies.rewardLedger,
			readPlayerDisplayName = roundRewardSettlementDependencies.readPlayerDisplayName,
			ownerDecisions = roundRewardSettlementDependencies.ownerDecisions,
			logger = roundRewardSettlementDependencies.logger,
			settledPlayerUserIdSet = self.settledPlayerUserIdSet,
		})
	for _, playerUserId in playerUserIdsWhoseSaveDataWasNotLoaded do
		self:removeParticipant(playerUserId)
	end
	return roundResults
end

function RefereedThemedRound:endOutfitDrafts()
	self.roundOutfitDraftKeeper:endRound()
end

return RefereedThemedRound
