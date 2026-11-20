-- Unit: StudioProjectSyncBatchRenderer's pure parts (the batches themselves are run end to end in
-- StudioSideProjectSyncRuntime.spec.luau).

local luau = require("@lune/luau")
local serde = require("@lune/serde")

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local StudioProjectSyncTestHarness = require("./StudioProjectSyncTestHarness")
local StudioProjectSyncBatchRenderer = require("../../tools/StudioProjectSyncBatchRenderer")
local StudioSideLengthPrefixedTexts = require("../../tools/StudioSideLengthPrefixedTexts")
local StudioTransferTextPacker = require("../../tools/StudioTransferTextPacker")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local buildProjectScript = StudioProjectSyncTestHarness.buildProjectScript

local function evaluateLuauLiteral(literalText: string)
	return luau.load("return " .. literalText)()
end

describe("StudioProjectSyncBatchRenderer.renderLuauLiteral", function()
	it("renders arrays in order and records with sorted identifier keys", function()
		expect(StudioProjectSyncBatchRenderer.renderLuauLiteral({ "a", 2, true })).toBe('{"a",2,true}')
		expect(StudioProjectSyncBatchRenderer.renderLuauLiteral({ zeta = false, alpha = { 1 } })).toBe(
			"{alpha={1},zeta=false}"
		)
	end)

	it("writes a multi-line text as a long string that cannot close early", function()
		expect(StudioProjectSyncBatchRenderer.renderLuauLiteral("a\nb")).toBe("[[\na\nb]]")
		expect(StudioProjectSyncBatchRenderer.renderLuauLiteral("x]]\ny")).toBe("[=[\nx]]\ny]=]")
		expect(StudioProjectSyncBatchRenderer.renderLuauLiteral("x\ny]")).toBe("[=[\nx\ny]]=]")
		expect(StudioProjectSyncBatchRenderer.renderLuauLiteral("x]=]\ny]")).toBe("[==[\nx]=]\ny]]==]")
	end)

	it("writes leading newlines of a long string as string.rep", function()
		expect(StudioProjectSyncBatchRenderer.renderLuauLiteral("\n\n\nreturn 1\n")).toBe(
			'string.rep("\\n", 3) .. [[\nreturn 1\n]]'
		)
		expect(StudioProjectSyncBatchRenderer.renderLuauLiteral("\nreturn 1\n")).toBe("[[\n\nreturn 1\n]]")
	end)

	it("quotes a one-line text and any text with a carriage return", function()
		expect(StudioProjectSyncBatchRenderer.renderLuauLiteral("one line")).toBe('"one line"')
		expect(evaluateLuauLiteral(StudioProjectSyncBatchRenderer.renderLuauLiteral("a\r\nb"))).toBe("a\r\nb")
		expect(string.sub(StudioProjectSyncBatchRenderer.renderLuauLiteral("a\r\nb"), 1, 1)).toBe('"')
	end)

	it("raises for values it cannot render", function()
		for _, badValue in
			{ 1.5, 0 / 0, math.huge, function() end, { [{}] = 1 }, { ["not an identifier"] = 1 }, { [5] = "gap" } }
		do
			expect(function()
				StudioProjectSyncBatchRenderer.renderLuauLiteral(badValue)
			end).toThrow("LuauLiteralRenderer: ")
		end
	end)

	it("round-trips random texts and tables exactly", function()
		local textPieces = { "\n", "]", "]]", "=", "]=]", "[[", "\t", "a", "--", "\r", '"', "\\", "\0", "é" }
		SeededRandomTrials.runSeededRandomTrials(300, function(randomNumberGenerator)
			local pieces = {}
			for _ = 1, randomNumberGenerator.nextWholeNumberInRange(0, 12) do
				table.insert(pieces, randomNumberGenerator.pickRandomListElement(textPieces))
			end
			local randomText = table.concat(pieces)
			local randomValue = {
				texts = { randomText, randomText .. "\n" },
				count = randomNumberGenerator.nextWholeNumberInRange(-5, 5),
			}
			expect(evaluateLuauLiteral(StudioProjectSyncBatchRenderer.renderLuauLiteral(randomValue))).toEqual(
				randomValue
			)
		end)
	end)
end)

describe("StudioProjectSyncBatchRenderer.parseStudioScriptManifestText", function()
	it("reads each line into a path key with class and lower-case SHA-256", function()
		expect(
			StudioProjectSyncBatchRenderer.parseStudioScriptManifestText(
				"1\tModuleScript\tgenerated/Pool\tABCdef01\n2\tScript\tMain\t00ff\n"
			)
		).toEqual({
			["1:generated/Pool"] = { className = "ModuleScript", sourceSha256Hex = "abcdef01" },
			["2:Main"] = { className = "Script", sourceSha256Hex = "00ff" },
		})
		expect(StudioProjectSyncBatchRenderer.parseStudioScriptManifestText("")).toEqual({})
	end)

	it("raises on a line without the four fields", function()
		expect(function()
			StudioProjectSyncBatchRenderer.parseStudioScriptManifestText("1\tModuleScript\tA")
		end).toThrow("not a Studio script manifest line: 1\tModuleScript\tA")
	end)
end)

describe("StudioProjectSyncBatchRenderer.stripCommentLinesAndIndentation", function()
	it("removes comment-only lines, blank lines and surrounding whitespace", function()
		expect(
			StudioProjectSyncBatchRenderer.stripCommentLinesAndIndentation(
				"-- head\n\n\tlocal a = 1  \n\t-- c\n\treturn a -- t\n"
			)
		).toBe("local a = 1\nreturn a -- t")
	end)
end)

describe("StudioProjectSyncBatchRenderer.renderStudioProjectSyncBatches", function()
	local function buildThreeScriptProject()
		return StudioProjectSyncTestHarness.buildCollectedProject({
			buildProjectScript(1, { "A" }, "ModuleScript", string.rep("a", 40)),
			buildProjectScript(1, { "B" }, "ModuleScript", string.rep("b", 40)),
			buildProjectScript(2, { "C" }, "ModuleScript", string.rep("c", 100)),
		})
	end

	local function render(collectedProject, renderOptions)
		return StudioProjectSyncBatchRenderer.renderStudioProjectSyncBatches(
			StudioProjectSyncTestHarness.RUNTIME_SOURCE_TEXT,
			collectedProject,
			renderOptions
		)
	end

	it("names and orders the batches, grouping scripts up to the byte limit (a bigger script alone)", function()
		local renderedSync = render(buildThreeScriptProject(), { maximumSourceBytesPerBatch = 80 })
		local batchSummaries = {}
		for _, studioSyncBatch in renderedSync.studioSyncBatches do
			table.insert(
				batchSummaries,
				{ studioSyncBatch.batchFileName, studioSyncBatch.batchLabel, studioSyncBatch.writtenScriptCount }
			)
		end
		expect(batchSummaries).toEqual({
			{ "00-install-runtime-and-read-manifest.luau", "install runtime and read Studio script manifest", 0 },
			{ "01-write-scripts-1-of-2.luau", "write scripts 1 of 2", 2 },
			{ "02-write-scripts-2-of-2.luau", "write scripts 2 of 2", 1 },
			{ "03-remove-unexpected-and-verify.luau", "remove unexpected instances and verify", 0 },
		})
		expect(renderedSync.selectedScriptCount).toBe(3)
		expect(renderedSync.writtenScriptCount).toBe(3)
	end)

	it("carries the runtime only in batch 00 and makes the others check its SHA-256", function()
		local renderedSync = render(buildThreeScriptProject(), { maximumSourceBytesPerBatch = 1000 })
		local strippedRuntimeText = StudioProjectSyncBatchRenderer.stripCommentLinesAndIndentation(
			StudioProjectSyncTestHarness.RUNTIME_SOURCE_TEXT
		)
		local runtimeSha256Hex = serde.hash("sha256", strippedRuntimeText)
		local packedRuntimeLiteral = StudioProjectSyncBatchRenderer.renderLuauLiteral(
			StudioTransferTextPacker.packTextForStudio(strippedRuntimeText)
		)
		local installingBatchText = renderedSync.studioSyncBatches[1].batchSourceText
		expect(string.find(installingBatchText, "local packedRuntimeText = " .. packedRuntimeLiteral, 1, true) ~= nil).toBeTrue()
		expect(string.find(installingBatchText, runtimeSha256Hex, 1, true) ~= nil).toBeTrue()
		-- Packed: the batch is much smaller than the runtime text it carries.
		expect(#installingBatchText < #strippedRuntimeText / 2).toBeTrue()
		for batchPosition = 2, #renderedSync.studioSyncBatches do
			local batchText = renderedSync.studioSyncBatches[batchPosition].batchSourceText
			expect(string.find(batchText, packedRuntimeLiteral, 1, true)).toBeNil()
			expect(string.find(batchText, "local packedRuntimeText", 1, true)).toBeNil()
			expect(string.find(batchText, runtimeSha256Hex, 1, true) ~= nil).toBeTrue()
		end
	end)

	it("carries each distinct source once per batch, and the scripts that share it in one batch", function()
		local sharedSourceText = string.rep("s", 60)
		local collectedProject = StudioProjectSyncTestHarness.buildCollectedProject({
			buildProjectScript(1, { "Lookup" }, "ModuleScript", sharedSourceText),
			buildProjectScript(2, { "Main" }, "Script", string.rep("m", 60)),
			buildProjectScript(3, { "Hud" }, "LocalScript", string.rep("h", 60)),
			buildProjectScript(4, { "Lookup" }, "ModuleScript", sharedSourceText),
		})
		-- A limit below two sources: each distinct source gets its own batch.
		local renderedSync = render(collectedProject, { maximumSourceBytesPerBatch = 100 })
		expect(#renderedSync.studioSyncBatches).toBe(5)
		local firstWriteBatchText = renderedSync.studioSyncBatches[2].batchSourceText
		expect(renderedSync.studioSyncBatches[2].writtenScriptCount).toBe(2)
		expect(
			string.find(
				firstWriteBatchText,
				'mappedFolderNumber=1,relativePathNames={"Lookup"},sourceSha256Hex',
				1,
				true
			) ~= nil
		).toBeTrue()
		expect(
			string.find(
				firstWriteBatchText,
				'mappedFolderNumber=4,relativePathNames={"Lookup"},sourceSha256Hex',
				1,
				true
			) ~= nil
		).toBeTrue()
		local packedSourceTexts =
			luau.load("return " .. string.match(firstWriteBatchText, 'packedSourceTexts=(%b"")'))()
		expect(
			StudioSideLengthPrefixedTexts.splitTexts(
				StudioProjectSyncTestHarness.decompressZstdFrameStatingItsSize(
					StudioProjectSyncTestHarness.decodeBase64((string.gsub(packedSourceTexts, "%s", "")))
				)
			)
		).toEqual({ sharedSourceText })
		expect(renderedSync.writtenScriptCount).toBe(4)
	end)

	it("lists the retired folders in the last batch and refuses one that is also mapped", function()
		local renderedSync = render(buildThreeScriptProject(), {
			maximumSourceBytesPerBatch = 1000,
			retiredFolders = StudioProjectSyncTestHarness.RETIRED_FOLDERS,
		})
		local verificationText = renderedSync.studioSyncBatches[#renderedSync.studioSyncBatches].batchSourceText
		expect(
			string.find(
				verificationText,
				'retiredFolders={{existingParentPathNames={"ReplicatedStorage"},mappedFolderName="Shared"}}',
				1,
				true
			) ~= nil
		).toBeTrue()
		expect(function()
			render(buildThreeScriptProject(), {
				maximumSourceBytesPerBatch = 1000,
				retiredFolders = {
					{ existingParentPathNames = { "ServerScriptService" }, mappedFolderName = "Server" },
				},
			})
		end).toThrow("ServerScriptService.Server is both mapped and retired; nothing was changed")
	end)

	it("writes only scripts whose class or SHA-256 differ from the manifest, or that it lacks", function()
		local collectedProject = buildThreeScriptProject()
		local manifestText = table.concat({
			"1\tModuleScript\tA\t" .. serde.hash("sha256", string.rep("a", 40)),
			"1\tScript\tB\t" .. serde.hash("sha256", string.rep("b", 40)),
		}, "\n")
		local renderedSync =
			render(collectedProject, { maximumSourceBytesPerBatch = 1000, studioScriptManifestText = manifestText })
		expect(renderedSync.writtenScriptCount).toBe(2)
		local writeBatchText = renderedSync.studioSyncBatches[2].batchSourceText
		expect(string.find(writeBatchText, 'relativePathNames={"A"}', 1, true)).toBeNil()
		expect(string.find(writeBatchText, 'relativePathNames={"B"}', 1, true) ~= nil).toBeTrue()
		expect(string.find(writeBatchText, 'relativePathNames={"C"}', 1, true) ~= nil).toBeTrue()
	end)

	it("writes a script whose class matches the manifest but whose SHA-256 does not", function()
		local manifestText = "1\tModuleScript\tA\t" .. serde.hash("sha256", "an older source")
		local renderedSync = render(
			buildThreeScriptProject(),
			{ maximumSourceBytesPerBatch = 1000, studioScriptManifestText = manifestText }
		)
		expect(renderedSync.writtenScriptCount).toBe(3)
	end)

	it("writes no write batch when everything matches the manifest", function()
		local collectedProject = buildThreeScriptProject()
		local manifestLines = {}
		for _, projectScript in collectedProject.projectScripts do
			table.insert(
				manifestLines,
				string.format(
					"%d\tModuleScript\t%s\t%s",
					projectScript.mappedFolderNumber,
					projectScript.relativePathNames[1],
					serde.hash("sha256", projectScript.sourceText)
				)
			)
		end
		local renderedSync = render(
			collectedProject,
			{ maximumSourceBytesPerBatch = 1000, studioScriptManifestText = table.concat(manifestLines, "\n") }
		)
		expect(#renderedSync.studioSyncBatches).toBe(2)
		expect(renderedSync.studioSyncBatches[2].batchFileName).toBe("01-remove-unexpected-and-verify.luau")
		expect(renderedSync.writtenScriptCount).toBe(0)
	end)

	it("writes and selects only the chosen scripts in a partial sync", function()
		local renderedSync = render(
			buildThreeScriptProject(),
			{ maximumSourceBytesPerBatch = 1000, selectedScriptNumberSet = { [3] = true } }
		)
		expect(renderedSync.selectedScriptCount).toBe(1)
		expect(renderedSync.writtenScriptCount).toBe(1)
		local verificationText = renderedSync.studioSyncBatches[3].batchSourceText
		expect(
			string.find(
				verificationText,
				'isSelectedForThisSync=false,mappedFolderNumber=1,relativePathNames={"A"}',
				1,
				true
			) ~= nil
		).toBeTrue()
		expect(
			string.find(
				verificationText,
				'isSelectedForThisSync=true,mappedFolderNumber=2,relativePathNames={"C"}',
				1,
				true
			) ~= nil
		).toBeTrue()
	end)

	it("raises for a missing or non-positive batch size", function()
		for _, badBatchSize in { 0, -5, "100", nil } do
			expect(function()
				render(buildThreeScriptProject(), { maximumSourceBytesPerBatch = badBatchSize })
			end).toThrow("maximumSourceBytesPerBatch must be a positive number")
		end
	end)
end)
