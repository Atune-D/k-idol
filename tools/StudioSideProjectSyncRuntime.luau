-- StudioSideProjectSyncRuntime: the part of the Studio project sync that runs INSIDE Roblox Studio
-- (Edit mode). Batch 00 written by tools/SyncProjectIntoStudio.luau carries this file's text
-- (bundled with its parts by tools/StudioSyncRuntimeBundler.luau, comment lines and indentation
-- removed, packed) and installs it for the Studio session; the later batches call it. The README
-- section "Loading the project into Roblox Studio" has the procedure.
-- It requires only its runtime parts (each `local X = require("./X")`, pasted in by the bundler);
-- they require nothing. Everything Roblox-specific goes through a `studioAccess` table, so the
-- Lune tests drive the same functions with Lune's own Instance implementation
-- (tests/tools/StudioSideProjectSyncRuntime*.spec.luau).
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (called by the generated batches, built by tools/StudioProjectSyncBatchRenderer.luau)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- StudioSideProjectSyncRuntime.createStudioAccessFromRobloxStudio(dataModel) -> studioAccess
--   studioAccess = { dataModel (`game`), createInstance(className) (Instance.new),
--     computeSha256Hex(text) -> lower-case hex (EncodingService ComputeStringHash),
--     unpackText(packedText) -> text: whitespace removed, then EncodingService Base64Decode and
--       DecompressBuffer (Zstd); the inverse of tools/StudioTransferTextPacker.luau,
--     writeScriptSource(scriptInstance, sourceText) -> wasOpenInScriptEditor: boolean
--       (sets Source, or asks the Script Editor through UpdateSourceAsync when the script is open) }
-- A mapped folder is { existingParentPathNames = { "StarterPlayer", "StarterPlayerScripts" },
-- mappedFolderName = "Client" }: the first parent name is a service (found with GetService), the
-- others must already exist as children (they are never created or removed); the mapped folder
-- itself and everything inside it belong to the project and are created, updated and removed.
--
-- StudioSideProjectSyncRuntime.describeBatchPayloadCanonically(batchPayload) -> string
--   tools/StudioSideBatchPayloadCanonicalText.luau. The renderer (Lune) puts the SHA-256 of this
--   text in each batch; the runtime recomputes it from the payload it actually received.
-- The two functions that change the place first raise, touching nothing, unless
-- studioAccess.computeSha256Hex(describeBatchPayloadCanonically(payload)) == payloadSha256Hex, so
-- a payload damaged on its way into execute_luau (a path, a class, a script left out) changes nothing.
--
-- StudioSideProjectSyncRuntime.applyScriptWriteBatch(studioAccess, scriptWriteBatch, payloadSha256Hex) -> reportText
--   scriptWriteBatch = { batchLabel, mappedFolders, packedSourceTexts, scriptWrites = { {
--     mappedFolderNumber, relativePathNames, className, sourceTextNumber, sourceSha256Hex } } }
--   packedSourceTexts: the batch's distinct sources joined by StudioSideLengthPrefixedTexts and
--   packed (unpackText reverses it); scripts with one source (both copies of a shared module) share it.
--   Before touching anything, checks the payload SHA-256, unpacks, and checks each script's source
--   against its SHA-256: any failure raises and nothing is changed. Then, per script, in order:
--   missing folders on the way are created; a missing script is "created"; one with other source
--   is "updated"; identical source is "unchanged"; an instance of the wrong class there is destroyed
--   and recreated ("replaced"); extra instances with the name are destroyed ("removed duplicate").
--   The report has one line per action plus a count line.
--
-- StudioSideProjectSyncRuntime.removeUnexpectedInstancesAndVerifyProject(studioAccess, projectShape, payloadSha256Hex) -> reportText
--   projectShape = { batchLabel, mappedFolders, retiredFolders, expectedFolders = { {
--     mappedFolderNumber, relativePathNames } }, expectedScripts = { { mappedFolderNumber,
--     relativePathNames, className, sourceSha256Hex, isSelectedForThisSync } } }
--   After the payload check (and a check that no retired folder is mapped), removes the retired
--   project folders (StudioSideRetiredProjectFolderRemover), creates every missing expected folder,
--   destroys every instance inside a mapped folder that is not an expected folder or script, every
--   duplicate, and every instance whose Name holds "/", a tab, CR or LF (it could pass for a project
--   path); then checks that every SELECTED expected script exists once with the right class and
--   SHA-256 (a partial sync selects some; the others are kept and not checked). The first line reads
--   "sync complete, verified N of N selected scripts (M project scripts in all)" or, when anything
--   is wrong, "SYNC INCOMPLETE, ..." with one "MISMATCH" line per problem; removals are listed.
--
-- StudioSideProjectSyncRuntime.readStudioScriptManifest(studioAccess, mappedFolders) -> manifestText
--   One line per script inside the mapped folders: "<mappedFolderNumber>\t<ClassName>\t<names
--   joined by '/'>\t<sha256 hex>". Read-only. An instance whose Name holds "/", a tab, CR or LF is
--   left out with everything inside it (the next remove-and-verify batch removes it).
--   tools/SyncProjectIntoStudio.luau --studio-manifest takes this text to write only what differs.
--
-- Roblox API used, each read in the official documentation while writing this file
-- (https://create.roblox.com/docs/reference/engine/...):
--   game:GetService                                  classes/ServiceProvider
--   Instance.new, Name, Parent, ClassName, GetChildren, Destroy, GetFullName   classes/Instance
--   ModuleScript.Source (read and write security None)   classes/ModuleScript
--   Script.Source, LocalScript                       classes/Script, classes/LocalScript
--   ScriptEditorService:FindScriptDocument, :UpdateSourceAsync   classes/ScriptEditorService
--   EncodingService:ComputeStringHash, Enum.HashAlgorithm.Sha256   classes/EncodingService, enums/HashAlgorithm
--   EncodingService:Base64Decode(buffer) -> buffer, :DecompressBuffer(buffer, algorithm) -> buffer,
--     Enum.CompressionAlgorithm.Zstd   classes/EncodingService, enums/CompressionAlgorithm
--   buffer.fromstring, buffer.tostring               libraries/buffer
-- Verified in Studio 0.748 on 2026-11-19 (Place1, Edit mode, through execute_luau): Source written
-- and read back is byte-identical (CR LF kept); ComputeStringHash Sha256 equals Lune's
-- serde.hash("sha256"); Base64Decode then DecompressBuffer gives back a text packed by Lune
-- byte-identically (CR and NUL included) once the Zstandard header states the content size.

local StudioSideBatchPayloadCanonicalText = require("./StudioSideBatchPayloadCanonicalText")
local StudioSideLengthPrefixedTexts = require("./StudioSideLengthPrefixedTexts")
local StudioSideRetiredProjectFolderRemover = require("./StudioSideRetiredProjectFolderRemover")

local StudioSideProjectSyncRuntime = {}

local function convertBinaryTextToLowerCaseHex(binaryText: string): string
	return (
		string.gsub(binaryText, ".", function(binaryCharacter)
			return string.format("%02x", string.byte(binaryCharacter))
		end)
	)
end

function StudioSideProjectSyncRuntime.createStudioAccessFromRobloxStudio(dataModel: any)
	local EncodingService = dataModel:GetService("EncodingService")
	local ScriptEditorService = dataModel:GetService("ScriptEditorService")
	return {
		dataModel = dataModel,
		createInstance = function(className: string)
			return Instance.new(className)
		end,
		computeSha256Hex = function(text: string): string
			return convertBinaryTextToLowerCaseHex(EncodingService:ComputeStringHash(text, Enum.HashAlgorithm.Sha256))
		end,
		unpackText = function(packedText: string): string
			local packedBuffer = EncodingService:Base64Decode(buffer.fromstring((string.gsub(packedText, "%s", ""))))
			return buffer.tostring(EncodingService:DecompressBuffer(packedBuffer, Enum.CompressionAlgorithm.Zstd))
		end,
		writeScriptSource = function(scriptInstance: any, sourceText: string): boolean
			if ScriptEditorService:FindScriptDocument(scriptInstance) ~= nil then
				ScriptEditorService:UpdateSourceAsync(scriptInstance, function()
					return sourceText
				end)
				return true
			end
			scriptInstance.Source = sourceText
			return false
		end,
	}
end

local SCRIPT_CLASS_NAMES = { ModuleScript = true, Script = true, LocalScript = true }

StudioSideProjectSyncRuntime.describeBatchPayloadCanonically =
	StudioSideBatchPayloadCanonicalText.describeBatchPayloadCanonically

-- Raises, before anything in Studio is touched, unless the payload is exactly what Lune hashed.
local function checkBatchPayloadSha256(studioAccess, batchPayload, payloadSha256Hex: string?)
	local receivedPayloadSha256Hex =
		studioAccess.computeSha256Hex(StudioSideProjectSyncRuntime.describeBatchPayloadCanonically(batchPayload))
	if receivedPayloadSha256Hex ~= payloadSha256Hex then
		error(
			string.format(
				"StudioSideProjectSyncRuntime: %s: the batch payload does not match its SHA-256 (damaged on the way?); nothing was changed",
				tostring(batchPayload.batchLabel)
			)
		)
	end
end

-- A name that holds the path separator or a manifest field or line separator could pass for
-- another path of the project, so an instance named like that is never kept or listed.
local function isNameUsableInPathKey(instanceName: string): boolean
	return string.find(instanceName, "[/\t\r\n]") == nil
end

local function findChildrenNamed(parentInstance: any, childName: string): { any }
	local matchingChildren = {}
	for _, childInstance in parentInstance:GetChildren() do
		if childInstance.Name == childName then
			table.insert(matchingChildren, childInstance)
		end
	end
	return matchingChildren
end

local function findExistingMappedFolderParent(studioAccess, mappedFolder): any
	local parentPathNames = mappedFolder.existingParentPathNames
	local currentInstance = studioAccess.dataModel:GetService(parentPathNames[1])
	for namePosition = 2, #parentPathNames do
		local matchingChildren = findChildrenNamed(currentInstance, parentPathNames[namePosition])
		if #matchingChildren ~= 1 then
			error(
				string.format(
					"StudioSideProjectSyncRuntime: expected exactly one %s under %s, found %d",
					parentPathNames[namePosition],
					currentInstance:GetFullName(),
					#matchingChildren
				)
			)
		end
		currentInstance = matchingChildren[1]
	end
	return currentInstance
end

-- Returns the single child of `className` named `childName`, creating it when missing. A child of
-- another class is destroyed and recreated; further children with the name are destroyed. Every
-- action is appended to `reportLines`; the second result says whether the child was created.
local function ensureSingleChildOfClass(studioAccess, parentInstance, childName, className, reportLines): (any, boolean)
	local keptChild = nil
	for _, candidateChild in findChildrenNamed(parentInstance, childName) do
		if keptChild == nil and candidateChild.ClassName == className then
			keptChild = candidateChild
		end
	end
	for _, candidateChild in findChildrenNamed(parentInstance, childName) do
		if candidateChild ~= keptChild then
			local isWrongClass = candidateChild.ClassName ~= className
			table.insert(
				reportLines,
				string.format(
					"%s %s (%s)",
					if isWrongClass and keptChild == nil then "replaced" else "removed duplicate",
					candidateChild:GetFullName(),
					candidateChild.ClassName
				)
			)
			candidateChild:Destroy()
		end
	end
	if keptChild ~= nil then
		return keptChild, false
	end
	local createdChild = studioAccess.createInstance(className)
	createdChild.Name = childName
	createdChild.Parent = parentInstance
	return createdChild, true
end

local function ensureMappedFolder(studioAccess, mappedFolder, reportLines): any
	local parentInstance = findExistingMappedFolderParent(studioAccess, mappedFolder)
	local mappedFolderInstance, wasCreated =
		ensureSingleChildOfClass(studioAccess, parentInstance, mappedFolder.mappedFolderName, "Folder", reportLines)
	if wasCreated then
		table.insert(reportLines, "created " .. mappedFolderInstance:GetFullName() .. " (Folder)")
	end
	return mappedFolderInstance
end

local function ensureFolderPath(studioAccess, mappedFolderInstance, folderPathNames, reportLines): any
	local currentInstance = mappedFolderInstance
	for _, folderName in folderPathNames do
		local folderInstance, wasCreated =
			ensureSingleChildOfClass(studioAccess, currentInstance, folderName, "Folder", reportLines)
		if wasCreated then
			table.insert(reportLines, "created " .. folderInstance:GetFullName() .. " (Folder)")
		end
		currentInstance = folderInstance
	end
	return currentInstance
end

local function splitParentAndLeafNames(relativePathNames: { string }): ({ string }, string)
	local parentNames = table.clone(relativePathNames)
	local leafName = table.remove(parentNames)
	return parentNames, leafName :: string
end

-- Raises, before anything in Studio is touched, when a script write is not usable. Returns each
-- script write's source text, in the order of scriptWrites.
local function checkScriptWritesBeforeApplying(studioAccess, scriptWriteBatch, sourceTexts: { string }): { string }
	local scriptSourceTexts = {}
	for _, scriptWrite in scriptWriteBatch.scriptWrites do
		local scriptDescription = table.concat(scriptWrite.relativePathNames, "/")
		local sourceText = sourceTexts[scriptWrite.sourceTextNumber]
		if not SCRIPT_CLASS_NAMES[scriptWrite.className] then
			error(
				string.format(
					"StudioSideProjectSyncRuntime: %s: %s is not a script class (%s); nothing was changed",
					scriptWriteBatch.batchLabel,
					scriptDescription,
					tostring(scriptWrite.className)
				)
			)
		end
		if sourceText == nil or studioAccess.computeSha256Hex(sourceText) ~= scriptWrite.sourceSha256Hex then
			error(
				string.format(
					"StudioSideProjectSyncRuntime: %s: source of %s does not match its SHA-256; nothing was changed",
					scriptWriteBatch.batchLabel,
					scriptDescription
				)
			)
		end
		table.insert(scriptSourceTexts, sourceText)
	end
	return scriptSourceTexts
end

function StudioSideProjectSyncRuntime.applyScriptWriteBatch(
	studioAccess,
	scriptWriteBatch,
	payloadSha256Hex: string
): string
	checkBatchPayloadSha256(studioAccess, scriptWriteBatch, payloadSha256Hex)
	local sourceTexts = StudioSideLengthPrefixedTexts.unpackAndSplitTexts(
		studioAccess.unpackText,
		scriptWriteBatch.packedSourceTexts,
		scriptWriteBatch.batchLabel
	)
	local scriptSourceTexts = checkScriptWritesBeforeApplying(studioAccess, scriptWriteBatch, sourceTexts)
	local reportLines = {}
	local actionCounts = { created = 0, updated = 0, unchanged = 0 }
	for scriptWritePosition, scriptWrite in scriptWriteBatch.scriptWrites do
		local mappedFolderInstance = ensureMappedFolder(
			studioAccess,
			scriptWriteBatch.mappedFolders[scriptWrite.mappedFolderNumber],
			reportLines
		)
		local folderPathNames, scriptName = splitParentAndLeafNames(scriptWrite.relativePathNames)
		local parentInstance = ensureFolderPath(studioAccess, mappedFolderInstance, folderPathNames, reportLines)
		local scriptInstance, wasCreated =
			ensureSingleChildOfClass(studioAccess, parentInstance, scriptName, scriptWrite.className, reportLines)
		local sourceText = scriptSourceTexts[scriptWritePosition]
		local scriptAction = if wasCreated
			then "created"
			elseif scriptInstance.Source == sourceText then "unchanged"
			else "updated"
		if scriptAction ~= "unchanged" then
			local wasOpenInScriptEditor = studioAccess.writeScriptSource(scriptInstance, sourceText)
			if wasOpenInScriptEditor then
				table.insert(reportLines, "note " .. scriptInstance:GetFullName() .. " was open in the Script Editor")
			end
		end
		actionCounts[scriptAction] += 1
		if scriptAction ~= "unchanged" then
			table.insert(
				reportLines,
				string.format("%s %s (%s)", scriptAction, scriptInstance:GetFullName(), scriptWrite.className)
			)
		end
	end
	table.insert(
		reportLines,
		1,
		string.format(
			"%s: %d created, %d updated, %d unchanged",
			scriptWriteBatch.batchLabel,
			actionCounts.created,
			actionCounts.updated,
			actionCounts.unchanged
		)
	)
	return table.concat(reportLines, "\n")
end

local function buildPathKey(mappedFolderNumber: number, relativePathNames: { string }): string
	return tostring(mappedFolderNumber) .. ":" .. table.concat(relativePathNames, "/")
end

-- Destroys, depth first, every descendant of `parentInstance` that the project does not list.
local function removeUnlistedDescendants(parentInstance, mappedFolderNumber, parentPathNames, listedKinds, reportLines)
	local isNameAlreadyKept = {}
	for _, childInstance in parentInstance:GetChildren() do
		local childPathNames = table.clone(parentPathNames)
		table.insert(childPathNames, childInstance.Name)
		local listedClassName = listedKinds[buildPathKey(mappedFolderNumber, childPathNames)]
		local isKept = listedClassName == childInstance.ClassName
			and not isNameAlreadyKept[childInstance.Name]
			and isNameUsableInPathKey(childInstance.Name)
		if isKept then
			isNameAlreadyKept[childInstance.Name] = true
			removeUnlistedDescendants(childInstance, mappedFolderNumber, childPathNames, listedKinds, reportLines)
		else
			table.insert(
				reportLines,
				string.format("removed %s (%s)", childInstance:GetFullName(), childInstance.ClassName)
			)
			childInstance:Destroy()
		end
	end
end

local function findInstanceAtRelativePath(mappedFolderInstance, relativePathNames): any
	local currentInstance = mappedFolderInstance
	for _, pathName in relativePathNames do
		currentInstance = findChildrenNamed(currentInstance, pathName)[1]
		if currentInstance == nil then
			return nil
		end
	end
	return currentInstance
end

function StudioSideProjectSyncRuntime.removeUnexpectedInstancesAndVerifyProject(
	studioAccess,
	projectShape,
	payloadSha256Hex: string
): string
	checkBatchPayloadSha256(studioAccess, projectShape, payloadSha256Hex)
	StudioSideRetiredProjectFolderRemover.checkRetiredFoldersAreNotMapped(
		projectShape.retiredFolders,
		projectShape.mappedFolders
	)
	local reportLines = {}
	local retiredFolderProblemCount = StudioSideRetiredProjectFolderRemover.removeRetiredProjectFolders(
		studioAccess,
		projectShape.retiredFolders,
		reportLines
	)
	local mappedFolderInstances = {}
	for mappedFolderNumber, mappedFolder in projectShape.mappedFolders do
		mappedFolderInstances[mappedFolderNumber] = ensureMappedFolder(studioAccess, mappedFolder, reportLines)
	end
	local listedKinds = {}
	for _, expectedFolder in projectShape.expectedFolders do
		ensureFolderPath(
			studioAccess,
			mappedFolderInstances[expectedFolder.mappedFolderNumber],
			expectedFolder.relativePathNames,
			reportLines
		)
		listedKinds[buildPathKey(expectedFolder.mappedFolderNumber, expectedFolder.relativePathNames)] = "Folder"
	end
	for _, expectedScript in projectShape.expectedScripts do
		listedKinds[buildPathKey(expectedScript.mappedFolderNumber, expectedScript.relativePathNames)] =
			expectedScript.className
	end
	for mappedFolderNumber, mappedFolderInstance in mappedFolderInstances do
		removeUnlistedDescendants(mappedFolderInstance, mappedFolderNumber, {}, listedKinds, reportLines)
	end

	-- Duplicates and wrong classes are gone after the removal above, so a selected script is
	-- either missing or present once with the expected class.
	local verifiedScriptCount, selectedScriptCount = 0, 0
	for _, expectedScript in projectShape.expectedScripts do
		if expectedScript.isSelectedForThisSync then
			selectedScriptCount += 1
			local scriptInstance = findInstanceAtRelativePath(
				mappedFolderInstances[expectedScript.mappedFolderNumber],
				expectedScript.relativePathNames
			)
			local mismatchDescription = if scriptInstance == nil
				then "missing (run the write batches)"
				elseif
					studioAccess.computeSha256Hex(scriptInstance.Source) ~= expectedScript.sourceSha256Hex
				then "source differs (run the write batches)"
				else nil
			if mismatchDescription == nil then
				verifiedScriptCount += 1
			else
				table.insert(
					reportLines,
					string.format(
						"MISMATCH %d:%s: %s",
						expectedScript.mappedFolderNumber,
						table.concat(expectedScript.relativePathNames, "/"),
						mismatchDescription
					)
				)
			end
		end
	end
	table.insert(
		reportLines,
		1,
		string.format(
			"%s: %s, verified %d of %d selected scripts (%d project scripts in all)",
			projectShape.batchLabel,
			if verifiedScriptCount == selectedScriptCount and retiredFolderProblemCount == 0
				then "sync complete"
				else "SYNC INCOMPLETE",
			verifiedScriptCount,
			selectedScriptCount,
			#projectShape.expectedScripts
		)
	)
	return table.concat(reportLines, "\n")
end

local function appendScriptManifestLines(
	parentInstance,
	mappedFolderNumber,
	parentPathNames,
	studioAccess,
	manifestLines
)
	for _, childInstance in parentInstance:GetChildren() do
		if not isNameUsableInPathKey(childInstance.Name) then
			continue
		end
		local childPathNames = table.clone(parentPathNames)
		table.insert(childPathNames, childInstance.Name)
		if SCRIPT_CLASS_NAMES[childInstance.ClassName] then
			table.insert(
				manifestLines,
				string.format(
					"%d\t%s\t%s\t%s",
					mappedFolderNumber,
					childInstance.ClassName,
					table.concat(childPathNames, "/"),
					studioAccess.computeSha256Hex(childInstance.Source)
				)
			)
		end
		appendScriptManifestLines(childInstance, mappedFolderNumber, childPathNames, studioAccess, manifestLines)
	end
end

function StudioSideProjectSyncRuntime.readStudioScriptManifest(studioAccess, mappedFolders): string
	local manifestLines = {}
	for mappedFolderNumber, mappedFolder in mappedFolders do
		local parentInstance = findExistingMappedFolderParent(studioAccess, mappedFolder)
		for _, mappedFolderInstance in findChildrenNamed(parentInstance, mappedFolder.mappedFolderName) do
			appendScriptManifestLines(mappedFolderInstance, mappedFolderNumber, {}, studioAccess, manifestLines)
		end
	end
	return table.concat(manifestLines, "\n")
end

return StudioSideProjectSyncRuntime
