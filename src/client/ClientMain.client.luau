-- ClientMain (development spec §3.2 "wiring only"): starts the device side of the game. It waits for
-- the server's remote channels, builds the device's rule modules and screens, connects every
-- server-sent channel to the module that reads it, and re-renders the screens when something changes
-- and five times a second (for the countdown and the wardrobe lock). It decides nothing itself:
--   rules      ThemedRoundDeviceSession (rounds, joining, wardrobe, drafts), WardrobeCatalogSnapshotRequester,
--              FanCountLeaderboardRequester, PlayerSaveDataStatusBarModel, DeviceKeyboardShortcutDecision,
--              LobbyDeviceSession (Phase 2: lobby menu, dances, shop, daily rewards, promo codes, lobby
--              outfit, the wardrobe's Buy panel), LobbyMenuNavigation (M, and 1-9 in the lobby outfit),
--              MarketplacePurchasePromptPermission (may Buy open a purchase prompt now)
--   what shows ThemedRoundScreenModelBuilder, LobbyDeviceSession:readLobbyScreenModel
--   screens    StatusBarView, RoundPhasePanelView, WardrobePanelView, LeaderboardPanelView,
--              RobloxWardrobePreviewCharacter, RobloxShowcaseCameraDirector, LobbyScreensView
--   engine     RobloxLobbyDancerReader (who is seen dancing), RobloxMarketplacePurchasePromptOpener
-- ⛔ Spec §5.1: nothing here changes a balance or ownership; they arrive only in the save snapshot.
-- 🔴 Purchase prompts (§2.12): the Buy button asks MarketplacePurchasePromptPermission with
-- RunService:IsStudio() read at that moment; in Studio it answers no and only the explanation shows.
-- RobloxMarketplacePurchasePromptOpener (which also refuses in Studio by itself) is called only on a yes.
--
-- Roblox API used, read in the official documentation (create.roblox.com/docs/reference/engine/...):
--   Players.LocalPlayer, Player.UserId, .DisplayName, Player.CharacterAdded, Player:WaitForChild("PlayerGui")
--                                                     classes/Players, classes/Player
--   ScreenGui .ResetOnSpawn (false: the screens survive a character respawn), .ZIndexBehavior,
--     .Name, .Parent                                  classes/ScreenGui, classes/LayerCollector
--   UserInputService.InputBegan(input, gameProcessedEvent), InputObject.KeyCode, .UserInputType
--                                                     classes/UserInputService, classes/InputObject
--   Enum.UserInputType.Keyboard, Enum.ZIndexBehavior.Sibling   enums/...
--   task.spawn, task.wait                             libraries/task
--   RunService:IsStudio() ("Returns whether the current environment is running in Studio")   classes/RunService
--   MarketplaceService.PromptPurchaseFinished(player, assetId, isPurchased),
--     .PromptBundlePurchaseFinished(player, bundleId, wasPurchased) ("Fires when a bundle purchase prompt
--     closes"; ownership is then asked again, never taken from the event)   classes/MarketplaceService

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CosmeticCatalog = require("../shared/CosmeticCatalog")
local CosmeticPresentationCatalog = require("../shared/CosmeticPresentationCatalog")
local DailyQuestCatalog = require("../shared/DailyQuestCatalog")
local DanceCatalog = require("../shared/DanceCatalog")
local DeviceKeyboardShortcutDecision = require("./DeviceKeyboardShortcutDecision")
local DeviceStateAttributesPublisher = require("./DeviceStateAttributesPublisher")
local FanCountLeaderboardRequester = require("./FanCountLeaderboardRequester")
local LeaderboardPanelView = require("./LeaderboardPanelView")
local LobbyDeviceSession = require("./LobbyDeviceSession")
local LobbyMenuNavigation = require("./LobbyMenuNavigation")
local LobbyScreensView = require("./LobbyScreensView")
local MarketplacePurchasePromptPermission = require("./MarketplacePurchasePromptPermission")
local PlayerSaveDataStatusBarModel = require("./PlayerSaveDataStatusBarModel")
local PlaytimeMilestoneCatalog = require("../shared/PlaytimeMilestoneCatalog")
local RemoteNames = require("../shared/RemoteNames")
local RobloxDeviceClockAndScheduler = require("./RobloxDeviceClockAndScheduler")
local RobloxDeviceRemoteChannels = require("./RobloxDeviceRemoteChannels")
local RobloxLobbyDancerReader = require("./RobloxLobbyDancerReader")
local RobloxMarketplacePurchasePromptOpener = require("./RobloxMarketplacePurchasePromptOpener")
local RobloxShowcaseCameraDirector = require("./RobloxShowcaseCameraDirector")
local RobloxWardrobePreviewCharacter = require("./RobloxWardrobePreviewCharacter")
local RoundPhasePanelView = require("./RoundPhasePanelView")
local StatusBarView = require("./StatusBarView")
local StylingItemLookup = require("../shared/StylingItemLookup")
local StylingItemPool = require("../shared/generated/StylingItemPool")
local ThemedRoundDeviceSession = require("./ThemedRoundDeviceSession")
local ThemedRoundScreenModelBuilder = require("./ThemedRoundScreenModelBuilder")
local WardrobeCatalogSnapshotRequester = require("./WardrobeCatalogSnapshotRequester")
local WardrobePanelView = require("./WardrobePanelView")

local CHANNELS = RemoteNames.REMOTE_CHANNEL_NAMES
local SCREEN_REFRESH_INTERVAL_SECONDS = 0.2

local localPlayer = Players.LocalPlayer
local channels = RobloxDeviceRemoteChannels.waitForRemoteChannels({
	CHANNELS.RoundStateChanged,
	CHANNELS.RequestJoinCurrentRound,
	CHANNELS.SetRoundOutfitDraft,
	CHANNELS.RoundOutfitDraftAcknowledged,
	CHANNELS.RoundResultsPublished,
	CHANNELS.PlayerSaveDataSnapshotChanged,
	CHANNELS.RequestFanCountLeaderboardTopEntries,
	CHANNELS.RequestWardrobeCatalogSnapshot,
	CHANNELS.WardrobeCatalogChanged,
	-- Phase 2
	CHANNELS.RequestStylingItemOwnership,
	CHANNELS.SetLobbyOutfit,
	CHANNELS.RequestPurchaseDanceWithStarCoins,
	CHANNELS.RequestPurchaseCosmeticWithStarCoins,
	CHANNELS.RequestEquipDance,
	CHANNELS.RequestEquipCosmetic,
	CHANNELS.RequestStartDanceInLobby,
	CHANNELS.RequestSyncDanceWithPlayer,
	CHANNELS.RequestStopDanceInLobby,
	CHANNELS.RequestClaimPlaytimeMilestone,
	CHANNELS.RequestClaimDailyQuestReward,
	CHANNELS.RequestRedeemPromoCode,
})
local deviceClock = RobloxDeviceClockAndScheduler.createDeviceClock()
local deviceScheduler = RobloxDeviceClockAndScheduler.createDeviceScheduler()
local stylingItemByStylingItemKey = StylingItemLookup.buildStylingItemByStylingItemKey(StylingItemPool.STYLING_ITEMS)
local isRunningInStudio = RunService:IsStudio()

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "IdolgrowDeviceScreens"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

local renderScreens -- set below; every module notifies through it
local isRenderingScreens = false
local function requestRender()
	-- A module that notifies while the screens are being drawn (the lobby session reacting to the
	-- round state read by that same render) is drawn at the next refresh, at most 0.2 s later.
	if renderScreens ~= nil and not isRenderingScreens then
		renderScreens()
	end
end

local statusBarModel = PlayerSaveDataStatusBarModel.new()
local session = ThemedRoundDeviceSession.new({
	localPlayerUserId = localPlayer.UserId,
	clock = deviceClock,
	scheduler = deviceScheduler,
	stylingItemByStylingItemKey = stylingItemByStylingItemKey,
	sendOutfitDraftToServer = function(message)
		channels:fireOutfitDraft(message)
	end,
	requestJoinCurrentRound = function(onAnswer)
		channels:askServer(CHANNELS.RequestJoinCurrentRound, nil, onAnswer)
	end,
	onSessionChanged = requestRender,
})
local lobbySession = LobbyDeviceSession.new({
	clock = deviceClock,
	scheduler = deviceScheduler,
	askServer = function(channelName, payload, onAnswer)
		channels:askServer(channelName, payload, onAnswer)
	end,
	stylingItemByStylingItemKey = stylingItemByStylingItemKey,
	danceCatalogDances = DanceCatalog.DANCES,
	cosmeticCatalog = CosmeticCatalog,
	findCosmeticPresentation = CosmeticPresentationCatalog.findCosmeticPresentation,
	playtimeMilestones = PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES,
	findDailyQuestByDailyQuestId = DailyQuestCatalog.findDailyQuestByDailyQuestId,
	onLobbyChanged = requestRender,
})
local catalogRequester = WardrobeCatalogSnapshotRequester.new({
	clock = deviceClock,
	scheduler = deviceScheduler,
	stylingItemByStylingItemKey = stylingItemByStylingItemKey,
	requestWardrobeCatalogSnapshot = function(onAnswer)
		channels:askServer(CHANNELS.RequestWardrobeCatalogSnapshot, nil, onAnswer)
	end,
	onWardrobeCatalogViewReady = function(wardrobeCatalogView)
		session:applyWardrobeCatalogView(wardrobeCatalogView)
		lobbySession:applyWardrobeCatalogView(wardrobeCatalogView)
	end,
})
local leaderboardRequester = FanCountLeaderboardRequester.new({
	clock = deviceClock,
	scheduler = deviceScheduler,
	localPlayerUserId = localPlayer.UserId,
	requestFanCountLeaderboardTopEntries = function(onAnswer)
		channels:askServer(CHANNELS.RequestFanCountLeaderboardTopEntries, nil, onAnswer)
	end,
	onLeaderboardPanelChanged = requestRender,
})

local leaderboardPanelView
local function toggleLeaderboard()
	local isOpening = not leaderboardPanelView:isOpen()
	leaderboardPanelView:setOpen(isOpening)
	if isOpening then
		leaderboardRequester:askForTopEntries()
	end
	requestRender()
end
local function tapRoundWardrobeItem(stylingItemKey: string)
	lobbySession:noteRoundWardrobeTap(stylingItemKey, session:tapWardrobeItem(stylingItemKey))
end
local statusBarView = StatusBarView.create(screenGui, toggleLeaderboard)
local roundPhasePanelView = RoundPhasePanelView.create(screenGui, function()
	session:askToJoinCurrentRound()
end)
local wardrobePanelView = WardrobePanelView.create(screenGui, tapRoundWardrobeItem)
local wardrobePreview = RobloxWardrobePreviewCharacter.create(screenGui, localPlayer)
leaderboardPanelView = LeaderboardPanelView.create(screenGui, function()
	leaderboardRequester:askForTopEntries()
end, function()
	leaderboardPanelView:setOpen(false)
end)
local showcaseCameraDirector = RobloxShowcaseCameraDirector.new(localPlayer)

-- §2.12 Buy: the decision is MarketplacePurchasePromptPermission's, on RunService:IsStudio() read now.
local latestLobbyScreenModel = nil
local buyButtonPressCount, purchasePromptOpenCount = 0, 0
local function handleBuyActivated()
	buyButtonPressCount += 1
	local purchasePanel = if latestLobbyScreenModel ~= nil then latestLobbyScreenModel.purchasePanel else nil
	local stylingItem = if purchasePanel ~= nil and purchasePanel.stylingItemKey ~= nil
		then stylingItemByStylingItemKey[purchasePanel.stylingItemKey]
		else nil
	if stylingItem ~= nil and purchasePanel.isBuyButtonVisible then
		local permission = MarketplacePurchasePromptPermission.decidePurchasePromptPermission({
			isRunningInStudio = RunService:IsStudio(),
			marketplaceItemKind = stylingItem.marketplaceItemKind,
			marketplaceItemId = stylingItem.marketplaceItemId,
			ownershipStatus = "NotOwned", -- the Buy button is shown only for that answer
		})
		if permission.mayOpenPurchasePrompt then
			purchasePromptOpenCount += 1
			RobloxMarketplacePurchasePromptOpener.openPurchasePromptForStylingItem(
				localPlayer,
				permission.purchasePromptKind,
				stylingItem.marketplaceItemId
			)
		end
	end
	requestRender()
end
local lobbyScreensView = LobbyScreensView.create(screenGui, lobbySession, localPlayer.DisplayName, handleBuyActivated)

local latestScreenModel = nil
local function drawScreens()
	local sessionSnapshot = session:readSessionSnapshot()
	local screenModel = ThemedRoundScreenModelBuilder.buildThemedRoundScreenModel(sessionSnapshot)
	latestScreenModel = screenModel
	lobbySession:noteRoundSessionSnapshot(sessionSnapshot)
	local roundState = sessionSnapshot.roundState
	local lobbyDancers = RobloxLobbyDancerReader.readLobbyDancers(localPlayer, {
		roundPhase = if roundState ~= nil then roundState.roundPhase else nil,
		participantUserIds = if roundState ~= nil then roundState.participantUserIds else {},
	}, DanceCatalog.DANCES)
	local lobbyScreenModel = lobbySession:readLobbyScreenModel({
		roundPreviewStylingItemKeys = screenModel.previewStylingItemKeys,
		localLobbyDanceId = lobbyDancers.localLobbyDanceId,
		otherPlayers = lobbyDancers.otherPlayers,
		isRunningInStudio = isRunningInStudio,
	})
	latestLobbyScreenModel = lobbyScreenModel
	statusBarView:render(statusBarModel:readStatusBarModel())
	roundPhasePanelView:render(screenModel)
	wardrobePanelView:render(screenModel.wardrobePanel)
	lobbyScreensView:render(lobbyScreenModel)
	wardrobePreview:showOutfit(lobbyScreenModel.previewStylingItemKeys, sessionSnapshot.wardrobeCatalogView)
	leaderboardPanelView:render(leaderboardRequester:readLeaderboardPanelModel())
	showcaseCameraDirector:update(screenModel.screenName)
	DeviceStateAttributesPublisher.publishSessionSnapshot(screenGui, sessionSnapshot)
	DeviceStateAttributesPublisher.publishRequestCounts(
		screenGui,
		leaderboardRequester:readRequestCount(),
		catalogRequester:readRequestCount()
	)
	DeviceStateAttributesPublisher.publishLobbyDiagnostics(screenGui, lobbySession:readLobbyDiagnostics(), {
		localLobbyDanceId = lobbyDancers.localLobbyDanceId,
		isRunningInStudio = isRunningInStudio,
		buyButtonPressCount = buyButtonPressCount,
		purchasePromptOpenCount = purchasePromptOpenCount,
	})
end
renderScreens = function()
	isRenderingScreens = true
	local didDraw, drawProblem = pcall(drawScreens)
	isRenderingScreens = false
	if not didDraw then
		warn("Device: drawing the screens failed: " .. tostring(drawProblem))
	end
end

channels:listenToServerMessage(CHANNELS.RoundStateChanged, function(message)
	session:receiveRoundStateChanged(message)
end)
channels:listenToServerMessage(CHANNELS.RoundOutfitDraftAcknowledged, function(message)
	session:receiveRoundOutfitDraftAcknowledged(message)
end)
channels:listenToServerMessage(CHANNELS.RoundResultsPublished, function(message)
	session:receiveRoundResultsPublished(message)
end)
channels:listenToServerMessage(CHANNELS.PlayerSaveDataSnapshotChanged, function(message)
	local isTakenByStatusBar = statusBarModel:receivePlayerSaveDataSnapshot(message)
	local isTakenByLobby = lobbySession:receivePlayerSaveDataSnapshot(message)
	if isTakenByStatusBar or isTakenByLobby then
		requestRender()
	end
end)
channels:listenToServerMessage(CHANNELS.WardrobeCatalogChanged, function(message)
	catalogRequester:receiveWardrobeCatalogChanged(message)
end)

-- §2.14: ownership is asked again after a purchase prompt closes (never taken from the event itself).
local function handlePurchasePromptClosed(player: Player, marketplaceItemKind: string, marketplaceItemId: number)
	if player ~= localPlayer then
		return
	end
	local didDerive, stylingItemKey =
		pcall(StylingItemLookup.deriveStylingItemKey, marketplaceItemKind, marketplaceItemId)
	if didDerive then
		lobbySession:notePurchasePromptClosed(stylingItemKey)
	end
end
MarketplaceService.PromptPurchaseFinished:Connect(function(player, assetId)
	handlePurchasePromptClosed(player, "Asset", assetId)
end)
MarketplaceService.PromptBundlePurchaseFinished:Connect(function(player, bundleId)
	handlePurchasePromptClosed(player, "Bundle", bundleId)
end)

localPlayer.CharacterAdded:Connect(function()
	wardrobePreview:handleCharacterRespawned()
	requestRender()
end)

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
	if input.UserInputType ~= Enum.UserInputType.Keyboard or latestScreenModel == nil then
		return
	end
	if latestLobbyScreenModel ~= nil then
		local lobbyKeyAction = LobbyMenuNavigation.decideLobbyMenuKeyAction(
			input.KeyCode.Name,
			gameProcessedEvent,
			latestLobbyScreenModel.lobbyMenu,
			latestLobbyScreenModel.lobbyOutfitPanel.wardrobePanel
		)
		if lobbyKeyAction ~= nil and lobbyKeyAction.actionKind == "ToggleLobbyMenu" then
			lobbySession:toggleLobbyMenu()
			return
		elseif lobbyKeyAction ~= nil and lobbyKeyAction.actionKind == "TapLobbyWardrobeItem" then
			lobbySession:tapLobbyWardrobeItem(lobbyKeyAction.stylingItemKey)
			return
		end
	end
	local keyAction =
		DeviceKeyboardShortcutDecision.decideKeyAction(input.KeyCode.Name, gameProcessedEvent, latestScreenModel)
	if keyAction == nil then
		return
	elseif keyAction.actionKind == "ToggleLeaderboard" then
		toggleLeaderboard()
	elseif keyAction.actionKind == "JoinCurrentRound" then
		session:askToJoinCurrentRound()
	elseif keyAction.actionKind == "TapWardrobeItem" then
		tapRoundWardrobeItem(keyAction.stylingItemKey)
	end
end)

catalogRequester:start()
renderScreens()
while true do
	task.wait(SCREEN_REFRESH_INTERVAL_SECONDS)
	renderScreens()
end
