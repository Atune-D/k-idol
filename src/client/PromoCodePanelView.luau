-- PromoCodePanelView (development spec §2.10): the Codes panel of the lobby menu: a hint, one text entry
-- and a large Redeem button (Enter in the entry redeems too), and the answer in plain words. It shows
-- PromoCodeRedeemForm's model and hands the typed text to a callback; what is sent, and when, is decided
-- there (the 2-second rule).
--
-- PUBLIC API
--   PromoCodePanelView.create(contentFrame, onRedeemActivated(typedText)) -> view
--   view:render(promoCodePanelModel)
--   Instances (for checks in a playtest): <contentFrame>.PromoCodeForm with HintLabel, CodeTextBox,
--   RedeemButton, FeedbackLabel.
--
-- Roblox API used: see DeviceInterfaceElementFactory; TextBox.Text and TextBox.FocusLost(enterPressed,
--   inputThatCausedFocusLoss)   https://create.roblox.com/docs/reference/engine/classes/TextBox

local DeviceInterfaceElementFactory = require("./DeviceInterfaceElementFactory")

local PromoCodePanelView = {}
PromoCodePanelView.__index = PromoCodePanelView

local COLORS = DeviceInterfaceElementFactory.COLORS

function PromoCodePanelView.create(contentFrame: Frame, onRedeemActivated: (string) -> ())
	local form = DeviceInterfaceElementFactory.createRowContainer("PromoCodeForm", contentFrame, 1, 10)
	form.Size = UDim2.fromScale(1, 0)
	local hintLabel = DeviceInterfaceElementFactory.createTextLabel("HintLabel", form, 18, 1)
	local codeTextBox = DeviceInterfaceElementFactory.createTextBox("CodeTextBox", form, "Type a code", 2)
	local redeemButton = DeviceInterfaceElementFactory.createTextButton("RedeemButton", form, "Redeem", 3, function()
		onRedeemActivated(codeTextBox.Text)
	end)
	codeTextBox.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			onRedeemActivated(codeTextBox.Text)
		end
	end)
	local feedbackLabel = DeviceInterfaceElementFactory.createTextLabel("FeedbackLabel", form, 18, 4)
	feedbackLabel.TextColor3 = COLORS.noticeText
	return setmetatable({
		hintLabel = hintLabel,
		redeemButton = redeemButton,
		feedbackLabel = feedbackLabel,
	}, PromoCodePanelView)
end

function PromoCodePanelView:render(model)
	self.hintLabel.Text = model.hintText
	self.redeemButton.Text = if model.isWaitingForAnswer then "Checking..." else "Redeem"
	DeviceInterfaceElementFactory.setLabelText(self.feedbackLabel, model.feedbackText)
end

return PromoCodePanelView
