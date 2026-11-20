-- The wardrobe's Buy action (§2.12): when ownership is asked (§2.14, §2.13), what the Buy panel shows,
-- and the decision that the purchase prompt can NEVER open while running in Roblox Studio.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local DeviceTestFixtures = require("./DeviceTestFixtures")
local LobbyTestFixtures = require("./LobbyTestFixtures")
local MarketplacePurchasePromptPermission = require("../../src/client/MarketplacePurchasePromptPermission")
local StylingItemOwnershipRequester = require("../../src/client/StylingItemOwnershipRequester")
local StylingItemPurchasePanelModelBuilder = require("../../src/client/StylingItemPurchasePanelModelBuilder")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local F = DeviceTestFixtures
local REFUSALS = MarketplacePurchasePromptPermission.REFUSAL_REASONS

describe("MarketplacePurchasePromptPermission", function()
	local decide = MarketplacePurchasePromptPermission.decidePurchasePromptPermission

	it("never allows the prompt while running in Studio, or when that fact is missing or not false", function()
		for _, studioFact in { true, "false", 0, 1 } do
			for _, kind in { "Asset", "Bundle", "Other" } do
				for _, ownershipStatus in { "NotOwned", "Owned", "Checking", "CheckFailed", "UnknownItem", "Refused" } do
					local decision = decide({
						isRunningInStudio = studioFact,
						marketplaceItemKind = kind,
						marketplaceItemId = 123,
						ownershipStatus = ownershipStatus,
					})
					expect(decision.mayOpenPurchasePrompt).toBe(false)
					expect(decision.refusalReason).toBe(REFUSALS.RunningInStudio)
				end
			end
		end
		local missingFact =
			decide({ marketplaceItemKind = "Asset", marketplaceItemId = 123, ownershipStatus = "NotOwned" })
		expect(missingFact.refusalReason).toBe(REFUSALS.RunningInStudio)
		expect(decide(nil).refusalReason).toBe(REFUSALS.RunningInStudio)
	end)

	it("outside Studio, allows the asset prompt for an Asset and the bundle prompt for a Bundle not owned", function()
		for _, kind in { "Asset", "Bundle" } do
			local decision = decide({
				isRunningInStudio = false,
				marketplaceItemKind = kind,
				marketplaceItemId = 98186475028072,
				ownershipStatus = "NotOwned",
			})
			expect(decision.mayOpenPurchasePrompt).toBe(true)
			expect(decision.purchasePromptKind).toBe(kind)
		end
	end)

	it("outside Studio, refuses any other kind, a bad id, and every ownership other than NotOwned", function()
		local function decideOutsideStudio(kind, itemId, ownershipStatus)
			return decide({
				isRunningInStudio = false,
				marketplaceItemKind = kind,
				marketplaceItemId = itemId,
				ownershipStatus = ownershipStatus,
			})
		end
		expect(decideOutsideStudio("GamePass", 5, "NotOwned").refusalReason).toBe(REFUSALS.UnknownMarketplaceItemKind)
		expect(decideOutsideStudio(nil, 5, "NotOwned").refusalReason).toBe(REFUSALS.UnknownMarketplaceItemKind)
		for _, badId in { 0, -3, 1.5, 0 / 0, math.huge, "5", nil } do
			expect(decideOutsideStudio("Asset", badId, "NotOwned").refusalReason).toBe(
				REFUSALS.InvalidMarketplaceItemId
			)
		end
		for _, ownershipStatus in { "Owned", "Checking", "CheckFailed", "UnknownItem", "Refused", nil } do
			expect(decideOutsideStudio("Bundle", 5, ownershipStatus).refusalReason).toBe(REFUSALS.NotKnownToBeUnowned)
		end
	end)
end)

local function createRequester()
	local fakeClock = FakeClock.new(LobbyTestFixtures.START_UNIX_SECONDS)
	local fakeScheduler = FakeScheduler.new(fakeClock)
	local fixture = { askedKeys = {}, askTimes = {}, pendingAnswers = {} }
	fixture.requester = StylingItemOwnershipRequester.new({
		clock = fakeClock,
		scheduler = fakeScheduler,
		requestStylingItemOwnership = function(stylingItemKey, onAnswer)
			table.insert(fixture.askedKeys, stylingItemKey)
			table.insert(
				fixture.askTimes,
				fakeClock:getCurrentUnixMilliseconds() - LobbyTestFixtures.START_UNIX_SECONDS * 1000
			)
			table.insert(fixture.pendingAnswers, onAnswer)
		end,
	})
	function fixture.advance(seconds)
		fakeScheduler:advanceTimeAndRunDueCallbacks(seconds)
	end
	function fixture.answer(answer)
		table.remove(fixture.pendingAnswers, 1)(answer)
	end
	return fixture
end

local SELECTED_HAIR = { isSelectionChanged = true, outfitStylingItemKeys = { F.HAIR } }

describe("StylingItemOwnershipRequester", function()
	it("asks when an item is selected, and reads Owned / NotOwned from the answer", function()
		local fixture = createRequester()
		fixture.requester:noteWardrobeTap(F.HAIR, SELECTED_HAIR)
		expect(fixture.askedKeys).toEqual({ F.HAIR })
		expect(fixture.requester:readFocusedOwnership().ownershipStatus).toBe("Checking")
		fixture.answer({ isAccepted = true, isOwnedByPlayer = false })
		expect(fixture.requester:readFocusedOwnership().ownershipStatus).toBe("NotOwned")
		fixture.advance(0.5)
		fixture.requester:noteWardrobeTap(
			F.GLASSES,
			{ isSelectionChanged = true, outfitStylingItemKeys = { F.GLASSES } }
		)
		fixture.answer({ isAccepted = true, isOwnedByPlayer = true })
		expect(fixture.requester:readFocusedOwnership()).toEqual({
			stylingItemKey = F.GLASSES,
			ownershipStatus = "Owned",
		})
	end)

	it("asks nothing for a tap that takes the item off or is refused, and clears the focus it had", function()
		local fixture = createRequester()
		fixture.requester:noteWardrobeTap(F.HAIR, SELECTED_HAIR)
		fixture.answer({ isAccepted = true, isOwnedByPlayer = false })
		fixture.advance(1)
		fixture.requester:noteWardrobeTap(F.HAIR, { isSelectionChanged = true, outfitStylingItemKeys = {} })
		expect(fixture.requester:readFocusedOwnership()).toBeNil()
		fixture.requester:noteWardrobeTap(F.GLASSES, { isSelectionChanged = false, outfitStylingItemKeys = {} })
		fixture.requester:noteWardrobeTap(F.GLASSES, nil)
		expect(#fixture.askedKeys).toBe(1)
	end)

	it("keeps 0.5 s after the previous answer, one in flight, and asks only the latest focus", function()
		local fixture = createRequester()
		fixture.requester:focusStylingItem(F.HAIR)
		fixture.requester:focusStylingItem(F.GLASSES)
		fixture.requester:focusStylingItem(F.DRESS)
		expect(fixture.askedKeys).toEqual({ F.HAIR })
		fixture.advance(0.2)
		fixture.answer({ isAccepted = true, isOwnedByPlayer = true }) -- for HAIR, no longer focused: dropped
		expect(fixture.requester:readFocusedOwnership().ownershipStatus).toBe("Checking")
		fixture.advance(0.499)
		expect(#fixture.askedKeys).toBe(1)
		fixture.advance(0.001)
		expect(fixture.askedKeys).toEqual({ F.HAIR, F.DRESS })
		expect(fixture.askTimes).toEqual({ 0, 700 })
		expect(fixture.requester:readSentRequestCount()).toBe(2)
	end)

	it("asks again after a purchase prompt closes, for the focused item only", function()
		local fixture = createRequester()
		fixture.requester:focusStylingItem(F.SHOES_BUNDLE)
		fixture.answer({ isAccepted = true, isOwnedByPlayer = false })
		fixture.requester:askAgainAfterPurchasePromptClosed(F.HAIR)
		fixture.advance(1)
		expect(#fixture.askedKeys).toBe(1)
		fixture.requester:askAgainAfterPurchasePromptClosed(F.SHOES_BUNDLE)
		expect(fixture.askedKeys).toEqual({ F.SHOES_BUNDLE, F.SHOES_BUNDLE })
		fixture.answer({ isAccepted = true, isOwnedByPlayer = true })
		expect(fixture.requester:readFocusedOwnership().ownershipStatus).toBe("Owned")
	end)

	it("reads failures: CheckFailed, UnknownItem, no answer; retries TooManyRequests at most 3 times", function()
		local fixture = createRequester()
		fixture.requester:focusStylingItem(F.HAIR)
		fixture.answer({ isAccepted = false, rejectionReason = "OwnershipCheckFailed" })
		expect(fixture.requester:readFocusedOwnership()).toEqual({
			stylingItemKey = F.HAIR,
			ownershipStatus = "CheckFailed",
			rejectionReason = "OwnershipCheckFailed",
		})
		fixture.advance(1)
		fixture.requester:focusStylingItem(F.HAIR)
		fixture.answer({ isAccepted = false, rejectionReason = "UnknownStylingItem" })
		expect(fixture.requester:readFocusedOwnership().ownershipStatus).toBe("UnknownItem")
		fixture.advance(1)
		fixture.requester:focusStylingItem(F.HAIR)
		fixture.answer(nil)
		expect(fixture.requester:readFocusedOwnership().ownershipStatus).toBe("CheckFailed")
		fixture.advance(1)
		fixture.requester:focusStylingItem(F.HAIR)
		local countBefore = #fixture.askedKeys
		for _ = 1, 4 do
			fixture.answer({ isAccepted = false, rejectionReason = "TooManyRequests" })
			fixture.advance(0.5)
		end
		expect(#fixture.askedKeys - countBefore).toBe(3)
		expect(fixture.requester:readFocusedOwnership().ownershipStatus).toBe("Refused")
	end)
end)

local function buildPanel(focusedOwnership, overrides)
	local purchaseInputs = {
		focusedOwnership = focusedOwnership,
		shownOutfitStylingItemKeys = { F.HAIR, F.SHOES_BUNDLE },
		wardrobeCatalogView = F.buildDevelopmentWardrobeCatalogView(),
		stylingItemByStylingItemKey = F.STYLING_ITEM_BY_STYLING_ITEM_KEY,
		isRunningInStudio = true,
	}
	for fieldName, fieldValue in overrides or {} do
		purchaseInputs[fieldName] = fieldValue
	end
	return StylingItemPurchasePanelModelBuilder.buildStylingItemPurchasePanelModel(purchaseInputs)
end

describe("StylingItemPurchasePanelModelBuilder", function()
	it("in Studio, shows the price for an item not owned and explains that buying is switched off", function()
		local panel = buildPanel({ stylingItemKey = F.HAIR, ownershipStatus = "NotOwned" })
		local wardrobeItem = F.buildDevelopmentWardrobeCatalogView().wardrobeItemByStylingItemKey[F.HAIR]
		expect(panel.isVisible).toBe(true)
		expect(panel.itemNameText).toBe(wardrobeItem.itemDisplayName)
		expect(panel.isBuyButtonVisible).toBe(true)
		expect(panel.buyButtonText).toBe(string.format("Buy for %d Robux", wardrobeItem.priceInRobux))
		expect(panel.explanationText).toBe(StylingItemPurchasePanelModelBuilder.STUDIO_PURCHASE_SWITCHED_OFF_TEXT)
		expect(panel.purchasePromptPermission.mayOpenPurchasePrompt).toBe(false)
	end)

	it("outside Studio, carries the asset or bundle prompt decision and no Studio explanation", function()
		local bundle = buildPanel(
			{ stylingItemKey = F.SHOES_BUNDLE, ownershipStatus = "NotOwned" },
			{ isRunningInStudio = false }
		)
		expect(bundle.purchasePromptPermission.purchasePromptKind).toBe("Bundle")
		expect(bundle.explanationText).toBe("")
		local asset = buildPanel(
			{ stylingItemKey = F.HAIR, ownershipStatus = "NotOwned" },
			{ isRunningInStudio = false }
		)
		expect(asset.purchasePromptPermission.purchasePromptKind).toBe("Asset")
	end)

	it("shows Owned, Checking and a failed check without any Buy action", function()
		local owned = buildPanel({ stylingItemKey = F.HAIR, ownershipStatus = "Owned" })
		expect(owned.ownershipText).toBe("You own this item.")
		expect(owned.isBuyButtonVisible).toBe(false)
		expect(buildPanel({ stylingItemKey = F.HAIR, ownershipStatus = "Checking" }).isBuyButtonVisible).toBe(false)
		local failed = buildPanel({
			stylingItemKey = F.HAIR,
			ownershipStatus = "CheckFailed",
			rejectionReason = "OwnershipCheckFailed",
		})
		expect(failed.isBuyButtonVisible).toBe(false)
		expect(failed.ownershipText).toBe("Roblox couldn't tell us right now whether you own this item.")
	end)

	it("is hidden without a focus, when the focus is not in the shown outfit, or without a wardrobe", function()
		expect(buildPanel(nil).isVisible).toBe(false)
		expect(buildPanel({ stylingItemKey = F.DRESS, ownershipStatus = "NotOwned" }).isVisible).toBe(false)
		local withoutWardrobe = StylingItemPurchasePanelModelBuilder.buildStylingItemPurchasePanelModel({
			focusedOwnership = { stylingItemKey = F.HAIR, ownershipStatus = "NotOwned" },
			shownOutfitStylingItemKeys = nil,
			wardrobeCatalogView = F.buildDevelopmentWardrobeCatalogView(),
			stylingItemByStylingItemKey = F.STYLING_ITEM_BY_STYLING_ITEM_KEY,
			isRunningInStudio = true,
		})
		expect(withoutWardrobe.isVisible).toBe(false)
	end)
end)
