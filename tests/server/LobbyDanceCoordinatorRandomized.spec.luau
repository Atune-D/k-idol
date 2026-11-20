-- LobbyDanceCoordinator seeded random sequences: random starts (owned, unowned and hostile ids),
-- syncs (dancers, followers, non-dancers, oneself, hostile values), stops, stage entries and
-- exits, and players being forgotten (their save stays loaded, so they may dance again), plus a
-- listener that sometimes changes the coordinator while being told. After every step the invariants of the coordinator's header
-- must hold, and replaying the change events must reproduce what readEveryLobbyDancerState says.

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local LobbyRequestRulesTestHarness = require("./LobbyRequestRulesTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_USER_IDS = {
	LobbyRequestRulesTestHarness.FIRST_PLAYER_USER_ID,
	LobbyRequestRulesTestHarness.SECOND_PLAYER_USER_ID,
	LobbyRequestRulesTestHarness.THIRD_PLAYER_USER_ID,
	LobbyRequestRulesTestHarness.FOURTH_PLAYER_USER_ID,
}
local CANDIDATE_DANCE_IDS = {
	LobbyRequestRulesTestHarness.STARTER_WAVE_DANCE_ID,
	LobbyRequestRulesTestHarness.STARTER_STEP_DANCE_ID,
	LobbyRequestRulesTestHarness.SHOP_TWIRL_DANCE_ID,
	LobbyRequestRulesTestHarness.RETIRED_DANCE_ID,
	"",
	0 / 0,
	false,
}
local ALLOWED_REJECTION_REASONS_BY_REQUEST_NAME = {
	Start = { DanceNotOwned = true, NotAllowedDuringRound = true },
	Sync = { TargetNotDancing = true, NotAllowedDuringRound = true },
	Stop = {},
}

local function buildDancerStateByPlayerUserIdFromEvents(recordedLobbyDanceStateChanges)
	local replayedLobbyDanceStateByPlayerUserId = {}
	for _, recordedChange in recordedLobbyDanceStateChanges do
		replayedLobbyDanceStateByPlayerUserId[recordedChange.playerUserId] = recordedChange.lobbyDanceState
	end
	return replayedLobbyDanceStateByPlayerUserId
end

local function expectCoordinatorInvariantsHold(harness, isOnStageByPlayerUserId)
	local everyLobbyDancerState = harness.lobbyDanceCoordinator:readEveryLobbyDancerState()
	local lobbyDanceStateByPlayerUserId = {}
	local previousPlayerUserId = -math.huge
	for _, lobbyDanceState in everyLobbyDancerState do
		expect(lobbyDanceState.dancingPlayerUserId > previousPlayerUserId).toBeTrue()
		previousPlayerUserId = lobbyDanceState.dancingPlayerUserId
		lobbyDanceStateByPlayerUserId[lobbyDanceState.dancingPlayerUserId] = lobbyDanceState
		expect(isOnStageByPlayerUserId[lobbyDanceState.dancingPlayerUserId] == true).toBeFalse()
	end
	for dancingPlayerUserId, lobbyDanceState in lobbyDanceStateByPlayerUserId do
		local followedPlayerUserId = lobbyDanceState.followedPlayerUserId
		if followedPlayerUserId == nil then
			-- A leader dances only a dance it owns that is in the catalog.
			local ownedDanceIds = harness.playerSaveDataKeeper:readPlayerSaveDataCopy(dancingPlayerUserId).ownedDanceIds
			expect(table.find(ownedDanceIds, lobbyDanceState.danceId) ~= nil).toBeTrue()
			expect(lobbyDanceState.danceId ~= LobbyRequestRulesTestHarness.RETIRED_DANCE_ID).toBeTrue()
		else
			-- A follower follows a dancing player in that player's dance and time.
			local followedLobbyDanceState = lobbyDanceStateByPlayerUserId[followedPlayerUserId]
			expect(followedLobbyDanceState ~= nil).toBeTrue()
			expect(lobbyDanceState.danceId).toBe(followedLobbyDanceState.danceId)
			expect(lobbyDanceState.danceStartedAtUnixMilliseconds).toBe(
				followedLobbyDanceState.danceStartedAtUnixMilliseconds
			)
			-- The chain up from this follower ends at a player dancing their own dance (no cycle).
			local visitedPlayerUserIds = { [dancingPlayerUserId] = true }
			local chainLobbyDanceState = followedLobbyDanceState
			while chainLobbyDanceState.followedPlayerUserId ~= nil do
				expect(visitedPlayerUserIds[chainLobbyDanceState.dancingPlayerUserId]).toBeNil()
				visitedPlayerUserIds[chainLobbyDanceState.dancingPlayerUserId] = true
				chainLobbyDanceState = lobbyDanceStateByPlayerUserId[chainLobbyDanceState.followedPlayerUserId]
				expect(chainLobbyDanceState ~= nil).toBeTrue()
			end
			expect(visitedPlayerUserIds[chainLobbyDanceState.dancingPlayerUserId]).toBeNil()
		end
	end
	expect(buildDancerStateByPlayerUserIdFromEvents(harness.recordedLobbyDanceStateChanges)).toEqual(
		lobbyDanceStateByPlayerUserId
	)
end

local function expectAnswerIsAllowed(requestName: string, answer)
	if answer.isAccepted then
		expect(answer).toEqual({ isAccepted = true })
		return
	end
	expect({ requestName, ALLOWED_REJECTION_REASONS_BY_REQUEST_NAME[requestName][answer.rejectionReason] }).toEqual({
		requestName,
		true,
	})
end

local function runOneRandomStep(harness, seededRandomNumberGenerator, isOnStageByPlayerUserId)
	local actingPlayerUserId = seededRandomNumberGenerator.pickRandomListElement(PLAYER_USER_IDS)
	local stepKind = seededRandomNumberGenerator.nextWholeNumberInRange(1, 10)
	if stepKind <= 4 then
		local danceId = seededRandomNumberGenerator.pickRandomListElement(CANDIDATE_DANCE_IDS)
		expectAnswerIsAllowed("Start", harness.sendStartDance(actingPlayerUserId, danceId))
	elseif stepKind <= 7 then
		local targetChoices = table.clone(PLAYER_USER_IDS)
		table.insert(targetChoices, 0 / 0)
		table.insert(targetChoices, "8801")
		local targetPlayerUserId = seededRandomNumberGenerator.pickRandomListElement(targetChoices)
		expectAnswerIsAllowed("Sync", harness.sendSyncDance(actingPlayerUserId, targetPlayerUserId))
	elseif stepKind == 8 then
		expectAnswerIsAllowed("Stop", harness.sendStopDance(actingPlayerUserId))
	elseif stepKind == 9 then
		local isGoingOnStage = not isOnStageByPlayerUserId[actingPlayerUserId]
		isOnStageByPlayerUserId[actingPlayerUserId] = isGoingOnStage
		harness.onThemedRoundStageAnswerByPlayerUserId[actingPlayerUserId] = isGoingOnStage
		if isGoingOnStage then
			harness.lobbyDanceCoordinator:endLobbyDanceOfPlayerGoingOnStage(actingPlayerUserId)
		end
	else
		harness.lobbyDanceCoordinator:forgetPlayer(actingPlayerUserId)
	end
end

describe("LobbyDanceCoordinator seeded random sequences", function()
	it("keeps every invariant after every step of 60 random sequences of 40 steps", function()
		SeededRandomTrials.runSeededRandomTrials(60, function(seededRandomNumberGenerator)
			local harness = LobbyRequestRulesTestHarness.createLobbyRequestRulesHarness()
			for _, playerUserId in PLAYER_USER_IDS do
				harness.loadNewPlayer(playerUserId)
			end
			harness.giveDanceIds(PLAYER_USER_IDS[1], { LobbyRequestRulesTestHarness.SHOP_TWIRL_DANCE_ID })
			harness.giveDanceIds(PLAYER_USER_IDS[2], { LobbyRequestRulesTestHarness.RETIRED_DANCE_ID })
			local isOnStageByPlayerUserId = {}
			-- Now and then a listener ends a random player's lobby dance while being told (re-entry).
			harness.lobbyDanceCoordinator:subscribeToLobbyDanceStateChanged(function()
				if seededRandomNumberGenerator.nextWholeNumberInRange(1, 8) == 1 then
					local endedPlayerUserId = seededRandomNumberGenerator.pickRandomListElement(PLAYER_USER_IDS)
					harness.lobbyDanceCoordinator:endLobbyDanceOfPlayerGoingOnStage(endedPlayerUserId)
				end
			end)
			for _ = 1, 40 do
				runOneRandomStep(harness, seededRandomNumberGenerator, isOnStageByPlayerUserId)
				expectCoordinatorInvariantsHold(harness, isOnStageByPlayerUserId)
			end
		end)
	end)
end)
