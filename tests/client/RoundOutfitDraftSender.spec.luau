-- Spec §2.3 "What the device does", on a fake clock: send interval, coalescing, resend with the same
-- number, saved only on the latest kept acknowledgement, put back on rejection, late and repeated
-- acknowledgements, acknowledgements for another round, numbering per round, and end of sending.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local RoundOutfitDraftSender = require("../../src/client/RoundOutfitDraftSender")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local STATUSES = RoundOutfitDraftSender.DRAFT_SAVING_STATUSES

local function createSenderUnderTest()
	local fakeClock = FakeClock.new(1_800_000_000)
	local fakeScheduler = FakeScheduler.new(fakeClock)
	local fixture = { fakeScheduler = fakeScheduler, sentDrafts = {}, putBacks = {}, statusChanges = {} }
	fixture.sender = RoundOutfitDraftSender.new({
		clock = fakeClock,
		scheduler = fakeScheduler,
		sendOutfitDraftToServer = function(message)
			table.insert(fixture.sentDrafts, {
				atMilliseconds = fakeClock:getCurrentUnixMilliseconds() - 1_800_000_000_000,
				message = message,
			})
		end,
		onSelectionPutBack = function(keys, rejectionReason)
			table.insert(fixture.putBacks, { keys = keys, rejectionReason = rejectionReason })
		end,
		onDraftSavingStatusChanged = function(status)
			table.insert(fixture.statusChanges, status)
		end,
	})
	function fixture.advance(seconds: number)
		fakeScheduler:advanceTimeAndRunDueCallbacks(seconds)
	end
	function fixture.acknowledge(roundId: string, number: number, isKept: boolean, rejectionReason: string?)
		fixture.sender:receiveOutfitDraftAcknowledgement({
			roundId = roundId,
			outfitDraftSequenceNumber = number,
			isKept = isKept,
			rejectionReason = rejectionReason,
		})
	end
	function fixture.sentNumbers()
		local numbers = {}
		for _, sent in fixture.sentDrafts do
			table.insert(numbers, sent.message.outfitDraftSequenceNumber)
		end
		return numbers
	end
	return fixture
end

describe("RoundOutfitDraftSender sending", function()
	it("sends the first change at once, numbered 1, with the round id and a copy of the keys", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		local keys = { "asset_1" }
		fixture.sender:submitCurrentOutfit(keys)
		table.insert(keys, "asset_2")
		expect(#fixture.sentDrafts).toBe(1)
		expect(fixture.sentDrafts[1].message).toEqual({
			roundId = "round-a",
			outfitDraftSequenceNumber = 1,
			outfitStylingItemKeys = { "asset_1" },
		})
		expect(fixture.sender:readDraftSavingStatus()).toBe(STATUSES.Saving)
	end)

	it("sends a change inside the 0.5 s interval when the interval ends, as one draft of the latest outfit", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_1" })
		fixture.advance(0.1)
		fixture.sender:submitCurrentOutfit({ "asset_1", "asset_2" })
		fixture.advance(0.1)
		fixture.sender:submitCurrentOutfit({ "asset_1", "asset_3" })
		fixture.advance(0.29)
		expect(#fixture.sentDrafts).toBe(1)
		fixture.advance(0.01)
		expect(#fixture.sentDrafts).toBe(2)
		expect(fixture.sentDrafts[2].atMilliseconds).toBe(500)
		expect(fixture.sentDrafts[2].message.outfitDraftSequenceNumber).toBe(2)
		expect(fixture.sentDrafts[2].message.outfitStylingItemKeys).toEqual({ "asset_1", "asset_3" })
	end)

	it("sends a change at once when the interval has already passed", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_1" })
		fixture.acknowledge("round-a", 1, true)
		fixture.advance(0.7)
		fixture.sender:submitCurrentOutfit({ "asset_2" })
		expect(fixture.sentNumbers()).toEqual({ 1, 2 })
		expect(fixture.sentDrafts[2].atMilliseconds).toBe(700)
	end)

	it("never sends two drafts less than 0.5 s apart over many fast changes", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		for changeNumber = 1, 40 do
			fixture.sender:submitCurrentOutfit({ "asset_" .. changeNumber })
			fixture.advance(0.07)
		end
		fixture.advance(1)
		for position = 2, #fixture.sentDrafts do
			local gap = fixture.sentDrafts[position].atMilliseconds - fixture.sentDrafts[position - 1].atMilliseconds
			expect(gap >= 500).toBeTrue()
		end
		local lastNewDraft = fixture.sentDrafts[#fixture.sentDrafts].message
		expect(lastNewDraft.outfitStylingItemKeys).toEqual({ "asset_40" })
	end)

	it("ignores changes before participation begins and after it ends", function()
		local fixture = createSenderUnderTest()
		fixture.sender:submitCurrentOutfit({ "asset_1" })
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:endRoundParticipation()
		fixture.sender:submitCurrentOutfit({ "asset_1" })
		fixture.advance(3)
		expect(#fixture.sentDrafts).toBe(0)
	end)
end)

describe("RoundOutfitDraftSender resending", function()
	it("resends the latest draft with the SAME number every second until it is acknowledged", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_1" })
		fixture.advance(0.99)
		expect(#fixture.sentDrafts).toBe(1)
		fixture.advance(0.01)
		expect(fixture.sentNumbers()).toEqual({ 1, 1 })
		expect(fixture.sentDrafts[2].atMilliseconds).toBe(1000)
		fixture.advance(1)
		expect(fixture.sentNumbers()).toEqual({ 1, 1, 1 })
		fixture.acknowledge("round-a", 1, true)
		fixture.advance(5)
		expect(#fixture.sentDrafts).toBe(3)
	end)

	it("resends only the latest draft, not an older unacknowledged one", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_1" })
		fixture.advance(0.2)
		fixture.sender:submitCurrentOutfit({ "asset_2" })
		fixture.advance(0.3) -- draft 2 sent at 0.5 s
		fixture.advance(1) -- 1.5 s: draft 2 resent
		expect(fixture.sentNumbers()).toEqual({ 1, 2, 2 })
		expect(fixture.sentDrafts[3].atMilliseconds).toBe(1500)
	end)

	it("stops resending when participation ends", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_1" })
		fixture.sender:endRoundParticipation()
		fixture.advance(5)
		expect(#fixture.sentDrafts).toBe(1)
	end)

	it("drops a waiting change when participation ends before its interval is over", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_1" })
		fixture.advance(0.1)
		fixture.sender:submitCurrentOutfit({ "asset_2" })
		fixture.sender:endRoundParticipation()
		fixture.advance(5)
		expect(fixture.sentNumbers()).toEqual({ 1 })
	end)
end)

describe("RoundOutfitDraftSender acknowledgements", function()
	it("shows Saved only when the latest draft is acknowledged as kept", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		expect(fixture.sender:readDraftSavingStatus()).toBe(STATUSES.NothingSentYet)
		fixture.sender:submitCurrentOutfit({ "asset_1" })
		fixture.advance(0.1)
		fixture.sender:submitCurrentOutfit({ "asset_2" })
		fixture.acknowledge("round-a", 1, true) -- older draft kept, a newer change is waiting
		expect(fixture.sender:readDraftSavingStatus()).toBe(STATUSES.Saving)
		fixture.advance(0.4) -- draft 2 sent
		expect(fixture.sender:readDraftSavingStatus()).toBe(STATUSES.Saving)
		fixture.acknowledge("round-a", 2, true)
		expect(fixture.sender:readDraftSavingStatus()).toBe(STATUSES.Saved)
		expect(fixture.sender:readLastKeptStylingItemKeys()).toEqual({ "asset_2" })
	end)

	it("keeps Saving when the latest draft is kept while a newer change waits for its interval", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_1" })
		fixture.advance(0.1)
		fixture.sender:submitCurrentOutfit({ "asset_2" })
		fixture.acknowledge("round-a", 1, true)
		expect(fixture.sender:readDraftSavingStatus()).toBe(STATUSES.Saving)
	end)

	it("puts the selection back to the last kept draft and says so when the latest draft is not kept", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_1" })
		fixture.acknowledge("round-a", 1, true)
		fixture.advance(0.6)
		fixture.sender:submitCurrentOutfit({ "asset_1", "asset_bad" })
		fixture.acknowledge("round-a", 2, false, "OutfitInvalid")
		expect(fixture.putBacks).toEqual({ { keys = { "asset_1" }, rejectionReason = "OutfitInvalid" } })
		expect(fixture.sender:readDraftSavingStatus()).toBe(STATUSES.PutBackToLastSaved)
		expect(fixture.sender:readLastKeptStylingItemKeys()).toEqual({ "asset_1" })
		fixture.advance(5)
		expect(fixture.sentNumbers()).toEqual({ 1, 2 }) -- no resend of the rejected draft
	end)

	it("puts the selection back to the empty outfit when nothing was kept yet", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_bad" })
		fixture.acknowledge("round-a", 1, false, "OutfitInvalid")
		expect(fixture.putBacks).toEqual({ { keys = {}, rejectionReason = "OutfitInvalid" } })
	end)

	it("drops a change waiting for its interval when the latest draft is rejected", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_bad" })
		fixture.advance(0.1)
		fixture.sender:submitCurrentOutfit({ "asset_bad", "asset_2" })
		fixture.acknowledge("round-a", 1, false, "OutfitInvalid")
		fixture.advance(3)
		expect(fixture.sentNumbers()).toEqual({ 1 })
	end)

	it("records an older draft acknowledged late as kept, but never goes back to an even older one", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_1" }) -- 1 at 0 s
		fixture.advance(0.5)
		fixture.sender:submitCurrentOutfit({ "asset_2" }) -- 2 at 0.5 s
		fixture.advance(0.5)
		fixture.sender:submitCurrentOutfit({ "asset_3" }) -- 3 at 1.0 s
		fixture.acknowledge("round-a", 2, true) -- late, older than the latest
		expect(fixture.sender:readDraftSavingStatus()).toBe(STATUSES.Saving)
		fixture.acknowledge("round-a", 1, true) -- even later and even older
		expect(fixture.sender:readLastKeptStylingItemKeys()).toEqual({ "asset_2" })
		fixture.acknowledge("round-a", 3, false, "OutfitInvalid")
		expect(fixture.putBacks[1].keys).toEqual({ "asset_2" })
	end)

	it("ignores an older draft's rejection: the newer draft in flight decides", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_1" })
		fixture.advance(0.5)
		fixture.sender:submitCurrentOutfit({ "asset_2" })
		fixture.acknowledge("round-a", 1, false, "OutfitInvalid")
		expect(#fixture.putBacks).toBe(0)
		expect(fixture.sender:readDraftSavingStatus()).toBe(STATUSES.Saving)
		fixture.acknowledge("round-a", 2, true)
		expect(fixture.sender:readDraftSavingStatus()).toBe(STATUSES.Saved)
	end)

	it("never records an older REJECTED draft as kept: a later put-back goes to the draft really kept", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_1" }) -- 1 at 0 s
		fixture.acknowledge("round-a", 1, true)
		fixture.advance(0.5)
		fixture.sender:submitCurrentOutfit({ "asset_bad_2" }) -- 2 at 0.5 s
		fixture.advance(0.5)
		fixture.sender:submitCurrentOutfit({ "asset_bad_3" }) -- 3 at 1.0 s
		fixture.acknowledge("round-a", 2, false, "OutfitInvalid")
		fixture.acknowledge("round-a", 3, false, "OutfitInvalid")
		expect(fixture.putBacks).toEqual({ { keys = { "asset_1" }, rejectionReason = "OutfitInvalid" } })
	end)

	it("handles the same acknowledgement arriving twice only once", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_1" })
		fixture.acknowledge("round-a", 1, true)
		fixture.advance(0.6)
		fixture.sender:submitCurrentOutfit({ "asset_bad" })
		fixture.acknowledge("round-a", 2, false, "OutfitInvalid")
		fixture.acknowledge("round-a", 2, false, "OutfitInvalid")
		expect(#fixture.putBacks).toBe(1)
		local statusChangeCount = #fixture.statusChanges
		fixture.acknowledge("round-a", 1, true)
		expect(#fixture.statusChanges).toBe(statusChangeCount)
	end)

	it("ignores acknowledgements for another round, for numbers never sent, and before participation", function()
		local fixture = createSenderUnderTest()
		fixture.acknowledge("round-a", 1, false, "OutfitInvalid")
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_1" })
		fixture.acknowledge("round-old", 1, false, "OutfitInvalid")
		fixture.acknowledge("round-a", 2, false, "OutfitInvalid")
		fixture.acknowledge("round-a", 7, true)
		expect(#fixture.putBacks).toBe(0)
		expect(fixture.sender:readDraftSavingStatus()).toBe(STATUSES.Saving)
		fixture.advance(1)
		expect(fixture.sentNumbers()).toEqual({ 1, 1 }) -- still unacknowledged, so resent
	end)
end)

describe("RoundOutfitDraftSender rounds", function()
	it("restarts numbering at 1 and forgets the kept draft for each new round", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_1" })
		fixture.acknowledge("round-a", 1, true)
		fixture.advance(0.6)
		fixture.sender:submitCurrentOutfit({ "asset_2" })
		fixture.acknowledge("round-a", 2, true)
		fixture.sender:endRoundParticipation()
		fixture.sender:beginRoundParticipation("round-b")
		expect(fixture.sender:readLastKeptStylingItemKeys()).toEqual({})
		expect(fixture.sender:readDraftSavingStatus()).toBe(STATUSES.NothingSentYet)
		fixture.sender:submitCurrentOutfit({ "asset_3" })
		local lastSent = fixture.sentDrafts[#fixture.sentDrafts].message
		expect(lastSent.roundId).toBe("round-b")
		expect(lastSent.outfitDraftSequenceNumber).toBe(1)
		fixture.acknowledge("round-a", 2, false, "OutfitInvalid") -- a stray one from the old round
		expect(#fixture.putBacks).toBe(0)
	end)

	it("forgetRound stops everything and leaves no participation", function()
		local fixture = createSenderUnderTest()
		fixture.sender:beginRoundParticipation("round-a")
		fixture.sender:submitCurrentOutfit({ "asset_1" })
		fixture.sender:forgetRound()
		expect(fixture.sender:readParticipatingRoundId()).toBeNil()
		expect(fixture.sender:readLatestSentOutfitDraftSequenceNumber()).toBe(0)
		fixture.advance(5)
		expect(#fixture.sentDrafts).toBe(1)
	end)
end)
