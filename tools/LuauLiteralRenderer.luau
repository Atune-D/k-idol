-- LuauLiteralRenderer: writes plain values as Luau source text, for the Studio project sync batches
-- (tools/StudioProjectSyncBatchRenderer.luau). Moved out of that file unchanged, so the renderer
-- stays under the 500-line cap; StudioProjectSyncBatchRenderer.renderLuauLiteral is this function.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- LuauLiteralRenderer.renderLuauLiteral(value) -> string
--   Luau literal for strings, whole numbers, booleans and tables of them (arrays and identifier
--   keys, keys sorted). A multi-line string with no control byte but newline and tab is written as
--   a long string (its leading newlines as string.rep); any other string is quoted with every
--   control byte, quote and backslash escaped as \ddd. Raises for anything else.

local LuauLiteralRenderer = {}

local function isLuauIdentifier(candidateKey: any): boolean
	return type(candidateKey) == "string" and string.match(candidateKey, "^[%a_][%w_]*$") ~= nil
end

-- A multi-line text without carriage returns becomes a long string, so source arrives readable
-- and one line per line; the level is the smallest whose closing bracket cannot occur early.
-- Anything else (a one-line text, or one with a carriage return, which a long string might not
-- keep exactly) becomes a quoted string.
-- string.format("%q") is not used: it leaves a carriage return raw, which ends a quoted string
-- in Luau ("Malformed string"). Every control byte, quote and backslash is escaped instead.
local function renderQuotedLuauStringLiteral(text: string): string
	return '"'
		.. string.gsub(text, '[%c"\\\127]', function(escapedCharacter)
			return string.format("\\%03d", string.byte(escapedCharacter))
		end)
		.. '"'
end

-- Control bytes other than newline and tab: a long string cannot hold "\0" (Luau rejects it) and
-- might not keep a carriage return exactly.
local CONTROL_BYTE_OTHER_THAN_NEWLINE_OR_TAB_PATTERN = "[\0-\8\11-\31\127]"

local function renderLuauStringLiteral(text: string): string
	local isPlainMultiLineText = string.find(text, "\n", 1, true) ~= nil
		and string.find(text, CONTROL_BYTE_OTHER_THAN_NEWLINE_OR_TAB_PATTERN) == nil
	if not isPlainMultiLineText then
		return renderQuotedLuauStringLiteral(text)
	end
	local equalsSigns = ""
	while
		string.find(text, "]" .. equalsSigns .. "]", 1, true) ~= nil
		or string.sub(text, -(#equalsSigns + 1)) == "]" .. equalsSigns
	do
		equalsSigns ..= "="
	end
	-- A run of leading newlines (a blanked header comment) is written as string.rep, so the batch
	-- holds no long run of empty lines to copy by count.
	local leadingNewlines = string.match(text, "^\n+") or ""
	local leadingNewlinesExpression = if #leadingNewlines >= 2
		then string.format('string.rep("\\n", %d) .. ', #leadingNewlines)
		else ""
	local textAfterLeadingNewlines = if #leadingNewlines >= 2 then string.sub(text, #leadingNewlines + 1) else text
	-- The newline right after the opening bracket is not part of the string (Luau skips it).
	return leadingNewlinesExpression
		.. "["
		.. equalsSigns
		.. "[\n"
		.. textAfterLeadingNewlines
		.. "]"
		.. equalsSigns
		.. "]"
end

function LuauLiteralRenderer.renderLuauLiteral(value: any): string
	local valueType = type(value)
	if valueType == "string" then
		return renderLuauStringLiteral(value)
	elseif valueType == "boolean" then
		return tostring(value)
	elseif valueType == "number" then
		if value % 1 ~= 0 or value ~= value or math.abs(value) == math.huge then
			error("LuauLiteralRenderer: only whole numbers are rendered, got " .. tostring(value))
		end
		return string.format("%d", value)
	elseif valueType ~= "table" then
		error("LuauLiteralRenderer: cannot render a " .. valueType)
	end
	local renderedFields = {}
	for _, arrayElement in ipairs(value) do
		table.insert(renderedFields, LuauLiteralRenderer.renderLuauLiteral(arrayElement))
	end
	local recordKeys = {}
	for fieldKey in value do
		if not (type(fieldKey) == "number" and fieldKey >= 1 and fieldKey <= #value and fieldKey % 1 == 0) then
			if not isLuauIdentifier(fieldKey) then
				error("LuauLiteralRenderer: cannot render the table key " .. tostring(fieldKey))
			end
			table.insert(recordKeys, fieldKey)
		end
	end
	table.sort(recordKeys)
	for _, recordKey in recordKeys do
		table.insert(renderedFields, recordKey .. "=" .. LuauLiteralRenderer.renderLuauLiteral(value[recordKey]))
	end
	return "{" .. table.concat(renderedFields, ",") .. "}"
end

return table.freeze(LuauLiteralRenderer)
