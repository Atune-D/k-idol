-- A test clock that, unlike FakeClock, may be set to any moment, including an earlier one. Used to
-- check what code under test promises when the real clock moves backwards. Whole milliseconds.

local BackwardsMovableFakeClock = {}
BackwardsMovableFakeClock.__index = BackwardsMovableFakeClock

export type BackwardsMovableFakeClock = typeof(setmetatable(
	{} :: {
		currentUnixMilliseconds: number,
	},
	BackwardsMovableFakeClock
))

function BackwardsMovableFakeClock.new(startingUnixMilliseconds: number): BackwardsMovableFakeClock
	return setmetatable({ currentUnixMilliseconds = startingUnixMilliseconds }, BackwardsMovableFakeClock)
end

function BackwardsMovableFakeClock.getCurrentUnixMilliseconds(self: BackwardsMovableFakeClock): number
	return self.currentUnixMilliseconds
end

-- Negative values move the clock backwards.
function BackwardsMovableFakeClock.moveByMilliseconds(self: BackwardsMovableFakeClock, movedMilliseconds: number)
	self.currentUnixMilliseconds += movedMilliseconds
end

return BackwardsMovableFakeClock
