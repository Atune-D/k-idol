-- DanceAndCosmeticCatalogEntryFinder: an untrusted id from a device becomes the catalog entry it
-- names, or nil (spec §2 intro, §2.8). Values that are not short strings never reach the catalog;
-- entries unusable for the requested use (Purchase or Equip) are treated as absent and logged.

local DanceAndCosmeticCatalogEntryFinder = require("../../src/server/DanceAndCosmeticCatalogEntryFinder")
local DanceAndCosmeticRequestTestHarness = require("./DanceAndCosmeticRequestTestHarness")
local DanceAndCosmeticShopTestCatalogs = require("../fixtures/DanceAndCosmeticShopTestCatalogs")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local MAXIMUM_LENGTH_BYTES = DanceAndCosmeticCatalogEntryFinder.MAXIMUM_UNTRUSTED_DANCE_OR_COSMETIC_ID_LENGTH_BYTES
local PURCHASE = DanceAndCosmeticCatalogEntryFinder.CATALOG_ENTRY_USES.Purchase
local EQUIP = DanceAndCosmeticCatalogEntryFinder.CATALOG_ENTRY_USES.Equip
local BOTH_USES = { PURCHASE, EQUIP }
local findDance = DanceAndCosmeticCatalogEntryFinder.findDanceForUntrustedDanceId
local findCosmetic = DanceAndCosmeticCatalogEntryFinder.findCosmeticForUntrustedCosmeticId
local isLookupWorthy = DanceAndCosmeticCatalogEntryFinder.isLookupWorthyDanceOrCosmeticId

local function createDanceEntry(danceId: string, starCoinPrice: any)
	return {
		danceId = danceId,
		danceDisplayName = "Fixture Dance",
		danceAnimationAssetId = "",
		starCoinPrice = starCoinPrice,
		isGrantedToNewPlayers = false,
	}
end

local function createCosmeticEntry(cosmeticId: string, cosmeticKind: any, starCoinPrice: any)
	return {
		cosmeticId = cosmeticId,
		cosmeticKind = cosmeticKind,
		cosmeticDisplayName = "Fixture Cosmetic",
		starCoinPrice = starCoinPrice,
	}
end

-- A catalog whose lookup returns `catalogEntry` for `danceOrCosmeticId`, whatever that entry is.
local function createDanceCatalogAnswering(danceId: string, danceEntry: any)
	return {
		findDanceByDanceId = function(askedDanceId)
			if askedDanceId == danceId then
				return danceEntry
			end
			return nil
		end,
	}
end

local function createCosmeticCatalogAnswering(cosmeticId: string, cosmeticEntry: any)
	return {
		findCosmeticByCosmeticId = function(askedCosmeticId)
			if askedCosmeticId == cosmeticId then
				return cosmeticEntry
			end
			return nil
		end,
	}
end

local function expectOneWarningContaining(logger, expectedFragments: { string })
	expect(#logger.loggedWarnings).toBe(1)
	expect(#logger.loggedInformation).toBe(0)
	for _, expectedFragment in expectedFragments do
		expect(string.find(logger.loggedWarnings[1], expectedFragment, 1, true) ~= nil).toBeTrue()
	end
end

describe("DanceAndCosmeticCatalogEntryFinder limits and uses", function()
	it("looks up ids of at most 64 bytes (the value is pinned so a change is deliberate)", function()
		expect(MAXIMUM_LENGTH_BYTES).toBe(64)
	end)

	it("offers exactly the uses Purchase and Equip, frozen", function()
		expect(DanceAndCosmeticCatalogEntryFinder.CATALOG_ENTRY_USES).toEqual({ Purchase = "Purchase", Equip = "Equip" })
		expect(table.isfrozen(DanceAndCosmeticCatalogEntryFinder.CATALOG_ENTRY_USES)).toBeTrue()
	end)

	it("raises for a use that is not one of CATALOG_ENTRY_USES", function()
		local logger = DanceAndCosmeticRequestTestHarness.createRecordingLogger()
		local danceCatalog = DanceAndCosmeticShopTestCatalogs.createDanceCatalog()
		local cosmeticCatalog = DanceAndCosmeticShopTestCatalogs.createCosmeticCatalog()
		expect(function()
			findDance(danceCatalog, logger, "neon_spin", "Wear")
		end).toThrow("unknown catalogEntryUse Wear")
		expect(function()
			findCosmetic(cosmeticCatalog, logger, "title_rising_star", nil)
		end).toThrow("unknown catalogEntryUse nil")
	end)

	it("treats only strings of 1..64 bytes as lookup-worthy", function()
		expect(isLookupWorthy("x")).toBeTrue()
		expect(isLookupWorthy(string.rep("a", MAXIMUM_LENGTH_BYTES))).toBeTrue()
		expect(isLookupWorthy(string.rep("a", MAXIMUM_LENGTH_BYTES + 1))).toBeFalse()
		expect(isLookupWorthy("")).toBeFalse()
		for _, notAString in { 7, true, {}, buffer.create(1) } do
			expect(isLookupWorthy(notAString)).toBeFalse()
		end
		expect(isLookupWorthy(nil)).toBeFalse()
	end)
end)

describe("DanceAndCosmeticCatalogEntryFinder with usable catalogs", function()
	for _, catalogEntryUse in BOTH_USES do
		it(
			"returns the catalog's own entry for a known dance and a known cosmetic (" .. catalogEntryUse .. ")",
			function()
				local logger = DanceAndCosmeticRequestTestHarness.createRecordingLogger()
				local danceCatalog = DanceAndCosmeticShopTestCatalogs.createDanceCatalog()
				local cosmeticCatalog = DanceAndCosmeticShopTestCatalogs.createCosmeticCatalog()
				expect(findDance(danceCatalog, logger, "neon_spin", catalogEntryUse)).toBe(
					DanceAndCosmeticShopTestCatalogs.findDanceEntry("neon_spin")
				)
				expect(findCosmetic(cosmeticCatalog, logger, "title_rising_star", catalogEntryUse)).toBe(
					DanceAndCosmeticShopTestCatalogs.findCosmeticEntry("title_rising_star")
				)
				expect(danceCatalog.askedDanceIds).toEqual({ "neon_spin" })
				expect(cosmeticCatalog.askedCosmeticIds).toEqual({ "title_rising_star" })
				expect(#logger.loggedWarnings + #logger.loggedInformation).toBe(0)
			end
		)
	end

	it("returns nil for an id the catalog does not hold, without logging", function()
		local logger = DanceAndCosmeticRequestTestHarness.createRecordingLogger()
		local danceCatalog = DanceAndCosmeticShopTestCatalogs.createDanceCatalog()
		local cosmeticCatalog = DanceAndCosmeticShopTestCatalogs.createCosmeticCatalog()
		expect(findDance(danceCatalog, logger, "ghost_shuffle", PURCHASE)).toBeNil()
		expect(findCosmetic(cosmeticCatalog, logger, "title_nobody", EQUIP)).toBeNil()
		expect(danceCatalog.askedDanceIds).toEqual({ "ghost_shuffle" })
		expect(#logger.loggedWarnings + #logger.loggedInformation).toBe(0)
	end)

	it("accepts a free entry (starCoinPrice 0) for a purchase", function()
		local logger = DanceAndCosmeticRequestTestHarness.createRecordingLogger()
		local freeDanceEntry = createDanceEntry("free_dance", 0)
		local freeCosmeticEntry = createCosmeticEntry("title_free", "Title", 0)
		expect(findDance(createDanceCatalogAnswering("free_dance", freeDanceEntry), logger, "free_dance", PURCHASE)).toBe(
			freeDanceEntry
		)
		expect(
			findCosmetic(
				createCosmeticCatalogAnswering("title_free", freeCosmeticEntry),
				logger,
				"title_free",
				PURCHASE
			)
		).toBe(freeCosmeticEntry)
	end)

	it("accepts every cosmetic kind of spec 1.7", function()
		local logger = DanceAndCosmeticRequestTestHarness.createRecordingLogger()
		for _, cosmeticKind in { "Title", "NameplateStyle", "StageEntranceEffect" } do
			local cosmeticEntry = createCosmeticEntry("kind_probe", cosmeticKind, 300)
			for _, catalogEntryUse in BOTH_USES do
				expect(
					findCosmetic(
						createCosmeticCatalogAnswering("kind_probe", cosmeticEntry),
						logger,
						"kind_probe",
						catalogEntryUse
					)
				).toBe(cosmeticEntry)
			end
		end
		expect(#logger.loggedWarnings).toBe(0)
	end)
end)

describe("DanceAndCosmeticCatalogEntryFinder with untrusted ids", function()
	it("looks up ids of 1 and of exactly MAXIMUM_UNTRUSTED_DANCE_OR_COSMETIC_ID_LENGTH_BYTES bytes", function()
		local logger = DanceAndCosmeticRequestTestHarness.createRecordingLogger()
		local longestDanceId = string.rep("d", MAXIMUM_LENGTH_BYTES)
		local longestDanceEntry = createDanceEntry(longestDanceId, 10)
		expect(
			findDance(createDanceCatalogAnswering(longestDanceId, longestDanceEntry), logger, longestDanceId, PURCHASE)
		).toBe(longestDanceEntry)
		local longestCosmeticId = string.rep("c", MAXIMUM_LENGTH_BYTES)
		local longestCosmeticEntry = createCosmeticEntry(longestCosmeticId, "Title", 10)
		expect(
			findCosmetic(
				createCosmeticCatalogAnswering(longestCosmeticId, longestCosmeticEntry),
				logger,
				longestCosmeticId,
				EQUIP
			)
		).toBe(longestCosmeticEntry)
		local shortestDanceEntry = createDanceEntry("x", 10)
		expect(findDance(createDanceCatalogAnswering("x", shortestDanceEntry), logger, "x", EQUIP)).toBe(
			shortestDanceEntry
		)
	end)

	it("never asks the catalog about a non-string, an empty string or an over-long string", function()
		local logger = DanceAndCosmeticRequestTestHarness.createRecordingLogger()
		local danceCatalog = DanceAndCosmeticShopTestCatalogs.createDanceCatalog()
		local cosmeticCatalog = DanceAndCosmeticShopTestCatalogs.createCosmeticCatalog()
		local overLongId = string.rep("n", MAXIMUM_LENGTH_BYTES + 1)
		local untrustedIds = table.pack(nil, 7, true, {}, "", overLongId, string.rep("z", 1_000_000))
		for untrustedIdPosition = 1, untrustedIds.n do
			local untrustedId = untrustedIds[untrustedIdPosition]
			for _, catalogEntryUse in BOTH_USES do
				expect(findDance(danceCatalog, logger, untrustedId, catalogEntryUse)).toBeNil()
				expect(findCosmetic(cosmeticCatalog, logger, untrustedId, catalogEntryUse)).toBeNil()
			end
		end
		expect(#danceCatalog.askedDanceIds).toBe(0)
		expect(#cosmeticCatalog.askedCosmeticIds).toBe(0)
		expect(#logger.loggedWarnings + #logger.loggedInformation).toBe(0)
	end)

	it("does not find an over-long id even when a catalog would hold it", function()
		local logger = DanceAndCosmeticRequestTestHarness.createRecordingLogger()
		local overLongId = string.rep("o", MAXIMUM_LENGTH_BYTES + 1)
		expect(
			findDance(
				createDanceCatalogAnswering(overLongId, createDanceEntry(overLongId, 5)),
				logger,
				overLongId,
				PURCHASE
			)
		).toBeNil()
		expect(
			findCosmetic(
				createCosmeticCatalogAnswering(overLongId, createCosmeticEntry(overLongId, "Title", 5)),
				logger,
				overLongId,
				EQUIP
			)
		).toBeNil()
	end)
end)

describe("DanceAndCosmeticCatalogEntryFinder with unusable catalog entries", function()
	-- { caseName, entry, expected problem text, unusable for which uses }
	local unusableDanceEntryCases = {
		{ "an entry that is not a table", true, "not a table", BOTH_USES },
		{ "an entry that is a number", 7, "not a table", BOTH_USES },
		{
			"a danceId that differs from the id",
			createDanceEntry("other_dance", 10),
			"its danceId differs from the id it was found by",
			BOTH_USES,
		},
		{
			"a negative price",
			createDanceEntry("broken_dance", -1),
			"starCoinPrice is not a whole number >= 0",
			{ PURCHASE },
		},
		{
			"a fractional price",
			createDanceEntry("broken_dance", 1.5),
			"starCoinPrice is not a whole number",
			{ PURCHASE },
		},
		{ "a NaN price", createDanceEntry("broken_dance", 0 / 0), "starCoinPrice is not a whole number", { PURCHASE } },
		{
			"an infinite price",
			createDanceEntry("broken_dance", math.huge),
			"starCoinPrice is not a whole number",
			{ PURCHASE },
		},
		{
			"a price given as text",
			createDanceEntry("broken_dance", "900"),
			"starCoinPrice is not a whole number",
			{ PURCHASE },
		},
		{ "no price", createDanceEntry("broken_dance", nil), "starCoinPrice is not a whole number", { PURCHASE } },
	}
	for _, unusableCase in unusableDanceEntryCases do
		local caseName, danceEntry, expectedProblem, unusableUses =
			unusableCase[1], unusableCase[2], unusableCase[3], unusableCase[4]
		for _, catalogEntryUse in BOTH_USES do
			local isUnusable = table.find(unusableUses, catalogEntryUse) ~= nil
			local expectation = if isUnusable then "treats as absent and logs" else "returns as usable"
			it(string.format("%s a dance entry with %s (%s)", expectation, caseName, catalogEntryUse), function()
				local logger = DanceAndCosmeticRequestTestHarness.createRecordingLogger()
				local danceCatalog = createDanceCatalogAnswering("broken_dance", danceEntry)
				if isUnusable then
					expect(findDance(danceCatalog, logger, "broken_dance", catalogEntryUse)).toBeNil()
					expectOneWarningContaining(logger, { 'dance catalog entry "broken_dance"', expectedProblem })
				else
					expect(findDance(danceCatalog, logger, "broken_dance", catalogEntryUse)).toBe(danceEntry)
					expect(#logger.loggedWarnings).toBe(0)
				end
			end)
		end
	end

	local KIND_PROBLEM = "cosmeticKind is not one of the cosmetic kinds of spec 1.7"
	local unusableCosmeticEntryCases = {
		{ "an entry that is not a table", true, "not a table", BOTH_USES },
		{ "an entry that is a number", 7, "not a table", BOTH_USES },
		{
			"a cosmeticId that differs from the id",
			createCosmeticEntry("title_other", "Title", 10),
			"its cosmeticId differs from the id it was found by",
			BOTH_USES,
		},
		{ "no cosmeticKind", createCosmeticEntry("title_broken", nil, 300), KIND_PROBLEM, BOTH_USES },
		{ "an empty cosmeticKind", createCosmeticEntry("title_broken", "", 300), KIND_PROBLEM, BOTH_USES },
		{ "a cosmeticKind that is not text", createCosmeticEntry("title_broken", 3, 300), KIND_PROBLEM, BOTH_USES },
		{
			"a cosmeticKind outside spec 1.7",
			createCosmeticEntry("title_broken", "Sticker", 300),
			KIND_PROBLEM,
			BOTH_USES,
		},
		{
			"a cosmeticKind in other letter case",
			createCosmeticEntry("title_broken", "title", 300),
			KIND_PROBLEM,
			BOTH_USES,
		},
		{
			"a negative price",
			createCosmeticEntry("title_broken", "Title", -300),
			"starCoinPrice is not a whole number >= 0",
			{ PURCHASE },
		},
		{
			"a fractional price",
			createCosmeticEntry("title_broken", "Title", 0.5),
			"starCoinPrice is not a whole",
			{ PURCHASE },
		},
		{
			"a NaN price",
			createCosmeticEntry("title_broken", "Title", 0 / 0),
			"starCoinPrice is not a whole",
			{ PURCHASE },
		},
		{
			"an infinite price",
			createCosmeticEntry("title_broken", "Title", math.huge),
			"starCoinPrice is not a whole",
			{ PURCHASE },
		},
		{ "no price", createCosmeticEntry("title_broken", "Title", nil), "starCoinPrice is not a whole", { PURCHASE } },
	}
	for _, unusableCase in unusableCosmeticEntryCases do
		local caseName, cosmeticEntry, expectedProblem, unusableUses =
			unusableCase[1], unusableCase[2], unusableCase[3], unusableCase[4]
		for _, catalogEntryUse in BOTH_USES do
			local isUnusable = table.find(unusableUses, catalogEntryUse) ~= nil
			local expectation = if isUnusable then "treats as absent and logs" else "returns as usable"
			it(string.format("%s a cosmetic entry with %s (%s)", expectation, caseName, catalogEntryUse), function()
				local logger = DanceAndCosmeticRequestTestHarness.createRecordingLogger()
				local cosmeticCatalog = createCosmeticCatalogAnswering("title_broken", cosmeticEntry)
				if isUnusable then
					expect(findCosmetic(cosmeticCatalog, logger, "title_broken", catalogEntryUse)).toBeNil()
					expectOneWarningContaining(logger, { 'cosmetic catalog entry "title_broken"', expectedProblem })
				else
					expect(findCosmetic(cosmeticCatalog, logger, "title_broken", catalogEntryUse)).toBe(cosmeticEntry)
					expect(#logger.loggedWarnings).toBe(0)
				end
			end)
		end
	end
end)

describe("Dance-shop requests over unusable catalog entries", function()
	it("refuses to sell an entry with a bad price but equips it when owned (the price plays no part)", function()
		local shopHarness = DanceAndCosmeticRequestTestHarness.createShopHarness(function(saveData)
			saveData.starCoinBalance = 1000
			table.insert(saveData.ownedDanceIds, "neon_spin")
			saveData.ownedCosmeticIds = { "title_rising_star" }
		end, {
			danceCatalog = createDanceCatalogAnswering("neon_spin", createDanceEntry("neon_spin", -5)),
			cosmeticCatalog = createCosmeticCatalogAnswering(
				"title_rising_star",
				createCosmeticEntry("title_rising_star", "Title", 0 / 0)
			),
		})
		local player = DanceAndCosmeticRequestTestHarness.PLAYER
		local saveDataBefore = shopHarness.readInMemorySaveData()
		expect(shopHarness.purchaseRequestAnswerer:purchaseDanceWithStarCoinsAndBuildAnswer(player, "neon_spin")).toEqual({
			isAccepted = false,
			rejectionReason = "UnknownDance",
		})
		expect(
			shopHarness.purchaseRequestAnswerer:purchaseCosmeticWithStarCoinsAndBuildAnswer(player, "title_rising_star")
		).toEqual({ isAccepted = false, rejectionReason = "UnknownCosmetic" })
		expect(shopHarness.readInMemorySaveData()).toEqual(saveDataBefore)
		expect(#shopHarness.shopLogger.loggedWarnings).toBe(2)

		expect(shopHarness.equipRequestAnswerer:equipOwnedDanceAndBuildAnswer(player, "neon_spin")).toEqual({
			isAccepted = true,
		})
		expect(shopHarness.equipRequestAnswerer:equipOwnedCosmeticAndBuildAnswer(player, "title_rising_star")).toEqual({
			isAccepted = true,
		})
		local saveDataAfter = shopHarness.readInMemorySaveData()
		expect(saveDataAfter.equippedDanceId).toBe("neon_spin")
		expect(saveDataAfter.equippedCosmeticIdByKind).toEqual({ Title = "title_rising_star" })
		expect(#shopHarness.shopLogger.loggedWarnings).toBe(2)
	end)

	it("never writes a cosmetic kind outside spec 1.7 into equippedCosmeticIdByKind", function()
		local shopHarness = DanceAndCosmeticRequestTestHarness.createShopHarness(function(saveData)
			saveData.ownedCosmeticIds = { "title_rising_star" }
			saveData.equippedCosmeticIdByKind = { Title = "title_rising_star" }
		end, {
			cosmeticCatalog = createCosmeticCatalogAnswering(
				"title_rising_star",
				createCosmeticEntry("title_rising_star", "Sticker", 300)
			),
		})
		local saveDataBefore = shopHarness.readInMemorySaveData()
		local inMemoryRevisionBefore = shopHarness.readSaveChangeRevisions()
		-- Owned and already equipped under Title: the re-equip is accepted and changes nothing.
		expect(
			shopHarness.equipRequestAnswerer:equipOwnedCosmeticAndBuildAnswer(
				DanceAndCosmeticRequestTestHarness.PLAYER,
				"title_rising_star"
			)
		).toEqual({ isAccepted = true })
		expect(shopHarness.readInMemorySaveData()).toEqual(saveDataBefore)
		expect((shopHarness.readSaveChangeRevisions())).toBe(inMemoryRevisionBefore)
		expect(#shopHarness.shopLogger.loggedWarnings).toBe(1)
	end)

	it("refuses an owned, unequipped cosmetic whose kind is outside spec 1.7, writing nothing", function()
		local shopHarness = DanceAndCosmeticRequestTestHarness.createShopHarness(function(saveData)
			saveData.ownedCosmeticIds = { "title_rising_star" }
		end, {
			cosmeticCatalog = createCosmeticCatalogAnswering(
				"title_rising_star",
				createCosmeticEntry("title_rising_star", "Sticker", 300)
			),
		})
		local saveDataBefore = shopHarness.readInMemorySaveData()
		expect(
			shopHarness.equipRequestAnswerer:equipOwnedCosmeticAndBuildAnswer(
				DanceAndCosmeticRequestTestHarness.PLAYER,
				"title_rising_star"
			)
		).toEqual({ isAccepted = false, rejectionReason = "CosmeticNotOwned" })
		expect(shopHarness.readInMemorySaveData()).toEqual(saveDataBefore)
	end)
end)
