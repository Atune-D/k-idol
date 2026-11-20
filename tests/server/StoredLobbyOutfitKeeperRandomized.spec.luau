-- StoredLobbyOutfitKeeper against the §1.5 table "Stored outfits that contain unavailable items",
-- over random pools, one to four players with random stored outfits sharing one catalog, random
-- hidden sets and a random moment at which the wardrobe catalog becomes ready.
-- The expectations are worked out here from the table directly, not through
-- StoredLobbyOutfitResolver. A failure names the seed (SeededRandomTrials).

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeMarketplaceStylingItemResolver = require("../Support/FakeMarketplaceStylingItemResolver")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local StoredLobbyOutfitKeeper = require("../../src/server/StoredLobbyOutfitKeeper")
local StylingItemLookup = require("../../src/shared/StylingItemLookup")
local OutfitValidator = require("../../src/shared/OutfitValidator")
local PlayerSaveDataKeeperTestHarness = require("./PlayerSaveDataKeeperTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

type SeededRandomNumberGenerator = SeededRandomTrials.SeededRandomNumberGenerator

local PLAYER = PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID
local START = PlayerSaveDataKeeperTestHarness.EXAMPLE_STARTING_UNIX_SECONDS
local RANDOM_TRIAL_COUNT = 150

local SINGLE_ITEM_SLOTS = table.freeze({
	"hair",
	"top",
	"bottom",
	"dress",
	"shoes",
	"makeup_eyes",
	"makeup_lips",
	"makeup_face",
	"eyelashes",
	"eyebrows",
})
local MAXIMUM_STORED_ACCESSORY_COUNT = 3

-- A random pool: one to four items per slot, each disabled with probability 1/5. Returns the
-- lookup and the keys grouped by slot.
local function buildRandomStylingItemPool(seededRandomNumberGenerator: SeededRandomNumberGenerator)
	local randomStylingItems = {}
	local stylingItemKeysByItemSlot = {}
	local nextMarketplaceItemId = 9100001
	local allItemSlots = table.clone(SINGLE_ITEM_SLOTS)
	table.insert(allItemSlots, "accessory")
	for _, itemSlot in allItemSlots do
		stylingItemKeysByItemSlot[itemSlot] = {}
		for _ = 1, seededRandomNumberGenerator.nextWholeNumberInRange(1, 4) do
			local marketplaceItemKind = StylingItemLookup.getRequiredMarketplaceItemKindForItemSlot(itemSlot)
			local stylingItemKey = StylingItemLookup.deriveStylingItemKey(marketplaceItemKind, nextMarketplaceItemId)
			table.insert(randomStylingItems, {
				stylingItemKey = stylingItemKey,
				marketplaceItemKind = marketplaceItemKind,
				marketplaceItemId = nextMarketplaceItemId,
				itemSlot = itemSlot,
				styleTags = { "y2k" },
				primaryColorTag = "pink",
				isEnabled = seededRandomNumberGenerator.nextWholeNumberInRange(1, 5) ~= 1,
			})
			table.insert(stylingItemKeysByItemSlot[itemSlot], stylingItemKey)
			nextMarketplaceItemId += 1
		end
	end
	return StylingItemLookup.buildStylingItemByStylingItemKey(randomStylingItems), stylingItemKeysByItemSlot
end

-- An outfit that was valid when it was stored (§1.5: one per slot, at most three accessories, a
-- dress never with a top or bottom), plus zero to three keys that were later dropped from the
-- pool, in random order.
local function buildRandomStoredOutfit(
	seededRandomNumberGenerator: SeededRandomNumberGenerator,
	stylingItemKeysByItemSlot
)
	local storedOutfitStylingItemKeys = {}
	local isWearingDress = seededRandomNumberGenerator.nextWholeNumberInRange(1, 3) == 1
	for _, itemSlot in SINGLE_ITEM_SLOTS do
		local isSlotAllowed = if isWearingDress then itemSlot ~= "top" and itemSlot ~= "bottom" else itemSlot ~= "dress"
		if isSlotAllowed and seededRandomNumberGenerator.nextWholeNumberInRange(1, 2) == 1 then
			table.insert(
				storedOutfitStylingItemKeys,
				seededRandomNumberGenerator.pickRandomListElement(stylingItemKeysByItemSlot[itemSlot])
			)
		end
	end
	local shuffledAccessoryKeys = table.clone(stylingItemKeysByItemSlot.accessory)
	seededRandomNumberGenerator.shuffleListInPlace(shuffledAccessoryKeys)
	for accessoryPosition = 1, seededRandomNumberGenerator.nextWholeNumberInRange(0, MAXIMUM_STORED_ACCESSORY_COUNT) do
		if shuffledAccessoryKeys[accessoryPosition] then
			table.insert(storedOutfitStylingItemKeys, shuffledAccessoryKeys[accessoryPosition])
		end
	end
	for droppedItemNumber = 1, seededRandomNumberGenerator.nextWholeNumberInRange(0, 3) do
		table.insert(storedOutfitStylingItemKeys, "asset_919900" .. tostring(droppedItemNumber))
	end
	seededRandomNumberGenerator.shuffleListInPlace(storedOutfitStylingItemKeys)
	return storedOutfitStylingItemKeys
end

-- Every enabled key, each hidden with a random per-trial probability; disabled keys are never
-- available (the catalog never lists them).
local function buildRandomAvailableStylingItemKeySet(
	seededRandomNumberGenerator: SeededRandomNumberGenerator,
	stylingItemByStylingItemKey
)
	local hiddenProbability = seededRandomNumberGenerator.nextFractionBetweenZeroAndOne()
	-- Keys in sorted order, so the same seed always draws the same numbers for the same keys.
	local sortedStylingItemKeys = {}
	for stylingItemKey in stylingItemByStylingItemKey do
		table.insert(sortedStylingItemKeys, stylingItemKey)
	end
	table.sort(sortedStylingItemKeys)
	local availableStylingItemKeySet = {}
	for _, stylingItemKey in sortedStylingItemKeys do
		local stylingItem = stylingItemByStylingItemKey[stylingItemKey]
		if
			stylingItem.isEnabled
			and seededRandomNumberGenerator.nextFractionBetweenZeroAndOne() >= hiddenProbability
		then
			availableStylingItemKeySet[stylingItemKey] = true
		end
	end
	return availableStylingItemKeySet
end

-- The §1.5 table, applied directly: row 1 removes, row 2 keeps and reports, the rest is worn.
local function workOutExpectationFromTable(storedOutfitStylingItemKeys, stylingItemByStylingItemKey, availableKeySet)
	local expectedKeptKeys, expectedUnavailableKeys, expectedWearableKeys = {}, {}, {}
	for _, storedKey in storedOutfitStylingItemKeys do
		local stylingItem = stylingItemByStylingItemKey[storedKey]
		if stylingItem ~= nil and stylingItem.isEnabled then
			table.insert(expectedKeptKeys, storedKey)
			if availableKeySet[storedKey] then
				table.insert(expectedWearableKeys, storedKey)
			else
				table.insert(expectedUnavailableKeys, storedKey)
			end
		end
	end
	return expectedKeptKeys, expectedUnavailableKeys, expectedWearableKeys
end

local MAXIMUM_PLAYER_COUNT = 4

local function expectEveryPlayerAvailability(storedLobbyOutfitKeeper, randomPlayers, availableKeySet, isCatalogReady)
	for _, randomPlayer in randomPlayers do
		local _, expectedUnavailableKeys, expectedWearableKeys = workOutExpectationFromTable(
			randomPlayer.storedOutfitStylingItemKeys,
			randomPlayer.stylingItemByStylingItemKey,
			availableKeySet
		)
		expect(storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(randomPlayer.playerUserId)).toEqual({
			isWardrobeCatalogReady = isCatalogReady,
			lobbyOutfitStylingItemKeys = randomPlayer.expectedKeptKeys,
			unavailableLobbyOutfitStylingItemKeys = if isCatalogReady then expectedUnavailableKeys else {},
			wearableLobbyOutfitStylingItemKeys = if isCatalogReady then expectedWearableKeys else {},
		})
		if isCatalogReady then
			expect(
				OutfitValidator.validateOutfit(
					expectedWearableKeys,
					randomPlayer.stylingItemByStylingItemKey,
					availableKeySet
				).isOutfitValid
			).toBeTrue()
		end
	end
end

-- One to four players, each with a random stored outfit, share one server and one catalog.
local function runOneRandomStoredOutfitTrial(seededRandomNumberGenerator: SeededRandomNumberGenerator)
	local stylingItemByStylingItemKey, stylingItemKeysByItemSlot =
		buildRandomStylingItemPool(seededRandomNumberGenerator)
	local availableKeySet =
		buildRandomAvailableStylingItemKeySet(seededRandomNumberGenerator, stylingItemByStylingItemKey)
	local isCatalogReadyBeforeLoad = seededRandomNumberGenerator.nextWholeNumberInRange(1, 2) == 1

	local harness = PlayerSaveDataKeeperTestHarness.createKeeperWithFakes()
	local fakeResolver = FakeMarketplaceStylingItemResolver.new()
	if isCatalogReadyBeforeLoad then
		fakeResolver:publishWardrobeCatalog(availableKeySet)
	end
	local storedLobbyOutfitKeeper = StoredLobbyOutfitKeeper.new({
		playerSaveDataKeeper = harness.playerSaveDataKeeper,
		stylingItemByStylingItemKey = stylingItemByStylingItemKey,
		marketplaceStylingItemResolver = fakeResolver,
		logger = { logInformation = function() end, logWarning = function() end },
	})
	storedLobbyOutfitKeeper:startLookingAfterStoredLobbyOutfits()

	local randomPlayers = {}
	for playerNumber = 1, seededRandomNumberGenerator.nextWholeNumberInRange(1, MAXIMUM_PLAYER_COUNT) do
		local playerUserId = PLAYER + playerNumber - 1
		local storedOutfitStylingItemKeys =
			buildRandomStoredOutfit(seededRandomNumberGenerator, stylingItemKeysByItemSlot)
		local storedSaveData = PlayerSaveDataSchema.createStartingPlayerSaveData(
			PlayerSaveDataKeeperTestHarness.STARTER_DANCE_IDS,
			START - 86400
		)
		storedSaveData.lobbyOutfitStylingItemKeys = table.clone(storedOutfitStylingItemKeys)
		harness.fakePlayerSaveDataStorage:setStoredPlayerSaveData(playerUserId, storedSaveData)
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(playerUserId)
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(playerUserId)
		local expectedKeptKeys =
			workOutExpectationFromTable(storedOutfitStylingItemKeys, stylingItemByStylingItemKey, availableKeySet)
		table.insert(randomPlayers, {
			playerUserId = playerUserId,
			storedOutfitStylingItemKeys = storedOutfitStylingItemKeys,
			stylingItemByStylingItemKey = stylingItemByStylingItemKey,
			expectedKeptKeys = expectedKeptKeys,
			hasAnythingToRemove = #expectedKeptKeys < #storedOutfitStylingItemKeys,
		})
	end

	local function expectEverySaveRemovedAtLoadOnly()
		for _, randomPlayer in randomPlayers do
			-- Row 1 removed at load, once; row 2 kept; a save with nothing to remove is not changed.
			expect(
				harness.playerSaveDataKeeper:readPlayerSaveDataCopy(randomPlayer.playerUserId).lobbyOutfitStylingItemKeys
			).toEqual(randomPlayer.expectedKeptKeys)
			expect(harness.playerSaveDataKeeper:readSaveChangeRevisions(randomPlayer.playerUserId)).toBe(
				if randomPlayer.hasAnythingToRemove then 1 else 0
			)
		end
	end

	expectEverySaveRemovedAtLoadOnly()
	if not isCatalogReadyBeforeLoad then
		expectEveryPlayerAvailability(storedLobbyOutfitKeeper, randomPlayers, availableKeySet, false)
		fakeResolver:publishWardrobeCatalog(availableKeySet)
	end
	expectEveryPlayerAvailability(storedLobbyOutfitKeeper, randomPlayers, availableKeySet, true)

	-- A later catalog version with a different hidden set changes what is worn, never the save.
	local laterAvailableKeySet =
		buildRandomAvailableStylingItemKeySet(seededRandomNumberGenerator, stylingItemByStylingItemKey)
	fakeResolver:publishWardrobeCatalog(laterAvailableKeySet)
	expectEveryPlayerAvailability(storedLobbyOutfitKeeper, randomPlayers, laterAvailableKeySet, true)
	expectEverySaveRemovedAtLoadOnly()

	-- What reaches storage with the next save is exactly the kept list.
	for _, randomPlayer in randomPlayers do
		harness.grantStarCoins(randomPlayer.playerUserId, 20)
	end
	harness.advanceSeconds(PlayerSaveDataKeeper.MINIMUM_SECONDS_BETWEEN_SAVE_STARTS)
	for _, randomPlayer in randomPlayers do
		harness.fakePlayerSaveDataStorage:completeOldestPendingOperation(randomPlayer.playerUserId)
		expect(
			harness.fakePlayerSaveDataStorage:readStoredPlayerSaveData(randomPlayer.playerUserId).lobbyOutfitStylingItemKeys
		).toEqual(randomPlayer.expectedKeptKeys)
	end
end

describe("StoredLobbyOutfitKeeper randomized against the §1.5 table", function()
	it(
		"for several players sharing one catalog: removes only keys that left the pool or are disabled, keeps hidden ones, reports and dresses correctly",
		function()
			SeededRandomTrials.runSeededRandomTrials(RANDOM_TRIAL_COUNT, function(seededRandomNumberGenerator)
				runOneRandomStoredOutfitTrial(seededRandomNumberGenerator)
			end)
		end
	)
end)
