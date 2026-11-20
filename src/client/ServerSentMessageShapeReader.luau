-- ServerSentMessageShapeReader (development spec §2.1, §2.3, §2.5, §2.6, §2.14): reads what the
-- server sends on its five channels into checked plain tables, so the rest of the device code can
-- rely on field types. The server is trusted, but a message of an unexpected shape (an older or
-- newer server, a bug) must never break the device: a message that does not have the documented
-- shape reads as nil and the caller ignores it. Fields the device does not use are not copied.
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API (each returns a fresh table, or nil when the shape is wrong)
--   readRoundStateChangedMessage(message) -> { roundId, roundPhase, phaseEndsAtUnixMilliseconds,
--       themeId, roundBonusRule = { roundBonusKind, bonusColorTag?, bonusStyleTag? },
--       participantUserIds = { number } }
--   readRoundOutfitDraftAcknowledgedMessage(message) -> { roundId, outfitDraftSequenceNumber,
--       isKept, rejectionReason? }
--   readRoundResultsPublishedMessage(message) -> { roundId, roundResults = { entry } }, entries in
--       the order sent (highest score first, §2.5); an entry with a wrong shape makes the whole
--       message nil (showing part of a result list would mislead).
--   readPlayerSaveDataSnapshotMessage(message) -> { shownFanCount, shownStarCoinBalance,
--       isSaveDataPersistenceDelayed, unavailableLobbyOutfitStylingItemKeys = { string } }
--   readWardrobeCatalogChangedMessage(message) -> { isWardrobeCatalogReady, wardrobeCatalogVersion }

local ThemedRoundProtocol = require("../shared/ThemedRoundProtocol")

local ServerSentMessageShapeReader = {}

local function isFiniteNumber(candidate: any): boolean
	return type(candidate) == "number" and candidate == candidate and math.abs(candidate) ~= math.huge
end

local function isNonEmptyString(candidate: any): boolean
	return type(candidate) == "string" and candidate ~= ""
end

local function readListOf(candidateList: any, isEntryValid: (any) -> boolean): { any }?
	if type(candidateList) ~= "table" then
		return nil
	end
	local copiedList = {}
	for listPosition = 1, #candidateList do
		local entry = candidateList[listPosition]
		if not isEntryValid(entry) then
			return nil
		end
		copiedList[listPosition] = entry
	end
	return copiedList
end

function ServerSentMessageShapeReader.readRoundStateChangedMessage(message: any)
	if type(message) ~= "table" or not isNonEmptyString(message.roundId) then
		return nil
	end
	if not ThemedRoundProtocol.isKnownRoundPhase(message.roundPhase) then
		return nil
	end
	if not isFiniteNumber(message.phaseEndsAtUnixMilliseconds) or not isNonEmptyString(message.themeId) then
		return nil
	end
	local bonusRule = message.roundBonusRule
	if type(bonusRule) ~= "table" or not isNonEmptyString(bonusRule.roundBonusKind) then
		return nil
	end
	local participantUserIds = readListOf(message.participantUserIds, isFiniteNumber)
	if participantUserIds == nil then
		return nil
	end
	return {
		roundId = message.roundId,
		roundPhase = message.roundPhase,
		phaseEndsAtUnixMilliseconds = message.phaseEndsAtUnixMilliseconds,
		themeId = message.themeId,
		roundBonusRule = {
			roundBonusKind = bonusRule.roundBonusKind,
			bonusColorTag = if type(bonusRule.bonusColorTag) == "string" then bonusRule.bonusColorTag else nil,
			bonusStyleTag = if type(bonusRule.bonusStyleTag) == "string" then bonusRule.bonusStyleTag else nil,
		},
		participantUserIds = participantUserIds,
	}
end

function ServerSentMessageShapeReader.readRoundOutfitDraftAcknowledgedMessage(message: any)
	if type(message) ~= "table" or not isNonEmptyString(message.roundId) then
		return nil
	end
	if not isFiniteNumber(message.outfitDraftSequenceNumber) or type(message.isKept) ~= "boolean" then
		return nil
	end
	return {
		roundId = message.roundId,
		outfitDraftSequenceNumber = message.outfitDraftSequenceNumber,
		isKept = message.isKept,
		rejectionReason = if type(message.rejectionReason) == "string" then message.rejectionReason else nil,
	}
end

local RESULT_ENTRY_NUMBER_FIELD_NAMES = table.freeze({
	"playerUserId",
	"outfitScore",
	"themeMatchPoints",
	"completenessPoints",
	"colorHarmonyPoints",
	"roundBonusPoints",
	"starCount",
	"starCoinsGranted",
	"fanCountGained",
})

local function readRoundResultEntry(entry: any)
	if type(entry) ~= "table" or type(entry.playerDisplayName) ~= "string" then
		return nil
	end
	if type(entry.isNewBestStarCountForTheme) ~= "boolean" then
		return nil
	end
	local copiedEntry = {
		playerDisplayName = entry.playerDisplayName,
		isNewBestStarCountForTheme = entry.isNewBestStarCountForTheme,
	}
	for _, fieldName in RESULT_ENTRY_NUMBER_FIELD_NAMES do
		if not isFiniteNumber(entry[fieldName]) then
			return nil
		end
		copiedEntry[fieldName] = entry[fieldName]
	end
	return copiedEntry
end

function ServerSentMessageShapeReader.readRoundResultsPublishedMessage(message: any)
	if type(message) ~= "table" or not isNonEmptyString(message.roundId) or type(message.roundResults) ~= "table" then
		return nil
	end
	local roundResults = {}
	for listPosition = 1, #message.roundResults do
		local copiedEntry = readRoundResultEntry(message.roundResults[listPosition])
		if copiedEntry == nil then
			return nil
		end
		roundResults[listPosition] = copiedEntry
	end
	return { roundId = message.roundId, roundResults = roundResults }
end

function ServerSentMessageShapeReader.readPlayerSaveDataSnapshotMessage(message: any)
	if
		type(message) ~= "table"
		or not isFiniteNumber(message.fanCount)
		or not isFiniteNumber(message.starCoinBalance)
	then
		return nil
	end
	if type(message.isSaveDataPersistenceDelayed) ~= "boolean" then
		return nil
	end
	local unavailableKeys = readListOf(message.unavailableLobbyOutfitStylingItemKeys, function(entry)
		return type(entry) == "string"
	end)
	if unavailableKeys == nil then
		return nil
	end
	return {
		shownFanCount = message.fanCount,
		shownStarCoinBalance = message.starCoinBalance,
		isSaveDataPersistenceDelayed = message.isSaveDataPersistenceDelayed,
		unavailableLobbyOutfitStylingItemKeys = unavailableKeys,
	}
end

function ServerSentMessageShapeReader.readWardrobeCatalogChangedMessage(message: any)
	if type(message) ~= "table" or type(message.isWardrobeCatalogReady) ~= "boolean" then
		return nil
	end
	if not isFiniteNumber(message.wardrobeCatalogVersion) then
		return nil
	end
	return {
		isWardrobeCatalogReady = message.isWardrobeCatalogReady,
		wardrobeCatalogVersion = message.wardrobeCatalogVersion,
	}
end

return table.freeze(ServerSentMessageShapeReader)
