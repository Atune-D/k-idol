-- ThemedRoundRefereeDependencyCheck: checks the dependencies table given to
-- ThemedRoundReferee.new, so a wiring mistake raises when the server starts instead of at the
-- first phase change or request.
-- Pure logic: no Roblox-specific interface is used.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- ThemedRoundRefereeDependencyCheck.assertRefereeDependenciesHaveTheirKinds(dependencies: any)
--   Returns nothing when `dependencies` is a table holding every required dependency of the
--   kind ThemedRoundReferee's header lists (tables: clock, scheduler, themedRoundClock,
--   playerRequestRateLimiter, rewardLedger, playerSaveDataKeeper,
--   marketplaceStylingItemResolver, stylingItemByStylingItemKey, logger; functions:
--   findThemeByThemeId, the three senders, readPlayerDisplayName), validateOutfit and
--   createRoundOutfitDraftKeeper each nil or a function, and ownerDecisions nil or accepted by
--   ThemedRoundOwnerDecisions.assertIsOwnerDecisions. Otherwise raises a message that starts
--   with "ThemedRoundReferee.new" (or the owner decisions check's own message) and names the
--   first wrong dependency, reported at the line that called ThemedRoundReferee.new.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local ThemedRoundOwnerDecisions = require("./ThemedRoundOwnerDecisions")

local ThemedRoundRefereeDependencyCheck = {}

local REQUIRED_DEPENDENCY_KINDS = table.freeze({
	{ "clock", "table" },
	{ "scheduler", "table" },
	{ "themedRoundClock", "table" },
	{ "playerRequestRateLimiter", "table" },
	{ "rewardLedger", "table" },
	{ "playerSaveDataKeeper", "table" },
	{ "marketplaceStylingItemResolver", "table" },
	{ "stylingItemByStylingItemKey", "table" },
	{ "findThemeByThemeId", "function" },
	{ "sendRoundStateChangedToEveryDevice", "function" },
	{ "sendRoundResultsPublishedToEveryDevice", "function" },
	{ "sendRoundOutfitDraftAcknowledged", "function" },
	{ "readPlayerDisplayName", "function" },
	{ "logger", "table" },
})

local OPTIONAL_FUNCTION_DEPENDENCY_NAMES = table.freeze({ "validateOutfit", "createRoundOutfitDraftKeeper" })

-- Level 4 skips this function, the check, and ThemedRoundReferee.new: the error points at the
-- line that called `new`.
local function raiseForWrongRefereeDependency(message: string)
	error(message, 4)
end

function ThemedRoundRefereeDependencyCheck.assertRefereeDependenciesHaveTheirKinds(dependencies: any)
	if type(dependencies) ~= "table" then
		raiseForWrongRefereeDependency("ThemedRoundReferee.new needs a dependencies table")
	end
	for _, dependencyNameAndKind in REQUIRED_DEPENDENCY_KINDS do
		local dependencyName, expectedKind = dependencyNameAndKind[1], dependencyNameAndKind[2]
		if type(dependencies[dependencyName]) ~= expectedKind then
			raiseForWrongRefereeDependency(
				string.format("ThemedRoundReferee.new needs dependencies.%s (a %s)", dependencyName, expectedKind)
			)
		end
	end
	for _, optionalFunctionName in OPTIONAL_FUNCTION_DEPENDENCY_NAMES do
		if dependencies[optionalFunctionName] ~= nil and type(dependencies[optionalFunctionName]) ~= "function" then
			raiseForWrongRefereeDependency(
				string.format("ThemedRoundReferee.new: dependencies.%s must be a function", optionalFunctionName)
			)
		end
	end
	if dependencies.ownerDecisions ~= nil then
		ThemedRoundOwnerDecisions.assertIsOwnerDecisions(dependencies.ownerDecisions)
	end
end

return table.freeze(ThemedRoundRefereeDependencyCheck)
