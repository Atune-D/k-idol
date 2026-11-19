-- Unit: item-pool tool, end to end (development spec §6.2). Runs the real command-line tool on
-- fake CSV files written to build/ (ignored by git) and checks its exit status, its printed
-- problems and the module it writes. All ids here are fake (9000001 and up).

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function findProjectRootFolderPath(): string
	local specFilePath = debug.info(1, "s")
	local projectRootFolderPath = string.match(specFilePath, "^(.*)[/\\]tests[/\\]tools[/\\][^/\\]+$")
	assert(projectRootFolderPath ~= nil, "cannot work out the project root from " .. tostring(specFilePath))
	return projectRootFolderPath
end

local PROJECT_ROOT_FOLDER_PATH = findProjectRootFolderPath()
local TOOL_SCRIPT_PATH = PROJECT_ROOT_FOLDER_PATH .. "/tools/GenerateStylingItemPool.luau"
local SCRATCH_FOLDER_PATH = PROJECT_ROOT_FOLDER_PATH .. "/build/generate-styling-item-pool-test"
local CSV_HEADER_LINE = "marketplaceItemKind,marketplaceItemId,itemSlot,styleTags,primaryColorTag,isEnabled"

local function prepareScratchFolder()
	if fs.isDir(SCRATCH_FOLDER_PATH) then
		fs.removeDir(SCRATCH_FOLDER_PATH)
	end
	fs.writeDir(SCRATCH_FOLDER_PATH)
end

local function runGenerateStylingItemPoolTool(csvText: string)
	prepareScratchFolder()
	local csvPath = SCRATCH_FOLDER_PATH .. "/styling-item-pool.csv"
	local generatedModulePath = SCRATCH_FOLDER_PATH .. "/generated/StylingItemPool.luau"
	fs.writeFile(csvPath, csvText)
	local toolRun = process.exec("lune", { "run", TOOL_SCRIPT_PATH, csvPath, generatedModulePath })
	return toolRun, generatedModulePath
end

describe("GenerateStylingItemPool command", function()
	it("exits 0 and writes a module matching the CSV for a valid file", function()
		local toolRun, generatedModulePath = runGenerateStylingItemPoolTool(
			CSV_HEADER_LINE .. '\nAsset,9000011,top,"y2k, cute",pink,true\nBundle,9000041,shoes,cute,white,false\n'
		)
		expect(toolRun.code).toBe(0)
		expect(fs.isFile(generatedModulePath)).toBeTrue()
		local generatedModule = luau.load(fs.readFile(generatedModulePath))()
		expect(generatedModule.STYLING_ITEMS).toEqual({
			{
				stylingItemKey = "asset_9000011",
				marketplaceItemKind = "Asset",
				marketplaceItemId = 9000011,
				itemSlot = "top",
				styleTags = { "y2k", "cute" },
				primaryColorTag = "pink",
				isEnabled = true,
			},
			{
				stylingItemKey = "bundle_9000041",
				marketplaceItemKind = "Bundle",
				marketplaceItemId = 9000041,
				itemSlot = "shoes",
				styleTags = { "cute" },
				primaryColorTag = "white",
				isEnabled = false,
			},
		})
	end)

	it("exits non-zero, prints every problem with its row number and writes nothing for a bad file", function()
		local toolRun, generatedModulePath = runGenerateStylingItemPoolTool(
			CSV_HEADER_LINE .. "\nAsset,9000041,shoes,cute,white,true\nAsset,9000001,hair,,pink,true\n"
		)
		expect(toolRun.code).toBe(1)
		expect(fs.isFile(generatedModulePath)).toBeFalse()
		expect(string.find(toolRun.stdout, "2 problem(s)", 1, true) ~= nil).toBeTrue()
		expect(string.find(toolRun.stdout, "row 2: a shoes row must have marketplaceItemKind Bundle", 1, true) ~= nil).toBeTrue()
		expect(string.find(toolRun.stdout, "row 3: styleTags is empty", 1, true) ~= nil).toBeTrue()
	end)

	it("exits non-zero when the CSV file does not exist", function()
		prepareScratchFolder()
		local toolRun = process.exec(
			"lune",
			{ "run", TOOL_SCRIPT_PATH, SCRATCH_FOLDER_PATH .. "/missing.csv", SCRATCH_FOLDER_PATH .. "/out.luau" }
		)
		expect(toolRun.code).toBe(1)
	end)
end)
