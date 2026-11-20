-- Builds a ThemedRoundReferee wired to the REAL ThemedRoundClock, PlayerRequestRateLimiter,
-- PlayerSaveDataKeeper (on FakePlayerSaveDataStorage that completes every operation at once),
-- RewardLedger and RoundOutfitDraftKeeper, all on one FakeClock and FakeScheduler, with the fake
-- styling item pool, a fake wardrobe catalog resolver and recording senders. Not a spec file.
-- The round-time actions and reads (advanceToRoundSecond, joinAtRoundSecond, sendDraftAtRoundSecond,
-- listAcknowledgementsSentTo, ...) live in ThemedRoundRefereeHarnessRoundActions.
--
-- Time is "round time": T = seconds since round 1's ThemeReveal began. The clock starts at T = 0,
-- so ThemeReveal 0-10, Styling 10-190, Showcase 190-250, Results 250-270, Intermission 270-280,
-- round 2 begins at 280. Round ids are "round-1", "round-2", …
-- The clock's random choices always take the first option, so round 1 is y2k_pop with the pink
-- ColorBonus: the spec §0.2 worked example outfit (E83) scores 83 and 4 stars in round 1.
--
-- Options (all optional):
--   rewardLedger              replaces the real ledger (for example ScriptableFakeThemedRoundRewardLedger)
--   ownerDecisions            passed to the referee
--   isWardrobeCatalogNotReadyAtStart   the resolver starts not ready (publish it later)
--   readPlayerDisplayName     replaces "Player <id>"
--   findThemeByThemeId        replaces ThemeCatalog.findThemeByThemeId
--   doNotStartRoundClock      build everything but do not start the clock
--   onRoundOutfitDraftAcknowledged(playerUserId, acknowledgement)   called after each recorded
--                             acknowledgement (randomized tests read the keeper's state there)

local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local FakePlayerSaveDataStorage = require("../Support/FakePlayerSaveDataStorage")
local FakeMarketplaceStylingItemResolver = require("../Support/FakeMarketplaceStylingItemResolver")
local CountingOutfitValidator = require("../Support/CountingOutfitValidator")
local RecordingLogger = require("../Support/RecordingLogger")
local RecordingRoundOutfitDraftAcknowledgementSender =
	require("../Support/RecordingRoundOutfitDraftAcknowledgementSender")
local RoundOutfitDraftTestMessages = require("../Support/RoundOutfitDraftTestMessages")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local RoundOutfitDraftKeeperTestHarness = require("./RoundOutfitDraftKeeperTestHarness")
local ThemedRoundRefereeHarnessRoundActions = require("./ThemedRoundRefereeHarnessRoundActions")
local PlayerRequestRateLimiter = require("../../src/server/PlayerRequestRateLimiter")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local RewardLedger = require("../../src/server/RewardLedger")
local RoundOutfitDraftKeeper = require("../../src/server/RoundOutfitDraftKeeper")
local ThemeCatalog = require("../../src/shared/ThemeCatalog")
local ThemedRoundClock = require("../../src/server/ThemedRoundClock")
local ThemedRoundReferee = require("../../src/server/ThemedRoundReferee")

local ThemedRoundRefereeTestHarness = {}

ThemedRoundRefereeTestHarness.ROUND_START_UNIX_SECONDS = ThemedRoundRefereeHarnessRoundActions.ROUND_START_UNIX_SECONDS
ThemedRoundRefereeTestHarness.STARTER_DANCE_IDS = ThemedRoundRefereeHarnessRoundActions.STARTER_DANCE_IDS
ThemedRoundRefereeTestHarness.createStoredSaveWithExampleHistory =
	ThemedRoundRefereeHarnessRoundActions.createStoredSaveWithExampleHistory

ThemedRoundRefereeTestHarness.PLAYER_P = RoundOutfitDraftKeeperTestHarness.PLAYER_P
ThemedRoundRefereeTestHarness.PLAYER_Q = RoundOutfitDraftKeeperTestHarness.PLAYER_Q
ThemedRoundRefereeTestHarness.PLAYER_R = RoundOutfitDraftKeeperTestHarness.PLAYER_R
ThemedRoundRefereeTestHarness.PLAYER_S = RoundOutfitDraftKeeperTestHarness.PLAYER_S

ThemedRoundRefereeTestHarness.OUTFIT_A = RoundOutfitDraftKeeperTestHarness.OUTFIT_A
ThemedRoundRefereeTestHarness.OUTFIT_B = RoundOutfitDraftKeeperTestHarness.OUTFIT_B
ThemedRoundRefereeTestHarness.OUTFIT_C = RoundOutfitDraftKeeperTestHarness.OUTFIT_C
ThemedRoundRefereeTestHarness.OUTFIT_D = RoundOutfitDraftKeeperTestHarness.OUTFIT_D
ThemedRoundRefereeTestHarness.INVALID_OUTFIT_X = RoundOutfitDraftKeeperTestHarness.INVALID_OUTFIT_X
ThemedRoundRefereeTestHarness.WORKED_EXAMPLE_OUTFIT_E83 = FakeStylingItemPool.WORKED_EXAMPLE_STYLING_ITEM_KEYS

local ROUND_START_UNIX_MILLISECONDS = ThemedRoundRefereeTestHarness.ROUND_START_UNIX_SECONDS * 1000

-- Wraps a ledger so every grantThemedRoundReward call is recorded, whatever it then does.
local function createRecordingLedgerProxy(wrappedRewardLedger, recordedGrantCalls)
	return {
		grantThemedRoundReward = function(_, playerUserId: number, themedRoundCompletion)
			table.insert(
				recordedGrantCalls,
				{ playerUserId = playerUserId, themedRoundCompletion = themedRoundCompletion }
			)
			return wrappedRewardLedger:grantThemedRoundReward(playerUserId, themedRoundCompletion)
		end,
	}
end

-- Wraps each draft keeper so the test sees every draft that reaches it.
local function createCountingDraftKeeperFactory(draftsReachingKeeperRecords, createdDraftKeepers)
	return function(keeperDependencies)
		local realDraftKeeper = RoundOutfitDraftKeeper.new(keeperDependencies)
		table.insert(createdDraftKeepers, realDraftKeeper)
		return setmetatable({}, {
			__index = function(_, methodName: string)
				return function(_, ...)
					if methodName == "receiveOutfitDraftFromDevice" then
						table.insert(draftsReachingKeeperRecords, { playerUserId = (...) })
					end
					return realDraftKeeper[methodName](realDraftKeeper, ...)
				end
			end,
		})
	end
end

-- The real save keeper on fake storage that completes every operation at once.
local function addPlayerSaveDataKeeperOnFakeStorage(harness)
	local fakePlayerSaveDataStorage = FakePlayerSaveDataStorage.new(harness.fakeClock)
	fakePlayerSaveDataStorage:setCompletesOperationsImmediately(true)
	local removedFromGamePlayerUserIds = {}
	local nextSessionLockNumber = 0
	harness.fakePlayerSaveDataStorage = fakePlayerSaveDataStorage
	harness.removedFromGamePlayerUserIds = removedFromGamePlayerUserIds
	harness.playerSaveDataKeeper = PlayerSaveDataKeeper.new({
		playerSaveDataStorage = fakePlayerSaveDataStorage,
		clock = harness.fakeClock,
		scheduler = harness.fakeScheduler,
		removePlayerFromGameWithMessage = function(playerUserId: number)
			table.insert(removedFromGamePlayerUserIds, playerUserId)
		end,
		logger = RecordingLogger.new(),
		generateUniqueSessionLockId = function()
			nextSessionLockNumber += 1
			return "referee-test-server-lock-" .. tostring(nextSessionLockNumber)
		end,
		buildStartingPlayerSaveDataForNewPlayer = function(currentUnixSeconds: number)
			return PlayerSaveDataSchema.createStartingPlayerSaveData(
				ThemedRoundRefereeTestHarness.STARTER_DANCE_IDS,
				currentUnixSeconds
			)
		end,
	})
end

-- The real round clock, always taking the first random option, with "round-N" ids; and the proxy
-- the referee sees, which remembers the referee's phase listener so a test can deliver a phase
-- change a second time.
local function addThemedRoundClockAndRefereeFacingProxy(harness)
	local generatedRoundCount = 0
	local themedRoundClock = ThemedRoundClock.new({
		themeCatalogThemes = ThemeCatalog.THEMES,
		clock = harness.fakeClock,
		scheduler = harness.fakeScheduler,
		randomNumberGenerator = {
			nextWholeNumberInRange = function(smallestWholeNumber: number)
				return smallestWholeNumber
			end,
		},
		generateUniqueRoundId = function()
			generatedRoundCount += 1
			return "round-" .. tostring(generatedRoundCount)
		end,
		logger = RecordingLogger.new(),
	})
	local refereePhaseChangeListeners = {}
	harness.themedRoundClock = themedRoundClock
	harness.refereePhaseChangeListeners = refereePhaseChangeListeners
	harness.refereeFacingRoundClock = setmetatable({
		subscribeToRoundPhaseChanged = function(_, listener)
			table.insert(refereePhaseChangeListeners, listener)
			return themedRoundClock:subscribeToRoundPhaseChanged(listener)
		end,
	}, {
		__index = function(_, methodName: string)
			return function(_, ...)
				return themedRoundClock[methodName](themedRoundClock, ...)
			end
		end,
	})
end

-- The three device senders: each records, in order, and the two broadcasts raise on request.
local function buildRecordingDeviceSenders(harness, chosenHarnessOptions)
	local function recordBroadcast(sentMessageKind: string, sentRecords, messageFieldName: string, sentMessage)
		table.insert(harness.orderedSentMessageLog, { sentMessageKind = sentMessageKind })
		table.insert(sentRecords, {
			roundMilliseconds = harness.readCurrentRoundMilliseconds(),
			[messageFieldName] = sentMessage,
		})
	end
	return {
		sendRoundStateChangedToEveryDevice = function(roundStateChangedMessage)
			recordBroadcast(
				"RoundStateChanged",
				harness.sentRoundStateChangedRecords,
				"roundStateChangedMessage",
				roundStateChangedMessage
			)
			if harness.shouldRoundStateChangedSenderRaise then
				error("deliberate RoundStateChanged send failure")
			end
		end,
		sendRoundResultsPublishedToEveryDevice = function(roundResultsPublishedMessage)
			recordBroadcast(
				"RoundResultsPublished",
				harness.sentRoundResultsPublishedRecords,
				"roundResultsPublishedMessage",
				roundResultsPublishedMessage
			)
			if harness.shouldRoundResultsPublishedSenderRaise then
				error("deliberate RoundResultsPublished send failure")
			end
		end,
		sendRoundOutfitDraftAcknowledged = function(playerUserId: number, acknowledgement)
			table.insert(
				harness.orderedSentMessageLog,
				{ sentMessageKind = "RoundOutfitDraftAcknowledged", playerUserId = playerUserId }
			)
			harness.recordingAcknowledgementSender.sendRoundOutfitDraftAcknowledged(playerUserId, acknowledgement)
			if chosenHarnessOptions.onRoundOutfitDraftAcknowledged then
				chosenHarnessOptions.onRoundOutfitDraftAcknowledged(playerUserId, acknowledgement)
			end
		end,
	}
end

local function buildRefereeDependencies(harness, chosenHarnessOptions)
	local recordingDeviceSenders = buildRecordingDeviceSenders(harness, chosenHarnessOptions)
	return {
		clock = harness.fakeClock,
		scheduler = harness.fakeScheduler,
		themedRoundClock = harness.refereeFacingRoundClock,
		playerRequestRateLimiter = harness.playerRequestRateLimiter,
		rewardLedger = createRecordingLedgerProxy(
			chosenHarnessOptions.rewardLedger or harness.realRewardLedger,
			harness.recordedGrantCalls
		),
		playerSaveDataKeeper = harness.playerSaveDataKeeper,
		marketplaceStylingItemResolver = harness.fakeResolver,
		stylingItemByStylingItemKey = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
		findThemeByThemeId = chosenHarnessOptions.findThemeByThemeId or ThemeCatalog.findThemeByThemeId,
		sendRoundStateChangedToEveryDevice = recordingDeviceSenders.sendRoundStateChangedToEveryDevice,
		sendRoundResultsPublishedToEveryDevice = recordingDeviceSenders.sendRoundResultsPublishedToEveryDevice,
		sendRoundOutfitDraftAcknowledged = recordingDeviceSenders.sendRoundOutfitDraftAcknowledged,
		readPlayerDisplayName = chosenHarnessOptions.readPlayerDisplayName or function(playerUserId: number)
			return "Player " .. tostring(playerUserId)
		end,
		logger = harness.recordingLogger,
		validateOutfit = harness.countingOutfitValidator.validateOutfit,
		ownerDecisions = chosenHarnessOptions.ownerDecisions,
		createRoundOutfitDraftKeeper = createCountingDraftKeeperFactory(
			harness.draftsReachingKeeperRecords,
			harness.createdDraftKeepers
		),
	}
end

function ThemedRoundRefereeTestHarness.createRefereeWithFakes(harnessOptions: any?)
	local chosenHarnessOptions = harnessOptions or {}
	local fakeClock = FakeClock.new(ThemedRoundRefereeTestHarness.ROUND_START_UNIX_SECONDS)
	local harness = {
		fakeClock = fakeClock,
		fakeScheduler = FakeScheduler.new(fakeClock),
		recordingLogger = RecordingLogger.new(),
		playerRequestRateLimiter = PlayerRequestRateLimiter.new({ clock = fakeClock }),
		fakeResolver = FakeMarketplaceStylingItemResolver.new(),
		countingOutfitValidator = CountingOutfitValidator.new(fakeClock),
		recordingAcknowledgementSender = RecordingRoundOutfitDraftAcknowledgementSender.new(fakeClock),
		recordedGrantCalls = {},
		sentRoundStateChangedRecords = {},
		sentRoundResultsPublishedRecords = {},
		draftsReachingKeeperRecords = {},
		-- Every message any sender was asked to send, in order: { sentMessageKind, playerUserId? }.
		orderedSentMessageLog = {},
		createdDraftKeepers = {},
		shouldRoundStateChangedSenderRaise = false,
		shouldRoundResultsPublishedSenderRaise = false,
	}
	if not chosenHarnessOptions.isWardrobeCatalogNotReadyAtStart then
		harness.fakeResolver:publishWardrobeCatalog(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
	end
	addPlayerSaveDataKeeperOnFakeStorage(harness)
	harness.realRewardLedger =
		RewardLedger.new({ playerSaveDataKeeper = harness.playerSaveDataKeeper, logger = RecordingLogger.new() })
	addThemedRoundClockAndRefereeFacingProxy(harness)
	ThemedRoundRefereeHarnessRoundActions.addRoundActionsToHarness(harness, ROUND_START_UNIX_MILLISECONDS)

	harness.refereeDependencies = buildRefereeDependencies(harness, chosenHarnessOptions)
	harness.referee = ThemedRoundReferee.new(harness.refereeDependencies)
	if not chosenHarnessOptions.doNotStartRoundClock then
		harness.themedRoundClock:startRoundCycle()
	end
	return harness
end

-- One acknowledgement summary as listAcknowledgementsSentTo returns it.
ThemedRoundRefereeTestHarness.expectedAcknowledgement = RoundOutfitDraftTestMessages.buildExpectedAcknowledgementSummary

return table.freeze(ThemedRoundRefereeTestHarness)
