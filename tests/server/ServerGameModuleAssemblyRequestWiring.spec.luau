-- The whole server assembled as ServerMain assembles it (on fakes), driven through the request
-- router the way a device drives it through the remote channels.

local UnitTestFramework = require("../Support/UnitTestFramework")
local ServerGameAssemblyTestHarness = require("./ServerGameAssemblyTestHarness")
local DeviceRequestChannelAnswerRouter = require("../../src/server/DeviceRequestChannelAnswerRouter")
local RemoteNames = require("../../src/shared/RemoteNames")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER = 2421377719
local OTHER_PLAYER = 1001

-- One request per request channel, with a payload that reaches the module's own checks.
local EXAMPLE_PAYLOAD_BY_REQUEST_CHANNEL = {
	RequestJoinCurrentRound = nil,
	RequestWardrobeCatalogSnapshot = nil,
	RequestStylingItemOwnership = "asset_7259123616",
	RequestFanCountLeaderboardTopEntries = nil,
	SetLobbyOutfit = { outfitStylingItemKeys = { "asset_7259123616" } },
	RequestPurchaseDanceWithStarCoins = "starter_groove",
	RequestPurchaseCosmeticWithStarCoins = "no_such_cosmetic",
	RequestEquipDance = "starter_groove",
	RequestEquipCosmetic = "no_such_cosmetic",
	RequestStartDanceInLobby = "starter_groove",
	RequestSyncDanceWithPlayer = OTHER_PLAYER,
	RequestStopDanceInLobby = nil,
	RequestClaimPlaytimeMilestone = 5,
	RequestClaimDailyQuestReward = "no_such_quest",
	RequestRedeemPromoCode = "NOSUCHCODE",
}

local function listRequestChannelNames(): { string }
	local requestChannelNames = {}
	for remoteChannelName, remoteChannelKind in RemoteNames.REMOTE_CHANNEL_KIND_BY_REMOTE_CHANNEL_NAME do
		if remoteChannelKind == RemoteNames.REMOTE_CHANNEL_KINDS.DeviceRequestWithServerAnswer then
			table.insert(requestChannelNames, remoteChannelName)
		end
	end
	table.sort(requestChannelNames)
	return requestChannelNames
end

local function createServerWithLoadedPlayer()
	local harness = ServerGameAssemblyTestHarness.createStartedServer()
	harness:joinPlayer(PLAYER)
	harness:advance(1)
	return harness
end

describe("ServerGameModuleAssembly request wiring", function()
	it("routes exactly the request channels of RemoteNames", function()
		local routedChannelNames = {}
		for routedChannelName in DeviceRequestChannelAnswerRouter.DEVICE_REQUEST_ROUTES do
			table.insert(routedChannelNames, routedChannelName)
		end
		table.sort(routedChannelNames)
		expect(routedChannelNames).toEqual(listRequestChannelNames())
		expect(#routedChannelNames).toBe(15)
	end)

	for _, requestChannelName in listRequestChannelNames() do
		it("asks the rate limiter exactly once for one " .. requestChannelName .. " request", function()
			local harness = createServerWithLoadedPlayer()
			local answer =
				harness:ask(requestChannelName, PLAYER, EXAMPLE_PAYLOAD_BY_REQUEST_CHANNEL[requestChannelName])
			expect(type(answer)).toBe("table")
			expect(harness.admitCallCountByPlayerAndChannel[PLAYER .. "/" .. requestChannelName]).toBe(1)
		end)

		it(
			"refuses a second " .. requestChannelName .. " request sent at once, and that refusal changes nothing",
			function()
				local harness = createServerWithLoadedPlayer()
				harness:ask(requestChannelName, PLAYER, EXAMPLE_PAYLOAD_BY_REQUEST_CHANNEL[requestChannelName])
				local revisionBefore = harness.modules.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)
				local saveBefore = harness.modules.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)
				local secondAnswer =
					harness:ask(requestChannelName, PLAYER, EXAMPLE_PAYLOAD_BY_REQUEST_CHANNEL[requestChannelName])
				local expectedReason = if requestChannelName == "RequestRedeemPromoCode"
					then "TooManyAttempts"
					else "TooManyRequests"
				expect(secondAnswer).toEqual({ isAccepted = false, rejectionReason = expectedReason })
				expect(harness.modules.playerSaveDataKeeper:readSaveChangeRevisions(PLAYER)).toBe(revisionBefore)
				expect(harness.modules.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER)).toEqual(saveBefore)
			end
		)
	end

	it("never asks the rate limiter for an outfit draft", function()
		local harness = createServerWithLoadedPlayer()
		harness:sendDraft(PLAYER, { roundId = "anything", outfitDraftSequenceNumber = 1, outfitStylingItemKeys = {} })
		expect(harness.admitCallCountByPlayerAndChannel[PLAYER .. "/SetRoundOutfitDraft"]).toBeNil()
	end)

	it("answers the wardrobe snapshot with the seven development items once the catalog is ready", function()
		local harness = createServerWithLoadedPlayer()
		local answer = harness:ask("RequestWardrobeCatalogSnapshot", PLAYER)
		expect(answer.isAccepted).toBeTrue()
		expect(answer.isWardrobeCatalogReady).toBeTrue()
		expect(answer.wardrobeCatalogVersion).toBe(1)
		expect(#answer.wardrobeItems).toBe(7)
		expect(harness:listSent("WardrobeCatalogChanged")).toEqual({
			{ isWardrobeCatalogReady = true, wardrobeCatalogVersion = 1 },
		})
	end)

	it("answers an ownership request through the resolver's callback, also when the answer comes later", function()
		local harness = createServerWithLoadedPlayer()
		expect(harness:ask("RequestStylingItemOwnership", PLAYER, "asset_7259123616")).toEqual({
			isAccepted = true,
			isOwnedByPlayer = false,
		})
		harness.marketplaceItemLookups:setOwnedMarketplaceItem(OTHER_PLAYER, "Bundle", 98186475028072)
		harness:joinPlayer(OTHER_PLAYER)
		harness.marketplaceItemLookups:holdOwnershipAnswers()
		local laterAnswers = {}
		harness.modules.deviceRequestChannelAnswerRouter:startAnsweringDeviceRequest(
			"RequestStylingItemOwnership",
			OTHER_PLAYER,
			"bundle_98186475028072",
			function(answer)
				table.insert(laterAnswers, answer)
			end
		)
		expect(#laterAnswers).toBe(0)
		harness.marketplaceItemLookups:releaseHeldOwnershipAnswers()
		expect(laterAnswers).toEqual({ { isAccepted = true, isOwnedByPlayer = true } })
		harness:advance(0.5)
		expect(harness:ask("RequestStylingItemOwnership", PLAYER, 12)).toEqual({
			isAccepted = false,
			rejectionReason = "UnknownStylingItem",
		})
	end)

	it("answers the leaderboard request in the §2 answer shape", function()
		local harness = createServerWithLoadedPlayer()
		local answer = harness:ask("RequestFanCountLeaderboardTopEntries", PLAYER)
		expect(answer.isAccepted).toBeTrue()
		expect(answer.refreshedAtUnixSeconds).toBe(ServerGameAssemblyTestHarness.SERVER_START_UNIX_SECONDS)
		expect(answer.leaderboardEntries).toEqual({})
	end)

	it("sends the save snapshot once after loading, and RoundStateChanged to the joining player", function()
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		harness:joinPlayer(PLAYER)
		local snapshots = harness:listSent("PlayerSaveDataSnapshotChanged", PLAYER)
		expect(#snapshots).toBe(1)
		expect(snapshots[1].starCoinBalance).toBe(0)
		expect(snapshots[1].equippedDanceId).toBe("starter_groove")
		local roundStatesToPlayer = harness:listSent("RoundStateChanged", PLAYER)
		expect(#roundStatesToPlayer).toBe(1)
		expect(roundStatesToPlayer[1].roundPhase).toBe("ThemeReveal")
	end)

	it("answers every Phase 2 request through its module (the shapes their headers give)", function()
		local harness = createServerWithLoadedPlayer()
		expect(harness:ask("RequestClaimPlaytimeMilestone", PLAYER, 5)).toEqual({
			isAccepted = false,
			rejectionReason = "MilestoneNotReached",
		})
		expect(harness:ask("RequestEquipDance", PLAYER, "starter_groove")).toEqual({ isAccepted = true })
		expect(harness:ask("RequestPurchaseCosmeticWithStarCoins", PLAYER, "title_rising_star").rejectionReason).toBe(
			"InsufficientStarCoins"
		)
		expect(harness:ask("RequestRedeemPromoCode", PLAYER, "NOSUCHCODE")).toEqual({
			isAccepted = false,
			rejectionReason = "UnknownPromoCode",
		})
		expect(harness:ask("SetLobbyOutfit", PLAYER, { outfitStylingItemKeys = { "asset_7259123616" } })).toEqual({
			isAccepted = true,
		})
		expect(harness:ask("RequestStartDanceInLobby", PLAYER, "starter_bounce")).toEqual({ isAccepted = true })
		harness:advance(0.5)
		expect(harness:ask("RequestStopDanceInLobby", PLAYER)).toEqual({ isAccepted = true })
		expect(harness:ask("RequestClaimDailyQuestReward", PLAYER, "no_such_quest")).toEqual({
			isAccepted = false,
			rejectionReason = "NotTodaysQuest",
		})
		expect(harness.modules.playerSaveDataKeeper:readPlayerSaveDataCopy(PLAYER).lobbyOutfitStylingItemKeys).toEqual({
			"asset_7259123616",
		})
	end)

	it(
		"answers RequestFailedOnServer and logs when a module raises, instead of leaving the device without an answer",
		function()
			local harness = createServerWithLoadedPlayer()
			harness.modules.lobbyDanceCoordinator.answerStopDanceInLobbyRequest = function()
				error("deliberate module failure")
			end
			expect(harness:ask("RequestStopDanceInLobby", PLAYER)).toEqual({
				isAccepted = false,
				rejectionReason = "RequestFailedOnServer",
			})
			expect(harness.logger:countWarningsContaining("deliberate module failure")).toBe(1)
		end
	)

	it("raises naming a missing answering module", function()
		expect(function()
			DeviceRequestChannelAnswerRouter.new({ logger = {} })
		end).toThrow("missing playerRequestRateLimiter")
	end)

	it("logs a raise inside the referee's draft handling instead of passing it to the caller", function()
		local harness = createServerWithLoadedPlayer()
		harness.modules.themedRoundReferee.receiveSetRoundOutfitDraftFromDevice = function()
			error("deliberate draft failure")
		end
		harness:sendDraft(PLAYER, {})
		expect(harness.logger:countWarningsContaining("deliberate draft failure")).toBe(1)
	end)

	it("raises for a channel that is not a request channel (a wiring error)", function()
		local harness = createServerWithLoadedPlayer()
		expect(function()
			harness:ask("RoundStateChanged", PLAYER)
		end).toThrow("is not a device request channel")
		expect(function()
			harness.modules.deviceRequestChannelAnswerRouter:receiveDeviceMessageWithoutAnswer(
				"SetLobbyOutfit",
				PLAYER,
				{}
			)
		end).toThrow("is not a device message channel")
	end)
end)
