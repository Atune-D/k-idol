-- ThemedRoundReferee when one of its own server dependencies raises (not a device value): the
-- available-set read during the cut-off, the theme lookup at ThemeReveal, and the score
-- calculation. One failure must cost at most the one participant it hit; every other
-- participant is still scored, staged and paid, and RoundStateChanged still goes out (§2.1, §2.3
-- "Cut-off", §2.5; audit question 18 "one failure never blocks the others").

local UnitTestFramework = require("../Support/UnitTestFramework")
local RecordingLogger = require("../Support/RecordingLogger")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local RefereedThemedRound = require("../../src/server/RefereedThemedRound")
local ThemeCatalog = require("../../src/shared/ThemeCatalog")
local ThemedRoundRefereeTestHarness = require("./ThemedRoundRefereeTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_P = ThemedRoundRefereeTestHarness.PLAYER_P
local PLAYER_Q = ThemedRoundRefereeTestHarness.PLAYER_Q
local OUTFIT_A = ThemedRoundRefereeTestHarness.OUTFIT_A
local OUTFIT_B = ThemedRoundRefereeTestHarness.OUTFIT_B
local OUTFIT_E83 = ThemedRoundRefereeTestHarness.WORKED_EXAMPLE_OUTFIT_E83
local createRefereeWithFakes = ThemedRoundRefereeTestHarness.createRefereeWithFakes

-- The resolver's available-set read raises once, the next time it is called after `breakOnce`.
local function makeAvailableSetReadRaiseOnce(harness)
	local fakeResolver = harness.fakeResolver
	local readRealAvailableStylingItemKeySet = fakeResolver.getAvailableStylingItemKeySet
	local isBroken = false
	fakeResolver.getAvailableStylingItemKeySet = function(resolver)
		if isBroken then
			isBroken = false
			error("deliberate available-set failure")
		end
		return readRealAvailableStylingItemKeySet(resolver)
	end
	return function()
		isBroken = true
	end
end

local function findShowcaseBroadcast(harness)
	for _, sentRecord in harness.sentRoundStateChangedRecords do
		if sentRecord.roundStateChangedMessage.roundPhase == "Showcase" then
			return sentRecord.roundStateChangedMessage
		end
	end
	return nil
end

describe("ThemedRoundReferee cut-off with a raising available-set read", function()
	it("costs only the waiting draft it hit: everyone is still scored, staged, paid and told of Showcase", function()
		local harness = createRefereeWithFakes()
		local breakAvailableSetReadOnce = makeAvailableSetReadRaiseOnce(harness)
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P, PLAYER_Q })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
		harness.sendDraftAtRoundSecond(20, PLAYER_Q, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(189.90, PLAYER_Q, 2, OUTFIT_E83)
		harness.sendDraftAtRoundSecond(189.95, PLAYER_Q, 3, OUTFIT_B) -- waits until the cut-off
		harness.advanceToRoundSecond(189.99)
		breakAvailableSetReadOnce()
		harness.advanceToRoundSecond(190)

		local showcaseBroadcast = findShowcaseBroadcast(harness)
		expect(showcaseBroadcast ~= nil).toBeTrue()
		expect(showcaseBroadcast.participantUserIds).toEqual({ PLAYER_P, PLAYER_Q })
		expect(harness.referee:readShowcaseStageEntry(PLAYER_P).outfitScore).toBe(83)
		-- Q keeps the draft acknowledged before the failure (seq 2), never the unprocessed seq 3.
		expect(harness.referee:readShowcaseStageEntry(PLAYER_Q).scoredOutfitStylingItemKeys).toEqual(OUTFIT_E83)
		expect(#harness.listAcknowledgementsSentTo(PLAYER_Q)).toBe(2)
		expect(#harness.recordingLogger.loggedWarnings).toBe(1)
		expect(harness.recordingLogger:countWarningsContaining("waiting drafts of round round-1 raised")).toBe(1)

		harness.advanceToRoundSecond(250)
		local roundResults = harness.listPublishedRoundResultsMessages()[1].roundResults
		expect(#roundResults).toBe(2)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(1)
		expect(harness.countGrantCallsFor(PLAYER_Q)).toBe(1)
	end)
end)

describe("ThemedRoundReferee phase step that raises", function()
	it("logs the failure and still sends RoundStateChanged for that phase", function()
		local harness = createRefereeWithFakes({
			findThemeByThemeId = function(themeId: string)
				if themeId == "y2k_pop" then
					error("deliberate theme lookup failure")
				end
				return ThemeCatalog.findThemeByThemeId(themeId)
			end,
		})
		expect(#harness.sentRoundStateChangedRecords).toBe(1)
		expect(harness.sentRoundStateChangedRecords[1].roundStateChangedMessage.roundPhase).toBe("ThemeReveal")
		expect(harness.recordingLogger:countWarningsContaining("the ThemeReveal step of round round-1 raised")).toBe(1)
		expect(harness.recordingLogger:countWarningsContaining("deliberate theme lookup failure")).toBe(1)
		harness.loadPlayer(PLAYER_P)
		expect(harness.joinAtRoundSecond(3, PLAYER_P)).toEqual({
			isAccepted = false,
			rejectionReason = "RoundNotJoinableNow",
		})
		harness.advanceToRoundSecond(279)
		expect(#harness.sentRoundStateChangedRecords).toBe(5)
		expect(harness.joinAtRoundSecond(281, PLAYER_P)).toEqual({ isAccepted = true })
	end)
end)

describe("RefereedThemedRound scoring that raises for one participant", function()
	-- A draft keeper stand-in whose cut-off hands back one outfit the score calculator rejects.
	local function createDraftKeeperHandingBackFinalOutfits(finalOutfitStylingItemKeysByPlayerUserId)
		return {
			addParticipant = function() end,
			cutOffOutfitDraftsAndFreezeFinalOutfits = function()
				return finalOutfitStylingItemKeysByPlayerUserId
			end,
		}
	end

	it("scores everyone else, gives them places 1, 2 and logs one warning naming the player", function()
		local recordingLogger = RecordingLogger.new()
		local refereedRound = RefereedThemedRound.new({
			roundId = "round-9",
			themeId = "y2k_pop",
			theme = ThemeCatalog.findThemeByThemeId("y2k_pop"),
			roundBonusRule = table.freeze({ roundBonusKind = "ColorBonus", bonusColorTag = "pink" }),
			roundOutfitDraftKeeper = createDraftKeeperHandingBackFinalOutfits({
				[10] = OUTFIT_E83,
				[20] = { "key_missing_from_the_pool" },
				[30] = OUTFIT_A,
			}),
			stylingItemByStylingItemKey = FakeStylingItemPool.FAKE_STYLING_ITEM_BY_STYLING_ITEM_KEY,
			logger = recordingLogger,
		})
		for _, playerUserId in { 10, 20, 30 } do
			refereedRound:addParticipant(playerUserId)
		end
		refereedRound:cutOffDraftsAndScoreFinalOutfitsOnce()
		expect(refereedRound:readScoredParticipantStillPresent(10).stagePlaceNumber).toBe(1)
		expect(refereedRound:readScoredParticipantStillPresent(20)).toBeNil()
		expect(refereedRound:readScoredParticipantStillPresent(30).stagePlaceNumber).toBe(2)
		expect(recordingLogger.loggedWarnings).toEqual({
			"RefereedThemedRound: scoring raised in round round-9 for players 20; they are not scored",
		})
		expect(refereedRound:isParticipant(20)).toBeTrue()
	end)
end)
