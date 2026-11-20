-- RobloxDeviceRemoteChannels (README "Channels as they travel (device side)"): the device's end of
-- the channels the server creates in ReplicatedStorage.Remotes at run time.
--   * waitForRemoteChannels waits until every Phase 1 channel the device uses exists (the server
--     creates them at start; a device may load first).
--   * askServer(channelName, payload, onAnswer) calls RemoteFunction:InvokeServer on its own thread
--     (InvokeServer yields until the server answers) and hands the answer to onAnswer; if the call
--     raises, onAnswer receives nil. The rule modules therefore never yield.
--   * fireOutfitDraft(message) is RemoteEvent:FireServer on SetRoundOutfitDraft.
--   * listenToServerMessage(channelName, handler) connects RemoteEvent.OnClientEvent; a handler that
--     raises is caught and reported with warn, so one bad message never disconnects a channel.
--   Only the channels RemoteNames lists are used; a wrong name raises (RemoteNames is strict).
--
-- PUBLIC API
--   RobloxDeviceRemoteChannels.waitForRemoteChannels(channelNames) -> channels   YIELDS
--   channels:askServer(channelName, payload, onAnswer(answer?))
--   channels:fireOutfitDraft(message)
--   channels:listenToServerMessage(channelName, handler(message))
--
-- Roblox API used, read in the official documentation (create.roblox.com/docs/reference/engine/...):
--   ReplicatedStorage (game:GetService)                     classes/ReplicatedStorage
--   Instance:WaitForChild(name)                             classes/Instance
--   RemoteFunction:InvokeServer (yields until the server's OnServerInvoke returns)   classes/RemoteFunction
--   RemoteEvent:FireServer, RemoteEvent.OnClientEvent       classes/RemoteEvent
--   RBXScriptSignal:Connect                                 datatypes/RBXScriptSignal
--   task.spawn                                              libraries/task

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteNames = require("../shared/RemoteNames")

local RobloxDeviceRemoteChannels = {}
RobloxDeviceRemoteChannels.__index = RobloxDeviceRemoteChannels

function RobloxDeviceRemoteChannels.waitForRemoteChannels(channelNames: { string })
	local remotesFolder = ReplicatedStorage:WaitForChild(RemoteNames.REMOTES_FOLDER_NAME)
	local remoteByChannelName = {}
	for _, channelName in channelNames do
		remoteByChannelName[channelName] = remotesFolder:WaitForChild(RemoteNames.REMOTE_CHANNEL_NAMES[channelName])
	end
	return setmetatable({ remoteByChannelName = remoteByChannelName }, RobloxDeviceRemoteChannels)
end

function RobloxDeviceRemoteChannels:readRemote(channelName: string): Instance
	local remote = self.remoteByChannelName[channelName]
	if remote == nil then
		error("RobloxDeviceRemoteChannels: channel " .. channelName .. " was not waited for")
	end
	return remote
end

function RobloxDeviceRemoteChannels:askServer(channelName: string, payload: any, onAnswer: (any) -> ())
	local remoteFunction = self:readRemote(channelName) :: RemoteFunction
	task.spawn(function()
		local didAnswer, answer = pcall(function()
			return remoteFunction:InvokeServer(payload)
		end)
		onAnswer(if didAnswer then answer else nil)
	end)
end

function RobloxDeviceRemoteChannels:fireOutfitDraft(message)
	local remoteEvent = self:readRemote(RemoteNames.REMOTE_CHANNEL_NAMES.SetRoundOutfitDraft) :: RemoteEvent
	remoteEvent:FireServer(message)
end

function RobloxDeviceRemoteChannels:listenToServerMessage(channelName: string, handler: (any) -> ())
	local remoteEvent = self:readRemote(channelName) :: RemoteEvent
	remoteEvent.OnClientEvent:Connect(function(message)
		local didHandle, problem = pcall(handler, message)
		if not didHandle then
			warn(string.format("Device: handling %s failed: %s", channelName, tostring(problem)))
		end
	end)
end

return RobloxDeviceRemoteChannels
