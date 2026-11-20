-- The lobby's save snapshot reading (§2.6), its request sending with the §2.13 intervals, and the plain
-- words for every answer of every Phase 2 request (§2.7 to §2.10, §2.14).

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeClock = require("../Support/FakeClock")
local LobbyTestFixtures = require("./LobbyTestFixtures")
local DanceAndCosmeticEquipRequestAnswerer = require("../../src/server/DanceAndCosmeticEquipRequestAnswerer")
local DanceAndCosmeticPurchaseRequestAnswerer = require("../../src/server/DanceAndCosmeticPurchaseRequestAnswerer")
local DeviceLobbyRequestSender = require("../../src/client/DeviceLobbyRequestSender")
local LobbyDanceCoordinator = require("../../src/server/LobbyDanceCoordinator")
local LobbyRequestAnswerTexts = require("../../src/client/LobbyRequestAnswerTexts")
local LobbySaveDataSnapshotReader = require("../../src/client/LobbySaveDataSnapshotReader")
local PromoCodeRedeemer = require("../../src/server/PromoCodeRedeemer")
local SetLobbyOutfitRequestAnswerer = require("../../src/server/SetLobbyOutfitRequestAnswerer")
local StylingItemOwnershipRequestAnswerer = require("../../src/server/StylingItemOwnershipRequestAnswerer")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

describe("LobbySaveDataSnapshotReader", function()
	it("reads the §2.6 fields the lobby shows into fresh tables", function()
		local message = LobbyTestFixtures.buildSnapshotMessage({
			ownedCosmeticIds = { "title_rising_star" },
			equippedCosmeticIdByKind = { Title = "title_rising_star" },
			dailyProgress = { playtimeSecondsToday = 120, dailyQuestProgressCountByQuestId = { complete_rounds_3 = 1 } },
		})
		local snapshot = LobbySaveDataSnapshotReader.readLobbySaveDataSnapshot(message)
		expect(snapshot.shownStarCoinBalance).toBe(500)
		expect(snapshot.equippedDanceId).toBe("starter_groove")
		expect(snapshot.ownedCosmeticIds).toEqual({ "title_rising_star" })
		expect(snapshot.equippedCosmeticIdByKind).toEqual({ Title = "title_rising_star" })
		expect(snapshot.dailyProgress.playtimeSecondsToday).toBe(120)
		expect(snapshot.dailyProgress.dailyQuestProgressCountByQuestId).toEqual({ complete_rounds_3 = 1 })
		expect(snapshot.todaysDailyQuestIds).toEqual(message.todaysDailyQuestIds)
		table.insert(message.ownedCosmeticIds, "changed")
		expect(snapshot.ownedCosmeticIds).toEqual({ "title_rising_star" })
	end)

	it("reads nothing from a message of the wrong shape", function()
		local read = LobbySaveDataSnapshotReader.readLobbySaveDataSnapshot
		expect(read(nil)).toBeNil()
		expect(read(LobbyTestFixtures.buildSnapshotMessage({ starCoinBalance = "500" }))).toBeNil()
		expect(read(LobbyTestFixtures.buildSnapshotMessage({ ownedDanceIds = { 1 } }))).toBeNil()
		expect(read(LobbyTestFixtures.buildSnapshotMessage({ equippedDanceId = 3 }))).toBeNil()
		expect(read(LobbyTestFixtures.buildSnapshotMessage({ equippedCosmeticIdByKind = { Title = 1 } }))).toBeNil()
		expect(read(LobbyTestFixtures.buildSnapshotMessage({ todaysDailyQuestIds = "x" }))).toBeNil()
		expect(read(LobbyTestFixtures.buildSnapshotMessage({ dailyProgress = { playtimeSecondsToday = 0 / 0 } }))).toBeNil()
		expect(read(LobbyTestFixtures.buildSnapshotMessage({ dailyProgress = { claimedDailyQuestIds = { 5 } } }))).toBeNil()
		expect(read(LobbyTestFixtures.buildSnapshotMessage({ unavailableLobbyOutfitStylingItemKeys = false }))).toBeNil()
	end)

	it("accepts a save without an equipped dance", function()
		local message = LobbyTestFixtures.buildSnapshotMessage()
		message.equippedDanceId = nil
		expect(LobbySaveDataSnapshotReader.readLobbySaveDataSnapshot(message).equippedDanceId).toBeNil()
	end)
end)

local function createSender()
	local fakeClock = FakeClock.new(LobbyTestFixtures.START_UNIX_SECONDS)
	local askServer, pendingRequests = LobbyTestFixtures.createRecordingAskServer()
	local changeCount = 0
	local sender = DeviceLobbyRequestSender.new({
		clock = fakeClock,
		askServer = askServer,
		onRequestOutcomeChanged = function()
			changeCount += 1
		end,
	})
	return sender, fakeClock, pendingRequests, function()
		return changeCount
	end
end

describe("DeviceLobbyRequestSender", function()
	it("sends one request per channel at a time and records its answer for the subject", function()
		local sender, _, pendingRequests = createSender()
		expect(sender:sendLobbyRequest("RequestEquipDance", "starter_sway", "starter_sway")).toBe(true)
		expect(pendingRequests[1].remoteChannelName).toBe("RequestEquipDance")
		expect(pendingRequests[1].payload).toBe("starter_sway")
		expect(sender:readLatestLobbyRequestOutcome("RequestEquipDance").isWaitingForAnswer).toBe(true)
		expect(sender:sendLobbyRequest("RequestEquipDance", "starter_bounce", "starter_bounce")).toBe(false)
		expect(#pendingRequests).toBe(1)
		pendingRequests[1].onAnswer({ isAccepted = true })
		local outcome = sender:readLatestLobbyRequestOutcome("RequestEquipDance")
		expect(outcome.requestSubject).toBe("starter_sway")
		expect(outcome.answer).toEqual({ isAccepted = true })
		expect(sender:readSentLobbyRequestCount("RequestEquipDance")).toBe(1)
	end)

	it(
		"waits the channel's §2.13 interval counted from the previous ANSWER, exactly at the interval allowed",
		function()
			local sender, fakeClock, pendingRequests = createSender()
			sender:sendLobbyRequest("RequestRedeemPromoCode", "ABC", "promoCode")
			fakeClock:advanceBySeconds(0.7)
			pendingRequests[1].onAnswer({ isAccepted = false, rejectionReason = "UnknownPromoCode" })
			fakeClock:advanceBySeconds(1.999)
			expect(sender:isLobbyRequestAllowedNow("RequestRedeemPromoCode")).toBe(false)
			expect(sender:readSecondsUntilLobbyRequestAllowed("RequestRedeemPromoCode")).toBeCloseTo(0.001, 1e-6)
			expect(sender:sendLobbyRequest("RequestRedeemPromoCode", "ABC", "promoCode")).toBe(false)
			local refused = sender:readLatestLobbyRequestOutcome("RequestRedeemPromoCode")
			expect(refused.refusedOnDevice).toBe(true)
			expect(refused.answer.rejectionReason).toBe(DeviceLobbyRequestSender.TOO_SOON_ON_DEVICE_REASON)
			expect(#pendingRequests).toBe(1)
			fakeClock:advanceBySeconds(0.001)
			expect(sender:sendLobbyRequest("RequestRedeemPromoCode", "ABC", "promoCode")).toBe(true)
			expect(#pendingRequests).toBe(2)
		end
	)

	it("keeps each channel's interval to itself", function()
		local sender, _, pendingRequests = createSender()
		sender:sendLobbyRequest("RequestEquipDance", "starter_sway", "starter_sway")
		pendingRequests[1].onAnswer({ isAccepted = true })
		expect(sender:sendLobbyRequest("RequestStartDanceInLobby", "starter_sway", "starter_sway")).toBe(true)
		expect(sender:isLobbyRequestAllowedNow("RequestEquipDance")).toBe(false)
	end)

	it("records a failed call as no answer and still starts the interval", function()
		local sender, fakeClock, pendingRequests = createSender()
		sender:sendLobbyRequest("RequestStopDanceInLobby", nil, "stop")
		pendingRequests[1].onAnswer(nil)
		expect(sender:readLatestLobbyRequestOutcome("RequestStopDanceInLobby").answer).toBeNil()
		expect(sender:isLobbyRequestAllowedNow("RequestStopDanceInLobby")).toBe(false)
		fakeClock:advanceBySeconds(0.5)
		expect(sender:isLobbyRequestAllowedNow("RequestStopDanceInLobby")).toBe(true)
	end)

	it("raises for a channel without a §2.13 interval", function()
		local sender = createSender()
		expect(function()
			sender:sendLobbyRequest("RoundStateChanged", nil, nil)
		end).toThrow("is not a rate-limited request channel")
	end)

	it("forgets an answered outcome on request, never one still waiting", function()
		local sender, _, pendingRequests = createSender()
		sender:sendLobbyRequest("SetLobbyOutfit", {}, "lobbyOutfit")
		sender:forgetLatestLobbyRequestOutcome("SetLobbyOutfit")
		expect(sender:readLatestLobbyRequestOutcome("SetLobbyOutfit") ~= nil).toBe(true)
		pendingRequests[1].onAnswer({ isAccepted = true })
		sender:forgetLatestLobbyRequestOutcome("SetLobbyOutfit")
		expect(sender:readLatestLobbyRequestOutcome("SetLobbyOutfit")).toBeNil()
	end)
end)

-- Every rejection reason each server module can answer, read from the server's own tables.
local SERVER_REASONS_BY_CHANNEL = {
	SetLobbyOutfit = SetLobbyOutfitRequestAnswerer.SET_LOBBY_OUTFIT_REJECTION_REASONS,
	RequestPurchaseDanceWithStarCoins = DanceAndCosmeticPurchaseRequestAnswerer.PURCHASE_REJECTION_REASONS,
	RequestPurchaseCosmeticWithStarCoins = DanceAndCosmeticPurchaseRequestAnswerer.PURCHASE_REJECTION_REASONS,
	RequestEquipDance = DanceAndCosmeticEquipRequestAnswerer.EQUIP_REJECTION_REASONS,
	RequestEquipCosmetic = DanceAndCosmeticEquipRequestAnswerer.EQUIP_REJECTION_REASONS,
	RequestStartDanceInLobby = LobbyDanceCoordinator.START_DANCE_IN_LOBBY_REJECTION_REASONS,
	RequestSyncDanceWithPlayer = LobbyDanceCoordinator.SYNC_DANCE_WITH_PLAYER_REJECTION_REASONS,
	RequestStopDanceInLobby = LobbyDanceCoordinator.STOP_DANCE_IN_LOBBY_REJECTION_REASONS,
	RequestClaimPlaytimeMilestone = {
		"UnknownMilestone",
		"MilestoneNotReached",
		"AlreadyClaimed",
		"SaveDataNotLoaded",
		"TooManyRequests",
	},
	RequestClaimDailyQuestReward = {
		"NotTodaysQuest",
		"QuestNotCompleted",
		"AlreadyClaimed",
		"SaveDataNotLoaded",
		"TooManyRequests",
	},
	RequestRedeemPromoCode = PromoCodeRedeemer.PROMO_CODE_REDEMPTION_REJECTION_REASONS,
	RequestStylingItemOwnership = {
		"UnknownStylingItem",
		"TooManyRequests",
		StylingItemOwnershipRequestAnswerer.STYLING_ITEM_OWNERSHIP_REJECTION_REASONS.OwnershipCheckFailed,
	},
}

-- Purchase reasons of the other kind never come back on a channel (UnknownCosmetic on the dance
-- channel); they still get the table's sentence, so they are not skipped.
local function describeRejection(channelName, rejectionReason)
	return LobbyRequestAnswerTexts.describeLobbyRequestOutcome({
		remoteChannelName = channelName,
		isWaitingForAnswer = false,
		answer = { isAccepted = false, rejectionReason = rejectionReason },
	})
end

describe("LobbyRequestAnswerTexts", function()
	it("has its own plain sentence for every rejection reason of every Phase 2 channel", function()
		for channelName, serverReasons in SERVER_REASONS_BY_CHANNEL do
			local channelTexts = LobbyRequestAnswerTexts.REJECTION_TEXT_BY_REASON_BY_REMOTE_CHANNEL_NAME[channelName]
			for _, rejectionReason in serverReasons do
				local isOtherKindPurchaseReason = (
					channelName == "RequestPurchaseDanceWithStarCoins" and rejectionReason == "UnknownCosmetic"
				)
					or (channelName == "RequestPurchaseCosmeticWithStarCoins" and rejectionReason == "UnknownDance")
					or (channelName == "RequestEquipDance" and rejectionReason == "CosmeticNotOwned")
					or (channelName == "RequestEquipCosmetic" and rejectionReason == "DanceNotOwned")
				if not isOtherKindPurchaseReason then
					local text = channelTexts[rejectionReason]
					if text == nil then
						error(string.format("no sentence for %s on %s", rejectionReason, channelName))
					end
					expect(describeRejection(channelName, rejectionReason)).toBe(text)
					expect(text ~= LobbyRequestAnswerTexts.GENERIC_REFUSAL_TEXT).toBe(true)
				end
			end
			expect(channelTexts.RequestFailedOnServer ~= nil).toBe(true)
		end
	end)

	it("explains TargetNotDancing, the 2-second rule and an unknown promo code in plain words", function()
		expect(describeRejection("RequestSyncDanceWithPlayer", "TargetNotDancing")).toBe(
			"That player is not dancing in the lobby right now, so there is nothing to join."
		)
		expect(describeRejection("RequestRedeemPromoCode", "TooManyAttempts")).toBe(
			"Too many tries. Wait 2 seconds between attempts."
		)
		expect(describeRejection("RequestRedeemPromoCode", "UnknownPromoCode")).toBe(
			"That code doesn't exist. Check the spelling and try again."
		)
	end)

	it("explains a device-side too-soon refusal with the channel's own interval", function()
		expect(describeRejection("RequestRedeemPromoCode", DeviceLobbyRequestSender.TOO_SOON_ON_DEVICE_REASON)).toBe(
			"Please wait 2 seconds between tries."
		)
		expect(describeRejection("RequestEquipDance", DeviceLobbyRequestSender.TOO_SOON_ON_DEVICE_REASON)).toBe(
			"Please wait 1 second between tries."
		)
		expect(describeRejection("RequestStartDanceInLobby", DeviceLobbyRequestSender.TOO_SOON_ON_DEVICE_REASON)).toBe(
			"Please wait 0.5 seconds between tries."
		)
	end)

	it("says waiting, no answer, accepted and an unknown reason in their own words", function()
		local describeOutcome = LobbyRequestAnswerTexts.describeLobbyRequestOutcome
		expect(describeOutcome(nil)).toBe("")
		expect(describeOutcome({ remoteChannelName = "RequestEquipDance", isWaitingForAnswer = true })).toBe(
			LobbyRequestAnswerTexts.WAITING_FOR_ANSWER_TEXT
		)
		expect(describeOutcome({ remoteChannelName = "RequestEquipDance", isWaitingForAnswer = false, answer = nil })).toBe(
			LobbyRequestAnswerTexts.GENERIC_NO_ANSWER_TEXT
		)
		expect(describeOutcome({
			remoteChannelName = "RequestPurchaseCosmeticWithStarCoins",
			isWaitingForAnswer = false,
			answer = { isAccepted = true },
		})).toBe("Bought! It will show as yours in a moment.")
		expect(describeRejection("RequestEquipDance", "SomethingNew")).toBe(
			LobbyRequestAnswerTexts.GENERIC_REFUSAL_TEXT
		)
	end)

	it("never states an amount from an accepted answer (balances come only from the snapshot)", function()
		for _, acceptedText in LobbyRequestAnswerTexts.ACCEPTED_TEXT_BY_REMOTE_CHANNEL_NAME do
			expect(string.find(acceptedText, "%d")).toBeNil()
		end
	end)
end)
