-- Unit: the Studio project sync across the layout change of 2026-11-19 (each side gets its own
-- "shared" sibling; ReplicatedStorage.Shared is retired). The batch TEXT is run in the stand-in
-- Studio session of StudioProjectSyncTestHarness.

local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local UnitTestFramework = require("../Support/UnitTestFramework")
local StudioProjectSyncTestHarness = require("./StudioProjectSyncTestHarness")
local StudioSideProjectSyncRuntime = require("../../tools/StudioSideProjectSyncRuntime")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local buildProjectScript = StudioProjectSyncTestHarness.buildProjectScript
local RETIRED_FOLDERS = StudioProjectSyncTestHarness.RETIRED_FOLDERS

-- The same shared module in both "shared" folders (1 and 4) and a server module requiring it.
local function buildProjectWithSharedCopies()
	return StudioProjectSyncTestHarness.buildCollectedProject({
		buildProjectScript(1, { "Catalog" }, "ModuleScript", "return { themes = 3 }\n"),
		buildProjectScript(2, { "Round" }, "ModuleScript", 'return require("../shared/Catalog")\n'),
		buildProjectScript(4, { "Catalog" }, "ModuleScript", "return { themes = 3 }\n"),
	})
end

local function addInstance(className: string, instanceName: string, parentInstance)
	local createdInstance = roblox.Instance.new(className)
	createdInstance.Name = instanceName
	createdInstance.Parent = parentInstance
	return createdInstance
end

-- What the place held under the old layout: ReplicatedStorage.Shared with two scripts.
local function addOldLayoutSharedFolder(studioSession)
	local oldSharedFolder = addInstance("Folder", "Shared", studioSession.dataModel:GetService("ReplicatedStorage"))
	addInstance("ModuleScript", "Catalog", oldSharedFolder)
	addInstance("ModuleScript", "Pool", addInstance("Folder", "generated", oldSharedFolder))
	return oldSharedFolder
end

local function splitReportLines(reportText: string): { string }
	return string.split(reportText, "\n")
end

describe("Studio sync: retired project folders", function()
	it("removes the old ReplicatedStorage.Shared with everything in it and still verifies complete", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local oldSharedFolder = addOldLayoutSharedFolder(studioSession)
		local outsideModule =
			addInstance("ModuleScript", "NotOurs", studioSession.dataModel:GetService("ReplicatedStorage"))
		local batchReports, renderedSync = StudioProjectSyncTestHarness.renderAndRunAllBatches(
			studioSession,
			buildProjectWithSharedCopies(),
			{ maximumSourceBytesPerBatch = 100000, retiredFolders = RETIRED_FOLDERS }
		)
		expect(splitReportLines(batchReports[#batchReports])).toEqual({
			renderedSync.expectedVerificationReportFirstLine,
			"removed retired project folder ReplicatedStorage.Shared (Folder, 2 scripts inside)",
			"created StarterPlayer.StarterPlayerScripts.Client (Folder)",
		})
		expect(oldSharedFolder.Parent).toBeNil()
		expect(outsideModule.Parent).toBe(studioSession.dataModel:GetService("ReplicatedStorage"))
		expect((StudioProjectSyncTestHarness.describePlace(studioSession))).toEqual({
			"ReplicatedStorage.NotOurs (ModuleScript)",
			"ServerScriptService.Server (Folder)",
			"ServerScriptService.Server.Round (ModuleScript)",
			"ServerScriptService.shared (Folder)",
			"ServerScriptService.shared.Catalog (ModuleScript)",
			"StarterPlayer.StarterPlayerScripts.Client (Folder)",
			"StarterPlayer.StarterPlayerScripts.shared (Folder)",
			"StarterPlayer.StarterPlayerScripts.shared.Catalog (ModuleScript)",
		})
	end)

	it("leaves a retired name that is not a Folder in place and reports the sync incomplete", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local strayModule =
			addInstance("ModuleScript", "Shared", studioSession.dataModel:GetService("ReplicatedStorage"))
		local batchReports = StudioProjectSyncTestHarness.renderAndRunAllBatches(
			studioSession,
			buildProjectWithSharedCopies(),
			{ maximumSourceBytesPerBatch = 100000, retiredFolders = RETIRED_FOLDERS }
		)
		expect(splitReportLines(batchReports[#batchReports])).toEqual({
			"remove unexpected instances and verify: SYNC INCOMPLETE, verified 3 of 3 selected scripts (3 project scripts in all)",
			"MISMATCH retired project folder ReplicatedStorage.Shared is a ModuleScript, not a Folder: left in place",
			"created StarterPlayer.StarterPlayerScripts.Client (Folder)",
		})
		expect(strayModule.Parent).toBe(studioSession.dataModel:GetService("ReplicatedStorage"))
	end)

	it("reports nothing when no retired folder is there, including below a parent that does not exist", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local batchReports, renderedSync =
			StudioProjectSyncTestHarness.renderAndRunAllBatches(studioSession, buildProjectWithSharedCopies(), {
				maximumSourceBytesPerBatch = 100000,
				retiredFolders = {
					RETIRED_FOLDERS[1],
					{ existingParentPathNames = { "StarterPlayer", "NoSuchParent" }, mappedFolderName = "Shared" },
				},
			})
		expect(splitReportLines(batchReports[#batchReports])).toEqual({
			renderedSync.expectedVerificationReportFirstLine,
			"created StarterPlayer.StarterPlayerScripts.Client (Folder)",
		})
	end)

	it("refuses, changing nothing, a payload whose retired folder is also mapped", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local oldSharedFolder = addOldLayoutSharedFolder(studioSession)
		local placeBefore = StudioProjectSyncTestHarness.describePlace(studioSession)
		local studioAccess = {
			dataModel = studioSession.fakeGame,
			createInstance = roblox.Instance.new,
			computeSha256Hex = function(text: string): string
				return serde.hash("sha256", text)
			end,
		}
		local projectShape = {
			batchLabel = "remove unexpected instances and verify",
			mappedFolders = { { existingParentPathNames = { "ReplicatedStorage" }, mappedFolderName = "Shared" } },
			retiredFolders = RETIRED_FOLDERS,
			expectedFolders = {},
			expectedScripts = {},
		}
		expect(function()
			StudioSideProjectSyncRuntime.removeUnexpectedInstancesAndVerifyProject(
				studioAccess,
				projectShape,
				serde.hash("sha256", StudioSideProjectSyncRuntime.describeBatchPayloadCanonically(projectShape))
			)
		end).toThrow("ReplicatedStorage.Shared is both mapped and retired; nothing was changed")
		expect((StudioProjectSyncTestHarness.describePlace(studioSession))).toEqual(placeBefore)
		expect(oldSharedFolder.Parent).toBe(studioSession.dataModel:GetService("ReplicatedStorage"))
	end)
end)

describe("Studio sync: the two copies of the shared modules", function()
	it("writes the same source into both shared folders from one write batch", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local batchReports, renderedSync = StudioProjectSyncTestHarness.renderAndRunAllBatches(
			studioSession,
			buildProjectWithSharedCopies(),
			-- Smaller than the two distinct sources together: each distinct source is a batch.
			{ maximumSourceBytesPerBatch = 30 }
		)
		expect(#renderedSync.studioSyncBatches).toBe(4)
		expect(batchReports[2]).toBe(table.concat({
			"write scripts 1 of 2: 2 created, 0 updated, 0 unchanged",
			"created ServerScriptService.shared (Folder)",
			"created ServerScriptService.shared.Catalog (ModuleScript)",
			"created StarterPlayer.StarterPlayerScripts.shared (Folder)",
			"created StarterPlayer.StarterPlayerScripts.shared.Catalog (ModuleScript)",
		}, "\n"))
		local _, sourceByFullName = StudioProjectSyncTestHarness.describePlace(studioSession)
		expect(sourceByFullName["ServerScriptService.shared.Catalog"]).toBe("return { themes = 3 }\n")
		expect(sourceByFullName["StarterPlayer.StarterPlayerScripts.shared.Catalog"]).toBe("return { themes = 3 }\n")
		expect(sourceByFullName["ServerScriptService.Server.Round"]).toBe('return require("../shared/Catalog")\n')
	end)
end)
