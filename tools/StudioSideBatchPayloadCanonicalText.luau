-- StudioSideBatchPayloadCanonicalText: one fixed text for a Studio project sync batch payload, so
-- Lune (the renderer) and Studio (the runtime) can compare the SHA-256 of what was sent with what
-- arrived. Moved unchanged out of tools/StudioSideProjectSyncRuntime.luau (500-line cap), which
-- still offers it as StudioSideProjectSyncRuntime.describeBatchPayloadCanonically. It is a runtime
-- PART: it requires nothing, because tools/StudioSyncRuntimeBundler.luau pastes it into batch 00.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- StudioSideBatchPayloadCanonicalText.describeBatchPayloadCanonically(batchPayload) -> string
--   One fixed text for a payload (strings, whole numbers, booleans and tables of them; keys sorted;
--   strings length-prefixed, so two different payloads never give the same text). Raises on any
--   other value and on a number that is not whole.

local StudioSideBatchPayloadCanonicalText = {}

local function describeValueCanonically(value: any, describedParts: { string })
	local valueType = type(value)
	if valueType == "string" then
		table.insert(describedParts, "s" .. #value .. ":" .. value)
	elseif valueType == "boolean" then
		table.insert(describedParts, if value then "T" else "F")
	elseif valueType == "number" then
		if value % 1 ~= 0 or value ~= value or math.abs(value) == math.huge then
			error("StudioSideProjectSyncRuntime: a batch payload number is not whole: " .. tostring(value))
		end
		table.insert(describedParts, string.format("n%d;", value))
	elseif valueType == "table" then
		local tableKeys = {}
		for tableKey in value do
			if type(tableKey) ~= "string" and type(tableKey) ~= "number" then
				error("StudioSideProjectSyncRuntime: a batch payload key is not a string or number")
			end
			table.insert(tableKeys, tableKey)
		end
		table.sort(tableKeys, function(firstKey, secondKey)
			if type(firstKey) ~= type(secondKey) then
				return type(firstKey) == "number"
			end
			return firstKey < secondKey
		end)
		table.insert(describedParts, "{")
		for _, tableKey in tableKeys do
			describeValueCanonically(tableKey, describedParts)
			describeValueCanonically(value[tableKey], describedParts)
		end
		table.insert(describedParts, "}")
	else
		error("StudioSideProjectSyncRuntime: a batch payload holds a " .. valueType)
	end
end

function StudioSideBatchPayloadCanonicalText.describeBatchPayloadCanonically(batchPayload: any): string
	local describedParts = {}
	describeValueCanonically(batchPayload, describedParts)
	return table.concat(describedParts)
end

return StudioSideBatchPayloadCanonicalText
