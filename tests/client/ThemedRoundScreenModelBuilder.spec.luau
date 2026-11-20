-- What each round screen shows for a given session snapshot.

local UnitTestFramework = require("../Support/UnitTestFramework")
local DeviceTestFixtures = require("./DeviceTestFixtures")
local ThemedRoundScreenModelBuilder = require("../../src/client/ThemedRoundScreenModelBuilder")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local F = DeviceTestFixtures
local NONE = table.freeze({}) -- an override meaning "this field is nil"

local function snapshot(overrides)
	local base = {
		localPlayerUserId = 101,
		roundState = {
			roundId = "r1",
			roundPhase = "Styling",
			phaseEndsAtUnixMilliseconds = 0,
			themeId = "y2k_pop",
			roundBonusRule = { roundBonusKind = "ColorBonus", bonusColorTag = "pink" },
			participantUserIds = {},
		},
		remainingSecondsInPhase = 90.2,
		isParticipant = false,
		isJoinRequestInFlight = false,
		canAskToJoinNow = true,
		joinRejection = nil,
		wardrobeCatalogView = F.buildDevelopmentWardrobeCatalogView(),
		isWardrobeUsableNow = false,
		selectedStylingItemKeys = {},
		draftSavingStatus = "NothingSentYet",
		latestSentOutfitDraftSequenceNumber = 0,
		lastKeptStylingItemKeys = {},
		outfitPutBackNotice = nil,
		selectionRefusal = nil,
		roundResults = nil,
	}
	for key, value in overrides or {} do
		base[key] = if value == NONE then nil else value
	end
	return base
end

local build = ThemedRoundScreenModelBuilder.buildThemedRoundScreenModel

describe("ThemedRoundScreenModelBuilder", function()
	it("shows only a connecting notice before any round state", function()
		local model = build(snapshot({ roundState = NONE, remainingSecondsInPhase = NONE }))
		expect(model.screenName).toBe("WaitingForServer")
		expect(model.phaseNoticeText).toBe("Connecting to the game...")
		expect(model.joinPanel.isVisible).toBeFalse()
		expect(model.wardrobePanel.isVisible).toBeFalse()
	end)

	it("shows the theme, the bonus rule in plain words, the countdown and a Join button", function()
		local model = build(snapshot())
		expect(model.screenName).toBe("Styling")
		expect(model.themeDisplayNameText).toBe("Y2K Pop")
		expect(model.roundBonusRuleText).toBe("Round bonus: wear pink items (up to 3 count).")
		expect(model.countdownText).toBe("1:31")
		expect(model.joinPanel.isJoinButtonVisible).toBeTrue()
		expect(model.joinPanel.isJoinButtonEnabled).toBeTrue()
		expect(model.wardrobePanel.isVisible).toBeFalse()
		expect(model.previewStylingItemKeys).toBeNil()
	end)

	it("shows the refusal of this round in plain words, and Joining... while asking", function()
		local refused = build(snapshot({ joinRejection = { roundId = "r1", rejectionReason = "RoundNotJoinableNow" } }))
		expect(refused.joinPanel.joinMessageText).toBe("Too late to join this round. You can join the next one.")
		local oldRefusal =
			build(snapshot({ joinRejection = { roundId = "r0", rejectionReason = "RoundNotJoinableNow" } }))
		expect(oldRefusal.joinPanel.joinMessageText).toBe("")
		local asking = build(snapshot({ isJoinRequestInFlight = true, canAskToJoinNow = false }))
		expect(asking.joinPanel.joinButtonText).toBe("Joining...")
		expect(asking.joinPanel.isJoinButtonEnabled).toBeFalse()
	end)

	it("shows a participant the wardrobe by slot with names, prices, the selection and the saving status", function()
		local model = build(snapshot({
			isParticipant = true,
			isWardrobeUsableNow = true,
			selectedStylingItemKeys = { F.DRESS },
			draftSavingStatus = "Saved",
		}))
		expect(model.joinPanel.isJoinButtonVisible).toBeFalse()
		expect(model.joinPanel.joinMessageText).toBe("You're in! Style your outfit.")
		local panel = model.wardrobePanel
		expect(panel.isVisible).toBeTrue()
		expect(panel.isLocked).toBeFalse()
		expect(panel.savingStatusText).toBe("Outfit saved")
		expect(panel.selectedItemCountText).toBe("Wearing 1 item")
		local titles, buttonCount = {}, 0
		for _, group in panel.slotGroups do
			table.insert(titles, group.slotTitleText)
			for _, button in group.itemButtons do
				buttonCount += 1
				expect(button.isEnabled).toBeTrue()
				expect(button.isSelected).toBe(button.stylingItemKey == F.DRESS)
			end
		end
		expect(titles).toEqual({ "Hair", "Tops", "Dresses", "Shoes", "Accessories (up to 3)", "Lip makeup" })
		expect(buttonCount).toBe(7)
		expect(panel.slotGroups[1].itemButtons[1]).toEqual({
			stylingItemKey = F.HAIR,
			itemNameText = "Black Messy Hairstyle",
			itemPriceText = "65 Robux",
			isSelected = false,
			isEnabled = true,
		})
		expect(model.previewStylingItemKeys).toEqual({ F.DRESS })
	end)

	it("disables every item and says so when the wardrobe is locked", function()
		local model =
			build(snapshot({ isParticipant = true, isWardrobeUsableNow = false, remainingSecondsInPhase = 0.8 }))
		expect(model.wardrobePanel.isLocked).toBeTrue()
		expect(model.wardrobePanel.wardrobeNoticeText).toBe("Time's up! Your last saved outfit goes on stage.")
		for _, group in model.wardrobePanel.slotGroups do
			for _, button in group.itemButtons do
				expect(button.isEnabled).toBeFalse()
			end
		end
	end)

	it("shows the put-back notice and a refused tap's reason", function()
		local model = build(snapshot({
			isParticipant = true,
			isWardrobeUsableNow = true,
			draftSavingStatus = "PutBackToLastSaved",
			outfitPutBackNotice = { roundId = "r1", rejectionReason = "OutfitInvalid" },
			selectionRefusal = { selectionRefusalReason = "AccessoryLimitReached" },
		}))
		expect(model.wardrobePanel.savingStatusText).toBe("Put back to your last saved outfit")
		expect(model.wardrobePanel.putBackNoticeText).toBe(
			"The server could not accept that outfit, so we put back your last saved outfit."
		)
		expect(model.wardrobePanel.selectionRefusalText).toBe("You can wear up to 3 accessories. Take one off first.")
	end)

	it("shows a loading notice and no items while the catalog is not ready", function()
		local model = build(snapshot({ isParticipant = true, wardrobeCatalogView = NONE }))
		expect(model.wardrobePanel.wardrobeNoticeText).toBe("The wardrobe is loading...")
		expect(model.wardrobePanel.slotGroups).toEqual({})
		expect(model.previewStylingItemKeys).toBeNil()
	end)

	it("shows Showcase, Results rows (even before the Results message) and the Intermission notice", function()
		local results = {
			roundId = "r1",
			roundResults = {
				{
					playerUserId = 101,
					playerDisplayName = "Me",
					outfitScore = 43,
					themeMatchPoints = 13.3,
					completenessPoints = 10,
					colorHarmonyPoints = 15,
					roundBonusPoints = 5,
					starCount = 2,
					starCoinsGranted = 40,
					fanCountGained = 20,
					isNewBestStarCountForTheme = false,
				},
			},
		}
		local function inPhase(roundPhase, roundResults)
			local state = table.clone(snapshot().roundState)
			state.roundPhase = roundPhase
			return build(snapshot({ roundState = state, roundResults = roundResults, isParticipant = true }))
		end
		expect(inPhase("Showcase").phaseNoticeText).toBe("Showtime! Everyone who took part is on stage.")
		expect(inPhase("Showcase").roundBonusRuleText).toBe("")
		expect(inPhase("Showcase").themeDisplayNameText).toBe("Y2K Pop")
		expect(inPhase("Results").roundBonusRuleText).toBe("Round bonus: wear pink items (up to 3 count).")
		expect(#inPhase("Showcase", results).resultsRows).toBe(1)
		expect(inPhase("Results").phaseNoticeText).toBe("Waiting for the results...")
		expect(inPhase("Results", results).resultsRows[1].scoreText).toBe("Score 43")
		expect(inPhase("Results", { roundId = "r1", roundResults = {} }).phaseNoticeText).toBe(
			"Nobody took part in this round. Join the next one!"
		)
		local intermission = inPhase("Intermission", results)
		expect(intermission.phaseNoticeText).toBe("Next round soon. Get ready for a new theme!")
		expect(intermission.resultsRows).toEqual({})
		expect(intermission.joinPanel.isVisible).toBeFalse()
		expect(intermission.wardrobePanel.isVisible).toBeFalse()
	end)

	it("explains an AlreadyParticipating answer to a player who is now a participant", function()
		local model = build(snapshot({
			isParticipant = true,
			joinRejection = { roundId = "r1", rejectionReason = "AlreadyParticipating" },
		}))
		expect(model.joinPanel.joinMessageText).toBe(
			"You are already taking part in this round. You're in! Style your outfit."
		)
		local otherRound = build(snapshot({
			isParticipant = true,
			joinRejection = { roundId = "r0", rejectionReason = "AlreadyParticipating" },
		}))
		expect(otherRound.joinPanel.joinMessageText).toBe("You're in! Style your outfit.")
	end)

	it("tells a participant during ThemeReveal that the wardrobe opens with styling", function()
		local state = table.clone(snapshot().roundState)
		state.roundPhase = "ThemeReveal"
		local model = build(snapshot({ roundState = state, isParticipant = true }))
		expect(model.joinPanel.joinMessageText).toBe("You're in! The wardrobe opens when styling starts.")
		expect(model.phaseTitleText).toBe("New theme!")
		expect(model.wardrobePanel.isVisible).toBeFalse()
	end)
end)
