-- A clock that only moves when a test moves it. Game modules that need "the current time"
-- receive a clock object with `getCurrentUnixSeconds` / `getCurrentUnixMilliseconds`; tests
-- pass a FakeClock so that time is fully deterministic and no test ever really waits.
--
-- Time is stored as whole Unix milliseconds so repeated fractional advances (0.1 + 0.2 ...)
-- never drift. Advances are rounded to the nearest millisecond.

local FakeClock = {}
FakeClock.__index = FakeClock

export type FakeClock = typeof(setmetatable(
	{} :: {
		currentUnixMilliseconds: number,
	},
	FakeClock
))

local function convertSecondsToWholeMilliseconds(durationSeconds: number): number
	return math.round(durationSeconds * 1000)
end

local function assertIsFiniteNumber(candidateNumber: any, argumentDescription: string)
	if
		type(candidateNumber) ~= "number"
		or candidateNumber ~= candidateNumber
		or math.abs(candidateNumber) == math.huge
	then
		error(
			string.format(
				"FakeClock: %s must be a finite number, got %s",
				argumentDescription,
				tostring(candidateNumber)
			),
			3
		)
	end
end

function FakeClock.new(startingUnixSeconds: number): FakeClock
	assertIsFiniteNumber(startingUnixSeconds, "startingUnixSeconds")
	local self = setmetatable({
		currentUnixMilliseconds = convertSecondsToWholeMilliseconds(startingUnixSeconds),
	}, FakeClock)
	return self
end

-- May be fractional (milliseconds precision).
function FakeClock.getCurrentUnixSeconds(self: FakeClock): number
	return self.currentUnixMilliseconds / 1000
end

function FakeClock.getCurrentUnixMilliseconds(self: FakeClock): number
	return self.currentUnixMilliseconds
end

function FakeClock.advanceBySeconds(self: FakeClock, elapsedSeconds: number)
	assertIsFiniteNumber(elapsedSeconds, "elapsedSeconds")
	if elapsedSeconds < 0 then
		error(string.format("FakeClock: time cannot move backwards (elapsedSeconds = %s)", tostring(elapsedSeconds)), 2)
	end
	self.currentUnixMilliseconds += convertSecondsToWholeMilliseconds(elapsedSeconds)
end

-- Used by FakeScheduler to step exactly to a scheduled moment.
function FakeClock.moveForwardToUnixMilliseconds(self: FakeClock, targetUnixMilliseconds: number)
	if targetUnixMilliseconds < self.currentUnixMilliseconds then
		error(
			string.format(
				"FakeClock: time cannot move backwards (from %d ms to %d ms)",
				self.currentUnixMilliseconds,
				targetUnixMilliseconds
			),
			2
		)
	end
	self.currentUnixMilliseconds = targetUnixMilliseconds
end

return FakeClock
