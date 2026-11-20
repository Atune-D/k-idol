-- Names of every device <-> server channel in the development spec §2 (Phases 1 and 2, spec v1.2: 21).
-- Channels live in a folder named REMOTES_FOLDER_NAME inside ReplicatedStorage.
--
-- Reading a name that is not listed raises an error instead of returning nil, so a typo
-- fails loudly at the call site rather than silently creating or looking up a wrong channel.
--
-- PUBLIC API
--   RemoteNames.REMOTES_FOLDER_NAME  = "Remotes"
--   RemoteNames.REMOTE_CHANNEL_NAMES  { [channelName]: channelName }, every channel of spec §2.
--       Frozen; reading an unknown name raises 'unknown remote channel "<name>"'.
--   RemoteNames.DEVICE_SENT_REMOTE_CHANNEL_NAME_SET  { [channelName]: true }
--       The channels a DEVICE sends on (requests and drafts; spec §2: "device asks" / "device
--       tells server"). These are the channels the server must treat as untrusted input and
--       rate-limit (§2.13).
--   RemoteNames.SERVER_SENT_REMOTE_CHANNEL_NAME_SET  { [channelName]: true }
--       The channels only the SERVER sends on (spec §2: "server -> every device" / "server ->
--       that device" / "server -> the owning device").
--   Every channel is in exactly one of the two sets. Both sets are frozen. Reading a known channel
--   that belongs to the other set gives nil; reading a name that is not a channel at all raises
--   'unknown remote channel "<name>"', so a typo cannot silently read as "not in this set".
--
--   How each channel travels (the ONE place both the server and the device read it from):
--   RemoteNames.REMOTE_CHANNEL_KINDS  frozen { DeviceRequestWithServerAnswer, DeviceMessageWithoutAnswer,
--       ServerMessage }:
--         DeviceRequestWithServerAnswer  "device asks, server answers": the device calls and waits
--                                        for one answer table.
--         DeviceMessageWithoutAnswer     "device tells server" (only SetRoundOutfitDraft; its
--                                        acknowledgement comes back on a server-sent channel).
--         ServerMessage                  every channel in SERVER_SENT_REMOTE_CHANNEL_NAME_SET.
--   RemoteNames.REMOTE_CHANNEL_KIND_BY_REMOTE_CHANNEL_NAME  frozen { [channelName]: kind } for
--       every channel; reading a name that is not a channel raises 'unknown remote channel "<name>"'.
--   RemoteNames.ROBLOX_REMOTE_INSTANCE_CLASS_NAME_BY_REMOTE_CHANNEL_KIND  frozen:
--       DeviceRequestWithServerAnswer -> "RemoteFunction", the other two kinds -> "RemoteEvent".
--       (Class names from https://create.roblox.com/docs/reference/engine/classes/RemoteFunction and
--       .../RemoteEvent; plain strings here, so this module stays free of Roblox interfaces.)

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

local REMOTE_CHANNEL_NAMES = RemoteNames.REMOTE_CHANNEL_NAMES

-- A frozen set of channel names. A known channel outside the set reads as nil; a name that is
-- not a channel at all raises, exactly as REMOTE_CHANNEL_NAMES does.
local function freezeRemoteChannelNameSet(remoteChannelNames: { string }): { [string]: boolean }
	local remoteChannelNameSet = {}
	for _, remoteChannelName in remoteChannelNames do
		remoteChannelNameSet[REMOTE_CHANNEL_NAMES[remoteChannelName]] = true -- an unknown name raises here
	end
	setmetatable(remoteChannelNameSet, {
		__index = function(_, readRemoteChannelName)
			if rawget(REMOTE_CHANNEL_NAMES, readRemoteChannelName) == nil then
				error(string.format("RemoteNames: unknown remote channel %q", tostring(readRemoteChannelName)), 2)
			end
			return nil
		end,
	})
	return table.freeze(remoteChannelNameSet)
end

-- Spec §2: the channels a device sends on.
RemoteNames.DEVICE_SENT_REMOTE_CHANNEL_NAME_SET = freezeRemoteChannelNameSet({
	-- Phase 1
	"RequestJoinCurrentRound", -- §2.2
	"SetRoundOutfitDraft", -- §2.3
	"RequestFanCountLeaderboardTopEntries", -- §2.11
	"RequestWardrobeCatalogSnapshot", -- §2.14
	"RequestStylingItemOwnership", -- §2.14
	-- Phase 2
	"SetLobbyOutfit", -- §2.7
	"RequestPurchaseDanceWithStarCoins", -- §2.8
	"RequestPurchaseCosmeticWithStarCoins", -- §2.8
	"RequestEquipDance", -- §2.8
	"RequestEquipCosmetic", -- §2.8
	"RequestStartDanceInLobby", -- §2.8
	"RequestSyncDanceWithPlayer", -- §2.8
	"RequestStopDanceInLobby", -- §2.8
	"RequestClaimPlaytimeMilestone", -- §2.9
	"RequestClaimDailyQuestReward", -- §2.9
	"RequestRedeemPromoCode", -- §2.10
})

-- Spec §2: the channels only the server sends on.
RemoteNames.SERVER_SENT_REMOTE_CHANNEL_NAME_SET = freezeRemoteChannelNameSet({
	"RoundStateChanged", -- §2.1, to every device
	"RoundOutfitDraftAcknowledged", -- §2.3, to that device
	"RoundResultsPublished", -- §2.5, to every device
	"PlayerSaveDataSnapshotChanged", -- §2.6, to the owning device
	"WardrobeCatalogChanged", -- §2.14, to every device
})

RemoteNames.REMOTE_CHANNEL_KINDS = table.freeze({
	DeviceRequestWithServerAnswer = "DeviceRequestWithServerAnswer",
	DeviceMessageWithoutAnswer = "DeviceMessageWithoutAnswer",
	ServerMessage = "ServerMessage",
})

-- Spec §2.3: the only channel a device sends on without waiting for an answer.
local DEVICE_SENT_CHANNEL_NAMES_WITHOUT_ANSWER = table.freeze({ "SetRoundOutfitDraft" })

local function buildRemoteChannelKindByRemoteChannelName(): { [string]: string }
	local remoteChannelKindByRemoteChannelName = {}
	for remoteChannelName in REMOTE_CHANNEL_NAMES do
		local remoteChannelKind
		if rawget(RemoteNames.SERVER_SENT_REMOTE_CHANNEL_NAME_SET, remoteChannelName) == true then
			remoteChannelKind = RemoteNames.REMOTE_CHANNEL_KINDS.ServerMessage
		elseif table.find(DEVICE_SENT_CHANNEL_NAMES_WITHOUT_ANSWER, remoteChannelName) ~= nil then
			remoteChannelKind = RemoteNames.REMOTE_CHANNEL_KINDS.DeviceMessageWithoutAnswer
		else
			remoteChannelKind = RemoteNames.REMOTE_CHANNEL_KINDS.DeviceRequestWithServerAnswer
		end
		remoteChannelKindByRemoteChannelName[remoteChannelName] = remoteChannelKind
	end
	return remoteChannelKindByRemoteChannelName
end

RemoteNames.REMOTE_CHANNEL_KIND_BY_REMOTE_CHANNEL_NAME =
	freezeWithErrorOnUnknownName(buildRemoteChannelKindByRemoteChannelName())

RemoteNames.ROBLOX_REMOTE_INSTANCE_CLASS_NAME_BY_REMOTE_CHANNEL_KIND = table.freeze({
	DeviceRequestWithServerAnswer = "RemoteFunction",
	DeviceMessageWithoutAnswer = "RemoteEvent",
	ServerMessage = "RemoteEvent",
})

return table.freeze(RemoteNames)
