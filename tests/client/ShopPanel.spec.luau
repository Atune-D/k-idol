-- The shop panel (§1.7, §2.8): every cosmetic in its group with its catalog name and price, ownership
-- and equipping only from the snapshot, missing coins explained, previews from the shared look data,
-- and the purchasable-dance path with a fixture dance catalog.

local UnitTestFramework = require("../Support/UnitTestFramework")
local LobbyTestFixtures = require("./LobbyTestFixtures")
local CosmeticCatalog = require("../../src/shared/CosmeticCatalog")
local CosmeticPresentationCatalog = require("../../src/shared/CosmeticPresentationCatalog")
local DanceCatalog = require("../../src/shared/DanceCatalog")
local LobbySaveDataSnapshotReader = require("../../src/client/LobbySaveDataSnapshotReader")
local ShopPanelModelBuilder = require("../../src/client/ShopPanelModelBuilder")
local StageEntranceEffectLookCatalog = require("../../src/shared/StageEntranceEffectLookCatalog")
local StageEntranceEffectPreviewDotPlanner = require("../../src/client/StageEntranceEffectPreviewDotPlanner")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function buildModel(snapshotOverrides, shopInputOverrides)
	local shopInputs = {
		lobbySnapshot = if snapshotOverrides == false
			then nil
			else LobbySaveDataSnapshotReader.readLobbySaveDataSnapshot(
				LobbyTestFixtures.buildSnapshotMessage(snapshotOverrides)
			),
		danceCatalogDances = DanceCatalog.DANCES,
		cosmeticCatalog = CosmeticCatalog,
		findCosmeticPresentation = CosmeticPresentationCatalog.findCosmeticPresentation,
		outcomeByRemoteChannelName = {},
	}
	for fieldName, fieldValue in shopInputOverrides or {} do
		shopInputs[fieldName] = fieldValue
	end
	return ShopPanelModelBuilder.buildShopPanelModel(shopInputs)
end

local function findRow(model, itemId)
	for _, group in model.groups do
		for _, itemRow in group.itemRows do
			if itemRow.itemId == itemId then
				return itemRow
			end
		end
	end
	return nil
end

describe("ShopPanelModelBuilder: what is for sale", function()
	it("lists all 47 cosmetics in their three groups, in catalog order, with catalog names and prices", function()
		local model = buildModel()
		expect(#model.groups).toBe(4)
		local expectedTitles = { "Dances", "Titles", "Nameplate styles", "Stage entrance effects" }
		local listedCount = 0
		for groupPosition, group in model.groups do
			expect(group.groupTitleText).toBe(expectedTitles[groupPosition])
		end
		for kindPosition, cosmeticKind in CosmeticCatalog.COSMETIC_KINDS do
			local group = model.groups[kindPosition + 1]
			local catalogCosmetics = CosmeticCatalog.listCosmeticsOfKind(cosmeticKind)
			expect(#group.itemRows).toBe(#catalogCosmetics)
			for rowPosition, itemRow in group.itemRows do
				local cosmetic = catalogCosmetics[rowPosition]
				expect(itemRow.itemId).toBe(cosmetic.cosmeticId)
				expect(itemRow.nameText).toBe(cosmetic.cosmeticDisplayName)
				expect(itemRow.priceText).toBe(
					string.format(
						"%s Star Coins",
						if cosmetic.starCoinPrice >= 1000
							then string.format("%d,%03d", cosmetic.starCoinPrice // 1000, cosmetic.starCoinPrice % 1000)
							else tostring(cosmetic.starCoinPrice)
					)
				)
				expect(itemRow.cosmeticKind).toBe(cosmeticKind)
				listedCount += 1
			end
		end
		expect(listedCount).toBe(47)
	end)

	it("says the real catalog has no dances for sale (only starter dances)", function()
		local danceGroup = buildModel().groups[1]
		expect(#danceGroup.itemRows).toBe(0)
		expect(danceGroup.emptyGroupText).toBe(ShopPanelModelBuilder.NO_DANCES_FOR_SALE_TEXT)
	end)

	it("lists the dances a fixture catalog sells, and not the starter dances", function()
		local model = buildModel(nil, { danceCatalogDances = LobbyTestFixtures.FIXTURE_DANCE_CATALOG.DANCES })
		local danceGroup = model.groups[1]
		expect(danceGroup.emptyGroupText).toBe("")
		expect(#danceGroup.itemRows).toBe(2)
		expect(danceGroup.itemRows[1].itemId).toBe("fixture_spin")
		expect(danceGroup.itemRows[1].shopItemKind).toBe("Dance")
		expect(danceGroup.itemRows[1].priceText).toBe("900 Star Coins")
		expect(danceGroup.itemRows[1].preview).toBeNil()
	end)
end)

describe("ShopPanelModelBuilder: buying and equipping", function()
	it("offers Buy when the balance covers the price, and says how many coins are missing when it does not", function()
		local model = buildModel({ starCoinBalance = 400 })
		local cheap = findRow(model, "title_rising_star") -- 300
		expect(cheap.isBuyButtonVisible).toBe(true)
		expect(cheap.isBuyButtonEnabled).toBe(true)
		expect(cheap.buyButtonText).toBe("Buy for 300 Star Coins")
		expect(cheap.missingStarCoinsText).toBe("")
		local standard = findRow(model, "title_runway_ready") -- 900
		expect(standard.isBuyButtonVisible).toBe(true)
		expect(standard.isBuyButtonEnabled).toBe(false)
		expect(standard.missingStarCoinsText).toBe("You need 500 more Star Coins.")
		local exact = findRow(buildModel({ starCoinBalance = 300 }), "title_rising_star")
		expect(exact.isBuyButtonEnabled).toBe(true)
		expect(model.balanceText).toBe("You have 400 Star Coins")
	end)

	it("shows owned and equipped only from the snapshot, with Equip for an owned item not equipped", function()
		local model = buildModel({
			ownedCosmeticIds = { "title_rising_star", "title_fresh_face", "nameplate_mint_fresh" },
			equippedCosmeticIdByKind = { Title = "title_rising_star" },
		})
		local equipped = findRow(model, "title_rising_star")
		expect(equipped.ownershipText).toBe("Equipped")
		expect(equipped.isEquipped).toBe(true)
		expect(equipped.isOwned).toBe(true)
		expect(findRow(model, "title_stage_rookie").isOwned).toBe(false)
		expect(equipped.isBuyButtonVisible).toBe(false)
		expect(equipped.isEquipButtonVisible).toBe(false)
		local owned = findRow(model, "title_fresh_face")
		expect(owned.ownershipText).toBe("Owned")
		expect(owned.isEquipButtonVisible).toBe(true)
		expect(owned.equipButtonText).toBe("Equip")
		expect(findRow(model, "nameplate_mint_fresh").isEquipButtonVisible).toBe(true)
		expect(findRow(model, "title_stage_rookie").ownershipText).toBe("Not owned yet")
	end)

	it("offers nothing to buy or equip before the first snapshot", function()
		local model = buildModel(false)
		expect(model.loadingText).toBe(ShopPanelModelBuilder.LOADING_TEXT)
		local row = findRow(model, "title_rising_star")
		expect(row.isBuyButtonVisible).toBe(false)
		expect(row.isEquipButtonVisible).toBe(false)
		expect(row.ownershipText).toBe("")
	end)

	it("handles a purchasable fixture dance: buy, then owned with Use on stage, then the stage dance", function()
		local fixtureDances = LobbyTestFixtures.FIXTURE_DANCE_CATALOG.DANCES
		local before =
			findRow(buildModel({ starCoinBalance = 1000 }, { danceCatalogDances = fixtureDances }), "fixture_spin")
		expect(before.isBuyButtonEnabled).toBe(true)
		local wave =
			findRow(buildModel({ starCoinBalance = 1000 }, { danceCatalogDances = fixtureDances }), "fixture_wave")
		expect(wave.missingStarCoinsText).toBe("You need 2,000 more Star Coins.")
		local owned = findRow(
			buildModel({ ownedDanceIds = { "starter_groove", "fixture_spin" } }, { danceCatalogDances = fixtureDances }),
			"fixture_spin"
		)
		expect(owned.isBuyButtonVisible).toBe(false)
		expect(owned.equipButtonText).toBe("Use on stage")
		expect(owned.isEquipButtonVisible).toBe(true)
		local onStage = findRow(
			buildModel(
				{ ownedDanceIds = { "starter_groove", "fixture_spin" }, equippedDanceId = "fixture_spin" },
				{ danceCatalogDances = fixtureDances }
			),
			"fixture_spin"
		)
		expect(onStage.ownershipText).toBe("Your stage dance")
	end)

	it("explains the latest tap on an item, buy or equip, whichever came last", function()
		local function outcomes(purchaseSequenceNumber, equipSequenceNumber)
			return {
				RequestPurchaseCosmeticWithStarCoins = {
					remoteChannelName = "RequestPurchaseCosmeticWithStarCoins",
					requestSubject = "title_rising_star",
					outcomeSequenceNumber = purchaseSequenceNumber,
					isWaitingForAnswer = false,
					answer = { isAccepted = true },
				},
				RequestEquipCosmetic = {
					remoteChannelName = "RequestEquipCosmetic",
					requestSubject = "title_rising_star",
					outcomeSequenceNumber = equipSequenceNumber,
					isWaitingForAnswer = false,
					answer = { isAccepted = true },
				},
			}
		end
		local equippedLast = buildModel(nil, { outcomeByRemoteChannelName = outcomes(1, 2) })
		expect(findRow(equippedLast, "title_rising_star").feedbackText).toBe("Equipped!")
		local boughtLast = buildModel(nil, { outcomeByRemoteChannelName = outcomes(4, 3) })
		expect(findRow(boughtLast, "title_rising_star").feedbackText).toBe("Bought! It will show as yours in a moment.")
	end)

	it("explains the latest buy or equip answer on that item's row only", function()
		local model = buildModel(nil, {
			outcomeByRemoteChannelName = {
				RequestPurchaseCosmeticWithStarCoins = {
					remoteChannelName = "RequestPurchaseCosmeticWithStarCoins",
					requestSubject = "title_superstar",
					isWaitingForAnswer = false,
					answer = { isAccepted = false, rejectionReason = "InsufficientStarCoins" },
				},
			},
		})
		expect(findRow(model, "title_superstar").feedbackText).toBe(
			"You don't have enough Star Coins for that item yet."
		)
		expect(findRow(model, "title_rising_star").feedbackText).toBe("")
	end)
end)

describe("ShopPanelModelBuilder: the balance boundary", function()
	it("with the balance exactly equal to the price, offers Buy and says nothing is missing", function()
		local row = findRow(buildModel({ starCoinBalance = 300 }), "title_rising_star")
		expect(row.isBuyButtonVisible).toBe(true)
		expect(row.isBuyButtonEnabled).toBe(true)
		expect(row.missingStarCoinsText).toBe("")
	end)

	it("with one Star Coin short, does not offer Buy and says 1 more is needed", function()
		local row = findRow(buildModel({ starCoinBalance = 299 }), "title_rising_star")
		expect(row.isBuyButtonVisible).toBe(true)
		expect(row.isBuyButtonEnabled).toBe(false)
		expect(row.missingStarCoinsText).toBe("You need 1 more Star Coin.")
	end)

	it("with one Star Coin over the price, offers Buy and says nothing is missing", function()
		local row = findRow(buildModel({ starCoinBalance = 301 }), "title_rising_star")
		expect(row.isBuyButtonEnabled).toBe(true)
		expect(row.missingStarCoinsText).toBe("")
	end)
end)

describe("ShopPanelModelBuilder: previews", function()
	it("previews a title by its text, a nameplate by its look and an entrance effect by a still dot plan", function()
		local model = buildModel()
		expect(findRow(model, "title_rising_star").preview).toEqual({ previewKind = "Title", titleText = "Rising Star" })
		local nameplatePreview = findRow(model, "nameplate_galaxy_swirl").preview
		expect(nameplatePreview.previewKind).toBe("NameplateStyle")
		expect(nameplatePreview.nameplateStyleLook.nameplateStyleCosmeticId).toBe("nameplate_galaxy_swirl")
		local entrancePreview = findRow(model, "entrance_confetti_pop").preview
		expect(entrancePreview.previewKind).toBe("StageEntranceEffect")
		expect(#entrancePreview.entranceEffectPreview.dots).toBe(24)
	end)
end)

describe("StageEntranceEffectPreviewDotPlanner", function()
	it("clamps a piece that is far outside the view to the box's edge margin", function()
		-- A fixture look: a wide row of curtain panels, most of them far to the sides.
		local wideCurtainLook = {
			stageEntranceEffectCosmeticId = "entrance_fixture_wide_curtain",
			pieceMotion = "RiseAsCurtain",
			pieceShape = "Block",
			pieceMaterial = "SmoothPlastic",
			pieceSizeStuds = { x = 6, y = 6, z = 0.2 },
			pieceColorRgbs = { { r = 200, g = 100, b = 255 } },
			pieceTransparency = 0.2,
			pieceCount = 9,
			effectDurationSeconds = 4,
		}
		local dots = StageEntranceEffectPreviewDotPlanner.planStageEntranceEffectPreview(wideCurtainLook).dots
		expect(dots[1].centerXScale).toBeCloseTo(0.03, 1e-9)
		expect(dots[9].centerXScale).toBeCloseTo(0.97, 1e-9)
		expect(dots[5].centerXScale).toBeCloseTo(0.5, 1e-9)
	end)

	it("draws every piece once, inside the box, at a moment it is fully visible", function()
		for _, look in StageEntranceEffectLookCatalog.STAGE_ENTRANCE_EFFECT_LOOKS do
			local preview = StageEntranceEffectPreviewDotPlanner.planStageEntranceEffectPreview(look)
			expect(#preview.dots).toBe(look.pieceCount)
			for dotPosition, dot in preview.dots do
				expect(dot.centerXScale >= 0 and dot.centerXScale <= 1).toBe(true)
				expect(dot.centerYScale >= 0 and dot.centerYScale <= 1).toBe(true)
				expect(dot.widthScale >= 0.03 and dot.widthScale <= 0.3).toBe(true)
				expect(dot.transparency).toBe(look.pieceTransparency)
				expect(dot.colorRgb).toBe(look.pieceColorRgbs[(dotPosition - 1) % #look.pieceColorRgbs + 1])
			end
			expect(preview.hasLight).toBe(look.light ~= nil)
		end
	end)

	it("places a burst piece where it is halfway through its visible time, seen from the front", function()
		-- Confetti Pop: BurstOutward, piece 1 (index 0) is at the chest (0, 3) at 0.1 D and out at 0.45 D;
		-- the middle of its fully visible time (0.1 D to 0.45 D) is 0.275 D, half way out.
		local look = StageEntranceEffectLookCatalog.findStageEntranceEffectLook("entrance_confetti_pop")
		local dot = StageEntranceEffectPreviewDotPlanner.planStageEntranceEffectPreview(look).dots[1]
		local elevation = -0.6
		local outX = math.cos(0) * math.cos(elevation) * 5
		local outY = 3 + math.sin(elevation) * 5
		expect(dot.centerXScale).toBeCloseTo((outX / 2 + 8) / 16, 1e-9)
		expect(dot.centerYScale).toBeCloseTo(1 - (3 + (outY - 3) / 2) / 16, 1e-9)
	end)
end)
