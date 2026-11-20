-- StudioSourceCommentLineBlanker: makes the copy of a script that the Studio project sync sends
-- to Studio, with every line that holds only a comment replaced by an empty line.
--
-- Why: the sync has to pass every byte of source through the `execute_luau` tool call, and about
-- a third of this project's source is comment-only lines (the public-API headers). Blanking them
-- keeps every line number identical, so an error line in Studio's output points at the same line
-- in the file, and code lines (with their trailing comments) are sent unchanged.
--
-- A file is sent VERBATIM (nothing blanked) when it contains anything that could make a line that
-- starts with "--" part of a string or of a block comment: a long bracket ("[[" or "[=[", which
-- also opens "--[[" block comments), a line ending in a backslash (a quoted string continued on
-- the next line) or the escape "\z" anywhere (it skips the line break and the whitespace after it,
-- so a quoted string can go on across lines). A comment-only line that starts with "--!" (a
-- directive such as --!strict, --!native, --!optimize 2) is never blanked, because it changes how
-- Studio compiles or checks the script. Every other comment-only line can only be a comment, so
-- blanking it cannot change what the code does (tests/tools/StudioSourceCommentLineBlanker.spec.luau
-- also compiles every project script before and after blanking and compares the bytecode).
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- StudioSourceCommentLineBlanker.blankCommentOnlyLines(sourceText) -> (studioSourceText, wasSentVerbatim)
--   Same number of lines and the same line endings; a comment-only line (optional leading spaces
--   or tabs, then "--", but not "--!") becomes empty. Every other line is unchanged.
--   wasSentVerbatim is true (and the text unchanged) for a file with a long bracket, a
--   backslash-continued line or "\z".

local StudioSourceCommentLineBlanker = {}

local function containsLongBracketOrContinuedString(sourceText: string): boolean
	return string.find(sourceText, "%[=*%[") ~= nil
		or string.find(sourceText, "\\\r?\n") ~= nil
		or string.find(sourceText, "\\z") ~= nil
end

function StudioSourceCommentLineBlanker.blankCommentOnlyLines(sourceText: string): (string, boolean)
	if containsLongBracketOrContinuedString(sourceText) then
		return sourceText, true
	end
	-- "[^\n]*" stops before each "\n", so a CR of a CR LF ending stays on its line: a blanked CR LF
	-- line keeps its CR, which keeps the line endings as they were.
	local studioSourceText = string.gsub(sourceText, "[^\n]*", function(sourceLine: string)
		if string.match(sourceLine, "^[ \t]*%-%-") and not string.match(sourceLine, "^[ \t]*%-%-!") then
			return if string.sub(sourceLine, -1) == "\r" then "\r" else ""
		end
		return sourceLine
	end)
	return studioSourceText, false
end

return table.freeze(StudioSourceCommentLineBlanker)
