-- Cosmetic catalog rules (development spec §0.2, §1.7, §1.10, §2.8), checked for every entry.
-- Spec §5.2 (no real names) cannot be checked by a test; the owner reviews the names.
-- Randomized lookup trials name their seed on failure; rerun with IDOLGROW_RANDOM_TEST_SEED=<seed>.

local UnitTestFramework = require("../Support/UnitTestFramework")
local CosmeticCatalog = require("../../src/shared/CosmeticCatalog")
local OutfitScoreCalculator = require("../../src/shared/OutfitScoreCalculator")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

-- Copied by hand from spec §1.7; the module must match it exactly.
local SPEC_COSMETIC_KINDS = { "Title", "NameplateStyle", "StageEntranceEffect" }

-- Draft naming convention, after the spec's example id `title_rising_star`.
local COSMETIC_ID_PREFIX_BY_COSMETIC_KIND = {
	Title = "title_",
	NameplateStyle = "nameplate_",
	StageEntranceEffect = "entrance_",
}

-- Pricing guide of spec §1.7: a themed round pays about 60 Star Coins on average; cheap items
-- cost about 5 rounds, standard about 15, premium about 50. "About" is read as within 15%.
local AVERAGE_STAR_COINS_PER_THEMED_ROUND = 60
local GUIDE_PRICE_TIER_ROUND_COUNTS = { 5, 15, 50 }
local GUIDE_PRICE_TOLERANCE_FRACTION = 0.15

-- Draft limit (not in the spec): a display name must fit a shop row or a nameplate.
local MAXIMUM_DISPLAY_NAME_LENGTH = 32

-- Estimate of what a heavily active player earns in three weeks (spec §0.2: there must always be
-- more to buy than an active player can afford in two to three weeks). Assumptions, each chosen
-- at the generous end, because the spec does not define "active player":
--   * Three weeks (the upper end of §0.2): 21 days, two hours of play every day.
--   * Back-to-back themed rounds of 280 seconds (§0.2): floor(2 x 3600 / 280) = 25 rounds a day.
--   * Every round pays the top star reward, read from OutfitScoreCalculator.STAR_REWARD_TIERS
--     (100 today), because players will find the best outfit for each theme (§0.2 B).
--   * Every playtime milestone claimed every day: 20+30+50+80+100+150 = 430 coins (§1.8).
--   * All three daily quests completed every day at 100 coins each (the §1.8 example reward).
--   * Two promo codes redeemed at 300 coins each (the §1.9 example reward).
-- Milestones, quests and promo codes have no module yet, so their spec values are copied here.
local ESTIMATED_PLAY_HOURS_PER_DAY = 2
local ESTIMATED_DAYS = 21
local THEMED_ROUND_SECONDS = 280
local PLAYTIME_MILESTONE_STAR_COINS_PER_DAY = 20 + 30 + 50 + 80 + 100 + 150
local DAILY_QUEST_STAR_COINS_PER_DAY = 3 * 100
local PROMO_CODE_STAR_COINS_IN_ESTIMATE = 2 * 300

local function findTopStarCoinsPerThemedRound(): number
	local topStarCoinsGranted = 0
	for _, starRewardTier in OutfitScoreCalculator.STAR_REWARD_TIERS do
		topStarCoinsGranted = math.max(topStarCoinsGranted, starRewardTier.starCoinsGranted)
	end
	return topStarCoinsGranted
end

local function estimateHeavilyActivePlayerStarCoinsInThreeWeeks(): number
	local themedRoundsPerDay = math.floor(ESTIMATED_PLAY_HOURS_PER_DAY * 3600 / THEMED_ROUND_SECONDS)
	local starCoinsPerDay = themedRoundsPerDay * findTopStarCoinsPerThemedRound()
		+ PLAYTIME_MILESTONE_STAR_COINS_PER_DAY
		+ DAILY_QUEST_STAR_COINS_PER_DAY
	return ESTIMATED_DAYS * starCoinsPerDay + PROMO_CODE_STAR_COINS_IN_ESTIMATE
end

-- The guide tier (5, 15 or 50 rounds) this price is "about", or nil if it is near none of them.
local function findGuidePriceTierRoundCount(starCoinPrice: number): number?
	local priceInRounds = starCoinPrice / AVERAGE_STAR_COINS_PER_THEMED_ROUND
	for _, tierRoundCount in GUIDE_PRICE_TIER_ROUND_COUNTS do
		if math.abs(priceInRounds - tierRoundCount) <= tierRoundCount * GUIDE_PRICE_TOLERANCE_FRACTION then
			return tierRoundCount
		end
	end
	return nil
end

-- Lower case with every run of whitespace collapsed to one space: two names with the same key
-- look the same in a shop row.
local function createDisplayNameComparisonKey(displayName: string): string
	return string.lower((string.gsub(displayName, "%s+", " ")))
end

local function collectCatalogCosmeticsOfKind(cosmeticKind: string)
	local catalogCosmeticsOfKind = {}
	for _, cosmetic in CosmeticCatalog.COSMETICS do
		if cosmetic.cosmeticKind == cosmeticKind then
			table.insert(catalogCosmeticsOfKind, cosmetic)
		end
	end
	return catalogCosmeticsOfKind
end

local NON_STRING_CANDIDATES = { 1, 0, true, false, {}, function() end }

local function describeCosmetic(cosmetic): string
	return "cosmetic " .. tostring(cosmetic.cosmeticId)
end

local function isSnakeCaseIdentifier(candidateIdentifier: string): boolean
	return string.match(candidateIdentifier, "^[a-z][_a-z0-9]*$") ~= nil
		and string.find(candidateIdentifier, "__", 1, true) == nil
		and string.sub(candidateIdentifier, -1) ~= "_"
end

local function sumStarCoinPrices(cosmetics): number
	local totalStarCoinPrice = 0
	for _, cosmetic in cosmetics do
		totalStarCoinPrice += cosmetic.starCoinPrice
	end
	return totalStarCoinPrice
end

describe("CosmeticCatalog entries", function()
	it("contains title_rising_star exactly as in spec §1.7", function()
		expect(CosmeticCatalog.findCosmeticByCosmeticId("title_rising_star")).toEqual({
			cosmeticId = "title_rising_star",
			cosmeticKind = "Title",
			cosmeticDisplayName = "Rising Star",
			starCoinPrice = 300,
		})
	end)

	it("COSMETIC_KINDS matches spec §1.7 exactly", function()
		expect(CosmeticCatalog.COSMETIC_KINDS).toEqual(SPEC_COSMETIC_KINDS)
	end)

	it("every entry has exactly the four fields of spec §1.7", function()
		for _, cosmetic in CosmeticCatalog.COSMETICS do
			local fieldNames = {}
			for fieldName in cosmetic do
				table.insert(fieldNames, fieldName)
			end
			table.sort(fieldNames)
			expect({ describeCosmetic(cosmetic), fieldNames }).toEqual({
				describeCosmetic(cosmetic),
				{ "cosmeticDisplayName", "cosmeticId", "cosmeticKind", "starCoinPrice" },
			})
		end
	end)

	it("every cosmetic id is unique snake_case", function()
		local seenCosmeticIdSet = {}
		for _, cosmetic in CosmeticCatalog.COSMETICS do
			local cosmeticLabel = describeCosmetic(cosmetic)
			expect({
				cosmeticLabel,
				type(cosmetic.cosmeticId) == "string" and isSnakeCaseIdentifier(cosmetic.cosmeticId),
			}).toEqual({
				cosmeticLabel,
				true,
			})
			expect({ cosmeticLabel, seenCosmeticIdSet[cosmetic.cosmeticId] }).toEqual({ cosmeticLabel, nil })
			seenCosmeticIdSet[cosmetic.cosmeticId] = true
		end
	end)

	it("every cosmetic has a known kind and an id starting with that kind's prefix", function()
		for _, cosmetic in CosmeticCatalog.COSMETICS do
			local cosmeticLabel = describeCosmetic(cosmetic)
			expect({ cosmeticLabel, table.find(SPEC_COSMETIC_KINDS, cosmetic.cosmeticKind) ~= nil }).toEqual({
				cosmeticLabel,
				true,
			})
			local cosmeticIdPrefix = COSMETIC_ID_PREFIX_BY_COSMETIC_KIND[cosmetic.cosmeticKind] or "?"
			local hasKindPrefix = string.sub(cosmetic.cosmeticId, 1, #cosmeticIdPrefix) == cosmeticIdPrefix
				and #cosmetic.cosmeticId > #cosmeticIdPrefix
			expect({ cosmeticLabel, hasKindPrefix }).toEqual({ cosmeticLabel, true })
		end
	end)

	it("every display name is non-empty, trimmed, single-spaced, short and printable", function()
		for _, cosmetic in CosmeticCatalog.COSMETICS do
			local cosmeticLabel = describeCosmetic(cosmetic)
			local displayName = cosmetic.cosmeticDisplayName
			local isWellFormedDisplayName = type(displayName) == "string"
				and #displayName > 0
				and #displayName <= MAXIMUM_DISPLAY_NAME_LENGTH
				and string.match(displayName, "^%s") == nil
				and string.match(displayName, "%s$") == nil
				and string.find(displayName, "%c") == nil
				and string.find(displayName, "  ", 1, true) == nil
			expect({ cosmeticLabel, isWellFormedDisplayName }).toEqual({ cosmeticLabel, true })
		end
	end)

	it("no two display names look the same, ignoring letter case and spacing", function()
		local seenDisplayNameComparisonKeySet = {}
		for _, cosmetic in CosmeticCatalog.COSMETICS do
			local cosmeticLabel = describeCosmetic(cosmetic)
			local displayNameComparisonKey = createDisplayNameComparisonKey(cosmetic.cosmeticDisplayName)
			expect({ cosmeticLabel, seenDisplayNameComparisonKeySet[displayNameComparisonKey] }).toEqual({
				cosmeticLabel,
				nil,
			})
			seenDisplayNameComparisonKeySet[displayNameComparisonKey] = true
		end
	end)

	it("every price is a whole positive number", function()
		for _, cosmetic in CosmeticCatalog.COSMETICS do
			local cosmeticLabel = describeCosmetic(cosmetic)
			local starCoinPrice = cosmetic.starCoinPrice
			local isWholePositiveNumber = type(starCoinPrice) == "number"
				and starCoinPrice > 0
				and starCoinPrice < math.huge
				and starCoinPrice == math.floor(starCoinPrice)
			expect({ cosmeticLabel, isWholePositiveNumber }).toEqual({ cosmeticLabel, true })
		end
	end)

	it("every price is about 5, 15 or 50 rounds of pay, and each of those tiers is used (§1.7)", function()
		local cosmeticCountByTierRoundCount = {}
		for _, cosmetic in CosmeticCatalog.COSMETICS do
			local cosmeticLabel = describeCosmetic(cosmetic)
			local tierRoundCount = findGuidePriceTierRoundCount(cosmetic.starCoinPrice)
			expect({ cosmeticLabel, cosmetic.starCoinPrice, tierRoundCount ~= nil }).toEqual({
				cosmeticLabel,
				cosmetic.starCoinPrice,
				true,
			})
			if tierRoundCount ~= nil then
				cosmeticCountByTierRoundCount[tierRoundCount] = (cosmeticCountByTierRoundCount[tierRoundCount] or 0) + 1
			end
		end
		for _, tierRoundCount in GUIDE_PRICE_TIER_ROUND_COUNTS do
			expect({ tierRoundCount, (cosmeticCountByTierRoundCount[tierRoundCount] or 0) > 0 }).toEqual({
				tierRoundCount,
				true,
			})
		end
	end)

	it("every kind has entries", function()
		for _, cosmeticKind in SPEC_COSMETIC_KINDS do
			expect({ cosmeticKind, #collectCatalogCosmeticsOfKind(cosmeticKind) > 0 }).toEqual({ cosmeticKind, true })
		end
	end)

	it("costs more in total than a heavily active player earns in three weeks (§0.2)", function()
		local estimatedStarCoinsEarned = estimateHeavilyActivePlayerStarCoinsInThreeWeeks()
		local totalCatalogStarCoinPrice = sumStarCoinPrices(CosmeticCatalog.COSMETICS)
		expect({
			totalCatalogStarCoinPrice,
			estimatedStarCoinsEarned,
			totalCatalogStarCoinPrice > estimatedStarCoinsEarned,
		}).toEqual({
			totalCatalogStarCoinPrice,
			estimatedStarCoinsEarned,
			true,
		})
	end)

	it("is frozen, cosmetic by cosmetic", function()
		expect(table.isfrozen(CosmeticCatalog)).toBeTrue()
		expect(table.isfrozen(CosmeticCatalog.COSMETIC_KINDS)).toBeTrue()
		expect(table.isfrozen(CosmeticCatalog.COSMETICS)).toBeTrue()
		for _, cosmetic in CosmeticCatalog.COSMETICS do
			expect({ describeCosmetic(cosmetic), table.isfrozen(cosmetic) }).toEqual({
				describeCosmetic(cosmetic),
				true,
			})
		end
	end)
end)

describe("CosmeticCatalog lookups", function()
	it("finds every cosmetic by id and returns nil for unknown, wrongly cased or non-string ids", function()
		for _, cosmetic in CosmeticCatalog.COSMETICS do
			expect(CosmeticCatalog.findCosmeticByCosmeticId(cosmetic.cosmeticId)).toBe(cosmetic)
		end
		expect(CosmeticCatalog.findCosmeticByCosmeticId("TITLE_RISING_STAR")).toBeNil()
		expect(CosmeticCatalog.findCosmeticByCosmeticId("no_such_cosmetic")).toBeNil()
		expect(CosmeticCatalog.findCosmeticByCosmeticId("")).toBeNil()
		expect(CosmeticCatalog.findCosmeticByCosmeticId(nil)).toBeNil()
		for _, nonStringCandidate in NON_STRING_CANDIDATES do
			expect(CosmeticCatalog.findCosmeticByCosmeticId(nonStringCandidate)).toBeNil()
		end
	end)

	it("lists each kind's cosmetics in catalog order, and together the lists hold every cosmetic once", function()
		local listedCosmeticCountByCosmeticId = {}
		for _, cosmeticKind in SPEC_COSMETIC_KINDS do
			local expectedCosmetics = collectCatalogCosmeticsOfKind(cosmeticKind)
			local listedCosmetics = CosmeticCatalog.listCosmeticsOfKind(cosmeticKind)
			expect({ cosmeticKind, #listedCosmetics }).toEqual({ cosmeticKind, #expectedCosmetics })
			for listPosition, listedCosmetic in listedCosmetics do
				expect(listedCosmetic).toBe(expectedCosmetics[listPosition])
				listedCosmeticCountByCosmeticId[listedCosmetic.cosmeticId] = (
					listedCosmeticCountByCosmeticId[listedCosmetic.cosmeticId] or 0
				) + 1
			end
		end
		for _, cosmetic in CosmeticCatalog.COSMETICS do
			expect({ describeCosmetic(cosmetic), listedCosmeticCountByCosmeticId[cosmetic.cosmeticId] }).toEqual({
				describeCosmetic(cosmetic),
				1,
			})
		end
	end)

	it("lists nothing for an unknown, wrongly cased or non-string kind", function()
		expect(CosmeticCatalog.listCosmeticsOfKind("title")).toEqual({})
		expect(CosmeticCatalog.listCosmeticsOfKind("PhotoFilter")).toEqual({})
		expect(CosmeticCatalog.listCosmeticsOfKind("")).toEqual({})
		expect(CosmeticCatalog.listCosmeticsOfKind(nil)).toEqual({})
		for _, nonStringCandidate in NON_STRING_CANDIDATES do
			expect(CosmeticCatalog.listCosmeticsOfKind(nonStringCandidate)).toEqual({})
		end
	end)

	it("returns a fresh list each time, so a caller cannot change the catalog", function()
		local firstTitleList = CosmeticCatalog.listCosmeticsOfKind("Title")
		expect(table.isfrozen(firstTitleList)).toBeFalse()
		local titleCountBefore = #firstTitleList
		table.insert(firstTitleList, CosmeticCatalog.COSMETICS[#CosmeticCatalog.COSMETICS])
		table.clear(CosmeticCatalog.listCosmeticsOfKind("NameplateStyle"))
		expect(#CosmeticCatalog.listCosmeticsOfKind("Title")).toBe(titleCountBefore)
		expect(#CosmeticCatalog.listCosmeticsOfKind("NameplateStyle") > 0).toBeTrue()
	end)

	it("knows exactly the three kinds of spec §1.7", function()
		for _, cosmeticKind in SPEC_COSMETIC_KINDS do
			expect({ cosmeticKind, CosmeticCatalog.isKnownCosmeticKind(cosmeticKind) }).toEqual({ cosmeticKind, true })
		end
		expect(CosmeticCatalog.isKnownCosmeticKind("title")).toBeFalse()
		expect(CosmeticCatalog.isKnownCosmeticKind("Dance")).toBeFalse()
		expect(CosmeticCatalog.isKnownCosmeticKind("")).toBeFalse()
		expect(CosmeticCatalog.isKnownCosmeticKind(nil)).toBeFalse()
		for _, nonStringCandidate in NON_STRING_CANDIDATES do
			expect(CosmeticCatalog.isKnownCosmeticKind(nonStringCandidate)).toBeFalse()
		end
	end)
end)

-- Randomized lookups: near-miss ids and kinds derived from real ones must never match.
local RANDOM_TRIAL_COUNT = 500

-- Flips the case of one randomly chosen letter (digits and "_" have no case, so they are skipped).
local function changeOneLetterCase(seededRandomNumberGenerator, originalText: string): string
	local letterPositions = {}
	for characterPosition = 1, #originalText do
		if string.match(string.sub(originalText, characterPosition, characterPosition), "%a") then
			table.insert(letterPositions, characterPosition)
		end
	end
	local letterPosition = seededRandomNumberGenerator.pickRandomListElement(letterPositions)
	local originalLetter = string.sub(originalText, letterPosition, letterPosition)
	local changedLetter = if string.upper(originalLetter) ~= originalLetter
		then string.upper(originalLetter)
		else string.lower(originalLetter)
	return string.sub(originalText, 1, letterPosition - 1)
		.. changedLetter
		.. string.sub(originalText, letterPosition + 1)
end

-- The small edits that turn a real id or kind into a near miss.
local NEAR_MISS_EDIT_TYPES = { "AppendCharacter", "RemoveCharacter", "PrependSpace", "AppendSpace", "ChangeLetterCase" }

-- A text that differs from `originalText` by one small edit, so it is never equal to it.
local function createNearMissText(seededRandomNumberGenerator, originalText: string): string
	local nearMissEditType = seededRandomNumberGenerator.pickRandomListElement(NEAR_MISS_EDIT_TYPES)
	local characterPosition = seededRandomNumberGenerator.nextWholeNumberInRange(1, #originalText)
	local nearMissText
	if nearMissEditType == "AppendCharacter" then
		nearMissText = originalText .. string.char(seededRandomNumberGenerator.nextWholeNumberInRange(32, 126))
	elseif nearMissEditType == "RemoveCharacter" then
		nearMissText = string.sub(originalText, 1, characterPosition - 1)
			.. string.sub(originalText, characterPosition + 1)
	elseif nearMissEditType == "PrependSpace" then
		nearMissText = " " .. originalText
	elseif nearMissEditType == "AppendSpace" then
		nearMissText = originalText .. " "
	else
		nearMissText = changeOneLetterCase(seededRandomNumberGenerator, originalText)
	end
	assert(nearMissText ~= originalText, "a near-miss text must differ from the original")
	return nearMissText
end

describe("CosmeticCatalog randomized lookups", function()
	it("an id or kind that differs from a real one finds nothing, unless it is itself real", function()
		SeededRandomTrials.runSeededRandomTrials(RANDOM_TRIAL_COUNT, function(seededRandomNumberGenerator)
			local realCosmetic = seededRandomNumberGenerator.pickRandomListElement(CosmeticCatalog.COSMETICS)
			local nearMissCosmeticId = createNearMissText(seededRandomNumberGenerator, realCosmetic.cosmeticId)
			local foundCosmetic = CosmeticCatalog.findCosmeticByCosmeticId(nearMissCosmeticId)
			if foundCosmetic ~= nil then
				expect(foundCosmetic.cosmeticId).toBe(nearMissCosmeticId)
			end
			expect(foundCosmetic == realCosmetic).toBeFalse()

			local realCosmeticKind = seededRandomNumberGenerator.pickRandomListElement(SPEC_COSMETIC_KINDS)
			local nearMissCosmeticKind = createNearMissText(seededRandomNumberGenerator, realCosmeticKind)
			local isNearMissKindReal = table.find(SPEC_COSMETIC_KINDS, nearMissCosmeticKind) ~= nil
			expect({ nearMissCosmeticKind, CosmeticCatalog.isKnownCosmeticKind(nearMissCosmeticKind) }).toEqual({
				nearMissCosmeticKind,
				isNearMissKindReal,
			})
			if not isNearMissKindReal then
				expect(CosmeticCatalog.listCosmeticsOfKind(nearMissCosmeticKind)).toEqual({})
			end
		end)
	end)
end)
