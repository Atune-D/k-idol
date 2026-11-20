-- A player leaves this server and rejoins it at once, while the OLD save session is still
-- finishing (development spec §3.4 loading and final save, §2.6, §3.5). Storage answers arrive in
-- the orders that let the new load finish as early as storage allows. For every way the old
-- session can end, the REAL keeper wired to the REAL ThemedRoundReferee, StoredLobbyOutfitKeeper,
-- DailyProgressTracker, FanCountLeaderboardKeeper and PlayerSaveDataSnapshotPublisher must leave
-- the new, live session intact: the keeper's events name only the player, so listeners must see
-- the old session end before anything about the new one.
--
-- (StoredSchemaVersionNotUnderstood and LoadRetriesExhausted cannot end an old session while a
-- newer one is live; PlayerSaveDataKeeperQuickRejoinSessions.spec.luau covers them.)

local FakePlayerSaveDataStorageAnswerOrder = require("../Support/FakePlayerSaveDataStorageAnswerOrder")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local QuickRejoinSameServerTestHarness = require("./QuickRejoinSameServerTestHarness")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local P = QuickRejoinSameServerTestHarness.PLAYER_P
local HIDDEN_HAIR_KEY = QuickRejoinSameServerTestHarness.HIDDEN_HAIR_KEY
local FINAL_SAVE_RETRY_DELAY_SECONDS = PlayerSaveDataKeeper.FINAL_SAVE_RETRY_DELAY_SECONDS
local FINAL_SAVE_MAXIMUM_RETRY_COUNT = PlayerSaveDataKeeper.FINAL_SAVE_MAXIMUM_RETRY_COUNT
local MINIMUM_SECONDS_BETWEEN_SAVE_STARTS = PlayerSaveDataKeeper.MINIMUM_SECONDS_BETWEEN_SAVE_STARTS

local function advanceSeconds(harness, elapsedSeconds: number)
	harness.fakeScheduler:advanceTimeAndRunDueCallbacks(elapsedSeconds)
end

-- Each ending starts with the player loaded, in the round, with unsaved progress, at T = 5,
-- unless `startsWithLoadInFlight`. `play` leaves, rejoins and answers storage; after it, every
-- operation still in flight succeeds and the device joins the round as soon as the save loads.
local OLD_SESSION_ENDINGS = {
	{
		endingName = "FinalSaveSucceeded, its write landing at once and its answer arriving late",
		expectedSessionEndReasons = { "FinalSaveSucceeded" },
		play = function(harness)
			harness.leaveServer(P)
			harness.joinServer(P)
			local heldFinalSaveAnswer = FakePlayerSaveDataStorageAnswerOrder.landOldestPendingWriteAndHoldItsAnswer(
				harness.fakePlayerSaveDataStorage,
				P
			)
			harness.completeEveryPendingOperation() -- whatever the new session has started meanwhile
			harness.joinRoundOnceLoaded(P)
			heldFinalSaveAnswer:deliverAnswer()
		end,
	},
	{
		endingName = "SessionLockLost, its final write landing with the answer lost and the retry finding the lock gone",
		expectedSessionEndReasons = { "SessionLockLost" },
		play = function(harness)
			harness.leaveServer(P)
			harness.joinServer(P)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperationButReportFailure(P)
			harness.completeEveryPendingOperation()
			harness.joinRoundOnceLoaded(P)
			advanceSeconds(harness, FINAL_SAVE_RETRY_DELAY_SECONDS)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(P) -- the old session's retry
		end,
	},
	{
		endingName = "FinalSaveAbandoned, its first write landing with the answer lost and every retry failing",
		expectedSessionEndReasons = { "FinalSaveAbandoned" },
		play = function(harness)
			harness.leaveServer(P)
			harness.joinServer(P)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperationButReportFailure(P)
			harness.completeEveryPendingOperation()
			harness.joinRoundOnceLoaded(P)
			for _ = 1, FINAL_SAVE_MAXIMUM_RETRY_COUNT do
				advanceSeconds(harness, FINAL_SAVE_RETRY_DELAY_SECONDS)
				harness.fakePlayerSaveDataStorage:failOldestPendingOperation(P)
			end
		end,
	},
	{
		endingName = "LeftBeforeLoadFinished, its load in flight at the leave failing after the rejoin's load could finish",
		expectedSessionEndReasons = { "LeftBeforeLoadFinished" },
		startsWithLoadInFlight = true,
		play = function(harness)
			harness.leaveServer(P)
			harness.joinServer(P)
			if harness.countPendingOperations(P) >= 2 then -- the rejoin's load is in flight too
				FakePlayerSaveDataStorageAnswerOrder.completeNewestPendingOperation(
					harness.fakePlayerSaveDataStorage,
					P
				)
				harness.joinRoundOnceLoaded(P)
			end
			harness.fakePlayerSaveDataStorage:failOldestPendingOperation(P) -- the first load
		end,
	},
	{
		endingName = "FinalSaveSucceeded after its in-flight load took the save, the final answer arriving late",
		expectedSessionEndReasons = { "FinalSaveSucceeded" },
		startsWithLoadInFlight = true,
		play = function(harness)
			harness.leaveServer(P)
			harness.joinServer(P)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(P) -- the first load takes the save
			local heldFinalSaveAnswer = FakePlayerSaveDataStorageAnswerOrder.landNewestPendingWriteAndHoldItsAnswer(
				harness.fakePlayerSaveDataStorage,
				P
			)
			harness.completeEveryPendingOperation()
			harness.joinRoundOnceLoaded(P)
			heldFinalSaveAnswer:deliverAnswer()
		end,
	},
}

local function playOldSessionEndingAndSettleNewSession(oldSessionEnding)
	local harness = QuickRejoinSameServerTestHarness.createHarness()
	if oldSessionEnding.startsWithLoadInFlight then
		harness.storeSaveWithHiddenLobbyItem(P)
		harness.joinServer(P)
	else
		harness.loadAndJoinRound(P)
		harness.applyProgressChange(P, "starCoinBalance", 40)
		harness.applyProgressChange(P, "fanCount", 25)
	end
	harness.advanceToRoundSecond(5)
	oldSessionEnding.play(harness)
	harness.completeEveryPendingOperation()
	harness.joinRoundOnceLoaded(P)
	expect(harness.listSessionEndReasons(P)).toEqual(oldSessionEnding.expectedSessionEndReasons)
	expect(harness.isLoaded(P)).toBeTrue()
	expect(harness.hasJoinedRoundSinceLoadByPlayerUserId[P]).toBeTrue()
	return harness
end

for _, oldSessionEnding in OLD_SESSION_ENDINGS do
	describe("Quick rejoin, old session ends with " .. oldSessionEnding.endingName, function()
		it("PlayerSaveDataKeeper: listeners see the old session end before anything about the new one", function()
			local harness = playOldSessionEndingAndSettleNewSession(oldSessionEnding)
			expect(QuickRejoinSameServerTestHarness.describeFirstSessionOverlap(harness.listEventRecordsOf(P))).toBeNil()
		end)

		it("StoredLobbyOutfitKeeper keeps the new session's stored-outfit availability", function()
			local harness = playOldSessionEndingAndSettleNewSession(oldSessionEnding)
			local storedLobbyOutfitAvailability = harness.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(P)
			expect(storedLobbyOutfitAvailability ~= nil).toBeTrue()
			expect(storedLobbyOutfitAvailability.unavailableLobbyOutfitStylingItemKeys).toEqual({ HIDDEN_HAIR_KEY })
		end)

		it("ThemedRoundReferee keeps the player in the round joined in the new session", function()
			local harness = playOldSessionEndingAndSettleNewSession(oldSessionEnding)
			expect(harness.referee:isParticipantOfCurrentRound(P)).toBeTrue()
		end)

		it("DailyProgressTracker keeps counting the new session's playtime", function()
			local harness = playOldSessionEndingAndSettleNewSession(oldSessionEnding)
			local playtimeBefore = harness.readInMemoryPlaytimeSecondsToday(P)
			advanceSeconds(harness, 61) -- playtime reaches the next whole minute, which is recorded
			expect(harness.readInMemoryPlaytimeSecondsToday(P) > playtimeBefore).toBeTrue()
			expect(harness.trackerLogger.loggedWarnings).toEqual({})
		end)

		it("FanCountLeaderboardKeeper keeps syncing the new session's saved fan count", function()
			local harness = playOldSessionEndingAndSettleNewSession(oldSessionEnding)
			local loadedFanCount = harness.playerSaveDataKeeper:readPlayerSaveDataCopy(P).fanCount
			expect(harness.fanCountLeaderboardKeeper:readLastLeaderboardSyncedFanCount(P)).toBe(loadedFanCount)
			harness.applyProgressChange(P, "fanCount", 10)
			advanceSeconds(harness, MINIMUM_SECONDS_BETWEEN_SAVE_STARTS)
			harness.completeEveryPendingOperation()
			expect(harness.fakeFanCountLeaderboardStorage:readStoredFanCount(P)).toBe(loadedFanCount + 10)
			expect(harness.fanCountLeaderboardKeeper:readLastLeaderboardSyncedFanCount(P)).toBe(loadedFanCount + 10)
		end)

		it(
			"PlayerSaveDataSnapshotPublisher sends the new session's changes at once, with the unavailable keys",
			function()
				local harness = playOldSessionEndingAndSettleNewSession(oldSessionEnding)
				expect(harness.publisher:isPublishingToPlayer(P)).toBeTrue()
				local sentBeforeGrant = #harness.listSnapshotMessagesSentTo(P)
				harness.applyProgressChange(P, "starCoinBalance", 70)
				local snapshotMessages = harness.listSnapshotMessagesSentTo(P)
				expect(#snapshotMessages).toBe(sentBeforeGrant + 1)
				local lastSnapshotMessage = snapshotMessages[#snapshotMessages]
				expect(lastSnapshotMessage.starCoinBalance).toBe(
					harness.playerSaveDataKeeper:readPlayerSaveDataCopy(P).starCoinBalance
				)
				expect(lastSnapshotMessage.unavailableLobbyOutfitStylingItemKeys).toEqual({ HIDDEN_HAIR_KEY })
				expect(harness.publisherLogger.loggedWarnings).toEqual({})
			end
		)
	end)
end
