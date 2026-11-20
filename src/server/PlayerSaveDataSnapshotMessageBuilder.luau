-- Builds the `PlayerSaveDataSnapshotChanged` message of development spec v1.3 §2.6 for ONE player
-- from what the server holds for that player. Pure logic: no Roblox-specific interface, no clock,
-- no state. PlayerSaveDataSnapshotPublisher decides WHEN to build and send it.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- PlayerSaveDataSnapshotMessageBuilder.SAVE_FIELD_NAMES_COPIED_INTO_SNAPSHOT_MESSAGE   (frozen list)
--   The save fields copied verbatim (deep copies) into the message:
--   fanCount, starCoinBalance, ownedDanceIds, equippedDanceId, ownedCosmeticIds,
--   equippedCosmeticIdByKind, lobbyOutfitStylingItemKeys, dailyProgress.
--   No other save field ever reaches the message: not the session lock, the schema version,
--   the timestamps, the promo code record, the round counters or anything unknown.
-- PlayerSaveDataSnapshotMessageBuilder.SNAPSHOT_MESSAGE_FIELD_NAMES   (frozen list)
--   Every field of the message: the list above plus unavailableLobbyOutfitStylingItemKeys,
--   todaysDailyQuestIds and isSaveDataPersistenceDelayed (exactly the eleven fields of §2.6).
--
-- PlayerSaveDataSnapshotMessageBuilder.buildPlayerSaveDataSnapshotMessage(snapshotMessageSources)
--     -> PlayerSaveDataSnapshotMessage
--   snapshotMessageSources = {
--     inMemorySaveData: PlayerSaveData,                  -- the player's in-memory save (read only)
--     unavailableLobbyOutfitStylingItemKeys: { string }, -- from StoredLobbyOutfitKeeper (may be frozen)
--     todaysDailyQuestIds: { string },                   -- from DailyQuestOfTheDaySelector (may be frozen)
--     isSaveDataPersistenceDelayed: boolean,             -- from PlayerSaveDataKeeper
--   }
--   Returns a FRESH plain table on every call: no table inside it is shared with the sources or
--   with an earlier message, and nothing in it is frozen, so a sender may modify it freely. A
--   save field that is absent stays absent (nil); its value is never invented here. Reads only;
--   changes nothing it is given. Raises (programming errors; an upstream fault is never hidden as
--   "nothing unavailable" or "no quests today") when `snapshotMessageSources` or
--   `inMemorySaveData` is not a table, when unavailableLobbyOutfitStylingItemKeys or
--   todaysDailyQuestIds is not a table, or when isSaveDataPersistenceDelayed is not a boolean.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local PlayerSaveDataSchema = require("./PlayerSaveDataSchema")

local createDeepCopyOfPlainTable = PlayerSaveDataSchema.createDeepCopyOfPlainTable

local PlayerSaveDataSnapshotMessageBuilder = {}

PlayerSaveDataSnapshotMessageBuilder.SAVE_FIELD_NAMES_COPIED_INTO_SNAPSHOT_MESSAGE = table.freeze({
	"fanCount",
	"starCoinBalance",
	"ownedDanceIds",
	"equippedDanceId",
	"ownedCosmeticIds",
	"equippedCosmeticIdByKind",
	"lobbyOutfitStylingItemKeys",
	"dailyProgress",
})

local UNAVAILABLE_LOBBY_OUTFIT_KEYS_FIELD_NAME = "unavailableLobbyOutfitStylingItemKeys"
local TODAYS_DAILY_QUEST_IDS_FIELD_NAME = "todaysDailyQuestIds"
local PERSISTENCE_DELAYED_FIELD_NAME = "isSaveDataPersistenceDelayed"

local function listEverySnapshotMessageFieldName(): { string }
	local snapshotMessageFieldNames =
		table.clone(PlayerSaveDataSnapshotMessageBuilder.SAVE_FIELD_NAMES_COPIED_INTO_SNAPSHOT_MESSAGE)
	table.insert(snapshotMessageFieldNames, UNAVAILABLE_LOBBY_OUTFIT_KEYS_FIELD_NAME)
	table.insert(snapshotMessageFieldNames, TODAYS_DAILY_QUEST_IDS_FIELD_NAME)
	table.insert(snapshotMessageFieldNames, PERSISTENCE_DELAYED_FIELD_NAME)
	return snapshotMessageFieldNames
end

PlayerSaveDataSnapshotMessageBuilder.SNAPSHOT_MESSAGE_FIELD_NAMES = table.freeze(listEverySnapshotMessageFieldName())

export type PlayerSaveDataSnapshotMessage = { [string]: any }

export type SnapshotMessageSources = {
	inMemorySaveData: any,
	unavailableLobbyOutfitStylingItemKeys: { string },
	todaysDailyQuestIds: { string },
	isSaveDataPersistenceDelayed: boolean,
}

-- Copies a list in order (ipairs), into a new unfrozen table. `sourceName` names the list in the
-- error raised for a value that is not a table.
local function copyListIntoUnfrozenList(originalList: any, sourceName: string): { any }
	if type(originalList) ~= "table" then
		error("PlayerSaveDataSnapshotMessageBuilder: " .. sourceName .. " must be a table", 3)
	end
	local copiedList = {}
	for _, listedValue in ipairs(originalList) do
		table.insert(copiedList, createDeepCopyOfPlainTable(listedValue))
	end
	return copiedList
end

function PlayerSaveDataSnapshotMessageBuilder.buildPlayerSaveDataSnapshotMessage(
	snapshotMessageSources: SnapshotMessageSources
): PlayerSaveDataSnapshotMessage
	if type(snapshotMessageSources) ~= "table" or type(snapshotMessageSources.inMemorySaveData) ~= "table" then
		error("PlayerSaveDataSnapshotMessageBuilder: inMemorySaveData must be a table", 2)
	end
	if type(snapshotMessageSources.isSaveDataPersistenceDelayed) ~= "boolean" then
		error("PlayerSaveDataSnapshotMessageBuilder: isSaveDataPersistenceDelayed must be a boolean", 2)
	end
	local inMemorySaveData = snapshotMessageSources.inMemorySaveData
	-- Fields are copied by name from the list above, so the message can only ever hold them.
	local snapshotMessage: PlayerSaveDataSnapshotMessage = {}
	for _, copiedSaveFieldName in PlayerSaveDataSnapshotMessageBuilder.SAVE_FIELD_NAMES_COPIED_INTO_SNAPSHOT_MESSAGE do
		snapshotMessage[copiedSaveFieldName] = createDeepCopyOfPlainTable(inMemorySaveData[copiedSaveFieldName])
	end
	snapshotMessage[UNAVAILABLE_LOBBY_OUTFIT_KEYS_FIELD_NAME] = copyListIntoUnfrozenList(
		snapshotMessageSources.unavailableLobbyOutfitStylingItemKeys,
		UNAVAILABLE_LOBBY_OUTFIT_KEYS_FIELD_NAME
	)
	snapshotMessage[TODAYS_DAILY_QUEST_IDS_FIELD_NAME] =
		copyListIntoUnfrozenList(snapshotMessageSources.todaysDailyQuestIds, TODAYS_DAILY_QUEST_IDS_FIELD_NAME)
	snapshotMessage[PERSISTENCE_DELAYED_FIELD_NAME] = snapshotMessageSources.isSaveDataPersistenceDelayed
	return snapshotMessage
end

return table.freeze(PlayerSaveDataSnapshotMessageBuilder)
