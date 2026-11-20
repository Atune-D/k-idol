-- CharacterAppearanceAndStageDirector (development spec v1.3 §2.4 Showcase and "Respawn", §2.7,
-- §3.7, §3.8): decides WHEN each player's character is dressed, put on the stage, made to dance
-- and given back its lobby appearance, and WHAT it is given each time. Applying that to a real
-- character is the injected presenter's job (RobloxCharacterShowcasePresenter); this module calls
-- no Roblox-specific interface, so the whole timing is tested with Lune.
--
-- Every decision is CharacterSpawnAppearanceDecider's, made from the facts at that moment:
-- keeper:isPlayerSaveDataLoaded, StoredLobbyOutfitKeeper's wearable lobby outfit and
-- referee:readCharacterSpawnRoundFacts. 🔴 Nothing here changes a round, a score or a save.
--
-- When it presents (presenter:presentCharacterAppearance(playerUserId, presentation)):
--   * A character spawned (joining, reset, falling out of the world): what the decider says.
--   * Showcase begins (the clock's phase change, after the referee scored): for each current
--     participant, in join order: LobbyDanceCoordinator:endLobbyDanceOfPlayerGoingOnStage, then
--     what the decider says (the scored outfit on their stage place with their dance; the lobby
--     appearance on stage for an empty scored outfit, owner decision Q23).
--   * Any later phase change while players are staged (normally Results): each staged player
--     still on the server is presented again, which the decider now answers with the lobby
--     appearance off the stage.
--   * The stored lobby outfit's availability changed (StoredLobbyOutfitKeeper; a SetLobbyOutfit,
--     the save loading, the catalog becoming ready): the lobby appearance, but only while the
--     decider says the player is not on stage.
--   * The player's lobby dance state changed (LobbyDanceCoordinator's subscription: started,
--     stopped, synced, the followed player changed, went on stage or left): the lobby appearance
--     with the new lobby dance, but only while the decider says the player is not on stage (going
--     on stage is presented by "Showcase begins" right after the coordinator's change).
--   * The save loaded or changed in memory (PlayerSaveDataKeeper) and the cosmetics to show
--     (LobbyDanceAndEquippedCosmeticsPresentationReader) differ from those last presented to that
--     player: what the decider says now, on stage or not. Such a presentation leaves a stage dance
--     that is already playing as it is (the presenter keeps an unchanged dance).
-- Every presentation is COMPLETE: it always carries the current lobby dance (off stage) and the
-- cosmetics to show, so a later presentation never undoes an earlier one by leaving a part out.
-- The lobby dance is never presented on stage; a lobby dance whose catalog entry has no usable
-- animation id is presented as no dance, with a warning.
-- The dance on stage is the player's equippedDanceId (DanceCatalog). An id the catalog does not
-- know, or one without an animation, falls back to the first dance granted to new players, with a
-- warning; with no usable dance at all the player stands on stage without dancing.
--
-- PUBLIC API
--   CharacterAppearanceAndStageDirector.new(dependencies) -> director
--     dependencies = { themedRoundClock, themedRoundReferee, playerSaveDataKeeper,
--       storedLobbyOutfitKeeper, lobbyDanceCoordinator, characterAppearancePresenter,
--       danceCatalog: { findDanceByDanceId, listDanceIdsGrantedToNewPlayers },
--       cosmeticCatalog: { findCosmeticByCosmeticId }, logger,
--       ownerDecisions: optional (ThemedRoundOwnerDecisions shape) }
--     characterAppearancePresenter:presentCharacterAppearance(playerUserId, presentation) must not
--     yield; presentation is frozen:
--       { outfitStylingItemKeysToWear: { string },   -- {} = the player's own avatar
--         stagePlaceNumber: number?,                  -- set exactly when the player is on stage
--         danceAnimationAssetId: string?,             -- set only on stage, when a dance is usable
--         lobbyDance: { danceId, danceAnimationAssetId, danceStartedAtUnixMilliseconds,
--           followedPlayerUserId? }?                  -- set only OFF stage, while the coordinator
--                                                     -- says the player dances in the lobby
--         equippedTitleCosmeticId: string?,           -- shown above the head (on and off stage)
--         equippedNameplateStyleCosmeticId: string?,  -- shown above the head (on and off stage)
--         stageEntranceEffectCosmeticId: string?,     -- only for "ShowcaseBegan" on stage: play once
--         characterSpawnAppearanceCase: string,       -- the decider's case
--         presentationReason: "CharacterSpawned" | "ShowcaseBegan" | "ShowcaseEnded" | "LobbyOutfitChanged"
--           | "LobbyDanceChanged" | "EquippedCosmeticsChanged" }
--   director:startDirectingCharacterAppearances()   subscribes to the clock, the outfit keeper, the
--     lobby dance coordinator and the save keeper (loaded and in-memory changes).
--     Create the referee BEFORE calling this, so at Showcase the referee has already scored.
--     Calling it twice raises.
--   director:handleCharacterSpawned(playerUserId)
--   director:forgetPlayer(playerUserId)   on leaving the server: no longer staged, and the cosmetics
--     last presented to them are forgotten
--   director:listStagedPlayerUserIds() -> { number }   sorted copy, for tests and diagnostics
-- A presenter or source that raises is logged as a warning and never stops the other players.

local CharacterSpawnAppearanceDecider = require("./CharacterSpawnAppearanceDecider")
local LobbyDanceAndEquippedCosmeticsPresentationReader = require("./LobbyDanceAndEquippedCosmeticsPresentationReader")
local LoggedErrorTextShortener = require("./LoggedErrorTextShortener")

local CharacterAppearanceAndStageDirector = {}
CharacterAppearanceAndStageDirector.__index = CharacterAppearanceAndStageDirector

local CASES = CharacterSpawnAppearanceDecider.CHARACTER_SPAWN_APPEARANCE_CASES
local SHOWCASE_PHASE = "Showcase"

local REQUIRED_DEPENDENCY_NAMES = table.freeze({
	"themedRoundClock",
	"themedRoundReferee",
	"playerSaveDataKeeper",
	"storedLobbyOutfitKeeper",
	"lobbyDanceCoordinator",
	"characterAppearancePresenter",
	"danceCatalog",
	"cosmeticCatalog",
	"logger",
})

function CharacterAppearanceAndStageDirector.new(dependencies)
	for _, dependencyName in REQUIRED_DEPENDENCY_NAMES do
		if type(dependencies) ~= "table" or dependencies[dependencyName] == nil then
			error("CharacterAppearanceAndStageDirector: missing " .. dependencyName, 2)
		end
	end
	return setmetatable({
		dependencies = dependencies,
		stagedPlayerUserIdSet = {} :: { [number]: boolean },
		presentedCosmeticsSignatureByPlayerUserId = {} :: { [number]: string },
		hasStarted = false,
	}, CharacterAppearanceAndStageDirector)
end

local function logWarning(self, message: string)
	self.dependencies.logger:logWarning("CharacterAppearanceAndStageDirector: " .. message)
end

local function decideAppearanceNow(self, playerUserId: number)
	local dependencies = self.dependencies
	local storedLobbyOutfitAvailability =
		dependencies.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(playerUserId)
	return CharacterSpawnAppearanceDecider.decideCharacterSpawnAppearance({
		isPlayerSaveDataLoaded = dependencies.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId),
		wearableLobbyOutfitStylingItemKeys = if storedLobbyOutfitAvailability
			then storedLobbyOutfitAvailability.wearableLobbyOutfitStylingItemKeys
			else nil,
		characterSpawnRoundFacts = dependencies.themedRoundReferee:readCharacterSpawnRoundFacts(playerUserId),
	}, dependencies.ownerDecisions)
end

local function findUsableDanceAnimationAssetId(danceCatalog, danceId: any): string?
	local dance = danceCatalog.findDanceByDanceId(danceId)
	if dance ~= nil and type(dance.danceAnimationAssetId) == "string" and dance.danceAnimationAssetId ~= "" then
		return dance.danceAnimationAssetId
	end
	return nil
end

local function chooseStageDanceAnimationAssetId(self, playerUserId: number): string?
	local dependencies = self.dependencies
	local saveDataCopy = dependencies.playerSaveDataKeeper:readPlayerSaveDataCopy(playerUserId)
	local equippedDanceId = if saveDataCopy then saveDataCopy.equippedDanceId else nil
	local danceAnimationAssetId = findUsableDanceAnimationAssetId(dependencies.danceCatalog, equippedDanceId)
	if danceAnimationAssetId ~= nil then
		return danceAnimationAssetId
	end
	logWarning(
		self,
		string.format("player %d has no usable equipped dance; using the first starter dance", playerUserId)
	)
	local starterDanceIds = dependencies.danceCatalog.listDanceIdsGrantedToNewPlayers()
	return findUsableDanceAnimationAssetId(dependencies.danceCatalog, starterDanceIds[1])
end

local function readLobbyDanceToPresent(self, playerUserId: number)
	local dependencies = self.dependencies
	local lobbyDance, unusableDanceId = LobbyDanceAndEquippedCosmeticsPresentationReader.readLobbyDanceToPresent(
		dependencies.lobbyDanceCoordinator,
		dependencies.danceCatalog,
		playerUserId
	)
	if unusableDanceId ~= nil then
		logWarning(
			self,
			string.format(
				"player %d dances %s in the lobby, which has no usable animation; no dance is shown",
				playerUserId,
				tostring(unusableDanceId)
			)
		)
	end
	return lobbyDance
end

local function readEquippedCosmeticIdsToPresent(self, playerUserId: number, saveDataCopy)
	local chosenSaveDataCopy = saveDataCopy
		or self.dependencies.playerSaveDataKeeper:readPlayerSaveDataCopy(playerUserId)
	return LobbyDanceAndEquippedCosmeticsPresentationReader.readEquippedCosmeticIdsToPresent(
		chosenSaveDataCopy,
		self.dependencies.cosmeticCatalog
	)
end

local function presentDecidedAppearance(
	self,
	playerUserId: number,
	presentationReason: string,
	characterSpawnAppearance
)
	local isOnStage = characterSpawnAppearance.stagePlaceNumber ~= nil
	local equippedCosmeticIds = readEquippedCosmeticIdsToPresent(self, playerUserId, nil)
	local presentation = table.freeze({
		outfitStylingItemKeysToWear = characterSpawnAppearance.outfitStylingItemKeysToWear,
		stagePlaceNumber = characterSpawnAppearance.stagePlaceNumber,
		danceAnimationAssetId = if isOnStage and characterSpawnAppearance.shouldRestartDance
			then chooseStageDanceAnimationAssetId(self, playerUserId)
			else nil,
		lobbyDance = if isOnStage then nil else readLobbyDanceToPresent(self, playerUserId),
		equippedTitleCosmeticId = equippedCosmeticIds.titleCosmeticId,
		equippedNameplateStyleCosmeticId = equippedCosmeticIds.nameplateStyleCosmeticId,
		stageEntranceEffectCosmeticId = if isOnStage and presentationReason == "ShowcaseBegan"
			then equippedCosmeticIds.stageEntranceEffectCosmeticId
			else nil,
		characterSpawnAppearanceCase = characterSpawnAppearance.characterSpawnAppearanceCase,
		presentationReason = presentationReason,
	})
	if isOnStage then
		self.stagedPlayerUserIdSet[playerUserId] = true
	end
	self.presentedCosmeticsSignatureByPlayerUserId[playerUserId] =
		LobbyDanceAndEquippedCosmeticsPresentationReader.buildEquippedCosmeticsSignature(equippedCosmeticIds)
	self.dependencies.characterAppearancePresenter:presentCharacterAppearance(playerUserId, presentation)
end

local function runForPlayerAndLogFailure(self, playerUserId: number, stepDescription: string, stepBody: () -> ())
	local didRun, raisedError = pcall(stepBody)
	if not didRun then
		logWarning(
			self,
			string.format(
				"%s for player %d raised: %s",
				stepDescription,
				playerUserId,
				LoggedErrorTextShortener.shortenErrorTextForLog(raisedError)
			)
		)
	end
end

local function handleShowcaseBegan(self)
	local dependencies = self.dependencies
	for _, participantUserId in dependencies.themedRoundReferee:listCurrentRoundParticipantUserIds() do
		runForPlayerAndLogFailure(self, participantUserId, "putting a participant on stage", function()
			dependencies.lobbyDanceCoordinator:endLobbyDanceOfPlayerGoingOnStage(participantUserId)
			presentDecidedAppearance(
				self,
				participantUserId,
				"ShowcaseBegan",
				decideAppearanceNow(self, participantUserId)
			)
		end)
	end
end

local function handleShowcaseEnded(self)
	local stagedPlayerUserIds = self:listStagedPlayerUserIds()
	table.clear(self.stagedPlayerUserIdSet)
	for _, stagedPlayerUserId in stagedPlayerUserIds do
		runForPlayerAndLogFailure(self, stagedPlayerUserId, "restoring the lobby appearance", function()
			presentDecidedAppearance(
				self,
				stagedPlayerUserId,
				"ShowcaseEnded",
				decideAppearanceNow(self, stagedPlayerUserId)
			)
		end)
	end
end

local function presentIfPlayerIsOffStage(self, playerUserId: number, presentationReason: string)
	local characterSpawnAppearance = decideAppearanceNow(self, playerUserId)
	local isLobbyCase = characterSpawnAppearance.characterSpawnAppearanceCase == CASES.LobbyAppearance
		or characterSpawnAppearance.characterSpawnAppearanceCase == CASES.LobbyAppearanceWhileStyling
	if isLobbyCase then
		presentDecidedAppearance(self, playerUserId, presentationReason, characterSpawnAppearance)
	end
end

local function handleLobbyOutfitAvailabilityChanged(self, playerUserId: number)
	runForPlayerAndLogFailure(self, playerUserId, "applying the changed lobby outfit", function()
		presentIfPlayerIsOffStage(self, playerUserId, "LobbyOutfitChanged")
	end)
end

local function handleLobbyDanceStateChanged(self, playerUserId: number)
	runForPlayerAndLogFailure(self, playerUserId, "applying the changed lobby dance", function()
		presentIfPlayerIsOffStage(self, playerUserId, "LobbyDanceChanged")
	end)
end

local NOTHING_PRESENTED_COSMETICS_SIGNATURE =
	LobbyDanceAndEquippedCosmeticsPresentationReader.buildEquippedCosmeticsSignature({})

local function handleSaveDataLoadedOrChanged(self, playerUserId: number, saveDataCopy)
	runForPlayerAndLogFailure(self, playerUserId, "applying the changed cosmetics", function()
		local cosmeticsSignature = LobbyDanceAndEquippedCosmeticsPresentationReader.buildEquippedCosmeticsSignature(
			readEquippedCosmeticIdsToPresent(self, playerUserId, saveDataCopy)
		)
		local presentedCosmeticsSignature = self.presentedCosmeticsSignatureByPlayerUserId[playerUserId]
			or NOTHING_PRESENTED_COSMETICS_SIGNATURE
		if cosmeticsSignature ~= presentedCosmeticsSignature then
			presentDecidedAppearance(
				self,
				playerUserId,
				"EquippedCosmeticsChanged",
				decideAppearanceNow(self, playerUserId)
			)
		end
	end)
end

function CharacterAppearanceAndStageDirector:startDirectingCharacterAppearances()
	if self.hasStarted then
		error("CharacterAppearanceAndStageDirector: already started", 2)
	end
	self.hasStarted = true
	self.dependencies.themedRoundClock:subscribeToRoundPhaseChanged(function(roundState)
		if roundState.roundPhase == SHOWCASE_PHASE then
			handleShowcaseBegan(self)
		elseif next(self.stagedPlayerUserIdSet) ~= nil then
			handleShowcaseEnded(self)
		end
	end)
	self.dependencies.storedLobbyOutfitKeeper:subscribeToStoredLobbyOutfitAvailabilityChanged(function(playerUserId)
		handleLobbyOutfitAvailabilityChanged(self, playerUserId)
	end)
	self.dependencies.lobbyDanceCoordinator:subscribeToLobbyDanceStateChanged(function(playerUserId)
		handleLobbyDanceStateChanged(self, playerUserId)
	end)
	local playerSaveDataKeeper = self.dependencies.playerSaveDataKeeper
	playerSaveDataKeeper:subscribeToPlayerSaveDataLoaded(function(playerUserId, loadedSaveDataCopy)
		handleSaveDataLoadedOrChanged(self, playerUserId, loadedSaveDataCopy)
	end)
	playerSaveDataKeeper:subscribeToInMemorySaveDataChanged(function(playerUserId, inMemorySaveDataCopy)
		handleSaveDataLoadedOrChanged(self, playerUserId, inMemorySaveDataCopy)
	end)
end

function CharacterAppearanceAndStageDirector:handleCharacterSpawned(playerUserId: number)
	runForPlayerAndLogFailure(self, playerUserId, "dressing a spawned character", function()
		presentDecidedAppearance(self, playerUserId, "CharacterSpawned", decideAppearanceNow(self, playerUserId))
	end)
end

function CharacterAppearanceAndStageDirector:forgetPlayer(playerUserId: number)
	self.stagedPlayerUserIdSet[playerUserId] = nil
	self.presentedCosmeticsSignatureByPlayerUserId[playerUserId] = nil
end

function CharacterAppearanceAndStageDirector:listStagedPlayerUserIds(): { number }
	local stagedPlayerUserIds = {}
	for stagedPlayerUserId in self.stagedPlayerUserIdSet do
		table.insert(stagedPlayerUserIds, stagedPlayerUserId)
	end
	table.sort(stagedPlayerUserIds)
	return stagedPlayerUserIds
end

return CharacterAppearanceAndStageDirector
