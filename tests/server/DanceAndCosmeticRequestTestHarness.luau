-- Builds the dance-shop request answerers on top of RewardLedgerCrashableServerTestHarness: a REAL
-- PlayerSaveDataKeeper, RewardLedger and PlayerRequestRateLimiter on a server that can crash,
-- fixture catalogs that record every id they are asked about, and a recording logger.
-- Not a spec file; the DanceAndCosmetic*.spec.luau files require it.

local DanceAndCosmeticEquipRequestAnswerer = require("../../src/server/DanceAndCosmeticEquipRequestAnswerer")
local DanceAndCosmeticPurchaseRequestAnswerer = require("../../src/server/DanceAndCosmeticPurchaseRequestAnswerer")
local DanceAndCosmeticShopTestCatalogs = require("../fixtures/DanceAndCosmeticShopTestCatalogs")
local PlayerRequestRateLimiter = require("../../src/server/PlayerRequestRateLimiter")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local RewardLedgerCrashableServerTestHarness = require("./RewardLedgerCrashableServerTestHarness")

local DanceAndCosmeticRequestTestHarness = {}

DanceAndCosmeticRequestTestHarness.PLAYER = RewardLedgerCrashableServerTestHarness.EXAMPLE_PLAYER_USER_ID
DanceAndCosmeticRequestTestHarness.OTHER_PLAYER = RewardLedgerCrashableServerTestHarness.OTHER_PLAYER_USER_ID

-- The shortest wait after which every dance-shop channel admits the player again (§2.13: 1 s).
DanceAndCosmeticRequestTestHarness.RATE_LIMIT_INTERVAL_SECONDS = 1

function DanceAndCosmeticRequestTestHarness.createRecordingLogger()
	local recordingLogger = { loggedInformation = {}, loggedWarnings = {} }
	function recordingLogger.logInformation(self, message: string)
		table.insert(self.loggedInformation, message)
	end
	function recordingLogger.logWarning(self, message: string)
		table.insert(self.loggedWarnings, message)
	end
	return recordingLogger
end

-- A limiter that admits everything and records every call as { playerUserId, remoteChannelName }.
function DanceAndCosmeticRequestTestHarness.createAdmitEverythingRateLimiter()
	local admitEverythingRateLimiter = { recordedCalls = {} }
	function admitEverythingRateLimiter.admitOrRefusePlayerRequest(self, playerUserId, remoteChannelName)
		table.insert(self.recordedCalls, { playerUserId = playerUserId, remoteChannelName = remoteChannelName })
		return { isRequestAllowed = true }
	end
	return admitEverythingRateLimiter
end

-- options = {
--   danceCatalog, cosmeticCatalog,   -- default: fresh fixture catalogs
--   playerRequestRateLimiter,        -- default: a REAL limiter on the harness clock
--   playerSaveDataKeeper,            -- default: the server's real keeper (a stand-in may wrap it)
-- }
local function buildAnswerersForServer(shopHarness, server, options)
	options = options or {}
	shopHarness.server = server
	shopHarness.playerSaveDataKeeper = options.playerSaveDataKeeper or server.playerSaveDataKeeper
	shopHarness.danceCatalog = options.danceCatalog or DanceAndCosmeticShopTestCatalogs.createDanceCatalog()
	shopHarness.cosmeticCatalog = options.cosmeticCatalog or DanceAndCosmeticShopTestCatalogs.createCosmeticCatalog()
	shopHarness.playerRequestRateLimiter = options.playerRequestRateLimiter
		or PlayerRequestRateLimiter.new({ clock = shopHarness.crashableHarness.fakeClock })
	shopHarness.shopLogger = DanceAndCosmeticRequestTestHarness.createRecordingLogger()
	shopHarness.purchaseRequestAnswerer = DanceAndCosmeticPurchaseRequestAnswerer.new({
		playerSaveDataKeeper = shopHarness.playerSaveDataKeeper,
		rewardLedger = server.rewardLedger,
		playerRequestRateLimiter = shopHarness.playerRequestRateLimiter,
		danceCatalog = shopHarness.danceCatalog,
		cosmeticCatalog = shopHarness.cosmeticCatalog,
		logger = shopHarness.shopLogger,
	})
	shopHarness.equipRequestAnswerer = DanceAndCosmeticEquipRequestAnswerer.new({
		playerSaveDataKeeper = shopHarness.playerSaveDataKeeper,
		playerRequestRateLimiter = shopHarness.playerRequestRateLimiter,
		danceCatalog = shopHarness.danceCatalog,
		cosmeticCatalog = shopHarness.cosmeticCatalog,
		logger = shopHarness.shopLogger,
	})
end

-- A loaded example player (adjusted by `adjustStartingSaveData`) on a running server, with both
-- answerers built. Storage holds every write in flight until the test finishes it.
function DanceAndCosmeticRequestTestHarness.createShopHarness(adjustStartingSaveData: ((any) -> ())?, options: any?)
	local crashableHarness, server =
		RewardLedgerCrashableServerTestHarness.createHarnessWithLoadedPlayer(adjustStartingSaveData)
	local shopHarness = { crashableHarness = crashableHarness }

	function shopHarness.rebuildAnswerersForCurrentServer(rebuildOptions: any?)
		buildAnswerersForServer(shopHarness, crashableHarness.currentServer, rebuildOptions)
	end

	-- Moves time past every dance-shop rate limit (runs due timers on the current server).
	function shopHarness.waitPastRateLimit()
		crashableHarness.advanceSeconds(DanceAndCosmeticRequestTestHarness.RATE_LIMIT_INTERVAL_SECONDS)
	end

	function shopHarness.readInMemorySaveData(playerUserId: number?)
		return shopHarness.server.playerSaveDataKeeper:readPlayerSaveDataCopy(
			playerUserId or DanceAndCosmeticRequestTestHarness.PLAYER
		)
	end

	function shopHarness.readSaveChangeRevisions(playerUserId: number?)
		return shopHarness.server.playerSaveDataKeeper:readSaveChangeRevisions(
			playerUserId or DanceAndCosmeticRequestTestHarness.PLAYER
		)
	end

	function shopHarness.countStartedStorageOperations(): number
		return crashableHarness.fakePlayerSaveDataStorage:countStartedOperations(
			DanceAndCosmeticRequestTestHarness.PLAYER
		)
	end

	-- Every in-memory change event the keeper raises from now on, as { playerUserId, saveDataCopy }.
	function shopHarness.recordInMemorySaveDataChangedEvents()
		local recordedEvents = {}
		shopHarness.server.playerSaveDataKeeper:subscribeToInMemorySaveDataChanged(
			function(playerUserId, inMemorySaveDataCopy)
				table.insert(recordedEvents, { playerUserId = playerUserId, saveDataCopy = inMemorySaveDataCopy })
			end
		)
		return recordedEvents
	end

	buildAnswerersForServer(shopHarness, server, options)
	return shopHarness
end

-- { catalog dependency name, the lookup function `new` requires it to carry }
DanceAndCosmeticRequestTestHarness.CATALOG_LOOKUP_FUNCTION_NAMES = table.freeze({
	{ "danceCatalog", "findDanceByDanceId" },
	{ "cosmeticCatalog", "findCosmeticByCosmeticId" },
})

-- Dependencies for `new` tests: an empty table per name, except catalogs that carry their lookup.
function DanceAndCosmeticRequestTestHarness.buildPlaceholderDependencies(requiredDependencyNames: { string })
	local placeholderDependencies = {}
	for _, dependencyName in requiredDependencyNames do
		placeholderDependencies[dependencyName] = {}
	end
	placeholderDependencies.danceCatalog = DanceAndCosmeticShopTestCatalogs.createDanceCatalog()
	placeholderDependencies.cosmeticCatalog = DanceAndCosmeticShopTestCatalogs.createCosmeticCatalog()
	return placeholderDependencies
end

-- Puts progress into every save field a dance-shop request must leave alone (everything except
-- starCoinBalance and the dance/cosmetic fields), so a change that wipes other progress is seen.
-- `randomNumberGenerator` (optional) varies the values; without it they are fixed.
function DanceAndCosmeticRequestTestHarness.giveProgressInEveryUnrelatedSaveField(randomNumberGenerator: any?)
	local function pickWholeNumber(smallestWholeNumber: number, largestWholeNumber: number): number
		if randomNumberGenerator == nil then
			return largestWholeNumber
		end
		return randomNumberGenerator.nextWholeNumberInRange(smallestWholeNumber, largestWholeNumber)
	end
	return function(saveData)
		saveData.fanCount = pickWholeNumber(1, 50_000)
		saveData.totalRoundsCompletedCount = pickWholeNumber(1, 900)
		saveData.bestStarCountByThemeId = { theme_seaside_picnic = pickWholeNumber(1, 5), theme_neon_night = 3 }
		saveData.lobbyOutfitStylingItemKeys = { "Accessory:" .. pickWholeNumber(1, 99_999), "Shirt:12345" }
		saveData.dailyProgress.playtimeSecondsToday = pickWholeNumber(1, 7200)
		saveData.dailyProgress.claimedPlaytimeMilestoneMinutes = { 5, 15 }
		saveData.dailyProgress.dailyQuestProgressCountByQuestId = { quest_complete_rounds = pickWholeNumber(1, 3) }
		saveData.dailyProgress.claimedDailyQuestIds = { "quest_complete_rounds" }
		saveData.redeemedPromoCodeIds = { "promo_fixture_code_" .. pickWholeNumber(1, 9) }
	end
end

-- Runs every given save adjustment in order (for createShopHarness).
function DanceAndCosmeticRequestTestHarness.combineSaveAdjustments(saveAdjustments: { (any) -> () })
	return function(saveData)
		for _, adjustSaveData in saveAdjustments do
			adjustSaveData(saveData)
		end
	end
end

-- A deep copy of `saveDataBefore` with `applyExpectedChange` applied: what the whole save must
-- equal after a request that should change only what `applyExpectedChange` changes.
function DanceAndCosmeticRequestTestHarness.buildExpectedSaveData(saveDataBefore, applyExpectedChange: (any) -> ())
	local expectedSaveData = PlayerSaveDataSchema.createDeepCopyOfPlainTable(saveDataBefore)
	applyExpectedChange(expectedSaveData)
	return expectedSaveData
end

-- Gives the example save a balance and leaves everything else as a new player's.
function DanceAndCosmeticRequestTestHarness.giveStarCoinBalance(starCoinBalanceToStore: number)
	return function(saveData)
		saveData.starCoinBalance = starCoinBalanceToStore
	end
end

return DanceAndCosmeticRequestTestHarness
