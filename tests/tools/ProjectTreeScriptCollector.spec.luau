-- Unit: ProjectTreeScriptCollector with an in-memory folder tree.

local UnitTestFramework = require("../Support/UnitTestFramework")
local ProjectTreeScriptCollector = require("../../tools/ProjectTreeScriptCollector")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

-- folderTree: nested tables are directories, strings are file contents.
local function createInMemoryFileReader(folderTree)
	local function findEntry(pathFromProjectRoot: string)
		local currentEntry = folderTree
		for pathName in string.gmatch(pathFromProjectRoot, "[^/]+") do
			if type(currentEntry) ~= "table" then
				return nil
			end
			currentEntry = currentEntry[pathName]
		end
		return currentEntry
	end
	return {
		isDirectory = function(pathFromProjectRoot: string): boolean
			return type(findEntry(pathFromProjectRoot)) == "table"
		end,
		listDirectoryEntryNames = function(pathFromProjectRoot: string): { string }
			local entryNames = {}
			for entryName in findEntry(pathFromProjectRoot) do
				table.insert(entryNames, entryName)
			end
			return entryNames
		end,
		readTextFile = function(pathFromProjectRoot: string): string
			return findEntry(pathFromProjectRoot)
		end,
	}
end

local THIS_PROJECT_TREE = {
	tree = {
		["$className"] = "DataModel",
		ReplicatedStorage = { Shared = { ["$path"] = "src/shared" } },
		ServerScriptService = { Server = { ["$path"] = "src/server" } },
		StarterPlayer = { StarterPlayerScripts = { Client = { ["$path"] = "src/client" } } },
	},
}

local function collect(folderTree, projectTree)
	return ProjectTreeScriptCollector.collectProjectScripts(
		projectTree or THIS_PROJECT_TREE,
		createInMemoryFileReader(folderTree)
	)
end

local function expectCollectionToRaise(folderTree, projectTree, expectedFragment: string)
	expect(function()
		collect(folderTree, projectTree)
	end).toThrow(expectedFragment)
end

describe("ProjectTreeScriptCollector.mapSourceFileNameToScript", function()
	it("maps the three suffixes and nothing else", function()
		expect({ ProjectTreeScriptCollector.mapSourceFileNameToScript("Main.server.luau") }).toEqual({
			"Main",
			"Script",
		})
		expect({ ProjectTreeScriptCollector.mapSourceFileNameToScript("Main.client.luau") }).toEqual({
			"Main",
			"LocalScript",
		})
		expect({ ProjectTreeScriptCollector.mapSourceFileNameToScript("Lookup.luau") }).toEqual({
			"Lookup",
			"ModuleScript",
		})
		expect({ ProjectTreeScriptCollector.mapSourceFileNameToScript("notes.md") }).toEqual({})
		expect({ ProjectTreeScriptCollector.mapSourceFileNameToScript("Old.lua") }).toEqual({})
		expect({ ProjectTreeScriptCollector.mapSourceFileNameToScript(".luau") }).toEqual({})
	end)

	it("raises for init files", function()
		for _, initFileName in { "init.luau", "init.server.luau", "init.client.luau" } do
			expect(function()
				ProjectTreeScriptCollector.mapSourceFileNameToScript(initFileName)
			end).toThrow("init files are not used")
		end
	end)
end)

describe("ProjectTreeScriptCollector.collectProjectScripts", function()
	it("collects this project's layout: mapped folders, sub-folders (empty ones too) and scripts, sorted", function()
		local collectedProject = collect({
			src = {
				shared = {
					["B.luau"] = "b",
					["A.luau"] = "a",
					generated = { ["Pool.luau"] = "p" },
					[".DS_Store"] = "x",
				},
				server = { ["Main.server.luau"] = "m", Empty = {} },
				client = {},
			},
		})
		expect(collectedProject.mappedFolders).toEqual({
			{
				existingParentPathNames = { "ReplicatedStorage" },
				mappedFolderName = "Shared",
				sourceDirectoryPath = "src/shared",
			},
			{
				existingParentPathNames = { "ServerScriptService" },
				mappedFolderName = "Server",
				sourceDirectoryPath = "src/server",
			},
			{
				existingParentPathNames = { "StarterPlayer", "StarterPlayerScripts" },
				mappedFolderName = "Client",
				sourceDirectoryPath = "src/client",
			},
		})
		expect(collectedProject.projectFolders).toEqual({
			{ mappedFolderNumber = 1, relativePathNames = { "generated" } },
			{ mappedFolderNumber = 2, relativePathNames = { "Empty" } },
		})
		expect(collectedProject.projectScripts).toEqual({
			{
				mappedFolderNumber = 1,
				relativePathNames = { "A" },
				className = "ModuleScript",
				sourceText = "a",
				sourceFilePath = "src/shared/A.luau",
			},
			{
				mappedFolderNumber = 1,
				relativePathNames = { "B" },
				className = "ModuleScript",
				sourceText = "b",
				sourceFilePath = "src/shared/B.luau",
			},
			{
				mappedFolderNumber = 1,
				relativePathNames = { "generated", "Pool" },
				className = "ModuleScript",
				sourceText = "p",
				sourceFilePath = "src/shared/generated/Pool.luau",
			},
			{
				mappedFolderNumber = 2,
				relativePathNames = { "Main" },
				className = "Script",
				sourceText = "m",
				sourceFilePath = "src/server/Main.server.luau",
			},
		})
	end)

	it("raises for a file that is not a script, an init file, and two files with one instance name", function()
		local baseTree = function(sharedFolder)
			return { src = { shared = sharedFolder, server = {}, client = {} } }
		end
		expectCollectionToRaise(
			baseTree({ ["notes.md"] = "x" }),
			nil,
			"not a .luau script file, the Studio sync cannot map it: src/shared/notes.md"
		)
		expectCollectionToRaise(baseTree({ ["init.luau"] = "x" }), nil, "init files are not used")
		expectCollectionToRaise(
			baseTree({ ["Main.luau"] = "x", ["Main.server.luau"] = "y" }),
			nil,
			"map to the same instance name Main"
		)
		expectCollectionToRaise(baseTree({ ["Main.luau"] = "x", Main = {} }), nil, "map to the same instance name Main")
	end)

	it("raises for project nodes the Studio sync does not support", function()
		local folderTree = { src = { shared = {}, file = "x" } }
		local unsupportedTrees = {
			{ projectTree = { tree = { ["$className"] = "Workspace" } }, expectedFragment = "tree root must be" },
			{
				projectTree = { tree = { ["$className"] = "DataModel", ["$path"] = "src" } },
				expectedFragment = "tree root must be",
			},
			{ projectTree = {}, expectedFragment = "the project has no tree" },
			{
				projectTree = {
					tree = { ["$className"] = "DataModel", ReplicatedStorage = { ["$path"] = "src/shared" } },
				},
				expectedFragment = "is a service",
			},
			{
				projectTree = {
					tree = {
						["$className"] = "DataModel",
						ReplicatedStorage = {
							Shared = { ["$path"] = "src/shared", Extra = { ["$path"] = "src/shared" } },
						},
					},
				},
				expectedFragment = "has both $path and child nodes",
			},
			{
				projectTree = {
					tree = { ["$className"] = "DataModel", ReplicatedStorage = { Shared = { ["$path"] = "src/file" } } },
				},
				expectedFragment = "is not a directory: src/file",
			},
			{
				projectTree = {
					tree = {
						["$className"] = "DataModel",
						ReplicatedStorage = { Shared = { ["$className"] = "Folder" } },
					},
				},
				expectedFragment = "uses $className",
			},
			{
				projectTree = { tree = { ["$className"] = "DataModel", ReplicatedStorage = { Shared = {} } } },
				expectedFragment = "has neither $path nor child nodes",
			},
			{
				projectTree = { tree = { ["$className"] = "DataModel", ReplicatedStorage = { Shared = "src/shared" } } },
				expectedFragment = "is not an object",
			},
		}
		for _, unsupportedTree in unsupportedTrees do
			expectCollectionToRaise(folderTree, unsupportedTree.projectTree, unsupportedTree.expectedFragment)
		end
	end)
end)
