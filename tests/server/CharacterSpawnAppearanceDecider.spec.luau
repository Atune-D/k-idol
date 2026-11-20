-- CharacterSpawnAppearanceDecider with ThemedRoundReferee:readCharacterSpawnRoundFacts
-- (development spec §2.4 "Respawn" table, §3.7). Referee audit PART 3 section K, scenarios 71 to
-- 74, PART 1 question 23 (owner question, both answers) and PART 2 item o.

local UnitTestFramework = require("../Support/UnitTestFramework")
local CharacterSpawnAppearanceDecider = require("../../src/server/CharacterSpawnAppearanceDecider")
local ThemedRoundOwnerDecisions = require("../../src/server/ThemedRoundOwnerDecisions")
local ThemedRoundRefereeTestHarness = require("./ThemedRoundRefereeTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_P = ThemedRoundRefereeTestHarness.PLAYER_P
local PLAYER_Q = ThemedRoundRefereeTestHarness.PLAYER_Q
local PLAYER_R = ThemedRoundRefereeTestHarness.PLAYER_R
local PLAYER_S = ThemedRoundRefereeTestHarness.PLAYER_S
local OUTFIT_A = ThemedRoundRefereeTestHarness.OUTFIT_A
local OUTFIT_B = ThemedRoundRefereeTestHarness.OUTFIT_B
local OUTFIT_E83 = ThemedRoundRefereeTestHarness.WORKED_EXAMPLE_OUTFIT_E83
local createRefereeWithFakes = ThemedRoundRefereeTestHarness.createRefereeWithFakes
local decideCharacterSpawnAppearance = CharacterSpawnAppearanceDecider.decideCharacterSpawnAppearance

local LOBBY_OUTFIT = table.freeze({ "asset_9000003", "asset_9000013" })

local function decideSpawnAppearanceNow(harness, playerUserId: number, ownerDecisions: any?)
	return decideCharacterSpawnAppearance({
		isPlayerSaveDataLoaded = harness.playerSaveDataKeeper:isPlayerSaveDataLoaded(playerUserId),
		wearableLobbyOutfitStylingItemKeys = LOBBY_OUTFIT,
		characterSpawnRoundFacts = harness.referee:readCharacterSpawnRoundFacts(playerUserId),
	}, ownerDecisions)
end

local function lobbyAppearance(characterSpawnAppearanceCase: string?)
	return {
		characterSpawnAppearanceCase = characterSpawnAppearanceCase or "LobbyAppearance",
		outfitStylingItemKeysToWear = LOBBY_OUTFIT,
		shouldRestartDance = false,
	}
end

-- P keeps E83 and Q keeps nothing; R never joins. Leaves time at T = 20.
local function createHarnessWithParticipantsPAndQ()
	local harness = createRefereeWithFakes()
	harness.loadAndJoinAtRoundSecond3({ PLAYER_P, PLAYER_Q })
	harness.loadPlayer(PLAYER_R)
	harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
	return harness
end

describe("CharacterSpawnAppearanceDecider §2.4 table rows (audit scenario 71)", function()
	it("participant during Showcase: the scored outfit, their stage place, the dance restarted", function()
		local harness = createHarnessWithParticipantsPAndQ()
		harness.advanceToRoundSecond(200)
		local characterSpawnAppearance = decideSpawnAppearanceNow(harness, PLAYER_P)
		expect(characterSpawnAppearance).toEqual({
			characterSpawnAppearanceCase = "ScoredOutfitOnStage",
			outfitStylingItemKeysToWear = OUTFIT_E83,
			stagePlaceNumber = 1,
			shouldRestartDance = true,
		})
		expect(table.isfrozen(characterSpawnAppearance)).toBeTrue()
		expect(table.isfrozen(characterSpawnAppearance.outfitStylingItemKeysToWear)).toBeTrue()
	end)

	it("participant during Styling: the lobby appearance (the device re-applies its draft preview)", function()
		local harness = createHarnessWithParticipantsPAndQ()
		harness.advanceToRoundSecond(60)
		expect(decideSpawnAppearanceNow(harness, PLAYER_P)).toEqual(lobbyAppearance("LobbyAppearanceWhileStyling"))
	end)

	it("participant in ThemeReveal, Results or Intermission: the lobby appearance", function()
		local harness = createHarnessWithParticipantsPAndQ()
		for _, roundSecond in { 5, 255, 275 } do
			if roundSecond == 5 then
				local themeRevealHarness = createRefereeWithFakes()
				themeRevealHarness.loadAndJoinAtRoundSecond3({ PLAYER_P })
				themeRevealHarness.advanceToRoundSecond(5)
				expect(decideSpawnAppearanceNow(themeRevealHarness, PLAYER_P)).toEqual(lobbyAppearance())
			else
				harness.advanceToRoundSecond(roundSecond)
				expect(harness.referee:isParticipantOfCurrentRound(PLAYER_P)).toBeTrue()
				expect(decideSpawnAppearanceNow(harness, PLAYER_P)).toEqual(lobbyAppearance())
			end
		end
	end)

	it("non-participant in every phase: the lobby appearance", function()
		local harness = createHarnessWithParticipantsPAndQ()
		for _, roundSecond in { 25, 60, 200, 255, 275 } do
			harness.advanceToRoundSecond(roundSecond)
			expect(decideSpawnAppearanceNow(harness, PLAYER_R)).toEqual(lobbyAppearance())
		end
		local themeRevealHarness = createRefereeWithFakes()
		themeRevealHarness.loadPlayer(PLAYER_R)
		themeRevealHarness.advanceToRoundSecond(5)
		expect(decideSpawnAppearanceNow(themeRevealHarness, PLAYER_R)).toEqual(lobbyAppearance())
	end)
end)

describe("CharacterSpawnAppearanceDecider reads the state at the moment of spawn (audit scenario 72)", function()
	it("a reset at T=249.5 that spawns at T=250.5 gets the lobby appearance", function()
		local harness = createHarnessWithParticipantsPAndQ()
		harness.advanceToRoundSecond(250.5)
		expect(decideSpawnAppearanceNow(harness, PLAYER_P)).toEqual(lobbyAppearance())
	end)

	it("a reset at T=189.5 that spawns at T=190.5 gets the scored outfit on stage", function()
		local harness = createHarnessWithParticipantsPAndQ()
		harness.advanceToRoundSecond(190.5)
		expect(decideSpawnAppearanceNow(harness, PLAYER_P).characterSpawnAppearanceCase).toBe("ScoredOutfitOnStage")
	end)
end)

describe("CharacterSpawnAppearanceDecider gaps in the table (audit scenario 73, owner question 23)", function()
	it("save not loaded: lobby appearance with an empty outfit, whatever the round facts say, without error", function()
		local characterSpawnAppearance = decideCharacterSpawnAppearance({
			isPlayerSaveDataLoaded = false,
			wearableLobbyOutfitStylingItemKeys = nil :: any,
			characterSpawnRoundFacts = {
				roundPhase = "Showcase",
				isParticipant = true,
				showcaseStageEntry = {
					stagePlaceNumber = 2,
					scoredOutfitStylingItemKeys = OUTFIT_E83,
					outfitScore = 83,
				},
			},
		})
		expect(characterSpawnAppearance).toEqual({
			characterSpawnAppearanceCase = "LobbyAppearance",
			outfitStylingItemKeysToWear = {},
			shouldRestartDance = false,
		})
		local harness = createRefereeWithFakes()
		harness.advanceToRoundSecond(200)
		expect(decideSpawnAppearanceNow(harness, PLAYER_S).outfitStylingItemKeysToWear).toEqual({})
	end)

	it(
		"default: a participant on stage with an empty scored outfit gets their place and dance in the lobby appearance",
		function()
			local harness = createHarnessWithParticipantsPAndQ()
			harness.advanceToRoundSecond(200)
			expect(decideSpawnAppearanceNow(harness, PLAYER_Q)).toEqual({
				characterSpawnAppearanceCase = "LobbyAppearanceOnStage",
				outfitStylingItemKeysToWear = LOBBY_OUTFIT,
				stagePlaceNumber = 2,
				shouldRestartDance = true,
			})
		end
	)

	it("alternative answer: the empty scored outfit itself is worn on stage", function()
		local harness = createHarnessWithParticipantsPAndQ()
		harness.advanceToRoundSecond(200)
		local wearingOwnerDecisions = table.clone(ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS)
		wearingOwnerDecisions.shouldShowLobbyAppearanceOnStageForEmptyScoredOutfit = false
		expect(decideSpawnAppearanceNow(harness, PLAYER_Q, wearingOwnerDecisions)).toEqual({
			characterSpawnAppearanceCase = "ScoredOutfitOnStage",
			outfitStylingItemKeysToWear = {},
			stagePlaceNumber = 2,
			shouldRestartDance = true,
		})
	end)

	it("stage places are never reassigned when someone leaves", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P, PLAYER_Q, PLAYER_R })
		for _, playerUserId in { PLAYER_P, PLAYER_Q, PLAYER_R } do
			harness.sendDraftAtRoundSecond(20, playerUserId, 1, OUTFIT_A)
		end
		harness.leaveServerAtRoundSecond(210, PLAYER_Q)
		harness.advanceToRoundSecond(215)
		expect(decideSpawnAppearanceNow(harness, PLAYER_R).stagePlaceNumber).toBe(3)
		expect(decideSpawnAppearanceNow(harness, PLAYER_P).stagePlaceNumber).toBe(1)
	end)

	it("a participant who left and spawns again gets the lobby appearance", function()
		local harness = createHarnessWithParticipantsPAndQ()
		harness.leaveServerAtRoundSecond(200, PLAYER_P)
		harness.advanceToRoundSecond(229)
		harness.loadPlayerFromWhatStorageHolds(PLAYER_P)
		harness.advanceToRoundSecond(230)
		expect(decideSpawnAppearanceNow(harness, PLAYER_P)).toEqual(lobbyAppearance())
	end)

	it("a stage entry outside Showcase is never used: the phase decides first", function()
		for _, roundPhase in { "Results", "Styling", "ThemeReveal", "Intermission" } do
			local characterSpawnAppearance = decideCharacterSpawnAppearance({
				isPlayerSaveDataLoaded = true,
				wearableLobbyOutfitStylingItemKeys = LOBBY_OUTFIT,
				characterSpawnRoundFacts = {
					roundPhase = roundPhase,
					isParticipant = true,
					showcaseStageEntry = {
						stagePlaceNumber = 2,
						scoredOutfitStylingItemKeys = OUTFIT_E83,
						outfitScore = 83,
					},
				},
			})
			expect(characterSpawnAppearance.stagePlaceNumber).toBeNil()
			expect(characterSpawnAppearance.outfitStylingItemKeysToWear).toEqual(LOBBY_OUTFIT)
		end
	end)

	it(
		"save loaded but the lobby outfit not known yet: the empty outfit stands in, the round decides the rest",
		function()
			local function decideWithUnknownLobbyOutfit(characterSpawnRoundFacts)
				return decideCharacterSpawnAppearance({
					isPlayerSaveDataLoaded = true,
					wearableLobbyOutfitStylingItemKeys = nil,
					characterSpawnRoundFacts = characterSpawnRoundFacts,
				})
			end
			local harness = createHarnessWithParticipantsPAndQ()
			harness.advanceToRoundSecond(60)
			expect(decideWithUnknownLobbyOutfit(harness.referee:readCharacterSpawnRoundFacts(PLAYER_P))).toEqual({
				characterSpawnAppearanceCase = "LobbyAppearanceWhileStyling",
				outfitStylingItemKeysToWear = {},
				shouldRestartDance = false,
			})
			harness.advanceToRoundSecond(200)
			expect(decideWithUnknownLobbyOutfit(harness.referee:readCharacterSpawnRoundFacts(PLAYER_P))).toEqual({
				characterSpawnAppearanceCase = "ScoredOutfitOnStage",
				outfitStylingItemKeysToWear = OUTFIT_E83,
				stagePlaceNumber = 1,
				shouldRestartDance = true,
			})
			local onStageWithEmptyOutfit =
				decideWithUnknownLobbyOutfit(harness.referee:readCharacterSpawnRoundFacts(PLAYER_Q))
			expect(onStageWithEmptyOutfit.characterSpawnAppearanceCase).toBe("LobbyAppearanceOnStage")
			expect(onStageWithEmptyOutfit.outfitStylingItemKeysToWear).toEqual({})
			expect(table.isfrozen(onStageWithEmptyOutfit.outfitStylingItemKeysToWear)).toBeTrue()
			expect(decideWithUnknownLobbyOutfit(harness.referee:readCharacterSpawnRoundFacts(PLAYER_R))).toEqual({
				characterSpawnAppearanceCase = "LobbyAppearance",
				outfitStylingItemKeysToWear = {},
				shouldRestartDance = false,
			})
		end
	)

	it("a participant in Showcase without a stage entry gets the lobby appearance", function()
		local characterSpawnAppearance = decideCharacterSpawnAppearance({
			isPlayerSaveDataLoaded = true,
			wearableLobbyOutfitStylingItemKeys = LOBBY_OUTFIT,
			characterSpawnRoundFacts = { roundPhase = "Showcase", isParticipant = true, showcaseStageEntry = nil },
		})
		expect(characterSpawnAppearance).toEqual(lobbyAppearance())
	end)
end)

describe("CharacterSpawnAppearanceDecider is read-only (audit scenario 74, PART 2 item o)", function()
	it("1000 decisions during Styling and Showcase change no draft state, score or result", function()
		local harness = createHarnessWithParticipantsPAndQ()
		harness.sendDraftAtRoundSecond(30, PLAYER_P, 2, OUTFIT_B)
		local draftKeeper = harness.createdDraftKeepers[1]
		for _ = 1, 500 do
			decideSpawnAppearanceNow(harness, PLAYER_P)
		end
		expect(draftKeeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_B)
		expect(draftKeeper:readHighestProcessedOutfitDraftSequenceNumber(PLAYER_P)).toBe(2)
		harness.advanceToRoundSecond(200)
		local showcaseStageEntryBefore = harness.referee:readShowcaseStageEntry(PLAYER_P)
		for _ = 1, 500 do
			decideSpawnAppearanceNow(harness, PLAYER_P)
		end
		expect(harness.referee:readShowcaseStageEntry(PLAYER_P)).toEqual(showcaseStageEntryBefore)
		harness.advanceToRoundSecond(251)
		expect(harness.listPublishedRoundResultsMessages()[1].roundResults[1].outfitScore).toBe(
			showcaseStageEntryBefore.outfitScore
		)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(2)
	end)

	it("the returned outfit cannot be changed and is never the caller's or the referee's list", function()
		local harness = createHarnessWithParticipantsPAndQ()
		harness.advanceToRoundSecond(200)
		local characterSpawnAppearance = decideSpawnAppearanceNow(harness, PLAYER_P)
		expect(function()
			(characterSpawnAppearance.outfitStylingItemKeysToWear :: any)[1] = "asset_9000002"
		end).toThrow()
		local refereeScoredOutfit = harness.referee:readShowcaseStageEntry(PLAYER_P).scoredOutfitStylingItemKeys
		expect(rawequal(characterSpawnAppearance.outfitStylingItemKeysToWear, refereeScoredOutfit)).toBeFalse()
		expect(refereeScoredOutfit).toEqual(OUTFIT_E83)

		local callerLobbyOutfit = { "asset_9000003" }
		local lobbyDecision = decideCharacterSpawnAppearance({
			isPlayerSaveDataLoaded = true,
			wearableLobbyOutfitStylingItemKeys = callerLobbyOutfit,
			characterSpawnRoundFacts = harness.referee:readCharacterSpawnRoundFacts(PLAYER_R),
		})
		callerLobbyOutfit[1] = "asset_9000002"
		expect(lobbyDecision.outfitStylingItemKeysToWear).toEqual({ "asset_9000003" })
		expect(table.isfrozen(lobbyDecision.outfitStylingItemKeysToWear)).toBeTrue()
	end)

	it("the referee's spawn facts are frozen and match the round", function()
		local harness = createHarnessWithParticipantsPAndQ()
		harness.advanceToRoundSecond(200)
		local characterSpawnRoundFacts = harness.referee:readCharacterSpawnRoundFacts(PLAYER_P)
		expect(table.isfrozen(characterSpawnRoundFacts)).toBeTrue()
		expect(table.isfrozen(characterSpawnRoundFacts.showcaseStageEntry)).toBeTrue()
		expect(characterSpawnRoundFacts).toEqual({
			roundPhase = "Showcase",
			isParticipant = true,
			showcaseStageEntry = { stagePlaceNumber = 1, scoredOutfitStylingItemKeys = OUTFIT_E83, outfitScore = 83 },
		})
		harness.themedRoundClock:stopRoundCycle()
		expect(harness.referee:readCharacterSpawnRoundFacts(PLAYER_P)).toEqual({ isParticipant = false })
	end)
end)
