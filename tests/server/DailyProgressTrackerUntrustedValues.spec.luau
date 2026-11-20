-- DailyProgressTracker against untrusted device values (development spec §2 intro, §2.9, §5.1):
-- whatever Luau value arrives as `milestoneMinutes` or `dailyQuestId`, the server never raises,
-- changes nothing, answers UnknownMilestone / NotTodaysQuest, and never logs or echoes the value.

local DailyProgressTrackerTestHarness = require("./DailyProgressTrackerTestHarness")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = DailyProgressTrackerTestHarness.PLAYER
local PINK_HAIR_KEY = DailyProgressTrackerTestHarness.PINK_HAIR_KEY

-- Long enough that a log line or answer holding it would stand out.
local HUGE_UNTRUSTED_TEXT = string.rep("quest_e", 150000)

local function createTableWhoseEveryMetamethodRaises()
	local raisingMetamethods = {}
	for _, metamethodName in
		{ "__index", "__newindex", "__eq", "__lt", "__le", "__len", "__concat", "__call", "__tostring", "__iter" }
	do
		raisingMetamethods[metamethodName] = function()
			error("an untrusted value's metamethod was used")
		end
	end
	return setmetatable({}, raisingMetamethods)
end

local function createCyclicTable()
	local cyclicTable = { dailyQuestId = "quest_e", milestoneMinutes = 5 }
	cyclicTable.self = cyclicTable
	return cyclicTable
end

-- Every kind of value a device could send, none of them a valid milestone or today's quest id.
local function listUntrustedValues()
	return {
		{ valueLabel = "nil", untrustedValue = nil },
		{ valueLabel = "true", untrustedValue = true },
		{ valueLabel = "NaN", untrustedValue = 0 / 0 },
		{ valueLabel = "infinity", untrustedValue = math.huge },
		{ valueLabel = "minus infinity", untrustedValue = -math.huge },
		{ valueLabel = "a huge number", untrustedValue = 1e308 },
		{ valueLabel = "zero", untrustedValue = 0 },
		{ valueLabel = "a negative milestone", untrustedValue = -5 },
		{ valueLabel = "an in-between number", untrustedValue = 5.5 },
		{ valueLabel = "a nearly whole number", untrustedValue = 5 + 1e-12 },
		{ valueLabel = "a number in a string", untrustedValue = "5" },
		{ valueLabel = "a quest id with a space", untrustedValue = "quest_e " },
		{ valueLabel = "a quest id in capitals", untrustedValue = "QUEST_E" },
		{ valueLabel = "an empty string", untrustedValue = "" },
		{ valueLabel = "a huge string", untrustedValue = HUGE_UNTRUSTED_TEXT },
		{ valueLabel = "a list holding a valid value", untrustedValue = { 5, "quest_e" } },
		{ valueLabel = "a table whose metamethods raise", untrustedValue = createTableWhoseEveryMetamethodRaises() },
		{ valueLabel = "a cyclic table", untrustedValue = createCyclicTable() },
		{ valueLabel = "a function", untrustedValue = function() end },
		{ valueLabel = "a coroutine", untrustedValue = coroutine.create(function() end) },
		{ valueLabel = "a buffer", untrustedValue = buffer.create(16) },
		{ valueLabel = "a vector", untrustedValue = vector.create(5, 0, 0) },
	}
end

local function expectNoLogLineMentionsUntrustedText(harness)
	for _, loggedLines in
		{
			harness.trackerLogger.loggedInformation,
			harness.trackerLogger.loggedWarnings,
			harness.ledgerLogger.loggedInformation,
			harness.ledgerLogger.loggedWarnings,
			harness.keeperHarness.loggedWarnings,
			harness.keeperHarness.loggedInformation,
		}
	do
		for _, loggedLine in loggedLines do
			expect(#loggedLine < 1000).toBeTrue()
		end
	end
end

describe("DailyProgressTracker with untrusted request values", function()
	it("answers UnknownMilestone to every unusable milestone value and changes nothing", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ admitsEveryRequest = true })
		harness.loadPlayer(PLAYER)
		harness.advanceSeconds(3600)
		local saveDataBefore = harness.readInMemorySaveData(PLAYER)
		local revisionBefore = harness.readInMemoryChangeRevision(PLAYER)
		for _, untrustedCase in listUntrustedValues() do
			local didAnswer, claimAnswer = pcall(function()
				return harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(
					PLAYER,
					untrustedCase.untrustedValue
				)
			end)
			if not didAnswer then
				error("raised for " .. untrustedCase.valueLabel .. ": " .. tostring(claimAnswer))
			end
			expect(claimAnswer).toEqual({ isAccepted = false, rejectionReason = "UnknownMilestone" })
		end
		expect(harness.readInMemoryChangeRevision(PLAYER)).toBe(revisionBefore)
		expect(harness.readInMemorySaveData(PLAYER)).toEqual(saveDataBefore)
		expectNoLogLineMentionsUntrustedText(harness)
	end)

	it("answers NotTodaysQuest to every unusable quest id value and changes nothing", function()
		local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ admitsEveryRequest = true })
		harness.loadPlayer(PLAYER)
		harness.grantRoundReward(PLAYER, "round-1", 4, { PINK_HAIR_KEY })
		local saveDataBefore = harness.readInMemorySaveData(PLAYER)
		local revisionBefore = harness.readInMemoryChangeRevision(PLAYER)
		for _, untrustedCase in listUntrustedValues() do
			local didAnswer, claimAnswer = pcall(function()
				return harness.dailyProgressTracker:answerClaimDailyQuestRewardRequest(
					PLAYER,
					untrustedCase.untrustedValue
				)
			end)
			if not didAnswer then
				error("raised for " .. untrustedCase.valueLabel .. ": " .. tostring(claimAnswer))
			end
			expect(claimAnswer).toEqual({ isAccepted = false, rejectionReason = "NotTodaysQuest" })
		end
		expect(harness.readInMemoryChangeRevision(PLAYER)).toBe(revisionBefore)
		expect(harness.readInMemorySaveData(PLAYER)).toEqual(saveDataBefore)
		expectNoLogLineMentionsUntrustedText(harness)
	end)

	it("random numbers: only the six defined milestones are ever accepted, each once", function()
		SeededRandomTrials.runSeededRandomTrials(20, function(randomNumberGenerator)
			local harness = DailyProgressTrackerTestHarness.createTrackerHarness({ admitsEveryRequest = true })
			harness.loadPlayer(PLAYER)
			harness.advanceSeconds(3600)
			local definedMilestoneMinutes = { 5, 10, 20, 30, 45, 60 }
			local acceptedMilestoneMinutesSet = {}
			for _ = 1, 40 do
				local requestedMilestoneMinutes = if randomNumberGenerator.nextFractionBetweenZeroAndOne() < 0.5
					then randomNumberGenerator.pickRandomListElement(definedMilestoneMinutes)
					else randomNumberGenerator.nextWholeNumberInRange(-100, 200)
						+ (if randomNumberGenerator.nextFractionBetweenZeroAndOne() < 0.3 then 0.5 else 0)
				local claimAnswer =
					harness.dailyProgressTracker:answerClaimPlaytimeMilestoneRequest(PLAYER, requestedMilestoneMinutes)
				local isDefinedMilestone = table.find(definedMilestoneMinutes, requestedMilestoneMinutes) ~= nil
				if not isDefinedMilestone then
					expect(claimAnswer.rejectionReason).toBe("UnknownMilestone")
				elseif acceptedMilestoneMinutesSet[requestedMilestoneMinutes] then
					expect(claimAnswer.rejectionReason).toBe("AlreadyClaimed")
				else
					expect(claimAnswer.isAccepted).toBeTrue()
					acceptedMilestoneMinutesSet[requestedMilestoneMinutes] = true
				end
			end
			local expectedBalance = 0
			for milestoneMinutes in acceptedMilestoneMinutesSet do
				expectedBalance += ({ [5] = 20, [10] = 30, [20] = 50, [30] = 80, [45] = 100, [60] = 150 })[milestoneMinutes]
			end
			expect(harness.readInMemorySaveData(PLAYER).starCoinBalance).toBe(expectedBalance)
		end)
	end)
end)
