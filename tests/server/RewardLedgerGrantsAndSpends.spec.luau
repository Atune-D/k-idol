local UnitTestFramework = require("../Support/UnitTestFramework")
local RewardLedger = require("../../src/server/RewardLedger")
local RewardLedgerCrashableServerTestHarness = require("./RewardLedgerCrashableServerTestHarness")
local RewardLedgerPhaseTwoTestCallers = require("./RewardLedgerPhaseTwoTestCallers")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = RewardLedgerCrashableServerTestHarness.EXAMPLE_PLAYER_USER_ID
local OTHER_PLAYER = RewardLedgerCrashableServerTestHarness.OTHER_PLAYER_USER_ID
local createHarnessWithLoadedPlayer = RewardLedgerCrashableServerTestHarness.createHarnessWithLoadedPlayer
local ALREADY_OWNED = RewardLedgerPhaseTwoTestCallers.ALREADY_OWNED_DECLINE_REASON

local function giveExampleBalances(saveData)
	saveData.starCoinBalance = 350
	saveData.fanCount = 1200
end

-- Everything a refused or failed operation must leave untouched.
local function captureObservableState(harness, server)
	return {
		inMemorySaveData = server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER),
		changeRevisions = { server.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER) },
		startedOperationCount = harness.fakePlayerSaveDataStorage:countStartedOperations(),
	}
end

local function createValidGrantRequest(overrides)
	local starCoinAndFanGrantRequest = {
		rewardSourceKind = RewardLedger.REWARD_SOURCE_KINDS.PromoCode,
		starCoinsToGrant = 300,
		fanCountToGrant = 0,
		grantDescriptionForLogs = "promo code launch_2026",
		checkGrantEligibility = function()
			return true
		end,
		writeGrantRecordThatPreventsRepeat = function(saveDataDraft)
			table.insert(saveDataDraft.redeemedPromoCodeIds, "launch_2026")
		end,
	}
	for overriddenFieldName, overridingValue in overrides or {} do
		starCoinAndFanGrantRequest[overriddenFieldName] = overridingValue
	end
	return starCoinAndFanGrantRequest
end

local function createValidSpendRequest(overrides)
	local starCoinSpendRequest = {
		purchaseKind = RewardLedger.PURCHASE_KINDS.Dance,
		starCoinPrice = 300,
		purchaseDescriptionForLogs = "dance neon_spin",
		checkPurchaseEligibility = function()
			return true
		end,
		writePurchaseRecordThatPreventsRepeat = function(saveDataDraft)
			table.insert(saveDataDraft.ownedDanceIds, "neon_spin")
		end,
	}
	for overriddenFieldName, overridingValue in overrides or {} do
		starCoinSpendRequest[overriddenFieldName] = overridingValue
	end
	return starCoinSpendRequest
end

describe("RewardLedger grants", function()
	it("adds Star Coins only, writes the record, and reports the new balance", function()
		local _, server = createHarnessWithLoadedPlayer(giveExampleBalances)
		local grantOutcome = RewardLedgerPhaseTwoTestCallers.claimPlaytimeMilestone(server.rewardLedger, PLAYER, 10, 30)
		expect(grantOutcome).toEqual({
			rewardLedgerOutcome = "Granted",
			starCoinsGranted = 30,
			fanCountGained = 0,
			starCoinBalanceAfterChange = 380,
			fanCountAfterChange = 1200,
			inMemoryChangeRevision = 1,
		})
		local saveData = server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
		expect(saveData.starCoinBalance).toBe(380)
		expect(saveData.fanCount).toBe(1200)
		expect(saveData.dailyProgress.claimedPlaytimeMilestoneMinutes).toEqual({ 10 })
	end)

	it("adds fans only when only fans are granted", function()
		local _, server = createHarnessWithLoadedPlayer(giveExampleBalances)
		local grantOutcome = server.rewardLedger:grantStarCoinsAndFans(
			PLAYER,
			createValidGrantRequest({ starCoinsToGrant = 0, fanCountToGrant = 25 })
		)
		expect(grantOutcome.rewardLedgerOutcome).toBe("Granted")
		local saveData = server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
		expect(saveData.starCoinBalance).toBe(350)
		expect(saveData.fanCount).toBe(1225)
	end)

	it("adds Star Coins and fans together in one change, seen by listeners only with its record", function()
		local _, server = createHarnessWithLoadedPlayer(giveExampleBalances)
		local seenInMemorySaves = {}
		server.playerSaveDataKeeper:subscribeToInMemorySaveDataChanged(function(_, inMemorySaveDataCopy)
			table.insert(seenInMemorySaves, inMemorySaveDataCopy)
		end)
		server.rewardLedger:grantStarCoinsAndFans(
			PLAYER,
			createValidGrantRequest({ starCoinsToGrant = 7, fanCountToGrant = 3 })
		)
		expect(#seenInMemorySaves).toBe(1)
		expect(seenInMemorySaves[1].starCoinBalance).toBe(357)
		expect(seenInMemorySaves[1].fanCount).toBe(1203)
		expect(seenInMemorySaves[1].redeemedPromoCodeIds).toEqual({ "launch_2026" })
	end)

	it("requests a save at once and the stored save holds the reward with its record", function()
		local harness, server = createHarnessWithLoadedPlayer(giveExampleBalances)
		RewardLedgerPhaseTwoTestCallers.redeemPromoCode(server.rewardLedger, PLAYER, "launch_2026", 300)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		local storedSaveData = harness.readStoredSaveData(PLAYER)
		expect(storedSaveData.starCoinBalance).toBe(650)
		expect(storedSaveData.redeemedPromoCodeIds).toEqual({ "launch_2026" })
	end)

	it("changes nothing when the eligibility check declines, and passes its reason on", function()
		local harness, server = createHarnessWithLoadedPlayer(function(saveData)
			giveExampleBalances(saveData)
			saveData.dailyProgress.claimedDailyQuestIds = { "complete_rounds_5" }
		end)
		local stateBefore = captureObservableState(harness, server)
		local grantOutcome =
			RewardLedgerPhaseTwoTestCallers.claimDailyQuestReward(server.rewardLedger, PLAYER, "complete_rounds_5", 100)
		expect(grantOutcome).toEqual({ rewardLedgerOutcome = "Declined", declineReason = "AlreadyClaimed" })
		harness.advanceSeconds(30)
		expect(captureObservableState(harness, server)).toEqual(stateBefore)
	end)

	it("never runs the record writer when the eligibility check declines", function()
		local _, server = createHarnessWithLoadedPlayer()
		local wasRecordWriterCalled = false
		server.rewardLedger:grantStarCoinsAndFans(
			PLAYER,
			createValidGrantRequest({
				checkGrantEligibility = function()
					return false, "NotEligibleForTest"
				end,
				writeGrantRecordThatPreventsRepeat = function()
					wasRecordWriterCalled = true
				end,
			})
		)
		expect(wasRecordWriterCalled).toBeFalse()
	end)

	it("answers SaveDataNotLoaded without running the eligibility check for a player not loaded", function()
		local _, server = createHarnessWithLoadedPlayer()
		local wasEligibilityChecked = false
		local grantOutcome = server.rewardLedger:grantStarCoinsAndFans(
			OTHER_PLAYER,
			createValidGrantRequest({
				checkGrantEligibility = function()
					wasEligibilityChecked = true
					return true
				end,
			})
		)
		expect(grantOutcome).toEqual({ rewardLedgerOutcome = "SaveDataNotLoaded" })
		expect(wasEligibilityChecked).toBeFalse()
		expect(#server.ledgerLogger.loggedWarnings).toBe(1)
		local notLoadedLogLine = server.ledgerLogger.loggedWarnings[1]
		expect(string.find(notLoadedLogLine, "save data not loaded", 1, true) ~= nil).toBeTrue()
		expect(string.find(notLoadedLogLine, tostring(OTHER_PLAYER), 1, true) ~= nil).toBeTrue()
	end)

	it("answers SaveDataNotLoaded once the player has started leaving", function()
		local _, server = createHarnessWithLoadedPlayer()
		server.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(PLAYER)
		local spendOutcome = server.rewardLedger:spendStarCoins(PLAYER, createValidSpendRequest({ starCoinPrice = 0 }))
		expect(spendOutcome).toEqual({ rewardLedgerOutcome = "SaveDataNotLoaded" })
	end)

	it("logs every applied grant with its rewardSourceKind and amounts", function()
		local _, server = createHarnessWithLoadedPlayer(giveExampleBalances)
		RewardLedgerPhaseTwoTestCallers.claimPlaytimeMilestone(server.rewardLedger, PLAYER, 5, 20)
		local grantLogLine = server.ledgerLogger.loggedInformation[#server.ledgerLogger.loggedInformation]
		expect(string.find(grantLogLine, "PlaytimeMilestone", 1, true) ~= nil).toBeTrue()
		expect(string.find(grantLogLine, "350 -> 370", 1, true) ~= nil).toBeTrue()
		expect(string.find(grantLogLine, tostring(PLAYER), 1, true) ~= nil).toBeTrue()
	end)
end)

describe("RewardLedger spends", function()
	it("takes exactly the price, writes the ownership record, and leaves fans alone", function()
		local _, server = createHarnessWithLoadedPlayer(giveExampleBalances)
		local spendOutcome =
			RewardLedgerPhaseTwoTestCallers.purchaseCosmetic(server.rewardLedger, PLAYER, "title_rising_star", 300)
		expect(spendOutcome).toEqual({
			rewardLedgerOutcome = "Spent",
			starCoinsSpent = 300,
			starCoinBalanceAfterChange = 50,
			inMemoryChangeRevision = 1,
		})
		local saveData = server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
		expect(saveData.starCoinBalance).toBe(50)
		expect(saveData.fanCount).toBe(1200)
		expect(saveData.ownedCosmeticIds).toEqual({ "title_rising_star" })
	end)

	it("allows a spend that leaves exactly 0", function()
		local _, server = createHarnessWithLoadedPlayer(giveExampleBalances)
		local spendOutcome =
			RewardLedgerPhaseTwoTestCallers.purchaseDance(server.rewardLedger, PLAYER, "neon_spin", 350)
		expect(spendOutcome.rewardLedgerOutcome).toBe("Spent")
		expect(server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).starCoinBalance).toBe(0)
	end)

	it("refuses a spend that would go below 0 and changes nothing, record included", function()
		local harness, server = createHarnessWithLoadedPlayer(giveExampleBalances)
		local stateBefore = captureObservableState(harness, server)
		local spendOutcome =
			RewardLedgerPhaseTwoTestCallers.purchaseDance(server.rewardLedger, PLAYER, "neon_spin", 351)
		expect(spendOutcome).toEqual({ rewardLedgerOutcome = "Declined", declineReason = "InsufficientStarCoins" })
		harness.advanceSeconds(30)
		expect(captureObservableState(harness, server)).toEqual(stateBefore)
	end)

	it("refuses buying an owned item and costs nothing, even when the balance would not cover it", function()
		for _, starCoinPrice in { 100, 5000 } do
			local harness, server = createHarnessWithLoadedPlayer(function(saveData)
				giveExampleBalances(saveData)
				table.insert(saveData.ownedDanceIds, "neon_spin")
			end)
			local stateBefore = captureObservableState(harness, server)
			local spendOutcome =
				RewardLedgerPhaseTwoTestCallers.purchaseDance(server.rewardLedger, PLAYER, "neon_spin", starCoinPrice)
			expect(spendOutcome).toEqual({ rewardLedgerOutcome = "Declined", declineReason = ALREADY_OWNED })
			expect(captureObservableState(harness, server)).toEqual(stateBefore)
		end
	end)

	it("refuses buying the same cosmetic a second time", function()
		local _, server = createHarnessWithLoadedPlayer(giveExampleBalances)
		RewardLedgerPhaseTwoTestCallers.purchaseCosmetic(server.rewardLedger, PLAYER, "title_rising_star", 100)
		local secondOutcome =
			RewardLedgerPhaseTwoTestCallers.purchaseCosmetic(server.rewardLedger, PLAYER, "title_rising_star", 100)
		expect(secondOutcome.declineReason).toBe(ALREADY_OWNED)
		expect(server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).starCoinBalance).toBe(250)
	end)

	it("logs every applied spend with its purchaseKind and amounts", function()
		local _, server = createHarnessWithLoadedPlayer(giveExampleBalances)
		RewardLedgerPhaseTwoTestCallers.purchaseDance(server.rewardLedger, PLAYER, "neon_spin", 100)
		local spendLogLine = server.ledgerLogger.loggedInformation[#server.ledgerLogger.loggedInformation]
		expect(string.find(spendLogLine, "purchaseKind Dance", 1, true) ~= nil).toBeTrue()
		expect(string.find(spendLogLine, "350 -> 250", 1, true) ~= nil).toBeTrue()
	end)
end)

describe("RewardLedger refuses programming errors loudly and changes nothing", function()
	local function expectRefusedLoudlyWithoutChange(performOperation, expectedMessageFragment)
		local harness, server = createHarnessWithLoadedPlayer(giveExampleBalances)
		local stateBefore = captureObservableState(harness, server)
		expect(function()
			performOperation(server.rewardLedger)
		end).toThrow(expectedMessageFragment)
		expect(captureObservableState(harness, server)).toEqual(stateBefore)
		return server
	end

	it("refuses an unknown rewardSourceKind, including the later Phase 3-4 kinds, and logs it", function()
		for _, unknownRewardSourceKind in { "Tournament", "StylingCommission", "HiddenQuest", "themedround", 7 } do
			local server = expectRefusedLoudlyWithoutChange(function(rewardLedger)
				rewardLedger:grantStarCoinsAndFans(
					PLAYER,
					createValidGrantRequest({ rewardSourceKind = unknownRewardSourceKind })
				)
			end, "unknown rewardSourceKind")
			expect(#server.ledgerLogger.loggedWarnings).toBe(1)
		end
	end)

	it("refuses a missing rewardSourceKind", function()
		expectRefusedLoudlyWithoutChange(function(rewardLedger)
			local starCoinAndFanGrantRequest = createValidGrantRequest()
			starCoinAndFanGrantRequest.rewardSourceKind = nil
			rewardLedger:grantStarCoinsAndFans(PLAYER, starCoinAndFanGrantRequest)
		end, "unknown rewardSourceKind")
	end)

	it("refuses a ThemedRound grant that bypasses grantThemedRoundReward", function()
		expectRefusedLoudlyWithoutChange(function(rewardLedger)
			rewardLedger:grantStarCoinsAndFans(PLAYER, createValidGrantRequest({ rewardSourceKind = "ThemedRound" }))
		end, "grantThemedRoundReward")
	end)

	it("refuses an unknown purchaseKind and logs it", function()
		for _, unknownPurchaseKind in { "Robux", "dance", false } do
			local server = expectRefusedLoudlyWithoutChange(function(rewardLedger)
				rewardLedger:spendStarCoins(PLAYER, createValidSpendRequest({ purchaseKind = unknownPurchaseKind }))
			end, "unknown purchaseKind")
			expect(#server.ledgerLogger.loggedWarnings).toBe(1)
		end
	end)

	it("refuses amounts that are not whole numbers >= 0", function()
		for _, invalidAmount in { -1, 2.5, 0 / 0, math.huge, "10" } do
			expectRefusedLoudlyWithoutChange(function(rewardLedger)
				rewardLedger:grantStarCoinsAndFans(
					PLAYER,
					createValidGrantRequest({ starCoinsToGrant = invalidAmount })
				)
			end, "starCoinsToGrant must be a whole number")
			expectRefusedLoudlyWithoutChange(function(rewardLedger)
				rewardLedger:grantStarCoinsAndFans(PLAYER, createValidGrantRequest({ fanCountToGrant = invalidAmount }))
			end, "fanCountToGrant must be a whole number")
			expectRefusedLoudlyWithoutChange(function(rewardLedger)
				rewardLedger:spendStarCoins(PLAYER, createValidSpendRequest({ starCoinPrice = invalidAmount }))
			end, "starCoinPrice must be a whole number")
		end
	end)

	it("refuses a request without its eligibility check or record writer", function()
		expectRefusedLoudlyWithoutChange(function(rewardLedger)
			local starCoinAndFanGrantRequest = createValidGrantRequest()
			starCoinAndFanGrantRequest.writeGrantRecordThatPreventsRepeat = nil
			rewardLedger:grantStarCoinsAndFans(PLAYER, starCoinAndFanGrantRequest)
		end, "writeGrantRecordThatPreventsRepeat must be a function")
		expectRefusedLoudlyWithoutChange(function(rewardLedger)
			local starCoinSpendRequest = createValidSpendRequest()
			starCoinSpendRequest.writePurchaseRecordThatPreventsRepeat = nil
			rewardLedger:spendStarCoins(PLAYER, starCoinSpendRequest)
		end, "writePurchaseRecordThatPreventsRepeat must be a function")
		expectRefusedLoudlyWithoutChange(function(rewardLedger)
			local starCoinSpendRequest = createValidSpendRequest()
			starCoinSpendRequest.checkPurchaseEligibility = nil
			rewardLedger:spendStarCoins(PLAYER, starCoinSpendRequest)
		end, "checkPurchaseEligibility must be a function")
	end)

	it("refuses a record writer that writes no record (the operation would be repeatable)", function()
		expectRefusedLoudlyWithoutChange(function(rewardLedger)
			rewardLedger:grantStarCoinsAndFans(
				PLAYER,
				createValidGrantRequest({ writeGrantRecordThatPreventsRepeat = function() end })
			)
		end, "wrote no record")
		expectRefusedLoudlyWithoutChange(function(rewardLedger)
			rewardLedger:spendStarCoins(
				PLAYER,
				createValidSpendRequest({ writePurchaseRecordThatPreventsRepeat = function() end })
			)
		end, "wrote no record")
	end)

	it("refuses a record writer that changes starCoinBalance or fanCount itself", function()
		for _, balanceFieldName in { "starCoinBalance", "fanCount" } do
			expectRefusedLoudlyWithoutChange(function(rewardLedger)
				rewardLedger:grantStarCoinsAndFans(
					PLAYER,
					createValidGrantRequest({
						writeGrantRecordThatPreventsRepeat = function(saveDataDraft)
							table.insert(saveDataDraft.redeemedPromoCodeIds, "launch_2026")
							saveDataDraft[balanceFieldName] += 1
						end,
					})
				)
			end, "only the ledger may")
		end
	end)

	it("refuses an eligibility check that tries to change the save", function()
		expectRefusedLoudlyWithoutChange(function(rewardLedger)
			rewardLedger:grantStarCoinsAndFans(
				PLAYER,
				createValidGrantRequest({
					checkGrantEligibility = function(saveDataReadOnlyView)
						saveDataReadOnlyView.dailyProgress.claimedDailyQuestIds[1] = "sneaky"
						return true
					end,
				})
			)
		end, "readonly")
	end)

	it("refuses an eligibility check that declines without a reason or returns a non-boolean", function()
		expectRefusedLoudlyWithoutChange(function(rewardLedger)
			rewardLedger:spendStarCoins(
				PLAYER,
				createValidSpendRequest({
					checkPurchaseEligibility = function()
						return false
					end,
				})
			)
		end, "non-empty reason")
		expectRefusedLoudlyWithoutChange(function(rewardLedger)
			rewardLedger:spendStarCoins(
				PLAYER,
				createValidSpendRequest({
					checkPurchaseEligibility = function()
						return "yes" :: any
					end,
				})
			)
		end, "must return true or false")
	end)

	it("refuses a missing dependency", function()
		expect(function()
			RewardLedger.new({ logger = {} })
		end).toThrow("missing dependency playerSaveDataKeeper")
	end)
end)
