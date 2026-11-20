-- A test double around the REAL OutfitValidator.validateOutfit: it forwards every call unchanged
-- and records it, so a test can count validations and see exactly what was validated.
--
--   CountingOutfitValidator.new(clock?) -> countingOutfitValidator
--   countingOutfitValidator.validateOutfit   pass this as the keeper's `validateOutfit`
--   countingOutfitValidator.validationCallCount
--   countingOutfitValidator.validationCalls   list of { validatedOutfitValue, verdict,
--       validatedAtUnixMilliseconds? }; `validatedOutfitValue` is the value the validator got
--       (the keeper's private copy), recorded as is.

local OutfitValidator = require("../../src/shared/OutfitValidator")

local CountingOutfitValidator = {}

function CountingOutfitValidator.new(clock: { getCurrentUnixMilliseconds: (any) -> number }?)
	local countingOutfitValidator = {
		validationCallCount = 0,
		validationCalls = {},
	}

	function countingOutfitValidator.validateOutfit(
		untrustedOutfitStylingItemKeys: any,
		stylingItemByStylingItemKey,
		availableStylingItemKeySet
	)
		local verdict = OutfitValidator.validateOutfit(
			untrustedOutfitStylingItemKeys,
			stylingItemByStylingItemKey,
			availableStylingItemKeySet
		)
		countingOutfitValidator.validationCallCount += 1
		table.insert(countingOutfitValidator.validationCalls, {
			validatedOutfitValue = untrustedOutfitStylingItemKeys,
			verdict = verdict,
			validatedAtUnixMilliseconds = if clock then clock:getCurrentUnixMilliseconds() else nil,
		})
		return verdict
	end

	return countingOutfitValidator
end

return table.freeze(CountingOutfitValidator)
