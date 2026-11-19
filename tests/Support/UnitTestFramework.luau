-- A small, dependency-free unit test framework for Lune.
--
-- Spec files call `describe` and `it` while they are being loaded; nothing runs at that moment.
-- RunAllTests then calls `runCollectedTestsAndReportOutcomes`, which runs every collected test,
-- prints one line per test and returns the number of failures.
--
-- Tests never wait for real time. Code under test receives a FakeClock / FakeScheduler instead.

local UnitTestExpectations = require("./UnitTestExpectations")

local UnitTestFramework = {}

type CollectedTest = {
	specFileLabel: string,
	fullTestName: string,
	testBody: () -> (),
}

local collectedTests: { CollectedTest } = {}
local describeBlockNameStack: { string } = {}
local currentSpecFileLabel = "(no spec file)"
local collectedTestCountBySpecFileLabel: { [string]: number } = {}

UnitTestFramework.expect = UnitTestExpectations.expect

function UnitTestFramework.beginCollectingTestsForSpecFile(specFileLabel: string)
	currentSpecFileLabel = specFileLabel
	collectedTestCountBySpecFileLabel[specFileLabel] = 0
	table.clear(describeBlockNameStack)
end

function UnitTestFramework.countCollectedTestsForSpecFile(specFileLabel: string): number
	return collectedTestCountBySpecFileLabel[specFileLabel] or 0
end

function UnitTestFramework.describe(describeBlockName: string, describeBlockBody: () -> ())
	table.insert(describeBlockNameStack, describeBlockName)
	-- Pop the name even if the block errors, so one broken spec file cannot rename later tests.
	local didSucceed, raisedError = pcall(describeBlockBody)
	table.remove(describeBlockNameStack)
	if not didSucceed then
		error(raisedError, 0)
	end
end

function UnitTestFramework.it(testName: string, testBody: () -> ())
	local fullNameParts = table.clone(describeBlockNameStack)
	table.insert(fullNameParts, testName)
	table.insert(collectedTests, {
		specFileLabel = currentSpecFileLabel,
		fullTestName = table.concat(fullNameParts, " > "),
		testBody = testBody,
	})
	collectedTestCountBySpecFileLabel[currentSpecFileLabel] = (
		collectedTestCountBySpecFileLabel[currentSpecFileLabel] or 0
	) + 1
end

local function describeTestFailure(raisedError: any): string
	if UnitTestExpectations.isExpectationFailure(raisedError) then
		return raisedError.failureMessage .. "\n        at " .. raisedError.failedAtSourceLocation
	end
	return "Unexpected error: " .. tostring(raisedError)
end

local function captureFailureWithTraceback(raisedError: any): any
	if UnitTestExpectations.isExpectationFailure(raisedError) then
		return raisedError
	end
	return debug.traceback(tostring(raisedError), 2)
end

-- Runs every collected test once, prints PASS/FAIL lines, and returns the failure count.
function UnitTestFramework.runCollectedTestsAndReportOutcomes(): (number, number)
	local passedTestCount = 0
	local failedTestCount = 0
	for _, collectedTest in collectedTests do
		local didPass, raisedError = xpcall(collectedTest.testBody, captureFailureWithTraceback)
		local testLabel = collectedTest.specFileLabel .. " :: " .. collectedTest.fullTestName
		if didPass then
			passedTestCount += 1
			print("  PASS  " .. testLabel)
		else
			failedTestCount += 1
			print("  FAIL  " .. testLabel)
			print("        " .. describeTestFailure(raisedError))
		end
	end
	return passedTestCount, failedTestCount
end

return UnitTestFramework
