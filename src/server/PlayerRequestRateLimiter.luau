-- PlayerRequestRateLimiter (development spec v1.3 §2.13): enforces a minimum interval per player
-- per request channel, so that nothing a device sends can push the game past Roblox's storage
-- limits (§3.6).
--
-- Calls no Roblox-specific interface. The clock is injected (see `new`).
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (the round referee and the server wiring are written from this)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- PlayerRequestRateLimiter.MINIMUM_REQUEST_INTERVAL_SECONDS_BY_REMOTE_CHANNEL_NAME
--   The §2.13 table (src/shared/RequestChannelMinimumIntervals, read by the device too):
--   { [remoteChannelName]: minimumIntervalSeconds } for exactly the channels in
--   RemoteNames.DEVICE_SENT_REMOTE_CHANNEL_NAME_SET (16 channels; no channel of
--   RemoteNames.SERVER_SENT_REMOTE_CHANNEL_NAME_SET is in it). Frozen. Reading a channel that is
--   not in it raises an error naming the channel.
-- PlayerRequestRateLimiter.OUTFIT_DRAFT_SERVER_PROCESSING_INTERVAL_SECONDS  (= 0.25, §2.3 check 3)
--   The `SetRoundOutfitDraft` entry of the table above, for the referee. Both are taken from
--   ThemedRoundProtocol.OUTFIT_DRAFT_SERVER_PROCESSING_INTERVAL_SECONDS (the value the device
--   shares), so the three can never differ.
--
-- PlayerRequestRateLimiter.new(dependencies) -> limiter
--   dependencies = {
--     clock: { getCurrentUnixMilliseconds: (self) -> number },
--         Whole milliseconds, so 0.25 s and 0.5 s intervals are exact. Should never move
--         backwards: while it reads earlier than a player's latest accepted request on a
--         channel, that channel stays refused for that player. A reading that is not a number,
--         or is NaN, raises.
--   }
--   Raises when `dependencies` or its clock is missing.
--
-- limiter:admitOrRefusePlayerRequest(playerUserId, remoteChannelName) -> RateLimitDecision
--   Call first, for every arriving request on every channel EXCEPT `SetRoundOutfitDraft`.
--   NOT a pure question: admitting a request records it, so asking twice can answer differently.
--   * Allowed when it is the player's first request on this channel, or when at least the
--     channel's minimum interval has passed since the player's latest ACCEPTED request on it
--     (exactly the interval is allowed). The current moment then becomes that latest accepted
--     request.
--   * Otherwise refused, and nothing changes: a refused request does not push the next allowed
--     moment further away.
--   Limits are independent per player and per channel.
--   Result: { isRequestAllowed = true }
--         | { isRequestAllowed = false, rejectionReason = "TooManyRequests" }
--         | { isRequestAllowed = false, rejectionReason = "TooManyAttempts" }   only RequestRedeemPromoCode (§2.10)
--   On refusal the caller answers `{ isAccepted = false, rejectionReason = <rejectionReason> }`
--   without looking at the request, or ignores the request if the channel has no answer.
--   Raises (a programming error) for: a channel not in the table (a typo, or a server -> device
--   channel); `SetRoundOutfitDraft` (drafts are coalesced, never refused: use the two draft
--   methods below); a playerUserId that is not a number.
--
-- Outfit drafts (§2.3 check 3: "at least 0.25 s since this player's previous draft was
-- processed"; a draft arriving sooner waits in the referee's one-place buffer, never refused):
-- limiter:readMillisecondsUntilOutfitDraftMayBeProcessed(playerUserId) -> number
--   0 when a draft may be processed now (no draft processed yet, or at least the interval has
--   passed since the last one); otherwise the whole milliseconds left to wait. Changes nothing.
--   If the clock has moved back before the last processed draft, the wait is longer than the
--   interval: until that moment plus 0.25 s.
--   The referee buffers the draft and schedules its processing after that many milliseconds
--   (divide by 1000 for a scheduler that takes seconds).
-- limiter:recordOutfitDraftProcessed(playerUserId)
--   Call each time the referee processes a draft (checks 4 onwards), including the waiting draft
--   processed at the end of `Styling`. Notes the current moment as the player's previous
--   processed draft.
--
-- limiter:forgetPlayer(playerUserId)
--   Call when a player leaves the server. Drops everything held for the player, so memory does
--   not grow over a long server session; a player who rejoins starts fresh.
-- limiter:countRememberedPlayers() -> number
--   How many players the limiter holds anything for (for tests and diagnostics).
--
-- Every method that takes a playerUserId raises when it is not a number.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local RemoteNames = require("../shared/RemoteNames")
local RequestChannelMinimumIntervals = require("../shared/RequestChannelMinimumIntervals")

local REMOTE_CHANNEL_NAMES = RemoteNames.REMOTE_CHANNEL_NAMES

export type RateLimitDecision = {
	isRequestAllowed: boolean,
	rejectionReason: string?,
}

export type PlayerRequestRateLimiterDependencies = {
	clock: { getCurrentUnixMilliseconds: (any) -> number },
}

local PlayerRequestRateLimiter = {}
PlayerRequestRateLimiter.__index = PlayerRequestRateLimiter

-- Spec §2.13, one entry per channel a device sends on. The table lives in
-- src/shared/RequestChannelMinimumIntervals.luau so that the device's request senders read the
-- very same numbers (one home, no copy); this is the same frozen table, not a copy of it.
PlayerRequestRateLimiter.MINIMUM_REQUEST_INTERVAL_SECONDS_BY_REMOTE_CHANNEL_NAME =
	RequestChannelMinimumIntervals.MINIMUM_REQUEST_INTERVAL_SECONDS_BY_REMOTE_CHANNEL_NAME

local OUTFIT_DRAFT_REMOTE_CHANNEL_NAME = REMOTE_CHANNEL_NAMES.SetRoundOutfitDraft
local PROMO_CODE_REMOTE_CHANNEL_NAME = REMOTE_CHANNEL_NAMES.RequestRedeemPromoCode

PlayerRequestRateLimiter.OUTFIT_DRAFT_SERVER_PROCESSING_INTERVAL_SECONDS =
	PlayerRequestRateLimiter.MINIMUM_REQUEST_INTERVAL_SECONDS_BY_REMOTE_CHANNEL_NAME[OUTFIT_DRAFT_REMOTE_CHANNEL_NAME]

local ALLOWED_DECISION: RateLimitDecision = table.freeze({ isRequestAllowed = true })
local REFUSED_WITH_TOO_MANY_REQUESTS_DECISION: RateLimitDecision =
	table.freeze({ isRequestAllowed = false, rejectionReason = "TooManyRequests" })
local REFUSED_WITH_TOO_MANY_ATTEMPTS_DECISION: RateLimitDecision =
	table.freeze({ isRequestAllowed = false, rejectionReason = "TooManyAttempts" })

export type PlayerRequestRateLimiter = typeof(setmetatable(
	{} :: {
		clock: { getCurrentUnixMilliseconds: (any) -> number },
		latestAcceptedUnixMillisecondsByRemoteChannelNameByPlayerUserId: { [number]: { [string]: number } },
	},
	PlayerRequestRateLimiter
))

-- Whole milliseconds, so that 0.25 s and 0.5 s compare exactly against a millisecond clock.
local function readMinimumIntervalMilliseconds(remoteChannelName: string): number
	local minimumIntervalSeconds =
		PlayerRequestRateLimiter.MINIMUM_REQUEST_INTERVAL_SECONDS_BY_REMOTE_CHANNEL_NAME[remoteChannelName]
	return math.round(minimumIntervalSeconds * 1000)
end

local function assertIsPlayerUserId(playerUserId: any)
	if type(playerUserId) ~= "number" then
		error(
			string.format("PlayerRequestRateLimiter: playerUserId must be a number, got %s", tostring(playerUserId)),
			3
		)
	end
end

function PlayerRequestRateLimiter.new(dependencies: PlayerRequestRateLimiterDependencies): PlayerRequestRateLimiter
	assert(type(dependencies) == "table" and dependencies.clock ~= nil, "PlayerRequestRateLimiter.new needs { clock }")
	return setmetatable({
		clock = dependencies.clock,
		latestAcceptedUnixMillisecondsByRemoteChannelNameByPlayerUserId = {},
	}, PlayerRequestRateLimiter)
end

local function readCurrentUnixMilliseconds(self: PlayerRequestRateLimiter): number
	local currentUnixMilliseconds = self.clock:getCurrentUnixMilliseconds()
	if type(currentUnixMilliseconds) ~= "number" or currentUnixMilliseconds ~= currentUnixMilliseconds then
		error("PlayerRequestRateLimiter: the clock must return a number of milliseconds", 3)
	end
	return currentUnixMilliseconds
end

local function recordLatestAcceptedUnixMilliseconds(
	self: PlayerRequestRateLimiter,
	playerUserId: number,
	remoteChannelName: string,
	acceptedUnixMilliseconds: number
)
	local latestAcceptedUnixMillisecondsByRemoteChannelName =
		self.latestAcceptedUnixMillisecondsByRemoteChannelNameByPlayerUserId[playerUserId]
	if latestAcceptedUnixMillisecondsByRemoteChannelName == nil then
		latestAcceptedUnixMillisecondsByRemoteChannelName = {}
		self.latestAcceptedUnixMillisecondsByRemoteChannelNameByPlayerUserId[playerUserId] =
			latestAcceptedUnixMillisecondsByRemoteChannelName
	end
	latestAcceptedUnixMillisecondsByRemoteChannelName[remoteChannelName] = acceptedUnixMilliseconds
end

-- 0 when the interval has passed (or nothing was accepted yet), otherwise the milliseconds left.
-- Reading the interval also validates the channel: an unknown channel raises, naming it.
local function readMillisecondsUntilIntervalHasPassed(
	self: PlayerRequestRateLimiter,
	playerUserId: number,
	remoteChannelName: string,
	currentUnixMilliseconds: number
): number
	local minimumIntervalMilliseconds = readMinimumIntervalMilliseconds(remoteChannelName)
	local latestAcceptedUnixMillisecondsByRemoteChannelName =
		self.latestAcceptedUnixMillisecondsByRemoteChannelNameByPlayerUserId[playerUserId]
	local latestAcceptedUnixMilliseconds = latestAcceptedUnixMillisecondsByRemoteChannelName
		and latestAcceptedUnixMillisecondsByRemoteChannelName[remoteChannelName]
	if latestAcceptedUnixMilliseconds == nil then
		return 0
	end
	return math.max(0, latestAcceptedUnixMilliseconds + minimumIntervalMilliseconds - currentUnixMilliseconds)
end

function PlayerRequestRateLimiter.admitOrRefusePlayerRequest(
	self: PlayerRequestRateLimiter,
	playerUserId: number,
	remoteChannelName: string
): RateLimitDecision
	assertIsPlayerUserId(playerUserId)
	readMinimumIntervalMilliseconds(remoteChannelName) -- an unknown channel raises here, naming it
	if remoteChannelName == OUTFIT_DRAFT_REMOTE_CHANNEL_NAME then
		error(
			"PlayerRequestRateLimiter: SetRoundOutfitDraft is coalesced, never refused (spec §2.3); use "
				.. "readMillisecondsUntilOutfitDraftMayBeProcessed and recordOutfitDraftProcessed",
			2
		)
	end

	local currentUnixMilliseconds = readCurrentUnixMilliseconds(self)
	local millisecondsLeft =
		readMillisecondsUntilIntervalHasPassed(self, playerUserId, remoteChannelName, currentUnixMilliseconds)
	if millisecondsLeft > 0 then
		if remoteChannelName == PROMO_CODE_REMOTE_CHANNEL_NAME then
			return REFUSED_WITH_TOO_MANY_ATTEMPTS_DECISION
		end
		return REFUSED_WITH_TOO_MANY_REQUESTS_DECISION
	end

	recordLatestAcceptedUnixMilliseconds(self, playerUserId, remoteChannelName, currentUnixMilliseconds)
	return ALLOWED_DECISION
end

function PlayerRequestRateLimiter.readMillisecondsUntilOutfitDraftMayBeProcessed(
	self: PlayerRequestRateLimiter,
	playerUserId: number
): number
	assertIsPlayerUserId(playerUserId)
	return readMillisecondsUntilIntervalHasPassed(
		self,
		playerUserId,
		OUTFIT_DRAFT_REMOTE_CHANNEL_NAME,
		readCurrentUnixMilliseconds(self)
	)
end

function PlayerRequestRateLimiter.recordOutfitDraftProcessed(self: PlayerRequestRateLimiter, playerUserId: number)
	assertIsPlayerUserId(playerUserId)
	recordLatestAcceptedUnixMilliseconds(
		self,
		playerUserId,
		OUTFIT_DRAFT_REMOTE_CHANNEL_NAME,
		readCurrentUnixMilliseconds(self)
	)
end

function PlayerRequestRateLimiter.forgetPlayer(self: PlayerRequestRateLimiter, playerUserId: number)
	assertIsPlayerUserId(playerUserId)
	self.latestAcceptedUnixMillisecondsByRemoteChannelNameByPlayerUserId[playerUserId] = nil
end

-- Lets tests check that forgetting really frees memory; not part of the request path.
function PlayerRequestRateLimiter.countRememberedPlayers(self: PlayerRequestRateLimiter): number
	local rememberedPlayerCount = 0
	for _ in self.latestAcceptedUnixMillisecondsByRemoteChannelNameByPlayerUserId do
		rememberedPlayerCount += 1
	end
	return rememberedPlayerCount
end

return table.freeze(PlayerRequestRateLimiter)
