-- Randomized sequences of the four dance-shop requests (spec §2.8, §2.13, §3.3) against a simple
-- model: random catalog prices, random starting balance and ownership, random ids (known, unknown,
-- removed from the catalog, and values that are not ids at all), random waits and storage
-- progress, random progress in every unrelated save field, and sometimes a removed id that is
-- still equipped, all through a REAL keeper, ledger and rate limiter. Every answer and the WHOLE
-- in-memory save after every step must match the model, the answerers must log nothing (every
-- trial catalog entry is usable), and the balance must never go below 0 or differ from the
-- starting balance minus the prices of what was bought. Failures print the seed.

local DanceAndCosmeticCatalogEntryFinder = require("../../src/server/DanceAndCosmeticCatalogEntryFinder")
local DanceAndCosmeticRequestTestHarness = require("./DanceAndCosmeticRequestTestHarness")
local DanceAndCosmeticShopTestCatalogs = require("../fixtures/DanceAndCosmeticShopTestCatalogs")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = DanceAndCosmeticRequestTestHarness.PLAYER
local TRIAL_COUNT = 40
local STEPS_PER_TRIAL = 30
local RATE_LIMIT_INTERVAL_MILLISECONDS = 1000

local function buildRandomlyPricedEntries(randomNumberGenerator, catalogEntries)
	local repricedEntries = {}
	for _, catalogEntry in catalogEntries do
		local repricedEntry = table.clone(catalogEntry)
		repricedEntry.starCoinPrice = randomNumberGenerator.nextWholeNumberInRange(0, 2000)
		table.insert(repricedEntries, table.freeze(repricedEntry))
	end
	return repricedEntries
end

local function findEntryById(catalogEntries, itemIdFieldName: string, itemId: any)
	for _, catalogEntry in catalogEntries do
		if catalogEntry[itemIdFieldName] == itemId then
			return catalogEntry
		end
	end
	return nil
end

local function pickRandomSubset(randomNumberGenerator, candidateIds: { string }): { string }
	local pickedIds = {}
	for _, candidateId in candidateIds do
		if randomNumberGenerator.nextWholeNumberInRange(0, 1) == 1 then
			table.insert(pickedIds, candidateId)
		end
	end
	return pickedIds
end

local NOT_AN_ID_VALUES = table.freeze({ 5, true, {}, "", string.rep("x", 65), "ghost_shuffle" })

local function pickRandomRequestedId(randomNumberGenerator, catalogIds: { string }, removedId: string): any
	local pickKind = randomNumberGenerator.nextWholeNumberInRange(1, 10)
	if pickKind <= 7 then
		return randomNumberGenerator.pickRandomListElement(catalogIds)
	end
	if pickKind == 8 then
		return removedId
	end
	if pickKind == 9 then
		return nil
	end
	return randomNumberGenerator.pickRandomListElement(NOT_AN_ID_VALUES)
end

-- The four requests, each with how the model decides it.
local REQUEST_KINDS = {
	{
		channelName = "RequestPurchaseDanceWithStarCoins",
		isPurchase = true,
		catalogEntriesKey = "danceEntries",
		itemIdFieldName = "danceId",
		ownedModelKey = "ownedDanceIds",
		unknownOrNotOwnedReason = "UnknownDance",
		sendRequest = function(shopHarness, requestedId)
			return shopHarness.purchaseRequestAnswerer:purchaseDanceWithStarCoinsAndBuildAnswer(PLAYER, requestedId)
		end,
	},
	{
		channelName = "RequestPurchaseCosmeticWithStarCoins",
		isPurchase = true,
		catalogEntriesKey = "cosmeticEntries",
		itemIdFieldName = "cosmeticId",
		ownedModelKey = "ownedCosmeticIds",
		unknownOrNotOwnedReason = "UnknownCosmetic",
		sendRequest = function(shopHarness, requestedId)
			return shopHarness.purchaseRequestAnswerer:purchaseCosmeticWithStarCoinsAndBuildAnswer(PLAYER, requestedId)
		end,
	},
	{
		channelName = "RequestEquipDance",
		isPurchase = false,
		catalogEntriesKey = "danceEntries",
		itemIdFieldName = "danceId",
		ownedModelKey = "ownedDanceIds",
		unknownOrNotOwnedReason = "DanceNotOwned",
		sendRequest = function(shopHarness, requestedId)
			return shopHarness.equipRequestAnswerer:equipOwnedDanceAndBuildAnswer(PLAYER, requestedId)
		end,
		equipIntoModel = function(shopModel, catalogEntry)
			shopModel.equippedDanceId = catalogEntry.danceId
		end,
		isEquippedInModel = function(shopModel, danceId)
			return shopModel.equippedDanceId == danceId
		end,
	},
	{
		channelName = "RequestEquipCosmetic",
		isPurchase = false,
		catalogEntriesKey = "cosmeticEntries",
		itemIdFieldName = "cosmeticId",
		ownedModelKey = "ownedCosmeticIds",
		unknownOrNotOwnedReason = "CosmeticNotOwned",
		sendRequest = function(shopHarness, requestedId)
			return shopHarness.equipRequestAnswerer:equipOwnedCosmeticAndBuildAnswer(PLAYER, requestedId)
		end,
		equipIntoModel = function(shopModel, catalogEntry)
			shopModel.equippedCosmeticIdByKind[catalogEntry.cosmeticKind] = catalogEntry.cosmeticId
		end,
		isEquippedInModel = function(shopModel, cosmeticId)
			for _, equippedCosmeticId in shopModel.equippedCosmeticIdByKind do
				if equippedCosmeticId == cosmeticId then
					return true
				end
			end
			return false
		end,
	},
}

-- Applies the request to the model and returns the answer the model expects.
local function decideExpectedAnswer(shopModel, requestKind, requestedId, currentUnixMilliseconds: number)
	local lastAcceptedUnixMilliseconds = shopModel.lastAdmittedUnixMillisecondsByChannelName[requestKind.channelName]
	if
		lastAcceptedUnixMilliseconds ~= nil
		and currentUnixMilliseconds - lastAcceptedUnixMilliseconds < RATE_LIMIT_INTERVAL_MILLISECONDS
	then
		return { isAccepted = false, rejectionReason = "TooManyRequests" }
	end
	shopModel.lastAdmittedUnixMillisecondsByChannelName[requestKind.channelName] = currentUnixMilliseconds
	local catalogEntry =
		findEntryById(shopModel[requestKind.catalogEntriesKey], requestKind.itemIdFieldName, requestedId)
	local ownedIds = shopModel[requestKind.ownedModelKey]
	local isOwned = type(requestedId) == "string" and table.find(ownedIds, requestedId) ~= nil
	if catalogEntry == nil then
		-- §2.13: re-equipping what is owned and already equipped is accepted, entry or not.
		local isReequipOfEquippedId = not requestKind.isPurchase
			and DanceAndCosmeticCatalogEntryFinder.isLookupWorthyDanceOrCosmeticId(requestedId)
			and isOwned
			and requestKind.isEquippedInModel(shopModel, requestedId)
		if isReequipOfEquippedId then
			return { isAccepted = true }
		end
		return { isAccepted = false, rejectionReason = requestKind.unknownOrNotOwnedReason }
	end
	if requestKind.isPurchase then
		if isOwned then
			return { isAccepted = false, rejectionReason = "AlreadyOwned" }
		end
		if shopModel.starCoinBalance < catalogEntry.starCoinPrice then
			return { isAccepted = false, rejectionReason = "InsufficientStarCoins" }
		end
		shopModel.starCoinBalance -= catalogEntry.starCoinPrice
		shopModel.totalStarCoinsSpent += catalogEntry.starCoinPrice
		table.insert(ownedIds, requestedId)
		return { isAccepted = true }
	end
	if not isOwned then
		return { isAccepted = false, rejectionReason = requestKind.unknownOrNotOwnedReason }
	end
	requestKind.equipIntoModel(shopModel, catalogEntry)
	return { isAccepted = true }
end

-- The whole save must equal the starting save with only the modelled fields changed (and the
-- fields the keeper itself refreshes on every save: the session lock and lastSavedAtUnixSeconds).
local function expectSaveMatchesModel(saveData, saveDataAtStart, shopModel, startingBalance: number)
	expect(saveData.starCoinBalance >= 0).toBeTrue()
	expect(saveData.starCoinBalance).toBe(startingBalance - shopModel.totalStarCoinsSpent)
	expect(saveData).toEqual(
		DanceAndCosmeticRequestTestHarness.buildExpectedSaveData(saveDataAtStart, function(expectedSaveData)
			expectedSaveData.starCoinBalance = shopModel.starCoinBalance
			expectedSaveData.ownedDanceIds = table.clone(shopModel.ownedDanceIds)
			expectedSaveData.ownedCosmeticIds = table.clone(shopModel.ownedCosmeticIds)
			expectedSaveData.equippedDanceId = shopModel.equippedDanceId
			expectedSaveData.equippedCosmeticIdByKind = table.clone(shopModel.equippedCosmeticIdByKind)
			expectedSaveData.gameServerSessionLock = saveData.gameServerSessionLock
			expectedSaveData.lastSavedAtUnixSeconds = saveData.lastSavedAtUnixSeconds
		end)
	)
end

local function advanceRandomly(randomNumberGenerator, crashableHarness)
	local waitChoice = randomNumberGenerator.nextWholeNumberInRange(1, 4)
	local waitSeconds = ({ 0, 0.5, 1, 12 })[waitChoice]
	if waitSeconds > 0 then
		crashableHarness.advanceSeconds(waitSeconds)
	end
	local fakeStorage = crashableHarness.fakePlayerSaveDataStorage
	if fakeStorage:countPendingOperations(PLAYER) > 0 and randomNumberGenerator.nextWholeNumberInRange(0, 1) == 1 then
		fakeStorage:completeOldestPendingOperation(PLAYER)
	end
end

local function runOneRandomTrial(randomNumberGenerator)
	local danceEntries =
		buildRandomlyPricedEntries(randomNumberGenerator, DanceAndCosmeticShopTestCatalogs.DANCE_ENTRIES)
	local cosmeticEntries =
		buildRandomlyPricedEntries(randomNumberGenerator, DanceAndCosmeticShopTestCatalogs.COSMETIC_ENTRIES)
	local danceIds, cosmeticIds = {}, {}
	for _, danceEntry in danceEntries do
		table.insert(danceIds, danceEntry.danceId)
	end
	for _, cosmeticEntry in cosmeticEntries do
		table.insert(cosmeticIds, cosmeticEntry.cosmeticId)
	end
	local startingBalance = randomNumberGenerator.nextWholeNumberInRange(0, 5000)
	local startingOwnedDanceIds = pickRandomSubset(randomNumberGenerator, danceIds)
	table.insert(startingOwnedDanceIds, DanceAndCosmeticShopTestCatalogs.REMOVED_DANCE_ID)
	local startingOwnedCosmeticIds = pickRandomSubset(randomNumberGenerator, cosmeticIds)
	table.insert(startingOwnedCosmeticIds, DanceAndCosmeticShopTestCatalogs.REMOVED_COSMETIC_ID)
	local isRemovedDanceEquippedAtStart = randomNumberGenerator.nextWholeNumberInRange(0, 2) == 0
	local startingEquippedCosmeticIdByKind = if randomNumberGenerator.nextWholeNumberInRange(0, 2) == 0
		then { Title = DanceAndCosmeticShopTestCatalogs.REMOVED_COSMETIC_ID }
		else {}

	local shopHarness = DanceAndCosmeticRequestTestHarness.createShopHarness(function(saveData)
		DanceAndCosmeticRequestTestHarness.giveProgressInEveryUnrelatedSaveField(randomNumberGenerator)(saveData)
		saveData.starCoinBalance = startingBalance
		saveData.ownedDanceIds = table.clone(startingOwnedDanceIds)
		saveData.ownedCosmeticIds = table.clone(startingOwnedCosmeticIds)
		if isRemovedDanceEquippedAtStart then
			saveData.equippedDanceId = DanceAndCosmeticShopTestCatalogs.REMOVED_DANCE_ID
		end
		saveData.equippedCosmeticIdByKind = table.clone(startingEquippedCosmeticIdByKind)
	end, {
		danceCatalog = DanceAndCosmeticShopTestCatalogs.createDanceCatalog(danceEntries),
		cosmeticCatalog = DanceAndCosmeticShopTestCatalogs.createCosmeticCatalog(cosmeticEntries),
	})
	local crashableHarness = shopHarness.crashableHarness
	local saveDataAtStart = shopHarness.readInMemorySaveData()
	local shopModel = {
		danceEntries = danceEntries,
		cosmeticEntries = cosmeticEntries,
		starCoinBalance = startingBalance,
		totalStarCoinsSpent = 0,
		ownedDanceIds = table.clone(startingOwnedDanceIds),
		ownedCosmeticIds = table.clone(startingOwnedCosmeticIds),
		equippedDanceId = saveDataAtStart.equippedDanceId,
		equippedCosmeticIdByKind = table.clone(startingEquippedCosmeticIdByKind),
		lastAdmittedUnixMillisecondsByChannelName = {},
	}

	for _ = 1, STEPS_PER_TRIAL do
		local requestKind = randomNumberGenerator.pickRandomListElement(REQUEST_KINDS)
		local requestedId = if requestKind.catalogEntriesKey == "danceEntries"
			then pickRandomRequestedId(
				randomNumberGenerator,
				danceIds,
				DanceAndCosmeticShopTestCatalogs.REMOVED_DANCE_ID
			)
			else pickRandomRequestedId(
				randomNumberGenerator,
				cosmeticIds,
				DanceAndCosmeticShopTestCatalogs.REMOVED_COSMETIC_ID
			)
		local revisionBefore = shopHarness.readSaveChangeRevisions()
		local saveDataBefore = shopHarness.readInMemorySaveData()
		local expectedAnswer = decideExpectedAnswer(
			shopModel,
			requestKind,
			requestedId,
			crashableHarness.fakeClock:getCurrentUnixMilliseconds()
		)
		expect(requestKind.sendRequest(shopHarness, requestedId)).toEqual(expectedAnswer)
		local saveDataAfter = shopHarness.readInMemorySaveData()
		expectSaveMatchesModel(saveDataAfter, saveDataAtStart, shopModel, startingBalance)
		expect(#shopHarness.shopLogger.loggedWarnings + #shopHarness.shopLogger.loggedInformation).toBe(0)
		-- A request that leaves the save as it was never bumps the revision (§2.13).
		local revisionAfter = shopHarness.readSaveChangeRevisions()
		if PlayerSaveDataSchema.arePlainValuesDeeplyEqual(saveDataBefore, saveDataAfter) then
			expect(revisionAfter).toBe(revisionBefore)
		else
			expect(revisionAfter).toBe(revisionBefore + 1)
		end
		advanceRandomly(randomNumberGenerator, crashableHarness)
	end
end

describe("dance-shop requests in random sequences", function()
	it("match the model in every answer and every save, and never take the balance below 0", function()
		SeededRandomTrials.runSeededRandomTrials(TRIAL_COUNT, function(randomNumberGenerator)
			runOneRandomTrial(randomNumberGenerator)
		end)
	end)
end)
