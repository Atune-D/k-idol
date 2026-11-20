-- Daily quest progress from rated rounds (development spec §1.8, §3.3 row "Round reward", §6.2
-- "quest progress counts only qualifying rounds"), through a REAL RewardLedger round reward carrying
-- the tracker's round record writer: balance, round record and quest progress arrive in one change,
-- only qualifying rounds count, and nothing a legitimate round holds can cancel the reward.
--
-- Today's test quests: quest_a (CompleteRounds, target 3), quest_d (at least 4 stars, target 2),
-- quest_e (pink, target 1).

local DailyProgressTracker = require("../../src/server/DailyProgressTracker")
local DailyProgressTrackerTestHarness = require("./DailyProgressTrackerTestHarness")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local OutfitScoreCalculator = require("../../src/shared/OutfitScoreCalculator")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = DailyProgressTrackerTestHarness.PLAYER
local PINK_HAIR_KEY = DailyProgressTrackerTestHarness.PINK_HAIR_KEY
local BLUE_TOP_KEY = DailyProgressTrackerTestHarness.BLUE_TOP_KEY
local BLACK_BOTTOM_KEY = DailyProgressTrackerTestHarness.BLACK_BOTTOM_KEY
local WHITE_SHOES_KEY = DailyProgressTrackerTestHarness.WHITE_SHOES_KEY

local function readProgressCounts(harness)
	return harness.readInMemoryDailyProgress(PLAYER).dailyQuestProgressCountByQuestId
end

local function findStarRewardTier(starCount: number)
	for _, starRewardTier in OutfitScoreCalculator.STAR_REWARD_TIERS do
		if starRewardTier.starCount == starCount then
			return starRewardTier
		end
	end
	error("no star reward tier for " .. tostring(starCount))
end

describe("Daily quest progress inside the round reward", function()
	it("writes balance, round record and quest progress in ONE change (one revision, one event)", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		local changedSaves = {}
		harness.playerSaveDataKeeper:subscribeToInMemorySaveDataChanged(function(_, saveDataCopy)
			table.insert(changedSaves, saveDataCopy)
		end)
		local revisionBefore = harness.readInMemoryChangeRevision(PLAYER)
		local roundOutcome = harness.grantRoundReward(PLAYER, "round-1", 4, { PINK_HAIR_KEY, BLACK_BOTTOM_KEY })
		expect(roundOutcome.rewardLedgerOutcome).toBe("Granted")
		expect(harness.readInMemoryChangeRevision(PLAYER)).toBe(revisionBefore + 1)
		expect(#changedSaves).toBe(1)
		local changedSave = changedSaves[1]
		expect(changedSave.starCoinBalance).toBe(findStarRewardTier(4).starCoinsGranted)
		expect(changedSave.totalRoundsCompletedCount).toBe(1)
		expect(changedSave.dailyProgress.dailyQuestProgressCountByQuestId).toEqual({
			quest_a = 1,
			quest_d = 1,
			quest_e = 1,
		})
	end)

	it("counts only qualifying rounds for each quest", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.grantRoundReward(PLAYER, "round-1", 3, { BLUE_TOP_KEY, BLACK_BOTTOM_KEY })
		expect(readProgressCounts(harness)).toEqual({ quest_a = 1 })
		harness.grantRoundReward(PLAYER, "round-2", 5, { BLUE_TOP_KEY })
		expect(readProgressCounts(harness)).toEqual({ quest_a = 2, quest_d = 1 })
		harness.grantRoundReward(PLAYER, "round-3", 1, { WHITE_SHOES_KEY, PINK_HAIR_KEY })
		expect(readProgressCounts(harness)).toEqual({ quest_a = 3, quest_d = 1, quest_e = 1 })
	end)

	it("stops at each quest's target", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		for roundNumber = 1, 5 do
			harness.grantRoundReward(PLAYER, "round-" .. roundNumber, 5, { PINK_HAIR_KEY })
		end
		expect(readProgressCounts(harness)).toEqual({ quest_a = 3, quest_d = 2, quest_e = 1 })
	end)

	it("rolls a stale day inside the round change: yesterday's progress never counts toward today's", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ secondsAfterMidnight = 86400 - 600 })
		harness.loadPlayer(PLAYER)
		harness.grantRoundReward(PLAYER, "round-1", 4, { BLUE_TOP_KEY })
		harness.grantRoundReward(PLAYER, "round-2", 4, { BLUE_TOP_KEY })
		-- Past midnight without running scheduled work: the save still holds yesterday's table.
		harness.fakeClock:advanceBySeconds(900)
		harness.grantRoundReward(PLAYER, "round-3", 2, { PINK_HAIR_KEY })
		local dailyProgress = harness.readInMemoryDailyProgress(PLAYER)
		expect(dailyProgress.dailyDateKey).toBe("2026-11-20")
		-- 2026-11-20's quests are quest_f, quest_e and quest_a (all qualify; quest_a starts over).
		expect(dailyProgress.dailyQuestProgressCountByQuestId).toEqual({ quest_a = 1, quest_e = 1, quest_f = 1 })
	end)

	it("repairs a malformed dailyProgress instead of cancelling the round reward", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ isTrackingNotStarted = true })
		harness.storeExistingPlayerSaveData(PLAYER, function(saveData)
			saveData.dailyProgress.claimedDailyQuestIds = { 7 }
		end)
		harness.loadPlayer(PLAYER)
		local roundOutcome = harness.grantRoundReward(PLAYER, "round-1", 3, { PINK_HAIR_KEY })
		expect(roundOutcome.rewardLedgerOutcome).toBe("Granted")
		local saveData = harness.readInMemorySaveData(PLAYER)
		expect(saveData.starCoinBalance).toBe(findStarRewardTier(3).starCoinsGranted)
		expect(saveData.dailyProgress.claimedDailyQuestIds).toEqual({})
		expect(saveData.dailyProgress.dailyQuestProgressCountByQuestId).toEqual({ quest_a = 1, quest_e = 1 })
		expect(#harness.trackerLogger.loggedWarnings).toBe(1)
		expect(string.find(harness.trackerLogger.loggedWarnings[1], "round round-1", 1, true) ~= nil).toBeTrue()
	end)

	it("skips a scored key the pool does not know (logged) and still counts the known ones", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.grantRoundReward(PLAYER, "round-1", 4, { FakeStylingItemPool.KEY_NOT_IN_POOL, PINK_HAIR_KEY })
		expect(readProgressCounts(harness)).toEqual({ quest_a = 1, quest_d = 1, quest_e = 1 })
		expect(#harness.trackerLogger.loggedWarnings).toBe(1)
		expect(
			string.find(harness.trackerLogger.loggedWarnings[1], FakeStylingItemPool.KEY_NOT_IN_POOL, 1, true) ~= nil
		).toBeTrue()
	end)

	it(
		"still grants the round when no scored key is known or the outfit list is empty: no quest progress, logged",
		function()
			local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
			harness.loadPlayer(PLAYER)
			local unknownKeysOutcome =
				harness.grantRoundReward(PLAYER, "round-1", 2, { FakeStylingItemPool.KEY_NOT_IN_POOL })
			local emptyOutfitOutcome = harness.grantRoundReward(PLAYER, "round-2", 2, {})
			expect(unknownKeysOutcome.rewardLedgerOutcome).toBe("Granted")
			expect(emptyOutfitOutcome.rewardLedgerOutcome).toBe("Granted")
			expect(harness.readInMemorySaveData(PLAYER).totalRoundsCompletedCount).toBe(2)
			expect(readProgressCounts(harness)).toEqual({})
			local noKnownItemWarningCount = 0
			for _, loggedWarning in harness.trackerLogger.loggedWarnings do
				if string.find(loggedWarning, "no known scored styling item", 1, true) then
					noKnownItemWarningCount += 1
				end
			end
			expect(noKnownItemWarningCount).toBe(2)
		end
	)

	it(
		"still grants the round when the quest rule raises (a broken catalog entry): no quest progress, logged",
		function()
			local catalogWithUnknownKind = {
				table.clone(DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS[1]),
				table.clone(DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS[2]),
				table.clone(DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS[3]),
			}
			catalogWithUnknownKind[2].dailyQuestKind = "NotAKind"
			local harness = DailyProgressTrackerTestHarness.createTrackerHarness({
				dailyQuestCatalogEntries = catalogWithUnknownKind,
			})
			harness.loadPlayer(PLAYER)
			local roundOutcome = harness.grantRoundReward(PLAYER, "round-1", 2, { PINK_HAIR_KEY })
			expect(roundOutcome.rewardLedgerOutcome).toBe("Granted")
			expect(harness.readInMemorySaveData(PLAYER).starCoinBalance).toBe(findStarRewardTier(2).starCoinsGranted)
			expect(readProgressCounts(harness)).toEqual({})
			expect(#harness.trackerLogger.loggedWarnings).toBe(1)
			expect(string.find(harness.trackerLogger.loggedWarnings[1], "could not be worked out", 1, true) ~= nil).toBeTrue()
		end
	)

	it("never changes starCoinBalance or fanCount itself", function()
		local roundRecordWriter = DailyProgressTracker.createDailyQuestProgressRoundRecordWriter({
			clock = {
				getCurrentUnixSeconds = function()
					return DailyProgressTrackerTestHarness.TEST_DAY_START_UNIX_SECONDS + 3600
				end,
			},
			stylingItemByStylingItemKey = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
			dailyQuestCatalogEntries = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS,
			logger = DailyProgressTrackerTestHarness.createRecordingLogger(),
		})
		local saveDataDraft = PlayerSaveDataSchema.createStartingPlayerSaveData({ "starter_wave" }, 0)
		saveDataDraft.starCoinBalance = 350
		saveDataDraft.fanCount = 1200
		roundRecordWriter(
			saveDataDraft,
			table.freeze({
				roundId = "round-1",
				themeId = "y2k_pop",
				starCount = 5,
				scoredOutfitStylingItemKeys = table.freeze({ PINK_HAIR_KEY }),
			})
		)
		expect(saveDataDraft.starCoinBalance).toBe(350)
		expect(saveDataDraft.fanCount).toBe(1200)
		expect(saveDataDraft.dailyProgress.dailyDateKey).toBe("2026-11-19")
		expect(saveDataDraft.dailyProgress.dailyQuestProgressCountByQuestId).toEqual({
			quest_a = 1,
			quest_d = 1,
			quest_e = 1,
		})
	end)

	it("random rounds: progress equals the qualifying rounds per quest, capped at the target", function()
		local scoredKeyCandidates = {}
		for _, fakeStylingItem in FakeStylingItemPool.FAKE_STYLING_ITEMS do
			table.insert(scoredKeyCandidates, fakeStylingItem.stylingItemKey)
		end
		SeededRandomTrials.runSeededRandomTrials(30, function(randomNumberGenerator)
			local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
			harness.loadPlayer(PLAYER)
			local qualifyingRoundCountByQuestId = { quest_a = 0, quest_d = 0, quest_e = 0 }
			local expectedStarCoinBalance = 0
			for roundNumber = 1, randomNumberGenerator.nextWholeNumberInRange(1, 8) do
				local starCount = randomNumberGenerator.nextWholeNumberInRange(1, 5)
				local scoredKeys = {}
				local hasPinkItem = false
				for _ = 1, randomNumberGenerator.nextWholeNumberInRange(1, 4) do
					local scoredKey = randomNumberGenerator.pickRandomListElement(scoredKeyCandidates)
					table.insert(scoredKeys, scoredKey)
					hasPinkItem = hasPinkItem
						or FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY[scoredKey].primaryColorTag
							== "pink"
				end
				harness.grantRoundReward(PLAYER, "round-" .. roundNumber, starCount, scoredKeys)
				expectedStarCoinBalance += findStarRewardTier(starCount).starCoinsGranted
				qualifyingRoundCountByQuestId.quest_a += 1
				qualifyingRoundCountByQuestId.quest_d += if starCount >= 4 then 1 else 0
				qualifyingRoundCountByQuestId.quest_e += if hasPinkItem then 1 else 0
			end
			local expectedProgressCounts = {}
			for dailyQuestId, qualifyingRoundCount in qualifyingRoundCountByQuestId do
				local targetCount = ({ quest_a = 3, quest_d = 2, quest_e = 1 })[dailyQuestId]
				if qualifyingRoundCount > 0 then
					expectedProgressCounts[dailyQuestId] = math.min(qualifyingRoundCount, targetCount)
				end
			end
			expect(readProgressCounts(harness)).toEqual(expectedProgressCounts)
			expect(harness.readInMemorySaveData(PLAYER).starCoinBalance).toBe(expectedStarCoinBalance)
		end)
	end)
end)
