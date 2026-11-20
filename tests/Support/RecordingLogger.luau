-- A logger test double for the `logger` dependency ({ logInformation, logWarning }) that keeps
-- every message, in order, so a test can assert what was logged.
--
--   RecordingLogger.new() -> recordingLogger
--   recordingLogger:logInformation(message)   appends to recordingLogger.loggedInformation
--   recordingLogger:logWarning(message)       appends to recordingLogger.loggedWarnings
--   recordingLogger:countWarningsContaining(searchedText) -> number   plain-text search

local RecordingLogger = {}
RecordingLogger.__index = RecordingLogger

function RecordingLogger.new()
	return setmetatable({ loggedInformation = {} :: { string }, loggedWarnings = {} :: { string } }, RecordingLogger)
end

function RecordingLogger:logInformation(message: string)
	table.insert(self.loggedInformation, message)
end

function RecordingLogger:logWarning(message: string)
	table.insert(self.loggedWarnings, message)
end

function RecordingLogger:countWarningsContaining(searchedText: string): number
	local matchingWarningCount = 0
	for _, loggedWarning in self.loggedWarnings do
		if string.find(loggedWarning, searchedText, 1, true) then
			matchingWarningCount += 1
		end
	end
	return matchingWarningCount
end

return table.freeze(RecordingLogger)
