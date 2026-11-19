-- Validates the owner's styling item pool spreadsheet and generates the game module from it
-- (development spec §1.2).
--
--   lune run tools/GenerateStylingItemPool.luau [csvPath] [generatedModulePath]
--
-- Defaults: data/styling-item-pool.csv -> src/shared/generated/StylingItemPool.luau, both
-- relative to the project root (found from this script's own location, not the current folder).
--
-- Every problem is printed with its spreadsheet row number (the header is row 1). On any problem
-- the tool exits with status 1 and does not write the generated module. All parsing, validation
-- and rendering live in StylingItemPoolCsvCompiler; this file only reads, prints and writes.

local fs = require("@lune/fs")
local process = require("@lune/process")

local StylingItemPoolCsvCompiler = require("./StylingItemPoolCsvCompiler")

local DEFAULT_CSV_PATH_FROM_PROJECT_ROOT = "data/styling-item-pool.csv"
local DEFAULT_GENERATED_MODULE_PATH_FROM_PROJECT_ROOT = "src/shared/generated/StylingItemPool.luau"

local function findProjectRootFolderPath(): string
	local toolScriptPath = debug.info(1, "s")
	local toolsFolderPath = string.match(toolScriptPath, "^(.*)[/\\][^/\\]+$")
	if toolsFolderPath == nil then
		error("GenerateStylingItemPool: cannot work out the tools folder from " .. tostring(toolScriptPath))
	end
	return toolsFolderPath .. "/.."
end

local function findParentFolderPath(filePath: string): string?
	return string.match(filePath, "^(.*)[/\\][^/\\]+$")
end

local projectRootFolderPath = findProjectRootFolderPath()
local csvPath = process.args[1] or (projectRootFolderPath .. "/" .. DEFAULT_CSV_PATH_FROM_PROJECT_ROOT)
local generatedModulePath = process.args[2]
	or (projectRootFolderPath .. "/" .. DEFAULT_GENERATED_MODULE_PATH_FROM_PROJECT_ROOT)

if not fs.isFile(csvPath) then
	print("GenerateStylingItemPool: CSV file not found: " .. csvPath)
	process.exit(1)
end

local stylingItemPoolCompilation = StylingItemPoolCsvCompiler.compileStylingItemPoolCsv(fs.readFile(csvPath))

if #stylingItemPoolCompilation.csvProblems > 0 then
	print(
		string.format(
			"GenerateStylingItemPool: %d problem(s) in %s; nothing was written.",
			#stylingItemPoolCompilation.csvProblems,
			csvPath
		)
	)
	for _, csvProblem in stylingItemPoolCompilation.csvProblems do
		print("  " .. StylingItemPoolCsvCompiler.formatCsvProblemForConsole(csvProblem))
	end
	process.exit(1)
end

local generatedModuleFolderPath = findParentFolderPath(generatedModulePath)
if generatedModuleFolderPath ~= nil and not fs.isDir(generatedModuleFolderPath) then
	fs.writeDir(generatedModuleFolderPath)
end
fs.writeFile(
	generatedModulePath,
	StylingItemPoolCsvCompiler.renderGeneratedStylingItemPoolModuleSource(stylingItemPoolCompilation.stylingItems)
)
print(
	string.format(
		"GenerateStylingItemPool: wrote %d styling item(s) to %s",
		#stylingItemPoolCompilation.stylingItems,
		generatedModulePath
	)
)
process.exit(0)
