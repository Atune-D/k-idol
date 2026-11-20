-- Spec §2.10 and §6.2 "Unit: promo codes": a typed code matches its catalog entry ignoring letter
-- case, is redeemable only inside its validity window (from inclusive, until exclusive), pays
-- exactly the catalog entry's reward, and nothing a device sends can raise or be paid for.

local UnitTestFramework = require("../Support/UnitTestFramework")
local PromoCodeFixtures = require("../fixtures/PromoCodeFixtures")
local PromoCodeRedeemerTestHarness = require("./PromoCodeRedeemerTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local STAGE_DEBUT_ID = PromoCodeRedeemerTestHarness.STAGE_DEBUT_PROMO_CODE_ID
local STAGE_DEBUT_REWARD = PromoCodeRedeemerTestHarness.STAGE_DEBUT_STAR_COIN_REWARD
local STARTING_BALANCE = PromoCodeRedeemerTestHarness.STARTING_STAR_COIN_BALANCE
local WINDOW_START = PromoCodeRedeemerTestHarness.WINDOW_START_UNIX_SECONDS
local WINDOW_END = PromoCodeRedeemerTestHarness.WINDOW_END_UNIX_SECONDS

local function expectAcceptedStageDebutRedemption(harness, redemptionAnswer)
	expect(redemptionAnswer).toEqual({ isAccepted = true, starCoinsGranted = STAGE_DEBUT_REWARD })
	local inMemorySaveData = harness.readInMemorySaveData()
	expect(inMemorySaveData.starCoinBalance).toBe(STARTING_BALANCE + STAGE_DEBUT_REWARD)
	expect(inMemorySaveData.fanCount).toBe(0)
	expect(inMemorySaveData.redeemedPromoCodeIds).toEqual({ STAGE_DEBUT_ID })
end

-- Also pins the whole log: exactly the redeemer's one line for this rejection (naming the
-- matched promoCodeId when there is one) and nothing from the ledger, so no device value is logged.
local function expectRejectedWithoutChange(
	harness,
	redemptionAnswer,
	expectedRejectionReason: string,
	matchedPromoCodeId: string?
)
	expect(redemptionAnswer).toEqual({ isAccepted = false, rejectionReason = expectedRejectionReason })
	expect(harness.observations.redeemerLogLines).toEqual({
		string.format(
			"information: PromoCodeRedeemer: redemption for player %d rejected: %s%s",
			PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID,
			expectedRejectionReason,
			if matchedPromoCodeId then " (promoCodeId " .. matchedPromoCodeId .. ")" else ""
		),
	})
	expect(harness.server.ledgerLogger.loggedInformation).toEqual({})
	expect(harness.server.ledgerLogger.loggedWarnings).toEqual({})
	local inMemorySaveData = harness.readInMemorySaveData()
	expect(inMemorySaveData.starCoinBalance).toBe(STARTING_BALANCE)
	expect(inMemorySaveData.redeemedPromoCodeIds).toEqual({})
	expect(harness.readInMemoryChangeRevision()).toBe(0)
	expect(harness.fakePlayerSaveDataStorage:countPendingOperations()).toBe(0)
end

describe("PromoCodeRedeemer letter case and spelling (§1.9)", function()
	for _, typedPromoCodeText in { "StageDebut", "stagedebut", "STAGEDEBUT", "sTaGeDeBuT", "  StageDebut\t" } do
		it(string.format("accepts %q and pays the catalog reward once", typedPromoCodeText), function()
			local harness = PromoCodeRedeemerTestHarness.createHarness()
			expectAcceptedStageDebutRedemption(harness, harness.redeem(typedPromoCodeText))
			expect(harness.readInMemoryChangeRevision()).toBe(1)
			expect(harness.fakePlayerSaveDataStorage:countPendingOperations()).toBe(1)
		end)
	end

	for _, typedPromoCodeText in { "StageDebu", "StageDebutt", "Stage Debut", "StageDébut", "", "   " } do
		it(string.format("answers UnknownPromoCode for %q and changes nothing", typedPromoCodeText), function()
			local harness = PromoCodeRedeemerTestHarness.createHarness()
			expectRejectedWithoutChange(harness, harness.redeem(typedPromoCodeText), "UnknownPromoCode")
		end)
	end
end)

describe("PromoCodeRedeemer validity window (from inclusive, until exclusive)", function()
	local windowCases = {
		{ caseName = "one second before the window", requestAtUnixSeconds = WINDOW_START - 1, isAccepted = false },
		{
			caseName = "one millisecond before the window",
			requestAtUnixSeconds = WINDOW_START - 0.001,
			isAccepted = false,
		},
		{ caseName = "exactly at the window start", requestAtUnixSeconds = WINDOW_START, isAccepted = true },
		{
			caseName = "one millisecond before the window end",
			requestAtUnixSeconds = WINDOW_END - 0.001,
			isAccepted = true,
		},
		{ caseName = "exactly at the window end", requestAtUnixSeconds = WINDOW_END, isAccepted = false },
		{ caseName = "a day after the window", requestAtUnixSeconds = WINDOW_END + 86400, isAccepted = false },
	}
	for _, windowCase in windowCases do
		it(
			windowCase.caseName .. (if windowCase.isAccepted then " -> accepted" else " -> PromoCodeNotActive"),
			function()
				local harness = PromoCodeRedeemerTestHarness.createHarness({
					requestAtUnixSeconds = windowCase.requestAtUnixSeconds,
				})
				expect(harness.fakeClock:getCurrentUnixSeconds()).toBe(windowCase.requestAtUnixSeconds)
				local redemptionAnswer = harness.redeem("stagedebut")
				if windowCase.isAccepted then
					expectAcceptedStageDebutRedemption(harness, redemptionAnswer)
				else
					expectRejectedWithoutChange(harness, redemptionAnswer, "PromoCodeNotActive", STAGE_DEBUT_ID)
				end
			end
		)
	end

	it("a code whose window has not started yet is PromoCodeNotActive, and accepted once it starts", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		expectRejectedWithoutChange(
			harness,
			harness.redeem("encore-2030"),
			"PromoCodeNotActive",
			PromoCodeRedeemerTestHarness.ENCORE_WEEK_PROMO_CODE_ID
		)
		harness.fakeClock:advanceBySeconds(1900000000 - harness.fakeClock:getCurrentUnixSeconds())
		expect(harness.redeem("encore-2030")).toEqual({ isAccepted = true, starCoinsGranted = 50 })
		expect(harness.readInMemorySaveData().redeemedPromoCodeIds).toEqual({
			PromoCodeRedeemerTestHarness.ENCORE_WEEK_PROMO_CODE_ID,
		})
	end)

	it("reads the time from the injected clock at each request", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness({ requestAtUnixSeconds = WINDOW_END - 1 })
		harness.advanceSeconds(1)
		expectRejectedWithoutChange(harness, harness.redeem("StageDebut"), "PromoCodeNotActive", STAGE_DEBUT_ID)
		expect(harness.observations.clockSecondsReadCount).toBe(1)
	end)
end)

describe("PromoCodeRedeemer pays only the catalog entry's reward", function()
	it("a table that pretends to carry the code or a reward is UnknownPromoCode and is never touched", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		local metamethodCallCount = 0
		local function countMetamethodCall(returnedValue)
			return function()
				metamethodCallCount += 1
				return returnedValue
			end
		end
		local pretendingPromoCodeText = setmetatable({ promoCodeText = "StageDebut", starCoinReward = 999999 }, {
			__tostring = countMetamethodCall("StageDebut"),
			__index = countMetamethodCall("StageDebut"),
			__len = countMetamethodCall(10),
			__eq = countMetamethodCall(true),
			__concat = countMetamethodCall("StageDebut"),
			__iter = countMetamethodCall(next),
		})
		expectRejectedWithoutChange(harness, harness.redeem(pretendingPromoCodeText), "UnknownPromoCode")
		expect(metamethodCallCount).toBe(0)
	end)

	for _, catalogStarCoinReward in { 7, 4321 } do
		it(string.format("a catalog reward of %d is paid exactly, with no fans", catalogStarCoinReward), function()
			local harness = PromoCodeRedeemerTestHarness.createHarness({
				promoCodeEntries = {
					PromoCodeFixtures.createFixturePromoCode({ starCoinReward = catalogStarCoinReward }),
				},
			})
			expect(harness.redeem("STAGEDEBUT")).toEqual({ isAccepted = true, starCoinsGranted = catalogStarCoinReward })
			expect(harness.readInMemorySaveData().starCoinBalance).toBe(STARTING_BALANCE + catalogStarCoinReward)
			expect(harness.readInMemorySaveData().fanCount).toBe(0)
		end)
	end
end)

describe("PromoCodeRedeemer untrusted promoCodeText values", function()
	local cyclicTable = {}
	cyclicTable.self = cyclicTable
	local untrustedValueCases = {
		{ "nil", nil },
		{ "a number", 12345 },
		{ "NaN", 0 / 0 },
		{ "infinity", math.huge },
		{ "a boolean", true },
		{ "a function", function() end },
		{ "a cyclic table", cyclicTable },
		{ "a list holding the code", { "StageDebut" } },
		{ "a string with a zero byte", "StageDebut\0" },
		{ "a one-megabyte string", string.rep("x", 1024 * 1024) },
		{ "the code padded far past the length limit", string.rep(" ", 200) .. "StageDebut" },
		{ "the code repeated", string.rep("StageDebut", 20) },
		{ "a buffer", buffer.create(16) },
		{ "a coroutine", coroutine.create(function() end) },
	}
	for _, untrustedValueCase in untrustedValueCases do
		it("answers UnknownPromoCode, without raising, for " .. untrustedValueCase[1], function()
			local harness = PromoCodeRedeemerTestHarness.createHarness()
			local didAnswer, redemptionAnswer = pcall(harness.redeem, untrustedValueCase[2])
			expect(didAnswer).toBeTrue()
			expectRejectedWithoutChange(harness, redemptionAnswer, "UnknownPromoCode")
		end)
	end

	it("an over-long value is refused before any catalog entry is read", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		harness.redeem(string.rep("A", 129))
		expect(harness.observations.promoCodeEntryFieldReadCount).toBe(0)
	end)

	it("a wrong guess reads each catalog entry's text at most once", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		harness.redeem("NotACode")
		expect(harness.observations.promoCodeEntryFieldReadCount).toBe(#harness.uncountedPromoCodeEntries)
	end)
end)
