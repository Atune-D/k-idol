-- StylingItemOwnershipRequester (development spec §2.12, §2.13, §2.14 RequestStylingItemOwnership): decides
-- WHEN the device asks the server whether the player owns the styling item they selected, and keeps
-- the answer for the wardrobe's Buy panel.
--   * The FOCUSED item is the one the player last tapped in a wardrobe (round or lobby) and that is
--     selected after the tap (noteWardrobeTap); tapping it off, or a refused tap, clears the focus
--     when it was that item. §2.14: "Ownership is asked for one item at a time, when the player
--     selects it, and again after a purchase prompt closes" (askAgainAfterPurchasePromptClosed).
--   * Every focus asks anew (ownership may have changed outside the game); nothing is cached across
--     selections.
--   * §2.13: at most one request in flight, and the next one at least 0.5 s
--     (src/shared/RequestChannelMinimumIntervals) after the previous ANSWER arrived (see
--     DeviceLobbyRequestSender for why from the answer). An ask inside the interval waits for its end
--     (only the latest focus is asked); a focus change while a request is in flight asks again for
--     the new focus once the answer is in. An answer for an item that is no longer focused is dropped.
--   * A TooManyRequests answer (another sender used the channel) is asked again after the interval,
--     at most MAX_TOO_MANY_REQUESTS_RETRIES times in a row.
-- ownershipStatus: "Checking" | "Owned" | "NotOwned" | "CheckFailed" (OwnershipCheckFailed, no answer,
-- or a wrong shape) | "UnknownItem" (UnknownStylingItem) | "Refused" (TooManyRequests after the retries).
-- The answer only decides what the Buy panel shows; the game grants and stores nothing (§2.12).
-- Pure logic: clock, scheduler and the request function are injected.
--
-- PUBLIC API
--   StylingItemOwnershipRequester.MAX_TOO_MANY_REQUESTS_RETRIES = 3
--   StylingItemOwnershipRequester.new({ clock, scheduler, requestStylingItemOwnership(stylingItemKey, onAnswer(answer?)),
--       onOwnershipChanged?() }) -> requester
--   requester:noteWardrobeTap(tappedStylingItemKey, selectionOutcome?)
--   requester:focusStylingItem(stylingItemKey)   requester:clearFocus()
--   requester:askAgainAfterPurchasePromptClosed(stylingItemKey)
--   requester:readFocusedOwnership() -> { stylingItemKey, ownershipStatus, rejectionReason? }?
--   requester:readSentRequestCount() -> number

local RequestChannelMinimumIntervals = require("../shared/RequestChannelMinimumIntervals")

local StylingItemOwnershipRequester = {}
StylingItemOwnershipRequester.__index = StylingItemOwnershipRequester

StylingItemOwnershipRequester.MAX_TOO_MANY_REQUESTS_RETRIES = 3

local MINIMUM_INTERVAL_SECONDS =
	RequestChannelMinimumIntervals.readMinimumRequestIntervalSeconds("RequestStylingItemOwnership")

function StylingItemOwnershipRequester.new(dependencies)
	return setmetatable({
		clock = dependencies.clock,
		scheduler = dependencies.scheduler,
		requestStylingItemOwnership = dependencies.requestStylingItemOwnership,
		onOwnershipChanged = dependencies.onOwnershipChanged,
		focusedStylingItemKey = nil,
		focusedOwnership = nil,
		isAskWanted = false,
		isRequestInFlight = false,
		cancelWaitingAsk = nil,
		lastAnswerAtUnixMilliseconds = nil,
		tooManyRequestsRetryCount = 0,
		sentRequestCount = 0,
	}, StylingItemOwnershipRequester)
end

function StylingItemOwnershipRequester:notifyOwnershipChanged()
	if self.onOwnershipChanged ~= nil then
		self.onOwnershipChanged()
	end
end

local function readOwnershipFromAnswer(answer: any)
	if type(answer) ~= "table" then
		return "CheckFailed", nil
	end
	if answer.isAccepted == true and type(answer.isOwnedByPlayer) == "boolean" then
		return if answer.isOwnedByPlayer then "Owned" else "NotOwned", nil
	end
	if answer.isAccepted == false and answer.rejectionReason == "UnknownStylingItem" then
		return "UnknownItem", answer.rejectionReason
	end
	if answer.isAccepted == false and answer.rejectionReason == "TooManyRequests" then
		return "Refused", answer.rejectionReason
	end
	return "CheckFailed", if type(answer.rejectionReason) == "string" then answer.rejectionReason else nil
end

function StylingItemOwnershipRequester:receiveAnswer(askedStylingItemKey: string, answer: any)
	self.isRequestInFlight = false
	self.lastAnswerAtUnixMilliseconds = self.clock:getCurrentUnixMilliseconds()
	if askedStylingItemKey == self.focusedStylingItemKey then
		local ownershipStatus, rejectionReason = readOwnershipFromAnswer(answer)
		local mayRetry = self.tooManyRequestsRetryCount < StylingItemOwnershipRequester.MAX_TOO_MANY_REQUESTS_RETRIES
		if ownershipStatus == "Refused" and mayRetry then
			self.tooManyRequestsRetryCount += 1
			self.isAskWanted = true
		else
			self.tooManyRequestsRetryCount = 0
			self.focusedOwnership = {
				stylingItemKey = askedStylingItemKey,
				ownershipStatus = ownershipStatus,
				rejectionReason = rejectionReason,
			}
		end
	end
	self:notifyOwnershipChanged()
	if self.isAskWanted then
		self:askWhenAllowed()
	end
end

function StylingItemOwnershipRequester:sendRequestNow()
	local askedStylingItemKey = self.focusedStylingItemKey
	self.isAskWanted = false
	if askedStylingItemKey == nil then
		return
	end
	self.isRequestInFlight = true
	self.sentRequestCount += 1
	self.requestStylingItemOwnership(askedStylingItemKey, function(answer)
		self:receiveAnswer(askedStylingItemKey, answer)
	end)
end

function StylingItemOwnershipRequester:askWhenAllowed()
	self.isAskWanted = true
	if self.isRequestInFlight or self.cancelWaitingAsk ~= nil then
		return
	end
	local waitMilliseconds = if self.lastAnswerAtUnixMilliseconds == nil
		then 0
		else self.lastAnswerAtUnixMilliseconds
			+ MINIMUM_INTERVAL_SECONDS * 1000
			- self.clock:getCurrentUnixMilliseconds()
	if waitMilliseconds <= 0 then
		self:sendRequestNow()
		return
	end
	self.cancelWaitingAsk = self.scheduler:scheduleCallbackAfterSeconds(waitMilliseconds / 1000, function()
		self.cancelWaitingAsk = nil
		if not self.isRequestInFlight and self.isAskWanted then
			self:sendRequestNow()
		end
	end)
end

function StylingItemOwnershipRequester:focusStylingItem(stylingItemKey: string)
	self.focusedStylingItemKey = stylingItemKey
	self.focusedOwnership = { stylingItemKey = stylingItemKey, ownershipStatus = "Checking" }
	self.tooManyRequestsRetryCount = 0
	self:notifyOwnershipChanged()
	self:askWhenAllowed()
end

function StylingItemOwnershipRequester:clearFocus()
	if self.focusedStylingItemKey == nil then
		return
	end
	self.focusedStylingItemKey = nil
	self.focusedOwnership = nil
	self.isAskWanted = false
	self:notifyOwnershipChanged()
end

function StylingItemOwnershipRequester:noteWardrobeTap(tappedStylingItemKey: string, selectionOutcome)
	if selectionOutcome == nil then
		return
	end
	local isSelectedAfterTap = selectionOutcome.isSelectionChanged
		and table.find(selectionOutcome.outfitStylingItemKeys, tappedStylingItemKey) ~= nil
	if isSelectedAfterTap then
		self:focusStylingItem(tappedStylingItemKey)
	elseif self.focusedStylingItemKey == tappedStylingItemKey then
		self:clearFocus()
	end
end

function StylingItemOwnershipRequester:askAgainAfterPurchasePromptClosed(stylingItemKey: string)
	if stylingItemKey == self.focusedStylingItemKey then
		self:focusStylingItem(stylingItemKey)
	end
end

function StylingItemOwnershipRequester:readFocusedOwnership()
	return if self.focusedOwnership ~= nil then table.clone(self.focusedOwnership) else nil
end

function StylingItemOwnershipRequester:readSentRequestCount(): number
	return self.sentRequestCount
end

return StylingItemOwnershipRequester
