-- RobloxMarketplaceItemLookups: the Roblox-side implementation of the MarketplaceItemLookups
-- interface that MarketplaceStylingItemResolver takes (interface documented at the top of
-- MarketplaceStylingItemResolver.luau; development spec §1.2, §2.14, §8). The resolver stays the
-- only module that asks Roblox about Marketplace items (§3.3): only the resolver is given this.
--
-- Every method returns at once without yielding its caller: the engine call runs in a new thread
-- (task.spawn), and the callback is called exactly once from that thread, after the engine
-- answered or raised. An engine error, an answer RobloxMarketplaceAnswerConverter rejects, an
-- unknown kind, or a player not in this server is reported as a failure through the callback;
-- nothing raises. The callback itself runs outside the protected call, so a callback that raises
-- is never called a second time.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (server wiring)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- RobloxMarketplaceItemLookups.newForThisServer() -> marketplaceItemLookups
--   Uses the services of `game`, task.spawn and Enum.AvatarItemType. Pass the result as
--   `marketplaceItemLookups` to MarketplaceStylingItemResolver.new.
-- RobloxMarketplaceItemLookups.new(robloxMarketplaceDependencies) -> marketplaceItemLookups
--   For tests: { avatarEditorService, assetService, marketplaceService, playersService,
--   avatarItemTypeByMarketplaceItemKind = { Asset = <enum>, Bundle = <enum> },
--   startThread = function(threadBody) }.
--
-- marketplaceItemLookups:startLookingUpMarketplaceItemDetails(marketplaceItemKind, marketplaceItemId, onLookupFinished)
--   AvatarEditorService:GetItemDetailsAsync(id, AvatarItemType.Asset | .Bundle), converted by
--   RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer.
-- marketplaceItemLookups:startLookingUpBundleContents(bundleId, onLookupFinished)
--   AssetService:GetBundleDetailsAsync(bundleId), converted by convertBundleDetailsAnswer.
-- marketplaceItemLookups:startCheckingPlayerOwnsMarketplaceItem(playerUserId, marketplaceItemKind,
--                                                               marketplaceItemId, onCheckFinished)
--   Players:GetPlayerByUserId, then MarketplaceService:PlayerOwnsAssetAsync (kind "Asset") or
--   :PlayerOwnsBundleAsync (kind "Bundle"). Fails when the player is not in this server or the
--   engine does not answer a boolean.
--
-- Roblox API used, each read in the official documentation while writing this file:
--   game:GetService                          https://create.roblox.com/docs/reference/engine/classes/ServiceProvider
--   AvatarEditorService:GetItemDetailsAsync  https://create.roblox.com/docs/reference/engine/classes/AvatarEditorService
--     (yields; experience-wide limit of 100 requests per second for these endpoints)
--   Enum.AvatarItemType.Asset / .Bundle      https://create.roblox.com/docs/reference/engine/enums/AvatarItemType
--   AssetService:GetBundleDetailsAsync       https://create.roblox.com/docs/reference/engine/classes/AssetService
--   MarketplaceService:PlayerOwnsAssetAsync, :PlayerOwnsBundleAsync (both yield and may throw)
--                                            https://create.roblox.com/docs/reference/engine/classes/MarketplaceService
--   Players:GetPlayerByUserId (nil when absent) https://create.roblox.com/docs/reference/engine/classes/Players
--   task.spawn                               https://create.roblox.com/docs/reference/engine/libraries/task
--
-- Verified in Studio 0.748 on 2026-11-19 (unpublished Place1), on the server of a playtest, with
-- the whole project loaded by tools/SyncProjectIntoStudio.luau (no copy, no harness): the real
-- MarketplaceStylingItemResolver resolved the seven-item development pool through this file (7
-- available, 0 hidden, first pass 0.7 s); ownership of an asset and of a bundle was read for the
-- playtest player (false, false). Earlier that day item details of asset 1 failed with the engine
-- error "HTTP request failed with status code: 400" and the method returned before answering. The
-- engine answers seen there are kept in tests/fixtures/CapturedRobloxMarketplaceAnswers.luau. The
-- Lune tests (tests/server/RobloxMarketplaceItemLookups.spec.luau) cover the threading and failure
-- rules with fake services.

local RobloxMarketplaceAnswerConverter = require("./RobloxMarketplaceAnswerConverter")

local RobloxMarketplaceItemLookups = {}
RobloxMarketplaceItemLookups.__index = RobloxMarketplaceItemLookups

function RobloxMarketplaceItemLookups.new(robloxMarketplaceDependencies)
	return setmetatable({
		avatarEditorService = robloxMarketplaceDependencies.avatarEditorService,
		assetService = robloxMarketplaceDependencies.assetService,
		marketplaceService = robloxMarketplaceDependencies.marketplaceService,
		playersService = robloxMarketplaceDependencies.playersService,
		avatarItemTypeByMarketplaceItemKind = robloxMarketplaceDependencies.avatarItemTypeByMarketplaceItemKind,
		startThread = robloxMarketplaceDependencies.startThread,
	}, RobloxMarketplaceItemLookups)
end

function RobloxMarketplaceItemLookups.newForThisServer()
	return RobloxMarketplaceItemLookups.new({
		avatarEditorService = game:GetService("AvatarEditorService"),
		assetService = game:GetService("AssetService"),
		marketplaceService = game:GetService("MarketplaceService"),
		playersService = game:GetService("Players"),
		avatarItemTypeByMarketplaceItemKind = {
			Asset = Enum.AvatarItemType.Asset,
			Bundle = Enum.AvatarItemType.Bundle,
		},
		startThread = function(threadBody: () -> ())
			task.spawn(threadBody)
		end,
	})
end

-- Runs `askRobloxAndConvert` in a new thread. It returns (answer, nil) or (nil, problem), or
-- raises; `onFinished` is then called exactly once with (true, answer, nil) or (false, nil, message).
local function startAskingRoblox(self, lookupDescription: string, askRobloxAndConvert: () -> (any, string?), onFinished)
	self.startThread(function()
		local didAskingSucceed, convertedAnswer, problemDescription = pcall(askRobloxAndConvert)
		if not didAskingSucceed then
			onFinished(false, nil, string.format("%s: Roblox raised: %s", lookupDescription, tostring(convertedAnswer)))
		elseif convertedAnswer == nil then
			onFinished(false, nil, string.format("%s: %s", lookupDescription, tostring(problemDescription)))
		else
			onFinished(true, convertedAnswer, nil)
		end
	end)
end

function RobloxMarketplaceItemLookups:startLookingUpMarketplaceItemDetails(
	marketplaceItemKind: string,
	marketplaceItemId: number,
	onLookupFinished: (boolean, any, string?) -> ()
)
	local lookupDescription =
		string.format("item details of %s %s", tostring(marketplaceItemKind), tostring(marketplaceItemId))
	startAskingRoblox(self, lookupDescription, function()
		local avatarItemType = self.avatarItemTypeByMarketplaceItemKind[marketplaceItemKind]
		if avatarItemType == nil then
			return nil, "unknown marketplaceItemKind"
		end
		local rawAvatarItemDetails = self.avatarEditorService:GetItemDetailsAsync(marketplaceItemId, avatarItemType)
		return RobloxMarketplaceAnswerConverter.convertAvatarItemDetailsAnswer(
			marketplaceItemKind,
			marketplaceItemId,
			rawAvatarItemDetails
		)
	end, onLookupFinished)
end

function RobloxMarketplaceItemLookups:startLookingUpBundleContents(
	bundleId: number,
	onLookupFinished: (boolean, any, string?) -> ()
)
	startAskingRoblox(self, "contents of bundle " .. tostring(bundleId), function()
		local rawBundleDetails = self.assetService:GetBundleDetailsAsync(bundleId)
		return RobloxMarketplaceAnswerConverter.convertBundleDetailsAnswer(bundleId, rawBundleDetails)
	end, onLookupFinished)
end

function RobloxMarketplaceItemLookups:startCheckingPlayerOwnsMarketplaceItem(
	playerUserId: number,
	marketplaceItemKind: string,
	marketplaceItemId: number,
	onCheckFinished: (boolean, boolean?, string?) -> ()
)
	local checkDescription = string.format(
		"ownership of %s %s by user %s",
		tostring(marketplaceItemKind),
		tostring(marketplaceItemId),
		tostring(playerUserId)
	)
	startAskingRoblox(self, checkDescription, function()
		local ownershipCheckMethodName = if marketplaceItemKind == "Asset"
			then "PlayerOwnsAssetAsync"
			elseif marketplaceItemKind == "Bundle" then "PlayerOwnsBundleAsync"
			else nil
		if ownershipCheckMethodName == nil then
			return nil, "unknown marketplaceItemKind"
		end
		local player = self.playersService:GetPlayerByUserId(playerUserId)
		if player == nil then
			return nil, "the player is not in this server"
		end
		local isOwnedByPlayer =
			self.marketplaceService[ownershipCheckMethodName](self.marketplaceService, player, marketplaceItemId)
		if type(isOwnedByPlayer) ~= "boolean" then
			return nil, "Roblox did not answer a boolean"
		end
		return isOwnedByPlayer, nil
	end, onCheckFinished)
end

return RobloxMarketplaceItemLookups
