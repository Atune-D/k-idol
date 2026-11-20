-- RobloxPlayerDisplayNameLookups: the two display-name readers the server modules take.
--   readPlayerDisplayName(playerUserId) -> string   (ThemedRoundReferee, for RoundResultsPublished)
--     The connected player's Player.DisplayName; "Player <userId>" when they are not connected.
--   lookUpPlayerDisplayNamesByUserId(playerUserIds) -> { [number]: string }
--     (FanCountLeaderboardKeeper, may yield) Connected players from Player.DisplayName; everyone
--     else from ONE UserService:GetUserInfosByUserIdsAsync call (at most 100 ids are asked by the
--     keeper). A failed call leaves those names missing; the keeper then shows "Player <userId>".
--
-- Roblox API used, read in the official documentation while writing this file:
--   Players:GetPlayerByUserId, Player.DisplayName
--                       https://create.roblox.com/docs/reference/engine/classes/Players
--                       https://create.roblox.com/docs/reference/engine/classes/Player
--   UserService:GetUserInfosByUserIdsAsync (yields; returns { Id, Username, DisplayName,
--     HasVerifiedBadge } in any order; may fail, so it is wrapped in pcall; 250 results per minute)
--                       https://create.roblox.com/docs/reference/engine/classes/UserService

local Players = game:GetService("Players")
local UserService = game:GetService("UserService")

local RobloxPlayerDisplayNameLookups = {}

function RobloxPlayerDisplayNameLookups.readPlayerDisplayName(playerUserId: number): string
	local player = Players:GetPlayerByUserId(playerUserId)
	if player ~= nil then
		return player.DisplayName
	end
	return "Player " .. tostring(playerUserId)
end

function RobloxPlayerDisplayNameLookups.lookUpPlayerDisplayNamesByUserId(
	playerUserIds: { number }
): { [number]: string }
	local displayNameByUserId = {}
	local userIdsToAskRoblox = {}
	for _, playerUserId in playerUserIds do
		local player = Players:GetPlayerByUserId(playerUserId)
		if player ~= nil then
			displayNameByUserId[playerUserId] = player.DisplayName
		else
			table.insert(userIdsToAskRoblox, playerUserId)
		end
	end
	if #userIdsToAskRoblox == 0 then
		return displayNameByUserId
	end
	local didAsk, userInfos = pcall(function()
		return UserService:GetUserInfosByUserIdsAsync(userIdsToAskRoblox)
	end)
	if didAsk and type(userInfos) == "table" then
		for _, userInfo in userInfos do
			if
				type(userInfo) == "table"
				and type(userInfo.Id) == "number"
				and type(userInfo.DisplayName) == "string"
			then
				displayNameByUserId[userInfo.Id] = userInfo.DisplayName
			end
		end
	end
	return displayNameByUserId
end

return RobloxPlayerDisplayNameLookups
