-- Names of every device <-> server channel in the development spec §2 (Phases 1 and 2, spec v1.2: 21).
-- Channels live in a folder named REMOTES_FOLDER_NAME inside ReplicatedStorage.
--
-- Reading a name that is not listed raises an error instead of returning nil, so a typo
-- fails loudly at the call site rather than silently creating or looking up a wrong channel.

local function freezeWithErrorOnUnknownName(remoteChannelNameByKey: { [string]: string }): { [string]: string }
	setmetatable(remoteChannelNameByKey, {
		__index = function(_, unknownRemoteChannelKey)
			error(string.format("RemoteNames: unknown remote channel %q", tostring(unknownRemoteChannelKey)), 2)
		end,
	})
	return table.freeze(remoteChannelNameByKey)
end

local RemoteNames = {}

RemoteNames.REMOTES_FOLDER_NAME = "Remotes"

RemoteNames.REMOTE_CHANNEL_NAMES = freezeWithErrorOnUnknownName({
	-- Phase 1
	RoundStateChanged = "RoundStateChanged", -- §2.1, server -> every device
	RequestJoinCurrentRound = "RequestJoinCurrentRound", -- §2.2, device asks, server answers
	SetRoundOutfitDraft = "SetRoundOutfitDraft", -- §2.3, device tells server; acknowledged on the next channel
	RoundOutfitDraftAcknowledged = "RoundOutfitDraftAcknowledged", -- §2.3, server -> that device
	RoundResultsPublished = "RoundResultsPublished", -- §2.5, server -> every device
	PlayerSaveDataSnapshotChanged = "PlayerSaveDataSnapshotChanged", -- §2.6, server -> owning device
	RequestFanCountLeaderboardTopEntries = "RequestFanCountLeaderboardTopEntries", -- §2.11, device asks, server answers
	RequestWardrobeCatalogSnapshot = "RequestWardrobeCatalogSnapshot", -- §2.14, device asks, server answers
	WardrobeCatalogChanged = "WardrobeCatalogChanged", -- §2.14, server -> every device
	RequestStylingItemOwnership = "RequestStylingItemOwnership", -- §2.14, device asks, server answers

	-- Phase 2
	SetLobbyOutfit = "SetLobbyOutfit", -- §2.7, device asks, server answers
	RequestPurchaseDanceWithStarCoins = "RequestPurchaseDanceWithStarCoins", -- §2.8
	RequestPurchaseCosmeticWithStarCoins = "RequestPurchaseCosmeticWithStarCoins", -- §2.8
	RequestEquipDance = "RequestEquipDance", -- §2.8
	RequestEquipCosmetic = "RequestEquipCosmetic", -- §2.8
	RequestStartDanceInLobby = "RequestStartDanceInLobby", -- §2.8
	RequestSyncDanceWithPlayer = "RequestSyncDanceWithPlayer", -- §2.8
	RequestStopDanceInLobby = "RequestStopDanceInLobby", -- §2.8
	RequestClaimPlaytimeMilestone = "RequestClaimPlaytimeMilestone", -- §2.9
	RequestClaimDailyQuestReward = "RequestClaimDailyQuestReward", -- §2.9
	RequestRedeemPromoCode = "RequestRedeemPromoCode", -- §2.10
})

return table.freeze(RemoteNames)
