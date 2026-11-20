-- StudioSideRetiredProjectFolderRemover: removes, inside Roblox Studio, the folders that an EARLIER
-- default.project.json mapped and the current one no longer maps (for example ReplicatedStorage.Shared,
-- which held src/shared until the shared modules moved next to each side as "shared"). Without it
-- the old copy would stay in the place, because the sync only manages the folders mapped today.
-- Called by the remove-and-verify batch (tools/StudioSideProjectSyncRuntime.luau). It is a runtime
-- PART: it requires nothing, because tools/StudioSyncRuntimeBundler.luau pastes it into batch 00.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- StudioSideRetiredProjectFolderRemover.checkRetiredFoldersAreNotMapped(retiredFolders, mappedFolders)
--   Raises when a retired folder has the same parents and name as a mapped folder (a project error:
--   the sync would remove what it must keep). Touches nothing.
-- StudioSideRetiredProjectFolderRemover.removeRetiredProjectFolders(studioAccess, retiredFolders, reportLines)
--     -> problemCount
--   A retired folder is { existingParentPathNames, mappedFolderName }, like a mapped folder. Every
--   child of that parent with that name that is a Folder is destroyed with everything inside it and
--   listed as "removed retired project folder <full name> (Folder, N scripts inside)". A child of
--   another class is left in place and listed as "MISMATCH retired project folder <full name> is a
--   <ClassName>, not a Folder: left in place" (one problem each; the caller then reports the sync
--   incomplete). A parent that does not exist means there is nothing to remove.
--
-- Roblox API used (https://create.roblox.com/docs/reference/engine/...): ServiceProvider:GetService
-- (classes/ServiceProvider); Instance Name, ClassName, GetChildren, GetDescendants, GetFullName,
-- Destroy (classes/Instance).

local StudioSideRetiredProjectFolderRemover = {}

local SCRIPT_CLASS_NAMES = { ModuleScript = true, Script = true, LocalScript = true }

local function describeFolderPlace(folderDescription): string
	return table.concat(folderDescription.existingParentPathNames, ".") .. "." .. folderDescription.mappedFolderName
end

function StudioSideRetiredProjectFolderRemover.checkRetiredFoldersAreNotMapped(retiredFolders, mappedFolders)
	local isMappedPlace = {}
	for _, mappedFolder in mappedFolders do
		isMappedPlace[describeFolderPlace(mappedFolder)] = true
	end
	for _, retiredFolder in retiredFolders do
		if isMappedPlace[describeFolderPlace(retiredFolder)] then
			error(
				"StudioSideRetiredProjectFolderRemover: "
					.. describeFolderPlace(retiredFolder)
					.. " is both mapped and retired; nothing was changed"
			)
		end
	end
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

local function countScriptsInside(folderInstance: any): number
	local scriptCount = 0
	for _, descendant in folderInstance:GetDescendants() do
		if SCRIPT_CLASS_NAMES[descendant.ClassName] then
			scriptCount += 1
		end
	end
	return scriptCount
end

function StudioSideRetiredProjectFolderRemover.removeRetiredProjectFolders(studioAccess, retiredFolders, reportLines)
	local problemCount = 0
	for _, retiredFolder in retiredFolders do
		local parentInstances = { studioAccess.dataModel:GetService(retiredFolder.existingParentPathNames[1]) }
		for namePosition = 2, #retiredFolder.existingParentPathNames do
			local childInstances = {}
			for _, parentInstance in parentInstances do
				for _, childInstance in
					findChildrenNamed(parentInstance, retiredFolder.existingParentPathNames[namePosition])
				do
					table.insert(childInstances, childInstance)
				end
			end
			parentInstances = childInstances
		end
		for _, parentInstance in parentInstances do
			for _, retiredInstance in findChildrenNamed(parentInstance, retiredFolder.mappedFolderName) do
				if retiredInstance.ClassName == "Folder" then
					table.insert(
						reportLines,
						string.format(
							"removed retired project folder %s (Folder, %d scripts inside)",
							retiredInstance:GetFullName(),
							countScriptsInside(retiredInstance)
						)
					)
					retiredInstance:Destroy()
				else
					problemCount += 1
					table.insert(
						reportLines,
						string.format(
							"MISMATCH retired project folder %s is a %s, not a Folder: left in place",
							retiredInstance:GetFullName(),
							retiredInstance.ClassName
						)
					)
				end
			end
		end
	end
	return problemCount
end

return StudioSideRetiredProjectFolderRemover
