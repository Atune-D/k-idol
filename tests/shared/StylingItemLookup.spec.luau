local UnitTestFramework = require("../Support/UnitTestFramework")
local StylingItemLookup = require("../../src/shared/StylingItemLookup")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

describe("StylingItemLookup.deriveStylingItemKey", function()
	it("derives asset_<id> and bundle_<id> (spec §1.2)", function()
		expect(StylingItemLookup.deriveStylingItemKey("Asset", 1234567890)).toBe("asset_1234567890")
		expect(StylingItemLookup.deriveStylingItemKey("Bundle", 9000041)).toBe("bundle_9000041")
	end)

	it("raises for an unknown kind or an id that is not a positive whole number", function()
		expect(function()
			StylingItemLookup.deriveStylingItemKey("asset", 1)
		end).toThrow("unknown marketplaceItemKind")
		for _, badMarketplaceItemId in { 0, -1, 1.5, math.huge, 0 / 0 } do
			expect(function()
				StylingItemLookup.deriveStylingItemKey("Asset", badMarketplaceItemId)
			end).toThrow("not a positive whole number")
		end
	end)
end)

describe("StylingItemLookup kind rules", function()
	it("requires Bundle for shoes and Asset for every other slot (spec §1.2)", function()
		expect(StylingItemLookup.getRequiredMarketplaceItemKindForItemSlot("shoes")).toBe("Bundle")
		for _, itemSlot in
			{
				"hair",
				"top",
				"bottom",
				"dress",
				"accessory",
				"makeup_eyes",
				"makeup_lips",
				"makeup_face",
				"eyelashes",
				"eyebrows",
			}
		do
			expect(StylingItemLookup.getRequiredMarketplaceItemKindForItemSlot(itemSlot)).toBe("Asset")
		end
	end)

	it("knows exactly the kinds Asset and Bundle", function()
		expect(StylingItemLookup.isKnownMarketplaceItemKind("Asset")).toBeTrue()
		expect(StylingItemLookup.isKnownMarketplaceItemKind("Bundle")).toBeTrue()
		for _, unknownKind in { "asset", "bundle", "", "Item", 1 } do
			expect(StylingItemLookup.isKnownMarketplaceItemKind(unknownKind)).toBeFalse()
		end
		expect(StylingItemLookup.isKnownMarketplaceItemKind(nil)).toBeFalse()
	end)
end)

describe("StylingItemLookup.buildStylingItemByStylingItemKey", function()
	it("maps every key, disabled ones included, and is frozen", function()
		local lookup = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY
		for _, fakeStylingItem in FakeStylingItemPool.FAKE_STYLING_ITEMS do
			expect(lookup[fakeStylingItem.stylingItemKey]).toBe(fakeStylingItem)
		end
		expect(lookup[FakeStylingItemPool.DISABLED_HAIR_KEY].isEnabled).toBeFalse()
		expect(table.isfrozen(lookup)).toBeTrue()
	end)

	it("accepts an empty pool", function()
		expect(StylingItemLookup.buildStylingItemByStylingItemKey({})).toEqual({})
	end)

	it("raises on a duplicated key or a key that does not match its kind and id", function()
		local hairItem = FakeStylingItemPool.FAKE_STYLING_ITEMS[1]
		expect(function()
			StylingItemLookup.buildStylingItemByStylingItemKey({ hairItem, hairItem })
		end).toThrow("appears more than once")
		local mislabelledItem = table.clone(hairItem)
		mislabelledItem.stylingItemKey = "bundle_9000001"
		expect(function()
			StylingItemLookup.buildStylingItemByStylingItemKey({ mislabelledItem :: any })
		end).toThrow("does not match its kind and id")
	end)
end)
