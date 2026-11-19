local UnitTestFramework = require("./UnitTestFramework")
local FakeClock = require("./FakeClock")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

-- 2026-11-19T00:00:00Z
local EXAMPLE_STARTING_UNIX_SECONDS = 1_763_510_400

describe("FakeClock", function()
	it("starts at the given time and does not move by itself", function()
		local fakeClock = FakeClock.new(EXAMPLE_STARTING_UNIX_SECONDS)
		expect(fakeClock:getCurrentUnixSeconds()).toBe(EXAMPLE_STARTING_UNIX_SECONDS)
		expect(fakeClock:getCurrentUnixMilliseconds()).toBe(EXAMPLE_STARTING_UNIX_SECONDS * 1000)
		expect(fakeClock:getCurrentUnixSeconds()).toBe(EXAMPLE_STARTING_UNIX_SECONDS)
	end)

	it("moves forward exactly by the advanced amount", function()
		local fakeClock = FakeClock.new(EXAMPLE_STARTING_UNIX_SECONDS)
		fakeClock:advanceBySeconds(180)
		expect(fakeClock:getCurrentUnixSeconds()).toBe(EXAMPLE_STARTING_UNIX_SECONDS + 180)
		fakeClock:advanceBySeconds(0.5)
		expect(fakeClock:getCurrentUnixMilliseconds()).toBe((EXAMPLE_STARTING_UNIX_SECONDS + 180) * 1000 + 500)
	end)

	it("does not drift when many fractional steps are added", function()
		local fakeClock = FakeClock.new(0)
		for _ = 1, 10 do
			fakeClock:advanceBySeconds(0.1)
		end
		expect(fakeClock:getCurrentUnixMilliseconds()).toBe(1000)
		expect(fakeClock:getCurrentUnixSeconds()).toBe(1)
	end)

	it("refuses to move backwards or by a non-finite amount", function()
		local fakeClock = FakeClock.new(EXAMPLE_STARTING_UNIX_SECONDS)
		expect(function()
			fakeClock:advanceBySeconds(-1)
		end).toThrow("cannot move backwards")
		expect(function()
			fakeClock:advanceBySeconds(math.huge)
		end).toThrow("must be a finite number")
		expect(function()
			fakeClock:moveForwardToUnixMilliseconds(0)
		end).toThrow("cannot move backwards")
		expect(fakeClock:getCurrentUnixSeconds()).toBe(EXAMPLE_STARTING_UNIX_SECONDS)
	end)

	it("keeps separate instances independent", function()
		local firstFakeClock = FakeClock.new(100)
		local secondFakeClock = FakeClock.new(100)
		firstFakeClock:advanceBySeconds(5)
		expect(firstFakeClock:getCurrentUnixSeconds()).toBe(105)
		expect(secondFakeClock:getCurrentUnixSeconds()).toBe(100)
	end)
end)
