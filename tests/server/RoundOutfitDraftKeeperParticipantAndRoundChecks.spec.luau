-- RoundOutfitDraftKeeper, §2.3 check 1: the sender is a participant, the roundId is this round's
-- and drafts are being accepted. Referee audit PART 3 section B, scenarios 10 to 13 (scenario 14
-- is in RoundOutfitDraftKeeperCutOff.spec), plus the keeper-side parts of scenarios 50, 53, 54
-- and 55 (removal, rejoining with a clean state, rounds kept apart).

local UnitTestFramework = require("../Support/UnitTestFramework")
local RoundOutfitDraftKeeperTestHarness = require("./RoundOutfitDraftKeeperTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_P = RoundOutfitDraftKeeperTestHarness.PLAYER_P
local PLAYER_Q = RoundOutfitDraftKeeperTestHarness.PLAYER_Q
local ROUND_ID = RoundOutfitDraftKeeperTestHarness.ROUND_ID
local NEXT_ROUND_ID = RoundOutfitDraftKeeperTestHarness.NEXT_ROUND_ID
local OUTFIT_A = RoundOutfitDraftKeeperTestHarness.OUTFIT_A
local OUTFIT_B = RoundOutfitDraftKeeperTestHarness.OUTFIT_B
local OUTFIT_C = RoundOutfitDraftKeeperTestHarness.OUTFIT_C
local OUTFIT_D = RoundOutfitDraftKeeperTestHarness.OUTFIT_D
local expectedAcknowledgement = RoundOutfitDraftKeeperTestHarness.expectedAcknowledgement

local function createStylingHarnessWithParticipants(playerUserIds: { number }, harnessOptions: any?)
	local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes(harnessOptions)
	harness.joinAtRoundSecond3AndStartStyling(playerUserIds)
	return harness
end

describe("RoundOutfitDraftKeeper check 1 (spec §2.3): participant, roundId, phase", function()
	it("scenario 10: a draft from a player who never joined is ignored and leaves no state", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_Q, 1, OUTFIT_A)
		expect(harness.recordingSender.countAcknowledgements()).toBe(0)
		expect(harness.countingOutfitValidator.validationCallCount).toBe(0)
		expect(harness.keeper:isParticipant(PLAYER_Q)).toBeFalse()
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_Q)).toBeNil()
		expect(harness.keeper:readHighestProcessedOutfitDraftSequenceNumber(PLAYER_Q)).toBeNil()
		expect(harness.keeper:countParticipants()).toBe(1)
		expect(harness.playerRequestRateLimiter:countRememberedPlayers()).toBe(0)
		harness.advanceToRoundSecond(190)
		expect(harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()).toEqual({ [PLAYER_P] = {} })
	end)

	it("scenario 11: a draft before joining does not use up its number", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20.0, PLAYER_Q, 1, OUTFIT_A)
		harness.advanceToRoundSecond(20.5)
		harness.keeper:addParticipant(PLAYER_Q)
		harness.sendDraftAtRoundSecond(21.0, PLAYER_Q, 1, OUTFIT_A)
		expect(harness.listAcknowledgementsSentTo(PLAYER_Q)).toEqual({ expectedAcknowledgement(21.0, 1, true) })
		harness.advanceToRoundSecond(190)
		expect(harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()[PLAYER_Q]).toEqual(OUTFIT_A)
	end)

	it("scenario 12: a wrong roundId is ignored without raising and does not start the interval", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.advanceToRoundSecond(20)
		local alwaysEqualTable = setmetatable({}, {
			__eq = function()
				return true
			end,
		})
		local wrongRoundIds = {
			{ "previous round", "round-0" },
			{ "never-issued future round", NEXT_ROUND_ID },
			{ "NaN", 0 / 0 },
			{ "table", {} },
			{ "table claiming equality", alwaysEqualTable },
			{ "missing", nil },
		}
		for _, wrongRoundIdCase in wrongRoundIds do
			local wrongRoundIdMessage = harness.buildOutfitDraftMessage(1, OUTFIT_A)
			wrongRoundIdMessage.roundId = wrongRoundIdCase[2]
			local didReturn, raisedError = pcall(function()
				harness.keeper:receiveOutfitDraftFromDevice(PLAYER_P, wrongRoundIdMessage)
			end)
			expect({ wrongRoundIdCase[1], didReturn, raisedError }).toEqual({ wrongRoundIdCase[1], true, nil })
		end
		expect(harness.recordingSender.countAcknowledgements()).toBe(0)
		expect(harness.keeper:readHighestProcessedOutfitDraftSequenceNumber(PLAYER_P)).toBe(0)
		expect(harness.keeper:countPendingOutfitDraftProcessingTimers()).toBe(0)

		harness.sendDraftAtRoundSecond(20.10, PLAYER_P, 1, OUTFIT_B)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({ expectedAcknowledgement(20.10, 1, true) })
	end)

	it("scenario 13: drafts before Styling are ignored; the same draft during Styling is kept", function()
		local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes()
		harness.advanceToRoundSecond(3)
		harness.addParticipants({ PLAYER_P })
		expect(harness.keeper:isAcceptingOutfitDrafts()).toBeFalse()
		harness.sendDraftAtRoundSecond(9.6, PLAYER_P, 1, OUTFIT_A)
		expect(harness.recordingSender.countAcknowledgements()).toBe(0)
		expect(harness.keeper:readHighestProcessedOutfitDraftSequenceNumber(PLAYER_P)).toBe(0)
		harness.startStylingAtRoundSecond10()
		expect(harness.keeper:isAcceptingOutfitDrafts()).toBeTrue()
		harness.sendDraftAtRoundSecond(10.6, PLAYER_P, 1, OUTFIT_A)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({ expectedAcknowledgement(10.6, 1, true) })
	end)
end)

describe("RoundOutfitDraftKeeper participants", function()
	it("scenario 50 (keeper side): removing a participant with a waiting draft cancels it for good", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(44.90, PLAYER_P, 7, OUTFIT_B)
		harness.sendDraftAtRoundSecond(44.95, PLAYER_P, 8, OUTFIT_C)
		harness.advanceToRoundSecond(45.00)
		harness.keeper:removeParticipant(PLAYER_P)
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
		expect(harness.keeper:countPendingOutfitDraftProcessingTimers()).toBe(0)
		harness.advanceToRoundSecond(46)
		expect(harness.recordingSender.countAcknowledgements()).toBe(1)
		expect(harness.keeper:isParticipant(PLAYER_P)).toBeFalse()
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toBeNil()
		harness.advanceToRoundSecond(190)
		expect(harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()).toEqual({})
	end)

	it("a stale timer of a removed participant does nothing when it still fires", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P }, { isTimerCancellationIgnored = true })
		harness.sendDraftAtRoundSecond(44.90, PLAYER_P, 7, OUTFIT_B)
		harness.sendDraftAtRoundSecond(44.95, PLAYER_P, 8, OUTFIT_C)
		harness.keeper:removeParticipant(PLAYER_P)
		harness.advanceToRoundSecond(46)
		expect(harness.recordingSender.countAcknowledgements()).toBe(1)
		expect(harness.countingOutfitValidator.validationCallCount).toBe(1)
	end)

	it("a stale timer from before a removal does not touch the same player's new clean state", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P }, { isTimerCancellationIgnored = true })
		harness.sendDraftAtRoundSecond(44.90, PLAYER_P, 7, OUTFIT_B)
		harness.sendDraftAtRoundSecond(44.95, PLAYER_P, 8, OUTFIT_C) -- old timer due 45.15
		harness.advanceToRoundSecond(45.00)
		harness.keeper:removeParticipant(PLAYER_P)
		harness.keeper:addParticipant(PLAYER_P)
		harness.sendDraftAtRoundSecond(45.01, PLAYER_P, 1, OUTFIT_A) -- waits (the limiter remembers 44.90)
		harness.advanceToRoundSecond(45.149)
		harness.advanceToRoundSecond(45.15) -- the old timer and the new one are both due now
		local acknowledgements = harness.listAcknowledgementsSentTo(PLAYER_P)
		expect(acknowledgements).toEqual({
			expectedAcknowledgement(44.90, 7, true),
			expectedAcknowledgement(45.15, 1, true),
		})
		expect(harness.countingOutfitValidator.validationCallCount).toBe(2)
	end)

	it("scenarios 53 and 54 (keeper side): a removed then re-added player starts clean", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(40, PLAYER_P, 7, OUTFIT_B)
		harness.advanceToRoundSecond(45)
		harness.keeper:removeParticipant(PLAYER_P)
		harness.sendDraftAtRoundSecond(46, PLAYER_P, 8, OUTFIT_C) -- after removal: ignored
		expect(harness.recordingSender.countAcknowledgements()).toBe(1)
		harness.keeper:removeParticipant(PLAYER_P) -- a second "left" notification is tolerated
		harness.advanceToRoundSecond(95)
		harness.keeper:addParticipant(PLAYER_P)
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual({})
		expect(harness.keeper:readHighestProcessedOutfitDraftSequenceNumber(PLAYER_P)).toBe(0)
		harness.sendDraftAtRoundSecond(96, PLAYER_P, 1, OUTFIT_C)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[2]).toEqual(expectedAcknowledgement(96, 1, true))
		harness.advanceToRoundSecond(190)
		expect(harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()[PLAYER_P]).toEqual(OUTFIT_C)
	end)

	it(
		"scenario 53 variant: the re-added player who sends nothing ends with the empty outfit, not the old one",
		function()
			local harness = createStylingHarnessWithParticipants({ PLAYER_P })
			harness.sendDraftAtRoundSecond(40, PLAYER_P, 7, OUTFIT_B)
			harness.advanceToRoundSecond(45)
			harness.keeper:removeParticipant(PLAYER_P)
			harness.advanceToRoundSecond(95)
			harness.keeper:addParticipant(PLAYER_P)
			harness.sendDraftAtRoundSecond(96, PLAYER_P, 7, OUTFIT_B) -- the old number is not "already processed"
			harness.advanceToRoundSecond(190)
			local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
			expect(harness.listAcknowledgementsSentTo(PLAYER_P)[2]).toEqual(expectedAcknowledgement(96, 7, true))
			expect(finalOutfits[PLAYER_P]).toEqual(OUTFIT_B)

			local secondHarness = createStylingHarnessWithParticipants({ PLAYER_P })
			secondHarness.sendDraftAtRoundSecond(40, PLAYER_P, 7, OUTFIT_B)
			secondHarness.advanceToRoundSecond(45)
			secondHarness.keeper:removeParticipant(PLAYER_P)
			secondHarness.advanceToRoundSecond(95)
			secondHarness.keeper:addParticipant(PLAYER_P)
			secondHarness.sendDraftAtRoundSecond(96, PLAYER_P, 6, OUTFIT_D)
			secondHarness.advanceToRoundSecond(190)
			expect(secondHarness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()[PLAYER_P]).toEqual(OUTFIT_D)

			local thirdHarness = createStylingHarnessWithParticipants({ PLAYER_P })
			thirdHarness.sendDraftAtRoundSecond(40, PLAYER_P, 7, OUTFIT_B)
			thirdHarness.advanceToRoundSecond(45)
			thirdHarness.keeper:removeParticipant(PLAYER_P)
			thirdHarness.keeper:addParticipant(PLAYER_P)
			thirdHarness.advanceToRoundSecond(190)
			expect(thirdHarness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()[PLAYER_P]).toEqual({})
		end
	)

	it("scenario 55 (keeper side): each round's keeper accepts only its own roundId and holds its own state", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(100, PLAYER_P, 40, OUTFIT_B)
		harness.advanceToRoundSecond(190)
		harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		harness.advanceToRoundSecond(280)
		harness.keeper:endRound()
		local nextRoundKeeper = harness.createKeeperForRound(NEXT_ROUND_ID)
		harness.advanceToRoundSecond(290)
		nextRoundKeeper:startAcceptingOutfitDrafts()
		harness.advanceToRoundSecond(300)
		nextRoundKeeper:receiveOutfitDraftFromDevice(
			PLAYER_P,
			harness.buildOutfitDraftMessage(1, OUTFIT_C, NEXT_ROUND_ID)
		)
		expect(harness.recordingSender.countAcknowledgements()).toBe(1) -- not yet a participant of R2
		nextRoundKeeper:addParticipant(PLAYER_P)
		harness.advanceToRoundSecond(301)
		nextRoundKeeper:receiveOutfitDraftFromDevice(PLAYER_P, harness.buildOutfitDraftMessage(41, OUTFIT_D, ROUND_ID))
		harness.keeper:receiveOutfitDraftFromDevice(PLAYER_P, harness.buildOutfitDraftMessage(41, OUTFIT_D, ROUND_ID))
		expect(harness.recordingSender.countAcknowledgements()).toBe(1)
		nextRoundKeeper:receiveOutfitDraftFromDevice(
			PLAYER_P,
			harness.buildOutfitDraftMessage(1, OUTFIT_C, NEXT_ROUND_ID)
		)
		local lastRecord = harness.recordingSender.sentAcknowledgementRecords[2]
		expect(lastRecord.acknowledgement).toEqual({
			roundId = NEXT_ROUND_ID,
			outfitDraftSequenceNumber = 1,
			isKept = true,
		})
		expect(nextRoundKeeper:getRoundId()).toBe(NEXT_ROUND_ID)
		expect(harness.keeper:getRoundId()).toBe(ROUND_ID)
	end)

	it("scenario 55: a timer left from round 1 does nothing when it fires during round 2", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P }, { isTimerCancellationIgnored = true })
		harness.sendDraftAtRoundSecond(100.00, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(100.10, PLAYER_P, 2, OUTFIT_B) -- timer due 100.25
		harness.keeper:endRound()
		local nextRoundKeeper = harness.createKeeperForRound(NEXT_ROUND_ID)
		nextRoundKeeper:addParticipant(PLAYER_P)
		nextRoundKeeper:startAcceptingOutfitDrafts()
		nextRoundKeeper:receiveOutfitDraftFromDevice(
			PLAYER_P,
			harness.buildOutfitDraftMessage(5, OUTFIT_C, NEXT_ROUND_ID)
		)
		harness.advanceToRoundSecond(101)
		expect(harness.recordingSender.countAcknowledgements()).toBe(2) -- R1 seq 1, then R2 seq 5 at 100.25
		expect(harness.recordingSender.sentAcknowledgementRecords[2].acknowledgement.roundId).toBe(NEXT_ROUND_ID)
		expect(nextRoundKeeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_C)
		expect(harness.countingOutfitValidator.validationCallCount).toBe(2)
	end)
end)
