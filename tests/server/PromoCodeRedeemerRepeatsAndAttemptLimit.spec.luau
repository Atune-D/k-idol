-- Spec §2.10, §2.13, §3.4 and §6.2 "Unit: promo codes": a code pays once per player, also after a
-- save, a leave and a reload; attempts faster than 2 seconds are refused with TooManyAttempts
-- without the text being checked; the rate limiter is asked before anything else; and nothing is
-- redeemed until the player's save has loaded.

local UnitTestFramework = require("../Support/UnitTestFramework")
local PromoCodeCatalog = require("../../src/server/PromoCodeCatalog")
local PromoCodeFixtures = require("../fixtures/PromoCodeFixtures")
local PromoCodeRedeemer = require("../../src/server/PromoCodeRedeemer")
local PromoCodeRedeemerTestHarness = require("./PromoCodeRedeemerTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local EXAMPLE_PLAYER_USER_ID = PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID
local OTHER_PLAYER_USER_ID = PromoCodeRedeemerTestHarness.OTHER_PLAYER_USER_ID
local STAGE_DEBUT_ID = PromoCodeRedeemerTestHarness.STAGE_DEBUT_PROMO_CODE_ID
local STAGE_DEBUT_REWARD = PromoCodeRedeemerTestHarness.STAGE_DEBUT_STAR_COIN_REWARD
local STARTING_BALANCE = PromoCodeRedeemerTestHarness.STARTING_STAR_COIN_BALANCE
local countRedemptionRecords = PromoCodeRedeemerTestHarness.countRedemptionRecords

local ACCEPTED_STAGE_DEBUT_ANSWER = { isAccepted = true, starCoinsGranted = STAGE_DEBUT_REWARD }

local function expectPaidExactlyOnce(saveData)
	expect(saveData.starCoinBalance).toBe(STARTING_BALANCE + STAGE_DEBUT_REWARD)
	expect(countRedemptionRecords(saveData, STAGE_DEBUT_ID)).toBe(1)
end

-- Snapshot of everything the redeemer could have looked at, to compare before and after a request.
local function readObservedWork(harness)
	local observations = harness.observations
	return {
		promoCodeEntryFieldReadCount = observations.promoCodeEntryFieldReadCount,
		clockSecondsReadCount = observations.clockSecondsReadCount,
		saveDataLoadedQuestionCount = observations.saveDataLoadedQuestionCount,
		rewardLedgerGrantCallCount = observations.rewardLedgerGrantCallCount,
		redeemerLogLineCount = #observations.redeemerLogLines,
		inMemoryChangeRevision = harness.readInMemoryChangeRevision(),
	}
end

describe("PromoCodeRedeemer second redemption of a code", function()
	it("is refused AlreadyRedeemed on the same server, in any letter case, and changes nothing", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		expect(harness.redeem("StageDebut")).toEqual(ACCEPTED_STAGE_DEBUT_ANSWER)
		for _, repeatedPromoCodeText in { "StageDebut", "STAGEDEBUT", " stagedebut " } do
			harness.waitOutAttemptInterval()
			local revisionBeforeRepeat = harness.readInMemoryChangeRevision()
			expect(harness.redeem(repeatedPromoCodeText)).toEqual({
				isAccepted = false,
				rejectionReason = "AlreadyRedeemed",
			})
			expect(harness.readInMemoryChangeRevision()).toBe(revisionBeforeRepeat)
		end
		expectPaidExactlyOnce(harness.readInMemorySaveData())
	end)

	it("is refused after the redemption was saved, the player left and rejoined the same server", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		expect(harness.redeem("StageDebut")).toEqual(ACCEPTED_STAGE_DEBUT_ANSWER)
		harness.completeEveryPendingSave()
		expectPaidExactlyOnce(harness.readStoredSaveData())
		harness.leaveAndRejoinSameServer()
		expect(harness.redeem("stagedebut")).toEqual({ isAccepted = false, rejectionReason = "AlreadyRedeemed" })
		expectPaidExactlyOnce(harness.readInMemorySaveData())
		expect(harness.readInMemoryChangeRevision()).toBe(0)
	end)

	it("is refused after the player left and joined a different server", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		expect(harness.redeem("StageDebut")).toEqual(ACCEPTED_STAGE_DEBUT_ANSWER)
		harness.leaveAndJoinNewServer()
		expectPaidExactlyOnce(harness.readInMemorySaveData())
		expect(harness.redeem("STAGEDEBUT")).toEqual({ isAccepted = false, rejectionReason = "AlreadyRedeemed" })
		harness.completeEveryPendingSave()
		expectPaidExactlyOnce(harness.readStoredSaveData())
	end)

	it("one player's redemption does not stop another player redeeming the same code", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		harness.crashableHarness.startServerAndLoadPlayer(OTHER_PLAYER_USER_ID)
		expect(harness.redeem("StageDebut")).toEqual(ACCEPTED_STAGE_DEBUT_ANSWER)
		expect(harness.redeem("StageDebut", OTHER_PLAYER_USER_ID)).toEqual(ACCEPTED_STAGE_DEBUT_ANSWER)
		expect(harness.redeem("StageDebut", OTHER_PLAYER_USER_ID)).toEqual({
			isAccepted = false,
			rejectionReason = "TooManyAttempts",
		})
	end)

	it("redeeming one code does not use up another code", function()
		-- Both fixture codes active at once: a StageDebut variant whose window covers 1900000000.
		local harness = PromoCodeRedeemerTestHarness.createHarness({
			requestAtUnixSeconds = 1900000000,
			promoCodeEntries = {
				PromoCodeFixtures.createFixturePromoCode({ validUntilUnixSeconds = 2000000000 }),
				PromoCodeFixtures.createFixturePromoCodeCatalog()[2],
			},
		})
		expect(harness.redeem("encore-2030")).toEqual({ isAccepted = true, starCoinsGranted = 50 })
		harness.waitOutAttemptInterval()
		expect(harness.redeem("StageDebut")).toEqual(ACCEPTED_STAGE_DEBUT_ANSWER)
		expect(harness.readInMemorySaveData().redeemedPromoCodeIds).toEqual({ "fixture_encore_week", STAGE_DEBUT_ID })
		expect(harness.readInMemorySaveData().starCoinBalance).toBe(STARTING_BALANCE + 50 + STAGE_DEBUT_REWARD)
	end)

	it("with several codes redeemed, retrying any of them is AlreadyRedeemed, also after a reload", function()
		-- Both fixture codes active at once, so the earlier redemption is not the latest record.
		local harness = PromoCodeRedeemerTestHarness.createHarness({
			requestAtUnixSeconds = 1900000000,
			promoCodeEntries = {
				PromoCodeFixtures.createFixturePromoCode({ validUntilUnixSeconds = 2000000000 }),
				PromoCodeFixtures.createFixturePromoCodeCatalog()[2],
			},
		})
		local BOTH_PAID_BALANCE = STARTING_BALANCE + STAGE_DEBUT_REWARD + 50
		local BOTH_RECORDS = { STAGE_DEBUT_ID, "fixture_encore_week" }
		expect(harness.redeem("StageDebut")).toEqual(ACCEPTED_STAGE_DEBUT_ANSWER)
		harness.waitOutAttemptInterval()
		expect(harness.redeem("encore-2030")).toEqual({ isAccepted = true, starCoinsGranted = 50 })
		local revisionAfterBothRedemptions = harness.readInMemoryChangeRevision()

		local function expectEveryRetryRefused(retriedPromoCodeTexts: { string })
			for _, retriedPromoCodeText in retriedPromoCodeTexts do
				harness.waitOutAttemptInterval()
				expect({ retriedPromoCodeText, harness.redeem(retriedPromoCodeText) }).toEqual({
					retriedPromoCodeText,
					{ isAccepted = false, rejectionReason = "AlreadyRedeemed" },
				})
			end
			local inMemorySaveData = harness.readInMemorySaveData()
			expect(inMemorySaveData.starCoinBalance).toBe(BOTH_PAID_BALANCE)
			expect(inMemorySaveData.redeemedPromoCodeIds).toEqual(BOTH_RECORDS)
		end

		expectEveryRetryRefused({ "STAGEDEBUT", "ENCORE-2030", "stagedebut", "encore-2030" })
		expect(harness.readInMemoryChangeRevision()).toBe(revisionAfterBothRedemptions)

		harness.completeEveryPendingSave()
		harness.leaveAndJoinNewServer()
		expectEveryRetryRefused({ "StageDebut", "Encore-2030", "STAGEDEBUT", "ENCORE-2030" })
		expect(harness.readInMemoryChangeRevision()).toBe(0)
		harness.completeEveryPendingSave()
		expect(harness.readStoredSaveData().starCoinBalance).toBe(BOTH_PAID_BALANCE)
		expect(harness.readStoredSaveData().redeemedPromoCodeIds).toEqual(BOTH_RECORDS)
	end)
end)

describe("PromoCodeRedeemer two redemptions of the same code in the same instant", function()
	it("with the real limiter: the second answers TooManyAttempts and the code pays once", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		expect(harness.redeem("StageDebut")).toEqual(ACCEPTED_STAGE_DEBUT_ANSWER)
		expect(harness.redeem("StageDebut")).toEqual({ isAccepted = false, rejectionReason = "TooManyAttempts" })
		expectPaidExactlyOnce(harness.readInMemorySaveData())
	end)

	it("past the limiter (a second request path on the same save): AlreadyRedeemed before any save", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		local secondRedeemerOnSameSave = PromoCodeRedeemer.new({
			playerSaveDataKeeper = harness.server.playerSaveDataKeeper,
			rewardLedger = harness.server.rewardLedger,
			playerRequestRateLimiter = {
				admitOrRefusePlayerRequest = function()
					return { isRequestAllowed = true }
				end,
			},
			clock = harness.fakeClock,
			logger = { logInformation = function() end, logWarning = function() end },
			promoCodeEntries = PromoCodeCatalog.freezePromoCodeCatalog(
				PromoCodeFixtures.createFixturePromoCodeCatalog()
			),
		})
		expect(harness.redeem("StageDebut")).toEqual(ACCEPTED_STAGE_DEBUT_ANSWER)
		expect(secondRedeemerOnSameSave:redeemPromoCodeAndAnswerRequest(EXAMPLE_PLAYER_USER_ID, "stagedebut")).toEqual({
			isAccepted = false,
			rejectionReason = "AlreadyRedeemed",
		})
		expect(secondRedeemerOnSameSave:redeemPromoCodeAndAnswerRequest(EXAMPLE_PLAYER_USER_ID, "STAGEDEBUT")).toEqual({
			isAccepted = false,
			rejectionReason = "AlreadyRedeemed",
		})
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations()).toBe(1)
		expectPaidExactlyOnce(harness.readInMemorySaveData())
		harness.completeEveryPendingSave()
		expectPaidExactlyOnce(harness.readStoredSaveData())
	end)
end)

describe("PromoCodeRedeemer attempt limit (one attempt every 2 seconds, §2.10)", function()
	it("an attempt 1.999 s after the last one is refused without the text being checked", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		expect(harness.redeem("NotACode")).toEqual({ isAccepted = false, rejectionReason = "UnknownPromoCode" })
		harness.advanceSeconds(1.999)
		local workBeforeRefusedAttempt = readObservedWork(harness)
		expect(harness.redeem("StageDebut")).toEqual({ isAccepted = false, rejectionReason = "TooManyAttempts" })
		-- The catalog was not consulted, the clock not read, the save not asked about, nothing granted or logged.
		expect(readObservedWork(harness)).toEqual(workBeforeRefusedAttempt)
		expect(harness.readInMemorySaveData().starCoinBalance).toBe(STARTING_BALANCE)
	end)

	it("a refused attempt never touches the value the device sent, whatever it is", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		local metamethodCallCount = 0
		local function countMetamethodCall(returnedValue)
			return function()
				metamethodCallCount += 1
				return returnedValue
			end
		end
		-- No raw fields: reading ANY field, its length, its text or iterating it calls a metamethod.
		local trappedDeviceValue = setmetatable({}, {
			__tostring = countMetamethodCall("StageDebut"),
			__index = countMetamethodCall("StageDebut"),
			__len = countMetamethodCall(10),
			__eq = countMetamethodCall(true),
			__lt = countMetamethodCall(true),
			__le = countMetamethodCall(true),
			__concat = countMetamethodCall("StageDebut"),
			__call = countMetamethodCall("StageDebut"),
			__iter = countMetamethodCall(next),
		})
		local refusedDeviceValues = { trappedDeviceValue, string.rep("StageDebut ", 400000) }
		expect(harness.redeem("NotACode").rejectionReason).toBe("UnknownPromoCode")
		local workBeforeRefusedAttempts = readObservedWork(harness)
		for _, refusedDeviceValue in refusedDeviceValues do
			harness.advanceSeconds(0.5)
			local didAnswer, refusalAnswer = pcall(harness.redeem, refusedDeviceValue)
			expect(didAnswer).toBeTrue()
			expect(refusalAnswer).toEqual({ isAccepted = false, rejectionReason = "TooManyAttempts" })
		end
		expect(metamethodCallCount).toBe(0)
		expect(readObservedWork(harness)).toEqual(workBeforeRefusedAttempts)
	end)

	it("an attempt exactly 2 s after the last admitted one is checked", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		harness.redeem("NotACode")
		harness.advanceSeconds(2)
		expect(harness.redeem("StageDebut")).toEqual(ACCEPTED_STAGE_DEBUT_ANSWER)
		expect(harness.observations.rateLimiterQuestionCount).toBe(2)
	end)

	it("a burst of attempts is refused, each refusal checks nothing, and only the first pays", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		expect(harness.redeem("StageDebut")).toEqual(ACCEPTED_STAGE_DEBUT_ANSWER)
		local workAfterFirstAttempt = readObservedWork(harness)
		for _ = 1, 50 do
			harness.advanceSeconds(0.01)
			expect(harness.redeem("StageDebut")).toEqual({ isAccepted = false, rejectionReason = "TooManyAttempts" })
		end
		expect(readObservedWork(harness)).toEqual(workAfterFirstAttempt)
		expect(harness.observations.rateLimiterQuestionCount).toBe(51)
		expectPaidExactlyOnce(harness.readInMemorySaveData())
	end)

	it("refused attempts do not push the next allowed attempt further away", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		harness.redeem("NotACode")
		harness.advanceSeconds(1.5)
		expect(harness.redeem("StageDebut").rejectionReason).toBe("TooManyAttempts")
		harness.advanceSeconds(0.5)
		expect(harness.redeem("StageDebut")).toEqual(ACCEPTED_STAGE_DEBUT_ANSWER)
	end)

	it("the limit is asked for the RequestRedeemPromoCode channel and its reason is passed on as is", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		local askedLimiterQuestions = {}
		local refusingRedeemer = PromoCodeRedeemer.new({
			playerSaveDataKeeper = harness.server.playerSaveDataKeeper,
			rewardLedger = harness.server.rewardLedger,
			playerRequestRateLimiter = {
				admitOrRefusePlayerRequest = function(_, playerUserId, remoteChannelName)
					table.insert(askedLimiterQuestions, { playerUserId, remoteChannelName })
					-- A reason no code contains, so passing it on cannot be mistaken for hardcoding.
					return table.freeze({ isRequestAllowed = false, rejectionReason = "SentinelLimiterReason" })
				end,
			},
			clock = harness.fakeClock,
			logger = { logInformation = function() end, logWarning = function() end },
			promoCodeEntries = {},
		})
		local refusalAnswer = refusingRedeemer:redeemPromoCodeAndAnswerRequest(EXAMPLE_PLAYER_USER_ID, "StageDebut")
		expect(refusalAnswer).toEqual({ isAccepted = false, rejectionReason = "SentinelLimiterReason" })
		expect(table.isfrozen(refusalAnswer)).toBeFalse()
		expect(askedLimiterQuestions).toEqual({ { EXAMPLE_PLAYER_USER_ID, "RequestRedeemPromoCode" } })
	end)
end)

describe("PromoCodeRedeemer before the player's save has loaded (§3.4)", function()
	it("answers SaveDataNotLoaded without consulting the catalog or the ledger", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness({ isPlayerLoaded = false })
		expect(harness.redeem("StageDebut")).toEqual({ isAccepted = false, rejectionReason = "SaveDataNotLoaded" })
		expect(harness.observations.promoCodeEntryFieldReadCount).toBe(0)
		expect(harness.observations.clockSecondsReadCount).toBe(0)
		expect(harness.observations.rewardLedgerGrantCallCount).toBe(0)
		expect(harness.observations.saveDataLoadedQuestionCount).toBe(1)
	end)

	it("asks the limiter first: a fast second attempt is TooManyAttempts even while not loaded", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness({ isPlayerLoaded = false })
		harness.redeem("StageDebut")
		expect(harness.redeem("StageDebut")).toEqual({ isAccepted = false, rejectionReason = "TooManyAttempts" })
		expect(harness.observations.saveDataLoadedQuestionCount).toBe(1)
	end)

	it("redeems normally once the save has loaded", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness({ isPlayerLoaded = false })
		expect(harness.redeem("StageDebut").rejectionReason).toBe("SaveDataNotLoaded")
		harness.crashableHarness.startServerAndLoadPlayer(EXAMPLE_PLAYER_USER_ID)
		harness.waitOutAttemptInterval()
		expect(harness.redeem("StageDebut")).toEqual(ACCEPTED_STAGE_DEBUT_ANSWER)
	end)

	it("answers SaveDataNotLoaded once the player has started leaving", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		harness.server.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(EXAMPLE_PLAYER_USER_ID)
		expect(harness.redeem("StageDebut")).toEqual({ isAccepted = false, rejectionReason = "SaveDataNotLoaded" })
		expect(harness.observations.rewardLedgerGrantCallCount).toBe(0)
	end)

	it("a ledger answer of SaveDataNotLoaded is passed on, logged by the ledger and not again here", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		local recordedLogLines = {}
		local redeemerWithStaleKeeperAnswer = PromoCodeRedeemer.new({
			playerSaveDataKeeper = {
				isPlayerSaveDataLoaded = function()
					return true
				end,
			},
			rewardLedger = {
				grantStarCoinsAndFans = function()
					return { rewardLedgerOutcome = "SaveDataNotLoaded" }
				end,
			},
			playerRequestRateLimiter = harness.playerRequestRateLimiter,
			clock = harness.fakeClock,
			logger = {
				logInformation = function(_, message)
					table.insert(recordedLogLines, message)
				end,
				logWarning = function(_, message)
					table.insert(recordedLogLines, message)
				end,
			},
			promoCodeEntries = PromoCodeCatalog.freezePromoCodeCatalog(
				PromoCodeFixtures.createFixturePromoCodeCatalog()
			),
		})
		expect(redeemerWithStaleKeeperAnswer:redeemPromoCodeAndAnswerRequest(EXAMPLE_PLAYER_USER_ID, "StageDebut")).toEqual({
			isAccepted = false,
			rejectionReason = "SaveDataNotLoaded",
		})
		expect(recordedLogLines).toEqual({})
	end)
end)

describe("PromoCodeRedeemer RewardLedger outcomes it does not expect", function()
	local unexpectedLedgerOutcomes = {
		{ "a decline with another reason", { rewardLedgerOutcome = "Declined", declineReason = "AlreadyClaimed" } },
		{ "a decline without a reason", { rewardLedgerOutcome = "Declined" } },
		{ "an unknown outcome", { rewardLedgerOutcome = "Spent" } },
	}
	for _, unexpectedLedgerOutcomeCase in unexpectedLedgerOutcomes do
		it("raises on " .. unexpectedLedgerOutcomeCase[1] .. " (a programming error)", function()
			local harness = PromoCodeRedeemerTestHarness.createHarness()
			local redeemerWithStubLedger = PromoCodeRedeemer.new({
				playerSaveDataKeeper = harness.server.playerSaveDataKeeper,
				rewardLedger = {
					grantStarCoinsAndFans = function()
						return table.clone(unexpectedLedgerOutcomeCase[2])
					end,
				},
				playerRequestRateLimiter = harness.playerRequestRateLimiter,
				clock = harness.fakeClock,
				logger = { logInformation = function() end },
				promoCodeEntries = PromoCodeCatalog.freezePromoCodeCatalog(
					PromoCodeFixtures.createFixturePromoCodeCatalog()
				),
			})
			expect(function()
				redeemerWithStubLedger:redeemPromoCodeAndAnswerRequest(EXAMPLE_PLAYER_USER_ID, "StageDebut")
			end).toThrow("unexpected RewardLedger outcome")
		end)
	end
end)
