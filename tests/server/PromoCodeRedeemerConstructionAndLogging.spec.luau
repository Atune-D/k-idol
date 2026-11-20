-- PromoCodeRedeemer.new checks and copies what it is given; every answer is a fresh table; the log
-- names the player, the reason and the matched promoCodeId but never the typed text, and refused
-- attempts are not logged at all. Also: the shipped (empty) catalog can be wired as it is.

local UnitTestFramework = require("../Support/UnitTestFramework")
local PromoCodeCatalog = require("../../src/server/PromoCodeCatalog")
local PromoCodeFixtures = require("../fixtures/PromoCodeFixtures")
local PromoCodeRedeemer = require("../../src/server/PromoCodeRedeemer")
local PromoCodeRedeemerTestHarness = require("./PromoCodeRedeemerTestHarness")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local EXAMPLE_PLAYER_USER_ID = PromoCodeRedeemerTestHarness.EXAMPLE_PLAYER_USER_ID
local STAGE_DEBUT_REWARD = PromoCodeRedeemerTestHarness.STAGE_DEBUT_STAR_COIN_REWARD

local function createSilentLogger()
	return { logInformation = function() end, logWarning = function() end }
end

-- Dependencies that are complete and valid; tests replace or remove one at a time.
local function createValidDependencies(harness)
	return {
		playerSaveDataKeeper = harness.server.playerSaveDataKeeper,
		rewardLedger = harness.server.rewardLedger,
		playerRequestRateLimiter = harness.playerRequestRateLimiter,
		clock = harness.fakeClock,
		logger = createSilentLogger(),
		promoCodeEntries = PromoCodeCatalog.freezePromoCodeCatalog(PromoCodeFixtures.createFixturePromoCodeCatalog()),
	}
end

describe("PromoCodeRedeemer.new", function()
	for _, missingDependencyName in
		{ "playerSaveDataKeeper", "rewardLedger", "playerRequestRateLimiter", "clock", "logger", "promoCodeEntries" }
	do
		it("raises when " .. missingDependencyName .. " is missing", function()
			local harness = PromoCodeRedeemerTestHarness.createHarness()
			local incompleteDependencies = createValidDependencies(harness)
			incompleteDependencies[missingDependencyName] = nil
			expect(function()
				PromoCodeRedeemer.new(incompleteDependencies)
			end).toThrow("missing dependency " .. missingDependencyName)
		end)
	end

	it("raises when the dependencies are not a table", function()
		expect(function()
			PromoCodeRedeemer.new(nil :: any)
		end).toThrow("needs a dependencies table")
	end)

	it("raises when promoCodeEntries is not a list", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		local dependencies = createValidDependencies(harness)
		dependencies.promoCodeEntries = "StageDebut"
		expect(function()
			PromoCodeRedeemer.new(dependencies)
		end).toThrow("promoCodeEntries must be a list")
	end)

	for unfrozenEntryPosition = 1, 3 do
		it(string.format("raises when the entry at position %d of 3 is not frozen", unfrozenEntryPosition), function()
			local harness = PromoCodeRedeemerTestHarness.createHarness()
			local dependencies = createValidDependencies(harness)
			local promoCodeEntries = {}
			for entryPosition = 1, 3 do
				local promoCodeEntry = PromoCodeFixtures.createFixturePromoCode({
					promoCodeId = "fixture_entry_" .. tostring(entryPosition),
					promoCodeText = "EntryText" .. tostring(entryPosition),
				})
				table.insert(
					promoCodeEntries,
					if entryPosition == unfrozenEntryPosition then promoCodeEntry else table.freeze(promoCodeEntry)
				)
			end
			dependencies.promoCodeEntries = promoCodeEntries
			expect(function()
				PromoCodeRedeemer.new(dependencies)
			end).toThrow(string.format("promoCodeEntries[%d] is not frozen", unfrozenEntryPosition))
		end)
	end

	it("raises, naming the problem, when an entry is not a table", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		local dependencies = createValidDependencies(harness)
		dependencies.promoCodeEntries = { "StageDebut" }
		expect(function()
			PromoCodeRedeemer.new(dependencies)
		end).toThrow("entry 1: is not a table")
	end)

	it("raises, naming the problem, when the entries break a catalog rule", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		local dependencies = createValidDependencies(harness)
		dependencies.promoCodeEntries = PromoCodeCatalog.freezePromoCodeCatalog({
			PromoCodeFixtures.createFixturePromoCode(),
			PromoCodeFixtures.createFixturePromoCode({ promoCodeText = "OtherText" }),
		})
		expect(function()
			PromoCodeRedeemer.new(dependencies)
		end).toThrow("promoCodeId repeats entry 1")
	end)

	it("copies the caller's list: later changes to it are not seen", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		local dependencies = createValidDependencies(harness)
		local callerOwnedPromoCodeEntries = { table.freeze(PromoCodeFixtures.createFixturePromoCode()) }
		dependencies.promoCodeEntries = callerOwnedPromoCodeEntries
		local redeemer = PromoCodeRedeemer.new(dependencies)
		callerOwnedPromoCodeEntries[1] = table.freeze(PromoCodeFixtures.createFixturePromoCode({ starCoinReward = 1 }))
		table.insert(
			callerOwnedPromoCodeEntries,
			table.freeze(PromoCodeFixtures.createFixturePromoCode({
				promoCodeId = "fixture_added_later",
				promoCodeText = "AddedLater",
			}))
		)
		expect(redeemer:redeemPromoCodeAndAnswerRequest(EXAMPLE_PLAYER_USER_ID, "AddedLater").rejectionReason).toBe(
			"UnknownPromoCode"
		)
		harness.waitOutAttemptInterval()
		expect(redeemer:redeemPromoCodeAndAnswerRequest(EXAMPLE_PLAYER_USER_ID, "StageDebut")).toEqual({
			isAccepted = true,
			starCoinsGranted = STAGE_DEBUT_REWARD,
		})
	end)

	it("keeps its copy frozen, so no code holding the redeemer can add or replace an entry", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		for _, promoCodeEntries in
			{ PromoCodeCatalog.PROMO_CODES, { table.freeze(PromoCodeFixtures.createFixturePromoCode()) } }
		do
			local dependencies = createValidDependencies(harness)
			dependencies.promoCodeEntries = promoCodeEntries
			local redeemer = PromoCodeRedeemer.new(dependencies)
			expect(rawequal(redeemer.promoCodeEntries, promoCodeEntries)).toBeFalse()
			expect(table.isfrozen(redeemer.promoCodeEntries)).toBeTrue()
			expect(function()
				table.insert(redeemer.promoCodeEntries, table.freeze(PromoCodeFixtures.createFixturePromoCode()))
			end).toThrow()
		end
	end)

	it("accepts the shipped catalog, which redeems nothing", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		local dependencies = createValidDependencies(harness)
		dependencies.promoCodeEntries = PromoCodeCatalog.PROMO_CODES
		local redeemer = PromoCodeRedeemer.new(dependencies)
		expect(redeemer:redeemPromoCodeAndAnswerRequest(EXAMPLE_PLAYER_USER_ID, "StageDebut")).toEqual({
			isAccepted = false,
			rejectionReason = "UnknownPromoCode",
		})
	end)

	it("lists exactly the §2.10 rejection reasons plus SaveDataNotLoaded, frozen", function()
		local rejectionReasons = PromoCodeRedeemer.PROMO_CODE_REDEMPTION_REJECTION_REASONS
		expect(rejectionReasons).toEqual({
			UnknownPromoCode = "UnknownPromoCode",
			PromoCodeNotActive = "PromoCodeNotActive",
			AlreadyRedeemed = "AlreadyRedeemed",
			TooManyAttempts = "TooManyAttempts",
			SaveDataNotLoaded = "SaveDataNotLoaded",
		})
		expect(table.isfrozen(rejectionReasons)).toBeTrue()
		expect(table.isfrozen(PromoCodeRedeemer)).toBeTrue()
	end)
end)

describe("PromoCodeRedeemer answers", function()
	it("every answer is a new, unfrozen table, so changing one never changes the next", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		local answers = {}
		local function redeemAfterInterval(typedPromoCodeText)
			harness.waitOutAttemptInterval()
			local redemptionAnswer = harness.redeem(typedPromoCodeText)
			table.insert(answers, redemptionAnswer)
			return redemptionAnswer
		end
		redeemAfterInterval("NotACode").rejectionReason = "Tampered"
		expect(redeemAfterInterval("NotACode")).toEqual({ isAccepted = false, rejectionReason = "UnknownPromoCode" })
		redeemAfterInterval("StageDebut").starCoinsGranted = 1
		expect(redeemAfterInterval("StageDebut")).toEqual({ isAccepted = false, rejectionReason = "AlreadyRedeemed" })
		table.insert(answers, harness.redeem("StageDebut")) -- TooManyAttempts
		table.insert(answers, harness.redeem("StageDebut")) -- TooManyAttempts again
		expect(answers[6]).toEqual({ isAccepted = false, rejectionReason = "TooManyAttempts" })
		for answerPosition, redemptionAnswer in answers do
			expect(table.isfrozen(redemptionAnswer)).toBeFalse()
			for otherAnswerPosition = answerPosition + 1, #answers do
				expect(rawequal(redemptionAnswer, answers[otherAnswerPosition])).toBeFalse()
			end
		end
	end)
end)

describe("PromoCodeRedeemer logging", function()
	it("logs exactly one line per admitted request, from the redeemer or from the ledger", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness({
			requestAtUnixSeconds = PromoCodeRedeemerTestHarness.WINDOW_START_UNIX_SECONDS - 10,
		})
		harness.redeem("NotACode")
		harness.waitOutAttemptInterval()
		harness.redeem("StageDebut") -- not active yet
		harness.advanceSeconds(10)
		harness.redeem("StageDebut") -- accepted: the ledger logs it, the redeemer does not
		harness.waitOutAttemptInterval()
		harness.redeem("StageDebut") -- AlreadyRedeemed: the ledger logs the decline, the redeemer does not
		harness.redeem("StageDebut") -- TooManyAttempts: not logged at all
		expect(harness.observations.redeemerLogLines).toEqual({
			string.format(
				"information: PromoCodeRedeemer: redemption for player %d rejected: UnknownPromoCode",
				EXAMPLE_PLAYER_USER_ID
			),
			string.format(
				"information: PromoCodeRedeemer: redemption for player %d rejected: PromoCodeNotActive (promoCodeId fixture_stage_debut)",
				EXAMPLE_PLAYER_USER_ID
			),
		})
		local grantDescription =
			"RewardLedger: grant 300 Star Coins and 0 fans (rewardSourceKind PromoCode: promo code fixture_stage_debut)"
		expect(harness.server.ledgerLogger.loggedInformation).toEqual({
			string.format(
				"%s applied for player %d; starCoinBalance 350 -> 650, fanCount 0 -> 0",
				grantDescription,
				EXAMPLE_PLAYER_USER_ID
			),
			string.format("%s declined for player %d: AlreadyRedeemed", grantDescription, EXAMPLE_PLAYER_USER_ID),
		})
		expect(harness.server.ledgerLogger.loggedWarnings).toEqual({})
	end)

	it("logs SaveDataNotLoaded once per admitted attempt", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness({ isPlayerLoaded = false })
		harness.redeem("StageDebut")
		harness.redeem("StageDebut")
		expect(harness.observations.redeemerLogLines).toEqual({
			string.format(
				"information: PromoCodeRedeemer: redemption for player %d rejected: SaveDataNotLoaded",
				EXAMPLE_PLAYER_USER_ID
			),
		})
	end)

	it("never logs or echoes the typed text, for random texts (seeded)", function()
		SeededRandomTrials.runSeededRandomTrials(60, function(seededRandomNumberGenerator)
			local harness = PromoCodeRedeemerTestHarness.createHarness()
			local typedCharacters = {}
			for _ = 1, seededRandomNumberGenerator.nextWholeNumberInRange(6, 40) do
				table.insert(typedCharacters, string.char(seededRandomNumberGenerator.nextWholeNumberInRange(65, 90)))
			end
			local typedPromoCodeText = "Q" .. table.concat(typedCharacters)
			local everyAnswer = {}
			for _ = 1, 3 do
				table.insert(everyAnswer, harness.redeem(typedPromoCodeText))
				table.insert(everyAnswer, harness.redeem(typedPromoCodeText))
				harness.waitOutAttemptInterval()
			end
			local everyLogLine = table.clone(harness.observations.redeemerLogLines)
			for _, ledgerLogLine in harness.server.ledgerLogger.loggedInformation do
				table.insert(everyLogLine, ledgerLogLine)
			end
			for _, ledgerLogLine in harness.server.ledgerLogger.loggedWarnings do
				table.insert(everyLogLine, ledgerLogLine)
			end
			expect(#harness.observations.redeemerLogLines).toBe(3)
			for _, logLine in everyLogLine do
				expect(string.find(string.lower(logLine), string.lower(typedPromoCodeText), 1, true)).toBeNil()
			end
			for _, redemptionAnswer in everyAnswer do
				for _, answerFieldValue in redemptionAnswer do
					expect(answerFieldValue == typedPromoCodeText).toBeFalse()
				end
			end
		end)
	end)

	it("never logs the typed spelling of a real code", function()
		local harness = PromoCodeRedeemerTestHarness.createHarness()
		harness.redeem("sTaGeDeBuT")
		harness.waitOutAttemptInterval()
		harness.redeem("sTaGeDeBuT")
		local everyLogLine = table.clone(harness.observations.redeemerLogLines)
		for _, ledgerLogLine in harness.server.ledgerLogger.loggedInformation do
			table.insert(everyLogLine, ledgerLogLine)
		end
		expect(#everyLogLine).toBe(2) -- the ledger's "applied" and "declined ...: AlreadyRedeemed"
		for _, logLine in everyLogLine do
			expect(string.find(string.lower(logLine), "stagedebut", 1, true)).toBeNil()
		end
	end)
end)
