-- Promo code catalog rules and the pure match decision (development spec §1.9, §2.10, and the
-- pure share of the §6.2 row "Unit: promo codes"). Uses fixture codes only: the shipped catalog
-- is checked against the rules, never relied on for its content. Randomized trials live in
-- PromoCodeCatalogRandomized.spec.luau.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local PromoCodeFixtures = require("../fixtures/PromoCodeFixtures")
local PromoCodeCatalog = require("../../src/server/PromoCodeCatalog")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

type PromoCode = PromoCodeCatalog.PromoCode

local FIXTURE_WINDOW_START_UNIX_SECONDS = PromoCodeFixtures.FIXTURE_WINDOW_START_UNIX_SECONDS
local FIXTURE_WINDOW_END_UNIX_SECONDS = PromoCodeFixtures.FIXTURE_WINDOW_END_UNIX_SECONDS
local createFixturePromoCode = PromoCodeFixtures.createFixturePromoCode
local createFixturePromoCodeCatalog = PromoCodeFixtures.createFixturePromoCodeCatalog

local function decideAtUnixSeconds(typedPromoCodeText: any, currentUnixSeconds: number)
	return PromoCodeCatalog.decidePromoCodeMatchAtUnixSeconds(
		typedPromoCodeText,
		currentUnixSeconds,
		createFixturePromoCodeCatalog()
	)
end

local function expectUnknownPromoCodeDecision(typedPromoCodeText: any)
	local promoCodeMatchDecision = decideAtUnixSeconds(typedPromoCodeText, FIXTURE_WINDOW_START_UNIX_SECONDS + 10)
	expect(promoCodeMatchDecision).toEqual({
		isPromoCodeActiveMatch = false,
		rejectionReason = "UnknownPromoCode",
	})
end

local function expectActiveMatchOfFixtureStageDebut(typedPromoCodeText: any)
	local promoCodeMatchDecision = decideAtUnixSeconds(typedPromoCodeText, FIXTURE_WINDOW_START_UNIX_SECONDS + 10)
	expect(promoCodeMatchDecision.isPromoCodeActiveMatch).toBeTrue()
	expect(promoCodeMatchDecision.rejectionReason).toBeNil()
	expect((promoCodeMatchDecision.matchedPromoCode :: PromoCode).promoCodeId).toBe("fixture_stage_debut")
end

local function countProblemsForSingleEntry(promoCodeFieldOverrides: { [string]: any }): number
	return #PromoCodeCatalog.findPromoCodeCatalogProblems({ createFixturePromoCode(promoCodeFieldOverrides) })
end

describe("PromoCodeCatalog shipped content", function()
	it("every shipped entry follows the catalog rules", function()
		expect(PromoCodeCatalog.findPromoCodeCatalogProblems(PromoCodeCatalog.PROMO_CODES)).toEqual({})
	end)

	it("is frozen, entry by entry", function()
		expect(table.isfrozen(PromoCodeCatalog)).toBeTrue()
		expect(table.isfrozen(PromoCodeCatalog.PROMO_CODES)).toBeTrue()
		expect(table.isfrozen(PromoCodeCatalog.PROMO_CODE_REJECTION_REASONS)).toBeTrue()
		-- Vacuous while the shipped catalog is empty; the next test covers the freezing itself.
		for _, shippedPromoCode in PromoCodeCatalog.PROMO_CODES do
			expect(table.isfrozen(shippedPromoCode)).toBeTrue()
		end
	end)

	it("freezePromoCodeCatalog freezes every entry and the list", function()
		local fixturePromoCodeCatalog = createFixturePromoCodeCatalog()
		expect(PromoCodeCatalog.freezePromoCodeCatalog(fixturePromoCodeCatalog)).toBe(fixturePromoCodeCatalog)
		expect(table.isfrozen(fixturePromoCodeCatalog)).toBeTrue()
		expect(table.isfrozen(fixturePromoCodeCatalog[1])).toBeTrue()
		expect(table.isfrozen(fixturePromoCodeCatalog[2])).toBeTrue()
	end)

	it("limits catalog texts to 32 bytes and typed texts to 128 bytes", function()
		expect(PromoCodeCatalog.MAXIMUM_PROMO_CODE_TEXT_BYTE_COUNT).toBe(32)
		expect(PromoCodeCatalog.MAXIMUM_TYPED_PROMO_CODE_TEXT_BYTE_COUNT).toBe(128)
	end)

	it("names exactly the two rejection reasons of §2.10 that the pure rule decides", function()
		expect(PromoCodeCatalog.PROMO_CODE_REJECTION_REASONS).toEqual({
			UnknownPromoCode = "UnknownPromoCode",
			PromoCodeNotActive = "PromoCodeNotActive",
		})
	end)
end)

describe("PromoCodeCatalog rules", function()
	it("a valid fixture catalog has no problems", function()
		expect(PromoCodeCatalog.findPromoCodeCatalogProblems(createFixturePromoCodeCatalog())).toEqual({})
	end)

	it("rejects a repeated promoCodeId", function()
		local catalogProblems = PromoCodeCatalog.findPromoCodeCatalogProblems({
			createFixturePromoCode(),
			createFixturePromoCode({ promoCodeText = "OtherText" }),
		})
		expect(#catalogProblems).toBe(1)
		expect(string.find(catalogProblems[1], "promoCodeId repeats entry 1", 1, true) ~= nil).toBeTrue()
	end)

	it("rejects a promoCodeText that repeats another ignoring letter case", function()
		local catalogProblems = PromoCodeCatalog.findPromoCodeCatalogProblems({
			createFixturePromoCode(),
			createFixturePromoCode({ promoCodeId = "fixture_other", promoCodeText = "sTAGEdEBUT" }),
		})
		expect(#catalogProblems).toBe(1)
		expect(string.find(catalogProblems[1], "promoCodeText repeats entry 1", 1, true) ~= nil).toBeTrue()
	end)

	it("requires a whole starCoinReward of at least 1", function()
		expect(countProblemsForSingleEntry({ starCoinReward = 1 })).toBe(0)
		for _, invalidStarCoinReward in { 0, -300, 1.5, 0 / 0, math.huge, "300", false } :: { any } do
			expect({
				tostring(invalidStarCoinReward),
				countProblemsForSingleEntry({ starCoinReward = invalidStarCoinReward }),
			}).toEqual({
				tostring(invalidStarCoinReward),
				1,
			})
		end
		local promoCodeWithoutReward = createFixturePromoCode() :: any
		promoCodeWithoutReward.starCoinReward = nil
		expect(#PromoCodeCatalog.findPromoCodeCatalogProblems({ promoCodeWithoutReward })).toBe(1)
	end)

	it("requires validFromUnixSeconds strictly before validUntilUnixSeconds", function()
		expect(countProblemsForSingleEntry({ validUntilUnixSeconds = FIXTURE_WINDOW_START_UNIX_SECONDS + 1 })).toBe(0)
		expect(countProblemsForSingleEntry({ validUntilUnixSeconds = FIXTURE_WINDOW_START_UNIX_SECONDS })).toBe(1)
		expect(countProblemsForSingleEntry({ validUntilUnixSeconds = FIXTURE_WINDOW_START_UNIX_SECONDS - 1 })).toBe(1)
	end)

	it("requires both window ends to be whole numbers", function()
		for _, invalidUnixSeconds in { 1800000000.5, 0 / 0, math.huge, -math.huge, "1800000000", true } :: { any } do
			expect({
				tostring(invalidUnixSeconds),
				countProblemsForSingleEntry({ validFromUnixSeconds = invalidUnixSeconds }),
			}).toEqual({
				tostring(invalidUnixSeconds),
				1,
			})
			expect({
				tostring(invalidUnixSeconds),
				countProblemsForSingleEntry({ validUntilUnixSeconds = invalidUnixSeconds }),
			}).toEqual({
				tostring(invalidUnixSeconds),
				1,
			})
		end
	end)

	it("requires promoCodeText to be 1 to 32 printable ASCII characters without whitespace", function()
		local longestAllowedText = string.rep("A", 32)
		expect(countProblemsForSingleEntry({ promoCodeText = longestAllowedText })).toBe(0)
		expect(countProblemsForSingleEntry({ promoCodeText = "A!~#9_-" })).toBe(0)
		for _, invalidPromoCodeText in
			{
				"",
				longestAllowedText .. "A",
				"STAGE DEBUT",
				" StageDebut",
				"Stage\tDebut",
				"Stage\127Debut",
				"Débuts",
				42,
			} :: { any }
		do
			expect({
				tostring(invalidPromoCodeText),
				countProblemsForSingleEntry({ promoCodeText = invalidPromoCodeText }),
			}).toEqual({
				tostring(invalidPromoCodeText),
				1,
			})
		end
	end)

	it("requires promoCodeId to be non-empty snake_case", function()
		for _, invalidPromoCodeId in
			{ "", "Launch_2026", "launch-2026", "2026_launch", "_launch_2026", "launch 2026", 7 } :: { any }
		do
			expect({ tostring(invalidPromoCodeId), countProblemsForSingleEntry({ promoCodeId = invalidPromoCodeId }) }).toEqual({
				tostring(invalidPromoCodeId),
				1,
			})
		end
	end)

	it("labels each problem with the entry position and id", function()
		expect(PromoCodeCatalog.findPromoCodeCatalogProblems({
			createFixturePromoCode(),
			createFixturePromoCode({ promoCodeId = "fixture_other", promoCodeText = "Other", starCoinReward = 0 }),
		})).toEqual({
			"entry 2 (fixture_other): starCoinReward must be a whole number of at least 1, got 0",
		})
	end)

	it("reports an entry that is not a table instead of raising", function()
		expect(#PromoCodeCatalog.findPromoCodeCatalogProblems({ "not an entry" } :: { any })).toBe(1)
	end)
end)

describe("PromoCodeCatalog matching typed text", function()
	it("matches ignoring letter case", function()
		expectActiveMatchOfFixtureStageDebut("StageDebut")
		expectActiveMatchOfFixtureStageDebut("stagedebut")
		expectActiveMatchOfFixtureStageDebut("STAGEDEBUT")
		expectActiveMatchOfFixtureStageDebut("sTaGeDeBuT")
	end)

	it("ignores surrounding whitespace but not inner whitespace", function()
		expectActiveMatchOfFixtureStageDebut("  StageDebut")
		expectActiveMatchOfFixtureStageDebut("StageDebut \t\r\n")
		expectActiveMatchOfFixtureStageDebut("\n stagedebut \n")
		expectActiveMatchOfFixtureStageDebut("\v\fStageDebut\f\v")
		expectUnknownPromoCodeDecision("Stage Debut")
		expectUnknownPromoCodeDecision("Stage\tDebut")
	end)

	it("answers UnknownPromoCode for text no entry has, including prefixes and longer texts", function()
		expectUnknownPromoCodeDecision("NoSuchCode")
		expectUnknownPromoCodeDecision("StageDebu")
		expectUnknownPromoCodeDecision("StageDebutX")
		expectUnknownPromoCodeDecision("fixture_stage_debut") -- the id is not the text
		expectUnknownPromoCodeDecision("")
		expectUnknownPromoCodeDecision("   ")
	end)

	it("answers UnknownPromoCode for every text when the catalog is empty", function()
		expect(PromoCodeCatalog.decidePromoCodeMatchAtUnixSeconds("StageDebut", FIXTURE_WINDOW_START_UNIX_SECONDS, {})).toEqual({
			isPromoCodeActiveMatch = false,
			rejectionReason = "UnknownPromoCode",
		})
	end)

	it("answers UnknownPromoCode without raising for non-string input", function()
		for _, nonStringTypedValue in
			{ 42, true, false, { "StageDebut" }, function() end, buffer.create(4), 0 / 0 } :: { any }
		do
			expectUnknownPromoCodeDecision(nonStringTypedValue)
		end
		expectUnknownPromoCodeDecision(nil)
	end)

	it("answers UnknownPromoCode without raising for very long input, at the 128-byte boundary", function()
		local paddingToMaximum = string.rep(" ", 128 - #"StageDebut")
		expectActiveMatchOfFixtureStageDebut(paddingToMaximum .. "StageDebut")
		expectUnknownPromoCodeDecision(paddingToMaximum .. " StageDebut")
		expectUnknownPromoCodeDecision(string.rep(" ", 1000000) .. "StageDebut")
		expectUnknownPromoCodeDecision(string.rep("StageDebut", 100000))
		expectUnknownPromoCodeDecision(string.rep("\0", 5000000))
	end)

	it("matches the longest allowed catalog text with 96 bytes of whitespace around it", function()
		local longestPromoCode = createFixturePromoCode({ promoCodeText = string.rep("Z", 32) })
		expect(PromoCodeCatalog.findPromoCodeCatalogProblems({ longestPromoCode })).toEqual({})
		local function findLongest(typedPromoCodeText: string)
			return PromoCodeCatalog.findPromoCodeMatchingTypedText(typedPromoCodeText, { longestPromoCode })
		end
		expect(findLongest(string.rep("z", 32))).toBe(longestPromoCode)
		expect(findLongest(string.rep(" ", 48) .. string.rep("z", 32) .. string.rep("\n", 48))).toBe(longestPromoCode)
		expect(findLongest(string.rep(" ", 48) .. string.rep("z", 32) .. string.rep("\n", 49))).toBeNil()
	end)

	it("returns the catalog entry itself", function()
		local fixturePromoCodeCatalog = createFixturePromoCodeCatalog()
		expect(PromoCodeCatalog.findPromoCodeMatchingTypedText("encore-2030", fixturePromoCodeCatalog)).toBe(
			fixturePromoCodeCatalog[2]
		)
	end)
end)

describe("PromoCodeCatalog validity window (from inclusive, until exclusive)", function()
	it("is not active before the window, with the matched entry reported", function()
		local promoCodeMatchDecision = decideAtUnixSeconds("StageDebut", FIXTURE_WINDOW_START_UNIX_SECONDS - 86400)
		expect(promoCodeMatchDecision.isPromoCodeActiveMatch).toBeFalse()
		expect(promoCodeMatchDecision.rejectionReason).toBe("PromoCodeNotActive")
		expect((promoCodeMatchDecision.matchedPromoCode :: PromoCode).promoCodeId).toBe("fixture_stage_debut")
	end)

	it("walks a fake clock across both exact boundary seconds", function()
		local fakeClock = FakeClock.new(FIXTURE_WINDOW_START_UNIX_SECONDS - 1)
		local function decideNow()
			return decideAtUnixSeconds("stagedebut", fakeClock:getCurrentUnixSeconds())
		end

		expect(decideNow().rejectionReason).toBe("PromoCodeNotActive") -- one second before from
		fakeClock:advanceBySeconds(0.999)
		expect(decideNow().rejectionReason).toBe("PromoCodeNotActive") -- one millisecond before from
		fakeClock:advanceBySeconds(0.001)
		expect(decideNow().isPromoCodeActiveMatch).toBeTrue() -- exactly validFromUnixSeconds
		fakeClock:advanceBySeconds(43200)
		expect(decideNow().isPromoCodeActiveMatch).toBeTrue() -- inside
		fakeClock:advanceBySeconds(FIXTURE_WINDOW_END_UNIX_SECONDS - FIXTURE_WINDOW_START_UNIX_SECONDS - 43200 - 0.001)
		expect(decideNow().isPromoCodeActiveMatch).toBeTrue() -- one millisecond before until
		fakeClock:advanceBySeconds(0.001)
		expect(decideNow()).toEqual({ -- exactly validUntilUnixSeconds
			isPromoCodeActiveMatch = false,
			matchedPromoCode = createFixturePromoCode(),
			rejectionReason = "PromoCodeNotActive",
		})
		fakeClock:advanceBySeconds(86400 * 365)
		expect(decideNow().rejectionReason).toBe("PromoCodeNotActive") -- long after
	end)

	it("judges each entry by its own window", function()
		expect(decideAtUnixSeconds("ENCORE-2030", FIXTURE_WINDOW_START_UNIX_SECONDS + 10).rejectionReason).toBe(
			"PromoCodeNotActive"
		)
		expect(decideAtUnixSeconds("encore-2030", 1900000000).isPromoCodeActiveMatch).toBeTrue()
		expect(decideAtUnixSeconds("StageDebut", 1900000000).rejectionReason).toBe("PromoCodeNotActive")
	end)

	it("raises for a current time that is not a finite number (a server programming error)", function()
		for _, invalidCurrentUnixSeconds in { 0 / 0, math.huge, -math.huge, "1800000000" } :: { any } do
			expect(function()
				decideAtUnixSeconds("StageDebut", invalidCurrentUnixSeconds)
			end).toThrow("finite currentUnixSeconds")
		end
	end)
end)
