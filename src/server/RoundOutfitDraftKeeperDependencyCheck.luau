-- RoundOutfitDraftKeeperDependencyCheck: checks the dependencies table given to
-- RoundOutfitDraftKeeper.new (development spec v1.3 §2.3), so a wiring mistake raises when the
-- round's keeper is created instead of in the middle of Styling.
-- Pure logic: no Roblox-specific interface is used.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- RoundOutfitDraftKeeperDependencyCheck.assertKeeperDependenciesHaveTheirKinds(dependencies: any)
--   Returns nothing when `dependencies` is a table holding a non-empty string roundId, the tables
--   clock, scheduler, playerRequestRateLimiter, stylingItemByStylingItemKey and logger, the
--   functions readAvailableStylingItemKeySet and sendRoundOutfitDraftAcknowledged, and either no
--   validateOutfit or a function. Otherwise raises a message that starts with
--   "RoundOutfitDraftKeeper.new" and names the first wrong dependency, reported at the line that
--   called RoundOutfitDraftKeeper.new.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local RoundOutfitDraftKeeperDependencyCheck = {}

local REQUIRED_DEPENDENCY_KINDS = table.freeze({
	{ "roundId", "string" },
	{ "clock", "table" },
	{ "scheduler", "table" },
	{ "playerRequestRateLimiter", "table" },
	{ "readAvailableStylingItemKeySet", "function" },
	{ "stylingItemByStylingItemKey", "table" },
	{ "sendRoundOutfitDraftAcknowledged", "function" },
	{ "logger", "table" },
})

-- Level 4 skips this function, the check, and RoundOutfitDraftKeeper.new: the error points at
-- the line that called `new`.
local function raiseForWrongKeeperDependency(message: string)
	error(message, 4)
end

function RoundOutfitDraftKeeperDependencyCheck.assertKeeperDependenciesHaveTheirKinds(dependencies: any)
	if type(dependencies) ~= "table" then
		raiseForWrongKeeperDependency("RoundOutfitDraftKeeper.new needs a dependencies table")
	end
	if dependencies.roundId == "" then
		raiseForWrongKeeperDependency("RoundOutfitDraftKeeper.new needs a non-empty dependencies.roundId")
	end
	for _, dependencyNameAndKind in REQUIRED_DEPENDENCY_KINDS do
		local dependencyName, expectedKind = dependencyNameAndKind[1], dependencyNameAndKind[2]
		if type(dependencies[dependencyName]) ~= expectedKind then
			raiseForWrongKeeperDependency(
				string.format("RoundOutfitDraftKeeper.new needs dependencies.%s (a %s)", dependencyName, expectedKind)
			)
		end
	end
	if dependencies.validateOutfit ~= nil and type(dependencies.validateOutfit) ~= "function" then
		raiseForWrongKeeperDependency("RoundOutfitDraftKeeper.new needs dependencies.validateOutfit (a function)")
	end
end

return table.freeze(RoundOutfitDraftKeeperDependencyCheck)
