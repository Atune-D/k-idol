-- RobloxCharacterShowcasePresenter (development spec v1.3 §1.7, §2.4, §2.8, §3.7, §3.8; gates 1G,
-- 2C, 2D): the `characterAppearancePresenter` CharacterAppearanceAndStageDirector drives, and the
-- ONE owner of what a player's character wears, where it stands, what it dances (on stage AND in
-- the lobby) and what it shows above its head. It turns each presentation into the real character:
-- CharacterPresentationStepPlanner decides the steps; PlayerCharacterDresser dresses, the stage
-- builder gives the standing point, RobloxCharacterDancePlayer plays the dance,
-- RobloxCharacterOverheadCosmeticDisplay shows the Title and NameplateStyle and
-- RobloxStageEntranceEffectPlayer plays the entrance effect.
--
-- Rules:
--   * presentCharacterAppearance never yields. Per player one worker thread applies the LATEST
--     presentation; a newer one arriving while a dress is being applied replaces any waiting one
--     (only the latest matters; an entrance effect still waiting is carried over by
--     CharacterPresentationStepPlanner.mergeWaitingPresentation), so two dresses of one character
--     never overlap and nothing else ever plays or dresses on the character.
--   * A presentation is applied to the player's CURRENT character once its appearance has loaded
--     and it is in the world. No character (not spawned yet): nothing is done; the next spawn
--     brings its own presentation (with the lobby dance, so a respawned lobby dancer dances again).
--   * The player's own avatar ("an empty list means the player's own Roblox avatar", §2.4) is the
--     character's applied description captured the first time a presentation meets a new
--     character, before this presenter changes anything (Roblox spawns every character in the
--     player's own avatar).
--   * Steps, in order: dress (only when the outfit differs), place (onto a new stage place facing
--     the audience, or back to the floor in front of the stage), dance (keep an identical dance,
--     else stop and start the new one: a stage dance from its start, a lobby dance in time with
--     its start moment), above-the-head cosmetics, the entrance effect once at the feet.
--   * 🔴 Gate 1G: Players.RespawnTime is 5 s by default, longer than the 3 s the gate allows. When
--     a character standing on stage dies (a reset), the presenter respawns that player after
--     STAGE_RESPAWN_DELAY_SECONDS with Player:LoadCharacterAsync; the spawn then goes through the
--     director like any spawn (back on stage, scored outfit, dancing). Nothing changes for anyone
--     off stage.
--   * Each application is logged with what was worn, danced and shown and how long it took.
--
-- PUBLIC API
--   RobloxCharacterShowcasePresenter.STAGE_RESPAWN_DELAY_SECONDS = 0.25
--   RobloxCharacterShowcasePresenter.new({ playerCharacterDresser, logger, clock, cosmeticCatalog? }) -> presenter
--     clock: { getCurrentUnixMilliseconds } (the clock the lobby dance coordinator uses);
--     cosmeticCatalog: default src/shared/CosmeticCatalog. Raises when clock is missing.
--   presenter:presentCharacterAppearance(playerUserId, presentation)   (see the director's header)
--   presenter:forgetPlayer(playerUserId)   on leaving: stops the dance and drops the state
--
-- Roblox API used, read in the official documentation while writing this file:
--   Players:GetPlayerByUserId, Player.Character, Player.DisplayName, Player:HasAppearanceLoaded,
--   Player.CharacterAppearanceLoaded, Player:LoadCharacterAsync (LoadCharacter is deprecated;
--   "It isn't recommended to call it again ... until CharacterAppearanceLoaded has fired"; the
--   character is moved to the spawn location AFTER CharacterAppearanceLoaded, so this waits for the
--   character to be in the world before moving it)
--                       https://create.roblox.com/docs/reference/engine/classes/Player
--                       https://create.roblox.com/docs/reference/engine/classes/Players
--   Humanoid.Died, Humanoid.HipHeight
--                       https://create.roblox.com/docs/reference/engine/classes/Humanoid
--   Model.PrimaryPart, PVInstance:PivotTo
--                       https://create.roblox.com/docs/reference/engine/classes/Model
--                       https://create.roblox.com/docs/reference/engine/classes/PVInstance
--   BasePart.Size       https://create.roblox.com/docs/reference/engine/classes/BasePart
--   Instance:IsDescendantOf, :FindFirstChild, :FindFirstChildOfClass
--                       https://create.roblox.com/docs/reference/engine/classes/Instance
--   task.spawn, task.wait, task.delay, os.clock
--                       https://create.roblox.com/docs/reference/engine/libraries/task
--                       https://create.roblox.com/docs/reference/engine/libraries/os

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local CharacterPresentationStepPlanner = require("./CharacterPresentationStepPlanner")
local LoggedErrorTextShortener = require("./LoggedErrorTextShortener")
local PlayerCharacterDresser = require("./PlayerCharacterDresser")
local RobloxCharacterDancePlayer = require("./RobloxCharacterDancePlayer")
local RobloxCharacterOverheadCosmeticDisplay = require("./RobloxCharacterOverheadCosmeticDisplay")
local RobloxStageEntranceEffectPlayer = require("./RobloxStageEntranceEffectPlayer")
local RobloxThemedRoundStageBuilder = require("./RobloxThemedRoundStageBuilder")

local RobloxCharacterShowcasePresenter = {}
RobloxCharacterShowcasePresenter.__index = RobloxCharacterShowcasePresenter

RobloxCharacterShowcasePresenter.STAGE_RESPAWN_DELAY_SECONDS = 0.25

local CHARACTER_READY_TIMEOUT_SECONDS = 10

function RobloxCharacterShowcasePresenter.new(dependencies)
	if dependencies.clock == nil then
		error("RobloxCharacterShowcasePresenter: missing clock", 2)
	end
	return setmetatable({
		playerCharacterDresser = dependencies.playerCharacterDresser,
		logger = dependencies.logger,
		clock = dependencies.clock,
		cosmeticCatalog = dependencies.cosmeticCatalog,
		presentationStateByPlayerUserId = {},
	}, RobloxCharacterShowcasePresenter)
end

local function readOrCreatePresentationState(self, playerUserId: number)
	local presentationState = self.presentationStateByPlayerUserId[playerUserId]
	if presentationState == nil then
		presentationState = {
			waitingPresentation = nil,
			waitingPresentationRequestedAtClock = 0,
			isWorkerRunning = false,
			trackedCharacter = nil,
			ownAvatarDescription = nil,
			appliedCharacterState = CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter(),
			danceTrack = nil,
		}
		self.presentationStateByPlayerUserId[playerUserId] = presentationState
	end
	return presentationState
end

-- Waits (yielding only this worker) until the character's appearance has loaded and it is in the
-- world with a root part. Returns false when that does not happen in time or it was replaced.
local function waitUntilCharacterIsReady(player: Player, character: Model): boolean
	local startedAtClock = os.clock()
	while os.clock() - startedAtClock < CHARACTER_READY_TIMEOUT_SECONDS do
		if player.Character ~= character then
			return false
		end
		if player:HasAppearanceLoaded() and character:IsDescendantOf(Workspace) and character.PrimaryPart ~= nil then
			return true
		end
		task.wait()
	end
	return false
end

local function readRootPartHeightAboveFloor(character: Model): number
	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid
	return humanoid.HipHeight + (character.PrimaryPart :: BasePart).Size.Y / 2
end

local function respawnPlayerQuicklyWhenStagedCharacterDies(self, player: Player, character: Model, presentationState)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end
	humanoid.Died:Once(function()
		if
			presentationState.trackedCharacter ~= character
			or presentationState.appliedCharacterState.stagePlaceNumberStoodOn == nil
		then
			return
		end
		self.logger:logInformation(
			string.format("RobloxCharacterShowcasePresenter: player %d died on stage; respawning", player.UserId)
		)
		task.delay(RobloxCharacterShowcasePresenter.STAGE_RESPAWN_DELAY_SECONDS, function()
			if player.Parent ~= nil and player.Character == character then
				player:LoadCharacterAsync()
			end
		end)
	end)
end

local function startTrackingNewCharacter(self, player: Player, character: Model, presentationState)
	presentationState.trackedCharacter = character
	presentationState.ownAvatarDescription = self.playerCharacterDresser:readAppliedDescriptionCopy(character)
	presentationState.appliedCharacterState = CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter()
	presentationState.danceTrack = nil
	respawnPlayerQuicklyWhenStagedCharacterDies(self, player, character, presentationState)
end

local function dressCharacter(self, character: Model, presentationState, outfitStylingItemKeys, outfitSignature)
	if #outfitStylingItemKeys == 0 then
		self.playerCharacterDresser:applyOwnAvatarDescription(character, presentationState.ownAvatarDescription)
	else
		self.playerCharacterDresser:dressCharacterInOutfit(character, outfitStylingItemKeys)
	end
	presentationState.appliedCharacterState.wornOutfitSignature = outfitSignature
end

local function placeCharacter(character: Model, presentationState, presentationPlan)
	local appliedCharacterState = presentationState.appliedCharacterState
	if presentationPlan.placementStep == "MoveOntoStagePlace" then
		character:PivotTo(
			RobloxThemedRoundStageBuilder.buildPerformerStandingCFrameOnStagePlace(
				presentationPlan.placementStagePlaceNumber,
				readRootPartHeightAboveFloor(character)
			)
		)
		appliedCharacterState.stagePlaceNumberStoodOn = presentationPlan.placementStagePlaceNumber
	elseif presentationPlan.placementStep == "MoveToFloorInFrontOfStagePlace" then
		character:PivotTo(
			RobloxThemedRoundStageBuilder.buildLobbyReturnCFrame(
				presentationPlan.placementStagePlaceNumber,
				readRootPartHeightAboveFloor(character)
			)
		)
		appliedCharacterState.stagePlaceNumberStoodOn = nil
	end
end

local function setDance(self, character: Model, presentationState, presentationPlan)
	if presentationPlan.danceStep == "KeepDanceAsItIs" then
		return
	end
	RobloxCharacterDancePlayer.stopDance(presentationState.danceTrack)
	presentationState.danceTrack = nil
	presentationState.appliedCharacterState.playingDanceSignature = nil
	if presentationPlan.danceStep == "StartStageDance" then
		presentationState.danceTrack =
			RobloxCharacterDancePlayer.startLoopingDance(character, presentationPlan.danceAnimationAssetId)
	elseif presentationPlan.danceStep == "StartLobbyDanceInTime" then
		presentationState.danceTrack = RobloxCharacterDancePlayer.startLoopingDanceInTime(
			character,
			presentationPlan.danceAnimationAssetId,
			presentationPlan.danceStartedAtUnixMilliseconds,
			self.clock,
			self.logger
		)
	end
	if presentationState.danceTrack ~= nil then
		presentationState.appliedCharacterState.playingDanceSignature = presentationPlan.danceSignature
	end
end

local function setOverheadCosmetics(player: Player, character: Model, presentationState, presentationPlan)
	if presentationPlan.overheadCosmeticsStep == "ShowOverheadCosmetics" then
		RobloxCharacterOverheadCosmeticDisplay.showOverheadCosmetics(
			character,
			player.DisplayName,
			presentationPlan.overheadCosmetics
		)
	elseif presentationPlan.overheadCosmeticsStep == "RemoveOverheadCosmetics" then
		RobloxCharacterOverheadCosmeticDisplay.removeOverheadCosmetics(character)
	else
		return
	end
	presentationState.appliedCharacterState.shownOverheadCosmeticsSignature =
		presentationPlan.overheadCosmeticsSignature
end

local function playStageEntranceEffectIfAny(presentationState, presentationPlan): string
	local stagePlaceNumberStoodOn = presentationState.appliedCharacterState.stagePlaceNumberStoodOn
	if presentationPlan.stageEntranceEffectLookToPlay == nil or stagePlaceNumberStoodOn == nil then
		return "none"
	end
	local performerFeetCFrame =
		RobloxThemedRoundStageBuilder.buildPerformerStandingCFrameOnStagePlace(stagePlaceNumberStoodOn, 0)
	RobloxStageEntranceEffectPlayer.playStageEntranceEffectOnce(
		performerFeetCFrame,
		presentationPlan.stageEntranceEffectLookToPlay
	)
	return presentationPlan.stageEntranceEffectLookToPlay.stageEntranceEffectCosmeticId
end

local function applyPresentation(self, playerUserId: number, presentationState, presentation, requestedAtClock: number)
	local player = Players:GetPlayerByUserId(playerUserId)
	local character = if player then player.Character else nil
	if player == nil or character == nil or not waitUntilCharacterIsReady(player, character) then
		return
	end
	if presentationState.trackedCharacter ~= character then
		startTrackingNewCharacter(self, player, character, presentationState)
	end
	local presentationPlan = CharacterPresentationStepPlanner.planPresentationSteps(
		presentationState.appliedCharacterState,
		presentation,
		self.cosmeticCatalog
	)
	if presentationPlan.shouldDressOutfit then
		dressCharacter(
			self,
			character,
			presentationState,
			presentation.outfitStylingItemKeysToWear,
			presentationPlan.outfitSignature
		)
		if player.Character ~= character then
			return
		end
	end
	placeCharacter(character, presentationState, presentationPlan)
	setDance(self, character, presentationState, presentationPlan)
	setOverheadCosmetics(player, character, presentationState, presentationPlan)
	local playedEntranceEffect = playStageEntranceEffectIfAny(presentationState, presentationPlan)
	self.logger:logInformation(
		string.format(
			"RobloxCharacterShowcasePresenter: player %d %s (%s): stage place %s, %s %s%s, wearing [%s], above head [%s], entrance effect %s; applied %.2f s after the request",
			playerUserId,
			presentation.presentationReason,
			presentation.characterSpawnAppearanceCase,
			tostring(presentation.stagePlaceNumber),
			presentationPlan.danceStep,
			tostring(presentationState.appliedCharacterState.playingDanceSignature),
			if presentation.lobbyDance and presentation.lobbyDance.followedPlayerUserId
				then " following " .. tostring(presentation.lobbyDance.followedPlayerUserId)
				else "",
			table.concat(presentation.outfitStylingItemKeysToWear, ", "),
			presentationState.appliedCharacterState.shownOverheadCosmeticsSignature,
			playedEntranceEffect,
			os.clock() - requestedAtClock
		)
	)
end

local function runPresentationWorker(self, playerUserId: number, presentationState)
	while presentationState.waitingPresentation ~= nil do
		local presentation = presentationState.waitingPresentation
		local requestedAtClock = presentationState.waitingPresentationRequestedAtClock
		presentationState.waitingPresentation = nil
		local didApply, raisedError =
			pcall(applyPresentation, self, playerUserId, presentationState, presentation, requestedAtClock)
		if not didApply then
			self.logger:logWarning(
				string.format(
					"RobloxCharacterShowcasePresenter: presenting %s for player %d raised: %s",
					tostring(presentation.presentationReason),
					playerUserId,
					LoggedErrorTextShortener.shortenErrorTextForLog(raisedError)
				)
			)
		end
	end
	presentationState.isWorkerRunning = false
end

function RobloxCharacterShowcasePresenter:presentCharacterAppearance(playerUserId: number, presentation)
	local presentationState = readOrCreatePresentationState(self, playerUserId)
	presentationState.waitingPresentation =
		CharacterPresentationStepPlanner.mergeWaitingPresentation(presentationState.waitingPresentation, presentation)
	presentationState.waitingPresentationRequestedAtClock = os.clock()
	if not presentationState.isWorkerRunning then
		presentationState.isWorkerRunning = true
		task.spawn(runPresentationWorker, self, playerUserId, presentationState)
	end
end

function RobloxCharacterShowcasePresenter:forgetPlayer(playerUserId: number)
	local presentationState = self.presentationStateByPlayerUserId[playerUserId]
	if presentationState == nil then
		return
	end
	presentationState.waitingPresentation = nil
	presentationState.trackedCharacter = nil
	RobloxCharacterDancePlayer.stopDance(presentationState.danceTrack)
	presentationState.danceTrack = nil
	self.presentationStateByPlayerUserId[playerUserId] = nil
end

-- Exposed for the Studio checks: what the character wears now.
RobloxCharacterShowcasePresenter.listWornAccessoryAndClothingNames =
	PlayerCharacterDresser.listWornAccessoryAndClothingNames

return RobloxCharacterShowcasePresenter
