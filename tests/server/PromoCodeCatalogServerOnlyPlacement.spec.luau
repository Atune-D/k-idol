-- Spec §1.9: the promo code catalog is never placed where player devices can read it.
-- Checked by effect, not by a hand-kept list. Everything is derived from default.project.json:
--   * every `$path` is resolved ("." and ".." segments, letter case ignored for comparison; an
--     empty result is the project root, which covers everything). A `$path` that cannot be
--     resolved (absolute, escaping the project, or a nested *.project.json) fails the test;
--   * the catalog file is covered only by mappings under a server-only top-level service;
--   * every mapping under any other top-level service is device-readable, and no file under it
--     (read from disk, recursively, any extension) names the module or contains any catalog
--     promoCodeText, ignoring case.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local UnitTestFramework = require("../Support/UnitTestFramework")
local PromoCodeCatalog = require("../../src/server/PromoCodeCatalog")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PROMO_CODE_CATALOG_MODULE_NAME = "PromoCodeCatalog"
local PROMO_CODE_CATALOG_PROJECT_RELATIVE_PATH = "src/server/PromoCodeCatalog.luau"
-- The top-level services whose contents Roblox keeps on the server. Any other service counts as
-- device-readable, so a newly mapped service is scanned unless it is added here on purpose.
local SERVER_ONLY_TOP_LEVEL_SERVICE_NAME_SET = { ServerScriptService = true, ServerStorage = true }
local PROJECT_ROOT_SERVICE_LABEL = "(project root)"

type ScannedSourceFile = {
	scannedFilePath: string,
	fileSourceText: string,
}

type ProjectTreeAnalysis = {
	servicesPlacingPromoCodeCatalog: { string },
	deviceReadableProjectPaths: { string },
	unresolvableMappingLines: { string },
}

local function findProjectRootFolderPath(): string
	local specFilePath = debug.info(1, "s")
	local projectRootFolderPath = string.match(specFilePath, "^(.*)[/\\]tests[/\\]server[/\\][^/\\]+$")
	assert(projectRootFolderPath ~= nil, "cannot work out the project root from " .. tostring(specFilePath))
	return projectRootFolderPath
end

local PROJECT_ROOT_FOLDER_PATH = findProjectRootFolderPath()

-- Resolves a project-relative `$path` to "a/b/c" ("" for the project root), letter case kept.
-- Returns nil and a reason when the path cannot be resolved inside the project.
local function resolveMappedProjectPath(mappedProjectPath: string): (string?, string?)
	local slashedPath = string.gsub(mappedProjectPath, "\\", "/")
	if string.sub(slashedPath, 1, 1) == "/" or string.match(slashedPath, "^%a:") then
		return nil, "is absolute"
	end
	local resolvedSegments = {}
	for pathSegment in string.gmatch(slashedPath, "[^/]+") do
		if pathSegment == ".." then
			if #resolvedSegments == 0 then
				return nil, "leaves the project folder"
			end
			table.remove(resolvedSegments)
		elseif pathSegment ~= "." then
			table.insert(resolvedSegments, pathSegment)
		end
	end
	local resolvedPath = table.concat(resolvedSegments, "/")
	if string.match(string.lower(resolvedPath), "%.project%.json$") then
		return nil, "is a nested project file, which this check does not follow"
	end
	return resolvedPath
end

-- True when the resolved mapping contains the resolved target, ignoring letter case.
local function doesResolvedPathCover(resolvedMappedPath: string, resolvedTargetPath: string): boolean
	local loweredMappedPath = string.lower(resolvedMappedPath)
	local loweredTargetPath = string.lower(resolvedTargetPath)
	return loweredMappedPath == ""
		or loweredMappedPath == loweredTargetPath
		or string.sub(loweredTargetPath, 1, #loweredMappedPath + 1) == loweredMappedPath .. "/"
end

local function analyzeProjectTreeNode(projectTreeNode: any, topLevelServiceName: string?, analysis: ProjectTreeAnalysis)
	if type(projectTreeNode) ~= "table" then
		return
	end
	local serviceLabel = topLevelServiceName or PROJECT_ROOT_SERVICE_LABEL
	local mappedProjectPath = projectTreeNode["$path"]
	if mappedProjectPath ~= nil then
		local resolvedMappedPath, unresolvableReason
		if type(mappedProjectPath) == "string" then
			resolvedMappedPath, unresolvableReason = resolveMappedProjectPath(mappedProjectPath)
		else
			unresolvableReason = "is not a string"
		end
		if resolvedMappedPath == nil then
			table.insert(
				analysis.unresolvableMappingLines,
				serviceLabel .. ": $path " .. tostring(mappedProjectPath) .. " " .. tostring(unresolvableReason)
			)
		else
			if doesResolvedPathCover(resolvedMappedPath, PROMO_CODE_CATALOG_PROJECT_RELATIVE_PATH) then
				table.insert(analysis.servicesPlacingPromoCodeCatalog, serviceLabel)
			end
			if topLevelServiceName == nil or not SERVER_ONLY_TOP_LEVEL_SERVICE_NAME_SET[topLevelServiceName] then
				table.insert(analysis.deviceReadableProjectPaths, resolvedMappedPath)
			end
		end
	end
	for childName, childNode in projectTreeNode do
		if string.sub(childName, 1, 1) ~= "$" then
			analyzeProjectTreeNode(childNode, topLevelServiceName or childName, analysis)
		end
	end
end

local function analyzeProjectTree(projectTree: any): ProjectTreeAnalysis
	local analysis: ProjectTreeAnalysis = {
		servicesPlacingPromoCodeCatalog = {},
		deviceReadableProjectPaths = {},
		unresolvableMappingLines = {},
	}
	analyzeProjectTreeNode(projectTree, nil, analysis)
	table.sort(analysis.servicesPlacingPromoCodeCatalog)
	table.sort(analysis.deviceReadableProjectPaths)
	table.sort(analysis.unresolvableMappingLines)
	return analysis
end

local function analyzeShippedProjectFile(): ProjectTreeAnalysis
	local projectFile = serde.decode("json", fs.readFile(PROJECT_ROOT_FOLDER_PATH .. "/default.project.json"))
	return analyzeProjectTree(projectFile.tree)
end

-- Every file (any extension) at or under `scannedPath`, recursively; a missing path holds no files.
local function readEveryFileAtOrUnder(scannedPath: string, scannedSourceFiles: { ScannedSourceFile })
	if fs.isFile(scannedPath) then
		table.insert(scannedSourceFiles, { scannedFilePath = scannedPath, fileSourceText = fs.readFile(scannedPath) })
	elseif fs.isDir(scannedPath) then
		for _, folderEntryName in fs.readDir(scannedPath) do
			readEveryFileAtOrUnder(scannedPath .. "/" .. folderEntryName, scannedSourceFiles)
		end
	end
end

-- One line per exposure found: a file naming the catalog module, or containing a promo code text.
local function findPromoCodeExposuresInSourceFiles(
	scannedSourceFiles: { ScannedSourceFile },
	promoCodes: { PromoCodeCatalog.PromoCode }
): { string }
	local promoCodeExposureLines = {}
	for _, scannedSourceFile in scannedSourceFiles do
		if string.find(scannedSourceFile.fileSourceText, PROMO_CODE_CATALOG_MODULE_NAME, 1, true) then
			table.insert(
				promoCodeExposureLines,
				scannedSourceFile.scannedFilePath .. " names " .. PROMO_CODE_CATALOG_MODULE_NAME
			)
		end
		local loweredFileSourceText = string.lower(scannedSourceFile.fileSourceText)
		for _, promoCode in promoCodes do
			if string.find(loweredFileSourceText, string.lower(promoCode.promoCodeText), 1, true) then
				table.insert(
					promoCodeExposureLines,
					scannedSourceFile.scannedFilePath .. " contains the text of " .. promoCode.promoCodeId
				)
			end
		end
	end
	return promoCodeExposureLines
end

local FIXTURE_PROMO_CODES: { PromoCodeCatalog.PromoCode } = {
	{
		promoCodeId = "fixture_secret_fan_gift",
		promoCodeText = "SecretFanGift",
		starCoinReward = 10,
		validFromUnixSeconds = 1800000000,
		validUntilUnixSeconds = 1800000100,
	},
}

local function createScratchFolderPath(): string
	local temporaryFolderPath = process.env.TMPDIR or process.env.TEMP or (PROJECT_ROOT_FOLDER_PATH .. "/build")
	temporaryFolderPath = string.gsub(temporaryFolderPath, "[/\\]+$", "")
	return string.format(
		"%s/PromoCodeCatalogPlacementScan_%d_%d",
		temporaryFolderPath,
		os.time(),
		math.floor(os.clock() * 1000000)
	)
end

describe("PromoCodeCatalog server-only placement (§1.9)", function()
	it("default.project.json places the catalog file only under ServerScriptService", function()
		local shippedProjectAnalysis = analyzeShippedProjectFile()
		expect(shippedProjectAnalysis.unresolvableMappingLines).toEqual({})
		expect(shippedProjectAnalysis.servicesPlacingPromoCodeCatalog).toEqual({ "ServerScriptService" })
		expect(fs.isFile(PROJECT_ROOT_FOLDER_PATH .. "/" .. PROMO_CODE_CATALOG_PROJECT_RELATIVE_PATH)).toBeTrue()
	end)

	it("every device-readable mapping of default.project.json exists and is scanned clean", function()
		local deviceReadableProjectPaths = analyzeShippedProjectFile().deviceReadableProjectPaths
		expect(#deviceReadableProjectPaths >= 1).toBeTrue()
		local scannedSourceFiles = {}
		for _, deviceReadableProjectPath in deviceReadableProjectPaths do
			local absoluteScannedPath = PROJECT_ROOT_FOLDER_PATH .. "/" .. deviceReadableProjectPath
			expect({ deviceReadableProjectPath, fs.isDir(absoluteScannedPath) or fs.isFile(absoluteScannedPath) }).toEqual({
				deviceReadableProjectPath,
				true,
			})
			readEveryFileAtOrUnder(absoluteScannedPath, scannedSourceFiles)
		end
		-- The project's device-readable folders hold source files, so an empty scan means the scan
		-- itself is broken, not that the project is clean.
		expect(#scannedSourceFiles >= 1).toBeTrue()
		expect(findPromoCodeExposuresInSourceFiles(scannedSourceFiles, PromoCodeCatalog.PROMO_CODES)).toEqual({})
	end)

	it("treats every mapping outside the server-only services as device-readable", function()
		local fixtureProjectAnalysis = analyzeProjectTree({
			ReplicatedStorage = { Shared = { ["$path"] = "src/shared" } },
			ReplicatedFirst = { Loading = { ["$path"] = "./src/loading/" } },
			Workspace = { Stage = { ["$path"] = "assets/stage.rbxm" } },
			StarterPlayer = { StarterPlayerScripts = { Client = { ["$path"] = "src/client" } } },
			ServerScriptService = { Server = { ["$path"] = "src/server" } },
			ServerStorage = { Assets = { ["$path"] = "src/serverAssets" } },
		})
		expect(fixtureProjectAnalysis.deviceReadableProjectPaths).toEqual({
			"assets/stage.rbxm",
			"src/client",
			"src/loading",
			"src/shared",
		})
		expect(fixtureProjectAnalysis.servicesPlacingPromoCodeCatalog).toEqual({ "ServerScriptService" })
		expect(analyzeProjectTree({ ["$path"] = "." }).deviceReadableProjectPaths).toEqual({ "" })
	end)

	it("the placement walk flags every spelling that puts src/server on devices", function()
		for _, catalogCoveringPath in
			{
				"",
				".",
				"./",
				"src",
				"src/",
				"./src/server/",
				"src/shared/..",
				"src/./server",
				"SRC/server",
				"src/server/../server",
				"src\\server",
				PROMO_CODE_CATALOG_PROJECT_RELATIVE_PATH,
			}
		do
			local fixtureProjectAnalysis =
				analyzeProjectTree({ ReplicatedStorage = { Everything = { ["$path"] = catalogCoveringPath } } })
			expect({ catalogCoveringPath, fixtureProjectAnalysis.servicesPlacingPromoCodeCatalog }).toEqual({
				catalogCoveringPath,
				{ "ReplicatedStorage" },
			})
		end
		for _, unrelatedPath in { "src/serverless", "src/shared", "src/server/../shared", "src/server/Other.luau" } do
			local fixtureProjectAnalysis =
				analyzeProjectTree({ ReplicatedStorage = { Other = { ["$path"] = unrelatedPath } } })
			expect({ unrelatedPath, fixtureProjectAnalysis.servicesPlacingPromoCodeCatalog }).toEqual({
				unrelatedPath,
				{},
			})
		end
		expect(analyzeProjectTree({ ["$path"] = "." }).servicesPlacingPromoCodeCatalog).toEqual({
			PROJECT_ROOT_SERVICE_LABEL,
		})
	end)

	it("reports every $path it cannot resolve instead of ignoring it", function()
		expect(analyzeProjectTree({
			ReplicatedStorage = {
				Absolute = { ["$path"] = "/Users/someone/src/server" },
				DriveLetter = { ["$path"] = "C:\\project\\src\\server" },
				Outside = { ["$path"] = "src/../../elsewhere" },
				Nested = { ["$path"] = "packages/Server.project.json" },
				NotText = { ["$path"] = 7 },
			},
		}).unresolvableMappingLines).toEqual({
			"ReplicatedStorage: $path /Users/someone/src/server is absolute",
			"ReplicatedStorage: $path 7 is not a string",
			"ReplicatedStorage: $path C:\\project\\src\\server is absolute",
			"ReplicatedStorage: $path packages/Server.project.json is a nested project file, which this check does not follow",
			"ReplicatedStorage: $path src/../../elsewhere leaves the project folder",
		})
	end)

	it("the scan reads nested folders, any extension, and single mapped files", function()
		local scratchFolderPath = createScratchFolderPath()
		fs.writeDir(scratchFolderPath .. "/client/nested")
		fs.writeFile(scratchFolderPath .. "/client/Clean.luau", 'local x = require("./ThemeCatalog")')
		fs.writeFile(scratchFolderPath .. "/client/nested/Hints.txt", "type SECRETfanGIFT!")
		fs.writeFile(scratchFolderPath .. "/client/nested/Loader.luau", 'require("../server/PromoCodeCatalog")')
		fs.writeFile(scratchFolderPath .. "/Single.json", '{"hint": "secretfangift"}')
		local scannedSourceFiles = {}
		local didScan, scanError = pcall(function()
			readEveryFileAtOrUnder(scratchFolderPath .. "/client", scannedSourceFiles)
			readEveryFileAtOrUnder(scratchFolderPath .. "/Single.json", scannedSourceFiles)
			readEveryFileAtOrUnder(scratchFolderPath .. "/missing", scannedSourceFiles)
		end)
		fs.removeDir(scratchFolderPath)
		assert(didScan, scanError)
		local exposureLines = findPromoCodeExposuresInSourceFiles(scannedSourceFiles, FIXTURE_PROMO_CODES)
		table.sort(exposureLines)
		local scratchPrefixLength = #scratchFolderPath + 1
		for exposurePosition, exposureLine in exposureLines do
			exposureLines[exposurePosition] = string.sub(exposureLine, scratchPrefixLength + 1)
		end
		expect(#scannedSourceFiles).toBe(4)
		expect(exposureLines).toEqual({
			"Single.json contains the text of fixture_secret_fan_gift",
			"client/nested/Hints.txt contains the text of fixture_secret_fan_gift",
			"client/nested/Loader.luau names PromoCodeCatalog",
		})
	end)
end)
