-- Builds a RoundOutfitDraftKeeper wired to fakes for the referee audit scenarios (PART 3): a
-- FakeClock and FakeScheduler, the REAL PlayerRequestRateLimiter, the REAL OutfitValidator behind
-- a counting wrapper, the fake styling item pool with a changeable available key set, a
-- recording acknowledgement sender and a recording logger. Not a spec file.
--
-- Time is "round time": T = seconds since the round's ThemeReveal began (ThemeReveal 0-10,
-- Styling 10-190). The harness starts at T = 0; `startStylingAtRoundSecond10()` moves to T = 10
-- and starts accepting drafts. Times in records are whole round milliseconds (T = 20.25 is 20250).

local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local CountingOutfitValidator = require("../Support/CountingOutfitValidator")
local RecordingLogger = require("../Support/RecordingLogger")
local RecordingRoundOutfitDraftAcknowledgementSender =
	require("../Support/RecordingRoundOutfitDraftAcknowledgementSender")
local RoundOutfitDraftTestMessages = require("../Support/RoundOutfitDraftTestMessages")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local PlayerRequestRateLimiter = require("../../src/server/PlayerRequestRateLimiter")
local RoundOutfitDraftKeeper = require("../../src/server/RoundOutfitDraftKeeper")

local RoundOutfitDraftKeeperTestHarness = {}

RoundOutfitDraftKeeperTestHarness.ROUND_START_UNIX_SECONDS = 1_763_510_400
RoundOutfitDraftKeeperTestHarness.ROUND_ID = "round-1"
RoundOutfitDraftKeeperTestHarness.NEXT_ROUND_ID = "round-2"

RoundOutfitDraftKeeperTestHarness.PLAYER_P = 8801
RoundOutfitDraftKeeperTestHarness.PLAYER_Q = 8802
RoundOutfitDraftKeeperTestHarness.PLAYER_R = 8803
RoundOutfitDraftKeeperTestHarness.PLAYER_S = 8804

-- Distinct valid fixture outfits (spec §1.5) and one invalid outfit (a top plus a dress).
RoundOutfitDraftKeeperTestHarness.OUTFIT_A = table.freeze({ "asset_9000002" })
RoundOutfitDraftKeeperTestHarness.OUTFIT_B = table.freeze({ "asset_9000003", "asset_9000012" })
RoundOutfitDraftKeeperTestHarness.OUTFIT_C = table.freeze({ "asset_9000031" })
RoundOutfitDraftKeeperTestHarness.OUTFIT_D = table.freeze({ "asset_9000013", "asset_9000022", "bundle_9000042" })
RoundOutfitDraftKeeperTestHarness.INVALID_OUTFIT_X = table.freeze({ "asset_9000011", "asset_9000032" })
RoundOutfitDraftKeeperTestHarness.WORKED_EXAMPLE_OUTFIT_E83 = FakeStylingItemPool.WORKED_EXAMPLE_STYLING_ITEM_KEYS

local ROUND_START_UNIX_MILLISECONDS = RoundOutfitDraftKeeperTestHarness.ROUND_START_UNIX_SECONDS * 1000

function RoundOutfitDraftKeeperTestHarness.convertRoundSecondsToRoundMilliseconds(roundSeconds: number): number
	return math.round(roundSeconds * 1000)
end

export type RoundOutfitDraftKeeperHarnessOptions = {
	-- The scheduler's cancel functions do nothing, so a "cancelled" timer still fires: proves the
	-- keeper's stale-timer guard on its own.
	isTimerCancellationIgnored: boolean?,
	-- Every timer runs this many milliseconds (at most half its delay) before the delay the
	-- keeper asked for (a real scheduler may run a callback slightly early).
	timerFiresEarlyByMilliseconds: number?,
}

function RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes(harnessOptions: RoundOutfitDraftKeeperHarnessOptions?)
	local chosenHarnessOptions: RoundOutfitDraftKeeperHarnessOptions = harnessOptions or {}
	local fakeClock = FakeClock.new(RoundOutfitDraftKeeperTestHarness.ROUND_START_UNIX_SECONDS)
	local fakeScheduler = FakeScheduler.new(fakeClock)
	local playerRequestRateLimiter = PlayerRequestRateLimiter.new({ clock = fakeClock })
	local countingOutfitValidator = CountingOutfitValidator.new(fakeClock)
	local recordingSender = RecordingRoundOutfitDraftAcknowledgementSender.new(fakeClock)
	local recordingLogger = RecordingLogger.new()
	local harness = {}

	local currentAvailableStylingItemKeySet = FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET
	local availableKeySetReadCount = 0

	local isTimerCancellationIgnored = chosenHarnessOptions.isTimerCancellationIgnored == true
	local timerFiresEarlyBySeconds = (chosenHarnessOptions.timerFiresEarlyByMilliseconds or 0) / 1000
	local requestedTimerDelaySeconds = {}
	local keeperScheduler = {
		scheduleCallbackAfterSeconds = function(_, delaySeconds: number, callback: () -> ())
			table.insert(requestedTimerDelaySeconds, delaySeconds)
			-- Early by at most half the delay, so a re-armed timer still makes progress.
			local earlinessSeconds = math.min(timerFiresEarlyBySeconds, math.floor(delaySeconds * 1000 / 2) / 1000)
			local cancelScheduledCallback =
				fakeScheduler:scheduleCallbackAfterSeconds(delaySeconds - earlinessSeconds, callback)
			if isTimerCancellationIgnored then
				return function() end
			end
			return cancelScheduledCallback
		end,
	}
	harness.requestedTimerDelaySeconds = requestedTimerDelaySeconds

	function harness.buildKeeperDependencies(roundId: string)
		return {
			roundId = roundId,
			clock = fakeClock,
			scheduler = keeperScheduler,
			playerRequestRateLimiter = playerRequestRateLimiter,
			readAvailableStylingItemKeySet = function()
				availableKeySetReadCount += 1
				return currentAvailableStylingItemKeySet
			end,
			stylingItemByStylingItemKey = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
			sendRoundOutfitDraftAcknowledged = recordingSender.sendRoundOutfitDraftAcknowledged,
			logger = recordingLogger,
			validateOutfit = countingOutfitValidator.validateOutfit,
		}
	end

	-- A keeper for another round sharing every fake (clock, scheduler, limiter, sender, ...).
	function harness.createKeeperForRound(roundId: string)
		return RoundOutfitDraftKeeper.new(harness.buildKeeperDependencies(roundId))
	end

	harness.keeper = harness.createKeeperForRound(RoundOutfitDraftKeeperTestHarness.ROUND_ID)
	harness.fakeClock = fakeClock
	harness.fakeScheduler = fakeScheduler
	harness.playerRequestRateLimiter = playerRequestRateLimiter
	harness.countingOutfitValidator = countingOutfitValidator
	harness.recordingSender = recordingSender
	harness.loggedWarnings = recordingLogger.loggedWarnings
	harness.loggedInformation = recordingLogger.loggedInformation

	function harness.readCurrentRoundMilliseconds(): number
		return fakeClock:getCurrentUnixMilliseconds() - ROUND_START_UNIX_MILLISECONDS
	end

	-- Moves time forward (through the scheduler, running due timers) to round second T.
	function harness.advanceToRoundSecond(roundSeconds: number)
		local targetRoundMilliseconds =
			RoundOutfitDraftKeeperTestHarness.convertRoundSecondsToRoundMilliseconds(roundSeconds)
		local elapsedMilliseconds = targetRoundMilliseconds - harness.readCurrentRoundMilliseconds()
		assert(elapsedMilliseconds >= 0, "advanceToRoundSecond cannot move time backwards")
		fakeScheduler:advanceTimeAndRunDueCallbacks(elapsedMilliseconds / 1000)
	end

	-- Moves the clock WITHOUT running any due timer (they become overdue).
	function harness.moveClockWithoutRunningTimersToRoundSecond(roundSeconds: number)
		fakeClock:moveForwardToUnixMilliseconds(
			ROUND_START_UNIX_MILLISECONDS
				+ RoundOutfitDraftKeeperTestHarness.convertRoundSecondsToRoundMilliseconds(roundSeconds)
		)
	end

	function harness.addParticipants(playerUserIds: { number })
		for _, playerUserId in playerUserIds do
			harness.keeper:addParticipant(playerUserId)
		end
	end

	-- The usual start: the players join at T = 3, then Styling starts at T = 10.
	function harness.joinAtRoundSecond3AndStartStyling(playerUserIds: { number })
		harness.advanceToRoundSecond(3)
		harness.addParticipants(playerUserIds)
		harness.startStylingAtRoundSecond10()
	end

	function harness.startStylingAtRoundSecond10()
		harness.advanceToRoundSecond(10)
		harness.keeper:startAcceptingOutfitDrafts()
	end

	-- A well-formed SetRoundOutfitDraft message with a fresh copy of the outfit list.
	function harness.buildOutfitDraftMessage(outfitDraftSequenceNumber: any, outfitStylingItemKeys: any, roundId: any?)
		return RoundOutfitDraftTestMessages.buildOutfitDraftMessage(
			if roundId == nil then RoundOutfitDraftKeeperTestHarness.ROUND_ID else roundId,
			outfitDraftSequenceNumber,
			outfitStylingItemKeys
		)
	end

	-- Moves to round second T (running due timers first), then delivers the draft.
	function harness.sendDraftAtRoundSecond(
		roundSeconds: number,
		playerUserId: number,
		outfitDraftSequenceNumber: any,
		outfitStylingItemKeys: any
	)
		harness.advanceToRoundSecond(roundSeconds)
		harness.keeper:receiveOutfitDraftFromDevice(
			playerUserId,
			harness.buildOutfitDraftMessage(outfitDraftSequenceNumber, outfitStylingItemKeys)
		)
	end

	-- { { roundMilliseconds, outfitDraftSequenceNumber, isKept, rejectionReason } } for a player.
	function harness.listAcknowledgementsSentTo(playerUserId: number)
		return RoundOutfitDraftTestMessages.summarizeAcknowledgementsSentTo(
			recordingSender,
			playerUserId,
			ROUND_START_UNIX_MILLISECONDS
		)
	end

	function harness.setAvailableStylingItemKeySet(availableStylingItemKeySet: { [string]: boolean })
		currentAvailableStylingItemKeySet = availableStylingItemKeySet
	end

	-- Hides one more key from now on (as if it left the available set during Styling).
	function harness.hideStylingItemKeyFromNowOn(hiddenStylingItemKey: string)
		currentAvailableStylingItemKeySet = RoundOutfitDraftTestMessages.copyAvailableStylingItemKeySetWithout(
			currentAvailableStylingItemKeySet,
			hiddenStylingItemKey
		)
	end

	function harness.countAvailableKeySetReads(): number
		return availableKeySetReadCount
	end

	return harness
end

-- A summary row as listAcknowledgementsSentTo returns it, for the ROUND_ID round.
function RoundOutfitDraftKeeperTestHarness.expectedAcknowledgement(
	roundSeconds: number,
	outfitDraftSequenceNumber: number,
	isKept: boolean
)
	return RoundOutfitDraftTestMessages.buildExpectedAcknowledgementSummary(
		roundSeconds,
		RoundOutfitDraftKeeperTestHarness.ROUND_ID,
		outfitDraftSequenceNumber,
		isKept
	)
end

return table.freeze(RoundOutfitDraftKeeperTestHarness)
