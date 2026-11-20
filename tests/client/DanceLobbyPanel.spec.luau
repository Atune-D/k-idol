-- The Dances panel (§2.8) and how the device tells who is dancing in the lobby (no server message).

local UnitTestFramework = require("../Support/UnitTestFramework")
local LobbyTestFixtures = require("./LobbyTestFixtures")
local DanceCatalog = require("../../src/shared/DanceCatalog")
local DanceLobbyPanelModelBuilder = require("../../src/client/DanceLobbyPanelModelBuilder")
local LobbyDancerObservation = require("../../src/client/LobbyDancerObservation")
local LobbySaveDataSnapshotReader = require("../../src/client/LobbySaveDataSnapshotReader")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function readSnapshot(overrides)
	return LobbySaveDataSnapshotReader.readLobbySaveDataSnapshot(LobbyTestFixtures.buildSnapshotMessage(overrides))
end

local function buildModel(danceInputOverrides)
	local danceInputs = {
		lobbySnapshot = readSnapshot(),
		danceCatalogDances = DanceCatalog.DANCES,
		localLobbyDanceId = nil,
		otherPlayers = {},
		outcomeByRemoteChannelName = {},
	}
	for fieldName, fieldValue in danceInputOverrides or {} do
		danceInputs[fieldName] = fieldValue
	end
	return DanceLobbyPanelModelBuilder.buildDanceLobbyPanelModel(danceInputs)
end

describe("LobbyDancerObservation", function()
	it("matches a playing animation to a catalog dance by its asset number, in any id form", function()
		local find = LobbyDancerObservation.findDanceIdForPlayingAnimationIds
		expect(find({ "rbxassetid://507776043" }, DanceCatalog.DANCES)).toBe("starter_bounce")
		expect(find({ "http://www.roblox.com/asset/?id=507777268" }, DanceCatalog.DANCES)).toBe("starter_sway")
		expect(find({ "https://assetdelivery.roblox.com/v1/asset/?id=507776043" }, DanceCatalog.DANCES)).toBe(
			"starter_bounce"
		)
		expect(find({ "rbxassetid://180435571", "rbxassetid://507771019" }, DanceCatalog.DANCES)).toBe("starter_groove")
		expect(find({ "rbxassetid://180435571" }, DanceCatalog.DANCES)).toBeNil()
		expect(find({ "rbxassetid://5077710190" }, DanceCatalog.DANCES)).toBeNil()
		expect(find({}, DanceCatalog.DANCES)).toBeNil()
		expect(LobbyDancerObservation.readAnimationAssetNumber("no number")).toBeNil()
		expect(LobbyDancerObservation.readAnimationAssetNumber(42)).toBeNil()
	end)

	it("does not count a Showcase participant on stage as dancing in the lobby", function()
		local dancer = { playerUserId = 7, playingAnimationIds = { "rbxassetid://507771019" } }
		local find = LobbyDancerObservation.findLobbyDanceIdOfPlayer
		expect(find(dancer, { roundPhase = "Showcase", participantUserIds = { 7 } }, DanceCatalog.DANCES)).toBeNil()
		expect(find(dancer, { roundPhase = "Showcase", participantUserIds = { 8 } }, DanceCatalog.DANCES)).toBe(
			"starter_groove"
		)
		expect(find(dancer, { roundPhase = "Styling", participantUserIds = { 7 } }, DanceCatalog.DANCES)).toBe(
			"starter_groove"
		)
		expect(find(dancer, { roundPhase = nil, participantUserIds = {} }, DanceCatalog.DANCES)).toBe("starter_groove")
	end)
end)

describe("DanceLobbyPanelModelBuilder", function()
	it("shows only a loading line before the first snapshot", function()
		local model = DanceLobbyPanelModelBuilder.buildDanceLobbyPanelModel({
			lobbySnapshot = nil,
			danceCatalogDances = DanceCatalog.DANCES,
			otherPlayers = {},
			outcomeByRemoteChannelName = {},
		})
		expect(model.loadingText).toBe(DanceLobbyPanelModelBuilder.LOADING_TEXT)
		expect(#model.danceRows).toBe(0)
	end)

	it("lists the owned dances in catalog order and marks the stage dance", function()
		local model = buildModel({
			lobbySnapshot = readSnapshot({
				ownedDanceIds = { "starter_sway", "starter_groove", "not_in_catalog" },
				equippedDanceId = "starter_sway",
			}),
		})
		expect(#model.danceRows).toBe(2)
		expect(model.danceRows[1].danceId).toBe("starter_groove")
		expect(model.danceRows[1].isEquipButtonVisible).toBe(true)
		expect(model.danceRows[1].stageDanceText).toBe("")
		expect(model.danceRows[2].danceNameText).toBe("Starter Sway")
		expect(model.danceRows[2].stageDanceText).toBe("Your stage dance")
		expect(model.danceRows[2].isEquipButtonVisible).toBe(false)
	end)

	it("says what the player is seen dancing", function()
		expect(buildModel().dancingStatusText).toBe("You are not dancing.")
		local model = buildModel({ localLobbyDanceId = "starter_bounce" })
		expect(model.dancingStatusText).toBe("You are dancing: Starter Bounce")
		expect(model.danceRows[2].startButtonText).toBe("Dancing now")
		expect(model.danceRows[1].startButtonText).toBe("Dance")
	end)

	it("offers every other player, says who is seen dancing, and explains the sync answer on their row", function()
		local model = buildModel({
			otherPlayers = {
				{ playerUserId = 2, playerDisplayName = "Ari", lobbyDanceId = "starter_sway" },
				{ playerUserId = 3, playerDisplayName = "Bo", lobbyDanceId = nil },
			},
			outcomeByRemoteChannelName = {
				RequestSyncDanceWithPlayer = {
					remoteChannelName = "RequestSyncDanceWithPlayer",
					requestSubject = 3,
					isWaitingForAnswer = false,
					answer = { isAccepted = false, rejectionReason = "TargetNotDancing" },
				},
			},
		})
		expect(model.playerRows[1].dancingText).toBe("Dancing: Starter Sway")
		expect(model.playerRows[1].feedbackText).toBe("")
		expect(model.playerRows[2].dancingText).toBe("Not dancing right now")
		expect(model.playerRows[2].feedbackText).toBe(
			"That player is not dancing in the lobby right now, so there is nothing to join."
		)
		expect(model.noOtherPlayersText).toBe("")
		expect(buildModel().noOtherPlayersText).toBe(DanceLobbyPanelModelBuilder.NO_OTHER_PLAYERS_TEXT)
	end)

	it("explains equip, start and stop answers where they belong", function()
		local model = buildModel({
			outcomeByRemoteChannelName = {
				RequestEquipDance = {
					remoteChannelName = "RequestEquipDance",
					requestSubject = "starter_bounce",
					isWaitingForAnswer = false,
					answer = { isAccepted = false, rejectionReason = "DanceNotOwned" },
				},
				RequestStartDanceInLobby = {
					remoteChannelName = "RequestStartDanceInLobby",
					requestSubject = "starter_sway",
					isWaitingForAnswer = false,
					answer = { isAccepted = false, rejectionReason = "NotAllowedDuringRound" },
				},
				RequestStopDanceInLobby = {
					remoteChannelName = "RequestStopDanceInLobby",
					requestSubject = "stop",
					isWaitingForAnswer = false,
					answer = { isAccepted = true },
				},
			},
		})
		expect(model.danceRows[1].feedbackText).toBe("")
		expect(model.danceRows[2].feedbackText).toBe("You don't own that dance, so it can't be used on stage.")
		expect(model.danceRows[3].feedbackText).toBe("You can't start a lobby dance while you are on stage.")
		expect(model.stopFeedbackText).toBe("Stopped dancing.")
	end)
end)
