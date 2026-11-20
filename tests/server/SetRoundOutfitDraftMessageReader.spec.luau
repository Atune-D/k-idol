-- SetRoundOutfitDraftMessageReader: reading an untrusted SetRoundOutfitDraft message (spec §2.3;
-- referee audit questions 4, 5, 6 and 9).

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local OutfitValidator = require("../../src/shared/OutfitValidator")
local SetRoundOutfitDraftMessageReader = require("../../src/server/SetRoundOutfitDraftMessageReader")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local SERVER_ROUND_ID = "round-7"
local isLegalOutfitDraftSequenceNumber = SetRoundOutfitDraftMessageReader.isLegalOutfitDraftSequenceNumber
local readOutfitDraftSequenceNumberForThisRound =
	SetRoundOutfitDraftMessageReader.readOutfitDraftSequenceNumberForThisRound
local takeBoundedOutfitStylingItemKeysSnapshot =
	SetRoundOutfitDraftMessageReader.takeBoundedOutfitStylingItemKeysSnapshot
local NOT_A_PLAIN_OUTFIT_LIST_MARKER = SetRoundOutfitDraftMessageReader.NOT_A_PLAIN_OUTFIT_LIST_MARKER

local function raisingMetatable()
	local function raiseWhenTouched()
		error("hostile metamethod ran")
	end
	return {
		__index = raiseWhenTouched,
		__newindex = raiseWhenTouched,
		__len = raiseWhenTouched,
		__iter = raiseWhenTouched,
		__eq = raiseWhenTouched,
		__lt = raiseWhenTouched,
		__le = raiseWhenTouched,
	}
end

describe("SetRoundOutfitDraftMessageReader.isLegalOutfitDraftSequenceNumber", function()
	it("accepts whole numbers from 1 to 2^53 - 1", function()
		for _, legalSequenceNumber in { 1, 2, 7, 1000000, 2 ^ 53 - 1 } do
			expect(isLegalOutfitDraftSequenceNumber(legalSequenceNumber)).toBeTrue()
		end
		expect(SetRoundOutfitDraftMessageReader.LARGEST_LEGAL_OUTFIT_DRAFT_SEQUENCE_NUMBER).toBe(2 ^ 53 - 1)
	end)

	it("rejects every other value without raising", function()
		local illegalSequenceNumbers = {
			0,
			-1,
			0.5,
			1.5,
			2 ^ 53,
			1e308,
			math.huge,
			-math.huge,
			0 / 0,
			"1",
			true,
			{},
			setmetatable({}, raisingMetatable()),
			function() end,
		}
		for _, illegalSequenceNumber in illegalSequenceNumbers do
			expect({ tostring(illegalSequenceNumber), isLegalOutfitDraftSequenceNumber(illegalSequenceNumber) }).toEqual({
				tostring(illegalSequenceNumber),
				false,
			})
		end
		expect(isLegalOutfitDraftSequenceNumber(nil)).toBeFalse()
	end)
end)

describe("SetRoundOutfitDraftMessageReader.readOutfitDraftSequenceNumberForThisRound", function()
	it("returns the number of a well-formed message for this round", function()
		expect(readOutfitDraftSequenceNumberForThisRound({
			roundId = SERVER_ROUND_ID,
			outfitDraftSequenceNumber = 3,
			outfitStylingItemKeys = {},
		}, SERVER_ROUND_ID)).toBe(3)
		local frozenMessage = table.freeze({ roundId = SERVER_ROUND_ID, outfitDraftSequenceNumber = 4 })
		expect(readOutfitDraftSequenceNumberForThisRound(frozenMessage, SERVER_ROUND_ID)).toBe(4)
	end)

	it("returns nil for a message that is not a plain table, or has another round, or an illegal number", function()
		local messageContainingItself = {}
		messageContainingItself.roundId = messageContainingItself
		local ignoredMessages = {
			{ "nil", nil },
			{ "number", 42 },
			{ "string", SERVER_ROUND_ID },
			{ "function", function() end },
			{
				"raising metatable",
				setmetatable({ roundId = SERVER_ROUND_ID, outfitDraftSequenceNumber = 1 }, raisingMetatable()),
			},
			{
				"harmless metatable",
				setmetatable({ roundId = SERVER_ROUND_ID, outfitDraftSequenceNumber = 1 }, {}),
			},
			{ "containing itself", messageContainingItself },
			{ "other round", { roundId = "round-6", outfitDraftSequenceNumber = 1 } },
			{ "round as number", { roundId = 7, outfitDraftSequenceNumber = 1 } },
			{ "round missing", { outfitDraftSequenceNumber = 1 } },
			{ "illegal number", { roundId = SERVER_ROUND_ID, outfitDraftSequenceNumber = 0 } },
			{ "number missing", { roundId = SERVER_ROUND_ID } },
			{ "array form", { SERVER_ROUND_ID, 1, {} } },
		}
		for _, ignoredCase in ignoredMessages do
			local didReturn, sequenceNumber =
				pcall(readOutfitDraftSequenceNumberForThisRound, ignoredCase[2], SERVER_ROUND_ID)
			expect({ ignoredCase[1], didReturn, sequenceNumber }).toEqual({ ignoredCase[1], true, nil })
		end
	end)

	it("matches the round id by primitive type with no coercion", function()
		expect(readOutfitDraftSequenceNumberForThisRound({ roundId = 17, outfitDraftSequenceNumber = 1 }, "17")).toBeNil()
		expect(readOutfitDraftSequenceNumberForThisRound({ roundId = "17", outfitDraftSequenceNumber = 1 }, "17")).toBe(
			1
		)
	end)

	it("never reads the message through metamethods even when they would answer correctly", function()
		local wasMetamethodUsed = false
		local proxiedMessage = setmetatable({}, {
			__index = function(_, fieldName)
				wasMetamethodUsed = true
				return if fieldName == "roundId" then SERVER_ROUND_ID else 1
			end,
		})
		expect(readOutfitDraftSequenceNumberForThisRound(proxiedMessage, SERVER_ROUND_ID)).toBeNil()
		expect(takeBoundedOutfitStylingItemKeysSnapshot(proxiedMessage)).toBe(NOT_A_PLAIN_OUTFIT_LIST_MARKER)
		expect(wasMetamethodUsed).toBeFalse()
	end)
end)

describe("SetRoundOutfitDraftMessageReader.takeBoundedOutfitStylingItemKeysSnapshot", function()
	it("copies a plain list into a fresh array that later changes to the original do not reach", function()
		local submittedList = { "asset_9000002", "asset_9000012" }
		local snapshot = takeBoundedOutfitStylingItemKeysSnapshot({ outfitStylingItemKeys = submittedList })
		expect(snapshot).toEqual({ "asset_9000002", "asset_9000012" })
		expect(rawequal(snapshot, submittedList)).toBeFalse()
		submittedList[1] = "changed"
		expect(snapshot).toEqual({ "asset_9000002", "asset_9000012" })
		expect(table.isfrozen(snapshot :: any)).toBeFalse()
	end)

	it("copies an empty list and a frozen list", function()
		expect(takeBoundedOutfitStylingItemKeysSnapshot({ outfitStylingItemKeys = {} })).toEqual({})
		local frozenList = table.freeze({ "asset_9000031" })
		expect(takeBoundedOutfitStylingItemKeysSnapshot({ outfitStylingItemKeys = frozenList })).toEqual({
			"asset_9000031",
		})
	end)

	it("copies an entry of exactly 40 characters and gives the marker for 41", function()
		local fortyCharacterKey = string.rep("k", OutfitValidator.MAX_STYLING_ITEM_KEY_LENGTH)
		expect(takeBoundedOutfitStylingItemKeysSnapshot({ outfitStylingItemKeys = { fortyCharacterKey } })).toEqual({
			fortyCharacterKey,
		})
		expect(takeBoundedOutfitStylingItemKeysSnapshot({
			outfitStylingItemKeys = { "asset_9000002", fortyCharacterKey .. "k" },
		})).toBe(NOT_A_PLAIN_OUTFIT_LIST_MARKER)
	end)

	it("keeps no reference to a large or nested device value inside a short list", function()
		local oneMegabyteString = string.rep("a", 1024 * 1024)
		local hundredThousandEntryTable = table.create(100000, "asset_9000002")
		local listContainingItself = {}
		listContainingItself[1] = listContainingItself
		local entryCases = {
			{ "a 1 MB string", { oneMegabyteString } },
			{ "a 1 MB string after a valid key", { "asset_9000002", oneMegabyteString } },
			{ "a 100000-entry table", { "asset_9000002", hundredThousandEntryTable } },
			{ "the list itself", listContainingItself },
			{ "numbers and booleans", { 1, true } },
		}
		for _, entryCase in entryCases do
			expect({ entryCase[1], takeBoundedOutfitStylingItemKeysSnapshot({ outfitStylingItemKeys = entryCase[2] }) }).toEqual({
				entryCase[1],
				NOT_A_PLAIN_OUTFIT_LIST_MARKER,
			})
		end
	end)

	it("hands the validator a value it judges exactly as it judges the original", function()
		local oneMegabyteString = string.rep("a", 1024 * 1024)
		for _, untrustedOutfitStylingItemKeys in { { oneMegabyteString }, { "asset_9000002", {} }, { 7 } } do
			local snapshot =
				takeBoundedOutfitStylingItemKeysSnapshot({ outfitStylingItemKeys = untrustedOutfitStylingItemKeys })
			local snapshotVerdict = OutfitValidator.validateOutfit(
				snapshot,
				FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
				FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET
			)
			local originalVerdict = OutfitValidator.validateOutfit(
				untrustedOutfitStylingItemKeys,
				FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
				FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET
			)
			expect(snapshotVerdict).toEqual(originalVerdict)
		end
	end)

	it("copies a list of exactly twelve entries and gives the marker for thirteen", function()
		local twelveEntries = table.create(12, "asset_9000002")
		expect(takeBoundedOutfitStylingItemKeysSnapshot({ outfitStylingItemKeys = twelveEntries })).toEqual(
			twelveEntries
		)
		local thirteenEntries = table.create(13, "asset_9000002")
		expect(takeBoundedOutfitStylingItemKeysSnapshot({ outfitStylingItemKeys = thirteenEntries })).toBe(
			NOT_A_PLAIN_OUTFIT_LIST_MARKER
		)
	end)

	it("gives the marker for every value that is not a plain list", function()
		local listWithHole = {}
		listWithHole[1] = "asset_9000002"
		listWithHole[3] = "asset_9000012"
		local listPlusNamedKey: { [any]: string } = { "asset_9000002" }
		listPlusNamedKey.extra = "x"
		local listStartingAtTwo = {}
		listStartingAtTwo[2] = "asset_9000002"
		local notPlainListCases = {
			{ "message nil", nil },
			{ "message with metatable", setmetatable({ outfitStylingItemKeys = {} }, {}) },
			{ "field missing", {} },
			{ "number", { outfitStylingItemKeys = 5 } },
			{ "string", { outfitStylingItemKeys = string.rep("a", 1024 * 1024) } },
			{
				"list with metatable",
				{ outfitStylingItemKeys = setmetatable({ "asset_9000002" }, raisingMetatable()) },
			},
			{ "hole", { outfitStylingItemKeys = listWithHole } },
			{ "starts at 2", { outfitStylingItemKeys = listStartingAtTwo } },
			{ "map", { outfitStylingItemKeys = { a = "asset_9000002" } } },
			{ "list plus a named key", { outfitStylingItemKeys = listPlusNamedKey } },
			{ "100000 entries", { outfitStylingItemKeys = table.create(100000, "asset_9000002") } },
		}
		for _, notPlainListCase in notPlainListCases do
			local didReturn, snapshot = pcall(takeBoundedOutfitStylingItemKeysSnapshot, notPlainListCase[2])
			expect({ notPlainListCase[1], didReturn, snapshot }).toEqual({
				notPlainListCase[1],
				true,
				NOT_A_PLAIN_OUTFIT_LIST_MARKER,
			})
		end
	end)
end)
