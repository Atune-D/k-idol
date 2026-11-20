-- UtcDailyDateKeyChangeWatcher: the UTC date change (development spec v1.3 §1.8 `dailyDateKey`)
-- reported once per change while the server runs, with a fake clock and scheduler.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local LoggedErrorTextShortener = require("../../src/server/LoggedErrorTextShortener")
local PlayerSaveDataSchema = require("../../src/server/PlayerSaveDataSchema")
local UtcDailyDateKeyChangeWatcher = require("../../src/server/UtcDailyDateKeyChangeWatcher")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local SECONDS_PER_DAY = 86400
-- 2026-11-19 00:00:00 UTC.
local MIDNIGHT_OF_2026_11_19 = 1_795_046_400

local function createRecordingLogger()
	local recordingLogger = { loggedInformation = {}, loggedWarnings = {} }
	function recordingLogger.logInformation(self, message: string)
		table.insert(self.loggedInformation, message)
	end
	function recordingLogger.logWarning(self, message: string)
		table.insert(self.loggedWarnings, message)
	end
	return recordingLogger
end

local function createStartedWatcher(startingUnixSeconds: number)
	local fakeClock = FakeClock.new(startingUnixSeconds)
	local fakeScheduler = FakeScheduler.new(fakeClock)
	local recordingLogger = createRecordingLogger()
	local watcher = UtcDailyDateKeyChangeWatcher.new({
		clock = fakeClock,
		scheduler = fakeScheduler,
		logger = recordingLogger,
	})
	local reportedDailyDateKeys = {}
	watcher:startWatchingUtcDailyDateKeyChanges(function(newUtcDailyDateKey)
		table.insert(reportedDailyDateKeys, newUtcDailyDateKey)
	end)
	return {
		fakeClock = fakeClock,
		fakeScheduler = fakeScheduler,
		recordingLogger = recordingLogger,
		watcher = watcher,
		reportedDailyDateKeys = reportedDailyDateKeys,
	}
end

describe("UtcDailyDateKeyChangeWatcher", function()
	it("reports the new key at UTC midnight and not a moment before", function()
		local watched = createStartedWatcher(MIDNIGHT_OF_2026_11_19 + 50_000)
		watched.fakeScheduler:advanceTimeAndRunDueCallbacks(SECONDS_PER_DAY - 50_000 - 0.001)
		expect(watched.reportedDailyDateKeys).toEqual({})
		watched.fakeScheduler:advanceTimeAndRunDueCallbacks(0.001)
		expect(watched.reportedDailyDateKeys).toEqual({ "2026-11-20" })
	end)

	it("reports every midnight, once each, over several days", function()
		local watched = createStartedWatcher(MIDNIGHT_OF_2026_11_19 + 1)
		watched.fakeScheduler:advanceTimeAndRunDueCallbacks(3 * SECONDS_PER_DAY)
		expect(watched.reportedDailyDateKeys).toEqual({ "2026-11-20", "2026-11-21", "2026-11-22" })
		expect(watched.fakeScheduler:getPendingCallbackCount()).toBe(1)
	end)

	it("started exactly at midnight, the first report is a whole day later", function()
		local watched = createStartedWatcher(MIDNIGHT_OF_2026_11_19)
		watched.fakeScheduler:advanceTimeAndRunDueCallbacks(SECONDS_PER_DAY - 0.001)
		expect(watched.reportedDailyDateKeys).toEqual({})
		watched.fakeScheduler:advanceTimeAndRunDueCallbacks(0.001)
		expect(watched.reportedDailyDateKeys).toEqual({ "2026-11-20" })
	end)

	it("a clock that jumped over several days gives one report with the latest key", function()
		local watched = createStartedWatcher(MIDNIGHT_OF_2026_11_19 + 10)
		watched.fakeClock:advanceBySeconds(3 * SECONDS_PER_DAY)
		watched.fakeScheduler:advanceTimeAndRunDueCallbacks(0)
		expect(watched.reportedDailyDateKeys).toEqual({ "2026-11-22" })
		watched.fakeScheduler:advanceTimeAndRunDueCallbacks(SECONDS_PER_DAY)
		expect(watched.reportedDailyDateKeys).toEqual({ "2026-11-22", "2026-11-23" })
	end)

	it("a check that runs early reports nothing and checks again at midnight", function()
		local currentUnixSeconds = MIDNIGHT_OF_2026_11_19 + 80_000
		local scheduledChecks = {}
		local earlyFiringScheduler = {}
		function earlyFiringScheduler.scheduleCallbackAfterSeconds(_, delaySeconds: number, callback: () -> ())
			table.insert(scheduledChecks, { delaySeconds = delaySeconds, callback = callback })
			return function() end
		end
		local reportedDailyDateKeys = {}
		local watcher = UtcDailyDateKeyChangeWatcher.new({
			clock = {
				getCurrentUnixSeconds = function()
					return currentUnixSeconds
				end,
			},
			scheduler = earlyFiringScheduler,
			logger = createRecordingLogger(),
		})
		watcher:startWatchingUtcDailyDateKeyChanges(function(newUtcDailyDateKey)
			table.insert(reportedDailyDateKeys, newUtcDailyDateKey)
		end)
		expect(scheduledChecks[1].delaySeconds).toBe(SECONDS_PER_DAY - 80_000)
		currentUnixSeconds = MIDNIGHT_OF_2026_11_19 + SECONDS_PER_DAY - 1.5 -- the scheduler fired early
		scheduledChecks[1].callback()
		expect(reportedDailyDateKeys).toEqual({})
		expect(scheduledChecks[2].delaySeconds).toBe(1.5)
		currentUnixSeconds = MIDNIGHT_OF_2026_11_19 + SECONDS_PER_DAY
		scheduledChecks[2].callback()
		expect(reportedDailyDateKeys).toEqual({ "2026-11-20" })
		expect(scheduledChecks[3].delaySeconds).toBe(SECONDS_PER_DAY)
		currentUnixSeconds = MIDNIGHT_OF_2026_11_19 + SECONDS_PER_DAY + 10 -- another early check, same new day
		scheduledChecks[3].callback()
		expect(reportedDailyDateKeys).toEqual({ "2026-11-20" })
	end)

	it("a callback that raises is logged and the watching goes on", function()
		local fakeClock = FakeClock.new(MIDNIGHT_OF_2026_11_19 + 5)
		local fakeScheduler = FakeScheduler.new(fakeClock)
		local recordingLogger = createRecordingLogger()
		local watcher = UtcDailyDateKeyChangeWatcher.new({
			clock = fakeClock,
			scheduler = fakeScheduler,
			logger = recordingLogger,
		})
		local callCount = 0
		watcher:startWatchingUtcDailyDateKeyChanges(function()
			callCount += 1
			error("callback failure")
		end)
		fakeScheduler:advanceTimeAndRunDueCallbacks(2 * SECONDS_PER_DAY)
		expect(callCount).toBe(2)
		expect(#recordingLogger.loggedWarnings).toBe(2)
		expect(string.find(recordingLogger.loggedWarnings[1], "2026-11-20", 1, true) ~= nil).toBeTrue()
		expect(string.find(recordingLogger.loggedWarnings[1], "callback failure", 1, true) ~= nil).toBeTrue()
	end)

	it("a callback error is logged cut to the limit", function()
		local fakeClock = FakeClock.new(MIDNIGHT_OF_2026_11_19 + 5)
		local fakeScheduler = FakeScheduler.new(fakeClock)
		local recordingLogger = createRecordingLogger()
		local watcher = UtcDailyDateKeyChangeWatcher.new({
			clock = fakeClock,
			scheduler = fakeScheduler,
			logger = recordingLogger,
		})
		watcher:startWatchingUtcDailyDateKeyChanges(function()
			error(string.rep("e", 5000), 0)
		end)
		fakeScheduler:advanceTimeAndRunDueCallbacks(SECONDS_PER_DAY)
		expect(recordingLogger.loggedWarnings).toEqual({
			"UtcDailyDateKeyChangeWatcher: the date change callback for 2026-11-20 failed: "
				.. string.rep("e", LoggedErrorTextShortener.MAXIMUM_LOGGED_ERROR_TEXT_LENGTH)
				.. "...(cut)",
		})
	end)

	it("a clock that raises once at the midnight check: logged, retried, and the watching goes on", function()
		local watched = createStartedWatcher(MIDNIGHT_OF_2026_11_19 + 50_000)
		local realGetCurrentUnixSeconds = watched.fakeClock.getCurrentUnixSeconds
		local remainingClockFailureCount = 0
		watched.fakeClock.getCurrentUnixSeconds = function(clock)
			if remainingClockFailureCount > 0 then
				remainingClockFailureCount -= 1
				error(string.rep("k", 5000), 0)
			end
			return realGetCurrentUnixSeconds(clock)
		end
		watched.fakeScheduler:advanceTimeAndRunDueCallbacks(SECONDS_PER_DAY - 50_000 - 0.001)
		remainingClockFailureCount = 1
		watched.fakeScheduler:advanceTimeAndRunDueCallbacks(0.001) -- the check at 00:00:00 fails
		expect(watched.reportedDailyDateKeys).toEqual({})
		expect(watched.recordingLogger.loggedWarnings).toEqual({
			"UtcDailyDateKeyChangeWatcher: reading the clock for the date check failed, retrying in 60 s: "
				.. string.rep("k", LoggedErrorTextShortener.MAXIMUM_LOGGED_ERROR_TEXT_LENGTH)
				.. "...(cut)",
		})
		expect(watched.fakeScheduler:getPendingCallbackCount()).toBe(1)
		watched.fakeScheduler:advanceTimeAndRunDueCallbacks(
			UtcDailyDateKeyChangeWatcher.CHECK_RETRY_DELAY_SECONDS - 0.001
		)
		expect(watched.reportedDailyDateKeys).toEqual({})
		watched.fakeScheduler:advanceTimeAndRunDueCallbacks(0.001)
		expect(watched.reportedDailyDateKeys).toEqual({ "2026-11-20" })
		watched.fakeScheduler:advanceTimeAndRunDueCallbacks(3 * SECONDS_PER_DAY)
		expect(watched.reportedDailyDateKeys).toEqual({ "2026-11-20", "2026-11-21", "2026-11-22", "2026-11-23" })
		expect(#watched.recordingLogger.loggedWarnings).toBe(1)
	end)

	it("a clock that gives something unusable at a check is treated like a clock that raises", function()
		for _, unusableClockCase in
			{
				{ value = "noon", describedAs = "noon" },
				{ value = 0 / 0, describedAs = "nan" },
				{ value = math.huge, describedAs = "inf" },
				{ value = -math.huge, describedAs = "-inf" },
				{ value = nil, describedAs = "nil" },
			}
		do
			local watched = createStartedWatcher(MIDNIGHT_OF_2026_11_19 + 50_000)
			local realGetCurrentUnixSeconds = watched.fakeClock.getCurrentUnixSeconds
			local isClockUnusable = true
			watched.fakeClock.getCurrentUnixSeconds = function(clock)
				if isClockUnusable then
					isClockUnusable = false
					return unusableClockCase.value
				end
				return realGetCurrentUnixSeconds(clock)
			end
			watched.fakeScheduler:advanceTimeAndRunDueCallbacks(SECONDS_PER_DAY - 50_000)
			expect(watched.reportedDailyDateKeys).toEqual({})
			expect(watched.recordingLogger.loggedWarnings).toEqual({
				"UtcDailyDateKeyChangeWatcher: reading the clock for the date check failed, retrying in 60 s: "
					.. "the clock gave "
					.. unusableClockCase.describedAs,
			})
			watched.fakeScheduler:advanceTimeAndRunDueCallbacks(UtcDailyDateKeyChangeWatcher.CHECK_RETRY_DELAY_SECONDS)
			expect(watched.reportedDailyDateKeys).toEqual({ "2026-11-20" })
		end
	end)

	it("a clock that raises while starting raises from start, starts nothing, and a later start works", function()
		local fakeClock = FakeClock.new(MIDNIGHT_OF_2026_11_19)
		local fakeScheduler = FakeScheduler.new(fakeClock)
		local isClockWired = false
		local watcher = UtcDailyDateKeyChangeWatcher.new({
			clock = {
				getCurrentUnixSeconds = function()
					if not isClockWired then
						error("clock not wired")
					end
					return fakeClock:getCurrentUnixSeconds()
				end,
			},
			scheduler = fakeScheduler,
			logger = createRecordingLogger(),
		})
		expect(function()
			watcher:startWatchingUtcDailyDateKeyChanges(function() end)
		end).toThrow("clock not wired")
		expect(fakeScheduler:getPendingCallbackCount()).toBe(0)
		isClockWired = true
		watcher:startWatchingUtcDailyDateKeyChanges(function() end)
		expect(fakeScheduler:getPendingCallbackCount()).toBe(1)
	end)

	it("raises when started twice or with a callback that is not a function", function()
		local watched = createStartedWatcher(MIDNIGHT_OF_2026_11_19)
		expect(function()
			watched.watcher:startWatchingUtcDailyDateKeyChanges(function() end)
		end).toThrow("already called")
		expect(watched.fakeScheduler:getPendingCallbackCount()).toBe(1)
		local fakeClock = FakeClock.new(MIDNIGHT_OF_2026_11_19)
		local unstartedWatcher = UtcDailyDateKeyChangeWatcher.new({
			clock = fakeClock,
			scheduler = FakeScheduler.new(fakeClock),
			logger = createRecordingLogger(),
		})
		expect(function()
			unstartedWatcher:startWatchingUtcDailyDateKeyChanges("not a function" :: any)
		end).toThrow("must be a function")
	end)

	it("raises when a dependency is missing", function()
		local fakeClock = FakeClock.new(MIDNIGHT_OF_2026_11_19)
		local completeDependencies = {
			clock = fakeClock,
			scheduler = FakeScheduler.new(fakeClock),
			logger = createRecordingLogger(),
		}
		for missingDependencyName in completeDependencies do
			local incompleteDependencies = table.clone(completeDependencies)
			incompleteDependencies[missingDependencyName] = nil
			expect(function()
				UtcDailyDateKeyChangeWatcher.new(incompleteDependencies)
			end).toThrow("missing dependency " .. missingDependencyName)
		end
	end)

	it("random start times: exactly one report per crossed midnight, each with that day's key", function()
		SeededRandomTrials.runSeededRandomTrials(100, function(randomNumberGenerator)
			local startingUnixSeconds = MIDNIGHT_OF_2026_11_19
				+ randomNumberGenerator.nextWholeNumberInRange(-400, 400) * SECONDS_PER_DAY
				+ randomNumberGenerator.nextWholeNumberInRange(0, SECONDS_PER_DAY * 1000 - 1) / 1000
			local watched = createStartedWatcher(startingUnixSeconds)
			local expectedDailyDateKeys = {}
			local stepCount = randomNumberGenerator.nextWholeNumberInRange(1, 8)
			for _ = 1, stepCount do
				local beforeStepDayNumber = math.floor(watched.fakeClock:getCurrentUnixSeconds() / SECONDS_PER_DAY)
				watched.fakeScheduler:advanceTimeAndRunDueCallbacks(
					randomNumberGenerator.nextWholeNumberInRange(1, 2 * SECONDS_PER_DAY * 1000) / 1000
				)
				local afterStepDayNumber = math.floor(watched.fakeClock:getCurrentUnixSeconds() / SECONDS_PER_DAY)
				for crossedDayNumber = beforeStepDayNumber + 1, afterStepDayNumber do
					table.insert(
						expectedDailyDateKeys,
						PlayerSaveDataSchema.formatUtcDailyDateKey(crossedDayNumber * SECONDS_PER_DAY)
					)
				end
			end
			expect(watched.reportedDailyDateKeys).toEqual(expectedDailyDateKeys)
		end)
	end)
end)
