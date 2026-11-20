-- RoundOutfitDraftKeeper: construction checks, the round lifecycle (startAcceptingOutfitDrafts,
-- cut-off, endRound), argument checks, frozen results, logging and a failing sender. Every
-- promise of the header comment that is not about one §2.3 check is tested here.

local UnitTestFramework = require("../Support/UnitTestFramework")
local RoundOutfitDraftKeeperTestHarness = require("./RoundOutfitDraftKeeperTestHarness")
local RoundOutfitDraftKeeper = require("../../src/server/RoundOutfitDraftKeeper")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_P = RoundOutfitDraftKeeperTestHarness.PLAYER_P
local PLAYER_Q = RoundOutfitDraftKeeperTestHarness.PLAYER_Q
local PLAYER_R = RoundOutfitDraftKeeperTestHarness.PLAYER_R
local ROUND_ID = RoundOutfitDraftKeeperTestHarness.ROUND_ID
local OUTFIT_A = RoundOutfitDraftKeeperTestHarness.OUTFIT_A
local OUTFIT_B = RoundOutfitDraftKeeperTestHarness.OUTFIT_B
local OUTFIT_C = RoundOutfitDraftKeeperTestHarness.OUTFIT_C
local INVALID_OUTFIT_X = RoundOutfitDraftKeeperTestHarness.INVALID_OUTFIT_X
local expectedAcknowledgement = RoundOutfitDraftKeeperTestHarness.expectedAcknowledgement

local function createStylingHarnessWithParticipants(playerUserIds: { number }, harnessOptions: any?)
	local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes(harnessOptions)
	harness.joinAtRoundSecond3AndStartStyling(playerUserIds)
	return harness
end

describe("RoundOutfitDraftKeeper.new", function()
	local requiredDependencyNames = {
		"roundId",
		"clock",
		"scheduler",
		"playerRequestRateLimiter",
		"readAvailableStylingItemKeySet",
		"stylingItemByStylingItemKey",
		"sendRoundOutfitDraftAcknowledged",
		"logger",
	}

	it("raises naming each missing dependency", function()
		local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes()
		for _, dependencyName in requiredDependencyNames do
			local keeperDependencies = harness.buildKeeperDependencies(ROUND_ID)
			keeperDependencies[dependencyName] = nil
			expect(function()
				RoundOutfitDraftKeeper.new(keeperDependencies)
			end).toThrow("dependencies." .. dependencyName)
		end
	end)

	it("raises for a dependency of the wrong kind, a non-table dependencies value and an empty roundId", function()
		local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes()
		for _, dependencyName in requiredDependencyNames do
			local keeperDependencies = harness.buildKeeperDependencies(ROUND_ID)
			keeperDependencies[dependencyName] = 5
			expect(function()
				RoundOutfitDraftKeeper.new(keeperDependencies)
			end).toThrow("dependencies." .. dependencyName)
		end
		local keeperDependencies = harness.buildKeeperDependencies(ROUND_ID)
		keeperDependencies.validateOutfit = "not a function"
		expect(function()
			RoundOutfitDraftKeeper.new(keeperDependencies)
		end).toThrow("dependencies.validateOutfit")
		expect(function()
			RoundOutfitDraftKeeper.new(nil :: any)
		end).toThrow("dependencies table")
		expect(function()
			RoundOutfitDraftKeeper.new(harness.buildKeeperDependencies(""))
		end).toThrow("non-empty")
	end)

	it("uses the real OutfitValidator when no validateOutfit is given", function()
		local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes()
		local keeperDependencies = harness.buildKeeperDependencies(ROUND_ID)
		keeperDependencies.validateOutfit = nil
		local keeper = RoundOutfitDraftKeeper.new(keeperDependencies)
		keeper:addParticipant(PLAYER_P)
		keeper:startAcceptingOutfitDrafts()
		keeper:receiveOutfitDraftFromDevice(PLAYER_P, harness.buildOutfitDraftMessage(1, INVALID_OUTFIT_X))
		harness.advanceToRoundSecond(1)
		keeper:receiveOutfitDraftFromDevice(PLAYER_P, harness.buildOutfitDraftMessage(2, OUTFIT_A))
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(0, 1, false),
			expectedAcknowledgement(1, 2, true),
		})
		expect(harness.countingOutfitValidator.validationCallCount).toBe(0)
	end)

	it("exposes the protocol constants", function()
		expect(RoundOutfitDraftKeeper.OUTFIT_DRAFT_REJECTION_REASON_OUTFIT_INVALID).toBe("OutfitInvalid")
		expect(RoundOutfitDraftKeeper.ACKNOWLEDGEMENT_RESEND_MINIMUM_INTERVAL_MILLISECONDS).toBe(250)
		expect(RoundOutfitDraftKeeper.EMPTY_OUTFIT_STYLING_ITEM_KEYS).toEqual({})
		expect(table.isfrozen(RoundOutfitDraftKeeper.EMPTY_OUTFIT_STYLING_ITEM_KEYS)).toBeTrue()
		expect(table.isfrozen(RoundOutfitDraftKeeper)).toBeTrue()
	end)
end)

describe("RoundOutfitDraftKeeper round lifecycle", function()
	it("accepts drafts only between startAcceptingOutfitDrafts and the cut-off", function()
		local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes()
		expect(harness.keeper:isAcceptingOutfitDrafts()).toBeFalse()
		expect(harness.keeper:getRoundId()).toBe(ROUND_ID)
		harness.keeper:startAcceptingOutfitDrafts()
		expect(harness.keeper:isAcceptingOutfitDrafts()).toBeTrue()
		expect(function()
			harness.keeper:startAcceptingOutfitDrafts()
		end).toThrow("startAcceptingOutfitDrafts called in stage AcceptingOutfitDrafts")
		harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		expect(harness.keeper:isAcceptingOutfitDrafts()).toBeFalse()
		expect(function()
			harness.keeper:startAcceptingOutfitDrafts()
		end).toThrow("startAcceptingOutfitDrafts called in stage OutfitDraftsCutOff")
	end)

	it("refuses to add a participant twice, after the cut-off and after endRound", function()
		local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes()
		harness.keeper:addParticipant(PLAYER_P) -- before Styling is allowed
		expect(function()
			harness.keeper:addParticipant(PLAYER_P)
		end).toThrow("already a participant")
		harness.keeper:startAcceptingOutfitDrafts()
		harness.keeper:addParticipant(PLAYER_Q) -- during Styling is allowed
		expect(harness.keeper:countParticipants()).toBe(2)
		harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		expect(function()
			harness.keeper:addParticipant(PLAYER_R)
		end).toThrow("addParticipant called in stage OutfitDraftsCutOff")
		harness.keeper:endRound()
		expect(function()
			harness.keeper:addParticipant(PLAYER_R)
		end).toThrow("addParticipant called in stage RoundEnded")
	end)

	it("can still remove a participant after the cut-off; the handed-back map does not change", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P, PLAYER_Q })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		harness.advanceToRoundSecond(190)
		local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		harness.keeper:removeParticipant(PLAYER_P)
		expect(harness.keeper:isParticipant(PLAYER_P)).toBeFalse()
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toBeNil()
		expect(finalOutfits).toEqual({ [PLAYER_P] = OUTFIT_A, [PLAYER_Q] = {} })
	end)

	it("endRound drops everything: drafts ignored, cut-off returns nil, removal does nothing", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P, PLAYER_Q })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.10, PLAYER_P, 2, OUTFIT_B)
		harness.keeper:endRound()
		expect(harness.keeper:countParticipants()).toBe(0)
		expect(harness.keeper:countPendingOutfitDraftProcessingTimers()).toBe(0)
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
		expect(harness.keeper:isParticipant(PLAYER_P)).toBeFalse()
		expect(harness.keeper:isAcceptingOutfitDrafts()).toBeFalse()
		harness.sendDraftAtRoundSecond(21, PLAYER_P, 3, OUTFIT_C)
		harness.keeper:removeParticipant(PLAYER_P)
		expect(harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()).toBeNil()
		harness.keeper:endRound()
		expect(harness.recordingSender.countAcknowledgements()).toBe(1)
		expect(function()
			harness.keeper:startAcceptingOutfitDrafts()
		end).toThrow("RoundEnded")
	end)

	it("a stale timer firing after endRound does nothing", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P }, { isTimerCancellationIgnored = true })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.10, PLAYER_P, 2, OUTFIT_B)
		harness.keeper:endRound()
		harness.advanceToRoundSecond(21)
		expect(harness.recordingSender.countAcknowledgements()).toBe(1)
		expect(harness.countingOutfitValidator.validationCallCount).toBe(1)
	end)

	it("the cut-off skips a participant that a sender removed during the cut-off", function()
		local harness = createStylingHarnessWithParticipants({})
		local keeperDependencies = harness.buildKeeperDependencies("round-removal")
		local recordingSend = keeperDependencies.sendRoundOutfitDraftAcknowledged
		local removingKeeper
		keeperDependencies.sendRoundOutfitDraftAcknowledged = function(playerUserId, acknowledgement)
			recordingSend(playerUserId, acknowledgement)
			if playerUserId == PLAYER_P and acknowledgement.outfitDraftSequenceNumber == 2 then
				removingKeeper:removeParticipant(PLAYER_Q)
			end
		end
		removingKeeper = RoundOutfitDraftKeeper.new(keeperDependencies)
		removingKeeper:addParticipant(PLAYER_P)
		removingKeeper:addParticipant(PLAYER_Q)
		removingKeeper:startAcceptingOutfitDrafts()
		harness.advanceToRoundSecond(189.9)
		for _, playerUserId in { PLAYER_P, PLAYER_Q } do
			removingKeeper:receiveOutfitDraftFromDevice(
				playerUserId,
				harness.buildOutfitDraftMessage(1, OUTFIT_A, "round-removal")
			)
			removingKeeper:receiveOutfitDraftFromDevice(
				playerUserId,
				harness.buildOutfitDraftMessage(2, OUTFIT_B, "round-removal")
			)
		end
		harness.advanceToRoundSecond(190)
		local finalOutfits = removingKeeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		expect(finalOutfits).toEqual({ [PLAYER_P] = OUTFIT_B })
		expect(#harness.listAcknowledgementsSentTo(PLAYER_Q)).toBe(1)
	end)
end)

describe("RoundOutfitDraftKeeper argument checks and read-only results", function()
	it("raises for a playerUserId that is not a number, or is NaN, in every method that takes one", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		local methodNames = {
			"addParticipant",
			"removeParticipant",
			"isParticipant",
			"receiveOutfitDraftFromDevice",
			"readKeptOutfitStylingItemKeys",
			"readHighestProcessedOutfitDraftSequenceNumber",
		}
		for _, methodName in methodNames do
			for _, badPlayerUserId in { "8801", 0 / 0, nil } do
				expect(function()
					harness.keeper[methodName](
						harness.keeper,
						badPlayerUserId,
						harness.buildOutfitDraftMessage(1, OUTFIT_A)
					)
				end).toThrow("RoundOutfitDraftKeeper: playerUserId must be a number")
			end
		end
	end)

	it("returns nil reads for a non-participant", function()
		local harness = createStylingHarnessWithParticipants({})
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toBeNil()
		expect(harness.keeper:readHighestProcessedOutfitDraftSequenceNumber(PLAYER_P)).toBeNil()
	end)

	it("hands out kept outfits and acknowledgements frozen, so no caller can change the keeper's state", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		expect(table.isfrozen(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P))).toBeTrue()
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		expect(table.isfrozen(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P))).toBeTrue()
		expect(table.isfrozen(harness.recordingSender.sentAcknowledgementRecords[1].acknowledgement)).toBeTrue()
		harness.advanceToRoundSecond(190)
		local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		expect(table.isfrozen(finalOutfits)).toBeTrue()
		expect(table.isfrozen(finalOutfits[PLAYER_P])).toBeTrue()
	end)
end)

describe("RoundOutfitDraftKeeper logging and a failing sender", function()
	it("logs nothing per draft: a hundred drafts of every kind leave the log empty", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		for draftNumber = 1, 100 do
			local roundSeconds = 20 + draftNumber * 0.1
			harness.sendDraftAtRoundSecond(
				roundSeconds,
				PLAYER_P,
				draftNumber,
				if draftNumber % 3 == 0 then INVALID_OUTFIT_X else OUTFIT_A
			)
			harness.sendDraftAtRoundSecond(roundSeconds, PLAYER_P, draftNumber - 1, OUTFIT_B)
			harness.sendDraftAtRoundSecond(roundSeconds, PLAYER_Q, draftNumber, OUTFIT_B)
			harness.sendDraftAtRoundSecond(roundSeconds, PLAYER_P, "x", OUTFIT_B)
		end
		expect(harness.loggedInformation).toEqual({})
		expect(harness.loggedWarnings).toEqual({})
	end)

	it("contains a raising sender: state still advances, only the first failure is logged", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P, PLAYER_Q })
		harness.recordingSender.shouldRaiseWhenSending = true
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20, PLAYER_Q, 1, OUTFIT_B)
		harness.sendDraftAtRoundSecond(21, PLAYER_P, 1, OUTFIT_A) -- re-send, also fails
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_A)
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_Q)).toEqual(OUTFIT_B)
		expect(harness.recordingSender.countAcknowledgements()).toBe(3)
		expect(#harness.loggedWarnings).toBe(1)
		expect(string.find(harness.loggedWarnings[1], "round-1", 1, true) ~= nil).toBeTrue()
		expect(string.find(harness.loggedWarnings[1], "deliberate send failure", 1, true) ~= nil).toBeTrue()
	end)

	it("a raising sender does not stop the cut-off from flushing and handing back everyone", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P, PLAYER_Q })
		harness.sendDraftAtRoundSecond(189.9, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(189.9, PLAYER_Q, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(189.95, PLAYER_P, 2, OUTFIT_B)
		harness.sendDraftAtRoundSecond(189.95, PLAYER_Q, 2, OUTFIT_C)
		harness.advanceToRoundSecond(190)
		harness.recordingSender.shouldRaiseWhenSending = true
		local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		expect(finalOutfits).toEqual({ [PLAYER_P] = OUTFIT_B, [PLAYER_Q] = OUTFIT_C })
		expect(harness.recordingSender.countAcknowledgements()).toBe(4)
		expect(#harness.loggedWarnings).toBe(1)
	end)
end)
