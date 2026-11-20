-- ServerGameModuleAssembly (development spec v1.3 §3.2 "ServerMain: wiring only"): constructs
-- every rule module of the game server with the dependencies it is given and connects the
-- modules to each other, in the construction and start order their headers require. It holds no
-- rule of its own. Everything that touches Roblox (time, delayed work, storage, Marketplace
-- lookups, sending to devices, removing a player, display names, the character presenter) comes
-- in as a dependency, so ServerMain passes the real Roblox implementations and the Lune tests pass
-- fakes and drive the whole server.
--
-- Order rules taken from the headers:
--   * RewardLedger gets DailyProgressTracker's round record writer; the tracker gets that ledger.
--   * ThemedRoundReferee is created before the round clock starts (it subscribes in `new`), and
--     the character director subscribes after the referee, so at Showcase the referee has scored.
--   * StoredLobbyOutfitKeeper, PlayerSaveDataSnapshotPublisher (before the tracker, see the
--     tracker's EVENT ORDER AT LOAD note), DailyProgressTracker and FanCountLeaderboardKeeper start
--     before any player's save can load, i.e. before ServerMain connects players.
--   * WardrobeCatalogChanged is subscribed before the resolver starts.
--   * The round clock starts last.
--
-- PUBLIC API
--   ServerGameModuleAssembly.assembleServerGameModules(serverDependencies) -> serverGameModules
--     serverDependencies = {
--       clock: { getCurrentUnixSeconds, getCurrentUnixMilliseconds },   one clock for everything
--       scheduler: { scheduleCallbackAfterSeconds },
--       logger: { logInformation, logWarning },
--       playerSaveDataStorage, fanCountLeaderboardStorage, marketplaceItemLookups,
--       randomNumberGenerator: { nextWholeNumberInRange },   called with a dot
--       generateUniqueId: () -> string,   session lock ids and round ids
--       removePlayerFromGameWithMessage: (playerUserId, playerFacingMessage) -> (),
--       lookUpPlayerDisplayNamesByUserId: (playerUserIds) -> { [number]: string },   may yield
--       readPlayerDisplayName: (playerUserId) -> string,
--       deviceMessageSenders = { sendRoundStateChangedToEveryDevice(message),
--         sendRoundStateChangedToPlayer(playerUserId, message),
--         sendRoundOutfitDraftAcknowledgedToPlayer(playerUserId, acknowledgement),   must not yield
--         sendRoundResultsPublishedToEveryDevice(message),
--         sendPlayerSaveDataSnapshotToPlayer(playerUserId, message),
--         sendWardrobeCatalogChangedToEveryDevice(message) },
--       characterAppearancePresenter: optional (CharacterAppearanceAndStageDirector's presenter);
--         without it no director is built (tests of the request wiring do not need one),
--       catalogs: optional overrides { stylingItems, themes, danceCatalog, cosmeticCatalog,
--         dailyQuestCatalogEntries, promoCodeEntries } (default: the shipped catalogs),
--       wrapPlayerRequestRateLimiter: optional (limiter) -> limiter, for tests that count calls,
--     }
--     serverGameModules = { stylingItemByStylingItemKey, playerRequestRateLimiter,
--       playerSaveDataKeeper, fanCountLeaderboardKeeper, rewardLedger, dailyProgressTracker,
--       marketplaceStylingItemResolver, storedLobbyOutfitKeeper, playerSaveDataSnapshotPublisher,
--       themedRoundClock, themedRoundReferee, danceAndCosmeticPurchaseRequestAnswerer,
--       danceAndCosmeticEquipRequestAnswerer, setLobbyOutfitRequestAnswerer, lobbyDanceCoordinator,
--       promoCodeRedeemer, deviceRequestChannelAnswerRouter, playerServerLifecycleSequences,
--       characterAppearanceAndStageDirector? }
--   ServerGameModuleAssembly.startServerGameModules(serverGameModules, serverDependencies)
--     Starts everything in the order above, ending with the round clock. Call once, before players
--     are connected.

local CharacterAppearanceAndStageDirector = require("./CharacterAppearanceAndStageDirector")
local DailyProgressTracker = require("./DailyProgressTracker")
local DanceAndCosmeticEquipRequestAnswerer = require("./DanceAndCosmeticEquipRequestAnswerer")
local DanceAndCosmeticPurchaseRequestAnswerer = require("./DanceAndCosmeticPurchaseRequestAnswerer")
local DeviceRequestChannelAnswerRouter = require("./DeviceRequestChannelAnswerRouter")
local FanCountLeaderboardKeeper = require("./FanCountLeaderboardKeeper")
local LobbyDanceCoordinator = require("./LobbyDanceCoordinator")
local MarketplaceStylingItemResolver = require("./MarketplaceStylingItemResolver")
local PlayerRequestRateLimiter = require("./PlayerRequestRateLimiter")
local PlayerSaveDataKeeper = require("./PlayerSaveDataKeeper")
local PlayerSaveDataSchema = require("./PlayerSaveDataSchema")
local PlayerSaveDataSnapshotPublisher = require("./PlayerSaveDataSnapshotPublisher")
local PlayerServerLifecycleSequences = require("./PlayerServerLifecycleSequences")
local PromoCodeCatalog = require("./PromoCodeCatalog")
local PromoCodeRedeemer = require("./PromoCodeRedeemer")
local RewardLedger = require("./RewardLedger")
local SetLobbyOutfitRequestAnswerer = require("./SetLobbyOutfitRequestAnswerer")
local StoredLobbyOutfitKeeper = require("./StoredLobbyOutfitKeeper")
local ThemedRoundClock = require("./ThemedRoundClock")
local ThemedRoundReferee = require("./ThemedRoundReferee")
local CosmeticCatalog = require("../shared/CosmeticCatalog")
local DailyQuestCatalog = require("../shared/DailyQuestCatalog")
local DanceCatalog = require("../shared/DanceCatalog")
local StylingItemLookup = require("../shared/StylingItemLookup")
local ThemeCatalog = require("../shared/ThemeCatalog")
local StylingItemPool = require("../shared/generated/StylingItemPool")

local ServerGameModuleAssembly = {}

local function readCatalogs(serverDependencies)
	local catalogOverrides = serverDependencies.catalogs or {}
	return {
		stylingItems = catalogOverrides.stylingItems or StylingItemPool.STYLING_ITEMS,
		themes = catalogOverrides.themes or ThemeCatalog.THEMES,
		danceCatalog = catalogOverrides.danceCatalog or DanceCatalog,
		cosmeticCatalog = catalogOverrides.cosmeticCatalog or CosmeticCatalog,
		dailyQuestCatalogEntries = catalogOverrides.dailyQuestCatalogEntries or DailyQuestCatalog.DAILY_QUESTS,
		promoCodeEntries = catalogOverrides.promoCodeEntries or PromoCodeCatalog.PROMO_CODES,
	}
end

local function buildSaveAndRewardModules(serverDependencies, catalogs, modules)
	local clock, scheduler, logger = serverDependencies.clock, serverDependencies.scheduler, serverDependencies.logger
	local starterDanceIds = catalogs.danceCatalog.listDanceIdsGrantedToNewPlayers()
	local limiter = PlayerRequestRateLimiter.new({ clock = clock })
	if serverDependencies.wrapPlayerRequestRateLimiter then
		limiter = serverDependencies.wrapPlayerRequestRateLimiter(limiter)
	end
	modules.playerRequestRateLimiter = limiter
	modules.playerSaveDataKeeper = PlayerSaveDataKeeper.new({
		playerSaveDataStorage = serverDependencies.playerSaveDataStorage,
		clock = clock,
		scheduler = scheduler,
		removePlayerFromGameWithMessage = serverDependencies.removePlayerFromGameWithMessage,
		logger = logger,
		generateUniqueSessionLockId = serverDependencies.generateUniqueId,
		buildStartingPlayerSaveDataForNewPlayer = function(currentUnixSeconds: number)
			return PlayerSaveDataSchema.createStartingPlayerSaveData(starterDanceIds, currentUnixSeconds)
		end,
	})
	modules.fanCountLeaderboardKeeper = FanCountLeaderboardKeeper.new({
		playerSaveDataKeeper = modules.playerSaveDataKeeper,
		fanCountLeaderboardStorage = serverDependencies.fanCountLeaderboardStorage,
		clock = clock,
		scheduler = scheduler,
		logger = logger,
		lookUpPlayerDisplayNamesByUserId = serverDependencies.lookUpPlayerDisplayNamesByUserId,
	})
	local dailyQuestProgressRoundRecordWriter = DailyProgressTracker.createDailyQuestProgressRoundRecordWriter({
		clock = clock,
		stylingItemByStylingItemKey = modules.stylingItemByStylingItemKey,
		dailyQuestCatalogEntries = catalogs.dailyQuestCatalogEntries,
		logger = logger,
	})
	modules.rewardLedger = RewardLedger.new({
		playerSaveDataKeeper = modules.playerSaveDataKeeper,
		logger = logger,
		themedRoundCompletionRecordWriters = { dailyQuestProgressRoundRecordWriter },
	})
	modules.dailyProgressTracker = DailyProgressTracker.new({
		playerSaveDataKeeper = modules.playerSaveDataKeeper,
		rewardLedger = modules.rewardLedger,
		playerRequestRateLimiter = limiter,
		clock = clock,
		scheduler = scheduler,
		logger = logger,
		dailyQuestCatalogEntries = catalogs.dailyQuestCatalogEntries,
	})
end

local function buildWardrobeAndSnapshotModules(serverDependencies, catalogs, modules)
	local logger = serverDependencies.logger
	modules.marketplaceStylingItemResolver = MarketplaceStylingItemResolver.new({
		stylingItems = catalogs.stylingItems,
		marketplaceItemLookups = serverDependencies.marketplaceItemLookups,
		scheduler = serverDependencies.scheduler,
		logger = logger,
	})
	modules.storedLobbyOutfitKeeper = StoredLobbyOutfitKeeper.new({
		playerSaveDataKeeper = modules.playerSaveDataKeeper,
		stylingItemByStylingItemKey = modules.stylingItemByStylingItemKey,
		marketplaceStylingItemResolver = modules.marketplaceStylingItemResolver,
		logger = logger,
	})
	modules.playerSaveDataSnapshotPublisher = PlayerSaveDataSnapshotPublisher.new({
		playerSaveDataKeeper = modules.playerSaveDataKeeper,
		storedLobbyOutfitKeeper = modules.storedLobbyOutfitKeeper,
		clock = serverDependencies.clock,
		scheduler = serverDependencies.scheduler,
		dailyQuestCatalogEntries = catalogs.dailyQuestCatalogEntries,
		sendPlayerSaveDataSnapshotToPlayer = serverDependencies.deviceMessageSenders.sendPlayerSaveDataSnapshotToPlayer,
		logger = logger,
	})
end

local function buildThemedRoundModules(serverDependencies, catalogs, modules)
	local senders = serverDependencies.deviceMessageSenders
	modules.themedRoundClock = ThemedRoundClock.new({
		themeCatalogThemes = catalogs.themes,
		clock = serverDependencies.clock,
		scheduler = serverDependencies.scheduler,
		randomNumberGenerator = serverDependencies.randomNumberGenerator,
		generateUniqueRoundId = serverDependencies.generateUniqueId,
		logger = serverDependencies.logger,
	})
	modules.themedRoundReferee = ThemedRoundReferee.new({
		clock = serverDependencies.clock,
		scheduler = serverDependencies.scheduler,
		themedRoundClock = modules.themedRoundClock,
		playerRequestRateLimiter = modules.playerRequestRateLimiter,
		rewardLedger = modules.rewardLedger,
		playerSaveDataKeeper = modules.playerSaveDataKeeper,
		marketplaceStylingItemResolver = modules.marketplaceStylingItemResolver,
		stylingItemByStylingItemKey = modules.stylingItemByStylingItemKey,
		findThemeByThemeId = function(themeId)
			for _, theme in catalogs.themes do
				if theme.themeId == themeId then
					return theme
				end
			end
			return nil
		end,
		sendRoundStateChangedToEveryDevice = senders.sendRoundStateChangedToEveryDevice,
		sendRoundResultsPublishedToEveryDevice = senders.sendRoundResultsPublishedToEveryDevice,
		sendRoundOutfitDraftAcknowledged = senders.sendRoundOutfitDraftAcknowledgedToPlayer,
		readPlayerDisplayName = serverDependencies.readPlayerDisplayName,
		logger = serverDependencies.logger,
	})
end

-- The two round questions the lobby modules ask, answered from the referee's own facts.
local function buildRoundQuestionsForLobbyModules(themedRoundReferee)
	local function readParticipantPhase(playerUserId: number): string?
		local roundFacts = themedRoundReferee:readCharacterSpawnRoundFacts(playerUserId)
		return if roundFacts.isParticipant then roundFacts.roundPhase else nil
	end
	return function(playerUserId: number): boolean
		local participantPhase = readParticipantPhase(playerUserId)
		return participantPhase == "Styling" or participantPhase == "Showcase"
	end, function(playerUserId: number): boolean
		return readParticipantPhase(playerUserId) == "Showcase"
	end
end

local function buildLobbyAndShopModules(serverDependencies, catalogs, modules)
	local logger, limiter, keeper =
		serverDependencies.logger, modules.playerRequestRateLimiter, modules.playerSaveDataKeeper
	local isPlayerStylingOrShowcaseParticipant, isPlayerOnThemedRoundStage =
		buildRoundQuestionsForLobbyModules(modules.themedRoundReferee)
	modules.danceAndCosmeticPurchaseRequestAnswerer = DanceAndCosmeticPurchaseRequestAnswerer.new({
		playerSaveDataKeeper = keeper,
		rewardLedger = modules.rewardLedger,
		playerRequestRateLimiter = limiter,
		danceCatalog = catalogs.danceCatalog,
		cosmeticCatalog = catalogs.cosmeticCatalog,
		logger = logger,
	})
	modules.danceAndCosmeticEquipRequestAnswerer = DanceAndCosmeticEquipRequestAnswerer.new({
		playerSaveDataKeeper = keeper,
		playerRequestRateLimiter = limiter,
		danceCatalog = catalogs.danceCatalog,
		cosmeticCatalog = catalogs.cosmeticCatalog,
		logger = logger,
	})
	modules.setLobbyOutfitRequestAnswerer = SetLobbyOutfitRequestAnswerer.new({
		playerSaveDataKeeper = keeper,
		playerRequestRateLimiter = limiter,
		marketplaceStylingItemResolver = modules.marketplaceStylingItemResolver,
		stylingItemByStylingItemKey = modules.stylingItemByStylingItemKey,
		isPlayerStylingOrShowcaseParticipant = isPlayerStylingOrShowcaseParticipant,
	})
	modules.lobbyDanceCoordinator = LobbyDanceCoordinator.new({
		playerSaveDataKeeper = keeper,
		playerRequestRateLimiter = limiter,
		danceCatalog = catalogs.danceCatalog,
		clock = serverDependencies.clock,
		isPlayerOnThemedRoundStage = isPlayerOnThemedRoundStage,
		logger = logger,
	})
	modules.promoCodeRedeemer = PromoCodeRedeemer.new({
		playerSaveDataKeeper = keeper,
		rewardLedger = modules.rewardLedger,
		playerRequestRateLimiter = limiter,
		clock = serverDependencies.clock,
		logger = logger,
		promoCodeEntries = catalogs.promoCodeEntries,
	})
end

local function buildWiringModules(serverDependencies, catalogs, modules)
	modules.deviceRequestChannelAnswerRouter = DeviceRequestChannelAnswerRouter.new({
		playerRequestRateLimiter = modules.playerRequestRateLimiter,
		themedRoundReferee = modules.themedRoundReferee,
		marketplaceStylingItemResolver = modules.marketplaceStylingItemResolver,
		fanCountLeaderboardKeeper = modules.fanCountLeaderboardKeeper,
		setLobbyOutfitRequestAnswerer = modules.setLobbyOutfitRequestAnswerer,
		danceAndCosmeticPurchaseRequestAnswerer = modules.danceAndCosmeticPurchaseRequestAnswerer,
		danceAndCosmeticEquipRequestAnswerer = modules.danceAndCosmeticEquipRequestAnswerer,
		lobbyDanceCoordinator = modules.lobbyDanceCoordinator,
		dailyProgressTracker = modules.dailyProgressTracker,
		promoCodeRedeemer = modules.promoCodeRedeemer,
		logger = serverDependencies.logger,
	})
	local forgetPlayerOnLeavingServerCallbacks = {}
	if serverDependencies.characterAppearancePresenter ~= nil then
		local director = CharacterAppearanceAndStageDirector.new({
			themedRoundClock = modules.themedRoundClock,
			themedRoundReferee = modules.themedRoundReferee,
			playerSaveDataKeeper = modules.playerSaveDataKeeper,
			storedLobbyOutfitKeeper = modules.storedLobbyOutfitKeeper,
			lobbyDanceCoordinator = modules.lobbyDanceCoordinator,
			characterAppearancePresenter = serverDependencies.characterAppearancePresenter,
			danceCatalog = catalogs.danceCatalog,
			cosmeticCatalog = catalogs.cosmeticCatalog,
			logger = serverDependencies.logger,
		})
		modules.characterAppearanceAndStageDirector = director
		table.insert(forgetPlayerOnLeavingServerCallbacks, function(playerUserId: number)
			director:forgetPlayer(playerUserId)
		end)
		local presenter = serverDependencies.characterAppearancePresenter
		if presenter.forgetPlayer then
			table.insert(forgetPlayerOnLeavingServerCallbacks, function(playerUserId: number)
				presenter:forgetPlayer(playerUserId)
			end)
		end
	end
	modules.playerServerLifecycleSequences = PlayerServerLifecycleSequences.new({
		playerSaveDataKeeper = modules.playerSaveDataKeeper,
		themedRoundReferee = modules.themedRoundReferee,
		themedRoundClock = modules.themedRoundClock,
		dailyProgressTracker = modules.dailyProgressTracker,
		lobbyDanceCoordinator = modules.lobbyDanceCoordinator,
		logger = serverDependencies.logger,
		sendRoundStateChangedToPlayer = serverDependencies.deviceMessageSenders.sendRoundStateChangedToPlayer,
		forgetPlayerOnLeavingServerCallbacks = forgetPlayerOnLeavingServerCallbacks,
	})
end

function ServerGameModuleAssembly.assembleServerGameModules(serverDependencies)
	local catalogs = readCatalogs(serverDependencies)
	local modules = {
		stylingItemByStylingItemKey = StylingItemLookup.buildStylingItemByStylingItemKey(catalogs.stylingItems),
	}
	buildSaveAndRewardModules(serverDependencies, catalogs, modules)
	buildWardrobeAndSnapshotModules(serverDependencies, catalogs, modules)
	buildThemedRoundModules(serverDependencies, catalogs, modules)
	buildLobbyAndShopModules(serverDependencies, catalogs, modules)
	buildWiringModules(serverDependencies, catalogs, modules)
	return modules
end

function ServerGameModuleAssembly.startServerGameModules(serverGameModules, serverDependencies)
	serverGameModules.storedLobbyOutfitKeeper:startLookingAfterStoredLobbyOutfits()
	serverGameModules.playerSaveDataSnapshotPublisher:startPublishingPlayerSaveDataSnapshots()
	serverGameModules.dailyProgressTracker:startTrackingDailyProgress()
	serverGameModules.fanCountLeaderboardKeeper:startSyncingAndRefreshingTopEntries()
	serverGameModules.marketplaceStylingItemResolver:subscribeToWardrobeCatalogChanged(
		serverDependencies.deviceMessageSenders.sendWardrobeCatalogChangedToEveryDevice
	)
	serverGameModules.marketplaceStylingItemResolver:startResolvingWardrobeCatalog()
	if serverGameModules.characterAppearanceAndStageDirector ~= nil then
		serverGameModules.characterAppearanceAndStageDirector:startDirectingCharacterAppearances()
	end
	serverGameModules.themedRoundClock:startRoundCycle()
end

return table.freeze(ServerGameModuleAssembly)
