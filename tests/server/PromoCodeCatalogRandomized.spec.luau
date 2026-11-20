-- Randomized trials of the promo code match decision and catalog rules (development spec §1.9,
-- §2.10). Every failure prints the seed (tests/fixtures/SeededRandomTrials.luau).

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local PromoCodeCatalog = require("../../src/server/PromoCodeCatalog")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

type PromoCode = PromoCodeCatalog.PromoCode

-- Reference model written independently of the module: inputs over 128 bytes match nothing;
-- otherwise trim ASCII whitespace, lower ASCII letters, compare; active when from <= now < until.
local REFERENCE_MODEL_MAXIMUM_TYPED_BYTE_COUNT = 128
local REFERENCE_MODEL_MAXIMUM_CATALOG_TEXT_BYTE_COUNT = 32
local ASCII_WHITESPACE_BYTE_SET = { [9] = true, [10] = true, [11] = true, [12] = true, [13] = true, [32] = true }

local function trimAsciiWhitespaceForReferenceModel(untrimmedText: string): string
	local firstKeptPosition, lastKeptPosition = 1, #untrimmedText
	while
		firstKeptPosition <= lastKeptPosition
		and ASCII_WHITESPACE_BYTE_SET[string.byte(untrimmedText, firstKeptPosition)]
	do
		firstKeptPosition += 1
	end
	while
		lastKeptPosition >= firstKeptPosition
		and ASCII_WHITESPACE_BYTE_SET[string.byte(untrimmedText, lastKeptPosition)]
	do
		lastKeptPosition -= 1
	end
	return string.sub(untrimmedText, firstKeptPosition, lastKeptPosition)
end

local function lowerAsciiLettersForReferenceModel(mixedCaseText: string): string
	return (
		string.gsub(mixedCaseText, "%u", function(upperCaseLetter)
			return string.char(string.byte(upperCaseLetter) + 32)
		end)
	)
end

local function decideWithReferenceModel(
	typedPromoCodeText: string,
	currentUnixSeconds: number,
	promoCodes: { PromoCode }
)
	if #typedPromoCodeText > REFERENCE_MODEL_MAXIMUM_TYPED_BYTE_COUNT then
		return { isPromoCodeActiveMatch = false, rejectionReason = "UnknownPromoCode" }
	end
	local comparedTypedText =
		lowerAsciiLettersForReferenceModel(trimAsciiWhitespaceForReferenceModel(typedPromoCodeText))
	for _, promoCode in promoCodes do
		if comparedTypedText == lowerAsciiLettersForReferenceModel(promoCode.promoCodeText) then
			if
				promoCode.validFromUnixSeconds <= currentUnixSeconds
				and currentUnixSeconds < promoCode.validUntilUnixSeconds
			then
				return { isPromoCodeActiveMatch = true, matchedPromoCode = promoCode }
			end
			return {
				isPromoCodeActiveMatch = false,
				matchedPromoCode = promoCode,
				rejectionReason = "PromoCodeNotActive",
			}
		end
	end
	return { isPromoCodeActiveMatch = false, rejectionReason = "UnknownPromoCode" }
end

-- Texts are 1 to 32 printable ASCII bytes, so the longest allowed catalog text is sampled.
local function createRandomPromoCodeCatalog(seededRandomNumberGenerator): { PromoCode }
	local randomPromoCodes = {}
	local usedLoweredTextSet = {}
	for entryNumber = 1, seededRandomNumberGenerator.nextWholeNumberInRange(1, 6) do
		local randomPromoCodeText
		repeat
			local randomTextCharacters = {}
			local randomTextLength = if seededRandomNumberGenerator.nextWholeNumberInRange(0, 3) == 0
				then REFERENCE_MODEL_MAXIMUM_CATALOG_TEXT_BYTE_COUNT
				else seededRandomNumberGenerator.nextWholeNumberInRange(
					1,
					REFERENCE_MODEL_MAXIMUM_CATALOG_TEXT_BYTE_COUNT
				)
			for _ = 1, randomTextLength do
				table.insert(
					randomTextCharacters,
					string.char(seededRandomNumberGenerator.nextWholeNumberInRange(33, 126))
				)
			end
			randomPromoCodeText = table.concat(randomTextCharacters)
		until not usedLoweredTextSet[string.lower(randomPromoCodeText)]
		usedLoweredTextSet[string.lower(randomPromoCodeText)] = true
		local randomValidFromUnixSeconds = seededRandomNumberGenerator.nextWholeNumberInRange(1700000000, 1900000000)
		table.insert(randomPromoCodes, {
			promoCodeId = "random_fixture_" .. entryNumber,
			promoCodeText = randomPromoCodeText,
			starCoinReward = seededRandomNumberGenerator.nextWholeNumberInRange(1, 1000),
			validFromUnixSeconds = randomValidFromUnixSeconds,
			validUntilUnixSeconds = randomValidFromUnixSeconds
				+ seededRandomNumberGenerator.nextWholeNumberInRange(1, 3),
		})
	end
	return randomPromoCodes
end

local function flipRandomLetterCase(seededRandomNumberGenerator, originalText: string): string
	return (
		string.gsub(originalText, "%a", function(asciiLetter)
			if seededRandomNumberGenerator.nextWholeNumberInRange(0, 1) == 0 then
				return string.upper(asciiLetter)
			end
			return string.lower(asciiLetter)
		end)
	)
end

local function createRandomWhitespacePadding(seededRandomNumberGenerator, maximumPaddingLength: number): string
	local paddingCharacters = {}
	for _ = 1, seededRandomNumberGenerator.nextWholeNumberInRange(0, maximumPaddingLength) do
		table.insert(
			paddingCharacters,
			seededRandomNumberGenerator.pickRandomListElement({ " ", "\t", "\n", "\r", "\v", "\f" })
		)
	end
	return table.concat(paddingCharacters)
end

describe("PromoCodeCatalog randomized", function()
	it("a re-cased catalog text with up to 96 bytes of padding matches, active exactly in its window", function()
		SeededRandomTrials.runSeededRandomTrials(500, function(seededRandomNumberGenerator)
			local randomPromoCodes = createRandomPromoCodeCatalog(seededRandomNumberGenerator)
			expect(PromoCodeCatalog.findPromoCodeCatalogProblems(randomPromoCodes)).toEqual({})
			local chosenPromoCode = seededRandomNumberGenerator.pickRandomListElement(randomPromoCodes)
			local typedPromoCodeText = createRandomWhitespacePadding(seededRandomNumberGenerator, 48)
				.. flipRandomLetterCase(seededRandomNumberGenerator, chosenPromoCode.promoCodeText)
				.. createRandomWhitespacePadding(seededRandomNumberGenerator, 48)
			local currentUnixSeconds = chosenPromoCode.validFromUnixSeconds
				+ seededRandomNumberGenerator.nextWholeNumberInRange(-3, 6)
			local isInsideWindow = chosenPromoCode.validFromUnixSeconds <= currentUnixSeconds
				and currentUnixSeconds < chosenPromoCode.validUntilUnixSeconds
			local promoCodeMatchDecision = PromoCodeCatalog.decidePromoCodeMatchAtUnixSeconds(
				typedPromoCodeText,
				currentUnixSeconds,
				randomPromoCodes
			)
			expect(promoCodeMatchDecision.matchedPromoCode).toBe(chosenPromoCode)
			expect(promoCodeMatchDecision.isPromoCodeActiveMatch).toBe(isInsideWindow)
			expect(promoCodeMatchDecision.rejectionReason).toBe(if isInsideWindow then nil else "PromoCodeNotActive")
		end)
	end)

	it("arbitrary bytes never raise and agree with an independent reference model", function()
		SeededRandomTrials.runSeededRandomTrials(1000, function(seededRandomNumberGenerator)
			local randomPromoCodes = createRandomPromoCodeCatalog(seededRandomNumberGenerator)
			local typedCharacters = {}
			local useNearMissOfCatalogText = seededRandomNumberGenerator.nextWholeNumberInRange(0, 1) == 0
			if useNearMissOfCatalogText then
				-- A catalog text with one random byte changed, inserted or removed, often a near-match.
				local baseText = seededRandomNumberGenerator.pickRandomListElement(randomPromoCodes).promoCodeText
				for characterPosition = 1, #baseText do
					table.insert(typedCharacters, string.sub(baseText, characterPosition, characterPosition))
				end
				local editPosition = seededRandomNumberGenerator.nextWholeNumberInRange(1, #typedCharacters + 1)
				local editKind = seededRandomNumberGenerator.nextWholeNumberInRange(1, 4)
				local randomByteCharacter = string.char(seededRandomNumberGenerator.nextWholeNumberInRange(0, 255))
				if editKind == 1 and editPosition <= #typedCharacters then
					typedCharacters[editPosition] = randomByteCharacter
				elseif editKind == 2 then
					table.insert(typedCharacters, editPosition, randomByteCharacter)
				elseif editKind == 3 and editPosition <= #typedCharacters then
					table.remove(typedCharacters, editPosition)
				end
			else
				for _ = 1, seededRandomNumberGenerator.nextWholeNumberInRange(0, 160) do
					table.insert(
						typedCharacters,
						string.char(seededRandomNumberGenerator.nextWholeNumberInRange(0, 255))
					)
				end
			end
			-- Up to 60 bytes each side, so matching texts land on both sides of the 128-byte cap.
			local typedPromoCodeText = createRandomWhitespacePadding(seededRandomNumberGenerator, 60)
				.. table.concat(typedCharacters)
				.. createRandomWhitespacePadding(seededRandomNumberGenerator, 60)
			local currentUnixSeconds = seededRandomNumberGenerator.nextWholeNumberInRange(1699999990, 1900000010)
			local didDecide, promoCodeMatchDecision = pcall(
				PromoCodeCatalog.decidePromoCodeMatchAtUnixSeconds,
				typedPromoCodeText,
				currentUnixSeconds,
				randomPromoCodes
			)
			expect(didDecide).toBeTrue()
			expect(promoCodeMatchDecision).toEqual(
				decideWithReferenceModel(typedPromoCodeText, currentUnixSeconds, randomPromoCodes)
			)
		end)
	end)

	it("a catalog with one randomly broken rule always reports a problem", function()
		local ruleBreakers = {
			function(randomPromoCodes)
				randomPromoCodes[#randomPromoCodes + 1] = table.clone(randomPromoCodes[1])
				-- A valid, distinct text, so only the repeated promoCodeId breaks a rule.
				randomPromoCodes[#randomPromoCodes].promoCodeText = "DuplicateIdEntryText"
			end,
			function(randomPromoCodes)
				local duplicatedTextEntry = table.clone(randomPromoCodes[1])
				duplicatedTextEntry.promoCodeId = "random_duplicate_text"
				duplicatedTextEntry.promoCodeText = string.upper(duplicatedTextEntry.promoCodeText)
				randomPromoCodes[#randomPromoCodes + 1] = duplicatedTextEntry
			end,
			function(randomPromoCodes)
				randomPromoCodes[#randomPromoCodes].starCoinReward = 0
			end,
			function(randomPromoCodes)
				randomPromoCodes[1].validUntilUnixSeconds = randomPromoCodes[1].validFromUnixSeconds
			end,
		}
		SeededRandomTrials.runSeededRandomTrials(200, function(seededRandomNumberGenerator)
			local randomPromoCodes = createRandomPromoCodeCatalog(seededRandomNumberGenerator)
			seededRandomNumberGenerator.pickRandomListElement(ruleBreakers)(randomPromoCodes)
			expect(#PromoCodeCatalog.findPromoCodeCatalogProblems(randomPromoCodes) >= 1).toBeTrue()
		end)
	end)
end)
