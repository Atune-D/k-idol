-- The committed generated module must be exactly what the tool produces from the committed CSV
-- (development spec §1.2: the generated file is never edited by hand), and the game must accept
-- it, including when the pool is empty.

local fs = require("@lune/fs")

local UnitTestFramework = require("../Support/UnitTestFramework")
local StylingItemPoolCsvCompiler = require("../../tools/StylingItemPoolCsvCompiler")
local StylingItemLookup = require("../../src/shared/StylingItemLookup")
local StylingItemPool = require("../../src/shared/generated/StylingItemPool")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function findProjectRootFolderPath(): string
	local specFilePath = debug.info(1, "s")
	local projectRootFolderPath = string.match(specFilePath, "^(.*)[/\\]tests[/\\]shared[/\\][^/\\]+$")
	assert(projectRootFolderPath ~= nil, "cannot work out the project root from " .. tostring(specFilePath))
	return projectRootFolderPath
end

local PROJECT_ROOT_FOLDER_PATH = findProjectRootFolderPath()

describe("generated StylingItemPool", function()
	it("the committed CSV has no problems", function()
		local compilation = StylingItemPoolCsvCompiler.compileStylingItemPoolCsv(
			fs.readFile(PROJECT_ROOT_FOLDER_PATH .. "/data/styling-item-pool.csv")
		)
		expect(compilation.csvProblems).toEqual({})
	end)

	it("the committed module is byte-for-byte what the tool generates from the committed CSV", function()
		local compilation = StylingItemPoolCsvCompiler.compileStylingItemPoolCsv(
			fs.readFile(PROJECT_ROOT_FOLDER_PATH .. "/data/styling-item-pool.csv")
		)
		local expectedModuleSource =
			StylingItemPoolCsvCompiler.renderGeneratedStylingItemPoolModuleSource(compilation.stylingItems)
		local committedModuleSource =
			fs.readFile(PROJECT_ROOT_FOLDER_PATH .. "/src/shared/generated/StylingItemPool.luau")
		expect(committedModuleSource == expectedModuleSource).toBeTrue()
	end)

	it("builds a lookup without error, even when empty, and is frozen", function()
		local stylingItemByStylingItemKey =
			StylingItemLookup.buildStylingItemByStylingItemKey(StylingItemPool.STYLING_ITEMS)
		expect(type(stylingItemByStylingItemKey)).toBe("table")
		expect(table.isfrozen(StylingItemPool)).toBeTrue()
		expect(table.isfrozen(StylingItemPool.STYLING_ITEMS)).toBeTrue()
	end)
end)
