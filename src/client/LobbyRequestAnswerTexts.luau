-- LobbyRequestAnswerTexts (development spec §2.7 to §2.10, §2.13, §2.14): every answer the server can
-- give to a Phase 2 request, in plain words, in one place. One sentence per rejection reason of each
-- channel (the server modules' reason tables; tests/client/LobbyRequestAnswerTexts.spec.luau fails
-- when a server reason has no sentence here), plus:
--   * RequestFailedOnServer (the server's answer when a module raised, README "Remote channels");
--   * a request that got no answer at all (the call failed): GENERIC_NO_ANSWER_TEXT;
--   * DeviceLobbyRequestSender's own refusal of a request asked for too soon (never sent);
--   * any reason this file does not know: GENERIC_REFUSAL_TEXT (a newer server).
-- Accepted answers get a sentence too. They never state an amount earned or a new balance: the
-- balance, ownership and claims shown come only from the save snapshot (§2.6 🔴), so an accepted
-- purchase or claim says the result is on its way, and the screens show it when the snapshot does.
-- No real brand, idol, group, artist or song names (spec §5.2).
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   LobbyRequestAnswerTexts.REJECTION_TEXT_BY_REASON_BY_REMOTE_CHANNEL_NAME   frozen
--   LobbyRequestAnswerTexts.ACCEPTED_TEXT_BY_REMOTE_CHANNEL_NAME               frozen
--   LobbyRequestAnswerTexts.GENERIC_NO_ANSWER_TEXT, .GENERIC_REFUSAL_TEXT, .WAITING_FOR_ANSWER_TEXT
--   LobbyRequestAnswerTexts.describeTooSoonOnDevice(remoteChannelName) -> string
--     "Please wait 2 seconds between tries." with the channel's own interval (§2.13).
--   LobbyRequestAnswerTexts.describeLobbyRequestOutcome(outcome?) -> string
--     outcome as DeviceLobbyRequestSender records it; "" for nil.
--   LobbyRequestAnswerTexts.describeLatestOutcomeForSubject(outcomes, requestSubject) -> string
--     Of the given outcomes (any may be nil) those for this subject, the latest tap's (highest
--     outcomeSequenceNumber) explained; "" when none is for this subject.

local DeviceLobbyRequestSender = require("./DeviceLobbyRequestSender")
local RequestChannelMinimumIntervals = require("../shared/RequestChannelMinimumIntervals")

local LobbyRequestAnswerTexts = {}

LobbyRequestAnswerTexts.GENERIC_NO_ANSWER_TEXT = "The server did not answer. Try again in a moment."
LobbyRequestAnswerTexts.GENERIC_REFUSAL_TEXT = "That didn't work right now. Try again in a moment."
LobbyRequestAnswerTexts.WAITING_FOR_ANSWER_TEXT = "Just a moment..."

local SAVE_NOT_LOADED = "Your progress is still loading. Try again in a moment."
local TOO_MANY_REQUESTS = "Slow down a little, then try again."
local FAILED_ON_SERVER = "Something went wrong on the server. Try again."

local function freezeReasonTexts(textByReason)
	textByReason.RequestFailedOnServer = textByReason.RequestFailedOnServer or FAILED_ON_SERVER
	return table.freeze(textByReason)
end

LobbyRequestAnswerTexts.REJECTION_TEXT_BY_REASON_BY_REMOTE_CHANNEL_NAME = table.freeze({
	SetLobbyOutfit = freezeReasonTexts({
		SaveDataNotLoaded = SAVE_NOT_LOADED,
		WardrobeCatalogNotReady = "The wardrobe is still loading. Try again in a moment.",
		OutfitInvalid = "That outfit can't be worn as it is. Change it and try again.",
		NotAllowedDuringRound = "You can't change your lobby outfit while you are styling or on stage.",
		TooManyRequests = TOO_MANY_REQUESTS,
	}),
	RequestPurchaseDanceWithStarCoins = freezeReasonTexts({
		UnknownDance = "That dance is not in the shop any more.",
		AlreadyOwned = "You already own that dance.",
		InsufficientStarCoins = "You don't have enough Star Coins for that dance yet.",
		SaveDataNotLoaded = SAVE_NOT_LOADED,
		TooManyRequests = TOO_MANY_REQUESTS,
	}),
	RequestPurchaseCosmeticWithStarCoins = freezeReasonTexts({
		UnknownCosmetic = "That item is not in the shop any more.",
		AlreadyOwned = "You already own that item.",
		InsufficientStarCoins = "You don't have enough Star Coins for that item yet.",
		SaveDataNotLoaded = SAVE_NOT_LOADED,
		TooManyRequests = TOO_MANY_REQUESTS,
	}),
	RequestEquipDance = freezeReasonTexts({
		DanceNotOwned = "You don't own that dance, so it can't be used on stage.",
		SaveDataNotLoaded = SAVE_NOT_LOADED,
		TooManyRequests = TOO_MANY_REQUESTS,
	}),
	RequestEquipCosmetic = freezeReasonTexts({
		CosmeticNotOwned = "You don't own that item, so it can't be equipped.",
		SaveDataNotLoaded = SAVE_NOT_LOADED,
		TooManyRequests = TOO_MANY_REQUESTS,
	}),
	RequestStartDanceInLobby = freezeReasonTexts({
		DanceNotOwned = "You don't own that dance yet.",
		NotAllowedDuringRound = "You can't start a lobby dance while you are on stage.",
		SaveDataNotLoaded = SAVE_NOT_LOADED,
		TooManyRequests = TOO_MANY_REQUESTS,
	}),
	RequestSyncDanceWithPlayer = freezeReasonTexts({
		TargetNotDancing = "That player is not dancing in the lobby right now, so there is nothing to join.",
		NotAllowedDuringRound = "You can't join a dance while you are on stage.",
		SaveDataNotLoaded = SAVE_NOT_LOADED,
		TooManyRequests = TOO_MANY_REQUESTS,
	}),
	RequestStopDanceInLobby = freezeReasonTexts({
		TooManyRequests = TOO_MANY_REQUESTS,
	}),
	RequestClaimPlaytimeMilestone = freezeReasonTexts({
		UnknownMilestone = "That playtime reward doesn't exist.",
		MilestoneNotReached = "You haven't played long enough today for that reward yet.",
		AlreadyClaimed = "You already claimed that reward today.",
		SaveDataNotLoaded = SAVE_NOT_LOADED,
		TooManyRequests = TOO_MANY_REQUESTS,
	}),
	RequestClaimDailyQuestReward = freezeReasonTexts({
		NotTodaysQuest = "That quest is not one of today's quests.",
		QuestNotCompleted = "That quest is not finished yet.",
		AlreadyClaimed = "You already claimed that quest today.",
		SaveDataNotLoaded = SAVE_NOT_LOADED,
		TooManyRequests = TOO_MANY_REQUESTS,
	}),
	RequestRedeemPromoCode = freezeReasonTexts({
		UnknownPromoCode = "That code doesn't exist. Check the spelling and try again.",
		PromoCodeNotActive = "That code is not active right now.",
		AlreadyRedeemed = "You already used that code.",
		TooManyAttempts = "Too many tries. Wait 2 seconds between attempts.",
		SaveDataNotLoaded = SAVE_NOT_LOADED,
	}),
	RequestStylingItemOwnership = freezeReasonTexts({
		UnknownStylingItem = "That item is not in the wardrobe right now.",
		OwnershipCheckFailed = "Roblox couldn't tell us right now whether you own this item.",
		TooManyRequests = TOO_MANY_REQUESTS,
	}),
})

LobbyRequestAnswerTexts.ACCEPTED_TEXT_BY_REMOTE_CHANNEL_NAME = table.freeze({
	SetLobbyOutfit = "Your lobby outfit is set.",
	RequestPurchaseDanceWithStarCoins = "Bought! It will show as yours in a moment.",
	RequestPurchaseCosmeticWithStarCoins = "Bought! It will show as yours in a moment.",
	RequestEquipDance = "Done! That dance is now your stage dance.",
	RequestEquipCosmetic = "Equipped!",
	RequestStartDanceInLobby = "Dancing!",
	RequestSyncDanceWithPlayer = "You joined their dance!",
	RequestStopDanceInLobby = "Stopped dancing.",
	RequestClaimPlaytimeMilestone = "Claimed! Your Star Coins arrive in a moment.",
	RequestClaimDailyQuestReward = "Claimed! Your Star Coins arrive in a moment.",
	RequestRedeemPromoCode = "Code accepted! Your Star Coins arrive in a moment.",
	RequestStylingItemOwnership = "",
})

function LobbyRequestAnswerTexts.describeTooSoonOnDevice(remoteChannelName: string): string
	local intervalSeconds = RequestChannelMinimumIntervals.readMinimumRequestIntervalSeconds(remoteChannelName)
	local secondsText = if intervalSeconds == 1
		then "1 second"
		else string.format("%s seconds", tostring(intervalSeconds))
	return string.format("Please wait %s between tries.", secondsText)
end

function LobbyRequestAnswerTexts.describeLobbyRequestOutcome(outcome): string
	if outcome == nil then
		return ""
	end
	if outcome.isWaitingForAnswer then
		return LobbyRequestAnswerTexts.WAITING_FOR_ANSWER_TEXT
	end
	local answer = outcome.answer
	if type(answer) ~= "table" then
		return LobbyRequestAnswerTexts.GENERIC_NO_ANSWER_TEXT
	end
	if answer.isAccepted == true then
		return LobbyRequestAnswerTexts.ACCEPTED_TEXT_BY_REMOTE_CHANNEL_NAME[outcome.remoteChannelName] or ""
	end
	if answer.rejectionReason == DeviceLobbyRequestSender.TOO_SOON_ON_DEVICE_REASON then
		return LobbyRequestAnswerTexts.describeTooSoonOnDevice(outcome.remoteChannelName)
	end
	local textByReason =
		LobbyRequestAnswerTexts.REJECTION_TEXT_BY_REASON_BY_REMOTE_CHANNEL_NAME[outcome.remoteChannelName]
	local reasonText = if textByReason ~= nil then textByReason[answer.rejectionReason] else nil
	return reasonText or LobbyRequestAnswerTexts.GENERIC_REFUSAL_TEXT
end

function LobbyRequestAnswerTexts.describeLatestOutcomeForSubject(outcomes: { any }, requestSubject: any): string
	local latestOutcome = nil
	for outcomePosition = 1, #outcomes do
		local outcome = outcomes[outcomePosition]
		local isForSubject = outcome ~= nil and outcome.requestSubject == requestSubject
		if
			isForSubject
			and (latestOutcome == nil or outcome.outcomeSequenceNumber > latestOutcome.outcomeSequenceNumber)
		then
			latestOutcome = outcome
		end
	end
	return LobbyRequestAnswerTexts.describeLobbyRequestOutcome(latestOutcome)
end

return table.freeze(LobbyRequestAnswerTexts)
