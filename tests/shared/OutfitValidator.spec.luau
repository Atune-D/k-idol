-- Unit: outfit validity (development spec §1.5, §6.2).

local UnitTestFramework = require("../Support/UnitTestFramework")
local OutfitValidator = require("../../src/shared/OutfitValidator")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local REASONS = OutfitValidator.OUTFIT_REJECTION_REASONS

local function validateFakeOutfit(untrustedOutfitStylingItemKeys: any)
	return OutfitValidator.validateOutfit(
		untrustedOutfitStylingItemKeys,
		FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
		FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET
	)
end

local function expectValid(outfitStylingItemKeys: any)
	local verdict = validateFakeOutfit(outfitStylingItemKeys)
	expect(verdict.outfitRejectionReason).toBeNil()
	expect(verdict.isOutfitValid).toBeTrue()
end

local function expectRejected(outfitStylingItemKeys: any, expectedReason: string, expectedRuleNumber: number?)
	local verdict = validateFakeOutfit(outfitStylingItemKeys)
	expect(verdict.isOutfitValid).toBeFalse()
	expect(verdict.outfitRejectionReason).toBe(expectedReason)
	expect(verdict.failedOutfitRuleNumber).toBe(expectedRuleNumber)
	return verdict
end

describe("OutfitValidator basics", function()
	it("accepts an empty outfit", function()
		expectValid({})
	end)

	it("accepts the §0.2 worked example outfit", function()
		expectValid(FakeStylingItemPool.WORKED_EXAMPLE_STYLING_ITEM_KEYS)
	end)

	it("accepts a full outfit of the largest valid size", function()
		local largestValidOutfit = {
			"asset_9000001",
			"asset_9000011",
			"asset_9000021",
			"bundle_9000041",
			"asset_9000051",
			"asset_9000052",
			"asset_9000053",
			"asset_9000061",
			"asset_9000071",
			"asset_9000081",
			"asset_9000091",
			"asset_9000095",
		}
		expect(#largestValidOutfit).toBe(OutfitValidator.MAX_OUTFIT_ITEM_COUNT)
		expectValid(largestValidOutfit)
	end)
end)

describe("OutfitValidator rule 1: every key is an enabled, non-hidden item of the pool", function()
	it("passes for enabled, available items", function()
		expectValid({ "asset_9000001", "asset_9000011" })
	end)

	it("fails for a key not in the pool and names it", function()
		local verdict =
			expectRejected({ "asset_9000001", FakeStylingItemPool.KEY_NOT_IN_POOL }, REASONS.StylingItemNotInPool, 1)
		expect(verdict.offendingStylingItemKey).toBe(FakeStylingItemPool.KEY_NOT_IN_POOL)
	end)

	it("fails for the bundle key of an id that exists only as an asset", function()
		expectRejected({ FakeStylingItemPool.BUNDLE_KEY_WITH_ASSET_ID_OF_POOL_ITEM }, REASONS.StylingItemNotInPool, 1)
		expectRejected({ "asset_9000041" }, REASONS.StylingItemNotInPool, 1) -- shoes are bundle_9000041
	end)

	it("fails for a disabled item", function()
		expectRejected({ FakeStylingItemPool.DISABLED_HAIR_KEY }, REASONS.StylingItemDisabled, 1)
		expectRejected({ FakeStylingItemPool.DISABLED_DRESS_KEY }, REASONS.StylingItemDisabled, 1)
	end)

	it("fails for an item hidden this session (an outfit containing a hidden item is invalid)", function()
		local verdict = expectRejected(
			{ "asset_9000011", FakeStylingItemPool.HIDDEN_HAIR_KEY },
			REASONS.StylingItemHiddenThisSession,
			1
		)
		expect(verdict.offendingStylingItemKey).toBe(FakeStylingItemPool.HIDDEN_HAIR_KEY)
	end)

	it("treats a disabled item as invalid even if the available set lists it", function()
		local availableSetIncludingDisabledItem = table.clone(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
		availableSetIncludingDisabledItem[FakeStylingItemPool.DISABLED_HAIR_KEY] = true
		local verdict = OutfitValidator.validateOutfit(
			{ FakeStylingItemPool.DISABLED_HAIR_KEY },
			FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
			availableSetIncludingDisabledItem
		)
		expect(verdict.outfitRejectionReason).toBe(REASONS.StylingItemDisabled)
	end)

	it("rejects everything against an empty pool", function()
		local verdict = OutfitValidator.validateOutfit({ "asset_9000001" }, {}, {})
		expect(verdict.outfitRejectionReason).toBe(REASONS.StylingItemNotInPool)
		expect(OutfitValidator.validateOutfit({}, {}, {}).isOutfitValid).toBeTrue()
	end)
end)

describe("OutfitValidator rule 2: no key appears twice", function()
	it("passes for distinct keys", function()
		expectValid({ "asset_9000051", "asset_9000052" })
	end)

	it("fails for a repeated key, even an accessory where several are allowed", function()
		local verdict =
			expectRejected({ "asset_9000051", "asset_9000052", "asset_9000051" }, REASONS.DuplicateStylingItem, 2)
		expect(verdict.offendingStylingItemKey).toBe("asset_9000051")
	end)
end)

describe("OutfitValidator rule 3: at most one item in each single-item slot", function()
	it("passes for one item in every single-item slot (without the dress)", function()
		expectValid({
			"asset_9000001",
			"asset_9000011",
			"asset_9000021",
			"bundle_9000041",
			"asset_9000061",
			"asset_9000071",
			"asset_9000081",
			"asset_9000091",
			"asset_9000095",
		})
	end)

	it("fails for two items in the same slot, for each single-item slot that has two items", function()
		local twoItemsBySlot = {
			hair = { "asset_9000001", "asset_9000002" },
			top = { "asset_9000011", "asset_9000012" },
			bottom = { "asset_9000021", "asset_9000022" },
			dress = { "asset_9000031", "asset_9000032" },
			shoes = { "bundle_9000041", "bundle_9000042" },
			makeup_eyes = { "asset_9000061", "asset_9000062" },
			makeup_lips = { "asset_9000071", "asset_9000072" },
		}
		for itemSlot, twoStylingItemKeys in twoItemsBySlot do
			local verdict = expectRejected(twoStylingItemKeys, REASONS.TooManyItemsInSingleItemSlot, 3)
			expect(verdict.offendingItemSlot).toBe(itemSlot)
		end
	end)

	it("counts a shoes bundle as one item", function()
		expectValid({ "bundle_9000041" })
		expectValid({ "bundle_9000043", "asset_9000001" })
	end)

	it("lists every single-item slot of §1.5 rule 3", function()
		expect(OutfitValidator.SINGLE_ITEM_SLOTS).toEqual({
			"hair",
			"top",
			"bottom",
			"dress",
			"shoes",
			"makeup_eyes",
			"makeup_lips",
			"makeup_face",
			"eyelashes",
			"eyebrows",
		})
	end)
end)

describe("OutfitValidator rule 4: at most 3 accessories", function()
	it("passes for 0, 1, 2 and 3 accessories", function()
		expect(OutfitValidator.MAX_ACCESSORY_ITEM_COUNT).toBe(3)
		expectValid({ "asset_9000051" })
		expectValid({ "asset_9000051", "asset_9000052" })
		expectValid({ "asset_9000051", "asset_9000052", "asset_9000053" })
	end)

	it("fails for 4 accessories", function()
		local verdict = expectRejected(
			{ "asset_9000051", "asset_9000052", "asset_9000053", "asset_9000054" },
			REASONS.TooManyAccessoryItems,
			4
		)
		expect(verdict.offendingItemSlot).toBe("accessory")
	end)
end)

describe("OutfitValidator rule 5: a dress cannot be combined with a top or a bottom", function()
	it("passes for a dress alone and for a top with a bottom", function()
		expectValid({ "asset_9000031", "bundle_9000041" })
		expectValid({ "asset_9000011", "asset_9000021" })
	end)

	it("fails for a dress with a top, with a bottom, and with both", function()
		expectRejected({ "asset_9000031", "asset_9000011" }, REASONS.DressCombinedWithTopOrBottom, 5)
		expectRejected({ "asset_9000021", "asset_9000031" }, REASONS.DressCombinedWithTopOrBottom, 5)
		expectRejected({ "asset_9000011", "asset_9000031", "asset_9000021" }, REASONS.DressCombinedWithTopOrBottom, 5)
	end)
end)

describe("OutfitValidator reports the lowest-numbered failing rule", function()
	it("reports rule 1 before rule 2, rule 2 before rule 3, rule 3 before rule 5", function()
		expectRejected(
			{ "asset_9000001", "asset_9000001", FakeStylingItemPool.KEY_NOT_IN_POOL },
			REASONS.StylingItemNotInPool,
			1
		)
		expectRejected({ "asset_9000001", "asset_9000001", "asset_9000002" }, REASONS.DuplicateStylingItem, 2)
		expectRejected({ "asset_9000011", "asset_9000012", "asset_9000031" }, REASONS.TooManyItemsInSingleItemSlot, 3)
	end)
end)

describe("OutfitValidator with untrusted input", function()
	it("rejects non-tables without raising", function()
		expectRejected(nil, REASONS.OutfitIsNotAListOfStylingItemKeys, nil)
		for _, nonTableValue in { 1, "asset_9000001", true, function() end } do
			expectRejected(nonTableValue, REASONS.OutfitIsNotAListOfStylingItemKeys, nil)
		end
	end)

	it("rejects lists holding non-strings, holes, extra keys or overlong strings", function()
		expectRejected({ 9000001 }, REASONS.OutfitIsNotAListOfStylingItemKeys, nil)
		expectRejected({ "asset_9000001", true }, REASONS.OutfitIsNotAListOfStylingItemKeys, nil)
		expectRejected({ { "asset_9000001" } }, REASONS.OutfitIsNotAListOfStylingItemKeys, nil)
		expectRejected({ [1] = "asset_9000001", [3] = "asset_9000011" }, REASONS.OutfitIsNotAListOfStylingItemKeys, nil)
		expectRejected({ stylingItemKey = "asset_9000001" }, REASONS.OutfitIsNotAListOfStylingItemKeys, nil)
		local listWithExtraKey: { [any]: any } = { "asset_9000001" }
		listWithExtraKey.extra = "asset_9000011"
		expectRejected(listWithExtraKey, REASONS.OutfitIsNotAListOfStylingItemKeys, nil)
		expectRejected({ string.rep("a", 100000) }, REASONS.OutfitIsNotAListOfStylingItemKeys, nil)
	end)

	it("rejects a table with a metatable without running its metamethods", function()
		local didRunMetamethod = false
		local trickOutfit = setmetatable({}, {
			__index = function()
				didRunMetamethod = true
				return "asset_9000001"
			end,
			__len = function()
				didRunMetamethod = true
				return 1
			end,
		})
		expectRejected(trickOutfit, REASONS.OutfitIsNotAListOfStylingItemKeys, nil)
		expect(didRunMetamethod).toBeFalse()
	end)

	it("rejects a list longer than MAX_OUTFIT_ITEM_COUNT, including a huge one, without raising", function()
		local thirteenKeys = {}
		for keyPosition = 1, OutfitValidator.MAX_OUTFIT_ITEM_COUNT + 1 do
			thirteenKeys[keyPosition] = "asset_" .. tostring(9500000 + keyPosition)
		end
		expectRejected(thirteenKeys, REASONS.TooManyItemsInOutfit, nil)

		local hugeList = table.create(1000000, "asset_9000001")
		expectRejected(hugeList, REASONS.TooManyItemsInOutfit, nil)
	end)

	it("returns frozen verdicts", function()
		expect(table.isfrozen(validateFakeOutfit({}))).toBeTrue()
		expect(table.isfrozen(validateFakeOutfit({ FakeStylingItemPool.KEY_NOT_IN_POOL }))).toBeTrue()
	end)

	it("raises when the trusted pool or available set is missing (programming error)", function()
		expect(function()
			OutfitValidator.validateOutfit({}, FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY, nil :: any)
		end).toThrow("must be tables")
	end)
end)
