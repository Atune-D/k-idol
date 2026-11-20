-- RobloxServerClock: the real "current time" given to the keepers, the round clock and the rate
-- limiter on the game server. It implements the clock interfaces they document:
--   PlayerSaveDataKeeper, FanCountLeaderboardKeeper   clock: { getCurrentUnixSeconds: (self) -> number }
--   ThemedRoundClock, PlayerRequestRateLimiter        clock: { getCurrentUnixMilliseconds: (self) -> number }
-- Both readings come from the same source, so they always agree:
-- getCurrentUnixSeconds() == getCurrentUnixMilliseconds() / 1000 for one reading (it can be
-- fractional, like tests/Support/FakeClock).
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (server wiring)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- RobloxServerClock.newForThisServer() -> clock      reads DateTime.now().UnixTimestampMillis
-- RobloxServerClock.new(readCurrentUnixMilliseconds: () -> number) -> clock   for tests
-- clock:getCurrentUnixMilliseconds() -> number   whole milliseconds since the Unix epoch
-- clock:getCurrentUnixSeconds() -> number        the same reading divided by 1000
--
-- Roblox API used, read in the official documentation while writing this file:
--   DateTime.now, DateTime.UnixTimestampMillis  https://create.roblox.com/docs/reference/engine/datatypes/DateTime
--     ("the device's local clock": on the game server that is the server machine's clock, which
--     the operating system keeps in sync; saves compare lock times across servers with it)
--
-- Verified in Studio 0.748 on 2026-11-19 (playtest server): back-to-back readings ms=1795137980118,
-- s=1795137980.118, os.time()=1795137980. Fractional on purpose: no module needs whole seconds.

local RobloxServerClock = {}
RobloxServerClock.__index = RobloxServerClock

function RobloxServerClock.new(readCurrentUnixMilliseconds: () -> number)
	return setmetatable({ readCurrentUnixMilliseconds = readCurrentUnixMilliseconds }, RobloxServerClock)
end

function RobloxServerClock.newForThisServer()
	return RobloxServerClock.new(function(): number
		return DateTime.now().UnixTimestampMillis
	end)
end

function RobloxServerClock:getCurrentUnixMilliseconds(): number
	return self.readCurrentUnixMilliseconds()
end

function RobloxServerClock:getCurrentUnixSeconds(): number
	return self.readCurrentUnixMilliseconds() / 1000
end

return RobloxServerClock
