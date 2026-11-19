-- Stored outfits that contain unavailable items (development spec §1.5 table, §2.4, §2.6).

local UnitTestFramework = require("../Support/UnitTestFramework")
local StoredLobbyOutfitResolver = require("../../src/shared/StoredLobbyOutfitResolver")
local OutfitValidator = require("../../src/shared/OutfitValidator")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function resolveFakeStoredOutfit(storedOutfitStylingItemKeys: any)
	return StoredLobbyOutfitResolver.resolveStoredLobbyOutfitStylingItemKeys(
		storedOutfitStylingItemKeys,
		FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
		FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET
	)
end

local function expectResolution(storedOutfitStylingItemKeys: any, expectedResolution)
	local resolution = resolveFakeStoredOutfit(storedOutfitStylingItemKeys)
	expect(resolution.wearableStylingItemKeys).toEqual(expectedResolution.wearableStylingItemKeys)
	expect(resolution.stylingItemKeysToRemoveFromSave).toEqual(expectedResolution.stylingItemKeysToRemoveFromSave)
	expect(resolution.unavailableStylingItemKeysThisSession).toEqual(
		expectedResolution.unavailableStylingItemKeysThisSession
	)
	expect(resolution.stylingItemKeysSkippedForBreakingOutfitRules).toEqual(
		expectedResolution.stylingItemKeysSkippedForBreakingOutfitRules or {}
	)
	expect(resolution.keptStoredLobbyOutfitStylingItemKeys).toEqual(
		expectedResolution.keptStoredLobbyOutfitStylingItemKeys
	)
end

describe("StoredLobbyOutfitResolver", function()
	it("wears every item of a fully available stored outfit and changes nothing in the save", function()
		local storedKeys = { "asset_9000001", "asset_9000011", "bundle_9000041" }
		expectResolution(storedKeys, {
			wearableStylingItemKeys = storedKeys,
			stylingItemKeysToRemoveFromSave = {},
			unavailableStylingItemKeysThisSession = {},
			keptStoredLobbyOutfitStylingItemKeys = storedKeys,
		})
	end)

	it("row 1: a key no longer in the pool is skipped and removed from the save", function()
		expectResolution({ "asset_9000011", FakeStylingItemPool.KEY_NOT_IN_POOL, "bundle_9000041" }, {
			wearableStylingItemKeys = { "asset_9000011", "bundle_9000041" },
			stylingItemKeysToRemoveFromSave = { FakeStylingItemPool.KEY_NOT_IN_POOL },
			unavailableStylingItemKeysThisSession = {},
			keptStoredLobbyOutfitStylingItemKeys = { "asset_9000011", "bundle_9000041" },
		})
	end)

	it("row 1: a key whose row has isEnabled = false is skipped and removed from the save", function()
		expectResolution({ FakeStylingItemPool.DISABLED_HAIR_KEY, "asset_9000011" }, {
			wearableStylingItemKeys = { "asset_9000011" },
			stylingItemKeysToRemoveFromSave = { FakeStylingItemPool.DISABLED_HAIR_KEY },
			unavailableStylingItemKeysThisSession = {},
			keptStoredLobbyOutfitStylingItemKeys = { "asset_9000011" },
		})
	end)

	it("row 2: a key hidden this session is skipped, KEPT in the save and reported as unavailable", function()
		expectResolution({ FakeStylingItemPool.HIDDEN_HAIR_KEY, "asset_9000011" }, {
			wearableStylingItemKeys = { "asset_9000011" },
			stylingItemKeysToRemoveFromSave = {},
			unavailableStylingItemKeysThisSession = { FakeStylingItemPool.HIDDEN_HAIR_KEY },
			keptStoredLobbyOutfitStylingItemKeys = { FakeStylingItemPool.HIDDEN_HAIR_KEY, "asset_9000011" },
		})
	end)

	it("keeps a pool item that is hidden because the whole catalog is empty (temporary fault)", function()
		local storedKeys = { "asset_9000001", "bundle_9000041" }
		local resolution = StoredLobbyOutfitResolver.resolveStoredLobbyOutfitStylingItemKeys(
			storedKeys,
			FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
			{}
		)
		expect(resolution.wearableStylingItemKeys).toEqual({})
		expect(resolution.stylingItemKeysToRemoveFromSave).toEqual({})
		expect(resolution.unavailableStylingItemKeysThisSession).toEqual(storedKeys)
		expect(resolution.keptStoredLobbyOutfitStylingItemKeys).toEqual(storedKeys)
	end)

	it("handles all three cases in one stored outfit", function()
		expectResolution({
			FakeStylingItemPool.HIDDEN_HAIR_KEY,
			FakeStylingItemPool.KEY_NOT_IN_POOL,
			"asset_9000032",
			FakeStylingItemPool.DISABLED_DRESS_KEY,
			"asset_9000051",
		}, {
			wearableStylingItemKeys = { "asset_9000032", "asset_9000051" },
			stylingItemKeysToRemoveFromSave = {
				FakeStylingItemPool.KEY_NOT_IN_POOL,
				FakeStylingItemPool.DISABLED_DRESS_KEY,
			},
			unavailableStylingItemKeysThisSession = { FakeStylingItemPool.HIDDEN_HAIR_KEY },
			keptStoredLobbyOutfitStylingItemKeys = {
				FakeStylingItemPool.HIDDEN_HAIR_KEY,
				"asset_9000032",
				"asset_9000051",
			},
		})
	end)

	it("treats an empty stored list (the player's own avatar) and a non-table as nothing to wear", function()
		local emptyExpectation = {
			wearableStylingItemKeys = {},
			stylingItemKeysToRemoveFromSave = {},
			unavailableStylingItemKeysThisSession = {},
			keptStoredLobbyOutfitStylingItemKeys = {},
		}
		expectResolution({}, emptyExpectation)
		expectResolution(nil, emptyExpectation)
		expectResolution("asset_9000001", emptyExpectation)
	end)

	it("removes entries that are not strings, since they cannot be keys", function()
		expectResolution({ 9000001, "asset_9000011" }, {
			wearableStylingItemKeys = { "asset_9000011" },
			stylingItemKeysToRemoveFromSave = { 9000001 },
			unavailableStylingItemKeysThisSession = {},
			keptStoredLobbyOutfitStylingItemKeys = { "asset_9000011" },
		})
	end)

	it(
		"never wears an invalid outfit: rule-breaking available keys are skipped and kept (not in spec; conservative)",
		function()
			-- Could happen if the owner changes an item's slot after the outfit was stored.
			expectResolution({ "asset_9000011", "asset_9000031", "asset_9000011" }, {
				wearableStylingItemKeys = { "asset_9000011" },
				stylingItemKeysToRemoveFromSave = {},
				unavailableStylingItemKeysThisSession = {},
				stylingItemKeysSkippedForBreakingOutfitRules = { "asset_9000031", "asset_9000011" },
				keptStoredLobbyOutfitStylingItemKeys = { "asset_9000011", "asset_9000031", "asset_9000011" },
			})
		end
	)

	it("returns frozen lists", function()
		local resolution = resolveFakeStoredOutfit({ "asset_9000001" })
		expect(table.isfrozen(resolution)).toBeTrue()
		expect(table.isfrozen(resolution.wearableStylingItemKeys)).toBeTrue()
		expect(table.isfrozen(resolution.keptStoredLobbyOutfitStylingItemKeys)).toBeTrue()
	end)

	it("the wearable part of every subset of the worked example is that subset, and valid", function()
		local workedExampleKeys = FakeStylingItemPool.WORKED_EXAMPLE_STYLING_ITEM_KEYS
		for subsetMask = 0, 2 ^ #workedExampleKeys - 1 do
			local subsetKeys = {}
			for keyPosition, workedExampleKey in workedExampleKeys do
				if bit32.extract(subsetMask, keyPosition - 1) == 1 then
					table.insert(subsetKeys, workedExampleKey)
				end
			end
			local resolution = resolveFakeStoredOutfit(subsetKeys)
			expect(resolution.wearableStylingItemKeys).toEqual(subsetKeys)
			expect(
				OutfitValidator.validateOutfit(
					resolution.wearableStylingItemKeys,
					FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
					FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET
				).isOutfitValid
			).toBeTrue()
		end
	end)
end)
