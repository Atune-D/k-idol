-- Chooses the three daily quests of one UTC day (development spec §1.8): "the same for every
-- player, selected from the catalog by a random generator seeded with dailyDateKey".
--
-- The answer depends only on `dailyDateKey` and on which quest ids the catalog holds (by default
-- DailyQuestCatalog.DAILY_QUESTS). It is the same on every game server, on every device and in
-- Lune, because the generator is PortableSeededRandomNumberGenerator (plain Luau, no runtime
-- random generator).
--
-- Selection: every catalog quest gets a day rank, the first number of a generator seeded with the
-- text "<dailyDateKey>/<dailyQuestId>". The three quests with the smallest day ranks are today's,
-- in ascending rank order (equal ranks, which are extremely unlikely, are ordered by id). So:
--   * every quest is equally likely on a given day, and the three are always distinct;
--   * the catalog's order does not matter at all;
--   * adding or removing one quest in a new game version changes at most one of a day's three
--     quests (spec §4: catalog changes ship by publishing). Servers on an old and a new version
--     therefore share at least two of the day's quests. They can still differ in one, so a player
--     who moves between them could claim a fourth quest that day; see the open question in
--     DailyQuestCatalog's header.
--
-- A catalog with fewer than three quests, or with a repeated quest id, is a configuration error
-- and raises an error; quests are never repeated to fill a gap. DailyQuestCatalog.spec.luau
-- keeps the real catalog at three or more unique quests.
-- Pure logic: no Roblox-specific interface is used.

local DailyQuestCatalog = require("./DailyQuestCatalog")
local PortableSeededRandomNumberGenerator = require("./PortableSeededRandomNumberGenerator")

type DailyQuest = DailyQuestCatalog.DailyQuest

local DailyQuestOfTheDaySelector = {}

-- "YYYY-MM-DD", as made by PlayerSaveDataSchema.formatUtcDailyDateKey.
local DAILY_DATE_KEY_PATTERN = "^%d%d%d%d%-%d%d%-%d%d$"
-- Separates the date key from the quest id in a day rank's seed text.
local DAY_RANK_SEED_TEXT_SEPARATOR = "/"

-- True when the value has the shape of a dailyDateKey ("YYYY-MM-DD"). The calendar itself is not
-- checked: keys are produced by the server from the clock, never taken from a device.
function DailyQuestOfTheDaySelector.isWellFormedDailyDateKey(candidateDailyDateKey: any): boolean
	return type(candidateDailyDateKey) == "string"
		and string.match(candidateDailyDateKey, DAILY_DATE_KEY_PATTERN) ~= nil
end

-- The day rank of one quest on one date: an unsigned 32-bit number; smaller ranks are picked first.
function DailyQuestOfTheDaySelector.calculateDailyQuestDayRank(dailyDateKey: string, dailyQuestId: string): number
	local dayRankGenerator = PortableSeededRandomNumberGenerator.createFromSeedText(
		dailyDateKey .. DAY_RANK_SEED_TEXT_SEPARATOR .. dailyQuestId
	)
	return dayRankGenerator.nextUnsigned32BitNumber()
end

local function assertCatalogCanFillADay(candidateDailyQuests: { DailyQuest })
	local dailyQuestCountPerDay = DailyQuestCatalog.DAILY_QUEST_COUNT_PER_DAY
	if #candidateDailyQuests < dailyQuestCountPerDay then
		error(
			string.format(
				"DailyQuestOfTheDaySelector: the catalog needs at least %d quests, it has %d",
				dailyQuestCountPerDay,
				#candidateDailyQuests
			),
			3
		)
	end
	local seenDailyQuestIdSet = {}
	for _, candidateDailyQuest in candidateDailyQuests do
		if seenDailyQuestIdSet[candidateDailyQuest.dailyQuestId] then
			error("DailyQuestOfTheDaySelector: the catalog repeats quest id " .. candidateDailyQuest.dailyQuestId, 3)
		end
		seenDailyQuestIdSet[candidateDailyQuest.dailyQuestId] = true
	end
end

-- The three quests of `dailyDateKey`, distinct, in ascending day rank, as a frozen list.
-- `dailyQuestCatalogEntries` defaults to DailyQuestCatalog.DAILY_QUESTS; tests pass their own list.
-- Raises an error for a malformed date key, a catalog with fewer than DAILY_QUEST_COUNT_PER_DAY
-- quests or a catalog that repeats a quest id.
function DailyQuestOfTheDaySelector.selectDailyQuestsForDailyDateKey(
	dailyDateKey: string,
	dailyQuestCatalogEntries: { DailyQuest }?
): { DailyQuest }
	if not DailyQuestOfTheDaySelector.isWellFormedDailyDateKey(dailyDateKey) then
		error("DailyQuestOfTheDaySelector: dailyDateKey must be a YYYY-MM-DD string, got " .. tostring(dailyDateKey), 2)
	end
	local candidateDailyQuests = dailyQuestCatalogEntries or DailyQuestCatalog.DAILY_QUESTS
	assertCatalogCanFillADay(candidateDailyQuests)

	local rankedCandidates = {}
	for _, candidateDailyQuest in candidateDailyQuests do
		table.insert(rankedCandidates, {
			dailyQuest = candidateDailyQuest,
			dayRank = DailyQuestOfTheDaySelector.calculateDailyQuestDayRank(
				dailyDateKey,
				candidateDailyQuest.dailyQuestId
			),
		})
	end
	table.sort(rankedCandidates, function(firstCandidate, secondCandidate)
		if firstCandidate.dayRank ~= secondCandidate.dayRank then
			return firstCandidate.dayRank < secondCandidate.dayRank
		end
		return firstCandidate.dailyQuest.dailyQuestId < secondCandidate.dailyQuest.dailyQuestId
	end)

	local selectedDailyQuests = {}
	for pickNumber = 1, DailyQuestCatalog.DAILY_QUEST_COUNT_PER_DAY do
		selectedDailyQuests[pickNumber] = rankedCandidates[pickNumber].dailyQuest
	end
	return table.freeze(selectedDailyQuests)
end

-- The ids of the three quests of `dailyDateKey`, in the same order, as a frozen list (spec §2.6
-- `todaysDailyQuestIds`).
function DailyQuestOfTheDaySelector.selectDailyQuestIdsForDailyDateKey(
	dailyDateKey: string,
	dailyQuestCatalogEntries: { DailyQuest }?
): { string }
	local selectedDailyQuestIds = {}
	for _, selectedDailyQuest in
		DailyQuestOfTheDaySelector.selectDailyQuestsForDailyDateKey(dailyDateKey, dailyQuestCatalogEntries)
	do
		table.insert(selectedDailyQuestIds, selectedDailyQuest.dailyQuestId)
	end
	return table.freeze(selectedDailyQuestIds)
end

return table.freeze(DailyQuestOfTheDaySelector)
