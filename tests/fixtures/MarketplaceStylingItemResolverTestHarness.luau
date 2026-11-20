-- Builds a MarketplaceStylingItemResolver wired to fakes (FakeClock, FakeScheduler,
-- FakeMarketplaceItemLookups) and records what it tells the outside world: log lines and every
-- WardrobeCatalogChanged message. Not a spec file; the resolver spec files require it.

local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local FakeMarketplaceItemLookups = require("../Support/FakeMarketplaceItemLookups")
local FakeStylingItemPool = require("./FakeStylingItemPool")
local StylingItemLookup = require("../../src/shared/StylingItemLookup")
local MarketplaceStylingItemResolver = require("../../src/server/MarketplaceStylingItemResolver")

local MarketplaceStylingItemResolverTestHarness = {}

MarketplaceStylingItemResolverTestHarness.EXAMPLE_STARTING_UNIX_SECONDS = 1_763_510_400
MarketplaceStylingItemResolverTestHarness.EXAMPLE_PLAYER_USER_ID = 8801
MarketplaceStylingItemResolverTestHarness.OTHER_PLAYER_USER_ID = 8802

-- Long enough for every retry of every lookup (2 + 4 + 8 seconds, twice for a bundle).
MarketplaceStylingItemResolverTestHarness.SECONDS_AFTER_WHICH_EVERY_RETRY_HAS_RUN = 60

-- `stylingItems` defaults to the fake pool. The resolver is created but NOT started, so a test
-- can script answers first and then call `harness.marketplaceStylingItemResolver:startResolvingWardrobeCatalog()`.
function MarketplaceStylingItemResolverTestHarness.createResolverWithFakes(stylingItems: { any }?)
	local fakeClock = FakeClock.new(MarketplaceStylingItemResolverTestHarness.EXAMPLE_STARTING_UNIX_SECONDS)
	local fakeScheduler = FakeScheduler.new(fakeClock)
	local fakeMarketplaceItemLookups = FakeMarketplaceItemLookups.new()
	local loggedWarnings = {}
	local loggedInformation = {}
	local receivedWardrobeCatalogChangedMessages = {}

	local recordingLogger = {}
	function recordingLogger.logInformation(_, message: string)
		table.insert(loggedInformation, message)
	end
	function recordingLogger.logWarning(_, message: string)
		table.insert(loggedWarnings, message)
	end

	local marketplaceStylingItemResolver = MarketplaceStylingItemResolver.new({
		stylingItems = stylingItems or FakeStylingItemPool.FAKE_STYLING_ITEMS,
		marketplaceItemLookups = fakeMarketplaceItemLookups,
		scheduler = fakeScheduler,
		logger = recordingLogger,
	})
	marketplaceStylingItemResolver:subscribeToWardrobeCatalogChanged(function(wardrobeCatalogChangedMessage)
		table.insert(receivedWardrobeCatalogChangedMessages, wardrobeCatalogChangedMessage)
	end)

	local harness = {
		fakeClock = fakeClock,
		fakeScheduler = fakeScheduler,
		fakeMarketplaceItemLookups = fakeMarketplaceItemLookups,
		marketplaceStylingItemResolver = marketplaceStylingItemResolver,
		loggedWarnings = loggedWarnings,
		loggedInformation = loggedInformation,
		receivedWardrobeCatalogChangedMessages = receivedWardrobeCatalogChangedMessages,
	}

	function harness.advanceSeconds(elapsedSeconds: number)
		fakeScheduler:advanceTimeAndRunDueCallbacks(elapsedSeconds)
	end

	function harness.startAndRunEveryRetry()
		marketplaceStylingItemResolver:startResolvingWardrobeCatalog()
		harness.advanceSeconds(MarketplaceStylingItemResolverTestHarness.SECONDS_AFTER_WHICH_EVERY_RETRY_HAS_RUN)
	end

	-- The ownership answer, which the fake delivers inside the start call unless answers are held.
	function harness.askOwnership(playerUserId: number, untrustedStylingItemKey: any)
		local receivedOwnershipAnswers = {}
		marketplaceStylingItemResolver:startAnsweringStylingItemOwnershipRequest(
			playerUserId,
			untrustedStylingItemKey,
			function(ownershipAnswer)
				table.insert(receivedOwnershipAnswers, ownershipAnswer)
			end
		)
		return receivedOwnershipAnswers
	end

	function harness.countLoggedWarningsMentioning(textFragment: string): number
		local matchingWarningCount = 0
		for _, loggedWarning in loggedWarnings do
			if string.find(loggedWarning, textFragment, 1, true) then
				matchingWarningCount += 1
			end
		end
		return matchingWarningCount
	end

	return harness
end

-- A frozen styling item in the shape of the generated pool, for small hand-made pools.
function MarketplaceStylingItemResolverTestHarness.defineStylingItem(
	marketplaceItemId: number,
	itemSlot: string,
	isEnabled: boolean
)
	local marketplaceItemKind = StylingItemLookup.getRequiredMarketplaceItemKindForItemSlot(itemSlot)
	return table.freeze({
		stylingItemKey = StylingItemLookup.deriveStylingItemKey(marketplaceItemKind, marketplaceItemId),
		marketplaceItemKind = marketplaceItemKind,
		marketplaceItemId = marketplaceItemId,
		itemSlot = itemSlot,
		styleTags = table.freeze({ "cute" }),
		primaryColorTag = "pink",
		isEnabled = isEnabled,
	})
end

return table.freeze(MarketplaceStylingItemResolverTestHarness)
