-- LobbyDanceAndEquippedCosmeticsPresentationReader (development spec v1.3 §1.7, §1.10
-- `equippedCosmeticIdByKind`, §2.8): reads, for CharacterAppearanceAndStageDirector, the two things
-- a character presentation carries besides its outfit and stage place:
--   * the lobby dance to play (LobbyDanceCoordinator's state, turned into an animation id), and
--   * the cosmetics to show (the save's equipped Title, NameplateStyle and StageEntranceEffect).
-- Pure logic: no Roblox-specific interface is used.
--
-- Rules:
--   * A lobby dance is presented only when the coordinator says the player dances AND the dance's
--     catalog entry has a usable animation id (a non-empty string). A dance without one presents
--     no dance (the reason is returned so the director can log it).
--   * A cosmetic is presented only when ALL hold: it is the save's equippedCosmeticIdByKind[kind],
--     it is in ownedCosmeticIds, CosmeticCatalog knows it with exactly that kind, and
--     CosmeticPresentationCatalog has a presentation for it. Anything else is shown as nothing
--     (a damaged or out-of-date save never shows something the player does not own).
--
-- PUBLIC API
--   Reader.readLobbyDanceToPresent(lobbyDanceCoordinator, danceCatalog, playerUserId)
--     -> (lobbyDance?, unusableDanceId?)
--     lobbyDance = frozen { danceId, danceAnimationAssetId, danceStartedAtUnixMilliseconds,
--       followedPlayerUserId? }. unusableDanceId is set when the player dances a dance with no
--       usable animation id (then lobbyDance is nil).
--   Reader.readEquippedCosmeticIdsToPresent(saveDataCopy?, cosmeticCatalog) -> frozen
--     { titleCosmeticId?, nameplateStyleCosmeticId?, stageEntranceEffectCosmeticId? }
--   Reader.buildEquippedCosmeticsSignature(equippedCosmeticIdsToPresent) -> string
--     Equal exactly when the three ids are equal (for change detection).

local CosmeticPresentationCatalog = require("../shared/CosmeticPresentationCatalog")

local LobbyDanceAndEquippedCosmeticsPresentationReader = {}

function LobbyDanceAndEquippedCosmeticsPresentationReader.readLobbyDanceToPresent(
	lobbyDanceCoordinator,
	danceCatalog,
	playerUserId: number
)
	local lobbyDanceState = lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(playerUserId)
	if lobbyDanceState == nil then
		return nil, nil
	end
	local dance = danceCatalog.findDanceByDanceId(lobbyDanceState.danceId)
	if dance == nil or type(dance.danceAnimationAssetId) ~= "string" or dance.danceAnimationAssetId == "" then
		return nil, lobbyDanceState.danceId
	end
	return table.freeze({
		danceId = lobbyDanceState.danceId,
		danceAnimationAssetId = dance.danceAnimationAssetId,
		danceStartedAtUnixMilliseconds = lobbyDanceState.danceStartedAtUnixMilliseconds,
		followedPlayerUserId = lobbyDanceState.followedPlayerUserId,
	}),
		nil
end

local function readPresentableEquippedCosmeticId(saveDataCopy, cosmeticCatalog, cosmeticKind: string): string?
	local equippedCosmeticIdByKind = saveDataCopy.equippedCosmeticIdByKind
	local ownedCosmeticIds = saveDataCopy.ownedCosmeticIds
	if type(equippedCosmeticIdByKind) ~= "table" or type(ownedCosmeticIds) ~= "table" then
		return nil
	end
	local equippedCosmeticId = equippedCosmeticIdByKind[cosmeticKind]
	if type(equippedCosmeticId) ~= "string" or table.find(ownedCosmeticIds, equippedCosmeticId) == nil then
		return nil
	end
	local cosmeticPresentation =
		CosmeticPresentationCatalog.findCosmeticPresentation(equippedCosmeticId, cosmeticCatalog)
	if cosmeticPresentation == nil or cosmeticPresentation.cosmeticKind ~= cosmeticKind then
		return nil
	end
	return equippedCosmeticId
end

function LobbyDanceAndEquippedCosmeticsPresentationReader.readEquippedCosmeticIdsToPresent(
	saveDataCopy,
	cosmeticCatalog
)
	if type(saveDataCopy) ~= "table" then
		return table.freeze({})
	end
	return table.freeze({
		titleCosmeticId = readPresentableEquippedCosmeticId(saveDataCopy, cosmeticCatalog, "Title"),
		nameplateStyleCosmeticId = readPresentableEquippedCosmeticId(saveDataCopy, cosmeticCatalog, "NameplateStyle"),
		stageEntranceEffectCosmeticId = readPresentableEquippedCosmeticId(
			saveDataCopy,
			cosmeticCatalog,
			"StageEntranceEffect"
		),
	})
end

function LobbyDanceAndEquippedCosmeticsPresentationReader.buildEquippedCosmeticsSignature(
	equippedCosmeticIdsToPresent
): string
	return string.format(
		"%s|%s|%s",
		equippedCosmeticIdsToPresent.titleCosmeticId or "",
		equippedCosmeticIdsToPresent.nameplateStyleCosmeticId or "",
		equippedCosmeticIdsToPresent.stageEntranceEffectCosmeticId or ""
	)
end

return table.freeze(LobbyDanceAndEquippedCosmeticsPresentationReader)
