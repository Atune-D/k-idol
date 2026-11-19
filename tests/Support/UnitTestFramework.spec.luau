-- Self-tests for the expectation matchers: each must pass on a match and fail with a
-- readable message on a mismatch.

local UnitTestFramework = require("./UnitTestFramework")
local UnitTestExpectations = require("./UnitTestExpectations")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function captureExpectationFailureMessage(matcherCall: () -> ()): string?
	local didSucceed, raisedError = pcall(matcherCall)
	if didSucceed then
		return nil
	end
	if not UnitTestExpectations.isExpectationFailure(raisedError) then
		error("matcher raised something other than an expectation failure: " .. tostring(raisedError))
	end
	return raisedError.failureMessage
end

describe("UnitTestExpectations", function()
	it("toBe passes on primitive equality and fails with both values in the message", function()
		expect(captureExpectationFailureMessage(function()
			expect(42).toBe(42)
		end)).toBeNil()
		expect(captureExpectationFailureMessage(function()
			expect(41).toBe(42)
		end)).toBe("Expected 41 to be 42")
		expect(captureExpectationFailureMessage(function()
			expect({}).toBe({})
		end)).toBe("Expected {} to be {}")
	end)

	it("toEqual compares tables by content in both directions", function()
		expect(captureExpectationFailureMessage(function()
			expect({ 1, { roundId = "a" } }).toEqual({ 1, { roundId = "a" } })
		end)).toBeNil()
		expect(captureExpectationFailureMessage(function()
			expect({ 1, 2 }).toEqual({ 1, 2, 3 })
		end)).toBe("Expected { [1] = 1, [2] = 2 } to deeply equal { [1] = 1, [2] = 2, [3] = 3 }")
		expect(captureExpectationFailureMessage(function()
			expect({ 1, 2, 3 }).toEqual({ 1, 2 })
		end)).toBe("Expected { [1] = 1, [2] = 2, [3] = 3 } to deeply equal { [1] = 1, [2] = 2 }")
	end)

	it("toBeNil, toBeTrue and toBeFalse do not accept truthy or falsy stand-ins", function()
		expect(captureExpectationFailureMessage(function()
			expect(false).toBeNil()
		end)).toBe("Expected false to be nil")
		expect(captureExpectationFailureMessage(function()
			expect(1).toBeTrue()
		end)).toBe("Expected 1 to be true")
		expect(captureExpectationFailureMessage(function()
			expect(nil).toBeFalse()
		end)).toBe("Expected nil to be false")
	end)

	it("toBeCloseTo respects the tolerance", function()
		expect(captureExpectationFailureMessage(function()
			expect(0.1 + 0.2).toBeCloseTo(0.3)
		end)).toBeNil()
		expect(captureExpectationFailureMessage(function()
			expect(83.34).toBeCloseTo(83.33, 0.001)
		end)).toBe("Expected 83.34 to be within 0.001 of 83.33")
	end)

	it("toContain and toHaveLength describe the array they inspected", function()
		expect(captureExpectationFailureMessage(function()
			expect({ "pink" }).toContain("pink")
		end)).toBeNil()
		expect(captureExpectationFailureMessage(function()
			expect({ "pink" }).toContain("red")
		end)).toBe('Expected { [1] = "pink" } to contain "red"')
		expect(captureExpectationFailureMessage(function()
			expect({ "pink" }).toHaveLength(2)
		end)).toBe('Expected length 2 but got 1 for { [1] = "pink" }')
	end)

	it("toThrow requires an error and, when given, a matching message fragment", function()
		expect(captureExpectationFailureMessage(function()
			expect(function()
				error("save lock lost")
			end).toThrow("lock lost")
		end)).toBeNil()
		expect(captureExpectationFailureMessage(function()
			expect(function() end).toThrow()
		end)).toBe("Expected the function to throw, but it returned normally")
		local mismatchMessage = captureExpectationFailureMessage(function()
			expect(function()
				error("storage error", 0)
			end).toThrow("lock lost")
		end)
		expect(mismatchMessage).toBe('Expected the thrown error to contain "lock lost", but it was "storage error"')
	end)

	it("a failure records the file and line of the test that called the matcher", function()
		local didSucceed, raisedError = pcall(function()
			expect(1).toBe(2)
		end)
		expect(didSucceed).toBeFalse()
		expect(string.find(raisedError.failedAtSourceLocation, "UnitTestFramework.spec:", 1, true) ~= nil).toBeTrue()
	end)
end)
