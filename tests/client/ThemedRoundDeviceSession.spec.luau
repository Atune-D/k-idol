-- ThemedRoundDeviceSession with hand-made server messages on a fake clock: joining and its
-- refusals, participation per round, the wardrobe lock one second before Styling ends, put-back on
-- a rejected draft, results per round, and nothing leaking into the next round.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local DeviceTestFixtures = require("./DeviceTestFixtures")
local ThemedRoundDeviceSession = require("../../src/client/ThemedRoundDeviceSession")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local F = DeviceTestFixtures
local LOCAL_USER_ID = 101
local START_MS = 1_800_000_000_000

local function createSessionUnderTest()
	local fakeClock = FakeClock.new(START_MS / 1000)
	local fakeScheduler = FakeScheduler.new(fakeClock)
	local fixture = { fakeClock = fakeClock, sentDrafts = {}, joinCallbacks = {}, changeCount = 0 }
	fixture.session = ThemedRoundDeviceSession.new({
		localPlayerUserId = LOCAL_USER_ID,
		clock = fakeClock,
		scheduler = fakeScheduler,
		stylingItemByStylingItemKey = F.STYLING_ITEM_BY_STYLING_ITEM_KEY,
		sendOutfitDraftToServer = function(message)
			table.insert(fixture.sentDrafts, message)
		end,
		requestJoinCurrentRound = function(onAnswer)
			table.insert(fixture.joinCallbacks, onAnswer)
		end,
		onSessionChanged = function()
			fixture.changeCount += 1
		end,
	})
	fixture.session:applyWardrobeCatalogView(F.buildDevelopmentWardrobeCatalogView())
	function fixture.advance(seconds)
		fakeScheduler:advanceTimeAndRunDueCallbacks(seconds)
	end
	function fixture.sendRoundState(roundId, roundPhase, secondsUntilEnd, participantUserIds)
		fixture.session:receiveRoundStateChanged({
			roundId = roundId,
			roundPhase = roundPhase,
			phaseEndsAtUnixMilliseconds = fakeClock:getCurrentUnixMilliseconds() + secondsUntilEnd * 1000,
			themeId = "y2k_pop",
			roundBonusRule = { roundBonusKind = "ColorBonus", bonusColorTag = "pink" },
			participantUserIds = participantUserIds or {},
		})
	end
	function fixture.answerJoin(answer)
		local onAnswer = table.remove(fixture.joinCallbacks, 1)
		onAnswer(answer)
	end
	function fixture.acknowledgeLatest(roundId, isKept, rejectionReason)
		local latest = fixture.sentDrafts[#fixture.sentDrafts]
		fixture.session:receiveRoundOutfitDraftAcknowledged({
			roundId = roundId,
			outfitDraftSequenceNumber = latest.outfitDraftSequenceNumber,
			isKept = isKept,
			rejectionReason = rejectionReason,
		})
	end
	function fixture.snapshot()
		return fixture.session:readSessionSnapshot()
	end
	return fixture
end

describe("ThemedRoundDeviceSession joining", function()
	it("asks once, ignores a second ask while in flight, and becomes a participant when accepted", function()
		local fixture = createSessionUnderTest()
		fixture.sendRoundState("r1", "Styling", 150)
		expect(fixture.session:askToJoinCurrentRound()).toBeTrue()
		expect(fixture.session:askToJoinCurrentRound()).toBeFalse()
		expect(#fixture.joinCallbacks).toBe(1)
		expect(fixture.snapshot().isJoinRequestInFlight).toBeTrue()
		fixture.answerJoin({ isAccepted = true })
		expect(fixture.snapshot().isParticipant).toBeTrue()
		expect(fixture.session:askToJoinCurrentRound()).toBeFalse()
	end)

	it("keeps a refusal for this round and lets the player ask again", function()
		local fixture = createSessionUnderTest()
		fixture.sendRoundState("r1", "Styling", 30)
		fixture.session:askToJoinCurrentRound()
		fixture.answerJoin({ isAccepted = false, rejectionReason = "RoundNotJoinableNow" })
		local snapshot = fixture.snapshot()
		expect(snapshot.isParticipant).toBeFalse()
		expect(snapshot.joinRejection).toEqual({ roundId = "r1", rejectionReason = "RoundNotJoinableNow" })
		expect(snapshot.canAskToJoinNow).toBeTrue()
	end)

	it("treats AlreadyParticipating as participation (an earlier answer may have been lost)", function()
		local fixture = createSessionUnderTest()
		fixture.sendRoundState("r1", "ThemeReveal", 8)
		fixture.session:askToJoinCurrentRound()
		fixture.answerJoin({ isAccepted = false, rejectionReason = "AlreadyParticipating" })
		expect(fixture.snapshot().isParticipant).toBeTrue()
		expect(fixture.snapshot().joinRejection.rejectionReason).toBe("AlreadyParticipating")
	end)

	it("treats a missing answer as a refusal without a reason", function()
		local fixture = createSessionUnderTest()
		fixture.sendRoundState("r1", "ThemeReveal", 8)
		fixture.session:askToJoinCurrentRound()
		fixture.answerJoin(nil)
		expect(fixture.snapshot().isParticipant).toBeFalse()
		expect(fixture.snapshot().joinRejection).toEqual({ roundId = "r1" })
	end)

	it("ignores an answer that arrives after the round changed", function()
		local fixture = createSessionUnderTest()
		fixture.sendRoundState("r1", "Styling", 61)
		fixture.session:askToJoinCurrentRound()
		fixture.sendRoundState("r2", "ThemeReveal", 10)
		fixture.answerJoin({ isAccepted = true })
		expect(fixture.snapshot().isParticipant).toBeFalse()
	end)

	it("cannot ask during Showcase, Results or Intermission, or before any round state", function()
		local fixture = createSessionUnderTest()
		expect(fixture.session:askToJoinCurrentRound()).toBeFalse()
		for _, roundPhase in { "Showcase", "Results", "Intermission" } do
			fixture.sendRoundState("r1", roundPhase, 10)
			expect(fixture.session:askToJoinCurrentRound()).toBeFalse()
		end
		expect(#fixture.joinCallbacks).toBe(0)
	end)

	it("counts a participantUserIds list naming the local player as participation", function()
		local fixture = createSessionUnderTest()
		fixture.sendRoundState("r1", "Showcase", 60, { 7, LOCAL_USER_ID })
		expect(fixture.snapshot().isParticipant).toBeTrue()
	end)
end)

describe("ThemedRoundDeviceSession wardrobe", function()
	local function joinedDuringStyling(secondsUntilEnd)
		local fixture = createSessionUnderTest()
		fixture.sendRoundState("r1", "Styling", secondsUntilEnd)
		fixture.session:askToJoinCurrentRound()
		fixture.answerJoin({ isAccepted = true })
		return fixture
	end

	it("is not usable for a non-participant or outside Styling", function()
		local fixture = createSessionUnderTest()
		fixture.sendRoundState("r1", "Styling", 100)
		expect(fixture.session:tapWardrobeItem(F.HAIR)).toBeNil()
		local joined = createSessionUnderTest()
		joined.sendRoundState("r1", "ThemeReveal", 10)
		joined.session:askToJoinCurrentRound()
		joined.answerJoin({ isAccepted = true })
		expect(joined.session:tapWardrobeItem(F.HAIR)).toBeNil()
		joined.advance(10)
		joined.sendRoundState("r1", "Styling", 180)
		expect(joined.session:tapWardrobeItem(F.HAIR).isSelectionChanged).toBeTrue()
		expect(joined.sentDrafts[1]).toEqual({
			roundId = "r1",
			outfitDraftSequenceNumber = 1,
			outfitStylingItemKeys = { F.HAIR },
		})
	end)

	it("locks one second before Styling ends: a tap at 1.001 s left works, at exactly 1 s it does not", function()
		local fixture = joinedDuringStyling(100)
		fixture.advance(100 - 1.001)
		expect(fixture.session:isWardrobeUsableNow()).toBeTrue()
		expect(fixture.session:tapWardrobeItem(F.HAIR).isSelectionChanged).toBeTrue()
		fixture.advance(0.001)
		expect(fixture.session:isWardrobeUsableNow()).toBeFalse()
		expect(fixture.session:tapWardrobeItem(F.GLASSES)).toBeNil()
		expect(fixture.snapshot().selectedStylingItemKeys).toEqual({ F.HAIR })
	end)

	it("still sends a change made just before the lock when its interval ends", function()
		local fixture = joinedDuringStyling(100)
		fixture.session:tapWardrobeItem(F.HAIR)
		fixture.advance(100 - 1.2)
		fixture.session:tapWardrobeItem(F.GLASSES) -- sent at once (interval long over)
		fixture.advance(0.1)
		fixture.session:tapWardrobeItem(F.DRESS) -- 1.1 s left: waits for the interval
		fixture.advance(0.2) -- 0.9 s left: locked now
		expect(fixture.session:isWardrobeUsableNow()).toBeFalse()
		fixture.advance(0.2)
		local lastSent = fixture.sentDrafts[#fixture.sentDrafts]
		expect(lastSent.outfitStylingItemKeys).toEqual({ F.HAIR, F.GLASSES, F.DRESS })
	end)

	it("puts the selection back to the last kept draft and keeps a notice when the server rejects a draft", function()
		local fixture = joinedDuringStyling(150)
		fixture.session:tapWardrobeItem(F.HAIR)
		fixture.acknowledgeLatest("r1", true)
		expect(fixture.snapshot().draftSavingStatus).toBe("Saved")
		fixture.advance(1)
		fixture.session:tapWardrobeItem(F.DRESS)
		fixture.acknowledgeLatest("r1", false, "OutfitInvalid")
		local snapshot = fixture.snapshot()
		expect(snapshot.selectedStylingItemKeys).toEqual({ F.HAIR })
		expect(snapshot.outfitPutBackNotice).toEqual({ roundId = "r1", rejectionReason = "OutfitInvalid" })
		expect(snapshot.draftSavingStatus).toBe("PutBackToLastSaved")
		fixture.advance(1)
		fixture.session:tapWardrobeItem(F.GLASSES)
		expect(fixture.snapshot().outfitPutBackNotice).toBeNil()
	end)

	it("keeps the reason a tap was refused until the next accepted tap", function()
		local fixture = joinedDuringStyling(150)
		fixture.session:applyWardrobeCatalogView(
			require("../../src/client/WardrobeCatalogView").buildWardrobeCatalogView(
				F.buildSnapshotAnswerWithItems({ F.HAIR }),
				F.STYLING_ITEM_BY_STYLING_ITEM_KEY
			)
		)
		fixture.session:tapWardrobeItem(F.DRESS)
		expect(fixture.snapshot().selectionRefusal).toEqual({ selectionRefusalReason = "NotInWardrobe" })
		fixture.session:tapWardrobeItem(F.HAIR)
		expect(fixture.snapshot().selectionRefusal).toBeNil()
	end)

	it("drops selected items a new catalog no longer lists and sends the result", function()
		local fixture = joinedDuringStyling(150)
		fixture.session:tapWardrobeItem(F.HAIR)
		fixture.advance(1)
		fixture.session:tapWardrobeItem(F.GLASSES)
		fixture.advance(1)
		fixture.session:applyWardrobeCatalogView(
			require("../../src/client/WardrobeCatalogView").buildWardrobeCatalogView(
				F.buildSnapshotAnswerWithItems({ F.GLASSES }),
				F.STYLING_ITEM_BY_STYLING_ITEM_KEY
			)
		)
		expect(fixture.snapshot().selectedStylingItemKeys).toEqual({ F.GLASSES })
		expect(fixture.sentDrafts[#fixture.sentDrafts].outfitStylingItemKeys).toEqual({ F.GLASSES })
	end)

	it("stops resending when Styling ends", function()
		local fixture = joinedDuringStyling(10)
		fixture.session:tapWardrobeItem(F.HAIR)
		fixture.advance(10)
		fixture.sendRoundState("r1", "Showcase", 60, { LOCAL_USER_ID })
		local sentCount = #fixture.sentDrafts
		fixture.advance(5)
		expect(#fixture.sentDrafts).toBe(sentCount)
		expect(fixture.snapshot().selectedStylingItemKeys).toEqual({ F.HAIR })
	end)
end)

describe("ThemedRoundDeviceSession rounds and results", function()
	it("keeps results only for the held round, even when they arrive before the Results phase message", function()
		local fixture = createSessionUnderTest()
		fixture.sendRoundState("r1", "Showcase", 60)
		fixture.session:receiveRoundResultsPublished({ roundId = "r0", roundResults = {} })
		expect(fixture.snapshot().roundResults).toBeNil()
		fixture.session:receiveRoundResultsPublished({ roundId = "r1", roundResults = {} })
		expect(fixture.snapshot().roundResults).toEqual({ roundId = "r1", roundResults = {} })
		fixture.sendRoundState("r1", "Results", 20)
		expect(fixture.snapshot().roundResults).toEqual({ roundId = "r1", roundResults = {} })
	end)

	it("forgets participation, selection, refusals, notices and results at a new round; numbering restarts", function()
		local fixture = createSessionUnderTest()
		fixture.sendRoundState("r1", "Styling", 150)
		fixture.session:askToJoinCurrentRound()
		fixture.answerJoin({ isAccepted = true })
		fixture.session:tapWardrobeItem(F.HAIR)
		fixture.advance(1)
		fixture.session:tapWardrobeItem(F.GLASSES)
		fixture.acknowledgeLatest("r1", false, "OutfitInvalid")
		fixture.session:receiveRoundResultsPublished({ roundId = "r1", roundResults = {} })
		fixture.sendRoundState("r2", "ThemeReveal", 10)
		local snapshot = fixture.snapshot()
		expect(snapshot.isParticipant).toBeFalse()
		expect(snapshot.selectedStylingItemKeys).toEqual({})
		expect(snapshot.outfitPutBackNotice).toBeNil()
		expect(snapshot.roundResults).toBeNil()
		expect(snapshot.latestSentOutfitDraftSequenceNumber).toBe(0)
		fixture.session:askToJoinCurrentRound()
		fixture.answerJoin({ isAccepted = true })
		fixture.advance(10)
		fixture.sendRoundState("r2", "Styling", 180)
		fixture.session:tapWardrobeItem(F.DRESS)
		expect(fixture.sentDrafts[#fixture.sentDrafts]).toEqual({
			roundId = "r2",
			outfitDraftSequenceNumber = 1,
			outfitStylingItemKeys = { F.DRESS },
		})
	end)

	it("ignores round state messages of the wrong shape", function()
		local fixture = createSessionUnderTest()
		fixture.session:receiveRoundStateChanged({ roundId = "r1", roundPhase = "Party" })
		expect(fixture.snapshot().roundState).toBeNil()
		expect(fixture.changeCount).toBe(1) -- only the catalog applied in the fixture
	end)
end)
