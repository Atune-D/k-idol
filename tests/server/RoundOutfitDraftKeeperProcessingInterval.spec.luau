-- RoundOutfitDraftKeeper, §2.3 check 3: the 0.25 s processing interval, the one-place waiting
-- buffer and its single timer. Referee audit PART 3 section D, scenarios 23 to 33, plus the
-- timer guard cases (times are round seconds T).

local UnitTestFramework = require("../Support/UnitTestFramework")
local RoundOutfitDraftKeeperTestHarness = require("./RoundOutfitDraftKeeperTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_P = RoundOutfitDraftKeeperTestHarness.PLAYER_P
local PLAYER_Q = RoundOutfitDraftKeeperTestHarness.PLAYER_Q
local OUTFIT_A = RoundOutfitDraftKeeperTestHarness.OUTFIT_A
local OUTFIT_B = RoundOutfitDraftKeeperTestHarness.OUTFIT_B
local OUTFIT_C = RoundOutfitDraftKeeperTestHarness.OUTFIT_C
local OUTFIT_D = RoundOutfitDraftKeeperTestHarness.OUTFIT_D
local INVALID_OUTFIT_X = RoundOutfitDraftKeeperTestHarness.INVALID_OUTFIT_X
local expectedAcknowledgement = RoundOutfitDraftKeeperTestHarness.expectedAcknowledgement

local function createStylingHarnessWithParticipants(playerUserIds: { number }, harnessOptions: any?)
	local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes(harnessOptions)
	harness.joinAtRoundSecond3AndStartStyling(playerUserIds)
	return harness
end

describe("RoundOutfitDraftKeeper check 3 (spec §2.3): processing interval", function()
	it("scenario 23: two drafts 0.1 s apart are both taken into account and the later one is kept", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({ expectedAcknowledgement(20.00, 1, true) })
		harness.sendDraftAtRoundSecond(20.10, PLAYER_P, 2, OUTFIT_B)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
		harness.advanceToRoundSecond(20.249)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
		harness.advanceToRoundSecond(20.250)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20.00, 1, true),
			expectedAcknowledgement(20.25, 2, true),
		})
		harness.advanceToRoundSecond(25)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(2)
		expect(harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()[PLAYER_P]).toEqual(OUTFIT_B)
	end)

	it("scenario 24: a draft exactly 0.25 s after the previous processing is processed immediately", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20.000, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.250, PLAYER_P, 2, OUTFIT_B)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[2]).toEqual(expectedAcknowledgement(20.25, 2, true))
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
	end)

	it("scenario 24 (separate run): a draft 1 ms too early waits until exactly 0.25 s", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20.000, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.249, PLAYER_P, 2, OUTFIT_B)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
		expect(harness.requestedTimerDelaySeconds).toEqual({ 0.001 })
		harness.advanceToRoundSecond(20.250)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[2]).toEqual(expectedAcknowledgement(20.25, 2, true))
	end)

	it("scenario 25: the interval runs from processing to processing, not from arrival", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.10, PLAYER_P, 2, OUTFIT_B)
		harness.sendDraftAtRoundSecond(20.40, PLAYER_P, 3, OUTFIT_C)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(2)
		harness.advanceToRoundSecond(21)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20.00, 1, true),
			expectedAcknowledgement(20.25, 2, true),
			expectedAcknowledgement(20.50, 3, true),
		})
	end)

	it("scenario 26: an invalid draft is processed, so it restarts the interval", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.30, PLAYER_P, 2, INVALID_OUTFIT_X)
		harness.sendDraftAtRoundSecond(20.40, PLAYER_P, 3, OUTFIT_B)
		harness.advanceToRoundSecond(21)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20.00, 1, true),
			expectedAcknowledgement(20.30, 2, false),
			expectedAcknowledgement(20.55, 3, true),
		})
	end)

	it("scenario 27: drafts arriving inside the interval coalesce into one waiting place with one timer", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		for _, arrival in { { 20.05, 2, OUTFIT_B }, { 20.10, 3, OUTFIT_C }, { 20.20, 4, OUTFIT_D } } do
			harness.sendDraftAtRoundSecond(arrival[1], PLAYER_P, arrival[2], arrival[3])
			expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(1)
			expect(harness.keeper:countPendingOutfitDraftProcessingTimers()).toBe(1)
		end
		harness.advanceToRoundSecond(20.25)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20.00, 1, true),
			expectedAcknowledgement(20.25, 4, true),
		})
		expect(harness.countingOutfitValidator.validationCallCount).toBe(2)
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_D)
		expect(harness.keeper:countPendingOutfitDraftProcessingTimers()).toBe(0)

		harness.sendDraftAtRoundSecond(21, PLAYER_P, 2, OUTFIT_B)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[3]).toEqual(expectedAcknowledgement(21, 4, true))
	end)

	it("scenario 28: a lower number never displaces the waiting draft", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 4, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.05, PLAYER_P, 6, OUTFIT_B)
		harness.sendDraftAtRoundSecond(20.10, PLAYER_P, 5, OUTFIT_C)
		harness.advanceToRoundSecond(21)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20.00, 4, true),
			expectedAcknowledgement(20.25, 6, true),
		})
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_B)
	end)

	it("scenario 29: the same number as the waiting draft is dropped; the first-arrived content stays", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.05, PLAYER_P, 2, OUTFIT_B)
		harness.sendDraftAtRoundSecond(20.10, PLAYER_P, 2, OUTFIT_C)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
		harness.advanceToRoundSecond(21)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20.00, 1, true),
			expectedAcknowledgement(20.25, 2, true),
		})
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_B)
	end)

	it("scenario 30: a waiting draft that turns out invalid is rejected; the kept draft stays", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.10, PLAYER_P, 2, INVALID_OUTFIT_X)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
		harness.advanceToRoundSecond(21)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20.00, 1, true),
			expectedAcknowledgement(20.25, 2, false),
		})
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_A)
	end)

	it("scenario 31 (reported spec gap): an invalid higher draft displaces a valid waiting one", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.05, PLAYER_P, 2, OUTFIT_B)
		harness.sendDraftAtRoundSecond(20.10, PLAYER_P, 3, INVALID_OUTFIT_X)
		harness.advanceToRoundSecond(21)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20.00, 1, true),
			expectedAcknowledgement(20.25, 3, false),
		})
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_A)
	end)

	it(
		"scenario 32: a newer draft arriving after an overdue timer is processed at once; the waiting one never",
		function()
			local harness = createStylingHarnessWithParticipants({ PLAYER_P })
			harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
			harness.sendDraftAtRoundSecond(20.10, PLAYER_P, 2, OUTFIT_B)
			harness.moveClockWithoutRunningTimersToRoundSecond(20.27)
			harness.keeper:receiveOutfitDraftFromDevice(PLAYER_P, harness.buildOutfitDraftMessage(3, OUTFIT_C))
			harness.advanceToRoundSecond(20.27) -- runs whatever is due
			harness.advanceToRoundSecond(21)
			expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
				expectedAcknowledgement(20.00, 1, true),
				expectedAcknowledgement(20.27, 3, true),
			})
			expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_C)
			expect(harness.countingOutfitValidator.validationCallCount).toBe(2)
			expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
			-- The superseded seq 2 is gone for good: the cut-off finds nothing waiting.
			harness.advanceToRoundSecond(190)
			expect(harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()[PLAYER_P]).toEqual(OUTFIT_C)
			expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(2)
		end
	)

	it("scenario 33: players are independent; neither buffer replaces the other's draft", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P, PLAYER_Q })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.05, PLAYER_Q, 1, OUTFIT_B)
		expect(harness.listAcknowledgementsSentTo(PLAYER_Q)).toEqual({ expectedAcknowledgement(20.05, 1, true) })
		harness.sendDraftAtRoundSecond(20.10, PLAYER_P, 2, OUTFIT_C)
		harness.sendDraftAtRoundSecond(20.12, PLAYER_Q, 2, OUTFIT_D)
		expect(harness.keeper:countPendingOutfitDraftProcessingTimers()).toBe(2)
		harness.advanceToRoundSecond(21)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[2]).toEqual(expectedAcknowledgement(20.25, 2, true))
		expect(harness.listAcknowledgementsSentTo(PLAYER_Q)[2]).toEqual(expectedAcknowledgement(20.30, 2, true))
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_C)
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_Q)).toEqual(OUTFIT_D)
	end)
end)

describe("RoundOutfitDraftKeeper waiting-draft timer", function()
	it("waits for the rest of the interval when the scheduler runs the timer early (still one timer)", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P }, { timerFiresEarlyByMilliseconds = 100 })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.10, PLAYER_P, 2, OUTFIT_B)
		harness.advanceToRoundSecond(20.249)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
		expect(harness.keeper:countPendingOutfitDraftProcessingTimers()).toBe(1)
		harness.advanceToRoundSecond(20.3)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[2]).toEqual(expectedAcknowledgement(20.25, 2, true))
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(2)
		expect(#harness.requestedTimerDelaySeconds > 1).toBeTrue() -- it was re-armed
		expect(harness.keeper:countPendingOutfitDraftProcessingTimers()).toBe(0)
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(0)
	end)

	it("asks the scheduler for exactly the milliseconds the limiter says are left", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.07, PLAYER_P, 2, OUTFIT_B)
		expect(harness.requestedTimerDelaySeconds).toEqual({ 0.18 })
	end)

	it("a timer whose draft was superseded (processed at once) does nothing when it still fires", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P }, { isTimerCancellationIgnored = true })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.10, PLAYER_P, 2, OUTFIT_B)
		harness.moveClockWithoutRunningTimersToRoundSecond(20.27)
		harness.keeper:receiveOutfitDraftFromDevice(PLAYER_P, harness.buildOutfitDraftMessage(3, OUTFIT_C))
		harness.keeper:receiveOutfitDraftFromDevice(PLAYER_P, harness.buildOutfitDraftMessage(4, OUTFIT_D))
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(2) -- the stale one and seq 4's
		harness.advanceToRoundSecond(20.27) -- the stale 20.25 timer runs now
		-- It neither processed seq 4 early nor scheduled a second timer for it.
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(2)
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(1)
		harness.advanceToRoundSecond(20.51)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(2)
		harness.advanceToRoundSecond(21)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20.00, 1, true),
			expectedAcknowledgement(20.27, 3, true),
			expectedAcknowledgement(20.52, 4, true),
		})
	end)
end)
