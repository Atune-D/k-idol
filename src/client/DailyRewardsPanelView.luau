-- DailyRewardsPanelView (development spec §1.8, §2.9): the Daily panel of the lobby menu. It shows
-- DailyRewardsPanelModelBuilder's model: when the day ends, today's playtime, the six playtime
-- milestones and today's three quests, each with its state, reward, Claim button and latest answer.
-- It decides nothing: Claim hands the milestone minutes or the quest id to a callback. Rows are rebuilt
-- only when the model changes (the shown playtime changes about once a minute).
--
-- PUBLIC API
--   DailyRewardsPanelView.create(contentFrame, { onClaimPlaytimeMilestone(milestoneMinutes),
--       onClaimDailyQuestReward(dailyQuestId) }) -> view
--   view:render(dailyRewardsPanelModel)
--   Instances (for checks in a playtest): <contentFrame>.DailyList with DayEndLabel, PlaytimeLabel,
--   NewDayNoticeLabel, Milestone_<minutes>.{TitleLabel, StateLabel, ClaimButton, FeedbackLabel},
--   Quest_<dailyQuestId>.{DescriptionLabel, ProgressLabel, StateLabel, ClaimButton, FeedbackLabel}.
--
-- Roblox API used: see DeviceInterfaceElementFactory.

local DeviceInterfaceElementFactory = require("./DeviceInterfaceElementFactory")

local DailyRewardsPanelView = {}
DailyRewardsPanelView.__index = DailyRewardsPanelView

local COLORS = DeviceInterfaceElementFactory.COLORS
local createLabel = DeviceInterfaceElementFactory.createTextLabel
local setLabelText = DeviceInterfaceElementFactory.setLabelText

function DailyRewardsPanelView.create(contentFrame: Frame, callbacks)
	local dailyList = DeviceInterfaceElementFactory.createScrollingList("DailyList", contentFrame)
	dailyList.Size = UDim2.fromScale(1, 1)
	DeviceInterfaceElementFactory.createVerticalList(dailyList, 8)
	return setmetatable(
		{ dailyList = dailyList, callbacks = callbacks, renderedSignature = nil },
		DailyRewardsPanelView
	)
end

local function buildSignature(model): string
	local parts = { model.loadingText, model.dayEndText, model.playtimeText, model.newDayNoticeText }
	for _, row in model.milestoneRows do
		table.insert(
			parts,
			table.concat({ row.minutesText, row.stateText, tostring(row.isClaimButtonVisible), row.feedbackText }, "|")
		)
	end
	for _, row in model.questRows do
		table.insert(
			parts,
			table.concat({
				row.dailyQuestId,
				row.descriptionText,
				row.progressText,
				row.stateText,
				tostring(row.isClaimButtonVisible),
				row.feedbackText,
			}, "|")
		)
	end
	return table.concat(parts, "\n")
end

local function addClaimAndFeedback(card: Frame, row, onClaim: () -> ())
	local claimButton = DeviceInterfaceElementFactory.createTextButton("ClaimButton", card, "Claim", 10, onClaim)
	claimButton.Visible = row.isClaimButtonVisible
	local feedbackLabel = createLabel("FeedbackLabel", card, 16, 11)
	feedbackLabel.TextColor3 = COLORS.noticeText
	setLabelText(feedbackLabel, row.feedbackText)
end

function DailyRewardsPanelView:render(model)
	local signature = buildSignature(model)
	if signature == self.renderedSignature then
		return
	end
	self.renderedSignature = signature
	local list, callbacks = self.dailyList, self.callbacks
	DeviceInterfaceElementFactory.destroyGuiChildren(list)
	setLabelText(createLabel("LoadingLabel", list, 18, 1), model.loadingText)
	local dayEndLabel = createLabel("DayEndLabel", list, 16, 2)
	dayEndLabel.TextColor3 = COLORS.noticeText
	setLabelText(dayEndLabel, model.dayEndText)
	setLabelText(createLabel("PlaytimeLabel", list, 20, 3), model.playtimeText)
	setLabelText(createLabel("NewDayNoticeLabel", list, 18, 4), model.newDayNoticeText)
	if #model.milestoneRows > 0 then
		local title = createLabel("PlaytimeRewardsTitle", list, 18, 5)
		title.TextColor3 = COLORS.mutedText
		title.Text = "Playtime rewards"
	end
	for rowPosition, row in model.milestoneRows do
		local card =
			DeviceInterfaceElementFactory.createItemCard("Milestone_" .. row.milestoneMinutes, list, 10 + rowPosition)
		createLabel("TitleLabel", card, 18, 1).Text = row.minutesText .. "   " .. row.rewardText
		createLabel("StateLabel", card, 16, 2).Text = row.stateText
		addClaimAndFeedback(card, row, function()
			callbacks.onClaimPlaytimeMilestone(row.milestoneMinutes)
		end)
	end
	if #model.questRows > 0 then
		local title = createLabel("QuestsTitle", list, 18, 50)
		title.TextColor3 = COLORS.mutedText
		title.Text = "Today's quests"
	end
	for rowPosition, row in model.questRows do
		local card = DeviceInterfaceElementFactory.createItemCard("Quest_" .. row.dailyQuestId, list, 50 + rowPosition)
		createLabel("DescriptionLabel", card, 18, 1).Text = row.descriptionText
		createLabel("ProgressLabel", card, 16, 2).Text = string.format("%s   %s", row.progressText, row.rewardText)
		setLabelText(createLabel("StateLabel", card, 16, 3), row.stateText)
		addClaimAndFeedback(card, row, function()
			callbacks.onClaimDailyQuestReward(row.dailyQuestId)
		end)
	end
end

return DailyRewardsPanelView
