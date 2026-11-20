-- Fixtures for the lobby device specs. Not a spec file.
--   LobbyTestFixtures.buildSnapshotMessage(overrides?) -> a PlayerSaveDataSnapshotChanged message of the
--     §2.6 shape (the eleven fields), for a player who owns the three starter dances; `overrides`
--     replaces top-level fields, and `overrides.dailyProgress` replaces dailyProgress fields.
--   LobbyTestFixtures.FIXTURE_DANCE_CATALOG   a DanceCatalog stand-in with two dances for sale
--     ("fixture_spin" 900, "fixture_wave" 3000) next to the real starter dances
--   LobbyTestFixtures.createRecordingAskServer() -> askServer, pendingRequests
--     askServer records { remoteChannelName, payload, onAnswer } and answers nothing by itself.

local DanceCatalog = require("../../src/shared/DanceCatalog")

local LobbyTestFixtures = {}

-- 2027-01-15 08:00:00 UTC (as ServerGameAssemblyTestHarness).
LobbyTestFixtures.START_UNIX_SECONDS = 1_800_000_000
LobbyTestFixtures.START_DAILY_DATE_KEY = "2027-01-15"

function LobbyTestFixtures.buildSnapshotMessage(overrides)
	local message = {
		fanCount = 10,
		starCoinBalance = 500,
		ownedDanceIds = { "starter_groove", "starter_bounce", "starter_sway" },
		equippedDanceId = "starter_groove",
		ownedCosmeticIds = {},
		equippedCosmeticIdByKind = {},
		lobbyOutfitStylingItemKeys = {},
		unavailableLobbyOutfitStylingItemKeys = {},
		dailyProgress = {
			dailyDateKey = LobbyTestFixtures.START_DAILY_DATE_KEY,
			playtimeSecondsToday = 0,
			claimedPlaytimeMilestoneMinutes = {},
			dailyQuestProgressCountByQuestId = {},
			claimedDailyQuestIds = {},
		},
		todaysDailyQuestIds = {
			"complete_rounds_3",
			"earn_at_least_4_stars_in_2_rounds",
			"wear_pink_in_2_rated_rounds",
		},
		isSaveDataPersistenceDelayed = false,
	}
	for fieldName, fieldValue in overrides or {} do
		if fieldName == "dailyProgress" then
			for progressFieldName, progressFieldValue in fieldValue do
				message.dailyProgress[progressFieldName] = progressFieldValue
			end
		else
			message[fieldName] = fieldValue
		end
	end
	return message
end

local fixtureDances = {}
for _, dance in DanceCatalog.DANCES do
	table.insert(fixtureDances, dance)
end
table.insert(
	fixtureDances,
	table.freeze({
		danceId = "fixture_spin",
		danceDisplayName = "Fixture Spin",
		danceAnimationAssetId = "rbxassetid://507771019",
		starCoinPrice = 900,
		isGrantedToNewPlayers = false,
	})
)
table.insert(
	fixtureDances,
	table.freeze({
		danceId = "fixture_wave",
		danceDisplayName = "Fixture Wave",
		danceAnimationAssetId = "rbxassetid://507776043",
		starCoinPrice = 3000,
		isGrantedToNewPlayers = false,
	})
)

local fixtureDanceById = {}
for _, dance in fixtureDances do
	fixtureDanceById[dance.danceId] = dance
end

LobbyTestFixtures.FIXTURE_DANCE_CATALOG = table.freeze({
	DANCES = table.freeze(fixtureDances),
	findDanceByDanceId = function(danceId)
		return if type(danceId) == "string" then fixtureDanceById[danceId] else nil
	end,
	listDanceIdsGrantedToNewPlayers = function()
		return DanceCatalog.listDanceIdsGrantedToNewPlayers()
	end,
})

function LobbyTestFixtures.createRecordingAskServer()
	local pendingRequests = {}
	local function askServer(remoteChannelName, payload, onAnswer)
		table.insert(pendingRequests, { remoteChannelName = remoteChannelName, payload = payload, onAnswer = onAnswer })
	end
	return askServer, pendingRequests
end

return LobbyTestFixtures
