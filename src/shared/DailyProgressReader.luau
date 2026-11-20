-- Reads one player's `dailyProgress` table (development spec §1.10) for the daily rules: checks
-- that it is well formed and belongs to the current UTC day, and answers the questions both
-- DailyRewardClaimEligibility and DailyQuestProgressFromRatedRound ask about it, so each rule
-- ("a missing count is 0", "is claimed", "has reached targetCount") is written once.
--
-- Why the check: these rules trust `dailyProgress.dailyDateKey` to mean "today". If the caller
-- forgot the daily reset, yesterday's playtime and quests would be honoured today; and a save
-- edited by hand or corrupted could hold a field of the wrong type. Both are programming or data
-- errors, not device requests, so they raise an error naming the field rather than being answered
-- with a rejection reason. Recovering (for example replacing a malformed table with a fresh one at
-- the daily reset) is the job of the code that loads and resets saves, not of these rules.
-- Reads only; changes nothing. Pure logic: no Roblox-specific interface is used.

local DailyQuestCatalog = require("./DailyQuestCatalog")
local DailyQuestOfTheDaySelector = require("./DailyQuestOfTheDaySelector")

type DailyQuest = DailyQuestCatalog.DailyQuest

-- The dailyProgress fields the daily rules read (PlayerSaveDataSchema.DailyProgress).
export type DailyProgress = {
	dailyDateKey: string,
	playtimeSecondsToday: number,
	claimedPlaytimeMilestoneMinutes: { number },
	dailyQuestProgressCountByQuestId: { [string]: number },
	claimedDailyQuestIds: { string },
}

local DailyProgressReader = {}

local function isNumberOtherThanNaN(candidateValue: any): boolean
	return type(candidateValue) == "number" and candidateValue == candidateValue
end

local function isListOfValuesOfType(candidateList: any, expectedValueType: string): boolean
	if type(candidateList) ~= "table" then
		return false
	end
	for _, listedValue in candidateList do
		if type(listedValue) ~= expectedValueType then
			return false
		end
	end
	return true
end

local function isProgressCountMap(candidateMap: any): boolean
	if type(candidateMap) ~= "table" then
		return false
	end
	for dailyQuestId, progressCount in candidateMap do
		if type(dailyQuestId) ~= "string" or not isNumberOtherThanNaN(progressCount) then
			return false
		end
	end
	return true
end

-- Returns the name of the first malformed field of `dailyProgress`, or nil when it is well formed.
local function findMalformedDailyProgressField(dailyProgress: any): string?
	if type(dailyProgress) ~= "table" then
		return "dailyProgress"
	elseif not DailyQuestOfTheDaySelector.isWellFormedDailyDateKey(dailyProgress.dailyDateKey) then
		return "dailyDateKey"
	elseif not isNumberOtherThanNaN(dailyProgress.playtimeSecondsToday) then
		return "playtimeSecondsToday"
	elseif not isListOfValuesOfType(dailyProgress.claimedPlaytimeMilestoneMinutes, "number") then
		return "claimedPlaytimeMilestoneMinutes"
	elseif not isProgressCountMap(dailyProgress.dailyQuestProgressCountByQuestId) then
		return "dailyQuestProgressCountByQuestId"
	elseif not isListOfValuesOfType(dailyProgress.claimedDailyQuestIds, "string") then
		return "claimedDailyQuestIds"
	end
	return nil
end

-- Raises an error unless `dailyProgress` is well formed and is the table of `currentDailyDateKey`
-- (the UTC day the server's clock says it is now). `errorLevel` is counted from the function that
-- calls this one, as in `error`: 1 blames that function, 2 blames its caller (the default is 1).
function DailyProgressReader.assertDailyProgressIsCurrentAndWellFormed(
	dailyProgress: any,
	currentDailyDateKey: any,
	errorLevel: number?
)
	local reportedErrorLevel = (errorLevel or 1) + 1
	if not DailyQuestOfTheDaySelector.isWellFormedDailyDateKey(currentDailyDateKey) then
		error("DailyProgressReader: currentDailyDateKey must be a YYYY-MM-DD string", reportedErrorLevel)
	end
	local malformedFieldName = findMalformedDailyProgressField(dailyProgress)
	if malformedFieldName ~= nil then
		error("DailyProgressReader: dailyProgress is malformed at " .. malformedFieldName, reportedErrorLevel)
	end
	if dailyProgress.dailyDateKey ~= currentDailyDateKey then
		error(
			string.format(
				"DailyProgressReader: dailyProgress is for %s, not today %s; apply the daily reset first",
				dailyProgress.dailyDateKey,
				currentDailyDateKey
			),
			reportedErrorLevel
		)
	end
end

-- The progress count stored for a quest today; a quest with no entry yet has made no progress (0).
function DailyProgressReader.readDailyQuestProgressCount(dailyProgress: DailyProgress, dailyQuestId: string): number
	return dailyProgress.dailyQuestProgressCountByQuestId[dailyQuestId] or 0
end

-- True when the quest's progress count is at or above its targetCount.
function DailyProgressReader.hasDailyQuestReachedTarget(dailyProgress: DailyProgress, dailyQuest: DailyQuest): boolean
	return DailyProgressReader.readDailyQuestProgressCount(dailyProgress, dailyQuest.dailyQuestId)
		>= dailyQuest.targetCount
end

-- True when the quest's reward has been claimed today.
function DailyProgressReader.isDailyQuestClaimed(dailyProgress: DailyProgress, dailyQuestId: string): boolean
	return table.find(dailyProgress.claimedDailyQuestIds, dailyQuestId) ~= nil
end

-- True when the playtime milestone with these minutes has been claimed today.
function DailyProgressReader.isPlaytimeMilestoneClaimed(dailyProgress: DailyProgress, milestoneMinutes: number): boolean
	return table.find(dailyProgress.claimedPlaytimeMilestoneMinutes, milestoneMinutes) ~= nil
end

return table.freeze(DailyProgressReader)
