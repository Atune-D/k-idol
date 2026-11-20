-- When the device asks for the wardrobe catalog snapshot (§2.14) and the leaderboard (§1.11, §2.11):
-- never more often than the server allows (§2.13), never two at once, asked again when needed.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local DeviceTestFixtures = require("./DeviceTestFixtures")
local FanCountLeaderboardRequester = require("../../src/client/FanCountLeaderboardRequester")
local WardrobeCatalogSnapshotRequester = require("../../src/client/WardrobeCatalogSnapshotRequester")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local START_SECONDS = 1_800_000_000

local function createCatalogRequester()
	local fakeClock = FakeClock.new(START_SECONDS)
	local fakeScheduler = FakeScheduler.new(fakeClock)
	local fixture = { askTimes = {}, pendingAnswers = {}, views = {} }
	fixture.requester = WardrobeCatalogSnapshotRequester.new({
		clock = fakeClock,
		scheduler = fakeScheduler,
		stylingItemByStylingItemKey = DeviceTestFixtures.STYLING_ITEM_BY_STYLING_ITEM_KEY,
		requestWardrobeCatalogSnapshot = function(onAnswer)
			table.insert(fixture.askTimes, fakeClock:getCurrentUnixSeconds() - START_SECONDS)
			table.insert(fixture.pendingAnswers, onAnswer)
		end,
		onWardrobeCatalogViewReady = function(view)
			table.insert(fixture.views, view)
		end,
	})
	function fixture.advance(seconds)
		fakeScheduler:advanceTimeAndRunDueCallbacks(seconds)
	end
	function fixture.answer(answer)
		table.remove(fixture.pendingAnswers, 1)(answer)
	end
	return fixture
end

local NOT_READY = { isAccepted = true, isWardrobeCatalogReady = false, wardrobeCatalogVersion = 0, wardrobeItems = {} }

describe("WardrobeCatalogSnapshotRequester", function()
	it("asks at start and hands on a ready catalog; asks nothing more on its own", function()
		local fixture = createCatalogRequester()
		fixture.requester:start()
		fixture.answer(DeviceTestFixtures.readServerWardrobeCatalogSnapshotAnswer())
		expect(#fixture.views).toBe(1)
		expect(#fixture.views[1].listedStylingItemKeys).toBe(7)
		fixture.advance(60)
		expect(fixture.askTimes).toEqual({ 0 })
	end)

	it("asks again 3 s after a not-ready, refused or missing answer", function()
		local fixture = createCatalogRequester()
		fixture.requester:start()
		fixture.answer(NOT_READY)
		expect(fixture.views[1].isWardrobeCatalogReady).toBeFalse()
		fixture.advance(2.9)
		expect(#fixture.askTimes).toBe(1)
		fixture.advance(0.1)
		expect(fixture.askTimes).toEqual({ 0, 3 })
		fixture.answer({ isAccepted = false, rejectionReason = "TooManyRequests" })
		fixture.advance(3)
		fixture.answer(nil)
		fixture.advance(3)
		expect(fixture.askTimes).toEqual({ 0, 3, 6, 9 })
	end)

	it("asks again when the catalog changes, but not sooner than 2 s after the last ask", function()
		local fixture = createCatalogRequester()
		fixture.requester:start()
		fixture.answer(DeviceTestFixtures.readServerWardrobeCatalogSnapshotAnswer())
		fixture.advance(0.5)
		fixture.requester:receiveWardrobeCatalogChanged({ isWardrobeCatalogReady = true, wardrobeCatalogVersion = 2 })
		fixture.requester:receiveWardrobeCatalogChanged({ isWardrobeCatalogReady = true, wardrobeCatalogVersion = 3 })
		expect(#fixture.askTimes).toBe(1)
		fixture.advance(1.5)
		expect(fixture.askTimes).toEqual({ 0, 2 })
		fixture.answer(DeviceTestFixtures.readServerWardrobeCatalogSnapshotAnswer())
		fixture.advance(10)
		expect(#fixture.askTimes).toBe(2)
		fixture.requester:receiveWardrobeCatalogChanged({})
		expect(fixture.askTimes).toEqual({ 0, 2, 12 })
	end)

	it("never has two requests in flight; a change during one asks again after its answer", function()
		local fixture = createCatalogRequester()
		fixture.requester:start()
		fixture.advance(5)
		fixture.requester:receiveWardrobeCatalogChanged({})
		expect(#fixture.askTimes).toBe(1)
		fixture.answer(DeviceTestFixtures.readServerWardrobeCatalogSnapshotAnswer())
		expect(fixture.askTimes).toEqual({ 0, 5 })
		expect(fixture.requester:readRequestCount()).toBe(2)
	end)
end)

local function createLeaderboardRequester()
	local fakeClock = FakeClock.new(START_SECONDS)
	local fakeScheduler = FakeScheduler.new(fakeClock)
	local fixture = { askTimes = {}, pendingAnswers = {} }
	fixture.requester = FanCountLeaderboardRequester.new({
		clock = fakeClock,
		scheduler = fakeScheduler,
		localPlayerUserId = 101,
		requestFanCountLeaderboardTopEntries = function(onAnswer)
			table.insert(fixture.askTimes, fakeClock:getCurrentUnixSeconds() - START_SECONDS)
			table.insert(fixture.pendingAnswers, onAnswer)
		end,
	})
	function fixture.advance(seconds)
		fakeScheduler:advanceTimeAndRunDueCallbacks(seconds)
	end
	function fixture.answer(answer)
		table.remove(fixture.pendingAnswers, 1)(answer)
	end
	return fixture
end

local function leaderboardAnswer(entries)
	return { isAccepted = true, leaderboardEntries = entries, refreshedAtUnixSeconds = START_SECONDS }
end

describe("FanCountLeaderboardRequester", function()
	it("never asks more often than once per 5 s; taps inside the interval are sent at its end, once", function()
		local fixture = createLeaderboardRequester()
		fixture.requester:askForTopEntries()
		fixture.answer(leaderboardAnswer({}))
		fixture.advance(1)
		fixture.requester:askForTopEntries()
		fixture.requester:askForTopEntries()
		fixture.advance(3.9)
		expect(fixture.askTimes).toEqual({ 0 })
		fixture.advance(0.1)
		expect(fixture.askTimes).toEqual({ 0, 5 })
		fixture.answer(leaderboardAnswer({}))
		fixture.advance(30)
		expect(#fixture.askTimes).toBe(2)
	end)

	it(
		"does not ask while a request is in flight; a tap meanwhile is honoured after the answer and the interval",
		function()
			local fixture = createLeaderboardRequester()
			fixture.requester:askForTopEntries()
			fixture.advance(7)
			fixture.requester:askForTopEntries()
			expect(#fixture.askTimes).toBe(1)
			fixture.answer(leaderboardAnswer({}))
			expect(fixture.askTimes).toEqual({ 0, 7 })
		end
	)

	it("shows the server's rows in order, the player's rank, or 'outside the top 100'", function()
		local fixture = createLeaderboardRequester()
		fixture.requester:askForTopEntries()
		fixture.answer(leaderboardAnswer({
			{ leaderboardRank = 1, playerUserId = 7, playerDisplayName = "Seven", fanCount = 2400 },
			{ leaderboardRank = 2, playerUserId = 101, playerDisplayName = "Me", fanCount = 20 },
		}))
		local panel = fixture.requester:readLeaderboardPanelModel()
		expect(panel.rows).toEqual({
			{ rankText = "#1", playerNameText = "Seven", fanCountText = "2,400 fans", isLocalPlayer = false },
			{ rankText = "#2", playerNameText = "Me", fanCountText = "20 fans", isLocalPlayer = true },
		})
		expect(panel.localPlayerRankText).toBe("You are #2.")
		fixture.advance(5)
		fixture.requester:askForTopEntries()
		fixture.answer(leaderboardAnswer({
			{ leaderboardRank = 1, playerUserId = 7, playerDisplayName = "Seven", fanCount = 2400 },
		}))
		expect(fixture.requester:readLeaderboardPanelModel().localPlayerRankText).toBe("You are outside the top 100.")
	end)

	it("shows at most 100 rows, keeps old rows on a failed answer and says so", function()
		local fixture = createLeaderboardRequester()
		local entries = {}
		for rank = 1, 120 do
			table.insert(
				entries,
				{ leaderboardRank = rank, playerUserId = rank, playerDisplayName = "P" .. rank, fanCount = 1000 - rank }
			)
		end
		fixture.requester:askForTopEntries()
		fixture.answer(leaderboardAnswer(entries))
		expect(#fixture.requester:readLeaderboardPanelModel().rows).toBe(100)
		fixture.advance(5)
		fixture.requester:askForTopEntries()
		fixture.answer({ isAccepted = false, rejectionReason = "TooManyRequests" })
		local panel = fixture.requester:readLeaderboardPanelModel()
		expect(#panel.rows).toBe(100)
		expect(panel.statusText).toBe("The leaderboard could not be loaded. Try again soon.")
	end)
end)
