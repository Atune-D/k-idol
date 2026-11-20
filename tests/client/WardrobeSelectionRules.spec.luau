-- Spec §1.5: tapping items in the wardrobe keeps the selection a valid outfit at every step, using only
-- items the server's catalog lists.

local UnitTestFramework = require("../Support/UnitTestFramework")
local DeviceTestFixtures = require("./DeviceTestFixtures")
local OutfitValidator = require("../../src/shared/OutfitValidator")
local StylingItemLookup = require("../../src/shared/StylingItemLookup")
local WardrobeCatalogView = require("../../src/client/WardrobeCatalogView")
local WardrobeSelectionRules = require("../../src/client/WardrobeSelectionRules")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local F = DeviceTestFixtures
local POOL = F.STYLING_ITEM_BY_STYLING_ITEM_KEY
local VIEW = F.buildDevelopmentWardrobeCatalogView()

local function tap(currentKeys, tappedKey, view, pool)
	return WardrobeSelectionRules.toggleStylingItemInSelection(currentKeys, tappedKey, view or VIEW, pool or POOL)
end

-- A wider fixture pool: two of each single slot, five accessories, every slot kind.
local function buildWidePoolAndView()
	local stylingItems = {}
	local snapshotItems = {}
	local nextId = 1000
	local function add(itemSlot: string)
		nextId += 1
		local kind = if itemSlot == "shoes" then "Bundle" else "Asset"
		local key = StylingItemLookup.deriveStylingItemKey(kind, nextId)
		table.insert(stylingItems, {
			stylingItemKey = key,
			marketplaceItemKind = kind,
			marketplaceItemId = nextId,
			itemSlot = itemSlot,
			styleTags = { "cute" },
			primaryColorTag = "pink",
			isEnabled = true,
		})
		table.insert(snapshotItems, {
			stylingItemKey = key,
			marketplaceItemKind = kind,
			marketplaceItemId = nextId,
			itemDisplayName = itemSlot .. " " .. nextId,
			priceInRobux = 10,
			wornAssets = {},
		})
	end
	for _, itemSlot in OutfitValidator.SINGLE_ITEM_SLOTS do
		add(itemSlot)
		add(itemSlot)
	end
	for _ = 1, 5 do
		add("accessory")
	end
	local pool = StylingItemLookup.buildStylingItemByStylingItemKey(stylingItems)
	local view = WardrobeCatalogView.buildWardrobeCatalogView({
		isAccepted = true,
		isWardrobeCatalogReady = true,
		wardrobeCatalogVersion = 1,
		wardrobeItems = snapshotItems,
	}, pool)
	return pool, view
end

describe("WardrobeSelectionRules", function()
	it("adds a tapped item and removes it when tapped again", function()
		local added = tap({}, F.HAIR)
		expect(added).toEqual({
			isSelectionChanged = true,
			outfitStylingItemKeys = { F.HAIR },
			removedStylingItemKeys = {},
		})
		local removed = tap({ F.HAIR, F.GLASSES }, F.HAIR)
		expect(removed.outfitStylingItemKeys).toEqual({ F.GLASSES })
		expect(removed.removedStylingItemKeys).toEqual({ F.HAIR })
	end)

	it("replaces a top and nothing else when a dress is tapped", function()
		local outcome = tap({ F.HAIR, F.JACKET_TOP, F.GLASSES }, F.DRESS)
		expect(outcome.outfitStylingItemKeys).toEqual({ F.HAIR, F.GLASSES, F.DRESS })
		expect(outcome.removedStylingItemKeys).toEqual({ F.JACKET_TOP })
	end)

	it("replaces a dress when a top is tapped", function()
		local outcome = tap({ F.DRESS, F.SHOES_BUNDLE }, F.JACKET_TOP)
		expect(outcome.outfitStylingItemKeys).toEqual({ F.SHOES_BUNDLE, F.JACKET_TOP })
		expect(outcome.removedStylingItemKeys).toEqual({ F.DRESS })
	end)

	it("replaces the item already in a single slot, and a dress replaces both a top and a bottom", function()
		local pool, view = buildWidePoolAndView()
		local hairs = view.wardrobeSlotGroups[1].wardrobeItems
		local outcome = tap({ hairs[1].stylingItemKey }, hairs[2].stylingItemKey, view, pool)
		expect(outcome.outfitStylingItemKeys).toEqual({ hairs[2].stylingItemKey })
		local function firstKeyOfSlot(itemSlot)
			for _, group in view.wardrobeSlotGroups do
				if group.itemSlot == itemSlot then
					return group.wardrobeItems[1].stylingItemKey
				end
			end
			error(itemSlot)
		end
		local top, bottom, dress = firstKeyOfSlot("top"), firstKeyOfSlot("bottom"), firstKeyOfSlot("dress")
		local dressed = tap({ top, bottom }, dress, view, pool)
		expect(dressed.outfitStylingItemKeys).toEqual({ dress })
		expect(dressed.removedStylingItemKeys).toEqual({ top, bottom })
		local bottomAgain = tap({ dress }, bottom, view, pool)
		expect(bottomAgain.outfitStylingItemKeys).toEqual({ bottom })
	end)

	it("refuses a fourth accessory without changing the selection", function()
		local pool, view = buildWidePoolAndView()
		local accessories = {}
		for _, group in view.wardrobeSlotGroups do
			if group.itemSlot == "accessory" then
				for _, item in group.wardrobeItems do
					table.insert(accessories, item.stylingItemKey)
				end
			end
		end
		local current = { accessories[1], accessories[2], accessories[3] }
		local outcome = tap(current, accessories[4], view, pool)
		expect(outcome.isSelectionChanged).toBeFalse()
		expect(outcome.selectionRefusalReason).toBe("AccessoryLimitReached")
		expect(outcome.outfitStylingItemKeys).toEqual(current)
		expect(tap({ accessories[1], accessories[2] }, accessories[3], view, pool).isSelectionChanged).toBeTrue()
	end)

	it("refuses an item the catalog does not list", function()
		local view = WardrobeCatalogView.buildWardrobeCatalogView(F.buildSnapshotAnswerWithItems({ F.HAIR }), POOL)
		local outcome = tap({ F.HAIR }, F.DRESS, view)
		expect(outcome.selectionRefusalReason).toBe("NotInWardrobe")
		expect(outcome.outfitStylingItemKeys).toEqual({ F.HAIR })
		expect(tap({}, "asset_404", view).selectionRefusalReason).toBe("NotInWardrobe")
	end)

	it("refuses when the shared validator rejects the result, whatever the reason", function()
		local view = DeviceTestFixtures.buildDevelopmentWardrobeCatalogView()
		local poolWithDisabledHair = table.clone(POOL)
		local disabledHair = table.clone(POOL[F.HAIR])
		disabledHair.isEnabled = false
		poolWithDisabledHair[F.HAIR] = disabledHair
		local outcome = tap({}, F.HAIR, view, poolWithDisabledHair)
		expect(outcome.selectionRefusalReason).toBe("WouldNotBeValidOutfit")
		expect(outcome.outfitStylingItemKeys).toEqual({})
	end)

	it("keeps the selection valid after every tap of a long random sequence", function()
		local pool, view = buildWidePoolAndView()
		local allKeys = view.listedStylingItemKeys
		local seed = 12345
		local selection = {}
		for _ = 1, 3000 do
			seed = (seed * 1103515245 + 12345) % 2147483648
			local tapped = allKeys[seed % #allKeys + 1]
			selection = tap(selection, tapped, view, pool).outfitStylingItemKeys
			local verdict = OutfitValidator.validateOutfit(selection, pool, view.availableStylingItemKeySet)
			expect(verdict.isOutfitValid).toBeTrue()
		end
	end)

	it("drops items a new catalog no longer lists, keeping the order of the rest", function()
		local smallerView =
			WardrobeCatalogView.buildWardrobeCatalogView(F.buildSnapshotAnswerWithItems({ F.HAIR, F.GLASSES }), POOL)
		local kept = WardrobeSelectionRules.keepOnlyListedStylingItems({ F.GLASSES, F.DRESS, F.HAIR }, smallerView)
		expect(kept).toEqual({ F.GLASSES, F.HAIR })
	end)
end)
