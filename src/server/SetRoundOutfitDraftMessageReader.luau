-- SetRoundOutfitDraftMessageReader (development spec v1.3 §2.3, §1.5): reads one untrusted
-- `SetRoundOutfitDraft` message `{ roundId, outfitDraftSequenceNumber, outfitStylingItemKeys }`
-- exactly as a device sent it, without trusting anything about it.
--
-- Pure logic, no state, no Roblox-specific interface. RoundOutfitDraftKeeper is its only user.
--
-- Rules it enforces (the defaults of the referee audit, questions 4, 5, 6 and 9):
--   * Nothing here raises for any value, and nothing a device sent can run code here: a value is
--     looked into only when it is a table WITHOUT a metatable, and then only with raw access
--     (rawget, next). A frozen table has no metatable, so it is read like any other table.
--   * Only the three named fields are read. Any other field (outfitScore, starCount,
--     playerUserId, ...) is never read, stored or echoed.
--   * No device value is ever used as a table key, concatenated or logged.
--   * The work done is bounded whatever the device sent: at most 2 × (MAX_OUTFIT_ITEM_COUNT + 1)
--     raw steps for the outfit list, a constant number for the rest.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- SetRoundOutfitDraftMessageReader.LARGEST_LEGAL_OUTFIT_DRAFT_SEQUENCE_NUMBER = 2^53 - 1
--
-- SetRoundOutfitDraftMessageReader.isLegalOutfitDraftSequenceNumber(candidate: any) -> boolean
--   True only for a number that is finite, whole, and in 1 .. 2^53 - 1 (audit question 4).
--
-- SetRoundOutfitDraftMessageReader.readOutfitDraftSequenceNumberForThisRound(
--     untrustedSetRoundOutfitDraftMessage: any, serverRoundId: string) -> number?
--   The message's legal outfitDraftSequenceNumber, or nil when the message must be ignored
--   without acknowledgement: it is not a table without a metatable; its roundId is not the
--   server's own (rawequal: same type and value, no coercion, so 1 never matches "1"); or its
--   sequence number is not legal. Allocates nothing.
--
-- SetRoundOutfitDraftMessageReader.takeBoundedOutfitStylingItemKeysSnapshot(
--     untrustedSetRoundOutfitDraftMessage: any) -> OutfitSnapshot
--   Call only after readOutfitDraftSequenceNumberForThisRound returned a number. A private
--   copy of the message's outfitStylingItemKeys taken now, so nothing the device (or a caller
--   holding the table) does to its table afterwards changes what is later validated and kept:
--   * a fresh array of the list's strings when the field is a table without a metatable whose
--     keys are exactly 1..n with n <= MAX_OUTFIT_ITEM_COUNT (12) and whose every entry is a
--     string of at most MAX_STYLING_ITEM_KEY_LENGTH (40) characters;
--   * otherwise NOT_A_PLAIN_OUTFIT_LIST_MARKER (`false`): field missing or not a table, a
--     metatable, more entries than any valid outfit can hold, a hole, a key outside 1..n, or an
--     entry that is not such a short string (a long string, a table, a number, ...).
--     OutfitValidator.validateOutfit rejects the marker exactly as it rejects the original value
--     (both are "not a list of styling item keys"), so the verdict never changes. The snapshot
--     therefore holds at most 12 strings of at most 40 characters and never a reference to a
--     large device value (for example a 1 MB string or a nested table).
--   The array is not frozen here; the keeper freezes it when it keeps it.
-- SetRoundOutfitDraftMessageReader.NOT_A_PLAIN_OUTFIT_LIST_MARKER = false
-- ════════════════════════════════════════════════════════════════════════════════════════════

local OutfitValidator = require("../shared/OutfitValidator")

export type OutfitSnapshot = { any } | boolean

local SetRoundOutfitDraftMessageReader = {}

SetRoundOutfitDraftMessageReader.LARGEST_LEGAL_OUTFIT_DRAFT_SEQUENCE_NUMBER = 2 ^ 53 - 1
SetRoundOutfitDraftMessageReader.NOT_A_PLAIN_OUTFIT_LIST_MARKER = false

local LARGEST_LEGAL_OUTFIT_DRAFT_SEQUENCE_NUMBER =
	SetRoundOutfitDraftMessageReader.LARGEST_LEGAL_OUTFIT_DRAFT_SEQUENCE_NUMBER
local NOT_A_PLAIN_OUTFIT_LIST_MARKER = SetRoundOutfitDraftMessageReader.NOT_A_PLAIN_OUTFIT_LIST_MARKER
-- The most items any valid outfit can hold: a longer list is already known to be invalid.
local MAX_OUTFIT_ITEM_COUNT = OutfitValidator.MAX_OUTFIT_ITEM_COUNT
-- The longest styling item key: a longer entry (or one that is not a string) is already invalid.
local MAX_STYLING_ITEM_KEY_LENGTH = OutfitValidator.MAX_STYLING_ITEM_KEY_LENGTH

local function isTableWithoutMetatable(candidate: any): boolean
	return type(candidate) == "table" and getmetatable(candidate) == nil
end

function SetRoundOutfitDraftMessageReader.isLegalOutfitDraftSequenceNumber(candidate: any): boolean
	-- NaN fails both comparisons; infinities fail the range; math.floor keeps only whole numbers.
	return type(candidate) == "number"
		and candidate >= 1
		and candidate <= LARGEST_LEGAL_OUTFIT_DRAFT_SEQUENCE_NUMBER
		and math.floor(candidate) == candidate
end

function SetRoundOutfitDraftMessageReader.readOutfitDraftSequenceNumberForThisRound(
	untrustedSetRoundOutfitDraftMessage: any,
	serverRoundId: string
): number?
	if not isTableWithoutMetatable(untrustedSetRoundOutfitDraftMessage) then
		return nil
	end
	local untrustedRoundId = rawget(untrustedSetRoundOutfitDraftMessage, "roundId")
	-- rawequal is false across types (no coercion: 17 never matches "17") and runs no metamethod.
	if not rawequal(untrustedRoundId, serverRoundId) then
		return nil
	end
	local untrustedOutfitDraftSequenceNumber = rawget(untrustedSetRoundOutfitDraftMessage, "outfitDraftSequenceNumber")
	if not SetRoundOutfitDraftMessageReader.isLegalOutfitDraftSequenceNumber(untrustedOutfitDraftSequenceNumber) then
		return nil
	end
	return untrustedOutfitDraftSequenceNumber
end

function SetRoundOutfitDraftMessageReader.takeBoundedOutfitStylingItemKeysSnapshot(
	untrustedSetRoundOutfitDraftMessage: any
): OutfitSnapshot
	if not isTableWithoutMetatable(untrustedSetRoundOutfitDraftMessage) then
		return NOT_A_PLAIN_OUTFIT_LIST_MARKER
	end
	local untrustedOutfitStylingItemKeys = rawget(untrustedSetRoundOutfitDraftMessage, "outfitStylingItemKeys")
	if not isTableWithoutMetatable(untrustedOutfitStylingItemKeys) then
		return NOT_A_PLAIN_OUTFIT_LIST_MARKER
	end

	local entryCount = 0
	for _ in next, untrustedOutfitStylingItemKeys do
		entryCount += 1
		if entryCount > MAX_OUTFIT_ITEM_COUNT then
			return NOT_A_PLAIN_OUTFIT_LIST_MARKER
		end
	end

	local outfitStylingItemKeysSnapshot = table.create(entryCount)
	for listPosition = 1, entryCount do
		local untrustedListEntry = rawget(untrustedOutfitStylingItemKeys, listPosition)
		-- nil is a hole or a key that is not one of 1..entryCount; # on a string is constant work.
		if type(untrustedListEntry) ~= "string" or #untrustedListEntry > MAX_STYLING_ITEM_KEY_LENGTH then
			return NOT_A_PLAIN_OUTFIT_LIST_MARKER
		end
		outfitStylingItemKeysSnapshot[listPosition] = untrustedListEntry
	end
	return outfitStylingItemKeysSnapshot
end

return table.freeze(SetRoundOutfitDraftMessageReader)
