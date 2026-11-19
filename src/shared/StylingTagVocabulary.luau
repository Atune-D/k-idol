-- Fixed tag vocabularies for styling items and themes (development spec §1.1).
-- An item or theme may only use values from these lists. Pure data: no Roblox-specific
-- interface is used, so this module runs unchanged in Roblox and in Lune tests.

local StylingTagVocabulary = {}

StylingTagVocabulary.STYLE_TAGS = table.freeze({
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
})

-- All colour tags, including the neutrals listed again in NEUTRAL_COLOR_TAGS.
StylingTagVocabulary.COLOR_TAGS = table.freeze({
	"pink",
	"red",
	"orange",
	"yellow",
	"green",
	"blue",
	"purple",
	"brown",
	"black",
	"white",
	"gray",
	"beige",
})

-- Neutral colours are ignored by colour harmony scoring and never chosen as a colour bonus.
StylingTagVocabulary.NEUTRAL_COLOR_TAGS = table.freeze({
	"black",
	"white",
	"gray",
	"beige",
})

StylingTagVocabulary.ITEM_SLOTS = table.freeze({
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
})

local function buildMembershipSet(vocabularyValues: { string }): { [string]: boolean }
	local membershipSet = {}
	for _, vocabularyValue in vocabularyValues do
		membershipSet[vocabularyValue] = true
	end
	return table.freeze(membershipSet)
end

local knownStyleTagSet = buildMembershipSet(StylingTagVocabulary.STYLE_TAGS)
local knownColorTagSet = buildMembershipSet(StylingTagVocabulary.COLOR_TAGS)
local neutralColorTagSet = buildMembershipSet(StylingTagVocabulary.NEUTRAL_COLOR_TAGS)
local knownItemSlotSet = buildMembershipSet(StylingTagVocabulary.ITEM_SLOTS)

-- Each check accepts any value (including nil and non-strings) and returns false for anything
-- that is not exactly one of the listed strings, so it can validate untrusted input directly.

function StylingTagVocabulary.isKnownStyleTag(candidateStyleTag: any): boolean
	return knownStyleTagSet[candidateStyleTag] == true
end

function StylingTagVocabulary.isKnownColorTag(candidateColorTag: any): boolean
	return knownColorTagSet[candidateColorTag] == true
end

function StylingTagVocabulary.isNeutralColorTag(candidateColorTag: any): boolean
	return neutralColorTagSet[candidateColorTag] == true
end

function StylingTagVocabulary.isKnownItemSlot(candidateItemSlot: any): boolean
	return knownItemSlotSet[candidateItemSlot] == true
end

return table.freeze(StylingTagVocabulary)
