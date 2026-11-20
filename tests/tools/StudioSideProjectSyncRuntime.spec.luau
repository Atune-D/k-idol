-- Unit: the Studio project sync end to end. The batch TEXT that tools/SyncProjectIntoStudio.luau
-- writes is run in a stand-in Studio session (tests/tools/StudioProjectSyncTestHarness.luau).

local roblox = require("@lune/roblox")

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local StudioProjectSyncTestHarness = require("./StudioProjectSyncTestHarness")
local StudioProjectSyncBatchRenderer = require("../../tools/StudioProjectSyncBatchRenderer")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local buildProjectScript = StudioProjectSyncTestHarness.buildProjectScript
local buildCollectedProject = StudioProjectSyncTestHarness.buildCollectedProject

local function buildSampleProject()
	return buildCollectedProject({
		buildProjectScript(1, { "Alpha" }, "ModuleScript", "-- header\nreturn 'alpha'\n"),
		buildProjectScript(1, { "generated", "Pool" }, "ModuleScript", "return { ']]' }\n"),
		buildProjectScript(2, { "ServerMain" }, "Script", "print('server')\n"),
		buildProjectScript(3, { "ClientMain" }, "LocalScript", "print('client')\n"),
	}, {
		{ mappedFolderNumber = 1, relativePathNames = { "generated" } },
		{ mappedFolderNumber = 2, relativePathNames = { "EmptyFolder" } },
	})
end

-- Sorted by byte order ("Server" before "shared"). The client-side "shared" folder is mapped but the
-- sample puts nothing in it, so it is created empty.
local SAMPLE_PROJECT_PLACE_DESCRIPTION = {
	"ServerScriptService.Server (Folder)",
	"ServerScriptService.Server.EmptyFolder (Folder)",
	"ServerScriptService.Server.ServerMain (Script)",
	"ServerScriptService.shared (Folder)",
	"ServerScriptService.shared.Alpha (ModuleScript)",
	"ServerScriptService.shared.generated (Folder)",
	"ServerScriptService.shared.generated.Pool (ModuleScript)",
	"StarterPlayer.StarterPlayerScripts.Client (Folder)",
	"StarterPlayer.StarterPlayerScripts.Client.ClientMain (LocalScript)",
	"StarterPlayer.StarterPlayerScripts.shared (Folder)",
}

local function findPlaceInstance(studioSession, fullPathNames: { string })
	local currentInstance = studioSession.dataModel:GetService(fullPathNames[1])
	for namePosition = 2, #fullPathNames do
		currentInstance = currentInstance:FindFirstChild(fullPathNames[namePosition])
	end
	return currentInstance
end

local function expectReportToContainLine(reportText: string, expectedLine: string)
	for reportLine in string.gmatch(reportText, "[^\n]+") do
		if reportLine == expectedLine then
			return
		end
	end
	expect(reportText).toBe("a report containing the line: " .. expectedLine)
end

describe("Studio project sync: first load and re-running", function()
	it("creates every folder and script where the project maps them, with comment lines blanked", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local batchReports = StudioProjectSyncTestHarness.renderAndRunAllBatches(studioSession, buildSampleProject())
		local placeDescription, sourceByFullName = StudioProjectSyncTestHarness.describePlace(studioSession)
		expect(placeDescription).toEqual(SAMPLE_PROJECT_PLACE_DESCRIPTION)
		expect(sourceByFullName["ServerScriptService.shared.Alpha"]).toBe("\nreturn 'alpha'\n")
		expect(sourceByFullName["ServerScriptService.shared.generated.Pool"]).toBe("return { ']]' }\n")
		expect(batchReports[1]).toBe("") -- the manifest of an empty place
		expect(batchReports[#batchReports]).toBe(
			"remove unexpected instances and verify: sync complete, verified 4 of 4 selected scripts (4 project scripts in all)\n"
				.. "created StarterPlayer.StarterPlayerScripts.shared (Folder)\n"
				.. "created ServerScriptService.Server.EmptyFolder (Folder)"
		)
	end)

	it("reports what each write batch created", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local batchReports = StudioProjectSyncTestHarness.renderAndRunAllBatches(
			studioSession,
			buildSampleProject(),
			{ maximumSourceBytesPerBatch = 100000 }
		)
		expect(batchReports[2]).toBe(table.concat({
			"write scripts 1 of 1: 4 created, 0 updated, 0 unchanged",
			"created ServerScriptService.shared (Folder)",
			"created ServerScriptService.shared.Alpha (ModuleScript)",
			"created ServerScriptService.shared.generated (Folder)",
			"created ServerScriptService.shared.generated.Pool (ModuleScript)",
			"created ServerScriptService.Server (Folder)",
			"created ServerScriptService.Server.ServerMain (Script)",
			"created StarterPlayer.StarterPlayerScripts.Client (Folder)",
			"created StarterPlayer.StarterPlayerScripts.Client.ClientMain (LocalScript)",
		}, "\n"))
	end)

	it("duplicates nothing when run twice, reporting every script unchanged", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		StudioProjectSyncTestHarness.renderAndRunAllBatches(studioSession, buildSampleProject())
		local secondReports = StudioProjectSyncTestHarness.renderAndRunAllBatches(
			studioSession,
			buildSampleProject(),
			{ maximumSourceBytesPerBatch = 100000 }
		)
		expect(secondReports[2]).toBe("write scripts 1 of 1: 0 created, 0 updated, 4 unchanged")
		expect(secondReports[3]).toBe(
			"remove unexpected instances and verify: sync complete, verified 4 of 4 selected scripts (4 project scripts in all)"
		)
		expect((StudioProjectSyncTestHarness.describePlace(studioSession))).toEqual(SAMPLE_PROJECT_PLACE_DESCRIPTION)
	end)

	it("updates a changed script in place (same instance) and reports it", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		StudioProjectSyncTestHarness.renderAndRunAllBatches(studioSession, buildSampleProject())
		local alphaInstance = findPlaceInstance(studioSession, { "ServerScriptService", "shared", "Alpha" })
		local changedProject = buildSampleProject()
		changedProject.projectScripts[1].sourceText = "return 'alpha v2'\n"
		local batchReports = StudioProjectSyncTestHarness.renderAndRunAllBatches(
			studioSession,
			changedProject,
			{ maximumSourceBytesPerBatch = 100000 }
		)
		expect(batchReports[2]).toBe(
			"write scripts 1 of 1: 0 created, 1 updated, 3 unchanged\nupdated ServerScriptService.shared.Alpha (ModuleScript)"
		)
		expect(findPlaceInstance(studioSession, { "ServerScriptService", "shared", "Alpha" })).toBe(alphaInstance)
		expect(alphaInstance.Source).toBe("return 'alpha v2'\n")
	end)

	it("writes a script that is open in the Script Editor through the editor and says so", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		StudioProjectSyncTestHarness.renderAndRunAllBatches(studioSession, buildSampleProject())
		local alphaInstance = findPlaceInstance(studioSession, { "ServerScriptService", "shared", "Alpha" })
		studioSession.openScriptDocuments[alphaInstance] = { isFakeScriptDocument = true }
		-- Open but unchanged: left alone, not rewritten through the editor.
		local clientMainInstance =
			findPlaceInstance(studioSession, { "StarterPlayer", "StarterPlayerScripts", "Client", "ClientMain" })
		studioSession.openScriptDocuments[clientMainInstance] = { isFakeScriptDocument = true }
		local changedProject = buildSampleProject()
		changedProject.projectScripts[1].sourceText = "return 'edited while open'\n"
		local batchReports = StudioProjectSyncTestHarness.renderAndRunAllBatches(
			studioSession,
			changedProject,
			{ maximumSourceBytesPerBatch = 100000 }
		)
		expect(studioSession.editorUpdates).toEqual({ "ServerScriptService.shared.Alpha" })
		expect(alphaInstance.Source).toBe("return 'edited while open'\n")
		expectReportToContainLine(
			batchReports[2],
			"note ServerScriptService.shared.Alpha was open in the Script Editor"
		)
	end)
end)

describe("Studio project sync: removal and verification", function()
	it("removes instances the project does not list, duplicates, and wrong classes, and reports each", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local _, renderedSync = StudioProjectSyncTestHarness.renderAndRunAllBatches(studioSession, buildSampleProject())
		local serverFolder = findPlaceInstance(studioSession, { "ServerScriptService", "Server" })
		local strayModule = roblox.Instance.new("ModuleScript")
		strayModule.Name = "Stray"
		strayModule.Parent = serverFolder
		local duplicateScript = serverFolder:FindFirstChild("ServerMain"):Clone()
		duplicateScript.Parent = serverFolder
		local wrongClassFolder = roblox.Instance.new("Folder")
		wrongClassFolder.Name = "Alpha"
		wrongClassFolder.Parent = findPlaceInstance(studioSession, { "ServerScriptService", "shared" })
		local outsideModule = roblox.Instance.new("ModuleScript")
		outsideModule.Name = "NotOurs"
		outsideModule.Parent = studioSession.dataModel:GetService("ReplicatedStorage")
		local nestedStray = roblox.Instance.new("Folder")
		nestedStray.Name = "NestedStray"
		nestedStray.Parent = findPlaceInstance(studioSession, { "ServerScriptService", "shared", "generated" })

		local _, verificationReport = StudioProjectSyncTestHarness.runBatchInStudioSession(
			studioSession,
			renderedSync.studioSyncBatches[#renderedSync.studioSyncBatches].batchSourceText
		)
		expectReportToContainLine(verificationReport, "removed ServerScriptService.Server.Stray (ModuleScript)")
		expectReportToContainLine(verificationReport, "removed ServerScriptService.Server.ServerMain (Script)")
		expectReportToContainLine(verificationReport, "removed ServerScriptService.shared.Alpha (Folder)")
		expectReportToContainLine(
			verificationReport,
			"removed ServerScriptService.shared.generated.NestedStray (Folder)"
		)
		local placeDescription = StudioProjectSyncTestHarness.describePlace(studioSession)
		local expectedDescription = table.clone(SAMPLE_PROJECT_PLACE_DESCRIPTION)
		table.insert(expectedDescription, "ReplicatedStorage.NotOurs (ModuleScript)")
		table.sort(expectedDescription)
		expect(placeDescription).toEqual(expectedDescription)
	end)

	it("removes a duplicate script while writing, keeping the first one", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		StudioProjectSyncTestHarness.renderAndRunAllBatches(studioSession, buildSampleProject())
		local serverFolder = findPlaceInstance(studioSession, { "ServerScriptService", "Server" })
		local firstServerMain = serverFolder:FindFirstChild("ServerMain")
		serverFolder:FindFirstChild("ServerMain"):Clone().Parent = serverFolder
		local batchReports = StudioProjectSyncTestHarness.renderAndRunAllBatches(
			studioSession,
			buildSampleProject(),
			{ maximumSourceBytesPerBatch = 100000 }
		)
		expectReportToContainLine(batchReports[2], "removed duplicate ServerScriptService.Server.ServerMain (Script)")
		expect(serverFolder:FindFirstChild("ServerMain")).toBe(firstServerMain)
		expect((StudioProjectSyncTestHarness.describePlace(studioSession))).toEqual(SAMPLE_PROJECT_PLACE_DESCRIPTION)
	end)

	it("replaces an instance of the wrong class at a script's place while writing", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local sharedFolder = roblox.Instance.new("Folder")
		sharedFolder.Name = "shared"
		sharedFolder.Parent = studioSession.dataModel:GetService("ServerScriptService")
		local wrongClassFolder = roblox.Instance.new("Folder")
		wrongClassFolder.Name = "Alpha"
		wrongClassFolder.Parent = sharedFolder
		local batchReports = StudioProjectSyncTestHarness.renderAndRunAllBatches(
			studioSession,
			buildSampleProject(),
			{ maximumSourceBytesPerBatch = 100000 }
		)
		expectReportToContainLine(batchReports[2], "replaced ServerScriptService.shared.Alpha (Folder)")
		expect((StudioProjectSyncTestHarness.describePlace(studioSession))).toEqual(SAMPLE_PROJECT_PLACE_DESCRIPTION)
	end)

	it("reports SYNC INCOMPLETE with a MISMATCH line for a missing or changed script", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local _, renderedSync = StudioProjectSyncTestHarness.renderAndRunAllBatches(studioSession, buildSampleProject())
		findPlaceInstance(studioSession, { "ServerScriptService", "shared", "Alpha" }).Source =
			"return 'changed in Studio'"
		findPlaceInstance(studioSession, { "ServerScriptService", "Server", "ServerMain" }):Destroy()
		local verificationBatch = renderedSync.studioSyncBatches[#renderedSync.studioSyncBatches]
		local _, verificationReport =
			StudioProjectSyncTestHarness.runBatchInStudioSession(studioSession, verificationBatch.batchSourceText)
		expect(verificationReport).toBe(table.concat({
			"remove unexpected instances and verify: SYNC INCOMPLETE, verified 2 of 4 selected scripts (4 project scripts in all)",
			"MISMATCH 1:Alpha: source differs (run the write batches)",
			"MISMATCH 2:ServerMain: missing (run the write batches)",
		}, "\n"))
	end)

	it("in a partial sync writes and verifies only the selected scripts and keeps the others", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		StudioProjectSyncTestHarness.renderAndRunAllBatches(studioSession, buildSampleProject())
		local changedProject = buildSampleProject()
		changedProject.projectScripts[1].sourceText = "return 'alpha v2'\n"
		changedProject.projectScripts[3].sourceText = "print('server v2')\n"
		local batchReports = StudioProjectSyncTestHarness.renderAndRunAllBatches(studioSession, changedProject, {
			maximumSourceBytesPerBatch = 100000,
			selectedScriptNumberSet = { [1] = true },
		})
		expect(batchReports[2]).toBe(
			"write scripts 1 of 1: 0 created, 1 updated, 0 unchanged\nupdated ServerScriptService.shared.Alpha (ModuleScript)"
		)
		expect(batchReports[3]).toBe(
			"remove unexpected instances and verify: sync complete, verified 1 of 1 selected scripts (4 project scripts in all)"
		)
		local _, sourceByFullName = StudioProjectSyncTestHarness.describePlace(studioSession)
		expect(sourceByFullName["ServerScriptService.Server.ServerMain"]).toBe("print('server')\n")
	end)
end)

describe("Studio project sync: manifest and safety checks", function()
	it("reads a manifest that makes the next sync write only what changed", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local firstReports = StudioProjectSyncTestHarness.renderAndRunAllBatches(studioSession, buildSampleProject())
		local secondReports = StudioProjectSyncTestHarness.renderAndRunAllBatches(studioSession, buildSampleProject())
		expect(firstReports[1]).toBe("")
		local manifestLines = string.split(secondReports[1], "\n")
		table.sort(manifestLines)
		expect(#manifestLines).toBe(4)
		expect(string.match(manifestLines[1], "^1\tModuleScript\tAlpha\t%x+$") ~= nil).toBeTrue()
		expect(string.match(manifestLines[2], "^1\tModuleScript\tgenerated/Pool\t%x+$") ~= nil).toBeTrue()
		expect(string.match(manifestLines[3], "^2\tScript\tServerMain\t%x+$") ~= nil).toBeTrue()
		expect(string.match(manifestLines[4], "^3\tLocalScript\tClientMain\t%x+$") ~= nil).toBeTrue()

		local changedProject = buildSampleProject()
		changedProject.projectScripts[3].sourceText = "print('server v2')\n"
		local incrementalSync = StudioProjectSyncBatchRenderer.renderStudioProjectSyncBatches(
			StudioProjectSyncTestHarness.RUNTIME_SOURCE_TEXT,
			changedProject,
			{ maximumSourceBytesPerBatch = 100000, studioScriptManifestText = secondReports[1] }
		)
		expect(incrementalSync.writtenScriptCount).toBe(1)
		expect(#incrementalSync.studioSyncBatches).toBe(3)
		local _, writeReport = StudioProjectSyncTestHarness.runBatchInStudioSession(
			studioSession,
			incrementalSync.studioSyncBatches[2].batchSourceText
		)
		expect(writeReport).toBe(
			"write scripts 1 of 1: 0 created, 1 updated, 0 unchanged\nupdated ServerScriptService.Server.ServerMain (Script)"
		)
	end)

	it("refuses to run a later batch before batch 00 installed the same runtime", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local renderedSync = StudioProjectSyncBatchRenderer.renderStudioProjectSyncBatches(
			StudioProjectSyncTestHarness.RUNTIME_SOURCE_TEXT,
			buildSampleProject(),
			{ maximumSourceBytesPerBatch = 100000 }
		)
		local didRun, runError = StudioProjectSyncTestHarness.runBatchInStudioSession(
			studioSession,
			renderedSync.studioSyncBatches[2].batchSourceText
		)
		expect(didRun).toBeFalse()
		expect(string.find(tostring(runError), "run 00-install-runtime-and-read-manifest.luau first", 1, true) ~= nil).toBeTrue()
		-- A working runtime from another batch set (another SHA-256) is refused too.
		StudioProjectSyncTestHarness.runBatchInStudioSession(
			studioSession,
			renderedSync.studioSyncBatches[1].batchSourceText
		)
		studioSession.sessionGlobals.IdolgrowStudioProjectSyncRuntime.runtimeSha256Hex = "another batch set"
		didRun, runError = StudioProjectSyncTestHarness.runBatchInStudioSession(
			studioSession,
			renderedSync.studioSyncBatches[2].batchSourceText
		)
		expect(didRun).toBeFalse()
		expect(string.find(tostring(runError), "run 00-install-runtime-and-read-manifest.luau first", 1, true) ~= nil).toBeTrue()
		expect((StudioProjectSyncTestHarness.describePlace(studioSession))).toEqual({})
	end)

	it("changes nothing when a source in a write batch was damaged on the way (payload SHA-256)", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local renderedSync = StudioProjectSyncBatchRenderer.renderStudioProjectSyncBatches(
			StudioProjectSyncTestHarness.RUNTIME_SOURCE_TEXT,
			buildSampleProject(),
			{ maximumSourceBytesPerBatch = 100000 }
		)
		StudioProjectSyncTestHarness.runBatchInStudioSession(
			studioSession,
			renderedSync.studioSyncBatches[1].batchSourceText
		)
		-- The sources travel packed: change one Base64 character of them.
		local damagedBatchText = StudioProjectSyncTestHarness.changeOnePackedCharacter(
			renderedSync.studioSyncBatches[2].batchSourceText,
			"packedSourceTexts="
		)
		local didRun, runError = StudioProjectSyncTestHarness.runBatchInStudioSession(studioSession, damagedBatchText)
		expect(didRun).toBeFalse()
		expect(
			string.find(
				tostring(runError),
				"write scripts 1 of 1: the batch payload does not match its SHA-256 (damaged on the way?); nothing was changed",
				1,
				true
			) ~= nil
		).toBeTrue()
		expect((StudioProjectSyncTestHarness.describePlace(studioSession))).toEqual({})
	end)

	it("raises, changing nothing, for a class that is not a script", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local brokenProject = buildCollectedProject({ buildProjectScript(1, { "Odd" }, "Part", "x") })
		local renderedSync = StudioProjectSyncBatchRenderer.renderStudioProjectSyncBatches(
			StudioProjectSyncTestHarness.RUNTIME_SOURCE_TEXT,
			brokenProject,
			{ maximumSourceBytesPerBatch = 100000 }
		)
		StudioProjectSyncTestHarness.runBatchInStudioSession(
			studioSession,
			renderedSync.studioSyncBatches[1].batchSourceText
		)
		local didRun, runError = StudioProjectSyncTestHarness.runBatchInStudioSession(
			studioSession,
			renderedSync.studioSyncBatches[2].batchSourceText
		)
		expect(didRun).toBeFalse()
		expect(string.find(tostring(runError), "Odd is not a script class (Part)", 1, true) ~= nil).toBeTrue()
		expect((StudioProjectSyncTestHarness.describePlace(studioSession))).toEqual({})
	end)

	it("raises when a parent that must already exist is missing", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		studioSession.dataModel:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts"):Destroy()
		local renderedSync = StudioProjectSyncBatchRenderer.renderStudioProjectSyncBatches(
			StudioProjectSyncTestHarness.RUNTIME_SOURCE_TEXT,
			buildSampleProject(),
			{ maximumSourceBytesPerBatch = 100000 }
		)
		local didRun, runError = StudioProjectSyncTestHarness.runBatchInStudioSession(
			studioSession,
			renderedSync.studioSyncBatches[1].batchSourceText
		)
		expect(didRun).toBeFalse()
		expect(
			string.find(
				tostring(runError),
				"expected exactly one StarterPlayerScripts under StarterPlayer, found 0",
				1,
				true
			) ~= nil
		).toBeTrue()
	end)
end)

describe("Studio project sync: randomized projects", function()
	it("always ends with exactly the project in the place, whatever was there and however it is batched", function()
		local SCRIPT_CLASS_NAMES = { "ModuleScript", "Script", "LocalScript" }
		local CANDIDATE_NAMES = { "A", "B", "C", "D" }
		SeededRandomTrials.runSeededRandomTrials(25, function(randomNumberGenerator)
			local studioSession = StudioProjectSyncTestHarness.createStudioSession()
			local function buildRandomProject()
				local projectScripts, usedPathKeys = {}, {}
				for _ = 1, randomNumberGenerator.nextWholeNumberInRange(1, 6) do
					local mappedFolderNumber = randomNumberGenerator.nextWholeNumberInRange(1, 3)
					local scriptName = randomNumberGenerator.pickRandomListElement(CANDIDATE_NAMES)
					local pathKey = mappedFolderNumber .. scriptName
					if not usedPathKeys[pathKey] then
						usedPathKeys[pathKey] = true
						table.insert(
							projectScripts,
							buildProjectScript(
								mappedFolderNumber,
								{ scriptName },
								randomNumberGenerator.pickRandomListElement(SCRIPT_CLASS_NAMES),
								string.rep("x]=", randomNumberGenerator.nextWholeNumberInRange(0, 3))
									.. "\n-- note\nreturn "
									.. randomNumberGenerator.nextWholeNumberInRange(1, 99)
									.. "\n"
							)
						)
					end
				end
				return buildCollectedProject(projectScripts)
			end
			local finalProject
			for _ = 1, randomNumberGenerator.nextWholeNumberInRange(1, 3) do
				finalProject = buildRandomProject()
				local batchReports = StudioProjectSyncTestHarness.renderAndRunAllBatches(studioSession, finalProject, {
					maximumSourceBytesPerBatch = randomNumberGenerator.nextWholeNumberInRange(1, 120),
				})
				expect(string.find(batchReports[#batchReports], "sync complete", 1, true) ~= nil).toBeTrue()
			end
			local placeDescription = StudioProjectSyncTestHarness.describePlace(studioSession)
			local scriptCount = 0
			for _, describedInstance in placeDescription do
				if not string.find(describedInstance, "(Folder)", 1, true) then
					scriptCount += 1
				end
			end
			expect(scriptCount).toBe(#finalProject.projectScripts)
		end)
	end)
end)
