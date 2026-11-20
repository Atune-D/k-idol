-- DanceAndCosmeticCatalogEntryFinder (development spec v1.3 §1.7, §2.8, §2 intro "every value
-- from the device is untrusted"): turns an UNTRUSTED dance or cosmetic id sent by a device into
-- the catalog entry it names, or nil. Used (through DanceAndCosmeticRequestScreening) by
-- DanceAndCosmeticPurchaseRequestAnswerer and DanceAndCosmeticEquipRequestAnswerer, so both
-- requests read ids by exactly the same rule.
--
-- Calls no Roblox-specific interface. The catalogs and the logger are passed in.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- DanceAndCosmeticCatalogEntryFinder.MAXIMUM_UNTRUSTED_DANCE_OR_COSMETIC_ID_LENGTH_BYTES = 64
--   Longest id (in bytes) that is looked up at all. The spec sets no limit; this one only bounds
--   the work a device can cause. Every id in the real DanceCatalog and CosmeticCatalog must fit
--   (tests/server/DanceAndCosmeticRealCatalogs.spec.luau fails otherwise).
--
-- DanceAndCosmeticCatalogEntryFinder.CATALOG_ENTRY_USES (frozen): Purchase, Equip.
--   What the entry is wanted for; it decides which fields must be usable (see below).
--
-- Catalog interfaces (the real modules src/shared/DanceCatalog.luau and
-- src/shared/CosmeticCatalog.luau satisfy them; tests pass fixture catalogs):
--   DanceCatalogForShop    = { findDanceByDanceId: (danceId: string) -> Dance? }
--   CosmeticCatalogForShop = { findCosmeticByCosmeticId: (cosmeticId: string) -> Cosmetic? }
--   Called with `.`, not `:`, and only ever with a string of
--   1..MAXIMUM_UNTRUSTED_DANCE_OR_COSMETIC_ID_LENGTH_BYTES bytes.
--
-- DanceAndCosmeticCatalogEntryFinder.isLookupWorthyDanceOrCosmeticId(untrustedId) -> boolean
--   True only for a string of 1..MAXIMUM_UNTRUSTED_DANCE_OR_COSMETIC_ID_LENGTH_BYTES bytes.
--   Accepts ANY Luau value and never raises or runs a metamethod.
--
-- DanceAndCosmeticCatalogEntryFinder.findDanceForUntrustedDanceId(danceCatalog, logger, untrustedDanceId, catalogEntryUse) -> Dance?
-- DanceAndCosmeticCatalogEntryFinder.findCosmeticForUntrustedCosmeticId(cosmeticCatalog, logger, untrustedCosmeticId, catalogEntryUse) -> Cosmetic?
--   Accept ANY Luau value as the untrusted id and never raise because of it. Return nil when:
--     * the id is not lookup-worthy (see above): the catalog is not asked and nothing is logged,
--       so a device cannot flood the logs;
--     * the catalog has no entry for it (nothing is logged);
--     * the catalog's entry is unusable for `catalogEntryUse`: logged as a warning naming the
--       catalog, the id (the device's string, at most 64 bytes, escaped with %q) and the problem.
--       Usable for Equip: a table whose `danceId` / `cosmeticId` equals the id; a cosmetic's
--       `cosmeticKind` must also be one of the kinds of spec §1.7 (CosmeticCatalog.COSMETIC_KINDS),
--       because it becomes a key of `equippedCosmeticIdByKind`. Usable for Purchase: usable for
--       Equip, and `starCoinPrice` is a whole number >= 0. The price plays no part in equipping.
--   Otherwise return the catalog's own entry (as the catalog gave it).
--   Raises when `catalogEntryUse` is not one of CATALOG_ENTRY_USES (a programming error).
--   logger = { logWarning: (self, message: string) -> () }
-- ════════════════════════════════════════════════════════════════════════════════════════════

local CosmeticCatalog = require("../shared/CosmeticCatalog")

local DanceAndCosmeticCatalogEntryFinder = {}

DanceAndCosmeticCatalogEntryFinder.MAXIMUM_UNTRUSTED_DANCE_OR_COSMETIC_ID_LENGTH_BYTES = 64

DanceAndCosmeticCatalogEntryFinder.CATALOG_ENTRY_USES = table.freeze({
	Purchase = "Purchase",
	Equip = "Equip",
})

local CATALOG_ENTRY_USES = DanceAndCosmeticCatalogEntryFinder.CATALOG_ENTRY_USES

-- How the dance catalog and the cosmetic catalog differ, so one lookup serves both.
type CatalogLookupDescription = {
	catalogLabel: string,
	catalogEntryIdFieldName: string,
	findCatalogEntryById: (catalog: any, lookupWorthyId: string) -> any,
	describeFamilySpecificEntryProblem: (catalogEntry: { [any]: any }) -> string?,
}

function DanceAndCosmeticCatalogEntryFinder.isLookupWorthyDanceOrCosmeticId(untrustedId: any): boolean
	return type(untrustedId) == "string"
		and #untrustedId >= 1
		and #untrustedId <= DanceAndCosmeticCatalogEntryFinder.MAXIMUM_UNTRUSTED_DANCE_OR_COSMETIC_ID_LENGTH_BYTES
end

-- NaN fails `>= 0`; infinity fails `% 1 == 0` (math.huge % 1 is NaN).
local function isWholeNonNegativeStarCoinPrice(candidateStarCoinPrice: any): boolean
	return type(candidateStarCoinPrice) == "number" and candidateStarCoinPrice >= 0 and candidateStarCoinPrice % 1 == 0
end

local DANCE_CATALOG_LOOKUP: CatalogLookupDescription = table.freeze({
	catalogLabel = "dance catalog",
	catalogEntryIdFieldName = "danceId",
	findCatalogEntryById = function(danceCatalog, lookupWorthyDanceId: string)
		return danceCatalog.findDanceByDanceId(lookupWorthyDanceId)
	end,
	describeFamilySpecificEntryProblem = function(_danceEntry)
		return nil
	end,
})

local COSMETIC_CATALOG_LOOKUP: CatalogLookupDescription = table.freeze({
	catalogLabel = "cosmetic catalog",
	catalogEntryIdFieldName = "cosmeticId",
	findCatalogEntryById = function(cosmeticCatalog, lookupWorthyCosmeticId: string)
		return cosmeticCatalog.findCosmeticByCosmeticId(lookupWorthyCosmeticId)
	end,
	describeFamilySpecificEntryProblem = function(cosmeticEntry)
		if not CosmeticCatalog.isKnownCosmeticKind(cosmeticEntry.cosmeticKind) then
			return "cosmeticKind is not one of the cosmetic kinds of spec 1.7"
		end
		return nil
	end,
})

-- Returns a problem description, or nil when the entry is usable for `catalogEntryUse`.
local function describeCatalogEntryProblem(
	catalogLookupDescription: CatalogLookupDescription,
	catalogEntry: any,
	lookupWorthyId: string,
	catalogEntryUse: string
): string?
	if type(catalogEntry) ~= "table" then
		return "not a table"
	end
	local catalogEntryIdFieldName = catalogLookupDescription.catalogEntryIdFieldName
	if catalogEntry[catalogEntryIdFieldName] ~= lookupWorthyId then
		return string.format("its %s differs from the id it was found by", catalogEntryIdFieldName)
	end
	local familySpecificProblem = catalogLookupDescription.describeFamilySpecificEntryProblem(catalogEntry)
	if familySpecificProblem ~= nil then
		return familySpecificProblem
	end
	if
		catalogEntryUse == CATALOG_ENTRY_USES.Purchase
		and not isWholeNonNegativeStarCoinPrice(catalogEntry.starCoinPrice)
	then
		return "starCoinPrice is not a whole number >= 0"
	end
	return nil
end

local function logUnusableCatalogEntry(logger, catalogLabel: string, lookupWorthyId: string, problemDescription: string)
	logger:logWarning(
		string.format(
			"DanceAndCosmeticCatalogEntryFinder: %s entry %q is unusable (%s); treated as not in the catalog",
			catalogLabel,
			lookupWorthyId,
			problemDescription
		)
	)
end

local function findUsableCatalogEntryForUntrustedId(
	catalogLookupDescription: CatalogLookupDescription,
	catalog,
	logger,
	untrustedId: any,
	catalogEntryUse: string
)
	if CATALOG_ENTRY_USES[catalogEntryUse] == nil then
		error("DanceAndCosmeticCatalogEntryFinder: unknown catalogEntryUse " .. tostring(catalogEntryUse), 3)
	end
	if not DanceAndCosmeticCatalogEntryFinder.isLookupWorthyDanceOrCosmeticId(untrustedId) then
		return nil
	end
	local catalogEntry = catalogLookupDescription.findCatalogEntryById(catalog, untrustedId)
	if catalogEntry == nil then
		return nil
	end
	local catalogEntryProblem =
		describeCatalogEntryProblem(catalogLookupDescription, catalogEntry, untrustedId, catalogEntryUse)
	if catalogEntryProblem ~= nil then
		logUnusableCatalogEntry(logger, catalogLookupDescription.catalogLabel, untrustedId, catalogEntryProblem)
		return nil
	end
	return catalogEntry
end

function DanceAndCosmeticCatalogEntryFinder.findDanceForUntrustedDanceId(
	danceCatalog,
	logger,
	untrustedDanceId: any,
	catalogEntryUse: string
)
	return findUsableCatalogEntryForUntrustedId(
		DANCE_CATALOG_LOOKUP,
		danceCatalog,
		logger,
		untrustedDanceId,
		catalogEntryUse
	)
end

function DanceAndCosmeticCatalogEntryFinder.findCosmeticForUntrustedCosmeticId(
	cosmeticCatalog,
	logger,
	untrustedCosmeticId: any,
	catalogEntryUse: string
)
	return findUsableCatalogEntryForUntrustedId(
		COSMETIC_CATALOG_LOOKUP,
		cosmeticCatalog,
		logger,
		untrustedCosmeticId,
		catalogEntryUse
	)
end

return table.freeze(DanceAndCosmeticCatalogEntryFinder)
