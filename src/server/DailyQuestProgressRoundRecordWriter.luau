-- Writes daily quest progress inside a round reward (development spec §3.3 row "Round reward":
-- the balance, the round record and daily quest progress are ONE change). Part of
-- DailyProgressTracker (split out for length); its public API is documented in
-- DailyProgressTracker.luau under `createDailyQuestProgressRoundRecordWriter`.
--
-- RewardLedger runs the writer inside its round-reward change, so it must never raise for a round
-- the referee can legitimately produce (a raise cancels the whole reward, Star Coins included),
-- must never yield and must never touch `starCoinBalance` or `fanCount`. So:
--   * the day boundary is applied first (a stale or malformed dailyProgress would make the shared
--     rules raise);
--   * a scored key the styling item pool lookup does not know is skipped and logged;
--   * when no primary colour tag is known at all, or the shared rule raises anyway, quest
--     progress for that round is skipped and logged: the round reward itself still applies.
--
-- Calls no Roblox-specific interface.

local DailyProgressDayBoundary = require("./DailyProgressDayBoundary")
local DailyQuestProgressFromRatedRound = require("../shared/DailyQuestProgressFromRatedRound")
local PlayerSaveDataSchema = require("./PlayerSaveDataSchema")

local DailyQuestProgressRoundRecordWriter = {}

export type RoundRecordWriterDependencies = {
	clock: { getCurrentUnixSeconds: (any) -> number },
	stylingItemByStylingItemKey: { [string]: any },
	-- Already copied and checked by DailyProgressTracker.
	dailyQuestCatalogEntries: { any },
	logger: { logInformation: (any, string) -> (), logWarning: (any, string) -> () },
}

-- The primary colour tag of every scored item the pool lookup knows, in outfit order.
local function collectScoredOutfitPrimaryColorTags(
	writerDependencies: RoundRecordWriterDependencies,
	themedRoundCompletion
)
	local scoredOutfitPrimaryColorTags = {}
	-- The keys come from the referee (strings of the scored outfit), never from a device.
	for _, scoredStylingItemKey in themedRoundCompletion.scoredOutfitStylingItemKeys do
		local scoredStylingItem = writerDependencies.stylingItemByStylingItemKey[scoredStylingItemKey]
		if scoredStylingItem ~= nil then
			table.insert(scoredOutfitPrimaryColorTags, scoredStylingItem.primaryColorTag)
		else
			writerDependencies.logger:logWarning(
				string.format(
					"DailyProgressTracker: round %s scored styling item %s, which the styling item pool does not know; "
						.. "it counts for no colour quest",
					tostring(themedRoundCompletion.roundId),
					tostring(scoredStylingItemKey)
				)
			)
		end
	end
	return scoredOutfitPrimaryColorTags
end

function DailyQuestProgressRoundRecordWriter.createThemedRoundCompletionRecordWriter(
	writerDependencies: RoundRecordWriterDependencies
): (any, any) -> ()
	return function(saveDataDraft, themedRoundCompletion)
		local currentUnixSeconds = writerDependencies.clock:getCurrentUnixSeconds()
		DailyProgressDayBoundary.replaceDailyProgressIfStaleOrMalformedAndLogRepair(
			saveDataDraft,
			currentUnixSeconds,
			writerDependencies.logger,
			"the save rewarded for round " .. tostring(themedRoundCompletion.roundId)
		)

		local scoredOutfitPrimaryColorTags =
			collectScoredOutfitPrimaryColorTags(writerDependencies, themedRoundCompletion)
		if #scoredOutfitPrimaryColorTags == 0 then
			writerDependencies.logger:logWarning(
				string.format(
					"DailyProgressTracker: round %s has no known scored styling item; no daily quest progress written",
					tostring(themedRoundCompletion.roundId)
				)
			)
			return
		end

		local dailyProgress = saveDataDraft.dailyProgress
		local didDetermine, dailyQuestProgressAdvancesOrError = pcall(
			DailyQuestProgressFromRatedRound.determineDailyQuestProgressFromRatedRound,
			dailyProgress,
			PlayerSaveDataSchema.formatUtcDailyDateKey(currentUnixSeconds),
			{
				isOutfitEmpty = false,
				starCount = themedRoundCompletion.starCount,
				scoredOutfitPrimaryColorTags = scoredOutfitPrimaryColorTags,
			},
			writerDependencies.dailyQuestCatalogEntries
		)
		if not didDetermine then
			writerDependencies.logger:logWarning(
				string.format(
					"DailyProgressTracker: daily quest progress for round %s could not be worked out: %s",
					tostring(themedRoundCompletion.roundId),
					tostring(dailyQuestProgressAdvancesOrError)
				)
			)
			return
		end
		for _, dailyQuestProgressAdvance in dailyQuestProgressAdvancesOrError do
			dailyProgress.dailyQuestProgressCountByQuestId[dailyQuestProgressAdvance.dailyQuestId] =
				dailyQuestProgressAdvance.progressCountAfterRound
		end
	end
end

return table.freeze(DailyQuestProgressRoundRecordWriter)
