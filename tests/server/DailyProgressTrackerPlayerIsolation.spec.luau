-- Daily claims are judged per player (development spec §2.9, §2.13 "rate limit per player and
-- channel", §5.1): each player has their own rate-limit budget and their own counted playtime, and
-- a refusal from the limiter is answered with exactly the limiter's reason, before the tracker
-- touches the keeper, the ledger, the clock or the untrusted value.

local DailyProgressTracker = require("../../src/server/DailyProgressTracker")
local DailyProgressTrackerTestHarness = require("./DailyProgressTrackerTestHarness")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = DailyProgressTrackerTestHarness.PLAYER
local OTHER_PLAYER = DailyProgressTrackerTestHarness.OTHER_PLAYER
local PINK_HAIR_KEY = DailyProgressTrackerTestHarness.PINK_HAIR_KEY

-- A stand-in whose every field access is counted (and whose methods raise if called).
local function createAccessCountingStandIn(accessCounter)
	return setmetatable({}, {
		__index = function(_, fieldName)
			accessCounter.accessCount += 1
			return function()
				error("touched " .. tostring(fieldName))
			end
		end,
	})
end

-- An untrusted value on which every metamethod counts as a touch.
local function createTouchCountingUntrustedValue(accessCounter)
	local function countTouch()
		accessCounter.accessCount += 1
		return nil
	end
	local touchCountingMetatable = {}
	for _, metamethodName in
		{ "__index", "__newindex", "__call", "__concat", "__unm", "__add", "__sub", "__mul", "__div", "__idiv" }
	do
		touchCountingMetatable[metamethodName] = countTouch
	end
	for _, metamethodName in { "__mod", "__pow", "__eq", "__lt", "__le", "__len", "__iter" } do
		touchCountingMetatable[metamethodName] = countTouch
	end
	touchCountingMetatable.__tostring = function()
		accessCounter.accessCount += 1
		return "touched"
	end
	return setmetatable({}, touchCountingMetatable)
end

describe("Daily claims of two players", function()
	it(
		"each player has their own rate-limit budget: two players claiming in the same instant are both judged",
		function()
			local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
			harness.loadPlayer(PLAYER)
			harness.loadPlayer(OTHER_PLAYER)
			harness.advanceSeconds(300)
			expect(harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 5).isAccepted).toBeTrue()
			expect(harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(OTHER_PLAYER, 5).isAccepted).toBeTrue()
			harness.grantRoundReward(PLAYER, "round-1", 2, { PINK_HAIR_KEY })
			harness.grantRoundReward(OTHER_PLAYER, "round-1", 2, { PINK_HAIR_KEY })
			harness.advanceSeconds(1)
			expect(harness.dailyProgressTracker:answerClaimDailyQuestRewardRequest(OTHER_PLAYER, "quest_e").isAccepted).toBeTrue()
			expect(harness.dailyProgressTracker:answerClaimDailyQuestRewardRequest(PLAYER, "quest_e").isAccepted).toBeTrue()
		end
	)

	it("judges each player's milestone claim on that player's own uncounted playtime", function()
		for _, playerOrder in { { PLAYER, OTHER_PLAYER }, { OTHER_PLAYER, PLAYER } } do
			local longerPlayingPlayer, shorterPlayingPlayer = playerOrder[1], playerOrder[2]
			local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ admitsEveryRequest = true })
			harness.loadPlayer(longerPlayingPlayer)
			harness.fakeClock:advanceBySeconds(250)
			harness.loadPlayer(shorterPlayingPlayer)
			-- Without running scheduled work: neither player's playtime is recorded yet.
			harness.fakeClock:advanceBySeconds(50)
			expect(harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(shorterPlayingPlayer, 5)).toEqual({
				isAccepted = false,
				rejectionReason = "MilestoneNotReached",
			})
			expect(harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(longerPlayingPlayer, 5).isAccepted).toBeTrue()
		end
	end)
end)

describe("A refusal from the rate limiter", function()
	it("is answered with exactly the limiter's reason, touching nothing else", function()
		local accessCounter = { accessCount = 0 }
		local refusingRateLimiter = { askedRequests = {} }
		function refusingRateLimiter.admitOrRefusePlayerRequest(self, playerUserId: number, remoteChannelName: string)
			table.insert(self.askedRequests, { playerUserId = playerUserId, remoteChannelName = remoteChannelName })
			return { isRequestAllowed = false, rejectionReason = "DistinctiveLimiterReason" }
		end
		local dailyProgressTracker = DailyProgressTracker.new({
			playerSaveDataKeeper = createAccessCountingStandIn(accessCounter),
			rewardLedger = createAccessCountingStandIn(accessCounter),
			playerRequestRateLimiter = refusingRateLimiter,
			clock = createAccessCountingStandIn(accessCounter),
			scheduler = createAccessCountingStandIn(accessCounter),
			logger = createAccessCountingStandIn(accessCounter),
			dailyQuestCatalogEntries = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS,
		})
		expect(accessCounter.accessCount).toBe(0)
		local untrustedValue = createTouchCountingUntrustedValue(accessCounter)

		expect(dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(OTHER_PLAYER, untrustedValue)).toEqual({
			isAccepted = false,
			rejectionReason = "DistinctiveLimiterReason",
		})
		expect(dailyProgressTracker:answerClaimDailyQuestRewardRequest(OTHER_PLAYER, untrustedValue)).toEqual({
			isAccepted = false,
			rejectionReason = "DistinctiveLimiterReason",
		})
		expect(accessCounter.accessCount).toBe(0)
		expect(refusingRateLimiter.askedRequests).toEqual({
			{ playerUserId = OTHER_PLAYER, remoteChannelName = "RequestClaimPlaytimeMilestone" },
			{ playerUserId = OTHER_PLAYER, remoteChannelName = "RequestClaimDailyQuestReward" },
		})
	end)
end)
