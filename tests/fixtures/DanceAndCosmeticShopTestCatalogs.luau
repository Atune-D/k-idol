-- Fixture dance and cosmetic catalogs for the dance-shop tests. The real DanceCatalog holds only
-- starter dances today, so these add purchasable ones. Every catalog built here records each id
-- it is asked about, so a test can prove an untrusted value never reached the catalog.
--
-- The starter dance ids equal RewardLedgerCrashableServerTestHarness.STARTER_DANCE_IDS, so a new
-- player's save owns exactly the two free dances below. All names are invented.

local DanceAndCosmeticShopTestCatalogs = {}

DanceAndCosmeticShopTestCatalogs.STARTER_DANCE_IDS = table.freeze({ "starter_wave", "starter_step" })

-- Owned by some test saves but NOT in the catalog any more (an entry the owner removed).
DanceAndCosmeticShopTestCatalogs.REMOVED_DANCE_ID = "retired_twirl"
DanceAndCosmeticShopTestCatalogs.REMOVED_COSMETIC_ID = "title_retired_badge"

DanceAndCosmeticShopTestCatalogs.DANCE_ENTRIES = table.freeze({
	table.freeze({
		danceId = "starter_wave",
		danceDisplayName = "Starter Wave",
		danceAnimationAssetId = "rbxassetid://1",
		starCoinPrice = 0,
		isGrantedToNewPlayers = true,
	}),
	table.freeze({
		danceId = "starter_step",
		danceDisplayName = "Starter Step",
		danceAnimationAssetId = "rbxassetid://2",
		starCoinPrice = 0,
		isGrantedToNewPlayers = true,
	}),
	table.freeze({
		danceId = "neon_spin",
		danceDisplayName = "Neon Spin",
		danceAnimationAssetId = "rbxassetid://3",
		starCoinPrice = 900,
		isGrantedToNewPlayers = false,
	}),
	table.freeze({
		danceId = "moonlight_glide",
		danceDisplayName = "Moonlight Glide",
		danceAnimationAssetId = "rbxassetid://4",
		starCoinPrice = 300,
		isGrantedToNewPlayers = false,
	}),
	table.freeze({
		danceId = "sparkle_hop",
		danceDisplayName = "Sparkle Hop",
		danceAnimationAssetId = "",
		starCoinPrice = 50,
		isGrantedToNewPlayers = false,
	}),
})

DanceAndCosmeticShopTestCatalogs.COSMETIC_ENTRIES = table.freeze({
	table.freeze({
		cosmeticId = "title_rising_star",
		cosmeticKind = "Title",
		cosmeticDisplayName = "Rising Star",
		starCoinPrice = 300,
	}),
	table.freeze({
		cosmeticId = "title_trendsetter",
		cosmeticKind = "Title",
		cosmeticDisplayName = "Trendsetter",
		starCoinPrice = 900,
	}),
	table.freeze({
		cosmeticId = "nameplate_mint_fresh",
		cosmeticKind = "NameplateStyle",
		cosmeticDisplayName = "Mint Fresh",
		starCoinPrice = 300,
	}),
	table.freeze({
		cosmeticId = "entrance_confetti_pop",
		cosmeticKind = "StageEntranceEffect",
		cosmeticDisplayName = "Confetti Pop",
		starCoinPrice = 3000,
	}),
})

-- Ids that are NOT in either catalog but look like real ones.
DanceAndCosmeticShopTestCatalogs.UNKNOWN_ITEM_IDS = table.freeze({ "ghost_shuffle", "title_nobody", "" })

local function buildRecordingCatalogLookup(catalogEntries, itemIdFieldName: string)
	local catalogEntryByItemId = {}
	for _, catalogEntry in catalogEntries do
		catalogEntryByItemId[catalogEntry[itemIdFieldName]] = catalogEntry
	end
	local askedItemIds = {}
	local function findCatalogEntry(itemId)
		table.insert(askedItemIds, itemId)
		return catalogEntryByItemId[itemId]
	end
	return findCatalogEntry, askedItemIds
end

-- A DanceCatalogForShop over `danceEntries` (default: DANCE_ENTRIES). `.askedDanceIds` lists
-- every id it was asked about, in order.
function DanceAndCosmeticShopTestCatalogs.createDanceCatalog(danceEntries: { any }?)
	local findDanceByDanceId, askedDanceIds =
		buildRecordingCatalogLookup(danceEntries or DanceAndCosmeticShopTestCatalogs.DANCE_ENTRIES, "danceId")
	return { findDanceByDanceId = findDanceByDanceId, askedDanceIds = askedDanceIds }
end

-- A CosmeticCatalogForShop over `cosmeticEntries` (default: COSMETIC_ENTRIES).
-- `.askedCosmeticIds` lists every id it was asked about, in order.
function DanceAndCosmeticShopTestCatalogs.createCosmeticCatalog(cosmeticEntries: { any }?)
	local findCosmeticByCosmeticId, askedCosmeticIds =
		buildRecordingCatalogLookup(cosmeticEntries or DanceAndCosmeticShopTestCatalogs.COSMETIC_ENTRIES, "cosmeticId")
	return { findCosmeticByCosmeticId = findCosmeticByCosmeticId, askedCosmeticIds = askedCosmeticIds }
end

function DanceAndCosmeticShopTestCatalogs.findDanceEntry(danceId: string)
	for _, danceEntry in DanceAndCosmeticShopTestCatalogs.DANCE_ENTRIES do
		if danceEntry.danceId == danceId then
			return danceEntry
		end
	end
	error("fixture: no dance " .. danceId)
end

function DanceAndCosmeticShopTestCatalogs.findCosmeticEntry(cosmeticId: string)
	for _, cosmeticEntry in DanceAndCosmeticShopTestCatalogs.COSMETIC_ENTRIES do
		if cosmeticEntry.cosmeticId == cosmeticId then
			return cosmeticEntry
		end
	end
	error("fixture: no cosmetic " .. cosmeticId)
end

return table.freeze(DanceAndCosmeticShopTestCatalogs)
