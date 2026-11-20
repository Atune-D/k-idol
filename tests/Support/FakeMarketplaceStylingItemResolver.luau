-- A fake of the wardrobe-catalog side of MarketplaceStylingItemResolver (development spec §2.14),
-- with exactly the interface StoredLobbyOutfitKeeper uses:
--   resolver:isWardrobeCatalogReady() -> boolean
--   resolver:getAvailableStylingItemKeySet() -> AvailableStylingItemKeySet   (empty while not ready)
--   resolver:subscribeToWardrobeCatalogChanged(listener(wardrobeCatalogChangedMessage)) -> unsubscribe
-- The message is { isWardrobeCatalogReady, wardrobeCatalogVersion }, as in §2.14.
--
-- The test drives it: the catalog starts not ready (version 0); `publishWardrobeCatalog(set)`
-- makes it ready with that available set, raises the version by one and tells every listener at
-- once (no waiting). Each call hands out a fresh frozen copy of the set.

local FakeMarketplaceStylingItemResolver = {}
FakeMarketplaceStylingItemResolver.__index = FakeMarketplaceStylingItemResolver

function FakeMarketplaceStylingItemResolver.new()
	return setmetatable({
		isCatalogReady = false,
		wardrobeCatalogVersion = 0,
		availableStylingItemKeySet = {} :: { [string]: boolean },
		catalogChangedSubscriptions = {} :: { { listener: (any) -> () } },
	}, FakeMarketplaceStylingItemResolver)
end

function FakeMarketplaceStylingItemResolver:isWardrobeCatalogReady(): boolean
	return self.isCatalogReady
end

function FakeMarketplaceStylingItemResolver:getAvailableStylingItemKeySet(): { [string]: boolean }
	if not self.isCatalogReady then
		return table.freeze({})
	end
	return table.freeze(table.clone(self.availableStylingItemKeySet))
end

function FakeMarketplaceStylingItemResolver:subscribeToWardrobeCatalogChanged(listener: (any) -> ()): () -> ()
	local subscription = { listener = listener }
	table.insert(self.catalogChangedSubscriptions, subscription)
	return function()
		local subscriptionIndex = table.find(self.catalogChangedSubscriptions, subscription)
		if subscriptionIndex then
			table.remove(self.catalogChangedSubscriptions, subscriptionIndex)
		end
	end
end

function FakeMarketplaceStylingItemResolver:countCatalogChangedSubscriptions(): number
	return #self.catalogChangedSubscriptions
end

local function tellListenersCatalogChanged(self)
	local wardrobeCatalogChangedMessage = table.freeze({
		isWardrobeCatalogReady = self.isCatalogReady,
		wardrobeCatalogVersion = self.wardrobeCatalogVersion,
	})
	for _, subscription in table.clone(self.catalogChangedSubscriptions) do
		subscription.listener(wardrobeCatalogChangedMessage)
	end
end

-- The first pass finished, or a later pass produced a new catalog version.
function FakeMarketplaceStylingItemResolver:publishWardrobeCatalog(availableStylingItemKeySet: { [string]: boolean })
	self.isCatalogReady = true
	self.wardrobeCatalogVersion += 1
	self.availableStylingItemKeySet = table.clone(availableStylingItemKeySet)
	tellListenersCatalogChanged(self)
end

return FakeMarketplaceStylingItemResolver
