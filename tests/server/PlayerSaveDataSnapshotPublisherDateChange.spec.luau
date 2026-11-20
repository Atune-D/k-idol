-- PlayerSaveDataSnapshotPublisher: today's quests when the UTC date changes while a player is
-- online (development spec v1.3 §1.8, §2.6), and the midnight fan-out to every online player.

local UnitTestFramework = require("../Support/UnitTestFramework")
local PlayerSaveDataSnapshotPublisherTestHarness = require("./PlayerSaveDataSnapshotPublisherTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local createHarness = PlayerSaveDataSnapshotPublisherTestHarness.createHarness
local PLAYER_USER_ID = PlayerSaveDataSnapshotPublisherTestHarness.PLAYER_USER_ID
local OTHER_PLAYER_USER_ID = PlayerSaveDataSnapshotPublisherTestHarness.OTHER_PLAYER_USER_ID
local LEAVING_PLAYER_USER_ID = 9903
local TODAYS_QUEST_IDS = PlayerSaveDataSnapshotPublisherTestHarness.TODAYS_QUEST_IDS
local TOMORROWS_QUEST_IDS = PlayerSaveDataSnapshotPublisherTestHarness.TOMORROWS_QUEST_IDS
local SECONDS_UNTIL_NEXT_UTC_MIDNIGHT = PlayerSaveDataSnapshotPublisherTestHarness.SECONDS_UNTIL_NEXT_UTC_MIDNIGHT

describe("PlayerSaveDataSnapshotPublisher when the UTC date changes", function()
	it("the pinned quest lists of the two test days differ (precondition)", function()
		expect(TODAYS_QUEST_IDS).toEqual({ "quest_a", "quest_d", "quest_e" })
		expect(TOMORROWS_QUEST_IDS).toEqual({ "quest_f", "quest_e", "quest_a" })
	end)

	it("sends the new day's quests to an online player at UTC midnight, not before", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.advanceSeconds(SECONDS_UNTIL_NEXT_UTC_MIDNIGHT - 0.001)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(1)
		harness.advanceSeconds(0.001)
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(2)
		local snapshotMessage = harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID)
		expect(snapshotMessage.todaysDailyQuestIds).toEqual(TOMORROWS_QUEST_IDS)
		-- The save's own dailyProgress is sent as the save holds it (the daily reset of an online
		-- player's save is not this module's job).
		expect(snapshotMessage.dailyProgress).toEqual(
			harness.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER_USER_ID).dailyProgress
		)
		expect(snapshotMessage.dailyProgress.dailyDateKey).toBe("2026-11-19")
	end)

	it("sends it to every online player and to nobody who left", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.loadPlayer(OTHER_PLAYER_USER_ID)
		harness.loadPlayer(LEAVING_PLAYER_USER_ID)
		harness.leaveAndFinishFinalSave(LEAVING_PLAYER_USER_ID)
		harness.advanceSeconds(SECONDS_UNTIL_NEXT_UTC_MIDNIGHT)
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID).todaysDailyQuestIds).toEqual(TOMORROWS_QUEST_IDS)
		expect(harness.readLastSnapshotMessageSentTo(OTHER_PLAYER_USER_ID).todaysDailyQuestIds).toEqual(
			TOMORROWS_QUEST_IDS
		)
		expect(harness.countSnapshotMessagesSentTo(LEAVING_PLAYER_USER_ID)).toBe(1)
	end)

	it("a sender that raises for one player at midnight does not stop the others", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.loadPlayer(OTHER_PLAYER_USER_ID)
		harness.senderRaisesForPlayerUserIdSet[PLAYER_USER_ID] = true
		harness.advanceSeconds(SECONDS_UNTIL_NEXT_UTC_MIDNIGHT)
		expect(harness.readLastSnapshotMessageSentTo(OTHER_PLAYER_USER_ID).todaysDailyQuestIds).toEqual(
			TOMORROWS_QUEST_IDS
		)
	end)

	it("keeps sending at each following midnight", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.advanceSeconds(SECONDS_UNTIL_NEXT_UTC_MIDNIGHT + 86400)
		local expectedThirdDayQuestIds =
			harness.buildExpectedSnapshotMessageForCurrentServerState(PLAYER_USER_ID).todaysDailyQuestIds
		local snapshotMessages = harness.listSnapshotMessagesSentTo(PLAYER_USER_ID)
		expect(snapshotMessages[2].todaysDailyQuestIds).toEqual(TOMORROWS_QUEST_IDS)
		expect(snapshotMessages[#snapshotMessages].todaysDailyQuestIds).toEqual(expectedThirdDayQuestIds)
	end)

	it("a message sent just after midnight already carries the new quests; midnight adds no copy", function()
		local harness = createHarness()
		harness.loadPlayer(PLAYER_USER_ID)
		harness.fakeClock:advanceBySeconds(SECONDS_UNTIL_NEXT_UTC_MIDNIGHT + 1) -- scheduler not run yet
		harness.equipDance(PLAYER_USER_ID, "starter_step")
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(2)
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID).todaysDailyQuestIds).toEqual(TOMORROWS_QUEST_IDS)
		harness.advanceSeconds(0) -- the overdue midnight check runs now
		expect(harness.countSnapshotMessagesSentTo(PLAYER_USER_ID)).toBe(2)
	end)

	it("a player who loads after midnight gets the new day's quests at load", function()
		local harness = createHarness()
		harness.advanceSeconds(SECONDS_UNTIL_NEXT_UTC_MIDNIGHT + 60)
		harness.loadPlayer(PLAYER_USER_ID)
		expect(harness.readLastSnapshotMessageSentTo(PLAYER_USER_ID).todaysDailyQuestIds).toEqual(TOMORROWS_QUEST_IDS)
	end)
end)

describe("PlayerSaveDataSnapshotPublisher midnight fan-out", function()
	-- Ids whose hash order is not their numeric order.
	local FAN_OUT_PLAYER_USER_IDS = { 9001, 42, 777, 31337, 5 }
	local FIRST_NEW_PLAYER_USER_ID = 100000
	local NEW_PLAYER_COUNT = 40

	local function countMessagesSentAfter(harness, sentRecordCountBefore: number, playerUserId: number): number
		local sentCount = 0
		for recordIndex = sentRecordCountBefore + 1, #harness.sentSnapshotRecords do
			if harness.sentSnapshotRecords[recordIndex].playerUserId == playerUserId then
				sentCount += 1
			end
		end
		return sentCount
	end

	it("checks every player online at midnight once, in ascending user id order", function()
		local harness = createHarness()
		for _, playerUserId in FAN_OUT_PLAYER_USER_IDS do
			harness.loadPlayer(playerUserId)
		end
		local sentRecordCountBefore = #harness.sentSnapshotRecords
		harness.advanceSeconds(SECONDS_UNTIL_NEXT_UTC_MIDNIGHT)
		local midnightRecipientUserIds = {}
		for recordIndex = sentRecordCountBefore + 1, #harness.sentSnapshotRecords do
			table.insert(midnightRecipientUserIds, harness.sentSnapshotRecords[recordIndex].playerUserId)
		end
		expect(midnightRecipientUserIds).toEqual({ 5, 42, 777, 9001, 31337 })
	end)

	it("a sender that loads many players during the fan-out changes neither who is checked nor how often", function()
		local harness = createHarness()
		for _, playerUserId in FAN_OUT_PLAYER_USER_IDS do
			harness.loadPlayer(playerUserId)
		end
		local hasLoadedNewPlayers = false
		harness.afterEverySend = function()
			if hasLoadedNewPlayers then
				return
			end
			hasLoadedNewPlayers = true
			for newPlayerIndex = 1, NEW_PLAYER_COUNT do
				harness.loadPlayer(FIRST_NEW_PLAYER_USER_ID + newPlayerIndex)
			end
		end
		local sentRecordCountBefore = #harness.sentSnapshotRecords
		harness.advanceSeconds(SECONDS_UNTIL_NEXT_UTC_MIDNIGHT)
		for _, playerUserId in FAN_OUT_PLAYER_USER_IDS do
			expect(countMessagesSentAfter(harness, sentRecordCountBefore, playerUserId)).toBe(1)
			expect(harness.readLastSnapshotMessageSentTo(playerUserId).todaysDailyQuestIds).toEqual(TOMORROWS_QUEST_IDS)
		end
		for newPlayerIndex = 1, NEW_PLAYER_COUNT do
			local newPlayerUserId = FIRST_NEW_PLAYER_USER_ID + newPlayerIndex
			expect(harness.countSnapshotMessagesSentTo(newPlayerUserId)).toBe(1) -- its load message only
		end
		expect(harness.publisherLogger.loggedWarnings).toEqual({})
	end)

	it("a player who leaves during the fan-out, before their turn, is sent nothing", function()
		local harness = createHarness()
		for _, playerUserId in FAN_OUT_PLAYER_USER_IDS do
			harness.loadPlayer(playerUserId)
		end
		harness.afterEverySend = function(playerUserId)
			if playerUserId == 5 then
				harness.leaveAndFinishFinalSave(31337)
			end
		end
		harness.advanceSeconds(SECONDS_UNTIL_NEXT_UTC_MIDNIGHT)
		expect(harness.countSnapshotMessagesSentTo(31337)).toBe(1)
		expect(harness.countSnapshotMessagesSentTo(9001)).toBe(2)
		expect(harness.publisherLogger.loggedWarnings).toEqual({})
	end)
end)
