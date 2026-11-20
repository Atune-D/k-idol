-- StudioProjectSyncBatchRenderer: writes the Luau text of every Studio project sync batch from
-- what ProjectTreeScriptCollector found. Batch 00 carries the Studio-side runtime (the text
-- StudioSyncRuntimeBundler made from tools/StudioSideProjectSyncRuntime.luau and its parts, comment
-- lines and indentation removed) PACKED (tools/StudioTransferTextPacker.luau), unpacks it with
-- EncodingService, hashes what it unpacked, raises (installing nothing) unless the text unpacks and
-- its SHA-256 equals the one Lune stamped into the batch, then compiles it with loadstring and
-- installs it as _G.IdolgrowStudioProjectSyncRuntime together with that SHA-256. Every later batch
-- checks that exactly that runtime is installed (else it raises, changing nothing) and makes one
-- call into it, passing its payload and the SHA-256 of the payload's canonical text
-- (StudioSideProjectSyncRuntime.describeBatchPayloadCanonically), which the runtime checks before
-- changing anything. A write batch's payload carries its scripts' sources packed, each distinct
-- source once. Each batch returns a report string when run through `execute_luau` in Edit mode.
-- What Studio receives for each script is StudioSourceCommentLineBlanker's copy (comment-only
-- lines blanked, line numbers unchanged); every SHA-256 below is of that copy.
-- Lune only (it hashes with @lune/serde); writes no files itself.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- StudioProjectSyncBatchRenderer.renderStudioProjectSyncBatches(bundledRuntimeSourceText, collectedProject, renderOptions)
--     -> { studioSyncBatches, selectedScriptCount, writtenScriptCount, expectedVerificationReportFirstLine }
--   bundledRuntimeSourceText: StudioSyncRuntimeBundler.bundleRuntimeSourceText's result.
--   selectedScriptCount: scripts in this sync (all, or the selection); writtenScriptCount: those
--   of them that the write batches carry (the others already match the manifest).
--   expectedVerificationReportFirstLine: the exact first line the last batch must answer with when
--   the sync worked, e.g. "...: sync complete, verified 71 of 71 selected scripts (71 project
--   scripts in all)".
--   renderOptions = {
--     maximumSourceBytesPerBatch: number,   bytes of DISTINCT Studio source per write batch (before
--         packing); a single larger source still gets a batch of its own; scripts with the same
--         source always share a batch and carry it once
--     studioScriptManifestText: string?,    output of the manifest batch; when given, only the
--         scripts whose class or SHA-256 differ from it (or that it lacks) are written
--     selectedScriptNumberSet: { [scriptNumber]: true }?,   a partial sync: only these scripts
--         are written and verified; the others are kept in Studio if present (nil: all scripts)
--     retiredFolders: { { existingParentPathNames, mappedFolderName } }?,   folders an earlier
--         project file mapped: the last batch removes them (nil: none). Raises when one of them
--         is also a mapped folder.
--   }
--   studioSyncBatches, in the order they must be run, each { batchFileName, batchLabel,
--   batchSourceText, writtenScriptCount }:
--     "00-install-runtime-and-read-manifest.luau"   always first; changes nothing in the place;
--                                               its output can be saved for --studio-manifest
--     "NN-write-scripts-K-of-M.luau"            zero or more; create or update scripts
--     "NN-remove-unexpected-and-verify.luau"    always last; removes retired folders, creates empty
--                                               folders, removes what the project does not list,
--                                               verifies every script's SHA-256
-- StudioProjectSyncBatchRenderer.parseStudioScriptManifestText(manifestText)
--     -> { [scriptPathKey]: { className, sourceSha256Hex } }   scriptPathKey = "<n>:<a/b/c>";
--   raises on a line that does not have the four tab-separated fields.
-- StudioProjectSyncBatchRenderer.stripCommentLinesAndIndentation(luauSourceText) -> string
--   Removes lines that are only a comment, blank lines and leading whitespace. Only for code
--   without multi-line strings (the runtime has none).
-- StudioProjectSyncBatchRenderer.renderLuauLiteral(value) -> string   (tools/LuauLiteralRenderer.luau)

-- Roblox globals the batches rely on (https://create.roblox.com/docs/reference/engine/globals/LuaGlobals):
--   _G: "A table that is shared between all scripts of the same context level"; observed in Studio
--       0.748 to persist between execute_luau calls of one Studio session.
--   loadstring: the page says it is disabled by default (ServerScriptService.LoadStringEnabled);
--       observed in Studio 0.748 on 2026-11-19 to work in execute_luau in Edit mode without changing
--       that setting (which execute_luau cannot even read). Batch 00 raises if loadstring is missing.
-- Batch 00 also uses EncodingService:Base64Decode and :DecompressBuffer with
-- Enum.CompressionAlgorithm.Zstd (classes/EncodingService, enums/CompressionAlgorithm) and
-- buffer.fromstring / buffer.tostring (libraries/buffer).

local serde = require("@lune/serde")

local LuauLiteralRenderer = require("./LuauLiteralRenderer")
local StudioSideLengthPrefixedTexts = require("./StudioSideLengthPrefixedTexts")
local StudioSideProjectSyncRuntime = require("./StudioSideProjectSyncRuntime")
local StudioSideRetiredProjectFolderRemover = require("./StudioSideRetiredProjectFolderRemover")
local StudioSourceCommentLineBlanker = require("./StudioSourceCommentLineBlanker")
local StudioTransferTextPacker = require("./StudioTransferTextPacker")

local StudioProjectSyncBatchRenderer = {}

local MANIFEST_BATCH_FILE_NAME = "00-install-runtime-and-read-manifest.luau"
local MANIFEST_BATCH_LABEL = "install runtime and read Studio script manifest"
local INSTALLED_RUNTIME_GLOBAL_NAME = "IdolgrowStudioProjectSyncRuntime"

StudioProjectSyncBatchRenderer.renderLuauLiteral = LuauLiteralRenderer.renderLuauLiteral
local renderLuauLiteral = LuauLiteralRenderer.renderLuauLiteral

function StudioProjectSyncBatchRenderer.stripCommentLinesAndIndentation(luauSourceText: string): string
	local keptLines = {}
	for sourceLine in string.gmatch(luauSourceText .. "\n", "([^\n]*)\n") do
		local trimmedLine = string.match(sourceLine, "^%s*(.-)%s*$") :: string
		if trimmedLine ~= "" and string.sub(trimmedLine, 1, 2) ~= "--" then
			table.insert(keptLines, trimmedLine)
		end
	end
	return table.concat(keptLines, "\n")
end

local function buildScriptPathKey(mappedFolderNumber: number, relativePathNames: { string }): string
	return tostring(mappedFolderNumber) .. ":" .. table.concat(relativePathNames, "/")
end

function StudioProjectSyncBatchRenderer.parseStudioScriptManifestText(manifestText: string)
	local manifestEntryByScriptPathKey = {}
	for manifestLine in string.gmatch(manifestText, "[^\r\n]+") do
		local mappedFolderNumberText, className, joinedPathNames, sourceSha256Hex =
			string.match(manifestLine, "^(%d+)\t([%w]+)\t([^\t]+)\t(%x+)$")
		if mappedFolderNumberText == nil then
			error("StudioProjectSyncBatchRenderer: not a Studio script manifest line: " .. manifestLine)
		end
		manifestEntryByScriptPathKey[mappedFolderNumberText .. ":" .. joinedPathNames] = {
			className = className,
			sourceSha256Hex = string.lower(sourceSha256Hex),
		}
	end
	return manifestEntryByScriptPathKey
end

-- The lines of batch 00 that unpack, check, compile and install the runtime it carries packed.
local function renderRuntimeInstallLines(strippedRuntimeText: string, runtimeSha256Hex: string): { string }
	local damagedMessage = "the Studio sync runtime text in this batch was damaged on the way"
	return {
		"local packedRuntimeText = "
			.. renderLuauLiteral(StudioTransferTextPacker.packTextForStudio(strippedRuntimeText)),
		'local EncodingService = game:GetService("EncodingService")',
		"local didUnpack, runtimeText = pcall(function()",
		'\tlocal packedBuffer = EncodingService:Base64Decode(buffer.fromstring((string.gsub(packedRuntimeText, "%s", ""))))',
		"\treturn buffer.tostring(EncodingService:DecompressBuffer(packedBuffer, Enum.CompressionAlgorithm.Zstd))",
		"end)",
		"if not didUnpack then",
		string.format('\terror("%s (it does not unpack); nothing was installed")', damagedMessage),
		"end",
		"local receivedRuntimeSha256Hex = string.gsub(",
		"\tEncodingService:ComputeStringHash(runtimeText, Enum.HashAlgorithm.Sha256),",
		'\t".",',
		"\tfunction(binaryCharacter)",
		'\t\treturn string.format("%02x", string.byte(binaryCharacter))',
		"\tend",
		")",
		string.format("if receivedRuntimeSha256Hex ~= %q then", runtimeSha256Hex),
		string.format('\terror("%s (SHA-256 mismatch); nothing was installed")', damagedMessage),
		"end",
		'if type(loadstring) ~= "function" then',
		'\terror("loadstring is not available here; nothing was installed")',
		"end",
		'local loadRuntime, loadProblem = loadstring(runtimeText, "=StudioSideProjectSyncRuntime")',
		"if loadRuntime == nil then",
		'\terror("the Studio sync runtime does not compile: " .. tostring(loadProblem))',
		"end",
		"local StudioSideProjectSyncRuntime = loadRuntime()",
		string.format(
			"_G.%s = { runtimeSha256Hex = %q, runtime = StudioSideProjectSyncRuntime }",
			INSTALLED_RUNTIME_GLOBAL_NAME,
			runtimeSha256Hex
		),
	}
end

-- Batch 00 installs the runtime in `_G` (shared by every execute_luau call of one Studio session),
-- so the other batches need not carry it. It installs only a runtime text whose SHA-256, computed
-- in Studio, is the one stamped here; the other batches refuse to run when the installed runtime
-- is missing or is not the one they were written with.
local function renderBatchSourceText(strippedRuntimeText: string, batchLabel: string, runtimeCallText: string): string
	local runtimeSha256Hex = serde.hash("sha256", strippedRuntimeText)
	local runtimeLines = if batchLabel == MANIFEST_BATCH_LABEL
		then renderRuntimeInstallLines(strippedRuntimeText, runtimeSha256Hex)
		else {
			string.format("local installedRuntime = _G.%s", INSTALLED_RUNTIME_GLOBAL_NAME),
			string.format(
				"if installedRuntime == nil or installedRuntime.runtimeSha256Hex ~= %q then",
				runtimeSha256Hex
			),
			string.format(
				'\terror("the Studio sync runtime of this batch set is not installed: run %s first")',
				MANIFEST_BATCH_FILE_NAME
			),
			"end",
			"local StudioSideProjectSyncRuntime = installedRuntime.runtime",
		}
	return table.concat({
		"-- idolgrow Studio project sync: " .. batchLabel,
		"-- Generated by tools/SyncProjectIntoStudio.luau; do not edit. Run in Roblox Studio in Edit mode",
		'-- through the execute_luau tool; it returns a report. See README.md, "Loading the project into Roblox Studio".',
		table.concat(runtimeLines, "\n"),
		"local studioAccess = StudioSideProjectSyncRuntime.createStudioAccessFromRobloxStudio(game)",
		runtimeCallText,
		"",
	}, "\n")
end

local function describeFoldersForStudio(folderDescriptions)
	local studioFolderDescriptions = {}
	for _, folderDescription in folderDescriptions do
		table.insert(studioFolderDescriptions, {
			existingParentPathNames = folderDescription.existingParentPathNames,
			mappedFolderName = folderDescription.mappedFolderName,
		})
	end
	return studioFolderDescriptions
end

-- The scripts exactly as Studio will hold them, each with the SHA-256 of that text.
local function prepareStudioScripts(collectedProject, selectedScriptNumberSet)
	local studioScripts = {}
	for scriptNumber, projectScript in collectedProject.projectScripts do
		local studioSourceText = StudioSourceCommentLineBlanker.blankCommentOnlyLines(projectScript.sourceText)
		table.insert(studioScripts, {
			mappedFolderNumber = projectScript.mappedFolderNumber,
			relativePathNames = projectScript.relativePathNames,
			className = projectScript.className,
			sourceText = studioSourceText,
			sourceSha256Hex = serde.hash("sha256", studioSourceText),
			isSelectedForThisSync = selectedScriptNumberSet == nil or selectedScriptNumberSet[scriptNumber] == true,
		})
	end
	return studioScripts
end

local function countSelectedScripts(studioScripts): number
	local selectedScriptCount = 0
	for _, studioScript in studioScripts do
		if studioScript.isSelectedForThisSync then
			selectedScriptCount += 1
		end
	end
	return selectedScriptCount
end

-- The scripts to write, each with its position in the project (`projectOrder`).
local function chooseScriptsToWrite(studioScripts, studioScriptManifestText: string?)
	local manifestEntryByScriptPathKey = if studioScriptManifestText ~= nil
		then StudioProjectSyncBatchRenderer.parseStudioScriptManifestText(studioScriptManifestText)
		else {}
	local scriptsToWrite = {}
	for projectOrder, studioScript in studioScripts do
		local manifestEntry = manifestEntryByScriptPathKey[buildScriptPathKey(
			studioScript.mappedFolderNumber,
			studioScript.relativePathNames
		)]
		local isAlreadyInStudio = manifestEntry ~= nil
			and manifestEntry.className == studioScript.className
			and manifestEntry.sourceSha256Hex == studioScript.sourceSha256Hex
		if studioScript.isSelectedForThisSync and not isAlreadyInStudio then
			table.insert(scriptsToWrite, { projectOrder = projectOrder, studioScript = studioScript })
		end
	end
	return scriptsToWrite
end

-- Groups the scripts to write by identical source (first appearance first), then fills batches
-- with whole source groups up to the byte limit, counting each distinct source once.
local function groupScriptsIntoBatches(scriptsToWrite, maximumSourceBytesPerBatch: number)
	local sourceGroups, sourceGroupBySourceText = {}, {}
	for _, scriptToWrite in scriptsToWrite do
		local sourceText = scriptToWrite.studioScript.sourceText
		local sourceGroup = sourceGroupBySourceText[sourceText]
		if sourceGroup == nil then
			sourceGroup = { sourceText = sourceText, scriptsToWrite = {} }
			sourceGroupBySourceText[sourceText] = sourceGroup
			table.insert(sourceGroups, sourceGroup)
		end
		table.insert(sourceGroup.scriptsToWrite, scriptToWrite)
	end
	local batchGroups = {}
	local currentBatch, currentBatchByteCount = {}, 0
	for _, sourceGroup in sourceGroups do
		if #currentBatch > 0 and currentBatchByteCount + #sourceGroup.sourceText > maximumSourceBytesPerBatch then
			table.insert(batchGroups, currentBatch)
			currentBatch, currentBatchByteCount = {}, 0
		end
		table.insert(currentBatch, sourceGroup)
		currentBatchByteCount += #sourceGroup.sourceText
	end
	if #currentBatch > 0 then
		table.insert(batchGroups, currentBatch)
	end
	return batchGroups
end

-- One write batch's payload: its distinct sources packed, and its scripts in project order.
local function buildScriptWritePayload(batchLabel: string, mappedFolderDescriptions, batchSourceGroups)
	local sourceTexts, batchScripts = {}, {}
	for sourceTextNumber, sourceGroup in batchSourceGroups do
		table.insert(sourceTexts, sourceGroup.sourceText)
		for _, scriptToWrite in sourceGroup.scriptsToWrite do
			table.insert(batchScripts, { sourceTextNumber = sourceTextNumber, scriptToWrite = scriptToWrite })
		end
	end
	table.sort(batchScripts, function(firstScript, secondScript)
		return firstScript.scriptToWrite.projectOrder < secondScript.scriptToWrite.projectOrder
	end)
	local scriptWrites = {}
	for _, batchScript in batchScripts do
		local studioScript = batchScript.scriptToWrite.studioScript
		table.insert(scriptWrites, {
			mappedFolderNumber = studioScript.mappedFolderNumber,
			relativePathNames = studioScript.relativePathNames,
			className = studioScript.className,
			sourceTextNumber = batchScript.sourceTextNumber,
			sourceSha256Hex = studioScript.sourceSha256Hex,
		})
	end
	return {
		batchLabel = batchLabel,
		mappedFolders = mappedFolderDescriptions,
		packedSourceTexts = StudioTransferTextPacker.packTextForStudio(
			StudioSideLengthPrefixedTexts.joinTexts(sourceTexts)
		),
		scriptWrites = scriptWrites,
	}
end

-- "return StudioSideProjectSyncRuntime.<functionName>(studioAccess, <payload>, <payload SHA-256>)"
local function renderPayloadCheckedRuntimeCall(runtimeFunctionName: string, batchPayload): string
	local payloadSha256Hex =
		serde.hash("sha256", StudioSideProjectSyncRuntime.describeBatchPayloadCanonically(batchPayload))
	return string.format(
		"return StudioSideProjectSyncRuntime.%s(studioAccess, %s, %q)",
		runtimeFunctionName,
		renderLuauLiteral(batchPayload),
		payloadSha256Hex
	)
end

local function renderVerificationBatchCall(
	batchLabel: string,
	mappedFolderDescriptions,
	retiredFolderDescriptions,
	collectedProject,
	studioScripts
): string
	local expectedScripts = {}
	for _, studioScript in studioScripts do
		table.insert(expectedScripts, {
			mappedFolderNumber = studioScript.mappedFolderNumber,
			relativePathNames = studioScript.relativePathNames,
			className = studioScript.className,
			sourceSha256Hex = studioScript.sourceSha256Hex,
			isSelectedForThisSync = studioScript.isSelectedForThisSync,
		})
	end
	local expectedFolders = {}
	for _, projectFolder in collectedProject.projectFolders do
		table.insert(expectedFolders, {
			mappedFolderNumber = projectFolder.mappedFolderNumber,
			relativePathNames = projectFolder.relativePathNames,
		})
	end
	return renderPayloadCheckedRuntimeCall("removeUnexpectedInstancesAndVerifyProject", {
		batchLabel = batchLabel,
		mappedFolders = mappedFolderDescriptions,
		retiredFolders = retiredFolderDescriptions,
		expectedFolders = expectedFolders,
		expectedScripts = expectedScripts,
	})
end

function StudioProjectSyncBatchRenderer.renderStudioProjectSyncBatches(
	bundledRuntimeSourceText: string,
	collectedProject,
	renderOptions
)
	local maximumSourceBytesPerBatch = renderOptions.maximumSourceBytesPerBatch
	if type(maximumSourceBytesPerBatch) ~= "number" or maximumSourceBytesPerBatch < 1 then
		error("StudioProjectSyncBatchRenderer: maximumSourceBytesPerBatch must be a positive number")
	end
	local mappedFolderDescriptions = describeFoldersForStudio(collectedProject.mappedFolders)
	local retiredFolderDescriptions = describeFoldersForStudio(renderOptions.retiredFolders or {})
	StudioSideRetiredProjectFolderRemover.checkRetiredFoldersAreNotMapped(
		retiredFolderDescriptions,
		mappedFolderDescriptions
	)
	local strippedRuntimeText = StudioProjectSyncBatchRenderer.stripCommentLinesAndIndentation(bundledRuntimeSourceText)
	local studioSyncBatches = {
		{
			batchFileName = MANIFEST_BATCH_FILE_NAME,
			batchLabel = MANIFEST_BATCH_LABEL,
			batchSourceText = renderBatchSourceText(
				strippedRuntimeText,
				MANIFEST_BATCH_LABEL,
				"return StudioSideProjectSyncRuntime.readStudioScriptManifest(studioAccess, "
					.. renderLuauLiteral(mappedFolderDescriptions)
					.. ")"
			),
			writtenScriptCount = 0,
		},
	}
	local studioScripts = prepareStudioScripts(collectedProject, renderOptions.selectedScriptNumberSet)
	local scriptsToWrite = chooseScriptsToWrite(studioScripts, renderOptions.studioScriptManifestText)
	local batchGroups = groupScriptsIntoBatches(scriptsToWrite, maximumSourceBytesPerBatch)
	for batchNumber, batchSourceGroups in batchGroups do
		local batchLabel = string.format("write scripts %d of %d", batchNumber, #batchGroups)
		local scriptWritePayload = buildScriptWritePayload(batchLabel, mappedFolderDescriptions, batchSourceGroups)
		table.insert(studioSyncBatches, {
			batchFileName = string.format("%02d-write-scripts-%d-of-%d.luau", batchNumber, batchNumber, #batchGroups),
			batchLabel = batchLabel,
			batchSourceText = renderBatchSourceText(
				strippedRuntimeText,
				batchLabel,
				renderPayloadCheckedRuntimeCall("applyScriptWriteBatch", scriptWritePayload)
			),
			writtenScriptCount = #scriptWritePayload.scriptWrites,
		})
	end
	local verificationBatchLabel = "remove unexpected instances and verify"
	table.insert(studioSyncBatches, {
		batchFileName = string.format("%02d-remove-unexpected-and-verify.luau", #batchGroups + 1),
		batchLabel = verificationBatchLabel,
		batchSourceText = renderBatchSourceText(
			strippedRuntimeText,
			verificationBatchLabel,
			renderVerificationBatchCall(
				verificationBatchLabel,
				mappedFolderDescriptions,
				retiredFolderDescriptions,
				collectedProject,
				studioScripts
			)
		),
		writtenScriptCount = 0,
	})
	local selectedScriptCount = countSelectedScripts(studioScripts)
	return {
		studioSyncBatches = studioSyncBatches,
		selectedScriptCount = selectedScriptCount,
		writtenScriptCount = #scriptsToWrite,
		expectedVerificationReportFirstLine = string.format(
			"%s: sync complete, verified %d of %d selected scripts (%d project scripts in all)",
			verificationBatchLabel,
			selectedScriptCount,
			selectedScriptCount,
			#studioScripts
		),
	}
end

return table.freeze(StudioProjectSyncBatchRenderer)
