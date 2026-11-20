-- The plain-words texts, the results rows and the status bar model.

local UnitTestFramework = require("../Support/UnitTestFramework")
local PlayerFacingTexts = require("../../src/client/PlayerFacingTexts")
local PlayerSaveDataStatusBarModel = require("../../src/client/PlayerSaveDataStatusBarModel")
local RoundResultsRowsBuilder = require("../../src/client/RoundResultsRowsBuilder")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

describe("PlayerFacingTexts", function()
	it("explains every join rejection reason of §2.2 in its own words, and anything else generically", function()
		local seenTexts = {}
		for _, reason in
			{
				"SaveDataNotLoaded",
				"WardrobeCatalogNotReady",
				"RoundNotJoinableNow",
				"AlreadyParticipating",
				"TooManyRequests",
				"RequestFailedOnServer",
			}
		do
			local text = PlayerFacingTexts.describeJoinRejectionReason(reason)
			expect(seenTexts[text]).toBeNil()
			seenTexts[text] = true
		end
		expect(PlayerFacingTexts.describeJoinRejectionReason("RoundNotJoinableNow")).toBe(
			"Too late to join this round. You can join the next one."
		)
		expect(PlayerFacingTexts.describeJoinRejectionReason(nil)).toBe("Could not join right now. Try again.")
		expect(PlayerFacingTexts.describeJoinRejectionReason("Whatever")).toBe("Could not join right now. Try again.")
	end)

	it("describes both bonus rule kinds and the theme name", function()
		expect(PlayerFacingTexts.describeRoundBonusRule({ roundBonusKind = "ColorBonus", bonusColorTag = "pink" })).toBe(
			"Round bonus: wear pink items (up to 3 count)."
		)
		expect(PlayerFacingTexts.describeRoundBonusRule({ roundBonusKind = "StyleBonus", bonusStyleTag = "gothic" })).toBe(
			"Round bonus: wear gothic style items (up to 3 count)."
		)
		expect(PlayerFacingTexts.describeRoundBonusRule({ roundBonusKind = "ColorBonus" })).toBe("")
		expect(PlayerFacingTexts.describeThemeDisplayName("y2k_pop")).toBe("Y2K Pop")
		expect(PlayerFacingTexts.describeThemeDisplayName("not_a_theme")).toBe("not_a_theme")
	end)

	it("formats the countdown rounded up and never negative", function()
		expect(PlayerFacingTexts.formatCountdownSeconds(179.2)).toBe("3:00")
		expect(PlayerFacingTexts.formatCountdownSeconds(61)).toBe("1:01")
		expect(PlayerFacingTexts.formatCountdownSeconds(0.01)).toBe("0:01")
		expect(PlayerFacingTexts.formatCountdownSeconds(0)).toBe("0:00")
		expect(PlayerFacingTexts.formatCountdownSeconds(-4)).toBe("0:00")
		expect(PlayerFacingTexts.formatCountdownSeconds(nil)).toBe("")
	end)

	it("groups thousands", function()
		expect(PlayerFacingTexts.formatWholeNumber(0)).toBe("0")
		expect(PlayerFacingTexts.formatWholeNumber(999)).toBe("999")
		expect(PlayerFacingTexts.formatWholeNumber(1240)).toBe("1,240")
		expect(PlayerFacingTexts.formatWholeNumber(1234567)).toBe("1,234,567")
		expect(PlayerFacingTexts.formatWholeNumber(-1240)).toBe("-1,240")
	end)

	it("says saved, saving and put back in plain words", function()
		expect(PlayerFacingTexts.describeDraftSavingStatus("Saved")).toBe("Outfit saved")
		expect(PlayerFacingTexts.describeDraftSavingStatus("Saving")).toBe("Saving...")
		expect(PlayerFacingTexts.describeDraftSavingStatus("PutBackToLastSaved")).toBe(
			"Put back to your last saved outfit"
		)
		expect(PlayerFacingTexts.describeSelectionRefusalReason("AccessoryLimitReached")).toBe(
			"You can wear up to 3 accessories. Take one off first."
		)
	end)
end)

local function entry(playerUserId, outfitScore, starCount, starCoinsGranted, fanCountGained, isNewBest)
	return {
		playerUserId = playerUserId,
		playerDisplayName = "Player " .. playerUserId,
		outfitScore = outfitScore,
		themeMatchPoints = 33.333333333333336,
		completenessPoints = 16.666666666666668,
		colorHarmonyPoints = 15,
		roundBonusPoints = 10,
		starCount = starCount,
		starCoinsGranted = starCoinsGranted,
		fanCountGained = fanCountGained,
		isNewBestStarCountForTheme = isNewBest,
	}
end

describe("RoundResultsRowsBuilder", function()
	it("keeps the server's order and shows the score, the four components and the stars for everyone", function()
		local rows = RoundResultsRowsBuilder.buildRoundResultsRows({
			roundId = "r1",
			roundResults = { entry(7, 75, 4, 80, 40, false), entry(101, 43, 2, 40, 20, true) },
		}, 101)
		expect(rows[1].placeText).toBe("#1")
		expect(rows[1].playerNameText).toBe("Player 7")
		expect(rows[1].scoreText).toBe("Score 75")
		expect(rows[1].componentsText).toBe("Theme 33.3/50 · Complete 16.7/20 · Colors 15/15 · Bonus 10/15")
		expect(rows[1].starsText).toBe("4 of 5 stars")
		expect(rows[1].rewardText).toBe("")
		expect(rows[2].playerNameText).toBe("Player 101 (you)")
		expect(rows[2].isLocalPlayer).toBeTrue()
		expect(rows[2].rewardText).toBe("You earned 40 Star Coins and 20 fans - a new best for this theme!")
	end)

	it("shows the empty-outfit entry as no stars and no reward", function()
		local empty = entry(101, 0, 0, 0, 0, false)
		empty.themeMatchPoints, empty.completenessPoints, empty.colorHarmonyPoints, empty.roundBonusPoints = 0, 0, 0, 0
		local rows = RoundResultsRowsBuilder.buildRoundResultsRows({ roundId = "r1", roundResults = { empty } }, 101)
		expect(rows[1].starsText).toBe("No stars: no outfit was saved")
		expect(rows[1].rewardText).toBe("No reward this round. Pick at least one item next time!")
		expect(rows[1].componentsText).toBe("Theme 0/50 · Complete 0/20 · Colors 0/15 · Bonus 0/15")
	end)
end)

describe("PlayerSaveDataStatusBarModel", function()
	it("shows dots before any snapshot, then exactly the snapshot's numbers and its notices", function()
		local keeper = PlayerSaveDataStatusBarModel.new()
		expect(keeper:readStatusBarModel()).toEqual({
			starCoinBalanceText = "...",
			fanCountText = "...",
			noticeTexts = {},
		})
		expect(keeper:receivePlayerSaveDataSnapshot({
			fanCount = 1240,
			starCoinBalance = 430,
			isSaveDataPersistenceDelayed = true,
			unavailableLobbyOutfitStylingItemKeys = { "asset_1" },
		})).toBeTrue()
		expect(keeper:readStatusBarModel()).toEqual({
			starCoinBalanceText = "430",
			fanCountText = "1,240",
			noticeTexts = {
				"Progress can't be saved right now.",
				"Some items of your saved outfit are unavailable right now.",
			},
		})
	end)

	it("keeps the previous snapshot when a malformed one arrives, and drops notices that end", function()
		local keeper = PlayerSaveDataStatusBarModel.new()
		keeper:receivePlayerSaveDataSnapshot({
			fanCount = 10,
			starCoinBalance = 20,
			isSaveDataPersistenceDelayed = true,
			unavailableLobbyOutfitStylingItemKeys = {},
		})
		expect(keeper:receivePlayerSaveDataSnapshot({ fanCount = 999 })).toBeFalse()
		expect(keeper:readStatusBarModel().fanCountText).toBe("10")
		keeper:receivePlayerSaveDataSnapshot({
			fanCount = 30,
			starCoinBalance = 60,
			isSaveDataPersistenceDelayed = false,
			unavailableLobbyOutfitStylingItemKeys = {},
		})
		expect(keeper:readStatusBarModel()).toEqual({
			starCoinBalanceText = "60",
			fanCountText = "30",
			noticeTexts = {},
		})
	end)
end)
