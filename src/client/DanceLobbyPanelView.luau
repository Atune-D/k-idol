-- DanceLobbyPanelView (development spec §2.8): the Dances panel of the lobby menu. It shows
-- DanceLobbyPanelModelBuilder's model: the dancing status and Stop button, one card per owned dance
-- (Dance, Use on stage) and one card per other player (Dance with them). It decides nothing; every
-- button hands its dance id or player id to a callback. Rows are rebuilt only when the model changes.
--
-- PUBLIC API
--   DanceLobbyPanelView.create(contentFrame, { onStartDance(danceId), onEquipDance(danceId),
--       onStopDance(), onSyncWithPlayer(playerUserId) }) -> view
--   view:render(dancesPanelModel)
--   Instances (for checks in a playtest): <contentFrame>.DanceList with StatusLabel, StopButton,
--   StopFeedbackLabel, Dance_<danceId>.{NameLabel, StageDanceLabel, StartButton, EquipButton,
--   FeedbackLabel}, PlayersTitle, NoOtherPlayersLabel, Player_<userId>.{NameLabel, DancingLabel,
--   SyncButton, FeedbackLabel}.
--
-- Roblox API used: see DeviceInterfaceElementFactory.

local DeviceInterfaceElementFactory = require("./DeviceInterfaceElementFactory")

local DanceLobbyPanelView = {}
DanceLobbyPanelView.__index = DanceLobbyPanelView

local COLORS = DeviceInterfaceElementFactory.COLORS
local createLabel = DeviceInterfaceElementFactory.createTextLabel
local setLabelText = DeviceInterfaceElementFactory.setLabelText

function DanceLobbyPanelView.create(contentFrame: Frame, callbacks)
	local danceList = DeviceInterfaceElementFactory.createScrollingList("DanceList", contentFrame)
	danceList.Size = UDim2.fromScale(1, 1)
	DeviceInterfaceElementFactory.createVerticalList(danceList, 8)
	return setmetatable({ danceList = danceList, callbacks = callbacks, renderedSignature = nil }, DanceLobbyPanelView)
end

local function buildSignature(model): string
	local parts = { model.loadingText, model.dancingStatusText, model.stopFeedbackText, model.noOtherPlayersText }
	for _, danceRow in model.danceRows do
		table.insert(
			parts,
			table.concat({
				danceRow.danceId,
				danceRow.stageDanceText,
				tostring(danceRow.isEquipButtonVisible),
				danceRow.startButtonText,
				danceRow.feedbackText,
			}, "|")
		)
	end
	for _, playerRow in model.playerRows do
		table.insert(
			parts,
			table.concat({
				tostring(playerRow.playerUserId),
				playerRow.playerNameText,
				playerRow.dancingText,
				playerRow.feedbackText,
			}, "|")
		)
	end
	return table.concat(parts, "\n")
end

function DanceLobbyPanelView:buildDanceCard(danceRow, layoutOrder: number)
	local callbacks = self.callbacks
	local card = DeviceInterfaceElementFactory.createItemCard("Dance_" .. danceRow.danceId, self.danceList, layoutOrder)
	createLabel("NameLabel", card, 20, 1).Text = danceRow.danceNameText
	local stageLabel = createLabel("StageDanceLabel", card, 16, 2)
	stageLabel.TextColor3 = COLORS.selectedItemBackground
	setLabelText(stageLabel, danceRow.stageDanceText)
	DeviceInterfaceElementFactory.createTextButton("StartButton", card, danceRow.startButtonText, 3, function()
		callbacks.onStartDance(danceRow.danceId)
	end)
	local equipButton = DeviceInterfaceElementFactory.createTextButton(
		"EquipButton",
		card,
		"Use on stage",
		4,
		function()
			callbacks.onEquipDance(danceRow.danceId)
		end
	)
	equipButton.Visible = danceRow.isEquipButtonVisible
	local feedbackLabel = createLabel("FeedbackLabel", card, 16, 5)
	feedbackLabel.TextColor3 = COLORS.noticeText
	setLabelText(feedbackLabel, danceRow.feedbackText)
end

function DanceLobbyPanelView:buildPlayerCard(playerRow, layoutOrder: number)
	local callbacks = self.callbacks
	local card = DeviceInterfaceElementFactory.createItemCard(
		"Player_" .. tostring(playerRow.playerUserId),
		self.danceList,
		layoutOrder
	)
	createLabel("NameLabel", card, 20, 1).Text = playerRow.playerNameText
	local dancingLabel = createLabel("DancingLabel", card, 16, 2)
	dancingLabel.TextColor3 = COLORS.mutedText
	dancingLabel.Text = playerRow.dancingText
	DeviceInterfaceElementFactory.createTextButton("SyncButton", card, "Dance with them", 3, function()
		callbacks.onSyncWithPlayer(playerRow.playerUserId)
	end)
	local feedbackLabel = createLabel("FeedbackLabel", card, 16, 4)
	feedbackLabel.TextColor3 = COLORS.noticeText
	setLabelText(feedbackLabel, playerRow.feedbackText)
end

function DanceLobbyPanelView:render(model)
	local signature = buildSignature(model)
	if signature == self.renderedSignature then
		return
	end
	self.renderedSignature = signature
	DeviceInterfaceElementFactory.destroyGuiChildren(self.danceList)
	local list = self.danceList
	if model.loadingText ~= "" then
		createLabel("LoadingLabel", list, 18, 1).Text = model.loadingText
		return
	end
	createLabel("StatusLabel", list, 20, 1).Text = model.dancingStatusText
	DeviceInterfaceElementFactory.createTextButton("StopButton", list, "Stop dancing", 2, self.callbacks.onStopDance)
	local stopFeedbackLabel = createLabel("StopFeedbackLabel", list, 16, 3)
	stopFeedbackLabel.TextColor3 = COLORS.noticeText
	setLabelText(stopFeedbackLabel, model.stopFeedbackText)
	local yourDancesTitle = createLabel("YourDancesTitle", list, 18, 4)
	yourDancesTitle.TextColor3 = COLORS.mutedText
	yourDancesTitle.Text = "Your dances"
	for rowPosition, danceRow in model.danceRows do
		self:buildDanceCard(danceRow, 10 + rowPosition)
	end
	local playersTitle = createLabel("PlayersTitle", list, 18, 100)
	playersTitle.TextColor3 = COLORS.mutedText
	playersTitle.Text = "Dance together"
	setLabelText(createLabel("NoOtherPlayersLabel", list, 16, 101), model.noOtherPlayersText)
	for rowPosition, playerRow in model.playerRows do
		self:buildPlayerCard(playerRow, 101 + rowPosition)
	end
end

return DanceLobbyPanelView
