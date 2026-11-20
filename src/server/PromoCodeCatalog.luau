-- Promo codes a player can type to receive star coins (development spec §1.9, §2.10), and the
-- pure rule that decides which catalog entry a typed code matches and whether that entry is
-- active at a given moment.
--
-- SERVER ONLY (spec §1.9). This file lives in src/server, which default.project.json maps to
-- ServerScriptService, so player devices never receive it. Never move it, never require it from
-- src/shared or src/client, and never copy a promo code text into those folders.
-- tests/server/PromoCodeCatalogServerOnlyPlacement.spec.luau enforces this by scanning files.
--
-- Matching rules (the spec leaves these open; decided here, conservatively):
--   * The typed text has its leading and trailing whitespace removed; inner whitespace is kept.
--   * The remainder is compared to each catalog text ignoring ASCII letter case.
--   * A typed value that is not a string, or that is longer than
--     MAXIMUM_TYPED_PROMO_CODE_TEXT_BYTE_COUNT (128) bytes BEFORE trimming, matches nothing, so
--     no string work is done on huge input. Catalog texts are at most
--     MAXIMUM_PROMO_CODE_TEXT_BYTE_COUNT (32) bytes, so every code still matches with at least
--     96 bytes of surrounding whitespace; whitespace beyond (128 - text length) bytes is the one
--     case where trimming does not save a typed code.
--   * An entry is active from validFromUnixSeconds INCLUSIVE until validUntilUnixSeconds
--     EXCLUSIVE: active when validFromUnixSeconds <= now < validUntilUnixSeconds.
--
-- Rules every catalog entry follows (findPromoCodeCatalogProblems; enforced by
-- tests/server/PromoCodeCatalog.spec.luau for the shipped entries):
--   * `promoCodeId` is unique, non-empty snake_case. It is what redeemedPromoCodeIds (§1.10)
--     stores, so it must never change or be reused once a code has gone live.
--   * `promoCodeText` is 1 to MAXIMUM_PROMO_CODE_TEXT_BYTE_COUNT printable ASCII
--     characters with no whitespace, and unique ignoring letter case.
--   * `starCoinReward` is a whole number of at least 1.
--   * `validFromUnixSeconds` and `validUntilUnixSeconds` are whole numbers, from before until.
--
-- Out of scope here: the attempt limit, AlreadyRedeemed, granting the reward and saving (all in
-- PromoCodeRedeemer). Pure logic: no Roblox-specific interface is used; the current time and
-- the catalog entries are passed in.

export type PromoCode = {
	promoCodeId: string,
	promoCodeText: string,
	starCoinReward: number,
	validFromUnixSeconds: number,
	validUntilUnixSeconds: number,
}

-- `matchedPromoCode` is set whenever the typed text matched an entry, including when that entry
-- is not active. `rejectionReason` is set exactly when `isPromoCodeActiveMatch` is false.
export type PromoCodeMatchDecision = {
	isPromoCodeActiveMatch: boolean,
	matchedPromoCode: PromoCode?,
	rejectionReason: string?,
}

local PromoCodeCatalog = {}

-- Rejection reasons of spec §2.10 that this pure rule can produce.
PromoCodeCatalog.PROMO_CODE_REJECTION_REASONS = table.freeze({
	UnknownPromoCode = "UnknownPromoCode",
	PromoCodeNotActive = "PromoCodeNotActive",
})

-- Longest catalog promoCodeText, in bytes.
PromoCodeCatalog.MAXIMUM_PROMO_CODE_TEXT_BYTE_COUNT = 32

-- Longest typed text, in bytes before trimming, that is looked at at all. Longer input is
-- answered UnknownPromoCode without any string work. Four times the catalog limit, so ordinary
-- surrounding whitespace never stops a valid code from matching.
PromoCodeCatalog.MAXIMUM_TYPED_PROMO_CODE_TEXT_BYTE_COUNT = 128

-- The shipped catalog is deliberately EMPTY, so no code can be redeemed until the owner defines
-- one with real dates (spec §1.9 gives an example without dates; real codes are the owner's).
-- To add a code, append an entry such as:
--
--   {
--       promoCodeId = "launch_2026",
--       promoCodeText = "<the code players type>",
--       starCoinReward = 300,
--       validFromUnixSeconds = <first second it works, UTC>,
--       validUntilUnixSeconds = <first second it no longer works, UTC>,
--   },
local shippedPromoCodes: { PromoCode } = {}

-- Freezes every entry and then the list itself, and returns the list.
function PromoCodeCatalog.freezePromoCodeCatalog(promoCodeEntries: { PromoCode }): { PromoCode }
	for _, promoCodeEntry in promoCodeEntries do
		table.freeze(promoCodeEntry)
	end
	return table.freeze(promoCodeEntries)
end

PromoCodeCatalog.PROMO_CODES = PromoCodeCatalog.freezePromoCodeCatalog(shippedPromoCodes)

local function isFiniteNumber(candidateNumber: any): boolean
	return type(candidateNumber) == "number"
		and candidateNumber == candidateNumber
		and candidateNumber ~= math.huge
		and candidateNumber ~= -math.huge
end

local function isWholeNumber(candidateNumber: any): boolean
	return isFiniteNumber(candidateNumber) and candidateNumber == math.floor(candidateNumber)
end

local function isPrintableAsciiTextWithoutWhitespace(candidateText: string): boolean
	for characterPosition = 1, #candidateText do
		local characterByte = string.byte(candidateText, characterPosition)
		if characterByte < 33 or characterByte > 126 then
			return false
		end
	end
	return true
end

-- The catalog spelling used for comparison: ASCII letters lowered, nothing else changed.
local function normalizePromoCodeTextForComparison(promoCodeText: string): string
	return string.lower(promoCodeText)
end

-- Lists every rule broken by `promoCodeEntries`, one readable line per problem, in entry order.
-- An empty list means the entries form a valid catalog.
function PromoCodeCatalog.findPromoCodeCatalogProblems(promoCodeEntries: { any }): { string }
	local catalogProblems = {}
	local entryPositionByPromoCodeId = {}
	local entryPositionByNormalizedPromoCodeText = {}

	for entryPosition, promoCodeEntry in promoCodeEntries do
		local entryLabel = "entry " .. tostring(entryPosition)
		local function reportProblem(problemDescription: string)
			table.insert(catalogProblems, entryLabel .. ": " .. problemDescription)
		end

		if type(promoCodeEntry) ~= "table" then
			reportProblem("is not a table")
			continue
		end

		local promoCodeId = promoCodeEntry.promoCodeId
		if type(promoCodeId) ~= "string" or string.match(promoCodeId, "^[a-z][a-z0-9_]*$") == nil then
			reportProblem("promoCodeId must be non-empty snake_case, got " .. tostring(promoCodeId))
		else
			entryLabel ..= " (" .. promoCodeId .. ")"
			local earlierEntryPosition = entryPositionByPromoCodeId[promoCodeId]
			if earlierEntryPosition ~= nil then
				reportProblem("promoCodeId repeats entry " .. earlierEntryPosition)
			else
				entryPositionByPromoCodeId[promoCodeId] = entryPosition
			end
		end

		local promoCodeText = promoCodeEntry.promoCodeText
		if
			type(promoCodeText) ~= "string"
			or #promoCodeText == 0
			or #promoCodeText > PromoCodeCatalog.MAXIMUM_PROMO_CODE_TEXT_BYTE_COUNT
			or not isPrintableAsciiTextWithoutWhitespace(promoCodeText)
		then
			reportProblem(
				"promoCodeText must be 1 to "
					.. PromoCodeCatalog.MAXIMUM_PROMO_CODE_TEXT_BYTE_COUNT
					.. " printable ASCII characters without whitespace"
			)
		else
			local normalizedPromoCodeText = normalizePromoCodeTextForComparison(promoCodeText)
			local earlierEntryPosition = entryPositionByNormalizedPromoCodeText[normalizedPromoCodeText]
			if earlierEntryPosition ~= nil then
				reportProblem("promoCodeText repeats entry " .. earlierEntryPosition .. " ignoring letter case")
			else
				entryPositionByNormalizedPromoCodeText[normalizedPromoCodeText] = entryPosition
			end
		end

		local starCoinReward = promoCodeEntry.starCoinReward
		if not isWholeNumber(starCoinReward) or starCoinReward < 1 then
			reportProblem("starCoinReward must be a whole number of at least 1, got " .. tostring(starCoinReward))
		end

		local validFromUnixSeconds = promoCodeEntry.validFromUnixSeconds
		local validUntilUnixSeconds = promoCodeEntry.validUntilUnixSeconds
		if not isWholeNumber(validFromUnixSeconds) or not isWholeNumber(validUntilUnixSeconds) then
			reportProblem("validFromUnixSeconds and validUntilUnixSeconds must both be whole numbers")
		elseif validFromUnixSeconds >= validUntilUnixSeconds then
			reportProblem("validFromUnixSeconds must be before validUntilUnixSeconds")
		end
	end

	return catalogProblems
end

-- True when `promoCode` can be redeemed at `currentUnixSeconds`: from inclusive, until exclusive.
function PromoCodeCatalog.isPromoCodeActiveAtUnixSeconds(promoCode: PromoCode, currentUnixSeconds: number): boolean
	return promoCode.validFromUnixSeconds <= currentUnixSeconds and currentUnixSeconds < promoCode.validUntilUnixSeconds
end

-- Returns the entry of `promoCodeEntries` that `typedPromoCodeText` names, or nil. Never raises,
-- whatever `typedPromoCodeText` is (it comes from a player's device).
function PromoCodeCatalog.findPromoCodeMatchingTypedText(
	typedPromoCodeText: any,
	promoCodeEntries: { PromoCode }
): PromoCode?
	if type(typedPromoCodeText) ~= "string" then
		return nil
	end
	if #typedPromoCodeText > PromoCodeCatalog.MAXIMUM_TYPED_PROMO_CODE_TEXT_BYTE_COUNT then
		return nil
	end
	local trimmedTypedPromoCodeText = string.match(typedPromoCodeText, "^%s*(.-)%s*$") :: string
	if trimmedTypedPromoCodeText == "" then
		return nil
	end
	local normalizedTypedPromoCodeText = normalizePromoCodeTextForComparison(trimmedTypedPromoCodeText)
	for _, promoCode in promoCodeEntries do
		if normalizePromoCodeTextForComparison(promoCode.promoCodeText) == normalizedTypedPromoCodeText then
			return promoCode
		end
	end
	return nil
end

-- The pure share of spec §2.10: which entry the typed text matches and whether it is active at
-- `currentUnixSeconds`. Rejections: UnknownPromoCode (no entry matches, including non-string or
-- over-long input) and PromoCodeNotActive (matched, but outside its validity window).
-- `currentUnixSeconds` comes from the server's clock; a value that is not a finite number is a
-- programming error and raises.
function PromoCodeCatalog.decidePromoCodeMatchAtUnixSeconds(
	typedPromoCodeText: any,
	currentUnixSeconds: number,
	promoCodeEntries: { PromoCode }
): PromoCodeMatchDecision
	assert(isFiniteNumber(currentUnixSeconds), "decidePromoCodeMatchAtUnixSeconds needs a finite currentUnixSeconds")
	local matchedPromoCode = PromoCodeCatalog.findPromoCodeMatchingTypedText(typedPromoCodeText, promoCodeEntries)
	if matchedPromoCode == nil then
		return {
			isPromoCodeActiveMatch = false,
			rejectionReason = PromoCodeCatalog.PROMO_CODE_REJECTION_REASONS.UnknownPromoCode,
		}
	end
	if not PromoCodeCatalog.isPromoCodeActiveAtUnixSeconds(matchedPromoCode, currentUnixSeconds) then
		return {
			isPromoCodeActiveMatch = false,
			matchedPromoCode = matchedPromoCode,
			rejectionReason = PromoCodeCatalog.PROMO_CODE_REJECTION_REASONS.PromoCodeNotActive,
		}
	end
	return {
		isPromoCodeActiveMatch = true,
		matchedPromoCode = matchedPromoCode,
	}
end

return table.freeze(PromoCodeCatalog)
