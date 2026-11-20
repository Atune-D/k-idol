local UnitTestFramework = require("../Support/UnitTestFramework")
local OutfitScoreCalculator = require("../../src/shared/OutfitScoreCalculator")
local RewardLedger = require("../../src/server/RewardLedger")
local RewardLedgerCrashableServerTestHarness = require("./RewardLedgerCrashableServerTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = RewardLedgerCrashableServerTestHarness.EXAMPLE_PLAYER_USER_ID
local OTHER_PLAYER = RewardLedgerCrashableServerTestHarness.OTHER_PLAYER_USER_ID
local createHarnessWithLoadedPlayer = RewardLedgerCrashableServerTestHarness.createHarnessWithLoadedPlayer

-- The "before" column of the spec §1.10 table.
local function giveExampleRoundHistory(saveData)
	saveData.starCoinBalance = 350
	saveData.fanCount = 1200
	saveData.totalRoundsCompletedCount = 14
	saveData.bestStarCountByThemeId = { y2k_pop = 3 }
end

local function createThemedRoundCompletion(roundId: string, themeId: string, starCount: number)
	return {
		roundId = roundId,
		themeId = themeId,
		starCount = starCount,
		scoredOutfitStylingItemKeys = { "asset_1001", "asset_1002" },
	}
end

describe("RewardLedger.grantThemedRoundReward", function()
	it("pays the spec §0.2 worked example: 4 stars, 350 -> 430 coins, 1200 -> 1240 fans, record updated", function()
		local _, server = createHarnessWithLoadedPlayer(giveExampleRoundHistory)
		local roundRewardOutcome =
			server.rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("round-1", "y2k_pop", 4))
		expect(roundRewardOutcome).toEqual({
			rewardLedgerOutcome = "Granted",
			starCoinsGranted = 80,
			fanCountGained = 40,
			starCoinBalanceAfterChange = 430,
			fanCountAfterChange = 1240,
			inMemoryChangeRevision = 1,
			isNewBestStarCountForTheme = true,
		})
		local saveData = server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
		expect(saveData.starCoinBalance).toBe(430)
		expect(saveData.fanCount).toBe(1240)
		expect(saveData.totalRoundsCompletedCount).toBe(15)
		expect(saveData.bestStarCountByThemeId).toEqual({ y2k_pop = 4 })
	end)

	it("pays every star count exactly the §1.6 table, read from OutfitScoreCalculator", function()
		local expectedRewardByStarCount =
			{ [1] = { 20, 10 }, [2] = { 40, 20 }, [3] = { 60, 30 }, [4] = { 80, 40 }, [5] = { 100, 50 } }
		for _, starRewardTier in OutfitScoreCalculator.STAR_REWARD_TIERS do
			local starCount = starRewardTier.starCount
			local _, server = createHarnessWithLoadedPlayer()
			local roundRewardOutcome = server.rewardLedger:grantThemedRoundReward(
				PLAYER,
				createThemedRoundCompletion("r", "y2k_pop", starCount)
			)
			expect({ roundRewardOutcome.starCoinsGranted, roundRewardOutcome.fanCountGained }).toEqual(
				expectedRewardByStarCount[starCount]
			)
			expect({ roundRewardOutcome.starCoinsGranted, roundRewardOutcome.fanCountGained }).toEqual({
				starRewardTier.starCoinsGranted,
				starRewardTier.fanCountGained,
			})
			local saveData = server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
			expect(saveData.starCoinBalance).toBe(starRewardTier.starCoinsGranted)
			expect(saveData.fanCount).toBe(starRewardTier.fanCountGained)
		end
	end)

	it("reports a first result for a theme as a new best and stores it", function()
		local _, server = createHarnessWithLoadedPlayer(giveExampleRoundHistory)
		local roundRewardOutcome = server.rewardLedger:grantThemedRoundReward(
			PLAYER,
			createThemedRoundCompletion("round-1", "gothic_night", 1)
		)
		expect(roundRewardOutcome.isNewBestStarCountForTheme).toBeTrue()
		expect(server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).bestStarCountByThemeId).toEqual({
			y2k_pop = 3,
			gothic_night = 1,
		})
	end)

	it("does not report an equal or lower result as a new best and never lowers the best", function()
		for _, starCount in { 3, 2 } do
			local _, server = createHarnessWithLoadedPlayer(giveExampleRoundHistory)
			local roundRewardOutcome = server.rewardLedger:grantThemedRoundReward(
				PLAYER,
				createThemedRoundCompletion("round-1", "y2k_pop", starCount)
			)
			expect(roundRewardOutcome.isNewBestStarCountForTheme).toBeFalse()
			local saveData = server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
			expect(saveData.bestStarCountByThemeId).toEqual({ y2k_pop = 3 })
			expect(saveData.totalRoundsCompletedCount).toBe(15)
		end
	end)

	it("refuses a second reward for the same round and player, and changes nothing", function()
		local _, server = createHarnessWithLoadedPlayer(giveExampleRoundHistory)
		server.rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("round-1", "y2k_pop", 4))
		local saveDataAfterFirst = server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
		local secondOutcome =
			server.rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("round-1", "y2k_pop", 5))
		expect(secondOutcome).toEqual({
			rewardLedgerOutcome = "Declined",
			declineReason = "RoundRewardAlreadyGranted",
			starCoinsGranted = 0,
			fanCountGained = 0,
			isNewBestStarCountForTheme = false,
		})
		expect(server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)).toEqual(saveDataAfterFirst)
	end)

	it("rewards another player in the same round, and the same player in the next round", function()
		local harness, server = createHarnessWithLoadedPlayer()
		harness.startServerAndLoadPlayer(OTHER_PLAYER)
		local rewardLedger = server.rewardLedger
		expect(
			rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("r1", "y2k_pop", 2)).rewardLedgerOutcome
		).toBe("Granted")
		expect(
			rewardLedger:grantThemedRoundReward(OTHER_PLAYER, createThemedRoundCompletion("r1", "y2k_pop", 2)).rewardLedgerOutcome
		).toBe("Granted")
		expect(
			rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("r2", "y2k_pop", 2)).rewardLedgerOutcome
		).toBe("Granted")
		expect(server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).totalRoundsCompletedCount).toBe(2)
	end)

	it("forgets only round ids older than the remembered window", function()
		local _, server = createHarnessWithLoadedPlayer()
		local rememberedRoundIdCount = RewardLedger.REMEMBERED_ROUND_ID_COUNT_FOR_DUPLICATE_GUARD
		for roundNumber = 1, rememberedRoundIdCount + 1 do
			server.rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("r" .. roundNumber, "t", 1))
		end
		local newestStillGuarded =
			server.rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("r2", "t", 1))
		expect(newestStillGuarded.declineReason).toBe("RoundRewardAlreadyGranted")
		expect(#server.rewardLedger.rememberedRoundIdsInGrantOrder).toBe(rememberedRoundIdCount)
		local oldestForgotten =
			server.rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("r1", "t", 1))
		expect(oldestForgotten.rewardLedgerOutcome).toBe("Granted")
	end)

	it("does not mark a round as rewarded when the save was not loaded, so a later grant still pays", function()
		local harness, server = createHarnessWithLoadedPlayer()
		local notLoadedOutcome =
			server.rewardLedger:grantThemedRoundReward(OTHER_PLAYER, createThemedRoundCompletion("r1", "y2k_pop", 3))
		expect(notLoadedOutcome).toEqual({
			rewardLedgerOutcome = "SaveDataNotLoaded",
			starCoinsGranted = 0,
			fanCountGained = 0,
			isNewBestStarCountForTheme = false,
		})
		harness.startServerAndLoadPlayer(OTHER_PLAYER)
		local laterOutcome =
			server.rewardLedger:grantThemedRoundReward(OTHER_PLAYER, createThemedRoundCompletion("r1", "y2k_pop", 3))
		expect(laterOutcome.rewardLedgerOutcome).toBe("Granted")
	end)

	it("logs the round grant with rewardSourceKind ThemedRound", function()
		local _, server = createHarnessWithLoadedPlayer(giveExampleRoundHistory)
		server.rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("round-7", "y2k_pop", 4))
		local grantLogLine = server.ledgerLogger.loggedInformation[#server.ledgerLogger.loggedInformation]
		expect(string.find(grantLogLine, "rewardSourceKind ThemedRound", 1, true) ~= nil).toBeTrue()
		expect(string.find(grantLogLine, "round-7", 1, true) ~= nil).toBeTrue()
	end)

	it("refuses a star count outside the §1.6 table, including 0 for an empty outfit", function()
		for _, invalidStarCount in { 0, 6, 2.5, -1, "4" } do
			local _, server = createHarnessWithLoadedPlayer()
			expect(function()
				server.rewardLedger:grantThemedRoundReward(
					PLAYER,
					createThemedRoundCompletion("r", "y2k_pop", invalidStarCount :: any)
				)
			end).toThrow("starCount must be one of")
			expect(server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).totalRoundsCompletedCount).toBe(0)
		end
	end)

	it("refuses a missing roundId, themeId or scored outfit", function()
		local _, server = createHarnessWithLoadedPlayer()
		for _, missingFieldName in { "roundId", "themeId", "scoredOutfitStylingItemKeys" } do
			local themedRoundCompletion = createThemedRoundCompletion("r", "y2k_pop", 3)
			themedRoundCompletion[missingFieldName] = nil
			expect(function()
				server.rewardLedger:grantThemedRoundReward(PLAYER, themedRoundCompletion)
			end).toThrow(missingFieldName)
		end
	end)
end)

-- Phase 2 daily quest progress joins the round reward through themedRoundCompletionRecordWriters.
describe("RewardLedger themedRoundCompletionRecordWriters (Phase 2 extension point)", function()
	local function countRoundTowardsDailyQuests(saveDataDraft, themedRoundCompletion)
		local progressCountByQuestId = saveDataDraft.dailyProgress.dailyQuestProgressCountByQuestId
		progressCountByQuestId.complete_rounds_5 = (progressCountByQuestId.complete_rounds_5 or 0) + 1
		if themedRoundCompletion.starCount >= 3 then
			progressCountByQuestId.earn_three_stars_3 = (progressCountByQuestId.earn_three_stars_3 or 0) + 1
		end
	end

	it("writes daily quest progress in the SAME change as the reward, with no change for the caller", function()
		local _, server = createHarnessWithLoadedPlayer(
			giveExampleRoundHistory,
			{ themedRoundCompletionRecordWriters = { countRoundTowardsDailyQuests } }
		)
		local seenInMemorySaves = {}
		server.playerSaveDataKeeper:subscribeToInMemorySaveDataChanged(function(_, inMemorySaveDataCopy)
			table.insert(seenInMemorySaves, inMemorySaveDataCopy)
		end)
		server.rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("round-1", "y2k_pop", 4))
		expect(#seenInMemorySaves).toBe(1)
		expect(seenInMemorySaves[1].starCoinBalance).toBe(430)
		expect(seenInMemorySaves[1].totalRoundsCompletedCount).toBe(15)
		expect(seenInMemorySaves[1].dailyProgress.dailyQuestProgressCountByQuestId).toEqual({
			complete_rounds_5 = 1,
			earn_three_stars_3 = 1,
		})
	end)

	it("hands each writer the round, theme, stars and scored outfit, read-only", function()
		local seenThemedRoundCompletions = {}
		local _, server = createHarnessWithLoadedPlayer(nil, {
			themedRoundCompletionRecordWriters = {
				function(saveDataDraft, themedRoundCompletion)
					table.insert(seenThemedRoundCompletions, themedRoundCompletion)
					saveDataDraft.dailyProgress.dailyQuestProgressCountByQuestId.seen = 1
				end,
			},
		})
		server.rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("round-1", "y2k_pop", 2))
		expect(seenThemedRoundCompletions[1]).toEqual(createThemedRoundCompletion("round-1", "y2k_pop", 2))
		expect(table.isfrozen(seenThemedRoundCompletions[1].scoredOutfitStylingItemKeys)).toBeTrue()
	end)

	it("applies nothing when a writer raises: no reward, no record, round still rewardable", function()
		local shouldWriterRaise = true
		local harness, server = createHarnessWithLoadedPlayer(giveExampleRoundHistory, {
			themedRoundCompletionRecordWriters = {
				function(saveDataDraft)
					saveDataDraft.dailyProgress.dailyQuestProgressCountByQuestId.complete_rounds_5 = 1
					if shouldWriterRaise then
						error("daily tracker bug")
					end
				end,
			},
		})
		local saveDataBefore = server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
		local startedOperationCountBefore = harness.fakePlayerSaveDataStorage:countStartedOperations()
		expect(function()
			server.rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("round-1", "y2k_pop", 4))
		end).toThrow("daily tracker bug")
		expect(server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)).toEqual(saveDataBefore)
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations()).toBe(startedOperationCountBefore)
		shouldWriterRaise = false
		local retriedOutcome =
			server.rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("round-1", "y2k_pop", 4))
		expect(retriedOutcome.rewardLedgerOutcome).toBe("Granted")
	end)

	it("refuses a writer that changes Star Coins or fans", function()
		local _, server = createHarnessWithLoadedPlayer(nil, {
			themedRoundCompletionRecordWriters = {
				function(saveDataDraft)
					saveDataDraft.starCoinBalance += 100
				end,
			},
		})
		expect(function()
			server.rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("round-1", "y2k_pop", 4))
		end).toThrow("only the ledger may")
		expect(server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).starCoinBalance).toBe(0)
	end)

	it("refuses a writer list holding something other than functions", function()
		local harness = RewardLedgerCrashableServerTestHarness.createHarness({
			themedRoundCompletionRecordWriters = { "not a function" },
		})
		expect(function()
			harness.startNewServer()
		end).toThrow("themedRoundCompletionRecordWriters[1] is not a function")
	end)

	it("keeps its own copy of the writer list: later changes to the caller's list have no effect", function()
		local writerNamesThatRan = {}
		local function createNamedWriter(writerName: string)
			return function(saveDataDraft)
				table.insert(writerNamesThatRan, writerName)
				saveDataDraft.dailyProgress.dailyQuestProgressCountByQuestId[writerName] = 1
			end
		end
		local callerOwnedWriterList = { createNamedWriter("original_first"), createNamedWriter("original_second") }
		local _, server =
			createHarnessWithLoadedPlayer(nil, { themedRoundCompletionRecordWriters = callerOwnedWriterList })
		table.insert(callerOwnedWriterList, createNamedWriter("added_later"))
		callerOwnedWriterList[1] = createNamedWriter("replaced_later")
		table.remove(callerOwnedWriterList, 2)
		server.rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("round-1", "y2k_pop", 3))
		expect(writerNamesThatRan).toEqual({ "original_first", "original_second" })
		expect(
			server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).dailyProgress.dailyQuestProgressCountByQuestId
		).toEqual({
			original_first = 1,
			original_second = 1,
		})
	end)

	it("does not let anyone change the ledger's own writer list", function()
		local _, server = createHarnessWithLoadedPlayer(nil, {
			themedRoundCompletionRecordWriters = {
				function(saveDataDraft)
					saveDataDraft.dailyProgress.dailyQuestProgressCountByQuestId.counted = 1
				end,
			},
		})
		local ledgerOwnedWriterList = server.rewardLedger.themedRoundCompletionRecordWriters
		expect(table.isfrozen(ledgerOwnedWriterList)).toBeTrue()
		expect(function()
			table.insert(ledgerOwnedWriterList, function() end)
		end).toThrow("readonly")
	end)

	it("runs writers after the ledger's own reward and round record, inside the same change", function()
		local draftSeenByWriter = nil
		local _, server = createHarnessWithLoadedPlayer(giveExampleRoundHistory, {
			themedRoundCompletionRecordWriters = {
				function(saveDataDraft)
					draftSeenByWriter = table.clone(saveDataDraft)
					draftSeenByWriter.bestStarCountByThemeId = table.clone(saveDataDraft.bestStarCountByThemeId)
					saveDataDraft.dailyProgress.dailyQuestProgressCountByQuestId.counted = 1
				end,
			},
		})
		server.rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("round-1", "y2k_pop", 4))
		expect(draftSeenByWriter.starCoinBalance).toBe(430)
		expect(draftSeenByWriter.fanCount).toBe(1240)
		expect(draftSeenByWriter.totalRoundsCompletedCount).toBe(15)
		expect(draftSeenByWriter.bestStarCountByThemeId).toEqual({ y2k_pop = 4 })
	end)

	it("refuses a writer that yields, and applies nothing", function()
		local _, server = createHarnessWithLoadedPlayer(giveExampleRoundHistory, {
			themedRoundCompletionRecordWriters = {
				function(saveDataDraft)
					saveDataDraft.dailyProgress.dailyQuestProgressCountByQuestId.counted = 1
					coroutine.yield()
				end,
			},
		})
		local saveDataBefore = server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
		expect(function()
			server.rewardLedger:grantThemedRoundReward(PLAYER, createThemedRoundCompletion("round-1", "y2k_pop", 4))
		end).toThrow("must not yield")
		expect(server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)).toEqual(saveDataBefore)
	end)
end)
