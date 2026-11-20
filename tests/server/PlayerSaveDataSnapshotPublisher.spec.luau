-- PlayerSaveDataSnapshotPublisher (development spec v1.3 §2.6, §2.13): what is sent and when, with
-- the REAL PlayerSaveDataKeeper, StoredLobbyOutfitKeeper and RewardLedger on fake storage, clock
-- and scheduler, and the fake catalog resolver.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local DailyQuestTestCatalog = require("../fixtures/DailyQuestTestCatalog")
local StandInPlayerSaveDataKeeper = require("../Support/StandInPlayerSaveDataKeeper")
local PlayerSaveDataSnapshotPublisher = require("../../src/server/PlayerSaveDataSnapshotPublisher")
local PlayerSaveDataSnapshotPublisherTestHarness = require("./PlayerSaveDataSnapshotPublisherTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local createHarness = PlayerSaveDataSnapshotPublisherTestHarness.createHarness
local PLAYER_USER_ID = PlayerSaveDataSnapshotPublisherTestHarness.PLAYER_USER_ID
local OTHER_PLAYER_USER_ID = PlayerSaveDataSnapshotPublisherTestHarness.OTHER_PLAYER_USER_ID
local TODAYS_QUEST_IDS = PlayerSaveDataSnapshotPublisherTestHarness.TODAYS_QUEST_IDS
local PINK_TOP_KEY = PlayerSaveDataSnapshotPublisherTestHarness.PINK_TOP_KEY
local WHITE_SHOES_KEY = PlayerSaveDataSnapshotPublisherTestHarness.WHITE_SHOES_KEY
local PINK_BAG_KEY = PlayerSaveDataSnapshotPublisherTestHarness.PINK_BAG_KEY
local HIDDEN_HAIR_KEY = FakeStylingItemPool.HIDDEN_HAIR_KEY
local FAKE_AVAILABLE_STYLING_ITEM_KEY_SET = FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET

local SPEC_SNAPSHOT_MESSAGE_FIELD_NAMES = {
	"fanCount",
	"starCoinBalance",
	"ownedDanceIds",
	"equippedDanceId",
	"ownedCosmeticIds",
	"equippedCosmeticIdByKind",
	"lobbyOutfitStylingItemKeys",
	"unavailableLobbyOutfitStylingItemKeys",
	"dailyProgress",
	"todaysDailyQuestIds",
	"isSaveDataPersistenceDelayed",
}

local function listSortedKeys(inspectedTable: { [any]: any }): { string }
	local sortedKeys = {}
	for tableKey in inspectedTable do
		table.insert(sortedKeys, tostring(tableKey))
	end
	table.sort(sortedKeys)
	return sortedKeys
end

local function expectLastMessageMatchesServerState(harness, playerUserId: number)
	expect(harness.readLastSnapshotMessageSentTo(playerUserId)).toEqual(
		harness.buildExpectedSnapshotMessage(playerUserId, {}, TODAYS_QUEST_IDS)
	)
end

describe("PlayerSaveDataSnapshotPublisher at load", function()
	it("sends exactly one message when the save has loaded, with exactly the §2.6 keys", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID, function(storedSaveData)
			storedSaveData.fanCount = 1200
			storedSaveData.starCoinBalance = 350
			storedSaveData.redeemedPromoCodeIds = { "old_code" }
			storedSaveData.totalRoundsCompletedCount = 14
		end)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
		local snapshotMessage = harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID)
		local expectedKeys = table.clone(SPEC_SNAPSHOT_MESSAGE_FIELD_NAMES)
		table.sort(expectedKeys)
		expect(listSortedKeys(snapshotMessage)).toEqual(expectedKeys)
		expect(snapshotMessage.fanCount).toBe(1200)
		expect(snapshotMessage.starCoinBalance).toBe(350)
		expect(snapshotMessage.ownedCosmeticIds).toEqual({ "cosmetic_sparkle_trail" })
		expect(snapshotMessage.todaysDailyQuestIds).toEqual(TODAYS_QUEST_IDS)
		expect(snapshotMessage.isSaveDataPersistenceDelayed).toBeFalse()
		expectLastMessageMatchesServerState(harness, PLAYER_USER_ID)
	end)

	it("sends nothing while the save is still loading", function()
		local harness = createHarness()
		harness.fakePlayerSaveDataStorage:setCompletesOperationsImmediately(false)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER_USER_ID)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(0)
		expect(harness.publisher:isPublishingToPlayer(PLAYER_USER_ID)).toBeFalse()
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER_USER_ID)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
		expect(harness.publisher:isPublishingToPlayer(PLAYER_USER_ID)).toBeTrue()
	end)
end)

describe("PlayerSaveDataSnapshotPublisher after changes", function()
	it("sends the new balance after a ledger grant", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.redeemPromoCode(PLAYER_USER_ID, "spring_code", 300)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(2)
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID).starCoinBalance).toBe(300)
		expectLastMessageMatchesServerState(harness, PLAYER_USER_ID)
	end)

	it("sends fans and Star Coins after a themed round reward", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.grantThemedRoundReward(PLAYER_USER_ID, "round-1", 4)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(2)
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID).fanCount > 0).toBeTrue()
		expectLastMessageMatchesServerState(harness, PLAYER_USER_ID)
	end)

	it("sends the new balance and ownership after a ledger spend", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID, function(storedSaveData)
			storedSaveData.starCoinBalance = 500
		end)
		harness.purchaseDance(PLAYER_USER_ID, "neon_spin", 200)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(2)
		local snapshotMessage = harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID)
		expect(snapshotMessage.starCoinBalance).toBe(300)
		expect(snapshotMessage.ownedDanceIds).toContain("neon_spin")
		expectLastMessageMatchesServerState(harness, PLAYER_USER_ID)
	end)

	it("sends nothing for a declined spend (nothing changed)", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.purchaseDance(PLAYER_USER_ID, "neon_spin", 200) -- balance 0: InsufficientStarCoins
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
	end)

	it("sends after an equip of a dance and of a cosmetic", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.equipDance(PLAYER_USER_ID, "starter_step")
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(2)
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID).equippedDanceId).toBe("starter_step")
		harness.equipCosmetic(PLAYER_USER_ID, "trail", "cosmetic_sparkle_trail")
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(3)
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID).equippedCosmeticIdByKind).toEqual({
			trail = "cosmetic_sparkle_trail",
		})
		expectLastMessageMatchesServerState(harness, PLAYER_USER_ID)
	end)

	it("sends exactly one message after a lobby outfit change", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.setLobbyOutfit(PLAYER_USER_ID, { PINK_TOP_KEY, WHITE_SHOES_KEY })
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(2)
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID).lobbyOutfitStylingItemKeys).toEqual({
			PINK_TOP_KEY,
			WHITE_SHOES_KEY,
		})
		expectLastMessageMatchesServerState(harness, PLAYER_USER_ID)
	end)

	it("sends when persistence becomes delayed and again when it recovers", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.failEverySaveUntilPersistenceDelayed(PLAYER_USER_ID) -- includes one grant
		local snapshotMessages = harness.listSnapshotMessagesSentTo(PLAYER_USER_ID)
		expect(#snapshotMessages).toBe(3)
		expect(snapshotMessages[2].isSaveDataPersistenceDelayed).toBeFalse()
		expect(snapshotMessages[3].isSaveDataPersistenceDelayed).toBeTrue()
		expect(snapshotMessages[3].starCoinBalance).toBe(snapshotMessages[2].starCoinBalance)
		harness.letNextPeriodicSaveSucceed(PLAYER_USER_ID)
		snapshotMessages = harness.listSnapshotMessagesSentTo(PLAYER_USER_ID)
		expect(#snapshotMessages).toBe(4)
		expect(snapshotMessages[4].isSaveDataPersistenceDelayed).toBeFalse()
		expectLastMessageMatchesServerState(harness, PLAYER_USER_ID)
	end)

	it("a change made while persistence is delayed carries the delayed flag", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.failEverySaveUntilPersistenceDelayed(PLAYER_USER_ID)
		harness.equipDance(PLAYER_USER_ID, "starter_step")
		local snapshotMessage = harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID)
		expect(snapshotMessage.equippedDanceId).toBe("starter_step")
		expect(snapshotMessage.isSaveDataPersistenceDelayed).toBeTrue()
	end)
end)

describe("PlayerSaveDataSnapshotPublisher suppression of identical messages (§2.13)", function()
	it("sends nothing for an equip of what is already equipped", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.equipDance(PLAYER_USER_ID, "starter_wave")
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
	end)

	it("sends nothing for setting the lobby outfit to the current one", function()
		local harness = createHarness()
		harness.loadPlayerWithStoredLobbyOutfit(PLAYER_USER_ID, { PINK_TOP_KEY })
		harness.setLobbyOutfit(PLAYER_USER_ID, { PINK_TOP_KEY })
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
	end)

	it("sends nothing when a save succeeds with persistence never delayed", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.advanceSeconds(3 * 120)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
	end)

	it("every 'save loaded' starts from a device that has been sent nothing", function()
		-- A keeper whose "session ended" never reaches the publisher: the second load must still
		-- send its first message even though it equals the last one sent before.
		local harness = createHarness()
		local sentSnapshotMessages = {}
		PlayerSaveDataSnapshotPublisher.new({
			playerSaveDataKeeper = StandInPlayerSaveDataKeeper.new(harness.playerSaveDataKeeper, {
				subscribeToPlayerSaveDataSessionEnded = function()
					return function() end
				end,
			}),
			storedLobbyOutfitKeeper = harness.storedLobbyOutfitKeeper,
			clock = harness.fakeClock,
			scheduler = harness.fakeScheduler,
			dailyQuestCatalogEntries = DailyQuestTestCatalog.SIX_TEST_DAILY_QUESTS,
			sendPlayerSaveDataSnapshotToPlayer = function(_, snapshotMessage)
				table.insert(sentSnapshotMessages, snapshotMessage)
			end,
			logger = { logInformation = function() end, logWarning = function() end },
		}):startPublishingPlayerSaveDataSnapshots()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.leaveAndFinishFinalSave(PLAYER_USER_ID)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(PLAYER_USER_ID)
		expect(#sentSnapshotMessages).toBe(2)
		expect(sentSnapshotMessages[2]).toEqual(sentSnapshotMessages[1])
	end)
end)

describe("PlayerSaveDataSnapshotPublisher isolation between players", function()
	it("sends each player's message only to that player", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID, function(storedSaveData)
			storedSaveData.starCoinBalance = 111
		end)
		harness.loadPlayer(OTHER_PLAYER_USER_ID, function(storedSaveData)
			storedSaveData.starCoinBalance = 222
		end)
		harness.redeemPromoCode(OTHER_PLAYER_USER_ID, "other_code", 8)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
		expect(harness.countSnapshotMessagesSentTo(OTHER_PLAYER_USER_ID)).toBe(2)
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID).starCoinBalance).toBe(111)
		expect(harness.readLastSnapshotMessageSentTo(OTHER_PLAYER_USER_ID).starCoinBalance).toBe(230)
	end)
end)

describe("PlayerSaveDataSnapshotPublisher message ownership", function()
	it("a sender that modifies its message changes neither the keeper nor later messages", function()
		local harness = createHarness()
		harness.afterEverySend = function(_, snapshotMessage)
			snapshotMessage.starCoinBalance = -1
			table.insert(snapshotMessage.ownedDanceIds, "stolen_dance")
			snapshotMessage.dailyProgress.playtimeSecondsToday = 999999
			table.clear(snapshotMessage.todaysDailyQuestIds)
		end
		harness.loadPlayer(PLAYER_USER_ID)
		harness.equipDance(PLAYER_USER_ID, "starter_step")
		harness.afterEverySend = nil
		harness.redeemPromoCode(PLAYER_USER_ID, "spring_code", 10)
		expectLastMessageMatchesServerState(harness, PLAYER_USER_ID)
		local inMemorySaveData = harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER_USER_ID)
		expect(inMemorySaveData.starCoinBalance).toBe(10)
		expect(table.find(inMemorySaveData.ownedDanceIds, "stolen_dance")).toBeNil()
	end)

	it("suppression compares against a private copy the sender cannot modify, nested tables included", function()
		local harness = createHarness({ isCatalogLeftNotReady = true })
		harness.afterEverySend = function(_, snapshotMessage)
			snapshotMessage.fanCount = 123456
			table.insert(snapshotMessage.ownedDanceIds, "stolen_dance")
			snapshotMessage.dailyProgress.playtimeSecondsToday = 999999
			table.clear(snapshotMessage.todaysDailyQuestIds)
			table.insert(snapshotMessage.lobbyOutfitStylingItemKeys, "asset_1")
			table.insert(snapshotMessage.unavailableLobbyOutfitStylingItemKeys, "asset_2")
			snapshotMessage.equippedCosmeticIdByKind.trail = "cosmetic_stolen"
		end
		harness.loadPlayerWithStoredLobbyOutfit(PLAYER_USER_ID, { PINK_TOP_KEY })
		-- Readiness changes the stored-outfit availability but not this player's message.
		harness.fakeResolver:publishWardrobeCatalog(FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
	end)

	it("a change the sender itself causes while sending is compared against the message being sent", function()
		-- The record of the last message is written before the sender runs; written after, the
		-- outer send would overwrite the nested one and a later change back would be suppressed.
		local harness = createHarness()
		local inconsistencyDescriptions = harness.recordMessagesInconsistentWithServerStateAtSendTime()
		local recordInconsistency = harness.afterEverySend
		local hasEquippedDuringSend = false
		harness.loadPlayer(PLAYER_USER_ID)
		harness.afterEverySend = function(playerUserId, snapshotMessage)
			recordInconsistency(playerUserId, snapshotMessage)
			if not hasEquippedDuringSend then
				hasEquippedDuringSend = true
				harness.equipDance(PLAYER_USER_ID, "starter_step")
			end
		end
		harness.redeemPromoCode(PLAYER_USER_ID, "spring_code", 5)
		harness.equipDance(PLAYER_USER_ID, "starter_wave")
		local snapshotMessages = harness.listSnapshotMessagesSentTo(PLAYER_USER_ID)
		expect(#snapshotMessages).toBe(4)
		expect(snapshotMessages[3].equippedDanceId).toBe("starter_step")
		expect(snapshotMessages[4].equippedDanceId).toBe("starter_wave")
		expect(snapshotMessages[4].starCoinBalance).toBe(5)
		expectLastMessageMatchesServerState(harness, PLAYER_USER_ID)
		expect(inconsistencyDescriptions).toEqual({})
	end)

	it("every message is a new table", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.equipDance(PLAYER_USER_ID, "starter_step")
		harness.equipDance(PLAYER_USER_ID, "starter_wave")
		local snapshotMessages = harness.listSnapshotMessagesSentTo(PLAYER_USER_ID)
		expect(#snapshotMessages).toBe(3)
		expect(snapshotMessages[1] == snapshotMessages[3]).toBeFalse()
		expect(snapshotMessages[1].ownedDanceIds == snapshotMessages[3].ownedDanceIds).toBeFalse()
		expect(snapshotMessages[1].dailyProgress == snapshotMessages[3].dailyProgress).toBeFalse()
		expect(snapshotMessages[1]).toEqual(snapshotMessages[3])
	end)

	it("sends a lobby outfit change that adds a hidden key with that key listed", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.setLobbyOutfit(PLAYER_USER_ID, { HIDDEN_HAIR_KEY, PINK_BAG_KEY })
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(2)
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID)).toEqual(
			harness.buildExpectedSnapshotMessage(PLAYER_USER_ID, { HIDDEN_HAIR_KEY }, TODAYS_QUEST_IDS)
		)
	end)
end)
