-- DailyProgressTracker (development spec v1.3 §1.8, §2.9, §3.3): the server's daily content.
-- Counts each player's playtime today, answers the two daily claim requests, writes daily quest
-- progress inside round rewards, and says which three quests are today's.
--
-- Calls no Roblox-specific interface. Everything external is injected (see `new`). Split for
-- length into DailyPlaytimePerPlayerRecorder (playtime counting), DailyProgressDayBoundary (the
-- UTC day reset and malformed-table repair) and DailyQuestProgressRoundRecordWriter (quest
-- progress inside a round reward); use them only through this module.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (the server wiring is written from this)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- Wiring order: create the round record writer, pass it to RewardLedger.new in
-- `themedRoundCompletionRecordWriters`, then create the tracker with that ledger and call
-- `startTrackingDailyProgress` before any player's save can load.
--
-- DailyProgressTracker.createDailyQuestProgressRoundRecordWriter(writerDependencies)
--     -> ThemedRoundCompletionRecordWriter   (= function(saveDataDraft, themedRoundCompletion))
--   writerDependencies = {
--     clock: { getCurrentUnixSeconds: (self) -> number },
--     stylingItemByStylingItemKey: StylingItemLookup.StylingItemByStylingItemKey  (the whole pool),
--     dailyQuestCatalogEntries: { DailyQuest },   -- normally DailyQuestCatalog.DAILY_QUESTS
--     logger: { logInformation: (self, message) -> (), logWarning: (self, message) -> () },
--   }
--   Raises when a dependency is missing or the catalog cannot fill a day (fewer than 3 quests,
--   a repeated id, an entry that is not a table). The catalog list and its entries are copied.
--   The writer runs INSIDE RewardLedger's round-reward change (spec §3.3 row "Round reward"):
--   it applies the day boundary (below), turns `scoredOutfitStylingItemKeys` into primary colour
--   tags through `stylingItemByStylingItemKey`, and stores in `dailyQuestProgressCountByQuestId`
--   what DailyQuestProgressFromRatedRound decides for today's quests. It never raises for a
--   round the referee can produce, never yields, and never touches `starCoinBalance` or
--   `fanCount`. A scored key the pool does not know counts for no colour quest (logged); if no
--   key is known, or the rule raises anyway, that round writes no quest progress (logged) and
--   the round reward still applies.
--
-- DailyProgressTracker.new(trackerDependencies) -> tracker
--   trackerDependencies = {
--     playerSaveDataKeeper: PlayerSaveDataKeeper,
--     rewardLedger: RewardLedger,
--     playerRequestRateLimiter: PlayerRequestRateLimiter,
--     clock: { getCurrentUnixSeconds: (self) -> number },
--     scheduler: { scheduleCallbackAfterSeconds: (self, delaySeconds, callback) -> cancelCallback },
--     logger: { logInformation: (self, message) -> (), logWarning: (self, message) -> () },
--     dailyQuestCatalogEntries: { DailyQuest },   -- the same list the writer was given
--   }
--   Raises when a dependency is missing or the catalog cannot fill a day. The catalog is copied.
--
-- tracker:startTrackingDailyProgress()
--   Subscribes to the keeper's "loaded" and "session ended" events. Calling it twice raises.
--   From each player's load until they leave, playtime is counted (see "Playtime" below). A
--   "session ended" event stops the counting only when the keeper no longer has a loaded save for
--   that player: the end of an OLDER session of a player who already rejoined this server (its
--   final save was still finishing) leaves the newer session's counting running.
--   EVENT ORDER AT LOAD: the tracker's "loaded" listener records playtime at once, and when that
--   changes the save (a malformed table repaired, or a new UTC day begun between the keeper's load
--   decision and its completion) the keeper fires "in-memory save changed" with the repaired save
--   INSIDE the "loaded" dispatch. A listener subscribed after the tracker therefore receives the
--   change BEFORE the "loaded" event, whose copy is then already out of date. The §2.6 snapshot
--   sender must build its first snapshot from keeper:readPlayerSaveDataCopy (not from the
--   "loaded" copy), or subscribe before startTrackingDailyProgress is called.
--
-- tracker:recordCountedPlaytimeAndStopCountingBeforeFinalSave(playerUserId)
--   Call when a player leaves, IMMEDIATELY BEFORE keeper:startFinalSaveForLeavingPlayer, so the
--   final save holds every counted second. Stops counting that player at once (nothing more is
--   counted or scheduled for them, even if no final save follows). Does nothing for a player who
--   is not being counted.
-- tracker:recordCountedPlaytimeOfEveryPlayerAndStopCountingBeforeShutdown()
--   Call IMMEDIATELY BEFORE keeper:startFinalSavesForServerShutdown. Same, for every player.
--
-- tracker:answerClaimPlaytimeMilestoneRequest(playerUserId, untrustedMilestoneMinutes) -> answer
-- tracker:answerClaimDailyQuestRewardRequest(playerUserId, untrustedDailyQuestId) -> answer
--   The two §2.9 requests. `playerUserId` comes from the server; the second argument comes from
--   the device and may be any Luau value. Checks, in order:
--     1. playerRequestRateLimiter:admitOrRefusePlayerRequest(playerUserId, <the request's channel
--        name>); on refusal the answer carries the limiter's reason ("TooManyRequests") and
--        nothing else is looked at.
--     2. The save has not loaded (or the player is leaving): "SaveDataNotLoaded".
--     3. A value that is not exactly a defined milestone (a number equal to one of 5, 10, 20, 30,
--        45, 60) answers "UnknownMilestone"; a value that is not exactly the id string of one of
--        today's three quests answers "NotTodaysQuest". The untrusted value is never logged,
--        echoed, used as a table key or used for anything else.
--     4. ONE RewardLedger grant (rewardSourceKind "PlaytimeMilestone" / "DailyQuest") whose
--        eligibility check is DailyRewardClaimEligibility, evaluated on the save inside that
--        change after the day boundary (and, for a milestone, with the playtime counted so far
--        but not yet recorded), and whose record adds the milestone to
--        `claimedPlaytimeMilestoneMinutes` / the quest to `claimedDailyQuestIds` (a milestone
--        claim also records the counted playtime). Refusals: "MilestoneNotReached" /
--        "QuestNotCompleted", then "AlreadyClaimed".
--   Answers (a new table every time):
--     { isAccepted = true, starCoinsGranted = number }
--     { isAccepted = false, rejectionReason = "TooManyRequests" | "SaveDataNotLoaded"
--         | "UnknownMilestone" | "MilestoneNotReached" | "AlreadyClaimed" }          (milestone)
--     { isAccepted = false, rejectionReason = "TooManyRequests" | "SaveDataNotLoaded"
--         | "NotTodaysQuest" | "QuestNotCompleted" | "AlreadyClaimed" }              (quest)
--   An accepted claim is a "ProgressChangeSavedAtOnce" (the ledger's): a save is requested.
--
-- tracker:readTodaysDailyQuestIds() -> { string }
--   The ids of today's three quests (UTC day of the clock), for `todaysDailyQuestIds` in the
--   §2.6 snapshot. The same for every player, so it takes no player. A new frozen list per call.
--
-- Day boundary (spec §1.10). Every change this module makes, and the round record writer, first
-- makes `dailyProgress` today's: another UTC day's table is replaced by a fresh one, so playtime
-- starts at 0 and unclaimed milestones and quests of the old day are lost. A malformed table
-- (any field DailyProgressReader rejects) is replaced by a fresh one the same way and a warning
-- is logged, because the shared daily rules raise on it.
--
-- Playtime. Counted from the moment a player's save has loaded until
-- recordCountedPlaytimeAndStopCountingBeforeFinalSave (or until the keeper ends the session and no
-- newer session of that player is loaded). Counted seconds
-- reach the in-memory save through keeper:applyChangeToPlayerSaveData with kind
-- "AppearanceChangeSavedLater" (despite its name, it means "change saved later": no save is
-- requested; the next periodic, claim, reward or final save writes it), at these moments only:
--   * at load (0 s; this also repairs a stale or malformed dailyProgress at once),
--   * each time today's playtime reaches a whole minute (milestones are whole minutes, so the
--     §2.6 snapshot shows a milestone as reached when it is), and at every UTC midnight,
--   * inside an accepted milestone claim (same change as the reward),
--   * in recordCountedPlaytimeAndStopCountingBeforeFinalSave / ...BeforeShutdown.
-- So playtime never causes a save of its own (spec §3.4 spacing, §3.6 budgets); it costs one
-- in-memory change and one snapshot message per player per minute. Seconds counted before
-- today's UTC midnight are never added to the new day. A crash loses up to about 180 s of
-- playtime: the 120 s periodic save interval plus up to 60 s counted but not yet recorded (when a
-- whole-minute recording falls due in the same instant as a periodic save, the save runs first
-- and holds playtime one minute old). No reward is affected: a milestone is only reached later.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local DailyPlaytimePerPlayerRecorder = require("./DailyPlaytimePerPlayerRecorder")
local DailyProgressDayBoundary = require("./DailyProgressDayBoundary")
local DailyQuestOfTheDaySelector = require("../shared/DailyQuestOfTheDaySelector")
local DailyQuestProgressRoundRecordWriter = require("./DailyQuestProgressRoundRecordWriter")
local DailyRewardClaimEligibility = require("../shared/DailyRewardClaimEligibility")
local PlayerSaveDataSchema = require("./PlayerSaveDataSchema")
local PlaytimeMilestoneCatalog = require("../shared/PlaytimeMilestoneCatalog")
local RemoteNames = require("../shared/RemoteNames")
local RewardLedger = require("./RewardLedger")

local DailyProgressTracker = {}
DailyProgressTracker.__index = DailyProgressTracker

DailyProgressTracker.SAVE_DATA_NOT_LOADED_REJECTION_REASON = "SaveDataNotLoaded"
DailyProgressTracker.DAILY_REWARD_CLAIM_REJECTION_REASONS =
	DailyRewardClaimEligibility.DAILY_REWARD_CLAIM_REJECTION_REASONS

local CLAIM_REJECTION_REASONS = DailyRewardClaimEligibility.DAILY_REWARD_CLAIM_REJECTION_REASONS
local CLAIM_PLAYTIME_MILESTONE_CHANNEL_NAME = RemoteNames.REMOTE_CHANNEL_NAMES.RequestClaimPlaytimeMilestone
local CLAIM_DAILY_QUEST_REWARD_CHANNEL_NAME = RemoteNames.REMOTE_CHANNEL_NAMES.RequestClaimDailyQuestReward

-- ── construction ────────────────────────────────────────────────────────────────────────────

local function requireDependencies(dependencies: any, requiredDependencyNames: { string }, constructorName: string)
	if type(dependencies) ~= "table" then
		error(constructorName .. ": dependencies must be a table", 3)
	end
	for _, requiredDependencyName in requiredDependencyNames do
		if dependencies[requiredDependencyName] == nil then
			error(constructorName .. ": missing dependency " .. requiredDependencyName, 3)
		end
	end
end

-- A frozen copy of the caller's catalog (list and entries), checked to be able to fill a day.
local function copyAndCheckDailyQuestCatalogEntries(dailyQuestCatalogEntries: any, constructorName: string)
	if type(dailyQuestCatalogEntries) ~= "table" then
		error(constructorName .. ": dailyQuestCatalogEntries must be a list of daily quests", 3)
	end
	local copiedDailyQuestCatalogEntries = {}
	for _, dailyQuest in ipairs(dailyQuestCatalogEntries) do
		if type(dailyQuest) ~= "table" then
			error(constructorName .. ": every daily quest must be a table", 3)
		end
		table.insert(copiedDailyQuestCatalogEntries, table.freeze(table.clone(dailyQuest)))
	end
	table.freeze(copiedDailyQuestCatalogEntries)
	local didSelect, selectionError = pcall(
		DailyQuestOfTheDaySelector.selectDailyQuestsForDailyDateKey,
		PlayerSaveDataSchema.formatUtcDailyDateKey(0),
		copiedDailyQuestCatalogEntries
	)
	if not didSelect then
		error(constructorName .. ": the daily quest catalog cannot fill a day: " .. tostring(selectionError), 3)
	end
	return copiedDailyQuestCatalogEntries
end

function DailyProgressTracker.createDailyQuestProgressRoundRecordWriter(writerDependencies)
	local constructorName = "DailyProgressTracker.createDailyQuestProgressRoundRecordWriter"
	requireDependencies(
		writerDependencies,
		{ "clock", "stylingItemByStylingItemKey", "dailyQuestCatalogEntries", "logger" },
		constructorName
	)
	return DailyQuestProgressRoundRecordWriter.createThemedRoundCompletionRecordWriter({
		clock = writerDependencies.clock,
		stylingItemByStylingItemKey = writerDependencies.stylingItemByStylingItemKey,
		dailyQuestCatalogEntries = copyAndCheckDailyQuestCatalogEntries(
			writerDependencies.dailyQuestCatalogEntries,
			constructorName
		),
		logger = writerDependencies.logger,
	})
end

function DailyProgressTracker.new(trackerDependencies)
	requireDependencies(trackerDependencies, {
		"playerSaveDataKeeper",
		"rewardLedger",
		"playerRequestRateLimiter",
		"clock",
		"scheduler",
		"logger",
		"dailyQuestCatalogEntries",
	}, "DailyProgressTracker.new")
	return setmetatable({
		playerSaveDataKeeper = trackerDependencies.playerSaveDataKeeper,
		rewardLedger = trackerDependencies.rewardLedger,
		playerRequestRateLimiter = trackerDependencies.playerRequestRateLimiter,
		clock = trackerDependencies.clock,
		logger = trackerDependencies.logger,
		dailyQuestCatalogEntries = copyAndCheckDailyQuestCatalogEntries(
			trackerDependencies.dailyQuestCatalogEntries,
			"DailyProgressTracker.new"
		),
		dailyPlaytimePerPlayerRecorder = DailyPlaytimePerPlayerRecorder.new({
			playerSaveDataKeeper = trackerDependencies.playerSaveDataKeeper,
			clock = trackerDependencies.clock,
			scheduler = trackerDependencies.scheduler,
			logger = trackerDependencies.logger,
		}),
		hasStartedTracking = false,
	}, DailyProgressTracker)
end

-- ── tracking ────────────────────────────────────────────────────────────────────────────────

function DailyProgressTracker:startTrackingDailyProgress()
	if self.hasStartedTracking then
		error("DailyProgressTracker: startTrackingDailyProgress was already called", 2)
	end
	self.hasStartedTracking = true
	self.playerSaveDataKeeper:subscribeToPlayerSaveDataLoaded(function(playerUserId)
		self.dailyPlaytimePerPlayerRecorder:startCountingPlaytime(playerUserId)
	end)
	self.playerSaveDataKeeper:subscribeToPlayerSaveDataSessionEnded(function(playerUserId)
		-- The event names only the player. When an OLDER session of a player who already rejoined
		-- ends (its final save still finishing), the newer session is loaded and owns the counting.
		if self.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId) then
			return
		end
		self.dailyPlaytimePerPlayerRecorder:stopCountingPlaytimeWithoutRecording(playerUserId)
	end)
end

function DailyProgressTracker:recordCountedPlaytimeAndStopCountingBeforeFinalSave(playerUserId: number)
	self.dailyPlaytimePerPlayerRecorder:recordPlaytimeAndStopCounting(playerUserId)
end

function DailyProgressTracker:recordCountedPlaytimeOfEveryPlayerAndStopCountingBeforeShutdown()
	self.dailyPlaytimePerPlayerRecorder:recordPlaytimeOfEveryCountedPlayerAndStopCounting()
end

function DailyProgressTracker:readTodaysDailyQuestIds(): { string }
	return DailyQuestOfTheDaySelector.selectDailyQuestIdsForDailyDateKey(
		PlayerSaveDataSchema.formatUtcDailyDateKey(self.clock:getCurrentUnixSeconds()),
		self.dailyQuestCatalogEntries
	)
end

-- ── claim requests ──────────────────────────────────────────────────────────────────────────

local function buildRejectionAnswer(rejectionReason: string)
	return { isAccepted = false, rejectionReason = rejectionReason }
end

-- Steps 1 and 2 of both claims. Returns a rejection answer, or nil to go on.
local function rejectBeforeLookingAtRequest(self, playerUserId: number, remoteChannelName: string)
	local rateLimitDecision = self.playerRequestRateLimiter:admitOrRefusePlayerRequest(playerUserId, remoteChannelName)
	if not rateLimitDecision.isRequestAllowed then
		return buildRejectionAnswer(rateLimitDecision.rejectionReason)
	end
	if not self.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId) then
		return buildRejectionAnswer(DailyProgressTracker.SAVE_DATA_NOT_LOADED_REJECTION_REASON)
	end
	return nil
end

local function buildAnswerFromGrantOutcome(grantOutcome)
	if grantOutcome.rewardLedgerOutcome == "Granted" then
		return { isAccepted = true, starCoinsGranted = grantOutcome.starCoinsGranted }
	end
	if grantOutcome.rewardLedgerOutcome == "SaveDataNotLoaded" then
		return buildRejectionAnswer(DailyProgressTracker.SAVE_DATA_NOT_LOADED_REJECTION_REASON)
	end
	return buildRejectionAnswer(grantOutcome.declineReason)
end

-- Turns a DailyRewardClaimEligibility decision into what checkGrantEligibility returns.
local function translateClaimDecision(claimDecision): (boolean, string?)
	if not claimDecision.isClaimAllowed then
		return false, claimDecision.rejectionReason
	end
	return true
end

function DailyProgressTracker:answerClaimPlaytimeMilestoneRequest(playerUserId: number, untrustedMilestoneMinutes: any)
	local earlyRejectionAnswer = rejectBeforeLookingAtRequest(self, playerUserId, CLAIM_PLAYTIME_MILESTONE_CHANNEL_NAME)
	if earlyRejectionAnswer ~= nil then
		return earlyRejectionAnswer
	end
	-- Checked to be a number before it is used as a table key (the catalog lookup would also
	-- tolerate any value; this keeps the "never a key before it is checked" rule visible here).
	local requestedPlaytimeMilestone = if type(untrustedMilestoneMinutes) == "number"
		then PlaytimeMilestoneCatalog.findPlaytimeMilestoneByMilestoneMinutes(untrustedMilestoneMinutes)
		else nil
	if requestedPlaytimeMilestone == nil then
		return buildRejectionAnswer(CLAIM_REJECTION_REASONS.UnknownMilestone)
	end

	local milestoneMinutes = requestedPlaytimeMilestone.milestoneMinutes
	local currentUnixSeconds = self.clock:getCurrentUnixSeconds()
	local currentDailyDateKey = PlayerSaveDataSchema.formatUtcDailyDateKey(currentUnixSeconds)
	local playtimeRecorder = self.dailyPlaytimePerPlayerRecorder
	local unrecordedPlaytimeSecondsToday =
		playtimeRecorder:calculateUnrecordedPlaytimeSecondsToday(playerUserId, currentUnixSeconds)

	local grantOutcome = self.rewardLedger:grantStarCoinsAndFans(playerUserId, {
		rewardSourceKind = RewardLedger.REWARD_SOURCE_KINDS.PlaytimeMilestone,
		starCoinsToGrant = requestedPlaytimeMilestone.starCoinReward,
		fanCountToGrant = 0,
		grantDescriptionForLogs = string.format("playtime milestone %d min", milestoneMinutes),
		checkGrantEligibility = function(saveDataReadOnlyView)
			local dailyProgressAsOfNow = DailyProgressDayBoundary.copyDailyProgressAsOfNow(
				saveDataReadOnlyView.dailyProgress,
				currentUnixSeconds
			)
			dailyProgressAsOfNow.playtimeSecondsToday += unrecordedPlaytimeSecondsToday
			return translateClaimDecision(
				DailyRewardClaimEligibility.decidePlaytimeMilestoneClaim(
					dailyProgressAsOfNow,
					currentDailyDateKey,
					milestoneMinutes
				)
			)
		end,
		writeGrantRecordThatPreventsRepeat = function(saveDataDraft)
			DailyProgressDayBoundary.replaceDailyProgressIfStaleOrMalformedAndLogRepair(
				saveDataDraft,
				currentUnixSeconds,
				self.logger,
				"player " .. tostring(playerUserId)
			)
			playtimeRecorder:addUnrecordedPlaytimeToDraft(saveDataDraft, unrecordedPlaytimeSecondsToday)
			table.insert(saveDataDraft.dailyProgress.claimedPlaytimeMilestoneMinutes, milestoneMinutes)
		end,
	})
	if grantOutcome.rewardLedgerOutcome == "Granted" then
		playtimeRecorder:markPlaytimeRecordedUpTo(playerUserId, currentUnixSeconds)
	end
	return buildAnswerFromGrantOutcome(grantOutcome)
end

function DailyProgressTracker:answerClaimDailyQuestRewardRequest(playerUserId: number, untrustedDailyQuestId: any)
	local earlyRejectionAnswer = rejectBeforeLookingAtRequest(self, playerUserId, CLAIM_DAILY_QUEST_REWARD_CHANNEL_NAME)
	if earlyRejectionAnswer ~= nil then
		return earlyRejectionAnswer
	end
	local currentUnixSeconds = self.clock:getCurrentUnixSeconds()
	local currentDailyDateKey = PlayerSaveDataSchema.formatUtcDailyDateKey(currentUnixSeconds)
	-- The untrusted value is only compared with `==` to three catalog strings: a string compared
	-- with any other type is plainly false (no metamethod runs), so no type check is needed.
	local requestedDailyQuest = nil
	for _, todaysDailyQuest in
		DailyQuestOfTheDaySelector.selectDailyQuestsForDailyDateKey(currentDailyDateKey, self.dailyQuestCatalogEntries)
	do
		if todaysDailyQuest.dailyQuestId == untrustedDailyQuestId then
			requestedDailyQuest = todaysDailyQuest
		end
	end
	if requestedDailyQuest == nil then
		return buildRejectionAnswer(CLAIM_REJECTION_REASONS.NotTodaysQuest)
	end

	local dailyQuestId = requestedDailyQuest.dailyQuestId
	local grantOutcome = self.rewardLedger:grantStarCoinsAndFans(playerUserId, {
		rewardSourceKind = RewardLedger.REWARD_SOURCE_KINDS.DailyQuest,
		starCoinsToGrant = requestedDailyQuest.starCoinReward,
		fanCountToGrant = 0,
		grantDescriptionForLogs = "daily quest " .. dailyQuestId,
		checkGrantEligibility = function(saveDataReadOnlyView)
			return translateClaimDecision(
				DailyRewardClaimEligibility.decideDailyQuestRewardClaim(
					DailyProgressDayBoundary.copyDailyProgressAsOfNow(
						saveDataReadOnlyView.dailyProgress,
						currentUnixSeconds
					),
					currentDailyDateKey,
					dailyQuestId,
					self.dailyQuestCatalogEntries
				)
			)
		end,
		writeGrantRecordThatPreventsRepeat = function(saveDataDraft)
			-- The check ran on today's table as of now, so the record must land in today's table
			-- too (never in another day's table that a later recording would throw away).
			DailyProgressDayBoundary.replaceDailyProgressIfStaleOrMalformedAndLogRepair(
				saveDataDraft,
				currentUnixSeconds,
				self.logger,
				"player " .. tostring(playerUserId)
			)
			table.insert(saveDataDraft.dailyProgress.claimedDailyQuestIds, dailyQuestId)
		end,
	})
	return buildAnswerFromGrantOutcome(grantOutcome)
end

return DailyProgressTracker
