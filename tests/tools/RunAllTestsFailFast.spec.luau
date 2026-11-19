-- tests/RunAllTests.luau must fail fast (exit 1 within seconds), not hang, when a module that two
-- spec files require has a syntax error. Lune 0.11.1 waits forever on the second `require` of
-- such a module, so the runner compiles every file first.
--
-- The check builds a tiny throwaway project under build/ (ignored by git): a copy of the real
-- runner and tests/Support, a module with a syntax error, and two spec files that require it.
-- The child run is started in its own process group through a small perl wrapper that kills the
-- whole group after CHILD_RUN_TIME_LIMIT_SECONDS and exits 124. The whole group matters: the
-- `lune` on PATH may be a toolchain shim (Rokit) that starts the real Lune as a child, and killing
-- only the shim would leave the hung Lune running. If the guard ever breaks, this test therefore
-- fails after the limit instead of hanging the suite.

local fs = require("@lune/fs")
local process = require("@lune/process")

local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local CHILD_RUN_TIME_LIMIT_SECONDS = 20
local EXPECTED_FAST_FAILURE_SECONDS = 10
local TIMED_OUT_EXIT_CODE = 124

-- Forks; the child moves into a new process group and execs the command; the parent kills the
-- whole group when the alarm fires, otherwise passes the child's exit status through.
local TIME_LIMITED_PROCESS_GROUP_PERL_SCRIPT = table.concat({
	"my $childProcessId = fork();",
	"if ($childProcessId == 0) { setpgrp(0, 0); exec(@ARGV) or exit(127); }",
	"$SIG{ALRM} = sub { kill('KILL', -$childProcessId); exit(" .. tostring(TIMED_OUT_EXIT_CODE) .. "); };",
	"alarm(%d);",
	"waitpid($childProcessId, 0);",
	"exit($? >> 8);",
}, " ")

local function findProjectRootFolderPath(): string
	local specFilePath = debug.info(1, "s")
	local projectRootFolderPath = string.match(specFilePath, "^(.*)[/\\]tests[/\\]tools[/\\][^/\\]+$")
	assert(projectRootFolderPath ~= nil, "cannot work out the project root from " .. tostring(specFilePath))
	return projectRootFolderPath
end

local PROJECT_ROOT_FOLDER_PATH = findProjectRootFolderPath()
local THROWAWAY_PROJECT_FOLDER_PATH = PROJECT_ROOT_FOLDER_PATH .. "/build/run-all-tests-fail-fast-test"

local function copyFolder(sourceFolderPath: string, destinationFolderPath: string)
	fs.writeDir(destinationFolderPath)
	for _, entryName in fs.readDir(sourceFolderPath) do
		local sourceEntryPath = sourceFolderPath .. "/" .. entryName
		if fs.isDir(sourceEntryPath) then
			copyFolder(sourceEntryPath, destinationFolderPath .. "/" .. entryName)
		else
			fs.writeFile(destinationFolderPath .. "/" .. entryName, fs.readFile(sourceEntryPath))
		end
	end
end

local function buildThrowawayProject(brokenModuleSource: string)
	if fs.isDir(THROWAWAY_PROJECT_FOLDER_PATH) then
		fs.removeDir(THROWAWAY_PROJECT_FOLDER_PATH)
	end
	fs.writeDir(THROWAWAY_PROJECT_FOLDER_PATH)
	fs.writeDir(THROWAWAY_PROJECT_FOLDER_PATH .. "/src")
	fs.writeDir(THROWAWAY_PROJECT_FOLDER_PATH .. "/tests")
	fs.writeFile(
		THROWAWAY_PROJECT_FOLDER_PATH .. "/tests/RunAllTests.luau",
		fs.readFile(PROJECT_ROOT_FOLDER_PATH .. "/tests/RunAllTests.luau")
	)
	copyFolder(PROJECT_ROOT_FOLDER_PATH .. "/tests/Support", THROWAWAY_PROJECT_FOLDER_PATH .. "/tests/Support")
	fs.writeFile(THROWAWAY_PROJECT_FOLDER_PATH .. "/src/DeliberatelyBrokenModule.luau", brokenModuleSource)
	local specSource = 'local UnitTestFramework = require("./Support/UnitTestFramework")\n'
		.. 'local DeliberatelyBrokenModule = require("../src/DeliberatelyBrokenModule")\n'
		.. 'UnitTestFramework.it("uses the module", function()\n'
		.. "\tassert(DeliberatelyBrokenModule ~= nil)\n"
		.. "end)\n"
	fs.writeFile(THROWAWAY_PROJECT_FOLDER_PATH .. "/tests/FirstUser.spec.luau", specSource)
	fs.writeFile(THROWAWAY_PROJECT_FOLDER_PATH .. "/tests/SecondUser.spec.luau", specSource)
end

local function runThrowawayProjectTestsWithTimeLimit()
	local wallClockStartedAtSeconds = os.time()
	local childRun = process.exec("perl", {
		"-e",
		string.format(TIME_LIMITED_PROCESS_GROUP_PERL_SCRIPT, CHILD_RUN_TIME_LIMIT_SECONDS),
		"lune",
		"run",
		THROWAWAY_PROJECT_FOLDER_PATH .. "/tests/RunAllTests.luau",
	})
	return childRun, os.time() - wallClockStartedAtSeconds
end

describe("RunAllTests fail-fast guard", function()
	it("exits 1 within seconds when a module required by two spec files has a syntax error", function()
		buildThrowawayProject("local brokenValue = \nreturn {}\n")
		local childRun, elapsedWallClockSeconds = runThrowawayProjectTestsWithTimeLimit()
		expect(childRun.code).toBe(1)
		expect(elapsedWallClockSeconds < EXPECTED_FAST_FAILURE_SECONDS).toBeTrue()
		expect(string.find(childRun.stdout, "syntax error in", 1, true) ~= nil).toBeTrue()
		expect(string.find(childRun.stdout, "DeliberatelyBrokenModule.luau", 1, true) ~= nil).toBeTrue()
	end)

	it("still runs normally and exits 0 when the module is fine", function()
		buildThrowawayProject("return {}\n")
		local childRun = runThrowawayProjectTestsWithTimeLimit()
		expect(childRun.code).toBe(0)
		expect(string.find(childRun.stdout, " 0 failed, 0 spec file problems", 1, true) ~= nil).toBeTrue()
	end)

	it("exits 1 within seconds when that module raises an error while loading", function()
		buildThrowawayProject('error("deliberate load failure")\nreturn {}\n')
		local childRun, elapsedWallClockSeconds = runThrowawayProjectTestsWithTimeLimit()
		expect(childRun.code).toBe(1)
		expect(elapsedWallClockSeconds < EXPECTED_FAST_FAILURE_SECONDS).toBeTrue()
		expect(string.find(childRun.stdout, "2 spec file problems", 1, true) ~= nil).toBeTrue()
	end)
end)
