-- DeviceRequestChannelAnswerRouter (development spec v1.3 §2, §2.13): connects every channel a
-- device sends on to the module method that already implements it. It decides nothing itself
-- beyond the one thing the wiring owes the spec: every device request is rate-limited EXACTLY
-- once. Most answering modules ask PlayerRequestRateLimiter themselves (their headers say so);
-- for the three whose methods do not (the wardrobe snapshot and the ownership answer of
-- MarketplaceStylingItemResolver, and FanCountLeaderboardKeeper's top entries) the router asks
-- the limiter first. Which is which is the declarative DEVICE_REQUEST_ROUTES table below.
--
-- `SetRoundOutfitDraft` is never rate-limited here (§2.13: drafts are coalesced, never refused;
-- the referee's draft keeper applies the 0.25 s interval).
-- Calls no Roblox-specific interface: RobloxDeviceRemoteChannelConnections calls it.
--
-- PUBLIC API
--   DeviceRequestChannelAnswerRouter.DEVICE_REQUEST_ROUTES   frozen
--     { [requestChannelName]: { isRateLimitedByAnsweringModule: boolean, answeringModuleName: string } }
--     for exactly the channels of kind DeviceRequestWithServerAnswer (RemoteNames).
--   DeviceRequestChannelAnswerRouter.REQUEST_FAILED_ON_SERVER_REJECTION_REASON = "RequestFailedOnServer"
--     The answer when the answering module RAISED (a server bug, never device input: every module
--     accepts any device value). Not a spec reason: added so a device always gets an answer
--     instead of an error; listed as a deviation.
--   DeviceRequestChannelAnswerRouter.new(answeringModules) -> router
--     answeringModules = { playerRequestRateLimiter, themedRoundReferee,
--       marketplaceStylingItemResolver, fanCountLeaderboardKeeper, setLobbyOutfitRequestAnswerer,
--       danceAndCosmeticPurchaseRequestAnswerer, danceAndCosmeticEquipRequestAnswerer,
--       lobbyDanceCoordinator, dailyProgressTracker, promoCodeRedeemer, logger }
--     Raises naming any that is missing.
--   router:startAnsweringDeviceRequest(requestChannelName, playerUserId, untrustedRequestPayload, onAnswerReady)
--     Calls onAnswerReady(answerTable) exactly once, during this call or later (only the
--     ownership answer comes later, from the resolver's callback). `playerUserId` is the server's
--     identity of the sender; the payload is whatever the device sent and is handed to the module
--     untouched. Answers are the modules' own (§2 shapes); the leaderboard answer is
--     { isAccepted = true, leaderboardEntries, refreshedAtUnixSeconds }. A channel that is not a
--     request channel raises (a wiring error).
--   router:receiveDeviceMessageWithoutAnswer(messageChannelName, playerUserId, untrustedMessage)
--     Only SetRoundOutfitDraft: hands the message to referee:receiveSetRoundOutfitDraftFromDevice.
--     Another channel raises. A raise inside the referee is logged, never passed to the caller.

local LoggedErrorTextShortener = require("./LoggedErrorTextShortener")
local RemoteNames = require("../shared/RemoteNames")

local DeviceRequestChannelAnswerRouter = {}
DeviceRequestChannelAnswerRouter.__index = DeviceRequestChannelAnswerRouter

DeviceRequestChannelAnswerRouter.REQUEST_FAILED_ON_SERVER_REJECTION_REASON = "RequestFailedOnServer"

local REQUIRED_ANSWERING_MODULE_NAMES = table.freeze({
	"playerRequestRateLimiter",
	"themedRoundReferee",
	"marketplaceStylingItemResolver",
	"fanCountLeaderboardKeeper",
	"setLobbyOutfitRequestAnswerer",
	"danceAndCosmeticPurchaseRequestAnswerer",
	"danceAndCosmeticEquipRequestAnswerer",
	"lobbyDanceCoordinator",
	"dailyProgressTracker",
	"promoCodeRedeemer",
	"logger",
})

local function route(answeringModuleName: string, isRateLimitedByAnsweringModule: boolean, answerRequest)
	return table.freeze({
		answeringModuleName = answeringModuleName,
		isRateLimitedByAnsweringModule = isRateLimitedByAnsweringModule,
		answerRequest = answerRequest,
	})
end

-- answerRequest(answeringModule, playerUserId, untrustedRequestPayload, onAnswerReady)
DeviceRequestChannelAnswerRouter.DEVICE_REQUEST_ROUTES = table.freeze({
	RequestJoinCurrentRound = route("themedRoundReferee", true, function(referee, playerUserId, _, onAnswerReady)
		onAnswerReady(referee:admitOrRejectJoinCurrentRoundRequest(playerUserId))
	end),
	RequestWardrobeCatalogSnapshot = route(
		"marketplaceStylingItemResolver",
		false,
		function(resolver, _, _, onAnswerReady)
			onAnswerReady(resolver:readWardrobeCatalogSnapshotAnswer())
		end
	),
	RequestStylingItemOwnership = route(
		"marketplaceStylingItemResolver",
		false,
		function(resolver, playerUserId, untrustedStylingItemKey, onAnswerReady)
			resolver:startAnsweringStylingItemOwnershipRequest(playerUserId, untrustedStylingItemKey, onAnswerReady)
		end
	),
	RequestFanCountLeaderboardTopEntries = route(
		"fanCountLeaderboardKeeper",
		false,
		function(keeper, _, _, onAnswerReady)
			local topEntriesAnswer = keeper:readTopEntriesAnswer()
			onAnswerReady({
				isAccepted = true,
				leaderboardEntries = topEntriesAnswer.leaderboardEntries,
				refreshedAtUnixSeconds = topEntriesAnswer.refreshedAtUnixSeconds,
			})
		end
	),
	SetLobbyOutfit = route(
		"setLobbyOutfitRequestAnswerer",
		true,
		function(answerer, playerUserId, payload, onAnswerReady)
			onAnswerReady(answerer:answerSetLobbyOutfitRequest(playerUserId, payload))
		end
	),
	RequestPurchaseDanceWithStarCoins = route(
		"danceAndCosmeticPurchaseRequestAnswerer",
		true,
		function(answerer, playerUserId, payload, onAnswerReady)
			onAnswerReady(answerer:purchaseDanceWithStarCoinsAndBuildAnswer(playerUserId, payload))
		end
	),
	RequestPurchaseCosmeticWithStarCoins = route(
		"danceAndCosmeticPurchaseRequestAnswerer",
		true,
		function(answerer, playerUserId, payload, onAnswerReady)
			onAnswerReady(answerer:purchaseCosmeticWithStarCoinsAndBuildAnswer(playerUserId, payload))
		end
	),
	RequestEquipDance = route(
		"danceAndCosmeticEquipRequestAnswerer",
		true,
		function(answerer, playerUserId, payload, onAnswerReady)
			onAnswerReady(answerer:equipOwnedDanceAndBuildAnswer(playerUserId, payload))
		end
	),
	RequestEquipCosmetic = route(
		"danceAndCosmeticEquipRequestAnswerer",
		true,
		function(answerer, playerUserId, payload, onAnswerReady)
			onAnswerReady(answerer:equipOwnedCosmeticAndBuildAnswer(playerUserId, payload))
		end
	),
	RequestStartDanceInLobby = route(
		"lobbyDanceCoordinator",
		true,
		function(coordinator, playerUserId, payload, onAnswerReady)
			onAnswerReady(coordinator:answerStartDanceInLobbyRequest(playerUserId, payload))
		end
	),
	RequestSyncDanceWithPlayer = route(
		"lobbyDanceCoordinator",
		true,
		function(coordinator, playerUserId, payload, onAnswerReady)
			onAnswerReady(coordinator:answerSyncDanceWithPlayerRequest(playerUserId, payload))
		end
	),
	RequestStopDanceInLobby = route(
		"lobbyDanceCoordinator",
		true,
		function(coordinator, playerUserId, _, onAnswerReady)
			onAnswerReady(coordinator:answerStopDanceInLobbyRequest(playerUserId))
		end
	),
	RequestClaimPlaytimeMilestone = route(
		"dailyProgressTracker",
		true,
		function(tracker, playerUserId, payload, onAnswerReady)
			onAnswerReady(tracker:answerClaimPlaytimeMilestoneRequest(playerUserId, payload))
		end
	),
	RequestClaimDailyQuestReward = route(
		"dailyProgressTracker",
		true,
		function(tracker, playerUserId, payload, onAnswerReady)
			onAnswerReady(tracker:answerClaimDailyQuestRewardRequest(playerUserId, payload))
		end
	),
	RequestRedeemPromoCode = route("promoCodeRedeemer", true, function(redeemer, playerUserId, payload, onAnswerReady)
		onAnswerReady(redeemer:redeemPromoCodeAndAnswerRequest(playerUserId, payload))
	end),
})

function DeviceRequestChannelAnswerRouter.new(answeringModules)
	for _, answeringModuleName in REQUIRED_ANSWERING_MODULE_NAMES do
		if type(answeringModules) ~= "table" or answeringModules[answeringModuleName] == nil then
			error("DeviceRequestChannelAnswerRouter: missing " .. answeringModuleName, 2)
		end
	end
	return setmetatable({ answeringModules = answeringModules }, DeviceRequestChannelAnswerRouter)
end

local function buildRejection(rejectionReason: string)
	return { isAccepted = false, rejectionReason = rejectionReason }
end

function DeviceRequestChannelAnswerRouter:startAnsweringDeviceRequest(
	requestChannelName: string,
	playerUserId: number,
	untrustedRequestPayload: any,
	onAnswerReady: (any) -> ()
)
	local deviceRequestRoute = DeviceRequestChannelAnswerRouter.DEVICE_REQUEST_ROUTES[requestChannelName]
	if deviceRequestRoute == nil then
		error(
			string.format(
				"DeviceRequestChannelAnswerRouter: %q is not a device request channel",
				tostring(requestChannelName)
			),
			2
		)
	end
	local hasAnswered = false
	local function answerOnce(answer)
		if hasAnswered then
			return
		end
		hasAnswered = true
		onAnswerReady(answer)
	end
	local answeringModules = self.answeringModules
	local didAnswerWithoutRaising, raisedError = pcall(function()
		if not deviceRequestRoute.isRateLimitedByAnsweringModule then
			local rateLimitDecision =
				answeringModules.playerRequestRateLimiter:admitOrRefusePlayerRequest(playerUserId, requestChannelName)
			if not rateLimitDecision.isRequestAllowed then
				answerOnce(buildRejection(rateLimitDecision.rejectionReason))
				return
			end
		end
		deviceRequestRoute.answerRequest(
			answeringModules[deviceRequestRoute.answeringModuleName],
			playerUserId,
			untrustedRequestPayload,
			answerOnce
		)
	end)
	if not didAnswerWithoutRaising then
		answeringModules.logger:logWarning(
			string.format(
				"DeviceRequestChannelAnswerRouter: answering %s for player %s raised: %s",
				requestChannelName,
				tostring(playerUserId),
				LoggedErrorTextShortener.shortenErrorTextForLog(raisedError)
			)
		)
		answerOnce(buildRejection(DeviceRequestChannelAnswerRouter.REQUEST_FAILED_ON_SERVER_REJECTION_REASON))
	end
end

function DeviceRequestChannelAnswerRouter:receiveDeviceMessageWithoutAnswer(
	messageChannelName: string,
	playerUserId: number,
	untrustedMessage: any
)
	if messageChannelName ~= RemoteNames.REMOTE_CHANNEL_NAMES.SetRoundOutfitDraft then
		error(
			string.format(
				"DeviceRequestChannelAnswerRouter: %q is not a device message channel",
				tostring(messageChannelName)
			),
			2
		)
	end
	local didReceive, raisedError = pcall(function()
		self.answeringModules.themedRoundReferee:receiveSetRoundOutfitDraftFromDevice(playerUserId, untrustedMessage)
	end)
	if not didReceive then
		self.answeringModules.logger:logWarning(
			string.format(
				"DeviceRequestChannelAnswerRouter: SetRoundOutfitDraft for player %s raised: %s",
				tostring(playerUserId),
				LoggedErrorTextShortener.shortenErrorTextForLog(raisedError)
			)
		)
	end
end

return DeviceRequestChannelAnswerRouter
