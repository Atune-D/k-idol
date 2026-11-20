-- ThemedRoundReferee, routing SetRoundOutfitDraft to the round's draft keeper (development spec
-- §2.3 check 1, §2.13, §3.3), its construction and argument checks, and rounds it cannot referee.
-- Referee-level parts of audit PART 3 scenarios 10, 14 and 41 (the draft protocol itself is
-- covered by the RoundOutfitDraftKeeper*.spec files), PART 1 questions 4 and 6.

local UnitTestFramework = require("../Support/UnitTestFramework")
local ThemedRoundOwnerDecisions = require("../../src/server/ThemedRoundOwnerDecisions")
local ThemedRoundReferee = require("../../src/server/ThemedRoundReferee")
local ThemedRoundRefereeTestHarness = require("./ThemedRoundRefereeTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_P = ThemedRoundRefereeTestHarness.PLAYER_P
local PLAYER_Q = ThemedRoundRefereeTestHarness.PLAYER_Q
local OUTFIT_A = ThemedRoundRefereeTestHarness.OUTFIT_A
local OUTFIT_C = ThemedRoundRefereeTestHarness.OUTFIT_C
local OUTFIT_D = ThemedRoundRefereeTestHarness.OUTFIT_D
local INVALID_OUTFIT_X = ThemedRoundRefereeTestHarness.INVALID_OUTFIT_X
local createRefereeWithFakes = ThemedRoundRefereeTestHarness.createRefereeWithFakes

describe("ThemedRoundReferee draft routing", function()
	it("scenario 10: a draft from a player who never joined never reaches the draft keeper", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.loadPlayer(PLAYER_Q)
		harness.sendDraftAtRoundSecond(20, PLAYER_Q, 1, OUTFIT_A)
		expect(harness.countDraftsReachingKeeperFrom(PLAYER_Q)).toBe(0)
		expect(harness.countingOutfitValidator.validationCallCount).toBe(0)
		harness.sendDraftAtRoundSecond(21, PLAYER_P, 1, OUTFIT_A)
		expect(harness.countDraftsReachingKeeperFrom(PLAYER_P)).toBe(1)
		harness.advanceToRoundSecond(251)
		expect(harness.countGrantCallsFor(PLAYER_Q)).toBe(0)
		expect(#harness.listPublishedRoundResultsMessages()[1].roundResults).toBe(1)
	end)

	it("hands a participant's draft to the keeper during ThemeReveal too, where check 1 ignores it", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(9.6, PLAYER_P, 1, OUTFIT_A)
		expect(harness.countDraftsReachingKeeperFrom(PLAYER_P)).toBe(1)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(0)
		harness.sendDraftAtRoundSecond(10.6, PLAYER_P, 1, OUTFIT_A)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
	end)

	it("runs the draft keeper on the referee's clock: re-sent acknowledgements 1 s apart both go out", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(21, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(22, PLAYER_P, 1, OUTFIT_A)
		local acknowledgements = harness.listAcknowledgementsSentTo(PLAYER_P)
		expect(#acknowledgements).toBe(3)
		expect(acknowledgements[3].roundMilliseconds).toBe(22000)
	end)

	it(
		"scenario 14: drafts after Styling get no acknowledgement and the result is computed from the kept draft",
		function()
			local harness = createRefereeWithFakes()
			harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
			harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_C)
			for _, lateRoundSecond in { 190.5, 249, 255, 275 } do
				harness.sendDraftAtRoundSecond(lateRoundSecond, PLAYER_P, 9, OUTFIT_D)
			end
			expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
			local roundResultsEntry = harness.listPublishedRoundResultsMessages()[1].roundResults[1]
			expect(roundResultsEntry.outfitScore).toBe(21)
			expect(harness.recordedGrantCalls[1].themedRoundCompletion.scoredOutfitStylingItemKeys).toEqual(OUTFIT_C)
		end
	)

	it("scenario 41: drafts never touch the save: no change, no revision bump, no storage operation", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.advanceToRoundSecond(20)
		local revisionBefore = harness.readInMemoryChangeRevision(PLAYER_P)
		local storageOperationsBefore = harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER_P)
		local outfitCycle = { OUTFIT_A, INVALID_OUTFIT_X, OUTFIT_C, {} }
		for draftNumber = 1, 50 do
			harness.sendDraftAtRoundSecond(
				20 + draftNumber * 0.3,
				PLAYER_P,
				if draftNumber % 5 == 0 then draftNumber - 1 else draftNumber,
				outfitCycle[draftNumber % #outfitCycle + 1]
			)
		end
		harness.advanceToRoundSecond(110)
		expect(harness.readInMemoryChangeRevision(PLAYER_P)).toBe(revisionBefore)
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER_P)).toBe(storageOperationsBefore)
		expect(harness.countingOutfitValidator.validationCallCount > 0).toBeTrue()
	end)
end)

describe("ThemedRoundReferee rounds it does not referee", function()
	it("a referee created mid-round leaves that round alone and referees the next one", function()
		local harness = createRefereeWithFakes()
		harness.advanceToRoundSecond(50)
		local lateSentRoundStateChangedMessages = {}
		local lateRefereeDependencies = table.clone(harness.refereeDependencies)
		lateRefereeDependencies.sendRoundStateChangedToEveryDevice = function(roundStateChangedMessage)
			table.insert(lateSentRoundStateChangedMessages, roundStateChangedMessage)
		end
		local lateReferee = ThemedRoundReferee.new(lateRefereeDependencies)
		harness.loadPlayer(PLAYER_P)
		expect(lateReferee:admitOrRejectJoinCurrentRoundRequest(PLAYER_P)).toEqual({
			isAccepted = false,
			rejectionReason = "RoundNotJoinableNow",
		})
		lateReferee:receiveSetRoundOutfitDraftFromDevice(PLAYER_P, harness.buildOutfitDraftMessage(1, OUTFIT_A))
		expect(lateReferee:readRoundStateChangedMessage().participantUserIds).toEqual({})
		harness.advanceToRoundSecond(190)
		expect(lateSentRoundStateChangedMessages[1].participantUserIds).toEqual({})
		harness.advanceToRoundSecond(281)
		expect(lateReferee:admitOrRejectJoinCurrentRoundRequest(PLAYER_P)).toEqual({ isAccepted = true })
	end)

	it("a round whose theme is not in the catalog is logged and not refereed; the next round is", function()
		local harness = createRefereeWithFakes({
			findThemeByThemeId = function(themeId: string)
				if themeId == "y2k_pop" then
					return nil
				end
				return require("../../src/shared/ThemeCatalog").findThemeByThemeId(themeId)
			end,
		})
		harness.loadPlayer(PLAYER_P)
		expect(harness.joinAtRoundSecond(3, PLAYER_P)).toEqual({
			isAccepted = false,
			rejectionReason = "RoundNotJoinableNow",
		})
		expect(#harness.recordingLogger.loggedWarnings).toBe(1)
		expect(string.find(harness.recordingLogger.loggedWarnings[1], "y2k_pop", 1, true) ~= nil).toBeTrue()
		expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({})
		expect(table.isfrozen(harness.referee:listCurrentRoundParticipantUserIds())).toBeTrue()
		expect(harness.referee:isParticipantOfCurrentRound(PLAYER_P)).toBeFalse()
		expect(harness.referee:readCharacterSpawnRoundFacts(PLAYER_P)).toEqual({
			roundPhase = "ThemeReveal",
			isParticipant = false,
		})
		harness.advanceToRoundSecond(279)
		expect(#harness.sentRoundResultsPublishedRecords).toBe(0)
		expect(#harness.sentRoundStateChangedRecords).toBe(5)
		expect(harness.joinAtRoundSecond(281, PLAYER_P)).toEqual({ isAccepted = true })
	end)
end)

describe("ThemedRoundReferee late phase notifications", function()
	it("a late ThemeReveal of the previous round leaves the round in progress untouched", function()
		local harness = createRefereeWithFakes()
		local roundOneThemeRevealState = harness.readCurrentRoundState()
		harness.loadPlayers({ PLAYER_P, PLAYER_Q })
		expect(harness.joinAtRoundSecond(283, PLAYER_P)).toEqual({ isAccepted = true })
		harness.sendDraftAtRoundSecond(295, PLAYER_P, 1, OUTFIT_A)
		local roundTwoDraftKeeper = harness.createdDraftKeepers[2]
		harness.redeliverRoundPhaseChangeToReferee(roundOneThemeRevealState)
		expect(#harness.createdDraftKeepers).toBe(2)
		expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({ PLAYER_P })
		expect(roundTwoDraftKeeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_A)
		harness.sendDraftAtRoundSecond(296, PLAYER_P, 2, OUTFIT_C)
		local acknowledgements = harness.listAcknowledgementsSentTo(PLAYER_P)
		expect(acknowledgements[#acknowledgements]).toEqual(
			ThemedRoundRefereeTestHarness.expectedAcknowledgement(296, "round-2", 2, true)
		)
		expect(harness.joinAtRoundSecond(297, PLAYER_Q)).toEqual({ isAccepted = true })
		harness.advanceToRoundSecond(470)
		expect(harness.referee:readShowcaseStageEntry(PLAYER_P).scoredOutfitStylingItemKeys).toEqual(OUTFIT_C)
	end)

	it("the same ThemeReveal delivered twice keeps the round's participants and draft keeper", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.redeliverRoundPhaseChangeToReferee(harness.readCurrentRoundState())
		expect(#harness.createdDraftKeepers).toBe(1)
		expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({ PLAYER_P })
	end)
end)

describe("ThemedRoundReferee after the round clock stopped", function()
	it("routes no draft and answers no participation for the round the clock left", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		harness.themedRoundClock:stopRoundCycle()
		harness.sendDraftAtRoundSecond(21, PLAYER_P, 2, OUTFIT_C, "round-1")
		expect(harness.countDraftsReachingKeeperFrom(PLAYER_P)).toBe(1)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
		expect(harness.referee:isParticipantOfCurrentRound(PLAYER_P)).toBeFalse()
		expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({})
		expect(harness.referee:readRoundStateChangedMessage()).toBeNil()
	end)
end)

describe("ThemedRoundReferee construction and argument checks", function()
	local REQUIRED_DEPENDENCY_NAMES = {
		"clock",
		"scheduler",
		"themedRoundClock",
		"playerRequestRateLimiter",
		"rewardLedger",
		"playerSaveDataKeeper",
		"marketplaceStylingItemResolver",
		"stylingItemByStylingItemKey",
		"findThemeByThemeId",
		"sendRoundStateChangedToEveryDevice",
		"sendRoundResultsPublishedToEveryDevice",
		"sendRoundOutfitDraftAcknowledged",
		"readPlayerDisplayName",
		"logger",
	}

	it("raises for a missing or wrongly kinded required dependency, naming it", function()
		local harness = createRefereeWithFakes({ doNotStartRoundClock = true })
		for _, dependencyName in REQUIRED_DEPENDENCY_NAMES do
			local incompleteDependencies = table.clone(harness.refereeDependencies)
			incompleteDependencies[dependencyName] = nil
			expect(function()
				ThemedRoundReferee.new(incompleteDependencies)
			end).toThrow("dependencies." .. dependencyName)
			incompleteDependencies[dependencyName] = true
			expect(function()
				ThemedRoundReferee.new(incompleteDependencies)
			end).toThrow("dependencies." .. dependencyName)
		end
		expect(function()
			ThemedRoundReferee.new(nil :: any)
		end).toThrow("dependencies table")
	end)

	it("raises for optional dependencies of the wrong kind and incomplete owner decisions", function()
		local harness = createRefereeWithFakes({ doNotStartRoundClock = true })
		for _, optionalFunctionName in { "validateOutfit", "createRoundOutfitDraftKeeper" } do
			local wrongDependencies = table.clone(harness.refereeDependencies)
			wrongDependencies[optionalFunctionName] = {}
			expect(function()
				ThemedRoundReferee.new(wrongDependencies)
			end).toThrow(optionalFunctionName)
		end
		local incompleteOwnerDecisions = table.clone(ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS)
		incompleteOwnerDecisions.shouldForfeitUnsettledRoundAtServerShutdown = nil :: any
		local wrongDependencies = table.clone(harness.refereeDependencies)
		wrongDependencies.ownerDecisions = incompleteOwnerDecisions
		expect(function()
			ThemedRoundReferee.new(wrongDependencies)
		end).toThrow("shouldForfeitUnsettledRoundAtServerShutdown")
		wrongDependencies.ownerDecisions = "yes"
		expect(function()
			ThemedRoundReferee.new(wrongDependencies)
		end).toThrow("ownerDecisions must be a table")
	end)

	it("works without the optional dependencies (real validator and draft keeper)", function()
		local harness = createRefereeWithFakes({ doNotStartRoundClock = true })
		local minimalDependencies = table.clone(harness.refereeDependencies)
		minimalDependencies.validateOutfit = nil
		minimalDependencies.createRoundOutfitDraftKeeper = nil
		minimalDependencies.ownerDecisions = nil
		local minimalReferee = ThemedRoundReferee.new(minimalDependencies)
		harness.themedRoundClock:startRoundCycle()
		harness.loadPlayer(PLAYER_P)
		harness.advanceToRoundSecond(3)
		expect(minimalReferee:admitOrRejectJoinCurrentRoundRequest(PLAYER_P)).toEqual({ isAccepted = true })
		harness.advanceToRoundSecond(20)
		minimalReferee:receiveSetRoundOutfitDraftFromDevice(PLAYER_P, harness.buildOutfitDraftMessage(1, OUTFIT_A))
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
		expect(harness.countingOutfitValidator.validationCallCount).toBe(0)
	end)

	local function expectEveryPlayerUserIdMethodToRaiseItsOwnMessage(referee)
		local methodCalls = {
			function(badPlayerUserId)
				referee:admitOrRejectJoinCurrentRoundRequest(badPlayerUserId)
			end,
			function(badPlayerUserId)
				referee:receiveSetRoundOutfitDraftFromDevice(badPlayerUserId, {})
			end,
			function(badPlayerUserId)
				referee:removePlayerWhoLeftServer(badPlayerUserId)
			end,
			function(badPlayerUserId)
				referee:isParticipantOfCurrentRound(badPlayerUserId)
			end,
			function(badPlayerUserId)
				referee:readShowcaseStageEntry(badPlayerUserId)
			end,
			function(badPlayerUserId)
				referee:readCharacterSpawnRoundFacts(badPlayerUserId)
			end,
		}
		for _, methodCall in methodCalls do
			for _, badPlayerUserId in { "8801", 0 / 0, nil } do
				-- The referee's own prefix: an inner module's check must not stand in for it.
				expect(function()
					methodCall(badPlayerUserId)
				end).toThrow("ThemedRoundReferee: playerUserId must be a number")
			end
		end
	end

	it("raises for a playerUserId that is not a number or is NaN, in every method that takes one", function()
		expectEveryPlayerUserIdMethodToRaiseItsOwnMessage(createRefereeWithFakes().referee)
	end)

	it("raises for a bad playerUserId also while no round is refereed (clock not started)", function()
		expectEveryPlayerUserIdMethodToRaiseItsOwnMessage(
			createRefereeWithFakes({ doNotStartRoundClock = true }).referee
		)
	end)
end)
