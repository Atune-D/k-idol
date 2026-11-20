-- PlayerSaveDataSnapshotPublisher when something around it fails (development spec v1.3 §2.6,
-- §5.1): a sender or a source that raises, bounded log lines, and the fallback when
-- StoredLobbyOutfitKeeper never reports an availability for the saved lobby outfit.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local LoggedErrorTextShortener = require("../../src/server/LoggedErrorTextShortener")
local PlayerSaveDataSnapshotPublisher = require("../../src/server/PlayerSaveDataSnapshotPublisher")
local PlayerSaveDataSnapshotPublisherTestHarness = require("./PlayerSaveDataSnapshotPublisherTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local createHarness = PlayerSaveDataSnapshotPublisherTestHarness.createHarness
local PLAYER_USER_ID = PlayerSaveDataSnapshotPublisherTestHarness.PLAYER_USER_ID
local OTHER_PLAYER_USER_ID = PlayerSaveDataSnapshotPublisherTestHarness.OTHER_PLAYER_USER_ID
local TODAYS_QUEST_IDS = PlayerSaveDataSnapshotPublisherTestHarness.TODAYS_QUEST_IDS
local PINK_TOP_KEY = PlayerSaveDataSnapshotPublisherTestHarness.PINK_TOP_KEY
local PINK_BAG_KEY = PlayerSaveDataSnapshotPublisherTestHarness.PINK_BAG_KEY
local HIDDEN_HAIR_KEY = FakeStylingItemPool.HIDDEN_HAIR_KEY
local FAKE_AVAILABLE_STYLING_ITEM_KEY_SET = FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET
local MAXIMUM_LOGGED_ERROR_TEXT_LENGTH = LoggedErrorTextShortener.MAXIMUM_LOGGED_ERROR_TEXT_LENGTH
local STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS = PlayerSaveDataSnapshotPublisher.STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS

local SENDING_FAILED_LOG_PREFIX = "PlayerSaveDataSnapshotPublisher: sending the snapshot to player 8801 failed: "
local BUILDING_FAILED_LOG_PREFIX = "PlayerSaveDataSnapshotPublisher: building the snapshot for player 8801 failed: "

-- error(text, 0) raises the text exactly, without a position prefix.
local function makeSenderRaiseExactly(harness, errorText: string)
	harness.afterEverySend = function()
		error(errorText, 0)
	end
end

describe("PlayerSaveDataSnapshotPublisher with a sender that raises", function()
	it("a sender that raises for one player disturbs neither the keeper nor the other player", function()
		local harness = createHarness()
		harness.senderRaisesForPlayerUserIdSet[PLAYER_USER_ID] = true
		harness.loadPlayer(PLAYER_USER_ID)
		harness.loadPlayer(OTHER_PLAYER_USER_ID)
		local grantOutcome = harness.redeemPromoCode(PLAYER_USER_ID, "spring_code", 50)
		expect(grantOutcome.rewardLedgerOutcome).toBe("Granted")
		expect(harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER_USER_ID).starCoinBalance).toBe(50)
		harness.redeemPromoCode(OTHER_PLAYER_USER_ID, "spring_code", 70)
		expect(harness.countSnapshotMessagesSentTo(OTHER_PLAYER_USER_ID)).toBe(2)
		expect(harness.readLastSnapshotMessageSentTo(OTHER_PLAYER_USER_ID).starCoinBalance).toBe(70)
		expect(#harness.publisherLogger.loggedWarnings).toBe(2)
		expect(string.find(harness.publisherLogger.loggedWarnings[1], SENDING_FAILED_LOG_PREFIX, 1, true)).toBe(1)
		expect(string.find(harness.publisherLogger.loggedWarnings[1], "fake sender failure", 1, true) ~= nil).toBeTrue()
	end)

	it("after a failed send the same message is sent again at the next chance (no suppression)", function()
		local harness = createHarness({ isCatalogLeftNotReady = true })
		harness.senderRaisesForPlayerUserIdSet[PLAYER_USER_ID] = true
		harness.loadPlayer(PLAYER_USER_ID)
		harness.senderRaisesForPlayerUserIdSet[PLAYER_USER_ID] = nil
		-- The catalog becoming ready changes nothing in this player's message.
		harness.fakeResolver:publishWardrobeCatalog(FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
		local snapshotMessages = harness.listSnapshotMessagesSentTo(PLAYER_USER_ID)
		expect(#snapshotMessages).toBe(2)
		expect(snapshotMessages[2]).toEqual(snapshotMessages[1])
	end)
end)

describe("PlayerSaveDataSnapshotPublisher bounded log lines", function()
	it("logs a sender error of exactly the limit in full", function()
		local harness = createHarness()
		local errorText = string.rep("x", MAXIMUM_LOGGED_ERROR_TEXT_LENGTH)
		makeSenderRaiseExactly(harness, errorText)
		harness.loadPlayer(PLAYER_USER_ID)
		expect(harness.publisherLogger.loggedWarnings).toEqual({ SENDING_FAILED_LOG_PREFIX .. errorText })
	end)

	it("cuts a sender error one character over the limit to exactly the limit", function()
		local harness = createHarness()
		local errorText = string.rep("x", MAXIMUM_LOGGED_ERROR_TEXT_LENGTH) .. "y"
		makeSenderRaiseExactly(harness, errorText)
		harness.loadPlayer(PLAYER_USER_ID)
		expect(harness.publisherLogger.loggedWarnings).toEqual({
			SENDING_FAILED_LOG_PREFIX .. string.rep("x", MAXIMUM_LOGGED_ERROR_TEXT_LENGTH) .. "...(cut)",
		})
	end)

	it("cuts a very long sender error", function()
		local harness = createHarness()
		makeSenderRaiseExactly(harness, string.rep("x", 5000))
		harness.loadPlayer(PLAYER_USER_ID)
		expect(harness.publisherLogger.loggedWarnings).toEqual({
			SENDING_FAILED_LOG_PREFIX .. string.rep("x", MAXIMUM_LOGGED_ERROR_TEXT_LENGTH) .. "...(cut)",
		})
	end)

	it("a failure while building is logged, cut, with the player, and sends nothing", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.fakeClock.getCurrentUnixSeconds = function()
			error(string.rep("c", 5000), 0)
		end
		harness.equipDance(PLAYER_USER_ID, "starter_step")
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
		expect(harness.publisherLogger.loggedWarnings).toEqual({
			BUILDING_FAILED_LOG_PREFIX .. string.rep("c", MAXIMUM_LOGGED_ERROR_TEXT_LENGTH) .. "...(cut)",
		})
	end)
end)

describe("PlayerSaveDataSnapshotPublisher when the stored-outfit availability never catches up", function()
	it("the outfit keeper fails while handling the load: one message after the wait, then one per change", function()
		local harness = createHarness()
		harness.makeCatalogReadinessQueriesRaise()
		harness.loadPlayerWithStoredLobbyOutfit(PLAYER_USER_ID, { HIDDEN_HAIR_KEY, PINK_TOP_KEY })
		expect(harness.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(PLAYER_USER_ID)).toBeNil()
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(0)
		harness.advanceSeconds(STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS - 0.001)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(0)
		harness.advanceSeconds(0.001)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
		-- The "nothing known about hidden items" picture: the hidden key is not listed.
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID)).toEqual(
			harness.buildExpectedSnapshotMessage(PLAYER_USER_ID, {}, TODAYS_QUEST_IDS)
		)
		expect(#harness.publisherLogger.loggedWarnings).toBe(1)
		expect(harness.publisherLogger.loggedWarnings[1]).toBe(
			"PlayerSaveDataSnapshotPublisher: the stored lobby outfit availability for player 8801 is missing after "
				.. "waiting 1 s; sending snapshots with no unavailable keys"
		)

		harness.redeemPromoCode(PLAYER_USER_ID, "spring_code", 50)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1) -- held again
		harness.advanceSeconds(STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(2)
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID).starCoinBalance).toBe(50)
		expect(#harness.publisherLogger.loggedWarnings).toBe(1) -- once per session
	end)

	it("one re-check covers every message held back meanwhile", function()
		local harness = createHarness()
		harness.makeCatalogReadinessQueriesRaise()
		harness.loadPlayer(PLAYER_USER_ID)
		local pendingCallbackCountAfterLoad = harness.fakeScheduler:getPendingCallbackCount()
		harness.equipDance(PLAYER_USER_ID, "starter_step") -- an appearance change schedules no save
		harness.equipDance(PLAYER_USER_ID, "starter_wave")
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(pendingCallbackCountAfterLoad)
		harness.advanceSeconds(STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID).equippedDanceId).toBe("starter_wave")
	end)

	it("the outfit keeper was never started: the load message still arrives after the wait", function()
		local harness = createHarness({ isStoredLobbyOutfitKeeperLeftUnstarted = true })
		harness.loadPlayer(PLAYER_USER_ID, function(storedSaveData)
			storedSaveData.starCoinBalance = 40
		end)
		harness.advanceSeconds(STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID).starCoinBalance).toBe(40)
		expect(#harness.publisherLogger.loggedWarnings).toBe(1)
	end)

	it("an availability left describing another lobby outfit falls back after the wait", function()
		local harness = createHarness()
		harness.loadPlayerWithStoredLobbyOutfit(PLAYER_USER_ID, { HIDDEN_HAIR_KEY })
		harness.makeCatalogReadinessQueriesRaise() -- the outfit keeper now fails on every change
		harness.setLobbyOutfit(PLAYER_USER_ID, { PINK_BAG_KEY })
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
		harness.advanceSeconds(STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(2)
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID)).toEqual(
			harness.buildExpectedSnapshotMessage(PLAYER_USER_ID, {}, TODAYS_QUEST_IDS)
		)
		expect(#harness.publisherLogger.loggedWarnings).toBe(1)
		expect(
			string.find(harness.publisherLogger.loggedWarnings[1], "is for another lobby outfit after", 1, true) ~= nil
		).toBeTrue()
	end)

	it("once the outfit keeper catches up, messages carry its unavailable keys again at once", function()
		local harness = createHarness()
		harness.loadPlayerWithStoredLobbyOutfit(PLAYER_USER_ID, { PINK_TOP_KEY })
		harness.makeCatalogReadinessQueriesRaise()
		harness.setLobbyOutfit(PLAYER_USER_ID, { PINK_BAG_KEY })
		harness.advanceSeconds(STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS) -- the fallback message
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(2)
		harness.makeCatalogReadinessQueriesWorkAgain()
		harness.setLobbyOutfit(PLAYER_USER_ID, { HIDDEN_HAIR_KEY, PINK_TOP_KEY })
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(3) -- no wait
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID)).toEqual(
			harness.buildExpectedSnapshotMessage(PLAYER_USER_ID, { HIDDEN_HAIR_KEY }, TODAYS_QUEST_IDS)
		)
		expect(#harness.publisherLogger.loggedWarnings).toBe(1)
	end)

	it("a re-check scheduled for an old session never sends for the new session early", function()
		local harness = createHarness()
		harness.makeCatalogReadinessQueriesRaise()
		harness.loadPlayer(PLAYER_USER_ID) -- held; re-check due at +1 s
		harness.advanceSeconds(STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS / 2)
		harness.leaveAndFinishFinalSave(PLAYER_USER_ID)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER_USER_ID) -- held; its re-check at +1.5 s
		harness.advanceSeconds(STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS / 2) -- the old re-check runs now
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(0)
		harness.advanceSeconds(STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS / 2)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
	end)

	it("in the normal load orders the wait passes without a message or a warning", function()
		for _, subscriptionOrder in { "PublisherFirst", "StoredLobbyOutfitKeeperFirst" } do
			local harness = createHarness({ subscriptionOrder = subscriptionOrder :: any })
			harness.loadPlayerWithStoredLobbyOutfit(PLAYER_USER_ID, { HIDDEN_HAIR_KEY, PINK_TOP_KEY })
			harness.setLobbyOutfit(PLAYER_USER_ID, { PINK_BAG_KEY })
			harness.advanceSeconds(STORED_OUTFIT_AVAILABILITY_WAIT_SECONDS)
			expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(2)
			expect(harness.publisherLogger.loggedWarnings).toEqual({})
		end
	end)
end)
