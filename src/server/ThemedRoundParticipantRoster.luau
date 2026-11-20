-- ThemedRoundParticipantRoster: who takes part in ONE themed round, in order of accepted joins
-- (development spec v1.3 §2.1 participantUserIds, §2.2; referee audit PART 1 questions 11, 15,
-- 20). ThemedRoundReferee owns one roster per round; the draft state lives in
-- RoundOutfitDraftKeeper, the scores in the referee.
-- Pure logic: no Roblox-specific interface is used.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- ThemedRoundParticipantRoster.new() -> roster   empty
-- roster:addParticipant(playerUserId) -> joinOrderPosition
--   Gives the player the next join order position (1, 2, 3 … never reused within the round, so a
--   player added again after leaving comes after everyone already listed). Raises when the
--   player is already a participant.
-- roster:removeParticipant(playerUserId) -> wasParticipant: boolean
--   Removes the player and remembers that they left this round. Does nothing (returns false) for
--   a non-participant, so a second "left" notification is harmless.
-- roster:isParticipant(playerUserId) -> boolean
-- roster:hasLeftThisRound(playerUserId) -> boolean   true once removed, even if added again
-- roster:readJoinOrderPosition(playerUserId) -> number?   nil for a non-participant
-- roster:listParticipantUserIdsInJoinOrder() -> { number }   a fresh frozen list
-- roster:countParticipants() -> number
--
-- Every method that takes a playerUserId raises when it is not a number or is NaN.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local PlayerUserIdArgumentCheck = require("./PlayerUserIdArgumentCheck")

local assertIsPlayerUserId = PlayerUserIdArgumentCheck.assertIsPlayerUserId
local CALLING_MODULE_NAME = "ThemedRoundParticipantRoster"

local ThemedRoundParticipantRoster = {}
ThemedRoundParticipantRoster.__index = ThemedRoundParticipantRoster

function ThemedRoundParticipantRoster.new()
	return setmetatable({
		joinOrderPositionByPlayerUserId = {} :: { [number]: number },
		leftPlayerUserIdSet = {} :: { [number]: boolean },
		lastGivenJoinOrderPosition = 0,
	}, ThemedRoundParticipantRoster)
end

function ThemedRoundParticipantRoster:addParticipant(playerUserId: number): number
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	if self.joinOrderPositionByPlayerUserId[playerUserId] ~= nil then
		error(string.format("ThemedRoundParticipantRoster: player %d is already a participant", playerUserId), 2)
	end
	self.lastGivenJoinOrderPosition += 1
	self.joinOrderPositionByPlayerUserId[playerUserId] = self.lastGivenJoinOrderPosition
	return self.lastGivenJoinOrderPosition
end

function ThemedRoundParticipantRoster:removeParticipant(playerUserId: number): boolean
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	if self.joinOrderPositionByPlayerUserId[playerUserId] == nil then
		return false
	end
	self.joinOrderPositionByPlayerUserId[playerUserId] = nil
	self.leftPlayerUserIdSet[playerUserId] = true
	return true
end

function ThemedRoundParticipantRoster:isParticipant(playerUserId: number): boolean
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	return self.joinOrderPositionByPlayerUserId[playerUserId] ~= nil
end

function ThemedRoundParticipantRoster:hasLeftThisRound(playerUserId: number): boolean
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	return self.leftPlayerUserIdSet[playerUserId] == true
end

function ThemedRoundParticipantRoster:readJoinOrderPosition(playerUserId: number): number?
	assertIsPlayerUserId(playerUserId, CALLING_MODULE_NAME)
	return self.joinOrderPositionByPlayerUserId[playerUserId]
end

function ThemedRoundParticipantRoster:listParticipantUserIdsInJoinOrder(): { number }
	local participantUserIds = {}
	for playerUserId in self.joinOrderPositionByPlayerUserId do
		table.insert(participantUserIds, playerUserId)
	end
	table.sort(participantUserIds, function(firstPlayerUserId: number, secondPlayerUserId: number)
		return self.joinOrderPositionByPlayerUserId[firstPlayerUserId]
			< self.joinOrderPositionByPlayerUserId[secondPlayerUserId]
	end)
	return table.freeze(participantUserIds)
end

function ThemedRoundParticipantRoster:countParticipants(): number
	local participantCount = 0
	for _ in self.joinOrderPositionByPlayerUserId do
		participantCount += 1
	end
	return participantCount
end

return ThemedRoundParticipantRoster
