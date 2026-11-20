-- LobbySaveDataSnapshotReader (development spec §2.6 PlayerSaveDataSnapshotChanged, §1.10, §5.1): reads
-- the parts of the save snapshot the Phase 2 lobby screens show (owned and equipped dances and
-- cosmetics, the stored lobby outfit, today's daily progress and quests) into a checked plain table.
-- ⛔ §5.1 / §2.6 🔴: everything the player owns, has equipped, has earned or has claimed is shown
-- ONLY from this message; the lobby screens never compute or guess any of it.
-- A message whose shape is not the documented one reads as nil, and the caller keeps the previous
-- snapshot (as PlayerSaveDataStatusBarModel does with the balance). Fields the lobby does not use
-- are not copied. Every list returned is fresh.
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   LobbySaveDataSnapshotReader.readLobbySaveDataSnapshot(message) -> lobbySnapshot?
--   lobbySnapshot = {
--     shownStarCoinBalance: number,   (named "shown": the device only shows it, spec §3.3 sole writer)
--     ownedDanceIds: { string }, equippedDanceId: string?,
--     ownedCosmeticIds: { string }, equippedCosmeticIdByKind: { [cosmeticKind]: cosmeticId },
--     lobbyOutfitStylingItemKeys: { string }, unavailableLobbyOutfitStylingItemKeys: { string },
--     dailyProgress = { dailyDateKey, playtimeSecondsToday, claimedPlaytimeMilestoneMinutes = { number },
--                       dailyQuestProgressCountByQuestId = { [id]: number }, claimedDailyQuestIds = { string } },
--     todaysDailyQuestIds: { string },
--   }

local LobbySaveDataSnapshotReader = {}

local function isFiniteNumber(candidate: any): boolean
	return type(candidate) == "number" and candidate == candidate and math.abs(candidate) ~= math.huge
end

local function isString(candidate: any): boolean
	return type(candidate) == "string"
end

local function readListOf(candidateList: any, isEntryValid: (any) -> boolean): { any }?
	if type(candidateList) ~= "table" then
		return nil
	end
	local copiedList = {}
	for listPosition = 1, #candidateList do
		if not isEntryValid(candidateList[listPosition]) then
			return nil
		end
		copiedList[listPosition] = candidateList[listPosition]
	end
	return copiedList
end

local function readMapOf(candidateMap: any, isValueValid: (any) -> boolean): { [string]: any }?
	if type(candidateMap) ~= "table" then
		return nil
	end
	local copiedMap = {}
	for mapKey, mapValue in candidateMap do
		if type(mapKey) ~= "string" or not isValueValid(mapValue) then
			return nil
		end
		copiedMap[mapKey] = mapValue
	end
	return copiedMap
end

local function readDailyProgress(candidate: any)
	if type(candidate) ~= "table" or type(candidate.dailyDateKey) ~= "string" then
		return nil
	end
	if not isFiniteNumber(candidate.playtimeSecondsToday) then
		return nil
	end
	local claimedMinutes = readListOf(candidate.claimedPlaytimeMilestoneMinutes, isFiniteNumber)
	local progressCounts = readMapOf(candidate.dailyQuestProgressCountByQuestId, isFiniteNumber)
	local claimedQuestIds = readListOf(candidate.claimedDailyQuestIds, isString)
	if claimedMinutes == nil or progressCounts == nil or claimedQuestIds == nil then
		return nil
	end
	return {
		dailyDateKey = candidate.dailyDateKey,
		playtimeSecondsToday = candidate.playtimeSecondsToday,
		claimedPlaytimeMilestoneMinutes = claimedMinutes,
		dailyQuestProgressCountByQuestId = progressCounts,
		claimedDailyQuestIds = claimedQuestIds,
	}
end

function LobbySaveDataSnapshotReader.readLobbySaveDataSnapshot(message: any)
	if type(message) ~= "table" or not isFiniteNumber(message.starCoinBalance) then
		return nil
	end
	if message.equippedDanceId ~= nil and type(message.equippedDanceId) ~= "string" then
		return nil
	end
	local lobbySnapshot = {
		shownStarCoinBalance = message.starCoinBalance,
		equippedDanceId = message.equippedDanceId,
		ownedDanceIds = readListOf(message.ownedDanceIds, isString),
		ownedCosmeticIds = readListOf(message.ownedCosmeticIds, isString),
		equippedCosmeticIdByKind = readMapOf(message.equippedCosmeticIdByKind, isString),
		lobbyOutfitStylingItemKeys = readListOf(message.lobbyOutfitStylingItemKeys, isString),
		unavailableLobbyOutfitStylingItemKeys = readListOf(message.unavailableLobbyOutfitStylingItemKeys, isString),
		dailyProgress = readDailyProgress(message.dailyProgress),
		todaysDailyQuestIds = readListOf(message.todaysDailyQuestIds, isString),
	}
	for _, requiredFieldName in
		{
			"ownedDanceIds",
			"ownedCosmeticIds",
			"equippedCosmeticIdByKind",
			"lobbyOutfitStylingItemKeys",
			"unavailableLobbyOutfitStylingItemKeys",
			"dailyProgress",
			"todaysDailyQuestIds",
		}
	do
		if lobbySnapshot[requiredFieldName] == nil then
			return nil
		end
	end
	return lobbySnapshot
end

return table.freeze(LobbySaveDataSnapshotReader)
