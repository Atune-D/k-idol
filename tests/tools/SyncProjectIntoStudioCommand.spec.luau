-- Unit: the Studio sync command end to end on this project. It writes its batches to a test-only
-- folder under build/ (ignored by git) through --output-folder, so running the tests never replaces
-- the batches an operator generated in build/studio-sync/.

local fs = require("@lune/fs")
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
local TOOL_SCRIPT_PATH = PROJECT_ROOT_FOLDER_PATH .. "/tools/SyncProjectIntoStudio.luau"
local BATCH_FOLDER_PATH = PROJECT_ROOT_FOLDER_PATH .. "/build/test-sync-project-into-studio-command"

local function runSyncCommand(commandArguments: { string })
	local runArguments = { "run", TOOL_SCRIPT_PATH }
	for _, commandArgument in commandArguments do
		table.insert(runArguments, commandArgument)
	end
	return process.exec("lune", runArguments)
end

local function expectOutputToContain(commandRun, expectedFragment: string)
	if not string.find(commandRun.stdout, expectedFragment, 1, true) then
		expect(commandRun.stdout).toBe("output containing: " .. expectedFragment)
	end
end

describe("SyncProjectIntoStudio command", function()
	it("writes the batches of a partial sync and lists them in order, replacing older batch files", function()
		fs.writeDir(BATCH_FOLDER_PATH)
		fs.writeFile(BATCH_FOLDER_PATH .. "/09-stale-batch.luau", "stale")
		fs.writeFile(BATCH_FOLDER_PATH .. "/keep-me.txt", "kept")
		local commandRun = runSyncCommand({ "--only", "OutfitScoreCalculator", "--output-folder", BATCH_FOLDER_PATH })
		expect(commandRun.code).toBe(0)
		-- OutfitScoreCalculator and its three requires, once in each side's "shared" folder.
		expectOutputToContain(commandRun, "8 selected (--only OutfitScoreCalculator and their requires), 8 to write")
		expectOutputToContain(commandRun, BATCH_FOLDER_PATH .. "/00-install-runtime-and-read-manifest.luau")
		expectOutputToContain(
			commandRun,
			"remove unexpected instances and verify: sync complete, verified 8 of 8 selected scripts ("
		)
		expect(fs.isFile(BATCH_FOLDER_PATH .. "/00-install-runtime-and-read-manifest.luau")).toBeTrue()
		expect(fs.isFile(BATCH_FOLDER_PATH .. "/09-stale-batch.luau")).toBeFalse()
		expect(fs.readFile(BATCH_FOLDER_PATH .. "/keep-me.txt")).toBe("kept")
		fs.removeDir(BATCH_FOLDER_PATH)
	end)

	it(
		"loads the whole project with no unresolvable require and removes the retired ReplicatedStorage.Shared",
		function()
			local commandRun = runSyncCommand({ "--output-folder", BATCH_FOLDER_PATH })
			local batchFileNames = {}
			for _, fileName in if fs.isDir(BATCH_FOLDER_PATH) then fs.readDir(BATCH_FOLDER_PATH) else {} do
				if string.match(fileName, "^%d%d%-.*%.luau$") then
					table.insert(batchFileNames, fileName)
				end
			end
			table.sort(batchFileNames)
			local verificationBatchText = if #batchFileNames > 0
				then fs.readFile(BATCH_FOLDER_PATH .. "/" .. batchFileNames[#batchFileNames])
				else ""
			fs.removeDir(BATCH_FOLDER_PATH)
			expect(commandRun.code).toBe(0)
			expect(string.find(commandRun.stdout, "WARNING", 1, true)).toBeNil()
			expect(
				string.match(batchFileNames[#batchFileNames], "^%d%d%-remove%-unexpected%-and%-verify%.luau$") ~= nil
			).toBeTrue()
			expect(
				string.find(
					verificationBatchText,
					'retiredFolders={{existingParentPathNames={"ReplicatedStorage"},mappedFolderName="Shared"}}',
					1,
					true
				) ~= nil
			).toBeTrue()
			for _, mappedFolderText in
				{
					'{existingParentPathNames={"ServerScriptService"},mappedFolderName="Server"}',
					'{existingParentPathNames={"ServerScriptService"},mappedFolderName="shared"}',
					'{existingParentPathNames={"StarterPlayer","StarterPlayerScripts"},mappedFolderName="Client"}',
					'{existingParentPathNames={"StarterPlayer","StarterPlayerScripts"},mappedFolderName="shared"}',
				}
			do
				expect({ mappedFolderText, string.find(verificationBatchText, mappedFolderText, 1, true) ~= nil }).toEqual({
					mappedFolderText,
					true,
				})
			end
		end
	)

	it("exits 1 and writes nothing for bad arguments, an unknown script name or a missing manifest", function()
		for _, badArguments in
			{
				{ "--bogus", "x" },
				{ "--only" },
				{ "--only", "A", "--only", "B" },
				{ "--output-folder" },
				{ "--output-folder", "a", "--output-folder", "b" },
			}
		do
			local commandRun = runSyncCommand(badArguments)
			expect(commandRun.code).toBe(1)
			expectOutputToContain(commandRun, "usage: lune run tools/SyncProjectIntoStudio.luau")
		end
		local unknownNameRun = runSyncCommand({ "--only", "NoSuchScript", "--output-folder", BATCH_FOLDER_PATH })
		expect(unknownNameRun.code).toBe(1)
		expectOutputToContain(unknownNameRun, "no project script is named NoSuchScript; nothing was written.")
		local missingManifestRun = runSyncCommand({
			"--studio-manifest",
			BATCH_FOLDER_PATH .. "/no-such-manifest.txt",
			"--output-folder",
			BATCH_FOLDER_PATH,
		})
		expect(missingManifestRun.code).toBe(1)
		expectOutputToContain(missingManifestRun, "studio manifest not found")
		expect(fs.isDir(BATCH_FOLDER_PATH)).toBeFalse()
	end)
end)
