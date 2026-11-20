local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local RemoteNames = require("../../src/shared/RemoteNames")
local ThemedRoundProtocol = require("../../src/shared/ThemedRoundProtocol")
local PlayerRequestRateLimiter = require("../../src/server/PlayerRequestRateLimiter")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local CHANNELS = RemoteNames.REMOTE_CHANNEL_NAMES
local INTERVAL_SECONDS_BY_CHANNEL = PlayerRequestRateLimiter.MINIMUM_REQUEST_INTERVAL_SECONDS_BY_REMOTE_CHANNEL_NAME

local PLAYER = 1001
local OTHER_PLAYER = 2002
local EXAMPLE_STARTING_UNIX_SECONDS = 1_800_000_000

-- Spec §2.13, copied by hand from the table (one row per channel).
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

-- Spec §2 channel directions, recorded once in RemoteNames (and checked against §2 there).
local DEVICE_SENT_CHANNEL_NAME_SET = RemoteNames.DEVICE_SENT_REMOTE_CHANNEL_NAME_SET
local SERVER_SENT_CHANNEL_NAME_SET = RemoteNames.SERVER_SENT_REMOTE_CHANNEL_NAME_SET

local ALLOWED = { isRequestAllowed = true }
local TOO_MANY_REQUESTS = { isRequestAllowed = false, rejectionReason = "TooManyRequests" }
local TOO_MANY_ATTEMPTS = { isRequestAllowed = false, rejectionReason = "TooManyAttempts" }

local function createLimiterWithFakeClock()
	local fakeClock = FakeClock.new(EXAMPLE_STARTING_UNIX_SECONDS)
	local playerRequestRateLimiter = PlayerRequestRateLimiter.new({ clock = fakeClock })
	return playerRequestRateLimiter, fakeClock
end

-- Every channel answered through the generic path (all but the coalesced draft channel).
local function listRefusableChannelNames(): { string }
	local refusableChannelNames = {}
	for channelName in SPEC_MINIMUM_INTERVAL_SECONDS_BY_CHANNEL do
		if channelName ~= CHANNELS.SetRoundOutfitDraft then
			table.insert(refusableChannelNames, channelName)
		end
	end
	table.sort(refusableChannelNames)
	return refusableChannelNames
end

local function expectedRefusalFor(channelName: string)
	return if channelName == CHANNELS.RequestRedeemPromoCode then TOO_MANY_ATTEMPTS else TOO_MANY_REQUESTS
end

describe("PlayerRequestRateLimiter interval table (spec §2.13)", function()
	it("gives every channel exactly the interval of the spec table", function()
		-- A plain copy without the raising metatable, so the comparison sees only the entries.
		local intervalSecondsByChannel = setmetatable(table.clone(INTERVAL_SECONDS_BY_CHANNEL), nil)
		expect(intervalSecondsByChannel).toEqual(SPEC_MINIMUM_INTERVAL_SECONDS_BY_CHANNEL)
	end)

	it("has an interval for every channel a device sends on", function()
		for channelName in DEVICE_SENT_CHANNEL_NAME_SET do
			if rawget(INTERVAL_SECONDS_BY_CHANNEL, channelName) == nil then
				error(channelName .. " is sent by a device but has no minimum interval")
			end
		end
	end)

	it("has no interval for any channel the server sends on", function()
		for channelName in SERVER_SENT_CHANNEL_NAME_SET do
			if rawget(INTERVAL_SECONDS_BY_CHANNEL, channelName) ~= nil then
				error(channelName .. " is sent only by the server but has a minimum interval")
			end
		end
	end)

	it("names only existing channels a device sends on", function()
		for channelName in INTERVAL_SECONDS_BY_CHANNEL do
			expect(rawget(CHANNELS, channelName)).toBe(channelName)
			expect(rawget(DEVICE_SENT_CHANNEL_NAME_SET, channelName)).toBe(true)
		end
	end)

	it("hands the referee the draft interval from the same table", function()
		expect(PlayerRequestRateLimiter.OUTFIT_DRAFT_SERVER_PROCESSING_INTERVAL_SECONDS).toBe(0.25)
		expect(PlayerRequestRateLimiter.OUTFIT_DRAFT_SERVER_PROCESSING_INTERVAL_SECONDS).toBe(
			INTERVAL_SECONDS_BY_CHANNEL[CHANNELS.SetRoundOutfitDraft]
		)
	end)

	it("uses exactly the draft interval the device shares (ThemedRoundProtocol, §2.3)", function()
		local sharedDraftIntervalSeconds = ThemedRoundProtocol.OUTFIT_DRAFT_SERVER_PROCESSING_INTERVAL_SECONDS
		expect(PlayerRequestRateLimiter.OUTFIT_DRAFT_SERVER_PROCESSING_INTERVAL_SECONDS).toBe(
			sharedDraftIntervalSeconds
		)
		expect(INTERVAL_SECONDS_BY_CHANNEL[CHANNELS.SetRoundOutfitDraft]).toBe(sharedDraftIntervalSeconds)
		-- And the wait the referee is told is that same interval, in whole milliseconds.
		local playerRequestRateLimiter = createLimiterWithFakeClock()
		playerRequestRateLimiter:recordOutfitDraftProcessed(PLAYER)
		expect(playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER)).toBe(
			math.round(sharedDraftIntervalSeconds * 1000)
		)
	end)

	it("raises naming the channel when an unknown channel is read, and cannot be changed", function()
		expect(function()
			return INTERVAL_SECONDS_BY_CHANNEL.RequestJoinCurentRound
		end).toThrow('"RequestJoinCurentRound" is not a rate-limited request channel')
		expect(function()
			(INTERVAL_SECONDS_BY_CHANNEL :: any).RequestJoinCurrentRound = 0
		end).toThrow()
	end)
end)

describe("PlayerRequestRateLimiter.admitOrRefusePlayerRequest", function()
	it("allows a player's first request on every channel", function()
		local playerRequestRateLimiter = createLimiterWithFakeClock()
		for _, channelName in listRefusableChannelNames() do
			expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(ALLOWED)
		end
	end)

	it("on every channel, refuses 1 ms before the interval and allows at exactly the interval", function()
		local playerRequestRateLimiter, fakeClock = createLimiterWithFakeClock()
		for _, channelName in listRefusableChannelNames() do
			local intervalMilliseconds = math.round(SPEC_MINIMUM_INTERVAL_SECONDS_BY_CHANNEL[channelName] * 1000)
			expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(ALLOWED)
			fakeClock:advanceBySeconds((intervalMilliseconds - 1) / 1000)
			expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(
				expectedRefusalFor(channelName)
			)
			fakeClock:advanceBySeconds(0.001)
			expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(ALLOWED)
			fakeClock:advanceBySeconds(10) -- leave every channel free before the next one is tried
		end
	end)

	it("refuses a request at the same moment as the accepted one", function()
		local playerRequestRateLimiter = createLimiterWithFakeClock()
		playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, CHANNELS.RequestJoinCurrentRound)
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, CHANNELS.RequestJoinCurrentRound)).toEqual(
			TOO_MANY_REQUESTS
		)
	end)

	it("changes nothing on refusal: refused requests do not push the next allowed moment away", function()
		local playerRequestRateLimiter, fakeClock = createLimiterWithFakeClock()
		local channelName = CHANNELS.SetLobbyOutfit -- 2 s
		playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)
		for _ = 1, 19 do -- a device hammering every 0.1 s
			fakeClock:advanceBySeconds(0.1)
			expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(TOO_MANY_REQUESTS)
		end
		fakeClock:advanceBySeconds(0.1) -- exactly 2 s after the accepted request
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(ALLOWED)
	end)

	it("measures the next interval from the latest accepted request, not the first", function()
		local playerRequestRateLimiter, fakeClock = createLimiterWithFakeClock()
		local channelName = CHANNELS.RequestEquipDance -- 1 s
		playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)
		fakeClock:advanceBySeconds(1.5)
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(ALLOWED)
		fakeClock:advanceBySeconds(0.999) -- 2.499 s after the first, 0.999 s after the latest
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(TOO_MANY_REQUESTS)
	end)

	it("keeps limits independent per player", function()
		local playerRequestRateLimiter = createLimiterWithFakeClock()
		local channelName = CHANNELS.RequestFanCountLeaderboardTopEntries
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(ALLOWED)
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(OTHER_PLAYER, channelName)).toEqual(ALLOWED)
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(TOO_MANY_REQUESTS)
	end)

	it("keeps limits independent per channel, even channels sharing a table row", function()
		local playerRequestRateLimiter = createLimiterWithFakeClock()
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, CHANNELS.RequestEquipDance)).toEqual(ALLOWED)
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, CHANNELS.RequestEquipCosmetic)).toEqual(
			ALLOWED
		)
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, CHANNELS.RequestJoinCurrentRound)).toEqual(
			ALLOWED
		)
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, CHANNELS.RequestEquipDance)).toEqual(
			TOO_MANY_REQUESTS
		)
	end)

	it("answers TooManyAttempts on the promo code channel and TooManyRequests elsewhere (§2.10)", function()
		local playerRequestRateLimiter, fakeClock = createLimiterWithFakeClock()
		local promoChannelName = CHANNELS.RequestRedeemPromoCode
		playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, promoChannelName)
		fakeClock:advanceBySeconds(1.999)
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, promoChannelName)).toEqual(TOO_MANY_ATTEMPTS)
		for _, channelName in listRefusableChannelNames() do
			if channelName ~= promoChannelName then
				playerRequestRateLimiter:admitOrRefusePlayerRequest(OTHER_PLAYER, channelName)
				expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(OTHER_PLAYER, channelName)).toEqual(
					TOO_MANY_REQUESTS
				)
			end
		end
	end)

	it("raises naming the channel for an unknown channel, and changes nothing", function()
		local playerRequestRateLimiter = createLimiterWithFakeClock()
		expect(function()
			playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, "RequestEquipDnace")
		end).toThrow('"RequestEquipDnace" is not a rate-limited request channel')
		expect(function()
			playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, CHANNELS.RoundStateChanged)
		end).toThrow('"RoundStateChanged" is not a rate-limited request channel')
		expect(playerRequestRateLimiter:countRememberedPlayers()).toBe(0)
	end)

	it("raises for the draft channel, which is coalesced and never refused (§2.3)", function()
		local playerRequestRateLimiter = createLimiterWithFakeClock()
		expect(function()
			playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, CHANNELS.SetRoundOutfitDraft)
		end).toThrow("SetRoundOutfitDraft is coalesced, never refused")
		expect(function()
			playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, CHANNELS.SetRoundOutfitDraft)
		end).toThrow("use readMillisecondsUntilOutfitDraftMayBeProcessed and recordOutfitDraftProcessed")
		expect(playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER)).toBe(0)
	end)

	it("raises for a player id that is not a number", function()
		local playerRequestRateLimiter = createLimiterWithFakeClock()
		expect(function()
			playerRequestRateLimiter:admitOrRefusePlayerRequest(
				tostring(PLAYER) :: any,
				CHANNELS.RequestJoinCurrentRound
			)
		end).toThrow("playerUserId must be a number")
	end)
end)

describe("PlayerRequestRateLimiter outfit drafts (spec §2.3 check 3)", function()
	it("lets a player's first draft be processed at once", function()
		local playerRequestRateLimiter = createLimiterWithFakeClock()
		expect(playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER)).toBe(0)
	end)

	it("reports the exact wait after a processed draft, reaching 0 at exactly 0.25 s", function()
		local playerRequestRateLimiter, fakeClock = createLimiterWithFakeClock()
		playerRequestRateLimiter:recordOutfitDraftProcessed(PLAYER)
		expect(playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER)).toBe(250)
		fakeClock:advanceBySeconds(0.1)
		expect(playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER)).toBe(150)
		fakeClock:advanceBySeconds(0.149)
		expect(playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER)).toBe(1)
		fakeClock:advanceBySeconds(0.001)
		expect(playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER)).toBe(0)
		fakeClock:advanceBySeconds(5)
		expect(playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER)).toBe(0)
	end)

	it("does not change anything by reading the wait", function()
		local playerRequestRateLimiter, fakeClock = createLimiterWithFakeClock()
		playerRequestRateLimiter:recordOutfitDraftProcessed(PLAYER)
		fakeClock:advanceBySeconds(0.2)
		playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER)
		fakeClock:advanceBySeconds(0.05)
		expect(playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER)).toBe(0)
	end)

	it("keeps draft timing per player and separate from every other channel", function()
		local playerRequestRateLimiter = createLimiterWithFakeClock()
		playerRequestRateLimiter:recordOutfitDraftProcessed(PLAYER)
		expect(playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(OTHER_PLAYER)).toBe(0)
		for _, channelName in listRefusableChannelNames() do
			expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(ALLOWED)
		end
		expect(playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER)).toBe(250)
	end)
end)

describe("PlayerRequestRateLimiter.forgetPlayer", function()
	it("lets a forgotten player start fresh on every channel and for drafts", function()
		local playerRequestRateLimiter = createLimiterWithFakeClock()
		for _, channelName in listRefusableChannelNames() do
			playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)
		end
		playerRequestRateLimiter:recordOutfitDraftProcessed(PLAYER)
		playerRequestRateLimiter:forgetPlayer(PLAYER)
		for _, channelName in listRefusableChannelNames() do
			expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(ALLOWED)
		end
		expect(playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER)).toBe(0)
	end)

	it("forgets only that player", function()
		local playerRequestRateLimiter = createLimiterWithFakeClock()
		local channelName = CHANNELS.RequestStylingItemOwnership
		playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)
		playerRequestRateLimiter:admitOrRefusePlayerRequest(OTHER_PLAYER, channelName)
		playerRequestRateLimiter:forgetPlayer(PLAYER)
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(OTHER_PLAYER, channelName)).toEqual(
			TOO_MANY_REQUESTS
		)
	end)

	it("holds nothing for players who have left, however many came and went", function()
		local playerRequestRateLimiter = createLimiterWithFakeClock()
		for playerUserId = 1, 500 do
			playerRequestRateLimiter:admitOrRefusePlayerRequest(playerUserId, CHANNELS.RequestJoinCurrentRound)
			playerRequestRateLimiter:recordOutfitDraftProcessed(playerUserId)
		end
		expect(playerRequestRateLimiter:countRememberedPlayers()).toBe(500)
		for playerUserId = 1, 500 do
			playerRequestRateLimiter:forgetPlayer(playerUserId)
		end
		expect(playerRequestRateLimiter:countRememberedPlayers()).toBe(0)
	end)

	it("tolerates forgetting a player it never saw", function()
		local playerRequestRateLimiter = createLimiterWithFakeClock()
		playerRequestRateLimiter:forgetPlayer(PLAYER)
		expect(playerRequestRateLimiter:countRememberedPlayers()).toBe(0)
	end)
end)
