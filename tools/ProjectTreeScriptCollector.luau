-- ProjectTreeScriptCollector: reads the Rojo project tree (default.project.json, already decoded)
-- and the source folders it points at, and lists what the Studio project sync must create: the
-- mapped folders, every folder below them, and every script with its source. File access is
-- injected, so tests pass an in-memory folder tree.
--
-- It accepts only the subset of the Rojo project format this project uses, and raises on
-- anything else instead of silently leaving something out of Studio:
--   * the root node has "$className": "DataModel"; its children are services;
--   * below a service, a node is either a "$path" to a DIRECTORY (mapped as a Folder of that
--     node's name, the way `rojo build` maps it) or has child nodes that already exist in a
--     fresh place (for example StarterPlayer.StarterPlayerScripts); no other "$" key is allowed
--     below the root, and a service itself cannot have a "$path";
--   * inside a mapped directory: a sub-directory is a Folder; `Name.server.luau` a Script,
--     `Name.client.luau` a LocalScript, `Name.luau` a ModuleScript (README "Development");
--     names starting with "." are ignored (macOS .DS_Store); `init` files, any other file and two
--     entries mapping to the same instance name are errors.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- ProjectTreeScriptCollector.collectProjectScripts(projectTree, projectFileReader) -> collectedProject
--   projectFileReader = {
--     isDirectory: (pathFromProjectRoot) -> boolean,
--     listDirectoryEntryNames: (pathFromProjectRoot) -> { string },
--     readTextFile: (pathFromProjectRoot) -> string,
--   }
--   collectedProject = {
--     mappedFolders = { { existingParentPathNames, mappedFolderName, sourceDirectoryPath } },
--     projectFolders = { { mappedFolderNumber, relativePathNames } },  every sub-directory
--     projectScripts = { { mappedFolderNumber, relativePathNames, className, sourceText,
--                          sourceFilePath } },
--   }
--   Mapped folders in tree order (children sorted by name); folders and scripts in directory order
--   (each directory's entries sorted by name, a sub-folder's contents right after the sub-folder).
--   Raises with a message naming the offending node or file.
-- ProjectTreeScriptCollector.mapSourceFileNameToScript(fileName) -> (instanceName?, className?)
--   nil when the file is not a script file (see the rules above); raises for an `init` file.

local ProjectTreeScriptCollector = {}

local SCRIPT_FILE_SUFFIX_CLASS_NAMES = {
	{ fileNameSuffix = ".server.luau", className = "Script" },
	{ fileNameSuffix = ".client.luau", className = "LocalScript" },
	{ fileNameSuffix = ".luau", className = "ModuleScript" },
}

function ProjectTreeScriptCollector.mapSourceFileNameToScript(fileName: string): (string?, string?)
	for _, suffixClassName in SCRIPT_FILE_SUFFIX_CLASS_NAMES do
		local suffixLength = #suffixClassName.fileNameSuffix
		if #fileName > suffixLength and string.sub(fileName, -suffixLength) == suffixClassName.fileNameSuffix then
			local instanceName = string.sub(fileName, 1, -suffixLength - 1)
			if instanceName == "init" then
				error("ProjectTreeScriptCollector: init files are not used in this project: " .. fileName)
			end
			return instanceName, suffixClassName.className
		end
	end
	return nil, nil
end

local function listChildNodeNames(projectNode): { string }
	local childNodeNames = {}
	for nodeKey in projectNode do
		if string.sub(nodeKey, 1, 1) ~= "$" then
			table.insert(childNodeNames, nodeKey)
		end
	end
	table.sort(childNodeNames)
	return childNodeNames
end

local function checkOnlyAllowedSpecialKeys(projectNode, nodeDescription: string)
	for nodeKey in projectNode do
		if string.sub(nodeKey, 1, 1) == "$" and nodeKey ~= "$path" then
			error(
				string.format(
					"ProjectTreeScriptCollector: %s uses %s, which the Studio sync does not support",
					nodeDescription,
					nodeKey
				)
			)
		end
	end
end

local function collectDirectoryContents(
	projectFileReader,
	directoryPath: string,
	mappedFolderNumber: number,
	parentPathNames: { string },
	collectedProject
)
	local entryNames = projectFileReader.listDirectoryEntryNames(directoryPath)
	table.sort(entryNames)
	local entryPathByInstanceName = {}
	for _, entryName in entryNames do
		if string.sub(entryName, 1, 1) ~= "." then
			local entryPath = directoryPath .. "/" .. entryName
			local isDirectory = projectFileReader.isDirectory(entryPath)
			local instanceName, className = entryName, "Folder"
			if not isDirectory then
				instanceName, className = ProjectTreeScriptCollector.mapSourceFileNameToScript(entryName)
				if instanceName == nil then
					error(
						"ProjectTreeScriptCollector: not a .luau script file, the Studio sync cannot map it: "
							.. entryPath
					)
				end
			end
			if entryPathByInstanceName[instanceName] ~= nil then
				error(
					string.format(
						"ProjectTreeScriptCollector: %s and %s map to the same instance name %s",
						entryPathByInstanceName[instanceName],
						entryPath,
						tostring(instanceName)
					)
				)
			end
			entryPathByInstanceName[instanceName] = entryPath
			local relativePathNames = table.clone(parentPathNames)
			table.insert(relativePathNames, instanceName :: string)
			if isDirectory then
				table.insert(collectedProject.projectFolders, {
					mappedFolderNumber = mappedFolderNumber,
					relativePathNames = relativePathNames,
				})
				collectDirectoryContents(
					projectFileReader,
					entryPath,
					mappedFolderNumber,
					relativePathNames,
					collectedProject
				)
			else
				table.insert(collectedProject.projectScripts, {
					mappedFolderNumber = mappedFolderNumber,
					relativePathNames = relativePathNames,
					className = className,
					sourceText = projectFileReader.readTextFile(entryPath),
					sourceFilePath = entryPath,
				})
			end
		end
	end
end

local function collectProjectNode(projectFileReader, projectNode, nodePathNames: { string }, collectedProject)
	local nodeDescription = "project node " .. table.concat(nodePathNames, ".")
	if type(projectNode) ~= "table" then
		error("ProjectTreeScriptCollector: " .. nodeDescription .. " is not an object")
	end
	checkOnlyAllowedSpecialKeys(projectNode, nodeDescription)
	local childNodeNames = listChildNodeNames(projectNode)
	local sourceDirectoryPath = projectNode["$path"]
	if sourceDirectoryPath == nil then
		if #childNodeNames == 0 then
			error("ProjectTreeScriptCollector: " .. nodeDescription .. " has neither $path nor child nodes")
		end
		for _, childNodeName in childNodeNames do
			local childPathNames = table.clone(nodePathNames)
			table.insert(childPathNames, childNodeName)
			collectProjectNode(projectFileReader, projectNode[childNodeName], childPathNames, collectedProject)
		end
		return
	end
	if #nodePathNames < 2 then
		error("ProjectTreeScriptCollector: " .. nodeDescription .. " is a service; a service cannot have a $path here")
	end
	if #childNodeNames > 0 then
		error("ProjectTreeScriptCollector: " .. nodeDescription .. " has both $path and child nodes")
	end
	if type(sourceDirectoryPath) ~= "string" or not projectFileReader.isDirectory(sourceDirectoryPath) then
		error(
			"ProjectTreeScriptCollector: $path of "
				.. nodeDescription
				.. " is not a directory: "
				.. tostring(sourceDirectoryPath)
		)
	end
	local existingParentPathNames = table.clone(nodePathNames)
	local mappedFolderName = table.remove(existingParentPathNames) :: string
	table.insert(collectedProject.mappedFolders, {
		existingParentPathNames = existingParentPathNames,
		mappedFolderName = mappedFolderName,
		sourceDirectoryPath = sourceDirectoryPath,
	})
	collectDirectoryContents(
		projectFileReader,
		sourceDirectoryPath,
		#collectedProject.mappedFolders,
		{},
		collectedProject
	)
end

function ProjectTreeScriptCollector.collectProjectScripts(projectTree, projectFileReader)
	if type(projectTree) ~= "table" or type(projectTree.tree) ~= "table" then
		error("ProjectTreeScriptCollector: the project has no tree")
	end
	local rootNode = projectTree.tree
	if rootNode["$className"] ~= "DataModel" or rootNode["$path"] ~= nil then
		error('ProjectTreeScriptCollector: the tree root must be { "$className": "DataModel" } without $path')
	end
	local collectedProject = { mappedFolders = {}, projectFolders = {}, projectScripts = {} }
	for _, serviceName in listChildNodeNames(rootNode) do
		collectProjectNode(projectFileReader, rootNode[serviceName], { serviceName }, collectedProject)
	end
	return collectedProject
end

return table.freeze(ProjectTreeScriptCollector)
