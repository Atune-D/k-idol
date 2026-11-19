-- Decides whether a list of styling item keys is a valid outfit (development spec §1.5).
--
-- Used for what a device SUBMITS (SetRoundOutfitDraft, SetLobbyOutfit). What is already stored
-- in a save is handled by StoredLobbyOutfitResolver instead.
--
-- The submitted outfit is untrusted: any value is accepted as input, nothing here raises an error
-- for it, and a malformed or oversized list is rejected before any per-item work.
--
-- The styling item pool and the set of keys available this server session (not hidden, §1.2) are
-- passed in, so tests use fixture pools. Both are trusted; passing a non-table raises.
-- Pure logic: no Roblox-specific interface is used.

local StylingItemLookup = require("./StylingItemLookup")

type StylingItem = StylingItemLookup.StylingItem
type StylingItemByStylingItemKey = StylingItemLookup.StylingItemByStylingItemKey
type AvailableStylingItemKeySet = StylingItemLookup.AvailableStylingItemKeySet

local OutfitValidator = {}

OutfitValidator.MAX_ACCESSORY_ITEM_COUNT = 3

-- Item slots that may hold at most one item each (§1.5 rule 3).
OutfitValidator.SINGLE_ITEM_SLOTS = table.freeze({
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

-- The most items any valid outfit can hold (12): one per single-item slot except the dress
-- (rule 5 makes a top plus a bottom the larger choice), plus the accessories. A longer list can
-- never be valid (rule 2 forbids repeats), so it is rejected before any per-item work, which caps
-- the work done for hostile input.
OutfitValidator.MAX_OUTFIT_ITEM_COUNT = #OutfitValidator.SINGLE_ITEM_SLOTS
	- 1
	+ OutfitValidator.MAX_ACCESSORY_ITEM_COUNT

-- Longer than any key the item pool tool can derive ("bundle_" + a 16-digit id is 23 characters).
-- A longer string cannot be a pool key; rejecting it early keeps hostile strings cheap.
OutfitValidator.MAX_STYLING_ITEM_KEY_LENGTH = 40

-- Why an outfit was rejected. Each reason names the §1.5 rule it belongs to in
-- OUTFIT_RULE_NUMBER_BY_REJECTION_REASON; the two shape reasons belong to no rule.
OutfitValidator.OUTFIT_REJECTION_REASONS = table.freeze({
	StylingItemNotInPool = "StylingItemNotInPool", -- rule 1
	StylingItemDisabled = "StylingItemDisabled", -- rule 1
	StylingItemHiddenThisSession = "StylingItemHiddenThisSession", -- rule 1
	DuplicateStylingItem = "DuplicateStylingItem", -- rule 2
	TooManyItemsInSingleItemSlot = "TooManyItemsInSingleItemSlot", -- rule 3
	TooManyAccessoryItems = "TooManyAccessoryItems", -- rule 4
	DressCombinedWithTopOrBottom = "DressCombinedWithTopOrBottom", -- rule 5
	OutfitIsNotAListOfStylingItemKeys = "OutfitIsNotAListOfStylingItemKeys", -- input shape
	TooManyItemsInOutfit = "TooManyItemsInOutfit", -- longer than MAX_OUTFIT_ITEM_COUNT
})

OutfitValidator.OUTFIT_RULE_NUMBER_BY_REJECTION_REASON = table.freeze({
	StylingItemNotInPool = 1,
	StylingItemDisabled = 1,
	StylingItemHiddenThisSession = 1,
	DuplicateStylingItem = 2,
	TooManyItemsInSingleItemSlot = 3,
	TooManyAccessoryItems = 4,
	DressCombinedWithTopOrBottom = 5,
})

export type OutfitValidationVerdict = {
	isOutfitValid: boolean,
	-- Set only when the outfit is invalid: one of OUTFIT_REJECTION_REASONS.
	outfitRejectionReason: string?,
	-- Set when the rejection is one of the §1.5 rules: 1 to 5. Nil for the two shape reasons.
	failedOutfitRuleNumber: number?,
	-- Set when the rejection is about one item: the key that broke the rule.
	offendingStylingItemKey: string?,
	-- Set when the rejection is about an item slot (rules 3 and 4).
	offendingItemSlot: string?,
}

local isSingleItemSlot: { [string]: boolean } = {}
for _, singleItemSlot in OutfitValidator.SINGLE_ITEM_SLOTS do
	isSingleItemSlot[singleItemSlot] = true
end

local VALID_OUTFIT_VERDICT: OutfitValidationVerdict = table.freeze({ isOutfitValid = true })

local function rejectOutfit(
	outfitRejectionReason: string,
	offendingStylingItemKey: string?,
	offendingItemSlot: string?
): OutfitValidationVerdict
	return table.freeze({
		isOutfitValid = false,
		outfitRejectionReason = outfitRejectionReason,
		failedOutfitRuleNumber = OutfitValidator.OUTFIT_RULE_NUMBER_BY_REJECTION_REASON[outfitRejectionReason],
		offendingStylingItemKey = offendingStylingItemKey,
		offendingItemSlot = offendingItemSlot,
	})
end

-- Returns the outfit's keys as a fresh array, or a rejection when the value is not a plain list
-- (keys 1..n, no holes, no other keys) of short strings no longer than MAX_OUTFIT_ITEM_COUNT.
-- Uses raw access only, so a table with metamethods cannot run code or lie about its contents.
local function readUntrustedOutfitStylingItemKeys(
	untrustedOutfitStylingItemKeys: any
): ({ string }?, OutfitValidationVerdict?)
	if type(untrustedOutfitStylingItemKeys) ~= "table" or getmetatable(untrustedOutfitStylingItemKeys) ~= nil then
		return nil, rejectOutfit(OutfitValidator.OUTFIT_REJECTION_REASONS.OutfitIsNotAListOfStylingItemKeys)
	end
	local entryCount = 0
	for _ in next, untrustedOutfitStylingItemKeys do
		entryCount += 1
		if entryCount > OutfitValidator.MAX_OUTFIT_ITEM_COUNT then
			return nil, rejectOutfit(OutfitValidator.OUTFIT_REJECTION_REASONS.TooManyItemsInOutfit)
		end
	end
	local outfitStylingItemKeys = table.create(entryCount)
	for listPosition = 1, entryCount do
		local outfitStylingItemKey = rawget(untrustedOutfitStylingItemKeys, listPosition)
		if
			type(outfitStylingItemKey) ~= "string"
			or #outfitStylingItemKey > OutfitValidator.MAX_STYLING_ITEM_KEY_LENGTH
		then
			-- A hole in the list, a key that is not 1..n, or an entry that is not a short string.
			return nil, rejectOutfit(OutfitValidator.OUTFIT_REJECTION_REASONS.OutfitIsNotAListOfStylingItemKeys)
		end
		outfitStylingItemKeys[listPosition] = outfitStylingItemKey
	end
	return outfitStylingItemKeys, nil
end

-- Checks a submitted outfit against the five rules of §1.5, in rule order, and reports the
-- lowest-numbered rule that fails. An empty list is valid.
--
-- `untrustedOutfitStylingItemKeys` may be any value. `stylingItemByStylingItemKey` comes from
-- StylingItemLookup.buildStylingItemByStylingItemKey. `availableStylingItemKeySet` holds `true`
-- for every key that is not hidden this server session; a key missing from it is hidden.
function OutfitValidator.validateOutfit(
	untrustedOutfitStylingItemKeys: any,
	stylingItemByStylingItemKey: StylingItemByStylingItemKey,
	availableStylingItemKeySet: AvailableStylingItemKeySet
): OutfitValidationVerdict
	if type(stylingItemByStylingItemKey) ~= "table" or type(availableStylingItemKeySet) ~= "table" then
		error("OutfitValidator.validateOutfit: the styling item pool and the available key set must be tables", 2)
	end

	local outfitStylingItemKeys, shapeRejection = readUntrustedOutfitStylingItemKeys(untrustedOutfitStylingItemKeys)
	if outfitStylingItemKeys == nil then
		return shapeRejection :: OutfitValidationVerdict
	end

	-- Rule 1: every key is an enabled, non-hidden styling item of the pool.
	local wornStylingItems: { StylingItem } = {}
	for _, outfitStylingItemKey in outfitStylingItemKeys do
		local stylingItem = stylingItemByStylingItemKey[outfitStylingItemKey]
		if stylingItem == nil then
			return rejectOutfit(OutfitValidator.OUTFIT_REJECTION_REASONS.StylingItemNotInPool, outfitStylingItemKey)
		end
		if stylingItem.isEnabled ~= true then
			return rejectOutfit(OutfitValidator.OUTFIT_REJECTION_REASONS.StylingItemDisabled, outfitStylingItemKey)
		end
		if availableStylingItemKeySet[outfitStylingItemKey] ~= true then
			return rejectOutfit(
				OutfitValidator.OUTFIT_REJECTION_REASONS.StylingItemHiddenThisSession,
				outfitStylingItemKey
			)
		end
		table.insert(wornStylingItems, stylingItem)
	end

	-- Rule 2: no key appears twice.
	local isStylingItemKeyAlreadySeen: { [string]: boolean } = {}
	for _, outfitStylingItemKey in outfitStylingItemKeys do
		if isStylingItemKeyAlreadySeen[outfitStylingItemKey] then
			return rejectOutfit(OutfitValidator.OUTFIT_REJECTION_REASONS.DuplicateStylingItem, outfitStylingItemKey)
		end
		isStylingItemKeyAlreadySeen[outfitStylingItemKey] = true
	end

	-- Rules 3 and 4: per-slot limits. A shoes bundle is one styling item, so it counts once.
	local wornItemCountByItemSlot: { [string]: number } = {}
	for _, wornStylingItem in wornStylingItems do
		local itemSlot = wornStylingItem.itemSlot
		wornItemCountByItemSlot[itemSlot] = (wornItemCountByItemSlot[itemSlot] or 0) + 1
	end
	for _, wornStylingItem in wornStylingItems do
		local itemSlot = wornStylingItem.itemSlot
		if isSingleItemSlot[itemSlot] and wornItemCountByItemSlot[itemSlot] > 1 then
			return rejectOutfit(
				OutfitValidator.OUTFIT_REJECTION_REASONS.TooManyItemsInSingleItemSlot,
				wornStylingItem.stylingItemKey,
				itemSlot
			)
		end
	end
	if (wornItemCountByItemSlot.accessory or 0) > OutfitValidator.MAX_ACCESSORY_ITEM_COUNT then
		return rejectOutfit(OutfitValidator.OUTFIT_REJECTION_REASONS.TooManyAccessoryItems, nil, "accessory")
	end

	-- Rule 5: a dress cannot be combined with a top or a bottom.
	if
		(wornItemCountByItemSlot.dress or 0) > 0
		and ((wornItemCountByItemSlot.top or 0) > 0 or (wornItemCountByItemSlot.bottom or 0) > 0)
	then
		return rejectOutfit(OutfitValidator.OUTFIT_REJECTION_REASONS.DressCombinedWithTopOrBottom)
	end

	return VALID_OUTFIT_VERDICT
end

return table.freeze(OutfitValidator)
