-- Single entry point for every unit test:  lune run tests/RunAllTests.luau
--
-- Finds every `*.spec.luau` file under tests/ (recursively), loads it so it registers its
-- tests, runs them all, prints a summary, and exits with status 1 if anything failed:
-- a failing test, a spec file that errors while loading, a spec file with no tests,
-- or no spec files at all.
--
-- Before loading any spec file, every .luau file under src/, tools/ and tests/ is compiled once.
-- If any has a syntax error, the run reports it and exits 1 without requiring anything. This
-- guard exists because Lune 0.11.1 waits forever when a second `require` reaches a module whose
-- first `require` failed with a syntax error, so a broken module required by two spec files
-- would otherwise hang the whole run instead of failing it. (A module that raises an error while
-- running does not hang; it is reported below as a spec-file problem.)

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local UnitTestFramework = require("./Support/UnitTestFramework")

-- Folders, relative to the project root, whose .luau files are compiled before any spec loads.
local SYNTAX_CHECKED_FOLDER_NAMES = { "src", "tools", "tests" }
local LUAU_FILE_SUFFIX = ".luau"

local SPEC_FILE_SUFFIX = ".spec.luau"

-- debug.info gives this script's own path without the extension; tests/ is its folder.
-- This makes the runner independent of the current working directory.
local function findTestsFolderPath(): string
	local runnerScriptPath = debug.info(1, "s")
	local testsFolderPath = string.match(runnerScriptPath, "^(.*)[/\\][^/\\]+$")
	if testsFolderPath == nil then
		error("RunAllTests: cannot work out the tests folder from " .. tostring(runnerScriptPath))
	end
	return testsFolderPath
end

local function collectSpecFileRelativePaths(
	testsFolderPath: string,
	relativeFolderPath: string,
	specFileRelativePaths: { string }
)
	local absoluteFolderPath = if relativeFolderPath == ""
		then testsFolderPath
		else testsFolderPath .. "/" .. relativeFolderPath
	for _, entryName in fs.readDir(absoluteFolderPath) do
		local entryRelativePath = if relativeFolderPath == "" then entryName else relativeFolderPath .. "/" .. entryName
		if fs.isDir(testsFolderPath .. "/" .. entryRelativePath) then
			collectSpecFileRelativePaths(testsFolderPath, entryRelativePath, specFileRelativePaths)
		elseif string.sub(entryName, -#SPEC_FILE_SUFFIX) == SPEC_FILE_SUFFIX then
			table.insert(specFileRelativePaths, entryRelativePath)
		end
	end
end

local function loadSpecFileAndReportProblem(specFileRelativePath: string): string?
	UnitTestFramework.beginCollectingTestsForSpecFile(specFileRelativePath)
	local requirePathWithoutExtension = "./" .. string.sub(specFileRelativePath, 1, -#".luau" - 1)
	local didLoad, loadError = pcall(require, requirePathWithoutExtension)
	if not didLoad then
		return "failed to load: " .. tostring(loadError)
	end
	if UnitTestFramework.countCollectedTestsForSpecFile(specFileRelativePath) == 0 then
		return "registered no tests"
	end
	return nil
end

local function collectLuauFilePaths(folderPath: string, luauFilePaths: { string })
	for _, entryName in fs.readDir(folderPath) do
		local entryPath = folderPath .. "/" .. entryName
		if fs.isDir(entryPath) then
			collectLuauFilePaths(entryPath, luauFilePaths)
		elseif string.sub(entryName, -#LUAU_FILE_SUFFIX) == LUAU_FILE_SUFFIX then
			table.insert(luauFilePaths, entryPath)
		end
	end
end

-- Returns one line per .luau file that does not compile, in path order.
local function findLuauFilesWithSyntaxErrors(projectRootFolderPath: string): { string }
	local luauFilePaths = {}
	for _, checkedFolderName in SYNTAX_CHECKED_FOLDER_NAMES do
		local checkedFolderPath = projectRootFolderPath .. "/" .. checkedFolderName
		if fs.isDir(checkedFolderPath) then
			collectLuauFilePaths(checkedFolderPath, luauFilePaths)
		end
	end
	table.sort(luauFilePaths)
	local syntaxErrorLines = {}
	for _, luauFilePath in luauFilePaths do
		local didCompile, compileError = pcall(luau.compile, fs.readFile(luauFilePath))
		if not didCompile then
			table.insert(syntaxErrorLines, luauFilePath .. " :: " .. tostring(compileError))
		end
	end
	return syntaxErrorLines
end

local testsFolderPath = findTestsFolderPath()
local syntaxErrorLines = findLuauFilesWithSyntaxErrors(testsFolderPath .. "/..")
if #syntaxErrorLines > 0 then
	for _, syntaxErrorLine in syntaxErrorLines do
		print("  FAIL  syntax error in " .. syntaxErrorLine)
	end
	print("")
	print(string.format("%d file(s) with syntax errors; no tests were run", #syntaxErrorLines))
	process.exit(1)
end

local specFileRelativePaths = {}
collectSpecFileRelativePaths(testsFolderPath, "", specFileRelativePaths)
table.sort(specFileRelativePaths)

local specFileProblemCount = 0
for _, specFileRelativePath in specFileRelativePaths do
	local specFileProblem = loadSpecFileAndReportProblem(specFileRelativePath)
	if specFileProblem then
		specFileProblemCount += 1
		print("  FAIL  " .. specFileRelativePath .. " :: " .. specFileProblem)
	end
end

local passedTestCount, failedTestCount = UnitTestFramework.runCollectedTestsAndReportOutcomes()

print("")
print(
	string.format(
		"%d spec files, %d tests: %d passed, %d failed, %d spec file problems",
		#specFileRelativePaths,
		passedTestCount + failedTestCount,
		passedTestCount,
		failedTestCount,
		specFileProblemCount
	)
)

if #specFileRelativePaths == 0 then
	print("No spec files found under " .. testsFolderPath)
	process.exit(1)
end
if failedTestCount > 0 or specFileProblemCount > 0 then
	process.exit(1)
end
process.exit(0)
