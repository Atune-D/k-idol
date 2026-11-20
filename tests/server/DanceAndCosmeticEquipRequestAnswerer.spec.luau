-- Spec §2.8 (`RequestEquipDance`, `RequestEquipCosmetic`), §2.13 (rate limit; equipping what is
-- already equipped is accepted and changes nothing), §3.4 (an appearance change requests no save
-- and is written by the next save of any kind), run against a REAL keeper and rate limiter.

local DanceAndCosmeticEquipRequestAnswerer = require("../../src/server/DanceAndCosmeticEquipRequestAnswerer")
local DanceAndCosmeticRequestTestHarness = require("./DanceAndCosmeticRequestTestHarness")
local DanceAndCosmeticShopTestCatalogs = require("../fixtures/DanceAndCosmeticShopTestCatalogs")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local RemoteNames = require("../../src/shared/RemoteNames")
local StandInPlayerSaveDataKeeper = require("../Support/StandInPlayerSaveDataKeeper")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = DanceAndCosmeticRequestTestHarness.PLAYER
local OTHER_PLAYER = DanceAndCosmeticRequestTestHarness.OTHER_PLAYER
local createShopHarness = DanceAndCosmeticRequestTestHarness.createShopHarness
local REMOVED_DANCE_ID = DanceAndCosmeticShopTestCatalogs.REMOVED_DANCE_ID
local REMOVED_COSMETIC_ID = DanceAndCosmeticShopTestCatalogs.REMOVED_COSMETIC_ID

local ACCEPTED = { isAccepted = true }

-- Nothing these requests answer is logged by the answerer itself (only an unusable catalog entry).
local function expectShopLoggerSilent(shopHarness)
	expect(#shopHarness.shopLogger.loggedWarnings + #shopHarness.shopLogger.loggedInformation).toBe(0)
end

local function rejectedWith(rejectionReason: string)
	return { isAccepted = false, rejectionReason = rejectionReason }
end

-- Owns neon_spin and the removed dance, the Rising Star title, the Trendsetter title, the Mint
-- Fresh nameplate and the removed cosmetic; wears starter_wave and the Rising Star title. Every
-- other save field holds progress, so an equip that touches anything else is seen.
local function giveOwnedAndEquippedItems(saveData)
	DanceAndCosmeticRequestTestHarness.giveProgressInEveryUnrelatedSaveField()(saveData)
	saveData.starCoinBalance = 5000
	table.insert(saveData.ownedDanceIds, "neon_spin")
	table.insert(saveData.ownedDanceIds, REMOVED_DANCE_ID)
	saveData.ownedCosmeticIds =
		{ "title_rising_star", "title_trendsetter", "nameplate_mint_fresh", REMOVED_COSMETIC_ID }
	saveData.equippedCosmeticIdByKind = { Title = "title_rising_star" }
end

local function createEquipHarness(shopHarnessOptions: any?)
	return createShopHarness(giveOwnedAndEquippedItems, shopHarnessOptions)
end

-- The two equip requests, described so every shared rule runs for both.
local EQUIP_REQUEST_KINDS = {
	{
		requestName = "RequestEquipDance",
		equipAndBuildAnswer = function(shopHarness, playerUserId, untrustedItemId)
			return shopHarness.equipRequestAnswerer:equipOwnedDanceAndBuildAnswer(playerUserId, untrustedItemId)
		end,
		ownedUnequippedItemId = "neon_spin",
		alreadyEquippedItemId = "starter_wave",
		notOwnedItemId = "moonlight_glide",
		removedOwnedItemId = REMOVED_DANCE_ID,
		notOwnedRejectionReason = "DanceNotOwned",
		ownedItemIdsFieldName = "ownedDanceIds",
		readEquippedState = function(saveData)
			return saveData.equippedDanceId
		end,
		writeEquippedState = function(saveData, equippedState)
			saveData.equippedDanceId = equippedState
		end,
		equipRemovedOwnedItem = function(saveData)
			saveData.equippedDanceId = REMOVED_DANCE_ID
		end,
		expectedEquippedStateAfterEquippingOwnedItem = "neon_spin",
		readAskedItemIds = function(shopHarness)
			return shopHarness.danceCatalog.askedDanceIds
		end,
	},
	{
		requestName = "RequestEquipCosmetic",
		equipAndBuildAnswer = function(shopHarness, playerUserId, untrustedItemId)
			return shopHarness.equipRequestAnswerer:equipOwnedCosmeticAndBuildAnswer(playerUserId, untrustedItemId)
		end,
		ownedUnequippedItemId = "nameplate_mint_fresh",
		alreadyEquippedItemId = "title_rising_star",
		notOwnedItemId = "entrance_confetti_pop",
		removedOwnedItemId = REMOVED_COSMETIC_ID,
		notOwnedRejectionReason = "CosmeticNotOwned",
		ownedItemIdsFieldName = "ownedCosmeticIds",
		readEquippedState = function(saveData)
			return saveData.equippedCosmeticIdByKind
		end,
		writeEquippedState = function(saveData, equippedState)
			saveData.equippedCosmeticIdByKind = table.clone(equippedState)
		end,
		equipRemovedOwnedItem = function(saveData)
			saveData.equippedCosmeticIdByKind.StageEntranceEffect = REMOVED_COSMETIC_ID
		end,
		expectedEquippedStateAfterEquippingOwnedItem = {
			Title = "title_rising_star",
			NameplateStyle = "nameplate_mint_fresh",
		},
		readAskedItemIds = function(shopHarness)
			return shopHarness.cosmeticCatalog.askedCosmeticIds
		end,
	},
}

local function expectSaveExactlyUnchanged(shopHarness, saveDataBefore, inMemoryRevisionBefore, changeEvents)
	expect(shopHarness.readInMemorySaveData()).toEqual(saveDataBefore)
	expect((shopHarness.readSaveChangeRevisions())).toBe(inMemoryRevisionBefore)
	expect(#changeEvents).toBe(0)
end

for _, equipRequestKind in EQUIP_REQUEST_KINDS do
	local equip = equipRequestKind.equipAndBuildAnswer

	describe(equipRequestKind.requestName, function()
		it("is accepted for an owned item and equips it, changing nothing else in the save", function()
			local shopHarness = createEquipHarness()
			local saveDataBefore = shopHarness.readInMemorySaveData()
			expect(equip(shopHarness, PLAYER, equipRequestKind.ownedUnequippedItemId)).toEqual(ACCEPTED)
			expect(shopHarness.readInMemorySaveData()).toEqual(
				DanceAndCosmeticRequestTestHarness.buildExpectedSaveData(saveDataBefore, function(expectedSaveData)
					equipRequestKind.writeEquippedState(
						expectedSaveData,
						equipRequestKind.expectedEquippedStateAfterEquippingOwnedItem
					)
				end)
			)
			expectShopLoggerSilent(shopHarness)
		end)

		it("is an appearance change: one revision and one event, but no save is requested", function()
			local shopHarness = createEquipHarness()
			local inMemoryRevisionBefore, lastSavedRevisionBefore = shopHarness.readSaveChangeRevisions()
			local storageOperationsBefore = shopHarness.countStartedStorageOperations()
			local changeEvents = shopHarness.recordInMemorySaveDataChangedEvents()
			equip(shopHarness, PLAYER, equipRequestKind.ownedUnequippedItemId)
			local inMemoryRevisionAfter, lastSavedRevisionAfter = shopHarness.readSaveChangeRevisions()
			expect(inMemoryRevisionAfter).toBe(inMemoryRevisionBefore + 1)
			expect(lastSavedRevisionAfter).toBe(lastSavedRevisionBefore)
			expect(#changeEvents).toBe(1)
			-- A requested save would start at once (the harness is 20 s past the load); none does,
			-- not even 30 s later.
			expect(shopHarness.countStartedStorageOperations()).toBe(storageOperationsBefore)
			shopHarness.crashableHarness.advanceSeconds(30)
			expect(shopHarness.countStartedStorageOperations()).toBe(storageOperationsBefore)
		end)

		it("is written by the next save of any kind (here the periodic save)", function()
			local shopHarness = createEquipHarness()
			equip(shopHarness, PLAYER, equipRequestKind.ownedUnequippedItemId)
			local crashableHarness = shopHarness.crashableHarness
			expect(crashableHarness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(0)
			crashableHarness.advanceSeconds(PlayerSaveDataKeeper.PERIODIC_SAVE_INTERVAL_SECONDS)
			expect(crashableHarness.fakePlayerSaveDataStorage:countPendingOperations(PLAYER)).toBe(1)
			crashableHarness.fakePlayerSaveDataStorage:completeOldestPendingOperation(PLAYER)
			expect(equipRequestKind.readEquippedState(crashableHarness.readStoredSaveData(PLAYER))).toEqual(
				equipRequestKind.expectedEquippedStateAfterEquippingOwnedItem
			)
		end)

		it("accepts equipping what is already equipped and changes nothing: no revision, save or event", function()
			local shopHarness = createEquipHarness()
			local saveDataBefore = shopHarness.readInMemorySaveData()
			local inMemoryRevisionBefore = shopHarness.readSaveChangeRevisions()
			local storageOperationsBefore = shopHarness.countStartedStorageOperations()
			local changeEvents = shopHarness.recordInMemorySaveDataChangedEvents()
			expect(equip(shopHarness, PLAYER, equipRequestKind.alreadyEquippedItemId)).toEqual(ACCEPTED)
			expectSaveExactlyUnchanged(shopHarness, saveDataBefore, inMemoryRevisionBefore, changeEvents)
			expect(shopHarness.countStartedStorageOperations()).toBe(storageOperationsBefore)
			expectShopLoggerSilent(shopHarness)
		end)

		it("accepts re-equipping an owned, equipped item whose catalog entry was removed, changing nothing", function()
			local shopHarness = createShopHarness(DanceAndCosmeticRequestTestHarness.combineSaveAdjustments({
				giveOwnedAndEquippedItems,
				equipRequestKind.equipRemovedOwnedItem,
			}))
			local saveDataBefore = shopHarness.readInMemorySaveData()
			local inMemoryRevisionBefore = shopHarness.readSaveChangeRevisions()
			local storageOperationsBefore = shopHarness.countStartedStorageOperations()
			local changeEvents = shopHarness.recordInMemorySaveDataChangedEvents()
			expect(equip(shopHarness, PLAYER, equipRequestKind.removedOwnedItemId)).toEqual(ACCEPTED)
			expectSaveExactlyUnchanged(shopHarness, saveDataBefore, inMemoryRevisionBefore, changeEvents)
			expect(shopHarness.countStartedStorageOperations()).toBe(storageOperationsBefore)
			expectShopLoggerSilent(shopHarness)
		end)

		it("refuses re-equipping an equipped item without a catalog entry that is not owned", function()
			local shopHarness = createShopHarness(DanceAndCosmeticRequestTestHarness.combineSaveAdjustments({
				giveOwnedAndEquippedItems,
				equipRequestKind.equipRemovedOwnedItem,
				function(saveData)
					local ownedIds = saveData[equipRequestKind.ownedItemIdsFieldName]
					table.remove(ownedIds, table.find(ownedIds, equipRequestKind.removedOwnedItemId))
				end,
			}))
			local saveDataBefore = shopHarness.readInMemorySaveData()
			expect(equip(shopHarness, PLAYER, equipRequestKind.removedOwnedItemId)).toEqual(
				rejectedWith(equipRequestKind.notOwnedRejectionReason)
			)
			expect(shopHarness.readInMemorySaveData()).toEqual(saveDataBefore)
		end)

		it("refuses an owned, equipped id longer than 64 bytes (never looked up)", function()
			local overLongId = string.rep("q", 65)
			local shopHarness = createShopHarness(DanceAndCosmeticRequestTestHarness.combineSaveAdjustments({
				giveOwnedAndEquippedItems,
				function(saveData)
					table.insert(saveData[equipRequestKind.ownedItemIdsFieldName], overLongId)
					equipRequestKind.writeEquippedState(
						saveData,
						if equipRequestKind.requestName == "RequestEquipDance"
							then overLongId
							else { Title = overLongId }
					)
				end,
			}))
			expect(equip(shopHarness, PLAYER, overLongId)).toEqual(
				rejectedWith(equipRequestKind.notOwnedRejectionReason)
			)
			expect(#equipRequestKind.readAskedItemIds(shopHarness)).toBe(0)
		end)

		it("refuses an item in the catalog that the player does not own, changing nothing", function()
			local shopHarness = createEquipHarness()
			local saveDataBefore = shopHarness.readInMemorySaveData()
			local inMemoryRevisionBefore = shopHarness.readSaveChangeRevisions()
			local changeEvents = shopHarness.recordInMemorySaveDataChangedEvents()
			expect(equip(shopHarness, PLAYER, equipRequestKind.notOwnedItemId)).toEqual(
				rejectedWith(equipRequestKind.notOwnedRejectionReason)
			)
			expectSaveExactlyUnchanged(shopHarness, saveDataBefore, inMemoryRevisionBefore, changeEvents)
			expectShopLoggerSilent(shopHarness)
		end)

		it("answers NotOwned for an id that is in no catalog (the spec gives equip no Unknown reason)", function()
			local shopHarness = createEquipHarness()
			local saveDataBefore = shopHarness.readInMemorySaveData()
			local inMemoryRevisionBefore = shopHarness.readSaveChangeRevisions()
			local changeEvents = shopHarness.recordInMemorySaveDataChangedEvents()
			expect(equip(shopHarness, PLAYER, "ghost_shuffle")).toEqual(
				rejectedWith(equipRequestKind.notOwnedRejectionReason)
			)
			expectSaveExactlyUnchanged(shopHarness, saveDataBefore, inMemoryRevisionBefore, changeEvents)
			expect(equipRequestKind.readAskedItemIds(shopHarness)).toEqual({ "ghost_shuffle" })
		end)

		it("refuses an owned item whose catalog entry was removed, and keeps it owned", function()
			local shopHarness = createEquipHarness()
			local saveDataBefore = shopHarness.readInMemorySaveData()
			local inMemoryRevisionBefore = shopHarness.readSaveChangeRevisions()
			local changeEvents = shopHarness.recordInMemorySaveDataChangedEvents()
			expect(equip(shopHarness, PLAYER, equipRequestKind.removedOwnedItemId)).toEqual(
				rejectedWith(equipRequestKind.notOwnedRejectionReason)
			)
			expectSaveExactlyUnchanged(shopHarness, saveDataBefore, inMemoryRevisionBefore, changeEvents)
			expect(#shopHarness.shopLogger.loggedWarnings).toBe(0)
		end)

		it("answers SaveDataNotLoaded for a player whose save has not loaded, before looking at the id", function()
			local shopHarness = createEquipHarness()
			expect(equip(shopHarness, OTHER_PLAYER, equipRequestKind.ownedUnequippedItemId)).toEqual(
				rejectedWith("SaveDataNotLoaded")
			)
			expect(#equipRequestKind.readAskedItemIds(shopHarness)).toBe(0)
			expectShopLoggerSilent(shopHarness)
		end)

		it("answers SaveDataNotLoaded when the keeper finds the save not loaded", function()
			local shopHarness = createEquipHarness()
			local claimsEveryoneLoadedKeeper =
				StandInPlayerSaveDataKeeper.new(shopHarness.server.playerSaveDataKeeper, {
					isPlayerSaveDataLoaded = function()
						return true
					end,
				})
			shopHarness.rebuildAnswerersForCurrentServer({ playerSaveDataKeeper = claimsEveryoneLoadedKeeper })
			expect(equip(shopHarness, OTHER_PLAYER, equipRequestKind.ownedUnequippedItemId)).toEqual(
				rejectedWith("SaveDataNotLoaded")
			)
		end)

		it("asks the rate limiter first, with the player and this request's channel", function()
			local admitEverythingRateLimiter = DanceAndCosmeticRequestTestHarness.createAdmitEverythingRateLimiter()
			local shopHarness = createEquipHarness({ playerRequestRateLimiter = admitEverythingRateLimiter })
			equip(shopHarness, PLAYER, equipRequestKind.ownedUnequippedItemId)
			expect(admitEverythingRateLimiter.recordedCalls).toEqual({
				{
					playerUserId = PLAYER,
					remoteChannelName = RemoteNames.REMOTE_CHANNEL_NAMES[equipRequestKind.requestName],
				},
			})
		end)

		it("on a rate-limit refusal answers its reason and looks at nothing else", function()
			local shopHarness = createEquipHarness()
			local keeperQuestionCount = 0
			local countingKeeper = StandInPlayerSaveDataKeeper.new(shopHarness.server.playerSaveDataKeeper, {
				isPlayerSaveDataLoaded = function()
					keeperQuestionCount += 1
					return true
				end,
				applyChangeToPlayerSaveData = function()
					keeperQuestionCount += 1
					return { changeOutcome = "Applied", inMemoryChangeRevision = 99 }
				end,
			})
			shopHarness.rebuildAnswerersForCurrentServer({
				playerRequestRateLimiter = {
					admitOrRefusePlayerRequest = function()
						return { isRequestAllowed = false, rejectionReason = "ReasonGivenByTheTestLimiter" }
					end,
				},
				playerSaveDataKeeper = countingKeeper,
			})
			expect(equip(shopHarness, PLAYER, equipRequestKind.ownedUnequippedItemId)).toEqual(
				rejectedWith("ReasonGivenByTheTestLimiter")
			)
			expect(keeperQuestionCount).toBe(0)
			expect(#equipRequestKind.readAskedItemIds(shopHarness)).toBe(0)
		end)

		it(
			"refuses a second equip within 1 s as TooManyRequests, changing nothing, and admits one after 1 s",
			function()
				local shopHarness = createEquipHarness()
				expect(equip(shopHarness, PLAYER, equipRequestKind.ownedUnequippedItemId)).toEqual(ACCEPTED)
				local saveDataAfterFirst = shopHarness.readInMemorySaveData()
				shopHarness.crashableHarness.advanceSeconds(0.999)
				expect(equip(shopHarness, PLAYER, equipRequestKind.alreadyEquippedItemId)).toEqual(
					rejectedWith("TooManyRequests")
				)
				expect(shopHarness.readInMemorySaveData()).toEqual(saveDataAfterFirst)
				expectShopLoggerSilent(shopHarness)
				shopHarness.crashableHarness.advanceSeconds(0.001)
				expect(equip(shopHarness, PLAYER, equipRequestKind.alreadyEquippedItemId)).toEqual(ACCEPTED)
			end
		)

		it("builds a fresh answer table every time", function()
			local shopHarness = createEquipHarness({
				playerRequestRateLimiter = DanceAndCosmeticRequestTestHarness.createAdmitEverythingRateLimiter(),
			})
			for _, playerAndRequestedId in
				{
					{ PLAYER, equipRequestKind.ownedUnequippedItemId },
					{ PLAYER, equipRequestKind.alreadyEquippedItemId },
					{ PLAYER, equipRequestKind.notOwnedItemId },
					{ PLAYER, "ghost_shuffle" },
					{ OTHER_PLAYER, equipRequestKind.ownedUnequippedItemId },
				}
			do
				local playerUserId, untrustedItemId = playerAndRequestedId[1], playerAndRequestedId[2]
				local firstAnswer = equip(shopHarness, playerUserId, untrustedItemId)
				local expectedAnswer = table.clone(firstAnswer)
				firstAnswer.isAccepted = "changed by the caller"
				firstAnswer.rejectionReason = "changed by the caller"
				expect(equip(shopHarness, playerUserId, untrustedItemId)).toEqual(expectedAnswer)
			end
		end)

		it("builds a fresh table for every TooManyRequests answer (real limiter)", function()
			local shopHarness = createEquipHarness()
			expect(equip(shopHarness, PLAYER, equipRequestKind.ownedUnequippedItemId)).toEqual(ACCEPTED)
			local firstRefusal = equip(shopHarness, PLAYER, equipRequestKind.ownedUnequippedItemId)
			expect(firstRefusal).toEqual(rejectedWith("TooManyRequests"))
			firstRefusal.isAccepted = "changed by the caller"
			firstRefusal.rejectionReason = "changed by the caller"
			expect(equip(shopHarness, PLAYER, equipRequestKind.ownedUnequippedItemId)).toEqual(
				rejectedWith("TooManyRequests")
			)
		end)
	end)
end

describe("RequestEquipCosmetic per kind", function()
	it("replaces the equipped cosmetic of the same kind and keeps the other kinds", function()
		local shopHarness = createEquipHarness({
			playerRequestRateLimiter = DanceAndCosmeticRequestTestHarness.createAdmitEverythingRateLimiter(),
		})
		local equipRequestAnswerer = shopHarness.equipRequestAnswerer
		expect(equipRequestAnswerer:equipOwnedCosmeticAndBuildAnswer(PLAYER, "nameplate_mint_fresh")).toEqual(ACCEPTED)
		expect(equipRequestAnswerer:equipOwnedCosmeticAndBuildAnswer(PLAYER, "title_trendsetter")).toEqual(ACCEPTED)
		expect(shopHarness.readInMemorySaveData().equippedCosmeticIdByKind).toEqual({
			Title = "title_trendsetter",
			NameplateStyle = "nameplate_mint_fresh",
		})
	end)

	it("equips a cosmetic bought a moment earlier", function()
		local shopHarness = createShopHarness(DanceAndCosmeticRequestTestHarness.giveStarCoinBalance(3000))
		expect(
			shopHarness.purchaseRequestAnswerer:purchaseCosmeticWithStarCoinsAndBuildAnswer(
				PLAYER,
				"entrance_confetti_pop"
			)
		).toEqual(ACCEPTED)
		expect(shopHarness.equipRequestAnswerer:equipOwnedCosmeticAndBuildAnswer(PLAYER, "entrance_confetti_pop")).toEqual(
			ACCEPTED
		)
		local saveDataAfter = shopHarness.readInMemorySaveData()
		expect(saveDataAfter.starCoinBalance).toBe(0)
		expect(saveDataAfter.equippedCosmeticIdByKind).toEqual({ StageEntranceEffect = "entrance_confetti_pop" })
	end)
end)

describe("RequestEquipDance and the purchase channels", function()
	it("keeps the equip and purchase rate limits independent (both admitted in the same instant)", function()
		local shopHarness = createShopHarness(DanceAndCosmeticRequestTestHarness.giveStarCoinBalance(1000))
		expect(shopHarness.purchaseRequestAnswerer:purchaseDanceWithStarCoinsAndBuildAnswer(PLAYER, "neon_spin")).toEqual(
			ACCEPTED
		)
		expect(shopHarness.equipRequestAnswerer:equipOwnedDanceAndBuildAnswer(PLAYER, "neon_spin")).toEqual(ACCEPTED)
		expect(shopHarness.equipRequestAnswerer:equipOwnedCosmeticAndBuildAnswer(PLAYER, "title_rising_star")).toEqual(
			rejectedWith("CosmeticNotOwned")
		)
		expect(shopHarness.readInMemorySaveData().equippedDanceId).toBe("neon_spin")
	end)
end)

describe("DanceAndCosmeticEquipRequestAnswerer.new", function()
	local requiredDependencyNames =
		{ "playerSaveDataKeeper", "playerRequestRateLimiter", "danceCatalog", "cosmeticCatalog", "logger" }
	for _, missingDependencyName in requiredDependencyNames do
		it("raises, naming it, when " .. missingDependencyName .. " is missing", function()
			local dependencies =
				DanceAndCosmeticRequestTestHarness.buildPlaceholderDependencies(requiredDependencyNames)
			dependencies[missingDependencyName] = nil
			expect(function()
				DanceAndCosmeticEquipRequestAnswerer.new(dependencies)
			end).toThrow("missing dependency " .. missingDependencyName)
		end)
	end

	it("accepts a complete set of dependencies", function()
		local dependencies = DanceAndCosmeticRequestTestHarness.buildPlaceholderDependencies(requiredDependencyNames)
		expect(type(DanceAndCosmeticEquipRequestAnswerer.new(dependencies))).toBe("table")
	end)

	for _, catalogLookup in DanceAndCosmeticRequestTestHarness.CATALOG_LOOKUP_FUNCTION_NAMES do
		local catalogDependencyName, lookupFunctionName = catalogLookup[1], catalogLookup[2]
		it("raises when " .. catalogDependencyName .. " has no " .. lookupFunctionName .. " function", function()
			local dependencies =
				DanceAndCosmeticRequestTestHarness.buildPlaceholderDependencies(requiredDependencyNames)
			dependencies[catalogDependencyName] = {}
			expect(function()
				DanceAndCosmeticEquipRequestAnswerer.new(dependencies)
			end).toThrow(catalogDependencyName .. "." .. lookupFunctionName .. " must be a function")
		end)
	end

	it(
		"lists exactly the equip rejection reasons of §2.8 plus SaveDataNotLoaded and TooManyRequests, frozen",
		function()
			local reasons = DanceAndCosmeticEquipRequestAnswerer.EQUIP_REJECTION_REASONS
			expect(reasons).toEqual({
				DanceNotOwned = "DanceNotOwned",
				CosmeticNotOwned = "CosmeticNotOwned",
				SaveDataNotLoaded = "SaveDataNotLoaded",
				TooManyRequests = "TooManyRequests",
			})
			expect(table.isfrozen(reasons)).toBeTrue()
		end
	)
end)
