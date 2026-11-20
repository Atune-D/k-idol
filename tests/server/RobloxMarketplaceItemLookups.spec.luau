-- Unit: RobloxMarketplaceItemLookups with fake Roblox services (the engine itself was exercised in
-- Studio; see the file header). The fake services answer with the answers captured in Studio.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local CapturedRobloxMarketplaceAnswers = require("../fixtures/CapturedRobloxMarketplaceAnswers")
local RobloxMarketplaceItemLookups = require("../../src/server/RobloxMarketplaceItemLookups")
local MarketplaceStylingItemResolver = require("../../src/server/MarketplaceStylingItemResolver")
local StylingItemLookup = require("../../src/shared/StylingItemLookup")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local ASSET_AVATAR_ITEM_TYPE = "AvatarItemType.Asset (fake enum)"
local BUNDLE_AVATAR_ITEM_TYPE = "AvatarItemType.Bundle (fake enum)"
local HAIR_ASSET_ID = 7259123616
local SHOES_BUNDLE_ID = 98186475028072
local PLAYER_USER_ID = 2421377719

-- Fake services answering from the captured engine answers. `engineCalls` records every call;
-- `raisingMethodNames[name] = message` makes that method raise instead.
local function createFakeRobloxServices()
	local fakeRobloxServices = { engineCalls = {}, raisingMethodNames = {}, ownedItemIds = {} }
	local fakePlayer = { UserId = PLAYER_USER_ID }
	local function recordEngineCall(methodName: string, ...)
		table.insert(fakeRobloxServices.engineCalls, { methodName = methodName, arguments = { ... } })
		local raisedMessage = fakeRobloxServices.raisingMethodNames[methodName]
		if raisedMessage then
			error(raisedMessage, 0)
		end
	end
	local avatarItemKindByEnum = { [ASSET_AVATAR_ITEM_TYPE] = "Asset", [BUNDLE_AVATAR_ITEM_TYPE] = "Bundle" }
	fakeRobloxServices.avatarEditorService = {
		GetItemDetailsAsync = function(_, itemId, avatarItemType)
			recordEngineCall("GetItemDetailsAsync", itemId, avatarItemType)
			local capturedAnswer =
				CapturedRobloxMarketplaceAnswers.AVATAR_ITEM_DETAILS_BY_KIND_AND_ID[avatarItemKindByEnum[avatarItemType]][itemId]
			if capturedAnswer == nil then
				error(CapturedRobloxMarketplaceAnswers.ITEM_DETAILS_HTTP_400_ERROR_MESSAGE, 0)
			end
			return CapturedRobloxMarketplaceAnswers.copyAnswer(capturedAnswer)
		end,
	}
	fakeRobloxServices.assetService = {
		GetBundleDetailsAsync = function(_, bundleId)
			recordEngineCall("GetBundleDetailsAsync", bundleId)
			local capturedAnswer = CapturedRobloxMarketplaceAnswers.BUNDLE_DETAILS_BY_BUNDLE_ID[bundleId]
			-- An unknown bundle answers something that is not a dictionary (a malformed answer).
			return if capturedAnswer then CapturedRobloxMarketplaceAnswers.copyAnswer(capturedAnswer) else "unexpected"
		end,
	}
	fakeRobloxServices.marketplaceService = {
		PlayerOwnsAssetAsync = function(_, player, assetId)
			recordEngineCall("PlayerOwnsAssetAsync", player, assetId)
			return fakeRobloxServices.ownedItemIds[assetId] or false
		end,
		PlayerOwnsBundleAsync = function(_, player, bundleId)
			recordEngineCall("PlayerOwnsBundleAsync", player, bundleId)
			return fakeRobloxServices.ownedItemIds[bundleId] or false
		end,
	}
	fakeRobloxServices.playersService = {
		GetPlayerByUserId = function(_, userId)
			return if userId == PLAYER_USER_ID then fakePlayer else nil
		end,
	}
	fakeRobloxServices.fakePlayer = fakePlayer
	return fakeRobloxServices
end

-- Lookups whose threads only run when the test calls runStartedThreads(), so a test can see
-- that a method returned before answering.
local function createLookupsWithHeldThreads(fakeRobloxServices)
	local heldThreadBodies = {}
	local marketplaceItemLookups = RobloxMarketplaceItemLookups.new({
		avatarEditorService = fakeRobloxServices.avatarEditorService,
		assetService = fakeRobloxServices.assetService,
		marketplaceService = fakeRobloxServices.marketplaceService,
		playersService = fakeRobloxServices.playersService,
		avatarItemTypeByMarketplaceItemKind = { Asset = ASSET_AVATAR_ITEM_TYPE, Bundle = BUNDLE_AVATAR_ITEM_TYPE },
		startThread = function(threadBody)
			table.insert(heldThreadBodies, threadBody)
		end,
	})
	local function runStartedThreads()
		while #heldThreadBodies > 0 do
			local threadBody = table.remove(heldThreadBodies, 1)
			-- A raising callback ends its own thread, as in Roblox; the thread error is collected.
			local didThreadFinish, threadError = pcall(threadBody)
			if not didThreadFinish then
				table.insert(fakeRobloxServices.threadErrors, threadError)
			end
		end
	end
	fakeRobloxServices.threadErrors = {}
	return marketplaceItemLookups, runStartedThreads
end

local function createCallbackRecorder()
	local callbackRecorder = { calls = {} }
	function callbackRecorder.callback(...)
		table.insert(callbackRecorder.calls, table.pack(...))
	end
	return callbackRecorder
end

describe("RobloxMarketplaceItemLookups item details", function()
	it("returns before the engine is asked, then calls back once with the converted details", function()
		local fakeRobloxServices = createFakeRobloxServices()
		local marketplaceItemLookups, runStartedThreads = createLookupsWithHeldThreads(fakeRobloxServices)
		local callbackRecorder = createCallbackRecorder()
		marketplaceItemLookups:startLookingUpMarketplaceItemDetails("Asset", HAIR_ASSET_ID, callbackRecorder.callback)
		expect(#fakeRobloxServices.engineCalls).toBe(0)
		expect(#callbackRecorder.calls).toBe(0)
		runStartedThreads()
		expect(fakeRobloxServices.engineCalls).toEqual({
			{ methodName = "GetItemDetailsAsync", arguments = { HAIR_ASSET_ID, ASSET_AVATAR_ITEM_TYPE } },
		})
		expect(#callbackRecorder.calls).toBe(1)
		expect(callbackRecorder.calls[1][1]).toBeTrue()
		expect(callbackRecorder.calls[1][2]).toEqual({
			itemDisplayName = "Black Messy Hairstyle",
			priceInRobux = 65,
			isOnSale = true,
			canBeSoldInThisGame = true,
			robloxAssetTypeName = "HairAccessory",
		})
		expect(callbackRecorder.calls[1][3]).toBeNil()
	end)

	it("asks for a bundle with the Bundle avatar item type", function()
		local fakeRobloxServices = createFakeRobloxServices()
		local marketplaceItemLookups, runStartedThreads = createLookupsWithHeldThreads(fakeRobloxServices)
		local callbackRecorder = createCallbackRecorder()
		marketplaceItemLookups:startLookingUpMarketplaceItemDetails(
			"Bundle",
			SHOES_BUNDLE_ID,
			callbackRecorder.callback
		)
		runStartedThreads()
		expect(fakeRobloxServices.engineCalls[1].arguments).toEqual({ SHOES_BUNDLE_ID, BUNDLE_AVATAR_ITEM_TYPE })
		expect(callbackRecorder.calls[1][2].itemDisplayName).toBe("Y2K Fur Boots")
	end)

	it("reports an engine error as a failure naming the lookup, without raising", function()
		local fakeRobloxServices = createFakeRobloxServices()
		local marketplaceItemLookups, runStartedThreads = createLookupsWithHeldThreads(fakeRobloxServices)
		local callbackRecorder = createCallbackRecorder()
		marketplaceItemLookups:startLookingUpMarketplaceItemDetails("Asset", 1, callbackRecorder.callback)
		runStartedThreads()
		expect(#callbackRecorder.calls).toBe(1)
		expect(callbackRecorder.calls[1][1]).toBeFalse()
		expect(callbackRecorder.calls[1][2]).toBeNil()
		expect(callbackRecorder.calls[1][3]).toBe(
			"item details of Asset 1: Roblox raised: "
				.. CapturedRobloxMarketplaceAnswers.ITEM_DETAILS_HTTP_400_ERROR_MESSAGE
		)
	end)

	it("reports an answer the converter rejects as a failure carrying the problem", function()
		local fakeRobloxServices = createFakeRobloxServices()
		fakeRobloxServices.avatarEditorService.GetItemDetailsAsync = function()
			return {
				Id = HAIR_ASSET_ID,
				ItemType = "Asset",
				Name = "x",
				Price = 1,
				SaleLocationType = "ShopAndAllExperiences",
			}
		end
		local marketplaceItemLookups, runStartedThreads = createLookupsWithHeldThreads(fakeRobloxServices)
		local callbackRecorder = createCallbackRecorder()
		marketplaceItemLookups:startLookingUpMarketplaceItemDetails("Asset", HAIR_ASSET_ID, callbackRecorder.callback)
		runStartedThreads()
		expect(callbackRecorder.calls[1][1]).toBeFalse()
		expect(callbackRecorder.calls[1][3]).toBe("item details of Asset 7259123616: IsPurchasable is not a boolean")
	end)

	it("reports an unknown kind as a failure without asking the engine", function()
		local fakeRobloxServices = createFakeRobloxServices()
		local marketplaceItemLookups, runStartedThreads = createLookupsWithHeldThreads(fakeRobloxServices)
		local callbackRecorder = createCallbackRecorder()
		marketplaceItemLookups:startLookingUpMarketplaceItemDetails("GamePass", 5, callbackRecorder.callback)
		runStartedThreads()
		expect(#fakeRobloxServices.engineCalls).toBe(0)
		expect(callbackRecorder.calls[1][1]).toBeFalse()
		expect(callbackRecorder.calls[1][3]).toBe("item details of GamePass 5: unknown marketplaceItemKind")
	end)

	it("calls a callback that raises only once", function()
		local fakeRobloxServices = createFakeRobloxServices()
		local marketplaceItemLookups, runStartedThreads = createLookupsWithHeldThreads(fakeRobloxServices)
		local callbackCount = 0
		marketplaceItemLookups:startLookingUpMarketplaceItemDetails("Asset", HAIR_ASSET_ID, function()
			callbackCount += 1
			error("listener bug")
		end)
		runStartedThreads()
		expect(callbackCount).toBe(1)
		expect(#fakeRobloxServices.threadErrors).toBe(1)
	end)
end)

describe("RobloxMarketplaceItemLookups bundle contents", function()
	it("calls back once with the converted entries, saved outfit marked not wearable", function()
		local fakeRobloxServices = createFakeRobloxServices()
		local marketplaceItemLookups, runStartedThreads = createLookupsWithHeldThreads(fakeRobloxServices)
		local callbackRecorder = createCallbackRecorder()
		marketplaceItemLookups:startLookingUpBundleContents(SHOES_BUNDLE_ID, callbackRecorder.callback)
		expect(#callbackRecorder.calls).toBe(0)
		runStartedThreads()
		expect(fakeRobloxServices.engineCalls).toEqual({
			{ methodName = "GetBundleDetailsAsync", arguments = { SHOES_BUNDLE_ID } },
		})
		expect(#callbackRecorder.calls).toBe(1)
		expect(callbackRecorder.calls[1][1]).toBeTrue()
		expect(callbackRecorder.calls[1][2]).toEqual({
			{ isWearableAsset = true, wornAssetId = 84885203198436, robloxAssetTypeName = "LeftShoeAccessory" },
			{ isWearableAsset = true, wornAssetId = 90774383444285, robloxAssetTypeName = "RightShoeAccessory" },
			{ isWearableAsset = false },
		})
	end)

	it("reports an engine error and a rejected answer as failures", function()
		local fakeRobloxServices = createFakeRobloxServices()
		fakeRobloxServices.raisingMethodNames.GetBundleDetailsAsync = "HTTP 400 (Bad Request)"
		local marketplaceItemLookups, runStartedThreads = createLookupsWithHeldThreads(fakeRobloxServices)
		local callbackRecorder = createCallbackRecorder()
		marketplaceItemLookups:startLookingUpBundleContents(SHOES_BUNDLE_ID, callbackRecorder.callback)
		runStartedThreads()
		expect(callbackRecorder.calls[1][1]).toBeFalse()
		expect(callbackRecorder.calls[1][3]).toBe(
			"contents of bundle 98186475028072: Roblox raised: HTTP 400 (Bad Request)"
		)

		fakeRobloxServices.raisingMethodNames.GetBundleDetailsAsync = nil
		marketplaceItemLookups:startLookingUpBundleContents(12345, callbackRecorder.callback)
		runStartedThreads()
		expect(callbackRecorder.calls[2][1]).toBeFalse()
		expect(callbackRecorder.calls[2][3]).toBe("contents of bundle 12345: the bundle details answer is not a table")
	end)
end)

describe("RobloxMarketplaceItemLookups ownership checks", function()
	it(
		"checks an asset with PlayerOwnsAssetAsync and a bundle with PlayerOwnsBundleAsync for the player instance",
		function()
			local fakeRobloxServices = createFakeRobloxServices()
			fakeRobloxServices.ownedItemIds[SHOES_BUNDLE_ID] = true
			local marketplaceItemLookups, runStartedThreads = createLookupsWithHeldThreads(fakeRobloxServices)
			local callbackRecorder = createCallbackRecorder()
			marketplaceItemLookups:startCheckingPlayerOwnsMarketplaceItem(
				PLAYER_USER_ID,
				"Asset",
				HAIR_ASSET_ID,
				callbackRecorder.callback
			)
			marketplaceItemLookups:startCheckingPlayerOwnsMarketplaceItem(
				PLAYER_USER_ID,
				"Bundle",
				SHOES_BUNDLE_ID,
				callbackRecorder.callback
			)
			expect(#callbackRecorder.calls).toBe(0)
			runStartedThreads()
			expect(fakeRobloxServices.engineCalls).toEqual({
				{ methodName = "PlayerOwnsAssetAsync", arguments = { fakeRobloxServices.fakePlayer, HAIR_ASSET_ID } },
				{
					methodName = "PlayerOwnsBundleAsync",
					arguments = { fakeRobloxServices.fakePlayer, SHOES_BUNDLE_ID },
				},
			})
			expect({ callbackRecorder.calls[1][1], callbackRecorder.calls[1][2], callbackRecorder.calls[1][3] }).toEqual({
				true,
				false,
			})
			expect({ callbackRecorder.calls[2][1], callbackRecorder.calls[2][2] }).toEqual({ true, true })
		end
	)

	it("fails without asking the engine for a player not in this server or an unknown kind", function()
		local fakeRobloxServices = createFakeRobloxServices()
		local marketplaceItemLookups, runStartedThreads = createLookupsWithHeldThreads(fakeRobloxServices)
		local callbackRecorder = createCallbackRecorder()
		marketplaceItemLookups:startCheckingPlayerOwnsMarketplaceItem(
			1,
			"Asset",
			HAIR_ASSET_ID,
			callbackRecorder.callback
		)
		marketplaceItemLookups:startCheckingPlayerOwnsMarketplaceItem(
			PLAYER_USER_ID,
			"Pass",
			5,
			callbackRecorder.callback
		)
		runStartedThreads()
		expect(#fakeRobloxServices.engineCalls).toBe(0)
		expect(callbackRecorder.calls[1][1]).toBeFalse()
		expect(callbackRecorder.calls[1][3]).toBe(
			"ownership of Asset 7259123616 by user 1: the player is not in this server"
		)
		expect(callbackRecorder.calls[2][3]).toBe("ownership of Pass 5 by user 2421377719: unknown marketplaceItemKind")
	end)

	it("fails when the engine raises or answers something other than a boolean", function()
		local fakeRobloxServices = createFakeRobloxServices()
		fakeRobloxServices.raisingMethodNames.PlayerOwnsAssetAsync = "inventory unavailable"
		fakeRobloxServices.marketplaceService.PlayerOwnsBundleAsync = function()
			return nil
		end
		local marketplaceItemLookups, runStartedThreads = createLookupsWithHeldThreads(fakeRobloxServices)
		local callbackRecorder = createCallbackRecorder()
		marketplaceItemLookups:startCheckingPlayerOwnsMarketplaceItem(
			PLAYER_USER_ID,
			"Asset",
			HAIR_ASSET_ID,
			callbackRecorder.callback
		)
		marketplaceItemLookups:startCheckingPlayerOwnsMarketplaceItem(
			PLAYER_USER_ID,
			"Bundle",
			SHOES_BUNDLE_ID,
			callbackRecorder.callback
		)
		runStartedThreads()
		expect(callbackRecorder.calls[1][1]).toBeFalse()
		expect(callbackRecorder.calls[1][3]).toBe(
			"ownership of Asset 7259123616 by user 2421377719: Roblox raised: inventory unavailable"
		)
		expect(callbackRecorder.calls[2][1]).toBeFalse()
		expect(callbackRecorder.calls[2][3]).toBe(
			"ownership of Bundle 98186475028072 by user 2421377719: Roblox did not answer a boolean"
		)
	end)
end)

-- The seven development-sample items (independent of data/styling-item-pool.csv, which the owner
-- will replace); slots follow the items, tags are irrelevant here.
local function buildStylingItemsForCapturedAnswers()
	local stylingItems = {}
	for _, kindIdSlot in
		{
			{ "Asset", 7259123616, "hair" },
			{ "Asset", 9122110415, "top" },
			{ "Asset", 9438759973, "dress" },
			{ "Asset", 4378579302, "accessory" },
			{ "Asset", 11884330, "accessory" },
			{ "Bundle", 98186475028072, "shoes" },
			{ "Asset", 106390919006817, "makeup_lips" },
		}
	do
		table.insert(stylingItems, {
			stylingItemKey = StylingItemLookup.deriveStylingItemKey(kindIdSlot[1], kindIdSlot[2]),
			marketplaceItemKind = kindIdSlot[1],
			marketplaceItemId = kindIdSlot[2],
			itemSlot = kindIdSlot[3],
			styleTags = { "cute" },
			primaryColorTag = "black",
			isEnabled = true,
		})
	end
	return stylingItems
end

describe("RobloxMarketplaceItemLookups with the real MarketplaceStylingItemResolver", function()
	it("makes all seven development-sample items available, as Studio showed", function()
		local fakeRobloxServices = createFakeRobloxServices()
		local marketplaceItemLookups, runStartedThreads = createLookupsWithHeldThreads(fakeRobloxServices)
		local fakeScheduler = FakeScheduler.new(FakeClock.new(0))
		local loggedWarnings = {}
		local resolver = MarketplaceStylingItemResolver.new({
			stylingItems = buildStylingItemsForCapturedAnswers(),
			marketplaceItemLookups = marketplaceItemLookups,
			scheduler = fakeScheduler,
			logger = {
				logInformation = function() end,
				logWarning = function(_, message)
					table.insert(loggedWarnings, message)
				end,
			},
		})
		resolver:startResolvingWardrobeCatalog()
		runStartedThreads() -- item details
		runStartedThreads() -- bundle contents, started by the shoes' details answer
		expect(resolver:isWardrobeCatalogReady()).toBeTrue()
		expect(loggedWarnings).toEqual({})
		local wardrobeItemSummaries = {}
		for _, wardrobeItem in resolver:readWardrobeCatalogSnapshotAnswer().wardrobeItems do
			table.insert(
				wardrobeItemSummaries,
				{ wardrobeItem.stylingItemKey, wardrobeItem.priceInRobux, #wardrobeItem.wornAssets }
			)
		end
		expect(wardrobeItemSummaries).toEqual({
			{ "asset_7259123616", 65, 1 },
			{ "asset_9122110415", 70, 1 },
			{ "asset_9438759973", 120, 1 },
			{ "asset_4378579302", 55, 1 },
			{ "asset_11884330", 95, 1 },
			{ "bundle_98186475028072", 60, 2 },
			{ "asset_106390919006817", 30, 1 },
		})
	end)
end)
