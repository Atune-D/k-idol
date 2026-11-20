-- LobbyDanceCoordinator RequestStartDanceInLobby (development spec §2.8, §2.13, §3.4): every
-- acceptance and rejection reason, the order of the checks, hostile values, plus `new` and the
-- reason lists. Sync and Stop are in LobbyDanceCoordinatorSyncAndStopRequests.spec.luau. Uses the REAL
-- save keeper and rate limiter (LobbyRequestRulesTestHarness).

local UnitTestFramework = require("../Support/UnitTestFramework")
local LobbyDanceCoordinator = require("../../src/server/LobbyDanceCoordinator")
local LobbyRequestRulesTestHarness = require("./LobbyRequestRulesTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local FIRST_PLAYER_USER_ID = LobbyRequestRulesTestHarness.FIRST_PLAYER_USER_ID
local SECOND_PLAYER_USER_ID = LobbyRequestRulesTestHarness.SECOND_PLAYER_USER_ID
local STARTER_WAVE_DANCE_ID = LobbyRequestRulesTestHarness.STARTER_WAVE_DANCE_ID
local STARTER_STEP_DANCE_ID = LobbyRequestRulesTestHarness.STARTER_STEP_DANCE_ID
local SHOP_TWIRL_DANCE_ID = LobbyRequestRulesTestHarness.SHOP_TWIRL_DANCE_ID
local RETIRED_DANCE_ID = LobbyRequestRulesTestHarness.RETIRED_DANCE_ID

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

describe("RequestStartDanceInLobby acceptance", function()
	it("an owned catalog dance starts now, following nobody, and listeners are told once", function()
		local harness = createHarnessWithLoadedPlayers()
		expect(harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)).toEqual(ACCEPTED)
		local expectedState = harness.buildExpectedLobbyDanceState(
			FIRST_PLAYER_USER_ID,
			STARTER_WAVE_DANCE_ID,
			harness.nowUnixMilliseconds(),
			nil
		)
		expect(harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID)).toEqual(expectedState)
		expect(harness.recordedLobbyDanceStateChanges).toEqual({
			{ playerUserId = FIRST_PLAYER_USER_ID, lobbyDanceState = expectedState },
		})
	end)

	it("changes no save (no revision bump, no save keeper event)", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		harness.sendStopDance(FIRST_PLAYER_USER_ID)
		expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(0)
		expect(harness.countSaveKeeperEvents("InMemorySaveDataChanged")).toBe(0)
	end)

	it("starting another dance replaces the dance and the start moment", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_STEP_DANCE_ID)
		expect(harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID)).toEqual(
			harness.buildExpectedLobbyDanceState(
				FIRST_PLAYER_USER_ID,
				STARTER_STEP_DANCE_ID,
				harness.nowUnixMilliseconds(),
				nil
			)
		)
		expect(#harness.recordedLobbyDanceStateChanges).toBe(2)
	end)

	it("starting the dance one already dances is accepted and changes nothing (same start moment, no event)", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		local startedAtUnixMilliseconds = harness.nowUnixMilliseconds()
		expect(harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)).toEqual(ACCEPTED)
		expect(
			harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID).danceStartedAtUnixMilliseconds
		).toBe(startedAtUnixMilliseconds)
		expect(#harness.recordedLobbyDanceStateChanges).toBe(1)
	end)

	it("a bought dance (given to ownedDanceIds) can be started", function()
		local harness = createHarnessWithLoadedPlayers()
		expect(harness.sendStartDance(FIRST_PLAYER_USER_ID, SHOP_TWIRL_DANCE_ID)).toEqual(rejectedWith("DanceNotOwned"))
		harness.giveDanceIds(FIRST_PLAYER_USER_ID, { SHOP_TWIRL_DANCE_ID })
		expect(harness.sendStartDance(FIRST_PLAYER_USER_ID, SHOP_TWIRL_DANCE_ID)).toEqual(ACCEPTED)
	end)
end)

describe("RequestStartDanceInLobby rejections", function()
	it("DanceNotOwned: a catalog dance the player does not own; nothing changes", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		expect(harness.sendStartDance(FIRST_PLAYER_USER_ID, SHOP_TWIRL_DANCE_ID)).toEqual(rejectedWith("DanceNotOwned"))
		expect(harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID).danceId).toBe(
			STARTER_WAVE_DANCE_ID
		)
		expect(#harness.recordedLobbyDanceStateChanges).toBe(1)
	end)

	it("DanceNotOwned: an owned dance that is no longer in the catalog", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.giveDanceIds(FIRST_PLAYER_USER_ID, { RETIRED_DANCE_ID })
		expect(harness.sendStartDance(FIRST_PLAYER_USER_ID, RETIRED_DANCE_ID)).toEqual(rejectedWith("DanceNotOwned"))
		expect(harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID)).toBeNil()
	end)

	it("DanceNotOwned for hostile danceId values, without raising", function()
		local harness = createHarnessWithLoadedPlayers()
		local cyclicTable = {}
		cyclicTable[1] = cyclicTable
		local hostileDanceIds = {
			{ "nil", nil },
			{ "a number", 1 },
			{ "NaN", 0 / 0 },
			{ "a table", { STARTER_WAVE_DANCE_ID } },
			{ "a cyclic table", cyclicTable },
			{
				"a table with a raising metatable",
				setmetatable({}, { __eq = error, __index = error, __tostring = error }),
			},
			{ "a function", function() end },
			{ "a huge string", string.rep(STARTER_WAVE_DANCE_ID, 100000) },
			{ "a differently cased id", "Starter_Wave" },
			{ "an id with a trailing space", STARTER_WAVE_DANCE_ID .. " " },
		}
		for _, hostileDanceIdCase in hostileDanceIds do
			local didAnswer, answerOrError = pcall(harness.sendStartDance, FIRST_PLAYER_USER_ID, hostileDanceIdCase[2])
			expect(didAnswer).toBeTrue()
			expect({ hostileDanceIdCase[1], answerOrError }).toEqual({
				hostileDanceIdCase[1],
				rejectedWith("DanceNotOwned"),
			})
		end
		expect(harness.recordedLobbyDanceStateChanges).toEqual({})
	end)

	it("a danceId longer than MAX_DANCE_ID_LENGTH is never looked up; one of exactly that length is", function()
		local harness = createHarnessWithLoadedPlayers()
		local maximumLength = LobbyDanceCoordinator.MAX_DANCE_ID_LENGTH
		expect(maximumLength).toBe(64)
		harness.sendStartDance(FIRST_PLAYER_USER_ID, string.rep("d", maximumLength + 1))
		expect(harness.recordingTestDanceCatalog.lookedUpDanceIds).toEqual({})
		harness.sendStartDance(FIRST_PLAYER_USER_ID, string.rep("d", maximumLength))
		expect(harness.recordingTestDanceCatalog.lookedUpDanceIds).toEqual({ string.rep("d", maximumLength) })
	end)

	it("NotAllowedDuringRound: the player is on the themed round stage; nothing changes", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.onThemedRoundStageAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = true
		expect(harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)).toEqual(
			rejectedWith("NotAllowedDuringRound")
		)
		expect(harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID)).toBeNil()
		expect(harness.askedOnThemedRoundStageUserIds).toEqual({ FIRST_PLAYER_USER_ID })
	end)

	it(
		"NotAllowedDuringRound comes before DanceNotOwned, and any answer other than false counts as on stage",
		function()
			local harness = createHarnessWithLoadedPlayers()
			harness.onThemedRoundStageAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = "maybe"
			expect(harness.sendStartDance(FIRST_PLAYER_USER_ID, SHOP_TWIRL_DANCE_ID)).toEqual(
				rejectedWith("NotAllowedDuringRound")
			)
			expect(harness.recordingTestDanceCatalog.lookedUpDanceIds).toEqual({})
			harness.onThemedRoundStageAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = function()
				return nil
			end
			expect(harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)).toEqual(
				rejectedWith("NotAllowedDuringRound")
			)
		end
	)

	it("SaveDataNotLoaded before the save loads, before the stage question, and once the player is leaving", function()
		local harness = LobbyRequestRulesTestHarness.createLobbyRequestRulesHarness()
		harness.onThemedRoundStageAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = true
		expect(harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)).toEqual(
			rejectedWith("SaveDataNotLoaded")
		)
		expect(harness.askedOnThemedRoundStageUserIds).toEqual({})
		harness.loadNewPlayer(FIRST_PLAYER_USER_ID)
		harness.onThemedRoundStageAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = false
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(FIRST_PLAYER_USER_ID)
		expect(harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)).toEqual(
			rejectedWith("SaveDataNotLoaded")
		)
	end)

	it("TooManyRequests within 0.5 s, asked first, changing nothing; exactly 0.5 s later is accepted", function()
		local harness = LobbyRequestRulesTestHarness.createLobbyRequestRulesHarness()
		local coordinator = harness.lobbyDanceCoordinator
		expect(coordinator:answerStartDanceInLobbyRequest(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)).toEqual(
			rejectedWith("SaveDataNotLoaded")
		)
		harness.loadNewPlayer(FIRST_PLAYER_USER_ID) -- takes no time
		expect(coordinator:answerStartDanceInLobbyRequest(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)).toEqual(
			rejectedWith("TooManyRequests")
		)
		harness.advanceSeconds(0.499)
		expect(coordinator:answerStartDanceInLobbyRequest(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)).toEqual(
			rejectedWith("TooManyRequests")
		)
		expect(coordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID)).toBeNil()
		expect(harness.askedOnThemedRoundStageUserIds).toEqual({})
		harness.advanceSeconds(0.001)
		expect(coordinator:answerStartDanceInLobbyRequest(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)).toEqual(
			ACCEPTED
		)
	end)

	it("builds a fresh answer table every time", function()
		local harness = createHarnessWithLoadedPlayers()
		local firstAnswer = harness.sendStartDance(FIRST_PLAYER_USER_ID, SHOP_TWIRL_DANCE_ID)
		local secondAnswer = harness.sendStartDance(FIRST_PLAYER_USER_ID, SHOP_TWIRL_DANCE_ID)
		expect(firstAnswer ~= secondAnswer).toBeTrue()
		local firstAcceptance = harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		local secondAcceptance = harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		expect(firstAcceptance ~= secondAcceptance).toBeTrue()
	end)
end)

describe("RequestStartDanceInLobby edge cases", function()
	it("an on-stage player who still has a lobby dance state (wiring not yet called) cannot start a dance", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		harness.onThemedRoundStageAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = true
		expect(harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_STEP_DANCE_ID)).toEqual(
			rejectedWith("NotAllowedDuringRound")
		)
		expect(harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID).danceId).toBe(
			STARTER_WAVE_DANCE_ID
		)
	end)

	it("SaveDataNotLoaded, without raising, when the player starts leaving during the stage question", function()
		local harness = createHarnessWithLoadedPlayers()
		harness.onThemedRoundStageAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = function(playerUserId)
			harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(playerUserId)
			return false
		end
		local didAnswer, answerOrError = pcall(harness.sendStartDance, FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)
		expect(didAnswer).toBeTrue()
		expect(answerOrError).toEqual(rejectedWith("SaveDataNotLoaded"))
		expect(harness.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(FIRST_PLAYER_USER_ID)).toBeNil()
	end)

	it("SaveDataNotLoaded when the keeper answers loaded but has no readable save copy", function()
		local harness = LobbyRequestRulesTestHarness.createLobbyRequestRulesHarness({
			replacementSaveKeeperMethodsByName = {
				readPlayerSaveDataCopy = function()
					return nil
				end,
			},
		})
		harness.loadNewPlayer(FIRST_PLAYER_USER_ID)
		expect(harness.sendStartDance(FIRST_PLAYER_USER_ID, STARTER_WAVE_DANCE_ID)).toEqual(
			rejectedWith("SaveDataNotLoaded")
		)
	end)
end)

describe("LobbyDanceCoordinator.new and reason lists", function()
	it("raises when a dependency is missing", function()
		local dependencyNames = {
			"playerSaveDataKeeper",
			"playerRequestRateLimiter",
			"danceCatalog",
			"clock",
			"isPlayerOnThemedRoundStage",
			"logger",
		}
		for _, missingDependencyName in dependencyNames do
			local dependencies = {}
			for _, dependencyName in dependencyNames do
				dependencies[dependencyName] = {}
			end
			dependencies[missingDependencyName] = nil
			expect(function()
				LobbyDanceCoordinator.new(dependencies)
			end).toThrow("missing dependency " .. missingDependencyName)
		end
	end)

	it("lists exactly the §2.8 reasons plus TooManyRequests (§2.13) and SaveDataNotLoaded (§3.4), frozen", function()
		local function listSortedReasons(rejectionReasons)
			local listedRejectionReasons = {}
			for reasonName, rejectionReason in rejectionReasons do
				expect(reasonName).toBe(rejectionReason)
				table.insert(listedRejectionReasons, rejectionReason)
			end
			table.sort(listedRejectionReasons)
			return listedRejectionReasons
		end
		expect(listSortedReasons(LobbyDanceCoordinator.START_DANCE_IN_LOBBY_REJECTION_REASONS)).toEqual({
			"DanceNotOwned",
			"NotAllowedDuringRound",
			"SaveDataNotLoaded",
			"TooManyRequests",
		})
		expect(listSortedReasons(LobbyDanceCoordinator.SYNC_DANCE_WITH_PLAYER_REJECTION_REASONS)).toEqual({
			"NotAllowedDuringRound",
			"SaveDataNotLoaded",
			"TargetNotDancing",
			"TooManyRequests",
		})
		expect(listSortedReasons(LobbyDanceCoordinator.STOP_DANCE_IN_LOBBY_REJECTION_REASONS)).toEqual({
			"TooManyRequests",
		})
		expect(table.isfrozen(LobbyDanceCoordinator.START_DANCE_IN_LOBBY_REJECTION_REASONS)).toBeTrue()
		expect(table.isfrozen(LobbyDanceCoordinator.SYNC_DANCE_WITH_PLAYER_REJECTION_REASONS)).toBeTrue()
		expect(table.isfrozen(LobbyDanceCoordinator.STOP_DANCE_IN_LOBBY_REJECTION_REASONS)).toBeTrue()
	end)
end)
