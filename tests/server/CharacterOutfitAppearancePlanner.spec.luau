-- The §3.7 dressing decision, checked against the seven development items as the REAL resolver
-- resolves them from the engine answers captured in Studio (asset types HairAccessory,
-- JacketAccessory, DressSkirtAccessory, NeckAccessory, FaceAccessory, a shoes bundle of
-- LeftShoeAccessory + RightShoeAccessory, LipMakeup).

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local RecordingLogger = require("../Support/RecordingLogger")
local CapturedAnswerMarketplaceItemLookups = require("../fixtures/CapturedAnswerMarketplaceItemLookups")
local CharacterOutfitAppearancePlanner = require("../../src/server/CharacterOutfitAppearancePlanner")
local MarketplaceStylingItemResolver = require("../../src/server/MarketplaceStylingItemResolver")
local StylingItemPool = require("../../src/shared/generated/StylingItemPool")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local HAIR = "asset_7259123616"
local JACKET_TOP = "asset_9122110415"
local DRESS = "asset_9438759973"
local TURTLE_NECK = "asset_4378579302"
local GLASSES = "asset_11884330"
local SHOES_BUNDLE = "bundle_98186475028072"
local LIP_MAKEUP = "asset_106390919006817"

local OWN_EYEBROWS =
	{ accessoryTypeName = "Eyebrow", assetId = 10725837187, isLayered = true, layeredClothingOrder = 0 }
local OWN_HAT = { accessoryTypeName = "Hat", assetId = 6833263240, isLayered = false }

local function createResolvedDevelopmentResolver()
	local fakeScheduler = FakeScheduler.new(FakeClock.new(1_800_000_000))
	local resolver = MarketplaceStylingItemResolver.new({
		stylingItems = StylingItemPool.STYLING_ITEMS,
		marketplaceItemLookups = CapturedAnswerMarketplaceItemLookups.new(),
		scheduler = fakeScheduler,
		logger = RecordingLogger.new(),
	})
	resolver:startResolvingWardrobeCatalog()
	fakeScheduler:advanceTimeAndRunDueCallbacks(1)
	assert(resolver:isWardrobeCatalogReady(), "the development pool must resolve from the captured answers")
	return resolver
end

local developmentResolver = createResolvedDevelopmentResolver()

local function plan(outfitStylingItemKeys: { string }, currentAccessoryEntries: { any }?)
	return CharacterOutfitAppearancePlanner.planCharacterAppearanceForOutfit({
		outfitStylingItemKeys = outfitStylingItemKeys,
		readResolvedStylingItemDetails = function(stylingItemKey)
			return developmentResolver:readResolvedStylingItemDetails(stylingItemKey)
		end,
		currentAccessoryEntries = currentAccessoryEntries or {},
	})
end

local function findEntryByAssetId(accessoryEntries, assetId: number)
	for _, accessoryEntry in accessoryEntries do
		if accessoryEntry.assetId == assetId then
			return accessoryEntry
		end
	end
	return nil
end

describe("CharacterOutfitAppearancePlanner with the seven development items", function()
	it("places each rigid item (hair, turtle neck, glasses) without an order", function()
		local appearancePlan = plan({ HAIR, TURTLE_NECK, GLASSES })
		expect(appearancePlan.accessoryEntries).toEqual({
			{ accessoryTypeName = "Hair", assetId = 7259123616, isLayered = false },
			{ accessoryTypeName = "Neck", assetId = 4378579302, isLayered = false },
			{ accessoryTypeName = "Face", assetId = 11884330, isLayered = false },
		})
		for _, accessoryEntry in appearancePlan.accessoryEntries do
			expect(accessoryEntry.layeredClothingOrder).toBeNil()
		end
	end)

	it("wears the shoes bundle as its left and right shoe, layered, below the dress", function()
		local appearancePlan = plan({ DRESS, SHOES_BUNDLE })
		local dressEntry = findEntryByAssetId(appearancePlan.accessoryEntries, 9438759973)
		local leftShoeEntry = findEntryByAssetId(appearancePlan.accessoryEntries, 84885203198436)
		local rightShoeEntry = findEntryByAssetId(appearancePlan.accessoryEntries, 90774383444285)
		expect(dressEntry).toEqual({
			accessoryTypeName = "DressSkirt",
			assetId = 9438759973,
			isLayered = true,
			layeredClothingOrder = 3,
		})
		expect(leftShoeEntry.accessoryTypeName).toBe("LeftShoe")
		expect(rightShoeEntry.accessoryTypeName).toBe("RightShoe")
		expect(leftShoeEntry.isLayered and rightShoeEntry.isLayered).toBeTrue()
		expect(leftShoeEntry.layeredClothingOrder < dressEntry.layeredClothingOrder).toBeTrue()
		expect(rightShoeEntry.layeredClothingOrder < dressEntry.layeredClothingOrder).toBeTrue()
		expect(#appearancePlan.accessoryEntries).toBe(3)
		expect(appearancePlan.wornStylingItemKeys).toEqual({ DRESS, SHOES_BUNDLE })
		expect(appearancePlan.skippedWornAssets).toEqual({})
	end)

	it(
		"puts the jacket above the shoes and every bottom and dress, and keeps the order whatever the outfit order",
		function()
			local appearancePlan = plan({ JACKET_TOP, SHOES_BUNDLE })
			local jacketEntry = findEntryByAssetId(appearancePlan.accessoryEntries, 9122110415)
			expect(jacketEntry).toEqual({
				accessoryTypeName = "Jacket",
				assetId = 9122110415,
				isLayered = true,
				layeredClothingOrder = 7,
			})
			local orders = CharacterOutfitAppearancePlanner.LAYERED_CLOTHING_ORDER_BY_ACCESSORY_TYPE_NAME
			for _, lowerTypeName in
				{ "LeftShoe", "RightShoe", "Pants", "Shorts", "DressSkirt", "TShirt", "Shirt", "Sweater" }
			do
				expect(orders[lowerTypeName] < orders.Jacket).toBeTrue()
			end
			for _, bottomTypeName in { "Pants", "Shorts", "DressSkirt" } do
				expect(orders.LeftShoe < orders[bottomTypeName]).toBeTrue()
			end
			expect(orders.TShirt < orders.Sweater and orders.Shirt < orders.Sweater).toBeTrue()
		end
	)

	it("applies the lip makeup as a Lip makeup entry and never as an accessory", function()
		local appearancePlan = plan({ LIP_MAKEUP })
		expect(appearancePlan.makeupEntries).toEqual({
			{ makeupTypeName = "Lip", assetId = 106390919006817, makeupOrder = 3 },
		})
		expect(appearancePlan.accessoryEntries).toEqual({})
	end)

	it("dresses the full valid seven-slot outfit (dress version) with every worn asset placed", function()
		local appearancePlan = plan({ HAIR, DRESS, TURTLE_NECK, GLASSES, SHOES_BUNDLE, LIP_MAKEUP })
		expect(#appearancePlan.accessoryEntries).toBe(6)
		expect(#appearancePlan.makeupEntries).toBe(1)
		expect(appearancePlan.skippedStylingItemKeys).toEqual({})
		expect(appearancePlan.skippedWornAssets).toEqual({})
		expect(#appearancePlan.wornStylingItemKeys).toBe(6)
	end)

	it("replaces the classic shirt, pants and T-shirt with nothing when the outfit has none", function()
		expect(plan({ HAIR }).classicClothingAssetIdByDescriptionPropertyName).toEqual({
			Shirt = 0,
			Pants = 0,
			GraphicTShirt = 0,
		})
	end)

	it("drops every own rigid accessory and layered piece but keeps the player's own eyebrows", function()
		local appearancePlan = plan({ HAIR }, {
			OWN_EYEBROWS,
			OWN_HAT,
			{ accessoryTypeName = "Jacket", assetId = 55, isLayered = true, layeredClothingOrder = 2 },
		})
		expect(appearancePlan.accessoryEntries).toEqual({
			OWN_EYEBROWS,
			{ accessoryTypeName = "Hair", assetId = 7259123616, isLayered = false },
		})
	end)

	it("gives an empty outfit an empty appearance apart from the player's own eyebrows", function()
		local appearancePlan = plan({}, { OWN_EYEBROWS, OWN_HAT })
		expect(appearancePlan.accessoryEntries).toEqual({ OWN_EYEBROWS })
		expect(appearancePlan.makeupEntries).toEqual({})
	end)
end)

describe("CharacterOutfitAppearancePlanner edge cases", function()
	local function planWithWornAssets(wornAssetsByStylingItemKey, outfitStylingItemKeys, currentAccessoryEntries)
		return CharacterOutfitAppearancePlanner.planCharacterAppearanceForOutfit({
			outfitStylingItemKeys = outfitStylingItemKeys,
			readResolvedStylingItemDetails = function(stylingItemKey)
				local wornAssets = wornAssetsByStylingItemKey[stylingItemKey]
				return if wornAssets then { wornAssets = wornAssets } else nil
			end,
			currentAccessoryEntries = currentAccessoryEntries or {},
		})
	end

	it("skips an item the resolver does not report (hidden this session) and lists it", function()
		local appearancePlan = planWithWornAssets({}, { "asset_1" })
		expect(appearancePlan.skippedStylingItemKeys).toEqual({ "asset_1" })
		expect(appearancePlan.accessoryEntries).toEqual({})
	end)

	it("skips a worn asset of a type the game does not dress, and still wears the item's other assets", function()
		local appearancePlan = planWithWornAssets({
			odd_item = {
				{ wornAssetId = 1, robloxAssetTypeName = "EarAccessory" },
				{ wornAssetId = 2, robloxAssetTypeName = "WaistAccessory" },
			},
		}, { "odd_item" })
		expect(appearancePlan.skippedWornAssets).toEqual({
			{ stylingItemKey = "odd_item", wornAssetId = 1, robloxAssetTypeName = "EarAccessory" },
		})
		expect(appearancePlan.accessoryEntries).toEqual({
			{ accessoryTypeName = "Waist", assetId = 2, isLayered = false },
		})
		expect(appearancePlan.wornStylingItemKeys).toEqual({ "odd_item" })
	end)

	it("never lists the same asset id twice", function()
		local appearancePlan = planWithWornAssets({
			first = { { wornAssetId = 7, robloxAssetTypeName = "HairAccessory" } },
			second = { { wornAssetId = 7, robloxAssetTypeName = "HairAccessory" } },
		}, { "first", "second" })
		expect(#appearancePlan.accessoryEntries).toBe(1)
	end)

	it("replaces the own eyebrows when the outfit wears eyebrows, and orders facial features at 0", function()
		local appearancePlan = planWithWornAssets({
			brows = { { wornAssetId = 99, robloxAssetTypeName = "EyebrowAccessory" } },
		}, { "brows" }, { OWN_EYEBROWS })
		expect(appearancePlan.accessoryEntries).toEqual({
			{ accessoryTypeName = "Eyebrow", assetId = 99, isLayered = true, layeredClothingOrder = 0 },
		})
	end)

	it("puts classic clothing into the description properties", function()
		local appearancePlan = planWithWornAssets({
			classic = {
				{ wornAssetId = 11, robloxAssetTypeName = "Shirt" },
				{ wornAssetId = 12, robloxAssetTypeName = "Pants" },
				{ wornAssetId = 13, robloxAssetTypeName = "TShirt" },
			},
		}, { "classic" })
		expect(appearancePlan.classicClothingAssetIdByDescriptionPropertyName).toEqual({
			Shirt = 11,
			Pants = 12,
			GraphicTShirt = 13,
		})
	end)

	it("orders makeup face below eye below lip", function()
		local orders = CharacterOutfitAppearancePlanner.MAKEUP_ORDER_BY_MAKEUP_TYPE_NAME
		expect(orders.Face < orders.Eye and orders.Eye < orders.Lip).toBeTrue()
	end)
end)
