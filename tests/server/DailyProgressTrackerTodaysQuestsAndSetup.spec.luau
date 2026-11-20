-- DailyProgressTracker: today's three quests (development spec §1.8 "the same for every player",
-- §2.6 `todaysDailyQuestIds`, §6.2 "Unit: daily content") and the construction rules of the
-- tracker and its round record writer (dependencies, catalog checks, catalog copies).

local DailyProgressTracker = require("../../src/server/DailyProgressTracker")
local DailyProgressTrackerTestHarness = require("./DailyProgressTrackerTestHarness")
local DailyQuestOfTheDaySelector = require("../../src/shared/DailyQuestOfTheDaySelector")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local FakeClock = require("../Support/FakeClock")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = DailyProgressTrackerTestHarness.PLAYER
local OTHER_PLAYER = DailyProgressTrackerTestHarness.OTHER_PLAYER
local PINK_HAIR_KEY = DailyProgressTrackerTestHarness.PINK_HAIR_KEY
local PINNED_IDS_BY_DATE = DailyQuestTestCatalog.PINNED_TEST_DAILY_QUEST_IDS_BY_DAILY_DATE_KEY

local function createUnfrozenCatalogCopy()
	local unfrozenCatalog = {}
	for _, dailyQuest in DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS do
		table.insert(unfrozenCatalog, table.clone(dailyQuest))
	end
	return unfrozenCatalog
end

local function createRecordingLogger()
	return DailyProgressTrackerTestHarness.createRecordingLogger()
end

local function buildCompleteTrackerDependencies()
	local fakeClock = FakeClock.new(DailyProgressTrackerTestHarness.TEST_DAY_START_UNIX_SECONDS)
	return {
		playerSaveDataKeeper = {},
		rewardLedger = {},
		playerRequestRateLimiter = {},
		clock = fakeClock,
		scheduler = {},
		logger = createRecordingLogger(),
		dailyQuestCatalogEntries = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS,
	}
end

local function buildCompleteWriterDependencies()
	return {
		clock = FakeClock.new(DailyProgressTrackerTestHarness.TEST_DAY_START_UNIX_SECONDS),
		stylingItemByStylingItemKey = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
		dailyQuestCatalogEntries = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS,
		logger = createRecordingLogger(),
	}
end

describe("DailyProgressTracker today's quests", function()
	it("reads today's three quest ids from the clock's UTC day", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		expect(harness.dailyProgressTracker:readTodaysDailyQuestIds()).toEqual(PINNED_IDS_BY_DATE["2026-11-19"])
		harness.advanceToTimeOfDay(1, 0)
		expect(harness.dailyProgressTracker:readTodaysDailyQuestIds()).toEqual(PINNED_IDS_BY_DATE["2026-11-20"])
	end)

	it("returns a new frozen list on every call", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		local firstTodaysDailyQuestIds = harness.dailyProgressTracker:readTodaysDailyQuestIds()
		local secondTodaysDailyQuestIds = harness.dailyProgressTracker:readTodaysDailyQuestIds()
		expect(table.isfrozen(firstTodaysDailyQuestIds)).toBeTrue()
		expect(rawequal(firstTodaysDailyQuestIds, secondTodaysDailyQuestIds)).toBeFalse()
	end)

	it("offers the same three quests to every player: both can complete and claim the same quest", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
		harness.loadPlayer(PLAYER)
		harness.loadPlayer(OTHER_PLAYER)
		harness.grantRoundReward(PLAYER, "round-1", 2, { PINK_HAIR_KEY })
		harness.grantRoundReward(OTHER_PLAYER, "round-1", 2, { PINK_HAIR_KEY })
		expect(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_e").isAccepted).toBeTrue()
		expect(harness.claimDailyQuestRewardAfterOneSecond(OTHER_PLAYER, "quest_e").isAccepted).toBeTrue()
		expect(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_b").rejectionReason).toBe("NotTodaysQuest")
		expect(harness.claimDailyQuestRewardAfterOneSecond(OTHER_PLAYER, "quest_b").rejectionReason).toBe(
			"NotTodaysQuest"
		)
	end)

	it("random dates: every player is offered exactly the selector's three quests for that date", function()
		SeededRandomTrials.runSeededRandomTrials(25, function(randomNumberGenerator)
			local harness = DailyProgressTrackerTestHarness.createTrackerHarness()
			harness.advanceToTimeOfDay(
				randomNumberGenerator.nextWholeNumberInRange(0, 5000),
				randomNumberGenerator.nextWholeNumberInRange(0, 86399)
			)
			harness.loadPlayer(PLAYER)
			harness.loadPlayer(OTHER_PLAYER)
			local currentDailyDateKey =
				PlayerSaveDataSchema.formatUtcDailyDateKey(harness.fakeClock:getCurrentUnixSeconds())
			local todaysDailyQuestIds = harness.dailyProgressTracker:readTodaysDailyQuestIds()
			expect(todaysDailyQuestIds).toEqual(
				DailyQuestOfTheDaySelector.selectDailyQuestIdsForDailyDateKey(
					currentDailyDateKey,
					DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS
				)
			)
			for _, playerUserId in { PLAYER, OTHER_PLAYER } do
				for _, catalogDailyQuest in DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS do
					local claimAnswer =
						harness.claimDailyQuestRewardAfterOneSecond(playerUserId, catalogDailyQuest.dailyQuestId)
					local isTodaysQuest = table.find(todaysDailyQuestIds, catalogDailyQuest.dailyQuestId) ~= nil
					-- One second later it can be just past midnight: the answer follows the new day.
					local dailyDateKeyAtClaim =
						PlayerSaveDataSchema.formatUtcDailyDateKey(harness.fakeClock:getCurrentUnixSeconds())
					if dailyDateKeyAtClaim == currentDailyDateKey then
						expect(claimAnswer.rejectionReason).toBe(
							if isTodaysQuest then "QuestNotCompleted" else "NotTodaysQuest"
						)
					end
				end
			end
		end)
	end)
end)

describe("DailyProgressTracker construction", function()
	it("raises when any tracker dependency is missing", function()
		for dependencyName in buildCompleteTrackerDependencies() do
			local trackerDependencies = buildCompleteTrackerDependencies()
			trackerDependencies[dependencyName] = nil
			expect(function()
				DailyProgressTracker.new(trackerDependencies)
			end).toThrow("missing dependency " .. dependencyName)
		end
		expect(function()
			DailyProgressTracker.new(nil)
		end).toThrow("dependencies must be a table")
	end)

	it("raises when any round record writer dependency is missing", function()
		for dependencyName in buildCompleteWriterDependencies() do
			local writerDependencies = buildCompleteWriterDependencies()
			writerDependencies[dependencyName] = nil
			expect(function()
				DailyProgressTracker.createDailyQuestProgressRoundRecordWriter(writerDependencies)
			end).toThrow("missing dependency " .. dependencyName)
		end
	end)

	it("raises for a catalog that cannot fill a day: too few quests, a repeated id, a non-table entry", function()
		local twoQuestCatalog =
			{ DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS[1], DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS[2] }
		local repeatedIdCatalog = createUnfrozenCatalogCopy()
		repeatedIdCatalog[2].dailyQuestId = repeatedIdCatalog[1].dailyQuestId
		local nonTableEntryCatalog = createUnfrozenCatalogCopy()
		nonTableEntryCatalog[3] = "quest_c" :: any
		for _, brokenCatalog in { twoQuestCatalog, repeatedIdCatalog, nonTableEntryCatalog, "not a list" :: any } do
			local trackerDependencies = buildCompleteTrackerDependencies()
			trackerDependencies.dailyQuestCatalogEntries = brokenCatalog
			expect(function()
				DailyProgressTracker.new(trackerDependencies)
			end).toThrow("DailyProgressTracker.new")
			local writerDependencies = buildCompleteWriterDependencies()
			writerDependencies.dailyQuestCatalogEntries = brokenCatalog
			expect(function()
				DailyProgressTracker.createDailyQuestProgressRoundRecordWriter(writerDependencies)
			end).toThrow("createDailyQuestProgressRoundRecordWriter")
		end
	end)

	it(
		"copies the caller's catalog: changing it afterwards changes neither today's quests nor quest progress",
		function()
			local callerOwnedCatalog = createUnfrozenCatalogCopy()
			local harness =
				DailyProgressTrackerTestHarness.createTrackerHarness({ dailyQuestCatalogEntries = callerOwnedCatalog })
			for _, callerOwnedQuest in callerOwnedCatalog do
				callerOwnedQuest.dailyQuestId = "changed_" .. callerOwnedQuest.dailyQuestId
				callerOwnedQuest.targetCount = 99
			end
			table.clear(callerOwnedCatalog)
			expect(harness.dailyProgressTracker:readTodaysDailyQuestIds()).toEqual(PINNED_IDS_BY_DATE["2026-11-19"])
			harness.loadPlayer(PLAYER)
			harness.grantRoundReward(PLAYER, "round-1", 2, { PINK_HAIR_KEY })
			expect(harness.readInMemoryDailyProgress(PLAYER).dailyQuestProgressCountByQuestId).toEqual({
				quest_a = 1,
				quest_e = 1,
			})
			expect(harness.claimDailyQuestRewardAfterOneSecond(PLAYER, "quest_e").isAccepted).toBeTrue()
		end
	)
end)
