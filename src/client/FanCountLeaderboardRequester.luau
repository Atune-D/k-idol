-- FanCountLeaderboardRequester (development spec §1.11 fan leaderboard, §2.11, §2.13): decides when
-- the device asks RequestFanCountLeaderboardTopEntries and turns the answer into panel rows.
--   * The device never asks more often than once per MINIMUM_REQUEST_INTERVAL_SECONDS (5 s, the
--     server's limit for this channel, §2.13), and never while a request is in flight. An ask
--     inside the interval is not refused: it is sent when the interval ends (one waiting ask at
--     most), so a tap on "Refresh" always leads to fresh rows.
--   * The server refreshes its cache every 60 s (§1.11), so the panel asks when it is opened and when
--     the player taps Refresh; it does not poll.
--   * Rows: the server's entries in its order (rank, name, fans), at most 100. The local player's
--     line says their rank when they are in the list, otherwise "You are outside the top 100"
--     (§1.11: an ordered data store cannot tell a rank beyond the top). A refused or failed answer
--     keeps the previous rows and says the list could not be loaded.
-- Pure logic: clock, scheduler and the request function are injected.
--
-- PUBLIC API
--   FanCountLeaderboardRequester.MINIMUM_REQUEST_INTERVAL_SECONDS = 5   (read from src/shared/RequestChannelMinimumIntervals)
--   FanCountLeaderboardRequester.MAXIMUM_SHOWN_ENTRY_COUNT = 100
--   FanCountLeaderboardRequester.new({ clock, scheduler, localPlayerUserId,
--       requestFanCountLeaderboardTopEntries(onAnswer(answer?)), onLeaderboardPanelChanged() })
--   requester:askForTopEntries()
--   requester:readLeaderboardPanelModel() -> { rows = { { rankText, playerNameText, fanCountText,
--       isLocalPlayer } }, localPlayerRankText, statusText }
--   requester:readRequestCount() -> number

local PlayerFacingTexts = require("./PlayerFacingTexts")
local RequestChannelMinimumIntervals = require("../shared/RequestChannelMinimumIntervals")

local FanCountLeaderboardRequester = {}
FanCountLeaderboardRequester.__index = FanCountLeaderboardRequester

-- The server's limit for this channel, read from the one shared table (spec §2.13).
FanCountLeaderboardRequester.MINIMUM_REQUEST_INTERVAL_SECONDS =
	RequestChannelMinimumIntervals.readMinimumRequestIntervalSeconds("RequestFanCountLeaderboardTopEntries")
FanCountLeaderboardRequester.MAXIMUM_SHOWN_ENTRY_COUNT = 100

local function isFiniteNumber(candidate: any): boolean
	return type(candidate) == "number" and candidate == candidate and math.abs(candidate) ~= math.huge
end

local function readLeaderboardEntries(answer: any)
	if type(answer) ~= "table" or answer.isAccepted ~= true or type(answer.leaderboardEntries) ~= "table" then
		return nil
	end
	local entries = {}
	for listPosition = 1, math.min(#answer.leaderboardEntries, FanCountLeaderboardRequester.MAXIMUM_SHOWN_ENTRY_COUNT) do
		local entry = answer.leaderboardEntries[listPosition]
		if
			type(entry) ~= "table"
			or not isFiniteNumber(entry.leaderboardRank)
			or not isFiniteNumber(entry.playerUserId)
			or not isFiniteNumber(entry.fanCount)
			or type(entry.playerDisplayName) ~= "string"
		then
			return nil
		end
		table.insert(entries, entry)
	end
	return entries
end

function FanCountLeaderboardRequester.new(dependencies)
	return setmetatable({
		clock = dependencies.clock,
		scheduler = dependencies.scheduler,
		localPlayerUserId = dependencies.localPlayerUserId,
		requestFanCountLeaderboardTopEntries = dependencies.requestFanCountLeaderboardTopEntries,
		onLeaderboardPanelChanged = dependencies.onLeaderboardPanelChanged,
		isRequestInFlight = false,
		isAskWaiting = false,
		cancelWaitingAsk = nil,
		lastRequestAtUnixMilliseconds = nil,
		requestCount = 0,
		leaderboardEntries = nil,
		statusText = "Loading the leaderboard...",
	}, FanCountLeaderboardRequester)
end

function FanCountLeaderboardRequester:notifyPanelChanged()
	if self.onLeaderboardPanelChanged ~= nil then
		self.onLeaderboardPanelChanged()
	end
end

function FanCountLeaderboardRequester:receiveAnswer(answer: any)
	self.isRequestInFlight = false
	local entries = readLeaderboardEntries(answer)
	if entries ~= nil then
		self.leaderboardEntries = entries
		self.statusText = if #entries == 0 then "Nobody is on the leaderboard yet." else ""
	else
		self.statusText = "The leaderboard could not be loaded. Try again soon."
	end
	self:notifyPanelChanged()
	if self.isAskWaiting then
		self:askForTopEntries()
	end
end

function FanCountLeaderboardRequester:sendRequestNow()
	self.isAskWaiting = false
	self.isRequestInFlight = true
	self.requestCount += 1
	self.lastRequestAtUnixMilliseconds = self.clock:getCurrentUnixMilliseconds()
	self.requestFanCountLeaderboardTopEntries(function(answer)
		self:receiveAnswer(answer)
	end)
end

function FanCountLeaderboardRequester:askForTopEntries()
	self.isAskWaiting = true
	if self.isRequestInFlight or self.cancelWaitingAsk ~= nil then
		return
	end
	local lastRequestAt = self.lastRequestAtUnixMilliseconds
	local waitMilliseconds = if lastRequestAt == nil
		then 0
		else lastRequestAt
			+ FanCountLeaderboardRequester.MINIMUM_REQUEST_INTERVAL_SECONDS * 1000
			- self.clock:getCurrentUnixMilliseconds()
	if waitMilliseconds <= 0 then
		self:sendRequestNow()
		return
	end
	self.cancelWaitingAsk = self.scheduler:scheduleCallbackAfterSeconds(waitMilliseconds / 1000, function()
		self.cancelWaitingAsk = nil
		if not self.isRequestInFlight then
			self:sendRequestNow()
		end
	end)
end

function FanCountLeaderboardRequester:readLeaderboardPanelModel()
	local rows = {}
	local localPlayerRankText = PlayerFacingTexts.OUTSIDE_LEADERBOARD_TOP_NOTICE
	for _, entry in self.leaderboardEntries or {} do
		local isLocalPlayer = entry.playerUserId == self.localPlayerUserId
		table.insert(rows, {
			rankText = string.format("#%d", entry.leaderboardRank),
			playerNameText = entry.playerDisplayName,
			fanCountText = PlayerFacingTexts.formatWholeNumber(entry.fanCount) .. " fans",
			isLocalPlayer = isLocalPlayer,
		})
		if isLocalPlayer then
			localPlayerRankText = string.format("You are #%d.", entry.leaderboardRank)
		end
	end
	if self.leaderboardEntries == nil then
		localPlayerRankText = ""
	end
	return { rows = rows, localPlayerRankText = localPlayerRankText, statusText = self.statusText }
end

function FanCountLeaderboardRequester:readRequestCount(): number
	return self.requestCount
end

return FanCountLeaderboardRequester
