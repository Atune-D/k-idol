-- RoundOutfitDraftKeeper randomized draft protocol runs: referee audit PART 3 scenario 77.
-- Three participants send drafts with random gaps of 0-0.6 s, numbers that rise, skip, repeat and
-- go backwards, valid and invalid outfits, some before Styling and some at and after T = 190.000
-- (the cut-off runs at exactly T = 190.000, randomly before or after the drafts of that instant).
-- Every failure names the random seed; rerun with IDOLGROW_RANDOM_TEST_SEED=<seed>.

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local RandomValidOutfitGenerator = require("../fixtures/RandomValidOutfitGenerator")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local OutfitValidator = require("../../src/shared/OutfitValidator")
local RoundOutfitDraftKeeperTestHarness = require("./RoundOutfitDraftKeeperTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local RANDOM_TRIAL_COUNT = 40
local PARTICIPANT_USER_IDS = {
	RoundOutfitDraftKeeperTestHarness.PLAYER_P,
	RoundOutfitDraftKeeperTestHarness.PLAYER_Q,
	RoundOutfitDraftKeeperTestHarness.PLAYER_R,
}
local STYLING_STARTS_AT_ROUND_MILLISECONDS = 10000
local CUT_OFF_AT_ROUND_MILLISECONDS = 190000
local LAST_ARRIVAL_AT_ROUND_MILLISECONDS = 191000
local PROCESSING_INTERVAL_MILLISECONDS = 250
local ROUND_START_UNIX_MILLISECONDS = RoundOutfitDraftKeeperTestHarness.ROUND_START_UNIX_SECONDS * 1000

local INVALID_OUTFITS = {
	RoundOutfitDraftKeeperTestHarness.INVALID_OUTFIT_X,
	{ FakeStylingItemPool.HIDDEN_HAIR_KEY },
	{ FakeStylingItemPool.KEY_NOT_IN_POOL },
	{ "asset_9000002", "asset_9000002" },
	{ "asset_9000051", "asset_9000052", "asset_9000053", "asset_9000054" },
}

local function isOutfitValidForThisRound(outfitStylingItemKeys: { string }): boolean
	return OutfitValidator.validateOutfit(
		outfitStylingItemKeys,
		FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
		FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET
	).isOutfitValid
end

-- One device per player: its own counter; the outfit of a number never changes once chosen.
local function generateArrivals(seededRandomNumberGenerator)
	local deviceCounterByPlayerUserId = {}
	local outfitBySequenceNumberByPlayerUserId = {}
	for _, playerUserId in PARTICIPANT_USER_IDS do
		deviceCounterByPlayerUserId[playerUserId] = 0
		outfitBySequenceNumberByPlayerUserId[playerUserId] = {}
	end

	local function chooseArrival(roundMilliseconds: number)
		local playerUserId = seededRandomNumberGenerator.pickRandomListElement(PARTICIPANT_USER_IDS)
		local deviceCounter = deviceCounterByPlayerUserId[playerUserId]
		local sequenceChoice = seededRandomNumberGenerator.nextFractionBetweenZeroAndOne()
		local outfitDraftSequenceNumber
		if sequenceChoice < 0.6 or deviceCounter == 0 then
			deviceCounter += seededRandomNumberGenerator.nextWholeNumberInRange(1, 3)
			deviceCounterByPlayerUserId[playerUserId] = deviceCounter
			outfitDraftSequenceNumber = deviceCounter
		elseif sequenceChoice < 0.8 then
			outfitDraftSequenceNumber = deviceCounter
		else
			outfitDraftSequenceNumber = seededRandomNumberGenerator.nextWholeNumberInRange(1, deviceCounter)
		end
		local outfitBySequenceNumber = outfitBySequenceNumberByPlayerUserId[playerUserId]
		if outfitBySequenceNumber[outfitDraftSequenceNumber] == nil then
			outfitBySequenceNumber[outfitDraftSequenceNumber] = if seededRandomNumberGenerator.nextFractionBetweenZeroAndOne()
					< 0.7
				then RandomValidOutfitGenerator.generateRandomValidOutfitStylingItemKeys(seededRandomNumberGenerator)
				else seededRandomNumberGenerator.pickRandomListElement(INVALID_OUTFITS)
		end
		return {
			roundMilliseconds = roundMilliseconds,
			playerUserId = playerUserId,
			outfitDraftSequenceNumber = outfitDraftSequenceNumber,
		}
	end

	local arrivals = {}
	local roundMilliseconds = seededRandomNumberGenerator.nextWholeNumberInRange(9000, 187000)
	while roundMilliseconds <= LAST_ARRIVAL_AT_ROUND_MILLISECONDS do
		table.insert(arrivals, chooseArrival(roundMilliseconds))
		local nextRoundMilliseconds = roundMilliseconds + seededRandomNumberGenerator.nextWholeNumberInRange(0, 600)
		if
			roundMilliseconds < CUT_OFF_AT_ROUND_MILLISECONDS
			and nextRoundMilliseconds >= CUT_OFF_AT_ROUND_MILLISECONDS
		then
			for _ = 1, seededRandomNumberGenerator.nextWholeNumberInRange(1, 3) do
				table.insert(arrivals, chooseArrival(CUT_OFF_AT_ROUND_MILLISECONDS))
			end
		end
		roundMilliseconds = math.max(nextRoundMilliseconds, roundMilliseconds)
	end
	return arrivals, outfitBySequenceNumberByPlayerUserId
end

local function runOneRandomDraftProtocolTrial(seededRandomNumberGenerator)
	local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes()
	local keeper = harness.keeper
	harness.advanceToRoundSecond(3)
	harness.addParticipants(PARTICIPANT_USER_IDS)
	local arrivals, outfitBySequenceNumberByPlayerUserId = generateArrivals(seededRandomNumberGenerator)

	local hasStartedAccepting, hasCutOff = false, false
	local finalOutfits
	local cutOffFirstAcknowledgementIndex, cutOffLastAcknowledgementIndex = 0, -1
	local arrivalIndexByAcknowledgementIndex = {}
	local highestAcceptedArrivalSequenceNumberByPlayerUserId = {}

	local function performCutOff()
		harness.advanceToRoundSecond(CUT_OFF_AT_ROUND_MILLISECONDS / 1000)
		cutOffFirstAcknowledgementIndex = harness.recordingSender.countAcknowledgements() + 1
		finalOutfits = keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		cutOffLastAcknowledgementIndex = harness.recordingSender.countAcknowledgements()
		hasCutOff = true
	end

	for arrivalIndex, arrival in arrivals do
		local arrivesAfterCutOff = arrival.roundMilliseconds > CUT_OFF_AT_ROUND_MILLISECONDS
			or (
				arrival.roundMilliseconds == CUT_OFF_AT_ROUND_MILLISECONDS
				and seededRandomNumberGenerator.nextFractionBetweenZeroAndOne() < 0.5
			)
		if not hasCutOff and arrivesAfterCutOff then
			performCutOff()
		end
		if not hasStartedAccepting and arrival.roundMilliseconds >= STYLING_STARTS_AT_ROUND_MILLISECONDS then
			harness.advanceToRoundSecond(STYLING_STARTS_AT_ROUND_MILLISECONDS / 1000)
			keeper:startAcceptingOutfitDrafts()
			hasStartedAccepting = true
		end
		harness.advanceToRoundSecond(arrival.roundMilliseconds / 1000)
		local playerUserId, outfitDraftSequenceNumber = arrival.playerUserId, arrival.outfitDraftSequenceNumber
		if keeper:isAcceptingOutfitDrafts() then
			highestAcceptedArrivalSequenceNumberByPlayerUserId[playerUserId] = math.max(
				highestAcceptedArrivalSequenceNumberByPlayerUserId[playerUserId] or 0,
				outfitDraftSequenceNumber
			)
		end
		local acknowledgementCountBefore = harness.recordingSender.countAcknowledgements()
		keeper:receiveOutfitDraftFromDevice(
			playerUserId,
			harness.buildOutfitDraftMessage(
				outfitDraftSequenceNumber,
				outfitBySequenceNumberByPlayerUserId[playerUserId][outfitDraftSequenceNumber]
			)
		)
		local acknowledgementCountAfter = harness.recordingSender.countAcknowledgements()
		expect(acknowledgementCountAfter - acknowledgementCountBefore <= 1).toBeTrue()
		if acknowledgementCountAfter > acknowledgementCountBefore then
			arrivalIndexByAcknowledgementIndex[acknowledgementCountAfter] = arrivalIndex
		end
		expect(keeper:countPendingOutfitDraftProcessingTimers() <= #PARTICIPANT_USER_IDS).toBeTrue()
		expect(harness.fakeScheduler:getPendingCallbackCount() <= #PARTICIPANT_USER_IDS).toBeTrue()
	end
	if not hasCutOff then
		performCutOff()
	end
	harness.advanceToRoundSecond(192)

	-- No acknowledgement after the cut-off step.
	expect(harness.recordingSender.countAcknowledgements()).toBe(cutOffLastAcknowledgementIndex)

	local highestFreshNumberByPlayerUserId = {}
	local lastFreshAcknowledgementByPlayerUserId = {}
	local lastFreshAtUnixMillisecondsByPlayerUserId = {}
	local lastKeptFreshNumberByPlayerUserId = {}
	local freshNumberSetByPlayerUserId = {}
	local freshAcknowledgementCount = 0
	for acknowledgementIndex, sentRecord in harness.recordingSender.sentAcknowledgementRecords do
		local playerUserId = sentRecord.playerUserId
		local acknowledgement = sentRecord.acknowledgement
		local highestFreshNumber = highestFreshNumberByPlayerUserId[playerUserId] or 0
		local arrivalIndex = arrivalIndexByAcknowledgementIndex[acknowledgementIndex]
		local isFromCutOff = acknowledgementIndex >= cutOffFirstAcknowledgementIndex
		local isResend = false
		if arrivalIndex ~= nil then
			local arrival = arrivals[arrivalIndex]
			expect(arrival.playerUserId).toBe(playerUserId)
			if arrival.outfitDraftSequenceNumber <= highestFreshNumber then
				-- A re-send caused by a check-2 failure: the stored ack of the highest processed draft.
				isResend = true
				expect(rawequal(acknowledgement, lastFreshAcknowledgementByPlayerUserId[playerUserId])).toBeTrue()
			else
				expect(acknowledgement.outfitDraftSequenceNumber).toBe(arrival.outfitDraftSequenceNumber)
			end
		end
		if not isResend then
			freshAcknowledgementCount += 1
			local freshNumber = acknowledgement.outfitDraftSequenceNumber
			-- Fresh-ack numbers strictly increase per player; one fresh ack per processed number.
			expect(freshNumber > highestFreshNumber).toBeTrue()
			local lastFreshAt = lastFreshAtUnixMillisecondsByPlayerUserId[playerUserId]
			if lastFreshAt ~= nil and not isFromCutOff then
				expect(sentRecord.sentAtUnixMilliseconds - lastFreshAt >= PROCESSING_INTERVAL_MILLISECONDS).toBeTrue()
			end
			local isOutfitValid =
				isOutfitValidForThisRound(outfitBySequenceNumberByPlayerUserId[playerUserId][freshNumber])
			expect(acknowledgement).toEqual({
				roundId = RoundOutfitDraftKeeperTestHarness.ROUND_ID,
				outfitDraftSequenceNumber = freshNumber,
				isKept = isOutfitValid,
				rejectionReason = if isOutfitValid then nil else "OutfitInvalid",
			})
			if isOutfitValid then
				lastKeptFreshNumberByPlayerUserId[playerUserId] = freshNumber
			end
			highestFreshNumberByPlayerUserId[playerUserId] = freshNumber
			lastFreshAcknowledgementByPlayerUserId[playerUserId] = acknowledgement
			lastFreshAtUnixMillisecondsByPlayerUserId[playerUserId] = sentRecord.sentAtUnixMilliseconds
			freshNumberSetByPlayerUserId[playerUserId] = freshNumberSetByPlayerUserId[playerUserId] or {}
			freshNumberSetByPlayerUserId[playerUserId][freshNumber] = true
		end
		expect(sentRecord.sentAtUnixMilliseconds - ROUND_START_UNIX_MILLISECONDS <= CUT_OFF_AT_ROUND_MILLISECONDS).toBeTrue()
	end
	expect(harness.countingOutfitValidator.validationCallCount).toBe(freshAcknowledgementCount)

	for _, playerUserId in PARTICIPANT_USER_IDS do
		-- The scored outfit is the one of the last fresh kept ack, or empty.
		local lastKeptFreshNumber = lastKeptFreshNumberByPlayerUserId[playerUserId]
		local expectedFinalOutfit = if lastKeptFreshNumber
			then outfitBySequenceNumberByPlayerUserId[playerUserId][lastKeptFreshNumber]
			else {}
		expect(finalOutfits[playerUserId]).toEqual(expectedFinalOutfit)
		-- The highest-numbered draft that arrived during Styling is always processed.
		local highestAcceptedArrival = highestAcceptedArrivalSequenceNumberByPlayerUserId[playerUserId]
		if highestAcceptedArrival ~= nil then
			expect((freshNumberSetByPlayerUserId[playerUserId] or {})[highestAcceptedArrival]).toBe(true)
		end
	end
end

describe("RoundOutfitDraftKeeper randomized draft protocol (audit scenario 77)", function()
	it("keeps every invariant over random arrivals around the whole of Styling and the cut-off", function()
		SeededRandomTrials.runSeededRandomTrials(RANDOM_TRIAL_COUNT, runOneRandomDraftProtocolTrial)
	end)
end)
