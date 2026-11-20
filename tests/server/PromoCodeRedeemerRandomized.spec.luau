-- Seeded random sequences of promo code requests checked against a small independent model of
-- spec §2.10: one attempt per 2 seconds (refused attempts do not count), case-insensitive match,
-- validity window from inclusive until exclusive, one redemption per code, the catalog reward.
-- Each trial builds its own catalog (3 to 5 entries, random texts and rewards, overlapping
-- windows), so codes are retried while the save already holds several redemption records.
-- A failure prints the seed (tests/fixtures/SeededRandomTrials.luau).

local UnitTestFramework = require("../Support/UnitTestFramework")
local PromoCodeFixtures = require("../fixtures/PromoCodeFixtures")
local PromoCodeRedeemerTestHarness = require("./PromoCodeRedeemerTestHarness")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local ATTEMPT_INTERVAL_MILLISECONDS = 2000

-- Every trial's catalog starts its windows around this moment.
local CATALOG_BASE_UNIX_SECONDS = 1800000000

type SeededRandomNumberGenerator = SeededRandomTrials.SeededRandomNumberGenerator

local function pickRandomUpperCaseLetters(seededRandomNumberGenerator: SeededRandomNumberGenerator, letterCount: number)
	local pickedLetters = {}
	for _ = 1, letterCount do
		table.insert(pickedLetters, string.char(seededRandomNumberGenerator.nextWholeNumberInRange(65, 90)))
	end
	return table.concat(pickedLetters)
end

-- 3 to 5 entries with random texts, rewards and windows that overlap one another, so several
-- codes can be redeemed and then retried while all of them are still active.
local function createRandomPromoCodeEntries(seededRandomNumberGenerator: SeededRandomNumberGenerator)
	local randomPromoCodeEntries = {}
	for entryNumber = 1, seededRandomNumberGenerator.nextWholeNumberInRange(3, 5) do
		local validFromUnixSeconds = CATALOG_BASE_UNIX_SECONDS
			+ seededRandomNumberGenerator.nextWholeNumberInRange(-20, 40)
		table.insert(
			randomPromoCodeEntries,
			PromoCodeFixtures.createFixturePromoCode({
				promoCodeId = "fixture_random_" .. tostring(entryNumber),
				-- The entry number keeps texts unique; the letters vary from trial to trial.
				promoCodeText = pickRandomUpperCaseLetters(seededRandomNumberGenerator, 4) .. "-" .. tostring(
					entryNumber
				),
				starCoinReward = seededRandomNumberGenerator.nextWholeNumberInRange(1, 1000),
				validFromUnixSeconds = validFromUnixSeconds,
				validUntilUnixSeconds = validFromUnixSeconds
					+ seededRandomNumberGenerator.nextWholeNumberInRange(10, 90),
			})
		)
	end
	return randomPromoCodeEntries
end

-- The model's own index of the trial's catalog, keyed by lower-case text.
local function indexModelPromoCodesByLowerCaseText(promoCodeEntries)
	local modelPromoCodesByLowerCaseText = {}
	for _, promoCodeEntry in promoCodeEntries do
		modelPromoCodesByLowerCaseText[string.lower(promoCodeEntry.promoCodeText)] = table.clone(promoCodeEntry)
	end
	return modelPromoCodesByLowerCaseText
end

-- Every moment a window opens or closes, in order.
local function listWindowEdgeUnixSeconds(promoCodeEntries): { number }
	local windowEdgeUnixSeconds = {}
	for _, promoCodeEntry in promoCodeEntries do
		table.insert(windowEdgeUnixSeconds, promoCodeEntry.validFromUnixSeconds)
		table.insert(windowEdgeUnixSeconds, promoCodeEntry.validUntilUnixSeconds)
	end
	table.sort(windowEdgeUnixSeconds)
	return windowEdgeUnixSeconds
end

local function spellInRandomLetterCase(seededRandomNumberGenerator: SeededRandomNumberGenerator, promoCodeText: string)
	local spelledCharacters = {}
	for characterPosition = 1, #promoCodeText do
		local promoCodeCharacter = string.sub(promoCodeText, characterPosition, characterPosition)
		table.insert(
			spelledCharacters,
			if seededRandomNumberGenerator.nextWholeNumberInRange(0, 1) == 0
				then string.lower(promoCodeCharacter)
				else string.upper(promoCodeCharacter)
		)
	end
	return table.concat(spelledCharacters)
end

local function pickRandomTypedValue(seededRandomNumberGenerator: SeededRandomNumberGenerator, promoCodeEntries): any
	local randomCatalogText = seededRandomNumberGenerator.pickRandomListElement(promoCodeEntries).promoCodeText
	local typedValueKind = seededRandomNumberGenerator.nextWholeNumberInRange(1, 7)
	if typedValueKind <= 2 then
		return spellInRandomLetterCase(seededRandomNumberGenerator, randomCatalogText)
	elseif typedValueKind == 3 then
		return " " .. spellInRandomLetterCase(seededRandomNumberGenerator, randomCatalogText) .. "\t"
	elseif typedValueKind == 4 then
		return "Wrong" .. tostring(seededRandomNumberGenerator.nextWholeNumberInRange(0, 99999))
	elseif typedValueKind == 5 then
		return string.rep(randomCatalogText, seededRandomNumberGenerator.nextWholeNumberInRange(2, 30))
	elseif typedValueKind == 6 then
		return seededRandomNumberGenerator.pickRandomListElement({ 0 / 0, math.huge, 42, false, "" })
	end
	return { promoCodeText = randomCatalogText, starCoinReward = 99999 }
end

-- What spec §2.10 says the answer must be, and the model's state after it.
local function decideModelAnswer(modelState, typedValue: any, currentUnixMilliseconds: number)
	local lastAdmittedUnixMilliseconds = modelState.lastAdmittedUnixMilliseconds
	if
		lastAdmittedUnixMilliseconds ~= nil
		and currentUnixMilliseconds - lastAdmittedUnixMilliseconds < ATTEMPT_INTERVAL_MILLISECONDS
	then
		return { isAccepted = false, rejectionReason = "TooManyAttempts" }
	end
	modelState.lastAdmittedUnixMilliseconds = currentUnixMilliseconds
	local matchedPromoCode = if type(typedValue) == "string"
		then modelState.promoCodesByLowerCaseText[string.lower(string.match(typedValue, "^%s*(.-)%s*$") :: string)]
		else nil
	if matchedPromoCode == nil then
		return { isAccepted = false, rejectionReason = "UnknownPromoCode" }
	end
	local currentUnixSeconds = currentUnixMilliseconds / 1000
	if
		currentUnixSeconds < matchedPromoCode.validFromUnixSeconds
		or currentUnixSeconds >= matchedPromoCode.validUntilUnixSeconds
	then
		return { isAccepted = false, rejectionReason = "PromoCodeNotActive" }
	end
	if modelState.redeemedPromoCodeIdSet[matchedPromoCode.promoCodeId] then
		modelState.alreadyRedeemedAnswerCount += 1
		return { isAccepted = false, rejectionReason = "AlreadyRedeemed" }
	end
	modelState.redeemedPromoCodeIdSet[matchedPromoCode.promoCodeId] = true
	table.insert(modelState.redeemedPromoCodeIds, matchedPromoCode.promoCodeId)
	modelState.starCoinBalance += matchedPromoCode.starCoinReward
	return { isAccepted = true, starCoinsGranted = matchedPromoCode.starCoinReward }
end

local function moveTimeRandomly(
	harness,
	seededRandomNumberGenerator: SeededRandomNumberGenerator,
	windowEdgeUnixSeconds
)
	local currentUnixSeconds = harness.fakeClock:getCurrentUnixSeconds()
	if seededRandomNumberGenerator.nextWholeNumberInRange(1, 8) == 1 then
		-- Jump to just around the next window edge (time only moves forward).
		for _, nextWindowEdgeUnixSeconds in windowEdgeUnixSeconds do
			local jumpTargetUnixSeconds = nextWindowEdgeUnixSeconds
				+ seededRandomNumberGenerator.nextWholeNumberInRange(-3, 3)
			if jumpTargetUnixSeconds > currentUnixSeconds then
				harness.fakeClock:advanceBySeconds(jumpTargetUnixSeconds - currentUnixSeconds)
				return
			end
		end
		return
	end
	harness.advanceSeconds(seededRandomNumberGenerator.nextWholeNumberInRange(0, 3000) / 1000)
end

describe("PromoCodeRedeemer random request sequences", function()
	it("every answer, the balance and the redemption records match the §2.10 model (seeded)", function()
		local totalAlreadyRedeemedAnswerCount = 0
		local trialsWithAnOlderCodeRetriedCount = 0
		SeededRandomTrials.runSeededRandomTrials(60, function(seededRandomNumberGenerator)
			local promoCodeEntries = createRandomPromoCodeEntries(seededRandomNumberGenerator)
			local windowEdgeUnixSeconds = listWindowEdgeUnixSeconds(promoCodeEntries)
			local harness = PromoCodeRedeemerTestHarness.createHarness({
				requestAtUnixSeconds = CATALOG_BASE_UNIX_SECONDS
					+ seededRandomNumberGenerator.nextWholeNumberInRange(-5, 5),
				promoCodeEntries = promoCodeEntries,
			})
			local modelState = {
				promoCodesByLowerCaseText = indexModelPromoCodesByLowerCaseText(promoCodeEntries),
				lastAdmittedUnixMilliseconds = nil :: number?,
				redeemedPromoCodeIdSet = {},
				redeemedPromoCodeIds = {},
				alreadyRedeemedAnswerCount = 0,
				starCoinBalance = PromoCodeRedeemerTestHarness.STARTING_STAR_COIN_BALANCE,
			}
			local hasRetriedAnOlderCode = false
			for stepNumber = 1, seededRandomNumberGenerator.nextWholeNumberInRange(20, 80) do
				moveTimeRandomly(harness, seededRandomNumberGenerator, windowEdgeUnixSeconds)
				local typedValue = pickRandomTypedValue(seededRandomNumberGenerator, promoCodeEntries)
				local recordCountBeforeStep = #modelState.redeemedPromoCodeIds
				local alreadyRedeemedCountBeforeStep = modelState.alreadyRedeemedAnswerCount
				local expectedAnswer =
					decideModelAnswer(modelState, typedValue, harness.fakeClock:getCurrentUnixMilliseconds())
				local actualAnswer = harness.redeem(typedValue)
				expect({ stepNumber, actualAnswer }).toEqual({ stepNumber, expectedAnswer })
				if
					modelState.alreadyRedeemedAnswerCount > alreadyRedeemedCountBeforeStep
					and recordCountBeforeStep >= 2
				then
					hasRetriedAnOlderCode = true
				end
			end
			local inMemorySaveData = harness.readInMemorySaveData()
			expect(inMemorySaveData.starCoinBalance).toBe(modelState.starCoinBalance)
			expect(inMemorySaveData.fanCount).toBe(0)
			expect(inMemorySaveData.redeemedPromoCodeIds).toEqual(modelState.redeemedPromoCodeIds)
			totalAlreadyRedeemedAnswerCount += modelState.alreadyRedeemedAnswerCount
			if hasRetriedAnOlderCode then
				trialsWithAnOlderCodeRetriedCount += 1
			end
		end)
		-- The trials must actually exercise retries while several records exist.
		expect(totalAlreadyRedeemedAnswerCount > 0).toBeTrue()
		expect(trialsWithAnOlderCodeRetriedCount >= 5).toBeTrue()
	end)
end)
