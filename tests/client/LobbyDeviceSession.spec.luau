-- LobbyDeviceSession on its own (fake clock, recorded requests): what it ties together and decides itself.

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local DeviceTestFixtures = require("./DeviceTestFixtures")
local LobbyTestFixtures = require("./LobbyTestFixtures")
local CosmeticCatalog = require("../../src/shared/CosmeticCatalog")
local CosmeticPresentationCatalog = require("../../src/shared/CosmeticPresentationCatalog")
local DailyQuestCatalog = require("../../src/shared/DailyQuestCatalog")
local DanceCatalog = require("../../src/shared/DanceCatalog")
local LobbyDeviceSession = require("../../src/client/LobbyDeviceSession")
local PlaytimeMilestoneCatalog = require("../../src/shared/PlaytimeMilestoneCatalog")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local F = DeviceTestFixtures

local function createLobbySession()
	local fakeClock = FakeClock.new(LobbyTestFixtures.START_UNIX_SECONDS)
	local askServer, pendingRequests = LobbyTestFixtures.createRecordingAskServer()
	local lobbySession = LobbyDeviceSession.new({
		clock = fakeClock,
		scheduler = FakeScheduler.new(fakeClock),
		askServer = askServer,
		stylingItemByStylingItemKey = F.STYLING_ITEM_BY_STYLING_ITEM_KEY,
		danceCatalogDances = DanceCatalog.DANCES,
		cosmeticCatalog = CosmeticCatalog,
		findCosmeticPresentation = CosmeticPresentationCatalog.findCosmeticPresentation,
		playtimeMilestones = PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES,
		findDailyQuestByDailyQuestId = DailyQuestCatalog.findDailyQuestByDailyQuestId,
	})
	lobbySession:noteRoundSessionSnapshot({ roundState = nil, isParticipant = false })
	return lobbySession, fakeClock, pendingRequests
end

local function readModel(lobbySession, roundPreviewStylingItemKeys)
	return lobbySession:readLobbyScreenModel({
		roundPreviewStylingItemKeys = roundPreviewStylingItemKeys,
		localLobbyDanceId = nil,
		otherPlayers = {},
		isRunningInStudio = true,
	})
end

describe("LobbyDeviceSession", function()
	it("counts the shown playtime from the moment the snapshot ARRIVED on the device", function()
		local lobbySession, fakeClock = createLobbySession()
		fakeClock:advanceBySeconds(600)
		lobbySession:receivePlayerSaveDataSnapshot(
			LobbyTestFixtures.buildSnapshotMessage({ dailyProgress = { playtimeSecondsToday = 250 } })
		)
		expect(readModel(lobbySession).dailyRewardsPanel.milestoneRows[1].stateText).toBe("In about 1 min")
		fakeClock:advanceBySeconds(55)
		expect(readModel(lobbySession).dailyRewardsPanel.milestoneRows[1].stateText).toBe("Unlocks within a minute...")
	end)

	it("ignores a snapshot of the wrong shape and keeps the previous one", function()
		local lobbySession = createLobbySession()
		expect(lobbySession:receivePlayerSaveDataSnapshot(LobbyTestFixtures.buildSnapshotMessage())).toBeTrue()
		expect(lobbySession:receivePlayerSaveDataSnapshot({ starCoinBalance = 5 })).toBeFalse()
		expect(readModel(lobbySession).shopPanel.balanceText).toBe("You have 500 Star Coins")
	end)

	it("sends nothing while the menu is closed or the player is busy in a round", function()
		local lobbySession, _, pendingRequests = createLobbySession()
		lobbySession:receivePlayerSaveDataSnapshot(LobbyTestFixtures.buildSnapshotMessage())
		expect(lobbySession:equipDance("starter_sway")).toBeFalse()
		lobbySession:toggleLobbyMenu()
		expect(lobbySession:equipDance("starter_sway")).toBeTrue()
		lobbySession:noteRoundSessionSnapshot({ roundState = { roundPhase = "Showcase" }, isParticipant = true })
		expect(lobbySession:buyCosmetic("title_rising_star")).toBeFalse()
		expect(lobbySession:submitTypedPromoCode("CODE")).toBeFalse()
		expect(#pendingRequests).toBe(1)
	end)

	it("opens the Outfit panel on the stored lobby outfit and previews it; a round preview takes precedence", function()
		local lobbySession = createLobbySession()
		lobbySession:receivePlayerSaveDataSnapshot(
			LobbyTestFixtures.buildSnapshotMessage({ lobbyOutfitStylingItemKeys = { F.HAIR, F.GLASSES } })
		)
		lobbySession:applyWardrobeCatalogView(F.buildDevelopmentWardrobeCatalogView())
		lobbySession:toggleLobbyMenu()
		expect(readModel(lobbySession).previewStylingItemKeys).toBeNil()
		lobbySession:openLobbyPanel("Outfit")
		expect(readModel(lobbySession).previewStylingItemKeys).toEqual({ F.HAIR, F.GLASSES })
		expect(readModel(lobbySession, { F.DRESS }).previewStylingItemKeys).toEqual({ F.DRESS })
	end)

	it("asks ownership for an item put on in the lobby outfit and shows the Buy panel for it", function()
		local lobbySession, _, pendingRequests = createLobbySession()
		lobbySession:receivePlayerSaveDataSnapshot(LobbyTestFixtures.buildSnapshotMessage())
		lobbySession:applyWardrobeCatalogView(F.buildDevelopmentWardrobeCatalogView())
		lobbySession:toggleLobbyMenu()
		lobbySession:openLobbyPanel("Outfit")
		lobbySession:tapLobbyWardrobeItem(F.SHOES_BUNDLE)
		expect(pendingRequests[1].remoteChannelName).toBe("RequestStylingItemOwnership")
		expect(pendingRequests[1].payload).toBe(F.SHOES_BUNDLE)
		pendingRequests[1].onAnswer({ isAccepted = true, isOwnedByPlayer = false })
		local purchasePanel = readModel(lobbySession).purchasePanel
		expect(purchasePanel.isVisible).toBeTrue()
		expect(purchasePanel.isBuyButtonVisible).toBeTrue()
		expect(purchasePanel.purchasePromptPermission.mayOpenPurchasePrompt).toBeFalse()
		expect(lobbySession:readLobbyDiagnostics().ownershipRequestCount).toBe(1)
	end)
end)
