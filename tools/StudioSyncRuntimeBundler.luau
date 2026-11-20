-- StudioSyncRuntimeBundler: makes the ONE text that batch 00 of the Studio project sync carries
-- into Studio, from tools/StudioSideProjectSyncRuntime.luau and the runtime parts it requires.
-- Studio cannot require these files (they are not in the place), so every line of the runtime of
-- the exact form
--     local PartName = require("./PartName")
-- is replaced by the part's own text wrapped as `local PartName = (function() ... end)()`. Lune
-- requires the same files normally, so the tests run the very code that Studio receives.
-- Lune only in the sense that it reads files through the injected reader; it requires nothing.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- StudioSyncRuntimeBundler.bundleRuntimeSourceText(runtimeSourceText, readRuntimePartSourceText) -> string
--   readRuntimePartSourceText(partName) -> the source of tools/<partName>.luau.
--   Raises when the runtime has any other require, or a part has any require at all (a part must
--   be self-contained), naming the line.

local StudioSyncRuntimeBundler = {}

local PART_REQUIRE_LINE_PATTERN = '^local ([%a_][%w_]*) = require%("%./([%a_][%w_]*)"%)%s*$'

local function containsRequireCall(sourceLine: string): boolean
	return string.find(sourceLine, "require%s*%(") ~= nil and not string.match(sourceLine, "^%s*%-%-")
end

function StudioSyncRuntimeBundler.bundleRuntimeSourceText(
	runtimeSourceText: string,
	readRuntimePartSourceText: (string) -> string
): string
	local bundledLines = {}
	for sourceLine in string.gmatch(runtimeSourceText .. "\n", "([^\n]*)\n") do
		local localName, partName = string.match(sourceLine, PART_REQUIRE_LINE_PATTERN)
		if localName ~= nil and localName == partName then
			local partSourceText = readRuntimePartSourceText(partName :: string)
			for partLine in string.gmatch(partSourceText, "[^\n]+") do
				if containsRequireCall(partLine) then
					error("StudioSyncRuntimeBundler: runtime part " .. partName .. " must not require: " .. partLine)
				end
			end
			table.insert(bundledLines, "local " .. localName .. " = (function()")
			table.insert(bundledLines, partSourceText)
			table.insert(bundledLines, "end)()")
		elseif containsRequireCall(sourceLine) then
			error(
				'StudioSyncRuntimeBundler: the runtime may only require its parts as local X = require("./X"): '
					.. sourceLine
			)
		else
			table.insert(bundledLines, sourceLine)
		end
	end
	return table.concat(bundledLines, "\n")
end

return table.freeze(StudioSyncRuntimeBundler)
