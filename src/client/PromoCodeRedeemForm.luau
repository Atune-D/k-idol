-- PromoCodeRedeemForm (development spec §1.9, §2.10, §2.13): the promo code panel of the lobby menu: what
-- happens when the player taps Redeem, and what the panel says.
--   * The typed text is trimmed of surrounding spaces (the server trims too, §10 v1.4 §2.10). Empty
--     text is not sent: "Type a code first.".
--   * 🔴 §2.10, the 2-second rule: at most one attempt every 2 seconds
--     (src/shared/RequestChannelMinimumIntervals, counted by DeviceLobbyRequestSender from the previous
--     answer). A faster tap is not sent and is explained ("Please wait 2 seconds between tries."); the
--     server's own TooManyAttempts answer is explained too.
--   * Every answer is explained in plain words (LobbyRequestAnswerTexts): UnknownPromoCode,
--     PromoCodeNotActive, AlreadyRedeemed, TooManyAttempts, SaveDataNotLoaded, RequestFailedOnServer,
--     no answer. An accepted code says the Star Coins are on their way; the balance itself is shown
--     only from the save snapshot (§2.6). The typed text is never shown back in a message.
-- Pure logic: the request sender is injected.
--
-- PUBLIC API
--   PromoCodeRedeemForm.EMPTY_CODE_TEXT, .HINT_TEXT
--   PromoCodeRedeemForm.new({ lobbyRequestSender }) -> form
--   form:submitTypedPromoCode(typedText) -> boolean   true when a request was sent
--   form:readPromoCodePanelModel() -> { hintText, feedbackText, isWaitingForAnswer }

local LobbyRequestAnswerTexts = require("./LobbyRequestAnswerTexts")

local PromoCodeRedeemForm = {}
PromoCodeRedeemForm.__index = PromoCodeRedeemForm

PromoCodeRedeemForm.EMPTY_CODE_TEXT = "Type a code first."
PromoCodeRedeemForm.HINT_TEXT = "Got a code from our social channels? Type it here."

local PROMO_CODE_CHANNEL_NAME = "RequestRedeemPromoCode"

function PromoCodeRedeemForm.new(dependencies)
	return setmetatable({
		lobbyRequestSender = dependencies.lobbyRequestSender,
		localNoticeText = nil,
	}, PromoCodeRedeemForm)
end

function PromoCodeRedeemForm:submitTypedPromoCode(typedText: any): boolean
	local trimmedText = if type(typedText) == "string" then string.match(typedText, "^%s*(.-)%s*$") else ""
	if trimmedText == "" then
		self.localNoticeText = PromoCodeRedeemForm.EMPTY_CODE_TEXT
		return false
	end
	self.localNoticeText = nil
	return self.lobbyRequestSender:sendLobbyRequest(PROMO_CODE_CHANNEL_NAME, trimmedText, "promoCode")
end

function PromoCodeRedeemForm:readPromoCodePanelModel()
	local outcome = self.lobbyRequestSender:readLatestLobbyRequestOutcome(PROMO_CODE_CHANNEL_NAME)
	return {
		hintText = PromoCodeRedeemForm.HINT_TEXT,
		feedbackText = self.localNoticeText or LobbyRequestAnswerTexts.describeLobbyRequestOutcome(outcome),
		isWaitingForAnswer = outcome ~= nil and outcome.isWaitingForAnswer == true,
	}
end

return PromoCodeRedeemForm
