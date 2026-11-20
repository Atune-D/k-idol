-- DanceLobbyPanelModelBuilder (development spec §0.2 "Lobby and dance floor", §1.7, §2.8): decides what
-- the Dances panel of the lobby menu shows, as plain data.
--   * The player's OWNED dances (from the latest save snapshot only, §2.6), in DanceCatalog order;
--     an owned id the device's catalog does not know is not listed. The one equipped for the stage
--     (equippedDanceId) is marked; every other owned dance offers "Use on stage" (RequestEquipDance).
--   * Each owned dance offers "Dance" (RequestStartDanceInLobby); "Stop dancing"
--     (RequestStopDanceInLobby, always accepted by the server) is always offered.
--   * Whether the player is dancing, and what, is what LobbyDancerObservation sees on their own
--     character (the server sends no message about it): "You are dancing: <name>" or "You are not
--     dancing.".
--   * Every OTHER player in the server is offered with "Dance with them" (RequestSyncDanceWithPlayer),
--     whether or not they are seen dancing: the server decides, and its answer is explained. A player
--     seen dancing says which dance; the others say "Not dancing right now". Nobody else: a line
--     saying so.
--   * Each request's latest outcome is explained (LobbyRequestAnswerTexts) on the row it belongs to:
--     on the dance's row the latest tap of equip or start, sync on the player's row, stop under the
--     Stop button.
-- Before the first snapshot only a loading line is shown.
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   DanceLobbyPanelModelBuilder.buildDanceLobbyPanelModel(danceInputs) -> model
--   danceInputs = { lobbySnapshot?, danceCatalogDances, localLobbyDanceId?,
--     otherPlayers = { { playerUserId, playerDisplayName, lobbyDanceId? } },
--     outcomeByRemoteChannelName = { [channelName]: outcome? } }
--   model = { loadingText, dancingStatusText, stopFeedbackText,
--     danceRows = { { danceId, danceNameText, stageDanceText, isEquipButtonVisible, startButtonText,
--                     feedbackText } },
--     playerRows = { { playerUserId, playerNameText, dancingText, feedbackText } },
--     noOtherPlayersText }

local LobbyRequestAnswerTexts = require("./LobbyRequestAnswerTexts")

local DanceLobbyPanelModelBuilder = {}

DanceLobbyPanelModelBuilder.LOADING_TEXT = "Loading your dances..."
DanceLobbyPanelModelBuilder.NO_OTHER_PLAYERS_TEXT = "Nobody else is here right now. Dance together when friends join!"

local function findDanceName(danceCatalogDances, danceId: string?): string?
	for _, dance in danceCatalogDances do
		if dance.danceId == danceId then
			return dance.danceDisplayName
		end
	end
	return nil
end

local function describeOutcomeFor(outcome, requestSubject: any): string
	if outcome == nil or outcome.requestSubject ~= requestSubject then
		return ""
	end
	return LobbyRequestAnswerTexts.describeLobbyRequestOutcome(outcome)
end

local function buildDanceRows(danceInputs)
	local lobbySnapshot = danceInputs.lobbySnapshot
	local outcomes = danceInputs.outcomeByRemoteChannelName
	local danceRows = {}
	for _, dance in danceInputs.danceCatalogDances do
		if table.find(lobbySnapshot.ownedDanceIds, dance.danceId) == nil then
			continue
		end
		local isStageDance = lobbySnapshot.equippedDanceId == dance.danceId
		table.insert(danceRows, {
			danceId = dance.danceId,
			danceNameText = dance.danceDisplayName,
			stageDanceText = if isStageDance then "Your stage dance" else "",
			isEquipButtonVisible = not isStageDance,
			startButtonText = if danceInputs.localLobbyDanceId == dance.danceId then "Dancing now" else "Dance",
			feedbackText = LobbyRequestAnswerTexts.describeLatestOutcomeForSubject(
				{ outcomes.RequestEquipDance, outcomes.RequestStartDanceInLobby },
				dance.danceId
			),
		})
	end
	return danceRows
end

local function buildPlayerRows(danceInputs)
	local playerRows = {}
	for _, otherPlayer in danceInputs.otherPlayers do
		local danceName = findDanceName(danceInputs.danceCatalogDances, otherPlayer.lobbyDanceId)
		table.insert(playerRows, {
			playerUserId = otherPlayer.playerUserId,
			playerNameText = otherPlayer.playerDisplayName,
			dancingText = if danceName ~= nil then "Dancing: " .. danceName else "Not dancing right now",
			feedbackText = describeOutcomeFor(
				danceInputs.outcomeByRemoteChannelName.RequestSyncDanceWithPlayer,
				otherPlayer.playerUserId
			),
		})
	end
	return playerRows
end

function DanceLobbyPanelModelBuilder.buildDanceLobbyPanelModel(danceInputs)
	local model = {
		loadingText = "",
		dancingStatusText = "",
		stopFeedbackText = "",
		danceRows = {},
		playerRows = {},
		noOtherPlayersText = "",
	}
	if danceInputs.lobbySnapshot == nil then
		model.loadingText = DanceLobbyPanelModelBuilder.LOADING_TEXT
		return model
	end
	local localDanceName = findDanceName(danceInputs.danceCatalogDances, danceInputs.localLobbyDanceId)
	model.dancingStatusText = if localDanceName ~= nil
		then "You are dancing: " .. localDanceName
		else "You are not dancing."
	local stopOutcome = danceInputs.outcomeByRemoteChannelName.RequestStopDanceInLobby
	model.stopFeedbackText = LobbyRequestAnswerTexts.describeLobbyRequestOutcome(stopOutcome)
	model.danceRows = buildDanceRows(danceInputs)
	model.playerRows = buildPlayerRows(danceInputs)
	if #model.playerRows == 0 then
		model.noOtherPlayersText = DanceLobbyPanelModelBuilder.NO_OTHER_PLAYERS_TEXT
	end
	return model
end

return table.freeze(DanceLobbyPanelModelBuilder)
