-- Test harness for the Studio project sync: a stand-in Studio session built on Lune's own Roblox
-- Instance implementation (@lune/roblox), in which the generated batch TEXT is run exactly as
-- execute_luau would run it (compiled with @lune/luau, `game`, `_G`, `Instance`, `Enum` and
-- `loadstring` provided). EncodingService and ScriptEditorService are fakes; Lune has neither.
-- The fake EncodingService decodes Base64 itself (strictly) and decompresses with @lune/serde,
-- and, like Roblox's DecompressBuffer (observed in Studio 0.748 on 2026-11-19), refuses a
-- Zstandard frame whose header does not state the content size.
-- MAPPED_FOLDERS follows this project's layout: each side has its own "shared" sibling folder.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local StudioProjectSyncBatchRenderer = require("../../tools/StudioProjectSyncBatchRenderer")
local StudioSyncRuntimeBundler = require("../../tools/StudioSyncRuntimeBundler")

local StudioProjectSyncTestHarness = {}

local function findProjectRootFolderPath(): string
	local harnessFilePath = debug.info(1, "s")
	local projectRootFolderPath = string.match(harnessFilePath, "^(.*)[/\\]tests[/\\]tools[/\\][^/\\]+$")
	assert(projectRootFolderPath ~= nil, "cannot work out the project root from " .. tostring(harnessFilePath))
	return projectRootFolderPath
end

local function readRuntimeSourceText(runtimeSourceName: string): string
	return fs.readFile(findProjectRootFolderPath() .. "/tools/" .. runtimeSourceName .. ".luau")
end

-- The bundled runtime (runtime and its parts), as tools/SyncProjectIntoStudio.luau passes it.
StudioProjectSyncTestHarness.RUNTIME_SOURCE_TEXT = StudioSyncRuntimeBundler.bundleRuntimeSourceText(
	readRuntimeSourceText("StudioSideProjectSyncRuntime"),
	readRuntimeSourceText
)

StudioProjectSyncTestHarness.MAPPED_FOLDERS = {
	{
		existingParentPathNames = { "ServerScriptService" },
		mappedFolderName = "shared",
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
	{
		existingParentPathNames = { "StarterPlayer", "StarterPlayerScripts" },
		mappedFolderName = "shared",
		sourceDirectoryPath = "src/shared",
	},
}

-- The folder this project mapped before each side got its own "shared".
StudioProjectSyncTestHarness.RETIRED_FOLDERS = {
	{ existingParentPathNames = { "ReplicatedStorage" }, mappedFolderName = "Shared" },
}

local function convertHexToBinaryText(hexText: string): string
	return (string.gsub(hexText, "%x%x", function(hexPair)
		return string.char(tonumber(hexPair, 16) :: number)
	end))
end

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Strict Base64 (RFC 4648, "=" padded, length a multiple of 4); raises on anything else.
function StudioProjectSyncTestHarness.decodeBase64(encodedText: string): string
	if #encodedText % 4 ~= 0 or string.find(encodedText, "[^%w%+/=]") or string.find(encodedText, "=[^=]") then
		error("fake Base64Decode: not Base64")
	end
	local decodedParts = {}
	for groupStart = 1, #encodedText, 4 do
		local groupValue, paddingCount = 0, 0
		for characterPosition = groupStart, groupStart + 3 do
			local character = string.sub(encodedText, characterPosition, characterPosition)
			local sixBits = 0
			if character == "=" then
				paddingCount += 1
			else
				sixBits = (string.find(BASE64_ALPHABET, character, 1, true) :: number) - 1
			end
			groupValue = groupValue * 64 + sixBits
		end
		local groupBytes = string.char(
			bit32.band(bit32.rshift(groupValue, 16), 255),
			bit32.band(bit32.rshift(groupValue, 8), 255),
			bit32.band(groupValue, 255)
		)
		table.insert(decodedParts, string.sub(groupBytes, 1, 3 - paddingCount))
	end
	return table.concat(decodedParts)
end

-- Like Roblox's DecompressBuffer: refuses a Zstandard frame without the content size in its header.
function StudioProjectSyncTestHarness.decompressZstdFrameStatingItsSize(frameBytes: string): string
	local frameHeaderDescriptor = string.byte(frameBytes, 5) or 0
	local statesContentSize = bit32.rshift(frameHeaderDescriptor, 6) ~= 0 or bit32.band(frameHeaderDescriptor, 32) ~= 0
	if string.sub(frameBytes, 1, 4) ~= "\40\181\47\253" or not statesContentSize then
		error("DecompressBuffer: decompression failed - Error (generic)")
	end
	return serde.decompress("zstd", frameBytes)
end

-- The batch text with one character of a packed text changed (the `characterNumber`-th Base64
-- character, default 1, after `fieldPrefix`, which is followed by `"` or `[[` and a line break).
function StudioProjectSyncTestHarness.changeOnePackedCharacter(
	batchText: string,
	fieldPrefix: string,
	characterNumber: number?
): string
	local _, prefixEnd = string.find(batchText, fieldPrefix, 1, true)
	assert(prefixEnd ~= nil, "test setup: packed field not found: " .. fieldPrefix)
	local openingText = string.match(batchText, '^"', prefixEnd + 1)
		or string.match(batchText, "^%[=*%[\n", prefixEnd + 1)
	assert(openingText ~= nil, "test setup: packed field is not a string literal: " .. fieldPrefix)
	local changedPosition = (prefixEnd :: number) + #openingText + (characterNumber or 1)
	local originalCharacter = string.sub(batchText, changedPosition, changedPosition)
	assert(string.match(originalCharacter, "[%w%+/]") ~= nil, "test setup: not a Base64 character")
	return string.sub(batchText, 1, changedPosition - 1)
		.. (if originalCharacter == "Q" then "R" else "Q")
		.. string.sub(batchText, changedPosition + 1)
end

-- A fresh stand-in Studio session: an empty place (with StarterPlayerScripts, which a fresh
-- Studio place has) and its own `_G`.
function StudioProjectSyncTestHarness.createStudioSession()
	local dataModel = roblox.Instance.new("DataModel")
	local starterPlayerScripts = roblox.Instance.new("StarterPlayerScripts")
	starterPlayerScripts.Name = "StarterPlayerScripts"
	starterPlayerScripts.Parent = dataModel:GetService("StarterPlayer")
	local studioSession = { dataModel = dataModel, sessionGlobals = {}, openScriptDocuments = {}, editorUpdates = {} }
	local fakeEncodingService = {
		ComputeStringHash = function(_, text: string, hashAlgorithm)
			assert(hashAlgorithm == "Sha256", "only Sha256 is faked")
			return convertHexToBinaryText(serde.hash("sha256", text))
		end,
		Base64Decode = function(_, encodedBuffer)
			return buffer.fromstring(StudioProjectSyncTestHarness.decodeBase64(buffer.tostring(encodedBuffer)))
		end,
		DecompressBuffer = function(_, compressedBuffer, compressionAlgorithm)
			assert(compressionAlgorithm == "Zstd", "only Zstd is faked")
			return buffer.fromstring(
				StudioProjectSyncTestHarness.decompressZstdFrameStatingItsSize(buffer.tostring(compressedBuffer))
			)
		end,
	}
	local fakeScriptEditorService = {
		FindScriptDocument = function(_, scriptInstance)
			return studioSession.openScriptDocuments[scriptInstance]
		end,
		UpdateSourceAsync = function(_, scriptInstance, decideNewSource)
			table.insert(studioSession.editorUpdates, scriptInstance:GetFullName())
			scriptInstance.Source = decideNewSource(scriptInstance.Source)
		end,
	}
	studioSession.fakeGame = {
		GetService = function(_, serviceName: string)
			if serviceName == "EncodingService" then
				return fakeEncodingService
			elseif serviceName == "ScriptEditorService" then
				return fakeScriptEditorService
			end
			return dataModel:GetService(serviceName)
		end,
	}
	return studioSession
end

-- Runs one batch's text in the session, as execute_luau would; returns (didRun, reportOrError).
-- `loadstring` behaves as Roblox documents it: the compiled function, or nil and the error text.
-- isLoadstringMissing (optional) runs the batch where loadstring is not a function (false: a nil
-- entry would fall through to Lune's own globals).
function StudioProjectSyncTestHarness.runBatchInStudioSession(
	studioSession,
	batchSourceText: string,
	isLoadstringMissing: boolean?
)
	local batchEnvironment = {
		game = studioSession.fakeGame,
		_G = studioSession.sessionGlobals,
		Instance = roblox.Instance,
		Enum = { HashAlgorithm = { Sha256 = "Sha256" }, CompressionAlgorithm = { Zstd = "Zstd" } },
	}
	batchEnvironment.loadstring = if isLoadstringMissing
		then false
		else function(chunkText: string, chunkName: string)
			local didCompile, chunkFunctionOrError = pcall(luau.load, chunkText, {
				debugName = chunkName,
				environment = batchEnvironment,
			})
			if didCompile then
				return chunkFunctionOrError
			end
			return nil, tostring(chunkFunctionOrError)
		end
	local batchFunction = luau.load(batchSourceText, {
		debugName = "studio sync batch",
		environment = batchEnvironment,
	})
	return pcall(batchFunction)
end

-- Renders the batches for `projectScripts` (and `projectFolders`) and runs them all in order.
-- Returns the reports and the rendered batches.
function StudioProjectSyncTestHarness.renderAndRunAllBatches(studioSession, collectedProject, renderOptions)
	local renderedSync = StudioProjectSyncBatchRenderer.renderStudioProjectSyncBatches(
		StudioProjectSyncTestHarness.RUNTIME_SOURCE_TEXT,
		collectedProject,
		renderOptions or { maximumSourceBytesPerBatch = 200 }
	)
	local batchReports = {}
	for _, studioSyncBatch in renderedSync.studioSyncBatches do
		local didRun, reportOrError =
			StudioProjectSyncTestHarness.runBatchInStudioSession(studioSession, studioSyncBatch.batchSourceText)
		if not didRun then
			error(string.format("batch %s failed: %s", studioSyncBatch.batchFileName, tostring(reportOrError)), 2)
		end
		table.insert(batchReports, reportOrError)
	end
	return batchReports, renderedSync
end

function StudioProjectSyncTestHarness.buildCollectedProject(projectScripts, projectFolders)
	return {
		mappedFolders = StudioProjectSyncTestHarness.MAPPED_FOLDERS,
		projectFolders = projectFolders or {},
		projectScripts = projectScripts,
	}
end

function StudioProjectSyncTestHarness.buildProjectScript(
	mappedFolderNumber: number,
	relativePathNames: { string },
	className: string,
	sourceText: string
)
	return {
		mappedFolderNumber = mappedFolderNumber,
		relativePathNames = relativePathNames,
		className = className,
		sourceText = sourceText,
		sourceFilePath = "fake/" .. table.concat(relativePathNames, "/"),
	}
end

-- Lists "<FullName> (<ClassName>)" for every descendant of the three mapped parents, sorted, and
-- each script's Source by full name.
function StudioProjectSyncTestHarness.describePlace(studioSession)
	local describedInstances, sourceByFullName = {}, {}
	local starterPlayerScripts =
		studioSession.dataModel:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts")
	for _, rootInstance in
		{
			studioSession.dataModel:GetService("ReplicatedStorage"),
			studioSession.dataModel:GetService("ServerScriptService"),
			starterPlayerScripts,
		}
	do
		for _, descendant in rootInstance:GetDescendants() do
			table.insert(describedInstances, descendant:GetFullName() .. " (" .. descendant.ClassName .. ")")
			if descendant:IsA("LuaSourceContainer") then
				sourceByFullName[descendant:GetFullName()] = descendant.Source
			end
		end
	end
	table.sort(describedInstances)
	return describedInstances, sourceByFullName
end

return StudioProjectSyncTestHarness
