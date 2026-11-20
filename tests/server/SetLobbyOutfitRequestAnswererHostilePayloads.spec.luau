-- SetLobbyOutfitRequestAnswerer with hostile device payloads (development spec §2 intro, §2.13,
-- §5.1): no value makes the server raise, a metatable never runs, nothing unusable is stored,
-- and the answer is OutfitInvalid. Plus seeded random trials of valid and broken outfits.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local RandomValidOutfitGenerator = require("../fixtures/RandomValidOutfitGenerator")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local LobbyRequestRulesTestHarness = require("./LobbyRequestRulesTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local FIRST_PLAYER_USER_ID = LobbyRequestRulesTestHarness.FIRST_PLAYER_USER_ID
local PINK_TOP_KEY = "asset_9000011"
local STORED_SHOES_KEY = "bundle_9000041"

local OUTFIT_INVALID = { isAccepted = false, rejectionReason = "OutfitInvalid" }

local function createLoadedHarness()
	local harness = LobbyRequestRulesTestHarness.createLobbyRequestRulesHarness()
	harness.loadNewPlayer(FIRST_PLAYER_USER_ID)
	return harness
end

local function createCyclicTable()
	local cyclicTable = {}
	cyclicTable[1] = cyclicTable
	cyclicTable.outfitStylingItemKeys = cyclicTable
	return cyclicTable
end

local function createTableWhoseMetatableRaises()
	return setmetatable({}, {
		__index = function()
			error("a metatable of the device ran")
		end,
		__len = function()
			error("a metatable of the device ran")
		end,
		__iter = function()
			error("a metatable of the device ran")
		end,
	})
end

local function createListWithStringField(firstKey: string)
	local listWithStringField = { firstKey }
	listWithStringField.outfit = "x"
	return listWithStringField
end

local function createLongList(listLength: number)
	local longList = table.create(listLength, PINK_TOP_KEY)
	return longList
end

local HOSTILE_REQUESTS = {
	{ "nil", nil },
	{ "false", false },
	{ "a number", 42 },
	{ "NaN", 0 / 0 },
	{ "a huge string", string.rep("asset_", 200000) },
	{ "a function", function() end },
	{ "a list of keys instead of a request", { PINK_TOP_KEY } },
	{ "a request without outfitStylingItemKeys", {} },
	{ "outfitStylingItemKeys = a string", { outfitStylingItemKeys = PINK_TOP_KEY } },
	{ "outfitStylingItemKeys = NaN", { outfitStylingItemKeys = 0 / 0 } },
	{ "a cyclic request", createCyclicTable() },
	{ "a request whose metatable raises", createTableWhoseMetatableRaises() },
	{
		"a request whose metatable would supply a valid outfit",
		setmetatable({}, { __index = { outfitStylingItemKeys = { PINK_TOP_KEY } } }),
	},
	{
		"a request carrying a valid outfit but having a metatable (Roblox never delivers one)",
		setmetatable({ outfitStylingItemKeys = { PINK_TOP_KEY } }, {}),
	},
	{ "a key list whose metatable raises", { outfitStylingItemKeys = createTableWhoseMetatableRaises() } },
	{
		"a key list whose metatable would supply a valid key",
		{
			outfitStylingItemKeys = setmetatable({}, {
				__index = { PINK_TOP_KEY },
				__len = function()
					return 1
				end,
			}),
		},
	},
	{ "a key list with a hole", { outfitStylingItemKeys = { PINK_TOP_KEY, nil, "bundle_9000041" } } },
	{ "a key list with a string field", { outfitStylingItemKeys = createListWithStringField(PINK_TOP_KEY) } },
	{ "a key list with a NaN entry", { outfitStylingItemKeys = { 0 / 0 } } },
	{ "a key list with a table entry", { outfitStylingItemKeys = { { PINK_TOP_KEY } } } },
	{ "a key list with a huge string", { outfitStylingItemKeys = { string.rep("a", 1000000) } } },
	{ "a key list of 100000 entries", { outfitStylingItemKeys = createLongList(100000) } },
	{ "a key list holding itself", { outfitStylingItemKeys = createCyclicTable() } },
	{ "a key list with key 0", { outfitStylingItemKeys = { [0] = PINK_TOP_KEY } } },
	-- Look-alikes of the stored outfit { STORED_SHOES_KEY }: never taken as "the same outfit".
	{
		"a key list whose metatable would supply the stored outfit",
		{
			outfitStylingItemKeys = setmetatable({}, {
				__index = { STORED_SHOES_KEY },
				__len = function()
					return 1
				end,
			}),
		},
	},
	{ "the stored key plus a string field", { outfitStylingItemKeys = createListWithStringField(STORED_SHOES_KEY) } },
	{
		"the stored key plus an entry after a hole",
		{ outfitStylingItemKeys = { STORED_SHOES_KEY, nil, STORED_SHOES_KEY } },
	},
	{ "the stored key at position 2", { outfitStylingItemKeys = { [2] = STORED_SHOES_KEY } } },
	{ "a key list with fractional keys", { outfitStylingItemKeys = { [1.5] = PINK_TOP_KEY } } },
}

describe("SetLobbyOutfit hostile payloads", function()
	for _, hostileRequestCase in HOSTILE_REQUESTS do
		it("answers OutfitInvalid without raising for " .. hostileRequestCase[1], function()
			local harness = createLoadedHarness()
			harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { STORED_SHOES_KEY } })
			local didAnswer, answerOrError =
				pcall(harness.sendSetLobbyOutfit, FIRST_PLAYER_USER_ID, hostileRequestCase[2])
			expect(didAnswer).toBeTrue()
			expect(answerOrError).toEqual(OUTFIT_INVALID)
			expect(harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)).toEqual({ STORED_SHOES_KEY })
			expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(1)
		end)
	end
end)

describe("SetLobbyOutfit seeded random trials", function()
	it("every random valid outfit is accepted and stored exactly, in order, as the server's own list", function()
		local harness = createLoadedHarness()
		SeededRandomTrials.runSeededRandomTrials(200, function(seededRandomNumberGenerator)
			local outfitStylingItemKeys =
				RandomValidOutfitGenerator.generateRandomValidOutfitStylingItemKeys(seededRandomNumberGenerator)
			local storedOutfitBefore = harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)
			local revisionBefore = harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)
			local sentOutfitStylingItemKeys = table.clone(outfitStylingItemKeys)
			local answer =
				harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = sentOutfitStylingItemKeys })
			expect(answer).toEqual({ isAccepted = true })
			expect(harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)).toEqual(outfitStylingItemKeys)
			local isSameAsBefore = table.concat(storedOutfitBefore, ",") == table.concat(outfitStylingItemKeys, ",")
			local expectedRevision = if isSameAsBefore then revisionBefore else (revisionBefore :: number) + 1
			expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(expectedRevision)
			table.clear(sentOutfitStylingItemKeys)
			expect(harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)).toEqual(outfitStylingItemKeys)
		end)
	end)

	it("a random valid outfit broken by one random fault is refused and changes nothing", function()
		local harness = createLoadedHarness()
		local outfitBreakers = {
			function(outfitStylingItemKeys)
				table.insert(outfitStylingItemKeys, FakeStylingItemPool.HIDDEN_HAIR_KEY)
			end,
			function(outfitStylingItemKeys)
				table.insert(outfitStylingItemKeys, FakeStylingItemPool.KEY_NOT_IN_POOL)
			end,
			function(outfitStylingItemKeys)
				table.insert(outfitStylingItemKeys, FakeStylingItemPool.DISABLED_DRESS_KEY)
			end,
			function(outfitStylingItemKeys)
				table.insert(outfitStylingItemKeys, outfitStylingItemKeys[1] or 7)
			end,
			function(outfitStylingItemKeys)
				table.insert(outfitStylingItemKeys, 1, 0 / 0)
			end,
			function(outfitStylingItemKeys)
				outfitStylingItemKeys[#outfitStylingItemKeys + 2] = PINK_TOP_KEY
			end,
		}
		SeededRandomTrials.runSeededRandomTrials(200, function(seededRandomNumberGenerator)
			local brokenOutfitStylingItemKeys =
				RandomValidOutfitGenerator.generateRandomValidOutfitStylingItemKeys(seededRandomNumberGenerator)
			seededRandomNumberGenerator.pickRandomListElement(outfitBreakers)(brokenOutfitStylingItemKeys)
			local storedOutfitBefore = harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)
			local revisionBefore = harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)
			local answer = harness.sendSetLobbyOutfit(
				FIRST_PLAYER_USER_ID,
				{ outfitStylingItemKeys = brokenOutfitStylingItemKeys }
			)
			expect(answer).toEqual(OUTFIT_INVALID)
			expect(harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)).toEqual(storedOutfitBefore)
			expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(revisionBefore)
		end)
	end)
end)
