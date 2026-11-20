-- Whole rounds on the assembled server (fakes for Roblox), as a participant and unattended, plus
-- the character director's presentations, leaving and shutdown.

local UnitTestFramework = require("../Support/UnitTestFramework")
local ServerGameAssemblyTestHarness = require("./ServerGameAssemblyTestHarness")
local OutfitScoreCalculator = require("../../src/shared/OutfitScoreCalculator")
local StylingItemLookup = require("../../src/shared/StylingItemLookup")
local ThemeCatalog = require("../../src/shared/ThemeCatalog")
local StylingItemPool = require("../../src/shared/generated/StylingItemPool")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = 2421377719
local SIX_ITEM_DRESS_OUTFIT = table.freeze({
	"asset_7259123616",
	"asset_9438759973",
	"asset_4378579302",
	"asset_11884330",
	"bundle_98186475028072",
	"asset_106390919006817",
})
local INVALID_DRESS_WITH_TOP_OUTFIT = table.freeze({ "asset_9438759973", "asset_9122110415" })

local function lastOf(list)
	return list[#list]
end

local function presentationsFor(harness, playerUserId: number)
	local presentations = {}
	for _, presentationRecord in harness.presentations do
		if presentationRecord.playerUserId == playerUserId then
			table.insert(presentations, presentationRecord.presentation)
		end
	end
	return presentations
end

local function joinRoundAndSendDrafts(harness)
	harness:joinPlayer(PLAYER)
	expect(harness:ask("RequestJoinCurrentRound", PLAYER)).toEqual({ isAccepted = true })
	harness:advanceToPhase("Styling")
	local roundId = harness:readRoundState().roundId
	harness:sendDraft(
		PLAYER,
		{ roundId = roundId, outfitDraftSequenceNumber = 1, outfitStylingItemKeys = SIX_ITEM_DRESS_OUTFIT }
	)
	harness:advance(1)
	harness:sendDraft(
		PLAYER,
		{ roundId = roundId, outfitDraftSequenceNumber = 2, outfitStylingItemKeys = INVALID_DRESS_WITH_TOP_OUTFIT }
	)
	harness:advance(1)
	harness:sendDraft(
		PLAYER,
		{ roundId = roundId, outfitDraftSequenceNumber = 2, outfitStylingItemKeys = SIX_ITEM_DRESS_OUTFIT }
	)
	harness:advance(1)
	return roundId
end

describe("ServerGameModuleAssembly: a full round as a participant", function()
	it("acknowledges drafts: kept, invalid, and the duplicate number re-sent unchanged", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		local roundId = joinRoundAndSendDrafts(harness)
		expect(harness:listSent("RoundOutfitDraftAcknowledged", PLAYER)).toEqual({
			{ roundId = roundId, outfitDraftSequenceNumber = 1, isKept = true },
			{ roundId = roundId, outfitDraftSequenceNumber = 2, isKept = false, rejectionReason = "OutfitInvalid" },
			{ roundId = roundId, outfitDraftSequenceNumber = 2, isKept = false, rejectionReason = "OutfitInvalid" },
		})
	end)

	it("processes two drafts sent 0.1 s apart: the first at once, the second 0.25 s after the first", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		harness:joinPlayer(PLAYER)
		harness:ask("RequestJoinCurrentRound", PLAYER)
		harness:advanceToPhase("Styling")
		local roundId = harness:readRoundState().roundId
		harness:sendDraft(
			PLAYER,
			{ roundId = roundId, outfitDraftSequenceNumber = 1, outfitStylingItemKeys = { "asset_7259123616" } }
		)
		harness:advance(0.1)
		harness:sendDraft(
			PLAYER,
			{ roundId = roundId, outfitDraftSequenceNumber = 2, outfitStylingItemKeys = SIX_ITEM_DRESS_OUTFIT }
		)
		expect(#harness:listSent("RoundOutfitDraftAcknowledged", PLAYER)).toBe(1)
		harness:advance(0.149)
		expect(#harness:listSent("RoundOutfitDraftAcknowledged", PLAYER)).toBe(1)
		harness:advance(0.001)
		expect(lastOf(harness:listSent("RoundOutfitDraftAcknowledged", PLAYER)).outfitDraftSequenceNumber).toBe(2)
	end)

	it("puts the participant on stage at Showcase in the scored outfit with their dance, and back after it", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		harness:joinPlayer(PLAYER)
		harness:ask("RequestJoinCurrentRound", PLAYER)
		harness:advanceToPhase("Styling")
		local roundId = harness:readRoundState().roundId
		harness:sendDraft(
			PLAYER,
			{ roundId = roundId, outfitDraftSequenceNumber = 1, outfitStylingItemKeys = SIX_ITEM_DRESS_OUTFIT }
		)
		harness:advanceToPhase("Showcase")
		local onStage = lastOf(presentationsFor(harness, PLAYER))
		expect(onStage.presentationReason).toBe("ShowcaseBegan")
		expect(onStage.characterSpawnAppearanceCase).toBe("ScoredOutfitOnStage")
		expect(onStage.outfitStylingItemKeysToWear).toEqual(SIX_ITEM_DRESS_OUTFIT)
		expect(onStage.stagePlaceNumber).toBe(1)
		expect(onStage.danceAnimationAssetId).toBe("rbxassetid://507771019")

		harness:advance(20)
		harness.modules.characterAppearanceAndStageDirector:handleCharacterSpawned(PLAYER)
		local afterReset = lastOf(presentationsFor(harness, PLAYER))
		expect(afterReset.presentationReason).toBe("CharacterSpawned")
		expect(afterReset.stagePlaceNumber).toBe(1)
		expect(afterReset.outfitStylingItemKeysToWear).toEqual(SIX_ITEM_DRESS_OUTFIT)
		expect(afterReset.danceAnimationAssetId).toBe("rbxassetid://507771019")

		harness:advanceToPhase("Results")
		local afterShowcase = lastOf(presentationsFor(harness, PLAYER))
		expect(afterShowcase.presentationReason).toBe("ShowcaseEnded")
		expect(afterShowcase.stagePlaceNumber).toBeNil()
		expect(afterShowcase.danceAnimationAssetId).toBeNil()
		expect(afterShowcase.outfitStylingItemKeysToWear).toEqual({})
		expect(harness.modules.characterAppearanceAndStageDirector:listStagedPlayerUserIds()).toEqual({})
	end)

	it(
		"publishes the result OutfitScoreCalculator gives for the round's theme and bonus, pays it and shows it in the next snapshot",
		function()
			local harness = ServerGameAssemblyTestHarness.createStartedServer()
			harness:joinPlayer(PLAYER)
			harness:ask("RequestJoinCurrentRound", PLAYER)
			harness:advanceToPhase("Styling")
			local roundState = harness:readRoundState()
			harness:sendDraft(PLAYER, {
				roundId = roundState.roundId,
				outfitDraftSequenceNumber = 1,
				outfitStylingItemKeys = SIX_ITEM_DRESS_OUTFIT,
			})
			harness:advanceToPhase("Results")
			local expectedScore = OutfitScoreCalculator.calculateOutfitScore(
				SIX_ITEM_DRESS_OUTFIT,
				StylingItemLookup.buildStylingItemByStylingItemKey(StylingItemPool.STYLING_ITEMS),
				ThemeCatalog.findThemeByThemeId(roundState.themeId),
				roundState.roundBonusRule
			)
			local published = lastOf(harness:listSent("RoundResultsPublished"))
			expect(published.roundId).toBe(roundState.roundId)
			local entry = published.roundResults[1]
			expect(entry.playerUserId).toBe(PLAYER)
			expect(entry.outfitScore).toBe(expectedScore.outfitScore)
			expect(entry.starCount).toBe(expectedScore.starCount)
			expect(entry.starCoinsGranted).toBe(expectedScore.starCoinsGranted)
			expect(entry.fanCountGained).toBe(expectedScore.fanCountGained)
			expect(expectedScore.starCount >= 1).toBeTrue()
			local snapshot = lastOf(harness:listSent("PlayerSaveDataSnapshotChanged", PLAYER))
			expect(snapshot.starCoinBalance).toBe(expectedScore.starCoinsGranted)
			expect(snapshot.fanCount).toBe(expectedScore.fanCountGained)
			harness:advance(11)
			expect(harness.playerSaveDataStorage:readStoredPlayerSaveDataCopy(PLAYER).starCoinBalance).toBe(
				expectedScore.starCoinsGranted
			)
		end
	)

	it("lists a participant who sent nothing with zeros and pays nothing", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		harness:joinPlayer(PLAYER)
		harness:ask("RequestJoinCurrentRound", PLAYER)
		harness:advanceToPhase("Results")
		local entry = lastOf(harness:listSent("RoundResultsPublished")).roundResults[1]
		expect(entry.playerUserId).toBe(PLAYER)
		expect({ entry.outfitScore, entry.starCount, entry.starCoinsGranted, entry.fanCountGained }).toEqual({
			0,
			0,
			0,
			0,
		})
		expect(entry.isNewBestStarCountForTheme).toBeFalse()
		expect(harness.modules.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).totalRoundsCompletedCount).toBe(0)
		local onStage = presentationsFor(harness, PLAYER)
		local showcasePresentation = nil
		for _, presentation in onStage do
			if presentation.presentationReason == "ShowcaseBegan" then
				showcasePresentation = presentation
			end
		end
		expect(showcasePresentation.characterSpawnAppearanceCase).toBe("LobbyAppearanceOnStage")
		expect(showcasePresentation.outfitStylingItemKeysToWear).toEqual({})
	end)
end)

describe("ServerGameModuleAssembly: round questions the lobby modules ask, and quest progress", function()
	it("refuses a lobby outfit to a Styling or Showcase participant and lobby dancing on stage only", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		local OTHER_PLAYER = 1001
		harness:joinPlayer(PLAYER)
		harness:joinPlayer(OTHER_PLAYER)
		harness:ask("RequestJoinCurrentRound", PLAYER)
		harness:advanceToPhase("Styling")
		local lobbyOutfitRequest = { outfitStylingItemKeys = { "asset_7259123616" } }
		expect(harness:ask("SetLobbyOutfit", PLAYER, lobbyOutfitRequest).rejectionReason).toBe("NotAllowedDuringRound")
		expect(harness:ask("SetLobbyOutfit", OTHER_PLAYER, lobbyOutfitRequest)).toEqual({ isAccepted = true })
		expect(harness:ask("RequestStartDanceInLobby", PLAYER, "starter_groove")).toEqual({ isAccepted = true })
		harness:advanceToPhase("Showcase")
		expect(harness:ask("RequestStartDanceInLobby", PLAYER, "starter_sway").rejectionReason).toBe(
			"NotAllowedDuringRound"
		)
		expect(harness:ask("RequestStartDanceInLobby", OTHER_PLAYER, "starter_sway")).toEqual({ isAccepted = true })
	end)

	it(
		"writes daily quest progress inside the round reward (the tracker's record writer is given to the ledger)",
		function()
			local harness = ServerGameAssemblyTestHarness.createStartedServer()
			harness:joinPlayer(PLAYER)
			harness:ask("RequestJoinCurrentRound", PLAYER)
			harness:advanceToPhase("Styling")
			harness:sendDraft(PLAYER, {
				roundId = harness:readRoundState().roundId,
				outfitDraftSequenceNumber = 1,
				outfitStylingItemKeys = SIX_ITEM_DRESS_OUTFIT,
			})
			harness:advanceToPhase("Results")
			local saveData = harness.modules.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
			expect(saveData.totalRoundsCompletedCount).toBe(1)
			expect(next(saveData.dailyProgress.dailyQuestProgressCountByQuestId) ~= nil).toBeTrue()
		end
	)
end)

describe("ServerGameModuleAssembly: unattended rounds, lobby outfit, leaving and shutdown", function()
	it("cycles three whole rounds with nobody taking part, every phase in order, with no warning", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		harness:advance(3 * 280)
		local phases = {}
		for _, roundStateMessage in harness:listSent("RoundStateChanged") do
			table.insert(phases, roundStateMessage.roundPhase)
		end
		expect(#phases).toBe(16)
		for phaseIndex, roundPhase in phases do
			local expectedPhase = ({ "ThemeReveal", "Styling", "Showcase", "Results", "Intermission" })[(phaseIndex - 1) % 5 + 1]
			expect(roundPhase).toBe(expectedPhase)
		end
		expect(#harness:listSent("RoundResultsPublished")).toBe(3)
		expect(harness.logger.loggedWarnings).toEqual({})
	end)

	it("presents the lobby outfit at spawn and when the player changes it outside a round", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		harness:joinPlayer(PLAYER)
		harness.modules.characterAppearanceAndStageDirector:handleCharacterSpawned(PLAYER)
		expect(lastOf(presentationsFor(harness, PLAYER)).outfitStylingItemKeysToWear).toEqual({})
		harness:ask("SetLobbyOutfit", PLAYER, { outfitStylingItemKeys = { "asset_7259123616", "asset_11884330" } })
		local changed = lastOf(presentationsFor(harness, PLAYER))
		expect(changed.presentationReason).toBe("LobbyOutfitChanged")
		expect(changed.outfitStylingItemKeysToWear).toEqual({ "asset_7259123616", "asset_11884330" })
		expect(changed.stagePlaceNumber).toBeNil()
	end)

	it("on leaving: removes the participant, forgets the presenter state and hands the save back", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		harness:joinPlayer(PLAYER)
		harness:ask("RequestJoinCurrentRound", PLAYER)
		harness.modules.playerServerLifecycleSequences:handlePlayerLeavingServer(PLAYER)
		harness:advance(0)
		expect(harness.modules.themedRoundReferee:isParticipantOfCurrentRound(PLAYER)).toBeFalse()
		expect(harness.characterAppearancePresenter.forgotPlayerUserIds).toEqual({ PLAYER })
		expect(harness.playerSaveDataStorage:readStoredPlayerSaveDataCopy(PLAYER).gameServerSessionLock).toBeNil()
	end)

	it("on shutdown: stops the rounds, writes every final save and then calls back once", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		harness:joinPlayer(PLAYER)
		local finishedCallCount = 0
		harness.modules.playerServerLifecycleSequences:startServerShutdownSequence(function()
			finishedCallCount += 1
		end)
		expect(harness.modules.themedRoundReferee:isServerShuttingDown()).toBeTrue()
		expect(harness.modules.themedRoundClock:isRoundCycleRunning()).toBeFalse()
		harness:advance(0)
		expect(finishedCallCount).toBe(1)
		expect(harness.playerSaveDataStorage:readStoredPlayerSaveDataCopy(PLAYER).gameServerSessionLock).toBeNil()
		harness.modules.playerServerLifecycleSequences:handlePlayerLeavingServer(PLAYER)
		harness:advance(30)
		expect(finishedCallCount).toBe(1)
	end)
end)
