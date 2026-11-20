-- LobbyScreensView (development spec §0.2 "Lobby and dance floor", Phase 2): creates every Phase 2
-- screen once and renders LobbyDeviceSession's lobby screen model into them: the lobby menu
-- (LobbyMenuView) with its five panels (DanceLobbyPanelView, ShopPanelView, DailyRewardsPanelView,
-- PromoCodePanelView, LobbyOutfitPanelView) and the wardrobe's Buy panel (StylingItemPurchasePanelView).
-- Every player action goes straight back to the lobby session (or, for Buy, to onBuyActivated); this
-- file decides nothing and never asks the engine for a purchase prompt.
--
-- PUBLIC API
--   LobbyScreensView.create(screenGui, lobbySession, playerDisplayName, onBuyActivated()) -> view
--   view:render(lobbyScreenModel)
--
-- Roblox API used: see the views listed above.

local DailyRewardsPanelView = require("./DailyRewardsPanelView")
local DanceLobbyPanelView = require("./DanceLobbyPanelView")
local LobbyMenuView = require("./LobbyMenuView")
local LobbyOutfitPanelView = require("./LobbyOutfitPanelView")
local PromoCodePanelView = require("./PromoCodePanelView")
local ShopPanelView = require("./ShopPanelView")
local StylingItemPurchasePanelView = require("./StylingItemPurchasePanelView")

local LobbyScreensView = {}
LobbyScreensView.__index = LobbyScreensView

function LobbyScreensView.create(
	screenGui: ScreenGui,
	lobbySession,
	playerDisplayName: string,
	onBuyActivated: () -> ()
)
	local menuView = LobbyMenuView.create(screenGui, {
		onMenuButtonActivated = function()
			lobbySession:toggleLobbyMenu()
		end,
		onTabActivated = function(panelName)
			lobbySession:openLobbyPanel(panelName)
		end,
	})
	local content = menuView.contentFrameByPanelName
	return setmetatable({
		menuView = menuView,
		dancesView = DanceLobbyPanelView.create(content.Dances, {
			onStartDance = function(danceId)
				lobbySession:startDanceInLobby(danceId)
			end,
			onEquipDance = function(danceId)
				lobbySession:equipDance(danceId)
			end,
			onStopDance = function()
				lobbySession:stopDanceInLobby()
			end,
			onSyncWithPlayer = function(playerUserId)
				lobbySession:syncDanceWithPlayer(playerUserId)
			end,
		}),
		shopView = ShopPanelView.create(content.Shop, {
			onBuyShopItem = function(itemRow)
				if itemRow.shopItemKind == "Dance" then
					lobbySession:buyDance(itemRow.itemId)
				else
					lobbySession:buyCosmetic(itemRow.itemId)
				end
			end,
			onEquipShopItem = function(itemRow)
				if itemRow.shopItemKind == "Dance" then
					lobbySession:equipDance(itemRow.itemId)
				else
					lobbySession:equipCosmetic(itemRow.itemId)
				end
			end,
		}, playerDisplayName),
		dailyView = DailyRewardsPanelView.create(content.Daily, {
			onClaimPlaytimeMilestone = function(milestoneMinutes)
				lobbySession:claimPlaytimeMilestone(milestoneMinutes)
			end,
			onClaimDailyQuestReward = function(dailyQuestId)
				lobbySession:claimDailyQuestReward(dailyQuestId)
			end,
		}),
		promoCodeView = PromoCodePanelView.create(content.Codes, function(typedText)
			lobbySession:submitTypedPromoCode(typedText)
		end),
		outfitView = LobbyOutfitPanelView.create(content.Outfit, {
			onWardrobeItemActivated = function(stylingItemKey)
				lobbySession:tapLobbyWardrobeItem(stylingItemKey)
			end,
			onConfirmActivated = function()
				lobbySession:confirmLobbyOutfit()
			end,
			onRestoreActivated = function()
				lobbySession:restoreStoredLobbyOutfit()
			end,
			onClearActivated = function()
				lobbySession:clearLobbyOutfit()
			end,
		}),
		purchaseView = StylingItemPurchasePanelView.create(screenGui, onBuyActivated),
	}, LobbyScreensView)
end

function LobbyScreensView:render(lobbyScreenModel)
	local menuModel = lobbyScreenModel.lobbyMenu
	self.menuView:render(menuModel)
	if menuModel.isMenuOpen then
		-- Only the shown panel is drawn; the others catch up when they are opened.
		local openPanelName = menuModel.openPanelName
		if openPanelName == "Dances" then
			self.dancesView:render(lobbyScreenModel.dancesPanel)
		elseif openPanelName == "Shop" then
			self.shopView:render(lobbyScreenModel.shopPanel)
		elseif openPanelName == "Daily" then
			self.dailyView:render(lobbyScreenModel.dailyRewardsPanel)
		elseif openPanelName == "Codes" then
			self.promoCodeView:render(lobbyScreenModel.promoCodePanel)
		elseif openPanelName == "Outfit" then
			self.outfitView:render(lobbyScreenModel.lobbyOutfitPanel)
		end
	end
	self.purchaseView:render(lobbyScreenModel.purchasePanel)
end

return LobbyScreensView
