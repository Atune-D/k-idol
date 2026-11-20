-- LobbyDanceCoordinator RequestSyncDanceWithPlayer and RequestStopDanceInLobby (development spec
-- §2.8 last two rows, §2.13, §3.4): every acceptance and rejection reason, the order of the
-- checks, hostile values and fresh answer tables. Following rules are in
-- LobbyDanceCoordinatorFollowing.spec.luau. Uses the REAL
-- save keeper and rate limiter (LobbyRequestRulesTestHarness).

local UnitTestFramework = require("../Support/UnitTestFramework")
local LobbyRequestRulesTestHarness = require("./LobbyRequestRulesTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local FIRST_PLAYER_USER_ID = LobbyRequestRulesTestHarness.FIRST_PLAYER_USER_ID
local SECOND_PLAYER_USER_ID = LobbyRequestRulesTestHarness.SECOND_PLAYER_USER_ID
local THIRD_PLAYER_USER_ID = LobbyRequestRulesTestHarness.THIRD_PLAYER_USER_ID
local STARTER_WAVE_DANCE_ID = LobbyRequestRulesTestHarness.STARTER_WAVE_DANCE_ID
local STARTER_STEP_DANCE_ID = LobbyRequestRulesTestHarness.STARTER_STEP_DANCE_ID
local SHOP_TWIRL_DANCE_ID = LobbyRequestRulesTestHarness.SHOP_TWIRL_DANCE_ID

local ACCEPTED = { isAccepted = true }
local function rejectedWith(rejectionReason: string)
	return { isAccepted = false, rejectionReason = rejectionReason }
end

local function createHarnessWithLoadedPlayers()
	local harness = LobbyRequestRulesTestHarness.createLobbyRequestRulesHarness()
	harness.loadNewPlayer(FIRST_PLAYER_USER_ID)
	harness.loadNewPlayer(SECOND_PLAYER_USER_ID)
	return harness
end

describe("RequestSyncDanceWithPlayer acceptance and rejections", function()
	it(
		"accepted when the target dances: the follower gets the target's dance and start moment without owning it",
		function()
			local harness = createHarnessWithLoadedPlayers()
			harness.giveDanceIds(SECOND_PLAYER_USER_ID, { SHOP_TWIRL_DANCE_ID })
			harness.sendStartDance(SECOND_PLAYER_USER_ID, SHOP_TWIRL_DANCE_ID)
			local leaderStartedAtUnixMilliseconds = harness.nowUnixMilliseconds()
			harness.advanceSeconds(7.25)
			expect(harness.sendSyncDance(FIRST_PLAYER_USER_ID, SECOND_PLAYER_USER_ID)).toEqual(ACCEPTED)
			local expectedFollowerState = harness.buildExpectedLobbyDanceState(
				FIRST_PLAYER_USER_ID,
				SHOP_TWIRL_DANCE_ID,
				leaderStartedAtUnixMilliseconds,
				SECOND_PLAYER_USER_ID
			)
			expect(harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID)).toEqual(
				expectedFollowerState
			)
			expect(harness.recordedLobbyDanceStateChanges[2]).toEqual({
				playerUserId = FIRST_PLAYER_USER_ID,
				lobbyDanceState = expectedFollowerState,
			})
			expect(
				table.find(
					harness.playerSaveDataKeeper:readPlayerSaveDataCopy(FIRST_PLAYER_USER_ID).ownedDanceIds,
					SHOP_TWIRL_DANCE_ID
				)
			).toBeNil()
		end
	)

	it("TargetNotDancing for a loaded player who is not dancing, and for unknown or hostile target values", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.loadNewPlayer(THIRD_PLAYER_USER_ID)
		harness.sendStartDance(SECOND_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		local hostileTargets = {
			{ "a loaded player not dancing", THIRD_PLAYER_USER_ID },
			{ "an unknown player id", 123456789 },
			{ "nil", nil },
			{ "the dancer's id as a string", tostring(SECOND_PLAYER_USER_ID) },
			{ "the dancer's id plus a fraction", SECOND_PLAYER_USER_ID + 0.5 },
			{ "NaN", 0 / 0 },
			{ "infinity", math.huge },
			{ "a table", { SECOND_PLAYER_USER_ID } },
			{ "a table with a raising metatable", setmetatable({}, { __eq = error, __index = error }) },
			{ "a huge string", string.rep("8", 1000000) },
		}
		for _, hostileTargetCase in hostileTargets do
			local didAnswer, answerOrError = pcall(harness.sendSyncDance, FIRST_PLAYER_USER_ID, hostileTargetCase[2])
			expect(didAnswer).toBeTrue()
			expect({ hostileTargetCase[1], answerOrError }).toEqual({
				hostileTargetCase[1],
				rejectedWith("TargetNotDancing"),
			})
		end
		expect(harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID)).toBeNil()
	end)

	it("NotAllowedDuringRound when the requester is on stage", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.sendStartDance(SECOND_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		harness.onThemedRoundStageAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = true
		expect(harness.sendSyncDance(FIRST_PLAYER_USER_ID, SECOND_PLAYER_USER_ID)).toEqual(
			rejectedWith("NotAllowedDuringRound")
		)
		expect(harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID)).toBeNil()
	end)

	it("SaveDataNotLoaded when the requester's save is not loaded (§3.4), even if the target dances", function()
		local harness = LobbyRequestRulesTestHarness.createLobbyRequestRulesHarness()
		harness.loadNewPlayer(SECOND_PLAYER_USER_ID)
		harness.sendStartDance(SECOND_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		expect(harness.sendSyncDance(FIRST_PLAYER_USER_ID, SECOND_PLAYER_USER_ID)).toEqual(
			rejectedWith("SaveDataNotLoaded")
		)
	end)

	it("TooManyRequests within 0.5 s on its own channel, asked first", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.sendStartDance(SECOND_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		local coordinator = harness.lobbyDanceCoordinator
		-- The start request just admitted on another channel does not limit the sync channel.
		expect(coordinator:answerStartDanceInLobbyRequest(FIRST_PLAYER_USER_ID, STARTER_STEP_DANCE_ID)).toEqual(
			ACCEPTED
		)
		expect(coordinator:answerSyncDanceWithPlayerRequest(FIRST_PLAYER_USER_ID, SECOND_PLAYER_USER_ID)).toEqual(
			ACCEPTED
		)
		expect(coordinator:answerSyncDanceWithPlayerRequest(FIRST_PLAYER_USER_ID, 0 / 0)).toEqual(
			rejectedWith("TooManyRequests")
		)
		harness.advanceSeconds(0.5)
		expect(coordinator:answerSyncDanceWithPlayerRequest(FIRST_PLAYER_USER_ID, 0 / 0)).toEqual(
			rejectedWith("TargetNotDancing")
		)
	end)
end)

describe("RequestSyncDanceWithPlayer request rules (§2.13, §3.4)", function()
	it("a rate-limited sync with a dancing target changes nothing and tells no listener", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.sendStartDance(SECOND_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		local coordinator = harness.lobbyDanceCoordinator
		expect(coordinator:answerSyncDanceWithPlayerRequest(FIRST_PLAYER_USER_ID, 0 / 0)).toEqual(
			rejectedWith("TargetNotDancing")
		)
		table.clear(harness.askedOnThemedRoundStageUserIds)
		expect(coordinator:answerSyncDanceWithPlayerRequest(FIRST_PLAYER_USER_ID, SECOND_PLAYER_USER_ID)).toEqual(
			rejectedWith("TooManyRequests")
		)
		expect(coordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID)).toBeNil()
		expect(#harness.recordedLobbyDanceStateChanges).toBe(1)
		expect(harness.askedOnThemedRoundStageUserIds).toEqual({})
	end)

	it("the limiter is asked first: an unloaded requester gets SaveDataNotLoaded, then TooManyRequests", function()
		local harness = LobbyRequestRulesTestHarness.createLobbyRequestRulesHarness()
		local coordinator = harness.lobbyDanceCoordinator
		expect(coordinator:answerSyncDanceWithPlayerRequest(FIRST_PLAYER_USER_ID, SECOND_PLAYER_USER_ID)).toEqual(
			rejectedWith("SaveDataNotLoaded")
		)
		expect(coordinator:answerSyncDanceWithPlayerRequest(FIRST_PLAYER_USER_ID, SECOND_PLAYER_USER_ID)).toEqual(
			rejectedWith("TooManyRequests")
		)
	end)

	it("SaveDataNotLoaded comes before the stage question", function()
		local harness = LobbyRequestRulesTestHarness.createLobbyRequestRulesHarness()
		harness.loadNewPlayer(SECOND_PLAYER_USER_ID)
		harness.sendStartDance(SECOND_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		table.clear(harness.askedOnThemedRoundStageUserIds)
		harness.onThemedRoundStageAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = true
		expect(harness.sendSyncDance(FIRST_PLAYER_USER_ID, SECOND_PLAYER_USER_ID)).toEqual(
			rejectedWith("SaveDataNotLoaded")
		)
		expect(harness.askedOnThemedRoundStageUserIds).toEqual({})
	end)

	it("an on-stage requester gets NotAllowedDuringRound before any target check (itself, a non-dancer)", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		harness.onThemedRoundStageAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = true
		expect(harness.sendSyncDance(FIRST_PLAYER_USER_ID, FIRST_PLAYER_USER_ID)).toEqual(
			rejectedWith("NotAllowedDuringRound")
		)
		expect(harness.sendSyncDance(FIRST_PLAYER_USER_ID, SECOND_PLAYER_USER_ID)).toEqual(
			rejectedWith("NotAllowedDuringRound")
		)
		expect(harness.sendSyncDance(FIRST_PLAYER_USER_ID, 0 / 0)).toEqual(rejectedWith("NotAllowedDuringRound"))
	end)

	it("builds a fresh answer table every time, accepted or rejected", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.sendStartDance(SECOND_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		local firstAcceptance = harness.sendSyncDance(FIRST_PLAYER_USER_ID, SECOND_PLAYER_USER_ID)
		local secondAcceptance = harness.sendSyncDance(FIRST_PLAYER_USER_ID, SECOND_PLAYER_USER_ID)
		expect(firstAcceptance).toEqual(ACCEPTED)
		expect(firstAcceptance ~= secondAcceptance).toBeTrue()
		local firstRejection = harness.sendSyncDance(FIRST_PLAYER_USER_ID, 0 / 0)
		local secondRejection = harness.sendSyncDance(FIRST_PLAYER_USER_ID, 0 / 0)
		expect(firstRejection).toEqual(rejectedWith("TargetNotDancing"))
		expect(firstRejection ~= secondRejection).toBeTrue()
	end)
end)

describe("RequestStopDanceInLobby", function()
	it("always accepted: a dancing player stops and listeners are told nil", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		expect(harness.sendStopDance(FIRST_PLAYER_USER_ID)).toEqual(ACCEPTED)
		expect(harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID)).toBeNil()
		expect(harness.recordedLobbyDanceStateChanges[2]).toEqual({
			playerUserId = FIRST_PLAYER_USER_ID,
			lobbyDanceState = nil,
		})
	end)

	it("accepted with no change and no event when not dancing, and for a player whose save is not loaded", function()
		local harness = LobbyRequestRulesTestHarness.createLobbyRequestRulesHarness()
		expect(harness.sendStopDance(FIRST_PLAYER_USER_ID)).toEqual(ACCEPTED)
		harness.loadNewPlayer(FIRST_PLAYER_USER_ID)
		expect(harness.sendStopDance(FIRST_PLAYER_USER_ID)).toEqual(ACCEPTED)
		expect(harness.recordedLobbyDanceStateChanges).toEqual({})
	end)

	it("a dancer whose save is no longer loaded (leaving) can still stop, and listeners are told nil", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(FIRST_PLAYER_USER_ID)
		expect(harness.sendStopDance(FIRST_PLAYER_USER_ID)).toEqual(ACCEPTED)
		expect(harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID)).toBeNil()
		expect(harness.recordedLobbyDanceStateChanges[2]).toEqual({
			playerUserId = FIRST_PLAYER_USER_ID,
			lobbyDanceState = nil,
		})
	end)

	it("builds a fresh answer table every time, accepted or rejected", function()
		local harness = createHarnessWithLoadedPlayers()
		local coordinator = harness.lobbyDanceCoordinator
		local firstAcceptance = harness.sendStopDance(FIRST_PLAYER_USER_ID)
		local secondAcceptance = harness.sendStopDance(FIRST_PLAYER_USER_ID)
		expect(firstAcceptance ~= secondAcceptance).toBeTrue()
		local firstRejection = coordinator:answerStopDanceInLobbyRequest(FIRST_PLAYER_USER_ID)
		local secondRejection = coordinator:answerStopDanceInLobbyRequest(FIRST_PLAYER_USER_ID)
		expect(firstRejection).toEqual(rejectedWith("TooManyRequests"))
		expect(firstRejection ~= secondRejection).toBeTrue()
	end)

	it("accepted for a player on stage (stopping is always allowed)", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.onThemedRoundStageAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = true
		expect(harness.sendStopDance(FIRST_PLAYER_USER_ID)).toEqual(ACCEPTED)
	end)

	it("TooManyRequests within 0.5 s on its own channel (§2.13), and the dance goes on", function()
		local harness = createHarnessWithLoadedPlayers()
		local coordinator = harness.lobbyDanceCoordinator
		expect(harness.sendStopDance(FIRST_PLAYER_USER_ID)).toEqual(ACCEPTED)
		expect(coordinator:answerStartDanceInLobbyRequest(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)).toEqual(
			ACCEPTED
		)
		expect(coordinator:answerStopDanceInLobbyRequest(FIRST_PLAYER_USER_ID)).toEqual(rejectedWith("TooManyRequests"))
		harness.advanceSeconds(0.499)
		expect(coordinator:answerStopDanceInLobbyRequest(FIRST_PLAYER_USER_ID)).toEqual(rejectedWith("TooManyRequests"))
		expect(coordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID).danceId).toBe(STARTER_WAVE_DANCE_ID)
		harness.advanceSeconds(0.001)
		expect(coordinator:answerStopDanceInLobbyRequest(FIRST_PLAYER_USER_ID)).toEqual(ACCEPTED)
		expect(coordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID)).toBeNil()
	end)
end)
