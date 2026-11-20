-- Spec §2 intro and §5.1: every value a device sends is untrusted. For each of the four dance-shop
-- requests, any Luau value in place of the id is refused with the reason the spec gives for an
-- unknown or unowned item, without raising, without changing the save, without reaching the
-- catalog unless it is a short string, without logging, and without echoing it back.

local DanceAndCosmeticRequestTestHarness = require("./DanceAndCosmeticRequestTestHarness")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = DanceAndCosmeticRequestTestHarness.PLAYER

local function createTableWhoseEveryMetamethodRaises()
	local function raiseFromMetamethod()
		error("a device-made metamethod ran on the server")
	end
	return setmetatable({}, {
		__index = raiseFromMetamethod,
		__newindex = raiseFromMetamethod,
		__eq = raiseFromMetamethod,
		__lt = raiseFromMetamethod,
		__le = raiseFromMetamethod,
		__len = raiseFromMetamethod,
		__concat = raiseFromMetamethod,
		__tostring = raiseFromMetamethod,
		__call = raiseFromMetamethod,
		__iter = raiseFromMetamethod,
	})
end

local function createCyclicTable()
	local cyclicTable = { danceId = "neon_spin" }
	cyclicTable.itself = cyclicTable
	return cyclicTable
end

-- { valueDescription, untrustedValue, reachesCatalog }
local UNTRUSTED_VALUE_CASES = {
	{ "nil", nil, false },
	{ "false", false, false },
	{ "true", true, false },
	{ "zero", 0, false },
	{ "a negative number", -1, false },
	{ "NaN", 0 / 0, false },
	{ "infinity", math.huge, false },
	{ "a huge whole number", 2 ^ 53, false },
	{ "an empty string", "", false },
	{ "a string one byte over the limit", string.rep("a", 65), false },
	{ "a 1 MB string", string.rep("neon_spin", 120_000), false },
	{ "a known id with a trailing zero byte", "neon_spin\0", true },
	{ "a known id in capitals", "NEON_SPIN", true },
	{ "a known id with a leading space", " title_rising_star", true },
	{ "an empty table", {}, false },
	{ "a list holding a known id", { "neon_spin" }, false },
	{ "a table that looks like a catalog entry", { danceId = "neon_spin", cosmeticId = "title_rising_star" }, false },
	{ "a table whose every metamethod raises", createTableWhoseEveryMetamethodRaises(), false },
	{ "a cyclic table", createCyclicTable(), false },
	{ "a frozen table", table.freeze({ "neon_spin" }), false },
	{ "a function", function() end, false },
	{ "a coroutine", coroutine.create(function() end), false },
	{ "a buffer", buffer.create(16), false },
	{ "a vector", vector.create(1, 2, 3), false },
}

-- The save owns everything the requests could name and has coins for all of it, so a refusal
-- can only come from the id itself.
local function giveEverything(saveData)
	saveData.starCoinBalance = 100_000
	table.insert(saveData.ownedDanceIds, "neon_spin")
	saveData.ownedCosmeticIds = { "title_rising_star" }
end

local REQUEST_KINDS = {
	{
		requestName = "RequestPurchaseDanceWithStarCoins",
		expectedRejectionReason = "UnknownDance",
		sendRequest = function(shopHarness, untrustedValue)
			return shopHarness.purchaseRequestAnswerer:purchaseDanceWithStarCoinsAndBuildAnswer(PLAYER, untrustedValue)
		end,
	},
	{
		requestName = "RequestPurchaseCosmeticWithStarCoins",
		expectedRejectionReason = "UnknownCosmetic",
		sendRequest = function(shopHarness, untrustedValue)
			return shopHarness.purchaseRequestAnswerer:purchaseCosmeticWithStarCoinsAndBuildAnswer(
				PLAYER,
				untrustedValue
			)
		end,
	},
	{
		requestName = "RequestEquipDance",
		expectedRejectionReason = "DanceNotOwned",
		sendRequest = function(shopHarness, untrustedValue)
			return shopHarness.equipRequestAnswerer:equipOwnedDanceAndBuildAnswer(PLAYER, untrustedValue)
		end,
	},
	{
		requestName = "RequestEquipCosmetic",
		expectedRejectionReason = "CosmeticNotOwned",
		sendRequest = function(shopHarness, untrustedValue)
			return shopHarness.equipRequestAnswerer:equipOwnedCosmeticAndBuildAnswer(PLAYER, untrustedValue)
		end,
	},
}

for _, requestKind in REQUEST_KINDS do
	describe(requestKind.requestName .. " with an untrusted id", function()
		for _, untrustedValueCase in UNTRUSTED_VALUE_CASES do
			local valueDescription, untrustedValue, reachesCatalog =
				untrustedValueCase[1], untrustedValueCase[2], untrustedValueCase[3]
			it("refuses " .. valueDescription .. " as " .. requestKind.expectedRejectionReason, function()
				local shopHarness = DanceAndCosmeticRequestTestHarness.createShopHarness(giveEverything)
				local saveDataBefore = shopHarness.readInMemorySaveData()
				local inMemoryRevisionBefore = shopHarness.readSaveChangeRevisions()
				local ledgerLogCountBefore = #shopHarness.server.ledgerLogger.loggedInformation
					+ #shopHarness.server.ledgerLogger.loggedWarnings

				local answer = requestKind.sendRequest(shopHarness, untrustedValue)

				expect(answer).toEqual({ isAccepted = false, rejectionReason = requestKind.expectedRejectionReason })
				expect(shopHarness.readInMemorySaveData()).toEqual(saveDataBefore)
				expect((shopHarness.readSaveChangeRevisions())).toBe(inMemoryRevisionBefore)
				local askedIdCount = #shopHarness.danceCatalog.askedDanceIds
					+ #shopHarness.cosmeticCatalog.askedCosmeticIds
				expect(askedIdCount).toBe(if reachesCatalog then 1 else 0)
				expect(#shopHarness.shopLogger.loggedInformation + #shopHarness.shopLogger.loggedWarnings).toBe(0)
				expect(
					#shopHarness.server.ledgerLogger.loggedInformation + #shopHarness.server.ledgerLogger.loggedWarnings
				).toBe(ledgerLogCountBefore)
			end)
		end
	end)
end
