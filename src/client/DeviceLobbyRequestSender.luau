-- DeviceLobbyRequestSender (development spec §2.7 to §2.10, §2.13): sends the Phase 2 lobby requests
-- (equip, buy, dance, claim, promo code, lobby outfit) and remembers the latest outcome per channel,
-- so every answer, accepted or refused, can be shown in plain words (LobbyRequestAnswerTexts).
--
-- The device respects each channel's minimum interval (src/shared/RequestChannelMinimumIntervals,
-- the very table the server's PlayerRequestRateLimiter enforces) and sends one request per channel
-- at a time:
--   * a request is sent only when no request on that channel is waiting for its answer, and at least
--     the channel's interval has passed since the ANSWER to the previous one arrived. Counting from
--     the answer (not from the send) is what makes the device's own requests safe from
--     TooManyRequests: the server accepted the previous request before it answered, and the next
--     one reaches the server after it leaves the device, so the server always sees at least the
--     interval between them, whatever the network delay.
--   * a request asked for too soon is NOT sent and NOT queued (a tap is a decision the player may
--     not want repeated later): its outcome is recorded as refused on the device with the reason
--     TOO_SOON_ON_DEVICE_REASON, so the screen explains it.
-- An outcome is { remoteChannelName, requestSubject, outcomeSequenceNumber, isWaitingForAnswer, answer?,
-- refusedOnDevice? }; outcomeSequenceNumber rises with every tap on any channel (the latest tap is highest).
-- `requestSubject` is whatever the caller passes to tell which button the answer belongs to (a
-- dance id, a cosmetic id, a milestone, ...). A missing answer (the call failed) is recorded as nil.
-- Nothing here changes a balance or ownership (§5.1): it only sends what the player asked for.
-- Pure logic: the clock and the channel call are injected.
--
-- PUBLIC API
--   DeviceLobbyRequestSender.TOO_SOON_ON_DEVICE_REASON = "TooSoonOnDevice"
--   DeviceLobbyRequestSender.new({ clock, askServer(remoteChannelName, payload, onAnswer(answer?)),
--       onRequestOutcomeChanged?() }) -> sender
--   sender:sendLobbyRequest(remoteChannelName, payload, requestSubject) -> boolean   true when sent
--   sender:isLobbyRequestAllowedNow(remoteChannelName) -> boolean
--   sender:readSecondsUntilLobbyRequestAllowed(remoteChannelName) -> number   0 when allowed now
--   sender:readLatestLobbyRequestOutcome(remoteChannelName) -> outcome?   (a fresh copy)
--   sender:forgetLatestLobbyRequestOutcome(remoteChannelName)
--   sender:readSentLobbyRequestCount(remoteChannelName) -> number

local RequestChannelMinimumIntervals = require("../shared/RequestChannelMinimumIntervals")

local DeviceLobbyRequestSender = {}
DeviceLobbyRequestSender.__index = DeviceLobbyRequestSender

DeviceLobbyRequestSender.TOO_SOON_ON_DEVICE_REASON = "TooSoonOnDevice"

function DeviceLobbyRequestSender.new(dependencies)
	return setmetatable({
		clock = dependencies.clock,
		askServer = dependencies.askServer,
		onRequestOutcomeChanged = dependencies.onRequestOutcomeChanged,
		channelStateByRemoteChannelName = {},
		lastOutcomeSequenceNumber = 0,
	}, DeviceLobbyRequestSender)
end

function DeviceLobbyRequestSender:readChannelState(remoteChannelName: string)
	local channelState = self.channelStateByRemoteChannelName[remoteChannelName]
	if channelState == nil then
		-- Reading the interval also checks the name: a channel without a limit raises here.
		channelState = {
			minimumIntervalMilliseconds = RequestChannelMinimumIntervals.readMinimumRequestIntervalSeconds(
				remoteChannelName
			) * 1000,
			isWaitingForAnswer = false,
			lastAnswerAtUnixMilliseconds = nil,
			latestOutcome = nil,
			sentRequestCount = 0,
		}
		self.channelStateByRemoteChannelName[remoteChannelName] = channelState
	end
	return channelState
end

-- Every outcome gets a number that rises with each tap, across channels, so a screen that explains
-- two channels on one row (buy and equip) can show the latest tap's outcome.
function DeviceLobbyRequestSender:takeNextOutcomeSequenceNumber(): number
	self.lastOutcomeSequenceNumber += 1
	return self.lastOutcomeSequenceNumber
end

function DeviceLobbyRequestSender:notifyOutcomeChanged()
	if self.onRequestOutcomeChanged ~= nil then
		self.onRequestOutcomeChanged()
	end
end

function DeviceLobbyRequestSender:readSecondsUntilLobbyRequestAllowed(remoteChannelName: string): number
	local channelState = self:readChannelState(remoteChannelName)
	if channelState.isWaitingForAnswer then
		return channelState.minimumIntervalMilliseconds / 1000
	end
	if channelState.lastAnswerAtUnixMilliseconds == nil then
		return 0
	end
	local waitMilliseconds = channelState.lastAnswerAtUnixMilliseconds
		+ channelState.minimumIntervalMilliseconds
		- self.clock:getCurrentUnixMilliseconds()
	return math.max(0, waitMilliseconds / 1000)
end

function DeviceLobbyRequestSender:isLobbyRequestAllowedNow(remoteChannelName: string): boolean
	return self:readSecondsUntilLobbyRequestAllowed(remoteChannelName) <= 0
end

function DeviceLobbyRequestSender:sendLobbyRequest(
	remoteChannelName: string,
	payload: any,
	requestSubject: any
): boolean
	local channelState = self:readChannelState(remoteChannelName)
	if not self:isLobbyRequestAllowedNow(remoteChannelName) then
		channelState.latestOutcome = {
			remoteChannelName = remoteChannelName,
			requestSubject = requestSubject,
			outcomeSequenceNumber = self:takeNextOutcomeSequenceNumber(),
			isWaitingForAnswer = false,
			refusedOnDevice = true,
			answer = { isAccepted = false, rejectionReason = DeviceLobbyRequestSender.TOO_SOON_ON_DEVICE_REASON },
		}
		self:notifyOutcomeChanged()
		return false
	end
	local outcome = {
		remoteChannelName = remoteChannelName,
		requestSubject = requestSubject,
		outcomeSequenceNumber = self:takeNextOutcomeSequenceNumber(),
		isWaitingForAnswer = true,
		refusedOnDevice = false,
		answer = nil,
	}
	channelState.isWaitingForAnswer = true
	channelState.latestOutcome = outcome
	channelState.sentRequestCount += 1
	self:notifyOutcomeChanged()
	self.askServer(remoteChannelName, payload, function(answer)
		channelState.isWaitingForAnswer = false
		channelState.lastAnswerAtUnixMilliseconds = self.clock:getCurrentUnixMilliseconds()
		-- A later local refusal may have replaced the outcome meanwhile; the answer still belongs to
		-- the request that was sent, so it is recorded as that request's outcome.
		outcome.isWaitingForAnswer = false
		outcome.answer = if type(answer) == "table" then table.clone(answer) else nil
		channelState.latestOutcome = outcome
		self:notifyOutcomeChanged()
	end)
	return true
end

function DeviceLobbyRequestSender:readLatestLobbyRequestOutcome(remoteChannelName: string)
	local latestOutcome = self:readChannelState(remoteChannelName).latestOutcome
	if latestOutcome == nil then
		return nil
	end
	local outcomeCopy = table.clone(latestOutcome)
	if outcomeCopy.answer ~= nil then
		outcomeCopy.answer = table.clone(outcomeCopy.answer)
	end
	return outcomeCopy
end

function DeviceLobbyRequestSender:forgetLatestLobbyRequestOutcome(remoteChannelName: string)
	local channelState = self:readChannelState(remoteChannelName)
	if not channelState.isWaitingForAnswer then
		channelState.latestOutcome = nil
	end
end

function DeviceLobbyRequestSender:readSentLobbyRequestCount(remoteChannelName: string): number
	return self:readChannelState(remoteChannelName).sentRequestCount
end

return DeviceLobbyRequestSender
