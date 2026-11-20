-- DanceAndCosmeticRequestScreening (development spec v1.3 §2 intro, §2.13, §3.4): the steps every
-- dance and cosmetic request (buy or equip) takes before its own decision, written once so the
-- order the spec fixes cannot drift between DanceAndCosmeticPurchaseRequestAnswerer and
-- DanceAndCosmeticEquipRequestAnswerer:
--   1. ask the rate limiter; 2. refuse while the save is not loaded; 3. find the catalog entry.
--
-- Calls no Roblox-specific interface. Everything external arrives in `screeningDependencies`.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- DanceAndCosmeticRequestScreening.DANCE_FAMILY, .COSMETIC_FAMILY (frozen DanceOrCosmeticFamily):
--   {
--     ownedIdsFieldName: "ownedDanceIds" | "ownedCosmeticIds",
--     catalogEntryIdFieldName: "danceId" | "cosmeticId",
--     findCatalogEntryForUntrustedId: (screeningDependencies, untrustedId, catalogEntryUse) -> entry?
--         -- DanceAndCosmeticCatalogEntryFinder on screeningDependencies.danceCatalog / .cosmeticCatalog
--   }
--
-- DanceAndCosmeticRequestScreening.SCREENING_OUTCOMES (frozen):
--   RequestRefused, NoUsableCatalogEntry, CatalogEntryFound.
--
-- DanceAndCosmeticRequestScreening.checkDanceAndCosmeticDependenciesPresent(moduleName, dependencies, requiredDependencyNames)
--   Raises "<moduleName>.new: missing dependency <name>" for the first name whose value is nil,
--   and "<moduleName>.new: danceCatalog.findDanceByDanceId must be a function" (the same for
--   cosmeticCatalog.findCosmeticByCosmeticId) when a catalog is present without its lookup.
--
-- DanceAndCosmeticRequestScreening.buildRejectedAnswer(rejectionReason) -> answer
--   { isAccepted = false, rejectionReason = rejectionReason }, a fresh table every time.
--
-- DanceAndCosmeticRequestScreening.screenRequestAndFindCatalogEntry(screeningDependencies, family,
--                                    remoteChannelName, catalogEntryUse, playerUserId, untrustedId)
--     -> (screeningOutcome, rejectionReasonOrCatalogEntry)
--   screeningDependencies = { playerRequestRateLimiter, playerSaveDataKeeper, danceCatalog,
--                             cosmeticCatalog, logger } (an answerer passes itself).
--   Steps, in order; the first that refuses ends the screening:
--     1. playerRequestRateLimiter:admitOrRefusePlayerRequest(playerUserId, remoteChannelName).
--        Refused -> ("RequestRefused", <the limiter's rejectionReason>); the id is not looked at
--        and nothing else is asked.
--     2. playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId) false
--        -> ("RequestRefused", "SaveDataNotLoaded"); the id is not looked at.
--     3. family.findCatalogEntryForUntrustedId(...) nil -> ("NoUsableCatalogEntry", nil).
--        Otherwise -> ("CatalogEntryFound", <the catalog's entry>).
--   Logs nothing itself (the finder logs an unusable catalog entry).
-- ════════════════════════════════════════════════════════════════════════════════════════════

local DanceAndCosmeticCatalogEntryFinder = require("./DanceAndCosmeticCatalogEntryFinder")

local DanceAndCosmeticRequestScreening = {}

DanceAndCosmeticRequestScreening.SCREENING_OUTCOMES = table.freeze({
	RequestRefused = "RequestRefused",
	NoUsableCatalogEntry = "NoUsableCatalogEntry",
	CatalogEntryFound = "CatalogEntryFound",
})

local SCREENING_OUTCOMES = DanceAndCosmeticRequestScreening.SCREENING_OUTCOMES

export type DanceOrCosmeticFamily = {
	ownedIdsFieldName: string,
	catalogEntryIdFieldName: string,
	findCatalogEntryForUntrustedId: (screeningDependencies: any, untrustedId: any, catalogEntryUse: string) -> any,
}

DanceAndCosmeticRequestScreening.DANCE_FAMILY = table.freeze({
	ownedIdsFieldName = "ownedDanceIds",
	catalogEntryIdFieldName = "danceId",
	findCatalogEntryForUntrustedId = function(screeningDependencies, untrustedDanceId: any, catalogEntryUse: string)
		return DanceAndCosmeticCatalogEntryFinder.findDanceForUntrustedDanceId(
			screeningDependencies.danceCatalog,
			screeningDependencies.logger,
			untrustedDanceId,
			catalogEntryUse
		)
	end,
}) :: DanceOrCosmeticFamily

DanceAndCosmeticRequestScreening.COSMETIC_FAMILY = table.freeze({
	ownedIdsFieldName = "ownedCosmeticIds",
	catalogEntryIdFieldName = "cosmeticId",
	findCatalogEntryForUntrustedId = function(screeningDependencies, untrustedCosmeticId: any, catalogEntryUse: string)
		return DanceAndCosmeticCatalogEntryFinder.findCosmeticForUntrustedCosmeticId(
			screeningDependencies.cosmeticCatalog,
			screeningDependencies.logger,
			untrustedCosmeticId,
			catalogEntryUse
		)
	end,
}) :: DanceOrCosmeticFamily

-- { catalog dependency name, the lookup function it must carry }
local CATALOG_LOOKUP_FUNCTION_NAMES = table.freeze({
	{ "danceCatalog", "findDanceByDanceId" },
	{ "cosmeticCatalog", "findCosmeticByCosmeticId" },
})

function DanceAndCosmeticRequestScreening.checkDanceAndCosmeticDependenciesPresent(
	moduleName: string,
	dependencies,
	requiredDependencyNames: { string }
)
	for _, requiredDependencyName in requiredDependencyNames do
		if dependencies[requiredDependencyName] == nil then
			error(string.format("%s.new: missing dependency %s", moduleName, requiredDependencyName), 3)
		end
	end
	for _, catalogLookupFunctionName in CATALOG_LOOKUP_FUNCTION_NAMES do
		local catalogDependencyName, lookupFunctionName = catalogLookupFunctionName[1], catalogLookupFunctionName[2]
		if type(dependencies[catalogDependencyName][lookupFunctionName]) ~= "function" then
			error(
				string.format("%s.new: %s.%s must be a function", moduleName, catalogDependencyName, lookupFunctionName),
				3
			)
		end
	end
end

function DanceAndCosmeticRequestScreening.buildRejectedAnswer(rejectionReason: string)
	return { isAccepted = false, rejectionReason = rejectionReason }
end

function DanceAndCosmeticRequestScreening.screenRequestAndFindCatalogEntry(
	screeningDependencies,
	family: DanceOrCosmeticFamily,
	remoteChannelName: string,
	catalogEntryUse: string,
	playerUserId: number,
	untrustedId: any
): (string, any)
	local rateLimitDecision =
		screeningDependencies.playerRequestRateLimiter:admitOrRefusePlayerRequest(playerUserId, remoteChannelName)
	if not rateLimitDecision.isRequestAllowed then
		return SCREENING_OUTCOMES.RequestRefused, rateLimitDecision.rejectionReason
	end
	if not screeningDependencies.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId) then
		return SCREENING_OUTCOMES.RequestRefused, "SaveDataNotLoaded"
	end
	local catalogEntry = family.findCatalogEntryForUntrustedId(screeningDependencies, untrustedId, catalogEntryUse)
	if catalogEntry == nil then
		return SCREENING_OUTCOMES.NoUsableCatalogEntry, nil
	end
	return SCREENING_OUTCOMES.CatalogEntryFound, catalogEntry
end

return table.freeze(DanceAndCosmeticRequestScreening)
