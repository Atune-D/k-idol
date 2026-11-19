-- Builds random outfits that obey every rule of development spec §1.5, from the fake pool.
-- Used by the randomized invariant tests; the validator must accept everything built here.

local FakeStylingItemPool = require("./FakeStylingItemPool")
local SeededRandomTrials = require("./SeededRandomTrials")

type SeededRandomNumberGenerator = SeededRandomTrials.SeededRandomNumberGenerator

local RandomValidOutfitGenerator = {}

local availableFakeStylingItemsByItemSlot = FakeStylingItemPool.groupAvailableFakeStylingItemsByItemSlot()

local ITEM_SLOTS_OTHER_THAN_BODY_AND_ACCESSORY =
	table.freeze({ "hair", "shoes", "makeup_eyes", "makeup_lips", "makeup_face", "eyelashes", "eyebrows" })

local MAXIMUM_ACCESSORY_ITEM_COUNT = 3

-- Item slots that, when filled, fill each scoring slot. Used to add an item to an empty slot.
RandomValidOutfitGenerator.ITEM_SLOTS_THAT_CAN_FILL_EMPTY_SCORING_SLOT = table.freeze({
	hair = table.freeze({ "hair" }),
	upperBody = table.freeze({ "top" }), -- an empty upperBody means no dress and no top is worn
	lowerBody = table.freeze({ "bottom" }), -- likewise for lowerBody
	shoes = table.freeze({ "shoes" }),
	accessory = table.freeze({ "accessory" }),
	makeup = table.freeze({ "makeup_eyes", "makeup_lips", "makeup_face", "eyelashes", "eyebrows" }),
})

function RandomValidOutfitGenerator.pickRandomAvailableStylingItemKeyForItemSlot(
	seededRandomNumberGenerator: SeededRandomNumberGenerator,
	itemSlot: string
): string
	local candidateStylingItems = availableFakeStylingItemsByItemSlot[itemSlot]
	assert(candidateStylingItems ~= nil, "the fake pool has no available item in slot " .. itemSlot)
	return seededRandomNumberGenerator.pickRandomListElement(candidateStylingItems).stylingItemKey
end

-- Each slot is filled with a random per-outfit probability, so outfits range from empty to full.
function RandomValidOutfitGenerator.generateRandomValidOutfitStylingItemKeys(
	seededRandomNumberGenerator: SeededRandomNumberGenerator
): { string }
	local slotFillProbability = seededRandomNumberGenerator.nextFractionBetweenZeroAndOne()
	local function shouldFillSlot(): boolean
		return seededRandomNumberGenerator.nextFractionBetweenZeroAndOne() < slotFillProbability
	end

	local outfitStylingItemKeys = {}
	local function wearRandomItemFromSlot(itemSlot: string)
		table.insert(
			outfitStylingItemKeys,
			RandomValidOutfitGenerator.pickRandomAvailableStylingItemKeyForItemSlot(
				seededRandomNumberGenerator,
				itemSlot
			)
		)
	end

	if seededRandomNumberGenerator.nextWholeNumberInRange(1, 3) == 1 then
		if shouldFillSlot() then
			wearRandomItemFromSlot("dress")
		end
	else
		if shouldFillSlot() then
			wearRandomItemFromSlot("top")
		end
		if shouldFillSlot() then
			wearRandomItemFromSlot("bottom")
		end
	end
	for _, itemSlot in ITEM_SLOTS_OTHER_THAN_BODY_AND_ACCESSORY do
		if shouldFillSlot() then
			wearRandomItemFromSlot(itemSlot)
		end
	end

	local shuffledAccessoryStylingItemKeys = {}
	for _, accessoryStylingItem in availableFakeStylingItemsByItemSlot.accessory do
		table.insert(shuffledAccessoryStylingItemKeys, accessoryStylingItem.stylingItemKey)
	end
	seededRandomNumberGenerator.shuffleListInPlace(shuffledAccessoryStylingItemKeys)
	local accessoryItemCount = seededRandomNumberGenerator.nextWholeNumberInRange(0, MAXIMUM_ACCESSORY_ITEM_COUNT)
	if not shouldFillSlot() then
		accessoryItemCount = 0
	end
	for accessoryPosition = 1, accessoryItemCount do
		table.insert(outfitStylingItemKeys, shuffledAccessoryStylingItemKeys[accessoryPosition])
	end

	seededRandomNumberGenerator.shuffleListInPlace(outfitStylingItemKeys)
	return outfitStylingItemKeys
end

return table.freeze(RandomValidOutfitGenerator)
