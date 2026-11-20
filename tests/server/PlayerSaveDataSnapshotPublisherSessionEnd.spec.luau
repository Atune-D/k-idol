-- PlayerSaveDataSnapshotPublisher when a player's save session ends (development spec v1.3 §2.6,
-- §3.4): every end reason of the REAL PlayerSaveDataKeeper forgets the player, and a player who
-- rejoins while the OLD session is still finishing is published again once the new session loads.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataSnapshotPublisher = require("../../src/server/PlayerSaveDataSnapshotPublisher")
local PlayerSaveDataSnapshotPublisherTestHarness = require("./PlayerSaveDataSnapshotPublisherTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local createHarness = PlayerSaveDataSnapshotPublisherTestHarness.createHarness
local PLAYER_USER_ID = PlayerSaveDataSnapshotPublisherTestHarness.PLAYER_USER_ID
local TOMORROWS_QUEST_IDS = PlayerSaveDataSnapshotPublisherTestHarness.TOMORROWS_QUEST_IDS
local SECONDS_UNTIL_NEXT_UTC_MIDNIGHT = PlayerSaveDataSnapshotPublisherTestHarness.SECONDS_UNTIL_NEXT_UTC_MIDNIGHT
local STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS = PlayerSaveDataSnapshotPublisher.STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS
local FINAL_SAVE_MAXIMUM_RETRY_COUNT = PlayerSaveDataKeeper.FINAL_SAVE_MAXIMUM_RETRY_COUNT
local FINAL_SAVE_RETRY_DELAY_SECONDS = PlayerSaveDataKeeper.FINAL_SAVE_RETRY_DELAY_SECONDS

local function listSessionEndReasonsOf(harness, playerUserId: number): { string }
	local sessionEndReasons = {}
	for _, endedSessionRecord in harness.endedSessionRecords do
		if endedSessionRecord.playerUserId == playerUserId then
			table.insert(sessionEndReasons, endedSessionRecord.sessionEndReason)
		end
	end
	return sessionEndReasons
end

-- After the session ended: a midnight and a catalog change send nothing more.
local function expectNothingMoreIsSentTo(harness, playerUserId: number)
	local sentBefore = harness.countSnapshotMessagesSentTo(playerUserId)
	harness.advanceSeconds(SECONDS_UNTIL_NEXT_UTC_MIDNIGHT + STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS)
	harness.fakeResolver:publishWardrobeCatalog({})
	harness.advanceSeconds(STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS)
	expect(harness.countSnapshotMessagesSentTo(playerUserId)).toBe(sentBefore)
end

describe("PlayerSaveDataSnapshotPublisher forgets a player for every session end reason", function()
	it("FinalSaveSucceeded", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.leaveAndFinishFinalSave(PLAYER_USER_ID)
		expect(listSessionEndReasonsOf(harness, PLAYER_USER_ID)).toEqual({ "FinalSaveSucceeded" })
		expect(harness.publisher:isPublishingToPlayer(PLAYER_USER_ID)).toBeFalse()
		expectNothingMoreIsSentTo(harness, PLAYER_USER_ID)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
	end)

	it("SessionLockLost (another server took the save)", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		local storedSaveData = harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(PLAYER_USER_ID)
		storedSaveData.gameServerSessionLock = {
			sessionLockId = "another-server-lock",
			lockRefreshedAtUnixSeconds = harness.fakeClock:getCurrentUnixSeconds(),
		}
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(PLAYER_USER_ID, storedSaveData)
		harness.redeemPromoCode(PLAYER_USER_ID, "spring_code", 10) -- the save it requests finds the lock
		harness.advanceSeconds(PlayerSaveDataKeeper.MINIMUM_SECONDS_BETWEEN_SAVE_STARTS)
		expect(listSessionEndReasonsOf(harness, PLAYER_USER_ID)).toEqual({ "SessionLockLost" })
		expect(harness.publisher:isPublishingToPlayer(PLAYER_USER_ID)).toBeFalse()
		expectNothingMoreIsSentTo(harness, PLAYER_USER_ID)
		expect(harness.publisherLogger.loggedWarnings).toEqual({})
	end)

	it("FinalSaveAbandoned (every final-save attempt failed)", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.fakePlayerSaveDataStorage:failNextStartedOperations(1 + FINAL_SAVE_MAXIMUM_RETRY_COUNT)
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER_USER_ID)
		expect(harness.publisher:isPublishingToPlayer(PLAYER_USER_ID)).toBeTrue() -- still saving
		harness.advanceSeconds(FINAL_SAVE_MAXIMUM_RETRY_COUNT * FINAL_SAVE_RETRY_DELAY_SECONDS)
		expect(listSessionEndReasonsOf(harness, PLAYER_USER_ID)).toEqual({ "FinalSaveAbandoned" })
		expect(harness.publisher:isPublishingToPlayer(PLAYER_USER_ID)).toBeFalse()
		expectNothingMoreIsSentTo(harness, PLAYER_USER_ID)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
	end)

	it("sends nothing once leaving started, even when persistence recovers during the final save", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.failEverySaveUntilPersistenceDelayed(PLAYER_USER_ID)
		local sentBeforeLeaving = harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)
		harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(false)
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER_USER_ID)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER_USER_ID) -- persistence recovers
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(sentBeforeLeaving)
		expect(harness.publisher:isPublishingToPlayer(PLAYER_USER_ID)).toBeFalse()
		expect(harness.publisherLogger.loggedWarnings).toEqual({})
	end)

	it("a player who loads again after leaving is sent a fresh first message", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.leaveAndFinishFinalSave(PLAYER_USER_ID)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER_USER_ID)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(2)
		local snapshotMessages = harness.listSnapshotMessagesSentTo(PLAYER_USER_ID)
		expect(snapshotMessages[2]).toEqual(snapshotMessages[1])
	end)
end)

-- The player leaves; the final write lands in storage (lock handed back) but its answer is lost,
-- so the OLD session schedules a final-save retry. The player rejoins at once: the keeper holds the
-- NEW load back until the old session has ended (PlayerSaveDataKeeper header, "Quick rejoin").
local function leaveWithLostFinalSaveAnswerAndRejoin(harness)
	harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(false)
	harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER_USER_ID)
	harness.fakePlayerSaveDataStorage:completeOldestPendingOperationButReportFailure(PLAYER_USER_ID)
	harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(true)
	harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER_USER_ID)
	expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER_USER_ID)).toBeFalse()
	expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
end

-- After the old session ended, the new session loaded and is published normally: the stored
-- outfit keeper knows the player again, so nothing waits and nothing is logged.
local function expectNewSessionKeepsBeingPublished(harness)
	expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER_USER_ID)).toBeTrue()
	expect(harness.publisher:isPublishingToPlayer(PLAYER_USER_ID)).toBeTrue()
	expect(harness.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(PLAYER_USER_ID) ~= nil).toBeTrue()
	expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(2)

	local grantOutcome = harness.redeemPromoCode(PLAYER_USER_ID, "rejoin_code", 70)
	expect(grantOutcome.rewardLedgerOutcome).toBe("Granted")
	expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(3) -- at once
	expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID).starCoinBalance).toBe(70)

	harness.advanceSeconds(SECONDS_UNTIL_NEXT_UTC_MIDNIGHT + STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS)
	expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(4)
	expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID)).toEqual(
		harness.buildExpectedSnapshotMessage(PLAYER_USER_ID, {}, TOMORROWS_QUEST_IDS)
	)
	expect(harness.publisherLogger.loggedWarnings).toEqual({})
end

describe("PlayerSaveDataSnapshotPublisher when a player rejoins while the old session is finishing", function()
	it("the old session's final save is abandoned: then the new session loads and is published", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		leaveWithLostFinalSaveAnswerAndRejoin(harness)
		harness.fakePlayerSaveDataStorage:failNextStartedOperations(FINAL_SAVE_MAXIMUM_RETRY_COUNT)
		harness.advanceSeconds(FINAL_SAVE_MAXIMUM_RETRY_COUNT * FINAL_SAVE_RETRY_DELAY_SECONDS)
		expect(listSessionEndReasonsOf(harness, PLAYER_USER_ID)).toEqual({ "FinalSaveAbandoned" })
		expectNewSessionKeepsBeingPublished(harness)
	end)

	it("the old session's final-save retry finds its lock handed back: then the new session loads", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		leaveWithLostFinalSaveAnswerAndRejoin(harness)
		harness.advanceSeconds(FINAL_SAVE_RETRY_DELAY_SECONDS)
		expect(listSessionEndReasonsOf(harness, PLAYER_USER_ID)).toEqual({ "SessionLockLost" })
		expectNewSessionKeepsBeingPublished(harness)
	end)

	it("the old session ends while the new one is still loading: forgotten, then the new load sends", function()
		local harness = createHarness()
		harness.loadPlayerWithStoredLobbyOutfit(PLAYER_USER_ID, { FakeStylingItemPool.HIDDEN_HAIR_KEY })
		harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(false)
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER_USER_ID)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER_USER_ID) -- waits behind the old write
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER_USER_ID) -- the old final save
		expect(listSessionEndReasonsOf(harness, PLAYER_USER_ID)).toEqual({ "FinalSaveSucceeded" })
		expect(harness.publisher:isPublishingToPlayer(PLAYER_USER_ID)).toBeFalse()
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER_USER_ID) -- the new load
		expect(harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(PLAYER_USER_ID)).toBeTrue()
		expect(harness.publisher:isPublishingToPlayer(PLAYER_USER_ID)).toBeTrue()
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(2)
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID).unavailableLobbyOutfitStylingItemKeys).toEqual({
			FakeStylingItemPool.HIDDEN_HAIR_KEY,
		})
		expect(harness.publisherLogger.loggedWarnings).toEqual({})
	end)
end)
