-- PlayerSaveDataSnapshotPublisher under random sequences of loads, grants, spends, equips, lobby
-- outfit changes, catalog changes, failing saves, passing days and players leaving, in a random
-- subscription order (development spec v1.3 §2.6, §2.13). After every step, for every player:
--   * every message equalled the server's state at the moment it was sent;
--   * the last message sent to an online player equals the server's state now;
--   * no message repeats the previous one of the same session;
--   * a player who has left is sent nothing more.
-- Failures print the seed (tests/fixtures/SeededRandomTrials.luau).

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local PlayerSaveDataSnapshotPublisherTestHarness = require("./PlayerSaveDataSnapshotPublisherTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_USER_IDS = { 8801, 8802, 8803 }
local STORED_OUTFIT_CANDIDATE_KEYS = {
	PlayerSaveDataSnapshotPublisherTestHarness.PINK_TOP_KEY,
	PlayerSaveDataSnapshotPublisherTestHarness.BLACK_BOTTOM_KEY,
	PlayerSaveDataSnapshotPublisherTestHarness.WHITE_SHOES_KEY,
	PlayerSaveDataSnapshotPublisherTestHarness.PINK_BAG_KEY,
	FakeStylingItemPool.HIDDEN_HAIR_KEY,
	FakeStylingItemPool.KEY_NOT_IN_POOL,
	FakeStylingItemPool.DISABLED_HAIR_KEY,
}
local DANCE_IDS = { "starter_wave", "starter_step", "neon_spin", "moon_glide" }
local STEP_COUNT_PER_TRIAL = 30

local function pickRandomKeySubset(randomNumberGenerator, candidateKeys: { string }): { string }
	local shuffledKeys = table.clone(candidateKeys)
	randomNumberGenerator.shuffleListInPlace(shuffledKeys)
	local pickedKeys = {}
	for keyIndex = 1, randomNumberGenerator.nextWholeNumberInRange(0, 3) do
		table.insert(pickedKeys, shuffledKeys[keyIndex])
	end
	return pickedKeys
end

local function createRandomCatalogKeySet(randomNumberGenerator)
	local availableStylingItemKeySet = table.clone(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
	if randomNumberGenerator.nextWholeNumberInRange(0, 1) == 1 then
		availableStylingItemKeySet[FakeStylingItemPool.HIDDEN_HAIR_KEY] = true
	end
	if randomNumberGenerator.nextWholeNumberInRange(0, 1) == 1 then
		availableStylingItemKeySet[PlayerSaveDataSnapshotPublisherTestHarness.PINK_BAG_KEY] = nil
	end
	return availableStylingItemKeySet
end

local function runOneRandomStep(harness, randomNumberGenerator, playerUserId: number)
	local isLoaded = harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId)
	local stepKind = randomNumberGenerator.nextWholeNumberInRange(1, 9)
	if not isLoaded then
		if not harness.publisher:isPublishingToPlayer(playerUserId) and stepKind <= 4 then
			harness.fakePlayerSaveDataStorage:failNextStartedOperations(0)
			harness.loadPlayer(playerUserId, function(storedSaveData)
				storedSaveData.starCoinBalance = randomNumberGenerator.nextWholeNumberInRange(0, 600)
				storedSaveData.lobbyOutfitStylingItemKeys =
					pickRandomKeySubset(randomNumberGenerator, STORED_OUTFIT_CANDIDATE_KEYS)
			end)
			return "load"
		end
		stepKind = 7 -- only shared steps for a player who is not online
	end
	if stepKind == 1 then
		harness.redeemPromoCode(
			playerUserId,
			"code_" .. tostring(randomNumberGenerator.nextWholeNumberInRange(1, 4)),
			40
		)
	elseif stepKind == 2 then
		harness.purchaseDance(playerUserId, randomNumberGenerator.pickRandomListElement(DANCE_IDS), 150)
	elseif stepKind == 3 then
		harness.equipDance(playerUserId, randomNumberGenerator.pickRandomListElement(DANCE_IDS))
	elseif stepKind == 4 then
		harness.setLobbyOutfit(playerUserId, pickRandomKeySubset(randomNumberGenerator, STORED_OUTFIT_CANDIDATE_KEYS))
	elseif stepKind == 5 then
		harness.fakePlayerSaveDataStorage:failNextStartedOperations(randomNumberGenerator.nextWholeNumberInRange(0, 4))
		harness.redeemPromoCode(
			playerUserId,
			"code_" .. tostring(randomNumberGenerator.nextWholeNumberInRange(5, 99)),
			1
		)
	elseif stepKind == 6 then
		harness.fakeResolver:publishWardrobeCatalog(createRandomCatalogKeySet(randomNumberGenerator))
	elseif stepKind == 7 then
		harness.advanceSeconds(randomNumberGenerator.nextWholeNumberInRange(1, 9000))
	elseif stepKind == 8 then
		harness.fakePlayerSaveDataStorage:failNextStartedOperations(0)
		harness.leaveAndFinishFinalSave(playerUserId)
	else
		harness.advanceSeconds(randomNumberGenerator.nextWholeNumberInRange(1, 30))
	end
	return tostring(stepKind)
end

describe("PlayerSaveDataSnapshotPublisher randomized sequences", function()
	it("every message is the server's state when sent; the last one is the state now", function()
		SeededRandomTrials.runSeededRandomTrials(60, function(randomNumberGenerator)
			local harness = PlayerSaveDataSnapshotPublisherTestHarness.createHarness({
				subscriptionOrder = if randomNumberGenerator.nextWholeNumberInRange(0, 1) == 1
					then "PublisherFirst"
					else "StoredLobbyOutfitKeeperFirst",
				isCatalogLeftNotReady = randomNumberGenerator.nextWholeNumberInRange(0, 1) == 1,
			})
			local inconsistencyDescriptions = harness.recordMessagesInconsistentWithServerStateAtSendTime()
			-- Index of the first message of each player's current session.
			local sessionFirstMessageIndexByPlayerUserId = {}
			local sentCountWhenLeftByPlayerUserId = {}
			local stepHistory = {}

			for _ = 1, STEP_COUNT_PER_TRIAL do
				local playerUserId = randomNumberGenerator.pickRandomListElement(PLAYER_USER_IDS)
				local sentCountBeforeStep = harness.countSnapshotMessagesSentTo(playerUserId)
				local stepDescription = runOneRandomStep(harness, randomNumberGenerator, playerUserId)
				table.insert(stepHistory, tostring(playerUserId) .. ":" .. stepDescription)
				if stepDescription == "load" then
					sessionFirstMessageIndexByPlayerUserId[playerUserId] = sentCountBeforeStep + 1
					sentCountWhenLeftByPlayerUserId[playerUserId] = nil
				end
				expect({ stepHistory, inconsistencyDescriptions }).toEqual({ stepHistory, {} })

				for _, checkedPlayerUserId in PLAYER_USER_IDS do
					local snapshotMessages = harness.listSnapshotMessagesSentTo(checkedPlayerUserId)
					if harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(checkedPlayerUserId) then
						expect({ stepHistory, snapshotMessages[#snapshotMessages] }).toEqual({
							stepHistory,
							harness.buildExpectedSnapshotMessageForCurrentServerState(checkedPlayerUserId),
						})
						local firstIndex = sessionFirstMessageIndexByPlayerUserId[checkedPlayerUserId]
						for messageIndex = firstIndex + 1, #snapshotMessages do
							local isRepeat = PlayerSaveDataSchema.arePlainValuesDeeplyEqual(
								snapshotMessages[messageIndex],
								snapshotMessages[messageIndex - 1]
							)
							expect({ stepHistory, messageIndex, isRepeat }).toEqual({ stepHistory, messageIndex, false })
						end
					else
						local sentCountWhenLeft = sentCountWhenLeftByPlayerUserId[checkedPlayerUserId]
						if sentCountWhenLeft == nil then
							sentCountWhenLeftByPlayerUserId[checkedPlayerUserId] = #snapshotMessages
						else
							expect({ stepHistory, #snapshotMessages }).toEqual({ stepHistory, sentCountWhenLeft })
						end
					end
				end
			end
		end)
	end)
end)
