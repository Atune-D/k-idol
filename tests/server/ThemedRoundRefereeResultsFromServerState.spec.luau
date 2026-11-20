-- ThemedRoundReferee: results come only from what the server holds (development spec §2.3,
-- §2.5, §3.3 "never accepts a score, star count or reward amount from a device"), and the kept
-- draft is scored as kept even when the available-item set changes during Styling (§1.2, §2.14).
-- Referee audit PART 3 scenarios 38 (at referee level), 64 and section I (65 to 67), PART 1
-- question 10.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local OutfitScoreCalculator = require("../../src/shared/OutfitScoreCalculator")
local ThemeCatalog = require("../../src/shared/ThemeCatalog")
local ThemedRoundRefereeTestHarness = require("./ThemedRoundRefereeTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_P = ThemedRoundRefereeTestHarness.PLAYER_P
local PLAYER_Q = ThemedRoundRefereeTestHarness.PLAYER_Q
local PLAYER_R = ThemedRoundRefereeTestHarness.PLAYER_R
local OUTFIT_A = ThemedRoundRefereeTestHarness.OUTFIT_A
local OUTFIT_C = ThemedRoundRefereeTestHarness.OUTFIT_C
local OUTFIT_E83 = ThemedRoundRefereeTestHarness.WORKED_EXAMPLE_OUTFIT_E83
local expectedAcknowledgement = ThemedRoundRefereeTestHarness.expectedAcknowledgement
local createRefereeWithFakes = ThemedRoundRefereeTestHarness.createRefereeWithFakes

-- In round 1 (y2k_pop, pink ColorBonus): 91 points / 5 stars and 65 / 3 stars.
local OUTFIT_SCORING_91 = table.freeze({
	"asset_9000001",
	"asset_9000011",
	"asset_9000021",
	"bundle_9000041",
	"asset_9000051",
	"asset_9000062",
})
local OUTFIT_SCORING_65 = table.freeze({ "asset_9000001", "asset_9000011", "asset_9000051" })
local WORKED_EXAMPLE_HAIR_KEY = "asset_9000001"
local ROUND_ONE_BONUS_RULE = table.freeze({ roundBonusKind = "ColorBonus", bonusColorTag = "pink" })

local function scoreInRoundOne(outfitStylingItemKeys: { string })
	return OutfitScoreCalculator.calculateOutfitScore(
		outfitStylingItemKeys,
		FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
		ThemeCatalog.findThemeByThemeId("y2k_pop") :: any,
		ROUND_ONE_BONUS_RULE
	)
end

local function readRoundOneResults(harness)
	return harness.listPublishedRoundResultsMessages()[1].roundResults
end

describe("ThemedRoundReferee results come only from server state (audit scenarios 64 and 38)", function()
	it(
		"scenario 64: every field equals calculateOutfitScore on the kept draft, with the server's id and name",
		function()
			local harness = createRefereeWithFakes()
			harness.loadAndJoinAtRoundSecond3({ PLAYER_P, PLAYER_Q, PLAYER_R })
			local keptOutfitByPlayerUserId =
				{ [PLAYER_P] = OUTFIT_SCORING_91, [PLAYER_Q] = OUTFIT_C, [PLAYER_R] = OUTFIT_SCORING_65 }
			for playerUserId, keptOutfit in keptOutfitByPlayerUserId do
				harness.sendDraftAtRoundSecond(20, playerUserId, 1, keptOutfit)
			end
			harness.advanceToRoundSecond(251)
			expect(#readRoundOneResults(harness)).toBe(3)
			for _, roundResultsEntry in readRoundOneResults(harness) do
				local outfitScoreBreakdown = scoreInRoundOne(keptOutfitByPlayerUserId[roundResultsEntry.playerUserId])
				expect(roundResultsEntry.playerDisplayName).toBe("Player " .. tostring(roundResultsEntry.playerUserId))
				for _, scoreFieldName in
					{
						"outfitScore",
						"themeMatchPoints",
						"completenessPoints",
						"colorHarmonyPoints",
						"roundBonusPoints",
						"starCount",
					}
				do
					expect(roundResultsEntry[scoreFieldName]).toBe(outfitScoreBreakdown[scoreFieldName])
				end
				expect(roundResultsEntry.starCoinsGranted).toBe(outfitScoreBreakdown.starCoinsGranted)
				expect(roundResultsEntry.fanCountGained).toBe(outfitScoreBreakdown.fanCountGained)
			end
		end
	)

	it("scenario 38: forged result fields in a draft are never read; P is paid for E83 and Q is untouched", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P, PLAYER_Q })
		harness.advanceToRoundSecond(20)
		local forgedDraftMessage = harness.buildOutfitDraftMessage(1, OUTFIT_E83)
		forgedDraftMessage.outfitScore = 100
		forgedDraftMessage.starCount = 5
		forgedDraftMessage.starCoinsGranted = 1e9
		forgedDraftMessage.fanCountGained = 1e9
		forgedDraftMessage.playerUserId = PLAYER_Q
		harness.referee:receiveSetRoundOutfitDraftFromDevice(PLAYER_P, forgedDraftMessage)
		harness.advanceToRoundSecond(251)
		local roundResults = readRoundOneResults(harness)
		expect(roundResults[1].playerUserId).toBe(PLAYER_P)
		expect({
			roundResults[1].outfitScore,
			roundResults[1].starCount,
			roundResults[1].starCoinsGranted,
			roundResults[1].fanCountGained,
		}).toEqual({
			83,
			4,
			80,
			40,
		})
		expect(harness.recordedGrantCalls[1].themedRoundCompletion.starCount).toBe(4)
		expect(roundResults[2].playerUserId).toBe(PLAYER_Q)
		expect(roundResults[2].starCoinsGranted).toBe(0)
		expect(harness.readInMemorySaveData(PLAYER_Q).starCoinBalance).toBe(350)
	end)
end)

describe("ThemedRoundReferee available-item set changing during Styling (audit section I)", function()
	it("scenario 65: a kept draft keeps its score when one of its items is hidden later", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(40, PLAYER_P, 1, OUTFIT_E83)
		harness.advanceToRoundSecond(120)
		harness.hideStylingItemKeyFromNowOn(WORKED_EXAMPLE_HAIR_KEY)
		harness.advanceToRoundSecond(190)
		local showcaseStageEntry = harness.referee:readShowcaseStageEntry(PLAYER_P)
		expect(showcaseStageEntry.scoredOutfitStylingItemKeys).toEqual(OUTFIT_E83)
		expect(showcaseStageEntry.outfitScore).toBe(83)
		harness.advanceToRoundSecond(251)
		expect(readRoundOneResults(harness)[1].outfitScore).toBe(83)
		expect(#harness.recordingLogger.loggedWarnings).toBe(0)
	end)

	it("scenario 48: an item hidden after the cut-off changes neither the entry nor the grant at T=250", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(40, PLAYER_P, 1, OUTFIT_E83)
		harness.advanceToRoundSecond(220)
		harness.hideStylingItemKeyFromNowOn(WORKED_EXAMPLE_HAIR_KEY)
		harness.advanceToRoundSecond(250)
		local roundResultsEntry = readRoundOneResults(harness)[1]
		expect({ roundResultsEntry.outfitScore, roundResultsEntry.starCount, roundResultsEntry.starCoinsGranted }).toEqual({
			83,
			4,
			80,
		})
		expect(harness.recordedGrantCalls[1].themedRoundCompletion.starCount).toBe(4)
		expect(harness.recordedGrantCalls[1].themedRoundCompletion.scoredOutfitStylingItemKeys).toEqual(OUTFIT_E83)
	end)

	it("scenario 66: a waiting draft is validated when processed, against the set current then", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(119.90, PLAYER_P, 5, OUTFIT_A)
		harness.sendDraftAtRoundSecond(119.95, PLAYER_P, 6, OUTFIT_C)
		harness.advanceToRoundSecond(120)
		harness.hideStylingItemKeyFromNowOn(OUTFIT_C[1])
		harness.advanceToRoundSecond(121)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(119.90, "round-1", 5, true),
			expectedAcknowledgement(120.15, "round-1", 6, false),
		})
		harness.advanceToRoundSecond(200)
		expect(harness.referee:readShowcaseStageEntry(PLAYER_P).scoredOutfitStylingItemKeys).toEqual(OUTFIT_A)
	end)

	it("scenario 67: a new draft still holding the hidden item is refused and the kept draft stays", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(40, PLAYER_P, 1, OUTFIT_E83)
		harness.advanceToRoundSecond(120)
		harness.hideStylingItemKeyFromNowOn(WORKED_EXAMPLE_HAIR_KEY)
		harness.sendDraftAtRoundSecond(125, PLAYER_P, 2, OUTFIT_E83)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[2]).toEqual(
			expectedAcknowledgement(125, "round-1", 2, false)
		)
		harness.advanceToRoundSecond(200)
		expect(harness.referee:readShowcaseStageEntry(PLAYER_P).outfitScore).toBe(83)
	end)
end)
