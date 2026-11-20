-- The request rate limiter's promises about its clock and its arguments (header of
-- src/server/PlayerRequestRateLimiter.luau): a clock moving backwards, a broken clock, missing
-- dependencies, and player ids that are not numbers.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local BackwardsMovableFakeClock = require("../Support/BackwardsMovableFakeClock")
local RemoteNames = require("../../src/shared/RemoteNames")
local PlayerRequestRateLimiter = require("../../src/server/PlayerRequestRateLimiter")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local CHANNELS = RemoteNames.REMOTE_CHANNEL_NAMES

local PLAYER = 1001
local EXAMPLE_STARTING_UNIX_MILLISECONDS = 1_800_000_000_000

local ALLOWED = { isRequestAllowed = true }
local TOO_MANY_REQUESTS = { isRequestAllowed = false, rejectionReason = "TooManyRequests" }
local TOO_MANY_ATTEMPTS = { isRequestAllowed = false, rejectionReason = "TooManyAttempts" }

local function createLimiterWithBackwardsMovableClock()
	local backwardsMovableFakeClock = BackwardsMovableFakeClock.new(EXAMPLE_STARTING_UNIX_MILLISECONDS)
	local playerRequestRateLimiter = PlayerRequestRateLimiter.new({ clock = backwardsMovableFakeClock })
	return playerRequestRateLimiter, backwardsMovableFakeClock
end

local function createLimiterWithClockReading(clockReading: any)
	return PlayerRequestRateLimiter.new({
		clock = {
			getCurrentUnixMilliseconds = function()
				return clockReading
			end,
		},
	})
end

describe("PlayerRequestRateLimiter when the clock moves backwards", function()
	it("keeps a channel refused while the clock reads earlier than the latest accepted request", function()
		local playerRequestRateLimiter, backwardsMovableFakeClock = createLimiterWithBackwardsMovableClock()
		local channelName = CHANNELS.RequestJoinCurrentRound -- 1 s
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(ALLOWED)
		-- Back by far more than one interval, then by just 1 ms short of the accepted moment.
		backwardsMovableFakeClock:moveByMilliseconds(-60_000)
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(TOO_MANY_REQUESTS)
		backwardsMovableFakeClock:moveByMilliseconds(59_999)
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(TOO_MANY_REQUESTS)
		-- The refusals changed nothing: allowed again at exactly one interval after the accepted moment.
		backwardsMovableFakeClock:moveByMilliseconds(1_000)
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(TOO_MANY_REQUESTS)
		backwardsMovableFakeClock:moveByMilliseconds(1)
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(ALLOWED)
	end)

	it("answers TooManyAttempts on the promo code channel after the clock moved back", function()
		local playerRequestRateLimiter, backwardsMovableFakeClock = createLimiterWithBackwardsMovableClock()
		local channelName = CHANNELS.RequestRedeemPromoCode
		playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)
		backwardsMovableFakeClock:moveByMilliseconds(-3_600_000)
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, channelName)).toEqual(TOO_MANY_ATTEMPTS)
	end)

	it("reports a draft wait until the last processed draft plus 0.25 s when the clock moved back", function()
		local playerRequestRateLimiter, backwardsMovableFakeClock = createLimiterWithBackwardsMovableClock()
		playerRequestRateLimiter:recordOutfitDraftProcessed(PLAYER)
		backwardsMovableFakeClock:moveByMilliseconds(-10_000)
		expect(playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER)).toBe(10_250)
		backwardsMovableFakeClock:moveByMilliseconds(10_249)
		expect(playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER)).toBe(1)
		backwardsMovableFakeClock:moveByMilliseconds(1)
		expect(playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER)).toBe(0)
	end)
end)

describe("PlayerRequestRateLimiter clock and dependency checks", function()
	it("raises when created without dependencies or without a clock", function()
		expect(function()
			PlayerRequestRateLimiter.new(nil :: any)
		end).toThrow("PlayerRequestRateLimiter.new needs { clock }")
		expect(function()
			PlayerRequestRateLimiter.new({} :: any)
		end).toThrow("PlayerRequestRateLimiter.new needs { clock }")
	end)

	it("raises on every path that reads a clock returning something other than a number", function()
		for _, brokenClockReading in { "1800000000000", true, 0 / 0 } do
			local playerRequestRateLimiter = createLimiterWithClockReading(brokenClockReading)
			expect(function()
				playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, CHANNELS.RequestJoinCurrentRound)
			end).toThrow("the clock must return a number of milliseconds")
			expect(function()
				playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(PLAYER)
			end).toThrow("the clock must return a number of milliseconds")
			expect(function()
				playerRequestRateLimiter:recordOutfitDraftProcessed(PLAYER)
			end).toThrow("the clock must return a number of milliseconds")
			expect(playerRequestRateLimiter:countRememberedPlayers()).toBe(0)
		end
	end)

	it("accepts a clock reading that is a number", function()
		local playerRequestRateLimiter = createLimiterWithClockReading(EXAMPLE_STARTING_UNIX_MILLISECONDS)
		expect(playerRequestRateLimiter:admitOrRefusePlayerRequest(PLAYER, CHANNELS.RequestJoinCurrentRound)).toEqual(
			ALLOWED
		)
	end)
end)

describe("PlayerRequestRateLimiter player id checks", function()
	-- Each method is tried with ids that are not numbers; each must raise and remember nothing.
	local methodCallByMethodName = {
		admitOrRefusePlayerRequest = function(playerRequestRateLimiter, playerUserId)
			playerRequestRateLimiter:admitOrRefusePlayerRequest(playerUserId, CHANNELS.RequestJoinCurrentRound)
		end,
		readMillisecondsUntilOutfitDraftMayBeProcessed = function(playerRequestRateLimiter, playerUserId)
			playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(playerUserId)
		end,
		recordOutfitDraftProcessed = function(playerRequestRateLimiter, playerUserId)
			playerRequestRateLimiter:recordOutfitDraftProcessed(playerUserId)
		end,
		forgetPlayer = function(playerRequestRateLimiter, playerUserId)
			playerRequestRateLimiter:forgetPlayer(playerUserId)
		end,
	}

	for methodName, callMethod in methodCallByMethodName do
		it(string.format("%s raises for a player id that is not a number", methodName), function()
			local playerRequestRateLimiter = PlayerRequestRateLimiter.new({ clock = FakeClock.new(1_800_000_000) })
			for _, invalidPlayerUserId in { tostring(PLAYER), true, { PLAYER } } do
				expect(function()
					callMethod(playerRequestRateLimiter, invalidPlayerUserId)
				end).toThrow("playerUserId must be a number")
			end
			expect(playerRequestRateLimiter:countRememberedPlayers()).toBe(0)
		end)
	end
end)
