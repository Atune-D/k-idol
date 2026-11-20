-- DailyQuestDescriptionTexts (development spec §1.8, §10 v1.4 owner question 11: "Daily quests have no
-- display text field; the device must derive text from the kind and its numbers"): the sentence the
-- daily rewards panel shows for a quest, built from its kind and numbers only, so a new quest in
-- DailyQuestCatalog needs no new text.
-- What each kind counts (DailyQuestCatalog header, DailyQuestProgressFromRatedRound), said plainly:
--   CompleteRounds          "Finish N themed rounds wearing an outfit."  (a rated round with a
--                           non-empty scored outfit; 1 -> "round")
--   EarnStarsAtLeast        "Get M stars or more in N rounds."  (counts rounds, not stars; "1 star",
--                           "1 round")
--   UseColorInRatedOutfit   "Wear something <colour> in N rounds."  (a rated round whose scored
--                           outfit has an item of that primary colour)
--   any other kind          "Complete this quest N times." (a newer catalog than this device knows)
-- Colour tags are written with spaces for underscores. No real brand, idol, group, artist or song
-- names (spec §5.2).
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   DailyQuestDescriptionTexts.describeDailyQuest(dailyQuest) -> string

local DailyQuestDescriptionTexts = {}

local function countWords(count: number, singularWord: string, pluralWord: string): string
	return string.format("%d %s", count, if count == 1 then singularWord else pluralWord)
end

function DailyQuestDescriptionTexts.describeDailyQuest(dailyQuest): string
	local roundsText = countWords(dailyQuest.targetCount, "round", "rounds")
	if dailyQuest.dailyQuestKind == "CompleteRounds" then
		return string.format(
			"Finish %s wearing an outfit.",
			countWords(dailyQuest.targetCount, "themed round", "themed rounds")
		)
	elseif dailyQuest.dailyQuestKind == "EarnStarsAtLeast" and type(dailyQuest.minimumStarCount) == "number" then
		return string.format(
			"Get %s or more in %s.",
			countWords(dailyQuest.minimumStarCount, "star", "stars"),
			roundsText
		)
	elseif dailyQuest.dailyQuestKind == "UseColorInRatedOutfit" and type(dailyQuest.requiredColorTag) == "string" then
		local colorWords = string.gsub(dailyQuest.requiredColorTag, "_", " ")
		return string.format("Wear something %s in %s.", colorWords, roundsText)
	end
	return string.format("Complete this quest %s.", countWords(dailyQuest.targetCount, "time", "times"))
end

return table.freeze(DailyQuestDescriptionTexts)
