-- CharacterAppearanceAndStageDirector on the assembled server (fakes for Roblox): the lobby dance
-- and the cosmetics every presentation carries (development spec §1.7, §2.4, §2.8, gate 2D), and
-- what the one presenter would do with them (CharacterPresentationStepPlanner replayed over the
-- presentations, standing in for RobloxCharacterShowcasePresenter).

local UnitTestFramework = require("../Support/UnitTestFramework")
local ServerGameAssemblyTestHarness = require("./ServerGameAssemblyTestHarness")
local CharacterPresentationStepPlanner = require("../../src/server/CharacterPresentationStepPlanner")
local LobbyDanceLoopTimePositionCalculator = require("../../src/server/LobbyDanceLoopTimePositionCalculator")
local DanceCatalog = require("../../src/shared/DanceCatalog")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local LEADER = 601
local FOLLOWER = 602
local HAIR = "asset_7259123616"
local MEASURED_LOOP_LENGTH_SECONDS = 2.0417 -- rbxassetid://507776043, measured in Studio

local function presentationsFor(harness, playerUserId: number)
	local presentations = {}
	for _, presentationRecord in harness.presentations do
		if presentationRecord.playerUserId == playerUserId then
			table.insert(presentations, presentationRecord.presentation)
		end
	end
	return presentations
end

local function lastPresentationFor(harness, playerUserId: number)
	local presentations = presentationsFor(harness, playerUserId)
	return presentations[#presentations]
end

local function countPresentations(harness, playerUserId: number, presentationReason: string?): number
	local presentationCount = 0
	for _, presentation in presentationsFor(harness, playerUserId) do
		if presentationReason == nil or presentation.presentationReason == presentationReason then
			presentationCount += 1
		end
	end
	return presentationCount
end

-- What the presenter would have applied after every presentation of this player so far.
local function replayPresentationsThroughPlanner(harness, playerUserId: number)
	local applied = CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter()
	local entranceEffectsPlayed = {}
	for _, presentation in presentationsFor(harness, playerUserId) do
		if presentation.presentationReason == "CharacterSpawned" then
			applied = CharacterPresentationStepPlanner.createAppliedStateOfNewCharacter()
		end
		local presentationPlan = CharacterPresentationStepPlanner.planPresentationSteps(applied, presentation)
		applied.wornOutfitSignature = presentationPlan.outfitSignature
		if presentationPlan.placementStep == "MoveOntoStagePlace" then
			applied.stagePlaceNumberStoodOn = presentationPlan.placementStagePlaceNumber
		elseif presentationPlan.placementStep == "MoveToFloorInFrontOfStagePlace" then
			applied.stagePlaceNumberStoodOn = nil
		end
		applied.playingDanceSignature = presentationPlan.danceSignature
		if presentationPlan.overheadCosmeticsStep ~= "KeepOverheadCosmetics" then
			applied.shownOverheadCosmeticsSignature = presentationPlan.overheadCosmeticsSignature
		end
		if presentationPlan.stageEntranceEffectLookToPlay then
			table.insert(
				entranceEffectsPlayed,
				presentationPlan.stageEntranceEffectLookToPlay.stageEntranceEffectCosmeticId
			)
		end
	end
	return applied, entranceEffectsPlayed
end

local function giveCosmeticsForTest(harness, playerUserId: number, cosmeticIds: { string })
	local changeResult = harness.modules.playerSaveDataKeeper:applyChangeToPlayerSaveData(
		playerUserId,
		"AppearanceChangeSavedLater",
		"test: own cosmetics",
		function(draft)
			for _, cosmeticId in cosmeticIds do
				table.insert(draft.ownedCosmeticIds, cosmeticId)
			end
			return true
		end
	)
	expect(changeResult.changeOutcome).toBe("Applied")
end

local function startDance(harness, playerUserId: number, danceId: string)
	expect(harness:ask("RequestStartDanceInLobby", playerUserId, danceId)).toEqual({ isAccepted = true })
	harness:advance(1)
end

local function joinRoundAndReachShowcase(harness, participantUserIds: { number })
	for _, participantUserId in participantUserIds do
		expect(harness:ask("RequestJoinCurrentRound", participantUserId)).toEqual({ isAccepted = true })
	end
	harness:advanceToPhase("Styling")
	local roundId = harness:readRoundState().roundId
	for _, participantUserId in participantUserIds do
		harness:sendDraft(
			participantUserId,
			{ roundId = roundId, outfitDraftSequenceNumber = 1, outfitStylingItemKeys = { HAIR } }
		)
	end
	harness:advanceToPhase("Showcase")
end

local function createServerWithTwoPlayers()
	local harness = ServerGameAssemblyTestHarness.createStartedServer()
	harness:joinPlayer(LEADER)
	harness:joinPlayer(FOLLOWER)
	return harness
end

describe("lobby dances everyone can see", function()
	it("presents each starter dance with its animation and the coordinator's start moment, and the stop", function()
		local harness = createServerWithTwoPlayers()
		for _, dance in DanceCatalog.DANCES do
			local requestedAt = harness.fakeClock:getCurrentUnixMilliseconds()
			startDance(harness, LEADER, dance.danceId)
			local presentation = presentationsFor(harness, LEADER)
			local dancing = presentation[#presentation]
			expect(dancing.presentationReason).toBe("LobbyDanceChanged")
			expect(dancing.lobbyDance.danceId).toBe(dance.danceId)
			expect(dancing.lobbyDance.danceAnimationAssetId).toBe(dance.danceAnimationAssetId)
			expect(dancing.lobbyDance.danceStartedAtUnixMilliseconds).toBe(requestedAt)
			expect(dancing.stagePlaceNumber).toBeNil()
			expect(dancing.danceAnimationAssetId).toBeNil()
		end
		expect(harness:ask("RequestStopDanceInLobby", LEADER)).toEqual({ isAccepted = true })
		local stopped = lastPresentationFor(harness, LEADER)
		expect(stopped.presentationReason).toBe("LobbyDanceChanged")
		expect(stopped.lobbyDance).toBeNil()
		expect(replayPresentationsThroughPlanner(harness, LEADER).playingDanceSignature).toBeNil()
	end)

	it("dances again after a respawn while dancing, keeping the start moment", function()
		local harness = createServerWithTwoPlayers()
		startDance(harness, LEADER, "starter_bounce")
		local startedAt = lastPresentationFor(harness, LEADER).lobbyDance.danceStartedAtUnixMilliseconds
		harness:advance(7)
		harness.modules.characterAppearanceAndStageDirector:handleCharacterSpawned(LEADER)
		local respawned = lastPresentationFor(harness, LEADER)
		expect(respawned.presentationReason).toBe("CharacterSpawned")
		expect(respawned.lobbyDance.danceId).toBe("starter_bounce")
		expect(respawned.lobbyDance.danceStartedAtUnixMilliseconds).toBe(startedAt)
		local applied = replayPresentationsThroughPlanner(harness, LEADER)
		expect(applied.playingDanceSignature).toBe("lobby/rbxassetid://507776043/" .. tostring(startedAt))
	end)

	it("makes a follower perform the leader's dance with the leader's start moment (in time)", function()
		local harness = createServerWithTwoPlayers()
		startDance(harness, LEADER, "starter_bounce")
		harness:advance(3.3)
		expect(harness:ask("RequestSyncDanceWithPlayer", FOLLOWER, LEADER)).toEqual({ isAccepted = true })
		local leaderDance = lastPresentationFor(harness, LEADER).lobbyDance
		local followerDance = lastPresentationFor(harness, FOLLOWER).lobbyDance
		expect(followerDance.danceAnimationAssetId).toBe(leaderDance.danceAnimationAssetId)
		expect(followerDance.danceStartedAtUnixMilliseconds).toBe(leaderDance.danceStartedAtUnixMilliseconds)
		expect(followerDance.followedPlayerUserId).toBe(LEADER)
		-- At any later moment both characters are at the same position of the loop.
		for _, laterSeconds in { 0, 0.4, 1.7, 61.25 } do
			harness:advance(laterSeconds)
			local now = harness.fakeClock:getCurrentUnixMilliseconds()
			local leaderPosition = LobbyDanceLoopTimePositionCalculator.computeLoopTimePositionSeconds(
				leaderDance.danceStartedAtUnixMilliseconds,
				now,
				MEASURED_LOOP_LENGTH_SECONDS
			)
			local followerPosition = LobbyDanceLoopTimePositionCalculator.computeLoopTimePositionSeconds(
				followerDance.danceStartedAtUnixMilliseconds,
				now,
				MEASURED_LOOP_LENGTH_SECONDS
			)
			expect(followerPosition).toBe(leaderPosition)
		end
		-- The follower's sync did not restart the leader's dance.
		expect(countPresentations(harness, LEADER, "LobbyDanceChanged")).toBe(1)
	end)

	for _, leaderChange in
		{
			{
				changeName = "changes dance",
				applyChange = function(harness)
					startDance(harness, LEADER, "starter_sway")
				end,
			},
			{
				changeName = "stops",
				applyChange = function(harness)
					expect(harness:ask("RequestStopDanceInLobby", LEADER)).toEqual({ isAccepted = true })
				end,
			},
			{
				changeName = "leaves the server",
				applyChange = function(harness)
					harness.modules.playerServerLifecycleSequences:handlePlayerLeavingServer(LEADER)
				end,
			},
		}
	do
		it("stops the follower's dance when the leader " .. leaderChange.changeName, function()
			local harness = createServerWithTwoPlayers()
			startDance(harness, LEADER, "starter_groove")
			expect(harness:ask("RequestSyncDanceWithPlayer", FOLLOWER, LEADER)).toEqual({ isAccepted = true })
			harness:advance(1)
			expect(lastPresentationFor(harness, FOLLOWER).lobbyDance ~= nil).toBeTrue()
			leaderChange.applyChange(harness)
			local followerAfter = lastPresentationFor(harness, FOLLOWER)
			expect(followerAfter.presentationReason).toBe("LobbyDanceChanged")
			expect(followerAfter.lobbyDance).toBeNil()
			expect(replayPresentationsThroughPlanner(harness, FOLLOWER).playingDanceSignature).toBeNil()
		end)
	end

	it("ends the lobby dance when going on stage; the follower stops; after the round nobody dances", function()
		local harness = createServerWithTwoPlayers()
		expect(harness:ask("RequestJoinCurrentRound", LEADER)).toEqual({ isAccepted = true })
		startDance(harness, LEADER, "starter_sway")
		expect(harness:ask("RequestSyncDanceWithPlayer", FOLLOWER, LEADER)).toEqual({ isAccepted = true })
		harness:advanceToPhase("Styling")
		-- Joining a round does not end a lobby dance: a Styling participant still dances (coordinator header).
		harness.modules.characterAppearanceAndStageDirector:handleCharacterSpawned(LEADER)
		local whileStyling = lastPresentationFor(harness, LEADER)
		expect(whileStyling.characterSpawnAppearanceCase).toBe("LobbyAppearanceWhileStyling")
		expect(whileStyling.lobbyDance.danceId).toBe("starter_sway")
		local roundId = harness:readRoundState().roundId
		harness:sendDraft(
			LEADER,
			{ roundId = roundId, outfitDraftSequenceNumber = 1, outfitStylingItemKeys = { HAIR } }
		)
		local leaderLobbyDanceChangesBefore = countPresentations(harness, LEADER, "LobbyDanceChanged")
		harness:advanceToPhase("Showcase")
		local onStage = lastPresentationFor(harness, LEADER)
		expect(onStage.presentationReason).toBe("ShowcaseBegan")
		expect(onStage.lobbyDance).toBeNil()
		expect(onStage.danceAnimationAssetId).toBe("rbxassetid://507771019")
		-- Going on stage is presented once, by Showcase, not also as a lobby dance change.
		expect(countPresentations(harness, LEADER, "LobbyDanceChanged")).toBe(leaderLobbyDanceChangesBefore)
		local applied = replayPresentationsThroughPlanner(harness, LEADER)
		expect(applied.playingDanceSignature).toBe("stage/1/rbxassetid://507771019")
		expect(lastPresentationFor(harness, FOLLOWER).lobbyDance).toBeNil()
		harness:advanceToPhase("Results")
		local afterRound = lastPresentationFor(harness, LEADER)
		expect(afterRound.presentationReason).toBe("ShowcaseEnded")
		expect(afterRound.lobbyDance).toBeNil()
		local appliedAfterRound = replayPresentationsThroughPlanner(harness, LEADER)
		expect(appliedAfterRound.playingDanceSignature).toBeNil()
		expect(appliedAfterRound.stagePlaceNumberStoodOn).toBeNil()
		expect(harness.modules.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(LEADER)).toBeNil()
	end)

	it("never presents a lobby dance on stage, even if the coordinator still reported one", function()
		local harness = createServerWithTwoPlayers()
		local coordinator = harness.modules.lobbyDanceCoordinator
		-- A faulty coordinator that never ends the dance (the real one ends it when Showcase begins).
		coordinator.readLobbyDanceStateOfPlayer = function(_, playerUserId)
			return table.freeze({
				dancingPlayerUserId = playerUserId,
				danceId = "starter_bounce",
				danceStartedAtUnixMilliseconds = 1,
			})
		end
		joinRoundAndReachShowcase(harness, { LEADER })
		local onStage = lastPresentationFor(harness, LEADER)
		expect(onStage.presentationReason).toBe("ShowcaseBegan")
		expect(onStage.lobbyDance).toBeNil()
		harness.modules.characterAppearanceAndStageDirector:handleCharacterSpawned(LEADER)
		expect(lastPresentationFor(harness, LEADER).lobbyDance).toBeNil()
		harness:advanceToPhase("Results")
		expect(lastPresentationFor(harness, LEADER).lobbyDance.danceId).toBe("starter_bounce")
	end)

	it("presents no dance, with a warning, for a lobby dance whose animation cannot be played", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer({
			catalogs = {
				danceCatalog = {
					findDanceByDanceId = function(danceId)
						local dance = DanceCatalog.findDanceByDanceId(danceId)
						if dance == nil then
							return nil
						end
						local unplayableDance = table.clone(dance)
						unplayableDance.danceAnimationAssetId = ""
						return table.freeze(unplayableDance)
					end,
					listDanceIdsGrantedToNewPlayers = DanceCatalog.listDanceIdsGrantedToNewPlayers,
				},
			},
		})
		harness:joinPlayer(LEADER)
		startDance(harness, LEADER, "starter_groove")
		local presentation = lastPresentationFor(harness, LEADER)
		expect(presentation.presentationReason).toBe("LobbyDanceChanged")
		expect(presentation.lobbyDance).toBeNil()
		expect(harness.logger:countWarningsContaining("which has no usable animation")).toBe(1)
	end)
end)

describe("cosmetics everyone can see", function()
	it("presents nothing above the head for a player with nothing equipped", function()
		local harness = createServerWithTwoPlayers()
		harness.modules.characterAppearanceAndStageDirector:handleCharacterSpawned(LEADER)
		local presentation = lastPresentationFor(harness, LEADER)
		expect(presentation.equippedTitleCosmeticId).toBeNil()
		expect(presentation.equippedNameplateStyleCosmeticId).toBeNil()
		expect(presentation.stageEntranceEffectCosmeticId).toBeNil()
	end)

	it("follows equipping a title and a nameplate style, and replacing the title", function()
		local harness = createServerWithTwoPlayers()
		giveCosmeticsForTest(harness, LEADER, { "title_rising_star", "title_superstar", "nameplate_neon_glow" })
		expect(countPresentations(harness, LEADER, "EquippedCosmeticsChanged")).toBe(0)
		expect(harness:ask("RequestEquipCosmetic", LEADER, "title_rising_star")).toEqual({ isAccepted = true })
		local titled = lastPresentationFor(harness, LEADER)
		expect(titled.presentationReason).toBe("EquippedCosmeticsChanged")
		expect(titled.equippedTitleCosmeticId).toBe("title_rising_star")
		expect(titled.equippedNameplateStyleCosmeticId).toBeNil()
		harness:advance(1)
		expect(harness:ask("RequestEquipCosmetic", LEADER, "nameplate_neon_glow")).toEqual({ isAccepted = true })
		local both = lastPresentationFor(harness, LEADER)
		expect(both.equippedTitleCosmeticId).toBe("title_rising_star")
		expect(both.equippedNameplateStyleCosmeticId).toBe("nameplate_neon_glow")
		harness:advance(1)
		expect(harness:ask("RequestEquipCosmetic", LEADER, "title_superstar")).toEqual({ isAccepted = true })
		expect(lastPresentationFor(harness, LEADER).equippedTitleCosmeticId).toBe("title_superstar")
		local applied = replayPresentationsThroughPlanner(harness, LEADER)
		expect(applied.shownOverheadCosmeticsSignature).toBe("title_superstar|nameplate_neon_glow")
		expect(countPresentations(harness, LEADER, "EquippedCosmeticsChanged")).toBe(3)
	end)

	it("does not present again for a save change that leaves the shown cosmetics as they are", function()
		local harness = createServerWithTwoPlayers()
		giveCosmeticsForTest(harness, LEADER, { "title_rising_star" })
		expect(harness:ask("RequestEquipCosmetic", LEADER, "title_rising_star")).toEqual({ isAccepted = true })
		local presentationCount = countPresentations(harness, LEADER)
		expect(harness:ask("RequestEquipDance", LEADER, "starter_sway")).toEqual({ isAccepted = true })
		harness:advance(1)
		expect(harness:ask("RequestEquipCosmetic", LEADER, "title_rising_star")).toEqual({ isAccepted = true })
		expect(countPresentations(harness, LEADER)).toBe(presentationCount)
	end)

	it("keeps the cosmetics and the dance in every other presentation (a respawn, a lobby dance)", function()
		local harness = createServerWithTwoPlayers()
		giveCosmeticsForTest(harness, LEADER, { "title_rising_star", "nameplate_mint_fresh" })
		expect(harness:ask("RequestEquipCosmetic", LEADER, "title_rising_star")).toEqual({ isAccepted = true })
		harness:advance(1)
		expect(harness:ask("RequestEquipCosmetic", LEADER, "nameplate_mint_fresh")).toEqual({ isAccepted = true })
		startDance(harness, LEADER, "starter_groove")
		local dancing = lastPresentationFor(harness, LEADER)
		expect(dancing.equippedTitleCosmeticId).toBe("title_rising_star")
		expect(dancing.equippedNameplateStyleCosmeticId).toBe("nameplate_mint_fresh")
		harness.modules.characterAppearanceAndStageDirector:handleCharacterSpawned(LEADER)
		local respawned = lastPresentationFor(harness, LEADER)
		expect(respawned.equippedTitleCosmeticId).toBe("title_rising_star")
		expect(respawned.equippedNameplateStyleCosmeticId).toBe("nameplate_mint_fresh")
		expect(respawned.lobbyDance.danceId).toBe("starter_groove")
	end)

	it("presents the saved cosmetics when a returning player's save loads", function()
		local harness = createServerWithTwoPlayers()
		giveCosmeticsForTest(harness, LEADER, { "title_fresh_face" })
		expect(harness:ask("RequestEquipCosmetic", LEADER, "title_fresh_face")).toEqual({ isAccepted = true })
		harness.modules.playerServerLifecycleSequences:handlePlayerLeavingServer(LEADER)
		harness:advance(30)
		local presentationCountBeforeRejoin = countPresentations(harness, LEADER)
		harness:joinPlayer(LEADER)
		harness:advance(1)
		local presentations = presentationsFor(harness, LEADER)
		expect(#presentations > presentationCountBeforeRejoin).toBeTrue()
		expect(presentations[#presentations].equippedTitleCosmeticId).toBe("title_fresh_face")
	end)

	it("presents the cosmetics again after the director forgot the player", function()
		local harness = createServerWithTwoPlayers()
		giveCosmeticsForTest(harness, LEADER, { "title_fresh_face" })
		expect(harness:ask("RequestEquipCosmetic", LEADER, "title_fresh_face")).toEqual({ isAccepted = true })
		local presentationCount = countPresentations(harness, LEADER)
		harness.modules.characterAppearanceAndStageDirector:forgetPlayer(LEADER)
		expect(harness:ask("RequestEquipDance", LEADER, "starter_sway")).toEqual({ isAccepted = true })
		expect(countPresentations(harness, LEADER)).toBe(presentationCount + 1)
		expect(lastPresentationFor(harness, LEADER).presentationReason).toBe("EquippedCosmeticsChanged")
	end)

	it("plays the equipped entrance effect once, at the start of Showcase only", function()
		local harness = createServerWithTwoPlayers()
		giveCosmeticsForTest(harness, LEADER, { "entrance_confetti_pop", "title_superstar" })
		expect(harness:ask("RequestEquipCosmetic", LEADER, "entrance_confetti_pop")).toEqual({ isAccepted = true })
		local equippedPresentation = lastPresentationFor(harness, LEADER)
		expect(equippedPresentation.presentationReason).toBe("EquippedCosmeticsChanged")
		expect(equippedPresentation.stageEntranceEffectCosmeticId).toBeNil()
		joinRoundAndReachShowcase(harness, { LEADER })
		local onStage = lastPresentationFor(harness, LEADER)
		expect(onStage.presentationReason).toBe("ShowcaseBegan")
		expect(onStage.stageEntranceEffectCosmeticId).toBe("entrance_confetti_pop")
		-- A respawn on stage and a cosmetic change on stage do not play it again and keep the stage dance.
		harness.modules.characterAppearanceAndStageDirector:handleCharacterSpawned(LEADER)
		expect(lastPresentationFor(harness, LEADER).stageEntranceEffectCosmeticId).toBeNil()
		harness:advance(1)
		expect(harness:ask("RequestEquipCosmetic", LEADER, "title_superstar")).toEqual({ isAccepted = true })
		local cosmeticOnStage = lastPresentationFor(harness, LEADER)
		expect(cosmeticOnStage.presentationReason).toBe("EquippedCosmeticsChanged")
		expect(cosmeticOnStage.stagePlaceNumber).toBe(1)
		expect(cosmeticOnStage.stageEntranceEffectCosmeticId).toBeNil()
		harness:advanceToPhase("Results")
		expect(lastPresentationFor(harness, LEADER).stageEntranceEffectCosmeticId).toBeNil()
		local applied, entranceEffectsPlayed = replayPresentationsThroughPlanner(harness, LEADER)
		expect(entranceEffectsPlayed).toEqual({ "entrance_confetti_pop" })
		expect(applied.shownOverheadCosmeticsSignature).toBe("title_superstar|")
	end)

	it("keeps the stage dance playing when the cosmetics change on stage", function()
		local harness = createServerWithTwoPlayers()
		giveCosmeticsForTest(harness, LEADER, { "title_superstar" })
		joinRoundAndReachShowcase(harness, { LEADER })
		local appliedBefore = replayPresentationsThroughPlanner(harness, LEADER)
		expect(harness:ask("RequestEquipCosmetic", LEADER, "title_superstar")).toEqual({ isAccepted = true })
		local cosmeticOnStage = lastPresentationFor(harness, LEADER)
		local presentationPlan = CharacterPresentationStepPlanner.planPresentationSteps(appliedBefore, cosmeticOnStage)
		expect(presentationPlan.danceStep).toBe("KeepDanceAsItIs")
		expect(presentationPlan.placementStep).toBe("StayInPlace")
		expect(presentationPlan.overheadCosmeticsStep).toBe("ShowOverheadCosmetics")
	end)
end)
