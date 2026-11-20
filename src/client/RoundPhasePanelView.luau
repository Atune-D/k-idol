-- RoundPhasePanelView: the centre panel of the round screens (ThemeReveal, Styling, Showcase,
-- Results, Intermission). It shows ThemedRoundScreenModelBuilder's model: the phase title, the theme,
-- the round bonus rule, the countdown, the phase notice, the join button and its message, and the
-- results rows. It decides nothing.
--
-- PUBLIC API
--   RoundPhasePanelView.create(screenGui, onJoinButtonActivated) -> view
--   view:render(screenModel)
--   Instances (for checks in a playtest): <screenGui>.RoundPhasePanel with PhaseTitleLabel,
--   ThemeNameLabel, RoundBonusRuleLabel, CountdownLabel, PhaseNoticeLabel, JoinButton,
--   JoinMessageLabel, ResultsList.Row1..n (each with Place/Name/Score/Components/Stars/Reward labels).
--   The panel's attribute "ScreenName" holds the screen model's screenName.
--
-- Roblox API used: see DeviceInterfaceElementFactory; Instance:SetAttribute, :Destroy, :GetChildren,
--   :IsA  https://create.roblox.com/docs/reference/engine/classes/Instance

local DeviceInterfaceElementFactory = require("./DeviceInterfaceElementFactory")

local RoundPhasePanelView = {}
RoundPhasePanelView.__index = RoundPhasePanelView

local COLORS = DeviceInterfaceElementFactory.COLORS
local RESULT_ROW_LABEL_NAMES = table.freeze({
	"placeText",
	"playerNameText",
	"scoreText",
	"componentsText",
	"starsText",
	"rewardText",
})

function RoundPhasePanelView.create(screenGui: ScreenGui, onJoinButtonActivated: () -> ())
	local panel = DeviceInterfaceElementFactory.createPanel("RoundPhasePanel", screenGui)
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.new(0.5, 0, 0, 130)
	panel.Size = UDim2.fromScale(0.34, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	DeviceInterfaceElementFactory.createVerticalList(panel, 6)
	local create = DeviceInterfaceElementFactory.createTextLabel
	local view = setmetatable({ panel = panel }, RoundPhasePanelView)
	view.phaseTitleLabel = create("PhaseTitleLabel", panel, 24, 1)
	view.themeNameLabel = create("ThemeNameLabel", panel, 28, 2)
	view.roundBonusRuleLabel = create("RoundBonusRuleLabel", panel, 18, 3)
	view.countdownLabel = create("CountdownLabel", panel, 34, 4)
	view.phaseNoticeLabel = create("PhaseNoticeLabel", panel, 18, 5)
	view.phaseNoticeLabel.TextColor3 = COLORS.noticeText
	view.joinButton =
		DeviceInterfaceElementFactory.createTextButton("JoinButton", panel, "Join this round", 6, onJoinButtonActivated)
	view.joinMessageLabel = create("JoinMessageLabel", panel, 18, 7)
	view.resultsList = DeviceInterfaceElementFactory.createScrollingList("ResultsList", panel)
	view.resultsList.LayoutOrder = 8
	view.resultsList.Size = UDim2.new(1, 0, 0, 260)
	DeviceInterfaceElementFactory.createVerticalList(view.resultsList, 6)
	view.renderedResultsSignature = ""
	return view
end

local function setLabelText(label: TextLabel, text: string)
	label.Text = text
	label.Visible = text ~= ""
end

function RoundPhasePanelView:renderResultsRows(resultsRows)
	local signatureParts = {}
	for _, row in resultsRows do
		table.insert(signatureParts, row.playerNameText .. "|" .. row.scoreText .. "|" .. row.rewardText)
	end
	local signature = table.concat(signatureParts, "\n")
	self.resultsList.Visible = #resultsRows > 0
	if signature == self.renderedResultsSignature then
		return
	end
	self.renderedResultsSignature = signature
	for _, child in self.resultsList:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	for rowPosition, row in resultsRows do
		local rowFrame = DeviceInterfaceElementFactory.createPanel("Row" .. rowPosition, self.resultsList)
		rowFrame.Size = UDim2.new(1, -10, 0, 0)
		rowFrame.AutomaticSize = Enum.AutomaticSize.Y
		rowFrame.LayoutOrder = rowPosition
		rowFrame.BackgroundColor3 = if row.isLocalPlayer then COLORS.localPlayerRowBackground else COLORS.itemBackground
		DeviceInterfaceElementFactory.createVerticalList(rowFrame, 2)
		for labelPosition, fieldName in RESULT_ROW_LABEL_NAMES do
			local label = DeviceInterfaceElementFactory.createTextLabel(fieldName, rowFrame, 16, labelPosition)
			setLabelText(label, row[fieldName])
		end
	end
end

function RoundPhasePanelView:render(screenModel)
	self.panel:SetAttribute("ScreenName", screenModel.screenName)
	setLabelText(self.phaseTitleLabel, screenModel.phaseTitleText)
	setLabelText(self.themeNameLabel, screenModel.themeDisplayNameText)
	setLabelText(self.roundBonusRuleLabel, screenModel.roundBonusRuleText)
	setLabelText(self.countdownLabel, screenModel.countdownText)
	setLabelText(self.phaseNoticeLabel, screenModel.phaseNoticeText)
	local joinPanel = screenModel.joinPanel
	self.joinButton.Visible = joinPanel.isVisible and joinPanel.isJoinButtonVisible
	self.joinButton.Text = joinPanel.joinButtonText .. " (J)"
	DeviceInterfaceElementFactory.setButtonEnabled(self.joinButton, joinPanel.isJoinButtonEnabled)
	setLabelText(self.joinMessageLabel, if joinPanel.isVisible then joinPanel.joinMessageText else "")
	self:renderResultsRows(screenModel.resultsRows)
end

return RoundPhasePanelView
