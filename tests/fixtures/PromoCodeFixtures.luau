-- Fixture promo codes shared by the PromoCodeCatalog spec files. Invented test values only;
-- they are never shipped and never relied on as real codes.

local PromoCodeCatalog = require("../../src/server/PromoCodeCatalog")

type PromoCode = PromoCodeCatalog.PromoCode

local PromoCodeFixtures = {}

PromoCodeFixtures.FIXTURE_WINDOW_START_UNIX_SECONDS = 1800000000
PromoCodeFixtures.FIXTURE_WINDOW_END_UNIX_SECONDS = 1800086400

-- The fixture entry "StageDebut", with any fields replaced by `promoCodeFieldOverrides`.
function PromoCodeFixtures.createFixturePromoCode(promoCodeFieldOverrides: { [string]: any }?): PromoCode
	local fixturePromoCode = {
		promoCodeId = "fixture_stage_debut",
		promoCodeText = "StageDebut",
		starCoinReward = 300,
		validFromUnixSeconds = PromoCodeFixtures.FIXTURE_WINDOW_START_UNIX_SECONDS,
		validUntilUnixSeconds = PromoCodeFixtures.FIXTURE_WINDOW_END_UNIX_SECONDS,
	}
	for overriddenFieldName, overriddenFieldValue in promoCodeFieldOverrides or {} do
		fixturePromoCode[overriddenFieldName] = overriddenFieldValue
	end
	return fixturePromoCode :: any
end

-- Two valid entries with windows that do not overlap.
function PromoCodeFixtures.createFixturePromoCodeCatalog(): { PromoCode }
	return {
		PromoCodeFixtures.createFixturePromoCode(),
		PromoCodeFixtures.createFixturePromoCode({
			promoCodeId = "fixture_encore_week",
			promoCodeText = "ENCORE-2030",
			starCoinReward = 50,
			validFromUnixSeconds = 1900000000,
			validUntilUnixSeconds = 1900604800,
		}),
	}
end

return table.freeze(PromoCodeFixtures)
