-- Pins the RewardLedger header promises about logging (spec §3.3: every grant and spend is logged)
-- and about checking each request before anything runs.

local UnitTestFramework = require("../Support/UnitTestFramework")
local RewardLedger = require("../../src/server/RewardLedger")
local RewardLedgerCrashableServerTestHarness = require("./RewardLedgerCrashableServerTestHarness")
local RewardLedgerPhaseTwoTestCallers = require("./RewardLedgerPhaseTwoTestCallers")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = RewardLedgerCrashableServerTestHarness.EXAMPLE_PLAYER_USER_ID
local createHarnessWithLoadedPlayer = RewardLedgerCrashableServerTestHarness.createHarnessWithLoadedPlayer

-- A list cannot hold nil, so a marker stands for "field missing".
local MISSING_FIELD_MARKER = table.freeze({})
local INVALID_DESCRIPTIONS_FOR_LOGS = { MISSING_FIELD_MARKER, "", 42 }

local function describeAsRequestValue(invalidDescription: any): any
	return if invalidDescription == MISSING_FIELD_MARKER then nil else invalidDescription
end

local function giveStarCoins(saveData)
	saveData.starCoinBalance = 350
end

local function createPromoGrantRequest(grantDescriptionForLogs)
	return {
		rewardSourceKind = RewardLedger.REWARD_SOURCE_KINDS.PromoCode,
		starCoinsToGrant = 300,
		fanCountToGrant = 0,
		grantDescriptionForLogs = grantDescriptionForLogs,
		checkGrantEligibility = function()
			return true
		end,
		writeGrantRecordThatPreventsRepeat = function(saveDataDraft)
			table.insert(saveDataDraft.redeemedPromoCodeIds, "launch_2026")
		end,
	}
end

local function createDanceSpendRequest(purchaseDescriptionForLogs)
	return {
		purchaseKind = RewardLedger.PURCHASE_KINDS.Dance,
		starCoinPrice = 100,
		purchaseDescriptionForLogs = purchaseDescriptionForLogs,
		checkPurchaseEligibility = function()
			return true
		end,
		writePurchaseRecordThatPreventsRepeat = function(saveDataDraft)
			table.insert(saveDataDraft.ownedDanceIds, "neon_spin")
		end,
	}
end

local function expectLogLineNaming(logLine: string?, expectedFragments: { string })
	expect(logLine ~= nil).toBeTrue()
	for _, expectedFragment in expectedFragments do
		expect({ logLine, string.find(logLine :: string, expectedFragment, 1, true) ~= nil }).toEqual({
			logLine,
			true,
		})
	end
end

local function findOnlyNewLogLine(loggedMessages, countBefore: number): string?
	expect(#loggedMessages).toBe(countBefore + 1)
	return loggedMessages[#loggedMessages]
end

describe("RewardLedger logs every declined grant and spend", function()
	it("logs a grant declined by its eligibility check at information level, naming player, kind and reason", function()
		local _, server = createHarnessWithLoadedPlayer(function(saveData)
			saveData.dailyProgress.claimedDailyQuestIds = { "complete_rounds_5" }
		end)
		local informationCountBefore = #server.ledgerLogger.loggedInformation
		local warningCountBefore = #server.ledgerLogger.loggedWarnings
		RewardLedgerPhaseTwoTestCallers.claimDailyQuestReward(server.rewardLedger, PLAYER, "complete_rounds_5", 100)
		local declineLogLine = findOnlyNewLogLine(server.ledgerLogger.loggedInformation, informationCountBefore)
		expectLogLineNaming(
			declineLogLine,
			{ "declined", tostring(PLAYER), "rewardSourceKind DailyQuest", "AlreadyClaimed" }
		)
		expect(#server.ledgerLogger.loggedWarnings).toBe(warningCountBefore)
	end)

	it("logs a spend declined by its eligibility check, naming player, kind and reason", function()
		local _, server = createHarnessWithLoadedPlayer(function(saveData)
			giveStarCoins(saveData)
			table.insert(saveData.ownedCosmeticIds, "title_rising_star")
		end)
		local informationCountBefore = #server.ledgerLogger.loggedInformation
		RewardLedgerPhaseTwoTestCallers.purchaseCosmetic(server.rewardLedger, PLAYER, "title_rising_star", 100)
		local declineLogLine = findOnlyNewLogLine(server.ledgerLogger.loggedInformation, informationCountBefore)
		expectLogLineNaming(declineLogLine, { "declined", tostring(PLAYER), "purchaseKind Cosmetic", "AlreadyOwned" })
	end)

	it("logs a spend declined for InsufficientStarCoins, naming player, kind and reason", function()
		local _, server = createHarnessWithLoadedPlayer(giveStarCoins)
		local informationCountBefore = #server.ledgerLogger.loggedInformation
		RewardLedgerPhaseTwoTestCallers.purchaseDance(server.rewardLedger, PLAYER, "neon_spin", 351)
		local declineLogLine = findOnlyNewLogLine(server.ledgerLogger.loggedInformation, informationCountBefore)
		expectLogLineNaming(
			declineLogLine,
			{ "declined", tostring(PLAYER), "purchaseKind Dance", "InsufficientStarCoins" }
		)
	end)

	it("logs a duplicate round reward at warning level, naming player, kind, round and reason", function()
		local _, server = createHarnessWithLoadedPlayer()
		local themedRoundCompletion =
			{ roundId = "round-9", themeId = "y2k_pop", starCount = 2, scoredOutfitStylingItemKeys = {} }
		server.rewardLedger:grantThemedRoundReward(PLAYER, themedRoundCompletion)
		local warningCountBefore = #server.ledgerLogger.loggedWarnings
		server.rewardLedger:grantThemedRoundReward(PLAYER, themedRoundCompletion)
		local declineLogLine = findOnlyNewLogLine(server.ledgerLogger.loggedWarnings, warningCountBefore)
		expectLogLineNaming(declineLogLine, {
			"declined",
			tostring(PLAYER),
			"rewardSourceKind ThemedRound",
			"round-9",
			"RoundRewardAlreadyGranted",
		})
	end)
end)

describe("RewardLedger checks every request before anything runs", function()
	local function expectRefusedLoudlyWithoutChange(performOperation, expectedMessageFragment: string)
		local harness, server = createHarnessWithLoadedPlayer(giveStarCoins)
		local saveDataBefore = server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
		local startedOperationCountBefore = harness.fakePlayerSaveDataStorage:countStartedOperations()
		local warningCountBefore = #server.ledgerLogger.loggedWarnings
		expect(function()
			performOperation(server.rewardLedger)
		end).toThrow(expectedMessageFragment)
		expect(server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)).toEqual(saveDataBefore)
		expect(harness.fakePlayerSaveDataStorage:countStartedOperations()).toBe(startedOperationCountBefore)
		expect(#server.ledgerLogger.loggedWarnings).toBe(warningCountBefore + 1)
	end

	it("refuses a missing or empty grantDescriptionForLogs", function()
		for _, invalidDescription in INVALID_DESCRIPTIONS_FOR_LOGS do
			expectRefusedLoudlyWithoutChange(function(rewardLedger)
				rewardLedger:grantStarCoinsAndFans(
					PLAYER,
					createPromoGrantRequest(describeAsRequestValue(invalidDescription))
				)
			end, "grantDescriptionForLogs must be a non-empty string")
		end
	end)

	it("refuses a missing or empty purchaseDescriptionForLogs", function()
		for _, invalidDescription in INVALID_DESCRIPTIONS_FOR_LOGS do
			expectRefusedLoudlyWithoutChange(function(rewardLedger)
				rewardLedger:spendStarCoins(PLAYER, createDanceSpendRequest(describeAsRequestValue(invalidDescription)))
			end, "purchaseDescriptionForLogs must be a non-empty string")
		end
	end)

	it("refuses an empty roundId or themeId", function()
		for _, emptiedFieldName in { "roundId", "themeId" } do
			local themedRoundCompletion =
				{ roundId = "round-1", themeId = "y2k_pop", starCount = 2, scoredOutfitStylingItemKeys = {} }
			themedRoundCompletion[emptiedFieldName] = ""
			expectRefusedLoudlyWithoutChange(function(rewardLedger)
				rewardLedger:grantThemedRoundReward(PLAYER, themedRoundCompletion)
			end, emptiedFieldName .. " must be a non-empty string")
		end
	end)

	it("refuses a request that is not a table", function()
		expectRefusedLoudlyWithoutChange(function(rewardLedger)
			rewardLedger:grantStarCoinsAndFans(PLAYER, "promo" :: any)
		end, "needs a starCoinAndFanGrantRequest table")
		expectRefusedLoudlyWithoutChange(function(rewardLedger)
			rewardLedger:spendStarCoins(PLAYER, nil :: any)
		end, "needs a starCoinSpendRequest table")
		expectRefusedLoudlyWithoutChange(function(rewardLedger)
			rewardLedger:grantThemedRoundReward(PLAYER, 4 :: any)
		end, "needs a themedRoundCompletion table")
	end)

	it("refuses an eligibility check that declines with an empty reason", function()
		local _, server = createHarnessWithLoadedPlayer(giveStarCoins)
		local saveDataBefore = server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
		local spendRequest = createDanceSpendRequest("dance neon_spin")
		spendRequest.checkPurchaseEligibility = function()
			return false, ""
		end
		expect(function()
			server.rewardLedger:spendStarCoins(PLAYER, spendRequest)
		end).toThrow("non-empty reason")
		expect(server.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)).toEqual(saveDataBefore)
	end)

	it("refuses a missing logger dependency", function()
		expect(function()
			RewardLedger.new({ playerSaveDataKeeper = {} })
		end).toThrow("missing dependency logger")
	end)

	it("raises if a keeper ever reports a record-writing change as making no difference", function()
		local keeperReportingNoDifference = {}
		function keeperReportingNoDifference.applyChangeToPlayerSaveData()
			return { changeOutcome = "AppliedWithoutAnyDifference" }
		end
		local rewardLedger = RewardLedger.new({
			playerSaveDataKeeper = keeperReportingNoDifference,
			logger = { logInformation = function() end, logWarning = function() end },
		})
		expect(function()
			rewardLedger:grantStarCoinsAndFans(PLAYER, createPromoGrantRequest("promo code launch_2026"))
		end).toThrow("reported no difference")
	end)
end)
