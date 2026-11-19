local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeFanCountLeaderboardStorage = require("../Support/FakeFanCountLeaderboardStorage")
local FanCountLeaderboardKeeper = require("../../src/server/FanCountLeaderboardKeeper")
local PlayerSaveDataKeeperTestHarness = require("./PlayerSaveDataKeeperTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID
local OTHER_PLAYER = PlayerSaveDataKeeperTestHarness.OTHER_PLAYER_USER_ID
local START = PlayerSaveDataKeeperTestHarness.EXAMPLE_STARTING_UNIX_SECONDS

-- A save keeper with a loaded-later player, plus a started leaderboard keeper on fake storage.
local function createLeaderboardHarness(lookUpPlayerDisplayNamesByUserId: any?)
	local harness = PlayerSaveDataKeeperTestHarness.createKeeperWithFakes()
	local fakeLeaderboardStorage = FakeFanCountLeaderboardStorage.new()
	local leaderboardWarnings = {}
	local fanCountLeaderboardKeeper = FanCountLeaderboardKeeper.new({
		playerSaveDataKeeper = harness.playerSaveDataKeeper,
		fanCountLeaderboardStorage = fakeLeaderboardStorage,
		clock = harness.fakeClock,
		scheduler = harness.fakeScheduler,
		logger = {
			logInformation = function() end,
			logWarning = function(_, message: string)
				table.insert(leaderboardWarnings, message)
			end,
		},
		lookUpPlayerDisplayNamesByUserId = lookUpPlayerDisplayNamesByUserId or function(playerUserIds)
			local displayNameByPlayerUserId = {}
			for _, playerUserId in playerUserIds do
				displayNameByPlayerUserId[playerUserId] = "Idol" .. tostring(playerUserId)
			end
			return displayNameByPlayerUserId
		end,
	})
	fanCountLeaderboardKeeper:startSyncingAndRefreshingTopEntries()
	harness.fakeLeaderboardStorage = fakeLeaderboardStorage
	harness.fanCountLeaderboardKeeper = fanCountLeaderboardKeeper
	harness.leaderboardWarnings = leaderboardWarnings
	return harness
end

-- Loads PLAYER (whose stored save has 1200 fans) and completes the catch-up sync.
local function loadPlayerWithTwelveHundredFans(harness)
	harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(
		PLAYER,
		PlayerSaveDataKeeperTestHarness.createStoredSaveLockedByOtherServer(START - 400)
	)
	harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
	harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
	harness.fakeLeaderboardStorage:completePendingWriteAt(1)
	harness.advanceSeconds(20)
end

describe("FanCountLeaderboardKeeper sync", function()
	it("syncs once from the loaded save (catch-up after a crash between saving and syncing)", function()
		local harness = createLeaderboardHarness()
		harness.fakeLeaderboardStorage:setStoredFanCount(PLAYER, 1100) -- the crashed server never synced 1200
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(
			PLAYER,
			PlayerSaveDataKeeperTestHarness.createStoredSaveLockedByOtherServer(START - 400)
		)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.fakeLeaderboardStorage.startedWriteRecords).toEqual({
			{ playerUserId = PLAYER, fanCountBeingWritten = 1200 },
		})
		harness.fakeLeaderboardStorage:completePendingWriteAt(1)
		expect(harness.fakeLeaderboardStorage:readStoredFanCount(PLAYER)).toBe(1200)
		expect(harness.fanCountLeaderboardKeeper:readLastLeaderboardSyncedFanCount(PLAYER)).toBe(1200)
	end)

	it("syncs after a successful save whose fanCount changed, and not when it is unchanged", function()
		local harness = createLeaderboardHarness()
		loadPlayerWithTwelveHundredFans(harness)
		harness.grantFans(PLAYER, 40)
		expect(#harness.fakeLeaderboardStorage.startedWriteRecords).toBe(1) -- not before the save
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.fakeLeaderboardStorage.startedWriteRecords[2]).toEqual({
			playerUserId = PLAYER,
			fanCountBeingWritten = 1240,
		})
		harness.fakeLeaderboardStorage:completePendingWriteAt(1)

		harness.advanceSeconds(10)
		harness.grantStarCoins(PLAYER, 80) -- fans unchanged
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(#harness.fakeLeaderboardStorage.startedWriteRecords).toBe(2)
	end)

	it("does not sync when the save failed", function()
		local harness = createLeaderboardHarness()
		loadPlayerWithTwelveHundredFans(harness)
		harness.grantFans(PLAYER, 40)
		harness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
		harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(true)
		harness.fakePlayerSaveDataStorage:failNextStartedOperations(3)
		harness.advanceSeconds(30)
		expect(harness.playerSaveDataKeeper:isSaveDataPersistenceDelayed(PLAYER)).toBeTrue()
		expect(#harness.fakeLeaderboardStorage.startedWriteRecords).toBe(1) -- only the catch-up sync
		expect(harness.fakeLeaderboardStorage:readStoredFanCount(PLAYER)).toBe(1200)
	end)

	it("never takes fanCount from an unsaved in-memory change", function()
		local harness = createLeaderboardHarness()
		loadPlayerWithTwelveHundredFans(harness)
		harness.grantFans(PLAYER, 40) -- save of 1240 in flight
		harness.grantFans(PLAYER, 10) -- 1250 only in memory
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		for _, leaderboardWrite in harness.fakeLeaderboardStorage.startedWriteRecords do
			expect(leaderboardWrite.fanCountBeingWritten == 1250).toBeFalse()
		end
		expect(harness.fakeLeaderboardStorage.startedWriteRecords[2].fanCountBeingWritten).toBe(1240)
	end)

	it(
		"does not let a failed or raising sync affect rewards or saving, retries nothing, and compares again after the next save",
		function()
			local harness = createLeaderboardHarness()
			loadPlayerWithTwelveHundredFans(harness)
			harness.grantFans(PLAYER, 40)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
			harness.fakeLeaderboardStorage:failPendingWriteAt(1)
			harness.advanceSeconds(120)
			expect(#harness.fakeLeaderboardStorage.startedWriteRecords).toBe(2) -- no retry by itself...
			expect(harness.fakeLeaderboardStorage:readStoredFanCount(PLAYER)).toBe(1200)

			harness.fakeLeaderboardStorage:setRaisesWhenWriteStarts(true)
			local changeResult = harness.grantFans(PLAYER, 10)
			expect(changeResult.changeOutcome).toBe("Applied")
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- the periodic save from 120 s
			while harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER) > 0 do
				harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
			end
			harness.advanceSeconds(10)
			while harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER) > 0 do
				harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
			end
			expect(harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER).fanCount).toBe(1250)
			expect(harness.playerSaveDataKeeper:isSaveDataPersistenceDelayed(PLAYER)).toBeFalse()
			expect(#harness.leaderboardWarnings >= 2).toBeTrue()

			-- ...but the next successful save compares again and syncs.
			harness.fakeLeaderboardStorage:setRaisesWhenWriteStarts(false)
			harness.advanceSeconds(10)
			harness.grantStarCoins(PLAYER, 1)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
			harness.fakeLeaderboardStorage:completePendingWriteAt(1)
			expect(harness.fakeLeaderboardStorage:readStoredFanCount(PLAYER)).toBe(1250)
		end
	)

	it("keeps the larger value when two writes complete in the opposite order to which they were issued", function()
		local harness = createLeaderboardHarness()
		loadPlayerWithTwelveHundredFans(harness)
		harness.grantFans(PLAYER, 40)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- issues 1240
		harness.advanceSeconds(10)
		harness.grantFans(PLAYER, 60)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER) -- issues 1300
		expect(harness.fakeLeaderboardStorage:countPendingWrites()).toBe(2)
		harness.fakeLeaderboardStorage:completePendingWriteAt(2) -- 1300 lands first
		harness.fakeLeaderboardStorage:completePendingWriteAt(1) -- 1240 lands late
		expect(harness.fakeLeaderboardStorage:readStoredFanCount(PLAYER)).toBe(1300)
		expect(harness.fanCountLeaderboardKeeper:readLastLeaderboardSyncedFanCount(PLAYER)).toBe(1300)
	end)

	it("never lowers a value written by a newer server", function()
		local harness = createLeaderboardHarness()
		harness.fakeLeaderboardStorage:setStoredFanCount(PLAYER, 5000)
		loadPlayerWithTwelveHundredFans(harness)
		expect(harness.fakeLeaderboardStorage:readStoredFanCount(PLAYER)).toBe(5000)
	end)

	it("syncs the final save and forgets the player afterwards", function()
		local harness = createLeaderboardHarness()
		loadPlayerWithTwelveHundredFans(harness)
		harness.fakeLeaderboardStorage:setCompletesWritesImmediately(true)
		harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(
			PLAYER,
			"AppearanceChangeSavedLater",
			"fans without a save request (test only)",
			function(saveDataDraft)
				saveDataDraft.fanCount = 1300
				return true
			end
		)
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		expect(harness.fakeLeaderboardStorage:readStoredFanCount(PLAYER)).toBe(1300)
		expect(harness.fanCountLeaderboardKeeper:readLastLeaderboardSyncedFanCount(PLAYER)).toBeNil()
	end)
end)

describe("FanCountLeaderboardKeeper top entries", function()
	it("reads the top entries at start and every 60 s, in the §2.11 shape with looked-up display names", function()
		local harness = createLeaderboardHarness()
		expect(harness.fakeLeaderboardStorage.startedReadCount).toBe(1)
		expect(harness.fanCountLeaderboardKeeper:readTopEntriesAnswer()).toEqual({
			leaderboardEntries = {},
			refreshedAtUnixSeconds = START,
		})
		harness.fakeLeaderboardStorage:setStoredFanCount(PLAYER, 1240)
		harness.fakeLeaderboardStorage:setStoredFanCount(OTHER_PLAYER, 3000)
		harness.advanceSeconds(59.999)
		expect(harness.fakeLeaderboardStorage.startedReadCount).toBe(1)
		harness.advanceSeconds(0.001)
		expect(harness.fakeLeaderboardStorage.startedReadCount).toBe(2)
		expect(harness.fanCountLeaderboardKeeper:readTopEntriesAnswer()).toEqual({
			leaderboardEntries = {
				{ leaderboardRank = 1, playerUserId = OTHER_PLAYER, playerDisplayName = "Idol8802", fanCount = 3000 },
				{ leaderboardRank = 2, playerUserId = PLAYER, playerDisplayName = "Idol8801", fanCount = 1240 },
			},
			refreshedAtUnixSeconds = START + 60,
		})
		harness.advanceSeconds(120)
		expect(harness.fakeLeaderboardStorage.startedReadCount).toBe(4)
	end)

	it("holds at most 100 entries", function()
		local harness = createLeaderboardHarness()
		for playerUserId = 1, 150 do
			harness.fakeLeaderboardStorage:setStoredFanCount(playerUserId, playerUserId * 10)
		end
		harness.advanceSeconds(60)
		local leaderboardEntries = harness.fanCountLeaderboardKeeper:readTopEntriesAnswer().leaderboardEntries
		expect(#leaderboardEntries).toBe(100)
		expect(leaderboardEntries[1].fanCount).toBe(1500)
		expect(leaderboardEntries[100].leaderboardRank).toBe(100)
		expect(leaderboardEntries[100].fanCount).toBe(510)
	end)

	it("keeps the previous cache when a read fails", function()
		local harness = createLeaderboardHarness()
		harness.fakeLeaderboardStorage:setStoredFanCount(PLAYER, 1240)
		harness.advanceSeconds(60)
		local answerBeforeFailure = harness.fanCountLeaderboardKeeper:readTopEntriesAnswer()
		harness.fakeLeaderboardStorage:setFailsReads(true)
		harness.fakeLeaderboardStorage:setStoredFanCount(PLAYER, 9999)
		harness.advanceSeconds(60)
		expect(harness.fanCountLeaderboardKeeper:readTopEntriesAnswer()).toEqual(answerBeforeFailure)
	end)

	it("falls back to a placeholder name when the display name lookup fails or misses a player", function()
		local harness = createLeaderboardHarness(function()
			error("display name service down")
		end)
		harness.fakeLeaderboardStorage:setStoredFanCount(PLAYER, 1240)
		harness.advanceSeconds(60)
		expect(harness.fanCountLeaderboardKeeper:readTopEntriesAnswer().leaderboardEntries[1].playerDisplayName).toBe(
			"Player 8801"
		)

		local partialHarness = createLeaderboardHarness(function()
			return { [OTHER_PLAYER] = "Known" }
		end)
		partialHarness.fakeLeaderboardStorage:setStoredFanCount(PLAYER, 1240)
		partialHarness.fakeLeaderboardStorage:setStoredFanCount(OTHER_PLAYER, 10)
		partialHarness.advanceSeconds(60)
		local leaderboardEntries = partialHarness.fanCountLeaderboardKeeper:readTopEntriesAnswer().leaderboardEntries
		expect(leaderboardEntries[1].playerDisplayName).toBe("Player 8801")
		expect(leaderboardEntries[2].playerDisplayName).toBe("Known")
	end)

	it("hands out answers that cannot change the cache", function()
		local harness = createLeaderboardHarness()
		harness.fakeLeaderboardStorage:setStoredFanCount(PLAYER, 1240)
		harness.advanceSeconds(60)
		local firstAnswer = harness.fanCountLeaderboardKeeper:readTopEntriesAnswer()
		firstAnswer.leaderboardEntries[1].fanCount = 0
		table.insert(firstAnswer.leaderboardEntries, {})
		local secondAnswer = harness.fanCountLeaderboardKeeper:readTopEntriesAnswer()
		expect(#secondAnswer.leaderboardEntries).toBe(1)
		expect(secondAnswer.leaderboardEntries[1].fanCount).toBe(1240)
	end)
end)
