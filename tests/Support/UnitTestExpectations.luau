-- The `expect(actualValue).toXxx(...)` matchers used inside `it` blocks.
-- A failing matcher raises an ExpectationFailure; UnitTestFramework reports its message
-- together with the file and line of the test that called the matcher.

local TestValueDescriber = require("./TestValueDescriber")

local UnitTestExpectations = {}

export type ExpectationFailure = {
	isUnitTestExpectationFailure: boolean,
	failureMessage: string,
	failedAtSourceLocation: string,
}

-- Stack levels: 1 = raiseExpectationFailure, 2 = the matcher, 3 = the test that called the matcher.
local TEST_BODY_STACK_LEVEL = 3

local function raiseExpectationFailure(failureMessage: string): never
	local testSourcePath, testSourceLine = debug.info(TEST_BODY_STACK_LEVEL, "sl")
	local expectationFailure: ExpectationFailure = {
		isUnitTestExpectationFailure = true,
		failureMessage = failureMessage,
		failedAtSourceLocation = string.format("%s:%s", tostring(testSourcePath), tostring(testSourceLine)),
	}
	error(expectationFailure, 0)
end

function UnitTestExpectations.isExpectationFailure(raisedError: any): boolean
	return type(raisedError) == "table" and raisedError.isUnitTestExpectationFailure == true
end

function UnitTestExpectations.expect(actualValue: any)
	local describe = TestValueDescriber.describeValue
	local matchers = {}

	-- Identity / primitive equality (==).
	function matchers.toBe(expectedValue: any)
		if actualValue ~= expectedValue then
			raiseExpectationFailure(
				string.format("Expected %s to be %s", describe(actualValue), describe(expectedValue))
			)
		end
	end

	-- Content equality for tables (same keys, deeply equal values).
	function matchers.toEqual(expectedValue: any)
		if not TestValueDescriber.areValuesDeeplyEqual(actualValue, expectedValue) then
			raiseExpectationFailure(
				string.format("Expected %s to deeply equal %s", describe(actualValue), describe(expectedValue))
			)
		end
	end

	function matchers.toBeNil()
		if actualValue ~= nil then
			raiseExpectationFailure(string.format("Expected %s to be nil", describe(actualValue)))
		end
	end

	function matchers.toBeTrue()
		if actualValue ~= true then
			raiseExpectationFailure(string.format("Expected %s to be true", describe(actualValue)))
		end
	end

	function matchers.toBeFalse()
		if actualValue ~= false then
			raiseExpectationFailure(string.format("Expected %s to be false", describe(actualValue)))
		end
	end

	function matchers.toBeCloseTo(expectedNumber: number, allowedAbsoluteDifference: number?)
		local tolerance = allowedAbsoluteDifference or 1e-9
		if type(actualValue) ~= "number" or math.abs(actualValue - expectedNumber) > tolerance then
			raiseExpectationFailure(
				string.format(
					"Expected %s to be within %s of %s",
					describe(actualValue),
					tostring(tolerance),
					tostring(expectedNumber)
				)
			)
		end
	end

	-- Array membership by deep equality.
	function matchers.toContain(expectedArrayElement: any)
		if type(actualValue) ~= "table" then
			raiseExpectationFailure(string.format("Expected %s to be an array", describe(actualValue)))
		end
		for _, actualArrayElement in ipairs(actualValue) do
			if TestValueDescriber.areValuesDeeplyEqual(actualArrayElement, expectedArrayElement) then
				return
			end
		end
		raiseExpectationFailure(
			string.format("Expected %s to contain %s", describe(actualValue), describe(expectedArrayElement))
		)
	end

	function matchers.toHaveLength(expectedLength: number)
		if type(actualValue) ~= "table" and type(actualValue) ~= "string" then
			raiseExpectationFailure(string.format("Expected %s to have a length", describe(actualValue)))
		end
		if #actualValue ~= expectedLength then
			raiseExpectationFailure(
				string.format(
					"Expected length %d but got %d for %s",
					expectedLength,
					#actualValue,
					describe(actualValue)
				)
			)
		end
	end

	-- `actualValue` must be a function that raises an error. When `expectedMessageFragment` is
	-- given, the error message must contain it (plain-text match, not a pattern).
	function matchers.toThrow(expectedMessageFragment: string?)
		if type(actualValue) ~= "function" then
			raiseExpectationFailure(string.format("Expected a function but got %s", describe(actualValue)))
		end
		local didSucceed, raisedError = pcall(actualValue)
		if didSucceed then
			raiseExpectationFailure("Expected the function to throw, but it returned normally")
		end
		if expectedMessageFragment == nil then
			return
		end
		local raisedErrorMessage = if UnitTestExpectations.isExpectationFailure(raisedError)
			then raisedError.failureMessage
			else tostring(raisedError)
		if not string.find(raisedErrorMessage, expectedMessageFragment, 1, true) then
			raiseExpectationFailure(
				string.format(
					"Expected the thrown error to contain %s, but it was %s",
					describe(expectedMessageFragment),
					describe(raisedErrorMessage)
				)
			)
		end
	end

	return matchers
end

return UnitTestExpectations
