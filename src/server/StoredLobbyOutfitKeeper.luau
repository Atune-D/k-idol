-- StoredLobbyOutfitKeeper (development spec v1.3 §1.5 "Stored outfits that contain unavailable
-- items", §2.4 lobby appearance, §2.6 `unavailableLobbyOutfitStylingItemKeys`): looks after every
-- online player's STORED lobby outfit (`lobbyOutfitStylingItemKeys` in the save).
--
-- Calls no Roblox-specific interface. Everything external is injected (see `new`).
--
-- Rules it enforces (the decision itself is StoredLobbyOutfitResolver's):
--   * When a save has loaded, every stored key that is no longer in the pool, or whose row has
--     isEnabled = false, is removed from the save ONCE, through
--     playerSaveDataKeeper:applyChangeToPlayerSaveData, as an "AppearanceChangeSavedLater" change:
--     no save is requested, the removal is written by the next save of any kind (§3.4).
--     A save with nothing to remove is not touched at all (no change call, no revision bump).
--   * 🔴 A key that is in the pool but hidden this server session is NEVER removed. Removal is
--     decided from the pool alone, never from the wardrobe catalog, so a catalog that is not
--     ready yet (whose available set is empty) cannot erase anything.
--   * Hidden keys are skipped when dressing and reported as unavailable (§2.6).
--   * While the wardrobe catalog is NOT ready, nothing is known about what is hidden: the player
--     is reported with no unavailable keys and nothing wearable (the player's own avatar), and
--     `isWardrobeCatalogReady = false`. When the catalog becomes ready, or its version changes,
--     every online player is worked out again and listeners are told about each player whose
--     availability changed.
--   * The availability also follows later in-memory changes of `lobbyOutfitStylingItemKeys`
--     (for example the Phase 2 `SetLobbyOutfit`); nothing is removed from the save then.
--   * A player is forgotten when the save keeper ends their session (they left, or the save
--     was lost to another server).
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- StoredLobbyOutfitKeeper.new(dependencies) -> keeper
--   dependencies = {
--     playerSaveDataKeeper: the PlayerSaveDataKeeper (subscribe* methods,
--         applyChangeToPlayerSaveData and readPlayerSaveDataCopy are used),
--     stylingItemByStylingItemKey: StylingItemLookup.StylingItemByStylingItemKey
--         (the whole pool, disabled rows included; normally built from the generated pool),
--     marketplaceStylingItemResolver: {
--       isWardrobeCatalogReady: (self) -> boolean,
--       getAvailableStylingItemKeySet: (self) -> StylingItemLookup.AvailableStylingItemKeySet,
--           (empty while the catalog is not ready)
--       subscribeToWardrobeCatalogChanged: (self, listener(wardrobeCatalogChangedMessage)) -> unsubscribe,
--     },
--     logger: { logInformation: (self, message: string) -> (), logWarning: (self, message: string) -> () },
--   }
-- keeper:startLookingAfterStoredLobbyOutfits()
--   Subscribes to the save keeper's and the resolver's events. Call once, before any player's
--   save can load. Calling it twice raises.
-- keeper:readStoredLobbyOutfitAvailability(playerUserId) -> StoredLobbyOutfitAvailability?
--   nil until the player's save has loaded, and again once the player is forgotten. Otherwise a
--   deeply frozen table:
--   {
--     isWardrobeCatalogReady: boolean,
--     lobbyOutfitStylingItemKeys: { string },            -- what the in-memory save holds now
--     unavailableLobbyOutfitStylingItemKeys: { string }, -- §2.6: stored keys hidden this session;
--                                                        -- always {} while the catalog is not ready
--     wearableLobbyOutfitStylingItemKeys: { string },    -- §2.4 lobby appearance, a valid outfit in
--                                                        -- stored order; {} = the player's own avatar;
--                                                        -- always {} while the catalog is not ready
--   }
-- keeper:subscribeToStoredLobbyOutfitAvailabilityChanged(listener(playerUserId, availability)) -> unsubscribe
--   Called once when a player's save has loaded (after any removal), then whenever that
--   player's availability changes (catalog readiness or version, or the stored list). Not
--   called when nothing changed. `availability` is the deeply frozen table above, so no
--   listener can change what another one sees. A listener that raises is logged and never
--   disturbs other listeners or the save keeper.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local PlayerSaveDataKeeper = require("./PlayerSaveDataKeeper")
local PlayerSaveDataSchema = require("./PlayerSaveDataSchema")
local StoredLobbyOutfitResolver = require("../shared/StoredLobbyOutfitResolver")
local StylingItemLookup = require("../shared/StylingItemLookup")

local arePlainValuesDeeplyEqual = PlayerSaveDataSchema.arePlainValuesDeeplyEqual

type AvailableStylingItemKeySet = StylingItemLookup.AvailableStylingItemKeySet

export type StoredLobbyOutfitAvailability = {
	isWardrobeCatalogReady: boolean,
	lobbyOutfitStylingItemKeys: { string },
	unavailableLobbyOutfitStylingItemKeys: { string },
	wearableLobbyOutfitStylingItemKeys: { string },
}

local StoredLobbyOutfitKeeper = {}
StoredLobbyOutfitKeeper.__index = StoredLobbyOutfitKeeper

StoredLobbyOutfitKeeper.REMOVAL_CHANGE_DESCRIPTION = "remove stored lobby outfit keys that left the styling item pool"

local EMPTY_AVAILABLE_STYLING_ITEM_KEY_SET: AvailableStylingItemKeySet = table.freeze({})

function StoredLobbyOutfitKeeper.new(dependencies)
	for _, requiredDependencyName in
		{ "playerSaveDataKeeper", "stylingItemByStylingItemKey", "marketplaceStylingItemResolver", "logger" }
	do
		if dependencies[requiredDependencyName] == nil then
			error("StoredLobbyOutfitKeeper.new: missing dependency " .. requiredDependencyName, 2)
		end
	end
	return setmetatable({
		playerSaveDataKeeper = dependencies.playerSaveDataKeeper,
		stylingItemByStylingItemKey = dependencies.stylingItemByStylingItemKey,
		marketplaceStylingItemResolver = dependencies.marketplaceStylingItemResolver,
		logger = dependencies.logger,

		hasStarted = false,
		-- Present for every player whose save has loaded and who has not been forgotten.
		storedLobbyOutfitAvailabilityByPlayerUserId = {} :: { [number]: StoredLobbyOutfitAvailability },
		availabilityChangedSubscriptions = {} :: { { listener: (number, StoredLobbyOutfitAvailability) -> () } },
	}, StoredLobbyOutfitKeeper)
end

-- ── working out a player's availability ─────────────────────────────────────────────────────

-- Reads the list with `ipairs`, exactly as StoredLobbyOutfitResolver does, so a damaged stored
-- value that is not a plain list (holes, extra fields) is read the same way by both.
local function copyStylingItemKeysIntoUnfrozenList(stylingItemKeys: { any }): { string }
	local plainStylingItemKeys = {}
	for _, stylingItemKey in ipairs(stylingItemKeys) do
		table.insert(plainStylingItemKeys, stylingItemKey)
	end
	return plainStylingItemKeys
end

local function readCatalogStateForDressing(self): (boolean, AvailableStylingItemKeySet)
	local isWardrobeCatalogReady = self.marketplaceStylingItemResolver:isWardrobeCatalogReady() == true
	if not isWardrobeCatalogReady then
		-- Nothing is known about hidden items yet; the empty set would make every key look hidden.
		return false, EMPTY_AVAILABLE_STYLING_ITEM_KEY_SET
	end
	return true, self.marketplaceStylingItemResolver:getAvailableStylingItemKeySet()
end

local function workOutStoredLobbyOutfitAvailability(
	self,
	storedLobbyOutfitStylingItemKeys: any
): StoredLobbyOutfitAvailability
	local isWardrobeCatalogReady, availableStylingItemKeySet = readCatalogStateForDressing(self)
	local storedLobbyOutfitResolution = StoredLobbyOutfitResolver.resolveStoredLobbyOutfitStylingItemKeys(
		storedLobbyOutfitStylingItemKeys,
		self.stylingItemByStylingItemKey,
		availableStylingItemKeySet
	)
	local lobbyOutfitStylingItemKeys = if type(storedLobbyOutfitStylingItemKeys) == "table"
		then copyStylingItemKeysIntoUnfrozenList(storedLobbyOutfitStylingItemKeys)
		else {}
	local unavailableLobbyOutfitStylingItemKeys = if isWardrobeCatalogReady
		then copyStylingItemKeysIntoUnfrozenList(storedLobbyOutfitResolution.unavailableStylingItemKeysThisSession)
		else {}
	return table.freeze({
		isWardrobeCatalogReady = isWardrobeCatalogReady,
		lobbyOutfitStylingItemKeys = table.freeze(lobbyOutfitStylingItemKeys),
		unavailableLobbyOutfitStylingItemKeys = table.freeze(unavailableLobbyOutfitStylingItemKeys),
		wearableLobbyOutfitStylingItemKeys = table.freeze(
			copyStylingItemKeysIntoUnfrozenList(storedLobbyOutfitResolution.wearableStylingItemKeys)
		),
	})
end

local function tellListenersAvailabilityChanged(self, playerUserId: number, availability: StoredLobbyOutfitAvailability)
	for _, subscription in table.clone(self.availabilityChangedSubscriptions) do
		local didListenerSucceed, listenerError = pcall(subscription.listener, playerUserId, availability)
		if not didListenerSucceed then
			self.logger:logWarning(
				string.format(
					"StoredLobbyOutfitKeeper: an availability-changed listener failed for player %d: %s",
					playerUserId,
					tostring(listenerError)
				)
			)
		end
	end
end

-- Stores the new availability of a player who is being looked after and tells listeners if it
-- differs from what was stored before.
local function refreshStoredLobbyOutfitAvailability(self, playerUserId: number, storedLobbyOutfitStylingItemKeys: any)
	local previousAvailability = self.storedLobbyOutfitAvailabilityByPlayerUserId[playerUserId]
	local newAvailability = workOutStoredLobbyOutfitAvailability(self, storedLobbyOutfitStylingItemKeys)
	if previousAvailability ~= nil and arePlainValuesDeeplyEqual(previousAvailability, newAvailability) then
		return
	end
	self.storedLobbyOutfitAvailabilityByPlayerUserId[playerUserId] = newAvailability
	tellListenersAvailabilityChanged(self, playerUserId, newAvailability)
end

-- ── removal at load ─────────────────────────────────────────────────────────────────────────

local function removeStylingItemKeysThatLeftThePool(self, playerUserId: number, loadedSaveDataCopy: any)
	-- Removal depends on the pool alone (§1.5 table, row 1), so the catalog state passed here is
	-- irrelevant to it; the empty set is used so it cannot matter.
	local loadedResolution = StoredLobbyOutfitResolver.resolveStoredLobbyOutfitStylingItemKeys(
		loadedSaveDataCopy.lobbyOutfitStylingItemKeys,
		self.stylingItemByStylingItemKey,
		EMPTY_AVAILABLE_STYLING_ITEM_KEY_SET
	)
	if #loadedResolution.stylingItemKeysToRemoveFromSave == 0 then
		return -- §2.13: nothing to change, so no change is made at all
	end

	local removedStylingItemKeys = {}
	local didApplyChange, changeResultOrError = pcall(function()
		return self.playerSaveDataKeeper:applyChangeToPlayerSaveData(
			playerUserId,
			PlayerSaveDataKeeper.APPEARANCE_CHANGE_SAVED_LATER,
			StoredLobbyOutfitKeeper.REMOVAL_CHANGE_DESCRIPTION,
			function(saveDataDraft)
				local draftResolution = StoredLobbyOutfitResolver.resolveStoredLobbyOutfitStylingItemKeys(
					saveDataDraft.lobbyOutfitStylingItemKeys,
					self.stylingItemByStylingItemKey,
					EMPTY_AVAILABLE_STYLING_ITEM_KEY_SET
				)
				if #draftResolution.stylingItemKeysToRemoveFromSave > 0 then
					removedStylingItemKeys = draftResolution.stylingItemKeysToRemoveFromSave
					saveDataDraft.lobbyOutfitStylingItemKeys =
						copyStylingItemKeysIntoUnfrozenList(draftResolution.keptStoredLobbyOutfitStylingItemKeys)
				end
				return true
			end
		)
	end)
	if not didApplyChange then
		self.logger:logWarning(
			string.format(
				"StoredLobbyOutfitKeeper: removing stored lobby outfit keys for player %d raised: %s",
				playerUserId,
				tostring(changeResultOrError)
			)
		)
		return
	end
	if changeResultOrError.changeOutcome ~= "Applied" then
		self.logger:logWarning(
			string.format(
				"StoredLobbyOutfitKeeper: removing stored lobby outfit keys for player %d ended with %s",
				playerUserId,
				tostring(changeResultOrError.changeOutcome)
			)
		)
		return
	end
	local removedStylingItemKeyTexts = {}
	for _, removedStylingItemKey in removedStylingItemKeys do
		table.insert(removedStylingItemKeyTexts, tostring(removedStylingItemKey))
	end
	self.logger:logInformation(
		string.format(
			"StoredLobbyOutfitKeeper: removed from player %d's stored lobby outfit (no longer in the pool or disabled): %s",
			playerUserId,
			table.concat(removedStylingItemKeyTexts, ", ")
		)
	)
end

-- ── save keeper and resolver events ─────────────────────────────────────────────────────────

local function onPlayerSaveDataLoaded(self, playerUserId: number, loadedSaveDataCopy: any)
	-- The player is not looked after yet, so the in-memory change event raised by the removal
	-- below is ignored; the availability is worked out once, from the save after the removal.
	self.storedLobbyOutfitAvailabilityByPlayerUserId[playerUserId] = nil
	removeStylingItemKeysThatLeftThePool(self, playerUserId, loadedSaveDataCopy)
	local inMemorySaveDataCopy = self.playerSaveDataKeeper:readPlayerSaveDataCopy(playerUserId)
	if inMemorySaveDataCopy == nil then
		return -- the player is already leaving
	end
	refreshStoredLobbyOutfitAvailability(self, playerUserId, inMemorySaveDataCopy.lobbyOutfitStylingItemKeys)
end

local function onInMemorySaveDataChanged(self, playerUserId: number, inMemorySaveDataCopy: any)
	-- Reachable: another module's "loaded" listener, subscribed before this keeper's, may change
	-- the save before this keeper has seen the load. Without this guard that change would
	-- publish an availability worked out before the removal, and listeners would be told twice.
	if self.storedLobbyOutfitAvailabilityByPlayerUserId[playerUserId] == nil then
		return
	end
	refreshStoredLobbyOutfitAvailability(self, playerUserId, inMemorySaveDataCopy.lobbyOutfitStylingItemKeys)
end

local function onWardrobeCatalogChanged(self)
	local lookedAfterPlayerUserIds = {}
	for playerUserId in self.storedLobbyOutfitAvailabilityByPlayerUserId do
		table.insert(lookedAfterPlayerUserIds, playerUserId)
	end
	table.sort(lookedAfterPlayerUserIds)
	for _, playerUserId in lookedAfterPlayerUserIds do
		local currentAvailability = self.storedLobbyOutfitAvailabilityByPlayerUserId[playerUserId]
		if currentAvailability ~= nil then
			refreshStoredLobbyOutfitAvailability(self, playerUserId, currentAvailability.lobbyOutfitStylingItemKeys)
		end
	end
end

-- ── public API ──────────────────────────────────────────────────────────────────────────────

function StoredLobbyOutfitKeeper:startLookingAfterStoredLobbyOutfits()
	if self.hasStarted then
		error("StoredLobbyOutfitKeeper: startLookingAfterStoredLobbyOutfits was already called", 2)
	end
	self.hasStarted = true
	self.playerSaveDataKeeper:subscribeToPlayerSaveDataLoaded(function(playerUserId, loadedSaveDataCopy)
		onPlayerSaveDataLoaded(self, playerUserId, loadedSaveDataCopy)
	end)
	self.playerSaveDataKeeper:subscribeToInMemorySaveDataChanged(function(playerUserId, inMemorySaveDataCopy)
		onInMemorySaveDataChanged(self, playerUserId, inMemorySaveDataCopy)
	end)
	self.playerSaveDataKeeper:subscribeToPlayerSaveDataSessionEnded(function(playerUserId)
		self.storedLobbyOutfitAvailabilityByPlayerUserId[playerUserId] = nil
	end)
	self.marketplaceStylingItemResolver:subscribeToWardrobeCatalogChanged(function()
		onWardrobeCatalogChanged(self)
	end)
end

function StoredLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(playerUserId: number): StoredLobbyOutfitAvailability?
	return self.storedLobbyOutfitAvailabilityByPlayerUserId[playerUserId]
end

function StoredLobbyOutfitKeeper:subscribeToStoredLobbyOutfitAvailabilityChanged(listener: (
	number,
	StoredLobbyOutfitAvailability
) -> ()): () -> ()
	if type(listener) ~= "function" then
		error("StoredLobbyOutfitKeeper: listener must be a function", 2)
	end
	local subscription = { listener = listener }
	table.insert(self.availabilityChangedSubscriptions, subscription)
	return function()
		local subscriptionIndex = table.find(self.availabilityChangedSubscriptions, subscription)
		if subscriptionIndex then
			table.remove(self.availabilityChangedSubscriptions, subscriptionIndex)
		end
	end
end

return StoredLobbyOutfitKeeper
