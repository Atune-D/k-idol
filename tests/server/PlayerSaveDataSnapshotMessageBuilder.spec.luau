-- PlayerSaveDataSnapshotMessageBuilder: the exact field set of development spec v1.3 §2.6, values
-- copied from the save, and a fresh unfrozen table every time.

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local PlayerSaveDataSnapshotMessageBuilder = require("../../src/server/PlayerSaveDataSnapshotMessageBuilder")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local buildPlayerSaveDataSnapshotMessage = PlayerSaveDataSnapshotMessageBuilder.buildPlayerSaveDataSnapshotMessage

-- Spec §2.6, written out here independently of the module's own lists.
local SPEC_SNAPSHOT_MESSAGE_FIELD_NAMES = {
	"fanCount",
	"starCoinBalance",
	"ownedDanceIds",
	"equippedDanceId",
	"ownedCosmeticIds",
	"equippedCosmeticIdByKind",
	"lobbyOutfitStylingItemKeys",
	"unavailableLobbyOutfitStylingItemKeys",
	"dailyProgress",
	"todaysDailyQuestIds",
	"isSaveDataPersistenceDelayed",
}

local function listSortedKeys(inspectedTable: { [any]: any }): { string }
	local sortedKeys = {}
	for tableKey in inspectedTable do
		table.insert(sortedKeys, tostring(tableKey))
	end
	table.sort(sortedKeys)
	return sortedKeys
end

local function listSortedNames(fieldNames: { string }): { string }
	local sortedNames = table.clone(fieldNames)
	table.sort(sortedNames)
	return sortedNames
end

-- A save holding every §1.10 field, the session lock and a field this code does not know.
local function createFullExampleSave()
	local exampleSave =
		PlayerSaveDataSchema.createStartingPlayerSaveData({ "starter_wave", "starter_step" }, 1_795_000_000)
	exampleSave.fanCount = 1240
	exampleSave.starCoinBalance = 430
	exampleSave.totalRoundsCompletedCount = 15
	exampleSave.bestStarCountByThemeId = { y2k_pop = 4 }
	exampleSave.ownedCosmeticIds = { "cosmetic_sparkle_trail" }
	exampleSave.equippedCosmeticIdByKind = { trail = "cosmetic_sparkle_trail" }
	exampleSave.lobbyOutfitStylingItemKeys = { "asset_9000011", "bundle_9000041" }
	exampleSave.dailyProgress.playtimeSecondsToday = 600
	exampleSave.dailyProgress.claimedPlaytimeMilestoneMinutes = { 5 }
	exampleSave.dailyProgress.dailyQuestProgressCountByQuestId = { quest_a = 2 }
	exampleSave.redeemedPromoCodeIds = { "launch_code" }
	exampleSave.gameServerSessionLock = { sessionLockId = "lock-1", lockRefreshedAtUnixSeconds = 1_795_000_000 }
	exampleSave.someFutureFieldNobodyListed = { secret = true }
	return exampleSave
end

local function createExampleSources(inMemorySaveData)
	return {
		inMemorySaveData = inMemorySaveData,
		unavailableLobbyOutfitStylingItemKeys = table.freeze({ "asset_9000005" }),
		todaysDailyQuestIds = DailyQuestTestCatalog.TODAYS_TEST_DAILY_QUEST_IDS,
		isSaveDataPersistenceDelayed = true,
	}
end

describe("PlayerSaveDataSnapshotMessageBuilder field set (§2.6)", function()
	it("the declared field list is exactly the eleven fields of §2.6", function()
		expect(listSortedNames(PlayerSaveDataSnapshotMessageBuilder.SNAPSHOT_MESSAGE_FIELD_NAMES)).toEqual(
			listSortedNames(SPEC_SNAPSHOT_MESSAGE_FIELD_NAMES)
		)
		expect(table.isfrozen(PlayerSaveDataSnapshotMessageBuilder.SNAPSHOT_MESSAGE_FIELD_NAMES)).toBeTrue()
		expect(table.isfrozen(PlayerSaveDataSnapshotMessageBuilder.SAVE_FIELD_NAMES_COPIED_INTO_SNAPSHOT_MESSAGE)).toBeTrue()
	end)

	it("a message built from a full save has exactly those keys: no other save field leaks", function()
		local snapshotMessage = buildPlayerSaveDataSnapshotMessage(createExampleSources(createFullExampleSave()))
		expect(listSortedKeys(snapshotMessage)).toEqual(listSortedNames(SPEC_SNAPSHOT_MESSAGE_FIELD_NAMES))
	end)

	it("copies each save field's value and passes the three server-computed fields", function()
		local exampleSave = createFullExampleSave()
		local snapshotMessage = buildPlayerSaveDataSnapshotMessage(createExampleSources(exampleSave))
		expect(snapshotMessage).toEqual({
			fanCount = 1240,
			starCoinBalance = 430,
			ownedDanceIds = { "starter_wave", "starter_step" },
			equippedDanceId = "starter_wave",
			ownedCosmeticIds = { "cosmetic_sparkle_trail" },
			equippedCosmeticIdByKind = { trail = "cosmetic_sparkle_trail" },
			lobbyOutfitStylingItemKeys = { "asset_9000011", "bundle_9000041" },
			unavailableLobbyOutfitStylingItemKeys = { "asset_9000005" },
			dailyProgress = exampleSave.dailyProgress,
			todaysDailyQuestIds = { "quest_a", "quest_d", "quest_e" },
			isSaveDataPersistenceDelayed = true,
		})
	end)

	it("leaves a save field that is absent absent instead of inventing a value", function()
		local exampleSave = createFullExampleSave()
		exampleSave.equippedDanceId = nil
		local snapshotMessage = buildPlayerSaveDataSnapshotMessage(createExampleSources(exampleSave))
		expect(snapshotMessage.equippedDanceId).toBeNil()
	end)
end)

describe("PlayerSaveDataSnapshotMessageBuilder fresh tables", function()
	it("shares no table with the save: editing the message leaves the save unchanged", function()
		local exampleSave = createFullExampleSave()
		local untouchedSave = PlayerSaveDataSchema.createDeepCopyOfPlainTable(exampleSave)
		local snapshotMessage = buildPlayerSaveDataSnapshotMessage(createExampleSources(exampleSave))
		table.insert(snapshotMessage.ownedDanceIds, "stolen_dance")
		table.insert(snapshotMessage.ownedCosmeticIds, "stolen_cosmetic")
		snapshotMessage.equippedCosmeticIdByKind.trail = "other"
		table.insert(snapshotMessage.lobbyOutfitStylingItemKeys, "asset_9000051")
		snapshotMessage.dailyProgress.claimedPlaytimeMilestoneMinutes[1] = 60
		snapshotMessage.dailyProgress.dailyQuestProgressCountByQuestId.quest_a = 99
		expect(exampleSave).toEqual(untouchedSave)
	end)

	it("copies frozen source lists into unfrozen lists the sender may modify", function()
		local exampleSources = createExampleSources(createFullExampleSave())
		local snapshotMessage = buildPlayerSaveDataSnapshotMessage(exampleSources)
		expect(table.isfrozen(snapshotMessage)).toBeFalse()
		expect(table.isfrozen(snapshotMessage.unavailableLobbyOutfitStylingItemKeys)).toBeFalse()
		expect(table.isfrozen(snapshotMessage.todaysDailyQuestIds)).toBeFalse()
		table.insert(snapshotMessage.unavailableLobbyOutfitStylingItemKeys, "x")
		table.insert(snapshotMessage.todaysDailyQuestIds, "y")
		expect(exampleSources.unavailableLobbyOutfitStylingItemKeys).toEqual({ "asset_9000005" })
		expect(exampleSources.todaysDailyQuestIds).toEqual({ "quest_a", "quest_d", "quest_e" })
	end)

	it("copies unfrozen source lists too, so editing the message cannot reach them", function()
		local exampleSources = createExampleSources(createFullExampleSave())
		exampleSources.unavailableLobbyOutfitStylingItemKeys = { "asset_9000005" }
		exampleSources.todaysDailyQuestIds = { "quest_a", "quest_d", "quest_e" }
		local snapshotMessage = buildPlayerSaveDataSnapshotMessage(exampleSources)
		snapshotMessage.unavailableLobbyOutfitStylingItemKeys[1] = "changed"
		snapshotMessage.todaysDailyQuestIds[1] = "changed"
		expect(exampleSources.unavailableLobbyOutfitStylingItemKeys).toEqual({ "asset_9000005" })
		expect(exampleSources.todaysDailyQuestIds).toEqual({ "quest_a", "quest_d", "quest_e" })
	end)

	it("two builds from the same sources share no table", function()
		local exampleSources = createExampleSources(createFullExampleSave())
		local firstMessage = buildPlayerSaveDataSnapshotMessage(exampleSources)
		local secondMessage = buildPlayerSaveDataSnapshotMessage(exampleSources)
		expect(firstMessage == secondMessage).toBeFalse()
		for fieldName, firstFieldValue in firstMessage do
			if type(firstFieldValue) == "table" then
				expect({ fieldName, firstFieldValue == secondMessage[fieldName] }).toEqual({ fieldName, false })
			end
		end
	end)
end)

describe("PlayerSaveDataSnapshotMessageBuilder programming errors", function()
	it("raises when the save is not a table", function()
		expect(function()
			buildPlayerSaveDataSnapshotMessage({
				inMemorySaveData = nil,
				unavailableLobbyOutfitStylingItemKeys = {},
				todaysDailyQuestIds = {},
				isSaveDataPersistenceDelayed = false,
			} :: any)
		end).toThrow("inMemorySaveData must be a table")
		expect(function()
			buildPlayerSaveDataSnapshotMessage(nil :: any)
		end).toThrow("inMemorySaveData must be a table")
	end)

	it("raises when isSaveDataPersistenceDelayed is not a boolean", function()
		local exampleSources = createExampleSources(createFullExampleSave())
		exampleSources.isSaveDataPersistenceDelayed = nil :: any
		expect(function()
			buildPlayerSaveDataSnapshotMessage(exampleSources)
		end).toThrow("isSaveDataPersistenceDelayed must be a boolean")
	end)

	it("raises when a server-computed list is missing or not a table (never hidden as an empty list)", function()
		for _, listSourceName in { "unavailableLobbyOutfitStylingItemKeys", "todaysDailyQuestIds" } do
			for _, unusableListCase in { { value = nil }, { value = "not a list" }, { value = 7 }, { value = false } } do
				local exampleSources = createExampleSources(createFullExampleSave())
				exampleSources[listSourceName] = unusableListCase.value
				expect(function()
					buildPlayerSaveDataSnapshotMessage(exampleSources)
				end).toThrow(listSourceName .. " must be a table")
			end
		end
	end)
end)

describe("PlayerSaveDataSnapshotMessageBuilder randomized saves", function()
	local SAVE_FIELD_NAMES_NOT_IN_MESSAGE = {
		"saveDataSchemaVersion",
		"totalRoundsCompletedCount",
		"bestStarCountByThemeId",
		"redeemedPromoCodeIds",
		"firstJoinedAtUnixSeconds",
		"lastSavedAtUnixSeconds",
		"gameServerSessionLock",
	}

	local function createRandomIdList(randomNumberGenerator, idPrefix: string): { string }
		local randomIds = {}
		for idNumber = 1, randomNumberGenerator.nextWholeNumberInRange(0, 5) do
			table.insert(
				randomIds,
				idPrefix .. tostring(idNumber * randomNumberGenerator.nextWholeNumberInRange(1, 99))
			)
		end
		return randomIds
	end

	it("every random save gives exactly the §2.6 keys with values equal to the save's", function()
		SeededRandomTrials.runSeededRandomTrials(200, function(randomNumberGenerator)
			local randomSave = PlayerSaveDataSchema.createStartingPlayerSaveData(
				{ "starter_wave" },
				randomNumberGenerator.nextWholeNumberInRange(1_600_000_000, 2_000_000_000)
			)
			randomSave.fanCount = randomNumberGenerator.nextWholeNumberInRange(0, 1_000_000)
			randomSave.starCoinBalance = randomNumberGenerator.nextWholeNumberInRange(0, 1_000_000)
			randomSave.ownedDanceIds = createRandomIdList(randomNumberGenerator, "dance_")
			randomSave.ownedCosmeticIds = createRandomIdList(randomNumberGenerator, "cosmetic_")
			randomSave.lobbyOutfitStylingItemKeys = createRandomIdList(randomNumberGenerator, "asset_")
			randomSave.redeemedPromoCodeIds = createRandomIdList(randomNumberGenerator, "code_")
			randomSave.gameServerSessionLock = {
				sessionLockId = "lock",
				lockRefreshedAtUnixSeconds = randomNumberGenerator.nextWholeNumberInRange(0, 9),
			}
			for extraFieldNumber = 1, randomNumberGenerator.nextWholeNumberInRange(0, 3) do
				randomSave["unlistedField" .. tostring(extraFieldNumber)] = extraFieldNumber
			end
			local unavailableKeys = createRandomIdList(randomNumberGenerator, "asset_")
			local questIds = createRandomIdList(randomNumberGenerator, "quest_")
			local isDelayed = randomNumberGenerator.nextWholeNumberInRange(0, 1) == 1

			local snapshotMessage = buildPlayerSaveDataSnapshotMessage({
				inMemorySaveData = randomSave,
				unavailableLobbyOutfitStylingItemKeys = unavailableKeys,
				todaysDailyQuestIds = questIds,
				isSaveDataPersistenceDelayed = isDelayed,
			})
			expect(listSortedKeys(snapshotMessage)).toEqual(listSortedNames(SPEC_SNAPSHOT_MESSAGE_FIELD_NAMES))
			for _, savedFieldName in SPEC_SNAPSHOT_MESSAGE_FIELD_NAMES do
				if randomSave[savedFieldName] ~= nil then
					expect({ savedFieldName, snapshotMessage[savedFieldName] }).toEqual({
						savedFieldName,
						randomSave[savedFieldName],
					})
				end
			end
			for _, hiddenFieldName in SAVE_FIELD_NAMES_NOT_IN_MESSAGE do
				expect({ hiddenFieldName, snapshotMessage[hiddenFieldName] }).toEqual({ hiddenFieldName, nil })
			end
			expect(snapshotMessage.unavailableLobbyOutfitStylingItemKeys).toEqual(unavailableKeys)
			expect(snapshotMessage.todaysDailyQuestIds).toEqual(questIds)
			expect(snapshotMessage.isSaveDataPersistenceDelayed).toBe(isDelayed)
		end)
	end)
end)
