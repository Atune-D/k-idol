-- LobbyDeviceSession (development spec §0.2 "Lobby and dance floor", §1.7 to §1.10, §2.6 to §2.10,
-- §2.12 to §2.14): the device's Phase 2 lobby: the player's actions in the lobby menu and the Buy panel,
-- and what every lobby screen shows. It ties together, without deciding anything they decide:
--   LobbySaveDataSnapshotReader   the latest save snapshot (the ONLY source of what is owned, equipped,
--                                 earned and claimed, §2.6 🔴; ⛔ §5.1 nothing here changes it)
--   DeviceLobbyRequestSender      every lobby request, one per channel at a time, with the §2.13 intervals
--   LobbyMenuNavigation           when the menu is available, open, and on which panel
--   LobbyOutfitSelection          the lobby outfit wardrobe (§2.7)
--   PromoCodeRedeemForm           the promo code panel (§2.10)
--   StylingItemOwnershipRequester the focused styling item's ownership for the Buy panel (§2.12, §2.14)
--   and the panel builders DanceLobbyPanelModelBuilder, ShopPanelModelBuilder,
--   DailyRewardsPanelModelBuilder, StylingItemPurchasePanelModelBuilder.
-- Every action is ignored while the lobby menu is not available (the player is a Styling or Showcase
-- participant), except the Buy panel's ownership, which follows the round wardrobe too.
-- Pure logic: clock, scheduler and the channel call are injected; catalogs are passed in, so tests use
-- fixtures.
--
-- PUBLIC API
--   LobbyDeviceSession.new({ clock, scheduler, askServer(channelName, payload, onAnswer(answer?)),
--       stylingItemByStylingItemKey, danceCatalogDances, cosmeticCatalog, findCosmeticPresentation,
--       playtimeMilestones, findDailyQuestByDailyQuestId, onLobbyChanged?() }) -> lobbySession
--   lobbySession:receivePlayerSaveDataSnapshot(message) -> boolean   true when taken
--   lobbySession:noteRoundSessionSnapshot(sessionSnapshot)   (availability; call before reading the model)
--   lobbySession:toggleLobbyMenu()   lobbySession:openLobbyPanel(panelName)
--   lobbySession:equipDance(danceId)   :startDanceInLobby(danceId)   :stopDanceInLobby()
--   lobbySession:syncDanceWithPlayer(targetPlayerUserId)
--   lobbySession:buyDance(danceId)   :buyCosmetic(cosmeticId)   :equipCosmetic(cosmeticId)
--   lobbySession:claimPlaytimeMilestone(milestoneMinutes)   :claimDailyQuestReward(dailyQuestId)
--   lobbySession:submitTypedPromoCode(typedText)
--   lobbySession:tapLobbyWardrobeItem(stylingItemKey)   :confirmLobbyOutfit()
--   lobbySession:restoreStoredLobbyOutfit()   :clearLobbyOutfit()
--   lobbySession:noteRoundWardrobeTap(stylingItemKey, selectionOutcome?)   (focus for the Buy panel)
--   lobbySession:notePurchasePromptClosed(stylingItemKey)
--   lobbySession:applyWardrobeCatalogView(wardrobeCatalogView)
--   lobbySession:readLobbyScreenModel(lobbyScreenInputs) -> lobbyScreenModel
--     lobbyScreenInputs = { roundPreviewStylingItemKeys?, localLobbyDanceId?, otherPlayers, isRunningInStudio }
--     lobbyScreenModel = { lobbyMenu, dancesPanel, shopPanel, dailyRewardsPanel, promoCodePanel,
--       lobbyOutfitPanel, purchasePanel, previewStylingItemKeys? }
--   lobbySession:readLobbyDiagnostics() -> { sentRequestCountByChannelName, ownershipRequestCount,
--       hasSaveDataSnapshot }

local DailyRewardsPanelModelBuilder = require("./DailyRewardsPanelModelBuilder")
local DanceLobbyPanelModelBuilder = require("./DanceLobbyPanelModelBuilder")
local DeviceLobbyRequestSender = require("./DeviceLobbyRequestSender")
local LobbyMenuNavigation = require("./LobbyMenuNavigation")
local LobbyOutfitSelection = require("./LobbyOutfitSelection")
local LobbySaveDataSnapshotReader = require("./LobbySaveDataSnapshotReader")
local PromoCodeRedeemForm = require("./PromoCodeRedeemForm")
local ShopPanelModelBuilder = require("./ShopPanelModelBuilder")
local StylingItemOwnershipRequester = require("./StylingItemOwnershipRequester")
local StylingItemPurchasePanelModelBuilder = require("./StylingItemPurchasePanelModelBuilder")

local LobbyDeviceSession = {}
LobbyDeviceSession.__index = LobbyDeviceSession

LobbyDeviceSession.LOBBY_REQUEST_CHANNEL_NAMES = table.freeze({
	"SetLobbyOutfit",
	"RequestPurchaseDanceWithStarCoins",
	"RequestPurchaseCosmeticWithStarCoins",
	"RequestEquipDance",
	"RequestEquipCosmetic",
	"RequestStartDanceInLobby",
	"RequestSyncDanceWithPlayer",
	"RequestStopDanceInLobby",
	"RequestClaimPlaytimeMilestone",
	"RequestClaimDailyQuestReward",
	"RequestRedeemPromoCode",
})

function LobbyDeviceSession.new(dependencies)
	local self = setmetatable({
		clock = dependencies.clock,
		catalogs = {
			danceCatalogDances = dependencies.danceCatalogDances,
			cosmeticCatalog = dependencies.cosmeticCatalog,
			findCosmeticPresentation = dependencies.findCosmeticPresentation,
			playtimeMilestones = dependencies.playtimeMilestones,
			findDailyQuestByDailyQuestId = dependencies.findDailyQuestByDailyQuestId,
		},
		stylingItemByStylingItemKey = dependencies.stylingItemByStylingItemKey,
		onLobbyChanged = dependencies.onLobbyChanged,
		lobbySnapshot = nil,
		snapshotReceivedAtUnixMilliseconds = nil,
		wardrobeCatalogView = nil,
		navigation = LobbyMenuNavigation.new(),
	}, LobbyDeviceSession)
	local notify = function()
		self:notifyLobbyChanged()
	end
	self.lobbyRequestSender = DeviceLobbyRequestSender.new({
		clock = dependencies.clock,
		askServer = dependencies.askServer,
		onRequestOutcomeChanged = notify,
	})
	self.promoCodeForm = PromoCodeRedeemForm.new({ lobbyRequestSender = self.lobbyRequestSender })
	self.lobbyOutfitSelection = LobbyOutfitSelection.new({
		stylingItemByStylingItemKey = dependencies.stylingItemByStylingItemKey,
		lobbyRequestSender = self.lobbyRequestSender,
	})
	self.ownershipRequester = StylingItemOwnershipRequester.new({
		clock = dependencies.clock,
		scheduler = dependencies.scheduler,
		requestStylingItemOwnership = function(stylingItemKey, onAnswer)
			dependencies.askServer("RequestStylingItemOwnership", stylingItemKey, onAnswer)
		end,
		onOwnershipChanged = notify,
	})
	return self
end

function LobbyDeviceSession:notifyLobbyChanged()
	if self.onLobbyChanged ~= nil then
		self.onLobbyChanged()
	end
end

function LobbyDeviceSession:receivePlayerSaveDataSnapshot(message: any): boolean
	local lobbySnapshot = LobbySaveDataSnapshotReader.readLobbySaveDataSnapshot(message)
	if lobbySnapshot == nil then
		return false
	end
	self.lobbySnapshot = lobbySnapshot
	self.snapshotReceivedAtUnixMilliseconds = self.clock:getCurrentUnixMilliseconds()
	self:notifyLobbyChanged()
	return true
end

function LobbyDeviceSession:applyWardrobeCatalogView(wardrobeCatalogView)
	self.wardrobeCatalogView = wardrobeCatalogView
	if self:isOutfitPanelShown() then
		self.lobbyOutfitSelection:restoreStoredOutfit(self.lobbySnapshot, wardrobeCatalogView)
	end
	self:notifyLobbyChanged()
end

function LobbyDeviceSession:noteRoundSessionSnapshot(sessionSnapshot)
	local wasOutfitPanelShown = self:isOutfitPanelShown()
	self.navigation:noteLobbyMenuAvailability(LobbyMenuNavigation.isLobbyMenuAvailable(sessionSnapshot))
	if wasOutfitPanelShown and not self:isOutfitPanelShown() then
		self.ownershipRequester:clearFocus()
	end
end

function LobbyDeviceSession:isLobbyMenuOpen(): boolean
	return self.navigation:readLobbyMenuModel().isMenuOpen
end

function LobbyDeviceSession:isOutfitPanelShown(): boolean
	local menuModel = self.navigation:readLobbyMenuModel()
	return menuModel.isMenuOpen and menuModel.openPanelName == "Outfit"
end

function LobbyDeviceSession:handleNavigationOutcome(navigationOutcome)
	if navigationOutcome.wasOutfitPanelOpened then
		self.lobbyOutfitSelection:beginEditing(self.lobbySnapshot, self.wardrobeCatalogView)
		self.ownershipRequester:clearFocus()
	elseif not self:isOutfitPanelShown() then
		self.ownershipRequester:clearFocus()
	end
	self:notifyLobbyChanged()
end

function LobbyDeviceSession:toggleLobbyMenu()
	self:handleNavigationOutcome(self.navigation:toggleLobbyMenu())
end

function LobbyDeviceSession:openLobbyPanel(panelName: string)
	self:handleNavigationOutcome(self.navigation:openLobbyPanel(panelName))
end

-- Sends one lobby request when the menu is open; returns whether it was sent.
function LobbyDeviceSession:sendWhileMenuOpen(remoteChannelName: string, payload: any, requestSubject: any): boolean
	if not self:isLobbyMenuOpen() then
		return false
	end
	return self.lobbyRequestSender:sendLobbyRequest(remoteChannelName, payload, requestSubject)
end

function LobbyDeviceSession:equipDance(danceId: string): boolean
	return self:sendWhileMenuOpen("RequestEquipDance", danceId, danceId)
end

function LobbyDeviceSession:startDanceInLobby(danceId: string): boolean
	return self:sendWhileMenuOpen("RequestStartDanceInLobby", danceId, danceId)
end

function LobbyDeviceSession:stopDanceInLobby(): boolean
	return self:sendWhileMenuOpen("RequestStopDanceInLobby", nil, "stop")
end

function LobbyDeviceSession:syncDanceWithPlayer(targetPlayerUserId: number): boolean
	return self:sendWhileMenuOpen("RequestSyncDanceWithPlayer", targetPlayerUserId, targetPlayerUserId)
end

function LobbyDeviceSession:buyDance(danceId: string): boolean
	return self:sendWhileMenuOpen("RequestPurchaseDanceWithStarCoins", danceId, danceId)
end

function LobbyDeviceSession:buyCosmetic(cosmeticId: string): boolean
	return self:sendWhileMenuOpen("RequestPurchaseCosmeticWithStarCoins", cosmeticId, cosmeticId)
end

function LobbyDeviceSession:equipCosmetic(cosmeticId: string): boolean
	return self:sendWhileMenuOpen("RequestEquipCosmetic", cosmeticId, cosmeticId)
end

function LobbyDeviceSession:claimPlaytimeMilestone(milestoneMinutes: number): boolean
	return self:sendWhileMenuOpen("RequestClaimPlaytimeMilestone", milestoneMinutes, milestoneMinutes)
end

function LobbyDeviceSession:claimDailyQuestReward(dailyQuestId: string): boolean
	return self:sendWhileMenuOpen("RequestClaimDailyQuestReward", dailyQuestId, dailyQuestId)
end

function LobbyDeviceSession:submitTypedPromoCode(typedText: any): boolean
	if not self:isLobbyMenuOpen() then
		return false
	end
	local wasSent = self.promoCodeForm:submitTypedPromoCode(typedText)
	self:notifyLobbyChanged()
	return wasSent
end

function LobbyDeviceSession:tapLobbyWardrobeItem(stylingItemKey: string)
	if not self:isOutfitPanelShown() then
		return nil
	end
	local selectionOutcome = self.lobbyOutfitSelection:tapWardrobeItem(stylingItemKey, self.wardrobeCatalogView)
	self.ownershipRequester:noteWardrobeTap(stylingItemKey, selectionOutcome)
	self:notifyLobbyChanged()
	return selectionOutcome
end

function LobbyDeviceSession:confirmLobbyOutfit(): boolean
	if not self:isOutfitPanelShown() then
		return false
	end
	return self.lobbyOutfitSelection:confirmLobbyOutfit()
end

function LobbyDeviceSession:restoreStoredLobbyOutfit()
	if self:isOutfitPanelShown() then
		self.lobbyOutfitSelection:restoreStoredOutfit(self.lobbySnapshot, self.wardrobeCatalogView)
		self.ownershipRequester:clearFocus()
		self:notifyLobbyChanged()
	end
end

function LobbyDeviceSession:clearLobbyOutfit()
	if self:isOutfitPanelShown() then
		self.lobbyOutfitSelection:clearSelection()
		self.ownershipRequester:clearFocus()
		self:notifyLobbyChanged()
	end
end

function LobbyDeviceSession:noteRoundWardrobeTap(stylingItemKey: string, selectionOutcome)
	self.ownershipRequester:noteWardrobeTap(stylingItemKey, selectionOutcome)
end

function LobbyDeviceSession:notePurchasePromptClosed(stylingItemKey: string)
	self.ownershipRequester:askAgainAfterPurchasePromptClosed(stylingItemKey)
end

function LobbyDeviceSession:readOutcomeByRemoteChannelName()
	local outcomeByRemoteChannelName = {}
	for _, remoteChannelName in LobbyDeviceSession.LOBBY_REQUEST_CHANNEL_NAMES do
		outcomeByRemoteChannelName[remoteChannelName] =
			self.lobbyRequestSender:readLatestLobbyRequestOutcome(remoteChannelName)
	end
	return outcomeByRemoteChannelName
end

function LobbyDeviceSession:readLobbyScreenModel(lobbyScreenInputs)
	local catalogs = self.catalogs
	local outcomes = self:readOutcomeByRemoteChannelName()
	local lobbyOutfitPanel =
		self.lobbyOutfitSelection:buildLobbyOutfitPanelModel(self.lobbySnapshot, self.wardrobeCatalogView)
	local previewStylingItemKeys = lobbyScreenInputs.roundPreviewStylingItemKeys
	local isLobbyWardrobeShown = self:isOutfitPanelShown() and #lobbyOutfitPanel.wardrobePanel.slotGroups > 0
	if previewStylingItemKeys == nil and isLobbyWardrobeShown then
		previewStylingItemKeys = self.lobbyOutfitSelection:readSelectedStylingItemKeys()
	end
	return {
		lobbyMenu = self.navigation:readLobbyMenuModel(),
		dancesPanel = DanceLobbyPanelModelBuilder.buildDanceLobbyPanelModel({
			lobbySnapshot = self.lobbySnapshot,
			danceCatalogDances = catalogs.danceCatalogDances,
			localLobbyDanceId = lobbyScreenInputs.localLobbyDanceId,
			otherPlayers = lobbyScreenInputs.otherPlayers,
			outcomeByRemoteChannelName = outcomes,
		}),
		shopPanel = ShopPanelModelBuilder.buildShopPanelModel({
			lobbySnapshot = self.lobbySnapshot,
			danceCatalogDances = catalogs.danceCatalogDances,
			cosmeticCatalog = catalogs.cosmeticCatalog,
			findCosmeticPresentation = catalogs.findCosmeticPresentation,
			outcomeByRemoteChannelName = outcomes,
		}),
		dailyRewardsPanel = DailyRewardsPanelModelBuilder.buildDailyRewardsPanelModel({
			lobbySnapshot = self.lobbySnapshot,
			snapshotReceivedAtUnixMilliseconds = self.snapshotReceivedAtUnixMilliseconds,
			nowUnixMilliseconds = self.clock:getCurrentUnixMilliseconds(),
			playtimeMilestones = catalogs.playtimeMilestones,
			findDailyQuestByDailyQuestId = catalogs.findDailyQuestByDailyQuestId,
			outcomeByRemoteChannelName = outcomes,
		}),
		promoCodePanel = self.promoCodeForm:readPromoCodePanelModel(),
		lobbyOutfitPanel = lobbyOutfitPanel,
		purchasePanel = StylingItemPurchasePanelModelBuilder.buildStylingItemPurchasePanelModel({
			focusedOwnership = self.ownershipRequester:readFocusedOwnership(),
			shownOutfitStylingItemKeys = previewStylingItemKeys,
			wardrobeCatalogView = self.wardrobeCatalogView,
			stylingItemByStylingItemKey = self.stylingItemByStylingItemKey,
			isRunningInStudio = lobbyScreenInputs.isRunningInStudio,
		}),
		previewStylingItemKeys = previewStylingItemKeys,
	}
end

function LobbyDeviceSession:readLobbyDiagnostics()
	local sentRequestCountByChannelName = {}
	for _, remoteChannelName in LobbyDeviceSession.LOBBY_REQUEST_CHANNEL_NAMES do
		sentRequestCountByChannelName[remoteChannelName] =
			self.lobbyRequestSender:readSentLobbyRequestCount(remoteChannelName)
	end
	return {
		sentRequestCountByChannelName = sentRequestCountByChannelName,
		ownershipRequestCount = self.ownershipRequester:readSentRequestCount(),
		hasSaveDataSnapshot = self.lobbySnapshot ~= nil,
	}
end

return LobbyDeviceSession
