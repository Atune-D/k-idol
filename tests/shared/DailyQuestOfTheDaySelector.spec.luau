-- The choice of the three daily quests of a UTC day (development spec §1.8, §6.2 "the same three
-- quests for every player on a given date"). Every randomized failure names its seed; rerun with
-- IDOLGROW_RANDOM_TEST_SEED=<seed> to repeat it.

local UnitTestFramework = require("../Support/UnitTestFramework")
local DailyQuestCatalog = require("../../src/shared/DailyQuestCatalog")
local DailyQuestOfTheDaySelector = require("../../src/shared/DailyQuestOfTheDaySelector")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local SIX_TEST_DAILY_QUESTS = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS
local pickRandomDailyDateKey = DailyQuestTestCatalog.pickRandomDailyDateKey

local function selectRealDailyQuestIds(dailyDateKey: string): { string }
	return DailyQuestOfTheDaySelector.selectDailyQuestIdsForDailyDateKey(dailyDateKey)
end

local function selectTestDailyQuestIds(dailyDateKey: string, dailyQuestCatalogEntries): { string }
	return DailyQuestOfTheDaySelector.selectDailyQuestIdsForDailyDateKey(dailyDateKey, dailyQuestCatalogEntries)
end

local function countIdsMissingFrom(checkedIds: { string }, referenceIds: { string }): number
	local missingIdCount = 0
	for _, checkedId in checkedIds do
		if table.find(referenceIds, checkedId) == nil then
			missingIdCount += 1
		end
	end
	return missingIdCount
end

local function createCompleteRoundsTestQuest(dailyQuestId: string)
	return table.freeze({
		dailyQuestId = dailyQuestId,
		dailyQuestKind = "CompleteRounds",
		targetCount = 1,
		starCoinReward = 10,
	})
end

describe("DailyQuestOfTheDaySelector fixed answers", function()
	it("the shared test catalog's pinned choices hold (computed by an independent reference)", function()
		for dailyDateKey, expectedDailyQuestIds in DailyQuestTestCatalog.PINNED_TEST_DAILY_QUEST_IDS_BY_DAILY_DATE_KEY do
			expect({ dailyDateKey, selectTestDailyQuestIds(dailyDateKey, SIX_TEST_DAILY_QUESTS) }).toEqual({
				dailyDateKey,
				expectedDailyQuestIds,
			})
		end
	end)

	it("computes day ranks matching the independent reference", function()
		-- Reference (Python): the first mulberry32 output seeded with FNV-1a("2026-11-19/<id>").
		local expectedDayRankByDailyQuestId = {
			quest_a = 1424857709,
			quest_b = 2174112854,
			quest_c = 2179304285,
			quest_d = 1830332461,
			quest_e = 1991644506,
			quest_f = 3288894970,
		}
		for dailyQuestId, expectedDayRank in expectedDayRankByDailyQuestId do
			expect({ dailyQuestId, DailyQuestOfTheDaySelector.calculateDailyQuestDayRank("2026-11-19", dailyQuestId) }).toEqual({
				dailyQuestId,
				expectedDayRank,
			})
		end
	end)

	it("returns the catalog entries themselves, matching the ids", function()
		local selectedDailyQuests =
			DailyQuestOfTheDaySelector.selectDailyQuestsForDailyDateKey("2026-11-19", SIX_TEST_DAILY_QUESTS)
		expect(selectedDailyQuests[1]).toBe(SIX_TEST_DAILY_QUESTS[1])
		expect(selectedDailyQuests[2]).toBe(SIX_TEST_DAILY_QUESTS[4])
		expect(selectedDailyQuests[3]).toBe(SIX_TEST_DAILY_QUESTS[5])
	end)

	it("uses the real catalog by default", function()
		local defaultSelection = DailyQuestOfTheDaySelector.selectDailyQuestsForDailyDateKey("2026-11-19")
		expect(
			DailyQuestOfTheDaySelector.selectDailyQuestsForDailyDateKey("2026-11-19", DailyQuestCatalog.DAILY_QUESTS)
		).toEqual(defaultSelection)
		for _, selectedDailyQuest in defaultSelection do
			expect(DailyQuestCatalog.findDailyQuestByDailyQuestId(selectedDailyQuest.dailyQuestId)).toBe(
				selectedDailyQuest
			)
		end
	end)

	it("returns frozen lists and is itself frozen", function()
		expect(table.isfrozen(DailyQuestOfTheDaySelector)).toBeTrue()
		expect(table.isfrozen(DailyQuestOfTheDaySelector.selectDailyQuestsForDailyDateKey("2026-11-19"))).toBeTrue()
		expect(table.isfrozen(selectRealDailyQuestIds("2026-11-19"))).toBeTrue()
	end)
end)

describe("DailyQuestOfTheDaySelector same quests for everyone", function()
	it("gives the same three quests whatever math.random's state (it never uses math.random)", function()
		local firstAnswer = selectRealDailyQuestIds("2026-12-24")
		for disturbingSeed = 1, 25 do
			math.randomseed(disturbingSeed)
			local _discardedRuntimeRandomNumber = math.random()
			expect(selectRealDailyQuestIds("2026-12-24")).toEqual(firstAnswer)
		end
		-- Leave math.random unpredictable again for any later test that uses it.
		math.randomseed(math.floor(os.clock() * 1000000) + os.time())
	end)

	it("depends on the date key alone: no state carries over between calls, for random dates", function()
		SeededRandomTrials.runSeededRandomTrials(300, function(trialRandomNumberGenerator)
			local dailyDateKey = pickRandomDailyDateKey(trialRandomNumberGenerator)
			local firstAnswer = selectRealDailyQuestIds(dailyDateKey)
			-- Other servers and players ask about other dates in between; the answer must not move.
			for _ = 1, trialRandomNumberGenerator.nextWholeNumberInRange(1, 5) do
				selectRealDailyQuestIds(pickRandomDailyDateKey(trialRandomNumberGenerator))
			end
			expect({ dailyDateKey, selectRealDailyQuestIds(dailyDateKey) }).toEqual({ dailyDateKey, firstAnswer })
		end)
	end)

	it("ignores the catalog's order: a shuffled catalog gives the same answer, for random dates", function()
		SeededRandomTrials.runSeededRandomTrials(200, function(trialRandomNumberGenerator)
			local dailyDateKey = pickRandomDailyDateKey(trialRandomNumberGenerator)
			local shuffledCatalog = table.clone(DailyQuestCatalog.DAILY_QUESTS)
			trialRandomNumberGenerator.shuffleListInPlace(shuffledCatalog)
			expect({ dailyDateKey, selectTestDailyQuestIds(dailyDateKey, shuffledCatalog) }).toEqual({
				dailyDateKey,
				selectRealDailyQuestIds(dailyDateKey),
			})
		end)
	end)

	it("adding or removing one quest changes at most one of the day's three, for random dates", function()
		SeededRandomTrials.runSeededRandomTrials(300, function(trialRandomNumberGenerator)
			local dailyDateKey = pickRandomDailyDateKey(trialRandomNumberGenerator)
			local answerBefore = selectRealDailyQuestIds(dailyDateKey)

			local catalogWithAddedQuest = table.clone(DailyQuestCatalog.DAILY_QUESTS)
			table.insert(
				catalogWithAddedQuest,
				trialRandomNumberGenerator.nextWholeNumberInRange(1, #catalogWithAddedQuest + 1),
				createCompleteRoundsTestQuest("added_quest")
			)
			local answerWithAddedQuest = selectTestDailyQuestIds(dailyDateKey, catalogWithAddedQuest)
			expect({ dailyDateKey, "added", countIdsMissingFrom(answerWithAddedQuest, answerBefore) <= 1 }).toEqual({
				dailyDateKey,
				"added",
				true,
			})

			local catalogWithRemovedQuest = table.clone(DailyQuestCatalog.DAILY_QUESTS)
			table.remove(
				catalogWithRemovedQuest,
				trialRandomNumberGenerator.nextWholeNumberInRange(1, #catalogWithRemovedQuest)
			)
			local answerWithRemovedQuest = selectTestDailyQuestIds(dailyDateKey, catalogWithRemovedQuest)
			expect({ dailyDateKey, "removed", countIdsMissingFrom(answerWithRemovedQuest, answerBefore) <= 1 }).toEqual({
				dailyDateKey,
				"removed",
				true,
			})
		end)
	end)
end)

describe("DailyQuestOfTheDaySelector distinct quests and spread", function()
	it("always picks three distinct catalog quests, for random dates", function()
		SeededRandomTrials.runSeededRandomTrials(500, function(trialRandomNumberGenerator)
			local dailyDateKey = pickRandomDailyDateKey(trialRandomNumberGenerator)
			local selectedDailyQuestIds = selectRealDailyQuestIds(dailyDateKey)
			expect({ dailyDateKey, #selectedDailyQuestIds }).toEqual({ dailyDateKey, 3 })
			local seenDailyQuestIdSet = {}
			for _, selectedDailyQuestId in selectedDailyQuestIds do
				expect({ dailyDateKey, selectedDailyQuestId, seenDailyQuestIdSet[selectedDailyQuestId] }).toEqual({
					dailyDateKey,
					selectedDailyQuestId,
					nil,
				})
				seenDailyQuestIdSet[selectedDailyQuestId] = true
				expect(DailyQuestCatalog.findDailyQuestByDailyQuestId(selectedDailyQuestId) ~= nil).toBeTrue()
			end
		end)
	end)

	it("spreads picks across the whole catalog over 3000 random dates (each quest within 25% of fair)", function()
		SeededRandomTrials.runSeededRandomTrials(1, function(trialRandomNumberGenerator)
			local sampledDateCount = 3000
			local pickCountByDailyQuestId = {}
			for _ = 1, sampledDateCount do
				for _, selectedDailyQuestId in
					selectRealDailyQuestIds(pickRandomDailyDateKey(trialRandomNumberGenerator))
				do
					pickCountByDailyQuestId[selectedDailyQuestId] = (pickCountByDailyQuestId[selectedDailyQuestId] or 0)
						+ 1
				end
			end
			local fairPickCount = sampledDateCount
				* DailyQuestCatalog.DAILY_QUEST_COUNT_PER_DAY
				/ #DailyQuestCatalog.DAILY_QUESTS
			for _, dailyQuest in DailyQuestCatalog.DAILY_QUESTS do
				local pickCount = pickCountByDailyQuestId[dailyQuest.dailyQuestId] or 0
				expect({
					dailyQuest.dailyQuestId,
					pickCount >= fairPickCount * 0.75 and pickCount <= fairPickCount * 1.25,
				}).toEqual({ dailyQuest.dailyQuestId, true })
			end
		end)
	end)

	it("changes from day to day: over 1000 consecutive days, few days repeat the previous day's set", function()
		local repeatedDayCount = 0
		local previousDaySelectionText = nil
		for dayNumber = 20454, 21453 do -- 2026-01-01 onwards
			local selectedDailyQuestIds = table.clone(
				selectRealDailyQuestIds(
					PlayerSaveDataSchema.formatUtcDailyDateKey(dayNumber * DailyQuestTestCatalog.SECONDS_PER_DAY)
				)
			)
			table.sort(selectedDailyQuestIds)
			local selectionText = table.concat(selectedDailyQuestIds, ",")
			if selectionText == previousDaySelectionText then
				repeatedDayCount += 1
			end
			previousDaySelectionText = selectionText
		end
		-- With 220 possible sets a fair choice repeats about 5 times in 1000 days.
		expect(repeatedDayCount <= 20).toBeTrue()
	end)
end)

describe("DailyQuestOfTheDaySelector small catalogs and bad input", function()
	it("with exactly three quests, picks all three", function()
		local threeTestDailyQuests = { SIX_TEST_DAILY_QUESTS[1], SIX_TEST_DAILY_QUESTS[2], SIX_TEST_DAILY_QUESTS[3] }
		local selectedDailyQuestIds = table.clone(selectTestDailyQuestIds("2026-11-19", threeTestDailyQuests))
		table.sort(selectedDailyQuestIds)
		expect(selectedDailyQuestIds).toEqual({ "quest_a", "quest_b", "quest_c" })
	end)

	it("refuses a catalog with fewer than three quests instead of repeating one", function()
		for _, tooSmallCatalog in
			{ {}, { SIX_TEST_DAILY_QUESTS[1] }, { SIX_TEST_DAILY_QUESTS[1], SIX_TEST_DAILY_QUESTS[2] } }
		do
			expect(function()
				DailyQuestOfTheDaySelector.selectDailyQuestsForDailyDateKey("2026-11-19", tooSmallCatalog)
			end).toThrow("the catalog needs at least 3 quests")
		end
	end)

	it("refuses a catalog that repeats a quest id, which could pick one quest twice", function()
		-- quest_a has the smallest day rank on 2026-11-19, so without the check it would be picked twice.
		local catalogWithRepeatedId = {
			SIX_TEST_DAILY_QUESTS[1],
			SIX_TEST_DAILY_QUESTS[1],
			SIX_TEST_DAILY_QUESTS[2],
			SIX_TEST_DAILY_QUESTS[3],
		}
		expect(function()
			DailyQuestOfTheDaySelector.selectDailyQuestsForDailyDateKey("2026-11-19", catalogWithRepeatedId)
		end).toThrow("the catalog repeats quest id quest_a")
	end)

	it("refuses a date key that is not YYYY-MM-DD", function()
		for _, malformedDailyDateKey in
			{ "2026-1-19", "20261119", "2026/11/19", "2026_11_19", "2026-11-19T00", " 2026-11-19", "", 20261119, nil }
		do
			expect(DailyQuestOfTheDaySelector.isWellFormedDailyDateKey(malformedDailyDateKey)).toBeFalse()
			expect(function()
				DailyQuestOfTheDaySelector.selectDailyQuestsForDailyDateKey(malformedDailyDateKey :: any)
			end).toThrow("dailyDateKey must be a YYYY-MM-DD string")
		end
		expect(DailyQuestOfTheDaySelector.isWellFormedDailyDateKey("2026-11-19")).toBeTrue()
	end)
end)
