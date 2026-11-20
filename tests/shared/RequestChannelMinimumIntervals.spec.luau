-- The §2.13 interval table has ONE home (src/shared/RequestChannelMinimumIntervals) that the server's
-- rate limiter and the device's request senders both read, so they cannot disagree.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FanCountLeaderboardRequester = require("../../src/client/FanCountLeaderboardRequester")
local PlayerRequestRateLimiter = require("../../src/server/PlayerRequestRateLimiter")
local RemoteNames = require("../../src/shared/RemoteNames")
local RequestChannelMinimumIntervals = require("../../src/shared/RequestChannelMinimumIntervals")
local WardrobeCatalogSnapshotRequester = require("../../src/client/WardrobeCatalogSnapshotRequester")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

-- Spec §2.13, copied by hand.
local SPEC_MINIMUM_INTERVAL_SECONDS_BY_CHANNEL = {
	SetRoundOutfitDraft = 0.25,
	RequestWardrobeCatalogSnapshot = 2,
	RequestStylingItemOwnership = 0.5,
	RequestJoinCurrentRound = 1,
	SetLobbyOutfit = 2,
	RequestEquipDance = 1,
	RequestEquipCosmetic = 1,
	RequestPurchaseDanceWithStarCoins = 1,
	RequestPurchaseCosmeticWithStarCoins = 1,
	RequestClaimPlaytimeMilestone = 1,
	RequestClaimDailyQuestReward = 1,
	RequestStartDanceInLobby = 0.5,
	RequestSyncDanceWithPlayer = 0.5,
	RequestStopDanceInLobby = 0.5,
	RequestRedeemPromoCode = 2,
	RequestFanCountLeaderboardTopEntries = 5,
}

local TABLE = RequestChannelMinimumIntervals.MINIMUM_REQUEST_INTERVAL_SECONDS_BY_REMOTE_CHANNEL_NAME

describe("RequestChannelMinimumIntervals", function()
	it("holds exactly the spec §2.13 interval of every device-sent channel", function()
		local copiedTable = table.clone(TABLE)
		expect(copiedTable).toEqual(SPEC_MINIMUM_INTERVAL_SECONDS_BY_CHANNEL)
		for channelName in copiedTable do
			expect(RemoteNames.DEVICE_SENT_REMOTE_CHANNEL_NAME_SET[channelName]).toBe(true)
		end
	end)

	it("raises, naming it, for a channel that is not rate-limited, by index and by function", function()
		expect(function()
			return TABLE.RoundStateChanged
		end).toThrow('"RoundStateChanged" is not a rate-limited request channel')
		expect(function()
			return RequestChannelMinimumIntervals.readMinimumRequestIntervalSeconds("RequestJoinCurentRound")
		end).toThrow('"RequestJoinCurentRound" is not a rate-limited request channel')
		expect(table.isfrozen(TABLE)).toBe(true)
	end)

	it("is the very table the server's rate limiter enforces", function()
		expect(PlayerRequestRateLimiter.MINIMUM_REQUEST_INTERVAL_SECONDS_BY_REMOTE_CHANNEL_NAME).toBe(TABLE)
	end)

	it("gives the device's Phase 1 requesters their intervals", function()
		expect(WardrobeCatalogSnapshotRequester.MINIMUM_REQUEST_INTERVAL_SECONDS).toBe(
			TABLE.RequestWardrobeCatalogSnapshot
		)
		expect(FanCountLeaderboardRequester.MINIMUM_REQUEST_INTERVAL_SECONDS).toBe(
			TABLE.RequestFanCountLeaderboardTopEntries
		)
	end)
end)
