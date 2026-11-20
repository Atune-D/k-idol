-- The daily rewards panel (§1.8, §2.9): milestones and quests only from the snapshot, the time shown
-- between snapshots, never a claim the server would refuse, the day end, and quest texts.

local UnitTestFramework = require("../Support/UnitTestFramework")
local LobbyTestFixtures = require("./LobbyTestFixtures")
local DailyQuestCatalog = require("../../src/shared/DailyQuestCatalog")
local DailyQuestDescriptionTexts = require("../../src/client/DailyQuestDescriptionTexts")
local DailyRewardsPanelModelBuilder = require("../../src/client/DailyRewardsPanelModelBuilder")
local LobbySaveDataSnapshotReader = require("../../src/client/LobbySaveDataSnapshotReader")
local PlaytimeMilestoneCatalog = require("../../src/shared/PlaytimeMilestoneCatalog")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local START_MS = LobbyTestFixtures.START_UNIX_SECONDS * 1000

local function buildModel(snapshotOverrides, secondsSinceSnapshot, outcomes, snapshotReceivedAtMs)
	return DailyRewardsPanelModelBuilder.buildDailyRewardsPanelModel({
		lobbySnapshot = LobbySaveDataSnapshotReader.readLobbySaveDataSnapshot(
			LobbyTestFixtures.buildSnapshotMessage(snapshotOverrides)
		),
		snapshotReceivedAtUnixMilliseconds = snapshotReceivedAtMs or START_MS,
		nowUnixMilliseconds = (snapshotReceivedAtMs or START_MS) + (secondsSinceSnapshot or 0) * 1000,
		playtimeMilestones = PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES,
		findDailyQuestByDailyQuestId = DailyQuestCatalog.findDailyQuestByDailyQuestId,
		outcomeByRemoteChannelName = outcomes or {},
	})
end

describe("DailyRewardsPanelModelBuilder: playtime milestones", function()
	it("lists the six milestones with their rewards", function()
		local model = buildModel()
		expect(#model.milestoneRows).toBe(6)
		local minutes, rewards = {}, {}
		for _, milestoneRow in model.milestoneRows do
			table.insert(minutes, milestoneRow.milestoneMinutes)
			table.insert(rewards, milestoneRow.rewardText)
		end
		expect(minutes).toEqual({ 5, 10, 20, 30, 45, 60 })
		expect(rewards[1]).toBe("+20 Star Coins")
		expect(rewards[6]).toBe("+150 Star Coins")
		expect(model.milestoneRows[1].minutesText).toBe("5 min of play")
	end)

	it("offers Claim only when the SNAPSHOT has reached the milestone, never on the estimate", function()
		local reached = buildModel({ dailyProgress = { playtimeSecondsToday = 300 } })
		expect(reached.milestoneRows[1].isClaimButtonVisible).toBe(true)
		expect(reached.milestoneRows[1].stateText).toBe("Ready to claim!")
		expect(reached.milestoneRows[2].isClaimButtonVisible).toBe(false)
		local estimated = buildModel({ dailyProgress = { playtimeSecondsToday = 299 } }, 30)
		expect(estimated.milestoneRows[1].isClaimButtonVisible).toBe(false)
		expect(estimated.milestoneRows[1].stateText).toBe("Unlocks within a minute...")
		local justShort = buildModel({ dailyProgress = { playtimeSecondsToday = 299.5 } })
		expect(justShort.milestoneRows[1].isClaimButtonVisible).toBe(false)
	end)

	it("moves the shown time with the clock between snapshots, at most 59 s past the snapshot", function()
		local function shownPlaytime(secondsSinceSnapshot)
			return buildModel({ dailyProgress = { playtimeSecondsToday = 240 } }, secondsSinceSnapshot).playtimeText
		end
		expect(shownPlaytime(0)).toBe("Played today: 4 min")
		expect(shownPlaytime(59)).toBe("Played today: 4 min")
		expect(shownPlaytime(60)).toBe("Played today: 4 min")
		expect(shownPlaytime(600)).toBe("Played today: 4 min")
		local early = buildModel({ dailyProgress = { playtimeSecondsToday = 250 } }, 0)
		expect(early.milestoneRows[1].stateText).toBe("In about 1 min")
		expect(early.milestoneRows[3].stateText).toBe("In about 16 min")
		local later = buildModel({ dailyProgress = { playtimeSecondsToday = 250 } }, 55)
		expect(later.milestoneRows[1].stateText).toBe("Unlocks within a minute...")
		expect(later.playtimeText).toBe("Played today: 5 min")
	end)

	it("shows a claimed milestone as claimed, without a button", function()
		local model =
			buildModel({ dailyProgress = { playtimeSecondsToday = 700, claimedPlaytimeMilestoneMinutes = { 5 } } })
		expect(model.milestoneRows[1].stateText).toBe("Claimed")
		expect(model.milestoneRows[1].isClaimButtonVisible).toBe(false)
		expect(model.milestoneRows[2].isClaimButtonVisible).toBe(true)
	end)

	it("hides the button while its claim waits or was accepted, and explains a refusal on its row", function()
		local function claimOutcome(isWaiting, answer)
			return {
				RequestClaimPlaytimeMilestone = {
					remoteChannelName = "RequestClaimPlaytimeMilestone",
					requestSubject = 5,
					isWaitingForAnswer = isWaiting,
					answer = answer,
				},
			}
		end
		local snapshot = { dailyProgress = { playtimeSecondsToday = 700 } }
		expect(buildModel(snapshot, 0, claimOutcome(true, nil)).milestoneRows[1].isClaimButtonVisible).toBe(false)
		local accepted = buildModel(snapshot, 0, claimOutcome(false, { isAccepted = true }))
		expect(accepted.milestoneRows[1].isClaimButtonVisible).toBe(false)
		expect(accepted.milestoneRows[1].feedbackText).toBe("Claimed! Your Star Coins arrive in a moment.")
		expect(accepted.milestoneRows[2].isClaimButtonVisible).toBe(true)
		local refused = buildModel(
			snapshot,
			0,
			claimOutcome(false, { isAccepted = false, rejectionReason = "MilestoneNotReached" })
		)
		expect(refused.milestoneRows[1].isClaimButtonVisible).toBe(true)
		expect(refused.milestoneRows[1].feedbackText).toBe("You haven't played long enough today for that reward yet.")
	end)
end)

describe("DailyRewardsPanelModelBuilder: numeric boundaries", function()
	it("offers Claim at exactly the milestone's seconds in the snapshot, not one second before", function()
		local atExactly = buildModel({ dailyProgress = { playtimeSecondsToday = 600 } })
		expect(atExactly.milestoneRows[2].isClaimButtonVisible).toBe(true)
		expect(atExactly.milestoneRows[2].stateText).toBe("Ready to claim!")
		local oneSecondShort = buildModel({ dailyProgress = { playtimeSecondsToday = 599 } })
		expect(oneSecondShort.milestoneRows[2].isClaimButtonVisible).toBe(false)
		expect(oneSecondShort.milestoneRows[2].stateText).toBe("In about 1 min")
	end)

	it("says 'unlocks within a minute' once the capped estimate reaches the milestone exactly", function()
		local estimateExactly = buildModel({ dailyProgress = { playtimeSecondsToday = 241 } }, 59)
		expect(estimateExactly.milestoneRows[1].stateText).toBe("Unlocks within a minute...")
		local estimateOneShort = buildModel({ dailyProgress = { playtimeSecondsToday = 240 } }, 600)
		expect(estimateOneShort.milestoneRows[1].stateText).toBe("In about 1 min")
		expect(estimateOneShort.milestoneRows[1].isClaimButtonVisible).toBe(false)
	end)

	it("completes a quest at exactly its target, not one below", function()
		local atTarget =
			buildModel({ dailyProgress = { dailyQuestProgressCountByQuestId = { complete_rounds_3 = 3 } } })
		expect(atTarget.questRows[1].progressText).toBe("3 / 3")
		expect(atTarget.questRows[1].isClaimButtonVisible).toBe(true)
		expect(atTarget.questRows[1].stateText).toBe("Complete! Claim your reward.")
		local oneBelow =
			buildModel({ dailyProgress = { dailyQuestProgressCountByQuestId = { complete_rounds_3 = 2 } } })
		expect(oneBelow.questRows[1].progressText).toBe("2 / 3")
		expect(oneBelow.questRows[1].isClaimButtonVisible).toBe(false)
		expect(oneBelow.questRows[1].stateText).toBe("In progress")
	end)

	it("switches the day-end wording at exactly one minute and exactly one hour left", function()
		local function dayEndText(secondsLeft)
			return buildModel(nil, 16 * 3600 - secondsLeft).dayEndText
		end
		expect(string.find(dayEndText(60), "end in 1 min ", 1, true) ~= nil).toBe(true)
		expect(string.find(dayEndText(59), "end in less than a minute", 1, true) ~= nil).toBe(true)
		expect(string.find(dayEndText(3600), "end in 1 h 0 min", 1, true) ~= nil).toBe(true)
		expect(string.find(dayEndText(3599), "end in 59 min", 1, true) ~= nil).toBe(true)
	end)
end)

describe("DailyRewardsPanelModelBuilder: the day", function()
	it("says when today's rewards end (UTC midnight) and that unclaimed ones are lost", function()
		-- START is 08:00:00 UTC: 16 h left.
		expect(buildModel().dayEndText).toBe(
			"Today's rewards end in 16 h 0 min (midnight UTC). Rewards you have not claimed by then are lost."
		)
		expect(DailyRewardsPanelModelBuilder.readSecondsUntilUtcDayEnds(LobbyTestFixtures.START_UNIX_SECONDS)).toBe(
			16 * 3600
		)
		local lastMinute = buildModel(nil, 16 * 3600 - 30)
		expect(string.find(lastMinute.dayEndText, "less than a minute", 1, true) ~= nil).toBe(true)
		local lastHour = buildModel(nil, 15 * 3600 + 30 * 60)
		expect(string.find(lastHour.dayEndText, "end in 30 min", 1, true) ~= nil).toBe(true)
	end)

	it("offers nothing once the device's UTC date passes the snapshot's day, until the new snapshot", function()
		local model = buildModel({ dailyProgress = { playtimeSecondsToday = 3600 } }, 16 * 3600 + 1)
		expect(model.newDayNoticeText).toBe(DailyRewardsPanelModelBuilder.NEW_DAY_NOTICE_TEXT)
		expect(model.playtimeText).toBe("")
		for _, milestoneRow in model.milestoneRows do
			expect(milestoneRow.isClaimButtonVisible).toBe(false)
		end
		expect(DailyRewardsPanelModelBuilder.formatUtcDailyDateKey(LobbyTestFixtures.START_UNIX_SECONDS + 16 * 3600)).toBe(
			"2027-01-16"
		)
	end)

	it("shows only a loading line before the first snapshot", function()
		local model = DailyRewardsPanelModelBuilder.buildDailyRewardsPanelModel({
			lobbySnapshot = nil,
			nowUnixMilliseconds = START_MS,
			playtimeMilestones = PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES,
			findDailyQuestByDailyQuestId = DailyQuestCatalog.findDailyQuestByDailyQuestId,
			outcomeByRemoteChannelName = {},
		})
		expect(model.loadingText).toBe(DailyRewardsPanelModelBuilder.LOADING_TEXT)
		expect(#model.milestoneRows).toBe(0)
	end)
end)

describe("DailyRewardsPanelModelBuilder: today's quests", function()
	it("shows the snapshot's three quests in order with text, capped progress and Claim when complete", function()
		local model = buildModel({
			dailyProgress = {
				dailyQuestProgressCountByQuestId = { complete_rounds_3 = 4, wear_pink_in_2_rated_rounds = 1 },
				claimedDailyQuestIds = {},
			},
		})
		expect(#model.questRows).toBe(3)
		expect(model.questRows[1].dailyQuestId).toBe("complete_rounds_3")
		expect(model.questRows[1].descriptionText).toBe("Finish 3 themed rounds wearing an outfit.")
		expect(model.questRows[1].progressText).toBe("3 / 3")
		expect(model.questRows[1].isClaimButtonVisible).toBe(true)
		expect(model.questRows[1].rewardText).toBe("+60 Star Coins")
		expect(model.questRows[2].descriptionText).toBe("Get 4 stars or more in 2 rounds.")
		expect(model.questRows[2].progressText).toBe("0 / 2")
		expect(model.questRows[2].isClaimButtonVisible).toBe(false)
		expect(model.questRows[3].progressText).toBe("1 / 2")
		expect(model.questRows[3].stateText).toBe("In progress")
	end)

	it("shows a claimed quest as claimed and an unknown quest id without a claim", function()
		local model = buildModel({
			todaysDailyQuestIds = { "complete_rounds_3", "quest_from_a_newer_version" },
			dailyProgress = {
				dailyQuestProgressCountByQuestId = { complete_rounds_3 = 5 },
				claimedDailyQuestIds = { "complete_rounds_3" },
			},
		})
		expect(model.questRows[1].stateText).toBe("Claimed")
		expect(model.questRows[1].isClaimButtonVisible).toBe(false)
		expect(model.questRows[2].isClaimButtonVisible).toBe(false)
		expect(model.questRows[2].progressText).toBe("0 done")
	end)
end)

describe("DailyQuestDescriptionTexts", function()
	it("derives a sentence from the kind and its numbers", function()
		local describeQuest = DailyQuestDescriptionTexts.describeDailyQuest
		expect(describeQuest({ dailyQuestKind = "CompleteRounds", targetCount = 1 })).toBe(
			"Finish 1 themed round wearing an outfit."
		)
		expect(describeQuest({ dailyQuestKind = "EarnStarsAtLeast", targetCount = 1, minimumStarCount = 5 })).toBe(
			"Get 5 stars or more in 1 round."
		)
		expect(describeQuest({ dailyQuestKind = "EarnStarsAtLeast", targetCount = 4, minimumStarCount = 1 })).toBe(
			"Get 1 star or more in 4 rounds."
		)
		expect(
			describeQuest({ dailyQuestKind = "UseColorInRatedOutfit", targetCount = 2, requiredColorTag = "light_blue" })
		).toBe("Wear something light blue in 2 rounds.")
		expect(describeQuest({ dailyQuestKind = "SomethingNew", targetCount = 2 })).toBe("Complete this quest 2 times.")
	end)

	it("gives every catalog quest a different sentence", function()
		local seenTexts = {}
		for _, dailyQuest in DailyQuestCatalog.DAILY_QUESTS do
			local text = DailyQuestDescriptionTexts.describeDailyQuest(dailyQuest)
			expect(seenTexts[text]).toBeNil()
			seenTexts[text] = true
		end
	end)
end)
