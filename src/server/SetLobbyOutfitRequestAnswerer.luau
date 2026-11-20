-- SetLobbyOutfitRequestAnswerer (development spec v1.3 §2.7, §2.13, §2.14, §3.4): answers the
-- device's `SetLobbyOutfit` request and stores the accepted outfit as the player's
-- `lobbyOutfitStylingItemKeys` (§1.10).
--
-- Calls no Roblox-specific interface. Everything external is injected (see `new`).
--
-- It does NOT dress the character. Dressing (§3.7) reacts to
-- StoredLobbyOutfitKeeper:subscribeToStoredLobbyOutfitAvailabilityChanged, which already follows
-- every in-memory change of `lobbyOutfitStylingItemKeys`; an accepted change made here reaches
-- that subscription with the new wearable outfit.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (the server wiring is written from this)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- SetLobbyOutfitRequestAnswerer.SET_LOBBY_OUTFIT_REJECTION_REASONS
--   { SaveDataNotLoaded, WardrobeCatalogNotReady, OutfitInvalid, NotAllowedDuringRound,
--     TooManyRequests } (§2.7), frozen.
-- SetLobbyOutfitRequestAnswerer.SET_LOBBY_OUTFIT_CHANGE_DESCRIPTION   the save-change log text.
--
-- SetLobbyOutfitRequestAnswerer.new(dependencies) -> answerer
--   dependencies = {
--     playerSaveDataKeeper: the PlayerSaveDataKeeper (isPlayerSaveDataLoaded,
--         readPlayerSaveDataCopy and applyChangeToPlayerSaveData are used),
--     playerRequestRateLimiter: the PlayerRequestRateLimiter (admitOrRefusePlayerRequest),
--     marketplaceStylingItemResolver: {
--       isWardrobeCatalogReady: (self) -> boolean,
--       getAvailableStylingItemKeySet: (self) -> StylingItemLookup.AvailableStylingItemKeySet,
--     },   the catalog the server last published (§2.14 🔴)
--     stylingItemByStylingItemKey: StylingItemLookup.StylingItemByStylingItemKey (the whole pool),
--     isPlayerStylingOrShowcaseParticipant: (playerUserId: number) -> boolean,
--         Must answer `true` exactly when the player is a participant of the CURRENT themed round
--         AND that round's `roundPhase` is `Styling` or `Showcase` (§2.7); `false` otherwise
--         (not a participant, or the phase is ThemeReveal, Results or Intermission). Normally
--         answered by the themed-round referee. Any answer other than `false` (nil, a string,
--         ...) is treated as "busy", so a faulty answer refuses rather than allows. If it
--         raises, the error reaches the caller (a wiring bug, not device input).
--   }
--   Raises when a dependency is missing.
--
-- answerer:answerSetLobbyOutfitRequest(playerUserId, untrustedSetLobbyOutfitRequest) -> answer
--   `playerUserId` is the server's own id of the sending player (trusted).
--   `untrustedSetLobbyOutfitRequest` is whatever the device sent, expected
--   `{ outfitStylingItemKeys = { stylingItemKey, ... } }`; ANY value is accepted as input and
--   nothing in it makes this raise. Checks, in this order; the first that fails answers:
--     1. The rate limiter, channel `SetLobbyOutfit` (2 s, §2.13). Refused -> its rejectionReason
--        (`TooManyRequests`); nothing else is looked at.
--     2. The save has not loaded (or the player is leaving) -> `SaveDataNotLoaded`.
--     3. The player is a Styling or Showcase participant -> `NotAllowedDuringRound`.
--     4. The wardrobe catalog is not ready -> `WardrobeCatalogNotReady` (even for an empty outfit).
--     5. The save copy cannot be read any more (the player started leaving during the injected
--        round question) -> `SaveDataNotLoaded`.
--     6. The request is not a table, has a metatable (Roblox never delivers one; refused before
--        it is read), or its `outfitStylingItemKeys` is not a plain list (keys 1..n, no
--        metatable) of at most MAX_OUTFIT_ITEM_COUNT short strings -> `OutfitInvalid`.
--     7. The submitted list is compared with the STORED outfit (the save keeper's copy):
--        * exactly the stored list (same keys, same order) -> accepted, nothing changes
--          (§2.13), even when some stored keys are hidden this session;
--        * exactly the stored list WITHOUT the keys hidden this session (what the device can
--          show, same order) -> accepted, nothing changes: the hidden keys stay stored (§1.5 🔴
--          "A temporary fault must never erase part of a stored outfit").
--     8. The list is not a valid outfit (§1.5) against the published catalog's available key
--        set (OutfitValidator: unknown, disabled or hidden key, repeats, slot limits, dress with
--        top or bottom) -> `OutfitInvalid`.
--   Any other valid submission REPLACES the whole stored list, so stored keys hidden this
--   session are dropped when the player chooses a different outfit (decided: the player chose a new outfit).
--   Then the outfit is stored through playerSaveDataKeeper:applyChangeToPlayerSaveData as an
--   "AppearanceChangeSavedLater" change (no save is requested, §3.4) described by
--   SET_LOBBY_OUTFIT_CHANGE_DESCRIPTION. What is stored is the server's OWN new list of the keys,
--   in the order sent; the device's table is never stored or kept.
--   Answers (a new table every call):
--     { isAccepted = true }
--     { isAccepted = false, rejectionReason = <one of SET_LOBBY_OUTFIT_REJECTION_REASONS> }
--   If the save keeper reports "SaveDataNotLoaded" for the change itself (the player started
--   leaving), the answer is `SaveDataNotLoaded`. Any other outcome than "Applied",
--   "AppliedWithoutAnyDifference" or "SaveDataNotLoaded" is a programming error and raises.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local OutfitValidator = require("../shared/OutfitValidator")
local PlayerSaveDataKeeper = require("./PlayerSaveDataKeeper")
local RemoteNames = require("../shared/RemoteNames")

local SetLobbyOutfitRequestAnswerer = {}
SetLobbyOutfitRequestAnswerer.__index = SetLobbyOutfitRequestAnswerer

SetLobbyOutfitRequestAnswerer.SET_LOBBY_OUTFIT_REJECTION_REASONS = table.freeze({
	SaveDataNotLoaded = "SaveDataNotLoaded",
	WardrobeCatalogNotReady = "WardrobeCatalogNotReady",
	OutfitInvalid = "OutfitInvalid",
	NotAllowedDuringRound = "NotAllowedDuringRound",
	TooManyRequests = "TooManyRequests",
})

SetLobbyOutfitRequestAnswerer.SET_LOBBY_OUTFIT_CHANGE_DESCRIPTION = "set lobby outfit"

local SET_LOBBY_OUTFIT_CHANNEL_NAME = RemoteNames.REMOTE_CHANNEL_NAMES.SetLobbyOutfit

function SetLobbyOutfitRequestAnswerer.new(dependencies)
	for _, requiredDependencyName in
		{
			"playerSaveDataKeeper",
			"playerRequestRateLimiter",
			"marketplaceStylingItemResolver",
			"stylingItemByStylingItemKey",
			"isPlayerStylingOrShowcaseParticipant",
		}
	do
		if dependencies[requiredDependencyName] == nil then
			error("SetLobbyOutfitRequestAnswerer.new: missing dependency " .. requiredDependencyName, 2)
		end
	end
	return setmetatable({
		playerSaveDataKeeper = dependencies.playerSaveDataKeeper,
		playerRequestRateLimiter = dependencies.playerRequestRateLimiter,
		marketplaceStylingItemResolver = dependencies.marketplaceStylingItemResolver,
		stylingItemByStylingItemKey = dependencies.stylingItemByStylingItemKey,
		isPlayerStylingOrShowcaseParticipant = dependencies.isPlayerStylingOrShowcaseParticipant,
	}, SetLobbyOutfitRequestAnswerer)
end

local function rejectSetLobbyOutfitRequest(rejectionReason: string)
	return { isAccepted = false, rejectionReason = rejectionReason }
end

local function areStylingItemKeyListsEqual(firstKeys: { string }, secondKeys: { string }): boolean
	if #firstKeys ~= #secondKeys then
		return false
	end
	for listPosition, firstKey in firstKeys do
		if secondKeys[listPosition] ~= firstKey then
			return false
		end
	end
	return true
end

local function listStoredKeysAvailableThisSession(storedKeys: { string }, availableStylingItemKeySet): { string }
	local availableStoredKeys = {}
	for _, storedKey in storedKeys do
		if availableStylingItemKeySet[storedKey] == true then
			table.insert(availableStoredKeys, storedKey)
		end
	end
	return availableStoredKeys
end

-- Returns the server's own copy of the submitted keys and OutfitValidator's verdict on them, or
-- nil when the request does not carry a plain list of short strings (the validator's shape
-- rules: no metatable, keys 1..n only, at most MAX_OUTFIT_ITEM_COUNT entries; checked with
-- bounded work). A request with a metatable is refused before it is read (Roblox never delivers
-- one), so no device code can run.
local function readSubmittedOutfitStylingItemKeysCopy(
	self,
	untrustedSetLobbyOutfitRequest: any,
	availableStylingItemKeySet
): ({ string }?, OutfitValidator.OutfitValidationVerdict?)
	if type(untrustedSetLobbyOutfitRequest) ~= "table" or getmetatable(untrustedSetLobbyOutfitRequest) ~= nil then
		return nil, nil
	end
	local untrustedOutfitStylingItemKeys = untrustedSetLobbyOutfitRequest.outfitStylingItemKeys
	local outfitValidationVerdict = OutfitValidator.validateOutfit(
		untrustedOutfitStylingItemKeys,
		self.stylingItemByStylingItemKey,
		availableStylingItemKeySet
	)
	-- Only the two shape reasons carry no §1.5 rule number.
	if not outfitValidationVerdict.isOutfitValid and outfitValidationVerdict.failedOutfitRuleNumber == nil then
		return nil, nil
	end
	local outfitStylingItemKeysCopy = {}
	for listPosition = 1, #untrustedOutfitStylingItemKeys do
		outfitStylingItemKeysCopy[listPosition] = untrustedOutfitStylingItemKeys[listPosition]
	end
	return outfitStylingItemKeysCopy, outfitValidationVerdict
end

function SetLobbyOutfitRequestAnswerer:answerSetLobbyOutfitRequest(
	playerUserId: number,
	untrustedSetLobbyOutfitRequest: any
)
	local rateLimitDecision =
		self.playerRequestRateLimiter:admitOrRefusePlayerRequest(playerUserId, SET_LOBBY_OUTFIT_CHANNEL_NAME)
	if not rateLimitDecision.isRequestAllowed then
		return rejectSetLobbyOutfitRequest(rateLimitDecision.rejectionReason)
	end
	if not self.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId) then
		return rejectSetLobbyOutfitRequest(
			SetLobbyOutfitRequestAnswerer.SET_LOBBY_OUTFIT_REJECTION_REASONS.SaveDataNotLoaded
		)
	end
	if self.isPlayerStylingOrShowcaseParticipant(playerUserId) ~= false then
		return rejectSetLobbyOutfitRequest(
			SetLobbyOutfitRequestAnswerer.SET_LOBBY_OUTFIT_REJECTION_REASONS.NotAllowedDuringRound
		)
	end
	if self.marketplaceStylingItemResolver:isWardrobeCatalogReady() ~= true then
		return rejectSetLobbyOutfitRequest(
			SetLobbyOutfitRequestAnswerer.SET_LOBBY_OUTFIT_REJECTION_REASONS.WardrobeCatalogNotReady
		)
	end
	-- Read after the injected round question, which may have let the player start leaving.
	local playerSaveDataCopy = self.playerSaveDataKeeper:readPlayerSaveDataCopy(playerUserId)
	if playerSaveDataCopy == nil then
		return rejectSetLobbyOutfitRequest(
			SetLobbyOutfitRequestAnswerer.SET_LOBBY_OUTFIT_REJECTION_REASONS.SaveDataNotLoaded
		)
	end
	local availableStylingItemKeySet = self.marketplaceStylingItemResolver:getAvailableStylingItemKeySet()
	local outfitStylingItemKeysCopy, outfitValidationVerdict =
		readSubmittedOutfitStylingItemKeysCopy(self, untrustedSetLobbyOutfitRequest, availableStylingItemKeySet)
	if outfitStylingItemKeysCopy == nil then
		return rejectSetLobbyOutfitRequest(
			SetLobbyOutfitRequestAnswerer.SET_LOBBY_OUTFIT_REJECTION_REASONS.OutfitInvalid
		)
	end
	local storedOutfitStylingItemKeys = playerSaveDataCopy.lobbyOutfitStylingItemKeys
	if
		areStylingItemKeyListsEqual(outfitStylingItemKeysCopy, storedOutfitStylingItemKeys)
		or areStylingItemKeyListsEqual(
			outfitStylingItemKeysCopy,
			listStoredKeysAvailableThisSession(storedOutfitStylingItemKeys, availableStylingItemKeySet)
		)
	then
		return { isAccepted = true } -- keeps the stored list, hidden keys included (§1.5, §2.13)
	end
	if not (outfitValidationVerdict :: OutfitValidator.OutfitValidationVerdict).isOutfitValid then
		return rejectSetLobbyOutfitRequest(
			SetLobbyOutfitRequestAnswerer.SET_LOBBY_OUTFIT_REJECTION_REASONS.OutfitInvalid
		)
	end

	-- An equal outfit was answered above; "AppliedWithoutAnyDifference" is still the keeper's
	-- answer for a draft equal to the save, which is not a change (§2.13).
	local changeResult = self.playerSaveDataKeeper:applyChangeToPlayerSaveData(
		playerUserId,
		PlayerSaveDataKeeper.APPEARANCE_CHANGE_SAVED_LATER,
		SetLobbyOutfitRequestAnswerer.SET_LOBBY_OUTFIT_CHANGE_DESCRIPTION,
		function(saveDataDraft)
			saveDataDraft.lobbyOutfitStylingItemKeys = outfitStylingItemKeysCopy
			return true
		end
	)
	local changeOutcome = changeResult.changeOutcome
	if changeOutcome == "Applied" or changeOutcome == "AppliedWithoutAnyDifference" then
		return { isAccepted = true }
	end
	if changeOutcome == "SaveDataNotLoaded" then
		return rejectSetLobbyOutfitRequest(
			SetLobbyOutfitRequestAnswerer.SET_LOBBY_OUTFIT_REJECTION_REASONS.SaveDataNotLoaded
		)
	end
	error(
		string.format(
			"SetLobbyOutfitRequestAnswerer: unexpected save change outcome %s for player %s",
			tostring(changeOutcome),
			tostring(playerUserId)
		),
		2
	)
end

return SetLobbyOutfitRequestAnswerer
