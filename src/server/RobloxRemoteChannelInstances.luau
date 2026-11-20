-- RobloxRemoteChannelInstances (development spec v1.3 §2): creates the folder
-- ReplicatedStorage.<RemoteNames.REMOTES_FOLDER_NAME> at server start with ONE instance per channel
-- of RemoteNames, of the class RemoteNames.ROBLOX_REMOTE_INSTANCE_CLASS_NAME_BY_REMOTE_CHANNEL_KIND
-- names for the channel's kind (RemoteFunction for "device asks, server answers", RemoteEvent for
-- SetRoundOutfitDraft and every server-sent channel), and builds the server's senders for the
-- server-sent channels. Nothing else; the device-sent channels are connected by
-- RobloxDeviceRemoteChannelConnections.
--
-- The folder must not exist yet (nothing in the project maps into ReplicatedStorage): finding one
-- raises, because a leftover folder could hold instances of the wrong class.
--
-- PUBLIC API
--   RobloxRemoteChannelInstances.createRemoteChannelInstances() -> remoteInstanceByRemoteChannelName
--   RobloxRemoteChannelInstances.buildDeviceMessageSenders(remoteInstanceByRemoteChannelName)
--     -> ServerGameModuleAssembly's `deviceMessageSenders` (none of them yields). A sender for one
--     player does nothing when that player is no longer in the server.
--
-- Roblox API used, read in the official documentation while writing this file:
--   game:GetService                   https://create.roblox.com/docs/reference/engine/classes/ServiceProvider
--   ReplicatedStorage                 https://create.roblox.com/docs/reference/engine/classes/ReplicatedStorage
--   Instance.new, Instance.Name, Instance.Parent, Instance:FindFirstChild
--                                     https://create.roblox.com/docs/reference/engine/classes/Instance
--   Folder                            https://create.roblox.com/docs/reference/engine/classes/Folder
--   RemoteEvent:FireClient, :FireAllClients ("Scripts firing a RemoteEvent do not yield")
--                                     https://create.roblox.com/docs/reference/engine/classes/RemoteEvent
--   RemoteFunction                    https://create.roblox.com/docs/reference/engine/classes/RemoteFunction
--   Players:GetPlayerByUserId (nil when absent)
--                                     https://create.roblox.com/docs/reference/engine/classes/Players

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteNames = require("../shared/RemoteNames")

local RobloxRemoteChannelInstances = {}

function RobloxRemoteChannelInstances.createRemoteChannelInstances(): { [string]: Instance }
	if ReplicatedStorage:FindFirstChild(RemoteNames.REMOTES_FOLDER_NAME) ~= nil then
		error(
			string.format(
				"RobloxRemoteChannelInstances: ReplicatedStorage.%s already exists; nothing may create it but the server",
				RemoteNames.REMOTES_FOLDER_NAME
			)
		)
	end
	local remotesFolder = Instance.new("Folder")
	remotesFolder.Name = RemoteNames.REMOTES_FOLDER_NAME
	local remoteInstanceByRemoteChannelName = {}
	local sortedRemoteChannelNames = {}
	for remoteChannelName in RemoteNames.REMOTE_CHANNEL_NAMES do
		table.insert(sortedRemoteChannelNames, remoteChannelName)
	end
	table.sort(sortedRemoteChannelNames)
	for _, remoteChannelName in sortedRemoteChannelNames do
		local remoteChannelKind = RemoteNames.REMOTE_CHANNEL_KIND_BY_REMOTE_CHANNEL_NAME[remoteChannelName]
		local remoteInstance =
			Instance.new(RemoteNames.ROBLOX_REMOTE_INSTANCE_CLASS_NAME_BY_REMOTE_CHANNEL_KIND[remoteChannelKind])
		remoteInstance.Name = remoteChannelName
		remoteInstance.Parent = remotesFolder
		remoteInstanceByRemoteChannelName[remoteChannelName] = remoteInstance
	end
	remotesFolder.Parent = ReplicatedStorage
	return remoteInstanceByRemoteChannelName
end

function RobloxRemoteChannelInstances.buildDeviceMessageSenders(remoteInstanceByRemoteChannelName: { [string]: any })
	local function sendToEveryDevice(remoteChannelName: string)
		local remoteEvent = remoteInstanceByRemoteChannelName[remoteChannelName]
		return function(message)
			remoteEvent:FireAllClients(message)
		end
	end
	local function sendToOnePlayer(remoteChannelName: string)
		local remoteEvent = remoteInstanceByRemoteChannelName[remoteChannelName]
		return function(playerUserId: number, message)
			local player = Players:GetPlayerByUserId(playerUserId)
			if player ~= nil then
				remoteEvent:FireClient(player, message)
			end
		end
	end
	local channelNames = RemoteNames.REMOTE_CHANNEL_NAMES
	return {
		sendRoundStateChangedToEveryDevice = sendToEveryDevice(channelNames.RoundStateChanged),
		sendRoundStateChangedToPlayer = sendToOnePlayer(channelNames.RoundStateChanged),
		sendRoundOutfitDraftAcknowledgedToPlayer = sendToOnePlayer(channelNames.RoundOutfitDraftAcknowledged),
		sendRoundResultsPublishedToEveryDevice = sendToEveryDevice(channelNames.RoundResultsPublished),
		sendPlayerSaveDataSnapshotToPlayer = sendToOnePlayer(channelNames.PlayerSaveDataSnapshotChanged),
		sendWardrobeCatalogChangedToEveryDevice = sendToEveryDevice(channelNames.WardrobeCatalogChanged),
	}
end

return RobloxRemoteChannelInstances
