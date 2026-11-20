-- PlayerSaveDataSnapshotPublisher (development spec v1.3 §2.6 `PlayerSaveDataSnapshotChanged`,
-- server -> the owning device): keeps every online player's device showing what the server holds
-- for that player. 🔴 The device shows balances only from this message (§2.6, §5.1).
--
-- Calls no Roblox-specific interface. Everything external is injected (see `new`); the server
-- wiring passes a sender that fires the RemoteEvent RemoteNames.REMOTE_CHANNEL_NAMES
-- .PlayerSaveDataSnapshotChanged to that one player.
--
-- What it sends: PlayerSaveDataSnapshotMessageBuilder's message, built at the moment of sending
-- from the server's CURRENT state (never from an event's possibly older copy):
--   * the in-memory save           keeper:readPlayerSaveDataCopy(playerUserId)
--   * isSaveDataPersistenceDelayed keeper:isSaveDataPersistenceDelayed(playerUserId)
--   * unavailable stored keys      storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(playerUserId)
--   * todaysDailyQuestIds          DailyQuestOfTheDaySelector, for the clock's UTC date, from the
--                                  injected daily quest catalog
--
-- When it sends (each time only if the message differs from the last one sent to that player):
--   * the player's save has loaded;
--   * the in-memory save changed; the persistence-delayed state changed; the player's stored
--     lobby outfit availability changed (StoredLobbyOutfitKeeper); the UTC date changed while
--     the player is online (UtcDailyDateKeyChangeWatcher).
--
-- Rules (the reasons are in the comments at the code):
--   * 🔴 Never an inconsistent picture. A message is sent at once only when
--     StoredLobbyOutfitKeeper's availability describes the SAME lobby outfit as the in-memory save.
--     Otherwise (the outfit keeper has not processed a load or a lobby outfit change yet) nothing
--     is sent now: the outfit keeper tells listeners as soon as it has caught up, and the message
--     is sent then. Every message is therefore a state the server really held, and the last
--     message after any burst of changes matches the server's final state.
--   * Fallback when the outfit keeper does NOT catch up (it failed while handling the load, it
--     forgot the player, it was never started): a held-back message is re-checked
--     STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS later. If the availability still does not describe
--     the saved lobby outfit, the message is sent with unavailableLobbyOutfitStylingItemKeys = {}
--     (the "nothing known about hidden items" picture §2.6 already uses while the wardrobe
--     catalog is not ready), and ONE warning per player save session is logged. Balances are
--     therefore never held back for longer than that wait.
--   * Messages per load (both subscription orders give the same counts):
--       catalog ready, nothing removed at load               -> 1 message
--       catalog ready, keys that left the pool removed        -> 1 message (after the removal)
--       catalog NOT ready                                     -> 1 message (no unavailable keys
--         are known yet, §2.6 field is empty), then 1 more when the catalog becomes ready ONLY if
--         that makes some stored keys unavailable (otherwise the message would be identical).
--       outfit keeper never catches up                        -> 1 message, after the wait above
--   * Identical consecutive messages to a player are suppressed (§2.13: a no-op causes no
--     snapshot message). The comparison is against a private deep copy of the last message
--     handed to the sender, recorded BEFORE the sender runs (so a change the sender itself
--     causes is compared against this message); if the sender raised, nothing counts as sent and
--     the next change sends. Each "save loaded" starts from nothing sent.
--   * Nothing is sent once the player has started leaving (the keeper reports the save as not
--     loaded). A "session ended" event forgets the player, unless the keeper reports a loaded
--     save for that user id at that moment: that is the late end of an OLD session after the
--     player rejoined and a new session loaded, and the new session keeps being published.
--     A forgotten player is sent nothing afterwards unless their save loads again.
--   * At a UTC date change every published player is re-checked once, in ascending user id
--     order, from a list taken before the first send (a sender that loads or ends players during
--     the fan-out changes neither who is checked nor how often).
--   * A sender or a source that raises is logged as a warning (error text cut by
--     LoggedErrorTextShortener) and never disturbs the keeper, the other listeners or the other
--     players.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (the server wiring is written from this)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- PlayerSaveDataSnapshotPublisher.STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS = 1
--   How long a message held back for the stored-outfit availability waits before the fallback.
--
-- PlayerSaveDataSnapshotPublisher.new(dependencies) -> publisher
--   dependencies = {
--     playerSaveDataKeeper: PlayerSaveDataKeeper  (subscribeToPlayerSaveDataLoaded,
--         subscribeToInMemorySaveDataChanged, subscribeToSaveDataPersistenceDelayedChanged,
--         subscribeToPlayerSaveDataSessionEnded, readPlayerSaveDataCopy, isPlayerSaveDataLoaded
--         and isSaveDataPersistenceDelayed are used),
--     storedLobbyOutfitKeeper: StoredLobbyOutfitKeeper  (readStoredLobbyOutfitAvailability and
--         subscribeToStoredLobbyOutfitAvailabilityChanged are used),
--     clock: { getCurrentUnixSeconds: (self) -> number },
--     scheduler: { scheduleCallbackAfterSeconds: (self, delaySeconds, callback) -> cancelCallback },
--     dailyQuestCatalogEntries: { DailyQuest },   -- normally DailyQuestCatalog.DAILY_QUESTS;
--         copied when `new` runs, so later edits of the caller's list change nothing. A catalog
--         that cannot fill a day raises here (DailyQuestOfTheDaySelector's rule).
--     sendPlayerSaveDataSnapshotToPlayer: (playerUserId: number, snapshotMessage) -> (),
--         sends to THAT player's device only. Receives a fresh table it may modify.
--     logger: { logInformation: (self, message: string) -> (), logWarning: (self, message: string) -> () },
--   }
--   A missing dependency, or a sender that is not a function, raises.
--
-- publisher:startPublishingPlayerSaveDataSnapshots()
--   Subscribes to both keepers and starts watching the UTC date. Call once, before any player's
--   save can load (a save that loaded earlier is not picked up). Calling it twice raises.
--
-- publisher:isPublishingToPlayer(playerUserId) -> boolean
--   True from the player's "save loaded" until their save session ends (see the session rule).
-- ════════════════════════════════════════════════════════════════════════════════════════════

local DailyQuestOfTheDaySelector = require("../shared/DailyQuestOfTheDaySelector")
local LoggedErrorTextShortener = require("./LoggedErrorTextShortener")
local PlayerSaveDataSchema = require("./PlayerSaveDataSchema")
local PlayerSaveDataSnapshotMessageBuilder = require("./PlayerSaveDataSnapshotMessageBuilder")
local UtcDailyDateKeyChangeWatcher = require("./UtcDailyDateKeyChangeWatcher")

local arePlainValuesDeeplyEqual = PlayerSaveDataSchema.arePlainValuesDeeplyEqual
local createDeepCopyOfPlainTable = PlayerSaveDataSchema.createDeepCopyOfPlainTable
local shortenErrorTextForLog = LoggedErrorTextShortener.shortenErrorTextForLog

local PlayerSaveDataSnapshotPublisher = {}
PlayerSaveDataSnapshotPublisher.__index = PlayerSaveDataSnapshotPublisher

PlayerSaveDataSnapshotPublisher.STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS = 1

-- What the publisher keeps for one player save session it publishes to.
type PublishedPlayerSession = {
	-- A private deep copy of the last message handed to the sender; nil = nothing counts as sent.
	lastSentSnapshotMessage: { [string]: any }?,
	-- True while a re-check of a message held back for the stored-outfit availability is scheduled.
	isAvailabilityRecheckPending: boolean,
	hasWarnedAboutStoredOutfitAvailability: boolean,
}

function PlayerSaveDataSnapshotPublisher.new(dependencies)
	for _, requiredDependencyName in
		{
			"playerSaveDataKeeper",
			"storedLobbyOutfitKeeper",
			"clock",
			"scheduler",
			"dailyQuestCatalogEntries",
			"sendPlayerSaveDataSnapshotToPlayer",
			"logger",
		}
	do
		if dependencies[requiredDependencyName] == nil then
			error("PlayerSaveDataSnapshotPublisher.new: missing dependency " .. requiredDependencyName, 2)
		end
	end
	if type(dependencies.sendPlayerSaveDataSnapshotToPlayer) ~= "function" then
		error("PlayerSaveDataSnapshotPublisher.new: sendPlayerSaveDataSnapshotToPlayer must be a function", 2)
	end
	local dailyQuestCatalogEntries = createDeepCopyOfPlainTable(dependencies.dailyQuestCatalogEntries)
	-- Fails at wiring time, not at the first player's load, if the catalog cannot fill a day.
	DailyQuestOfTheDaySelector.selectDailyQuestIdsForDailyDateKey(
		PlayerSaveDataSchema.formatUtcDailyDateKey(dependencies.clock:getCurrentUnixSeconds()),
		dailyQuestCatalogEntries
	)
	return setmetatable({
		playerSaveDataKeeper = dependencies.playerSaveDataKeeper,
		storedLobbyOutfitKeeper = dependencies.storedLobbyOutfitKeeper,
		clock = dependencies.clock,
		scheduler = dependencies.scheduler,
		dailyQuestCatalogEntries = dailyQuestCatalogEntries,
		sendPlayerSaveDataSnapshotToPlayer = dependencies.sendPlayerSaveDataSnapshotToPlayer,
		logger = dependencies.logger,
		utcDailyDateKeyChangeWatcher = UtcDailyDateKeyChangeWatcher.new({
			clock = dependencies.clock,
			scheduler = dependencies.scheduler,
			logger = dependencies.logger,
		}),
		hasStarted = false,
		publishedPlayerSessionByPlayerUserId = {} :: { [number]: PublishedPlayerSession },
	}, PlayerSaveDataSnapshotPublisher)
end

-- ── building ────────────────────────────────────────────────────────────────────────────────

-- The list as StoredLobbyOutfitKeeper reads it (ipairs; a non-table is the empty outfit).
local function listStylingItemKeysInStoredOrder(storedStylingItemKeys: any): { any }
	local stylingItemKeysInStoredOrder = {}
	if type(storedStylingItemKeys) ~= "table" then
		return stylingItemKeysInStoredOrder
	end
	for _, stylingItemKey in ipairs(storedStylingItemKeys) do
		table.insert(stylingItemKeysInStoredOrder, stylingItemKey)
	end
	return stylingItemKeysInStoredOrder
end

-- nil when the stored-outfit availability was worked out for the outfit the save now holds;
-- otherwise why not. Combining the two while they differ would show the device a state the
-- server never held.
local function describeWhyAvailabilityDoesNotDescribeSavedLobbyOutfit(
	storedLobbyOutfitAvailability: any,
	inMemorySaveData: any
): string?
	if type(storedLobbyOutfitAvailability) ~= "table" then
		return "missing"
	end
	local doesDescribeSavedLobbyOutfit = arePlainValuesDeeplyEqual(
		listStylingItemKeysInStoredOrder(storedLobbyOutfitAvailability.lobbyOutfitStylingItemKeys),
		listStylingItemKeysInStoredOrder(inMemorySaveData.lobbyOutfitStylingItemKeys)
	)
	return if doesDescribeSavedLobbyOutfit then nil else "for another lobby outfit"
end

-- Returns (snapshotMessage?, availabilityProblem?):
--   (nil, nil)        the player is leaving: send nothing;
--   (nil, problem)    the availability has not caught up and the fallback is not allowed yet;
--   (message, nil)    the consistent message;
--   (message, problem) the fallback message (no unavailable keys) after the wait.
local function buildSnapshotMessageFromCurrentServerState(
	self,
	playerUserId: number,
	isAvailabilityFallbackAllowed: boolean
): ({ [string]: any }?, string?)
	local inMemorySaveData = self.playerSaveDataKeeper:readPlayerSaveDataCopy(playerUserId)
	if inMemorySaveData == nil then
		return nil, nil
	end
	local storedLobbyOutfitAvailability = self.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(playerUserId)
	local availabilityProblem =
		describeWhyAvailabilityDoesNotDescribeSavedLobbyOutfit(storedLobbyOutfitAvailability, inMemorySaveData)
	if availabilityProblem ~= nil and not isAvailabilityFallbackAllowed then
		return nil, availabilityProblem
	end
	local todaysDailyQuestIds = DailyQuestOfTheDaySelector.selectDailyQuestIdsForDailyDateKey(
		PlayerSaveDataSchema.formatUtcDailyDateKey(self.clock:getCurrentUnixSeconds()),
		self.dailyQuestCatalogEntries
	)
	return PlayerSaveDataSnapshotMessageBuilder.buildPlayerSaveDataSnapshotMessage({
		inMemorySaveData = inMemorySaveData,
		unavailableLobbyOutfitStylingItemKeys = if availabilityProblem == nil
			then storedLobbyOutfitAvailability.unavailableLobbyOutfitStylingItemKeys
			else {},
		todaysDailyQuestIds = todaysDailyQuestIds,
		isSaveDataPersistenceDelayed = self.playerSaveDataKeeper:isSaveDataPersistenceDelayed(playerUserId) == true,
	}),
		availabilityProblem
end

-- ── sending ─────────────────────────────────────────────────────────────────────────────────

local sendSnapshotMessageIfChanged -- forward declaration

local function scheduleAvailabilityRecheckOnce(
	self,
	playerUserId: number,
	publishedPlayerSession: PublishedPlayerSession
)
	if publishedPlayerSession.isAvailabilityRecheckPending then
		return -- one re-check covers every message held back meanwhile (it builds from the state then)
	end
	publishedPlayerSession.isAvailabilityRecheckPending = true
	self.scheduler:scheduleCallbackAfterSeconds(
		PlayerSaveDataSnapshotPublisher.STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS,
		function()
			publishedPlayerSession.isAvailabilityRecheckPending = false
			if self.publishedPlayerSessionByPlayerUserId[playerUserId] ~= publishedPlayerSession then
				return -- that session was forgotten or replaced by a new load meanwhile
			end
			sendSnapshotMessageIfChanged(self, playerUserId, true)
		end
	)
end

local function warnOnceAboutStoredOutfitAvailability(
	self,
	playerUserId: number,
	publishedPlayerSession: PublishedPlayerSession,
	availabilityProblem: string
)
	if publishedPlayerSession.hasWarnedAboutStoredOutfitAvailability then
		return
	end
	publishedPlayerSession.hasWarnedAboutStoredOutfitAvailability = true
	self.logger:logWarning(
		string.format(
			"PlayerSaveDataSnapshotPublisher: the stored lobby outfit availability for player %d is %s after "
				.. "waiting %d s; sending snapshots with no unavailable keys",
			playerUserId,
			availabilityProblem,
			PlayerSaveDataSnapshotPublisher.STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS
		)
	)
end

function sendSnapshotMessageIfChanged(self, playerUserId: number, isAvailabilityFallbackAllowed: boolean)
	local publishedPlayerSession = self.publishedPlayerSessionByPlayerUserId[playerUserId]
	if publishedPlayerSession == nil then
		return -- not loaded yet as far as this publisher knows, or forgotten
	end
	local didBuild, snapshotMessageOrError, availabilityProblem =
		pcall(buildSnapshotMessageFromCurrentServerState, self, playerUserId, isAvailabilityFallbackAllowed)
	if not didBuild then
		self.logger:logWarning(
			string.format(
				"PlayerSaveDataSnapshotPublisher: building the snapshot for player %d failed: %s",
				playerUserId,
				shortenErrorTextForLog(snapshotMessageOrError)
			)
		)
		return
	end
	local snapshotMessage = snapshotMessageOrError
	if snapshotMessage == nil then
		if availabilityProblem ~= nil then
			scheduleAvailabilityRecheckOnce(self, playerUserId, publishedPlayerSession)
		end
		return
	end
	if availabilityProblem ~= nil then
		warnOnceAboutStoredOutfitAvailability(self, playerUserId, publishedPlayerSession, availabilityProblem)
	end
	local lastSentSnapshotMessage = publishedPlayerSession.lastSentSnapshotMessage
	if lastSentSnapshotMessage ~= nil and arePlainValuesDeeplyEqual(lastSentSnapshotMessage, snapshotMessage) then
		return -- §2.13: nothing changed for the device
	end
	-- Recorded before sending (from a private copy the sender cannot reach), so a change made
	-- while the sender runs is compared against this message, not an older one.
	publishedPlayerSession.lastSentSnapshotMessage = createDeepCopyOfPlainTable(snapshotMessage)
	local didSend, sendError = pcall(self.sendPlayerSaveDataSnapshotToPlayer, playerUserId, snapshotMessage)
	if not didSend then
		-- The device may not have it: never suppress the next message because of this one.
		publishedPlayerSession.lastSentSnapshotMessage = nil
		self.logger:logWarning(
			string.format(
				"PlayerSaveDataSnapshotPublisher: sending the snapshot to player %d failed: %s",
				playerUserId,
				shortenErrorTextForLog(sendError)
			)
		)
	end
end

local function sendSnapshotMessagesToEveryPlayerForNewUtcDate(self)
	-- A list taken first: a sender may load or end players while this loop runs.
	local publishedPlayerUserIds = {}
	for playerUserId in self.publishedPlayerSessionByPlayerUserId do
		table.insert(publishedPlayerUserIds, playerUserId)
	end
	table.sort(publishedPlayerUserIds)
	for _, playerUserId in publishedPlayerUserIds do
		sendSnapshotMessageIfChanged(self, playerUserId, false)
	end
end

-- ── public API ──────────────────────────────────────────────────────────────────────────────

function PlayerSaveDataSnapshotPublisher:startPublishingPlayerSaveDataSnapshots()
	if self.hasStarted then
		error("PlayerSaveDataSnapshotPublisher: startPublishingPlayerSaveDataSnapshots was already called", 2)
	end
	self.hasStarted = true
	local playerSaveDataKeeper = self.playerSaveDataKeeper
	playerSaveDataKeeper:subscribeToPlayerSaveDataLoaded(function(playerUserId)
		-- A new session starts from nothing: its device has been sent nothing yet.
		self.publishedPlayerSessionByPlayerUserId[playerUserId] = {
			lastSentSnapshotMessage = nil,
			isAvailabilityRecheckPending = false,
			hasWarnedAboutStoredOutfitAvailability = false,
		}
		sendSnapshotMessageIfChanged(self, playerUserId, false)
	end)
	playerSaveDataKeeper:subscribeToInMemorySaveDataChanged(function(playerUserId)
		sendSnapshotMessageIfChanged(self, playerUserId, false)
	end)
	playerSaveDataKeeper:subscribeToSaveDataPersistenceDelayedChanged(function(playerUserId)
		sendSnapshotMessageIfChanged(self, playerUserId, false)
	end)
	playerSaveDataKeeper:subscribeToPlayerSaveDataSessionEnded(function(playerUserId)
		-- The keeper names the player, not the session: the late end of an old session (its final
		-- save still retrying when the player rejoined) must not silence the new loaded session.
		if playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId) then
			return
		end
		self.publishedPlayerSessionByPlayerUserId[playerUserId] = nil
	end)
	self.storedLobbyOutfitKeeper:subscribeToStoredLobbyOutfitAvailabilityChanged(function(playerUserId)
		sendSnapshotMessageIfChanged(self, playerUserId, false)
	end)
	self.utcDailyDateKeyChangeWatcher:startWatchingUtcDailyDateKeyChanges(function()
		sendSnapshotMessagesToEveryPlayerForNewUtcDate(self)
	end)
end

function PlayerSaveDataSnapshotPublisher:isPublishingToPlayer(playerUserId: number): boolean
	return self.publishedPlayerSessionByPlayerUserId[playerUserId] ~= nil
end

return PlayerSaveDataSnapshotPublisher
