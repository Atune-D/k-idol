-- CharacterPresentationStepPlanner: the decisions of the one presenter that owns a character.

local UnitTestFramework = require("../Support/UnitTestFramework")
local CharacterPresentationStepPlanner = require("../../src/server/CharacterPresentationStepPlanner")
local NameplateStyleLookCatalog = require("../../src/shared/NameplateStyleLookCatalog")
local StageEntranceEffectLookCatalog = require("../../src/shared/StageEntranceEffectLookCatalog")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local plan = CharacterPresentationStepPlanner.planPresentationSteps
local HAIR = "asset_7259123616"
local GROOVE = "rbxassetid://507771019"
local BOUNCE = "rbxassetid://507776043"
local STARTED_AT = 1_800_000_000_000

local function presentation(fields)
	local built = {
		outfitStylingItemKeysToWear = {},
		characterSpawnAppearanceCase = "LobbyAppearance",
		presentationReason = "CharacterSpawned",
	}
	for fieldName, fieldValue in fields do
		built[fieldName] = fieldValue
	end
	return table.freeze(built)
end

local function lobbyDance(danceAnimationAssetId: string, danceStartedAtUnixMilliseconds: number)
	return table.freeze({
		danceId = "starter",
		danceAnimationAssetId = danceAnimationAssetId,
		danceStartedAtUnixMilliseconds = danceStartedAtUnixMilliseconds,
	})
end

-- Records a plan into an applied state, as the presenter does after carrying it out.
local function applyPlan(appliedCharacterState, presentationPlan)
	appliedCharacterState.wornOutfitSignature = presentationPlan.outfitSignature
	if presentationPlan.placementStep == "MoveOntoStagePlace" then
		appliedCharacterState.stagePlaceNumberStoodOn = presentationPlan.placementStagePlaceNumber
	elseif presentationPlan.placementStep == "MoveToFloorInFrontOfStagePlace" then
		appliedCharacterState.stagePlaceNumberStoodOn = nil
	end
	appliedCharacterState.playingDanceSignature = presentationPlan.danceSignature
	if presentationPlan.overheadCosmeticsStep ~= "KeepOverheadCosmetics" then
		appliedCharacterState.shownOverheadCosmeticsSignature = presentationPlan.overheadCosmeticsSignature
	end
end

describe("CharacterPresentationStepPlanner", function()
	it("starts a new character in the player's own avatar, off stage, not dancing, nothing above the head", function()
		expect(CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter()).toEqual({
			wornOutfitSignature = "",
			shownOverheadCosmeticsSignature = "",
		})
		local stepsForNothing =
			plan(CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter(), presentation({}))
		expect(stepsForNothing.shouldDressOutfit).toBeFalse()
		expect(stepsForNothing.placementStep).toBe("StayInPlace")
		expect(stepsForNothing.danceStep).toBe("KeepDanceAsItIs")
		expect(stepsForNothing.overheadCosmeticsStep).toBe("KeepOverheadCosmetics")
		expect(stepsForNothing.stageEntranceEffectLookToPlay).toBeNil()
	end)

	it("dresses only when the outfit differs from what the character wears", function()
		local applied = CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter()
		local withHair = plan(applied, presentation({ outfitStylingItemKeysToWear = { HAIR } }))
		expect(withHair.shouldDressOutfit).toBeTrue()
		applyPlan(applied, withHair)
		expect(plan(applied, presentation({ outfitStylingItemKeysToWear = { HAIR } })).shouldDressOutfit).toBeFalse()
		expect(plan(applied, presentation({})).shouldDressOutfit).toBeTrue()
	end)

	it("starts a lobby dance in time with its start moment, and keeps it when only something else changes", function()
		local applied = CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter()
		local start = plan(applied, presentation({ lobbyDance = lobbyDance(GROOVE, STARTED_AT) }))
		expect(start.danceStep).toBe("StartLobbyDanceInTime")
		expect(start.danceAnimationAssetId).toBe(GROOVE)
		expect(start.danceStartedAtUnixMilliseconds).toBe(STARTED_AT)
		applyPlan(applied, start)
		local cosmeticChange = plan(
			applied,
			presentation({ lobbyDance = lobbyDance(GROOVE, STARTED_AT), equippedTitleCosmeticId = "title_superstar" })
		)
		expect(cosmeticChange.danceStep).toBe("KeepDanceAsItIs")
		expect(cosmeticChange.overheadCosmeticsStep).toBe("ShowOverheadCosmetics")
	end)

	it("restarts the lobby dance for another dance or another start moment (a new sync), and stops it", function()
		local applied = CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter()
		applyPlan(applied, plan(applied, presentation({ lobbyDance = lobbyDance(GROOVE, STARTED_AT) })))
		expect(plan(applied, presentation({ lobbyDance = lobbyDance(BOUNCE, STARTED_AT) })).danceStep).toBe(
			"StartLobbyDanceInTime"
		)
		local resynced = plan(applied, presentation({ lobbyDance = lobbyDance(GROOVE, STARTED_AT - 4_000) }))
		expect(resynced.danceStep).toBe("StartLobbyDanceInTime")
		expect(resynced.danceStartedAtUnixMilliseconds).toBe(STARTED_AT - 4_000)
		local stopped = plan(applied, presentation({}))
		expect(stopped.danceStep).toBe("StopDance")
		expect(stopped.danceSignature).toBeNil()
	end)

	it("goes on stage: moves onto the place, replaces the lobby dance by the stage dance", function()
		local applied = CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter()
		applyPlan(applied, plan(applied, presentation({ lobbyDance = lobbyDance(GROOVE, STARTED_AT) })))
		-- The director never sends a lobby dance on stage; even if one came, the stage dance wins.
		local onStage = plan(
			applied,
			presentation({
				stagePlaceNumber = 3,
				danceAnimationAssetId = BOUNCE,
				lobbyDance = lobbyDance(GROOVE, STARTED_AT),
				characterSpawnAppearanceCase = "ScoredOutfitOnStage",
				presentationReason = "ShowcaseBegan",
			})
		)
		expect(onStage.placementStep).toBe("MoveOntoStagePlace")
		expect(onStage.placementStagePlaceNumber).toBe(3)
		expect(onStage.danceStep).toBe("StartStageDance")
		expect(onStage.danceAnimationAssetId).toBe(BOUNCE)
		applyPlan(applied, onStage)
		local cosmeticOnStage = plan(
			applied,
			presentation({
				stagePlaceNumber = 3,
				danceAnimationAssetId = BOUNCE,
				equippedTitleCosmeticId = "title_superstar",
			})
		)
		expect(cosmeticOnStage.placementStep).toBe("StayInPlace")
		expect(cosmeticOnStage.danceStep).toBe("KeepDanceAsItIs")
		local onStageWithoutDance = plan(applied, presentation({ stagePlaceNumber = 3 }))
		expect(onStageWithoutDance.danceStep).toBe("StopDance")
	end)

	it("comes off stage after the round: back to the floor in front of the place, not dancing", function()
		local applied = CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter()
		applyPlan(applied, plan(applied, presentation({ stagePlaceNumber = 2, danceAnimationAssetId = GROOVE })))
		local offStage = plan(applied, presentation({ presentationReason = "ShowcaseEnded" }))
		expect(offStage.placementStep).toBe("MoveToFloorInFrontOfStagePlace")
		expect(offStage.placementStagePlaceNumber).toBe(2)
		expect(offStage.danceStep).toBe("StopDance")
		applyPlan(applied, offStage)
		expect(plan(applied, presentation({})).placementStep).toBe("StayInPlace")
	end)

	it("shows the title text and nameplate look above the head, replaces and removes them", function()
		local applied = CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter()
		local both = plan(
			applied,
			presentation({
				equippedTitleCosmeticId = "title_rising_star",
				equippedNameplateStyleCosmeticId = "nameplate_neon_glow",
			})
		)
		expect(both.overheadCosmeticsStep).toBe("ShowOverheadCosmetics")
		expect(both.overheadCosmetics.titleText).toBe("Rising Star")
		expect(both.overheadCosmetics.nameplateStyleLook).toBe(
			NameplateStyleLookCatalog.findNameplateStyleLook("nameplate_neon_glow")
		)
		applyPlan(applied, both)
		local replacedTitle = plan(
			applied,
			presentation({
				equippedTitleCosmeticId = "title_superstar",
				equippedNameplateStyleCosmeticId = "nameplate_neon_glow",
			})
		)
		expect(replacedTitle.overheadCosmeticsStep).toBe("ShowOverheadCosmetics")
		expect(replacedTitle.overheadCosmetics.titleText).toBe("Superstar")
		applyPlan(applied, replacedTitle)
		local removed = plan(applied, presentation({}))
		expect(removed.overheadCosmeticsStep).toBe("RemoveOverheadCosmetics")
		expect(removed.overheadCosmetics).toBeNil()
	end)

	it("shows the cosmetics again after dressing (applying an outfit may rebuild the head)", function()
		local applied = CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter()
		applyPlan(applied, plan(applied, presentation({ equippedTitleCosmeticId = "title_superstar" })))
		local dressed = plan(
			applied,
			presentation({ outfitStylingItemKeysToWear = { HAIR }, equippedTitleCosmeticId = "title_superstar" })
		)
		expect(dressed.shouldDressOutfit).toBeTrue()
		expect(dressed.overheadCosmeticsStep).toBe("ShowOverheadCosmetics")
	end)

	it("shows nothing for ids the presentation catalog does not know or of the wrong kind", function()
		local applied = CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter()
		local unknown = plan(
			applied,
			presentation({
				equippedTitleCosmeticId = "nameplate_neon_glow",
				equippedNameplateStyleCosmeticId = "title_superstar",
				stagePlaceNumber = 1,
				stageEntranceEffectCosmeticId = "nameplate_neon_glow",
			})
		)
		expect(unknown.overheadCosmeticsStep).toBe("KeepOverheadCosmetics")
		expect(unknown.overheadCosmetics).toBeNil()
		expect(unknown.stageEntranceEffectLookToPlay).toBeNil()
	end)

	it("plays the entrance effect only for a presentation on a stage place", function()
		local applied = CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter()
		local onStage = plan(
			applied,
			presentation({ stagePlaceNumber = 1, stageEntranceEffectCosmeticId = "entrance_confetti_pop" })
		)
		expect(onStage.stageEntranceEffectLookToPlay).toBe(
			StageEntranceEffectLookCatalog.findStageEntranceEffectLook("entrance_confetti_pop")
		)
		local offStage = plan(applied, presentation({ stageEntranceEffectCosmeticId = "entrance_confetti_pop" }))
		expect(offStage.stageEntranceEffectLookToPlay).toBeNil()
	end)

	it("carries a waiting entrance effect into a newer presentation for the same stage place only", function()
		local waiting = presentation({ stagePlaceNumber = 4, stageEntranceEffectCosmeticId = "entrance_star_burst" })
		local newerSamePlace = presentation({ stagePlaceNumber = 4, presentationReason = "CharacterSpawned" })
		local merged = CharacterPresentationStepPlanner.mergeWaitingPresentation(waiting, newerSamePlace)
		expect(merged.stageEntranceEffectCosmeticId).toBe("entrance_star_burst")
		expect(merged.presentationReason).toBe("CharacterSpawned")
		expect(table.isfrozen(merged)).toBeTrue()
		local newerOffStage = presentation({ presentationReason = "ShowcaseEnded" })
		expect(CharacterPresentationStepPlanner.mergeWaitingPresentation(waiting, newerOffStage)).toBe(newerOffStage)
		local newerOtherPlace = presentation({ stagePlaceNumber = 5 })
		expect(CharacterPresentationStepPlanner.mergeWaitingPresentation(waiting, newerOtherPlace)).toBe(
			newerOtherPlace
		)
		expect(CharacterPresentationStepPlanner.mergeWaitingPresentation(nil, newerSamePlace)).toBe(newerSamePlace)
		local newerWithOwnEffect =
			presentation({ stagePlaceNumber = 4, stageEntranceEffectCosmeticId = "entrance_petal_swirl" })
		expect(CharacterPresentationStepPlanner.mergeWaitingPresentation(waiting, newerWithOwnEffect)).toBe(
			newerWithOwnEffect
		)
	end)
end)

-- A presentation catalog that answers EVERY id (also nil) with a presentation of `cosmeticKind`
-- that wrongly carries the fields of all three kinds, so the planner's own kind checks are what
-- keeps a wrong-kind presentation from being used.
local function createFaultyPresentationCatalogAnsweringKind(cosmeticKind: string)
	return {
		findCosmeticPresentation = function(cosmeticId)
			return table.freeze({
				cosmeticKind = cosmeticKind,
				cosmeticId = cosmeticId,
				titleText = "Faulty Title",
				nameplateStyleLook = NameplateStyleLookCatalog.findNameplateStyleLook("nameplate_neon_glow"),
				stageEntranceEffectLook = StageEntranceEffectLookCatalog.findStageEntranceEffectLook(
					"entrance_confetti_pop"
				),
			})
		end,
	}
end

local function presentationWithEveryCosmetic()
	return presentation({
		stagePlaceNumber = 1,
		equippedTitleCosmeticId = "some_title",
		equippedNameplateStyleCosmeticId = "some_nameplate",
		stageEntranceEffectCosmeticId = "some_effect",
	})
end

describe("CharacterPresentationStepPlanner guards", function()
	it("never plays the lobby dance on stage, also when the stage presentation has no stage dance", function()
		local applied = CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter()
		local onStageWithLobbyDanceOnly =
			presentation({ stagePlaceNumber = 2, lobbyDance = lobbyDance(GROOVE, STARTED_AT) })
		local fromNothing = plan(applied, onStageWithLobbyDanceOnly)
		expect(fromNothing.danceStep).toBe("KeepDanceAsItIs")
		expect(fromNothing.danceSignature).toBeNil()
		applyPlan(applied, plan(applied, presentation({ lobbyDance = lobbyDance(GROOVE, STARTED_AT) })))
		local fromLobbyDance = plan(applied, onStageWithLobbyDanceOnly)
		expect(fromLobbyDance.danceStep).toBe("StopDance")
		expect(fromLobbyDance.danceAnimationAssetId).toBeNil()
	end)

	it("never plays a stage dance off stage", function()
		local applied = CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter()
		applyPlan(applied, plan(applied, presentation({ lobbyDance = lobbyDance(GROOVE, STARTED_AT) })))
		local offStageWithStageDanceId = plan(applied, presentation({ danceAnimationAssetId = BOUNCE }))
		expect(offStageWithStageDanceId.danceStep).toBe("StopDance")
		expect(offStageWithStageDanceId.danceAnimationAssetId).toBeNil()
	end)

	it("never plays a Title or NameplateStyle presentation as an entrance effect", function()
		for _, wrongKind in { "Title", "NameplateStyle" } do
			local steps = plan(
				CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter(),
				presentationWithEveryCosmetic(),
				nil,
				createFaultyPresentationCatalogAnsweringKind(wrongKind)
			)
			expect(steps.stageEntranceEffectLookToPlay).toBeNil()
		end
	end)

	it("never shows a title text from a presentation that is not a Title", function()
		for _, wrongKind in { "NameplateStyle", "StageEntranceEffect" } do
			local steps = plan(
				CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter(),
				presentationWithEveryCosmetic(),
				nil,
				createFaultyPresentationCatalogAnsweringKind(wrongKind)
			)
			expect(steps.overheadCosmetics == nil or steps.overheadCosmetics.titleText == nil).toBeTrue()
		end
	end)

	it("never shows a nameplate from a presentation that is not a NameplateStyle", function()
		for _, wrongKind in { "Title", "StageEntranceEffect" } do
			local steps = plan(
				CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter(),
				presentationWithEveryCosmetic(),
				nil,
				createFaultyPresentationCatalogAnsweringKind(wrongKind)
			)
			expect(steps.overheadCosmetics == nil or steps.overheadCosmetics.nameplateStyleLook == nil).toBeTrue()
		end
	end)

	it("uses each presentation of the right kind from the same faulty catalog", function()
		local steps = plan(
			CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter(),
			presentationWithEveryCosmetic(),
			nil,
			createFaultyPresentationCatalogAnsweringKind("StageEntranceEffect")
		)
		expect(steps.stageEntranceEffectLookToPlay ~= nil).toBeTrue()
		expect(steps.overheadCosmetics).toBeNil()
	end)

	it("plays no entrance effect for a presentation that names none", function()
		local steps = plan(
			CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter(),
			presentation({ stagePlaceNumber = 1 }),
			nil,
			createFaultyPresentationCatalogAnsweringKind("StageEntranceEffect")
		)
		expect(steps.stageEntranceEffectLookToPlay).toBeNil()
	end)

	it("plays nothing, without raising, for an entrance effect id that has no presentation", function()
		local steps = plan(
			CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter(),
			presentation({ stagePlaceNumber = 1, stageEntranceEffectCosmeticId = "entrance_not_in_the_catalog" })
		)
		expect(steps.stageEntranceEffectLookToPlay).toBeNil()
	end)

	it("puts only the cosmetics actually shown into the overhead signature", function()
		local steps = plan(
			CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter(),
			presentation({
				equippedTitleCosmeticId = "title_not_in_the_catalog",
				equippedNameplateStyleCosmeticId = "nameplate_neon_glow",
			})
		)
		expect(steps.overheadCosmeticsSignature).toBe("|nameplate_neon_glow")
		local titleOnly = plan(
			CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter(),
			presentation({
				equippedTitleCosmeticId = "title_superstar",
				equippedNameplateStyleCosmeticId = "nameplate_not_in_the_catalog",
			})
		)
		expect(titleOnly.overheadCosmeticsSignature).toBe("title_superstar|")
	end)

	it("leaves a newer presentation as it is when the waiting one has no entrance effect or no stage place", function()
		local newerOnStage = presentation({ stagePlaceNumber = 4 })
		local waitingWithoutEffect = presentation({ stagePlaceNumber = 4 })
		expect(CharacterPresentationStepPlanner.mergeWaitingPresentation(waitingWithoutEffect, newerOnStage)).toBe(
			newerOnStage
		)
		local waitingEffectOffStage = presentation({ stageEntranceEffectCosmeticId = "entrance_star_burst" })
		local newerOffStage = presentation({ presentationReason = "LobbyDanceChanged" })
		expect(CharacterPresentationStepPlanner.mergeWaitingPresentation(waitingEffectOffStage, newerOffStage)).toBe(
			newerOffStage
		)
	end)
end)
