-- Runs the REAL PromoCodeRedeemer with a real PlayerRequestRateLimiter, PlayerSaveDataKeeper and
-- RewardLedger on a server that can crash (RewardLedgerCrashableServerTestHarness), and watches
-- every dependency the redeemer is given, so tests can prove what it did and did NOT look at.
-- Not a spec file; the PromoCodeRedeemer spec files require it.
--
-- What is watched (all counts start at 0 for each new server):
--   promoCodeEntryFieldReadCount   reads of any field of any catalog entry, through counting
--                                  proxies (so "the catalog was not consulted" is observable)
--   clockSecondsReadCount          redeemer reads of clock:getCurrentUnixSeconds
--   saveDataLoadedQuestionCount    redeemer calls of keeper:isPlayerSaveDataLoaded
--   rewardLedgerGrantCallCount     redeemer calls of rewardLedger:grantStarCoinsAndFans
--   rateLimiterQuestionCount       redeemer calls of limiter:admitOrRefusePlayerRequest
--   redeemerLogLines               every line the redeemer logged, as "information: ..." / "warning: ..."

local PlayerRequestRateLimiter = require("../../src/server/PlayerRequestRateLimiter")
local PromoCodeFixtures = require("../fixtures/PromoCodeFixtures")
local PromoCodeRedeemer = require("../../src/server/PromoCodeRedeemer")
local RewardLedgerCrashableServerTestHarness = require("./RewardLedgerCrashableServerTestHarness")

local PromoCodeRedeemerTestHarness = {}

PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID = RewardLedgerCrashableServerTestHarness.EXAMPLE_PLAYER_USER_ID
PromoCodeRedeemerTestHarness.OTHER_PLAYER_USER_ID = RewardLedgerCrashableServerTestHarness.OTHER_PLAYER_USER_ID

-- The fixture catalog: "StageDebut" (fixture_stage_debut, 300 Star Coins) active during
-- [FIXTURE_WINDOW_START_UNIX_SECONDS, FIXTURE_WINDOW_END_UNIX_SECONDS), and "ENCORE-2030"
-- (fixture_encore_week, 50 Star Coins) active only from 1900000000.
PromoCodeRedeemerTestHarness.STAGE_DEBUT_PROMO_CODE_ID = "fixture_stage_debut"
PromoCodeRedeemerTestHarness.STAGE_DEBUT_STAR_COIN_REWARD = 300
PromoCodeRedeemerTestHarness.ENCORE_WEEK_PROMO_CODE_ID = "fixture_encore_week"
PromoCodeRedeemerTestHarness.WINDOW_START_UNIX_SECONDS = PromoCodeFixtures.FIXTURE_WINDOW_START_UNIX_SECONDS
PromoCodeRedeemerTestHarness.WINDOW_END_UNIX_SECONDS = PromoCodeFixtures.FIXTURE_WINDOW_END_UNIX_SECONDS
-- An hour into the StageDebut window: the default moment of the first request.
PromoCodeRedeemerTestHarness.INSIDE_WINDOW_UNIX_SECONDS = PromoCodeFixtures.FIXTURE_WINDOW_START_UNIX_SECONDS + 3600

-- The starting balance of the player's existing save in every harness.
PromoCodeRedeemerTestHarness.STARTING_STAR_COIN_BALANCE = 350

-- Wraps each entry in a frozen proxy that counts every field read. The returned list itself is
-- an ordinary list the caller may still change.
local function createCountingPromoCodeEntries(promoCodeEntries, onEntryFieldRead: () -> ())
	local countingPromoCodeEntries = {}
	for _, promoCodeEntry in promoCodeEntries do
		local frozenPromoCodeEntry = table.freeze(table.clone(promoCodeEntry))
		local countingProxy = setmetatable({}, {
			__index = function(_, entryFieldName)
				onEntryFieldRead()
				return frozenPromoCodeEntry[entryFieldName]
			end,
		})
		table.insert(countingPromoCodeEntries, table.freeze(countingProxy))
	end
	return countingPromoCodeEntries
end

-- options = {
--   requestAtUnixSeconds: number?   -- the clock reads this once the player is loaded (default:
--                                      INSIDE_WINDOW_UNIX_SECONDS); loading happens 20 s earlier
--   promoCodeEntries: { PromoCode }? -- default: the fixture catalog
--   isPlayerLoaded: boolean?         -- default true
-- }
function PromoCodeRedeemerTestHarness.createHarness(options: { [string]: any }?)
	local harnessOptions = options or {}
	local crashableHarness = RewardLedgerCrashableServerTestHarness.createHarness()
	local fakeClock = crashableHarness.fakeClock
	local requestAtUnixSeconds = harnessOptions.requestAtUnixSeconds
		or PromoCodeRedeemerTestHarness.INSIDE_WINDOW_UNIX_SECONDS
	fakeClock:advanceBySeconds(requestAtUnixSeconds - 20 - fakeClock:getCurrentUnixSeconds())

	local harness = {
		crashableHarness = crashableHarness,
		fakeClock = fakeClock,
		fakePlayerSaveDataStorage = crashableHarness.fakePlayerSaveDataStorage,
		uncountedPromoCodeEntries = harnessOptions.promoCodeEntries
			or PromoCodeFixtures.createFixturePromoCodeCatalog(),
	}

	-- Builds a limiter and redeemer for the server now running, with fresh counters.
	local function attachRedeemerToCurrentServer()
		local server = crashableHarness.currentServer
		local observations = {
			promoCodeEntryFieldReadCount = 0,
			clockSecondsReadCount = 0,
			saveDataLoadedQuestionCount = 0,
			rewardLedgerGrantCallCount = 0,
			rateLimiterQuestionCount = 0,
			redeemerLogLines = {},
		}
		local playerRequestRateLimiter = PlayerRequestRateLimiter.new({ clock = fakeClock })
		local countingPromoCodeEntries = createCountingPromoCodeEntries(harness.uncountedPromoCodeEntries, function()
			observations.promoCodeEntryFieldReadCount += 1
		end)
		local redeemer = PromoCodeRedeemer.new({
			playerSaveDataKeeper = {
				isPlayerSaveDataLoaded = function(_, playerUserId)
					observations.saveDataLoadedQuestionCount += 1
					return server.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId)
				end,
			},
			rewardLedger = {
				grantStarCoinsAndFans = function(_, playerUserId, starCoinAndFanGrantRequest)
					observations.rewardLedgerGrantCallCount += 1
					return server.rewardLedger:grantStarCoinsAndFans(playerUserId, starCoinAndFanGrantRequest)
				end,
			},
			playerRequestRateLimiter = {
				admitOrRefusePlayerRequest = function(_, playerUserId, remoteChannelName)
					observations.rateLimiterQuestionCount += 1
					return playerRequestRateLimiter:admitOrRefusePlayerRequest(playerUserId, remoteChannelName)
				end,
			},
			clock = {
				getCurrentUnixSeconds = function()
					observations.clockSecondsReadCount += 1
					return fakeClock:getCurrentUnixSeconds()
				end,
			},
			logger = {
				logInformation = function(_, message: string)
					table.insert(observations.redeemerLogLines, "information: " .. message)
				end,
				logWarning = function(_, message: string)
					table.insert(observations.redeemerLogLines, "warning: " .. message)
				end,
			},
			promoCodeEntries = countingPromoCodeEntries,
		})
		-- Construction checks the catalog; only requests are counted.
		observations.promoCodeEntryFieldReadCount = 0
		harness.server = server
		harness.playerRequestRateLimiter = playerRequestRateLimiter
		harness.redeemer = redeemer
		harness.observations = observations
	end

	function harness.redeem(untrustedPromoCodeText: any, playerUserId: number?)
		return harness.redeemer:redeemPromoCodeAndAnswerRequest(
			playerUserId or PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID,
			untrustedPromoCodeText
		)
	end

	-- Moves time on the running server, running its due timers (saves, retries).
	function harness.advanceSeconds(elapsedSeconds: number)
		crashableHarness.advanceSeconds(elapsedSeconds)
	end

	-- Moves past the 2 s attempt interval.
	function harness.waitOutAttemptInterval()
		crashableHarness.advanceSeconds(
			PlayerRequestRateLimiter.MINIMUM_REQUEST_INTERVAL_SECONDS_BY_REMOTE_CHANNEL_NAME.RequestRedeemPromoCode
		)
	end

	function harness.readInMemorySaveData()
		return crashableHarness.readInMemorySaveData(PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID)
	end

	function harness.readStoredSaveData()
		return crashableHarness.readStoredSaveData(PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID)
	end

	function harness.readInMemoryChangeRevision(): number?
		return (
			harness.server.playerSaveDataKeeper:readSaveChangeRevisions(
				PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID
			)
		)
	end

	-- Lets every save the storage holds in flight succeed (including saves they cause at once).
	function harness.completeEveryPendingSave()
		while harness.fakePlayerSaveDataStorage:countPendingOperations() > 0 do
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation()
		end
	end

	-- The player leaves (final save succeeds) and joins this same server again.
	function harness.leaveAndRejoinSameServer()
		local playerSaveDataKeeper = harness.server.playerSaveDataKeeper
		playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID)
		harness.completeEveryPendingSave()
		harness.playerRequestRateLimiter:forgetPlayer(PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID)
		playerSaveDataKeeper:startLoadingPlayerSaveData(PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID)
		harness.completeEveryPendingSave()
		assert(
			playerSaveDataKeeper:isPlayerSaveDataLoaded(PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID),
			"rejoin failed"
		)
		harness.advanceSeconds(20)
	end

	-- The server crashes; a new server (new keeper, ledger, limiter, redeemer) loads the player.
	function harness.crashAndLoadPlayerOnNewServer(inFlightWriteFate: string)
		crashableHarness.crashCurrentServer(inFlightWriteFate)
		crashableHarness.startServerAndLoadPlayer(PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID)
		attachRedeemerToCurrentServer()
		harness.advanceSeconds(20)
	end

	-- The player leaves with a successful final save; then the player joins a different server.
	function harness.leaveAndJoinNewServer()
		harness.server.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(
			PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID
		)
		harness.completeEveryPendingSave()
		assert(harness.readStoredSaveData().gameServerSessionLock == nil, "the final save should hand the lock back")
		harness.crashAndLoadPlayerOnNewServer("InFlightWritesLost")
	end

	crashableHarness.storeExistingPlayerSaveData(PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID, function(saveData)
		saveData.starCoinBalance = PromoCodeRedeemerTestHarness.STARTING_STAR_COIN_BALANCE
	end)
	if harnessOptions.isPlayerLoaded == false then
		crashableHarness.startNewServer()
	else
		crashableHarness.startServerAndLoadPlayer(PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID)
	end
	attachRedeemerToCurrentServer()
	crashableHarness.advanceSeconds(20)
	return harness
end

-- Counts how often `promoCodeId` appears in a save's redeemedPromoCodeIds.
function PromoCodeRedeemerTestHarness.countRedemptionRecords(saveData, promoCodeId: string): number
	local redemptionRecordCount = 0
	for _, redeemedPromoCodeId in saveData.redeemedPromoCodeIds do
		if redeemedPromoCodeId == promoCodeId then
			redemptionRecordCount += 1
		end
	end
	return redemptionRecordCount
end

return PromoCodeRedeemerTestHarness
