-- ThemedRoundReferee, RequestJoinCurrentRound (development spec §2, §2.1, §2.2, §2.13). Referee
-- audit PART 3 section A, scenarios 1 to 9, and PART 1 questions 13, 14, 15; PART 2 item k.
-- Runs against the REAL ThemedRoundClock, rate limiter, save keeper and ledger on fake time.

local UnitTestFramework = require("../Support/UnitTestFramework")
local ThemedRoundJoinRequestDecision = require("../../src/server/ThemedRoundJoinRequestDecision")
local ThemedRoundRefereeTestHarness = require("./ThemedRoundRefereeTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_P = ThemedRoundRefereeTestHarness.PLAYER_P
local PLAYER_Q = ThemedRoundRefereeTestHarness.PLAYER_Q
local PLAYER_R = ThemedRoundRefereeTestHarness.PLAYER_R
local OUTFIT_A = ThemedRoundRefereeTestHarness.OUTFIT_A
local OUTFIT_B = ThemedRoundRefereeTestHarness.OUTFIT_B
local OUTFIT_E83 = ThemedRoundRefereeTestHarness.WORKED_EXAMPLE_OUTFIT_E83
local expectedAcknowledgement = ThemedRoundRefereeTestHarness.expectedAcknowledgement

local ACCEPTED = { isAccepted = true }
local function rejectedWith(rejectionReason: string)
	return { isAccepted = false, rejectionReason = rejectionReason }
end

local createRefereeWithFakes = ThemedRoundRefereeTestHarness.createRefereeWithFakes

describe("ThemedRoundReferee join window (§2.2, audit scenario 1)", function()
	it("accepts at T=0.000, 9.999, 129.999 and 130.000 and refuses at 130.001", function()
		local harness = createRefereeWithFakes()
		local playerUserIds = { 9001, 9002, 9003, 9004, 9005 }
		harness.loadPlayers(playerUserIds)
		local firstAcceptedAnswer = harness.joinAtRoundSecond(0, 9001)
		expect(firstAcceptedAnswer).toEqual(ACCEPTED)
		local secondAcceptedAnswer = harness.joinAtRoundSecond(9.999, 9002)
		expect(secondAcceptedAnswer).toEqual(ACCEPTED)
		expect(rawequal(firstAcceptedAnswer, secondAcceptedAnswer)).toBeFalse()
		expect(table.isfrozen(secondAcceptedAnswer)).toBeTrue()
		expect(harness.joinAtRoundSecond(129.999, 9003)).toEqual(ACCEPTED)
		expect(harness.joinAtRoundSecond(130, 9004)).toEqual(ACCEPTED)
		expect(harness.joinAtRoundSecond(130.001, 9005)).toEqual(rejectedWith("RoundNotJoinableNow"))
		expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({ 9001, 9002, 9003, 9004 })
	end)

	it("refuses non-participants in Showcase, Results and Intermission and accepts at T=280 into round 2", function()
		local harness = createRefereeWithFakes()
		harness.loadPlayers({ PLAYER_P })
		expect(harness.joinAtRoundSecond(190, PLAYER_P)).toEqual(rejectedWith("RoundNotJoinableNow"))
		expect(harness.joinAtRoundSecond(250, PLAYER_P)).toEqual(rejectedWith("RoundNotJoinableNow"))
		expect(harness.joinAtRoundSecond(270, PLAYER_P)).toEqual(rejectedWith("RoundNotJoinableNow"))
		expect(harness.joinAtRoundSecond(280, PLAYER_P)).toEqual(ACCEPTED)
		expect(harness.readCurrentRoundId()).toBe("round-2")
		expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({ PLAYER_P })
	end)

	it("measures the window against the published phase end in milliseconds (pure decision)", function()
		local stylingEndsAt = 1_000_000
		local isRoundPhaseOpenForJoining = ThemedRoundJoinRequestDecision.isRoundPhaseOpenForJoining
		expect(isRoundPhaseOpenForJoining("Styling", stylingEndsAt, stylingEndsAt - 60000)).toBeTrue()
		expect(isRoundPhaseOpenForJoining("Styling", stylingEndsAt, stylingEndsAt - 59999)).toBeFalse()
		expect(isRoundPhaseOpenForJoining("ThemeReveal", stylingEndsAt, stylingEndsAt + 5)).toBeTrue()
		for _, closedRoundPhase in { "Showcase", "Results", "Intermission" } do
			expect(isRoundPhaseOpenForJoining(closedRoundPhase, stylingEndsAt, stylingEndsAt - 200000)).toBeFalse()
		end
	end)
end)

describe("ThemedRoundReferee join preconditions (audit scenario 2)", function()
	it("answers SaveDataNotLoaded until the save loads, then accepts", function()
		local harness = createRefereeWithFakes()
		expect(harness.joinAtRoundSecond(5, PLAYER_P)).toEqual(rejectedWith("SaveDataNotLoaded"))
		harness.advanceToRoundSecond(20)
		harness.loadPlayer(PLAYER_P)
		expect(harness.joinAtRoundSecond(22, PLAYER_P)).toEqual(ACCEPTED)
	end)

	it("answers WardrobeCatalogNotReady until the catalog is ready, then accepts", function()
		local harness = createRefereeWithFakes({ isWardrobeCatalogNotReadyAtStart = true })
		harness.loadPlayers({ PLAYER_P })
		expect(harness.joinAtRoundSecond(5, PLAYER_P)).toEqual(rejectedWith("WardrobeCatalogNotReady"))
		harness.advanceToRoundSecond(30)
		harness.fakeResolver:publishWardrobeCatalog(
			require("../fixtures/FakeStylingItemPool").FAKE_AVAILABLE_STYLING_ITEM_KEY_SET
		)
		expect(harness.joinAtRoundSecond(32, PLAYER_P)).toEqual(ACCEPTED)
	end)

	it("answers SaveDataNotLoaded when both the save and the catalog are missing", function()
		local harness = createRefereeWithFakes({ isWardrobeCatalogNotReadyAtStart = true })
		expect(harness.joinAtRoundSecond(5, PLAYER_P)).toEqual(rejectedWith("SaveDataNotLoaded"))
	end)
end)

describe("ThemedRoundReferee rejection order (audit question 13)", function()
	it("puts TooManyRequests first: a participant asking again within 1 s is told TooManyRequests", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		expect(harness.joinAtRoundSecond(3.5, PLAYER_P)).toEqual(rejectedWith("TooManyRequests"))
		expect(harness.joinAtRoundSecond(4, PLAYER_P)).toEqual(rejectedWith("AlreadyParticipating"))
	end)

	it("asks the rate limiter before anything else, so even a refused join uses the channel's interval", function()
		local harness = createRefereeWithFakes()
		expect(harness.joinAtRoundSecond(5, PLAYER_P)).toEqual(rejectedWith("SaveDataNotLoaded"))
		harness.loadPlayer(PLAYER_P)
		expect(harness.joinAtRoundSecond(5.5, PLAYER_P)).toEqual(rejectedWith("TooManyRequests"))
		expect(harness.joinAtRoundSecond(6, PLAYER_P)).toEqual(ACCEPTED)
	end)

	it(
		"orders the five reasons TooManyRequests, AlreadyParticipating, SaveDataNotLoaded, WardrobeCatalogNotReady, RoundNotJoinableNow",
		function()
			local decide = ThemedRoundJoinRequestDecision.decideJoinCurrentRoundAnswer
			local function factsWithFailures(failingFactNames: { string })
				local joinRequestFacts = {
					isAdmittedByRateLimiter = true,
					isAlreadyParticipating = false,
					isPlayerSaveDataLoaded = true,
					isWardrobeCatalogReady = true,
					isRoundJoinableNow = true,
				}
				for _, failingFactName in failingFactNames do
					joinRequestFacts[failingFactName] = failingFactName == "isAlreadyParticipating"
				end
				return joinRequestFacts
			end
			local allFailing = {
				"isAdmittedByRateLimiter",
				"isAlreadyParticipating",
				"isPlayerSaveDataLoaded",
				"isWardrobeCatalogReady",
				"isRoundJoinableNow",
			}
			local expectedReasons = {
				"TooManyRequests",
				"AlreadyParticipating",
				"SaveDataNotLoaded",
				"WardrobeCatalogNotReady",
				"RoundNotJoinableNow",
			}
			for firstFailingPosition, expectedReason in expectedReasons do
				local failing = table.move(allFailing, firstFailingPosition, #allFailing, 1, {})
				expect(decide(factsWithFailures(failing))).toEqual(rejectedWith(expectedReason))
			end
			expect(decide(factsWithFailures({}))).toEqual(ACCEPTED)
			expect(table.isfrozen(decide(factsWithFailures({})))).toBeTrue()
		end
	)
end)

describe("ThemedRoundReferee joining twice (audit scenario 3)", function()
	it("answers AlreadyParticipating in every phase and changes nothing", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(40, PLAYER_P, 2, OUTFIT_E83)
		local draftKeeper = harness.createdDraftKeepers[1]
		expect(harness.joinAtRoundSecond(45, PLAYER_P)).toEqual(rejectedWith("AlreadyParticipating"))
		expect(draftKeeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_E83)
		expect(draftKeeper:readHighestProcessedOutfitDraftSequenceNumber(PLAYER_P)).toBe(2)
		harness.sendDraftAtRoundSecond(46, PLAYER_P, 3, OUTFIT_B)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[3]).toEqual(expectedAcknowledgement(46, "round-1", 3, true))
		harness.sendDraftAtRoundSecond(47, PLAYER_P, 4, OUTFIT_E83)
		for _, askingRoundSecond in { 150, 200, 255 } do
			expect(harness.joinAtRoundSecond(askingRoundSecond, PLAYER_P)).toEqual(rejectedWith("AlreadyParticipating"))
		end
		expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({ PLAYER_P })
		local roundResults = harness.listPublishedRoundResultsMessages()[1].roundResults
		expect(#roundResults).toBe(1)
		expect(roundResults[1].outfitScore).toBe(83)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(1)
	end)
end)

describe("ThemedRoundReferee rejected joins (audit scenarios 4 and 5)", function()
	it("scenario 4: a rejected join creates no state; that player's drafts never reach the draft keeper", function()
		local harness = createRefereeWithFakes()
		expect(harness.joinAtRoundSecond(5, PLAYER_P)).toEqual(rejectedWith("SaveDataNotLoaded"))
		harness.loadPlayer(PLAYER_Q)
		expect(harness.joinAtRoundSecond(130.001, PLAYER_Q)).toEqual(rejectedWith("RoundNotJoinableNow"))
		harness.sendDraftAtRoundSecond(131, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(131, PLAYER_Q, 1, OUTFIT_A)
		expect(harness.recordingAcknowledgementSender.countAcknowledgements()).toBe(0)
		expect(harness.countingOutfitValidator.validationCallCount).toBe(0)
		expect(#harness.draftsReachingKeeperRecords).toBe(0)
		expect(harness.createdDraftKeepers[1]:countParticipants()).toBe(0)
		expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({})
	end)

	it(
		"scenario 4: drafts after a WardrobeCatalogNotReady or TooManyRequests rejection never reach the keeper",
		function()
			local harness = createRefereeWithFakes({ isWardrobeCatalogNotReadyAtStart = true })
			harness.loadPlayers({ PLAYER_P })
			expect(harness.joinAtRoundSecond(5, PLAYER_P)).toEqual(rejectedWith("WardrobeCatalogNotReady"))
			harness.fakeResolver:publishWardrobeCatalog(
				require("../fixtures/FakeStylingItemPool").FAKE_AVAILABLE_STYLING_ITEM_KEY_SET
			)
			expect(harness.joinAtRoundSecond(5.5, PLAYER_P)).toEqual(rejectedWith("TooManyRequests"))
			harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
			harness.sendDraftAtRoundSecond(21, PLAYER_P, 2, OUTFIT_B)
			expect(harness.recordingAcknowledgementSender.countAcknowledgements()).toBe(0)
			expect(harness.countingOutfitValidator.validationCallCount).toBe(0)
			expect(#harness.draftsReachingKeeperRecords).toBe(0)
			expect(harness.referee:isParticipantOfCurrentRound(PLAYER_P)).toBeFalse()
		end
	)

	it(
		"scenario 5: arguments sent with the request are ignored and every answer is a fresh table of the §2 shape",
		function()
			local harness = createRefereeWithFakes()
			harness.loadPlayers({ PLAYER_P })
			local raisingMetatableArgument = setmetatable({}, {
				__index = function()
					error("must not be read")
				end,
				__len = function()
					error("must not be measured")
				end,
			})
			local hugeArgument = table.create(100000, "x")
			local hostileArguments = { "round-2", 0 / 0, raisingMetatableArgument, hugeArgument }
			local previousAnswer = nil
			for argumentPosition, hostileArgument in hostileArguments do
				harness.advanceToRoundSecond(264 + argumentPosition)
				local answer = (harness.referee.admitOrRejectJoinCurrentRoundRequest :: any)(
					harness.referee,
					PLAYER_P,
					hostileArgument
				)
				expect(answer).toEqual(rejectedWith("RoundNotJoinableNow"))
				expect(table.isfrozen(answer)).toBeTrue()
				expect(answer == previousAnswer).toBeFalse()
				previousAnswer = answer
			end
			harness.advanceToRoundSecond(281)
			expect(harness.referee:isParticipantOfCurrentRound(PLAYER_P)).toBeFalse()
			expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({})
		end
	)
end)

describe("ThemedRoundReferee floods and capacity (audit scenarios 6 and 7, question 14)", function()
	it("scenario 6: of 100 joins at the same instant exactly one is accepted; one entry and one grant", function()
		local harness = createRefereeWithFakes()
		harness.loadPlayers({ PLAYER_P })
		harness.advanceToRoundSecond(20)
		local acceptedCount, tooManyRequestsCount = 0, 0
		for _ = 1, 100 do
			local answer = harness.referee:admitOrRejectJoinCurrentRoundRequest(PLAYER_P)
			if answer.isAccepted then
				acceptedCount += 1
			elseif answer.rejectionReason == "TooManyRequests" then
				tooManyRequestsCount += 1
			end
		end
		expect(acceptedCount).toBe(1)
		expect(tooManyRequestsCount).toBe(99)
		expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({ PLAYER_P })
		harness.sendDraftAtRoundSecond(21, PLAYER_P, 1, OUTFIT_E83)
		harness.advanceToRoundSecond(251)
		expect(#harness.listPublishedRoundResultsMessages()[1].roundResults).toBe(1)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(1)
	end)

	it(
		"scenario 7: twelve participants join between T=1 and T=9; each is scored, granted once and listed once",
		function()
			local harness = createRefereeWithFakes()
			local playerUserIds = {}
			for playerNumber = 1, 12 do
				table.insert(playerUserIds, 9100 + playerNumber)
			end
			harness.loadPlayers(playerUserIds)
			for playerNumber, playerUserId in playerUserIds do
				expect(harness.joinAtRoundSecond(1 + (playerNumber - 1) * 8 / 11, playerUserId)).toEqual(ACCEPTED)
			end
			for playerNumber, playerUserId in playerUserIds do
				harness.sendDraftAtRoundSecond(20 + playerNumber, playerUserId, 1, OUTFIT_E83)
			end
			harness.advanceToRoundSecond(190)
			for playerNumber, playerUserId in playerUserIds do
				expect(harness.referee:readShowcaseStageEntry(playerUserId).stagePlaceNumber).toBe(playerNumber)
			end
			harness.advanceToRoundSecond(250)
			local roundResults = harness.listPublishedRoundResultsMessages()[1].roundResults
			expect(#roundResults).toBe(12)
			for playerNumber, playerUserId in playerUserIds do
				expect(harness.countGrantCallsFor(playerUserId)).toBe(1)
				expect(roundResults[playerNumber].playerUserId).toBe(playerUserId)
				expect(roundResults[playerNumber].starCoinsGranted).toBe(80)
			end
		end
	)
end)

describe("ThemedRoundReferee participantUserIds and rounds (audit scenarios 8 and 9, question 15)", function()
	it("scenario 8: the list is the live set in join order at each broadcast and on demand", function()
		local harness = createRefereeWithFakes()
		harness.loadPlayers({ PLAYER_P, PLAYER_Q, PLAYER_R })
		local function broadcastParticipantsAt(roundSeconds: number)
			for _, sentRecord in harness.sentRoundStateChangedRecords do
				if sentRecord.roundMilliseconds == roundSeconds * 1000 then
					return sentRecord.roundStateChangedMessage.participantUserIds
				end
			end
			error("no RoundStateChanged at " .. tostring(roundSeconds))
		end
		harness.joinAtRoundSecond(3, PLAYER_P)
		harness.joinAtRoundSecond(60, PLAYER_Q)
		harness.advanceToRoundSecond(61)
		expect(harness.referee:readRoundStateChangedMessage().participantUserIds).toEqual({ PLAYER_P, PLAYER_Q })
		harness.leaveServerAtRoundSecond(200, PLAYER_P)
		harness.advanceToRoundSecond(201)
		expect(harness.referee:readRoundStateChangedMessage().participantUserIds).toEqual({ PLAYER_Q })
		harness.advanceToRoundSecond(280)
		expect(broadcastParticipantsAt(0)).toEqual({})
		expect(broadcastParticipantsAt(10)).toEqual({ PLAYER_P })
		expect(broadcastParticipantsAt(190)).toEqual({ PLAYER_P, PLAYER_Q })
		expect(broadcastParticipantsAt(250)).toEqual({ PLAYER_Q })
		expect(broadcastParticipantsAt(270)).toEqual({ PLAYER_Q })
		expect(broadcastParticipantsAt(280)).toEqual({})
		expect(table.isfrozen(broadcastParticipantsAt(250))).toBeTrue()
	end)

	it("scenario 8: the list follows join order, not user id order (higher id joins first)", function()
		local harness = createRefereeWithFakes()
		harness.loadPlayers({ PLAYER_P, PLAYER_Q })
		expect(harness.joinAtRoundSecond(3, PLAYER_Q)).toEqual(ACCEPTED)
		expect(harness.joinAtRoundSecond(60, PLAYER_P)).toEqual(ACCEPTED)
		expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({ PLAYER_Q, PLAYER_P })
		expect(harness.referee:readRoundStateChangedMessage().participantUserIds).toEqual({ PLAYER_Q, PLAYER_P })
		harness.advanceToRoundSecond(190)
		expect(harness.readLastBroadcastParticipantUserIds()).toEqual({ PLAYER_Q, PLAYER_P })
	end)

	it("scenario 9: participation does not carry over into the next round", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
		harness.advanceToRoundSecond(280)
		expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({})
		expect(harness.referee:isParticipantOfCurrentRound(PLAYER_P)).toBeFalse()
		local acknowledgementCountAfterRoundOne = #harness.listAcknowledgementsSentTo(PLAYER_P)
		harness.sendDraftAtRoundSecond(290.5, PLAYER_P, 1, OUTFIT_A, "round-2")
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(acknowledgementCountAfterRoundOne)
		expect(harness.joinAtRoundSecond(291, PLAYER_P)).toEqual(ACCEPTED)
		harness.sendDraftAtRoundSecond(292, PLAYER_P, 1, OUTFIT_A, "round-2")
		local acknowledgements = harness.listAcknowledgementsSentTo(PLAYER_P)
		expect(#acknowledgements).toBe(acknowledgementCountAfterRoundOne + 1)
		expect(acknowledgements[#acknowledgements]).toEqual(expectedAcknowledgement(292, "round-2", 1, true))
	end)
end)
