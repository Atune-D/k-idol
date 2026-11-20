-- WardrobeCatalogSnapshotRequester (development spec §2.14 wardrobe catalog, §2.13 rate limits):
-- decides WHEN the device asks the server for the wardrobe catalog snapshot.
--   * It asks once at start, and again whenever WardrobeCatalogChanged arrives (§2.14 "A device then
--     asks for the snapshot again").
--   * While the answer says the catalog is not ready, or the request failed (no answer, refused,
--     TooManyRequests, a wrong shape), it asks again after RETRY_AFTER_SECONDS.
--   * Never more often than once per MINIMUM_REQUEST_INTERVAL_SECONDS (the server's limit for this
--     channel, §2.13: 2 s); an ask inside the interval waits for its end. At most one request is in
--     flight; a change arriving meanwhile asks again once the answer is in.
--   * A ready snapshot is handed to onWardrobeCatalogViewReady as a WardrobeCatalogView. A not-ready
--     answer is also handed on (the wardrobe then shows its loading notice).
-- Pure logic: clock, scheduler and the request function are injected.
--
-- PUBLIC API
--   WardrobeCatalogSnapshotRequester.MINIMUM_REQUEST_INTERVAL_SECONDS = 2   (read from src/shared/RequestChannelMinimumIntervals)
--   WardrobeCatalogSnapshotRequester.RETRY_AFTER_SECONDS = 3
--   WardrobeCatalogSnapshotRequester.new({ clock, scheduler, stylingItemByStylingItemKey,
--       requestWardrobeCatalogSnapshot(onAnswer(answer?)), onWardrobeCatalogViewReady(view) })
--   requester:start()
--   requester:receiveWardrobeCatalogChanged(message)   (any message: it only triggers an ask)
--   requester:readRequestCount() -> number   requests sent so far (for checks)

local WardrobeCatalogView = require("./WardrobeCatalogView")
local RequestChannelMinimumIntervals = require("../shared/RequestChannelMinimumIntervals")

local WardrobeCatalogSnapshotRequester = {}
WardrobeCatalogSnapshotRequester.__index = WardrobeCatalogSnapshotRequester

-- The server's limit for this channel, read from the one shared table (spec §2.13).
WardrobeCatalogSnapshotRequester.MINIMUM_REQUEST_INTERVAL_SECONDS =
	RequestChannelMinimumIntervals.readMinimumRequestIntervalSeconds("RequestWardrobeCatalogSnapshot")
WardrobeCatalogSnapshotRequester.RETRY_AFTER_SECONDS = 3

function WardrobeCatalogSnapshotRequester.new(dependencies)
	return setmetatable({
		clock = dependencies.clock,
		scheduler = dependencies.scheduler,
		stylingItemByStylingItemKey = dependencies.stylingItemByStylingItemKey,
		requestWardrobeCatalogSnapshot = dependencies.requestWardrobeCatalogSnapshot,
		onWardrobeCatalogViewReady = dependencies.onWardrobeCatalogViewReady,
		isRequestInFlight = false,
		isAskWanted = false,
		cancelWaitingAsk = nil,
		lastRequestAtUnixMilliseconds = nil,
		requestCount = 0,
	}, WardrobeCatalogSnapshotRequester)
end

function WardrobeCatalogSnapshotRequester:receiveAnswer(answer: any)
	self.isRequestInFlight = false
	local view = WardrobeCatalogView.buildWardrobeCatalogView(answer, self.stylingItemByStylingItemKey)
	if view ~= nil then
		self.onWardrobeCatalogViewReady(view)
	end
	if view == nil or not view.isWardrobeCatalogReady then
		self.cancelRetry = self.scheduler:scheduleCallbackAfterSeconds(
			WardrobeCatalogSnapshotRequester.RETRY_AFTER_SECONDS,
			function()
				self.cancelRetry = nil
				self:askWhenAllowed()
			end
		)
	end
	if self.isAskWanted then
		self:askWhenAllowed()
	end
end

function WardrobeCatalogSnapshotRequester:sendRequestNow()
	self.isAskWanted = false
	self.isRequestInFlight = true
	self.requestCount += 1
	self.lastRequestAtUnixMilliseconds = self.clock:getCurrentUnixMilliseconds()
	self.requestWardrobeCatalogSnapshot(function(answer)
		self:receiveAnswer(answer)
	end)
end

function WardrobeCatalogSnapshotRequester:askWhenAllowed()
	self.isAskWanted = true
	if self.isRequestInFlight or self.cancelWaitingAsk ~= nil then
		return
	end
	if self.cancelRetry ~= nil then
		self.cancelRetry()
		self.cancelRetry = nil
	end
	local lastRequestAt = self.lastRequestAtUnixMilliseconds
	local waitMilliseconds = if lastRequestAt == nil
		then 0
		else lastRequestAt
			+ WardrobeCatalogSnapshotRequester.MINIMUM_REQUEST_INTERVAL_SECONDS * 1000
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

function WardrobeCatalogSnapshotRequester:start()
	self:askWhenAllowed()
end

function WardrobeCatalogSnapshotRequester:receiveWardrobeCatalogChanged(_message: any)
	self:askWhenAllowed()
end

function WardrobeCatalogSnapshotRequester:readRequestCount(): number
	return self.requestCount
end

return WardrobeCatalogSnapshotRequester
