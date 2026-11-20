-- Unit: the integrity checks of the Studio project sync. A batch damaged on its way into
-- execute_luau must change nothing: batch 00 installs only an undamaged runtime, and the write and
-- remove-and-verify batches run only when their payload matches the SHA-256 Lune stamped into them.
-- Also: an instance whose name holds the path separator never passes for a project path.

local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local StudioProjectSyncTestHarness = require("./StudioProjectSyncTestHarness")
local StudioProjectSyncBatchRenderer = require("../../tools/StudioProjectSyncBatchRenderer")
local StudioSideLengthPrefixedTexts = require("../../tools/StudioSideLengthPrefixedTexts")
local StudioSideProjectSyncRuntime = require("../../tools/StudioSideProjectSyncRuntime")
local StudioTransferTextPacker = require("../../tools/StudioTransferTextPacker")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local buildProjectScript = StudioProjectSyncTestHarness.buildProjectScript
local buildCollectedProject = StudioProjectSyncTestHarness.buildCollectedProject
local describeCanonically = StudioSideProjectSyncRuntime.describeBatchPayloadCanonically

local function buildSampleProject()
	return buildCollectedProject({
		buildProjectScript(1, { "Alpha" }, "ModuleScript", "return 'alpha'\n"),
		buildProjectScript(1, { "generated", "Pool" }, "ModuleScript", "return 'pool'\n"),
		buildProjectScript(2, { "ServerMain" }, "Script", "print('server')\n"),
	}, { { mappedFolderNumber = 1, relativePathNames = { "generated" } } })
end

local function renderSampleSync()
	return StudioProjectSyncBatchRenderer.renderStudioProjectSyncBatches(
		StudioProjectSyncTestHarness.RUNTIME_SOURCE_TEXT,
		buildSampleProject(),
		{ maximumSourceBytesPerBatch = 100000 }
	)
end

local function expectErrorContaining(runError, expectedFragment: string)
	if not string.find(tostring(runError), expectedFragment, 1, true) then
		expect(tostring(runError)).toBe("an error containing: " .. expectedFragment)
	end
end

local function replaceExactlyOnce(text: string, searchedText: string, replacementText: string): string
	local foundAt = string.find(text, searchedText, 1, true)
	assert(foundAt ~= nil, "test setup: text not found: " .. searchedText)
	assert(string.find(text, searchedText, foundAt + 1, true) == nil, "test setup: text found twice: " .. searchedText)
	return string.sub(text, 1, foundAt - 1) .. replacementText .. string.sub(text, foundAt + #searchedText)
end

local function runEveryBatch(studioSession, renderedSync)
	local batchReports = {}
	for _, studioSyncBatch in renderedSync.studioSyncBatches do
		local didRun, reportOrError =
			StudioProjectSyncTestHarness.runBatchInStudioSession(studioSession, studioSyncBatch.batchSourceText)
		assert(didRun, "test setup: batch failed: " .. tostring(reportOrError))
		table.insert(batchReports, reportOrError)
	end
	return batchReports
end

describe("Studio sync batch 00: installs only an undamaged runtime", function()
	it("raises and installs nothing when the packed runtime text unpacks to another text", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local installBatchText = renderSampleSync().studioSyncBatches[1].batchSourceText
		local strippedRuntimeText = StudioProjectSyncBatchRenderer.stripCommentLinesAndIndentation(
			StudioProjectSyncTestHarness.RUNTIME_SOURCE_TEXT
		)
		local damagedRuntimeText =
			replaceExactlyOnce(strippedRuntimeText, "verifiedScriptCount == selectedScriptCount", "true")
		local damagedBatchText = replaceExactlyOnce(
			installBatchText,
			StudioProjectSyncBatchRenderer.renderLuauLiteral(
				StudioTransferTextPacker.packTextForStudio(strippedRuntimeText)
			),
			StudioProjectSyncBatchRenderer.renderLuauLiteral(
				StudioTransferTextPacker.packTextForStudio(damagedRuntimeText)
			)
		)
		local didRun, runError = StudioProjectSyncTestHarness.runBatchInStudioSession(studioSession, damagedBatchText)
		expect(didRun).toBeFalse()
		expectErrorContaining(runError, "runtime text in this batch was damaged on the way (SHA-256 mismatch)")
		expect(studioSession.sessionGlobals.IdolgrowStudioProjectSyncRuntime).toBeNil()
	end)

	it("raises and installs nothing when the packed runtime text does not unpack", function()
		for _, changedCharacterNumber in { 1, 3, 9 } do
			local studioSession = StudioProjectSyncTestHarness.createStudioSession()
			local damagedBatchText = StudioProjectSyncTestHarness.changeOnePackedCharacter(
				renderSampleSync().studioSyncBatches[1].batchSourceText,
				"local packedRuntimeText = ",
				changedCharacterNumber
			)
			local didRun, runError =
				StudioProjectSyncTestHarness.runBatchInStudioSession(studioSession, damagedBatchText)
			expect(didRun).toBeFalse()
			expectErrorContaining(runError, "runtime text in this batch was damaged on the way (")
			expect(studioSession.sessionGlobals.IdolgrowStudioProjectSyncRuntime).toBeNil()
		end
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local _, runError = StudioProjectSyncTestHarness.runBatchInStudioSession(
			studioSession,
			StudioProjectSyncTestHarness.changeOnePackedCharacter(
				renderSampleSync().studioSyncBatches[1].batchSourceText,
				"local packedRuntimeText = "
			)
		)
		expectErrorContaining(runError, "runtime text in this batch was damaged on the way (it does not unpack)")
	end)

	it("raises and installs nothing when the runtime does not compile", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local renderedSync = StudioProjectSyncBatchRenderer.renderStudioProjectSyncBatches(
			"return (\n",
			buildSampleProject(),
			{ maximumSourceBytesPerBatch = 100000 }
		)
		local didRun, runError = StudioProjectSyncTestHarness.runBatchInStudioSession(
			studioSession,
			renderedSync.studioSyncBatches[1].batchSourceText
		)
		expect(didRun).toBeFalse()
		expectErrorContaining(runError, "the Studio sync runtime does not compile")
		expect(studioSession.sessionGlobals.IdolgrowStudioProjectSyncRuntime).toBeNil()
	end)

	it("raises and installs nothing where loadstring is missing", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local didRun, runError = StudioProjectSyncTestHarness.runBatchInStudioSession(
			studioSession,
			renderSampleSync().studioSyncBatches[1].batchSourceText,
			true
		)
		expect(didRun).toBeFalse()
		expectErrorContaining(runError, "loadstring is not available here; nothing was installed")
		expect(studioSession.sessionGlobals.IdolgrowStudioProjectSyncRuntime).toBeNil()
	end)

	it("installs the runtime it carries under the SHA-256 of that runtime text", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		StudioProjectSyncTestHarness.runBatchInStudioSession(
			studioSession,
			renderSampleSync().studioSyncBatches[1].batchSourceText
		)
		local installedRuntime = studioSession.sessionGlobals.IdolgrowStudioProjectSyncRuntime
		expect(installedRuntime.runtimeSha256Hex).toBe(
			serde.hash(
				"sha256",
				StudioProjectSyncBatchRenderer.stripCommentLinesAndIndentation(
					StudioProjectSyncTestHarness.RUNTIME_SOURCE_TEXT
				)
			)
		)
		expect(type(installedRuntime.runtime.removeUnexpectedInstancesAndVerifyProject)).toBe("function")
	end)
end)

describe("Studio sync payload checks: a damaged payload changes nothing", function()
	it("refuses a verify batch with one expected script left out, removing nothing", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local renderedSync = renderSampleSync()
		runEveryBatch(studioSession, renderedSync)
		local placeBefore = StudioProjectSyncTestHarness.describePlace(studioSession)
		local verifyBatchText = renderedSync.studioSyncBatches[#renderedSync.studioSyncBatches].batchSourceText
		local leftOutEntry = string.match(
			verifyBatchText,
			'{className="Script",[^}]-relativePathNames={"ServerMain"},sourceSha256Hex="%x+"},?'
		)
		assert(leftOutEntry ~= nil, "test setup: ServerMain entry not found")
		local damagedBatchText = replaceExactlyOnce(verifyBatchText, leftOutEntry, "")
		local didRun, runError = StudioProjectSyncTestHarness.runBatchInStudioSession(studioSession, damagedBatchText)
		expect(didRun).toBeFalse()
		expectErrorContaining(
			runError,
			"remove unexpected instances and verify: the batch payload does not match its SHA-256 (damaged on the way?); nothing was changed"
		)
		expect((StudioProjectSyncTestHarness.describePlace(studioSession))).toEqual(placeBefore)
	end)

	it("refuses a write batch whose script path or class was damaged, creating nothing", function()
		for _, damage in
			{
				{ searchedText = '{"ServerMain"}', replacementText = '{"ServerMan"}' },
				{ searchedText = 'className="Script"', replacementText = 'className="LocalScript"' },
			}
		do
			local studioSession = StudioProjectSyncTestHarness.createStudioSession()
			local renderedSync = renderSampleSync()
			StudioProjectSyncTestHarness.runBatchInStudioSession(
				studioSession,
				renderedSync.studioSyncBatches[1].batchSourceText
			)
			local damagedBatchText = replaceExactlyOnce(
				renderedSync.studioSyncBatches[2].batchSourceText,
				damage.searchedText,
				damage.replacementText
			)
			local didRun, runError =
				StudioProjectSyncTestHarness.runBatchInStudioSession(studioSession, damagedBatchText)
			expect(didRun).toBeFalse()
			expectErrorContaining(runError, "the batch payload does not match its SHA-256")
			expect((StudioProjectSyncTestHarness.describePlace(studioSession))).toEqual({})
		end
	end)

	it("still refuses a script whose source does not match its own SHA-256 when the payload hash matches", function()
		local studioSession = StudioProjectSyncTestHarness.createStudioSession()
		local studioAccess = {
			dataModel = studioSession.fakeGame,
			createInstance = roblox.Instance.new,
			computeSha256Hex = function(text: string): string
				return serde.hash("sha256", text)
			end,
			writeScriptSource = function(scriptInstance, sourceText: string): boolean
				scriptInstance.Source = sourceText
				return false
			end,
			unpackText = function(packedText: string): string
				return StudioProjectSyncTestHarness.decompressZstdFrameStatingItsSize(
					StudioProjectSyncTestHarness.decodeBase64((string.gsub(packedText, "%s", "")))
				)
			end,
		}
		local function buildScriptWriteBatch(packedSourceTexts: string, sourceTextNumber: number)
			return {
				batchLabel = "write scripts 1 of 1",
				mappedFolders = { { existingParentPathNames = { "ServerScriptService" }, mappedFolderName = "Server" } },
				packedSourceTexts = packedSourceTexts,
				scriptWrites = {
					{
						mappedFolderNumber = 1,
						relativePathNames = { "ServerMain" },
						className = "Script",
						sourceTextNumber = sourceTextNumber,
						sourceSha256Hex = serde.hash("sha256", "print('other')\n"),
					},
				},
			}
		end
		local packedSourceTexts =
			StudioTransferTextPacker.packTextForStudio(StudioSideLengthPrefixedTexts.joinTexts({ "print('server')\n" }))
		for _, sourceTextNumber in { 1, 2 } do
			local scriptWriteBatch = buildScriptWriteBatch(packedSourceTexts, sourceTextNumber)
			expect(function()
				StudioSideProjectSyncRuntime.applyScriptWriteBatch(
					studioAccess,
					scriptWriteBatch,
					serde.hash("sha256", describeCanonically(scriptWriteBatch))
				)
			end).toThrow("source of ServerMain does not match its SHA-256; nothing was changed")
		end
		local scriptWriteBatch = buildScriptWriteBatch(packedSourceTexts, 1)
		expect(function()
			StudioSideProjectSyncRuntime.applyScriptWriteBatch(studioAccess, scriptWriteBatch, nil :: any)
		end).toThrow("the batch payload does not match its SHA-256")
		-- Packed sources that do not unpack (payload hash matching) are refused too.
		for _, unusablePackedText in
			{
				"not base64!",
				StudioTransferTextPacker.encodeBase64("\40\181\47\253\0\0"),
				StudioTransferTextPacker.packTextForStudio("12:too short"),
			}
		do
			local unusableBatch = buildScriptWriteBatch(unusablePackedText, 1)
			expect(function()
				StudioSideProjectSyncRuntime.applyScriptWriteBatch(
					studioAccess,
					unusableBatch,
					serde.hash("sha256", describeCanonically(unusableBatch))
				)
			end).toThrow("write scripts 1 of 1: the packed sources do not unpack (")
		end
		expect((StudioProjectSyncTestHarness.describePlace(studioSession))).toEqual({})
	end)
end)

describe("Studio sync payload canonical text", function()
	it("is the same whatever order the keys were inserted in", function()
		local firstPayload = { b = 1, a = { "x", "y" }, c = true }
		local secondPayload = {}
		secondPayload.c = true
		secondPayload.a = { "x", "y" }
		secondPayload.b = 1
		expect(describeCanonically(firstPayload)).toBe(describeCanonically(secondPayload))
	end)

	it("tells apart payloads that a plain join would confuse", function()
		local confusablePairs = {
			{ { "ab", "c" }, { "a", "bc" } },
			-- Without the length prefix both would read "{n1;san2;sb}".
			{ { "an2;sb" }, { "a", "b" } },
			{ { "1" }, { 1 } },
			{ { true }, { "T" } },
			{ { a = "" }, { a = {} } },
			{ { [1] = "x" }, { ["1"] = "x" } },
			{ { "x", "y" }, { "y", "x" } },
			{ { 12 }, { 1, 2 } },
		}
		for _, confusablePair in confusablePairs do
			expect(describeCanonically(confusablePair[1]) ~= describeCanonically(confusablePair[2])).toBeTrue()
		end
	end)

	it("raises on a value or key it cannot describe", function()
		expect(function()
			describeCanonically({ 1.5 })
		end).toThrow("a batch payload number is not whole: 1.5")
		expect(function()
			describeCanonically({ math.huge })
		end).toThrow("not whole")
		expect(function()
			describeCanonically({ print })
		end).toThrow("a batch payload holds a function")
		expect(function()
			describeCanonically({ [true] = 1 })
		end).toThrow("a batch payload key is not a string or number")
	end)

	it("changes whenever any one leaf of a random payload changes, and never with key order", function()
		SeededRandomTrials.runSeededRandomTrials(200, function(randomNumberGenerator)
			local leafCandidates = { "", "a", "ab", "b", 0, 1, 12, -3, true, false }
			local function buildRandomPayload(depth: number)
				local payload = {}
				for position = 1, randomNumberGenerator.nextWholeNumberInRange(1, 4) do
					local leafOrTable = if depth < 2
							and randomNumberGenerator.nextWholeNumberInRange(1, 4) == 1
						then buildRandomPayload(depth + 1)
						else randomNumberGenerator.pickRandomListElement(leafCandidates)
					if randomNumberGenerator.nextWholeNumberInRange(1, 2) == 1 then
						payload[position] = leafOrTable
					else
						payload["k" .. position] = leafOrTable
					end
				end
				return payload
			end
			local function copyInShuffledKeyOrder(payload)
				local keys = {}
				for key in payload do
					table.insert(keys, key)
				end
				randomNumberGenerator.shuffleListInPlace(keys)
				local payloadCopy = {}
				for _, key in keys do
					payloadCopy[key] = if type(payload[key]) == "table"
						then copyInShuffledKeyOrder(payload[key])
						else payload[key]
				end
				return payloadCopy
			end
			local payload = buildRandomPayload(0)
			local payloadCopy = copyInShuffledKeyOrder(payload)
			expect(describeCanonically(payloadCopy)).toBe(describeCanonically(payload))
			-- Change one top-level leaf (or add a key) and the text must change.
			local changedKey = next(payloadCopy)
			local originalValue = payloadCopy[changedKey]
			payloadCopy[changedKey] = if originalValue == "changed" then "changed again" else "changed"
			expect(describeCanonically(payloadCopy) ~= describeCanonically(payload)).toBeTrue()
		end)
	end)
end)

describe("Studio sync: instance names that hold a path separator", function()
	it("removes a stray named like a nested project path and keeps it out of the manifest", function()
		for _, strayName in { "generated/Pool", "Alpha\t", "Alpha\n" } do
			local studioSession = StudioProjectSyncTestHarness.createStudioSession()
			local renderedSync = renderSampleSync()
			runEveryBatch(studioSession, renderedSync)
			local sharedFolder =
				studioSession.dataModel:GetService("ServerScriptService"):FindFirstChild("shared") :: any
			local strayModule = roblox.Instance.new("ModuleScript")
			strayModule.Name = strayName
			strayModule.Parent = sharedFolder
			local strayChild = roblox.Instance.new("ModuleScript")
			strayChild.Name = "Inside"
			strayChild.Parent = strayModule

			local didReadManifest, manifestText = StudioProjectSyncTestHarness.runBatchInStudioSession(
				studioSession,
				renderedSync.studioSyncBatches[1].batchSourceText
			)
			expect(didReadManifest).toBeTrue()
			expect(#string.split(manifestText, "\n")).toBe(3)
			expect(string.find(manifestText, "Inside", 1, true)).toBeNil()

			local batchReports = runEveryBatch(studioSession, renderedSync)
			local verificationReport = batchReports[#batchReports]
			expect(string.split(verificationReport, "\n")[1]).toBe(renderedSync.expectedVerificationReportFirstLine)
			expect(
				string.find(
					verificationReport,
					"removed ServerScriptService.shared." .. strayName .. " (ModuleScript)",
					1,
					true
				) ~= nil
			).toBeTrue()
			expect(strayModule.Parent).toBeNil()
		end
	end)
end)

describe("Studio sync renderer: expected verification line", function()
	it("names the selected and the total script counts", function()
		local fullSync = renderSampleSync()
		expect(fullSync.expectedVerificationReportFirstLine).toBe(
			"remove unexpected instances and verify: sync complete, verified 3 of 3 selected scripts (3 project scripts in all)"
		)
		local partialSync = StudioProjectSyncBatchRenderer.renderStudioProjectSyncBatches(
			StudioProjectSyncTestHarness.RUNTIME_SOURCE_TEXT,
			buildSampleProject(),
			{ maximumSourceBytesPerBatch = 100000, selectedScriptNumberSet = { [3] = true } }
		)
		expect(partialSync.expectedVerificationReportFirstLine).toBe(
			"remove unexpected instances and verify: sync complete, verified 1 of 1 selected scripts (3 project scripts in all)"
		)
	end)
end)
