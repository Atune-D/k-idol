-- DailyProgressTracker claim requests (development spec §2.9, §2.13, §3.3, §3.4, §6.2 "Unit: daily
-- content"): RequestClaimPlaytimeMilestone and RequestClaimDailyQuestReward with the REAL keeper,
-- ledger and (unless stated) rate limiter: milestones cannot be claimed early or twice, quests only
-- when completed and once, rate limiting first, SaveDataNotLoaded, and the day boundary.

local DailyProgressTracker = require("../../src/server/DailyProgressTracker")
local DailyProgressTrackerTestHarness = require("./DailyProgressTrackerTestHarness")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = DailyProgressTrackerTestHarness.PLAYER
local PINK_HAIR_KEY = DailyProgressTrackerTestHarness.PINK_HAIR_KEY
local BLACK_BOTTOM_KEY = DailyProgressTrackerTestHarness.BLACK_BOTTOM_KEY
local NEXT_DAILY_DATE_KEY = "2026-11-20"

local function readStarCoinBalance(harness): number
	return harness.readInMemorySaveData(PLAYER).starCoinBalance
end

local function expectRejection(claimAnswer, expectedRejectionReason: string)
	expect(claimAnswer).toEqual({ isAccepted = false, rejectionReason = expectedRejectionReason })
end

describe("RequestClaimPlaytimeMilestone", function()
	it("refuses a milestone before playtime reaches it and pays it from the moment it does", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(298)
		local revisionBeforeEarlyClaim = harness.readInMemoryChangeRevision(PLAYER)
		expectRejection(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 5), "MilestoneNotReached")
		expect(readStarCoinBalance(harness)).toBe(0)
		expect(harness.readInMemoryChangeRevision(PLAYER)).toBe(revisionBeforeEarlyClaim)

		local claimAnswer = harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 5)
		expect(claimAnswer).toEqual({ isAccepted = true, starCoinsGranted = 20 })
		local saveData = harness.readInMemorySaveData(PLAYER)
		expect(saveData.starCoinBalance).toBe(20)
		expect(saveData.fanCount).toBe(0)
		expect(saveData.dailyProgress.claimedPlaytimeMilestoneMinutes).toEqual({ 5 })
	end)

	it("refuses a second claim of the same milestone the same day and pays nothing more", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(600)
		expect(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 10).isAccepted).toBeTrue()
		local revisionAfterClaim = harness.readInMemoryChangeRevision(PLAYER)
		expectRejection(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 10), "AlreadyClaimed")
		expect(readStarCoinBalance(harness)).toBe(30)
		expect(harness.readInMemoryChangeRevision(PLAYER)).toBe(revisionAfterClaim)
	end)

	it("pays every milestone its own amount, 430 Star Coins in all after an hour", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(3600)
		local starCoinRewardByMilestoneMinutes = { [5] = 20, [10] = 30, [20] = 50, [30] = 80, [45] = 100, [60] = 150 }
		for _, milestoneMinutes in { 60, 5, 45, 10, 30, 20 } do
			expect(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, milestoneMinutes)).toEqual({
				isAccepted = true,
				starCoinsGranted = starCoinRewardByMilestoneMinutes[milestoneMinutes],
			})
		end
		expect(readStarCoinBalance(harness)).toBe(430)
	end)

	it("judges the claim on the playtime counted so far, even before the next scheduled recording", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		-- Move the clock without running scheduled work: no recording has run since the load.
		harness.fakeClock:advanceBySeconds(300)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(0)
		expect(harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 5).isAccepted).toBeTrue()
		-- The claim recorded the counted playtime in the same change; it is not counted twice later.
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(300)
		harness.advanceSeconds(0)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(300)
		harness.advanceSeconds(60)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(360)
	end)

	it("a declined claim records no playtime and marks nothing as recorded", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.fakeClock:advanceBySeconds(200)
		expectRejection(
			harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 5),
			"MilestoneNotReached"
		)
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(0)
		harness.fakeClock:advanceBySeconds(100)
		harness.advanceSeconds(1)
		expect(harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 5).isAccepted).toBeTrue()
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(301)
	end)

	it("pays once when two claims of one milestone arrive in the same instant (rate limiter admitting both)", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ admitsEveryRequest = true })
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(300)
		local firstAnswer = harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 5)
		local secondAnswer = harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 5)
		expect(firstAnswer.isAccepted).toBeTrue()
		expectRejection(secondAnswer, "AlreadyClaimed")
		expect(readStarCoinBalance(harness)).toBe(20)
		expect(harness.readInMemoryDailyProgress(PLAYER).claimedPlaytimeMilestoneMinutes).toEqual({ 5 })
	end)

	it("requests a save at once for an accepted claim", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(300)
		local startedOperationsBeforeClaim = harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)
		expect(harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 5).isAccepted).toBeTrue()
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations(PLAYER)).toBe(startedOperationsBeforeClaim + 1)
		local storedDailyProgress = harness.readStoredSaveData(PLAYER).dailyProgress
		expect(storedDailyProgress.claimedPlaytimeMilestoneMinutes).toEqual({ 5 })
		expect(storedDailyProgress.playtimeSecondsToday).toBe(300)
	end)
end)

describe("RequestClaimDailyQuestReward", function()
	it("refuses a quest of the catalog that is not one of today's three", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		expectRejection(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_b"), "NotTodaysQuest")
	end)

	it("refuses today's quest until its progress reaches the target, then pays it once", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		expectRejection(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_a"), "QuestNotCompleted")
		harness.grantRoundReward(PLAYER, "round-1", 3, { BLACK_BOTTOM_KEY })
		harness.grantRoundReward(PLAYER, "round-2", 3, { BLACK_BOTTOM_KEY })
		expectRejection(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_a"), "QuestNotCompleted")
		harness.grantRoundReward(PLAYER, "round-3", 3, { BLACK_BOTTOM_KEY })
		local balanceBeforeClaim = readStarCoinBalance(harness)

		expect(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_a")).toEqual({
			isAccepted = true,
			starCoinsGranted = 60,
		})
		expect(readStarCoinBalance(harness)).toBe(balanceBeforeClaim + 60)
		expect(harness.readInMemoryDailyProgress(PLAYER).claimedDailyQuestIds).toEqual({ "quest_a" })

		expectRejection(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_a"), "AlreadyClaimed")
		expect(readStarCoinBalance(harness)).toBe(balanceBeforeClaim + 60)
	end)

	it("pays once when two claims of one quest arrive in the same instant (rate limiter admitting both)", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ admitsEveryRequest = true })
		harness.loadPlayer(PLAYER)
		harness.grantRoundReward(PLAYER, "round-1", 2, { PINK_HAIR_KEY })
		local balanceBeforeClaims = readStarCoinBalance(harness)
		expect(harness.dailyProgressTracker:answerClaimDailyQuestRewardRequest(PLAYER, "quest_e").isAccepted).toBeTrue()
		expectRejection(
			harness.dailyProgressTracker:answerClaimDailyQuestRewardRequest(PLAYER, "quest_e"),
			"AlreadyClaimed"
		)
		expect(readStarCoinBalance(harness)).toBe(balanceBeforeClaims + 70)
	end)
end)

describe("Daily claims and the UTC day boundary", function()
	it("loses yesterday's claims and unclaimed milestones: after midnight milestones need new playtime", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ secondsAfterMidnight = 86400 - 600 })
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(300)
		expect(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 5).isAccepted).toBeTrue()
		harness.advanceToTimeOfDay(1, 120)
		expectRejection(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 5), "MilestoneNotReached")
		expectRejection(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 10), "MilestoneNotReached")
		harness.advanceToTimeOfDay(1, 300)
		expect(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 5).isAccepted).toBeTrue()
		expect(readStarCoinBalance(harness)).toBe(40)
	end)

	it("rolls the day inside the claim itself when midnight passed before any recording ran", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ secondsAfterMidnight = 86400 - 600 })
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(300)
		expect(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 5).isAccepted).toBeTrue()
		-- Straight from 23:55:01 to 00:05:00 without running scheduled work: the save still
		-- holds yesterday.
		harness.fakeClock:advanceBySeconds(599)
		expect(harness.readInMemoryDailyProgress(PLAYER).dailyDateKey).toBe("2026-11-19")
		expect(harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 5).isAccepted).toBeTrue()
		local dailyProgress = harness.readInMemoryDailyProgress(PLAYER)
		expect(dailyProgress.dailyDateKey).toBe(NEXT_DAILY_DATE_KEY)
		expect(dailyProgress.playtimeSecondsToday).toBe(300)
		expect(dailyProgress.claimedPlaytimeMilestoneMinutes).toEqual({ 5 })
	end)

	it("loses yesterday's unclaimed quest progress even for a quest that is also today's", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ secondsAfterMidnight = 86400 - 600 })
		harness.loadPlayer(PLAYER)
		-- quest_e (pink, target 1) is a quest on both 2026-11-19 and 2026-11-20.
		harness.grantRoundReward(PLAYER, "round-1", 2, { PINK_HAIR_KEY })
		expect(harness.readInMemoryDailyProgress(PLAYER).dailyQuestProgressCountByQuestId.quest_e).toBe(1)
		harness.fakeClock:advanceBySeconds(1200)
		expectRejection(
			harness.dailyProgressTracker:answerClaimDailyQuestRewardRequest(PLAYER, "quest_e"),
			"QuestNotCompleted"
		)
		expectRejection(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_d"), "NotTodaysQuest")
		expect(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_f").rejectionReason).toBe("QuestNotCompleted")
	end)
end)

describe("Daily claims with a malformed stored dailyProgress", function()
	it("repairs it at load (once tracking has started) and logs a warning", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.storeExistingPlayerSaveData(PLAYER, function(saveData)
			saveData.dailyProgress.claimedPlaytimeMilestoneMinutes = { "five" }
			saveData.dailyProgress.playtimeSecondsToday = 400
		end)
		harness.loadPlayer(PLAYER)
		local dailyProgress = harness.readInMemoryDailyProgress(PLAYER)
		expect(dailyProgress.claimedPlaytimeMilestoneMinutes).toEqual({})
		expect(dailyProgress.playtimeSecondsToday).toBe(0)
		expect(#harness.trackerLogger.loggedWarnings).toBe(1)
		expect(string.find(harness.trackerLogger.loggedWarnings[1], "player 8801", 1, true) ~= nil).toBeTrue()
	end)

	it("pays a milestone reached in the save even for a player whose playtime is not being counted", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ isTrackingNotStarted = true })
		harness.storeExistingPlayerSaveData(PLAYER, function(saveData)
			saveData.dailyProgress.playtimeSecondsToday = 400
		end)
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(100)
		expect(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 5).isAccepted).toBeTrue()
		expect(harness.readInMemoryDailyProgress(PLAYER).playtimeSecondsToday).toBe(400)
		expectRejection(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 10), "MilestoneNotReached")
	end)

	it("never raises on it in a claim, and judges the claim on a fresh dailyProgress", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ isTrackingNotStarted = true })
		harness.storeExistingPlayerSaveData(PLAYER, function(saveData)
			saveData.dailyProgress.dailyQuestProgressCountByQuestId = { quest_e = "done" }
			saveData.dailyProgress.playtimeSecondsToday = 4000
		end)
		harness.loadPlayer(PLAYER)
		expectRejection(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_e"), "QuestNotCompleted")
		expectRejection(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 5), "MilestoneNotReached")
	end)
end)

describe("Daily claim request checks", function()
	it("asks the rate limiter first, on each request's own channel", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ admitsEveryRequest = true })
		harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 5)
		harness.dailyProgressTracker:answerClaimDailyQuestRewardRequest(PLAYER, "quest_a")
		expect(harness.playerRequestRateLimiter.admittedRequests).toEqual({
			{ playerUserId = PLAYER, remoteChannelName = "RequestClaimPlaytimeMilestone" },
			{ playerUserId = PLAYER, remoteChannelName = "RequestClaimDailyQuestReward" },
		})
	end)

	-- The stronger "looks at nothing else" check (counting every keeper, ledger and clock access
	-- and every metamethod of the value) is in DailyProgressTrackerPlayerIsolation.spec.luau.
	it("answers the real limiter's TooManyRequests for a second request in the same instant", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		local requestTouchedCount = 0
		local untrustedValueThatCountsTouches = setmetatable({}, {
			__index = function()
				requestTouchedCount += 1
				return nil
			end,
		})
		-- Not loaded: the first request is admitted and answered SaveDataNotLoaded; the second
		-- request in the same instant is refused before the save is even looked at.
		expectRejection(
			harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 5),
			"SaveDataNotLoaded"
		)
		expectRejection(
			harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, untrustedValueThatCountsTouches),
			"TooManyRequests"
		)
		expectRejection(
			harness.dailyProgressTracker:answerClaimDailyQuestRewardRequest(PLAYER, "quest_a"),
			"SaveDataNotLoaded"
		)
		expectRejection(
			harness.dailyProgressTracker:answerClaimDailyQuestRewardRequest(PLAYER, untrustedValueThatCountsTouches),
			"TooManyRequests"
		)
		expect(requestTouchedCount).toBe(0)
	end)

	it("refuses a second claim within 1 s with TooManyRequests and changes nothing; one at 1 s is judged", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(600)
		expect(harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 5).isAccepted).toBeTrue()
		local revisionAfterClaim = harness.readInMemoryChangeRevision(PLAYER)
		harness.fakeClock:advanceBySeconds(0.999)
		expectRejection(harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 10), "TooManyRequests")
		expect(harness.readInMemoryChangeRevision(PLAYER)).toBe(revisionAfterClaim)
		expect(readStarCoinBalance(harness)).toBe(20)
		harness.fakeClock:advanceBySeconds(0.001)
		expect(harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 10).isAccepted).toBeTrue()
	end)

	it("answers SaveDataNotLoaded before the save has loaded and once the player is leaving", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ isStorageHeldInFlight = true })
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		expectRejection(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 5), "SaveDataNotLoaded")
		expectRejection(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_a"), "SaveDataNotLoaded")
		-- Even an unusable value gets SaveDataNotLoaded until the save has loaded (spec §3.4).
		expectRejection(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 7), "SaveDataNotLoaded")
		expectRejection(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_b"), "SaveDataNotLoaded")
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		harness.advanceSeconds(400)
		harness.leavePlayer(PLAYER)
		expectRejection(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 5), "SaveDataNotLoaded")
		expectRejection(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_a"), "SaveDataNotLoaded")
	end)

	it("grants through the ledger with each claim's rewardSourceKind, so the ledger logs it", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.grantRoundReward(PLAYER, "round-1", 2, { PINK_HAIR_KEY })
		harness.advanceSeconds(300)
		expect(harness.claimPlaytimeMilestoneAfterOneSecond(PLAYER, 5).isAccepted).toBeTrue()
		local milestoneLogLine = harness.ledgerLogger.loggedInformation[#harness.ledgerLogger.loggedInformation]
		expect(
			string.find(milestoneLogLine, "rewardSourceKind PlaytimeMilestone: playtime milestone 5 min", 1, true)
				~= nil
		).toBeTrue()
		expect(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_e").isAccepted).toBeTrue()
		local questLogLine = harness.ledgerLogger.loggedInformation[#harness.ledgerLogger.loggedInformation]
		expect(string.find(questLogLine, "rewardSourceKind DailyQuest: daily quest quest_e", 1, true) ~= nil).toBeTrue()
	end)

	it("answers SaveDataNotLoaded when the ledger finds the save gone", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ admitsEveryRequest = true })
		harness.loadPlayer(PLAYER)
		harness.grantRoundReward(PLAYER, "round-1", 2, { PINK_HAIR_KEY })
		harness.advanceSeconds(300)
		local ledgerThatFindsNoSave = {}
		function ledgerThatFindsNoSave.grantStarCoinsAndFans()
			return { rewardLedgerOutcome = "SaveDataNotLoaded" }
		end
		local trackerOnLedgerThatFindsNoSave = DailyProgressTracker.new({
			playerSaveDataKeeper = harness.playerSaveDataKeeper,
			rewardLedger = ledgerThatFindsNoSave,
			playerRequestRateLimiter = harness.playerRequestRateLimiter,
			clock = harness.fakeClock,
			scheduler = harness.fakeScheduler,
			logger = harness.trackerLogger,
			dailyQuestCatalogEntries = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS,
		})
		expectRejection(
			trackerOnLedgerThatFindsNoSave:answerClaimPlaytimeMilestoneRequest(PLAYER, 5),
			"SaveDataNotLoaded"
		)
		expectRejection(
			trackerOnLedgerThatFindsNoSave:answerClaimDailyQuestRewardRequest(PLAYER, "quest_e"),
			"SaveDataNotLoaded"
		)
	end)

	it("builds a new, unfrozen answer table every time", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ admitsEveryRequest = true })
		harness.loadPlayer(PLAYER)
		local firstAnswer = harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 7)
		local secondAnswer = harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 7)
		expect(rawequal(firstAnswer, secondAnswer)).toBeFalse()
		expect(table.isfrozen(firstAnswer)).toBeFalse()
		firstAnswer.rejectionReason = "Changed"
		expectRejection(harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, 7), "UnknownMilestone")
		local firstQuestAnswer = harness.dailyProgressTracker:answerClaimDailyQuestRewardRequest(PLAYER, "nope")
		local secondQuestAnswer = harness.dailyProgressTracker:answerClaimDailyQuestRewardRequest(PLAYER, "nope")
		expect(rawequal(firstQuestAnswer, secondQuestAnswer)).toBeFalse()
		expect(table.isfrozen(firstQuestAnswer)).toBeFalse()
	end)
end)
