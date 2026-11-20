-- RoundOutfitDraftKeeper under floods: bounded validations, timers, acknowledgements and work
-- whatever a device sends (audit question 25). Referee audit PART 3 section J, scenarios 68 to 70,
-- and the "bounded number of raw steps" clause of scenario 35.

local UnitTestFramework = require("../Support/UnitTestFramework")
local RoundOutfitDraftKeeperTestHarness = require("./RoundOutfitDraftKeeperTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_P = RoundOutfitDraftKeeperTestHarness.PLAYER_P
local PLAYER_Q = RoundOutfitDraftKeeperTestHarness.PLAYER_Q
local ROUND_ID = RoundOutfitDraftKeeperTestHarness.ROUND_ID
local OUTFIT_A = RoundOutfitDraftKeeperTestHarness.OUTFIT_A
local OUTFIT_B = RoundOutfitDraftKeeperTestHarness.OUTFIT_B
local OUTFIT_C = RoundOutfitDraftKeeperTestHarness.OUTFIT_C
local OUTFIT_D = RoundOutfitDraftKeeperTestHarness.OUTFIT_D
local expectedAcknowledgement = RoundOutfitDraftKeeperTestHarness.expectedAcknowledgement

local FLOOD_OUTFITS = { OUTFIT_A, OUTFIT_B, OUTFIT_C, OUTFIT_D }

local function createStylingHarnessWithParticipants(playerUserIds: { number })
	local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes()
	harness.joinAtRoundSecond3AndStartStyling(playerUserIds)
	return harness
end

describe("RoundOutfitDraftKeeper draft floods (audit question 25)", function()
	it(
		"scenarios 68 and 70: 10000 rising drafts in one second cost at most 4 validations; another player is not delayed",
		function()
			local harness = createStylingHarnessWithParticipants({ PLAYER_P, PLAYER_Q })
			local draftsPerStep = 100
			local highestSentSequenceNumber = 0
			for stepNumber = 0, 99 do
				harness.advanceToRoundSecond(20 + stepNumber * 0.01)
				if stepNumber == 30 then
					harness.keeper:receiveOutfitDraftFromDevice(PLAYER_Q, harness.buildOutfitDraftMessage(1, OUTFIT_D))
				end
				for _ = 1, draftsPerStep do
					highestSentSequenceNumber += 1
					harness.keeper:receiveOutfitDraftFromDevice(
						PLAYER_P,
						harness.buildOutfitDraftMessage(
							highestSentSequenceNumber,
							FLOOD_OUTFITS[highestSentSequenceNumber % 4 + 1]
						)
					)
				end
				expect(harness.keeper:countPendingOutfitDraftProcessingTimers() <= 2).toBeTrue()
				expect(#harness.listAcknowledgementsSentTo(PLAYER_P) <= 4).toBeTrue()
			end
			expect(highestSentSequenceNumber).toBe(10000)
			local validationTimesForP = {}
			for _, validationCall in harness.countingOutfitValidator.validationCalls do
				table.insert(
					validationTimesForP,
					validationCall.validatedAtUnixMilliseconds
						- RoundOutfitDraftKeeperTestHarness.ROUND_START_UNIX_SECONDS * 1000
				)
			end
			-- P at 20.00, 20.25, 20.50, 20.75; Q once at 20.30.
			expect(validationTimesForP).toEqual({ 20000, 20250, 20300, 20500, 20750 })
			expect(harness.listAcknowledgementsSentTo(PLAYER_Q)).toEqual({ expectedAcknowledgement(20.30, 1, true) })

			harness.advanceToRoundSecond(21.00)
			local acknowledgementsForP = harness.listAcknowledgementsSentTo(PLAYER_P)
			expect(acknowledgementsForP[#acknowledgementsForP]).toEqual(expectedAcknowledgement(21.00, 10000, true))
			expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(FLOOD_OUTFITS[10000 % 4 + 1])
			expect(harness.keeper:readHighestProcessedOutfitDraftSequenceNumber(PLAYER_P)).toBe(10000)
			expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
		end
	)

	it("never holds more than one pending timer per participant", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		for sequenceNumber = 2, 500 do
			harness.keeper:receiveOutfitDraftFromDevice(
				PLAYER_P,
				harness.buildOutfitDraftMessage(sequenceNumber, OUTFIT_B)
			)
			expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(1)
		end
		expect(#harness.requestedTimerDelaySeconds).toBe(1)
	end)

	it("scenario 69: 10000 drafts from a player who never joined leave nothing behind", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.advanceToRoundSecond(20)
		for sequenceNumber = 1, 10000 do
			harness.keeper:receiveOutfitDraftFromDevice(
				PLAYER_Q,
				harness.buildOutfitDraftMessage(sequenceNumber, OUTFIT_A)
			)
		end
		expect(harness.recordingSender.countAcknowledgements()).toBe(0)
		expect(harness.countingOutfitValidator.validationCallCount).toBe(0)
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
		expect(harness.keeper:isParticipant(PLAYER_Q)).toBeFalse()
		expect(harness.keeper:countParticipants()).toBe(1)
		expect(harness.playerRequestRateLimiter:countRememberedPlayers()).toBe(0)
	end)

	it("scenario 35: work per arriving draft does not grow with the size of the submitted list", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		local hugeOutfitList = table.create(200000, "asset_9000002")
		local hugeMap = {}
		for entryNumber = 1, 200000 do
			hugeMap["key" .. tostring(entryNumber)] = entryNumber
		end
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		local arrivalCount = 1000
		local startedAtCpuSeconds = os.clock()
		for sequenceNumber = 2, arrivalCount + 1 do
			harness.keeper:receiveOutfitDraftFromDevice(PLAYER_P, {
				roundId = ROUND_ID,
				outfitDraftSequenceNumber = sequenceNumber,
				outfitStylingItemKeys = if sequenceNumber % 2 == 0 then hugeOutfitList else hugeMap,
			})
		end
		local elapsedCpuSeconds = os.clock() - startedAtCpuSeconds
		-- Walking each 200000-entry table once per arrival would take whole seconds.
		expect(elapsedCpuSeconds < 0.5).toBeTrue()
		harness.advanceToRoundSecond(21)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[2]).toEqual(
			expectedAcknowledgement(20.25, arrivalCount + 1, false)
		)
	end)
end)
