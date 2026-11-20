-- CharacterAppearanceAndStageDirector on the assembled server (fakes for Roblox): the cases its
-- header promises beyond the full-round flow covered in ServerGameModuleAssemblyRoundsAndLifecycle.

local UnitTestFramework = require("../Support/UnitTestFramework")
local ServerGameAssemblyTestHarness = require("./ServerGameAssemblyTestHarness")
local CharacterAppearanceAndStageDirector = require("../../src/server/CharacterAppearanceAndStageDirector")
local DanceCatalog = require("../../src/shared/DanceCatalog")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = 501
local SECOND_PLAYER = 502
local HAIR = "asset_7259123616"

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

local function joinRoundWithHairDraft(harness, playerUserId: number)
	harness:joinPlayer(playerUserId)
	harness:ask("RequestJoinCurrentRound", playerUserId)
end

local function sendHairDraftsAndAdvanceToShowcase(harness, playerUserIds: { number })
	harness:advanceToPhase("Styling")
	local roundId = harness:readRoundState().roundId
	for _, playerUserId in playerUserIds do
		harness:sendDraft(
			playerUserId,
			{ roundId = roundId, outfitDraftSequenceNumber = 1, outfitStylingItemKeys = { HAIR } }
		)
	end
	harness:advanceToPhase("Showcase")
end

describe("CharacterAppearanceAndStageDirector", function()
	it("gives stage places in join order and ends each participant's lobby dance when Showcase begins", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		joinRoundWithHairDraft(harness, PLAYER)
		joinRoundWithHairDraft(harness, SECOND_PLAYER)
		expect(harness:ask("RequestStartDanceInLobby", PLAYER, "starter_sway")).toEqual({ isAccepted = true })
		sendHairDraftsAndAdvanceToShowcase(harness, { PLAYER, SECOND_PLAYER })
		expect(lastPresentationFor(harness, PLAYER).stagePlaceNumber).toBe(1)
		expect(lastPresentationFor(harness, SECOND_PLAYER).stagePlaceNumber).toBe(2)
		expect(harness.modules.lobbyDanceCoordinator:readLobbyDanceStateOfPlayer(PLAYER)).toBeNil()
		expect(harness.modules.characterAppearanceAndStageDirector:listStagedPlayerUserIds()).toEqual({
			PLAYER,
			SECOND_PLAYER,
		})
	end)

	it("dances the player's equipped dance on stage", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		joinRoundWithHairDraft(harness, PLAYER)
		expect(harness:ask("RequestEquipDance", PLAYER, "starter_bounce")).toEqual({ isAccepted = true })
		sendHairDraftsAndAdvanceToShowcase(harness, { PLAYER })
		expect(lastPresentationFor(harness, PLAYER).danceAnimationAssetId).toBe("rbxassetid://507776043")
	end)

	it("falls back to the first starter dance, with a warning, when the equipped dance is unknown", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		joinRoundWithHairDraft(harness, PLAYER)
		harness.modules.playerSaveDataKeeper:applyChangeToPlayerSaveData(
			PLAYER,
			"AppearanceChangeSavedLater",
			"test",
			function(draft)
				draft.equippedDanceId = "retired_dance"
				return true
			end
		)
		sendHairDraftsAndAdvanceToShowcase(harness, { PLAYER })
		expect(lastPresentationFor(harness, PLAYER).danceAnimationAssetId).toBe("rbxassetid://507771019")
		expect(harness.logger:countWarningsContaining("no usable equipped dance")).toBe(1)
	end)

	-- The real DanceCatalog plus test-only entries with animation ids that cannot be played.
	-- `starterAnimationAssetIdOverride` replaces the animation id of every dance granted to new players.
	local function buildDanceCatalogWithUnplayableEntries(starterAnimationAssetIdOverride: string?)
		local extraDanceByDanceId = {
			unproduced_dance = table.freeze({
				danceId = "unproduced_dance",
				danceDisplayName = "Unproduced Dance",
				danceAnimationAssetId = "",
				starCoinPrice = 900,
				isGrantedToNewPlayers = false,
			}),
			dance_with_number_id = table.freeze({
				danceId = "dance_with_number_id",
				danceDisplayName = "Dance With Number Id",
				danceAnimationAssetId = 507771019 :: any,
				starCoinPrice = 900,
				isGrantedToNewPlayers = false,
			}),
		}
		return {
			findDanceByDanceId = function(danceId)
				local extraDance = extraDanceByDanceId[danceId]
				if extraDance ~= nil then
					return extraDance
				end
				local realDance = DanceCatalog.findDanceByDanceId(danceId)
				if realDance ~= nil and starterAnimationAssetIdOverride ~= nil and realDance.isGrantedToNewPlayers then
					local overriddenDance = table.clone(realDance)
					overriddenDance.danceAnimationAssetId = starterAnimationAssetIdOverride
					return table.freeze(overriddenDance)
				end
				return realDance
			end,
			listDanceIdsGrantedToNewPlayers = DanceCatalog.listDanceIdsGrantedToNewPlayers,
		}
	end

	local function setEquippedDanceIdDirectly(harness, equippedDanceId: any)
		harness.modules.playerSaveDataKeeper:applyChangeToPlayerSaveData(
			PLAYER,
			"AppearanceChangeSavedLater",
			"test",
			function(draft)
				draft.equippedDanceId = equippedDanceId
				return true
			end
		)
	end

	for _, unplayableCase in
		{
			{
				caseName = "a catalog dance whose animation id is the empty string",
				equippedDanceId = "unproduced_dance",
			},
			{
				caseName = "a catalog dance whose animation id is not a string",
				equippedDanceId = "dance_with_number_id",
			},
			{ caseName = "no catalog entry at all", equippedDanceId = "retired_dance" },
			{ caseName = "no equipped dance id in the save", equippedDanceId = nil },
		}
	do
		it("falls back to the first starter dance, with a warning, for " .. unplayableCase.caseName, function()
			local harness = ServerGameAssemblyTestHarness.createStartedServer({
				catalogs = { danceCatalog = buildDanceCatalogWithUnplayableEntries() },
			})
			joinRoundWithHairDraft(harness, PLAYER)
			setEquippedDanceIdDirectly(harness, unplayableCase.equippedDanceId)
			sendHairDraftsAndAdvanceToShowcase(harness, { PLAYER })
			local onStage = lastPresentationFor(harness, PLAYER)
			expect(onStage.presentationReason).toBe("ShowcaseBegan")
			expect(onStage.stagePlaceNumber).toBe(1)
			expect(onStage.danceAnimationAssetId).toBe("rbxassetid://507771019")
			expect(harness.logger:countWarningsContaining("no usable equipped dance")).toBe(1)
		end)
	end

	it("stands the player on stage without a dance when the starter dance cannot be played either", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer({
			catalogs = { danceCatalog = buildDanceCatalogWithUnplayableEntries("") },
		})
		joinRoundWithHairDraft(harness, PLAYER)
		setEquippedDanceIdDirectly(harness, "unproduced_dance")
		sendHairDraftsAndAdvanceToShowcase(harness, { PLAYER })
		local onStage = lastPresentationFor(harness, PLAYER)
		expect(onStage.presentationReason).toBe("ShowcaseBegan")
		expect(onStage.stagePlaceNumber).toBe(1)
		expect(onStage.danceAnimationAssetId).toBeNil()
	end)

	it("does not take a staged player off the stage when their lobby outfit availability changes", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		joinRoundWithHairDraft(harness, PLAYER)
		sendHairDraftsAndAdvanceToShowcase(harness, { PLAYER })
		local presentationCountOnStage = #presentationsFor(harness, PLAYER)
		-- A lobby outfit change is refused during Showcase, so change the stored list directly.
		harness.modules.playerSaveDataKeeper:applyChangeToPlayerSaveData(
			PLAYER,
			"AppearanceChangeSavedLater",
			"test",
			function(draft)
				draft.lobbyOutfitStylingItemKeys = { HAIR }
				return true
			end
		)
		expect(#presentationsFor(harness, PLAYER)).toBe(presentationCountOnStage)
		harness:advanceToPhase("Results")
		expect(lastPresentationFor(harness, PLAYER).outfitStylingItemKeysToWear).toEqual({ HAIR })
	end)

	it("keeps presenting the other participants when the presenter raises for one", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		joinRoundWithHairDraft(harness, PLAYER)
		joinRoundWithHairDraft(harness, SECOND_PLAYER)
		local presenter = harness.characterAppearancePresenter
		local realPresent = presenter.presentCharacterAppearance
		presenter.presentCharacterAppearance = function(self, playerUserId, presentation)
			if playerUserId == PLAYER and presentation.presentationReason == "ShowcaseBegan" then
				error("deliberate presenter failure")
			end
			realPresent(self, playerUserId, presentation)
		end
		sendHairDraftsAndAdvanceToShowcase(harness, { PLAYER, SECOND_PLAYER })
		expect(lastPresentationFor(harness, SECOND_PLAYER).stagePlaceNumber).toBe(2)
		expect(harness.logger:countWarningsContaining("deliberate presenter failure")).toBe(1)
	end)

	it("forgets a player who left, so the end of Showcase does not present them", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		joinRoundWithHairDraft(harness, PLAYER)
		sendHairDraftsAndAdvanceToShowcase(harness, { PLAYER })
		harness.modules.playerServerLifecycleSequences:handlePlayerLeavingServer(PLAYER)
		local presentationCount = #presentationsFor(harness, PLAYER)
		harness:advanceToPhase("Results")
		expect(#presentationsFor(harness, PLAYER)).toBe(presentationCount)
	end)

	it("presents the player's own avatar on a spawn before the save has loaded", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		harness.modules.characterAppearanceAndStageDirector:handleCharacterSpawned(PLAYER)
		local presentation = lastPresentationFor(harness, PLAYER)
		expect(presentation.outfitStylingItemKeysToWear).toEqual({})
		expect(presentation.characterSpawnAppearanceCase).toBe("LobbyAppearance")
	end)

	it("raises when started twice or built without a dependency", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		expect(function()
			harness.modules.characterAppearanceAndStageDirector:startDirectingCharacterAppearances()
		end).toThrow("already started")
		expect(function()
			CharacterAppearanceAndStageDirector.new({})
		end).toThrow("missing themedRoundClock")
	end)
end)
