-- LobbyDanceCoordinator subscriptions, reads for a device that has just joined, and forgetting a
-- player who leaves: listeners that raise, unsubscribe themselves or others while being told, or
-- read the coordinator while being told; frozen and fresh read results; hostile read arguments.

local UnitTestFramework = require("../Support/UnitTestFramework")
local LobbyDanceCoordinator = require("../../src/server/LobbyDanceCoordinator")
local LobbyRequestRulesTestHarness = require("./LobbyRequestRulesTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local FIRST_PLAYER_USER_ID = LobbyRequestRulesTestHarness.FIRST_PLAYER_USER_ID
local SECOND_PLAYER_USER_ID = LobbyRequestRulesTestHarness.SECOND_PLAYER_USER_ID
local THIRD_PLAYER_USER_ID = LobbyRequestRulesTestHarness.THIRD_PLAYER_USER_ID
local STARTER_WAVE_DANCE_ID = LobbyRequestRulesTestHarness.STARTER_WAVE_DANCE_ID
local STARTER_STEP_DANCE_ID = LobbyRequestRulesTestHarness.STARTER_STEP_DANCE_ID

local function createHarnessWithThreeLoadedPlayers()
	local harness = LobbyRequestRulesTestHarness.createLobbyRequestRulesHarness()
	for _, playerUserId in { FIRST_PLAYER_USER_ID, SECOND_PLAYER_USER_ID, THIRD_PLAYER_USER_ID } do
		harness.loadNewPlayer(playerUserId)
	end
	return harness
end

describe("subscribeToLobbyDanceStateChanged", function()
	it("a listener that raises is logged and does not stop later listeners or the change", function()
		local harness = createHarnessWithThreeLoadedPlayers()
		local laterListenerCalls = {}
		harness.lobbyDanceCoordinator:subscribeToLobbyDanceStateChanged(function()
			error("listener exploded")
		end)
		harness.lobbyDanceCoordinator:subscribeToLobbyDanceStateChanged(function(playerUserId, lobbyDanceState)
			table.insert(laterListenerCalls, { playerUserId, lobbyDanceState and lobbyDanceState.danceId })
		end)
		expect(harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)).toEqual({ isAccepted = true })
		expect(laterListenerCalls).toEqual({ { FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID } })
		expect(#harness.coordinatorWarnings).toBe(1)
		expect(string.find(harness.coordinatorWarnings[1], "listener exploded", 1, true) ~= nil).toBeTrue()
		expect(string.find(harness.coordinatorWarnings[1], tostring(FIRST_PLAYER_USER_ID), 1, true) ~= nil).toBeTrue()
		expect(harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID).danceId).toBe(
			STARTER_WAVE_DANCE_ID
		)
	end)

	it("a raising listener is logged once per change, including each follower's change", function()
		local harness = createHarnessWithThreeLoadedPlayers()
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		harness.sendSyncDance(SECOND_PLAYER_USER_ID, FIRST_PLAYER_USER_ID)
		harness.lobbyDanceCoordinator:subscribeToLobbyDanceStateChanged(function()
			error("listener exploded")
		end)
		harness.sendStopDance(FIRST_PLAYER_USER_ID)
		expect(#harness.coordinatorWarnings).toBe(2)
		expect(string.find(harness.coordinatorWarnings[2], tostring(SECOND_PLAYER_USER_ID), 1, true) ~= nil).toBeTrue()
	end)

	it("a listener that unsubscribes itself while being told does not make the next listener miss it", function()
		local harness = createHarnessWithThreeLoadedPlayers()
		local selfRemovingListenerCallCount, nextListenerCallCount = 0, 0
		local unsubscribeSelfRemovingListener
		unsubscribeSelfRemovingListener = harness.lobbyDanceCoordinator:subscribeToLobbyDanceStateChanged(function()
			selfRemovingListenerCallCount += 1
			unsubscribeSelfRemovingListener()
		end)
		harness.lobbyDanceCoordinator:subscribeToLobbyDanceStateChanged(function()
			nextListenerCallCount += 1
		end)
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		expect({ selfRemovingListenerCallCount, nextListenerCallCount }).toEqual({ 1, 1 })
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_STEP_DANCE_ID)
		expect({ selfRemovingListenerCallCount, nextListenerCallCount }).toEqual({ 1, 2 })
		expect(#harness.recordedLobbyDanceStateChanges).toBe(2) -- the harness's own listener, subscribed first
	end)

	it(
		"a listener that unsubscribes a later listener: that listener still gets the change in progress, nothing after",
		function()
			local harness = createHarnessWithThreeLoadedPlayers()
			local laterListenerCallCount = 0
			local unsubscribeLaterListener
			harness.lobbyDanceCoordinator:subscribeToLobbyDanceStateChanged(function()
				if unsubscribeLaterListener then
					unsubscribeLaterListener()
				end
			end)
			unsubscribeLaterListener = harness.lobbyDanceCoordinator:subscribeToLobbyDanceStateChanged(function()
				laterListenerCallCount += 1
			end)
			harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
			harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_STEP_DANCE_ID)
			expect(laterListenerCallCount).toBe(1)
		end
	)

	it("unsubscribing twice is harmless and removes nothing else", function()
		local harness = createHarnessWithThreeLoadedPlayers()
		local unsubscribe = harness.lobbyDanceCoordinator:subscribeToLobbyDanceStateChanged(function() end)
		unsubscribe()
		unsubscribe()
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		expect(#harness.recordedLobbyDanceStateChanges).toBe(1)
	end)

	it("a listener reading the coordinator while told about the leader already sees the followers ended", function()
		local harness = createHarnessWithThreeLoadedPlayers()
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		harness.sendSyncDance(SECOND_PLAYER_USER_ID, FIRST_PLAYER_USER_ID)
		local followerStateSeenDuringLeaderChange = "not told"
		harness.lobbyDanceCoordinator:subscribeToLobbyDanceStateChanged(function(playerUserId)
			if playerUserId == FIRST_PLAYER_USER_ID then
				followerStateSeenDuringLeaderChange =
					harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(SECOND_PLAYER_USER_ID)
			end
		end)
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_STEP_DANCE_ID)
		expect(followerStateSeenDuringLeaderChange).toBeNil()
	end)

	it(
		"a listener that makes a request while told: every listener hears every change once, in applied order",
		function()
			local harness = createHarnessWithThreeLoadedPlayers()
			local coordinator = harness.lobbyDanceCoordinator
			harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
			harness.sendSyncDance(SECOND_PLAYER_USER_ID, FIRST_PLAYER_USER_ID)
			table.clear(harness.recordedLobbyDanceStateChanges)
			local reactingListenerChanges, laterListenerChanges = {}, {}
			local nestedAnswer
			coordinator:subscribeToLobbyDanceStateChanged(function(playerUserId, lobbyDanceState)
				table.insert(
					reactingListenerChanges,
					{ playerUserId = playerUserId, lobbyDanceState = lobbyDanceState }
				)
				if playerUserId == FIRST_PLAYER_USER_ID and lobbyDanceState == nil then
					nestedAnswer =
						coordinator:answerStartDanceInLobbyRequest(SECOND_PLAYER_USER_ID, STARTER_STEP_DANCE_ID)
				end
			end)
			coordinator:subscribeToLobbyDanceStateChanged(function(playerUserId, lobbyDanceState)
				table.insert(laterListenerChanges, { playerUserId = playerUserId, lobbyDanceState = lobbyDanceState })
			end)
			harness.sendStopDance(FIRST_PLAYER_USER_ID)
			expect(nestedAnswer).toEqual({ isAccepted = true })
			local secondPlayerState = coordinator:readLobbyDanceStateOfPlayer(SECOND_PLAYER_USER_ID)
			expect(secondPlayerState.danceId).toBe(STARTER_STEP_DANCE_ID)
			local expectedChanges = {
				{ playerUserId = FIRST_PLAYER_USER_ID, lobbyDanceState = nil },
				{ playerUserId = SECOND_PLAYER_USER_ID, lobbyDanceState = nil },
				{ playerUserId = SECOND_PLAYER_USER_ID, lobbyDanceState = secondPlayerState },
			}
			expect(harness.recordedLobbyDanceStateChanges).toEqual(expectedChanges)
			expect(reactingListenerChanges).toEqual(expectedChanges)
			expect(laterListenerChanges).toEqual(expectedChanges)
		end
	)

	it("after a nested change, later changes are told normally (the queue is emptied)", function()
		local harness = createHarnessWithThreeLoadedPlayers()
		local coordinator = harness.lobbyDanceCoordinator
		local hasReacted = false
		coordinator:subscribeToLobbyDanceStateChanged(function(playerUserId)
			if playerUserId == FIRST_PLAYER_USER_ID and not hasReacted then
				hasReacted = true
				coordinator:endLobbyDanceOfPlayerGoingOnStage(FIRST_PLAYER_USER_ID)
			end
		end)
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		expect(#harness.recordedLobbyDanceStateChanges).toBe(2)
		harness.sendStartDance(THIRD_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		expect(#harness.recordedLobbyDanceStateChanges).toBe(3)
		expect(harness.recordedLobbyDanceStateChanges[3].playerUserId).toBe(THIRD_PLAYER_USER_ID)
	end)

	it("a logger that raises: the error reaches the caller and later changes are still told once", function()
		local harness = createHarnessWithThreeLoadedPlayers()
		local coordinatorWithRaisingLogger = LobbyDanceCoordinator.new({
			playerSaveDataKeeper = harness.playerSaveDataKeeper,
			playerRequestRateLimiter = harness.playerRequestRateLimiter,
			danceCatalog = harness.recordingTestDanceCatalog,
			clock = harness.fakeClock,
			isPlayerOnThemedRoundStage = function()
				return false
			end,
			logger = {
				logWarning = function()
					error("logger is down")
				end,
			},
		})
		local unsubscribeRaisingListener = coordinatorWithRaisingLogger:subscribeToLobbyDanceStateChanged(function()
			error("listener exploded")
		end)
		harness.advanceSeconds(1)
		expect(function()
			coordinatorWithRaisingLogger:answerStartDanceInLobbyRequest(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		end).toThrow("logger is down")
		unsubscribeRaisingListener()
		local toldChanges = {}
		coordinatorWithRaisingLogger:subscribeToLobbyDanceStateChanged(function(playerUserId, lobbyDanceState)
			table.insert(toldChanges, { playerUserId, lobbyDanceState and lobbyDanceState.danceId })
		end)
		harness.advanceSeconds(1)
		coordinatorWithRaisingLogger:answerStartDanceInLobbyRequest(FIRST_PLAYER_USER_ID, STARTER_STEP_DANCE_ID)
		expect(toldChanges).toEqual({ { FIRST_PLAYER_USER_ID, STARTER_STEP_DANCE_ID } })
	end)

	it("listeners receive the frozen state that reads return", function()
		local harness = createHarnessWithThreeLoadedPlayers()
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		local receivedLobbyDanceState = harness.recordedLobbyDanceStateChanges[1].lobbyDanceState
		expect(table.isfrozen(receivedLobbyDanceState)).toBeTrue()
		expect(receivedLobbyDanceState).toBe(
			harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID)
		)
		expect(function()
			receivedLobbyDanceState.danceId = STARTER_STEP_DANCE_ID
		end).toThrow()
	end)

	it("raises for a listener that is not a function", function()
		local harness = createHarnessWithThreeLoadedPlayers()
		expect(function()
			harness.lobbyDanceCoordinator:subscribeToLobbyDanceStateChanged("not a function")
		end).toThrow("listener must be a function")
	end)
end)

describe("Reads for a device that has just joined", function()
	it("readEveryLobbyDancerState lists every dancer, sorted by player id, leaders and followers alike", function()
		local harness = createHarnessWithThreeLoadedPlayers()
		harness.sendStartDance(THIRD_PLAYER_USER_ID, STARTER_STEP_DANCE_ID)
		local thirdStartedAtUnixMilliseconds = harness.nowUnixMilliseconds()
		harness.sendStartDance(SECOND_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		local secondStartedAtUnixMilliseconds = harness.nowUnixMilliseconds()
		harness.sendSyncDance(FIRST_PLAYER_USER_ID, SECOND_PLAYER_USER_ID)
		expect(harness.lobbyDanceCoordinator:readEveryLobbyDancerState()).toEqual({
			harness.buildExpectedLobbyDanceState(
				FIRST_PLAYER_USER_ID,
				STARTER_WAVE_DANCE_ID,
				secondStartedAtUnixMilliseconds,
				SECOND_PLAYER_USER_ID
			),
			harness.buildExpectedLobbyDanceState(
				SECOND_PLAYER_USER_ID,
				STARTER_WAVE_DANCE_ID,
				secondStartedAtUnixMilliseconds,
				nil
			),
			harness.buildExpectedLobbyDanceState(
				THIRD_PLAYER_USER_ID,
				STARTER_STEP_DANCE_ID,
				thirdStartedAtUnixMilliseconds,
				nil
			),
		})
	end)

	it("returns a new frozen list each time, empty when nobody dances", function()
		local harness = createHarnessWithThreeLoadedPlayers()
		local emptyDancerStates = harness.lobbyDanceCoordinator:readEveryLobbyDancerState()
		expect(emptyDancerStates).toEqual({})
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		local firstDancerStates = harness.lobbyDanceCoordinator:readEveryLobbyDancerState()
		local secondDancerStates = harness.lobbyDanceCoordinator:readEveryLobbyDancerState()
		expect(firstDancerStates ~= secondDancerStates).toBeTrue()
		expect(table.isfrozen(firstDancerStates)).toBeTrue()
		expect(table.isfrozen(firstDancerStates[1])).toBeTrue()
		expect(emptyDancerStates).toEqual({})
		expect(function()
			table.insert(firstDancerStates, firstDancerStates[1])
		end).toThrow()
	end)

	it(
		"readLobbyDanceStateOfPlayer answers nil for any value that is not a dancing player's id, without raising",
		function()
			local harness = createHarnessWithThreeLoadedPlayers()
			harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
			for _, hostilePlayerUserId in
				{ SECOND_PLAYER_USER_ID, tostring(FIRST_PLAYER_USER_ID), 0 / 0, math.huge, {}, false }
			do
				expect(harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(hostilePlayerUserId)).toBeNil()
			end
		end
	)
end)

describe("forgetPlayer (a player who leaves the server is forgotten)", function()
	it("a dancing player: their state ends, listeners are told nil, and reads no longer list them", function()
		local harness = createHarnessWithThreeLoadedPlayers()
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		harness.sendStartDance(SECOND_PLAYER_USER_ID, STARTER_STEP_DANCE_ID)
		harness.lobbyDanceCoordinator:forgetPlayer(FIRST_PLAYER_USER_ID)
		expect(harness.recordedLobbyDanceStateChanges[3]).toEqual({
			playerUserId = FIRST_PLAYER_USER_ID,
			lobbyDanceState = nil,
		})
		expect(harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID)).toBeNil()
		expect(#harness.lobbyDanceCoordinator:readEveryLobbyDancerState()).toBe(1)
	end)

	it("a follower who leaves: only the follower is forgotten, the leader dances on", function()
		local harness = createHarnessWithThreeLoadedPlayers()
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		harness.sendSyncDance(SECOND_PLAYER_USER_ID, FIRST_PLAYER_USER_ID)
		harness.lobbyDanceCoordinator:forgetPlayer(SECOND_PLAYER_USER_ID)
		expect(harness.recordedLobbyDanceStateChanges[3]).toEqual({
			playerUserId = SECOND_PLAYER_USER_ID,
			lobbyDanceState = nil,
		})
		expect(#harness.recordedLobbyDanceStateChanges).toBe(3)
		expect(harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID).danceId).toBe(
			STARTER_WAVE_DANCE_ID
		)
	end)

	it("a player who is not dancing: nothing happens and no listener is told", function()
		local harness = createHarnessWithThreeLoadedPlayers()
		harness.lobbyDanceCoordinator:forgetPlayer(FIRST_PLAYER_USER_ID)
		harness.lobbyDanceCoordinator:forgetPlayer(FIRST_PLAYER_USER_ID + 999)
		expect(harness.recordedLobbyDanceStateChanges).toEqual({})
	end)

	it("a forgotten player can no longer be synced with", function()
		local harness = createHarnessWithThreeLoadedPlayers()
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		harness.lobbyDanceCoordinator:forgetPlayer(FIRST_PLAYER_USER_ID)
		expect(harness.sendSyncDance(SECOND_PLAYER_USER_ID, FIRST_PLAYER_USER_ID)).toEqual({
			isAccepted = false,
			rejectionReason = "TargetNotDancing",
		})
	end)
end)
