-- DailyProgressDayBoundary (development spec §1.8, §1.10): today's table is kept, another day's
-- table is replaced for the new day, and each kind of malformed table is replaced and reported as
-- malformed; the read-only copy used by claim checks never changes the stored table.

local DailyProgressDayBoundary = require("../../src/server/DailyProgressDayBoundary")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

-- 2026-11-19 10:00 UTC.
local TEST_DAY_START_UNIX_SECONDS = 1_795_046_400
local TEST_MORNING_UNIX_SECONDS = TEST_DAY_START_UNIX_SECONDS + 36000

local function createSaveDataDraftWithDailyProgress(dailyProgress)
	local saveDataDraft =
		PlayerSaveDataSchema.createStartingPlayerSaveData({ "starter_wave" }, TEST_MORNING_UNIX_SECONDS)
	saveDataDraft.dailyProgress = dailyProgress
	return saveDataDraft
end

local function createRecordingLogger()
	local recordingLogger = { loggedWarnings = {} }
	function recordingLogger.logWarning(self, message: string)
		table.insert(self.loggedWarnings, message)
	end
	return recordingLogger
end

describe("DailyProgressDayBoundary", function()
	it("matches the test date", function()
		expect(PlayerSaveDataSchema.formatUtcDailyDateKey(TEST_DAY_START_UNIX_SECONDS)).toBe("2026-11-19")
		expect(PlayerSaveDataSchema.formatUtcDailyDateKey(TEST_DAY_START_UNIX_SECONDS - 1)).toBe("2026-11-18")
	end)

	it("keeps today's well-formed table untouched", function()
		local todaysDailyProgress = DailyQuestTestCatalog.createTestDailyProgress({
			playtimeSecondsToday = 700,
			claimedPlaytimeMilestoneMinutes = { 5, 10 },
			dailyQuestProgressCountByQuestId = { quest_a = 2 },
			claimedDailyQuestIds = { "quest_e" },
		})
		local saveDataDraft = createSaveDataDraftWithDailyProgress(todaysDailyProgress)
		expect(
			DailyProgressDayBoundary.replaceDailyProgressIfStaleOrMalformed(saveDataDraft, TEST_MORNING_UNIX_SECONDS)
		).toBe("KeptCurrentDailyProgress")
		expect(rawequal(saveDataDraft.dailyProgress, todaysDailyProgress)).toBeTrue()
		expect(saveDataDraft.dailyProgress.playtimeSecondsToday).toBe(700)
	end)

	it("replaces another day's well-formed table with a fresh one for today", function()
		local yesterdaysDailyProgress = PlayerSaveDataSchema.createFreshDailyProgress("2026-11-18")
		yesterdaysDailyProgress.playtimeSecondsToday = 3600
		yesterdaysDailyProgress.claimedPlaytimeMilestoneMinutes = { 5 }
		local saveDataDraft = createSaveDataDraftWithDailyProgress(yesterdaysDailyProgress)
		local recordingLogger = createRecordingLogger()
		expect(
			DailyProgressDayBoundary.replaceDailyProgressIfStaleOrMalformedAndLogRepair(
				saveDataDraft,
				TEST_MORNING_UNIX_SECONDS,
				recordingLogger,
				"player 1"
			)
		).toBe("ReplacedForNewDay")
		expect(saveDataDraft.dailyProgress).toEqual(PlayerSaveDataSchema.createFreshDailyProgress("2026-11-19"))
		expect(recordingLogger.loggedWarnings).toEqual({})
	end)

	it(
		"drops all four fields of another day's table: playtime, milestone claims, quest progress, quest claims",
		function()
			local otherDaysDailyProgresses = {
				PlayerSaveDataSchema.createFreshDailyProgress("2026-11-18"),
				-- Dated in the future: the server clock moved back across midnight.
				PlayerSaveDataSchema.createFreshDailyProgress("2026-11-20"),
			}
			for _, otherDaysDailyProgress in otherDaysDailyProgresses do
				otherDaysDailyProgress.playtimeSecondsToday = 3600
				otherDaysDailyProgress.claimedPlaytimeMilestoneMinutes = { 5, 10 }
				otherDaysDailyProgress.dailyQuestProgressCountByQuestId = { quest_a = 3, quest_e = 1 }
				otherDaysDailyProgress.claimedDailyQuestIds = { "quest_e", "quest_a" }
				local frozenCopy = DailyQuestTestCatalog.freezeDeeply(
					PlayerSaveDataSchema.createDeepCopyOfPlainTable(otherDaysDailyProgress)
				)
				expect(DailyProgressDayBoundary.copyDailyProgressAsOfNow(frozenCopy, TEST_MORNING_UNIX_SECONDS)).toEqual(
					PlayerSaveDataSchema.createFreshDailyProgress("2026-11-19")
				)
				local saveDataDraft = createSaveDataDraftWithDailyProgress(otherDaysDailyProgress)
				expect(
					DailyProgressDayBoundary.replaceDailyProgressIfStaleOrMalformed(
						saveDataDraft,
						TEST_MORNING_UNIX_SECONDS
					)
				).toBe("ReplacedForNewDay")
				expect(saveDataDraft.dailyProgress).toEqual(PlayerSaveDataSchema.createFreshDailyProgress("2026-11-19"))
			end
		end
	)

	it("replaces every kind of malformed table and reports it as malformed (with one warning)", function()
		local malformedDailyProgresses = {
			"not a table",
			5,
			DailyQuestTestCatalog.createTestDailyProgress({ dailyDateKey = 20261119 }),
			DailyQuestTestCatalog.createTestDailyProgress({ playtimeSecondsToday = 0 / 0 }),
			DailyQuestTestCatalog.createTestDailyProgress({ playtimeSecondsToday = "60" }),
			DailyQuestTestCatalog.createTestDailyProgress({ claimedPlaytimeMilestoneMinutes = { "5" } }),
			DailyQuestTestCatalog.createTestDailyProgress({ dailyQuestProgressCountByQuestId = { quest_a = "2" } }),
			DailyQuestTestCatalog.createTestDailyProgress({ claimedDailyQuestIds = { 1 } }),
			DailyQuestTestCatalog.createTestDailyProgress({ claimedDailyQuestIds = "quest_a" }),
		}
		for _, malformedDailyProgress in malformedDailyProgresses do
			local saveDataDraft = createSaveDataDraftWithDailyProgress(malformedDailyProgress)
			local recordingLogger = createRecordingLogger()
			expect(
				DailyProgressDayBoundary.replaceDailyProgressIfStaleOrMalformedAndLogRepair(
					saveDataDraft,
					TEST_MORNING_UNIX_SECONDS,
					recordingLogger,
					"player 1"
				)
			).toBe("ReplacedBecauseMalformed")
			expect(saveDataDraft.dailyProgress).toEqual(PlayerSaveDataSchema.createFreshDailyProgress("2026-11-19"))
			expect(#recordingLogger.loggedWarnings).toBe(1)
			expect(string.find(recordingLogger.loggedWarnings[1], "player 1", 1, true) ~= nil).toBeTrue()
		end
	end)

	it("treats a malformed table of another day as malformed", function()
		local saveDataDraft =
			createSaveDataDraftWithDailyProgress(PlayerSaveDataSchema.createFreshDailyProgress("2026-11-18"))
		saveDataDraft.dailyProgress.claimedDailyQuestIds = { false }
		expect(
			DailyProgressDayBoundary.replaceDailyProgressIfStaleOrMalformed(saveDataDraft, TEST_MORNING_UNIX_SECONDS)
		).toBe("ReplacedBecauseMalformed")
	end)

	it("copies today's table as of now without touching a frozen original, and gives a fresh one otherwise", function()
		local todaysDailyProgress = DailyQuestTestCatalog.freezeDeeply(
			DailyQuestTestCatalog.createTestDailyProgress({ playtimeSecondsToday = 90 })
		)
		local copiedDailyProgress =
			DailyProgressDayBoundary.copyDailyProgressAsOfNow(todaysDailyProgress, TEST_MORNING_UNIX_SECONDS)
		expect(copiedDailyProgress).toEqual(todaysDailyProgress)
		copiedDailyProgress.playtimeSecondsToday += 10
		table.insert(copiedDailyProgress.claimedPlaytimeMilestoneMinutes, 5)
		expect(todaysDailyProgress.playtimeSecondsToday).toBe(90)

		local nextDayCopy =
			DailyProgressDayBoundary.copyDailyProgressAsOfNow(todaysDailyProgress, TEST_DAY_START_UNIX_SECONDS + 86400)
		expect(nextDayCopy).toEqual(PlayerSaveDataSchema.createFreshDailyProgress("2026-11-20"))
	end)

	it("random moments: start of the UTC day and seconds until the next one", function()
		SeededRandomTrials.runSeededRandomTrials(200, function(randomNumberGenerator)
			local dayNumber = randomNumberGenerator.nextWholeNumberInRange(18262, 32872)
			local secondsIntoDay = randomNumberGenerator.nextWholeNumberInRange(0, 86399)
				+ randomNumberGenerator.nextWholeNumberInRange(0, 999) / 1000
			local currentUnixSeconds = dayNumber * 86400 + secondsIntoDay
			expect(DailyProgressDayBoundary.calculateStartOfUtcDayUnixSeconds(currentUnixSeconds)).toBe(
				dayNumber * 86400
			)
			expect(DailyProgressDayBoundary.calculateSecondsUntilNextUtcDay(currentUnixSeconds)).toBeCloseTo(
				86400 - secondsIntoDay,
				1e-6
			)
		end)
	end)
end)
