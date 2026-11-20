-- RobloxServerLogger: the `logger` every server module takes ({ logInformation, logWarning }),
-- writing to the Roblox output. Information lines go through print, warnings through warn, both
-- prefixed "[idolgrow]" so they are easy to find among engine lines.
--
-- PUBLIC API
--   RobloxServerLogger.newForThisServer() -> logger
--   logger:logInformation(message)   print("[idolgrow] " .. message)
--   logger:logWarning(message)       warn("[idolgrow] " .. message)
--   logger:logLoudWarning(message)   warn with a banner, for the one development-storage warning
--
-- Roblox API used, read in the official documentation while writing this file:
--   print, warn   https://create.roblox.com/docs/reference/engine/globals/LuaGlobals
--                 https://create.roblox.com/docs/reference/engine/globals/RobloxGlobals

local RobloxServerLogger = {}
RobloxServerLogger.__index = RobloxServerLogger

local LOG_LINE_PREFIX = "[idolgrow] "

function RobloxServerLogger.newForThisServer()
	return setmetatable({}, RobloxServerLogger)
end

function RobloxServerLogger:logInformation(message: string)
	print(LOG_LINE_PREFIX .. message)
end

function RobloxServerLogger:logWarning(message: string)
	warn(LOG_LINE_PREFIX .. message)
end

function RobloxServerLogger:logLoudWarning(message: string)
	local banner = string.rep("!", 24)
	warn(string.format("%s%s %s %s", LOG_LINE_PREFIX, banner, message, banner))
end

return RobloxServerLogger
