local UnitTestFramework = require("../Support/UnitTestFramework")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local EXAMPLE_UNIX_SECONDS = 1_763_510_400 -- 2025-11-19 00:00:00 UTC

-- Every field of spec §1.10, copied by hand.
local SPEC_SAVE_DATA_FIELD_NAMES = {
	"saveDataSchemaVersion",
	"fanCount",
	"starCoinBalance",
	"totalRoundsCompletedCount",
	"bestStarCountByThemeId",
	"ownedDanceIds",
	"equippedDanceId",
	"ownedCosmeticIds",
	"equippedCosmeticIdByKind",
	"lobbyOutfitStylingItemKeys",
	"dailyProgress",
	"redeemedPromoCodeIds",
	"firstJoinedAtUnixSeconds",
	"lastSavedAtUnixSeconds",
}

describe("PlayerSaveDataSchema.createStartingPlayerSaveData", function()
	it("gives a new player zero fans and coins, every starter dance, and the first one equipped (§1.10)", function()
		local startingSaveData =
			PlayerSaveDataSchema.createStartingPlayerSaveData({ "starter_wave", "starter_step" }, EXAMPLE_UNIX_SECONDS)
		expect(startingSaveData).toEqual({
			saveDataSchemaVersion = 1,
			fanCount = 0,
			starCoinBalance = 0,
			totalRoundsCompletedCount = 0,
			bestStarCountByThemeId = {},
			ownedDanceIds = { "starter_wave", "starter_step" },
			equippedDanceId = "starter_wave",
			ownedCosmeticIds = {},
			equippedCosmeticIdByKind = {},
			lobbyOutfitStylingItemKeys = {},
			dailyProgress = {
				dailyDateKey = "2025-11-19",
				playtimeSecondsToday = 0,
				claimedPlaytimeMilestoneMinutes = {},
				dailyQuestProgressCountByQuestId = {},
				claimedDailyQuestIds = {},
			},
			redeemedPromoCodeIds = {},
			firstJoinedAtUnixSeconds = EXAMPLE_UNIX_SECONDS,
			lastSavedAtUnixSeconds = EXAMPLE_UNIX_SECONDS,
		})
	end)

	it("has exactly the spec §1.10 fields (the lock is added later by the keeper)", function()
		local startingSaveData =
			PlayerSaveDataSchema.createStartingPlayerSaveData({ "starter_wave" }, EXAMPLE_UNIX_SECONDS)
		local actualFieldNames = {}
		for fieldName in startingSaveData do
			table.insert(actualFieldNames, fieldName)
		end
		table.sort(actualFieldNames)
		local expectedFieldNames = table.clone(SPEC_SAVE_DATA_FIELD_NAMES)
		table.sort(expectedFieldNames)
		expect(actualFieldNames).toEqual(expectedFieldNames)
	end)

	it("does not share the caller's starter dance list", function()
		local starterDanceIds = { "starter_wave" }
		local startingSaveData =
			PlayerSaveDataSchema.createStartingPlayerSaveData(starterDanceIds, EXAMPLE_UNIX_SECONDS)
		table.insert(starterDanceIds, "added_later")
		expect(startingSaveData.ownedDanceIds).toEqual({ "starter_wave" })
	end)

	it("refuses to build a starting save without any starter dance", function()
		expect(function()
			PlayerSaveDataSchema.createStartingPlayerSaveData({}, EXAMPLE_UNIX_SECONDS)
		end).toThrow("at least one starter dance")
	end)
end)

describe("PlayerSaveDataSchema.formatUtcDailyDateKey", function()
	it("formats the UTC calendar date as YYYY-MM-DD", function()
		expect(PlayerSaveDataSchema.formatUtcDailyDateKey(0)).toBe("1970-01-01")
		expect(PlayerSaveDataSchema.formatUtcDailyDateKey(951_782_400)).toBe("2000-02-29")
		expect(PlayerSaveDataSchema.formatUtcDailyDateKey(EXAMPLE_UNIX_SECONDS)).toBe("2025-11-19")
		expect(PlayerSaveDataSchema.formatUtcDailyDateKey(1_798_675_200)).toBe("2026-12-31")
	end)

	it("changes exactly at UTC midnight", function()
		expect(PlayerSaveDataSchema.formatUtcDailyDateKey(EXAMPLE_UNIX_SECONDS - 0.001)).toBe("2025-11-18")
		expect(PlayerSaveDataSchema.formatUtcDailyDateKey(EXAMPLE_UNIX_SECONDS + 86399.999)).toBe("2025-11-19")
		expect(PlayerSaveDataSchema.formatUtcDailyDateKey(EXAMPLE_UNIX_SECONDS + 86400)).toBe("2025-11-20")
	end)

	it("agrees with the operating system's UTC calendar on random instants", function()
		for _ = 1, 500 do
			local randomUnixSeconds = math.random(0, 4_102_444_800) -- 1970 .. 2100
			expect(PlayerSaveDataSchema.formatUtcDailyDateKey(randomUnixSeconds)).toBe(
				os.date("!%Y-%m-%d", randomUnixSeconds)
			)
		end
	end)
end)

describe("PlayerSaveDataSchema.replaceDailyProgressIfDailyDateKeyChanged", function()
	local function createSaveWithProgressOn(dailyDateKey: string)
		local saveData = PlayerSaveDataSchema.createStartingPlayerSaveData({ "starter_wave" }, EXAMPLE_UNIX_SECONDS)
		saveData.dailyProgress = {
			dailyDateKey = dailyDateKey,
			playtimeSecondsToday = 900,
			claimedPlaytimeMilestoneMinutes = { 5, 10 },
			dailyQuestProgressCountByQuestId = { complete_rounds_5 = 3 },
			claimedDailyQuestIds = { "earn_stars_3" },
		}
		return saveData
	end

	it("keeps today's progress untouched on the same UTC day", function()
		local saveData = createSaveWithProgressOn("2025-11-19")
		local didReset =
			PlayerSaveDataSchema.replaceDailyProgressIfDailyDateKeyChanged(saveData, EXAMPLE_UNIX_SECONDS + 3600)
		expect(didReset).toBeFalse()
		expect(saveData.dailyProgress.playtimeSecondsToday).toBe(900)
		expect(saveData.dailyProgress.claimedPlaytimeMilestoneMinutes).toEqual({ 5, 10 })
	end)

	it("replaces the whole table with a fresh one when the UTC day changed", function()
		local saveData = createSaveWithProgressOn("2025-11-18")
		local didReset = PlayerSaveDataSchema.replaceDailyProgressIfDailyDateKeyChanged(saveData, EXAMPLE_UNIX_SECONDS)
		expect(didReset).toBeTrue()
		expect(saveData.dailyProgress).toEqual(PlayerSaveDataSchema.createFreshDailyProgress("2025-11-19"))
	end)

	it("creates fresh progress when the stored table is missing", function()
		local saveData = createSaveWithProgressOn("2025-11-19")
		saveData.dailyProgress = nil :: any
		expect(PlayerSaveDataSchema.replaceDailyProgressIfDailyDateKeyChanged(saveData, EXAMPLE_UNIX_SECONDS)).toBeTrue()
		expect(saveData.dailyProgress.dailyDateKey).toBe("2025-11-19")
	end)
end)

describe("PlayerSaveDataSchema.upgradeStoredPlayerSaveDataToCurrentSchema", function()
	local function createVersionOneSave()
		return PlayerSaveDataSchema.createStartingPlayerSaveData({ "starter_wave" }, EXAMPLE_UNIX_SECONDS)
	end

	it("accepts a version 1 save unchanged, as a separate copy", function()
		local storedSaveData = createVersionOneSave()
		local upgradedSaveData, refusalReason =
			PlayerSaveDataSchema.upgradeStoredPlayerSaveDataToCurrentSchema(storedSaveData)
		expect(refusalReason).toBeNil()
		expect(upgradedSaveData).toEqual(storedSaveData)
		expect(upgradedSaveData == storedSaveData).toBeFalse()
	end)

	it("refuses a save whose version is newer than this code understands", function()
		local storedSaveData = createVersionOneSave()
		storedSaveData.saveDataSchemaVersion = 2
		local upgradedSaveData, refusalReason =
			PlayerSaveDataSchema.upgradeStoredPlayerSaveDataToCurrentSchema(storedSaveData)
		expect(upgradedSaveData).toBeNil()
		expect(refusalReason).toBe("SchemaVersionNewerThanThisServerUnderstands")
	end)

	it("refuses a save without a usable version", function()
		local storedSaveData: any = createVersionOneSave()
		storedSaveData.saveDataSchemaVersion = nil
		expect(select(2, PlayerSaveDataSchema.upgradeStoredPlayerSaveDataToCurrentSchema(storedSaveData))).toBe(
			"SchemaVersionMissing"
		)
		expect(select(2, PlayerSaveDataSchema.upgradeStoredPlayerSaveDataToCurrentSchema("not a table"))).toBe(
			"SchemaVersionMissing"
		)
	end)

	it("runs the upgrade hook one version at a time and never edits the stored save", function()
		local storedSaveData: any = createVersionOneSave()
		local upgradersByFromVersion = {
			[1] = function(saveDataAtVersionOne)
				saveDataAtVersionOne.saveDataSchemaVersion = 2
				saveDataAtVersionOne.addedInVersionTwo = true
				return saveDataAtVersionOne
			end,
			[2] = function(saveDataAtVersionTwo)
				saveDataAtVersionTwo.saveDataSchemaVersion = 3
				saveDataAtVersionTwo.addedInVersionThree = true
				return saveDataAtVersionTwo
			end,
		}
		local upgradedSaveData: any =
			PlayerSaveDataSchema.upgradeStoredPlayerSaveDataToCurrentSchema(storedSaveData, upgradersByFromVersion, 3)
		expect(upgradedSaveData.saveDataSchemaVersion).toBe(3)
		expect(upgradedSaveData.addedInVersionTwo).toBeTrue()
		expect(upgradedSaveData.addedInVersionThree).toBeTrue()
		expect(storedSaveData.saveDataSchemaVersion).toBe(1)
		expect(storedSaveData.addedInVersionTwo).toBeNil()
	end)

	it("refuses when an upgrader is missing or skips a version", function()
		local storedSaveData = createVersionOneSave()
		expect(select(2, PlayerSaveDataSchema.upgradeStoredPlayerSaveDataToCurrentSchema(storedSaveData, {}, 2))).toBe(
			"SchemaUpgraderMissing"
		)
		local skippingUpgraders = {
			[1] = function(saveDataAtVersionOne)
				saveDataAtVersionOne.saveDataSchemaVersion = 3
				return saveDataAtVersionOne
			end,
		}
		expect(
			select(
				2,
				PlayerSaveDataSchema.upgradeStoredPlayerSaveDataToCurrentSchema(storedSaveData, skippingUpgraders, 3)
			)
		).toBe("SchemaUpgraderProducedWrongVersion")
	end)
end)

describe("PlayerSaveDataSchema deep copy and comparison", function()
	it("copies nested tables so editing the copy leaves the original untouched", function()
		local originalTable = { nestedList = { 1, 2 }, nestedMap = { y2k_pop = 3 } }
		local copiedTable = PlayerSaveDataSchema.createDeepCopyOfPlainTable(originalTable)
		copiedTable.nestedList[1] = 99
		copiedTable.nestedMap.y2k_pop = 4
		expect(originalTable).toEqual({ nestedList = { 1, 2 }, nestedMap = { y2k_pop = 3 } })
	end)

	it("compares content, not identity, in both directions", function()
		local areEqual = PlayerSaveDataSchema.arePlainValuesDeeplyEqual
		expect(areEqual({ a = { 1, 2 } }, { a = { 1, 2 } })).toBeTrue()
		expect(areEqual({ a = { 1, 2 } }, { a = { 1, 3 } })).toBeFalse()
		expect(areEqual({ a = 1 }, { a = 1, b = 2 })).toBeFalse()
		expect(areEqual({ a = 1, b = 2 }, { a = 1 })).toBeFalse()
		expect(areEqual({}, {})).toBeTrue()
		expect(areEqual(1, "1")).toBeFalse()
	end)
end)
