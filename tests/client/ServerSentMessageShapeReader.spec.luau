-- The device reads each server message into a checked shape and ignores a message of another shape.

local UnitTestFramework = require("../Support/UnitTestFramework")
local ServerSentMessageShapeReader = require("../../src/client/ServerSentMessageShapeReader")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function roundState()
	return {
		roundId = "id-1",
		roundPhase = "Styling",
		phaseEndsAtUnixMilliseconds = 1_800_000_190_000,
		themeId = "y2k_pop",
		roundBonusRule = { roundBonusKind = "ColorBonus", bonusColorTag = "pink" },
		participantUserIds = { 101 },
		somethingElse = true,
	}
end

local function resultEntry()
	return {
		playerUserId = 101,
		playerDisplayName = "Tester 101",
		outfitScore = 43,
		themeMatchPoints = 13.333333333333334,
		completenessPoints = 10,
		colorHarmonyPoints = 15,
		roundBonusPoints = 5,
		starCount = 2,
		starCoinsGranted = 40,
		fanCountGained = 20,
		isNewBestStarCountForTheme = true,
	}
end

describe("ServerSentMessageShapeReader", function()
	it("reads a round state message and drops unknown fields", function()
		local read = ServerSentMessageShapeReader.readRoundStateChangedMessage(roundState())
		expect(read).toEqual({
			roundId = "id-1",
			roundPhase = "Styling",
			phaseEndsAtUnixMilliseconds = 1_800_000_190_000,
			themeId = "y2k_pop",
			roundBonusRule = { roundBonusKind = "ColorBonus", bonusColorTag = "pink" },
			participantUserIds = { 101 },
		})
	end)

	it("rejects a round state with a bad phase, id, end time, bonus rule or participant list", function()
		local mutations = {
			function(m)
				m.roundPhase = "Party"
			end,
			function(m)
				m.roundId = ""
			end,
			function(m)
				m.phaseEndsAtUnixMilliseconds = "soon"
			end,
			function(m)
				m.roundBonusRule = nil
			end,
			function(m)
				m.participantUserIds = { "101" }
			end,
			function(m)
				m.themeId = 5
			end,
		}
		for _, mutate in mutations do
			local message = roundState()
			mutate(message)
			expect(ServerSentMessageShapeReader.readRoundStateChangedMessage(message)).toBeNil()
		end
		expect(ServerSentMessageShapeReader.readRoundStateChangedMessage(nil)).toBeNil()
	end)

	it("reads acknowledgements with and without a rejection reason, and rejects bad ones", function()
		expect(ServerSentMessageShapeReader.readRoundOutfitDraftAcknowledgedMessage({
			roundId = "id-1",
			outfitDraftSequenceNumber = 2,
			isKept = true,
		})).toEqual({ roundId = "id-1", outfitDraftSequenceNumber = 2, isKept = true })
		expect(ServerSentMessageShapeReader.readRoundOutfitDraftAcknowledgedMessage({
			roundId = "id-1",
			outfitDraftSequenceNumber = 1,
			isKept = false,
			rejectionReason = "OutfitInvalid",
		}).rejectionReason).toBe("OutfitInvalid")
		expect(ServerSentMessageShapeReader.readRoundOutfitDraftAcknowledgedMessage({
			roundId = "id-1",
			outfitDraftSequenceNumber = 1,
			isKept = "yes",
		})).toBeNil()
	end)

	it("reads results in the order sent and rejects the whole message for one bad entry", function()
		local second = resultEntry()
		second.playerUserId = 102
		second.outfitScore = 10
		local read = ServerSentMessageShapeReader.readRoundResultsPublishedMessage({
			roundId = "id-1",
			roundResults = { resultEntry(), second },
		})
		expect(read.roundResults[1].playerUserId).toBe(101)
		expect(read.roundResults[2].playerUserId).toBe(102)
		expect(read.roundResults[1]).toEqual(resultEntry())
		local broken = resultEntry()
		broken.starCount = nil
		expect(ServerSentMessageShapeReader.readRoundResultsPublishedMessage({
			roundId = "id-1",
			roundResults = { resultEntry(), broken },
		})).toBeNil()
	end)

	it("reads the snapshot fields the device shows and rejects a snapshot without balances", function()
		local message = {
			fanCount = 20,
			starCoinBalance = 40,
			isSaveDataPersistenceDelayed = false,
			unavailableLobbyOutfitStylingItemKeys = { "asset_1" },
			ownedDanceIds = { "starter_groove" },
		}
		expect(ServerSentMessageShapeReader.readPlayerSaveDataSnapshotMessage(message)).toEqual({
			shownFanCount = 20,
			shownStarCoinBalance = 40,
			isSaveDataPersistenceDelayed = false,
			unavailableLobbyOutfitStylingItemKeys = { "asset_1" },
		})
		message.starCoinBalance = nil
		expect(ServerSentMessageShapeReader.readPlayerSaveDataSnapshotMessage(message)).toBeNil()
	end)

	it("reads the catalog change message", function()
		expect(ServerSentMessageShapeReader.readWardrobeCatalogChangedMessage({
			isWardrobeCatalogReady = true,
			wardrobeCatalogVersion = 1,
		})).toEqual({ isWardrobeCatalogReady = true, wardrobeCatalogVersion = 1 })
		expect(ServerSentMessageShapeReader.readWardrobeCatalogChangedMessage({ isWardrobeCatalogReady = true })).toBeNil()
	end)
end)
