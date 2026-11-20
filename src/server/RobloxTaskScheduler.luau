-- RobloxTaskScheduler: the real "do X after N seconds" given to the keepers, the round clock and
-- the Marketplace resolver on the game server. It implements the scheduler interface they all
-- document: scheduler: { scheduleCallbackAfterSeconds: (self, delaySeconds, callback) -> cancelCallback }
--
-- Rules (the same as tests/Support/FakeScheduler, so code tested with the fake behaves the same):
--   * scheduleCallbackAfterSeconds returns at once; the callback runs once, no earlier than
--     delaySeconds later (task.delay: on the first Heartbeat after the time has passed).
--   * The returned cancel function stops a callback that has not started; calling it twice, after
--     the callback ran, or from inside the callback itself does nothing more and never raises.
--     A cancelled callback never runs: the delayed thread checks a cancelled flag before calling,
--     so this holds even if the engine could not cancel the thread.
--   * delaySeconds must be a finite number >= 0 and callback a function; otherwise it raises
--     (a wiring bug, as in FakeScheduler).
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (server wiring)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- RobloxTaskScheduler.newForThisServer() -> scheduler   uses task.delay and task.cancel
-- RobloxTaskScheduler.new({ startDelayedThread = (delaySeconds, threadBody) -> thread,
--                           cancelThread = (thread) -> () }) -> scheduler   for tests
-- scheduler:scheduleCallbackAfterSeconds(delaySeconds, callback) -> cancelScheduledCallback: () -> ()
--
-- Roblox API used, read in the official documentation while writing this file:
--   task.delay, task.cancel   https://create.roblox.com/docs/reference/engine/libraries/task
--     (task.cancel "may" raise for a thread that cannot be cancelled, for example the running
--     one; the page says not to rely on when, so the cancel attempt is protected)
--
-- Verified in Studio 0.748 on 2026-11-19, on the server of a playtest: callbacks asked for 0 s,
-- 0.5 s and 2 s ran after 0.016 s, 0.516 s and 2.016 s; a 1 s callback cancelled twice never ran;
-- a cancel from inside the running callback did not raise; a delay of -1 raised; the real
-- ThemedRoundClock advanced from ThemeReveal into Styling on it after 10.015 s (asked 10 s).

local RobloxTaskScheduler = {}
RobloxTaskScheduler.__index = RobloxTaskScheduler

function RobloxTaskScheduler.new(taskDependencies)
	return setmetatable({
		startDelayedThread = taskDependencies.startDelayedThread,
		cancelThread = taskDependencies.cancelThread,
	}, RobloxTaskScheduler)
end

function RobloxTaskScheduler.newForThisServer()
	return RobloxTaskScheduler.new({
		startDelayedThread = function(delaySeconds: number, threadBody: () -> ()): thread
			return task.delay(delaySeconds, threadBody)
		end,
		cancelThread = function(delayedThread: thread)
			task.cancel(delayedThread)
		end,
	})
end

function RobloxTaskScheduler:scheduleCallbackAfterSeconds(delaySeconds: number, callback: () -> ()): () -> ()
	local isFiniteNonNegativeDelay = type(delaySeconds) == "number" and delaySeconds >= 0 and delaySeconds ~= math.huge
	if not isFiniteNonNegativeDelay then
		error("RobloxTaskScheduler: delaySeconds must be a finite number >= 0, got " .. tostring(delaySeconds), 2)
	end
	if type(callback) ~= "function" then
		error("RobloxTaskScheduler: callback must be a function", 2)
	end

	local isCancelledOrStarted = false
	local delayedThread = self.startDelayedThread(delaySeconds, function()
		if isCancelledOrStarted then
			return
		end
		isCancelledOrStarted = true
		callback()
	end)

	return function()
		if isCancelledOrStarted then
			return
		end
		isCancelledOrStarted = true
		-- The flag alone already keeps the callback from running; cancelling only frees the thread.
		pcall(self.cancelThread, delayedThread)
	end
end

return RobloxTaskScheduler
