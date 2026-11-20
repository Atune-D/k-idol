-- Spec §3.3 "A reward and its record are one change" for the promo code redemption, end to end
-- through the redeemer: a crash or save failure anywhere between the redemption and its save
-- leaves the stored save holding the Star Coins together with the redeemedPromoCodeIds record,
-- or neither; and after the reload the code can be paid at most once in total.

local UnitTestFramework = require("../Support/UnitTestFramework")
local PromoCodeRedeemerTestHarness = require("./PromoCodeRedeemerTestHarness")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local EXAMPLE_PLAYER_USER_ID = PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID
local STAGE_DEBUT_ID = PromoCodeRedeemerTestHarness.STAGE_DEBUT_PROMO_CODE_ID
local STAGE_DEBUT_REWARD = PromoCodeRedeemerTestHarness.STAGE_DEBUT_STAR_COIN_REWARD
local STARTING_BALANCE = PromoCodeRedeemerTestHarness.STARTING_STAR_COIN_BALANCE
local countRedemptionRecords = PromoCodeRedeemerTestHarness.countRedemptionRecords

-- "Both", "Neither", or a description of the inconsistency.
local function classifyRewardAndRecord(saveData): string
	local redemptionRecordCount = countRedemptionRecords(saveData, STAGE_DEBUT_ID)
	if saveData.starCoinBalance == STARTING_BALANCE + STAGE_DEBUT_REWARD and redemptionRecordCount == 1 then
		return "Both"
	end
	if saveData.starCoinBalance == STARTING_BALANCE and redemptionRecordCount == 0 then
		return "Neither"
	end
	return string.format(
		"Inconsistent (starCoinBalance %d, %d redemption records)",
		saveData.starCoinBalance,
		redemptionRecordCount
	)
end

-- Each point runs right after the redemption was applied in memory (its save write in flight).
local FAILURE_INJECTION_POINTS = {
	{
		pointName = "crash while the save write is in flight; it never arrives",
		injectFailureBeforeCrash = function() end,
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
		injectFailureBeforeCrash = function(harness)
			harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(EXAMPLE_PLAYER_USER_ID)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Both",
	},
	{
		pointName = "save fails, crash before its retry",
		injectFailureBeforeCrash = function(harness)
			harness.fakePlayerSaveDataStorage:failOldestPendingOperation(EXAMPLE_PLAYER_USER_ID)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Neither",
	},
	{
		pointName = "save fails, its retry lands, crash before the answer",
		injectFailureBeforeCrash = function(harness)
			harness.fakePlayerSaveDataStorage:failOldestPendingOperation(EXAMPLE_PLAYER_USER_ID)
			harness.advanceSeconds(2)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLanded",
		expectedReloadedState = "Both",
	},
	{
		pointName = "player leaves, the save fails, crash while the final save is in flight",
		injectFailureBeforeCrash = function(harness)
			harness.server.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(EXAMPLE_PLAYER_USER_ID)
			harness.fakePlayerSaveDataStorage:failOldestPendingOperation(EXAMPLE_PLAYER_USER_ID)
		end,
		inFlightWriteFateAtCrash = "InFlightWritesLost",
		expectedReloadedState = "Neither",
	},
}

-- After the reload the code pays at most once in total, whatever the reloaded state was.
local function expectCodePaysAtMostOnceAfterReload(harness, reloadedState: string)
	local firstAnswerAfterReload = harness.redeem("StageDebut")
	if reloadedState == "Both" then
		expect(firstAnswerAfterReload).toEqual({ isAccepted = false, rejectionReason = "AlreadyRedeemed" })
	else
		expect(firstAnswerAfterReload).toEqual({ isAccepted = true, starCoinsGranted = STAGE_DEBUT_REWARD })
	end
	harness.waitOutAttemptInterval()
	expect(harness.redeem("STAGEDEBUT")).toEqual({ isAccepted = false, rejectionReason = "AlreadyRedeemed" })
	harness.completeEveryPendingSave()
	expect(classifyRewardAndRecord(harness.readStoredSaveData())).toBe("Both")
end

local function redeemThenCrashAtPoint(failureInjectionPoint)
	local harness = PromoCodeRedeemerTestHarness.createHarness()
	expect(harness.redeem("StageDebut")).toEqual({ isAccepted = true, starCoinsGranted = STAGE_DEBUT_REWARD })
	expect(classifyRewardAndRecord(harness.readInMemorySaveData())).toBe("Both")
	expect(classifyRewardAndRecord(harness.readStoredSaveData())).toBe("Neither")
	expect(harness.fakePlayerSaveDataStorage:countPendingOperations(EXAMPLE_PLAYER_USER_ID)).toBe(1)

	failureInjectionPoint.injectFailureBeforeCrash(harness)
	harness.crashAndLoadPlayerOnNewServer(failureInjectionPoint.inFlightWriteFateAtCrash)
	return harness
end

describe("PromoCodeRedeemer redemption under save failures and crashes", function()
	for _, failureInjectionPoint in FAILURE_INJECTION_POINTS do
		it(failureInjectionPoint.pointName .. " -> " .. failureInjectionPoint.expectedReloadedState, function()
			local harness = redeemThenCrashAtPoint(failureInjectionPoint)
			expect(classifyRewardAndRecord(harness.readStoredSaveData())).toBe(
				failureInjectionPoint.expectedReloadedState
			)
			expect(classifyRewardAndRecord(harness.readInMemorySaveData())).toBe(
				failureInjectionPoint.expectedReloadedState
			)
			expectCodePaysAtMostOnceAfterReload(harness, failureInjectionPoint.expectedReloadedState)
		end)
	end

	it("random sequences of redemptions, save outcomes and crashes never pay a code twice", function()
		SeededRandomTrials.runSeededRandomTrials(40, function(seededRandomNumberGenerator)
			local harness = PromoCodeRedeemerTestHarness.createHarness()
			local fakeStorage = harness.fakePlayerSaveDataStorage
			for _ = 1, seededRandomNumberGenerator.nextWholeNumberInRange(3, 12) do
				local stepKind = seededRandomNumberGenerator.pickRandomListElement({
					"Redeem",
					"Redeem",
					"CompleteSave",
					"FailSave",
					"AdvanceTime",
					"CrashLosingWrites",
					"CrashLandingWrites",
				})
				if stepKind == "Redeem" then
					local redemptionAnswer = harness.redeem(
						seededRandomNumberGenerator.pickRandomListElement({ "StageDebut", "stagedebut", "STAGEDEBUT" })
					)
					expect(redemptionAnswer.isAccepted == true or redemptionAnswer.rejectionReason ~= nil).toBeTrue()
				elseif
					stepKind == "CompleteSave" and fakeStorage:countPendingOperations(EXAMPLE_PLAYER_USER_ID) > 0
				then
					fakeStorage:completeOldestPendingOperation(EXAMPLE_PLAYER_USER_ID)
				elseif stepKind == "FailSave" and fakeStorage:countPendingOperations(EXAMPLE_PLAYER_USER_ID) > 0 then
					fakeStorage:failOldestPendingOperation(EXAMPLE_PLAYER_USER_ID)
				elseif stepKind == "AdvanceTime" then
					harness.advanceSeconds(seededRandomNumberGenerator.nextWholeNumberInRange(0, 15))
				elseif stepKind == "CrashLosingWrites" then
					harness.crashAndLoadPlayerOnNewServer("InFlightWritesLost")
				elseif stepKind == "CrashLandingWrites" then
					harness.crashAndLoadPlayerOnNewServer("InFlightWritesLanded")
				end
				local storedState = classifyRewardAndRecord(harness.readStoredSaveData())
				local inMemoryState = classifyRewardAndRecord(harness.readInMemorySaveData())
				expect(storedState == "Both" or storedState == "Neither").toBeTrue()
				expect(inMemoryState == "Both" or inMemoryState == "Neither").toBeTrue()
			end
			harness.crashAndLoadPlayerOnNewServer("InFlightWritesLanded")
			expectCodePaysAtMostOnceAfterReload(harness, classifyRewardAndRecord(harness.readStoredSaveData()))
		end)
	end)
end)
