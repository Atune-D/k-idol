-- Runs the REAL PlayerSaveDataKeeper, StoredLobbyOutfitKeeper and RewardLedger with
-- PlayerSaveDataSnapshotPublisher on fake storage, clock and scheduler and a fake catalog resolver,
-- and records every snapshot message the publisher sends. Not a spec file; the
-- PlayerSaveDataSnapshotPublisher spec files require it.
--
-- The clock starts at 2026-11-19 12:00:00 UTC, so the shared test daily quest catalog's pinned
-- choices for 2026-11-19 and 2026-11-20 apply. Storage completes every operation immediately
-- unless a test changes that.

local DailyQuestOfTheDaySelector = require("../../src/shared/DailyQuestOfTheDaySelector")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local FakeClock = require("../Support/FakeClock")
local FakeMarketplaceStylingItemResolver = require("../Support/FakeMarketplaceStylingItemResolver")
local FakePlayerSaveDataStorage = require("../Support/FakePlayerSaveDataStorage")
local FakeScheduler = require("../Support/FakeScheduler")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local PlayerSaveDataSnapshotPublisher = require("../../src/server/PlayerSaveDataSnapshotPublisher")
local RewardLedger = require("../../src/server/RewardLedger")
local RewardLedgerPhaseTwoTestCallers = require("./RewardLedgerPhaseTwoTestCallers")
local StoredLobbyOutfitKeeper = require("../../src/server/StoredLobbyOutfitKeeper")

local PlayerSaveDataSnapshotPublisherTestHarness = {}

PlayerSaveDataSnapshotPublisherTestHarness.SECONDS_PER_DAY = 86400
-- 2026-11-19 12:00:00 UTC.
PlayerSaveDataSnapshotPublisherTestHarness.STARTING_UNIX_SECONDS = 1_795_046_400 + 43_200
PlayerSaveDataSnapshotPublisherTestHarness.SECONDS_UNTIL_NEXT_UTC_MIDNIGHT = 43_200
PlayerSaveDataSnapshotPublisherTestHarness.PLAYER_USER_ID = 8801
PlayerSaveDataSnapshotPublisherTestHarness.OTHER_PLAYER_USER_ID = 8802
PlayerSaveDataSnapshotPublisherTestHarness.STARTER_DANCE_IDS = table.freeze({ "starter_wave", "starter_step" })

-- Pool keys used by the specs (tests/fixtures/FakeStylingItemPool.luau).
PlayerSaveDataSnapshotPublisherTestHarness.PINK_TOP_KEY = "asset_9000011"
PlayerSaveDataSnapshotPublisherTestHarness.BLACK_BOTTOM_KEY = "asset_9000021"
PlayerSaveDataSnapshotPublisherTestHarness.WHITE_SHOES_KEY = "bundle_9000041"
PlayerSaveDataSnapshotPublisherTestHarness.PINK_BAG_KEY = "asset_9000051"

PlayerSaveDataSnapshotPublisherTestHarness.TODAYS_QUEST_IDS =
	DailyQuestTestCatalog.PINNED_TEST_DAILY_QUEST_IDS_BY_DAILY_DATE_KEY["2026-11-19"]
PlayerSaveDataSnapshotPublisherTestHarness.TOMORROWS_QUEST_IDS =
	DailyQuestTestCatalog.PINNED_TEST_DAILY_QUEST_IDS_BY_DAILY_DATE_KEY["2026-11-20"]

export type SubscriptionOrder = "PublisherFirst" | "StoredLobbyOutfitKeeperFirst"

export type HarnessOptions = {
	subscriptionOrder: SubscriptionOrder?, -- default "PublisherFirst"
	isCatalogLeftNotReady: boolean?, -- default: the fixture catalog is published before any load
	-- Runs right before StoredLobbyOutfitKeeper subscribes (after the publisher when
	-- "PublisherFirst"), so a test can put its own save keeper listener between the two.
	subscribeBeforeStoredLobbyOutfitKeeperStarts: ((playerSaveDataKeeper: any, rewardLedger: any) -> ())?,
	-- StoredLobbyOutfitKeeper is created but never started (a wiring fault): it never reports
	-- any availability.
	isStoredLobbyOutfitKeeperLeftUnstarted: boolean?,
}

local function createRecordingLogger()
	local recordingLogger = { loggedInformation = {}, loggedWarnings = {} }
	function recordingLogger.logInformation(self, message: string)
		table.insert(self.loggedInformation, message)
	end
	function recordingLogger.logWarning(self, message: string)
		table.insert(self.loggedWarnings, message)
	end
	return recordingLogger
end

function PlayerSaveDataSnapshotPublisherTestHarness.createHarness(harnessOptions: HarnessOptions?)
	local options: HarnessOptions = harnessOptions or {}
	local fakeClock = FakeClock.new(PlayerSaveDataSnapshotPublisherTestHarness.STARTING_UNIX_SECONDS)
	local fakeScheduler = FakeScheduler.new(fakeClock)
	local fakePlayerSaveDataStorage = FakePlayerSaveDataStorage.new(fakeClock)
	fakePlayerSaveDataStorage:setCompletesOperationsImmediately(true)
	local keeperLogger = createRecordingLogger()
	local publisherLogger = createRecordingLogger()
	local nextSessionLockNumber = 0

	local playerSaveDataKeeper = PlayerSaveDataKeeper.new({
		playerSaveDataStorage = fakePlayerSaveDataStorage,
		clock = fakeClock,
		scheduler = fakeScheduler,
		removePlayerFromGameWithMessage = function() end,
		logger = keeperLogger,
		generateUniqueSessionLockId = function()
			nextSessionLockNumber += 1
			return "snapshot-test-lock-" .. tostring(nextSessionLockNumber)
		end,
		buildStartingPlayerSaveDataForNewPlayer = function(currentUnixSeconds: number)
			return PlayerSaveDataSchema.createStartingPlayerSaveData(
				PlayerSaveDataSnapshotPublisherTestHarness.STARTER_DANCE_IDS,
				currentUnixSeconds
			)
		end,
	})
	local fakeResolver = FakeMarketplaceStylingItemResolver.new()
	if not options.isCatalogLeftNotReady then
		fakeResolver:publishWardrobeCatalog(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
	end
	local storedLobbyOutfitKeeper = StoredLobbyOutfitKeeper.new({
		playerSaveDataKeeper = playerSaveDataKeeper,
		stylingItemByStylingItemKey = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
		marketplaceStylingItemResolver = fakeResolver,
		logger = createRecordingLogger(),
	})
	local rewardLedger =
		RewardLedger.new({ playerSaveDataKeeper = playerSaveDataKeeper, logger = createRecordingLogger() })

	local harness = {
		fakeClock = fakeClock,
		fakeScheduler = fakeScheduler,
		fakePlayerSaveDataStorage = fakePlayerSaveDataStorage,
		fakeResolver = fakeResolver,
		playerSaveDataKeeper = playerSaveDataKeeper,
		storedLobbyOutfitKeeper = storedLobbyOutfitKeeper,
		rewardLedger = rewardLedger,
		publisherLogger = publisherLogger,
		-- Every call of the sender, in order: { playerUserId, snapshotMessage }.
		sentSnapshotRecords = {},
		-- Players for whom the sender raises (after recording the call).
		senderRaisesForPlayerUserIdSet = {} :: { [number]: boolean },
		-- Called by the sender after recording, before raising; tests use it to modify the message.
		afterEverySend = nil :: ((number, any) -> ())?,
	}

	local function sendPlayerSaveDataSnapshotToPlayer(playerUserId: number, snapshotMessage)
		table.insert(harness.sentSnapshotRecords, { playerUserId = playerUserId, snapshotMessage = snapshotMessage })
		if harness.afterEverySend then
			harness.afterEverySend(playerUserId, snapshotMessage)
		end
		if harness.senderRaisesForPlayerUserIdSet[playerUserId] then
			error("fake sender failure for player " .. tostring(playerUserId))
		end
	end

	local publisher = PlayerSaveDataSnapshotPublisher.new({
		playerSaveDataKeeper = playerSaveDataKeeper,
		storedLobbyOutfitKeeper = storedLobbyOutfitKeeper,
		clock = fakeClock,
		scheduler = fakeScheduler,
		dailyQuestCatalogEntries = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS,
		sendPlayerSaveDataSnapshotToPlayer = sendPlayerSaveDataSnapshotToPlayer,
		logger = publisherLogger,
	})
	harness.publisher = publisher

	local function startStoredLobbyOutfitKeeper()
		if options.subscribeBeforeStoredLobbyOutfitKeeperStarts then
			options.subscribeBeforeStoredLobbyOutfitKeeperStarts(playerSaveDataKeeper, rewardLedger)
		end
		if not options.isStoredLobbyOutfitKeeperLeftUnstarted then
			storedLobbyOutfitKeeper:startLookingAfterStoredLobbyOutfits()
		end
	end
	if options.subscriptionOrder == "StoredLobbyOutfitKeeperFirst" then
		startStoredLobbyOutfitKeeper()
		publisher:startPublishingPlayerSaveDataSnapshots()
	else
		publisher:startPublishingPlayerSaveDataSnapshots()
		startStoredLobbyOutfitKeeper()
	end

	function harness.advanceSeconds(elapsedSeconds: number)
		fakeScheduler:advanceTimeAndRunDueCallbacks(elapsedSeconds)
	end

	-- Puts a save in storage (a starting save from two days ago, with `editStoredSaveData` applied)
	-- and loads it; storage completes the load at once.
	function harness.loadPlayer(playerUserId: number, editStoredSaveData: ((any) -> ())?)
		local storedSaveData = PlayerSaveDataSchema.createStartingPlayerSaveData(
			PlayerSaveDataSnapshotPublisherTestHarness.STARTER_DANCE_IDS,
			fakeClock:getCurrentUnixSeconds() - 2 * PlayerSaveDataSnapshotPublisherTestHarness.SECONDS_PER_DAY
		)
		storedSaveData.ownedCosmeticIds = { "cosmetic_sparkle_trail" }
		if editStoredSaveData then
			editStoredSaveData(storedSaveData)
		end
		fakePlayerSaveDataStorage:setStoredPlayerSaveData(playerUserId, storedSaveData)
		playerSaveDataKeeper:startLoadingPlayerSaveData(playerUserId)
		assert(playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId), "harness: the load should have succeeded")
	end

	function harness.loadPlayerWithStoredLobbyOutfit(playerUserId: number, storedLobbyOutfitStylingItemKeys: { string })
		harness.loadPlayer(playerUserId, function(storedSaveData)
			storedSaveData.lobbyOutfitStylingItemKeys = table.clone(storedLobbyOutfitStylingItemKeys)
		end)
	end

	function harness.listSnapshotMessagesSentTo(playerUserId: number): { any }
		local snapshotMessages = {}
		for _, sentSnapshotRecord in harness.sentSnapshotRecords do
			if sentSnapshotRecord.playerUserId == playerUserId then
				table.insert(snapshotMessages, sentSnapshotRecord.snapshotMessage)
			end
		end
		return snapshotMessages
	end

	function harness.countSnapshotMessagesSentTo(playerUserId: number): number
		return #harness.listSnapshotMessagesSentTo(playerUserId)
	end

	function harness.readLastSnapshotMessageSentTo(playerUserId: number): any
		local snapshotMessages = harness.listSnapshotMessagesSentTo(playerUserId)
		return snapshotMessages[#snapshotMessages]
	end

	-- The §2.6 message the test expects for the player's CURRENT in-memory save, written out
	-- field by field (independently of the publisher's builder).
	function harness.buildExpectedSnapshotMessage(
		playerUserId: number,
		expectedUnavailableLobbyOutfitStylingItemKeys: { string },
		expectedTodaysDailyQuestIds: { string }
	)
		local inMemorySaveData = playerSaveDataKeeper:readPlayerSaveDataCopy(playerUserId)
		assert(inMemorySaveData ~= nil, "harness: the player's save is not loaded")
		return {
			fanCount = inMemorySaveData.fanCount,
			starCoinBalance = inMemorySaveData.starCoinBalance,
			ownedDanceIds = inMemorySaveData.ownedDanceIds,
			equippedDanceId = inMemorySaveData.equippedDanceId,
			ownedCosmeticIds = inMemorySaveData.ownedCosmeticIds,
			equippedCosmeticIdByKind = inMemorySaveData.equippedCosmeticIdByKind,
			lobbyOutfitStylingItemKeys = inMemorySaveData.lobbyOutfitStylingItemKeys,
			unavailableLobbyOutfitStylingItemKeys = expectedUnavailableLobbyOutfitStylingItemKeys,
			dailyProgress = inMemorySaveData.dailyProgress,
			todaysDailyQuestIds = expectedTodaysDailyQuestIds,
			isSaveDataPersistenceDelayed = playerSaveDataKeeper:isSaveDataPersistenceDelayed(playerUserId),
		}
	end

	-- §1.5 / §2.6, worked out here from the fixture pool and the fake catalog's current state:
	-- stored keys that are in the pool and enabled but hidden by a READY catalog.
	function harness.computeExpectedUnavailableLobbyOutfitStylingItemKeys(lobbyOutfitStylingItemKeys: { string })
		local expectedUnavailableKeys = {}
		if not fakeResolver:isWardrobeCatalogReady() then
			return expectedUnavailableKeys
		end
		local availableStylingItemKeySet = fakeResolver:getAvailableStylingItemKeySet()
		for _, stylingItemKey in lobbyOutfitStylingItemKeys do
			local poolStylingItem = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY[stylingItemKey]
			if poolStylingItem and poolStylingItem.isEnabled and not availableStylingItemKeySet[stylingItemKey] then
				table.insert(expectedUnavailableKeys, stylingItemKey)
			end
		end
		return expectedUnavailableKeys
	end

	-- The message the player's device should show for the server's state right now.
	function harness.buildExpectedSnapshotMessageForCurrentServerState(playerUserId: number)
		local inMemorySaveData = playerSaveDataKeeper:readPlayerSaveDataCopy(playerUserId)
		assert(inMemorySaveData ~= nil, "harness: the player's save is not loaded")
		local todaysDailyDateKey = PlayerSaveDataSchema.formatUtcDailyDateKey(fakeClock:getCurrentUnixSeconds())
		-- Pinned (independently computed) choices where they exist; the accepted selector otherwise.
		local todaysQuestIds = DailyQuestTestCatalog.PINNED_TEST_DAILY_QUEST_IDS_BY_DAILY_DATE_KEY[todaysDailyDateKey]
			or DailyQuestOfTheDaySelector.selectDailyQuestIdsForDailyDateKey(
				todaysDailyDateKey,
				DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS
			)
		return harness.buildExpectedSnapshotMessage(
			playerUserId,
			harness.computeExpectedUnavailableLobbyOutfitStylingItemKeys(inMemorySaveData.lobbyOutfitStylingItemKeys),
			todaysQuestIds
		)
	end

	-- From now on, every message is compared, AT THE MOMENT IT IS SENT, with the server's state
	-- at that moment; each difference is recorded in the returned list (empty = all consistent).
	function harness.recordMessagesInconsistentWithServerStateAtSendTime(): { string }
		local inconsistencyDescriptions = {}
		harness.afterEverySend = function(playerUserId: number, snapshotMessage)
			local expectedSnapshotMessage = harness.buildExpectedSnapshotMessageForCurrentServerState(playerUserId)
			if not PlayerSaveDataSchema.arePlainValuesDeeplyEqual(snapshotMessage, expectedSnapshotMessage) then
				table.insert(
					inconsistencyDescriptions,
					string.format(
						"message %d to player %d differs from the server state",
						#harness.sentSnapshotRecords,
						playerUserId
					)
				)
			end
		end
		return inconsistencyDescriptions
	end

	-- ── changes made the way the real modules make them ──────────────────────────────────────

	function harness.redeemPromoCode(playerUserId: number, promoCodeId: string, starCoinReward: number)
		return RewardLedgerPhaseTwoTestCallers.redeemPromoCode(rewardLedger, playerUserId, promoCodeId, starCoinReward)
	end

	function harness.purchaseDance(playerUserId: number, danceId: string, starCoinPrice: number)
		return RewardLedgerPhaseTwoTestCallers.purchaseDance(rewardLedger, playerUserId, danceId, starCoinPrice)
	end

	function harness.grantThemedRoundReward(playerUserId: number, roundId: string, starCount: number)
		return rewardLedger:grantThemedRoundReward(playerUserId, {
			roundId = roundId,
			themeId = "y2k_pop",
			starCount = starCount,
			scoredOutfitStylingItemKeys = {},
		})
	end

	local function applyAppearanceChange(playerUserId: number, changeDescription: string, editDraft: (any) -> ())
		return playerSaveDataKeeper:applyChangeToPlayerSaveData(
			playerUserId,
			PlayerSaveDataKeeper.APPEARANCE_CHANGE_SAVED_LATER,
			changeDescription,
			function(saveDataDraft)
				editDraft(saveDataDraft)
				return true
			end
		)
	end

	function harness.equipDance(playerUserId: number, danceId: string)
		return applyAppearanceChange(playerUserId, "test equip dance", function(saveDataDraft)
			saveDataDraft.equippedDanceId = danceId
		end)
	end

	function harness.equipCosmetic(playerUserId: number, cosmeticKind: string, cosmeticId: string)
		return applyAppearanceChange(playerUserId, "test equip cosmetic", function(saveDataDraft)
			saveDataDraft.equippedCosmeticIdByKind[cosmeticKind] = cosmeticId
		end)
	end

	function harness.setLobbyOutfit(playerUserId: number, lobbyOutfitStylingItemKeys: { string })
		return applyAppearanceChange(playerUserId, "test set lobby outfit", function(saveDataDraft)
			saveDataDraft.lobbyOutfitStylingItemKeys = table.clone(lobbyOutfitStylingItemKeys)
		end)
	end

	-- A progress change whose save, and every retry of it, fails: afterwards the keeper reports
	-- the player's persistence as delayed. Returns after the last retry failed.
	function harness.failEverySaveUntilPersistenceDelayed(playerUserId: number)
		local retryDelaysSeconds = PlayerSaveDataKeeper.FAILED_SAVE_RETRY_DELAYS_SECONDS
		fakePlayerSaveDataStorage:failNextStartedOperations(1 + #retryDelaysSeconds)
		harness.redeemPromoCode(playerUserId, "delayed_save_code_" .. tostring(fakeClock:getCurrentUnixSeconds()), 5)
		harness.advanceSeconds(PlayerSaveDataKeeper.MINIMUM_SECONDS_BETWEEN_SAVE_STARTS)
		for _, retryDelaySeconds in retryDelaysSeconds do
			harness.advanceSeconds(retryDelaySeconds)
		end
		assert(
			playerSaveDataKeeper:isSaveDataPersistenceDelayed(playerUserId),
			"harness: persistence should be delayed"
		)
	end

	-- Lets the next periodic save run and succeed; afterwards persistence is no longer delayed.
	function harness.letNextPeriodicSaveSucceed(playerUserId: number)
		harness.advanceSeconds(PlayerSaveDataKeeper.PERIODIC_SAVE_INTERVAL_SECONDS)
		assert(
			not playerSaveDataKeeper:isSaveDataPersistenceDelayed(playerUserId),
			"harness: persistence should no longer be delayed"
		)
	end

	-- Every "session ended" event, in order: { playerUserId, sessionEndReason }.
	harness.endedSessionRecords = {}
	playerSaveDataKeeper:subscribeToPlayerSaveDataSessionEnded(function(playerUserId, sessionEndReason)
		table.insert(harness.endedSessionRecords, { playerUserId = playerUserId, sessionEndReason = sessionEndReason })
	end)

	-- Makes the fake catalog resolver raise from now on whenever StoredLobbyOutfitKeeper asks
	-- whether the catalog is ready (the outfit keeper then fails inside its own listeners).
	function harness.makeCatalogReadinessQueriesRaise()
		fakeResolver.isWardrobeCatalogReady = function()
			error("fake resolver failure")
		end
	end

	function harness.makeCatalogReadinessQueriesWorkAgain()
		fakeResolver.isWardrobeCatalogReady = nil
	end

	function harness.leaveAndFinishFinalSave(playerUserId: number)
		playerSaveDataKeeper:startFinalSaveForLeavingPlayer(playerUserId)
		assert(not playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId), "harness: the player should be leaving")
	end

	return harness
end

return PlayerSaveDataSnapshotPublisherTestHarness
