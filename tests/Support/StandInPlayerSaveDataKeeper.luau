-- A stand-in for PlayerSaveDataKeeper that forwards every method to a REAL keeper except the
-- ones a test replaces. Used only to reach situations the real keeper does not produce on
-- demand, for example `applyChangeToPlayerSaveData` raising (it raises only on programming
-- errors). Events still come from the real keeper, because subscriptions are forwarded.
--
--   StandInPlayerSaveDataKeeper.new(realPlayerSaveDataKeeper, replacementMethodsByName) -> stand-in
--   replacementMethodsByName: { [methodName]: (standIn, ...) -> ... }

local StandInPlayerSaveDataKeeper = {}

function StandInPlayerSaveDataKeeper.new(realPlayerSaveDataKeeper, replacementMethodsByName: { [string]: any })
	return setmetatable({}, {
		__index = function(_, methodName: string)
			local replacementMethod = replacementMethodsByName[methodName]
			if replacementMethod ~= nil then
				return replacementMethod
			end
			local realMethod = realPlayerSaveDataKeeper[methodName]
			if type(realMethod) ~= "function" then
				return realMethod
			end
			return function(_, ...)
				return realMethod(realPlayerSaveDataKeeper, ...)
			end
		end,
	})
end

return StandInPlayerSaveDataKeeper
