-- ProjectRequireResolver: resolves every string require of the collected project the way Roblox
-- resolves it inside the place that default.project.json describes, so the Studio project sync
-- can (1) warn about requires that work under Lune (relative to the file) but NOT in Roblox
-- (relative to the instance tree), and (2) load only some scripts plus everything they require.
--
-- Roblox's rules, read on https://create.roblox.com/docs/reference/engine/globals/LuaGlobals
-- (require): "./" starts at script.Parent, "../" at script.Parent.Parent, "@self/" at script,
-- "@game/" at game; each further component is a child, ".." the parent. Verified in Studio 0.748
-- on 2026-11-19: from ServerScriptService.X.B, require("../Y/A") fails with 'could not resolve
-- child component "Y"' when Y is a folder in ReplicatedStorage.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- ProjectRequireResolver.listRequirePathsInSource(sourceText) -> { string }
--   Every require("...") / require('...') string argument on a line that is not a comment, line
--   by line (within one line, the double-quoted ones first).
-- ProjectRequireResolver.resolveRequirePath(requiringScriptPathNames, requirePath) -> { string }?
--   The instance path (names from the service down) that `requirePath` points at when required
--   from the script at `requiringScriptPathNames`; nil when the path leaves the DataModel or has
--   an unsupported prefix.
-- ProjectRequireResolver.describeProjectRequires(collectedProject) -> { scriptRequires, unresolvableRequires }
--   scriptRequires[scriptNumber] = { scriptNumber of each required project ModuleScript }
--   unresolvableRequires = { { requiringScriptFullName, requirePath } }: requires that point at no
--   ModuleScript of the project inside Roblox (they will fail there at run time).
-- ProjectRequireResolver.buildScriptFullPathNames(collectedProject, projectScript) -> { string }
-- ProjectRequireResolver.selectScriptsAndTheirRequires(collectedProject, selectedScriptNames)
--     -> { [scriptNumber]: true }
--   The scripts whose instance name is in `selectedScriptNames`, plus everything they require
--   (transitively, through requires that resolve in Roblox). Raises for a name that matches no script.

local ProjectRequireResolver = {}

function ProjectRequireResolver.listRequirePathsInSource(sourceText: string): { string }
	local requirePaths = {}
	for sourceLine in string.gmatch(sourceText, "[^\n]+") do
		if not string.match(sourceLine, "^%s*%-%-") then
			for _, requirePattern in { 'require%(%s*"([^"]+)"%s*%)', "require%(%s*'([^']+)'%s*%)" } do
				for requirePath in string.gmatch(sourceLine, requirePattern) do
					table.insert(requirePaths, requirePath)
				end
			end
		end
	end
	return requirePaths
end

function ProjectRequireResolver.resolveRequirePath(
	requiringScriptPathNames: { string },
	requirePath: string
): { string }?
	local resolvedPathNames = table.clone(requiringScriptPathNames)
	local remainingPath: string
	if string.sub(requirePath, 1, 2) == "./" then
		table.remove(resolvedPathNames)
		remainingPath = string.sub(requirePath, 3)
	elseif string.sub(requirePath, 1, 3) == "../" then
		table.remove(resolvedPathNames)
		table.remove(resolvedPathNames)
		remainingPath = string.sub(requirePath, 4)
	elseif string.sub(requirePath, 1, 6) == "@self/" then
		remainingPath = string.sub(requirePath, 7)
	elseif string.sub(requirePath, 1, 6) == "@game/" then
		resolvedPathNames = {}
		remainingPath = string.sub(requirePath, 7)
	else
		return nil
	end
	for pathComponent in string.gmatch(remainingPath, "[^/]+") do
		if pathComponent == ".." then
			if #resolvedPathNames == 0 then
				return nil
			end
			table.remove(resolvedPathNames)
		else
			table.insert(resolvedPathNames, pathComponent)
		end
	end
	return resolvedPathNames
end

function ProjectRequireResolver.buildScriptFullPathNames(collectedProject, projectScript): { string }
	local mappedFolder = collectedProject.mappedFolders[projectScript.mappedFolderNumber]
	local fullPathNames = table.clone(mappedFolder.existingParentPathNames)
	table.insert(fullPathNames, mappedFolder.mappedFolderName)
	for _, relativePathName in projectScript.relativePathNames do
		table.insert(fullPathNames, relativePathName)
	end
	return fullPathNames
end

function ProjectRequireResolver.describeProjectRequires(collectedProject)
	local moduleScriptNumberByFullName = {}
	for scriptNumber, projectScript in collectedProject.projectScripts do
		if projectScript.className == "ModuleScript" then
			local fullName =
				table.concat(ProjectRequireResolver.buildScriptFullPathNames(collectedProject, projectScript), ".")
			moduleScriptNumberByFullName[fullName] = scriptNumber
		end
	end
	local scriptRequires, unresolvableRequires = {}, {}
	for scriptNumber, projectScript in collectedProject.projectScripts do
		local requiringScriptPathNames =
			ProjectRequireResolver.buildScriptFullPathNames(collectedProject, projectScript)
		scriptRequires[scriptNumber] = {}
		for _, requirePath in ProjectRequireResolver.listRequirePathsInSource(projectScript.sourceText) do
			local resolvedPathNames = ProjectRequireResolver.resolveRequirePath(requiringScriptPathNames, requirePath)
			local requiredScriptNumber = if resolvedPathNames
				then moduleScriptNumberByFullName[table.concat(resolvedPathNames, ".")]
				else nil
			if requiredScriptNumber then
				table.insert(scriptRequires[scriptNumber], requiredScriptNumber)
			else
				table.insert(unresolvableRequires, {
					requiringScriptFullName = table.concat(requiringScriptPathNames, "."),
					requirePath = requirePath,
				})
			end
		end
	end
	return { scriptRequires = scriptRequires, unresolvableRequires = unresolvableRequires }
end

function ProjectRequireResolver.selectScriptsAndTheirRequires(collectedProject, selectedScriptNames: { string })
	local projectRequires = ProjectRequireResolver.describeProjectRequires(collectedProject)
	local isScriptSelected = {}
	local scriptNumbersToVisit = {}
	for _, selectedScriptName in selectedScriptNames do
		local didMatch = false
		for scriptNumber, projectScript in collectedProject.projectScripts do
			if projectScript.relativePathNames[#projectScript.relativePathNames] == selectedScriptName then
				didMatch = true
				table.insert(scriptNumbersToVisit, scriptNumber)
			end
		end
		if not didMatch then
			error("ProjectRequireResolver: no project script is named " .. selectedScriptName)
		end
	end
	while #scriptNumbersToVisit > 0 do
		local scriptNumber = table.remove(scriptNumbersToVisit) :: number
		if not isScriptSelected[scriptNumber] then
			isScriptSelected[scriptNumber] = true
			for _, requiredScriptNumber in projectRequires.scriptRequires[scriptNumber] do
				table.insert(scriptNumbersToVisit, requiredScriptNumber)
			end
		end
	end
	return isScriptSelected
end

return table.freeze(ProjectRequireResolver)
