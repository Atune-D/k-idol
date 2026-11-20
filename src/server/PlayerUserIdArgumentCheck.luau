-- PlayerUserIdArgumentCheck: the one rule for a `playerUserId` argument that the server wiring
-- passes to the themed round modules (RoundOutfitDraftKeeper, ThemedRoundParticipantRoster,
-- ThemedRoundReferee). A playerUserId is the server's identity of a player, never a device
-- value, so a wrong one is a wiring error and raises.
-- Pure logic: no Roblox-specific interface is used.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- PlayerUserIdArgumentCheck.assertIsPlayerUserId(playerUserId: any, callingModuleName: string)
--   Returns nothing for a number that is not NaN. Otherwise raises
--   "<callingModuleName>: playerUserId must be a number, got <type>", reported at the line that
--   called the calling module's method (call it directly from that method).
-- ════════════════════════════════════════════════════════════════════════════════════════════

local PlayerUserIdArgumentCheck = {}

function PlayerUserIdArgumentCheck.assertIsPlayerUserId(playerUserId: any, callingModuleName: string)
	-- NaN is the only number not equal to itself.
	if type(playerUserId) ~= "number" or playerUserId ~= playerUserId then
		error(string.format("%s: playerUserId must be a number, got %s", callingModuleName, type(playerUserId)), 3)
	end
end

return table.freeze(PlayerUserIdArgumentCheck)
