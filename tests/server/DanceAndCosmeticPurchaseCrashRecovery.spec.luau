-- Spec §3.3 "A reward and its record are one change" (row "Dance or cosmetic purchase") and §6.2
-- "Unit: ledger": a purchase made through DanceAndCosmeticPurchaseRequestAnswerer, followed by a
-- crash or save failure at each point before the save is finished. The save loaded by the next
-- server holds the spend together with the ownership, or neither; and buying the item again then
-- pays at most once in total. Also: an equip that no save has written yet is lost with the crash
-- (it is an appearance change, §3.4) and never disturbs a purchase.

local DanceAndCosmeticRequestTestHarness = require("./DanceAndCosmeticRequestTestHarness")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = DanceAndCosmeticRequestTestHarness.PLAYER
local STARTING_BALANCE = 1000

local PURCHASE_SCENARIOS = {
	{
		purchaseName = "dance purchase",
		purchasedItemId = "neon_spin",
		starCoinPrice = 900,
		ownedItemIdsFieldName = "ownedDanceIds",
		purchase = function(shopHarness)
			return shopHarness.purchaseRequestAnswerer:purchaseDanceWithStarCoinsAndBuildAnswer(PLAYER, "neon_spin")
		end,
	},
	{
		purchaseName = "cosmetic purchase",
		purchasedItemId = "title_rising_star",
		starCoinPrice = 300,
		ownedItemIdsFieldName = "ownedCosmeticIds",
		purchase = function(shopHarness)
			return shopHarness.purchaseRequestAnswerer:purchaseCosmeticWithStarCoinsAndBuildAnswer(
				PLAYER,
				"title_rising_star"
			)
		end,
	},
}

local FAILURE_INJECTION_POINTS = {
	{
		pointName = "crash while the save write is in flight; it never arrives",
		injectFailureBeforeCrash = function(crashableHarness)
			expect(crashableHarness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Neither",
	},
	{
		pointName = "crash after the write arrived, before its answer",
		injectFailureBeforeCrash = function() end,
		inFlightWriteFateAtCrash = "InFlightWritesLanded",
		expectedReloadedState = "Both",
	},
	{
		pointName = "crash after the save succeeded",
		injectFailureBeforeCrash = function(crashableHarness)
			crashableHarness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Both",
	},
	{
		pointName = "save fails, crash before its retry",
		injectFailureBeforeCrash = function(crashableHarness)
			crashableHarness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Neither",
	},
	{
		pointName = "save fails, the retry lands, then crash",
		injectFailureBeforeCrash = function(crashableHarness)
			crashableHarness.fakePlayerSaveDataStorage:failOldestPendingOperation(PLAYER)
			crashableHarness.advanceSeconds(2)
			crashableHarness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Both",
	},
	{
		pointName = "the write lands but its answer is lost, then crash",
		injectFailureBeforeCrash = function(crashableHarness)
			crashableHarness.fakePlayerSaveDataStorage:completeOldestPendingOperationButReportFailure(PLAYER)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Both",
	},
}

local function classifySpendAndOwnership(purchaseScenario, saveData): string
	local isOwned = table.find(saveData[purchaseScenario.ownedItemIdsFieldName], purchaseScenario.purchasedItemId)
		~= nil
	local isSpent = saveData.starCoinBalance == STARTING_BALANCE - purchaseScenario.starCoinPrice
	local isUnspent = saveData.starCoinBalance == STARTING_BALANCE
	if isOwned and isSpent then
		return "Both"
	end
	if not isOwned and isUnspent then
		return "Neither"
	end
	return string.format("Inconsistent (starCoinBalance %d, owned %s)", saveData.starCoinBalance, tostring(isOwned))
end

for _, purchaseScenario in PURCHASE_SCENARIOS do
	describe(purchaseScenario.purchaseName .. " and a crash", function()
		for _, failureInjectionPoint in FAILURE_INJECTION_POINTS do
			it(
				failureInjectionPoint.pointName
					.. ": reloaded save holds "
					.. failureInjectionPoint.expectedReloadedState,
				function()
					local shopHarness = DanceAndCosmeticRequestTestHarness.createShopHarness(
						DanceAndCosmeticRequestTestHarness.giveStarCoinBalance(STARTING_BALANCE)
					)
					local crashableHarness = shopHarness.crashableHarness
					expect(purchaseScenario.purchase(shopHarness)).toEqual({ isAccepted = true })
					failureInjectionPoint.injectFailureBeforeCrash(crashableHarness)
					crashableHarness.crashCurrentServer(failureInjectionPoint.inFlightWriteFateAtCrash)

					crashableHarness.startServerAndLoadPlayer(PLAYER)
					shopHarness.rebuildAnswerersForCurrentServer()
					local reloadedSaveData = shopHarness.readInMemorySaveData()
					expect(classifySpendAndOwnership(purchaseScenario, reloadedSaveData)).toBe(
						failureInjectionPoint.expectedReloadedState
					)

					-- Buying again pays at most once in total.
					local repeatAnswer = purchaseScenario.purchase(shopHarness)
					if failureInjectionPoint.expectedReloadedState == "Both" then
						expect(repeatAnswer).toEqual({ isAccepted = false, rejectionReason = "AlreadyOwned" })
						expect(shopHarness.readInMemorySaveData()).toEqual(reloadedSaveData)
					else
						expect(repeatAnswer).toEqual({ isAccepted = true })
					end
					expect(classifySpendAndOwnership(purchaseScenario, shopHarness.readInMemorySaveData())).toBe("Both")
				end
			)
		end
	end)
end

describe("an equip and a crash", function()
	it("an equip no save has written is lost with the crash; a purchase saved after it keeps both", function()
		local shopHarness = DanceAndCosmeticRequestTestHarness.createShopHarness(
			DanceAndCosmeticRequestTestHarness.giveStarCoinBalance(STARTING_BALANCE)
		)
		local crashableHarness = shopHarness.crashableHarness
		expect(shopHarness.equipRequestAnswerer:equipOwnedDanceAndBuildAnswer(PLAYER, "starter_step")).toEqual({
			isAccepted = true,
		})
		crashableHarness.crashCurrentServer("InFlightWritesLost")
		crashableHarness.startServerAndLoadPlayer(PLAYER)
		shopHarness.rebuildAnswerersForCurrentServer()
		expect(shopHarness.readInMemorySaveData().equippedDanceId).toBe("starter_wave")

		-- The equip is written by the purchase's save (the next save of any kind).
		crashableHarness.advanceSeconds(20)
		expect(shopHarness.equipRequestAnswerer:equipOwnedDanceAndBuildAnswer(PLAYER, "starter_step")).toEqual({
			isAccepted = true,
		})
		expect(shopHarness.purchaseRequestAnswerer:purchaseDanceWithStarCoinsAndBuildAnswer(PLAYER, "neon_spin")).toEqual({
			isAccepted = true,
		})
		crashableHarness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
		crashableHarness.crashCurrentServer("InFlightWritesLost")
		crashableHarness.startServerAndLoadPlayer(PLAYER)
		shopHarness.rebuildAnswerersForCurrentServer()
		local reloadedSaveData = shopHarness.readInMemorySaveData()
		expect(reloadedSaveData.equippedDanceId).toBe("starter_step")
		expect(reloadedSaveData.starCoinBalance).toBe(STARTING_BALANCE - 900)
		expect(table.find(reloadedSaveData.ownedDanceIds, "neon_spin") ~= nil).toBeTrue()
	end)
end)
