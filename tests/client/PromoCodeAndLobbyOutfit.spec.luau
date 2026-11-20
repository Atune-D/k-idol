-- The promo code panel (§2.10, the 2-second rule) and the lobby outfit wardrobe (§1.5, §2.7).

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local DeviceTestFixtures = require("./DeviceTestFixtures")
local LobbyTestFixtures = require("./LobbyTestFixtures")
local DeviceLobbyRequestSender = require("../../src/client/DeviceLobbyRequestSender")
local LobbyOutfitSelection = require("../../src/client/LobbyOutfitSelection")
local LobbySaveDataSnapshotReader = require("../../src/client/LobbySaveDataSnapshotReader")
local PlayerFacingTexts = require("../../src/client/PlayerFacingTexts")
local PromoCodeRedeemForm = require("../../src/client/PromoCodeRedeemForm")
local WardrobeCatalogView = require("../../src/client/WardrobeCatalogView")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local F = DeviceTestFixtures

local function createSender()
	local fakeClock = FakeClock.new(LobbyTestFixtures.START_UNIX_SECONDS)
	local askServer, pendingRequests = LobbyTestFixtures.createRecordingAskServer()
	return DeviceLobbyRequestSender.new({ clock = fakeClock, askServer = askServer }), fakeClock, pendingRequests
end

describe("PromoCodeRedeemForm", function()
	it("sends the trimmed code and explains the server's answer", function()
		local sender, _, pendingRequests = createSender()
		local form = PromoCodeRedeemForm.new({ lobbyRequestSender = sender })
		expect(form:submitTypedPromoCode("  idolstart \n")).toBe(true)
		expect(pendingRequests[1].remoteChannelName).toBe("RequestRedeemPromoCode")
		expect(pendingRequests[1].payload).toBe("idolstart")
		expect(form:readPromoCodePanelModel().isWaitingForAnswer).toBe(true)
		pendingRequests[1].onAnswer({ isAccepted = false, rejectionReason = "UnknownPromoCode" })
		expect(form:readPromoCodePanelModel().feedbackText).toBe(
			"That code doesn't exist. Check the spelling and try again."
		)
	end)

	it("does not send an empty code and says so", function()
		local sender, _, pendingRequests = createSender()
		local form = PromoCodeRedeemForm.new({ lobbyRequestSender = sender })
		expect(form:submitTypedPromoCode("   ")).toBe(false)
		expect(form:submitTypedPromoCode(nil)).toBe(false)
		expect(#pendingRequests).toBe(0)
		expect(form:readPromoCodePanelModel().feedbackText).toBe(PromoCodeRedeemForm.EMPTY_CODE_TEXT)
	end)

	it("keeps the 2-second rule: a faster second attempt is not sent and is explained", function()
		local sender, fakeClock, pendingRequests = createSender()
		local form = PromoCodeRedeemForm.new({ lobbyRequestSender = sender })
		form:submitTypedPromoCode("FIRST")
		pendingRequests[1].onAnswer({ isAccepted = false, rejectionReason = "UnknownPromoCode" })
		fakeClock:advanceBySeconds(1.5)
		expect(form:submitTypedPromoCode("SECOND")).toBe(false)
		expect(#pendingRequests).toBe(1)
		expect(form:readPromoCodePanelModel().feedbackText).toBe("Please wait 2 seconds between tries.")
		fakeClock:advanceBySeconds(0.5)
		expect(form:submitTypedPromoCode("SECOND")).toBe(true)
		pendingRequests[2].onAnswer({ isAccepted = false, rejectionReason = "TooManyAttempts" })
		expect(form:readPromoCodePanelModel().feedbackText).toBe("Too many tries. Wait 2 seconds between attempts.")
	end)

	it("says an accepted code's coins are on their way without naming an amount", function()
		local sender, _, pendingRequests = createSender()
		local form = PromoCodeRedeemForm.new({ lobbyRequestSender = sender })
		form:submitTypedPromoCode("GOOD")
		pendingRequests[1].onAnswer({ isAccepted = true, starCoinsGranted = 300 })
		expect(form:readPromoCodePanelModel().feedbackText).toBe("Code accepted! Your Star Coins arrive in a moment.")
	end)
end)

local function readSnapshot(overrides)
	return LobbySaveDataSnapshotReader.readLobbySaveDataSnapshot(LobbyTestFixtures.buildSnapshotMessage(overrides))
end

local function createSelection()
	local sender, fakeClock, pendingRequests = createSender()
	local selection = LobbyOutfitSelection.new({
		stylingItemByStylingItemKey = F.STYLING_ITEM_BY_STYLING_ITEM_KEY,
		lobbyRequestSender = sender,
	})
	return selection, pendingRequests, fakeClock
end

local function buildViewWith(stylingItemKeys)
	return WardrobeCatalogView.buildWardrobeCatalogView(
		F.buildSnapshotAnswerWithItems(stylingItemKeys),
		F.STYLING_ITEM_BY_STYLING_ITEM_KEY
	)
end

describe("LobbyOutfitSelection", function()
	it("starts from the stored lobby outfit minus the items the catalog does not list now", function()
		local selection = createSelection()
		local snapshot = readSnapshot({ lobbyOutfitStylingItemKeys = { F.HAIR, F.DRESS, F.GLASSES } })
		selection:beginEditing(snapshot, buildViewWith({ F.HAIR, F.GLASSES, F.SHOES_BUNDLE }))
		expect(selection:readSelectedStylingItemKeys()).toEqual({ F.HAIR, F.GLASSES })
		selection:beginEditing(readSnapshot(), F.buildDevelopmentWardrobeCatalogView())
		expect(selection:readSelectedStylingItemKeys()).toEqual({})
	end)

	it("applies the round wardrobe's selection rules (a dress pushes out a top, one hair)", function()
		local selection = createSelection()
		local view = F.buildDevelopmentWardrobeCatalogView()
		selection:beginEditing(readSnapshot(), view)
		selection:tapWardrobeItem(F.JACKET_TOP, view)
		selection:tapWardrobeItem(F.HAIR, view)
		local outcome = selection:tapWardrobeItem(F.DRESS, view)
		expect(outcome.isSelectionChanged).toBe(true)
		expect(selection:readSelectedStylingItemKeys()).toEqual({ F.HAIR, F.DRESS })
		selection:tapWardrobeItem(F.HAIR, view)
		expect(selection:readSelectedStylingItemKeys()).toEqual({ F.DRESS })
		local refused = selection:tapWardrobeItem("asset_1", view)
		expect(refused.selectionRefusalReason).toBe("NotInWardrobe")
		expect(selection:buildLobbyOutfitPanelModel(readSnapshot(), view).wardrobePanel.selectionRefusalText).toBe(
			PlayerFacingTexts.describeSelectionRefusalReason("NotInWardrobe")
		)
		expect(selection:tapWardrobeItem(F.HAIR, nil)).toBeNil()
	end)

	it(
		"sends SetLobbyOutfit with the selection and explains the answer; the unchanged outfit may be sent again",
		function()
			local selection, pendingRequests, fakeClock = createSelection()
			local view = F.buildDevelopmentWardrobeCatalogView()
			local snapshot = readSnapshot({ lobbyOutfitStylingItemKeys = { F.HAIR } })
			selection:beginEditing(snapshot, view)
			expect(selection:buildLobbyOutfitPanelModel(snapshot, view).storedOutfitText).toBe(
				"This is your saved lobby outfit."
			)
			expect(selection:confirmLobbyOutfit()).toBe(true)
			expect(pendingRequests[1].remoteChannelName).toBe("SetLobbyOutfit")
			expect(pendingRequests[1].payload).toEqual({ outfitStylingItemKeys = { F.HAIR } })
			pendingRequests[1].onAnswer({ isAccepted = false, rejectionReason = "NotAllowedDuringRound" })
			expect(selection:buildLobbyOutfitPanelModel(snapshot, view).confirmFeedbackText).toBe(
				"You can't change your lobby outfit while you are styling or on stage."
			)
			expect(selection:confirmLobbyOutfit()).toBe(false)
			fakeClock:advanceBySeconds(2)
			expect(selection:confirmLobbyOutfit()).toBe(true)
			pendingRequests[2].onAnswer({ isAccepted = true })
			expect(selection:buildLobbyOutfitPanelModel(snapshot, view).confirmFeedbackText).toBe(
				"Your lobby outfit is set."
			)
		end
	)

	it("builds the wardrobe model the round wardrobe view draws, with every listed item", function()
		local selection = createSelection()
		local view = F.buildDevelopmentWardrobeCatalogView()
		local snapshot = readSnapshot({ lobbyOutfitStylingItemKeys = { F.GLASSES } })
		selection:beginEditing(snapshot, view)
		local panel = selection:buildLobbyOutfitPanelModel(snapshot, view).wardrobePanel
		expect(panel.isVisible).toBe(true)
		expect(panel.isLocked).toBe(false)
		local listedCount, selectedKeys = 0, {}
		for _, slotGroup in panel.slotGroups do
			for _, itemButton in slotGroup.itemButtons do
				listedCount += 1
				expect(itemButton.isEnabled).toBe(true)
				if itemButton.isSelected then
					table.insert(selectedKeys, itemButton.stylingItemKey)
				end
			end
		end
		expect(listedCount).toBe(#view.listedStylingItemKeys)
		expect(selectedKeys).toEqual({ F.GLASSES })
		expect(panel.selectedItemCountText).toBe("Wearing 1 item")
		selection:clearSelection()
		expect(selection:buildLobbyOutfitPanelModel(snapshot, view).wardrobePanel.selectedItemCountText).toBe(
			"Wearing your own avatar"
		)
	end)

	it("tells the player when stored items are unavailable, and that a new outfit replaces them", function()
		local selection = createSelection()
		local view = F.buildDevelopmentWardrobeCatalogView()
		local snapshot = readSnapshot({ unavailableLobbyOutfitStylingItemKeys = { "asset_1" } })
		local panel = selection:buildLobbyOutfitPanelModel(snapshot, view).wardrobePanel
		expect(panel.putBackNoticeText).toBe(
			PlayerFacingTexts.UNAVAILABLE_SAVED_OUTFIT_ITEMS_NOTICE
				.. " "
				.. LobbyOutfitSelection.REPLACES_UNAVAILABLE_ITEMS_TEXT
		)
		expect(selection:buildLobbyOutfitPanelModel(readSnapshot(), view).wardrobePanel.putBackNoticeText).toBe("")
	end)

	it("shows a loading notice and no items before the snapshot or while the catalog is not ready", function()
		local selection = createSelection()
		local noSnapshot = selection:buildLobbyOutfitPanelModel(nil, F.buildDevelopmentWardrobeCatalogView())
		expect(noSnapshot.wardrobePanel.wardrobeNoticeText).toBe(LobbyOutfitSelection.LOADING_SAVE_TEXT)
		expect(#noSnapshot.wardrobePanel.slotGroups).toBe(0)
		local notReady = selection:buildLobbyOutfitPanelModel(readSnapshot(), nil)
		expect(notReady.wardrobePanel.wardrobeNoticeText).toBe(PlayerFacingTexts.WARDROBE_LOADING_NOTICE)
	end)
end)
