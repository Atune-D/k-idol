-- Randomized tests for the request rate limiter (development spec §2.13, §2.3 check 3).
-- Every failure names the random seed; rerun with IDOLGROW_RANDOM_TEST_SEED=<seed> to repeat it
-- (see tests/fixtures/SeededRandomTrials.luau).

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local BackwardsMovableFakeClock = require("../Support/BackwardsMovableFakeClock")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local RemoteNames = require("../../src/shared/RemoteNames")
local PlayerRequestRateLimiter = require("../../src/server/PlayerRequestRateLimiter")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local RANDOM_TRIAL_COUNT = 200
local EVENTS_PER_TRIAL = 300
local DRAFT_INTERVAL_MILLISECONDS = 250

local CHANNELS = RemoteNames.REMOTE_CHANNEL_NAMES

-- Spec §2.13 intervals in whole milliseconds, copied by hand (draft channel handled apart).
local SPEC_INTERVAL_MILLISECONDS_BY_REFUSABLE_CHANNEL = {
	RequestWardrobeCatalogSnapshot = 2000,
	RequestStylingItemOwnership = 500,
	RequestJoinCurrentRound = 1000,
	SetLobbyOutfit = 2000,
	RequestEquipDance = 1000,
	RequestEquipCosmetic = 1000,
	RequestPurchaseDanceWithStarCoins = 1000,
	RequestPurchaseCosmeticWithStarCoins = 1000,
	RequestClaimPlaytimeMilestone = 1000,
	RequestClaimDailyQuestReward = 1000,
	RequestStartDanceInLobby = 500,
	RequestSyncDanceWithPlayer = 500,
	RequestStopDanceInLobby = 500,
	RequestRedeemPromoCode = 2000,
	RequestFanCountLeaderboardTopEntries = 5000,
}

local REFUSABLE_CHANNEL_NAMES = {}
for channelName in SPEC_INTERVAL_MILLISECONDS_BY_REFUSABLE_CHANNEL do
	table.insert(REFUSABLE_CHANNEL_NAMES, channelName)
end
table.sort(REFUSABLE_CHANNEL_NAMES)

-- Clock moves biased towards the interesting edges: 0, just before, exactly at and just after an
-- interval, and now and then backwards by up to three intervals (the limiter promises to keep
-- refusing while the clock reads earlier than the latest accepted request).
local function pickRandomClockMoveMilliseconds(seededRandomNumberGenerator): number
	local edgeIntervalMilliseconds = seededRandomNumberGenerator.pickRandomListElement({ 250, 500, 1000, 2000, 5000 })
	local advanceKind = seededRandomNumberGenerator.nextWholeNumberInRange(1, 7)
	if advanceKind == 6 then
		return -seededRandomNumberGenerator.nextWholeNumberInRange(1, 3 * edgeIntervalMilliseconds)
	elseif advanceKind == 1 then
		return 0
	elseif advanceKind == 2 then
		return edgeIntervalMilliseconds - 1
	elseif advanceKind == 3 then
		return edgeIntervalMilliseconds
	elseif advanceKind == 4 then
		return edgeIntervalMilliseconds + 1
	end
	return seededRandomNumberGenerator.nextWholeNumberInRange(0, 1200)
end

-- The obviously correct model: per player, per channel, the moment of the latest accepted request.
local function createSimpleRateLimitModel()
	local latestAcceptedMillisecondsByModelKey = {}
	local simpleRateLimitModel = {}

	function simpleRateLimitModel.decideRequest(playerUserId, channelName, currentMilliseconds)
		local modelKey = tostring(playerUserId) .. "/" .. channelName
		local latestAcceptedMilliseconds = latestAcceptedMillisecondsByModelKey[modelKey]
		local intervalMilliseconds = SPEC_INTERVAL_MILLISECONDS_BY_REFUSABLE_CHANNEL[channelName]
		if
			latestAcceptedMilliseconds ~= nil
			and currentMilliseconds - latestAcceptedMilliseconds < intervalMilliseconds
		then
			local rejectionReason = if channelName == CHANNELS.RequestRedeemPromoCode
				then "TooManyAttempts"
				else "TooManyRequests"
			return { isRequestAllowed = false, rejectionReason = rejectionReason }
		end
		latestAcceptedMillisecondsByModelKey[modelKey] = currentMilliseconds
		return { isRequestAllowed = true }
	end

	function simpleRateLimitModel.readDraftWait(playerUserId, currentMilliseconds)
		local latestProcessedMilliseconds = latestAcceptedMillisecondsByModelKey[tostring(playerUserId) .. "/draft"]
		if latestProcessedMilliseconds == nil then
			return 0
		end
		return math.max(0, latestProcessedMilliseconds + DRAFT_INTERVAL_MILLISECONDS - currentMilliseconds)
	end

	function simpleRateLimitModel.recordDraftProcessed(playerUserId, currentMilliseconds)
		latestAcceptedMillisecondsByModelKey[tostring(playerUserId) .. "/draft"] = currentMilliseconds
	end

	function simpleRateLimitModel.forgetPlayer(playerUserId)
		local playerKeyPrefix = tostring(playerUserId) .. "/"
		for modelKey in latestAcceptedMillisecondsByModelKey do
			if string.sub(modelKey, 1, #playerKeyPrefix) == playerKeyPrefix then
				latestAcceptedMillisecondsByModelKey[modelKey] = nil
			end
		end
	end

	return simpleRateLimitModel
end

describe("PlayerRequestRateLimiter randomized", function()
	it(
		"agrees with a simple model for random request times (some backwards), players, channels and departures",
		function()
			SeededRandomTrials.runSeededRandomTrials(RANDOM_TRIAL_COUNT, function(seededRandomNumberGenerator)
				local fakeClock = BackwardsMovableFakeClock.new(
					seededRandomNumberGenerator.nextWholeNumberInRange(1, 2_000_000_000) * 1000
				)
				local playerRequestRateLimiter = PlayerRequestRateLimiter.new({ clock = fakeClock })
				local simpleRateLimitModel = createSimpleRateLimitModel()
				local playerUserIds = {}
				for _ = 1, seededRandomNumberGenerator.nextWholeNumberInRange(1, 4) do
					table.insert(playerUserIds, seededRandomNumberGenerator.nextWholeNumberInRange(1, 9_000_000_000))
				end
				-- A few channels only, so that requests on one channel often fall inside its interval.
				local trialChannelNames = table.clone(REFUSABLE_CHANNEL_NAMES)
				seededRandomNumberGenerator.shuffleListInPlace(trialChannelNames)
				trialChannelNames =
					{ table.unpack(trialChannelNames, 1, seededRandomNumberGenerator.nextWholeNumberInRange(1, 4)) }
				if seededRandomNumberGenerator.nextWholeNumberInRange(1, 2) == 1 then
					table.insert(trialChannelNames, CHANNELS.RequestRedeemPromoCode)
				end

				for eventNumber = 1, EVENTS_PER_TRIAL do
					fakeClock:moveByMilliseconds(pickRandomClockMoveMilliseconds(seededRandomNumberGenerator))
					local currentMilliseconds = fakeClock:getCurrentUnixMilliseconds()
					local playerUserId = seededRandomNumberGenerator.pickRandomListElement(playerUserIds)
					local eventKind = seededRandomNumberGenerator.nextWholeNumberInRange(1, 20)
					local eventLabel =
						string.format("event %d (player %d at %d ms)", eventNumber, playerUserId, currentMilliseconds)
					if eventKind == 1 then
						playerRequestRateLimiter:forgetPlayer(playerUserId)
						simpleRateLimitModel.forgetPlayer(playerUserId)
					elseif eventKind <= 5 then
						local draftWaitMilliseconds =
							playerRequestRateLimiter:readMillisecondsUntilOutfitDraftMayBeProcessed(playerUserId)
						expect({ eventLabel, draftWaitMilliseconds }).toEqual({
							eventLabel,
							simpleRateLimitModel.readDraftWait(playerUserId, currentMilliseconds),
						})
						-- The referee processes when the wait is 0; at the end of Styling it processes anyway.
						if draftWaitMilliseconds == 0 or eventKind == 5 then
							playerRequestRateLimiter:recordOutfitDraftProcessed(playerUserId)
							simpleRateLimitModel.recordDraftProcessed(playerUserId, currentMilliseconds)
						end
					else
						local channelName = seededRandomNumberGenerator.pickRandomListElement(trialChannelNames)
						expect({
							eventLabel,
							channelName,
							playerRequestRateLimiter:admitOrRefusePlayerRequest(playerUserId, channelName),
						}).toEqual({
							eventLabel,
							channelName,
							simpleRateLimitModel.decideRequest(playerUserId, channelName, currentMilliseconds),
						})
					end
				end
			end)
		end
	)

	it("never accepts more than one request per interval on a channel, however fast a device sends", function()
		SeededRandomTrials.runSeededRandomTrials(RANDOM_TRIAL_COUNT, function(seededRandomNumberGenerator)
			local fakeClock = FakeClock.new(seededRandomNumberGenerator.nextWholeNumberInRange(1, 2_000_000_000))
			local playerRequestRateLimiter = PlayerRequestRateLimiter.new({ clock = fakeClock })
			local channelName = seededRandomNumberGenerator.pickRandomListElement(REFUSABLE_CHANNEL_NAMES)
			local intervalMilliseconds = SPEC_INTERVAL_MILLISECONDS_BY_REFUSABLE_CHANNEL[channelName]
			local acceptedRequestMilliseconds = {}
			for _ = 1, EVENTS_PER_TRIAL do
				fakeClock:advanceBySeconds(
					seededRandomNumberGenerator.nextWholeNumberInRange(0, intervalMilliseconds) / 1000
				)
				local rateLimitDecision = playerRequestRateLimiter:admitOrRefusePlayerRequest(1, channelName)
				if rateLimitDecision.isRequestAllowed then
					table.insert(acceptedRequestMilliseconds, fakeClock:getCurrentUnixMilliseconds())
				end
			end
			expect(#acceptedRequestMilliseconds > 0).toBeTrue()
			for acceptedPosition = 2, #acceptedRequestMilliseconds do
				local gapMilliseconds = acceptedRequestMilliseconds[acceptedPosition]
					- acceptedRequestMilliseconds[acceptedPosition - 1]
				expect({ channelName, gapMilliseconds >= intervalMilliseconds }).toEqual({ channelName, true })
			end
		end)
	end)
end)
