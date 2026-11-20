-- LobbyDanceCoordinator dance sync (development spec §2.8 "A synced player performs the target's
-- dance, in time with the target, without owning it, until either of them stops"): the start
-- moment handed to followers, and every open case the coordinator's header decides.

local UnitTestFramework = require("../Support/UnitTestFramework")
local LobbyRequestRulesTestHarness = require("./LobbyRequestRulesTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local LEADER_USER_ID = LobbyRequestRulesTestHarness.FIRST_PLAYER_USER_ID
local FIRST_FOLLOWER_USER_ID = LobbyRequestRulesTestHarness.SECOND_PLAYER_USER_ID
local SECOND_FOLLOWER_USER_ID = LobbyRequestRulesTestHarness.THIRD_PLAYER_USER_ID
local OTHER_DANCER_USER_ID = LobbyRequestRulesTestHarness.FOURTH_PLAYER_USER_ID
local STARTER_WAVE_DANCE_ID = LobbyRequestRulesTestHarness.STARTER_WAVE_DANCE_ID
local STARTER_STEP_DANCE_ID = LobbyRequestRulesTestHarness.STARTER_STEP_DANCE_ID
local SHOP_TWIRL_DANCE_ID = LobbyRequestRulesTestHarness.SHOP_TWIRL_DANCE_ID

local ACCEPTED = { isAccepted = true }
local TARGET_NOT_DANCING = { isAccepted = false, rejectionReason = "TargetNotDancing" }

-- LEADER_USER_ID dances SHOP_TWIRL_DANCE_ID (owned by the leader only); FIRST_FOLLOWER_USER_ID
-- and SECOND_FOLLOWER_USER_ID follow the leader. OTHER_DANCER_USER_ID is loaded and not dancing.
-- The recorded changes are cleared at the end.
local function createHarnessWithLeaderAndTwoFollowers()
	local harness = LobbyRequestRulesTestHarness.createLobbyRequestRulesHarness()
	for _, playerUserId in { LEADER_USER_ID, FIRST_FOLLOWER_USER_ID, SECOND_FOLLOWER_USER_ID, OTHER_DANCER_USER_ID } do
		harness.loadNewPlayer(playerUserId)
	end
	harness.giveDanceIds(LEADER_USER_ID, { SHOP_TWIRL_DANCE_ID })
	assert(harness.sendStartDance(LEADER_USER_ID, SHOP_TWIRL_DANCE_ID).isAccepted, "the leader should start")
	harness.leaderStartedAtUnixMilliseconds = harness.nowUnixMilliseconds()
	harness.advanceSeconds(3.3)
	assert(harness.sendSyncDance(SECOND_FOLLOWER_USER_ID, LEADER_USER_ID).isAccepted, "the second follower should sync")
	assert(harness.sendSyncDance(FIRST_FOLLOWER_USER_ID, LEADER_USER_ID).isAccepted, "the first follower should sync")
	table.clear(harness.recordedLobbyDanceStateChanges)
	return harness
end

local function readState(harness, playerUserId: number)
	return harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(playerUserId)
end

local function expectFollowersEndedAfter(harness, expectedLeaderChange)
	expect(harness.recordedLobbyDanceStateChanges).toEqual({
		expectedLeaderChange,
		{ playerUserId = FIRST_FOLLOWER_USER_ID, lobbyDanceState = nil },
		{ playerUserId = SECOND_FOLLOWER_USER_ID, lobbyDanceState = nil },
	})
	expect(readState(harness, FIRST_FOLLOWER_USER_ID)).toBeNil()
	expect(readState(harness, SECOND_FOLLOWER_USER_ID)).toBeNil()
end

describe("Dance sync in time (§2.8)", function()
	it("every follower carries the leader's start moment, not the moment it synced", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		for _, followerUserId in { FIRST_FOLLOWER_USER_ID, SECOND_FOLLOWER_USER_ID } do
			expect(readState(harness, followerUserId)).toEqual(
				harness.buildExpectedLobbyDanceState(
					followerUserId,
					SHOP_TWIRL_DANCE_ID,
					harness.leaderStartedAtUnixMilliseconds,
					LEADER_USER_ID
				)
			)
		end
		expect(harness.nowUnixMilliseconds() > harness.leaderStartedAtUnixMilliseconds).toBeTrue()
	end)

	it("a follower does not need to own the dance, and its save is not changed", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		expect(readState(harness, FIRST_FOLLOWER_USER_ID).danceId).toBe(SHOP_TWIRL_DANCE_ID)
		expect(
			table.find(
				harness.playerSaveDataKeeper:readPlayerSaveDataCopy(FIRST_FOLLOWER_USER_ID).ownedDanceIds,
				SHOP_TWIRL_DANCE_ID
			)
		).toBeNil()
		expect(harness.readInMemoryChangeRevision(FIRST_FOLLOWER_USER_ID)).toBe(0)
	end)

	it("the leader's own state is untouched by followers syncing", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		expect(readState(harness, LEADER_USER_ID)).toEqual(
			harness.buildExpectedLobbyDanceState(
				LEADER_USER_ID,
				SHOP_TWIRL_DANCE_ID,
				harness.leaderStartedAtUnixMilliseconds,
				nil
			)
		)
	end)
end)

describe("Syncing with oneself (decided: TargetNotDancing)", function()
	it("refused for a player who is not dancing", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		expect(harness.sendSyncDance(OTHER_DANCER_USER_ID, OTHER_DANCER_USER_ID)).toEqual(TARGET_NOT_DANCING)
		expect(readState(harness, OTHER_DANCER_USER_ID)).toBeNil()
	end)

	it("refused for a leader, whose dance and followers stay as they are", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		expect(harness.sendSyncDance(LEADER_USER_ID, LEADER_USER_ID)).toEqual(TARGET_NOT_DANCING)
		expect(readState(harness, LEADER_USER_ID).followedPlayerUserId).toBeNil()
		expect(readState(harness, FIRST_FOLLOWER_USER_ID).followedPlayerUserId).toBe(LEADER_USER_ID)
		expect(harness.recordedLobbyDanceStateChanges).toEqual({})
	end)

	it("refused for a follower, who keeps following", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		expect(harness.sendSyncDance(FIRST_FOLLOWER_USER_ID, FIRST_FOLLOWER_USER_ID)).toEqual(TARGET_NOT_DANCING)
		expect(readState(harness, FIRST_FOLLOWER_USER_ID).followedPlayerUserId).toBe(LEADER_USER_ID)
		expect(harness.recordedLobbyDanceStateChanges).toEqual({})
	end)

	it("syncing with one's own follower is syncing with oneself: refused", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		expect(harness.sendSyncDance(LEADER_USER_ID, FIRST_FOLLOWER_USER_ID)).toEqual(TARGET_NOT_DANCING)
		expect(readState(harness, LEADER_USER_ID).followedPlayerUserId).toBeNil()
		expect(harness.recordedLobbyDanceStateChanges).toEqual({})
	end)
end)

describe(
	"Syncing with a player who is themselves syncing (decided: follow that player, §2.8 'until either of them stops')",
	function()
		it("the requester follows the tapped follower, with the dance and start moment it shows", function()
			local harness = createHarnessWithLeaderAndTwoFollowers()
			expect(harness.sendSyncDance(OTHER_DANCER_USER_ID, FIRST_FOLLOWER_USER_ID)).toEqual(ACCEPTED)
			expect(readState(harness, OTHER_DANCER_USER_ID)).toEqual(
				harness.buildExpectedLobbyDanceState(
					OTHER_DANCER_USER_ID,
					SHOP_TWIRL_DANCE_ID,
					harness.leaderStartedAtUnixMilliseconds,
					FIRST_FOLLOWER_USER_ID
				)
			)
		end)

		it("the tapped follower stopping ends the requester's dance; the leader and other followers go on", function()
			local harness = createHarnessWithLeaderAndTwoFollowers()
			harness.sendSyncDance(OTHER_DANCER_USER_ID, FIRST_FOLLOWER_USER_ID)
			table.clear(harness.recordedLobbyDanceStateChanges)
			harness.sendStopDance(FIRST_FOLLOWER_USER_ID)
			expect(harness.recordedLobbyDanceStateChanges).toEqual({
				{ playerUserId = FIRST_FOLLOWER_USER_ID, lobbyDanceState = nil },
				{ playerUserId = OTHER_DANCER_USER_ID, lobbyDanceState = nil },
			})
			expect(readState(harness, OTHER_DANCER_USER_ID)).toBeNil()
			expect(readState(harness, SECOND_FOLLOWER_USER_ID).followedPlayerUserId).toBe(LEADER_USER_ID)
			expect(readState(harness, LEADER_USER_ID).danceId).toBe(SHOP_TWIRL_DANCE_ID)
		end)

		it("the leader stopping ends the whole chain, level by level", function()
			local harness = createHarnessWithLeaderAndTwoFollowers()
			harness.sendSyncDance(OTHER_DANCER_USER_ID, FIRST_FOLLOWER_USER_ID)
			table.clear(harness.recordedLobbyDanceStateChanges)
			harness.sendStopDance(LEADER_USER_ID)
			expect(harness.recordedLobbyDanceStateChanges).toEqual({
				{ playerUserId = LEADER_USER_ID, lobbyDanceState = nil },
				{ playerUserId = FIRST_FOLLOWER_USER_ID, lobbyDanceState = nil },
				{ playerUserId = SECOND_FOLLOWER_USER_ID, lobbyDanceState = nil },
				{ playerUserId = OTHER_DANCER_USER_ID, lobbyDanceState = nil },
			})
			expect(harness.lobbyDanceCoordinator:readEveryLobbyDancerState()).toEqual({})
		end)

		it("syncing with the player one already follows is accepted and changes nothing", function()
			local harness = createHarnessWithLeaderAndTwoFollowers()
			expect(harness.sendSyncDance(FIRST_FOLLOWER_USER_ID, LEADER_USER_ID)).toEqual(ACCEPTED)
			expect(harness.recordedLobbyDanceStateChanges).toEqual({})
		end)

		it("a follower switching to another follower of the same leader now follows that follower", function()
			local harness = createHarnessWithLeaderAndTwoFollowers()
			expect(harness.sendSyncDance(FIRST_FOLLOWER_USER_ID, SECOND_FOLLOWER_USER_ID)).toEqual(ACCEPTED)
			expect(readState(harness, FIRST_FOLLOWER_USER_ID)).toEqual(
				harness.buildExpectedLobbyDanceState(
					FIRST_FOLLOWER_USER_ID,
					SHOP_TWIRL_DANCE_ID,
					harness.leaderStartedAtUnixMilliseconds,
					SECOND_FOLLOWER_USER_ID
				)
			)
		end)

		it("syncing with one's own follower, directly or through a chain, is refused and changes nothing", function()
			local harness = createHarnessWithLeaderAndTwoFollowers()
			harness.sendSyncDance(OTHER_DANCER_USER_ID, FIRST_FOLLOWER_USER_ID)
			table.clear(harness.recordedLobbyDanceStateChanges)
			expect(harness.sendSyncDance(LEADER_USER_ID, OTHER_DANCER_USER_ID)).toEqual(TARGET_NOT_DANCING)
			expect(harness.sendSyncDance(FIRST_FOLLOWER_USER_ID, OTHER_DANCER_USER_ID)).toEqual(TARGET_NOT_DANCING)
			expect(harness.recordedLobbyDanceStateChanges).toEqual({})
			expect(readState(harness, OTHER_DANCER_USER_ID).followedPlayerUserId).toBe(FIRST_FOLLOWER_USER_ID)
		end)
	end
)

describe("Followers when their leader's lobby dance changes (decided: followers stop)", function()
	it("the leader switches to another dance: the leader restarts now, every follower stops", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		harness.sendStartDance(LEADER_USER_ID, STARTER_STEP_DANCE_ID)
		expectFollowersEndedAfter(harness, {
			playerUserId = LEADER_USER_ID,
			lobbyDanceState = harness.buildExpectedLobbyDanceState(
				LEADER_USER_ID,
				STARTER_STEP_DANCE_ID,
				harness.nowUnixMilliseconds(),
				nil
			),
		})
	end)

	it("the leader starts the dance it already dances: nothing changes, followers keep following", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		expect(harness.sendStartDance(LEADER_USER_ID, SHOP_TWIRL_DANCE_ID)).toEqual(ACCEPTED)
		expect(readState(harness, FIRST_FOLLOWER_USER_ID).followedPlayerUserId).toBe(LEADER_USER_ID)
		expect(harness.recordedLobbyDanceStateChanges).toEqual({})
	end)

	it("the leader stops: every follower stops", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		harness.sendStopDance(LEADER_USER_ID)
		expectFollowersEndedAfter(harness, { playerUserId = LEADER_USER_ID, lobbyDanceState = nil })
	end)

	it("the leader syncs with someone else: the leader follows, its followers stop", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		harness.sendStartDance(OTHER_DANCER_USER_ID, STARTER_WAVE_DANCE_ID)
		local otherLeaderStartedAtUnixMilliseconds = harness.nowUnixMilliseconds()
		table.clear(harness.recordedLobbyDanceStateChanges)
		harness.sendSyncDance(LEADER_USER_ID, OTHER_DANCER_USER_ID)
		expectFollowersEndedAfter(harness, {
			playerUserId = LEADER_USER_ID,
			lobbyDanceState = harness.buildExpectedLobbyDanceState(
				LEADER_USER_ID,
				STARTER_WAVE_DANCE_ID,
				otherLeaderStartedAtUnixMilliseconds,
				OTHER_DANCER_USER_ID
			),
		})
	end)

	it("the leader leaves the server: forgotten, and every follower stops", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		harness.lobbyDanceCoordinator:forgetPlayer(LEADER_USER_ID)
		expectFollowersEndedAfter(harness, { playerUserId = LEADER_USER_ID, lobbyDanceState = nil })
		expect(readState(harness, LEADER_USER_ID)).toBeNil()
	end)

	it("the leader goes on the themed round stage: its lobby dance ends and every follower stops", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		harness.onThemedRoundStageAnswerByPlayerUserId[LEADER_USER_ID] = true
		harness.lobbyDanceCoordinator:endLobbyDanceOfPlayerGoingOnStage(LEADER_USER_ID)
		expectFollowersEndedAfter(harness, { playerUserId = LEADER_USER_ID, lobbyDanceState = nil })
	end)

	it("a leader on stage whose lobby dance the wiring has not yet ended cannot be synced with", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		harness.onThemedRoundStageAnswerByPlayerUserId[LEADER_USER_ID] = true
		expect(harness.sendSyncDance(OTHER_DANCER_USER_ID, LEADER_USER_ID)).toEqual(TARGET_NOT_DANCING)
		expect(readState(harness, OTHER_DANCER_USER_ID)).toBeNil()
	end)

	it("a leader on stage whose lobby dance is not yet ended cannot be synced with through a follower", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		harness.onThemedRoundStageAnswerByPlayerUserId[LEADER_USER_ID] = true
		expect(harness.sendSyncDance(OTHER_DANCER_USER_ID, FIRST_FOLLOWER_USER_ID)).toEqual(TARGET_NOT_DANCING)
		expect(readState(harness, OTHER_DANCER_USER_ID)).toBeNil()
	end)

	it("a tapped follower that is itself on stage cannot be synced with", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		harness.onThemedRoundStageAnswerByPlayerUserId[FIRST_FOLLOWER_USER_ID] = true
		expect(harness.sendSyncDance(OTHER_DANCER_USER_ID, FIRST_FOLLOWER_USER_ID)).toEqual(TARGET_NOT_DANCING)
		expect(harness.sendSyncDance(OTHER_DANCER_USER_ID, SECOND_FOLLOWER_USER_ID)).toEqual(ACCEPTED)
	end)

	it(
		"a leaving leader (final save started, not yet forgotten) cannot be synced with, directly or via a follower",
		function()
			local harness = createHarnessWithLeaderAndTwoFollowers()
			harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(LEADER_USER_ID)
			expect(harness.sendSyncDance(OTHER_DANCER_USER_ID, LEADER_USER_ID)).toEqual(TARGET_NOT_DANCING)
			expect(harness.sendSyncDance(OTHER_DANCER_USER_ID, FIRST_FOLLOWER_USER_ID)).toEqual(TARGET_NOT_DANCING)
			expect(readState(harness, OTHER_DANCER_USER_ID)).toBeNil()
		end
	)

	it("a leaving follower cannot be synced with", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(FIRST_FOLLOWER_USER_ID)
		expect(harness.sendSyncDance(OTHER_DANCER_USER_ID, FIRST_FOLLOWER_USER_ID)).toEqual(TARGET_NOT_DANCING)
	end)

	it("followers stopped this way can sync again with a new leader dance", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		harness.sendStartDance(LEADER_USER_ID, STARTER_STEP_DANCE_ID)
		expect(harness.sendSyncDance(FIRST_FOLLOWER_USER_ID, LEADER_USER_ID)).toEqual(ACCEPTED)
		expect(readState(harness, FIRST_FOLLOWER_USER_ID).danceId).toBe(STARTER_STEP_DANCE_ID)
	end)
end)

describe("A follower's own changes leave the leader alone", function()
	it("a follower stops: only that follower's state ends", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		harness.sendStopDance(FIRST_FOLLOWER_USER_ID)
		expect(harness.recordedLobbyDanceStateChanges).toEqual({
			{ playerUserId = FIRST_FOLLOWER_USER_ID, lobbyDanceState = nil },
		})
		expect(readState(harness, SECOND_FOLLOWER_USER_ID).followedPlayerUserId).toBe(LEADER_USER_ID)
		expect(readState(harness, LEADER_USER_ID).danceId).toBe(SHOP_TWIRL_DANCE_ID)
	end)

	it("a follower starts an owned dance: the follow ends and its own dance starts now", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		harness.sendStartDance(FIRST_FOLLOWER_USER_ID, STARTER_WAVE_DANCE_ID)
		expect(readState(harness, FIRST_FOLLOWER_USER_ID)).toEqual(
			harness.buildExpectedLobbyDanceState(
				FIRST_FOLLOWER_USER_ID,
				STARTER_WAVE_DANCE_ID,
				harness.nowUnixMilliseconds(),
				nil
			)
		)
		expect(#harness.recordedLobbyDanceStateChanges).toBe(1)
	end)

	it("a follower that owns the followed dance and starts it becomes its own leader from now", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		harness.giveDanceIds(FIRST_FOLLOWER_USER_ID, { SHOP_TWIRL_DANCE_ID })
		expect(harness.sendStartDance(FIRST_FOLLOWER_USER_ID, SHOP_TWIRL_DANCE_ID)).toEqual(ACCEPTED)
		expect(readState(harness, FIRST_FOLLOWER_USER_ID)).toEqual(
			harness.buildExpectedLobbyDanceState(
				FIRST_FOLLOWER_USER_ID,
				SHOP_TWIRL_DANCE_ID,
				harness.nowUnixMilliseconds(),
				nil
			)
		)
		expect(readState(harness, LEADER_USER_ID).danceStartedAtUnixMilliseconds).toBe(
			harness.leaderStartedAtUnixMilliseconds
		)
	end)

	it("a follower cannot start the followed dance on its own without owning it", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		expect(harness.sendStartDance(FIRST_FOLLOWER_USER_ID, SHOP_TWIRL_DANCE_ID)).toEqual({
			isAccepted = false,
			rejectionReason = "DanceNotOwned",
		})
		expect(readState(harness, FIRST_FOLLOWER_USER_ID).followedPlayerUserId).toBe(LEADER_USER_ID)
	end)

	it("a follower syncs with another leader: it moves, the first leader is untouched", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		harness.sendStartDance(OTHER_DANCER_USER_ID, STARTER_STEP_DANCE_ID)
		harness.sendSyncDance(FIRST_FOLLOWER_USER_ID, OTHER_DANCER_USER_ID)
		expect(readState(harness, FIRST_FOLLOWER_USER_ID).followedPlayerUserId).toBe(OTHER_DANCER_USER_ID)
		expect(readState(harness, FIRST_FOLLOWER_USER_ID).danceId).toBe(STARTER_STEP_DANCE_ID)
		expect(readState(harness, SECOND_FOLLOWER_USER_ID).followedPlayerUserId).toBe(LEADER_USER_ID)
	end)

	it("a follower goes on stage: only its lobby dance ends", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		harness.lobbyDanceCoordinator:endLobbyDanceOfPlayerGoingOnStage(FIRST_FOLLOWER_USER_ID)
		expect(harness.recordedLobbyDanceStateChanges).toEqual({
			{ playerUserId = FIRST_FOLLOWER_USER_ID, lobbyDanceState = nil },
		})
		expect(readState(harness, LEADER_USER_ID).danceId).toBe(SHOP_TWIRL_DANCE_ID)
	end)
end)

describe("A dancing player and themed rounds (decided: only being on stage ends a lobby dance)", function()
	it(
		"joining a round (Styling) keeps the lobby dance; on stage ends it; after the Showcase dancing is allowed again",
		function()
			local harness = createHarnessWithLeaderAndTwoFollowers()
			-- Joined the round: the stage question still answers false during ThemeReveal and Styling.
			expect(readState(harness, LEADER_USER_ID).danceId).toBe(SHOP_TWIRL_DANCE_ID)
			expect(harness.sendStartDance(LEADER_USER_ID, STARTER_WAVE_DANCE_ID)).toEqual(ACCEPTED)
			-- Showcase starts: the wiring ends the lobby dance and the stage question answers true.
			harness.lobbyDanceCoordinator:endLobbyDanceOfPlayerGoingOnStage(LEADER_USER_ID)
			harness.onThemedRoundStageAnswerByPlayerUserId[LEADER_USER_ID] = true
			expect(readState(harness, LEADER_USER_ID)).toBeNil()
			expect(harness.sendStartDance(LEADER_USER_ID, STARTER_WAVE_DANCE_ID)).toEqual({
				isAccepted = false,
				rejectionReason = "NotAllowedDuringRound",
			})
			expect(harness.sendSyncDance(LEADER_USER_ID, FIRST_FOLLOWER_USER_ID)).toEqual({
				isAccepted = false,
				rejectionReason = "NotAllowedDuringRound",
			})
			-- Results: off the stage again.
			harness.onThemedRoundStageAnswerByPlayerUserId[LEADER_USER_ID] = false
			expect(harness.sendStartDance(LEADER_USER_ID, STARTER_WAVE_DANCE_ID)).toEqual(ACCEPTED)
		end
	)

	it("ending the lobby dance of a player going on stage who is not dancing changes nothing", function()
		local harness = createHarnessWithLeaderAndTwoFollowers()
		harness.lobbyDanceCoordinator:endLobbyDanceOfPlayerGoingOnStage(OTHER_DANCER_USER_ID)
		expect(harness.recordedLobbyDanceStateChanges).toEqual({})
	end)
end)
