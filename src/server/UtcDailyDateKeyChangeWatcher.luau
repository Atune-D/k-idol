-- Tells its owner when the UTC calendar date (`dailyDateKey`, development spec v1.3 §1.8) changes
-- while the server runs, so that "today's" content can be recomputed for players who are online.
--
-- Calls no Roblox-specific interface. The clock and the scheduler are injected.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- UtcDailyDateKeyChangeWatcher.CHECK_RETRY_DELAY_SECONDS = 60
--
-- UtcDailyDateKeyChangeWatcher.new(dependencies) -> watcher
--   dependencies = {
--     clock: { getCurrentUnixSeconds: (self) -> number },
--     scheduler: { scheduleCallbackAfterSeconds: (self, delaySeconds, callback) -> cancelCallback },
--     logger: { logInformation: (self, message: string) -> (), logWarning: (self, message: string) -> () },
--   }
--   A missing dependency raises.
--
-- watcher:startWatchingUtcDailyDateKeyChanges(onUtcDailyDateKeyChanged: (newUtcDailyDateKey: string) -> ())
--   Remembers today's key (PlayerSaveDataSchema.formatUtcDailyDateKey of the clock) and schedules
--   a check for the next UTC midnight. At each check:
--     * the next check is always scheduled (for the following UTC midnight);
--     * if the clock's date key differs from the last one seen, the callback is called ONCE with
--       the new key (a clock that jumped over several days gives one call with the latest key);
--     * if the check ran before midnight by the clock (date unchanged), nothing is called and the
--       next check is scheduled for the remaining time.
--   A check that cannot read the clock (it raises, or returns something that is not a usable
--   number) is logged as a warning and retried CHECK_RETRY_DELAY_SECONDS later; the watching
--   never stops. A callback that raises is logged as a warning and never stops the watching.
--   Logged error texts are cut by LoggedErrorTextShortener.
--   Calling it twice, or with a callback that is not a function, raises. The clock is read
--   unprotected while starting: a clock that fails then is a wiring error and raises, and the
--   watcher stays unstarted (a later start may succeed).
-- ════════════════════════════════════════════════════════════════════════════════════════════

local LoggedErrorTextShortener = require("./LoggedErrorTextShortener")
local PlayerSaveDataSchema = require("./PlayerSaveDataSchema")

local shortenErrorTextForLog = LoggedErrorTextShortener.shortenErrorTextForLog

local UtcDailyDateKeyChangeWatcher = {}
UtcDailyDateKeyChangeWatcher.__index = UtcDailyDateKeyChangeWatcher

UtcDailyDateKeyChangeWatcher.CHECK_RETRY_DELAY_SECONDS = 60

local SECONDS_PER_DAY = 86400

function UtcDailyDateKeyChangeWatcher.new(dependencies)
	for _, requiredDependencyName in { "clock", "scheduler", "logger" } do
		if dependencies[requiredDependencyName] == nil then
			error("UtcDailyDateKeyChangeWatcher.new: missing dependency " .. requiredDependencyName, 2)
		end
	end
	return setmetatable({
		clock = dependencies.clock,
		scheduler = dependencies.scheduler,
		logger = dependencies.logger,
		hasStarted = false,
		lastSeenUtcDailyDateKey = nil :: string?,
		onUtcDailyDateKeyChanged = nil :: ((string) -> ())?,
	}, UtcDailyDateKeyChangeWatcher)
end

-- Always > 0: at exactly midnight it is a whole day.
local function calculateSecondsUntilNextUtcMidnight(currentUnixSeconds: number): number
	local nextUtcMidnightUnixSeconds = (math.floor(currentUnixSeconds / SECONDS_PER_DAY) + 1) * SECONDS_PER_DAY
	return nextUtcMidnightUnixSeconds - currentUnixSeconds
end

-- Reads the clock once; returns the delay until the next check and today's key. Raises for a
-- clock that raises or gives something that is not a finite number.
local function readNextCheckDelayAndCurrentUtcDailyDateKey(self): (number, string)
	local currentUnixSeconds = self.clock:getCurrentUnixSeconds()
	local isFiniteNumber = type(currentUnixSeconds) == "number"
		and currentUnixSeconds == currentUnixSeconds
		and math.abs(currentUnixSeconds) ~= math.huge
	if not isFiniteNumber then
		error("the clock gave " .. shortenErrorTextForLog(currentUnixSeconds), 0)
	end
	return calculateSecondsUntilNextUtcMidnight(currentUnixSeconds),
		PlayerSaveDataSchema.formatUtcDailyDateKey(currentUnixSeconds)
end

local scheduleUtcDailyDateKeyCheckAfterSeconds -- forward declaration

local function runUtcDailyDateKeyCheck(self)
	local didReadClock, nextCheckDelaySecondsOrError, currentUtcDailyDateKey =
		pcall(readNextCheckDelayAndCurrentUtcDailyDateKey, self)
	if not didReadClock then
		self.logger:logWarning(
			string.format(
				"UtcDailyDateKeyChangeWatcher: reading the clock for the date check failed, retrying in %d s: %s",
				UtcDailyDateKeyChangeWatcher.CHECK_RETRY_DELAY_SECONDS,
				shortenErrorTextForLog(nextCheckDelaySecondsOrError)
			)
		)
		scheduleUtcDailyDateKeyCheckAfterSeconds(self, UtcDailyDateKeyChangeWatcher.CHECK_RETRY_DELAY_SECONDS)
		return
	end
	scheduleUtcDailyDateKeyCheckAfterSeconds(self, nextCheckDelaySecondsOrError)
	if currentUtcDailyDateKey == self.lastSeenUtcDailyDateKey then
		return
	end
	self.lastSeenUtcDailyDateKey = currentUtcDailyDateKey
	local didCallbackSucceed, callbackError = pcall(self.onUtcDailyDateKeyChanged, currentUtcDailyDateKey)
	if not didCallbackSucceed then
		self.logger:logWarning(
			string.format(
				"UtcDailyDateKeyChangeWatcher: the date change callback for %s failed: %s",
				currentUtcDailyDateKey,
				shortenErrorTextForLog(callbackError)
			)
		)
	end
end

function scheduleUtcDailyDateKeyCheckAfterSeconds(self, delaySeconds: number)
	self.scheduler:scheduleCallbackAfterSeconds(delaySeconds, function()
		runUtcDailyDateKeyCheck(self)
	end)
end

function UtcDailyDateKeyChangeWatcher:startWatchingUtcDailyDateKeyChanges(
	onUtcDailyDateKeyChanged: (newUtcDailyDateKey: string) -> ()
)
	if self.hasStarted then
		error("UtcDailyDateKeyChangeWatcher: startWatchingUtcDailyDateKeyChanges was already called", 2)
	end
	if type(onUtcDailyDateKeyChanged) ~= "function" then
		error("UtcDailyDateKeyChangeWatcher: onUtcDailyDateKeyChanged must be a function", 2)
	end
	local nextCheckDelaySeconds, currentUtcDailyDateKey = readNextCheckDelayAndCurrentUtcDailyDateKey(self)
	self.hasStarted = true
	self.onUtcDailyDateKeyChanged = onUtcDailyDateKeyChanged
	self.lastSeenUtcDailyDateKey = currentUtcDailyDateKey
	scheduleUtcDailyDateKeyCheckAfterSeconds(self, nextCheckDelaySeconds)
end

return UtcDailyDateKeyChangeWatcher
