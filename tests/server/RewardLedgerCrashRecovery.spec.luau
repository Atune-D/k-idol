-- Spec §3.3 "A reward and its record are one change" and §6.2 "Unit: ledger": for each operation of
-- the §3.3 table, a save failure or a crash is injected at every point between the in-memory change
-- and a finished save. The reloaded save must hold the reward together with its record, or neither,
-- and the operation must not then pay a second time.

local UnitTestFramework = require("../Support/UnitTestFramework")
local RewardLedgerCrashableServerTestHarness = require("./RewardLedgerCrashableServerTestHarness")
local RewardLedgerPhaseTwoTestCallers = require("./RewardLedgerPhaseTwoTestCallers")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = RewardLedgerCrashableServerTestHarness.EXAMPLE_PLAYER_USER_ID

local function giveExampleBalancesAndRoundHistory(saveData)
	saveData.starCoinBalance = 350
	saveData.fanCount = 1200
	saveData.totalRoundsCompletedCount = 14
	saveData.bestStarCountByThemeId = { y2k_pop = 3 }
end

local function isListHolding(candidateList, expectedElement): boolean
	return table.find(candidateList, expectedElement) ~= nil
end

-- Each scenario: how to perform the operation, the balances before and after it, whether a save
-- holds its record, and how a repeat is refused.
local OPERATION_SCENARIOS = {
	{
		operationName = "playtime milestone claim",
		performOperation = function(rewardLedger)
			return RewardLedgerPhaseTwoTestCallers.claimPlaytimeMilestone(rewardLedger, PLAYER, 10, 30)
		end,
		balancesAfterOperation = { starCoinBalance = 380, fanCount = 1200 },
		isRecordPresent = function(saveData)
			return isListHolding(saveData.dailyProgress.claimedPlaytimeMilestoneMinutes, 10)
		end,
		declineReasonOnRepeat = "AlreadyClaimed",
	},
	{
		operationName = "daily quest claim",
		performOperation = function(rewardLedger)
			return RewardLedgerPhaseTwoTestCallers.claimDailyQuestReward(rewardLedger, PLAYER, "complete_rounds_5", 100)
		end,
		balancesAfterOperation = { starCoinBalance = 450, fanCount = 1200 },
		isRecordPresent = function(saveData)
			return isListHolding(saveData.dailyProgress.claimedDailyQuestIds, "complete_rounds_5")
		end,
		declineReasonOnRepeat = "AlreadyClaimed",
	},
	{
		operationName = "promo code redemption",
		performOperation = function(rewardLedger)
			return RewardLedgerPhaseTwoTestCallers.redeemPromoCode(rewardLedger, PLAYER, "launch_2026", 300)
		end,
		balancesAfterOperation = { starCoinBalance = 650, fanCount = 1200 },
		isRecordPresent = function(saveData)
			return isListHolding(saveData.redeemedPromoCodeIds, "launch_2026")
		end,
		declineReasonOnRepeat = "AlreadyRedeemed",
	},
	{
		operationName = "dance purchase",
		performOperation = function(rewardLedger)
			return RewardLedgerPhaseTwoTestCallers.purchaseDance(rewardLedger, PLAYER, "neon_spin", 200)
		end,
		balancesAfterOperation = { starCoinBalance = 150, fanCount = 1200 },
		isRecordPresent = function(saveData)
			return isListHolding(saveData.ownedDanceIds, "neon_spin")
		end,
		declineReasonOnRepeat = "AlreadyOwned",
	},
	{
		operationName = "cosmetic purchase",
		performOperation = function(rewardLedger)
			return RewardLedgerPhaseTwoTestCallers.purchaseCosmetic(rewardLedger, PLAYER, "title_rising_star", 300)
		end,
		balancesAfterOperation = { starCoinBalance = 50, fanCount = 1200 },
		isRecordPresent = function(saveData)
			return isListHolding(saveData.ownedCosmeticIds, "title_rising_star")
		end,
		declineReasonOnRepeat = "AlreadyOwned",
	},
	{
		operationName = "themed round reward",
		performOperation = function(rewardLedger)
			return rewardLedger:grantThemedRoundReward(PLAYER, {
				roundId = "round-1",
				themeId = "y2k_pop",
				starCount = 4,
				scoredOutfitStylingItemKeys = { "asset_1001" },
			})
		end,
		balancesAfterOperation = { starCoinBalance = 430, fanCount = 1240 },
		isRecordPresent = function(saveData)
			return saveData.totalRoundsCompletedCount == 15 and saveData.bestStarCountByThemeId.y2k_pop == 4
		end,
		declineReasonOnRepeat = "RoundRewardAlreadyGranted",
		-- The round's non-repeatability lives in the ledger's memory (the round itself does not
		-- survive a crash); the save record is a count, not a round id. See RewardLedger header.
		isRepeatRefusedAfterReload = false,
	},
}

-- "Neither", "Both", or a description of the inconsistency.
local function classifyRewardAndRecord(operationScenario, saveData): string
	local hasRecord = operationScenario.isRecordPresent(saveData)
	local balancesAfter = operationScenario.balancesAfterOperation
	local hasReward = saveData.starCoinBalance == balancesAfter.starCoinBalance
		and saveData.fanCount == balancesAfter.fanCount
	local hasNoReward = saveData.starCoinBalance == 350 and saveData.fanCount == 1200
	if hasReward and hasRecord then
		return "Both"
	end
	if hasNoReward and not hasRecord then
		return "Neither"
	end
	return string.format(
		"Inconsistent (starCoinBalance %d, fanCount %d, record %s)",
		saveData.starCoinBalance,
		saveData.fanCount,
		tostring(hasRecord)
	)
end

-- Each point runs right after the operation was applied in memory; the server then crashes with
-- its in-flight writes lost or landed, and the point names what the reloaded save must hold.
local FAILURE_INJECTION_POINTS = {
	{
		pointName = "crash while the save waits for the 10 s spacing (no write started)",
		secondsBetweenLoadAndOperation = 0,
		injectFailureBeforeCrash = function(harness)
			expect(harness.fakePlayerSaveDataStorage:countPendingOperations()).toBe(0)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Neither",
	},
	{
		pointName = "crash while the save write is in flight; it never arrives",
		injectFailureBeforeCrash = function(harness)
			expect(harness.fakePlayerSaveDataStorage:countPendingOperations()).toBe(1)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Neither",
	},
	{
		pointName = "crash after the write arrived, before its answer",
		injectFailureBeforeCrash = function(harness)
			expect(harness.fakePlayerSaveDataStorage:countPendingOperations()).toBe(1)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLanded",
		expectedReloadedState = "Both",
	},
	{
		pointName = "crash after the save succeeded",
		injectFailureBeforeCrash = function(harness)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Both",
	},
	{
		pointName = "save fails, crash before its retry",
		injectFailureBeforeCrash = function(harness)
			harness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Neither",
	},
	{
		pointName = "save fails, crash while the retry is in flight",
		injectFailureBeforeCrash = function(harness)
			harness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
			harness.advanceSeconds(2)
			expect(harness.fakePlayerSaveDataStorage:countPendingOperations()).toBe(1)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Neither",
	},
	{
		pointName = "save fails, the retry succeeds, then crash",
		injectFailureBeforeCrash = function(harness)
			harness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
			harness.advanceSeconds(2)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Both",
	},
	{
		pointName = "every retry fails (persistence delayed), then crash",
		injectFailureBeforeCrash = function(harness)
			local fakeStorage = harness.fakePlayerSaveDataStorage
			fakeStorage:failOldestPendingOperation(PLAYER)
			for _, retryDelaySeconds in { 2, 4, 8 } do
				harness.advanceSeconds(retryDelaySeconds)
				fakeStorage:failOldestPendingOperation(PLAYER)
			end
			expect(harness.currentServer.playerSaveDataKeeper:isSaveDataPersistenceDelayed(PLAYER)).toBeTrue()
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Neither",
	},
	{
		pointName = "the write arrives but its answer is lost, the retry lands, then crash",
		injectFailureBeforeCrash = function(harness)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperationButReportFailure(PLAYER)
			harness.advanceSeconds(2)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Both",
	},
	{
		pointName = "storage runs the save decision twice (as Roblox may), save succeeds, then crash",
		injectFailureBeforeCrash = function(harness)
			harness.fakePlayerSaveDataStorage:setRunsEveryDecisionTwice(true)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
			harness.fakePlayerSaveDataStorage:setRunsEveryDecisionTwice(false)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Both",
	},
	{
		pointName = "player leaves, the save fails, crash while the final save is in flight",
		isPlayerLeaving = true,
		injectFailureBeforeCrash = function(harness)
			harness.currentServer.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
			harness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
			expect(harness.fakePlayerSaveDataStorage:countPendingOperations()).toBe(1)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Neither",
	},
	{
		pointName = "player leaves and the final save succeeds, then the server goes away",
		isPlayerLeaving = true,
		injectFailureBeforeCrash = function(harness)
			harness.currentServer.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
			expect(harness.readStoredSaveData(PLAYER).gameServerSessionLock).toBeNil()
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Both",
	},
}

local function expectRepeatRefusedOnSameServer(operationScenario, failureInjectionPoint, server)
	local saveDataBeforeRepeat = server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
	local repeatOutcome = operationScenario.performOperation(server.rewardLedger)
	if failureInjectionPoint.isPlayerLeaving then
		-- Refused either way: the round guard answers first, every other operation finds no save.
		local acceptableOutcomes = { "SaveDataNotLoaded", "Declined" }
		expect(table.find(acceptableOutcomes, repeatOutcome.rewardLedgerOutcome) ~= nil).toBeTrue()
		return
	end
	expect(repeatOutcome.rewardLedgerOutcome).toBe("Declined")
	expect(repeatOutcome.declineReason).toBe(operationScenario.declineReasonOnRepeat)
	expect(server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)).toEqual(saveDataBeforeRepeat)
end

-- After the reload: at most one more reward can ever be obtained, and only if none was kept.
local function expectNoSecondRewardAfterReload(operationScenario, harness, server, reloadedState: string)
	local firstRepeatOutcome = operationScenario.performOperation(server.rewardLedger)
	if reloadedState == "Both" then
		expect(firstRepeatOutcome.declineReason).toBe(operationScenario.declineReasonOnRepeat)
	else
		expect(firstRepeatOutcome.declineReason).toBeNil()
	end
	local secondRepeatOutcome = operationScenario.performOperation(server.rewardLedger)
	expect(secondRepeatOutcome.declineReason).toBe(operationScenario.declineReasonOnRepeat)
	if harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER) > 0 then
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
	end
	expect(classifyRewardAndRecord(operationScenario, harness.readStoredSaveData(PLAYER))).toBe("Both")
end

for _, operationScenario in OPERATION_SCENARIOS do
	describe("RewardLedger " .. operationScenario.operationName .. " under save failures and crashes", function()
		for _, failureInjectionPoint in FAILURE_INJECTION_POINTS do
			it(failureInjectionPoint.pointName .. " -> " .. failureInjectionPoint.expectedReloadedState, function()
				local harness = RewardLedgerCrashableServerTestHarness.createHarness()
				harness.storeExistingPlayerSaveData(PLAYER, giveExampleBalancesAndRoundHistory)
				local server = harness.startServerAndLoadPlayer(PLAYER)
				harness.advanceSeconds(failureInjectionPoint.secondsBetweenLoadAndOperation or 20)

				local operationOutcome = operationScenario.performOperation(server.rewardLedger)
				expect(operationOutcome.declineReason).toBeNil()
				expect(classifyRewardAndRecord(operationScenario, harness.readStoredSaveData(PLAYER))).toBe("Neither")
				expect(classifyRewardAndRecord(operationScenario, harness.readInMemorySaveData(PLAYER))).toBe("Both")

				failureInjectionPoint.injectFailureBeforeCrash(harness)
				expectRepeatRefusedOnSameServer(operationScenario, failureInjectionPoint, server)
				harness.crashCurrentServer(failureInjectionPoint.inFlightWriteFateAtCrash)

				local storedAfterCrash = harness.readStoredSaveData(PLAYER)
				expect(classifyRewardAndRecord(operationScenario, storedAfterCrash)).toBe(
					failureInjectionPoint.expectedReloadedState
				)
				local reloadedServer = harness.startServerAndLoadPlayer(PLAYER)
				local reloadedSaveData = harness.readInMemorySaveData(PLAYER)
				expect(classifyRewardAndRecord(operationScenario, reloadedSaveData)).toBe(
					failureInjectionPoint.expectedReloadedState
				)
				harness.advanceSeconds(20)
				if operationScenario.isRepeatRefusedAfterReload ~= false then
					expectNoSecondRewardAfterReload(
						operationScenario,
						harness,
						reloadedServer,
						failureInjectionPoint.expectedReloadedState
					)
				end
			end)
		end
	end)
end
