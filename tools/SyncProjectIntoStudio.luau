-- Writes the batches that load this project's source into an open Roblox Studio place, without
-- the Rojo Studio plugin (README "Loading the project into Roblox Studio").
--
--   lune run tools/SyncProjectIntoStudio.luau [--studio-manifest <file>] [--only <Name>[,<Name>...]]
--                                             [--output-folder <folder>]
--
-- Reads default.project.json and the folders it maps, and replaces the generated batch files in
-- build/studio-sync/ (files named "NN-*.luau"; any other file there, such as a saved manifest, is
-- kept). Each batch is then run, in file-name order, through the Studio MCP `execute_luau` tool
-- in Edit mode; each returns a report of what it created, updated, left unchanged and removed.
--   --studio-manifest <file>   the saved output of batch 00: only scripts that differ are written.
--   --only <names>             a partial sync: only the named scripts (instance names, comma
--                              separated) and every script they require are written and verified.
--                              Only requires that resolve INSIDE ROBLOX are followed (the WARNING
--                              lines list the others), so a script whose requires do not resolve
--                              there is selected without the modules those requires name.
--   --output-folder <folder>   write the batches there instead of build/studio-sync (the tests use
--                              this so they never replace the batches an operator generated).
-- Prints a warning for every require that will not resolve inside Roblox. Exits with status 1,
-- writing nothing, when the arguments or the project cannot be used.
-- The last batch also removes the folders listed in RETIRED_PROJECT_FOLDERS (mapped by an earlier
-- default.project.json) from the place.
-- The work is done by ProjectTreeScriptCollector, ProjectRequireResolver, StudioSyncRuntimeBundler,
-- StudioProjectSyncBatchRenderer and StudioSideProjectSyncRuntime; this file only reads, prints
-- and writes.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local ProjectRequireResolver = require("./ProjectRequireResolver")
local ProjectTreeScriptCollector = require("./ProjectTreeScriptCollector")
local StudioProjectSyncBatchRenderer = require("./StudioProjectSyncBatchRenderer")
local StudioSyncRuntimeBundler = require("./StudioSyncRuntimeBundler")

local PROJECT_FILE_NAME = "default.project.json"
local STUDIO_SYNC_BATCH_FOLDER = "build/studio-sync"
local RUNTIME_SOURCE_FOLDER = "tools"
local RUNTIME_SOURCE_NAME = "StudioSideProjectSyncRuntime"
-- Every byte of a batch passes through one execute_luau tool call that the agent driving Studio
-- writes out in full, after reading the batch file. Sources travel packed (about a fifth of their
-- size), so 64 KB of distinct source makes a batch file of roughly 13 to 16 KB.
local MAXIMUM_SOURCE_BYTES_PER_BATCH = 64000
-- Folders that an earlier default.project.json mapped and the current one does not: the last
-- batch removes them from the place (README "Loading the project into Roblox Studio").
-- ReplicatedStorage.Shared held src/shared until 2026-11-19, when each side got its own sibling
-- copy named "shared" so that require("../shared/X") resolves in Roblox as it does in Lune.
local RETIRED_PROJECT_FOLDERS = {
	{ existingParentPathNames = { "ReplicatedStorage" }, mappedFolderName = "Shared" },
}
local USAGE_TEXT = "usage: lune run tools/SyncProjectIntoStudio.luau [--studio-manifest <file>]"
	.. " [--only <Name>[,<Name>...]] [--output-folder <folder>]"

local function exitWithMessage(message: string): never
	print(message)
	process.exit(1)
	error("unreachable")
end

local function findProjectRootFolderPath(): string
	local toolScriptPath = debug.info(1, "s")
	local toolsFolderPath = string.match(toolScriptPath, "^(.*)[/\\][^/\\]+$")
	if toolsFolderPath == nil then
		exitWithMessage("SyncProjectIntoStudio: cannot work out the tools folder from " .. tostring(toolScriptPath))
	end
	return toolsFolderPath .. "/.."
end

local function readCommandOptions(): (string?, { string }?, string?)
	local studioManifestPath, selectedScriptNames, outputFolderPath = nil, nil, nil
	local commandArguments = process.args
	local argumentPosition = 1
	while argumentPosition <= #commandArguments do
		local optionName, optionValue = commandArguments[argumentPosition], commandArguments[argumentPosition + 1]
		local isManifestOption = optionName == "--studio-manifest" and studioManifestPath == nil
		local isOnlyOption = optionName == "--only" and selectedScriptNames == nil
		local isOutputFolderOption = optionName == "--output-folder" and outputFolderPath == nil
		if optionValue == nil or not (isManifestOption or isOnlyOption or isOutputFolderOption) then
			exitWithMessage(USAGE_TEXT)
		end
		if isManifestOption then
			studioManifestPath = optionValue
		elseif isOnlyOption then
			selectedScriptNames = string.split(optionValue, ",")
		else
			outputFolderPath = optionValue
		end
		argumentPosition += 2
	end
	return studioManifestPath, selectedScriptNames, outputFolderPath
end

local projectRootFolderPath = findProjectRootFolderPath()
local function resolveFromProjectRoot(pathFromProjectRoot: string): string
	return projectRootFolderPath .. "/" .. pathFromProjectRoot
end

local studioManifestPath, selectedScriptNames, outputFolderPath = readCommandOptions()
if studioManifestPath ~= nil and not fs.isFile(studioManifestPath) then
	exitWithMessage("SyncProjectIntoStudio: studio manifest not found: " .. studioManifestPath)
end

local didPrepare, preparedSyncOrError = pcall(function()
	local collectedProject = ProjectTreeScriptCollector.collectProjectScripts(
		serde.decode("json", fs.readFile(resolveFromProjectRoot(PROJECT_FILE_NAME))),
		{
			isDirectory = function(pathFromProjectRoot: string): boolean
				return fs.isDir(resolveFromProjectRoot(pathFromProjectRoot))
			end,
			listDirectoryEntryNames = function(pathFromProjectRoot: string): { string }
				return fs.readDir(resolveFromProjectRoot(pathFromProjectRoot))
			end,
			readTextFile = function(pathFromProjectRoot: string): string
				return fs.readFile(resolveFromProjectRoot(pathFromProjectRoot))
			end,
		}
	)
	return {
		collectedProject = collectedProject,
		projectRequires = ProjectRequireResolver.describeProjectRequires(collectedProject),
		selectedScriptNumberSet = if selectedScriptNames
			then ProjectRequireResolver.selectScriptsAndTheirRequires(collectedProject, selectedScriptNames)
			else nil,
	}
end)
if not didPrepare then
	exitWithMessage("SyncProjectIntoStudio: " .. tostring(preparedSyncOrError) .. "; nothing was written.")
end
local collectedProject = preparedSyncOrError.collectedProject

local function readRuntimeSourceText(runtimeSourceName: string): string
	return fs.readFile(resolveFromProjectRoot(RUNTIME_SOURCE_FOLDER .. "/" .. runtimeSourceName .. ".luau"))
end

local renderedSync = StudioProjectSyncBatchRenderer.renderStudioProjectSyncBatches(
	StudioSyncRuntimeBundler.bundleRuntimeSourceText(readRuntimeSourceText(RUNTIME_SOURCE_NAME), readRuntimeSourceText),
	collectedProject,
	{
		maximumSourceBytesPerBatch = MAXIMUM_SOURCE_BYTES_PER_BATCH,
		studioScriptManifestText = if studioManifestPath then fs.readFile(studioManifestPath) else nil,
		selectedScriptNumberSet = preparedSyncOrError.selectedScriptNumberSet,
		retiredFolders = RETIRED_PROJECT_FOLDERS,
	}
)

local shownBatchFolderPath = outputFolderPath or STUDIO_SYNC_BATCH_FOLDER
local batchFolderPath = outputFolderPath or resolveFromProjectRoot(STUDIO_SYNC_BATCH_FOLDER)
if not fs.isDir(batchFolderPath) then
	fs.writeDir(batchFolderPath)
end
for _, existingFileName in fs.readDir(batchFolderPath) do
	if string.match(existingFileName, "^%d%d%-.*%.luau$") then
		fs.removeFile(batchFolderPath .. "/" .. existingFileName)
	end
end

for _, unresolvableRequire in preparedSyncOrError.projectRequires.unresolvableRequires do
	print(
		string.format(
			'WARNING: in Roblox, %s cannot resolve require("%s"): it points at no ModuleScript of this project',
			unresolvableRequire.requiringScriptFullName,
			unresolvableRequire.requirePath
		)
	)
end
print(
	string.format(
		"SyncProjectIntoStudio: %d scripts in the project, %d selected%s, %d to write%s",
		#collectedProject.projectScripts,
		renderedSync.selectedScriptCount,
		if selectedScriptNames
			then " (--only " .. table.concat(selectedScriptNames, ",") .. " and their requires)"
			else "",
		renderedSync.writtenScriptCount,
		if studioManifestPath
			then " (the others already match " .. studioManifestPath .. ")"
			else " (no manifest given: writing every selected script)"
	)
)
print("Run these in Roblox Studio, Edit mode, through execute_luau, in this order:")
for _, studioSyncBatch in renderedSync.studioSyncBatches do
	fs.writeFile(batchFolderPath .. "/" .. studioSyncBatch.batchFileName, studioSyncBatch.batchSourceText)
	print(
		string.format(
			"  %s/%s  (%s; %d scripts; %d bytes)",
			shownBatchFolderPath,
			studioSyncBatch.batchFileName,
			studioSyncBatch.batchLabel,
			studioSyncBatch.writtenScriptCount,
			#studioSyncBatch.batchSourceText
		)
	)
end
print(
	"Batch 00 installs the runtime the others use and changes nothing in the place; save its output to use --studio-manifest next time."
)
print("The last batch's report must start with exactly this line: " .. renderedSync.expectedVerificationReportFirstLine)
process.exit(0)
