-- DailyRewardsPanelModelBuilder (development spec §1.8, §1.10, §2.9): decides what the daily rewards
-- panel of the lobby menu shows, as plain data: the six playtime milestones, today's three quests, and
-- when the day ends (UTC midnight, §1.8: unclaimed rewards are lost then).
--
-- What is reached, claimed and completed comes ONLY from the latest save snapshot's dailyProgress and
-- todaysDailyQuestIds (§2.6 🔴). The server records today's playtime into the save about once per
-- played minute (DailyProgressTracker), so between snapshots the device shows time this way:
--   * The playtime SHOWN is the snapshot's playtimeSecondsToday plus the time since that snapshot
--     arrived, but never more than PLAYTIME_ESTIMATE_LIMIT_SECONDS past it (the server sends the next
--     one within about a minute; a late snapshot never makes the estimate run away).
--   * A milestone offers "Claim" ONLY when the snapshot itself has reached it and has not claimed it.
--     When only the estimate has reached it the row says it unlocks within a minute and offers
--     nothing, so the device never offers a reward the server would refuse as MilestoneNotReached.
--   * While a claim is waiting for its answer, or was accepted and the snapshot does not show it yet,
--     its button is hidden (no second claim of the same reward).
--   * If the UTC date the device's clock gives differs from the snapshot's dailyDateKey (midnight
--     passed), nothing is claimable and the panel says a new day has started until the new snapshot.
-- Quests: in todaysDailyQuestIds order, with DailyQuestDescriptionTexts' sentence, progress "x / target"
-- (capped at the target), the reward, and "Claim" when progress has reached the target and it is not
-- claimed. A quest id this device's catalog does not know is listed without a claim button.
-- Each claim's latest answer is explained on its row (LobbyRequestAnswerTexts).
-- Pure logic: no Roblox-specific interface is used; the current time is passed in.
--
-- PUBLIC API
--   DailyRewardsPanelModelBuilder.PLAYTIME_ESTIMATE_LIMIT_SECONDS = 59
--   DailyRewardsPanelModelBuilder.formatUtcDailyDateKey(unixSeconds) -> "YYYY-MM-DD"
--   DailyRewardsPanelModelBuilder.readSecondsUntilUtcDayEnds(unixSeconds) -> number (1..86400)
--   DailyRewardsPanelModelBuilder.estimatePlaytimeSecondsToday(lobbySnapshot, snapshotReceivedAtUnixMilliseconds,
--       nowUnixMilliseconds) -> number
--   DailyRewardsPanelModelBuilder.buildDailyRewardsPanelModel(dailyInputs) -> model
--   dailyInputs = { lobbySnapshot?, snapshotReceivedAtUnixMilliseconds?, nowUnixMilliseconds,
--     playtimeMilestones, findDailyQuestByDailyQuestId(id) -> quest?, outcomeByRemoteChannelName }
--   model = { loadingText, dayEndText, playtimeText, newDayNoticeText,
--     milestoneRows = { { milestoneMinutes, minutesText, rewardText, stateText, isClaimButtonVisible, feedbackText } },
--     questRows = { { dailyQuestId, descriptionText, progressText, rewardText, stateText, isClaimButtonVisible,
--                     feedbackText } } }

local DailyQuestDescriptionTexts = require("./DailyQuestDescriptionTexts")
local LobbyRequestAnswerTexts = require("./LobbyRequestAnswerTexts")

local DailyRewardsPanelModelBuilder = {}

DailyRewardsPanelModelBuilder.PLAYTIME_ESTIMATE_LIMIT_SECONDS = 59
DailyRewardsPanelModelBuilder.LOADING_TEXT = "Loading your daily rewards..."
DailyRewardsPanelModelBuilder.NEW_DAY_NOTICE_TEXT = "A new day has started! Your new daily rewards are on their way..."

local SECONDS_PER_DAY = 86400

function DailyRewardsPanelModelBuilder.formatUtcDailyDateKey(unixSeconds: number): string
	return os.date("!%Y-%m-%d", math.floor(unixSeconds)) :: string
end

function DailyRewardsPanelModelBuilder.readSecondsUntilUtcDayEnds(unixSeconds: number): number
	return SECONDS_PER_DAY - math.floor(unixSeconds) % SECONDS_PER_DAY
end

function DailyRewardsPanelModelBuilder.estimatePlaytimeSecondsToday(
	lobbySnapshot,
	snapshotReceivedAtUnixMilliseconds: number,
	nowUnixMilliseconds: number
): number
	local sinceSnapshotSeconds = math.max(0, (nowUnixMilliseconds - snapshotReceivedAtUnixMilliseconds) / 1000)
	return lobbySnapshot.dailyProgress.playtimeSecondsToday
		+ math.min(sinceSnapshotSeconds, DailyRewardsPanelModelBuilder.PLAYTIME_ESTIMATE_LIMIT_SECONDS)
end

local function describeDayEnd(nowUnixSeconds: number): string
	local secondsLeft = DailyRewardsPanelModelBuilder.readSecondsUntilUtcDayEnds(nowUnixSeconds)
	local timeText
	if secondsLeft < 60 then
		timeText = "less than a minute"
	else
		local wholeMinutes = secondsLeft // 60
		timeText = if wholeMinutes >= 60
			then string.format("%d h %d min", wholeMinutes // 60, wholeMinutes % 60)
			else string.format("%d min", wholeMinutes)
	end
	return string.format(
		"Today's rewards end in %s (midnight UTC). Rewards you have not claimed by then are lost.",
		timeText
	)
end

local function isOutcomeHidingClaim(outcome, requestSubject: any): boolean
	if outcome == nil or outcome.requestSubject ~= requestSubject then
		return false
	end
	return outcome.isWaitingForAnswer or (type(outcome.answer) == "table" and outcome.answer.isAccepted == true)
end

local function describeOutcomeFor(outcome, requestSubject: any): string
	if outcome == nil or outcome.requestSubject ~= requestSubject then
		return ""
	end
	return LobbyRequestAnswerTexts.describeLobbyRequestOutcome(outcome)
end

local function buildMilestoneRows(dailyInputs, estimatedPlaytimeSeconds: number, isNewDayPending: boolean)
	local dailyProgress = dailyInputs.lobbySnapshot.dailyProgress
	local claimOutcome = dailyInputs.outcomeByRemoteChannelName.RequestClaimPlaytimeMilestone
	local milestoneRows = {}
	for _, milestone in dailyInputs.playtimeMilestones do
		local requiredSeconds = milestone.milestoneMinutes * 60
		local isClaimed = table.find(dailyProgress.claimedPlaytimeMilestoneMinutes, milestone.milestoneMinutes) ~= nil
		local isReachedInSnapshot = dailyProgress.playtimeSecondsToday >= requiredSeconds
		local stateText, isClaimable = "", false
		if isNewDayPending then
			stateText = "Waiting for today's update..."
		elseif isClaimed then
			stateText = "Claimed"
		elseif isReachedInSnapshot then
			stateText, isClaimable = "Ready to claim!", true
		elseif estimatedPlaytimeSeconds >= requiredSeconds then
			stateText = "Unlocks within a minute..."
		else
			local minutesLeft = math.ceil((requiredSeconds - estimatedPlaytimeSeconds) / 60)
			stateText = string.format("In about %d min", minutesLeft)
		end
		table.insert(milestoneRows, {
			milestoneMinutes = milestone.milestoneMinutes,
			minutesText = string.format("%d min of play", milestone.milestoneMinutes),
			rewardText = string.format("+%d Star Coins", milestone.starCoinReward),
			stateText = stateText,
			isClaimButtonVisible = isClaimable and not isOutcomeHidingClaim(claimOutcome, milestone.milestoneMinutes),
			feedbackText = describeOutcomeFor(claimOutcome, milestone.milestoneMinutes),
		})
	end
	return milestoneRows
end

local function buildQuestRows(dailyInputs, isNewDayPending: boolean)
	local lobbySnapshot = dailyInputs.lobbySnapshot
	local dailyProgress = lobbySnapshot.dailyProgress
	local claimOutcome = dailyInputs.outcomeByRemoteChannelName.RequestClaimDailyQuestReward
	local questRows = {}
	for _, dailyQuestId in lobbySnapshot.todaysDailyQuestIds do
		local dailyQuest = dailyInputs.findDailyQuestByDailyQuestId(dailyQuestId)
		local progressCount = dailyProgress.dailyQuestProgressCountByQuestId[dailyQuestId] or 0
		local isClaimed = table.find(dailyProgress.claimedDailyQuestIds, dailyQuestId) ~= nil
		local questRow = {
			dailyQuestId = dailyQuestId,
			descriptionText = "A new quest this version of the game can't show yet.",
			progressText = string.format("%d done", progressCount),
			rewardText = "",
			stateText = if isClaimed then "Claimed" else "",
			isClaimButtonVisible = false,
			feedbackText = describeOutcomeFor(claimOutcome, dailyQuestId),
		}
		if dailyQuest ~= nil then
			local isComplete = progressCount >= dailyQuest.targetCount
			questRow.descriptionText = DailyQuestDescriptionTexts.describeDailyQuest(dailyQuest)
			questRow.progressText =
				string.format("%d / %d", math.min(progressCount, dailyQuest.targetCount), dailyQuest.targetCount)
			questRow.rewardText = string.format("+%d Star Coins", dailyQuest.starCoinReward)
			if isNewDayPending then
				questRow.stateText = "Waiting for today's update..."
			elseif not isClaimed then
				questRow.stateText = if isComplete then "Complete! Claim your reward." else "In progress"
				questRow.isClaimButtonVisible = isComplete and not isOutcomeHidingClaim(claimOutcome, dailyQuestId)
			end
		end
		table.insert(questRows, questRow)
	end
	return questRows
end

function DailyRewardsPanelModelBuilder.buildDailyRewardsPanelModel(dailyInputs)
	local nowUnixSeconds = dailyInputs.nowUnixMilliseconds / 1000
	local model = {
		loadingText = "",
		dayEndText = describeDayEnd(nowUnixSeconds),
		playtimeText = "",
		newDayNoticeText = "",
		milestoneRows = {},
		questRows = {},
	}
	local lobbySnapshot = dailyInputs.lobbySnapshot
	if lobbySnapshot == nil or dailyInputs.snapshotReceivedAtUnixMilliseconds == nil then
		model.loadingText = DailyRewardsPanelModelBuilder.LOADING_TEXT
		return model
	end
	local isNewDayPending = DailyRewardsPanelModelBuilder.formatUtcDailyDateKey(nowUnixSeconds)
		~= lobbySnapshot.dailyProgress.dailyDateKey
	local estimatedPlaytimeSeconds = DailyRewardsPanelModelBuilder.estimatePlaytimeSecondsToday(
		lobbySnapshot,
		dailyInputs.snapshotReceivedAtUnixMilliseconds,
		dailyInputs.nowUnixMilliseconds
	)
	if isNewDayPending then
		model.newDayNoticeText = DailyRewardsPanelModelBuilder.NEW_DAY_NOTICE_TEXT
	else
		model.playtimeText = string.format("Played today: %d min", math.floor(estimatedPlaytimeSeconds / 60))
	end
	model.milestoneRows = buildMilestoneRows(dailyInputs, estimatedPlaytimeSeconds, isNewDayPending)
	model.questRows = buildQuestRows(dailyInputs, isNewDayPending)
	return model
end

return table.freeze(DailyRewardsPanelModelBuilder)
