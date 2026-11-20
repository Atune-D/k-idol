-- RequestChannelMinimumIntervals (development spec §2.13 "Request rate limits"): the minimum interval
-- per player per device-sent channel, in ONE place that both sides read. The server's
-- PlayerRequestRateLimiter enforces exactly this table; the device's request senders wait at least
-- this long between two requests on a channel, so the two can never disagree.
--
-- The SetRoundOutfitDraft entry (0.25 s, coalesced rather than refused, §2.3) is read from
-- ThemedRoundProtocol, which already shares it with the device's draft sender.
-- Pure data: no Roblox-specific interface is used.
--
-- PUBLIC API
--   RequestChannelMinimumIntervals.MINIMUM_REQUEST_INTERVAL_SECONDS_BY_REMOTE_CHANNEL_NAME
--     frozen { [remoteChannelName]: seconds } for exactly the channels of
--     RemoteNames.DEVICE_SENT_REMOTE_CHANNEL_NAME_SET (16). Reading any other name raises an error
--     naming it ('"<name>" is not a rate-limited request channel').
--   RequestChannelMinimumIntervals.readMinimumRequestIntervalSeconds(remoteChannelName) -> number
--     The same lookup as a function (raises for any other name).

local RemoteNames = require("./RemoteNames")
local ThemedRoundProtocol = require("./ThemedRoundProtocol")

local REMOTE_CHANNEL_NAMES = RemoteNames.REMOTE_CHANNEL_NAMES

local RequestChannelMinimumIntervals = {}

local function freezeWithErrorOnUnknownChannel(minimumIntervalSecondsByRemoteChannelName: { [string]: number })
	setmetatable(minimumIntervalSecondsByRemoteChannelName, {
		__index = function(_, unknownRemoteChannelName)
			error(
				string.format(
					"PlayerRequestRateLimiter: %q is not a rate-limited request channel",
					tostring(unknownRemoteChannelName)
				),
				2
			)
		end,
	})
	return table.freeze(minimumIntervalSecondsByRemoteChannelName)
end

-- Spec §2.13, one entry per channel a device sends on.
RequestChannelMinimumIntervals.MINIMUM_REQUEST_INTERVAL_SECONDS_BY_REMOTE_CHANNEL_NAME =
	freezeWithErrorOnUnknownChannel({
		-- 0.25 s, coalesced rather than refused (§2.3); shared with the device, so read from there.
		[REMOTE_CHANNEL_NAMES.SetRoundOutfitDraft] = ThemedRoundProtocol.OUTFIT_DRAFT_SERVER_PROCESSING_INTERVAL_SECONDS,
		[REMOTE_CHANNEL_NAMES.RequestWardrobeCatalogSnapshot] = 2,
		[REMOTE_CHANNEL_NAMES.RequestStylingItemOwnership] = 0.5,
		[REMOTE_CHANNEL_NAMES.RequestJoinCurrentRound] = 1,
		[REMOTE_CHANNEL_NAMES.SetLobbyOutfit] = 2,
		[REMOTE_CHANNEL_NAMES.RequestEquipDance] = 1,
		[REMOTE_CHANNEL_NAMES.RequestEquipCosmetic] = 1,
		[REMOTE_CHANNEL_NAMES.RequestPurchaseDanceWithStarCoins] = 1,
		[REMOTE_CHANNEL_NAMES.RequestPurchaseCosmeticWithStarCoins] = 1,
		[REMOTE_CHANNEL_NAMES.RequestClaimPlaytimeMilestone] = 1,
		[REMOTE_CHANNEL_NAMES.RequestClaimDailyQuestReward] = 1,
		[REMOTE_CHANNEL_NAMES.RequestStartDanceInLobby] = 0.5,
		[REMOTE_CHANNEL_NAMES.RequestSyncDanceWithPlayer] = 0.5,
		[REMOTE_CHANNEL_NAMES.RequestStopDanceInLobby] = 0.5,
		[REMOTE_CHANNEL_NAMES.RequestRedeemPromoCode] = 2, -- answers TooManyAttempts (§2.10)
		[REMOTE_CHANNEL_NAMES.RequestFanCountLeaderboardTopEntries] = 5,
	})

function RequestChannelMinimumIntervals.readMinimumRequestIntervalSeconds(remoteChannelName: string): number
	return RequestChannelMinimumIntervals.MINIMUM_REQUEST_INTERVAL_SECONDS_BY_REMOTE_CHANNEL_NAME[remoteChannelName]
end

return table.freeze(RequestChannelMinimumIntervals)
