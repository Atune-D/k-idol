-- PlayerSaveDataSnapshotPublisher: the setup rules of `new` and
-- `startPublishingPlayerSaveDataSnapshots` (dependencies, the daily quest catalog copy,
-- subscriptions).

local UnitTestFramework = require("../Support/UnitTestFramework")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local PlayerSaveDataSnapshotPublisher = require("../../src/server/PlayerSaveDataSnapshotPublisher")
local PlayerSaveDataSnapshotPublisherTestHarness = require("./PlayerSaveDataSnapshotPublisherTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local createHarness = PlayerSaveDataSnapshotPublisherTestHarness.createHarness
local PLAYER_USER_ID = PlayerSaveDataSnapshotPublisherTestHarness.PLAYER_USER_ID
local TODAYS_QUEST_IDS = PlayerSaveDataSnapshotPublisherTestHarness.TODAYS_QUEST_IDS

-- A complete set of dependencies whose keepers are inert stand-ins.
local function createInertDependencies()
	local fakeClock = FakeClock.new(PlayerSaveDataSnapshotPublisherTestHarness.STARTING_UNIX_SECONDS)
	local inertKeeper = {}
	local subscribedEventNames = {}
	for _, subscribeMethodName in
		{
			"subscribeToPlayerSaveDataLoaded",
			"subscribeToInMemorySaveDataChanged",
			"subscribeToSaveDataPersistenceDelayedChanged",
			"subscribeToPlayerSaveDataSessionEnded",
			"subscribeToStoredLobbyOutfitAvailabilityChanged",
		}
	do
		inertKeeper[subscribeMethodName] = function()
			table.insert(subscribedEventNames, subscribeMethodName)
			return function() end
		end
	end
	return {
		playerSaveDataKeeper = inertKeeper,
		storedLobbyOutfitKeeper = inertKeeper,
		clock = fakeClock,
		scheduler = FakeScheduler.new(fakeClock),
		dailyQuestCatalogEntries = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS,
		sendPlayerSaveDataSnapshotToPlayer = function() end,
		logger = { logInformation = function() end, logWarning = function() end },
	},
		subscribedEventNames
end

describe("PlayerSaveDataSnapshotPublisher setup", function()
	it("raises when a dependency is missing", function()
		local completeDependencies = createInertDependencies()
		for missingDependencyName in completeDependencies do
			local incompleteDependencies = table.clone(completeDependencies)
			incompleteDependencies[missingDependencyName] = nil
			expect(function()
				PlayerSaveDataSnapshotPublisher.new(incompleteDependencies)
			end).toThrow("missing dependency " .. missingDependencyName)
		end
	end)

	it("raises when the sender is not a function", function()
		local dependencies = createInertDependencies()
		dependencies.sendPlayerSaveDataSnapshotToPlayer = {} :: any
		expect(function()
			PlayerSaveDataSnapshotPublisher.new(dependencies)
		end).toThrow("sendPlayerSaveDataSnapshotToPlayer must be a function")
	end)

	it("raises at once for a daily quest catalog that cannot fill a day", function()
		local dependencies = createInertDependencies()
		dependencies.dailyQuestCatalogEntries = {
			DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS[1],
			DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS[2],
		}
		expect(function()
			PlayerSaveDataSnapshotPublisher.new(dependencies)
		end).toThrow("needs at least")
	end)

	it("subscribes to every event once on start, and raises when started twice", function()
		local dependencies, subscribedEventNames = createInertDependencies()
		local publisher = PlayerSaveDataSnapshotPublisher.new(dependencies)
		expect(#subscribedEventNames).toBe(0)
		publisher:startPublishingPlayerSaveDataSnapshots()
		table.sort(subscribedEventNames)
		expect(subscribedEventNames).toEqual({
			"subscribeToInMemorySaveDataChanged",
			"subscribeToPlayerSaveDataLoaded",
			"subscribeToPlayerSaveDataSessionEnded",
			"subscribeToSaveDataPersistenceDelayedChanged",
			"subscribeToStoredLobbyOutfitAvailabilityChanged",
		})
		expect(dependencies.scheduler:getPendingCallbackCount()).toBe(1)
		expect(function()
			publisher:startPublishingPlayerSaveDataSnapshots()
		end).toThrow("already called")
		expect(#subscribedEventNames).toBe(5)
		expect(dependencies.scheduler:getPendingCallbackCount()).toBe(1)
	end)

	it("copies the caller's catalog: editing it afterwards changes nothing", function()
		local callerOwnedCatalog = table.clone(DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS)
		local harness = createHarness()
		local dependencies = createInertDependencies()
		dependencies.dailyQuestCatalogEntries = callerOwnedCatalog
		dependencies.playerSaveDataKeeper = harness.playerSaveDataKeeper
		dependencies.storedLobbyOutfitKeeper = harness.storedLobbyOutfitKeeper
		dependencies.clock = harness.fakeClock
		dependencies.scheduler = harness.fakeScheduler
		local sentSnapshotMessages = {}
		dependencies.sendPlayerSaveDataSnapshotToPlayer = function(_, snapshotMessage)
			table.insert(sentSnapshotMessages, snapshotMessage)
		end
		local publisher = PlayerSaveDataSnapshotPublisher.new(dependencies)
		publisher:startPublishingPlayerSaveDataSnapshots()
		table.clear(callerOwnedCatalog)
		harness.loadPlayer(PLAYER_USER_ID)
		expect(#sentSnapshotMessages).toBe(1)
		expect(sentSnapshotMessages[1].todaysDailyQuestIds).toEqual(TODAYS_QUEST_IDS)
	end)
end)
