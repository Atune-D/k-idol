-- Builds the lobby request rules (SetLobbyOutfitRequestAnswerer and LobbyDanceCoordinator) on a
-- REAL PlayerSaveDataKeeper (fake storage, clock and scheduler), a REAL PlayerRequestRateLimiter
-- on the same fake clock, a REAL StoredLobbyOutfitKeeper, a fake catalog resolver and a test
-- dance catalog. Records every lobby dance state change, every coordinator warning and every
-- call of the injected "busy in a themed round" questions. Not a spec file.
--
-- options (all optional):
--   isCatalogLeftNotReady: boolean          the fake resolver never publishes a catalog
--   replacementSaveKeeperMethodsByName      the rules see a StandInPlayerSaveDataKeeper instead

local FakeMarketplaceStylingItemResolver = require("../Support/FakeMarketplaceStylingItemResolver")
local StandInPlayerSaveDataKeeper = require("../Support/StandInPlayerSaveDataKeeper")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local LobbyDanceCoordinator = require("../../src/server/LobbyDanceCoordinator")
local PlayerRequestRateLimiter = require("../../src/server/PlayerRequestRateLimiter")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local SetLobbyOutfitRequestAnswerer = require("../../src/server/SetLobbyOutfitRequestAnswerer")
local StoredLobbyOutfitKeeper = require("../../src/server/StoredLobbyOutfitKeeper")
local PlayerSaveDataKeeperTestHarness = require("./PlayerSaveDataKeeperTestHarness")

local LobbyRequestRulesTestHarness = {}

LobbyRequestRulesTestHarness.FIRST_PLAYER_USER_ID = PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID
LobbyRequestRulesTestHarness.SECOND_PLAYER_USER_ID = PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID + 1
LobbyRequestRulesTestHarness.THIRD_PLAYER_USER_ID = PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID + 2
LobbyRequestRulesTestHarness.FOURTH_PLAYER_USER_ID = PlayerSaveDataKeeperTestHarness.EXAMPLE_PLAYER_USER_ID + 3

-- Owned by every new player of the save keeper harness (its STARTER_DANCE_IDS).
LobbyRequestRulesTestHarness.STARTER_WAVE_DANCE_ID = "starter_wave"
LobbyRequestRulesTestHarness.STARTER_STEP_DANCE_ID = "starter_step"
-- In the test catalog, owned by nobody unless a test gives it.
LobbyRequestRulesTestHarness.SHOP_TWIRL_DANCE_ID = "shop_twirl"
-- Not in the test catalog (a dance removed from the game); a test may put it in a save.
LobbyRequestRulesTestHarness.RETIRED_DANCE_ID = "retired_slide"

LobbyRequestRulesTestHarness.SET_LOBBY_OUTFIT_INTERVAL_SECONDS = 2
LobbyRequestRulesTestHarness.LOBBY_DANCE_INTERVAL_SECONDS = 0.5

local TEST_DANCE_IDS = {
	LobbyRequestRulesTestHarness.STARTER_WAVE_DANCE_ID,
	LobbyRequestRulesTestHarness.STARTER_STEP_DANCE_ID,
	LobbyRequestRulesTestHarness.SHOP_TWIRL_DANCE_ID,
}

local function createRecordingTestDanceCatalog()
	local danceByDanceId = {}
	for _, danceId in TEST_DANCE_IDS do
		danceByDanceId[danceId] = table.freeze({
			danceId = danceId,
			danceDisplayName = danceId,
			danceAnimationAssetId = "",
			starCoinPrice = if danceId == LobbyRequestRulesTestHarness.SHOP_TWIRL_DANCE_ID then 900 else 0,
			isGrantedToNewPlayers = danceId ~= LobbyRequestRulesTestHarness.SHOP_TWIRL_DANCE_ID,
		})
	end
	local recordingTestDanceCatalog = { lookedUpDanceIds = {} }
	-- As strict as the injected contract: findDanceByDanceId takes a string.
	function recordingTestDanceCatalog.findDanceByDanceId(danceId: any)
		if type(danceId) ~= "string" then
			error("test dance catalog: findDanceByDanceId takes a string, got " .. type(danceId))
		end
		table.insert(recordingTestDanceCatalog.lookedUpDanceIds, danceId)
		return danceByDanceId[danceId]
	end
	return recordingTestDanceCatalog
end

function LobbyRequestRulesTestHarness.createLobbyRequestRulesHarness(options: { [string]: any }?)
	local chosenOptions = options or {}
	local harness = PlayerSaveDataKeeperTestHarness.createKeeperWithFakes()
	local fakeResolver = FakeMarketplaceStylingItemResolver.new()
	if not chosenOptions.isCatalogLeftNotReady then
		fakeResolver:publishWardrobeCatalog(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
	end
	local saveKeeperSeenByLobbyRules = harness.playerSaveDataKeeper
	if chosenOptions.replacementSaveKeeperMethodsByName then
		saveKeeperSeenByLobbyRules = StandInPlayerSaveDataKeeper.new(
			harness.playerSaveDataKeeper,
			chosenOptions.replacementSaveKeeperMethodsByName
		)
	end
	local playerRequestRateLimiter = PlayerRequestRateLimiter.new({ clock = harness.fakeClock })

	local storedLobbyOutfitKeeper = StoredLobbyOutfitKeeper.new({
		playerSaveDataKeeper = harness.playerSaveDataKeeper,
		stylingItemByStylingItemKey = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
		marketplaceStylingItemResolver = fakeResolver,
		logger = { logInformation = function() end, logWarning = function() end },
	})
	storedLobbyOutfitKeeper:startLookingAfterStoredLobbyOutfits()

	-- What the injected round questions answer, per player; anything unset answers false. A
	-- function set as the answer is called with the player's id and its result is answered (so a
	-- test can answer nil, or act while the question is asked).
	harness.stylingOrShowcaseParticipantAnswerByPlayerUserId = {}
	harness.onThemedRoundStageAnswerByPlayerUserId = {}
	harness.askedStylingOrShowcaseParticipantUserIds = {}
	harness.askedOnThemedRoundStageUserIds = {}
	local function readConfiguredAnswer(answerByPlayerUserId, playerUserId: number)
		local answer = answerByPlayerUserId[playerUserId]
		if answer == nil then
			return false
		end
		if type(answer) == "function" then
			return answer(playerUserId)
		end
		return answer
	end
	local function answerStylingOrShowcaseParticipant(playerUserId: number)
		table.insert(harness.askedStylingOrShowcaseParticipantUserIds, playerUserId)
		return readConfiguredAnswer(harness.stylingOrShowcaseParticipantAnswerByPlayerUserId, playerUserId)
	end
	local function answerOnThemedRoundStage(playerUserId: number)
		table.insert(harness.askedOnThemedRoundStageUserIds, playerUserId)
		return readConfiguredAnswer(harness.onThemedRoundStageAnswerByPlayerUserId, playerUserId)
	end

	local setLobbyOutfitRequestAnswerer = SetLobbyOutfitRequestAnswerer.new({
		playerSaveDataKeeper = saveKeeperSeenByLobbyRules,
		playerRequestRateLimiter = playerRequestRateLimiter,
		marketplaceStylingItemResolver = fakeResolver,
		stylingItemByStylingItemKey = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
		isPlayerStylingOrShowcaseParticipant = answerStylingOrShowcaseParticipant,
	})

	local coordinatorWarnings = {}
	local recordingTestDanceCatalog = createRecordingTestDanceCatalog()
	local lobbyDanceCoordinator = LobbyDanceCoordinator.new({
		playerSaveDataKeeper = saveKeeperSeenByLobbyRules,
		playerRequestRateLimiter = playerRequestRateLimiter,
		danceCatalog = recordingTestDanceCatalog,
		clock = harness.fakeClock,
		isPlayerOnThemedRoundStage = answerOnThemedRoundStage,
		logger = {
			-- The coordinator's contract asks for logWarning only.
			logWarning = function(_, message: string)
				table.insert(coordinatorWarnings, message)
			end,
		},
	})
	local recordedLobbyDanceStateChanges = {}
	lobbyDanceCoordinator:subscribeToLobbyDanceStateChanged(function(playerUserId, lobbyDanceState)
		table.insert(recordedLobbyDanceStateChanges, { playerUserId = playerUserId, lobbyDanceState = lobbyDanceState })
	end)

	harness.fakeResolver = fakeResolver
	harness.playerRequestRateLimiter = playerRequestRateLimiter
	harness.storedLobbyOutfitKeeper = storedLobbyOutfitKeeper
	harness.setLobbyOutfitRequestAnswerer = setLobbyOutfitRequestAnswerer
	harness.lobbyDanceCoordinator = lobbyDanceCoordinator
	harness.recordingTestDanceCatalog = recordingTestDanceCatalog
	harness.recordedLobbyDanceStateChanges = recordedLobbyDanceStateChanges
	harness.coordinatorWarnings = coordinatorWarnings
	harness.recordedSaveKeeperEvents = harness.recordEveryEvent()

	function harness.nowUnixMilliseconds(): number
		return harness.fakeClock:getCurrentUnixMilliseconds()
	end

	-- Each send waits out its channel's interval first, so the rate limiter admits it.
	function harness.sendSetLobbyOutfit(playerUserId: number, untrustedSetLobbyOutfitRequest: any)
		harness.advanceSeconds(LobbyRequestRulesTestHarness.SET_LOBBY_OUTFIT_INTERVAL_SECONDS)
		return setLobbyOutfitRequestAnswerer:answerSetLobbyOutfitRequest(playerUserId, untrustedSetLobbyOutfitRequest)
	end
	function harness.sendStartDance(playerUserId: number, untrustedDanceId: any)
		harness.advanceSeconds(LobbyRequestRulesTestHarness.LOBBY_DANCE_INTERVAL_SECONDS)
		return lobbyDanceCoordinator:answerStartDanceInLobbyRequest(playerUserId, untrustedDanceId)
	end
	function harness.sendSyncDance(playerUserId: number, untrustedTargetPlayerUserId: any)
		harness.advanceSeconds(LobbyRequestRulesTestHarness.LOBBY_DANCE_INTERVAL_SECONDS)
		return lobbyDanceCoordinator:answerSyncDanceWithPlayerRequest(playerUserId, untrustedTargetPlayerUserId)
	end
	function harness.sendStopDance(playerUserId: number)
		harness.advanceSeconds(LobbyRequestRulesTestHarness.LOBBY_DANCE_INTERVAL_SECONDS)
		return lobbyDanceCoordinator:answerStopDanceInLobbyRequest(playerUserId)
	end

	function harness.readInMemoryLobbyOutfit(playerUserId: number)
		return harness.playerSaveDataKeeper:readPlayerSaveDataCopy(playerUserId).lobbyOutfitStylingItemKeys
	end

	function harness.readInMemoryChangeRevision(playerUserId: number): number?
		local inMemoryChangeRevision = harness.playerSaveDataKeeper:readSaveChangeRevisions(playerUserId)
		return inMemoryChangeRevision
	end

	function harness.countSaveKeeperEvents(eventName: string): number
		local eventCount = 0
		for _, recordedEvent in harness.recordedSaveKeeperEvents do
			if recordedEvent.eventName == eventName then
				eventCount += 1
			end
		end
		return eventCount
	end

	-- Puts dance ids into a loaded player's ownedDanceIds (a test-only appearance change).
	function harness.giveDanceIds(playerUserId: number, givenDanceIds: { string })
		local changeResult = harness.playerSaveDataKeeper:applyChangeToPlayerSaveData(
			playerUserId,
			PlayerSaveDataKeeper.APPEARANCE_CHANGE_SAVED_LATER,
			"test: give dances",
			function(saveDataDraft)
				for _, givenDanceId in givenDanceIds do
					table.insert(saveDataDraft.ownedDanceIds, givenDanceId)
				end
				return true
			end
		)
		assert(changeResult.changeOutcome == "Applied", "harness: giving dances should apply")
	end

	-- The state a player should have when dancing; compares by content.
	function harness.buildExpectedLobbyDanceState(
		dancingPlayerUserId: number,
		danceId: string,
		danceStartedAtUnixMilliseconds: number,
		followedPlayerUserId: number?
	)
		return {
			dancingPlayerUserId = dancingPlayerUserId,
			danceId = danceId,
			danceStartedAtUnixMilliseconds = danceStartedAtUnixMilliseconds,
			followedPlayerUserId = followedPlayerUserId,
		}
	end

	return harness
end

return LobbyRequestRulesTestHarness
