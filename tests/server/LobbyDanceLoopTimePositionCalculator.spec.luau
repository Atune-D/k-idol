-- LobbyDanceLoopTimePositionCalculator: where in its loop a lobby dance is, from its start moment.

local UnitTestFramework = require("../Support/UnitTestFramework")
local LobbyDanceLoopTimePositionCalculator = require("../../src/server/LobbyDanceLoopTimePositionCalculator")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local compute = LobbyDanceLoopTimePositionCalculator.computeLoopTimePositionSeconds
local STARTED_AT = 1_800_000_000_000

describe("LobbyDanceLoopTimePositionCalculator", function()
	it("is the elapsed time within the first loop", function()
		expect(compute(STARTED_AT, STARTED_AT + 1250, 2)).toBeCloseTo(1.25, 1e-9)
		expect(compute(STARTED_AT, STARTED_AT, 2)).toBe(0)
	end)

	it("wraps around the loop length after whole loops", function()
		expect(compute(STARTED_AT, STARTED_AT + 7_300, 2)).toBeCloseTo(1.3, 1e-9)
		expect(compute(STARTED_AT, STARTED_AT + 6_000, 2)).toBeCloseTo(0, 1e-9)
		expect(compute(STARTED_AT, STARTED_AT + 100_000, 2.0417)).toBeCloseTo(100 % 2.0417, 1e-9)
	end)

	it("gives a leader and a follower with the same start moment the same position", function()
		local now = STARTED_AT + 123_456
		local leaderPosition = compute(STARTED_AT, now, 2.0417)
		local followerPosition = compute(STARTED_AT, now, 2.0417)
		expect(followerPosition).toBe(leaderPosition)
		expect(leaderPosition ~= nil and leaderPosition >= 0 and leaderPosition < 2.0417).toBeTrue()
	end)

	it("treats a start moment in the future (a clock that stepped back) as just started", function()
		expect(compute(STARTED_AT, STARTED_AT - 5_000, 2)).toBe(0)
	end)

	it("is unknown (nil) while the loop length is not known, so nothing is guessed", function()
		for _, unknownLength in { 0, -1, 0 / 0, math.huge, -math.huge, "2" :: any } do
			expect(compute(STARTED_AT, STARTED_AT + 1_000, unknownLength)).toBeNil()
		end
		expect(compute(STARTED_AT, STARTED_AT + 1_000, nil)).toBeNil()
	end)

	it("is unknown (nil) when either moment is not a finite number", function()
		for _, badMoment in { 0 / 0, math.huge, -math.huge, "1" :: any } do
			expect(compute(badMoment, STARTED_AT, 2)).toBeNil()
			expect(compute(STARTED_AT, badMoment, 2)).toBeNil()
		end
		expect(compute(nil, STARTED_AT, 2)).toBeNil()
		expect(compute(STARTED_AT, nil, 2)).toBeNil()
	end)

	it("always stays inside [0, length) for many lengths and moments", function()
		for elapsedMilliseconds = 0, 20_000, 37 do
			for _, loopLength in { 0.001, 0.3, 1, 1.5, 2.0417, 7.25 } do
				local position = compute(STARTED_AT, STARTED_AT + elapsedMilliseconds, loopLength)
				expect(position ~= nil and position >= 0 and position < loopLength).toBeTrue()
			end
		end
	end)

	it("waits a bounded time for the length", function()
		expect(LobbyDanceLoopTimePositionCalculator.LOOP_LENGTH_WAIT_TIMEOUT_SECONDS).toBe(10)
	end)
end)
