-- Unit: ProjectRequireResolver (Roblox's require-by-string rules applied to the project tree).

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local StudioProjectSyncTestHarness = require("./StudioProjectSyncTestHarness")
local ProjectRequireResolver = require("../../tools/ProjectRequireResolver")
local ProjectTreeScriptCollector = require("../../tools/ProjectTreeScriptCollector")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local buildProjectScript = StudioProjectSyncTestHarness.buildProjectScript

local REQUIRING_SCRIPT_PATH_NAMES = { "ServerScriptService", "Server", "Resolver" }

describe("ProjectRequireResolver.listRequirePathsInSource", function()
	it("lists double- and single-quoted requires in order and skips comment lines", function()
		local sourceText = table.concat({
			'local A = require("./A")',
			'-- local Skipped = require("./Skipped")',
			"local B = require( '../shared/B' ) local C = require(\"@game/ReplicatedStorage/C\")",
			"local D = require(script.Parent.D)",
		}, "\n")
		expect(ProjectRequireResolver.listRequirePathsInSource(sourceText)).toEqual({
			"./A",
			"@game/ReplicatedStorage/C",
			"../shared/B",
		})
	end)
end)

describe("ProjectRequireResolver.resolveRequirePath", function()
	it("follows ./, ../, @self/, @game/ and .. components", function()
		local resolve = function(requirePath)
			return ProjectRequireResolver.resolveRequirePath(REQUIRING_SCRIPT_PATH_NAMES, requirePath)
		end
		expect(resolve("./Sibling")).toEqual({ "ServerScriptService", "Server", "Sibling" })
		expect(resolve("../shared/Lookup")).toEqual({ "ServerScriptService", "shared", "Lookup" })
		expect(resolve("@self/Child")).toEqual({ "ServerScriptService", "Server", "Resolver", "Child" })
		expect(resolve("@game/ReplicatedStorage/Shared/Lookup")).toEqual({ "ReplicatedStorage", "Shared", "Lookup" })
		expect(resolve("./../../ReplicatedStorage/Shared/X")).toEqual({ "ReplicatedStorage", "Shared", "X" })
	end)

	it("answers nil for an unsupported prefix or a path that leaves the DataModel", function()
		expect(ProjectRequireResolver.resolveRequirePath(REQUIRING_SCRIPT_PATH_NAMES, "Lookup")).toBeNil()
		expect(ProjectRequireResolver.resolveRequirePath(REQUIRING_SCRIPT_PATH_NAMES, "@shared/Lookup")).toBeNil()
		expect(ProjectRequireResolver.resolveRequirePath(REQUIRING_SCRIPT_PATH_NAMES, "../../../../X")).toBeNil()
	end)

	it("never goes above the DataModel and keeps the requiring path untouched, for random paths", function()
		local pathComponents = { "..", "A", "B" }
		SeededRandomTrials.runSeededRandomTrials(200, function(randomNumberGenerator)
			local requirePath = randomNumberGenerator.pickRandomListElement({ "./", "../", "@self/", "@game/" })
			for _ = 1, randomNumberGenerator.nextWholeNumberInRange(0, 6) do
				requirePath ..= randomNumberGenerator.pickRandomListElement(pathComponents) .. "/"
			end
			requirePath ..= "Target"
			local requiringPathNames = table.clone(REQUIRING_SCRIPT_PATH_NAMES)
			local resolvedPathNames = ProjectRequireResolver.resolveRequirePath(requiringPathNames, requirePath)
			expect(requiringPathNames).toEqual(REQUIRING_SCRIPT_PATH_NAMES)
			if resolvedPathNames then
				expect(resolvedPathNames[#resolvedPathNames]).toBe("Target")
				expect(table.find(resolvedPathNames, "..")).toBeNil()
			end
		end)
	end)
end)

local function buildProjectWithRequires()
	return StudioProjectSyncTestHarness.buildCollectedProject({
		buildProjectScript(1, { "Lookup" }, "ModuleScript", 'local V = require("./Vocabulary")'),
		buildProjectScript(1, { "Vocabulary" }, "ModuleScript", "return {}"),
		buildProjectScript(1, { "Unused" }, "ModuleScript", "return {}"),
		buildProjectScript(
			2,
			{ "Resolver" },
			"ModuleScript",
			'local L = require("../shared/Lookup")\nlocal Q = require("./Queue")'
		),
		buildProjectScript(
			2,
			{ "Queue" },
			"ModuleScript",
			'local L = require("@game/ReplicatedStorage/Shared/Lookup")'
		),
		buildProjectScript(2, { "Main" }, "Script", 'local R = require("./Resolver")'),
	})
end

describe("ProjectRequireResolver.describeProjectRequires", function()
	-- The harness maps folder 1 to ServerScriptService.shared, 2 to ServerScriptService.Server, 3 to
	-- StarterPlayerScripts.Client and 4 to StarterPlayerScripts.shared (this project's layout).
	it("links requires that resolve to a project ModuleScript and lists those that do not resolve in Roblox", function()
		local projectRequires = ProjectRequireResolver.describeProjectRequires(buildProjectWithRequires())
		expect(projectRequires.scriptRequires).toEqual({ { 2 }, {}, {}, { 1, 5 }, {}, { 4 } })
		expect(projectRequires.unresolvableRequires).toEqual({
			{
				requiringScriptFullName = "ServerScriptService.Server.Queue",
				requirePath = "@game/ReplicatedStorage/Shared/Lookup",
			},
		})
	end)

	it("resolves ../shared/X from each side to that side's own shared copy", function()
		local collectedProject = StudioProjectSyncTestHarness.buildCollectedProject({
			buildProjectScript(1, { "Catalog" }, "ModuleScript", "return {}"),
			buildProjectScript(2, { "ServerUser" }, "ModuleScript", 'return require("../shared/Catalog")'),
			buildProjectScript(3, { "ClientUser" }, "ModuleScript", 'return require("../shared/Catalog")'),
			buildProjectScript(4, { "Catalog" }, "ModuleScript", "return {}"),
		})
		local projectRequires = ProjectRequireResolver.describeProjectRequires(collectedProject)
		expect(projectRequires.scriptRequires).toEqual({ {}, { 1 }, { 4 }, {} })
		expect(projectRequires.unresolvableRequires).toEqual({})
	end)

	it("finds no unresolvable require in this project as default.project.json maps it", function()
		local projectRootFolderPath = string.match(debug.info(1, "s"), "^(.*)[/\\]tests[/\\]tools[/\\][^/\\]+$")
		local function resolveFromProjectRoot(pathFromProjectRoot: string): string
			return projectRootFolderPath .. "/" .. pathFromProjectRoot
		end
		local collectedProject = ProjectTreeScriptCollector.collectProjectScripts(
			serde.decode("json", fs.readFile(resolveFromProjectRoot("default.project.json"))),
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
		local projectRequires = ProjectRequireResolver.describeProjectRequires(collectedProject)
		expect(projectRequires.unresolvableRequires).toEqual({})
		-- Every require stays inside the service of the requiring script (server code never reaches
		-- into StarterPlayer, device code never into ServerScriptService).
		local requireCount = 0
		for scriptNumber, requiredScriptNumbers in projectRequires.scriptRequires do
			local requiringFullPathNames = ProjectRequireResolver.buildScriptFullPathNames(
				collectedProject,
				collectedProject.projectScripts[scriptNumber]
			)
			for _, requiredScriptNumber in requiredScriptNumbers do
				requireCount += 1
				local requiredFullPathNames = ProjectRequireResolver.buildScriptFullPathNames(
					collectedProject,
					collectedProject.projectScripts[requiredScriptNumber]
				)
				expect({ requiringFullPathNames, requiredFullPathNames[1] }).toEqual({
					requiringFullPathNames,
					requiringFullPathNames[1],
				})
			end
		end
		expect(requireCount > 0).toBeTrue()
	end)

	it("does not count a Script as something a require can reach", function()
		local collectedProject = StudioProjectSyncTestHarness.buildCollectedProject({
			buildProjectScript(2, { "Main" }, "Script", "return 1"),
			buildProjectScript(2, { "User" }, "ModuleScript", 'return require("./Main")'),
		})
		expect(#ProjectRequireResolver.describeProjectRequires(collectedProject).unresolvableRequires).toBe(1)
	end)
end)

describe("ProjectRequireResolver.selectScriptsAndTheirRequires", function()
	it("selects the named scripts and everything they require, transitively", function()
		expect(ProjectRequireResolver.selectScriptsAndTheirRequires(buildProjectWithRequires(), { "Main" })).toEqual({
			[6] = true,
			[4] = true,
			[5] = true,
			[1] = true,
			[2] = true,
		})
		expect(
			ProjectRequireResolver.selectScriptsAndTheirRequires(buildProjectWithRequires(), { "Unused", "Vocabulary" })
		).toEqual({
			[3] = true,
			[2] = true,
		})
	end)

	it("raises for a name that matches no script", function()
		expect(function()
			ProjectRequireResolver.selectScriptsAndTheirRequires(buildProjectWithRequires(), { "Main", "Missing" })
		end).toThrow("no project script is named Missing")
	end)
end)

describe("ProjectRequireResolver.buildScriptFullPathNames", function()
	it("joins the mapped folder's parents, its name and the script's relative path", function()
		local collectedProject = buildProjectWithRequires()
		local scriptInClient = buildProjectScript(3, { "Ui", "Wardrobe" }, "LocalScript", "")
		expect(ProjectRequireResolver.buildScriptFullPathNames(collectedProject, scriptInClient)).toEqual({
			"StarterPlayer",
			"StarterPlayerScripts",
			"Client",
			"Ui",
			"Wardrobe",
		})
	end)
end)
