-- CharacterAppearanceAndStageDirector on stand-in dependencies: it follows the save keeper's own
-- events for the cosmetics to show, without relying on any other module to present at that moment.

local UnitTestFramework = require("../Support/UnitTestFramework")
local RecordingLogger = require("../Support/RecordingLogger")
local CharacterAppearanceAndStageDirector = require("../../src/server/CharacterAppearanceAndStageDirector")
local CosmeticCatalog = require("../../src/shared/CosmeticCatalog")
local DanceCatalog = require("../../src/shared/DanceCatalog")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = 701

local function createDirectorWithStandIns()
	local standIns = { presentations = {}, saveDataCopy = nil, listenersByEvent = {} }
	local function subscriber(eventName)
		return function(_, listener)
			standIns.listenersByEvent[eventName] = listener
			return function() end
		end
	end
	local director = CharacterAppearanceAndStageDirector.new({
		themedRoundClock = { subscribeToRoundPhaseChanged = subscriber("roundPhaseChanged") },
		themedRoundReferee = {
			readCharacterSpawnRoundFacts = function()
				return { isParticipant = false }
			end,
			listCurrentRoundParticipantUserIds = function()
				return {}
			end,
		},
		playerSaveDataKeeper = {
			isPlayerSaveDataLoaded = function()
				return standIns.saveDataCopy ~= nil
			end,
			readPlayerSaveDataCopy = function()
				return standIns.saveDataCopy
			end,
			subscribeToPlayerSaveDataLoaded = subscriber("saveLoaded"),
			subscribeToInMemorySaveDataChanged = subscriber("inMemorySaveChanged"),
		},
		storedLobbyOutfitKeeper = {
			readStoredLobbyOutfitAvailability = function()
				return nil
			end,
			-- Never tells anything: the director must not depend on it to show cosmetics.
			subscribeToStoredLobbyOutfitAvailabilityChanged = subscriber("lobbyOutfitChanged"),
		},
		lobbyDanceCoordinator = {
			readLobbyDanceStateOfPlayer = function()
				return nil
			end,
			subscribeToLobbyDanceStateChanged = subscriber("lobbyDanceChanged"),
		},
		characterAppearancePresenter = {
			presentCharacterAppearance = function(_, playerUserId, presentation)
				table.insert(standIns.presentations, { playerUserId = playerUserId, presentation = presentation })
			end,
		},
		danceCatalog = DanceCatalog,
		cosmeticCatalog = CosmeticCatalog,
		logger = RecordingLogger.new(),
	})
	director:startDirectingCharacterAppearances()
	return director, standIns
end

local function saveWithTitle(titleCosmeticId: string?)
	return {
		ownedCosmeticIds = { "title_rising_star", "title_superstar" },
		equippedCosmeticIdByKind = { Title = titleCosmeticId },
		equippedDanceId = "starter_groove",
		lobbyOutfitStylingItemKeys = {},
	}
end

describe("CharacterAppearanceAndStageDirector save events", function()
	it("presents the equipped cosmetics when a save with them loads", function()
		local _, standIns = createDirectorWithStandIns()
		standIns.saveDataCopy = saveWithTitle("title_superstar")
		standIns.listenersByEvent.saveLoaded(PLAYER, standIns.saveDataCopy)
		expect(#standIns.presentations).toBe(1)
		expect(standIns.presentations[1].presentation.presentationReason).toBe("EquippedCosmeticsChanged")
		expect(standIns.presentations[1].presentation.equippedTitleCosmeticId).toBe("title_superstar")
	end)

	it("does not present when a loading save shows nothing", function()
		local _, standIns = createDirectorWithStandIns()
		standIns.saveDataCopy = saveWithTitle(nil)
		standIns.listenersByEvent.saveLoaded(PLAYER, standIns.saveDataCopy)
		expect(#standIns.presentations).toBe(0)
	end)

	it("presents again only when the cosmetics to show change", function()
		local _, standIns = createDirectorWithStandIns()
		standIns.saveDataCopy = saveWithTitle("title_rising_star")
		standIns.listenersByEvent.inMemorySaveChanged(PLAYER, saveWithTitle("title_rising_star"))
		expect(#standIns.presentations).toBe(1)
		standIns.listenersByEvent.inMemorySaveChanged(PLAYER, saveWithTitle("title_rising_star"))
		expect(#standIns.presentations).toBe(1)
		standIns.saveDataCopy = saveWithTitle("title_superstar")
		standIns.listenersByEvent.inMemorySaveChanged(PLAYER, saveWithTitle("title_superstar"))
		expect(#standIns.presentations).toBe(2)
		expect(standIns.presentations[2].presentation.equippedTitleCosmeticId).toBe("title_superstar")
	end)

	it("raises when built without the cosmetic catalog", function()
		expect(function()
			CharacterAppearanceAndStageDirector.new({
				themedRoundClock = {},
				themedRoundReferee = {},
				playerSaveDataKeeper = {},
				storedLobbyOutfitKeeper = {},
				lobbyDanceCoordinator = {},
				characterAppearancePresenter = {},
				danceCatalog = {},
				logger = {},
			})
		end).toThrow("missing cosmeticCatalog")
	end)
end)
