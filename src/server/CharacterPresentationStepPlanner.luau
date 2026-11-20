-- CharacterPresentationStepPlanner (development spec v1.3 §1.7, §2.4, §2.8, §3.7): the decisions of
-- RobloxCharacterShowcasePresenter, the ONE owner of what a player's character wears, where it
-- stands, what it dances and what it shows above its head. Given what the presenter has already
-- applied to the current character and the newest presentation (CharacterAppearanceAndStageDirector's
-- header), it says which steps to take. The Roblox file only carries the steps out.
-- Pure logic: no Roblox-specific interface is used.
--
-- Rules:
--   * Outfit: dressed only when the outfit differs from what this character wears ("" = the
--     player's own avatar, which a new character wears).
--   * Place: moved onto a stage place when the presentation names a place the character does not
--     stand on yet; moved to the floor in front of its last place when the presentation is off
--     stage and the character stood on stage; otherwise left where it is.
--   * Dance: one dance at a time. On stage the stage dance (danceAnimationAssetId); off stage the
--     lobby dance (lobbyDance), started at the position in its loop that its start moment gives
--     (LobbyDanceLoopTimePositionCalculator). A dance identical to the one playing (same place
--     and animation on stage; same animation and start moment in the lobby) keeps playing, so a
--     presentation that changes something else never restarts it. No dance -> stopped.
--   * Above the head: the equipped Title (its text) and NameplateStyle (its look), resolved
--     through CosmeticPresentationCatalog; an id it does not know is shown as nothing. Shown
--     again whenever the outfit was dressed (applying an outfit may rebuild the head); removed
--     when nothing is equipped any more.
--   * Stage entrance effect: played when the presentation carries one and the character is on a
--     stage place after this presentation (the director sets it only at the start of Showcase).
--   * mergeWaitingPresentation: the presenter keeps only the latest waiting presentation; an
--     entrance effect waiting to be played is carried into a newer presentation for the same
--     stage place, so a quick respawn or cosmetic change at the start of Showcase cannot swallow
--     it. It is dropped when the newer presentation is off stage or on another place.
--
-- PUBLIC API
--   Planner.createAppliedStateOfNewCharacter() -> appliedCharacterState (a new mutable table)
--     { wornOutfitSignature = "", stagePlaceNumberStoodOn = nil, playingDanceSignature = nil,
--       shownOverheadCosmeticsSignature = "" }
--   Planner.planPresentationSteps(appliedCharacterState, presentation, cosmeticCatalog?,
--       cosmeticPresentationCatalog?) -> plan (frozen)
--     cosmeticCatalog: default src/shared/CosmeticCatalog. cosmeticPresentationCatalog: default
--     src/shared/CosmeticPresentationCatalog (findCosmeticPresentation(id, cosmeticCatalog)); tests
--     pass a faulty one to check that this planner itself never uses a presentation of the wrong
--     kind (a Title or NameplateStyle id never plays as an entrance effect, and so on).
--     plan = {
--       shouldDressOutfit: boolean, outfitSignature: string,
--       placementStep: "MoveOntoStagePlace" | "MoveToFloorInFrontOfStagePlace" | "StayInPlace",
--       placementStagePlaceNumber: number?,
--       danceStep: "KeepDanceAsItIs" | "StopDance" | "StartStageDance" | "StartLobbyDanceInTime",
--       danceAnimationAssetId: string?, danceStartedAtUnixMilliseconds: number?,
--       danceSignature: string?,          the playingDanceSignature once the step is done
--       overheadCosmeticsStep: "KeepOverheadCosmetics" | "ShowOverheadCosmetics" | "RemoveOverheadCosmetics",
--       overheadCosmetics: { titleText: string?, nameplateStyleLook: NameplateStyleLook? }?,
--       overheadCosmeticsSignature: string,
--       stageEntranceEffectLookToPlay: StageEntranceEffectLook?,
--     }
--   Planner.mergeWaitingPresentation(waitingPresentation?, newerPresentation) -> presentation

local CosmeticPresentationCatalog = require("../shared/CosmeticPresentationCatalog")

local CharacterPresentationStepPlanner = {}

function CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter()
	return {
		wornOutfitSignature = "",
		stagePlaceNumberStoodOn = nil,
		playingDanceSignature = nil,
		shownOverheadCosmeticsSignature = "",
	}
end

local function planPlacement(appliedCharacterState, presentation): (string, number?)
	if presentation.stagePlaceNumber ~= nil then
		if presentation.stagePlaceNumber ~= appliedCharacterState.stagePlaceNumberStoodOn then
			return "MoveOntoStagePlace", presentation.stagePlaceNumber
		end
		return "StayInPlace", nil
	end
	if appliedCharacterState.stagePlaceNumberStoodOn ~= nil then
		return "MoveToFloorInFrontOfStagePlace", appliedCharacterState.stagePlaceNumberStoodOn
	end
	return "StayInPlace", nil
end

local function planDance(appliedCharacterState, presentation)
	local danceStep, danceAnimationAssetId, danceStartedAtUnixMilliseconds, danceSignature
	if presentation.stagePlaceNumber ~= nil and presentation.danceAnimationAssetId ~= nil then
		danceStep = "StartStageDance"
		danceAnimationAssetId = presentation.danceAnimationAssetId
		danceSignature = string.format("stage/%d/%s", presentation.stagePlaceNumber, danceAnimationAssetId)
	elseif presentation.stagePlaceNumber == nil and presentation.lobbyDance ~= nil then
		danceStep = "StartLobbyDanceInTime"
		danceAnimationAssetId = presentation.lobbyDance.danceAnimationAssetId
		danceStartedAtUnixMilliseconds = presentation.lobbyDance.danceStartedAtUnixMilliseconds
		danceSignature = string.format("lobby/%s/%s", danceAnimationAssetId, tostring(danceStartedAtUnixMilliseconds))
	end
	if danceSignature == appliedCharacterState.playingDanceSignature then
		return { danceStep = "KeepDanceAsItIs", danceSignature = danceSignature }
	end
	if danceSignature == nil then
		return { danceStep = "StopDance" }
	end
	return {
		danceStep = danceStep,
		danceAnimationAssetId = danceAnimationAssetId,
		danceStartedAtUnixMilliseconds = danceStartedAtUnixMilliseconds,
		danceSignature = danceSignature,
	}
end

local function readOverheadCosmetics(presentation, cosmeticCatalog, cosmeticPresentationCatalog)
	local titlePresentation =
		cosmeticPresentationCatalog.findCosmeticPresentation(presentation.equippedTitleCosmeticId, cosmeticCatalog)
	local nameplatePresentation = cosmeticPresentationCatalog.findCosmeticPresentation(
		presentation.equippedNameplateStyleCosmeticId,
		cosmeticCatalog
	)
	local titleText = if titlePresentation and titlePresentation.cosmeticKind == "Title"
		then titlePresentation.titleText
		else nil
	local nameplateStyleLook = if nameplatePresentation
			and nameplatePresentation.cosmeticKind == "NameplateStyle"
		then nameplatePresentation.nameplateStyleLook
		else nil
	if titleText == nil and nameplateStyleLook == nil then
		return nil, ""
	end
	local signature = string.format(
		"%s|%s",
		if titleText then presentation.equippedTitleCosmeticId else "",
		if nameplateStyleLook then presentation.equippedNameplateStyleCosmeticId else ""
	)
	return table.freeze({ titleText = titleText, nameplateStyleLook = nameplateStyleLook }), signature
end

local function planOverheadStep(appliedCharacterState, overheadCosmetics, signature: string, shouldDressOutfit: boolean)
	if overheadCosmetics == nil then
		if appliedCharacterState.shownOverheadCosmeticsSignature == "" then
			return "KeepOverheadCosmetics"
		end
		return "RemoveOverheadCosmetics"
	end
	if shouldDressOutfit or signature ~= appliedCharacterState.shownOverheadCosmeticsSignature then
		return "ShowOverheadCosmetics"
	end
	return "KeepOverheadCosmetics"
end

local function readStageEntranceEffectLookToPlay(presentation, cosmeticCatalog, cosmeticPresentationCatalog)
	if presentation.stagePlaceNumber == nil or presentation.stageEntranceEffectCosmeticId == nil then
		return nil
	end
	local effectPresentation = cosmeticPresentationCatalog.findCosmeticPresentation(
		presentation.stageEntranceEffectCosmeticId,
		cosmeticCatalog
	)
	if effectPresentation == nil or effectPresentation.cosmeticKind ~= "StageEntranceEffect" then
		return nil
	end
	return effectPresentation.stageEntranceEffectLook
end

function CharacterPresentationStepPlanner.planPresentationSteps(
	appliedCharacterState,
	presentation,
	cosmeticCatalog,
	cosmeticPresentationCatalog
)
	local chosenCosmeticPresentationCatalog = cosmeticPresentationCatalog or CosmeticPresentationCatalog
	local outfitSignature = table.concat(presentation.outfitStylingItemKeysToWear, ",")
	local shouldDressOutfit = outfitSignature ~= appliedCharacterState.wornOutfitSignature
	local placementStep, placementStagePlaceNumber = planPlacement(appliedCharacterState, presentation)
	local dancePlan = planDance(appliedCharacterState, presentation)
	local overheadCosmetics, overheadCosmeticsSignature =
		readOverheadCosmetics(presentation, cosmeticCatalog, chosenCosmeticPresentationCatalog)
	return table.freeze({
		shouldDressOutfit = shouldDressOutfit,
		outfitSignature = outfitSignature,
		placementStep = placementStep,
		placementStagePlaceNumber = placementStagePlaceNumber,
		danceStep = dancePlan.danceStep,
		danceAnimationAssetId = dancePlan.danceAnimationAssetId,
		danceStartedAtUnixMilliseconds = dancePlan.danceStartedAtUnixMilliseconds,
		danceSignature = dancePlan.danceSignature,
		overheadCosmeticsStep = planOverheadStep(
			appliedCharacterState,
			overheadCosmetics,
			overheadCosmeticsSignature,
			shouldDressOutfit
		),
		overheadCosmetics = overheadCosmetics,
		overheadCosmeticsSignature = overheadCosmeticsSignature,
		stageEntranceEffectLookToPlay = readStageEntranceEffectLookToPlay(
			presentation,
			cosmeticCatalog,
			chosenCosmeticPresentationCatalog
		),
	})
end

function CharacterPresentationStepPlanner.mergeWaitingPresentation(waitingPresentation, newerPresentation)
	if
		waitingPresentation == nil
		or waitingPresentation.stageEntranceEffectCosmeticId == nil
		or newerPresentation.stageEntranceEffectCosmeticId ~= nil
		or newerPresentation.stagePlaceNumber == nil
		or newerPresentation.stagePlaceNumber ~= waitingPresentation.stagePlaceNumber
	then
		return newerPresentation
	end
	local mergedPresentation = table.clone(newerPresentation)
	mergedPresentation.stageEntranceEffectCosmeticId = waitingPresentation.stageEntranceEffectCosmeticId
	return table.freeze(mergedPresentation)
end

return table.freeze(CharacterPresentationStepPlanner)
