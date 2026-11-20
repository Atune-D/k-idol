-- Spec §2.8 (`RequestPurchaseDanceWithStarCoins`, `RequestPurchaseCosmeticWithStarCoins`), §2.13,
-- §3.3 (one ledger spend; starCoinBalance never below 0), §3.4 (SaveDataNotLoaded; a purchase
-- requests a save at once) and §6.2 "Unit: ledger" (buying an owned item is refused and costs
-- nothing), run against a REAL keeper, ledger and rate limiter.

local DanceAndCosmeticPurchaseRequestAnswerer = require("../../src/server/DanceAndCosmeticPurchaseRequestAnswerer")
local DanceAndCosmeticRequestTestHarness = require("./DanceAndCosmeticRequestTestHarness")
local RemoteNames = require("../../src/shared/RemoteNames")
local StandInPlayerSaveDataKeeper = require("../Support/StandInPlayerSaveDataKeeper")
local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = DanceAndCosmeticRequestTestHarness.PLAYER
local OTHER_PLAYER = DanceAndCosmeticRequestTestHarness.OTHER_PLAYER
local createShopHarness = DanceAndCosmeticRequestTestHarness.createShopHarness
local giveStarCoinBalance = DanceAndCosmeticRequestTestHarness.giveStarCoinBalance

local function rejectedWith(rejectionReason: string)
	return { isAccepted = false, rejectionReason = rejectionReason }
end

local ACCEPTED = { isAccepted = true }

-- Nothing these requests answer is logged by the answerer itself (only an unusable catalog entry).
local function expectShopLoggerSilent(shopHarness)
	expect(#shopHarness.shopLogger.loggedWarnings + #shopHarness.shopLogger.loggedInformation).toBe(0)
end

local function giveBalanceAndOwnedItems(
	starCoinBalance: number,
	ownedDanceIds: { string }?,
	ownedCosmeticIds: { string }?
)
	return function(saveData)
		saveData.starCoinBalance = starCoinBalance
		if ownedDanceIds then
			saveData.ownedDanceIds = ownedDanceIds
		end
		if ownedCosmeticIds then
			saveData.ownedCosmeticIds = ownedCosmeticIds
		end
	end
end

-- The two purchase requests, described so every shared rule runs for both.
local PURCHASE_REQUEST_KINDS = {
	{
		requestName = "RequestPurchaseDanceWithStarCoins",
		expectedPurchaseKind = "Dance",
		purchaseAndBuildAnswer = function(shopHarness, playerUserId, untrustedItemId)
			return shopHarness.purchaseRequestAnswerer:purchaseDanceWithStarCoinsAndBuildAnswer(
				playerUserId,
				untrustedItemId
			)
		end,
		purchasableItemId = "neon_spin",
		purchasableItemPrice = 900,
		otherPurchasableItemId = "moonlight_glide",
		ownedItemIdsFieldName = "ownedDanceIds",
		unknownItemRejectionReason = "UnknownDance",
		idFromTheOtherCatalog = "title_rising_star",
		readAskedItemIds = function(shopHarness)
			return shopHarness.danceCatalog.askedDanceIds
		end,
		giveOtherFamilyOwnedAndEquipped = function(saveData)
			saveData.ownedCosmeticIds = { "title_trendsetter", "nameplate_mint_fresh" }
			saveData.equippedCosmeticIdByKind = { Title = "title_trendsetter", NameplateStyle = "nameplate_mint_fresh" }
		end,
	},
	{
		requestName = "RequestPurchaseCosmeticWithStarCoins",
		expectedPurchaseKind = "Cosmetic",
		purchaseAndBuildAnswer = function(shopHarness, playerUserId, untrustedItemId)
			return shopHarness.purchaseRequestAnswerer:purchaseCosmeticWithStarCoinsAndBuildAnswer(
				playerUserId,
				untrustedItemId
			)
		end,
		purchasableItemId = "title_trendsetter",
		purchasableItemPrice = 900,
		otherPurchasableItemId = "nameplate_mint_fresh",
		ownedItemIdsFieldName = "ownedCosmeticIds",
		unknownItemRejectionReason = "UnknownCosmetic",
		idFromTheOtherCatalog = "neon_spin",
		readAskedItemIds = function(shopHarness)
			return shopHarness.cosmeticCatalog.askedCosmeticIds
		end,
		giveOtherFamilyOwnedAndEquipped = function(saveData)
			table.insert(saveData.ownedDanceIds, "sparkle_hop")
			saveData.equippedDanceId = "sparkle_hop"
		end,
	},
}

-- Every other save field holds progress, so a purchase that touches anything but the balance and
-- the one owned list is seen.
local function createHarnessOwning(purchaseRequestKind, starCoinBalance: number, ownedItemIds: { string })
	return createShopHarness(DanceAndCosmeticRequestTestHarness.combineSaveAdjustments({
		DanceAndCosmeticRequestTestHarness.giveProgressInEveryUnrelatedSaveField(),
		purchaseRequestKind.giveOtherFamilyOwnedAndEquipped,
		function(saveData)
			saveData.starCoinBalance = starCoinBalance
			for _, ownedItemId in ownedItemIds do
				table.insert(saveData[purchaseRequestKind.ownedItemIdsFieldName], ownedItemId)
			end
		end,
	}))
end

for _, purchaseRequestKind in PURCHASE_REQUEST_KINDS do
	local purchase = purchaseRequestKind.purchaseAndBuildAnswer
	local itemId = purchaseRequestKind.purchasableItemId
	local itemPrice = purchaseRequestKind.purchasableItemPrice
	local ownedFieldName = purchaseRequestKind.ownedItemIdsFieldName

	describe(purchaseRequestKind.requestName, function()
		it("is accepted when the item exists, is not owned and the balance covers the catalog price", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, 1000, {})
			local saveDataBefore = shopHarness.readInMemorySaveData()
			expect(purchase(shopHarness, PLAYER, itemId)).toEqual(ACCEPTED)
			-- Only the balance and the one owned list change; every other field keeps its progress.
			expect(shopHarness.readInMemorySaveData()).toEqual(
				DanceAndCosmeticRequestTestHarness.buildExpectedSaveData(saveDataBefore, function(expectedSaveData)
					expectedSaveData.starCoinBalance = 1000 - itemPrice
					table.insert(expectedSaveData[ownedFieldName], itemId)
				end)
			)
			expectShopLoggerSilent(shopHarness)
		end)

		it("leaves the balance at exactly 0 when it equals the price", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, itemPrice, {})
			expect(purchase(shopHarness, PLAYER, itemId)).toEqual(ACCEPTED)
			expect(shopHarness.readInMemorySaveData().starCoinBalance).toBe(0)
		end)

		it("is one ledger spend: one revision, and a save is requested at once (§3.4)", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, 1000, {})
			local inMemoryRevisionBefore = shopHarness.readSaveChangeRevisions()
			local storageOperationsBefore = shopHarness.countStartedStorageOperations()
			local changeEvents = shopHarness.recordInMemorySaveDataChangedEvents()
			purchase(shopHarness, PLAYER, itemId)
			expect((shopHarness.readSaveChangeRevisions())).toBe(inMemoryRevisionBefore + 1)
			expect(#changeEvents).toBe(1)
			expect(shopHarness.countStartedStorageOperations()).toBe(storageOperationsBefore + 1)
			local ledgerInformation = shopHarness.server.ledgerLogger.loggedInformation
			local spendLogLine = ledgerInformation[#ledgerInformation]
			local expectedLogFragment = string.format(
				"purchaseKind %s: %s %s",
				purchaseRequestKind.expectedPurchaseKind,
				string.lower(purchaseRequestKind.expectedPurchaseKind),
				itemId
			)
			expect(string.find(spendLogLine, expectedLogFragment, 1, true) ~= nil).toBeTrue()
		end)

		it("equips nothing", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, 1000, {})
			local saveDataBefore = shopHarness.readInMemorySaveData()
			purchase(shopHarness, PLAYER, itemId)
			local saveDataAfter = shopHarness.readInMemorySaveData()
			expect(saveDataAfter.equippedDanceId).toBe(saveDataBefore.equippedDanceId)
			expect(saveDataAfter.equippedCosmeticIdByKind).toEqual(saveDataBefore.equippedCosmeticIdByKind)
		end)

		it("refuses InsufficientStarCoins when the balance is one below the price, changing nothing", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, itemPrice - 1, {})
			local saveDataBefore = shopHarness.readInMemorySaveData()
			local storageOperationsBefore = shopHarness.countStartedStorageOperations()
			expect(purchase(shopHarness, PLAYER, itemId)).toEqual(rejectedWith("InsufficientStarCoins"))
			expect(shopHarness.readInMemorySaveData()).toEqual(saveDataBefore)
			expect(shopHarness.countStartedStorageOperations()).toBe(storageOperationsBefore)
			expectShopLoggerSilent(shopHarness)
		end)

		it("refuses buying an owned item as AlreadyOwned, and it costs nothing (§6.2)", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, 5000, { itemId })
			local saveDataBefore = shopHarness.readInMemorySaveData()
			local inMemoryRevisionBefore = shopHarness.readSaveChangeRevisions()
			expect(purchase(shopHarness, PLAYER, itemId)).toEqual(rejectedWith("AlreadyOwned"))
			expect(shopHarness.readInMemorySaveData()).toEqual(saveDataBefore)
			expect((shopHarness.readSaveChangeRevisions())).toBe(inMemoryRevisionBefore)
			expectShopLoggerSilent(shopHarness)
		end)

		it("answers AlreadyOwned, not InsufficientStarCoins, for an owned item the player cannot afford", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, 0, { itemId })
			expect(purchase(shopHarness, PLAYER, itemId)).toEqual(rejectedWith("AlreadyOwned"))
		end)

		it("refuses an id that is in no catalog, or only in the other catalog, as unknown", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, 5000, {})
			local saveDataBefore = shopHarness.readInMemorySaveData()
			for _, unknownItemId in { "ghost_shuffle", purchaseRequestKind.idFromTheOtherCatalog } do
				shopHarness.waitPastRateLimit()
				expect(purchase(shopHarness, PLAYER, unknownItemId)).toEqual(
					rejectedWith(purchaseRequestKind.unknownItemRejectionReason)
				)
			end
			expect(shopHarness.readInMemorySaveData()).toEqual(saveDataBefore)
			expect(#shopHarness.shopLogger.loggedWarnings + #shopHarness.shopLogger.loggedInformation).toBe(0)
		end)

		it("answers SaveDataNotLoaded for a player whose save has not loaded, before looking at the id", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, 5000, {})
			expect(purchase(shopHarness, OTHER_PLAYER, itemId)).toEqual(rejectedWith("SaveDataNotLoaded"))
			expect(purchase(shopHarness, OTHER_PLAYER + 1, "ghost_shuffle")).toEqual(rejectedWith("SaveDataNotLoaded"))
			expect(#purchaseRequestKind.readAskedItemIds(shopHarness)).toBe(0)
			expectShopLoggerSilent(shopHarness)
		end)

		it("answers SaveDataNotLoaded when the ledger finds the save not loaded", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, 5000, {})
			local claimsEveryoneLoadedKeeper =
				StandInPlayerSaveDataKeeper.new(shopHarness.server.playerSaveDataKeeper, {
					isPlayerSaveDataLoaded = function()
						return true
					end,
				})
			shopHarness.rebuildAnswerersForCurrentServer({ playerSaveDataKeeper = claimsEveryoneLoadedKeeper })
			expect(purchase(shopHarness, OTHER_PLAYER, itemId)).toEqual(rejectedWith("SaveDataNotLoaded"))
		end)

		it("asks the rate limiter first, with the player and this request's channel", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, 5000, {})
			local admitEverythingRateLimiter = DanceAndCosmeticRequestTestHarness.createAdmitEverythingRateLimiter()
			shopHarness.rebuildAnswerersForCurrentServer({ playerRequestRateLimiter = admitEverythingRateLimiter })
			purchase(shopHarness, PLAYER, itemId)
			expect(admitEverythingRateLimiter.recordedCalls).toEqual({
				{
					playerUserId = PLAYER,
					remoteChannelName = RemoteNames.REMOTE_CHANNEL_NAMES[purchaseRequestKind.requestName],
				},
			})
		end)

		it("on a rate-limit refusal answers its reason and looks at nothing else", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, 5000, {})
			local refusingRateLimiter = {
				admitOrRefusePlayerRequest = function()
					return { isRequestAllowed = false, rejectionReason = "ReasonGivenByTheTestLimiter" }
				end,
			}
			local keeperQuestionCount = 0
			local countingKeeper = StandInPlayerSaveDataKeeper.new(shopHarness.server.playerSaveDataKeeper, {
				isPlayerSaveDataLoaded = function()
					keeperQuestionCount += 1
					return true
				end,
			})
			shopHarness.rebuildAnswerersForCurrentServer({
				playerRequestRateLimiter = refusingRateLimiter,
				playerSaveDataKeeper = countingKeeper,
			})
			local saveDataBefore = shopHarness.readInMemorySaveData()
			expect(purchase(shopHarness, PLAYER, itemId)).toEqual(rejectedWith("ReasonGivenByTheTestLimiter"))
			expect(keeperQuestionCount).toBe(0)
			expect(#purchaseRequestKind.readAskedItemIds(shopHarness)).toBe(0)
			expect(shopHarness.readInMemorySaveData()).toEqual(saveDataBefore)
		end)

		it("refuses a second purchase within 1 s as TooManyRequests and admits one after 1 s (§2.13)", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, 5000, {})
			expect(purchase(shopHarness, PLAYER, itemId)).toEqual(ACCEPTED)
			local saveDataAfterFirst = shopHarness.readInMemorySaveData()
			shopHarness.crashableHarness.advanceSeconds(0.999)
			expect(purchase(shopHarness, PLAYER, purchaseRequestKind.otherPurchasableItemId)).toEqual(
				rejectedWith("TooManyRequests")
			)
			expect(shopHarness.readInMemorySaveData()).toEqual(saveDataAfterFirst)
			expectShopLoggerSilent(shopHarness)
			shopHarness.crashableHarness.advanceSeconds(0.001)
			expect(purchase(shopHarness, PLAYER, purchaseRequestKind.otherPurchasableItemId)).toEqual(ACCEPTED)
		end)

		it("pays once for two purchases of the same item in the same instant (real limiter)", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, 5000, {})
			expect(purchase(shopHarness, PLAYER, itemId)).toEqual(ACCEPTED)
			expect(purchase(shopHarness, PLAYER, itemId)).toEqual(rejectedWith("TooManyRequests"))
			expect(shopHarness.readInMemorySaveData().starCoinBalance).toBe(5000 - itemPrice)
		end)

		it("pays once for two purchases of the same item in the same instant (limiter admitting both)", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, 5000, {})
			shopHarness.rebuildAnswerersForCurrentServer({
				playerRequestRateLimiter = DanceAndCosmeticRequestTestHarness.createAdmitEverythingRateLimiter(),
			})
			expect(purchase(shopHarness, PLAYER, itemId)).toEqual(ACCEPTED)
			expect(purchase(shopHarness, PLAYER, itemId)).toEqual(rejectedWith("AlreadyOwned"))
			local saveDataAfter = shopHarness.readInMemorySaveData()
			expect(saveDataAfter.starCoinBalance).toBe(5000 - itemPrice)
			local ownedCount = 0
			for _, ownedItemId in saveDataAfter[ownedFieldName] do
				if ownedItemId == itemId then
					ownedCount += 1
				end
			end
			expect(ownedCount).toBe(1)
		end)

		it("builds a fresh answer table every time", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, 5000, {})
			shopHarness.rebuildAnswerersForCurrentServer({
				playerRequestRateLimiter = DanceAndCosmeticRequestTestHarness.createAdmitEverythingRateLimiter(),
			})
			local firstAcceptedAnswer = purchase(shopHarness, PLAYER, itemId)
			firstAcceptedAnswer.isAccepted = "changed by the caller"
			local secondAcceptedAnswer = purchase(shopHarness, PLAYER, purchaseRequestKind.otherPurchasableItemId)
			expect(secondAcceptedAnswer).toEqual(ACCEPTED)
			local firstRejectedAnswer = purchase(shopHarness, PLAYER, "ghost_shuffle")
			firstRejectedAnswer.rejectionReason = "changed by the caller"
			expect(purchase(shopHarness, PLAYER, "ghost_shuffle")).toEqual(
				rejectedWith(purchaseRequestKind.unknownItemRejectionReason)
			)
			local firstAlreadyOwnedAnswer = purchase(shopHarness, PLAYER, itemId)
			firstAlreadyOwnedAnswer.rejectionReason = "changed by the caller"
			expect(purchase(shopHarness, PLAYER, itemId)).toEqual(rejectedWith("AlreadyOwned"))
			local firstNotLoadedAnswer = purchase(shopHarness, OTHER_PLAYER, itemId)
			firstNotLoadedAnswer.rejectionReason = "changed by the caller"
			expect(purchase(shopHarness, OTHER_PLAYER, itemId)).toEqual(rejectedWith("SaveDataNotLoaded"))
		end)

		it("builds a fresh table for every InsufficientStarCoins answer", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, 0, {})
			shopHarness.rebuildAnswerersForCurrentServer({
				playerRequestRateLimiter = DanceAndCosmeticRequestTestHarness.createAdmitEverythingRateLimiter(),
			})
			local firstAnswer = purchase(shopHarness, PLAYER, itemId)
			expect(firstAnswer).toEqual(rejectedWith("InsufficientStarCoins"))
			firstAnswer.isAccepted = "changed by the caller"
			firstAnswer.rejectionReason = "changed by the caller"
			expect(purchase(shopHarness, PLAYER, itemId)).toEqual(rejectedWith("InsufficientStarCoins"))
		end)

		it("builds a fresh table for every TooManyRequests answer (real limiter)", function()
			local shopHarness = createHarnessOwning(purchaseRequestKind, 5000, {})
			expect(purchase(shopHarness, PLAYER, itemId)).toEqual(ACCEPTED)
			local firstRefusal = purchase(shopHarness, PLAYER, itemId)
			expect(firstRefusal).toEqual(rejectedWith("TooManyRequests"))
			firstRefusal.isAccepted = "changed by the caller"
			firstRefusal.rejectionReason = "changed by the caller"
			expect(purchase(shopHarness, PLAYER, itemId)).toEqual(rejectedWith("TooManyRequests"))
		end)
	end)
end

describe("RequestPurchaseDanceWithStarCoins with a dance granted to new players", function()
	it("sells a free starter dance the save lacks for 0 Star Coins", function()
		local shopHarness = createShopHarness(giveBalanceAndOwnedItems(40, { "starter_wave" }))
		expect(shopHarness.purchaseRequestAnswerer:purchaseDanceWithStarCoinsAndBuildAnswer(PLAYER, "starter_step")).toEqual(
			ACCEPTED
		)
		local saveDataAfter = shopHarness.readInMemorySaveData()
		expect(saveDataAfter.starCoinBalance).toBe(40)
		expect(saveDataAfter.ownedDanceIds).toEqual({ "starter_wave", "starter_step" })
	end)

	it("refuses an owned starter dance as AlreadyOwned", function()
		local shopHarness = createShopHarness(giveStarCoinBalance(40))
		expect(shopHarness.purchaseRequestAnswerer:purchaseDanceWithStarCoinsAndBuildAnswer(PLAYER, "starter_wave")).toEqual(
			rejectedWith("AlreadyOwned")
		)
	end)
end)

describe("DanceAndCosmeticPurchaseRequestAnswerer.new", function()
	local requiredDependencyNames = {
		"playerSaveDataKeeper",
		"rewardLedger",
		"playerRequestRateLimiter",
		"danceCatalog",
		"cosmeticCatalog",
		"logger",
	}
	for _, missingDependencyName in requiredDependencyNames do
		it("raises, naming it, when " .. missingDependencyName .. " is missing", function()
			local dependencies =
				DanceAndCosmeticRequestTestHarness.buildPlaceholderDependencies(requiredDependencyNames)
			dependencies[missingDependencyName] = nil
			expect(function()
				DanceAndCosmeticPurchaseRequestAnswerer.new(dependencies)
			end).toThrow("missing dependency " .. missingDependencyName)
		end)
	end

	it("accepts a complete set of dependencies", function()
		local dependencies = DanceAndCosmeticRequestTestHarness.buildPlaceholderDependencies(requiredDependencyNames)
		expect(type(DanceAndCosmeticPurchaseRequestAnswerer.new(dependencies))).toBe("table")
	end)

	for _, catalogLookup in DanceAndCosmeticRequestTestHarness.CATALOG_LOOKUP_FUNCTION_NAMES do
		local catalogDependencyName, lookupFunctionName = catalogLookup[1], catalogLookup[2]
		it("raises when " .. catalogDependencyName .. " has no " .. lookupFunctionName .. " function", function()
			local dependencies =
				DanceAndCosmeticRequestTestHarness.buildPlaceholderDependencies(requiredDependencyNames)
			dependencies[catalogDependencyName] = { [lookupFunctionName] = "not a function" }
			expect(function()
				DanceAndCosmeticPurchaseRequestAnswerer.new(dependencies)
			end).toThrow(catalogDependencyName .. "." .. lookupFunctionName .. " must be a function")
		end)
	end

	it("lists exactly the purchase rejection reasons of §2.8 plus TooManyRequests (§2.13), frozen", function()
		local reasons = DanceAndCosmeticPurchaseRequestAnswerer.PURCHASE_REJECTION_REASONS
		expect(reasons).toEqual({
			UnknownDance = "UnknownDance",
			UnknownCosmetic = "UnknownCosmetic",
			AlreadyOwned = "AlreadyOwned",
			InsufficientStarCoins = "InsufficientStarCoins",
			SaveDataNotLoaded = "SaveDataNotLoaded",
			TooManyRequests = "TooManyRequests",
		})
		expect(table.isfrozen(reasons)).toBeTrue()
	end)
end)
