-- Random sequences of grants, spends, round rewards, save completions, save failures and crashes,
-- checked against a simple model. A failure prints the seed (IDOLGROW_RANDOM_TEST_SEED reproduces it).
--
-- Two kinds of check:
--   * model: before each operation the expected outcome and the expected in-memory save are worked
--     out from the save as it stands, then compared with what the real ledger and keeper did;
--   * records explain balances: every save that ever reached storage, and every in-memory save,
--     must have exactly the balance and fan count its records add up to (starting values plus
--     the rewards of every claimed/redeemed/completed record, minus the prices of every owned
--     item). A reward without its record, or a record without its reward, breaks this sum.

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local RewardLedgerCrashableServerTestHarness = require("./RewardLedgerCrashableServerTestHarness")
local RewardLedgerPhaseTwoTestCallers = require("./RewardLedgerPhaseTwoTestCallers")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = RewardLedgerCrashableServerTestHarness.EXAMPLE_PLAYER_USER_ID
local createDeepCopy = PlayerSaveDataSchema.createDeepCopyOfPlainTable

local RANDOM_TRIAL_COUNT = 150
local STEPS_PER_TRIAL = 40

-- Test-side catalogs (the real ones are Phase 2). Amounts are fixed per id so records explain balances.
local PLAYTIME_MILESTONE_REWARDS = {
	{ milestoneMinutes = 5, starCoinReward = 20 },
	{ milestoneMinutes = 10, starCoinReward = 30 },
	{ milestoneMinutes = 20, starCoinReward = 50 },
	{ milestoneMinutes = 60, starCoinReward = 150 },
}
local DAILY_QUEST_REWARDS = {
	{ dailyQuestId = "complete_rounds_5", starCoinReward = 100 },
	{ dailyQuestId = "earn_stars_3", starCoinReward = 60 },
}
local PROMO_CODE_REWARDS = {
	{ promoCodeId = "launch_2026", starCoinReward = 300 },
	{ promoCodeId = "summer_stage", starCoinReward = 150 },
}
local DANCE_PRICES = {
	{ danceId = "neon_spin", starCoinPrice = 900 },
	{ danceId = "slide_step", starCoinPrice = 300 },
	{ danceId = "pop_lock", starCoinPrice = 0 },
}
local COSMETIC_PRICES = {
	{ cosmeticId = "title_rising_star", starCoinPrice = 300 },
	{ cosmeticId = "plate_glitter", starCoinPrice = 60 },
}
-- Spec §1.6, written out independently of OutfitScoreCalculator: [starCount] = { coins, fans }.
local ROUND_REWARD_BY_STAR_COUNT = { { 20, 10 }, { 40, 20 }, { 60, 30 }, { 80, 40 }, { 100, 50 } }
local THEME_IDS = { "y2k_pop", "gothic_night", "beach_day" }

-- The Nth completed round of a save always earns the same stars, so the count explains the sum.
local function determineStarCountForRoundNumber(roundNumber: number): number
	return (roundNumber * 3) % 5 + 1
end

local function sumAmountsOfRecordedIds(catalog, idFieldName: string, amountFieldName: string, recordedIds): number
	local amountSum = 0
	for _, catalogEntry in catalog do
		if table.find(recordedIds, catalogEntry[idFieldName]) then
			amountSum += catalogEntry[amountFieldName]
		end
	end
	return amountSum
end

local function expectRecordsExplainBalances(saveData, startingBalances, whichSaveDescription: string)
	local dailyProgress = saveData.dailyProgress
	local expectedStarCoinBalance = startingBalances.starCoinBalance
		+ sumAmountsOfRecordedIds(
			PLAYTIME_MILESTONE_REWARDS,
			"milestoneMinutes",
			"starCoinReward",
			dailyProgress.claimedPlaytimeMilestoneMinutes
		)
		+ sumAmountsOfRecordedIds(
			DAILY_QUEST_REWARDS,
			"dailyQuestId",
			"starCoinReward",
			dailyProgress.claimedDailyQuestIds
		)
		+ sumAmountsOfRecordedIds(PROMO_CODE_REWARDS, "promoCodeId", "starCoinReward", saveData.redeemedPromoCodeIds)
		- sumAmountsOfRecordedIds(DANCE_PRICES, "danceId", "starCoinPrice", saveData.ownedDanceIds)
		- sumAmountsOfRecordedIds(COSMETIC_PRICES, "cosmeticId", "starCoinPrice", saveData.ownedCosmeticIds)
	local expectedFanCount = startingBalances.fanCount
	for roundNumber = 1, saveData.totalRoundsCompletedCount do
		local roundReward = ROUND_REWARD_BY_STAR_COUNT[determineStarCountForRoundNumber(roundNumber)]
		expectedStarCoinBalance += roundReward[1]
		expectedFanCount += roundReward[2]
	end
	local observedBalances = { saveData.starCoinBalance, saveData.fanCount, whichSaveDescription }
	expect(observedBalances).toEqual({ expectedStarCoinBalance, expectedFanCount, whichSaveDescription })
	expect(saveData.starCoinBalance >= 0).toBeTrue()
	for _, recordListName in { "redeemedPromoCodeIds", "ownedDanceIds", "ownedCosmeticIds" } do
		local recordList = saveData[recordListName]
		for recordPosition, recordedId in recordList do
			expect({ recordListName, table.find(recordList, recordedId) }).toEqual({ recordListName, recordPosition })
		end
	end
end

-- Each random operation: how to perform it, and the model's prediction from the save before it.
-- prediction = { rewardLedgerOutcome, declineReason?, saveDataAfter, isNewBestStarCountForTheme? }
local function pickRandomOperation(seededRandomNumberGenerator, roundIdPrefix: string, roundSequenceNumber: number)
	local operationKindNumber = seededRandomNumberGenerator.nextWholeNumberInRange(1, 6)
	local ALREADY_CLAIMED = RewardLedgerPhaseTwoTestCallers.ALREADY_CLAIMED_DECLINE_REASON

	local function buildGrantOperation(
		operationLabel,
		getRecordList,
		recordedId,
		starCoinReward,
		declineReason,
		perform
	)
		return {
			operationLabel = operationLabel,
			performOperation = perform,
			predictOutcome = function(saveDataBefore)
				if table.find(getRecordList(saveDataBefore), recordedId) then
					return {
						rewardLedgerOutcome = "Declined",
						declineReason = declineReason,
						saveDataAfter = saveDataBefore,
					}
				end
				local saveDataAfter = createDeepCopy(saveDataBefore)
				saveDataAfter.starCoinBalance += starCoinReward
				table.insert(getRecordList(saveDataAfter), recordedId)
				return { rewardLedgerOutcome = "Granted", saveDataAfter = saveDataAfter }
			end,
		}
	end

	local function buildPurchaseOperation(operationLabel, ownedIdsFieldName, purchasedItemId, starCoinPrice, perform)
		return {
			operationLabel = operationLabel,
			performOperation = perform,
			predictOutcome = function(saveDataBefore)
				if table.find(saveDataBefore[ownedIdsFieldName], purchasedItemId) then
					return {
						rewardLedgerOutcome = "Declined",
						declineReason = "AlreadyOwned",
						saveDataAfter = saveDataBefore,
					}
				end
				if starCoinPrice > saveDataBefore.starCoinBalance then
					return {
						rewardLedgerOutcome = "Declined",
						declineReason = "InsufficientStarCoins",
						saveDataAfter = saveDataBefore,
					}
				end
				local saveDataAfter = createDeepCopy(saveDataBefore)
				saveDataAfter.starCoinBalance -= starCoinPrice
				table.insert(saveDataAfter[ownedIdsFieldName], purchasedItemId)
				return { rewardLedgerOutcome = "Spent", saveDataAfter = saveDataAfter }
			end,
		}
	end

	if operationKindNumber == 1 then
		local milestone = seededRandomNumberGenerator.pickRandomListElement(PLAYTIME_MILESTONE_REWARDS)
		return buildGrantOperation(
			"claim milestone " .. milestone.milestoneMinutes,
			function(saveData)
				return saveData.dailyProgress.claimedPlaytimeMilestoneMinutes
			end,
			milestone.milestoneMinutes,
			milestone.starCoinReward,
			ALREADY_CLAIMED,
			function(rewardLedger)
				return RewardLedgerPhaseTwoTestCallers.claimPlaytimeMilestone(
					rewardLedger,
					PLAYER,
					milestone.milestoneMinutes,
					milestone.starCoinReward
				)
			end
		)
	elseif operationKindNumber == 2 then
		local dailyQuest = seededRandomNumberGenerator.pickRandomListElement(DAILY_QUEST_REWARDS)
		return buildGrantOperation(
			"claim quest " .. dailyQuest.dailyQuestId,
			function(saveData)
				return saveData.dailyProgress.claimedDailyQuestIds
			end,
			dailyQuest.dailyQuestId,
			dailyQuest.starCoinReward,
			ALREADY_CLAIMED,
			function(rewardLedger)
				return RewardLedgerPhaseTwoTestCallers.claimDailyQuestReward(
					rewardLedger,
					PLAYER,
					dailyQuest.dailyQuestId,
					dailyQuest.starCoinReward
				)
			end
		)
	elseif operationKindNumber == 3 then
		local promoCode = seededRandomNumberGenerator.pickRandomListElement(PROMO_CODE_REWARDS)
		return buildGrantOperation(
			"redeem " .. promoCode.promoCodeId,
			function(saveData)
				return saveData.redeemedPromoCodeIds
			end,
			promoCode.promoCodeId,
			promoCode.starCoinReward,
			RewardLedgerPhaseTwoTestCallers.ALREADY_REDEEMED_DECLINE_REASON,
			function(rewardLedger)
				return RewardLedgerPhaseTwoTestCallers.redeemPromoCode(
					rewardLedger,
					PLAYER,
					promoCode.promoCodeId,
					promoCode.starCoinReward
				)
			end
		)
	elseif operationKindNumber == 4 then
		local dance = seededRandomNumberGenerator.pickRandomListElement(DANCE_PRICES)
		return buildPurchaseOperation(
			"buy dance " .. dance.danceId,
			"ownedDanceIds",
			dance.danceId,
			dance.starCoinPrice,
			function(rewardLedger)
				return RewardLedgerPhaseTwoTestCallers.purchaseDance(
					rewardLedger,
					PLAYER,
					dance.danceId,
					dance.starCoinPrice
				)
			end
		)
	elseif operationKindNumber == 5 then
		local cosmetic = seededRandomNumberGenerator.pickRandomListElement(COSMETIC_PRICES)
		return buildPurchaseOperation(
			"buy cosmetic " .. cosmetic.cosmeticId,
			"ownedCosmeticIds",
			cosmetic.cosmeticId,
			cosmetic.starCoinPrice,
			function(rewardLedger)
				return RewardLedgerPhaseTwoTestCallers.purchaseCosmetic(
					rewardLedger,
					PLAYER,
					cosmetic.cosmeticId,
					cosmetic.starCoinPrice
				)
			end
		)
	end

	local themeId = seededRandomNumberGenerator.pickRandomListElement(THEME_IDS)
	local roundId = string.format("%s-round-%d", roundIdPrefix, roundSequenceNumber)
	local starCountForThisRound = nil
	return {
		operationLabel = "round reward " .. roundId,
		performOperation = function(rewardLedger)
			return rewardLedger:grantThemedRoundReward(PLAYER, {
				roundId = roundId,
				themeId = themeId,
				starCount = starCountForThisRound,
				scoredOutfitStylingItemKeys = { "asset_1001" },
			})
		end,
		predictOutcome = function(saveDataBefore)
			starCountForThisRound = determineStarCountForRoundNumber(saveDataBefore.totalRoundsCompletedCount + 1)
			local roundReward = ROUND_REWARD_BY_STAR_COUNT[starCountForThisRound]
			local saveDataAfter = createDeepCopy(saveDataBefore)
			saveDataAfter.starCoinBalance += roundReward[1]
			saveDataAfter.fanCount += roundReward[2]
			saveDataAfter.totalRoundsCompletedCount += 1
			local previousBestStarCount = saveDataBefore.bestStarCountByThemeId[themeId]
			local isNewBest = previousBestStarCount == nil or starCountForThisRound > previousBestStarCount
			if isNewBest then
				saveDataAfter.bestStarCountByThemeId[themeId] = starCountForThisRound
			end
			return {
				rewardLedgerOutcome = "Granted",
				saveDataAfter = saveDataAfter,
				isNewBestStarCountForTheme = isNewBest,
			}
		end,
	}
end

describe("RewardLedger randomized sequences with save failures and crashes", function()
	it("keeps every reward with its record, matches the model, and never pays twice", function()
		local crashesThatLostInMemoryWorkCount = 0
		local crashesThatKeptEverythingCount = 0

		SeededRandomTrials.runSeededRandomTrials(RANDOM_TRIAL_COUNT, function(seededRandomNumberGenerator, trialNumber)
			local startingBalances = {
				starCoinBalance = seededRandomNumberGenerator.nextWholeNumberInRange(0, 1500),
				fanCount = seededRandomNumberGenerator.nextWholeNumberInRange(0, 500),
			}
			local harness = RewardLedgerCrashableServerTestHarness.createHarness()
			harness.storeExistingPlayerSaveData(PLAYER, function(saveData)
				saveData.starCoinBalance = startingBalances.starCoinBalance
				saveData.fanCount = startingBalances.fanCount
			end)
			local server = harness.startServerAndLoadPlayer(PLAYER)
			local fakeStorage = harness.fakePlayerSaveDataStorage
			local roundSequenceNumber = 0
			local stepLog = {}

			for stepNumber = 1, STEPS_PER_TRIAL do
				local actionRoll = seededRandomNumberGenerator.nextWholeNumberInRange(1, 100)
				local hasPendingWrite = fakeStorage:countPendingOperations(PLAYER) > 0
				local stepDescription
				if actionRoll <= 50 then
					roundSequenceNumber += 1
					local randomOperation =
						pickRandomOperation(seededRandomNumberGenerator, "trial" .. trialNumber, roundSequenceNumber)
					stepDescription = randomOperation.operationLabel
					local saveDataBefore = harness.readInMemorySaveData(PLAYER)
					local prediction = randomOperation.predictOutcome(saveDataBefore)
					local ledgerOutcome = randomOperation.performOperation(server.rewardLedger)
					local stepContext = string.format("step %d (%s)", stepNumber, stepDescription)
					expect({ stepContext, ledgerOutcome.rewardLedgerOutcome, ledgerOutcome.declineReason }).toEqual({
						stepContext,
						prediction.rewardLedgerOutcome,
						prediction.declineReason,
					})
					if prediction.isNewBestStarCountForTheme ~= nil then
						expect(ledgerOutcome.isNewBestStarCountForTheme).toBe(prediction.isNewBestStarCountForTheme)
					end
					expect(harness.readInMemorySaveData(PLAYER)).toEqual(prediction.saveDataAfter)
				elseif actionRoll <= 65 then
					local elapsedSeconds = seededRandomNumberGenerator.nextWholeNumberInRange(1, 15)
					stepDescription = "advance " .. elapsedSeconds .. " s"
					harness.advanceSeconds(elapsedSeconds)
				elseif actionRoll <= 80 and hasPendingWrite then
					stepDescription = "storage completes the oldest write"
					fakeStorage:completeOldestPendingOperation(PLAYER)
				elseif actionRoll <= 87 and hasPendingWrite then
					stepDescription = "storage fails the oldest write"
					fakeStorage:failOldestPendingOperation(PLAYER)
				elseif actionRoll <= 90 and hasPendingWrite then
					stepDescription = "storage writes but the answer is lost"
					fakeStorage:completeOldestPendingOperationButReportFailure(PLAYER)
				elseif actionRoll > 90 then
					local inFlightWriteFate = if actionRoll <= 95 then "InFlightWritesLost" else "InFlightWritesLanded"
					stepDescription = "crash, " .. inFlightWriteFate
					local inMemoryBeforeCrash = harness.readInMemorySaveData(PLAYER)
					harness.crashCurrentServer(inFlightWriteFate)
					server = harness.startServerAndLoadPlayer(PLAYER)
					local reloadedSaveData = harness.readInMemorySaveData(PLAYER)
					if
						reloadedSaveData.starCoinBalance == inMemoryBeforeCrash.starCoinBalance
						and reloadedSaveData.totalRoundsCompletedCount == inMemoryBeforeCrash.totalRoundsCompletedCount
						and #reloadedSaveData.redeemedPromoCodeIds == #inMemoryBeforeCrash.redeemedPromoCodeIds
					then
						crashesThatKeptEverythingCount += 1
					else
						crashesThatLostInMemoryWorkCount += 1
					end
				else
					stepDescription = "nothing to do"
				end
				table.insert(stepLog, stepDescription)

				local stepContext = string.format("after step %d: %s", stepNumber, table.concat(stepLog, " | "))
				expectRecordsExplainBalances(
					harness.readInMemorySaveData(PLAYER),
					startingBalances,
					"in memory " .. stepContext
				)
				expectRecordsExplainBalances(
					harness.readStoredSaveData(PLAYER),
					startingBalances,
					"stored " .. stepContext
				)
			end

			-- Every value ever written, in order: each one consistent, and fans never went down.
			local previousWrittenFanCount = -1
			for writtenPosition, writtenRecord in fakeStorage.writtenPlayerSaveDataRecords do
				local writtenPlayerSaveData = writtenRecord.writtenPlayerSaveData
				expectRecordsExplainBalances(writtenPlayerSaveData, startingBalances, "write " .. writtenPosition)
				expect(writtenPlayerSaveData.fanCount >= previousWrittenFanCount).toBeTrue()
				previousWrittenFanCount = writtenPlayerSaveData.fanCount
			end
		end)

		-- The trials must really have exercised both kinds of crash outcome.
		expect(crashesThatLostInMemoryWorkCount > 0).toBeTrue()
		expect(crashesThatKeptEverythingCount > 0).toBeTrue()
	end)
end)
