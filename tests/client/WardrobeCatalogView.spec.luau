-- Spec §2.14 and gate 1H: the wardrobe lists exactly the items the server reports as available, with
-- the server's names and prices, grouped by slot, and nothing else.

local UnitTestFramework = require("../Support/UnitTestFramework")
local DeviceTestFixtures = require("./DeviceTestFixtures")
local WardrobeCatalogView = require("../../src/client/WardrobeCatalogView")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local F = DeviceTestFixtures
local POOL = DeviceTestFixtures.STYLING_ITEM_BY_STYLING_ITEM_KEY

local function listGroupedKeys(view)
	local grouped = {}
	for _, group in view.wardrobeSlotGroups do
		local keys = {}
		for _, item in group.wardrobeItems do
			table.insert(keys, item.stylingItemKey)
		end
		table.insert(grouped, { group.itemSlot, keys })
	end
	return grouped
end

describe("WardrobeCatalogView", function()
	it("lists exactly the seven items of the server's snapshot, grouped by slot in wardrobe order", function()
		local view = DeviceTestFixtures.buildDevelopmentWardrobeCatalogView()
		expect(view.isWardrobeCatalogReady).toBeTrue()
		expect(listGroupedKeys(view)).toEqual({
			{ "hair", { DeviceTestFixtures.HAIR } },
			{ "top", { DeviceTestFixtures.JACKET_TOP } },
			{ "dress", { DeviceTestFixtures.DRESS } },
			{ "shoes", { DeviceTestFixtures.SHOES_BUNDLE } },
			{ "accessory", { DeviceTestFixtures.TURTLE_NECK, DeviceTestFixtures.GLASSES } },
			{ "makeup_lips", { DeviceTestFixtures.LIP_MAKEUP } },
		})
		expect(#view.listedStylingItemKeys).toBe(7)
		expect(view.unlistableStylingItemKeys).toEqual({})
	end)

	it("shows the server's names, prices and worn assets unchanged", function()
		local serverAnswer = DeviceTestFixtures.readServerWardrobeCatalogSnapshotAnswer()
		local view = DeviceTestFixtures.buildDevelopmentWardrobeCatalogView()
		for _, serverItem in serverAnswer.wardrobeItems do
			local listedItem = view.wardrobeItemByStylingItemKey[serverItem.stylingItemKey]
			expect(listedItem.itemDisplayName).toBe(serverItem.itemDisplayName)
			expect(listedItem.priceInRobux).toBe(serverItem.priceInRobux)
			expect(listedItem.wornAssets).toEqual(serverItem.wornAssets)
		end
		expect(view.wardrobeItemByStylingItemKey[DeviceTestFixtures.HAIR].itemDisplayName).toBe("Black Messy Hairstyle")
		expect(view.wardrobeItemByStylingItemKey[DeviceTestFixtures.HAIR].priceInRobux).toBe(65)
	end)

	it("does not list a pool item the server leaves out (hidden this session)", function()
		local answer =
			DeviceTestFixtures.buildSnapshotAnswerWithItems({ DeviceTestFixtures.HAIR, DeviceTestFixtures.DRESS })
		local view = WardrobeCatalogView.buildWardrobeCatalogView(answer, POOL)
		expect(view.listedStylingItemKeys).toEqual({ DeviceTestFixtures.HAIR, DeviceTestFixtures.DRESS })
		expect(view.availableStylingItemKeySet).toEqual({
			[DeviceTestFixtures.HAIR] = true,
			[DeviceTestFixtures.DRESS] = true,
		})
	end)

	it(
		"does not list an item the device's pool does not know, is disabled, or appears twice, and reports it",
		function()
			local answer = DeviceTestFixtures.buildSnapshotAnswerWithItems({ DeviceTestFixtures.HAIR })
			table.insert(answer.wardrobeItems, {
				stylingItemKey = "asset_999",
				marketplaceItemKind = "Asset",
				marketplaceItemId = 999,
				itemDisplayName = "Unknown",
				priceInRobux = 5,
				wornAssets = {},
			})
			table.insert(answer.wardrobeItems, answer.wardrobeItems[1])
			local poolWithDisabledDress = table.clone(POOL)
			local disabledDress = table.clone(POOL[DeviceTestFixtures.DRESS])
			disabledDress.isEnabled = false
			poolWithDisabledDress[DeviceTestFixtures.DRESS] = disabledDress
			table.insert(
				answer.wardrobeItems,
				DeviceTestFixtures.buildSnapshotAnswerWithItems({ DeviceTestFixtures.DRESS }).wardrobeItems[1]
			)
			local view = WardrobeCatalogView.buildWardrobeCatalogView(answer, poolWithDisabledDress)
			expect(view.listedStylingItemKeys).toEqual({ DeviceTestFixtures.HAIR })
			expect(view.unlistableStylingItemKeys).toEqual({
				"asset_999",
				DeviceTestFixtures.HAIR,
				DeviceTestFixtures.DRESS,
			})
		end
	)

	it("gives an empty, not-ready view for a not-ready answer and nil for a refused or malformed one", function()
		local notReady = WardrobeCatalogView.buildWardrobeCatalogView(
			{ isAccepted = true, isWardrobeCatalogReady = false, wardrobeCatalogVersion = 0, wardrobeItems = {} },
			POOL
		)
		expect(notReady.isWardrobeCatalogReady).toBeFalse()
		expect(notReady.listedStylingItemKeys).toEqual({})
		-- Not ready means nothing is listed, even if items came along (§2.14: empty while not ready).
		local notReadyWithItems = F.buildSnapshotAnswerWithItems({ F.HAIR })
		notReadyWithItems.isWardrobeCatalogReady = false
		local notReadyView = WardrobeCatalogView.buildWardrobeCatalogView(notReadyWithItems, POOL)
		expect(notReadyView.listedStylingItemKeys).toEqual({})
		expect(notReadyView.availableStylingItemKeySet).toEqual({})
		expect(
			WardrobeCatalogView.buildWardrobeCatalogView(
				{ isAccepted = false, rejectionReason = "TooManyRequests" },
				POOL
			)
		).toBeNil()
		expect(WardrobeCatalogView.buildWardrobeCatalogView(nil, POOL)).toBeNil()
		local badItem = DeviceTestFixtures.buildSnapshotAnswerWithItems({ DeviceTestFixtures.HAIR })
		badItem.wardrobeItems[1] =
			{ stylingItemKey = DeviceTestFixtures.HAIR, itemDisplayName = "x", priceInRobux = "free", wornAssets = {} }
		expect(WardrobeCatalogView.buildWardrobeCatalogView(badItem, POOL)).toBeNil()
	end)

	it("answers worn assets for the preview from the snapshot, and nil for an unlisted key", function()
		local view = DeviceTestFixtures.buildDevelopmentWardrobeCatalogView()
		local readDetails = WardrobeCatalogView.readResolvedStylingItemDetailsFromView(view)
		expect(readDetails(DeviceTestFixtures.SHOES_BUNDLE)).toEqual({
			wornAssets = {
				{ wornAssetId = 84885203198436, robloxAssetTypeName = "LeftShoeAccessory" },
				{ wornAssetId = 90774383444285, robloxAssetTypeName = "RightShoeAccessory" },
			},
		})
		expect(readDetails("asset_1")).toBeNil()
	end)
end)
