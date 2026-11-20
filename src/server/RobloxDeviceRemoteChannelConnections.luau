-- RobloxDeviceRemoteChannelConnections (development spec v1.3 §2): connects every device-sent
-- channel's Roblox instance to DeviceRequestChannelAnswerRouter.
--   * A request channel (RemoteFunction): OnServerInvoke = the router's answer for that player.
--     The handler waits for the answer with CallbackAnswerWaiter: only the invoking device's
--     handler thread is suspended (the ownership answer arrives through the resolver's callback),
--     everything else keeps running, and the device always gets exactly one answer (the resolver
--     answers within its own timeout; a module that raises is answered RequestFailedOnServer by the
--     router).
--   * SetRoundOutfitDraft (RemoteEvent): OnServerEvent hands the message to the router.
--   * A server-sent channel (RemoteEvent): an empty OnServerEvent handler, so whatever a device
--     fires there is dropped.
-- The sending Player comes from the engine (the first handler argument), never from the payload;
-- only its UserId is passed on. A request carries at most ONE payload value (the spec §2 payload);
-- further arguments a device adds are dropped here.
--
-- PUBLIC API
--   RobloxDeviceRemoteChannelConnections.connectDeviceRemoteChannels(remoteInstanceByRemoteChannelName,
--     deviceRequestChannelAnswerRouter)
--
-- Roblox API used, read in the official documentation while writing this file:
--   RemoteFunction.OnServerInvoke ("When the bound function returns, the returned values are sent
--     back to the calling client"; the client's InvokeServer yields until then)
--                                    https://create.roblox.com/docs/reference/engine/classes/RemoteFunction
--   RemoteEvent.OnServerEvent (the firing Player first)
--                                    https://create.roblox.com/docs/reference/engine/classes/RemoteEvent
--   RBXScriptSignal:Connect          https://create.roblox.com/docs/reference/engine/datatypes/RBXScriptSignal
--   Player.UserId                    https://create.roblox.com/docs/reference/engine/classes/Player
--   task.spawn (resumes the suspended handler thread with the answer)
--                                    https://create.roblox.com/docs/reference/engine/libraries/task
-- Verified in Studio 0.748 on 2026-11-19 (playtest server): a thread suspended with
-- coroutine.yield was resumed by task.spawn(thread, value) and received the value.

local CallbackAnswerWaiter = require("./CallbackAnswerWaiter")
local RemoteNames = require("../shared/RemoteNames")

local RobloxDeviceRemoteChannelConnections = {}

local function resumeWaitingHandlerThread(waitingThread: thread, answer: any)
	task.spawn(waitingThread, answer)
end

function RobloxDeviceRemoteChannelConnections.connectDeviceRemoteChannels(
	remoteInstanceByRemoteChannelName: { [string]: any },
	deviceRequestChannelAnswerRouter
)
	local kinds = RemoteNames.REMOTE_CHANNEL_KINDS
	for remoteChannelName, remoteChannelKind in RemoteNames.REMOTE_CHANNEL_KIND_BY_REMOTE_CHANNEL_NAME do
		local remoteInstance = remoteInstanceByRemoteChannelName[remoteChannelName]
		if remoteChannelKind == kinds.DeviceRequestWithServerAnswer then
			remoteInstance.OnServerInvoke = function(sendingPlayer: Player, untrustedRequestPayload: any)
				local sendingPlayerUserId = sendingPlayer.UserId
				return CallbackAnswerWaiter.waitForCallbackAnswer(function(onAnswerReady)
					deviceRequestChannelAnswerRouter:startAnsweringDeviceRequest(
						remoteChannelName,
						sendingPlayerUserId,
						untrustedRequestPayload,
						onAnswerReady
					)
				end, resumeWaitingHandlerThread)
			end
		elseif remoteChannelKind == kinds.DeviceMessageWithoutAnswer then
			remoteInstance.OnServerEvent:Connect(function(sendingPlayer: Player, untrustedMessage: any)
				deviceRequestChannelAnswerRouter:receiveDeviceMessageWithoutAnswer(
					remoteChannelName,
					sendingPlayer.UserId,
					untrustedMessage
				)
			end)
		else
			-- A server-sent channel: a device that fires it is ignored. A connected handler makes
			-- the engine drop such events instead of queueing them for a listener that never comes.
			remoteInstance.OnServerEvent:Connect(function() end)
		end
	end
end

return RobloxDeviceRemoteChannelConnections
