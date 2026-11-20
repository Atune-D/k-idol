-- Runs the resolver's Marketplace item lookups with a cap on how many are in flight at once and
-- with spaced retries (development spec §2.14: "retrying a failed lookup up to 3 times before
-- hiding the item").
--
-- One lookup = one first attempt plus at most MAXIMUM_RETRY_COUNT retries, so at most four
-- attempts. Retry n waits RETRY_DELAY_SECONDS_BY_RETRY_NUMBER[n] seconds (2, 4, 8) through the
-- injected scheduler, so tests never wait. A waiting retry does not count as in flight.
--
-- An attempt that has not answered within LOOKUP_ATTEMPT_TIMEOUT_SECONDS (a value the spec does
-- not give) counts as a failed attempt, so a Roblox call that hangs is retried and, after the
-- last attempt, the item is hidden instead of the catalog never becoming ready. The timer starts
-- when the attempt gets an in-flight slot and is cancelled when the attempt answers. A late
-- answer to a timed-out attempt is ignored like any second call, so a slot is freed exactly once.
--
-- An attempt is a function `startLookupAttempt(onAttemptFinished)` that must return at once and
-- call `onAttemptFinished(wasAttemptSuccessful, lookupAnswer, lookupErrorMessage)` exactly once,
-- before or after returning. Only `wasAttemptSuccessful == true` counts as success; any other
-- value (false, nil, a truthy non-boolean) is a failed attempt. A second call is ignored; an
-- attempt that raises while starting counts as a failed attempt (unless it had already reported
-- finishing).
-- Pure logic: no Roblox-specific interface is used.

local MarketplaceItemLookupRetryQueue = {}
MarketplaceItemLookupRetryQueue.__index = MarketplaceItemLookupRetryQueue

MarketplaceItemLookupRetryQueue.MAXIMUM_RETRY_COUNT = 3
MarketplaceItemLookupRetryQueue.RETRY_DELAY_SECONDS_BY_RETRY_NUMBER = table.freeze({ 2, 4, 8 })
MarketplaceItemLookupRetryQueue.MAXIMUM_LOOKUP_ATTEMPTS_IN_FLIGHT = 10
MarketplaceItemLookupRetryQueue.LOOKUP_ATTEMPT_TIMEOUT_SECONDS = 15

export type LookupAttemptFinishedCallback = (
	wasAttemptSuccessful: boolean,
	lookupAnswer: any,
	lookupErrorMessage: string?
) -> ()

export type LookupSettledCallback = (
	wasLookupSuccessful: boolean,
	lookupAnswer: any,
	lastLookupErrorMessage: string?,
	attemptCount: number
) -> ()

function MarketplaceItemLookupRetryQueue.new(scheduler)
	if scheduler == nil then
		error("MarketplaceItemLookupRetryQueue.new: missing scheduler", 2)
	end
	return setmetatable({
		scheduler = scheduler,
		lookupAttemptsWaitingForSlot = {} :: { () -> () },
		lookupAttemptsInFlightCount = 0,
		isStartingWaitingAttempts = false,
	}, MarketplaceItemLookupRetryQueue)
end

-- Starts waiting attempts while there is room. Re-entrant calls (an attempt that finishes inside
-- its own start call) return at once; the outer loop picks up the freed slot, so a pool of
-- lookups that all finish immediately never builds a deep call stack.
local function startWaitingAttemptsWhileSlotsAreFree(self)
	if self.isStartingWaitingAttempts then
		return
	end
	self.isStartingWaitingAttempts = true
	while
		self.lookupAttemptsInFlightCount < MarketplaceItemLookupRetryQueue.MAXIMUM_LOOKUP_ATTEMPTS_IN_FLIGHT
		and #self.lookupAttemptsWaitingForSlot > 0
	do
		local nextLookupAttempt = table.remove(self.lookupAttemptsWaitingForSlot, 1)
		self.lookupAttemptsInFlightCount += 1
		nextLookupAttempt()
	end
	self.isStartingWaitingAttempts = false
end

-- Queues one lookup. `onLookupSettled` is called exactly once: with the answer of the first
-- successful attempt, or with failure after the last retry failed.
function MarketplaceItemLookupRetryQueue:runLookupWithRetries(
	startLookupAttempt: (
		onAttemptFinished: LookupAttemptFinishedCallback
	) -> (),
	onLookupSettled: LookupSettledCallback
)
	local attemptCount = 0

	local function queueAttempt()
		attemptCount += 1
		local thisAttemptNumber = attemptCount
		local hasThisAttemptFinished = false
		local cancelAttemptTimeout: (() -> ())? = nil

		local function onAttemptFinished(wasAttemptSuccessful: boolean, lookupAnswer: any, lookupErrorMessage: string?)
			if hasThisAttemptFinished then
				return
			end
			hasThisAttemptFinished = true
			if cancelAttemptTimeout ~= nil then
				cancelAttemptTimeout()
				cancelAttemptTimeout = nil
			end
			self.lookupAttemptsInFlightCount -= 1
			if wasAttemptSuccessful == true then
				onLookupSettled(true, lookupAnswer, nil, thisAttemptNumber)
			elseif thisAttemptNumber > MarketplaceItemLookupRetryQueue.MAXIMUM_RETRY_COUNT then
				onLookupSettled(false, nil, lookupErrorMessage, thisAttemptNumber)
			else
				local retryDelaySeconds =
					MarketplaceItemLookupRetryQueue.RETRY_DELAY_SECONDS_BY_RETRY_NUMBER[thisAttemptNumber]
				self.scheduler:scheduleCallbackAfterSeconds(retryDelaySeconds, queueAttempt)
			end
			startWaitingAttemptsWhileSlotsAreFree(self)
		end

		table.insert(self.lookupAttemptsWaitingForSlot, function()
			-- Scheduled before starting, so an attempt that answers inside its start call cancels it.
			cancelAttemptTimeout = self.scheduler:scheduleCallbackAfterSeconds(
				MarketplaceItemLookupRetryQueue.LOOKUP_ATTEMPT_TIMEOUT_SECONDS,
				function()
					cancelAttemptTimeout = nil -- it has run; never cancel it afterwards
					onAttemptFinished(
						false,
						nil,
						string.format(
							"no answer within %d seconds",
							MarketplaceItemLookupRetryQueue.LOOKUP_ATTEMPT_TIMEOUT_SECONDS
						)
					)
				end
			)
			local didStart, startError = pcall(startLookupAttempt, onAttemptFinished)
			if not didStart then
				onAttemptFinished(false, nil, "the lookup raised while starting: " .. tostring(startError))
			end
		end)
		startWaitingAttemptsWhileSlotsAreFree(self)
	end

	queueAttempt()
end

function MarketplaceItemLookupRetryQueue:countLookupAttemptsInFlight(): number
	return self.lookupAttemptsInFlightCount
end

return MarketplaceItemLookupRetryQueue
