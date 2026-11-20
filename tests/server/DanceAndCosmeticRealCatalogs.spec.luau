-- The dance-shop answerers and DanceAndCosmeticCatalogEntryFinder against the REAL catalogs
-- (src/shared/DanceCatalog.luau, src/shared/CosmeticCatalog.luau), as the server wiring passes
-- them: every real id fits the finder's id limit and is found for both uses, and a real cosmetic
-- and a real starter dance can be bought and equipped.

local CosmeticCatalog = require("../../src/shared/CosmeticCatalog")
local DanceAndCosmeticCatalogEntryFinder = require("../../src/server/DanceAndCosmeticCatalogEntryFinder")
local DanceAndCosmeticRequestTestHarness = require("./DanceAndCosmeticRequestTestHarness")
local DanceCatalog = require("../../src/shared/DanceCatalog")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = DanceAndCosmeticRequestTestHarness.PLAYER
local MAXIMUM_LENGTH_BYTES = DanceAndCosmeticCatalogEntryFinder.MAXIMUM_UNTRUSTED_DANCE_OR_COSMETIC_ID_LENGTH_BYTES
local CATALOG_ENTRY_USES = DanceAndCosmeticCatalogEntryFinder.CATALOG_ENTRY_USES

local function createHarnessOverRealCatalogs(adjustStartingSaveData: (any) -> ())
	return DanceAndCosmeticRequestTestHarness.createShopHarness(adjustStartingSaveData, {
		danceCatalog = DanceCatalog,
		cosmeticCatalog = CosmeticCatalog,
	})
end

describe("DanceAndCosmeticCatalogEntryFinder over the real catalogs", function()
	it("finds every real dance, for a purchase and for an equip, and every id fits the limit", function()
		local logger = DanceAndCosmeticRequestTestHarness.createRecordingLogger()
		expect(#DanceCatalog.DANCES > 0).toBeTrue()
		for _, dance in DanceCatalog.DANCES do
			expect(#dance.danceId >= 1 and #dance.danceId <= MAXIMUM_LENGTH_BYTES).toBeTrue()
			for _, catalogEntryUse in { CATALOG_ENTRY_USES.Purchase, CATALOG_ENTRY_USES.Equip } do
				expect(
					DanceAndCosmeticCatalogEntryFinder.findDanceForUntrustedDanceId(
						DanceCatalog,
						logger,
						dance.danceId,
						catalogEntryUse
					)
				).toBe(dance)
			end
		end
		expect(#logger.loggedWarnings).toBe(0)
	end)

	it("finds every real cosmetic, for a purchase and for an equip, and every id fits the limit", function()
		local logger = DanceAndCosmeticRequestTestHarness.createRecordingLogger()
		expect(#CosmeticCatalog.COSMETICS > 0).toBeTrue()
		for _, cosmetic in CosmeticCatalog.COSMETICS do
			expect(#cosmetic.cosmeticId >= 1 and #cosmetic.cosmeticId <= MAXIMUM_LENGTH_BYTES).toBeTrue()
			for _, catalogEntryUse in { CATALOG_ENTRY_USES.Purchase, CATALOG_ENTRY_USES.Equip } do
				expect(
					DanceAndCosmeticCatalogEntryFinder.findCosmeticForUntrustedCosmeticId(
						CosmeticCatalog,
						logger,
						cosmetic.cosmeticId,
						catalogEntryUse
					)
				).toBe(cosmetic)
			end
		end
		expect(#logger.loggedWarnings).toBe(0)
	end)
end)

describe("Dance-shop requests over the real catalogs", function()
	it("buys a real cosmetic at its catalog price and equips it", function()
		local titleRisingStar = CosmeticCatalog.findCosmeticByCosmeticId("title_rising_star")
		local shopHarness = createHarnessOverRealCatalogs(DanceAndCosmeticRequestTestHarness.giveStarCoinBalance(1000))
		expect(
			shopHarness.purchaseRequestAnswerer:purchaseCosmeticWithStarCoinsAndBuildAnswer(PLAYER, "title_rising_star")
		).toEqual({ isAccepted = true })
		expect(shopHarness.equipRequestAnswerer:equipOwnedCosmeticAndBuildAnswer(PLAYER, "title_rising_star")).toEqual({
			isAccepted = true,
		})
		local saveDataAfter = shopHarness.readInMemorySaveData()
		expect(saveDataAfter.starCoinBalance).toBe(1000 - titleRisingStar.starCoinPrice)
		expect(saveDataAfter.ownedCosmeticIds).toEqual({ "title_rising_star" })
		expect(saveDataAfter.equippedCosmeticIdByKind).toEqual({ Title = "title_rising_star" })
	end)

	it("sells a real starter dance the save lacks for 0 and equips it", function()
		local starterDanceIds = DanceCatalog.listDanceIdsGrantedToNewPlayers()
		local missingStarterDanceId = starterDanceIds[#starterDanceIds]
		local shopHarness = createHarnessOverRealCatalogs(function(saveData)
			saveData.starCoinBalance = 40
			saveData.ownedDanceIds = { starterDanceIds[1] }
			saveData.equippedDanceId = starterDanceIds[1]
		end)
		expect(
			shopHarness.purchaseRequestAnswerer:purchaseDanceWithStarCoinsAndBuildAnswer(PLAYER, missingStarterDanceId)
		).toEqual({ isAccepted = true })
		expect(shopHarness.equipRequestAnswerer:equipOwnedDanceAndBuildAnswer(PLAYER, missingStarterDanceId)).toEqual({
			isAccepted = true,
		})
		local saveDataAfter = shopHarness.readInMemorySaveData()
		expect(saveDataAfter.starCoinBalance).toBe(40)
		expect(saveDataAfter.ownedDanceIds).toEqual({ starterDanceIds[1], missingStarterDanceId })
		expect(saveDataAfter.equippedDanceId).toBe(missingStarterDanceId)
		expect(#shopHarness.shopLogger.loggedWarnings).toBe(0)
	end)
end)
