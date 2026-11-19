-- Decides what to do with a STORED outfit (`lobbyOutfitStylingItemKeys` in the save) whose items
-- may have become unavailable since it was stored (development spec §1.5, "Stored outfits that
-- contain unavailable items"; §2.4; §2.6).
--
--   Key no longer in the pool, or its row has isEnabled = false   -> skipped when dressing,
--                                                                     removed from the save
--   Key in the pool but hidden this server session (§1.2)        -> skipped when dressing,
--                                                                     KEPT in the save
--   Otherwise                                                     -> worn
--
-- A temporary fault (hidden item) must never erase part of a stored outfit.
--
-- Not covered by the spec, handled conservatively here: an available key that would break a §1.5
-- rule together with the keys already chosen to be worn (a repeated key, or a conflict caused by
-- the owner changing an item's slot after the outfit was stored) is skipped when dressing and
-- kept in the save, so the wearable part is always a valid outfit and nothing is erased on a
-- case the spec does not name. Such keys are reported separately.
-- Pure logic: no Roblox-specific interface is used.

local OutfitValidator = require("./OutfitValidator")
local StylingItemLookup = require("./StylingItemLookup")

type StylingItemByStylingItemKey = StylingItemLookup.StylingItemByStylingItemKey
type AvailableStylingItemKeySet = StylingItemLookup.AvailableStylingItemKeySet

export type StoredLobbyOutfitResolution = {
	-- What to dress the character in, in stored order. Always a valid outfit (§1.5).
	wearableStylingItemKeys: { string },
	-- Entries to delete from `lobbyOutfitStylingItemKeys` when the save is loaded: keys no longer
	-- in the pool or disabled, plus any entry that is not a string at all (it cannot be a key).
	stylingItemKeysToRemoveFromSave: { any },
	-- Keys hidden this server session; kept in the save. This is
	-- `unavailableLobbyOutfitStylingItemKeys` of §2.6.
	unavailableStylingItemKeysThisSession: { string },
	-- Available keys skipped because wearing them would break a §1.5 rule; kept in the save.
	stylingItemKeysSkippedForBreakingOutfitRules: { string },
	-- The stored list with only the removed entries taken out, in stored order: the value
	-- `lobbyOutfitStylingItemKeys` should hold after loading.
	keptStoredLobbyOutfitStylingItemKeys: { string },
}

local StoredLobbyOutfitResolver = {}

-- `storedOutfitStylingItemKeys` comes from a save; anything that is not a table is treated as an
-- empty outfit. The pool and the available key set are the same ones OutfitValidator takes.
function StoredLobbyOutfitResolver.resolveStoredLobbyOutfitStylingItemKeys(
	storedOutfitStylingItemKeys: any,
	stylingItemByStylingItemKey: StylingItemByStylingItemKey,
	availableStylingItemKeySet: AvailableStylingItemKeySet
): StoredLobbyOutfitResolution
	local wearableStylingItemKeys: { string } = {}
	local stylingItemKeysToRemoveFromSave: { any } = {}
	local unavailableStylingItemKeysThisSession: { string } = {}
	local stylingItemKeysSkippedForBreakingOutfitRules: { string } = {}
	local keptStoredLobbyOutfitStylingItemKeys: { string } = {}

	if type(storedOutfitStylingItemKeys) == "table" then
		for _, storedStylingItemKey in ipairs(storedOutfitStylingItemKeys) do
			local stylingItem = if type(storedStylingItemKey) == "string"
				then stylingItemByStylingItemKey[storedStylingItemKey]
				else nil
			if stylingItem == nil or stylingItem.isEnabled ~= true then
				table.insert(stylingItemKeysToRemoveFromSave, storedStylingItemKey)
				continue
			end
			table.insert(keptStoredLobbyOutfitStylingItemKeys, storedStylingItemKey)
			if availableStylingItemKeySet[storedStylingItemKey] ~= true then
				table.insert(unavailableStylingItemKeysThisSession, storedStylingItemKey)
				continue
			end
			local candidateWearableStylingItemKeys = table.clone(wearableStylingItemKeys)
			table.insert(candidateWearableStylingItemKeys, storedStylingItemKey)
			local candidateVerdict = OutfitValidator.validateOutfit(
				candidateWearableStylingItemKeys,
				stylingItemByStylingItemKey,
				availableStylingItemKeySet
			)
			if candidateVerdict.isOutfitValid then
				wearableStylingItemKeys = candidateWearableStylingItemKeys
			else
				table.insert(stylingItemKeysSkippedForBreakingOutfitRules, storedStylingItemKey)
			end
		end
	end

	return table.freeze({
		wearableStylingItemKeys = table.freeze(wearableStylingItemKeys),
		stylingItemKeysToRemoveFromSave = table.freeze(stylingItemKeysToRemoveFromSave),
		unavailableStylingItemKeysThisSession = table.freeze(unavailableStylingItemKeysThisSession),
		stylingItemKeysSkippedForBreakingOutfitRules = table.freeze(stylingItemKeysSkippedForBreakingOutfitRules),
		keptStoredLobbyOutfitStylingItemKeys = table.freeze(keptStoredLobbyOutfitStylingItemKeys),
	})
end

return table.freeze(StoredLobbyOutfitResolver)
