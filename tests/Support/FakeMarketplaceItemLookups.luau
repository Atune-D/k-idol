-- A fake MarketplaceItemLookups (interface documented in src/server/MarketplaceStylingItemResolver.luau).
--
-- Every answer is scripted by the test. Nothing here is a real Roblox answer: the asset type
-- names are obviously fake strings, and ids are whatever the fixture pool uses.
--
-- Scripting answers (each script is a list used one entry per attempt; once the list runs out
-- its LAST entry repeats):
--   setItemDetailsAnswers(marketplaceItemKind, marketplaceItemId, { scriptedAnswer, ... })
--   setBundleContentsAnswers(bundleId, { scriptedAnswer, ... })
--   setOwnershipAnswers(playerUserId, marketplaceItemKind, marketplaceItemId, { scriptedAnswer, ... })
--   scriptedAnswer = { wasLookupSuccessful: boolean, lookupAnswer: any, lookupErrorMessage: string? }
--     or the string "RaiseWhileStarting" (the start call raises),
--     or the string "NeverAnswer" (the callback is never called by the fake; it is kept in
--     `neverAnsweredLookups` so a test can answer late with `answerNeverAnsweredLookupLate`).
-- Without a script: item details are on sale, sellable here, priced from the id; a bundle holds
-- a fake left shoe, a fake right shoe and a non-wearable saved-outfit entry; nobody owns anything.
--
-- Timing: answers are delivered inside the start call, unless `setHoldsAnswersUntilReleased(true)`;
-- then they wait in `pendingLookupAnswers` until `releasePendingAnswerAt(position)` or
-- `releaseAllPendingAnswers()`. Every started call is recorded, and the largest number of
-- answers ever held at once (details, contents and ownership alike) is kept in `largestPendingLookupCount`.

local FakeMarketplaceItemLookups = {}
FakeMarketplaceItemLookups.__index = FakeMarketplaceItemLookups

FakeMarketplaceItemLookups.RAISE_WHILE_STARTING = "RaiseWhileStarting"
FakeMarketplaceItemLookups.NEVER_ANSWER = "NeverAnswer"
FakeMarketplaceItemLookups.FAKE_ASSET_TYPE_NAME = "FakeAssetTypeForTests"
FakeMarketplaceItemLookups.FAKE_LEFT_SHOE_ASSET_TYPE_NAME = "FakeLeftShoeAssetTypeForTests"
FakeMarketplaceItemLookups.FAKE_RIGHT_SHOE_ASSET_TYPE_NAME = "FakeRightShoeAssetTypeForTests"

-- The fake shoes inside bundle N are assets N*10+1 (left) and N*10+2 (right).
function FakeMarketplaceItemLookups.deriveFakeLeftShoeAssetId(bundleId: number): number
	return bundleId * 10 + 1
end

function FakeMarketplaceItemLookups.deriveFakeRightShoeAssetId(bundleId: number): number
	return bundleId * 10 + 2
end

function FakeMarketplaceItemLookups.buildOnSaleSellableItemDetails(
	marketplaceItemKind: string,
	marketplaceItemId: number
)
	return {
		itemDisplayName = string.format("Fake %s %d", marketplaceItemKind, marketplaceItemId),
		priceInRobux = marketplaceItemId % 1000,
		isOnSale = true,
		canBeSoldInThisGame = true,
		robloxAssetTypeName = if marketplaceItemKind == "Asset"
			then FakeMarketplaceItemLookups.FAKE_ASSET_TYPE_NAME
			else nil,
	}
end

function FakeMarketplaceItemLookups.buildFakeShoeBundleContentEntries(bundleId: number)
	return {
		{
			isWearableAsset = true,
			wornAssetId = FakeMarketplaceItemLookups.deriveFakeLeftShoeAssetId(bundleId),
			robloxAssetTypeName = FakeMarketplaceItemLookups.FAKE_LEFT_SHOE_ASSET_TYPE_NAME,
		},
		{
			isWearableAsset = true,
			wornAssetId = FakeMarketplaceItemLookups.deriveFakeRightShoeAssetId(bundleId),
			robloxAssetTypeName = FakeMarketplaceItemLookups.FAKE_RIGHT_SHOE_ASSET_TYPE_NAME,
		},
		-- The saved-outfit entry every bundle lists; not an asset a character wears.
		{ isWearableAsset = false, wornAssetId = bundleId * 10 + 9 },
	}
end

function FakeMarketplaceItemLookups.succeedWith(lookupAnswer: any)
	return { wasLookupSuccessful = true, lookupAnswer = lookupAnswer }
end

function FakeMarketplaceItemLookups.failWith(lookupErrorMessage: string?)
	return { wasLookupSuccessful = false, lookupErrorMessage = lookupErrorMessage or "fake lookup error" }
end

function FakeMarketplaceItemLookups.new()
	return setmetatable({
		scriptedAnswersByLookupName = {} :: { [string]: { any } },
		attemptCountByLookupName = {} :: { [string]: number },
		holdsAnswersUntilReleased = false,
		pendingLookupAnswers = {} :: { { lookupName: string, deliverAnswer: () -> () } },
		largestPendingLookupCount = 0,
		-- Lookups scripted "NeverAnswer", in start order: { lookupName, onLookupFinished }.
		neverAnsweredLookups = {} :: { { lookupName: string, onLookupFinished: (boolean, any, string?) -> () } },
		-- Every start call, in order: lookup names such as "details Asset 9000001",
		-- "contents 9000041", "ownership 8801 Bundle 9000041".
		startedLookupNames = {} :: { string },
	}, FakeMarketplaceItemLookups)
end

local function buildDetailsLookupName(marketplaceItemKind: string, marketplaceItemId: number): string
	return string.format("details %s %d", marketplaceItemKind, marketplaceItemId)
end

local function buildContentsLookupName(bundleId: number): string
	return string.format("contents %d", bundleId)
end

local function buildOwnershipLookupName(playerUserId: number, marketplaceItemKind: string, marketplaceItemId: number)
	return string.format("ownership %d %s %d", playerUserId, marketplaceItemKind, marketplaceItemId)
end

function FakeMarketplaceItemLookups:setItemDetailsAnswers(
	marketplaceItemKind: string,
	marketplaceItemId: number,
	scriptedAnswers: { any }
)
	self.scriptedAnswersByLookupName[buildDetailsLookupName(marketplaceItemKind, marketplaceItemId)] = scriptedAnswers
end

function FakeMarketplaceItemLookups:setBundleContentsAnswers(bundleId: number, scriptedAnswers: { any })
	self.scriptedAnswersByLookupName[buildContentsLookupName(bundleId)] = scriptedAnswers
end

function FakeMarketplaceItemLookups:setOwnershipAnswers(
	playerUserId: number,
	marketplaceItemKind: string,
	marketplaceItemId: number,
	scriptedAnswers: { any }
)
	self.scriptedAnswersByLookupName[buildOwnershipLookupName(playerUserId, marketplaceItemKind, marketplaceItemId)] =
		scriptedAnswers
end

function FakeMarketplaceItemLookups:setHoldsAnswersUntilReleased(holdsAnswersUntilReleased: boolean)
	self.holdsAnswersUntilReleased = holdsAnswersUntilReleased
end

-- How many times this lookup was started ("details Asset 9000001", "contents 9000041", ...).
function FakeMarketplaceItemLookups:countStartedLookups(lookupName: string): number
	return self.attemptCountByLookupName[lookupName] or 0
end

function FakeMarketplaceItemLookups:countPendingAnswers(): number
	return #self.pendingLookupAnswers
end

local function pickScriptedAnswer(self, lookupName: string, defaultScriptedAnswer: any)
	local attemptNumber = (self.attemptCountByLookupName[lookupName] or 0) + 1
	self.attemptCountByLookupName[lookupName] = attemptNumber
	table.insert(self.startedLookupNames, lookupName)
	local scriptedAnswers = self.scriptedAnswersByLookupName[lookupName]
	if scriptedAnswers == nil or #scriptedAnswers == 0 then
		return defaultScriptedAnswer
	end
	return scriptedAnswers[math.min(attemptNumber, #scriptedAnswers)]
end

local function deliverOrHoldAnswer(
	self,
	lookupName: string,
	scriptedAnswer: any,
	onLookupFinished: (boolean, any, string?) -> ()
)
	if scriptedAnswer == FakeMarketplaceItemLookups.RAISE_WHILE_STARTING then
		error("fake lookup raised while starting " .. lookupName)
	end
	if scriptedAnswer == FakeMarketplaceItemLookups.NEVER_ANSWER then
		table.insert(self.neverAnsweredLookups, { lookupName = lookupName, onLookupFinished = onLookupFinished })
		return
	end
	local function deliverAnswer()
		onLookupFinished(
			scriptedAnswer.wasLookupSuccessful,
			scriptedAnswer.lookupAnswer,
			scriptedAnswer.lookupErrorMessage
		)
	end
	if not self.holdsAnswersUntilReleased then
		deliverAnswer()
		return
	end
	table.insert(self.pendingLookupAnswers, { lookupName = lookupName, deliverAnswer = deliverAnswer })
	self.largestPendingLookupCount = math.max(self.largestPendingLookupCount, #self.pendingLookupAnswers)
end

function FakeMarketplaceItemLookups:startLookingUpMarketplaceItemDetails(
	marketplaceItemKind: string,
	marketplaceItemId: number,
	onLookupFinished: (boolean, any, string?) -> ()
)
	local lookupName = buildDetailsLookupName(marketplaceItemKind, marketplaceItemId)
	local scriptedAnswer = pickScriptedAnswer(
		self,
		lookupName,
		FakeMarketplaceItemLookups.succeedWith(
			FakeMarketplaceItemLookups.buildOnSaleSellableItemDetails(marketplaceItemKind, marketplaceItemId)
		)
	)
	deliverOrHoldAnswer(self, lookupName, scriptedAnswer, onLookupFinished)
end

function FakeMarketplaceItemLookups:startLookingUpBundleContents(
	bundleId: number,
	onLookupFinished: (boolean, any, string?) -> ()
)
	local lookupName = buildContentsLookupName(bundleId)
	local scriptedAnswer = pickScriptedAnswer(
		self,
		lookupName,
		FakeMarketplaceItemLookups.succeedWith(FakeMarketplaceItemLookups.buildFakeShoeBundleContentEntries(bundleId))
	)
	deliverOrHoldAnswer(self, lookupName, scriptedAnswer, onLookupFinished)
end

function FakeMarketplaceItemLookups:startCheckingPlayerOwnsMarketplaceItem(
	playerUserId: number,
	marketplaceItemKind: string,
	marketplaceItemId: number,
	onCheckFinished: (boolean, any, string?) -> ()
)
	local lookupName = buildOwnershipLookupName(playerUserId, marketplaceItemKind, marketplaceItemId)
	local scriptedAnswer = pickScriptedAnswer(self, lookupName, FakeMarketplaceItemLookups.succeedWith(false))
	deliverOrHoldAnswer(self, lookupName, scriptedAnswer, onCheckFinished)
end

function FakeMarketplaceItemLookups:releasePendingAnswerAt(pendingPosition: number)
	local pendingLookupAnswer = self.pendingLookupAnswers[pendingPosition]
	if pendingLookupAnswer == nil then
		error("FakeMarketplaceItemLookups: no pending answer at position " .. tostring(pendingPosition), 2)
	end
	table.remove(self.pendingLookupAnswers, pendingPosition)
	pendingLookupAnswer.deliverAnswer()
end

-- Calls back a lookup that was scripted "NeverAnswer", as a Roblox call answering very late would.
function FakeMarketplaceItemLookups:answerNeverAnsweredLookupLate(
	neverAnsweredPosition: number,
	wasLookupSuccessful: any,
	lookupAnswer: any
)
	local neverAnsweredLookup = self.neverAnsweredLookups[neverAnsweredPosition]
	if neverAnsweredLookup == nil then
		error("FakeMarketplaceItemLookups: no never-answered lookup at position " .. tostring(neverAnsweredPosition), 2)
	end
	neverAnsweredLookup.onLookupFinished(wasLookupSuccessful, lookupAnswer, nil)
end

-- Releases held answers oldest first, including answers to lookups started while releasing.
function FakeMarketplaceItemLookups:releaseAllPendingAnswers()
	while #self.pendingLookupAnswers > 0 do
		self:releasePendingAnswerAt(1)
	end
end

return FakeMarketplaceItemLookups
