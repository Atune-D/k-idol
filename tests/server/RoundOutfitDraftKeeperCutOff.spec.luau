-- RoundOutfitDraftKeeper, the §2.3 cut-off at the end of Styling. Referee audit PART 3 section
-- F, scenarios 43 to 48 (times are round seconds T; Styling ends at T = 190).

local UnitTestFramework = require("../Support/UnitTestFramework")
local RoundOutfitDraftKeeperTestHarness = require("./RoundOutfitDraftKeeperTestHarness")
local RoundOutfitDraftKeeper = require("../../src/server/RoundOutfitDraftKeeper")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_P = RoundOutfitDraftKeeperTestHarness.PLAYER_P
local PLAYER_Q = RoundOutfitDraftKeeperTestHarness.PLAYER_Q
local PLAYER_R = RoundOutfitDraftKeeperTestHarness.PLAYER_R
local OUTFIT_A = RoundOutfitDraftKeeperTestHarness.OUTFIT_A
local OUTFIT_B = RoundOutfitDraftKeeperTestHarness.OUTFIT_B
local OUTFIT_C = RoundOutfitDraftKeeperTestHarness.OUTFIT_C
local OUTFIT_D = RoundOutfitDraftKeeperTestHarness.OUTFIT_D
local INVALID_OUTFIT_X = RoundOutfitDraftKeeperTestHarness.INVALID_OUTFIT_X
local WORKED_EXAMPLE_OUTFIT_E83 = RoundOutfitDraftKeeperTestHarness.WORKED_EXAMPLE_OUTFIT_E83
local expectedAcknowledgement = RoundOutfitDraftKeeperTestHarness.expectedAcknowledgement

local function createStylingHarnessWithParticipants(playerUserIds: { number }, harnessOptions: any?)
	local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes(harnessOptions)
	harness.joinAtRoundSecond3AndStartStyling(playerUserIds)
	return harness
end

describe("RoundOutfitDraftKeeper cut-off (spec §2.3)", function()
	it(
		"scenario 43: a waiting draft is processed and acknowledged during the cut-off, before outfits are handed back",
		function()
			local harness = createStylingHarnessWithParticipants({ PLAYER_P })
			harness.sendDraftAtRoundSecond(189.90, PLAYER_P, 7, OUTFIT_B)
			harness.sendDraftAtRoundSecond(189.95, PLAYER_P, 8, OUTFIT_C)
			harness.advanceToRoundSecond(190.00)
			expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)

			local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
			expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
				expectedAcknowledgement(189.90, 7, true),
				expectedAcknowledgement(190.00, 8, true),
			})
			expect(finalOutfits[PLAYER_P]).toEqual(OUTFIT_C)
			expect(harness.keeper:isAcceptingOutfitDrafts()).toBeFalse()
			expect(harness.keeper:countPendingOutfitDraftProcessingTimers()).toBe(0)
			expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)

			harness.advanceToRoundSecond(191)
			expect(harness.recordingSender.countAcknowledgements()).toBe(2)
			expect(harness.countingOutfitValidator.validationCallCount).toBe(2)
			expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_C)
		end
	)

	it("scenario 43: the cut-off flush records a processing with the limiter", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(189.90, PLAYER_P, 7, OUTFIT_B)
		harness.sendDraftAtRoundSecond(189.95, PLAYER_P, 8, OUTFIT_C)
		harness.advanceToRoundSecond(190.00)
		harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		expect(harness.playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER_P)).toBe(250)
	end)

	it(
		"scenario 44: an invalid waiting draft flushed at the cut-off is rejected; the earlier kept draft is final",
		function()
			local harness = createStylingHarnessWithParticipants({ PLAYER_P })
			harness.sendDraftAtRoundSecond(189.90, PLAYER_P, 7, OUTFIT_B)
			harness.sendDraftAtRoundSecond(189.95, PLAYER_P, 8, INVALID_OUTFIT_X)
			harness.advanceToRoundSecond(190.00)
			local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
			expect(harness.listAcknowledgementsSentTo(PLAYER_P)[2]).toEqual(expectedAcknowledgement(190.00, 8, false))
			expect(finalOutfits[PLAYER_P]).toEqual(OUTFIT_B)
		end
	)

	it("scenario 45 (a): a draft handled at T = 190.000 before the cut-off step is acknowledged and final", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P, PLAYER_Q })
		harness.sendDraftAtRoundSecond(150, PLAYER_P, 8, OUTFIT_C)
		harness.sendDraftAtRoundSecond(189.90, PLAYER_Q, 8, OUTFIT_C)
		harness.sendDraftAtRoundSecond(190.000, PLAYER_P, 9, OUTFIT_D) -- processed at once
		harness.sendDraftAtRoundSecond(190.000, PLAYER_Q, 9, OUTFIT_D) -- waits, flushed below
		local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[2]).toEqual(expectedAcknowledgement(190, 9, true))
		expect(harness.listAcknowledgementsSentTo(PLAYER_Q)[2]).toEqual(expectedAcknowledgement(190, 9, true))
		expect(finalOutfits[PLAYER_P]).toEqual(OUTFIT_D)
		expect(finalOutfits[PLAYER_Q]).toEqual(OUTFIT_D)
	end)

	it("scenario 45 (b): a draft handled at T = 190.000 after the cut-off step is ignored", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(150, PLAYER_P, 8, OUTFIT_C)
		harness.advanceToRoundSecond(190.000)
		local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		harness.keeper:receiveOutfitDraftFromDevice(PLAYER_P, harness.buildOutfitDraftMessage(9, OUTFIT_D))
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({ expectedAcknowledgement(150, 8, true) })
		expect(finalOutfits[PLAYER_P]).toEqual(OUTFIT_C)
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_C)
		expect(harness.countingOutfitValidator.validationCallCount).toBe(1)
	end)

	it("scenario 46: a resend arriving after the cut-off gets no acknowledgement at all", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(189.20, PLAYER_P, 8, OUTFIT_C)
		harness.advanceToRoundSecond(190)
		local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		harness.sendDraftAtRoundSecond(190.10, PLAYER_P, 8, OUTFIT_C)
		expect(harness.recordingSender.countAcknowledgements()).toBe(1)
		expect(finalOutfits[PLAYER_P]).toEqual(OUTFIT_C)
	end)

	it("scenario 14: drafts at T = 190.5, 249, 255 and 275 are ignored without acknowledgement", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(100, PLAYER_P, 1, OUTFIT_C)
		harness.advanceToRoundSecond(190)
		local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		for _, roundSeconds in { 190.5, 249, 255, 275 } do
			harness.sendDraftAtRoundSecond(roundSeconds, PLAYER_P, 9, OUTFIT_D)
		end
		expect(harness.recordingSender.countAcknowledgements()).toBe(1)
		expect(harness.countingOutfitValidator.validationCallCount).toBe(1)
		expect(finalOutfits[PLAYER_P]).toEqual(OUTFIT_C)
	end)

	it("scenario 47: a second cut-off returns nil, sends nothing and changes nothing", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(189.90, PLAYER_P, 7, OUTFIT_B)
		harness.sendDraftAtRoundSecond(189.95, PLAYER_P, 8, OUTFIT_C)
		harness.advanceToRoundSecond(190)
		local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		expect(harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()).toBeNil()
		expect(harness.recordingSender.countAcknowledgements()).toBe(2)
		expect(harness.countingOutfitValidator.validationCallCount).toBe(2)
		expect(finalOutfits[PLAYER_P]).toEqual(OUTFIT_C)
		expect(#harness.loggedInformation).toBe(1)
	end)

	it("scenario 47: a stale timer firing after the cut-off does nothing", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P }, { isTimerCancellationIgnored = true })
		harness.sendDraftAtRoundSecond(189.90, PLAYER_P, 7, OUTFIT_B)
		harness.sendDraftAtRoundSecond(189.95, PLAYER_P, 8, OUTFIT_C)
		harness.advanceToRoundSecond(190)
		harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(1) -- not really cancelled
		harness.advanceToRoundSecond(191)
		expect(harness.recordingSender.countAcknowledgements()).toBe(2)
		expect(harness.countingOutfitValidator.validationCallCount).toBe(2)
	end)

	it(
		"scenario 48: the handed-back outfits are frozen and never re-validated, even if the available set changes",
		function()
			local harness = createStylingHarnessWithParticipants({ PLAYER_P })
			harness.sendDraftAtRoundSecond(40, PLAYER_P, 1, WORKED_EXAMPLE_OUTFIT_E83)
			harness.advanceToRoundSecond(190)
			local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
			harness.advanceToRoundSecond(220)
			harness.hideStylingItemKeyFromNowOn(WORKED_EXAMPLE_OUTFIT_E83[1])
			harness.advanceToRoundSecond(250)
			expect(finalOutfits[PLAYER_P]).toEqual(WORKED_EXAMPLE_OUTFIT_E83)
			expect(table.isfrozen(finalOutfits)).toBeTrue()
			expect(table.isfrozen(finalOutfits[PLAYER_P])).toBeTrue()
			expect(harness.countingOutfitValidator.validationCallCount).toBe(1)
		end
	)

	it("scenario 65 (keeper side): a kept draft is handed back whole even after one of its items was hidden", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(40, PLAYER_P, 1, WORKED_EXAMPLE_OUTFIT_E83)
		harness.advanceToRoundSecond(120)
		harness.hideStylingItemKeyFromNowOn(WORKED_EXAMPLE_OUTFIT_E83[1])
		harness.advanceToRoundSecond(190)
		expect(harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()[PLAYER_P]).toEqual(WORKED_EXAMPLE_OUTFIT_E83)
	end)

	it("hands back every current participant, the empty outfit for one with no kept draft, nobody removed", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P, PLAYER_Q, PLAYER_R })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20, PLAYER_R, 1, OUTFIT_B)
		harness.advanceToRoundSecond(100)
		harness.keeper:removeParticipant(PLAYER_R)
		harness.advanceToRoundSecond(190)
		local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		expect(finalOutfits).toEqual({ [PLAYER_P] = OUTFIT_A, [PLAYER_Q] = {} })
		expect(table.isfrozen(finalOutfits[PLAYER_Q])).toBeTrue()
	end)

	it("may run before drafts were ever accepted: everyone has the empty outfit", function()
		local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes()
		harness.advanceToRoundSecond(3)
		harness.addParticipants({ PLAYER_P })
		local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		expect(finalOutfits).toEqual({ [PLAYER_P] = {} })
		expect(harness.keeper:isAcceptingOutfitDrafts()).toBeFalse()
		expect(function()
			harness.keeper:startAcceptingOutfitDrafts()
		end).toThrow("startAcceptingOutfitDrafts")
	end)

	it("flushes every participant's waiting draft, in join order, ignoring the interval", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_Q, PLAYER_R, PLAYER_P })
		harness.sendDraftAtRoundSecond(189.90, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(189.90, PLAYER_Q, 1, OUTFIT_B)
		harness.sendDraftAtRoundSecond(189.99, PLAYER_P, 2, OUTFIT_C)
		harness.sendDraftAtRoundSecond(189.99, PLAYER_Q, 2, OUTFIT_D)
		harness.advanceToRoundSecond(190)
		local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		local sentRecords = harness.recordingSender.sentAcknowledgementRecords
		expect(#sentRecords).toBe(4)
		expect(sentRecords[3].playerUserId).toBe(PLAYER_Q)
		expect(sentRecords[4].playerUserId).toBe(PLAYER_P)
		expect(finalOutfits).toEqual({ [PLAYER_P] = OUTFIT_C, [PLAYER_Q] = OUTFIT_D, [PLAYER_R] = {} })
		expect(harness.loggedInformation).toEqual({
			"RoundOutfitDraftKeeper: outfit drafts of round round-1 cut off with 3 participants; "
				.. "2 waiting drafts processed",
		})
	end)

	it(
		"stops accepting before flushing: a draft delivered from inside the sender during the cut-off is ignored",
		function()
			local harness = createStylingHarnessWithParticipants({})
			harness.advanceToRoundSecond(190)
			local reenteringKeeper
			local reentryCount = 0
			local keeperDependencies = harness.buildKeeperDependencies("round-reentry")
			local recordingSend = keeperDependencies.sendRoundOutfitDraftAcknowledged
			keeperDependencies.sendRoundOutfitDraftAcknowledged = function(playerUserId, acknowledgement)
				recordingSend(playerUserId, acknowledgement)
				reentryCount += 1
				reenteringKeeper:receiveOutfitDraftFromDevice(
					PLAYER_Q,
					harness.buildOutfitDraftMessage(reentryCount, OUTFIT_C, "round-reentry")
				)
			end
			reenteringKeeper = RoundOutfitDraftKeeper.new(keeperDependencies)
			reenteringKeeper:addParticipant(PLAYER_P)
			reenteringKeeper:addParticipant(PLAYER_Q)
			reenteringKeeper:startAcceptingOutfitDrafts()
			reenteringKeeper:receiveOutfitDraftFromDevice(
				PLAYER_P,
				harness.buildOutfitDraftMessage(1, OUTFIT_A, "round-reentry")
			)
			reenteringKeeper:receiveOutfitDraftFromDevice(
				PLAYER_P,
				harness.buildOutfitDraftMessage(2, OUTFIT_B, "round-reentry")
			)
			-- While accepting: P's ack delivered Q's seq 1 (processed, acked: that delivered Q's seq 2,
			-- which waits). P's seq 2 waits too.
			expect(reentryCount).toBe(2)
			expect(reenteringKeeper:readHighestProcessedOutfitDraftSequenceNumber(PLAYER_Q)).toBe(1)
			local finalOutfits = reenteringKeeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
			-- The flush acks of P's seq 2 and Q's seq 2 delivered Q's seq 3 and 4: both ignored.
			expect(reentryCount).toBe(4)
			expect(finalOutfits[PLAYER_P]).toEqual(OUTFIT_B)
			expect(finalOutfits[PLAYER_Q]).toEqual(OUTFIT_C)
			expect(reenteringKeeper:readHighestProcessedOutfitDraftSequenceNumber(PLAYER_Q)).toBe(2)
		end
	)

	it("stores a fresh acknowledgement before sending it: a duplicate sent from inside the sender gets it", function()
		local harness = createStylingHarnessWithParticipants({})
		harness.advanceToRoundSecond(20)
		local reenteringKeeper
		local hasReentered = false
		local keeperDependencies = harness.buildKeeperDependencies("round-reentry")
		local recordingSend = keeperDependencies.sendRoundOutfitDraftAcknowledged
		keeperDependencies.sendRoundOutfitDraftAcknowledged = function(playerUserId, acknowledgement)
			recordingSend(playerUserId, acknowledgement)
			if acknowledgement.outfitDraftSequenceNumber == 2 and not hasReentered then
				hasReentered = true
				reenteringKeeper:receiveOutfitDraftFromDevice(
					PLAYER_P,
					harness.buildOutfitDraftMessage(2, OUTFIT_B, "round-reentry")
				)
			end
		end
		reenteringKeeper = RoundOutfitDraftKeeper.new(keeperDependencies)
		reenteringKeeper:addParticipant(PLAYER_P)
		reenteringKeeper:startAcceptingOutfitDrafts()
		reenteringKeeper:receiveOutfitDraftFromDevice(
			PLAYER_P,
			harness.buildOutfitDraftMessage(1, OUTFIT_A, "round-reentry")
		)
		harness.advanceToRoundSecond(21)
		reenteringKeeper:receiveOutfitDraftFromDevice(
			PLAYER_P,
			harness.buildOutfitDraftMessage(2, OUTFIT_B, "round-reentry")
		)
		local sentRecords = harness.recordingSender.sentAcknowledgementRecords
		expect(#sentRecords).toBe(3)
		expect(rawequal(sentRecords[3].acknowledgement, sentRecords[2].acknowledgement)).toBeTrue()
	end)

	it("a server dependency raising while one waiting draft is flushed costs only that draft", function()
		local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes()
		local keeperDependencies = harness.buildKeeperDependencies("round-isolation")
		local readAvailableStylingItemKeySet = keeperDependencies.readAvailableStylingItemKeySet
		local isAvailableSetReadBroken = false
		keeperDependencies.readAvailableStylingItemKeySet = function()
			if isAvailableSetReadBroken then
				isAvailableSetReadBroken = false -- fails once: for the first participant flushed
				error("deliberate available-set failure")
			end
			return readAvailableStylingItemKeySet()
		end
		local isolationKeeper = RoundOutfitDraftKeeper.new(keeperDependencies)
		local function sendDraft(playerUserId: number, outfitDraftSequenceNumber: number, outfitStylingItemKeys)
			isolationKeeper:receiveOutfitDraftFromDevice(
				playerUserId,
				harness.buildOutfitDraftMessage(outfitDraftSequenceNumber, outfitStylingItemKeys, "round-isolation")
			)
		end
		harness.advanceToRoundSecond(3)
		isolationKeeper:addParticipant(PLAYER_P)
		isolationKeeper:addParticipant(PLAYER_Q)
		harness.advanceToRoundSecond(10)
		isolationKeeper:startAcceptingOutfitDrafts()
		harness.advanceToRoundSecond(189.90)
		sendDraft(PLAYER_P, 1, OUTFIT_A)
		sendDraft(PLAYER_Q, 1, OUTFIT_B)
		harness.advanceToRoundSecond(189.95)
		sendDraft(PLAYER_P, 2, OUTFIT_C)
		sendDraft(PLAYER_Q, 2, OUTFIT_D)
		harness.advanceToRoundSecond(190)
		isAvailableSetReadBroken = true
		local finalOutfits = isolationKeeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		expect(finalOutfits).toEqual({ [PLAYER_P] = OUTFIT_A, [PLAYER_Q] = OUTFIT_D })
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_Q)).toBe(2)
		expect(#harness.loggedWarnings).toBe(1)
		expect(string.find(harness.loggedWarnings[1], "1 waiting drafts of round round-isolation", 1, true) ~= nil).toBeTrue()
		expect(isolationKeeper:countPendingOutfitDraftProcessingTimers()).toBe(0)
	end)
end)
