-- ThemedRoundScreenModelBuilder: decides WHAT the round screens show for one session snapshot
-- (ThemedRoundDeviceSession:readSessionSnapshot), as plain data. The Roblox views only copy it into
-- interface instances, so everything a player can see is tested here with Lune.
--
-- Per round phase (spec §2.1):
--   * no round state yet: "Connecting to the game..." and nothing else;
--   * ThemeReveal: the theme's display name, the round bonus rule in plain words, the countdown,
--     and the join panel;
--   * Styling: the same, plus, for a participant, the wardrobe: slot groups with every listed item
--     (name and price), the selection marked, the saving status, the put-back notice, the reason a
--     tap was refused, and the lock notice when locked; the wardrobe shows a loading notice while
--     the catalog is not ready;
--   * Showcase: a showcase notice, without the bonus rule (a short panel keeps the stage in view),
--     and the results as soon as they arrive (see below);
--   * Results: the results rows (RoundResultsRowsBuilder) once RoundResultsPublished for this round
--     has arrived; it may arrive before the phase message; until then "Waiting for the results...",
--     and "Nobody took part" for an empty list;
--   * Intermission: "Next round soon".
-- Join panel: shown during ThemeReveal and Styling. For a non-participant: a Join button, enabled
--   when the session can ask now, labelled "Joining..." while a request is in flight, and the
--   plain-words reason of the last refusal for this round. For a participant: "You're in!" text.
-- The preview shows the selection while the wardrobe is shown; otherwise previewStylingItemKeys is
--   nil (the preview is hidden).
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   ThemedRoundScreenModelBuilder.buildThemedRoundScreenModel(sessionSnapshot) -> screenModel
--   screenModel = {
--     screenName: "WaitingForServer" | a round phase,
--     phaseTitleText, themeDisplayNameText, roundBonusRuleText, countdownText, phaseNoticeText,
--     joinPanel = { isVisible, isJoinButtonVisible, isJoinButtonEnabled, joinButtonText, joinMessageText },
--     wardrobePanel = { isVisible, isLocked, wardrobeNoticeText, savingStatusText, putBackNoticeText,
--       selectionRefusalText, selectedItemCountText, slotGroups = { { slotTitleText,
--       itemButtons = { { stylingItemKey, itemNameText, itemPriceText, isSelected, isEnabled } } } } },
--     previewStylingItemKeys: { string }?,
--     resultsRows: { row }   (empty when there is nothing to show)
--   }

local PlayerFacingTexts = require("./PlayerFacingTexts")
local RoundResultsRowsBuilder = require("./RoundResultsRowsBuilder")

local ThemedRoundScreenModelBuilder = {}

local RESULTS_WAITING_NOTICE = "Waiting for the results..."
local RESULTS_NOBODY_NOTICE = "Nobody took part in this round. Join the next one!"

local PHASE_TITLE_TEXT_BY_ROUND_PHASE = table.freeze({
	ThemeReveal = "New theme!",
	Styling = "Styling time",
	Showcase = "Showcase",
	Results = "Results",
	Intermission = "Break",
})

local function buildJoinPanel(sessionSnapshot, roundPhase: string)
	local isJoinPhase = roundPhase == "ThemeReveal" or roundPhase == "Styling"
	local joinPanel = {
		isVisible = isJoinPhase,
		isJoinButtonVisible = false,
		isJoinButtonEnabled = false,
		joinButtonText = "Join this round",
		joinMessageText = "",
	}
	if not isJoinPhase then
		return joinPanel
	end
	local joinRejection = sessionSnapshot.joinRejection
	local isRejectionOfThisRound = joinRejection ~= nil and joinRejection.roundId == sessionSnapshot.roundState.roundId
	if sessionSnapshot.isParticipant then
		joinPanel.joinMessageText = if roundPhase == "ThemeReveal"
			then "You're in! The wardrobe opens when styling starts."
			else "You're in! Style your outfit."
		-- Asked twice: the server's answer is explained, then what it means.
		if isRejectionOfThisRound and joinRejection.rejectionReason == "AlreadyParticipating" then
			joinPanel.joinMessageText = PlayerFacingTexts.describeJoinRejectionReason("AlreadyParticipating")
				.. " "
				.. joinPanel.joinMessageText
		end
		return joinPanel
	end
	joinPanel.isJoinButtonVisible = true
	joinPanel.isJoinButtonEnabled = sessionSnapshot.canAskToJoinNow
	if sessionSnapshot.isJoinRequestInFlight then
		joinPanel.joinButtonText = "Joining..."
	end
	if isRejectionOfThisRound then
		joinPanel.joinMessageText = PlayerFacingTexts.describeJoinRejectionReason(joinRejection.rejectionReason)
	end
	return joinPanel
end

local function buildSlotGroups(sessionSnapshot, isLocked: boolean)
	local slotGroups = {}
	local selectedKeySet = {}
	for _, selectedKey in sessionSnapshot.selectedStylingItemKeys do
		selectedKeySet[selectedKey] = true
	end
	for _, wardrobeSlotGroup in sessionSnapshot.wardrobeCatalogView.wardrobeSlotGroups do
		local itemButtons = {}
		for _, wardrobeItem in wardrobeSlotGroup.wardrobeItems do
			table.insert(itemButtons, {
				stylingItemKey = wardrobeItem.stylingItemKey,
				itemNameText = wardrobeItem.itemDisplayName,
				itemPriceText = string.format(
					"%s Robux",
					PlayerFacingTexts.formatWholeNumber(wardrobeItem.priceInRobux)
				),
				isSelected = selectedKeySet[wardrobeItem.stylingItemKey] == true,
				isEnabled = not isLocked,
			})
		end
		table.insert(slotGroups, { slotTitleText = wardrobeSlotGroup.itemSlotDisplayName, itemButtons = itemButtons })
	end
	return slotGroups
end

local function buildWardrobePanel(sessionSnapshot, roundPhase: string)
	local wardrobePanel = {
		isVisible = roundPhase == "Styling" and sessionSnapshot.isParticipant,
		isLocked = not sessionSnapshot.isWardrobeUsableNow,
		wardrobeNoticeText = "",
		savingStatusText = "",
		putBackNoticeText = "",
		selectionRefusalText = "",
		selectedItemCountText = "",
		slotGroups = {},
	}
	if not wardrobePanel.isVisible then
		return wardrobePanel
	end
	local wardrobeCatalogView = sessionSnapshot.wardrobeCatalogView
	if wardrobeCatalogView == nil or not wardrobeCatalogView.isWardrobeCatalogReady then
		wardrobePanel.wardrobeNoticeText = PlayerFacingTexts.WARDROBE_LOADING_NOTICE
		return wardrobePanel
	end
	if wardrobePanel.isLocked then
		wardrobePanel.wardrobeNoticeText = PlayerFacingTexts.WARDROBE_LOCKED_NOTICE
	end
	wardrobePanel.savingStatusText = PlayerFacingTexts.describeDraftSavingStatus(sessionSnapshot.draftSavingStatus)
	if sessionSnapshot.outfitPutBackNotice ~= nil then
		wardrobePanel.putBackNoticeText =
			PlayerFacingTexts.describeOutfitPutBack(sessionSnapshot.outfitPutBackNotice.rejectionReason)
	end
	if sessionSnapshot.selectionRefusal ~= nil then
		wardrobePanel.selectionRefusalText =
			PlayerFacingTexts.describeSelectionRefusalReason(sessionSnapshot.selectionRefusal.selectionRefusalReason)
	end
	local selectedCount = #sessionSnapshot.selectedStylingItemKeys
	wardrobePanel.selectedItemCountText =
		string.format("Wearing %d item%s", selectedCount, if selectedCount == 1 then "" else "s")
	wardrobePanel.slotGroups = buildSlotGroups(sessionSnapshot, wardrobePanel.isLocked)
	return wardrobePanel
end

function ThemedRoundScreenModelBuilder.buildThemedRoundScreenModel(sessionSnapshot)
	local roundState = sessionSnapshot.roundState
	local screenModel = {
		screenName = "WaitingForServer",
		phaseTitleText = "",
		themeDisplayNameText = "",
		roundBonusRuleText = "",
		countdownText = "",
		phaseNoticeText = PlayerFacingTexts.WAITING_FOR_SERVER_NOTICE,
		joinPanel = buildJoinPanel(sessionSnapshot, "WaitingForServer"),
		wardrobePanel = buildWardrobePanel(sessionSnapshot, "WaitingForServer"),
		previewStylingItemKeys = nil,
		resultsRows = {},
	}
	if roundState == nil then
		return screenModel
	end
	local roundPhase = roundState.roundPhase
	screenModel.screenName = roundPhase
	screenModel.phaseTitleText = PHASE_TITLE_TEXT_BY_ROUND_PHASE[roundPhase]
	screenModel.themeDisplayNameText = PlayerFacingTexts.describeThemeDisplayName(roundState.themeId)
	-- Showcase keeps the panel short so the stage below it stays in view.
	screenModel.roundBonusRuleText = if roundPhase == "Showcase"
		then ""
		else PlayerFacingTexts.describeRoundBonusRule(roundState.roundBonusRule)
	screenModel.countdownText = PlayerFacingTexts.formatCountdownSeconds(sessionSnapshot.remainingSecondsInPhase)
	screenModel.phaseNoticeText = if roundPhase == "Showcase"
		then PlayerFacingTexts.SHOWCASE_NOTICE
		elseif roundPhase == "Intermission" then PlayerFacingTexts.INTERMISSION_NOTICE
		else ""
	screenModel.joinPanel = buildJoinPanel(sessionSnapshot, roundPhase)
	screenModel.wardrobePanel = buildWardrobePanel(sessionSnapshot, roundPhase)
	if screenModel.wardrobePanel.isVisible and #screenModel.wardrobePanel.slotGroups > 0 then
		screenModel.previewStylingItemKeys = table.clone(sessionSnapshot.selectedStylingItemKeys)
	end
	local isResultsTime = roundPhase == "Results" or roundPhase == "Showcase"
	if isResultsTime and sessionSnapshot.roundResults ~= nil then
		screenModel.resultsRows = RoundResultsRowsBuilder.buildRoundResultsRows(
			sessionSnapshot.roundResults,
			sessionSnapshot.localPlayerUserId
		)
	end
	if roundPhase == "Results" then
		screenModel.phaseNoticeText = if sessionSnapshot.roundResults == nil
			then RESULTS_WAITING_NOTICE
			elseif #screenModel.resultsRows == 0 then RESULTS_NOBODY_NOTICE
			else ""
	end
	return screenModel
end

return table.freeze(ThemedRoundScreenModelBuilder)
