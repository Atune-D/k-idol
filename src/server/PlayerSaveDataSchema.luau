-- The shape of a player's save (development spec §1.10) as pure logic: the starting save for a
-- new player, the UTC daily date key, the daily reset rule, schema-version handling, and the
-- deep copy / deep comparison the archivist uses on plain save tables.
--
-- Calls no Roblox-specific interface. The current time is always passed in by the caller.
--
-- Schema versions: Phase 1 has only version 1. When the save structure changes, raise
-- CURRENT_SAVE_DATA_SCHEMA_VERSION by one and add an upgrader to
-- SAVE_DATA_SCHEMA_UPGRADERS_BY_FROM_VERSION[oldVersion] that turns a save of `oldVersion` into
-- one of `oldVersion + 1`. A stored save whose version is newer than this code understands is
-- refused, never rewritten (PlayerSaveDataKeeper leaves it untouched in storage).

local PlayerSaveDataSchema = {}

PlayerSaveDataSchema.CURRENT_SAVE_DATA_SCHEMA_VERSION = 1

-- [fromSchemaVersion] = function(saveDataAtFromVersion) -> saveDataAtFromVersionPlusOne.
-- Empty in Phase 1 (there is only version 1).
PlayerSaveDataSchema.SAVE_DATA_SCHEMA_UPGRADERS_BY_FROM_VERSION = {} :: { [number]: (any) -> any }

local SECONDS_PER_DAY = 86400

export type DailyProgress = {
	dailyDateKey: string,
	playtimeSecondsToday: number,
	claimedPlaytimeMilestoneMinutes: { number },
	dailyQuestProgressCountByQuestId: { [string]: number },
	claimedDailyQuestIds: { string },
}

export type GameServerSessionLock = {
	sessionLockId: string,
	lockRefreshedAtUnixSeconds: number,
}

export type PlayerSaveData = {
	saveDataSchemaVersion: number,
	fanCount: number,
	starCoinBalance: number,
	totalRoundsCompletedCount: number,
	bestStarCountByThemeId: { [string]: number },
	ownedDanceIds: { string },
	equippedDanceId: string,
	ownedCosmeticIds: { string },
	equippedCosmeticIdByKind: { [string]: string },
	lobbyOutfitStylingItemKeys: { string },
	dailyProgress: DailyProgress,
	redeemedPromoCodeIds: { string },
	firstJoinedAtUnixSeconds: number,
	lastSavedAtUnixSeconds: number,
	gameServerSessionLock: GameServerSessionLock?,
}

-- Copies nested plain tables (no metatables, no cycles). Saves are plain data, so this is enough.
-- The copy is never frozen, even when the original is.
function PlayerSaveDataSchema.createDeepCopyOfPlainTable<T>(originalPlainTable: T): T
	if type(originalPlainTable) ~= "table" then
		return originalPlainTable
	end
	local copiedPlainTable = {}
	for copiedKey, copiedValue in originalPlainTable :: any do
		copiedPlainTable[PlayerSaveDataSchema.createDeepCopyOfPlainTable(copiedKey)] =
			PlayerSaveDataSchema.createDeepCopyOfPlainTable(copiedValue)
	end
	return copiedPlainTable :: any
end

-- True when two plain values hold the same content: same keys, deeply equal values.
function PlayerSaveDataSchema.arePlainValuesDeeplyEqual(firstPlainValue: any, secondPlainValue: any): boolean
	if firstPlainValue == secondPlainValue then
		return true
	end
	if type(firstPlainValue) ~= "table" or type(secondPlainValue) ~= "table" then
		return false
	end
	for comparedKey, firstNestedValue in firstPlainValue do
		if not PlayerSaveDataSchema.arePlainValuesDeeplyEqual(firstNestedValue, secondPlainValue[comparedKey]) then
			return false
		end
	end
	for comparedKey in secondPlainValue do
		if firstPlainValue[comparedKey] == nil then
			return false
		end
	end
	return true
end

-- Converts a count of days since 1970-01-01 to a proleptic Gregorian (year, month, day).
-- Algorithm "civil_from_days" by Howard Hinnant (public domain), using floor division.
local function convertDaysSinceUnixEpochToCivilDate(daysSinceUnixEpoch: number): (number, number, number)
	local shiftedDayCount = daysSinceUnixEpoch + 719468
	local eraIndex = shiftedDayCount // 146097
	local dayOfEra = shiftedDayCount - eraIndex * 146097
	local yearOfEra = (dayOfEra - dayOfEra // 1460 + dayOfEra // 36524 - dayOfEra // 146096) // 365
	local dayOfYearStartingInMarch = dayOfEra - (365 * yearOfEra + yearOfEra // 4 - yearOfEra // 100)
	local monthIndexStartingInMarch = (5 * dayOfYearStartingInMarch + 2) // 153
	local dayOfMonth = dayOfYearStartingInMarch - (153 * monthIndexStartingInMarch + 2) // 5 + 1
	local monthOfYear = if monthIndexStartingInMarch < 10
		then monthIndexStartingInMarch + 3
		else monthIndexStartingInMarch - 9
	local calendarYear = yearOfEra + eraIndex * 400 + (if monthOfYear <= 2 then 1 else 0)
	return calendarYear, monthOfYear, dayOfMonth
end

-- The UTC calendar date of `unixSeconds` as "YYYY-MM-DD" (spec §1.8 `dailyDateKey`).
function PlayerSaveDataSchema.formatUtcDailyDateKey(unixSeconds: number): string
	local daysSinceUnixEpoch = math.floor(unixSeconds / SECONDS_PER_DAY)
	local calendarYear, monthOfYear, dayOfMonth = convertDaysSinceUnixEpochToCivilDate(daysSinceUnixEpoch)
	return string.format("%04d-%02d-%02d", calendarYear, monthOfYear, dayOfMonth)
end

function PlayerSaveDataSchema.createFreshDailyProgress(dailyDateKey: string): DailyProgress
	return {
		dailyDateKey = dailyDateKey,
		playtimeSecondsToday = 0,
		claimedPlaytimeMilestoneMinutes = {},
		dailyQuestProgressCountByQuestId = {},
		claimedDailyQuestIds = {},
	}
end

-- The save a brand-new player starts with (spec §1.10). `starterDanceIds` are the ids of every
-- dance whose `isGrantedToNewPlayers` is true, in catalog order; the first one is equipped.
-- The caller (server wiring) reads them from DanceCatalog, so this module does not depend on it.
-- `gameServerSessionLock` is absent; PlayerSaveDataKeeper adds its own lock when it stores the save.
function PlayerSaveDataSchema.createStartingPlayerSaveData(
	starterDanceIds: { string },
	currentUnixSeconds: number
): PlayerSaveData
	if type(starterDanceIds) ~= "table" or type(starterDanceIds[1]) ~= "string" then
		error("PlayerSaveDataSchema: a new player needs at least one starter dance id", 2)
	end
	if type(currentUnixSeconds) ~= "number" then
		error("PlayerSaveDataSchema: currentUnixSeconds must be a number", 2)
	end
	return {
		saveDataSchemaVersion = PlayerSaveDataSchema.CURRENT_SAVE_DATA_SCHEMA_VERSION,
		fanCount = 0,
		starCoinBalance = 0,
		totalRoundsCompletedCount = 0,
		bestStarCountByThemeId = {},
		ownedDanceIds = table.clone(starterDanceIds),
		equippedDanceId = starterDanceIds[1],
		ownedCosmeticIds = {},
		equippedCosmeticIdByKind = {},
		lobbyOutfitStylingItemKeys = {},
		dailyProgress = PlayerSaveDataSchema.createFreshDailyProgress(
			PlayerSaveDataSchema.formatUtcDailyDateKey(currentUnixSeconds)
		),
		redeemedPromoCodeIds = {},
		firstJoinedAtUnixSeconds = currentUnixSeconds,
		lastSavedAtUnixSeconds = currentUnixSeconds,
		gameServerSessionLock = nil,
	}
end

-- Daily reset rule (spec §1.10): when today's UTC date key differs from the stored one, the whole
-- `dailyProgress` table is replaced by a fresh one. Mutates `saveData`; returns whether it reset.
function PlayerSaveDataSchema.replaceDailyProgressIfDailyDateKeyChanged(
	saveData: PlayerSaveData,
	currentUnixSeconds: number
): boolean
	local currentDailyDateKey = PlayerSaveDataSchema.formatUtcDailyDateKey(currentUnixSeconds)
	local storedDailyProgress = saveData.dailyProgress
	if type(storedDailyProgress) == "table" and storedDailyProgress.dailyDateKey == currentDailyDateKey then
		return false
	end
	saveData.dailyProgress = PlayerSaveDataSchema.createFreshDailyProgress(currentDailyDateKey)
	return true
end

export type SchemaUpgradeRefusalReason =
	"SchemaVersionMissing"
	| "SchemaVersionNewerThanThisServerUnderstands"
	| "SchemaUpgraderMissing"
	| "SchemaUpgraderProducedWrongVersion"

-- Brings a stored save up to `targetSchemaVersion` (default: CURRENT_SAVE_DATA_SCHEMA_VERSION).
-- Returns (upgradedSaveData, nil) or (nil, refusalReason). Never modifies `storedSaveData`.
-- `upgradersByFromVersion` and `targetSchemaVersion` are parameters only so tests can exercise the
-- upgrade path while Phase 1 has a single version.
function PlayerSaveDataSchema.upgradeStoredPlayerSaveDataToCurrentSchema(
	storedSaveData: any,
	upgradersByFromVersion: { [number]: (any) -> any }?,
	targetSchemaVersion: number?
): (PlayerSaveData?, SchemaUpgradeRefusalReason?)
	local effectiveUpgradersByFromVersion = upgradersByFromVersion
		or PlayerSaveDataSchema.SAVE_DATA_SCHEMA_UPGRADERS_BY_FROM_VERSION
	local effectiveTargetSchemaVersion = targetSchemaVersion or PlayerSaveDataSchema.CURRENT_SAVE_DATA_SCHEMA_VERSION

	local storedSchemaVersion = if type(storedSaveData) == "table" then storedSaveData.saveDataSchemaVersion else nil
	if type(storedSchemaVersion) ~= "number" or storedSchemaVersion < 1 or storedSchemaVersion % 1 ~= 0 then
		return nil, "SchemaVersionMissing"
	end
	if storedSchemaVersion > effectiveTargetSchemaVersion then
		return nil, "SchemaVersionNewerThanThisServerUnderstands"
	end

	local upgradingSaveData = PlayerSaveDataSchema.createDeepCopyOfPlainTable(storedSaveData)
	while upgradingSaveData.saveDataSchemaVersion < effectiveTargetSchemaVersion do
		local fromSchemaVersion = upgradingSaveData.saveDataSchemaVersion
		local upgradeOneSchemaVersion = effectiveUpgradersByFromVersion[fromSchemaVersion]
		if upgradeOneSchemaVersion == nil then
			return nil, "SchemaUpgraderMissing"
		end
		upgradingSaveData = upgradeOneSchemaVersion(upgradingSaveData)
		if type(upgradingSaveData) ~= "table" or upgradingSaveData.saveDataSchemaVersion ~= fromSchemaVersion + 1 then
			return nil, "SchemaUpgraderProducedWrongVersion"
		end
	end
	return upgradingSaveData, nil
end

return PlayerSaveDataSchema
