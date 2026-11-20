-- Turns a raised error into text short enough to log. A raised error may carry text of any
-- length (for example a sender or a callback that fails with a huge message); a log line must
-- stay bounded.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- LoggedErrorTextShortener.MAXIMUM_LOGGED_ERROR_TEXT_LENGTH = 300
-- LoggedErrorTextShortener.CUT_MARKER = "...(cut)"
--
-- LoggedErrorTextShortener.shortenErrorTextForLog(raisedError: any) -> string
--   tostring(raisedError) when it is at most MAXIMUM_LOGGED_ERROR_TEXT_LENGTH characters long;
--   otherwise its first MAXIMUM_LOGGED_ERROR_TEXT_LENGTH characters followed by CUT_MARKER.
--   Never raises for an error value whose tostring works (every plain Luau value).
-- ════════════════════════════════════════════════════════════════════════════════════════════

local LoggedErrorTextShortener = {}

LoggedErrorTextShortener.MAXIMUM_LOGGED_ERROR_TEXT_LENGTH = 300
LoggedErrorTextShortener.CUT_MARKER = "...(cut)"

function LoggedErrorTextShortener.shortenErrorTextForLog(raisedError: any): string
	local errorText = tostring(raisedError)
	local maximumLength = LoggedErrorTextShortener.MAXIMUM_LOGGED_ERROR_TEXT_LENGTH
	if #errorText <= maximumLength then
		return errorText
	end
	return string.sub(errorText, 1, maximumLength) .. LoggedErrorTextShortener.CUT_MARKER
end

return table.freeze(LoggedErrorTextShortener)
