local UnitTestFramework = require("../Support/UnitTestFramework")
local StylingTagVocabulary = require("../../src/shared/StylingTagVocabulary")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

-- Copied by hand from development spec §1.1; the module must match it exactly.
local SPEC_STYLE_TAGS = {
	"y2k",
	"streetwear",
	"cute",
	"elegant",
	"gothic",
	"sporty",
	"retro",
	"fantasy",
	"beach",
	"formal",
	"punk",
	"preppy",
}
local SPEC_NON_NEUTRAL_COLOR_TAGS = { "pink", "red", "orange", "yellow", "green", "blue", "purple", "brown" }
local SPEC_NEUTRAL_COLOR_TAGS = { "black", "white", "gray", "beige" }
local SPEC_ITEM_SLOTS = {
	"hair",
	"top",
	"bottom",
	"dress",
	"shoes",
	"accessory",
	"makeup_eyes",
	"makeup_lips",
	"makeup_face",
	"eyelashes",
	"eyebrows",
}

local NON_STRING_CANDIDATES = { 1, true, {}, function() end }

local function expectNoDuplicateValues(vocabularyValues: { string })
	local seenValues = {}
	for _, vocabularyValue in vocabularyValues do
		expect(seenValues[vocabularyValue]).toBeNil()
		seenValues[vocabularyValue] = true
	end
end

describe("StylingTagVocabulary lists", function()
	it("STYLE_TAGS matches spec §1.1 exactly", function()
		expect(StylingTagVocabulary.STYLE_TAGS).toEqual(SPEC_STYLE_TAGS)
	end)

	it("COLOR_TAGS holds the eight colours followed by the four neutrals from spec §1.1", function()
		local specColorTags = table.clone(SPEC_NON_NEUTRAL_COLOR_TAGS)
		table.move(SPEC_NEUTRAL_COLOR_TAGS, 1, #SPEC_NEUTRAL_COLOR_TAGS, #specColorTags + 1, specColorTags)
		expect(StylingTagVocabulary.COLOR_TAGS).toEqual(specColorTags)
	end)

	it("NEUTRAL_COLOR_TAGS is exactly black, white, gray, beige", function()
		expect(StylingTagVocabulary.NEUTRAL_COLOR_TAGS).toEqual(SPEC_NEUTRAL_COLOR_TAGS)
	end)

	it("every neutral colour is also a known colour", function()
		for _, neutralColorTag in StylingTagVocabulary.NEUTRAL_COLOR_TAGS do
			expect(StylingTagVocabulary.COLOR_TAGS).toContain(neutralColorTag)
		end
	end)

	it("ITEM_SLOTS matches spec §1.1 exactly", function()
		expect(StylingTagVocabulary.ITEM_SLOTS).toEqual(SPEC_ITEM_SLOTS)
	end)

	it("no list contains a duplicate value", function()
		expectNoDuplicateValues(StylingTagVocabulary.STYLE_TAGS)
		expectNoDuplicateValues(StylingTagVocabulary.COLOR_TAGS)
		expectNoDuplicateValues(StylingTagVocabulary.NEUTRAL_COLOR_TAGS)
		expectNoDuplicateValues(StylingTagVocabulary.ITEM_SLOTS)
	end)

	it("the module and its lists are frozen so no caller can change the vocabulary", function()
		expect(table.isfrozen(StylingTagVocabulary)).toBeTrue()
		expect(table.isfrozen(StylingTagVocabulary.STYLE_TAGS)).toBeTrue()
		expect(table.isfrozen(StylingTagVocabulary.COLOR_TAGS)).toBeTrue()
		expect(table.isfrozen(StylingTagVocabulary.NEUTRAL_COLOR_TAGS)).toBeTrue()
		expect(table.isfrozen(StylingTagVocabulary.ITEM_SLOTS)).toBeTrue()
		expect(function()
			table.insert(StylingTagVocabulary.STYLE_TAGS :: any, "invented_style")
		end).toThrow()
	end)
end)

describe("StylingTagVocabulary.isKnownStyleTag", function()
	it("accepts every spec style tag", function()
		for _, specStyleTag in SPEC_STYLE_TAGS do
			expect(StylingTagVocabulary.isKnownStyleTag(specStyleTag)).toBeTrue()
		end
	end)

	it("rejects colour tags, item slots, wrong case, padding, empty text and non-strings", function()
		for _, rejectedCandidate in { "pink", "hair", "Y2K", " y2k", "", "y2k ", "hip_hop" } do
			expect(StylingTagVocabulary.isKnownStyleTag(rejectedCandidate)).toBeFalse()
		end
		for _, nonStringCandidate in NON_STRING_CANDIDATES do
			expect(StylingTagVocabulary.isKnownStyleTag(nonStringCandidate)).toBeFalse()
		end
		expect(StylingTagVocabulary.isKnownStyleTag(nil)).toBeFalse()
	end)
end)

describe("StylingTagVocabulary.isKnownColorTag", function()
	it("accepts every non-neutral and every neutral spec colour", function()
		for _, specColorTag in SPEC_NON_NEUTRAL_COLOR_TAGS do
			expect(StylingTagVocabulary.isKnownColorTag(specColorTag)).toBeTrue()
		end
		for _, specNeutralColorTag in SPEC_NEUTRAL_COLOR_TAGS do
			expect(StylingTagVocabulary.isKnownColorTag(specNeutralColorTag)).toBeTrue()
		end
	end)

	it("rejects unknown colours, spelling variants, wrong case and non-strings", function()
		for _, rejectedCandidate in { "grey", "Pink", "teal", "y2k", "" } do
			expect(StylingTagVocabulary.isKnownColorTag(rejectedCandidate)).toBeFalse()
		end
		for _, nonStringCandidate in NON_STRING_CANDIDATES do
			expect(StylingTagVocabulary.isKnownColorTag(nonStringCandidate)).toBeFalse()
		end
		expect(StylingTagVocabulary.isKnownColorTag(nil)).toBeFalse()
	end)
end)

describe("StylingTagVocabulary.isNeutralColorTag", function()
	it("is true for the four neutrals", function()
		for _, specNeutralColorTag in SPEC_NEUTRAL_COLOR_TAGS do
			expect(StylingTagVocabulary.isNeutralColorTag(specNeutralColorTag)).toBeTrue()
		end
	end)

	it("is false for every non-neutral colour", function()
		for _, specColorTag in SPEC_NON_NEUTRAL_COLOR_TAGS do
			expect(StylingTagVocabulary.isNeutralColorTag(specColorTag)).toBeFalse()
		end
	end)

	it("is false for unknown values and non-strings", function()
		for _, rejectedCandidate in { "grey", "Black", "", "hair" } do
			expect(StylingTagVocabulary.isNeutralColorTag(rejectedCandidate)).toBeFalse()
		end
		for _, nonStringCandidate in NON_STRING_CANDIDATES do
			expect(StylingTagVocabulary.isNeutralColorTag(nonStringCandidate)).toBeFalse()
		end
		expect(StylingTagVocabulary.isNeutralColorTag(nil)).toBeFalse()
	end)
end)

describe("StylingTagVocabulary.isKnownItemSlot", function()
	it("accepts every spec item slot", function()
		for _, specItemSlot in SPEC_ITEM_SLOTS do
			expect(StylingTagVocabulary.isKnownItemSlot(specItemSlot)).toBeTrue()
		end
	end)

	it("rejects scoring-slot names that are not item slots, wrong case and non-strings", function()
		-- upperBody / lowerBody / makeup are scoring slots (§1.6), not item slots.
		for _, rejectedCandidate in { "upperBody", "lowerBody", "makeup", "Hair", "makeup-eyes", "" } do
			expect(StylingTagVocabulary.isKnownItemSlot(rejectedCandidate)).toBeFalse()
		end
		for _, nonStringCandidate in NON_STRING_CANDIDATES do
			expect(StylingTagVocabulary.isKnownItemSlot(nonStringCandidate)).toBeFalse()
		end
		expect(StylingTagVocabulary.isKnownItemSlot(nil)).toBeFalse()
	end)
end)
