-- The UTC day boundary of a player's `dailyProgress` (development spec §1.8, §1.10) as the daily
-- tracker applies it inside every change it makes. Part of DailyProgressTracker (split out for
-- length); its public API is documented in DailyProgressTracker.luau.
--
-- Why this exists: the shared daily rules (DailyRewardClaimEligibility,
-- DailyQuestProgressFromRatedRound) RAISE on a dailyProgress that is stale (another day) or
-- malformed, and a raise inside a round reward cancels the whole reward. So before any rule sees a
-- dailyProgress, the tracker makes it today's well-formed table:
--   * another day's table is replaced by a fresh one (spec §1.10, through
--     PlayerSaveDataSchema.replaceDailyProgressIfDailyDateKeyChanged);
--   * a malformed table (any field DailyProgressReader rejects) is replaced by a fresh one too.
--     A corrupted table cannot be trusted field by field, so it is handled like the daily reset.
--
-- Pure logic: no Roblox-specific interface is used. The current time is always passed in.

local DailyProgressReader = require("../shared/DailyProgressReader")
local PlayerSaveDataSchema = require("./PlayerSaveDataSchema")

local DailyProgressDayBoundary = {}

DailyProgressDayBoundary.SECONDS_PER_UTC_DAY = 86400

export type DailyProgressReplacement = "KeptCurrentDailyProgress" | "ReplacedForNewDay" | "ReplacedBecauseMalformed"

-- True when `dailyProgress` is well formed and belongs to `currentDailyDateKey`.
function DailyProgressDayBoundary.isDailyProgressCurrentAndWellFormed(
	dailyProgress: any,
	currentDailyDateKey: string
): boolean
	-- The reader only raises; pcall turns its verdict into a boolean. It never yields.
	return (pcall(DailyProgressReader.assertDailyProgressIsCurrentAndWellFormed, dailyProgress, currentDailyDateKey))
end

-- Makes `saveDataDraft.dailyProgress` today's well-formed table, replacing it with a fresh one when
-- it is another day's or malformed. Mutates `saveDataDraft`; says what it did.
function DailyProgressDayBoundary.replaceDailyProgressIfStaleOrMalformed(
	saveDataDraft: any,
	currentUnixSeconds: number
): DailyProgressReplacement
	local currentDailyDateKey = PlayerSaveDataSchema.formatUtcDailyDateKey(currentUnixSeconds)
	local storedDailyProgress = saveDataDraft.dailyProgress
	if DailyProgressDayBoundary.isDailyProgressCurrentAndWellFormed(storedDailyProgress, currentDailyDateKey) then
		return "KeptCurrentDailyProgress"
	end
	local isWellFormedTableOfAnotherDay = type(storedDailyProgress) == "table"
		and DailyProgressDayBoundary.isDailyProgressCurrentAndWellFormed(
			storedDailyProgress,
			storedDailyProgress.dailyDateKey
		)
	if isWellFormedTableOfAnotherDay then
		PlayerSaveDataSchema.replaceDailyProgressIfDailyDateKeyChanged(saveDataDraft, currentUnixSeconds)
		return "ReplacedForNewDay"
	end
	saveDataDraft.dailyProgress = PlayerSaveDataSchema.createFreshDailyProgress(currentDailyDateKey)
	return "ReplacedBecauseMalformed"
end

-- replaceDailyProgressIfStaleOrMalformed, plus one warning line when a malformed table had to be
-- replaced (a normal new day is not worth a warning). `saveOwnerDescriptionForLogs` says whose
-- save it is, e.g. "player 8801" or "the save rewarded for round r-7".
function DailyProgressDayBoundary.replaceDailyProgressIfStaleOrMalformedAndLogRepair(
	saveDataDraft: any,
	currentUnixSeconds: number,
	logger: {
		logWarning: (any, string) -> (),
	},
	saveOwnerDescriptionForLogs: string
): DailyProgressReplacement
	local dailyProgressReplacement =
		DailyProgressDayBoundary.replaceDailyProgressIfStaleOrMalformed(saveDataDraft, currentUnixSeconds)
	if dailyProgressReplacement == "ReplacedBecauseMalformed" then
		logger:logWarning(
			string.format(
				"DailyProgressTracker: the malformed dailyProgress of %s was replaced by a fresh one",
				saveOwnerDescriptionForLogs
			)
		)
	end
	return dailyProgressReplacement
end

-- A private, editable copy of today's dailyProgress as the save would hold it after
-- replaceDailyProgressIfStaleOrMalformed. `storedDailyProgress` (often a frozen read-only view) is
-- never changed.
function DailyProgressDayBoundary.copyDailyProgressAsOfNow(storedDailyProgress: any, currentUnixSeconds: number)
	local currentDailyDateKey = PlayerSaveDataSchema.formatUtcDailyDateKey(currentUnixSeconds)
	if DailyProgressDayBoundary.isDailyProgressCurrentAndWellFormed(storedDailyProgress, currentDailyDateKey) then
		return PlayerSaveDataSchema.createDeepCopyOfPlainTable(storedDailyProgress)
	end
	return PlayerSaveDataSchema.createFreshDailyProgress(currentDailyDateKey)
end

-- The Unix time at which the UTC day containing `currentUnixSeconds` began.
function DailyProgressDayBoundary.calculateStartOfUtcDayUnixSeconds(currentUnixSeconds: number): number
	return math.floor(currentUnixSeconds / DailyProgressDayBoundary.SECONDS_PER_UTC_DAY)
		* DailyProgressDayBoundary.SECONDS_PER_UTC_DAY
end

-- Seconds from `currentUnixSeconds` to the next UTC midnight; always above 0.
function DailyProgressDayBoundary.calculateSecondsUntilNextUtcDay(currentUnixSeconds: number): number
	return DailyProgressDayBoundary.calculateStartOfUtcDayUnixSeconds(currentUnixSeconds)
		+ DailyProgressDayBoundary.SECONDS_PER_UTC_DAY
		- currentUnixSeconds
end

return table.freeze(DailyProgressDayBoundary)
