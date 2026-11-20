local UnitTestFramework = require("../Support/UnitTestFramework")
local RecordingLogger = require("../Support/RecordingLogger")
local PlayerServerLifecycleSequences = require("../../src/server/PlayerServerLifecycleSequences")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = 77

-- Every dependency records "<module>.<method>" into one shared call log, in call order.
local function createRecordingDependencies(failingCallName: string?)
	local callLog = {}
	local function recordingModule(moduleName: string, extraMethods: { [string]: any }?)
		return setmetatable(extraMethods or {}, {
			__index = function(_, methodName: string)
				return function()
					local callName = moduleName .. "." .. methodName
					table.insert(callLog, callName)
					if callName == failingCallName then
						error("deliberate failure of " .. callName)
					end
				end
			end,
		})
	end
	local finalSaveCallbacks = {}
	local dependencies = {
		playerSaveDataKeeper = recordingModule("keeper", {
			startFinalSavesForServerShutdown = function(_, onEveryFinalSaveFinished)
				table.insert(callLog, "keeper.startFinalSavesForServerShutdown")
				if failingCallName == "keeper.startFinalSavesForServerShutdown" then
					error("deliberate failure")
				end
				table.insert(finalSaveCallbacks, onEveryFinalSaveFinished)
			end,
		}),
		themedRoundReferee = recordingModule("referee", {
			readRoundStateChangedMessage = function()
				table.insert(callLog, "referee.readRoundStateChangedMessage")
				return { roundPhase = "Styling" }
			end,
		}),
		themedRoundClock = recordingModule("clock"),
		dailyProgressTracker = recordingModule("tracker"),
		lobbyDanceCoordinator = recordingModule("coordinator"),
		logger = RecordingLogger.new(),
		sendRoundStateChangedToPlayer = function(playerUserId, message)
			table.insert(callLog, string.format("send RoundStateChanged %d %s", playerUserId, message.roundPhase))
		end,
		forgetPlayerOnLeavingServerCallbacks = {
			function(playerUserId)
				table.insert(callLog, "presenter.forget " .. playerUserId)
			end,
		},
	}
	return dependencies, callLog, finalSaveCallbacks
end

describe("PlayerServerLifecycleSequences", function()
	it("on joining starts loading the save at once, then sends RoundStateChanged to that player", function()
		local dependencies, callLog = createRecordingDependencies()
		PlayerServerLifecycleSequences.new(dependencies):handlePlayerJoinedServer(PLAYER)
		expect(callLog).toEqual({
			"keeper.startLoadingPlayerSaveData",
			"referee.readRoundStateChangedMessage",
			"send RoundStateChanged 77 Styling",
		})
	end)

	it("on leaving runs tracker, referee, dance coordinator, forgetters, then the final save, in that order", function()
		local dependencies, callLog = createRecordingDependencies()
		PlayerServerLifecycleSequences.new(dependencies):handlePlayerLeavingServer(PLAYER)
		expect(callLog).toEqual({
			"tracker.recordCountedPlaytimeAndStopCountingBeforeFinalSave",
			"referee.removePlayerWhoLeftServer",
			"coordinator.forgetPlayer",
			"presenter.forget 77",
			"keeper.startFinalSaveForLeavingPlayer",
		})
	end)

	it("still starts the final save when an earlier leaving step raises, and logs the failure", function()
		local dependencies, callLog = createRecordingDependencies("referee.removePlayerWhoLeftServer")
		PlayerServerLifecycleSequences.new(dependencies):handlePlayerLeavingServer(PLAYER)
		expect(callLog[#callLog]).toBe("keeper.startFinalSaveForLeavingPlayer")
		expect(dependencies.logger:countWarningsContaining("deliberate failure of referee.removePlayerWhoLeftServer")).toBe(
			1
		)
	end)

	it(
		"on shutdown tells the referee first, stops the clock, records playtime, then starts every final save",
		function()
			local dependencies, callLog, finalSaveCallbacks = createRecordingDependencies()
			local sequences = PlayerServerLifecycleSequences.new(dependencies)
			local finishedCount = 0
			sequences:startServerShutdownSequence(function()
				finishedCount += 1
			end)
			expect(callLog).toEqual({
				"referee.beginServerShutdown",
				"clock.stopRoundCycle",
				"tracker.recordCountedPlaytimeOfEveryPlayerAndStopCountingBeforeShutdown",
				"keeper.startFinalSavesForServerShutdown",
			})
			expect(finishedCount).toBe(0)
			finalSaveCallbacks[1]()
			expect(finishedCount).toBe(1)
			expect(sequences:hasServerShutdownStarted()).toBeTrue()
		end
	)

	it("does nothing on a second shutdown call", function()
		local dependencies, callLog = createRecordingDependencies()
		local sequences = PlayerServerLifecycleSequences.new(dependencies)
		sequences:startServerShutdownSequence(function() end)
		local callCountAfterFirst = #callLog
		sequences:startServerShutdownSequence(function() end)
		expect(#callLog).toBe(callCountAfterFirst)
	end)

	it("calls the shutdown callback at once when the final saves could not even start", function()
		local dependencies = createRecordingDependencies("keeper.startFinalSavesForServerShutdown")
		local finishedCount = 0
		PlayerServerLifecycleSequences.new(dependencies):startServerShutdownSequence(function()
			finishedCount += 1
		end)
		expect(finishedCount).toBe(1)
	end)

	it("raises naming a missing dependency", function()
		local dependencies = createRecordingDependencies()
		dependencies.lobbyDanceCoordinator = nil
		expect(function()
			PlayerServerLifecycleSequences.new(dependencies)
		end).toThrow("missing lobbyDanceCoordinator")
	end)
end)
