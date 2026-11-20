-- RoundOutfitDraftKeeper, §2.3 check 2: sequence numbers and re-sent acknowledgements.
-- Referee audit PART 3 section C, scenarios 15 to 22 (times are round seconds T).

local UnitTestFramework = require("../Support/UnitTestFramework")
local RoundOutfitDraftKeeperTestHarness = require("./RoundOutfitDraftKeeperTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_P = RoundOutfitDraftKeeperTestHarness.PLAYER_P
local PLAYER_Q = RoundOutfitDraftKeeperTestHarness.PLAYER_Q
local OUTFIT_A = RoundOutfitDraftKeeperTestHarness.OUTFIT_A
local OUTFIT_B = RoundOutfitDraftKeeperTestHarness.OUTFIT_B
local OUTFIT_C = RoundOutfitDraftKeeperTestHarness.OUTFIT_C
local INVALID_OUTFIT_X = RoundOutfitDraftKeeperTestHarness.INVALID_OUTFIT_X
local expectedAcknowledgement = RoundOutfitDraftKeeperTestHarness.expectedAcknowledgement

local function createStylingHarnessWithParticipants(playerUserIds: { number })
	local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes()
	harness.joinAtRoundSecond3AndStartStyling(playerUserIds)
	return harness
end

describe("RoundOutfitDraftKeeper check 2 (spec §2.3): sequence numbers", function()
	it("scenario 15: a first draft is acknowledged once, at once, only to its sender, and kept", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P, PLAYER_Q })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)

		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({ expectedAcknowledgement(20, 1, true) })
		expect(harness.recordingSender.countAcknowledgements()).toBe(1)
		-- Exactly the four §2.3 fields, rejectionReason absent when kept.
		expect(harness.recordingSender.sentAcknowledgementRecords[1].acknowledgement).toEqual({
			roundId = RoundOutfitDraftKeeperTestHarness.ROUND_ID,
			outfitDraftSequenceNumber = 1,
			isKept = true,
		})
		local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		expect(finalOutfits[PLAYER_P]).toEqual(OUTFIT_A)
		expect(finalOutfits[PLAYER_Q]).toEqual({})
	end)

	it("scenario 16: a duplicate number with different content is not processed; the stored ack is re-sent", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(21, PLAYER_P, 1, OUTFIT_B)

		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20, 1, true),
			expectedAcknowledgement(21, 1, true),
		})
		local sentRecords = harness.recordingSender.sentAcknowledgementRecords
		expect(rawequal(sentRecords[1].acknowledgement, sentRecords[2].acknowledgement)).toBeTrue()
		expect(harness.countingOutfitValidator.validationCallCount).toBe(1)
		expect(harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()[PLAYER_P]).toEqual(OUTFIT_A)
	end)

	it("scenario 17: a number going backwards gets the ack of the HIGHEST processed draft", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(21, PLAYER_P, 2, OUTFIT_B)
		harness.sendDraftAtRoundSecond(22, PLAYER_P, 1, OUTFIT_C)

		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20, 1, true),
			expectedAcknowledgement(21, 2, true),
			expectedAcknowledgement(22, 2, true),
		})
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_B)
		expect(harness.countingOutfitValidator.validationCallCount).toBe(2)
	end)

	it("scenario 18: after an invalid highest draft, duplicates get the stored rejection without validating", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 5, OUTFIT_B)
		harness.sendDraftAtRoundSecond(21, PLAYER_P, 6, INVALID_OUTFIT_X)
		harness.sendDraftAtRoundSecond(22, PLAYER_P, 5, OUTFIT_B)
		harness.sendDraftAtRoundSecond(23, PLAYER_P, 6, OUTFIT_A) -- same number, now a valid outfit
		expect(harness.countingOutfitValidator.validationCallCount).toBe(2)
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_B)
		harness.sendDraftAtRoundSecond(24, PLAYER_P, 7, OUTFIT_C)

		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20, 5, true),
			expectedAcknowledgement(21, 6, false),
			expectedAcknowledgement(22, 6, false),
			expectedAcknowledgement(23, 6, false),
			expectedAcknowledgement(24, 7, true),
		})
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_C)
	end)

	it("scenario 19: numbers may skip and need not start at 1", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 7, OUTFIT_A)
		harness.sendDraftAtRoundSecond(21, PLAYER_P, 50, OUTFIT_B)
		harness.sendDraftAtRoundSecond(22, PLAYER_P, 49, OUTFIT_C)

		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20, 7, true),
			expectedAcknowledgement(21, 50, true),
			expectedAcknowledgement(22, 50, true),
		})
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_B)
		expect(harness.keeper:readHighestProcessedOutfitDraftSequenceNumber(PLAYER_P)).toBe(50)
	end)

	it("scenario 20: numbers 0 and -1 before anything was processed are ignored; then 1 is kept at once", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 0, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20, PLAYER_P, -1, OUTFIT_A)
		expect(harness.recordingSender.countAcknowledgements()).toBe(0)
		expect(harness.countingOutfitValidator.validationCallCount).toBe(0)
		expect(harness.keeper:readHighestProcessedOutfitDraftSequenceNumber(PLAYER_P)).toBe(0)
		expect(harness.keeper:countPendingOutfitDraftProcessingTimers()).toBe(0)

		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({ expectedAcknowledgement(20, 1, true) })
	end)

	it("scenario 21: hostile sequence numbers are ignored and do not poison the highest processed number", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		local raisingComparisonTable = setmetatable({}, {
			__lt = function()
				error("hostile __lt ran")
			end,
			__le = function()
				error("hostile __le ran")
			end,
		})
		local hostileSequenceNumbers = {
			{ "nil", nil },
			{ "string", "2" },
			{ "boolean", true },
			{ "empty table", {} },
			{ "table with raising comparisons", raisingComparisonTable },
			{ "NaN", 0 / 0 },
			{ "+infinity", math.huge },
			{ "-infinity", -math.huge },
			{ "fraction", 1.5 },
			{ "2^53", 2 ^ 53 },
			{ "1e308", 1e308 },
		}
		harness.advanceToRoundSecond(21)
		for _, hostileCase in hostileSequenceNumbers do
			local didReturn, raisedError = pcall(function()
				harness.keeper:receiveOutfitDraftFromDevice(
					PLAYER_P,
					harness.buildOutfitDraftMessage(hostileCase[2], OUTFIT_B)
				)
			end)
			expect({ hostileCase[1], didReturn, raisedError }).toEqual({ hostileCase[1], true, nil })
			expect({ hostileCase[1], harness.recordingSender.countAcknowledgements() }).toEqual({ hostileCase[1], 1 })
			expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_A)
			expect(harness.keeper:readHighestProcessedOutfitDraftSequenceNumber(PLAYER_P)).toBe(1)
			expect(harness.keeper:countPendingOutfitDraftProcessingTimers()).toBe(0)
		end
		expect(harness.countingOutfitValidator.validationCallCount).toBe(1)

		harness.sendDraftAtRoundSecond(22, PLAYER_P, 2, OUTFIT_B)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[2]).toEqual(expectedAcknowledgement(22, 2, true))
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_B)
	end)
end)

describe("RoundOutfitDraftKeeper check 2: re-sent acknowledgements are bounded (audit question 3)", function()
	it("scenario 22: twenty duplicates in 0.2 s give one re-send and leave the interval alone", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		for copyNumber = 1, 20 do
			harness.sendDraftAtRoundSecond(20.00 + copyNumber * 0.01, PLAYER_P, 1, OUTFIT_A)
		end
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20.00, 1, true),
			expectedAcknowledgement(20.01, 1, true),
		})
		expect(harness.countingOutfitValidator.validationCallCount).toBe(1)

		harness.sendDraftAtRoundSecond(20.21, PLAYER_P, 2, OUTFIT_B)
		harness.advanceToRoundSecond(20.3)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[3]).toEqual(expectedAcknowledgement(20.25, 2, true))
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(3)
	end)

	it("scenario 22 (separate run): a single resend one second later gets one re-sent ack", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(21.00, PLAYER_P, 1, OUTFIT_A)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20.00, 1, true),
			expectedAcknowledgement(21.00, 1, true),
		})
	end)

	it("allows the next re-send exactly 0.25 s after the previous re-send, not 1 ms sooner", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20.000, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.010, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.259, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.260, PLAYER_P, 1, OUTFIT_A)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20.000, 1, true),
			expectedAcknowledgement(20.010, 1, true),
			expectedAcknowledgement(20.260, 1, true),
		})
	end)

	it("bounds re-sends per player: another player's duplicates do not use up this player's re-send", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P, PLAYER_Q })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.00, PLAYER_Q, 1, OUTFIT_B)
		harness.sendDraftAtRoundSecond(20.01, PLAYER_Q, 1, OUTFIT_B)
		harness.sendDraftAtRoundSecond(20.02, PLAYER_P, 1, OUTFIT_A)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(2)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_Q)).toBe(2)
	end)
end)
