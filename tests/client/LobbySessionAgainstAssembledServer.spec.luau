-- The device's lobby (LobbyDeviceSession with ThemedRoundDeviceSession and the catalog requester)
-- driven against the WHOLE game server assembled on fakes (ServerGameAssemblyTestHarness), on one fake
-- clock: what the panels show comes only from the server's snapshots and answers.
-- The harness is given a fixture dance catalog with dances for sale (the real catalog sells none) and a
-- fixture promo code, so the purchase paths can run; both exist only in this test.

local UnitTestFramework = require("../Support/UnitTestFramework")
local DeviceTestFixtures = require("./DeviceTestFixtures")
local LobbyTestFixtures = require("./LobbyTestFixtures")
local ServerGameAssemblyTestHarness = require("../server/ServerGameAssemblyTestHarness")
local CosmeticCatalog = require("../../src/shared/CosmeticCatalog")
local CosmeticPresentationCatalog = require("../../src/shared/CosmeticPresentationCatalog")
local DailyQuestCatalog = require("../../src/shared/DailyQuestCatalog")
local LobbyDeviceSession = require("../../src/client/LobbyDeviceSession")
local PlaytimeMilestoneCatalog = require("../../src/shared/PlaytimeMilestoneCatalog")
local PromoCodeCatalog = require("../../src/server/PromoCodeCatalog")
local ThemedRoundDeviceSession = require("../../src/client/ThemedRoundDeviceSession")
local WardrobeCatalogSnapshotRequester = require("../../src/client/WardrobeCatalogSnapshotRequester")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local F = DeviceTestFixtures
local LOCAL_USER_ID = 101
local OTHER_USER_ID = 202

local FIXTURE_PROMO_CODES = PromoCodeCatalog.freezePromoCodeCatalog({
	{
		promoCodeId = "lobby_test_code",
		promoCodeText = "LOBBYTEST",
		starCoinReward = 1500,
		validFromUnixSeconds = ServerGameAssemblyTestHarness.SERVER_START_UNIX_SECONDS - 10,
		validUntilUnixSeconds = ServerGameAssemblyTestHarness.SERVER_START_UNIX_SECONDS + 86400,
	},
})

local function connectDevice()
	local harness = ServerGameAssemblyTestHarness.createStartedServer({
		catalogs = { danceCatalog = LobbyTestFixtures.FIXTURE_DANCE_CATALOG, promoCodeEntries = FIXTURE_PROMO_CODES },
	})
	local device = { harness = harness, deliveredCount = 0, askedChannels = {} }
	local function askServer(remoteChannelName, payload, onAnswer)
		table.insert(device.askedChannels, remoteChannelName)
		onAnswer(harness:ask(remoteChannelName, LOCAL_USER_ID, payload))
	end
	device.roundSession = ThemedRoundDeviceSession.new({
		localPlayerUserId = LOCAL_USER_ID,
		clock = harness.fakeClock,
		scheduler = harness.fakeScheduler,
		stylingItemByStylingItemKey = F.STYLING_ITEM_BY_STYLING_ITEM_KEY,
		sendOutfitDraftToServer = function(message)
			harness:sendDraft(LOCAL_USER_ID, message)
		end,
		requestJoinCurrentRound = function(onAnswer)
			onAnswer(harness:ask("RequestJoinCurrentRound", LOCAL_USER_ID, nil))
		end,
	})
	device.lobby = LobbyDeviceSession.new({
		clock = harness.fakeClock,
		scheduler = harness.fakeScheduler,
		askServer = askServer,
		stylingItemByStylingItemKey = F.STYLING_ITEM_BY_STYLING_ITEM_KEY,
		danceCatalogDances = LobbyTestFixtures.FIXTURE_DANCE_CATALOG.DANCES,
		cosmeticCatalog = CosmeticCatalog,
		findCosmeticPresentation = CosmeticPresentationCatalog.findCosmeticPresentation,
		playtimeMilestones = PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES,
		findDailyQuestByDailyQuestId = DailyQuestCatalog.findDailyQuestByDailyQuestId,
	})
	device.catalogRequester = WardrobeCatalogSnapshotRequester.new({
		clock = harness.fakeClock,
		scheduler = harness.fakeScheduler,
		stylingItemByStylingItemKey = F.STYLING_ITEM_BY_STYLING_ITEM_KEY,
		requestWardrobeCatalogSnapshot = function(onAnswer)
			onAnswer(harness:ask("RequestWardrobeCatalogSnapshot", LOCAL_USER_ID, nil))
		end,
		onWardrobeCatalogViewReady = function(view)
			device.roundSession:applyWardrobeCatalogView(view)
			device.lobby:applyWardrobeCatalogView(view)
		end,
	})
	function device.pump()
		while device.deliveredCount < #harness.sentMessages do
			device.deliveredCount += 1
			local sent = harness.sentMessages[device.deliveredCount]
			if sent.playerUserId == nil or sent.playerUserId == LOCAL_USER_ID then
				if sent.channel == "RoundStateChanged" then
					device.roundSession:receiveRoundStateChanged(sent.message)
				elseif sent.channel == "RoundOutfitDraftAcknowledged" then
					device.roundSession:receiveRoundOutfitDraftAcknowledged(sent.message)
				elseif sent.channel == "PlayerSaveDataSnapshotChanged" then
					device.lobby:receivePlayerSaveDataSnapshot(sent.message)
				elseif sent.channel == "WardrobeCatalogChanged" then
					device.catalogRequester:receiveWardrobeCatalogChanged(sent.message)
				end
			end
		end
		device.lobby:noteRoundSessionSnapshot(device.roundSession:readSessionSnapshot())
	end
	function device.run(seconds)
		for _ = 1, math.round(seconds / 0.05) do
			harness:advance(0.05)
			device.pump()
		end
	end
	function device.read(otherPlayers)
		return device.lobby:readLobbyScreenModel({
			roundPreviewStylingItemKeys = nil,
			localLobbyDanceId = nil,
			otherPlayers = otherPlayers or {},
			isRunningInStudio = true,
		})
	end
	harness:joinPlayer(LOCAL_USER_ID)
	device.catalogRequester:start()
	device.pump()
	device.run(5)
	return device
end

local function findShopRow(screenModel, itemId)
	for _, group in screenModel.shopPanel.groups do
		for _, itemRow in group.itemRows do
			if itemRow.itemId == itemId then
				return itemRow
			end
		end
	end
	return nil
end

local function readLatestSnapshot(harness)
	local snapshots = harness:listSent("PlayerSaveDataSnapshotChanged", LOCAL_USER_ID)
	return snapshots[#snapshots]
end

describe("lobby session against the assembled server", function()
	it("dances: equip a starter dance for the stage, start, stop, and sync answers explained", function()
		local device = connectDevice()
		device.lobby:toggleLobbyMenu()
		local dances = device.read().dancesPanel
		expect(#dances.danceRows).toBe(3)
		expect(dances.danceRows[1].stageDanceText).toBe("Your stage dance")
		expect(device.lobby:equipDance("starter_sway")).toBeTrue()
		device.run(0.1)
		expect(readLatestSnapshot(device.harness).equippedDanceId).toBe("starter_sway")
		expect(device.read().dancesPanel.danceRows[3].stageDanceText).toBe("Your stage dance")
		expect(device.lobby:startDanceInLobby("starter_bounce")).toBeTrue()
		expect(device.read().dancesPanel.danceRows[2].feedbackText).toBe("Dancing!")
		expect(device.lobby:syncDanceWithPlayer(LOCAL_USER_ID)).toBeTrue()
		device.harness:joinPlayer(OTHER_USER_ID)
		device.run(0.5)
		local others = { { playerUserId = OTHER_USER_ID, playerDisplayName = "Other", lobbyDanceId = nil } }
		expect(device.lobby:syncDanceWithPlayer(OTHER_USER_ID)).toBeTrue()
		expect(device.read(others).dancesPanel.playerRows[1].feedbackText).toBe(
			"That player is not dancing in the lobby right now, so there is nothing to join."
		)
		device.harness:ask("RequestStartDanceInLobby", OTHER_USER_ID, "starter_groove")
		device.run(0.5)
		expect(device.lobby:syncDanceWithPlayer(OTHER_USER_ID)).toBeTrue()
		expect(device.read(others).dancesPanel.playerRows[1].feedbackText).toBe("You joined their dance!")
		expect(device.lobby:stopDanceInLobby()).toBeTrue()
		expect(device.read().dancesPanel.stopFeedbackText).toBe("Stopped dancing.")
		expect(device.lobby:stopDanceInLobby()).toBeFalse()
		expect(device.read().dancesPanel.stopFeedbackText).toBe("Please wait 0.5 seconds between tries.")
	end)

	it(
		"daily: a milestone not reached is refused and explained; reached, it is claimed once from the snapshot",
		function()
			local device = connectDevice()
			device.lobby:toggleLobbyMenu()
			local daily = device.read().dailyRewardsPanel
			expect(daily.milestoneRows[1].isClaimButtonVisible).toBeFalse()
			expect(device.lobby:claimPlaytimeMilestone(5)).toBeTrue()
			expect(device.read().dailyRewardsPanel.milestoneRows[1].feedbackText).toBe(
				"You haven't played long enough today for that reward yet."
			)
			local questIds = {}
			for _, questRow in daily.questRows do
				table.insert(questIds, questRow.dailyQuestId)
			end
			expect(questIds).toEqual(readLatestSnapshot(device.harness).todaysDailyQuestIds)
			device.run(300)
			expect(readLatestSnapshot(device.harness).dailyProgress.playtimeSecondsToday >= 300).toBeTrue()
			local balanceBefore = readLatestSnapshot(device.harness).starCoinBalance
			expect(device.read().dailyRewardsPanel.milestoneRows[1].isClaimButtonVisible).toBeTrue()
			expect(device.lobby:claimPlaytimeMilestone(5)).toBeTrue()
			device.run(0.1)
			expect(readLatestSnapshot(device.harness).starCoinBalance).toBe(balanceBefore + 20)
			local claimed = device.read().dailyRewardsPanel.milestoneRows[1]
			expect(claimed.stateText).toBe("Claimed")
			expect(claimed.isClaimButtonVisible).toBeFalse()
			device.run(1)
			expect(device.lobby:claimPlaytimeMilestone(5)).toBeTrue()
			expect(device.read().dailyRewardsPanel.milestoneRows[1].feedbackText).toBe(
				"You already claimed that reward today."
			)
		end
	)

	it("promo codes and the shop: codes explained, buy a dance and a cosmetic, equip them, never twice", function()
		local device = connectDevice()
		device.lobby:toggleLobbyMenu()
		expect(device.lobby:submitTypedPromoCode("NOPE")).toBeTrue()
		expect(device.read().promoCodePanel.feedbackText).toBe(
			"That code doesn't exist. Check the spelling and try again."
		)
		expect(device.lobby:submitTypedPromoCode("lobbytest")).toBeFalse()
		expect(device.read().promoCodePanel.feedbackText).toBe("Please wait 2 seconds between tries.")
		device.run(2)
		expect(device.lobby:submitTypedPromoCode(" lobbytest ")).toBeTrue()
		device.run(0.1)
		expect(readLatestSnapshot(device.harness).starCoinBalance).toBe(1500)
		expect(device.read().shopPanel.balanceText).toBe("You have 1,500 Star Coins")

		local wave = findShopRow(device.read(), "fixture_wave")
		expect(wave.isBuyButtonEnabled).toBeFalse()
		expect(wave.missingStarCoinsText).toBe("You need 1,500 more Star Coins.")
		expect(device.lobby:buyDance("fixture_spin")).toBeTrue()
		device.run(0.1)
		expect(readLatestSnapshot(device.harness).starCoinBalance).toBe(600)
		local spin = findShopRow(device.read(), "fixture_spin")
		expect(spin.ownershipText).toBe("Owned")
		expect(spin.isBuyButtonVisible).toBeFalse()
		expect(device.lobby:equipDance("fixture_spin")).toBeTrue()
		device.run(0.1)
		expect(findShopRow(device.read(), "fixture_spin").ownershipText).toBe("Your stage dance")
		expect(#device.read().dancesPanel.danceRows).toBe(4)
		device.run(1)
		expect(device.lobby:buyDance("fixture_spin")).toBeTrue()
		expect(findShopRow(device.read(), "fixture_spin").feedbackText).toBe("You already own that dance.")

		expect(device.lobby:buyCosmetic("title_runway_ready")).toBeTrue() -- 900 > 600
		expect(findShopRow(device.read(), "title_runway_ready").feedbackText).toBe(
			"You don't have enough Star Coins for that item yet."
		)
		device.run(1)
		expect(device.lobby:buyCosmetic("title_rising_star")).toBeTrue()
		device.run(0.1)
		expect(readLatestSnapshot(device.harness).starCoinBalance).toBe(300)
		expect(device.lobby:equipCosmetic("title_rising_star")).toBeTrue()
		device.run(0.1)
		local title = findShopRow(device.read(), "title_rising_star")
		expect(title.ownershipText).toBe("Equipped")
		expect(title.feedbackText).toBe("Equipped!")
		expect(readLatestSnapshot(device.harness).equippedCosmeticIdByKind.Title).toBe("title_rising_star")
	end)

	it("lobby outfit: set in the lobby; the menu closes and refuses actions while styling as a participant", function()
		local device = connectDevice()
		device.lobby:toggleLobbyMenu()
		device.lobby:openLobbyPanel("Outfit")
		device.lobby:tapLobbyWardrobeItem(F.HAIR)
		device.lobby:tapLobbyWardrobeItem(F.GLASSES)
		local beforeConfirm = device.read()
		expect(beforeConfirm.previewStylingItemKeys).toEqual({ F.HAIR, F.GLASSES })
		expect(beforeConfirm.purchasePanel.isVisible).toBeTrue()
		expect(beforeConfirm.purchasePanel.explanationText ~= "" or beforeConfirm.purchasePanel.ownershipText ~= "").toBeTrue()
		expect(device.lobby:confirmLobbyOutfit()).toBeTrue()
		device.run(0.1)
		expect(readLatestSnapshot(device.harness).lobbyOutfitStylingItemKeys).toEqual({ F.HAIR, F.GLASSES })
		expect(device.read().lobbyOutfitPanel.confirmFeedbackText).toBe("Your lobby outfit is set.")

		expect(device.roundSession:askToJoinCurrentRound()).toBeTrue()
		device.run(device.harness:secondsUntilPhase("Styling") + 0.05)
		local busy = device.read()
		expect(busy.lobbyMenu.isMenuOpen).toBeFalse()
		expect(busy.lobbyMenu.isMenuButtonVisible).toBeFalse()
		expect(device.lobby:equipDance("starter_sway")).toBeFalse()
		expect(device.lobby:confirmLobbyOutfit()).toBeFalse()
	end)
end)
