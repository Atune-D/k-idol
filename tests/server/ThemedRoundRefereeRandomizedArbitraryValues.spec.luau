-- ThemedRoundReferee under arbitrary device values (referee audit PART 3 scenario 79): 5000 steps,
-- each a random player (participant or not, save loaded or not), a random time step of 0-0.3 s
-- across all five phases, and a join or draft built from arbitrary Luau values: nil, booleans,
-- NaN, ±infinity, huge and fractional numbers, long strings, nested and self-referencing tables,
-- tables whose metatable raises, valid and invalid outfits. A failure names the seed.
--
-- Invariants:
--   * The referee never raises.
--   * Pending draft timers never exceed the participants.
--   * Validations stay within players × (elapsed Styling seconds ÷ 0.25 + 2 per round).
--   * The scored outfit equals the outfit the TEST sent under the number of the last
--     acknowledgement with isKept = true in that round, or is empty when there is none (the
--     scenario 77 invariant). Each (round, player, number) carries one fixed content, so the
--     expected outfit never comes from the code under test.
--   * Grants per round never exceed the participants at Results, each paid at most once, and
--     only for a non-empty kept outfit, exactly the one that was scored.

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local SetRoundOutfitDraftMessageReader = require("../../src/server/SetRoundOutfitDraftMessageReader")
local ThemedRoundRefereeTestHarness = require("./ThemedRoundRefereeTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local LOADED_PLAYER_USER_IDS = { 9401, 9402, 9403, 9404 }
local ALL_PLAYER_USER_IDS = { 9401, 9402, 9403, 9404, 9405, 9406 }
local STEP_COUNT = 5000
local MAXIMUM_STEP_MILLISECONDS = 300
local OUTFIT_CHOICES = {
	ThemedRoundRefereeTestHarness.OUTFIT_A,
	ThemedRoundRefereeTestHarness.OUTFIT_B,
	ThemedRoundRefereeTestHarness.OUTFIT_C,
	ThemedRoundRefereeTestHarness.OUTFIT_D,
	ThemedRoundRefereeTestHarness.WORKED_EXAMPLE_OUTFIT_E83,
	ThemedRoundRefereeTestHarness.INVALID_OUTFIT_X,
	{},
}

local function createRaisingMetatableTable()
	return setmetatable({}, {
		__index = function()
			error("arbitrary value: __index raised")
		end,
		__len = function()
			error("arbitrary value: __len raised")
		end,
		__lt = function()
			error("arbitrary value: __lt raised")
		end,
		__le = function()
			error("arbitrary value: __le raised")
		end,
		__eq = function()
			error("arbitrary value: __eq raised")
		end,
		__iter = function()
			error("arbitrary value: __iter raised")
		end,
	})
end

local function buildArbitraryValue(seededRandomNumberGenerator, nestingDepth: number): any
	local valueKindNumber = seededRandomNumberGenerator.nextWholeNumberInRange(1, 16)
	if valueKindNumber == 1 then
		return nil
	elseif valueKindNumber == 2 then
		return seededRandomNumberGenerator.nextWholeNumberInRange(0, 1) == 1
	elseif valueKindNumber == 3 then
		return 0 / 0
	elseif valueKindNumber == 4 then
		return if seededRandomNumberGenerator.nextWholeNumberInRange(0, 1) == 1 then math.huge else -math.huge
	elseif valueKindNumber == 5 then
		return seededRandomNumberGenerator.pickRandomListElement({ 2 ^ 53, 2 ^ 53 - 1, 1e308, -1e308, -1, 0 })
	elseif valueKindNumber == 6 then
		return seededRandomNumberGenerator.nextFractionBetweenZeroAndOne() * 100
	elseif valueKindNumber == 7 then
		return seededRandomNumberGenerator.nextWholeNumberInRange(-3, 60)
	elseif valueKindNumber == 8 then
		return string.rep("x", seededRandomNumberGenerator.nextWholeNumberInRange(1000, 20000))
	elseif valueKindNumber == 9 then
		return seededRandomNumberGenerator.pickRandomListElement({ "round-1", "round-2", "asset_9000001", "", "nil" })
	elseif valueKindNumber == 10 and nestingDepth < 3 then
		local nestedTable = {}
		for _ = 1, seededRandomNumberGenerator.nextWholeNumberInRange(0, 5) do
			local nestedKey = buildArbitraryValue(seededRandomNumberGenerator, nestingDepth + 1)
			local isNotANumberKey = type(nestedKey) == "number" and nestedKey ~= nestedKey
			if nestedKey ~= nil and not isNotANumberKey then
				nestedTable[nestedKey] = buildArbitraryValue(seededRandomNumberGenerator, nestingDepth + 1)
			end
		end
		return nestedTable
	elseif valueKindNumber == 11 then
		local selfReferencingTable = { "asset_9000001" }
		selfReferencingTable[2] = selfReferencingTable
		selfReferencingTable.outfitStylingItemKeys = selfReferencingTable
		return selfReferencingTable
	elseif valueKindNumber == 12 then
		return createRaisingMetatableTable()
	elseif valueKindNumber == 13 then
		return table.create(seededRandomNumberGenerator.nextWholeNumberInRange(13, 5000), "asset_9000001")
	elseif valueKindNumber == 14 then
		return function() end
	end
	return table.clone(seededRandomNumberGenerator.pickRandomListElement(OUTFIT_CHOICES))
end

-- The outfit sent under one (round, player, sequence number), fixed the first time that number
-- is used in a message the keeper could process, so every later message with that number carries
-- the same content and the test knows exactly what a kept acknowledgement refers to.
local function createSentOutfitBook()
	local sentOutfitByDraftKey: { [string]: { outfitStylingItemKeys: any } } = {}
	local sentOutfitBook = {}
	local function buildDraftKey(roundId: string, playerUserId: number, outfitDraftSequenceNumber: number): string
		return string.format("%s/%d/%d", roundId, playerUserId, outfitDraftSequenceNumber)
	end
	-- Rewrites the message's outfit to the content first sent under its number (lists are copied).
	function sentOutfitBook.fixOutfitOfProcessableMessage(draftMessage, currentRoundId: string, playerUserId: number)
		local outfitDraftSequenceNumber = draftMessage.outfitDraftSequenceNumber
		local isProcessable = rawequal(draftMessage.roundId, currentRoundId)
			and SetRoundOutfitDraftMessageReader.isLegalOutfitDraftSequenceNumber(outfitDraftSequenceNumber)
		if not isProcessable then
			return
		end
		local draftKey = buildDraftKey(currentRoundId, playerUserId, outfitDraftSequenceNumber)
		local sentOutfit = sentOutfitByDraftKey[draftKey]
		if sentOutfit == nil then
			sentOutfitByDraftKey[draftKey] = { outfitStylingItemKeys = draftMessage.outfitStylingItemKeys }
		elseif
			type(sentOutfit.outfitStylingItemKeys) == "table"
			and getmetatable(sentOutfit.outfitStylingItemKeys) == nil
		then
			draftMessage.outfitStylingItemKeys = table.clone(sentOutfit.outfitStylingItemKeys)
		else
			draftMessage.outfitStylingItemKeys = sentOutfit.outfitStylingItemKeys
		end
	end
	function sentOutfitBook.readSentOutfit(roundId: string, playerUserId: number, outfitDraftSequenceNumber: number)
		return sentOutfitByDraftKey[buildDraftKey(roundId, playerUserId, outfitDraftSequenceNumber)]
	end
	return sentOutfitBook
end

local function buildArbitraryDraftMessage(seededRandomNumberGenerator, currentRoundId: string?): any
	if seededRandomNumberGenerator.nextWholeNumberInRange(1, 10) <= 3 then
		return buildArbitraryValue(seededRandomNumberGenerator, 0)
	end
	local roundIdChoice = seededRandomNumberGenerator.nextWholeNumberInRange(1, 10)
	local outfitChoice = seededRandomNumberGenerator.nextWholeNumberInRange(1, 10)
	local draftMessage = {
		roundId = if roundIdChoice <= 6
			then currentRoundId
			elseif roundIdChoice <= 8 then "round-0"
			else buildArbitraryValue(seededRandomNumberGenerator, 0),
		outfitDraftSequenceNumber = if seededRandomNumberGenerator.nextWholeNumberInRange(1, 10) <= 6
			then seededRandomNumberGenerator.nextWholeNumberInRange(1, 40)
			else buildArbitraryValue(seededRandomNumberGenerator, 0),
		outfitStylingItemKeys = if outfitChoice <= 6
			then table.clone(seededRandomNumberGenerator.pickRandomListElement(OUTFIT_CHOICES))
			else buildArbitraryValue(seededRandomNumberGenerator, 0),
	}
	if seededRandomNumberGenerator.nextWholeNumberInRange(1, 10) == 1 then
		draftMessage.outfitScore = 100
		draftMessage.starCount = 5
		draftMessage.starCoinsGranted = 1e9
	end
	return draftMessage
end

-- At the first Showcase step of a round: every participant's scored outfit is the one the test
-- itself sent under the number of their last kept acknowledgement (empty when none).
local function checkShowcaseScoredOutfits(harness, roundId: string, readExpectedScoredOutfit)
	for _, participantUserId in harness.referee:listCurrentRoundParticipantUserIds() do
		local showcaseStageEntry = harness.referee:readShowcaseStageEntry(participantUserId)
		expect(showcaseStageEntry.scoredOutfitStylingItemKeys).toEqual(
			readExpectedScoredOutfit(roundId, participantUserId)
		)
	end
end

-- At the first Results step of a round: grants are at most one per participant, only for a
-- non-empty kept outfit, exactly that outfit, and every participant with one is granted.
local function checkResultsGrants(harness, roundId: string, readExpectedScoredOutfit)
	local participantUserIds = harness.referee:listCurrentRoundParticipantUserIds()
	local grantedPlayerUserIdSet, roundGrantCount = {}, 0
	for _, grantCall in harness.recordedGrantCalls do
		if grantCall.themedRoundCompletion.roundId ~= roundId then
			continue
		end
		roundGrantCount += 1
		expect(grantedPlayerUserIdSet[grantCall.playerUserId]).toBeNil()
		grantedPlayerUserIdSet[grantCall.playerUserId] = true
		local scoredOutfit = grantCall.themedRoundCompletion.scoredOutfitStylingItemKeys
		expect(#scoredOutfit > 0).toBeTrue()
		expect(scoredOutfit).toEqual(readExpectedScoredOutfit(roundId, grantCall.playerUserId))
	end
	expect(roundGrantCount <= #participantUserIds).toBeTrue()
	for _, participantUserId in participantUserIds do
		local isKeptOutfitNonEmpty = #readExpectedScoredOutfit(roundId, participantUserId) > 0
		expect(grantedPlayerUserIdSet[participantUserId] == true).toBe(isKeptOutfitNonEmpty)
	end
end

describe("ThemedRoundReferee with arbitrary device values (audit scenario 79)", function()
	it("never raises and keeps every scoring, timer, validation and payment invariant", function()
		SeededRandomTrials.runSeededRandomTrials(1, function(seededRandomNumberGenerator)
			local sentOutfitBook = createSentOutfitBook()
			-- [roundId][playerUserId] = the outfit the test sent under the last kept acknowledgement
			local expectedKeptOutfitByRoundId = {}
			local harness = ThemedRoundRefereeTestHarness.createRefereeWithFakes({
				onRoundOutfitDraftAcknowledged = function(playerUserId: number, acknowledgement)
					if not acknowledgement.isKept then
						return
					end
					local sentOutfit = sentOutfitBook.readSentOutfit(
						acknowledgement.roundId,
						playerUserId,
						acknowledgement.outfitDraftSequenceNumber
					)
					expect(sentOutfit ~= nil).toBeTrue()
					local roundExpectations = expectedKeptOutfitByRoundId[acknowledgement.roundId] or {}
					expectedKeptOutfitByRoundId[acknowledgement.roundId] = roundExpectations
					roundExpectations[playerUserId] = table.clone(sentOutfit.outfitStylingItemKeys)
				end,
			})
			for _, playerUserId in LOADED_PLAYER_USER_IDS do
				harness.loadPlayer(playerUserId)
			end

			local function readExpectedScoredOutfit(roundId: string, playerUserId: number)
				local roundExpectations = expectedKeptOutfitByRoundId[roundId] or {}
				return roundExpectations[playerUserId] or {}
			end

			local checkedShowcaseRoundIds, checkedResultsRoundIds = {}, {}
			local stylingMillisecondsElapsed, roundsStartedCount = 0, 1
			local lastSeenRoundId = harness.readCurrentRoundId()
			for _ = 1, STEP_COUNT do
				local roundPhaseBeforeStep = harness.readCurrentRoundState().roundPhase
				local stepMilliseconds =
					seededRandomNumberGenerator.nextWholeNumberInRange(0, MAXIMUM_STEP_MILLISECONDS)
				harness.advanceToRoundSecond((harness.readCurrentRoundMilliseconds() + stepMilliseconds) / 1000)
				local roundState = harness.readCurrentRoundState()
				if roundPhaseBeforeStep == "Styling" or roundState.roundPhase == "Styling" then
					stylingMillisecondsElapsed += stepMilliseconds
				end
				if roundState.roundId ~= lastSeenRoundId then
					lastSeenRoundId = roundState.roundId
					roundsStartedCount += 1
				end

				local playerUserId = seededRandomNumberGenerator.pickRandomListElement(ALL_PLAYER_USER_IDS)
				local isJoinRequest = seededRandomNumberGenerator.nextWholeNumberInRange(1, 10) <= 2
				local arbitraryDeviceValue
				if isJoinRequest then
					arbitraryDeviceValue = buildArbitraryValue(seededRandomNumberGenerator, 0)
				else
					arbitraryDeviceValue = buildArbitraryDraftMessage(seededRandomNumberGenerator, roundState.roundId)
					if type(arbitraryDeviceValue) == "table" and getmetatable(arbitraryDeviceValue) == nil then
						sentOutfitBook.fixOutfitOfProcessableMessage(
							arbitraryDeviceValue,
							roundState.roundId,
							playerUserId
						)
					end
				end
				local didStepSucceed, stepError = pcall(function()
					if isJoinRequest then
						(harness.referee.admitOrRejectJoinCurrentRoundRequest :: any)(
							harness.referee,
							playerUserId,
							arbitraryDeviceValue
						)
					else
						harness.referee:receiveSetRoundOutfitDraftFromDevice(playerUserId, arbitraryDeviceValue)
					end
				end)
				if not didStepSucceed then
					error("the referee raised for an arbitrary device value: " .. tostring(stepError), 0)
				end

				local currentDraftKeeper = harness.createdDraftKeepers[#harness.createdDraftKeepers]
				expect(
					currentDraftKeeper:countPendingOutfitDraftProcessingTimers()
						<= currentDraftKeeper:countParticipants()
				).toBeTrue()
				expect(
					harness.countingOutfitValidator.validationCallCount
						<= #LOADED_PLAYER_USER_IDS * (stylingMillisecondsElapsed / 250 + 2 * roundsStartedCount)
				).toBeTrue()

				local roundId = roundState.roundId
				if roundState.roundPhase == "Showcase" and not checkedShowcaseRoundIds[roundId] then
					checkedShowcaseRoundIds[roundId] = true
					checkShowcaseScoredOutfits(harness, roundId, readExpectedScoredOutfit)
				elseif roundState.roundPhase == "Results" and not checkedResultsRoundIds[roundId] then
					checkedResultsRoundIds[roundId] = true
					checkResultsGrants(harness, roundId, readExpectedScoredOutfit)
				end
			end
			expect(roundsStartedCount >= 2).toBeTrue()
			expect(harness.countingOutfitValidator.validationCallCount > 0).toBeTrue()
			expect(#harness.recordedGrantCalls > 0).toBeTrue()
		end)
	end)
end)
