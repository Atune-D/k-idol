-- Counts `playtimeSecondsToday` (development spec §2.9: "counted by the server while the player is
-- connected") for every player whose save is loaded, and writes it into the in-memory save. Part
-- of DailyProgressTracker (split out for length); its public API and the reasoning behind the
-- write cadence are documented in DailyProgressTracker.luau.
--
-- Per player it remembers one moment, `playtimeRecordedUpToUnixSeconds`: every second after it is
-- counted but not yet in the save. Counted seconds that fall before today's UTC midnight belong to
-- a day whose progress is gone, so they are never added to the new day.
--
-- Calls no Roblox-specific interface.

local DailyProgressDayBoundary = require("./DailyProgressDayBoundary")
local PlayerSaveDataKeeper = require("./PlayerSaveDataKeeper")

local DailyPlaytimePerPlayerRecorder = {}
DailyPlaytimePerPlayerRecorder.__index = DailyPlaytimePerPlayerRecorder

-- Playtime is written into the in-memory save each time it reaches a whole minute (milestones are
-- whole minutes), and at every UTC midnight.
DailyPlaytimePerPlayerRecorder.SECONDS_PER_PLAYTIME_MINUTE = 60
-- A recording is never scheduled sooner than this after the previous one, so a fractional clock
-- reading just below a whole minute cannot cause a burst of tiny recordings.
DailyPlaytimePerPlayerRecorder.MINIMUM_SECONDS_BETWEEN_SCHEDULED_RECORDINGS = 1

DailyPlaytimePerPlayerRecorder.PLAYTIME_RECORDING_CHANGE_DESCRIPTION = "record counted daily playtime"

type PlaytimeCountingState = {
	playtimeRecordedUpToUnixSeconds: number,
	cancelNextScheduledRecording: (() -> ())?,
}

function DailyPlaytimePerPlayerRecorder.new(recorderDependencies)
	return setmetatable({
		playerSaveDataKeeper = recorderDependencies.playerSaveDataKeeper,
		clock = recorderDependencies.clock,
		scheduler = recorderDependencies.scheduler,
		logger = recorderDependencies.logger,
		playtimeCountingStateByPlayerUserId = {} :: { [number]: PlaytimeCountingState },
	}, DailyPlaytimePerPlayerRecorder)
end

local function readCurrentUnixSeconds(self): number
	return self.clock:getCurrentUnixSeconds()
end

-- Seconds counted for the player since the last recording that belong to today's UTC day.
-- 0 for a player who is not being counted, and when the clock reads earlier than the last recording.
function DailyPlaytimePerPlayerRecorder:calculateUnrecordedPlaytimeSecondsToday(
	playerUserId: number,
	currentUnixSeconds: number
): number
	local playtimeCountingState = self.playtimeCountingStateByPlayerUserId[playerUserId]
	if playtimeCountingState == nil then
		return 0
	end
	local countingStartedTodayAtUnixSeconds = math.max(
		playtimeCountingState.playtimeRecordedUpToUnixSeconds,
		DailyProgressDayBoundary.calculateStartOfUtcDayUnixSeconds(currentUnixSeconds)
	)
	return math.max(0, currentUnixSeconds - countingStartedTodayAtUnixSeconds)
end

-- Adds the player's unrecorded playtime of today to `saveDataDraft`, whose dailyProgress must
-- already be today's (DailyProgressDayBoundary). Does not mark it recorded: call
-- markPlaytimeRecordedUpTo once the change holding the draft has been applied.
function DailyPlaytimePerPlayerRecorder:addUnrecordedPlaytimeToDraft(
	saveDataDraft: any,
	unrecordedPlaytimeSecondsToday: number
)
	saveDataDraft.dailyProgress.playtimeSecondsToday += unrecordedPlaytimeSecondsToday
end

-- Notes that every second up to `currentUnixSeconds` is now in the in-memory save. Never moves
-- the moment backwards, so a clock that jumps back cannot make seconds count twice.
function DailyPlaytimePerPlayerRecorder:markPlaytimeRecordedUpTo(playerUserId: number, currentUnixSeconds: number)
	local playtimeCountingState = self.playtimeCountingStateByPlayerUserId[playerUserId]
	if playtimeCountingState == nil then
		return
	end
	playtimeCountingState.playtimeRecordedUpToUnixSeconds =
		math.max(playtimeCountingState.playtimeRecordedUpToUnixSeconds, currentUnixSeconds)
end

local function calculateSecondsUntilNextRecording(
	playtimeSecondsTodayAfterRecording: number?,
	currentUnixSeconds: number
)
	local secondsPerPlaytimeMinute = DailyPlaytimePerPlayerRecorder.SECONDS_PER_PLAYTIME_MINUTE
	local secondsUntilNextWholePlaytimeMinute = if playtimeSecondsTodayAfterRecording == nil
		then secondsPerPlaytimeMinute
		else secondsPerPlaytimeMinute - playtimeSecondsTodayAfterRecording % secondsPerPlaytimeMinute
	return math.min(
		math.max(
			secondsUntilNextWholePlaytimeMinute,
			DailyPlaytimePerPlayerRecorder.MINIMUM_SECONDS_BETWEEN_SCHEDULED_RECORDINGS
		),
		DailyProgressDayBoundary.calculateSecondsUntilNextUtcDay(currentUnixSeconds)
	)
end

local function stopCountingPlaytime(self, playerUserId: number)
	local playtimeCountingState = self.playtimeCountingStateByPlayerUserId[playerUserId]
	if playtimeCountingState == nil then
		return
	end
	self.playtimeCountingStateByPlayerUserId[playerUserId] = nil
	if playtimeCountingState.cancelNextScheduledRecording ~= nil then
		playtimeCountingState.cancelNextScheduledRecording()
	end
end

-- One "AppearanceChangeSavedLater" change: applies the day boundary and adds the unrecorded
-- playtime. Returns today's playtime after the change, or nil when nothing could be recorded.
local function recordUnrecordedPlaytimeIntoSave(self, playerUserId: number): number?
	local currentUnixSeconds = readCurrentUnixSeconds(self)
	local unrecordedPlaytimeSecondsToday =
		self:calculateUnrecordedPlaytimeSecondsToday(playerUserId, currentUnixSeconds)
	local playtimeSecondsTodayAfterRecording: number? = nil
	local didApplyChange, changeResultOrError = pcall(function()
		return self.playerSaveDataKeeper:applyChangeToPlayerSaveData(
			playerUserId,
			PlayerSaveDataKeeper.APPEARANCE_CHANGE_SAVED_LATER,
			DailyPlaytimePerPlayerRecorder.PLAYTIME_RECORDING_CHANGE_DESCRIPTION,
			function(saveDataDraft)
				DailyProgressDayBoundary.replaceDailyProgressIfStaleOrMalformedAndLogRepair(
					saveDataDraft,
					currentUnixSeconds,
					self.logger,
					"player " .. tostring(playerUserId)
				)
				self:addUnrecordedPlaytimeToDraft(saveDataDraft, unrecordedPlaytimeSecondsToday)
				playtimeSecondsTodayAfterRecording = saveDataDraft.dailyProgress.playtimeSecondsToday
				return true
			end
		)
	end)
	if not didApplyChange then
		self.logger:logWarning(
			string.format(
				"DailyProgressTracker: recording playtime for player %d raised: %s",
				playerUserId,
				tostring(changeResultOrError)
			)
		)
		return nil
	end
	if changeResultOrError.changeOutcome == "SaveDataNotLoaded" then
		self.logger:logWarning(
			string.format(
				"DailyProgressTracker: %.3f s of playtime of player %d not recorded: save data not loaded",
				unrecordedPlaytimeSecondsToday,
				playerUserId
			)
		)
		stopCountingPlaytime(self, playerUserId)
		return nil
	end
	self:markPlaytimeRecordedUpTo(playerUserId, currentUnixSeconds)
	return playtimeSecondsTodayAfterRecording
end

local function scheduleNextRecording(self, playerUserId: number, playtimeSecondsTodayAfterRecording: number?)
	local playtimeCountingState = self.playtimeCountingStateByPlayerUserId[playerUserId]
	if playtimeCountingState == nil then
		return
	end
	local secondsUntilNextRecording =
		calculateSecondsUntilNextRecording(playtimeSecondsTodayAfterRecording, readCurrentUnixSeconds(self))
	playtimeCountingState.cancelNextScheduledRecording = self.scheduler:scheduleCallbackAfterSeconds(
		secondsUntilNextRecording,
		function()
			-- Stopping counting cancels this callback, so it only runs while the player is counted.
			playtimeCountingState.cancelNextScheduledRecording = nil
			scheduleNextRecording(self, playerUserId, recordUnrecordedPlaytimeIntoSave(self, playerUserId))
		end
	)
end

-- Starts counting from now. The first recording runs at once, so a stale or malformed
-- dailyProgress is repaired as soon as the save has loaded.
function DailyPlaytimePerPlayerRecorder:startCountingPlaytime(playerUserId: number)
	stopCountingPlaytime(self, playerUserId)
	self.playtimeCountingStateByPlayerUserId[playerUserId] = {
		playtimeRecordedUpToUnixSeconds = readCurrentUnixSeconds(self),
		cancelNextScheduledRecording = nil,
	}
	scheduleNextRecording(self, playerUserId, recordUnrecordedPlaytimeIntoSave(self, playerUserId))
end

-- Records what was counted, then stops counting the player.
function DailyPlaytimePerPlayerRecorder:recordPlaytimeAndStopCounting(playerUserId: number)
	if self.playtimeCountingStateByPlayerUserId[playerUserId] == nil then
		return
	end
	recordUnrecordedPlaytimeIntoSave(self, playerUserId)
	stopCountingPlaytime(self, playerUserId)
end

-- Stops counting without recording (the keeper already forgot the player's save).
function DailyPlaytimePerPlayerRecorder:stopCountingPlaytimeWithoutRecording(playerUserId: number)
	stopCountingPlaytime(self, playerUserId)
end

-- recordPlaytimeAndStopCounting for every counted player. Luau allows removing the visited entry
-- while traversing a table, which is all stopping a player does to the map.
function DailyPlaytimePerPlayerRecorder:recordPlaytimeOfEveryCountedPlayerAndStopCounting()
	for countedPlayerUserId in self.playtimeCountingStateByPlayerUserId do
		self:recordPlaytimeAndStopCounting(countedPlayerUserId)
	end
end

return DailyPlaytimePerPlayerRecorder
