-- RobloxDeviceClockAndScheduler: the real "current time" and "do X after N seconds" handed to the
-- device's rule modules, in the shapes tests/Support/FakeClock and FakeScheduler have:
--   clock:getCurrentUnixMilliseconds() -> number
--   scheduler:scheduleCallbackAfterSeconds(delaySeconds, callback) -> cancel()
--
-- The clock is Workspace:GetServerTimeNow(): "the client's best approximation of the current time on
-- the server ... a Unix timestamp ... monotonic; its value will never decrease. It moves at the same
-- rate as the local clock to within 0.6%." So it compares directly with the server's
-- phaseEndsAtUnixMilliseconds (the server reads DateTime.now()), and it is also used for the draft
-- and request intervals (it never runs backwards). RoundPhaseCountdownEstimator still guards against
-- it being wrong.
--
-- PUBLIC API
--   RobloxDeviceClockAndScheduler.createDeviceClock() -> clock
--   RobloxDeviceClockAndScheduler.createDeviceScheduler() -> scheduler
--     cancel() before the callback ran stops it; after it ran (or twice) it does nothing.
--
-- Roblox API used, read in the official documentation (create.roblox.com/docs/reference/engine/...):
--   Workspace:GetServerTimeNow   classes/Workspace (quoted above; "calling it from a client that isn't
--     connected will throw an error": the device code only starts once the remote channels exist)
--   task.delay, task.cancel ("can be used with ... the thread returned by task.delay")   libraries/task

local Workspace = game:GetService("Workspace")

local RobloxDeviceClockAndScheduler = {}

function RobloxDeviceClockAndScheduler.createDeviceClock()
	return {
		getCurrentUnixMilliseconds = function(_self): number
			return Workspace:GetServerTimeNow() * 1000
		end,
	}
end

function RobloxDeviceClockAndScheduler.createDeviceScheduler()
	return {
		scheduleCallbackAfterSeconds = function(_self, delaySeconds: number, callback: () -> ())
			local hasRunOrBeenCancelled = false
			local delayedThread = task.delay(delaySeconds, function()
				if hasRunOrBeenCancelled then
					return
				end
				hasRunOrBeenCancelled = true
				callback()
			end)
			return function()
				if hasRunOrBeenCancelled then
					return
				end
				hasRunOrBeenCancelled = true
				task.cancel(delayedThread)
			end
		end,
	}
end

return table.freeze(RobloxDeviceClockAndScheduler)
