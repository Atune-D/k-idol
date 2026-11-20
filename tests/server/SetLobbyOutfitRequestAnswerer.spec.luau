-- SetLobbyOutfitRequestAnswerer (development spec §2.7, §2.13, §2.14, §3.4): every acceptance and
-- rejection reason, the order of the checks, the no-op rule, the server's own copy of the
-- outfit, and the wiring to StoredLobbyOutfitKeeper's availability subscription. Uses the REAL
-- save keeper, rate limiter and stored-outfit keeper (LobbyRequestRulesTestHarness).

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local PlayerSaveDataKeeper = require("../../src/server/PlayerSaveDataKeeper")
local SetLobbyOutfitRequestAnswerer = require("../../src/server/SetLobbyOutfitRequestAnswerer")
local LobbyRequestRulesTestHarness = require("./LobbyRequestRulesTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local FIRST_PLAYER_USER_ID = LobbyRequestRulesTestHarness.FIRST_PLAYER_USER_ID
local SECOND_PLAYER_USER_ID = LobbyRequestRulesTestHarness.SECOND_PLAYER_USER_ID
local createLobbyRequestRulesHarness = LobbyRequestRulesTestHarness.createLobbyRequestRulesHarness

local PINK_HAIR_KEY = "asset_9000001"
local PINK_TOP_KEY = "asset_9000011"
local BLACK_BOTTOM_KEY = "asset_9000021"
local WHITE_SHOES_KEY = "bundle_9000041"
local RED_DRESS_KEY = "asset_9000031"
local PINK_BAG_KEY = "asset_9000051"

local ACCEPTED = { isAccepted = true }
local function rejectedWith(rejectionReason: string)
	return { isAccepted = false, rejectionReason = rejectionReason }
end

local function createLoadedHarness(options: { [string]: any }?)
	local harness = createLobbyRequestRulesHarness(options)
	harness.loadNewPlayer(FIRST_PLAYER_USER_ID)
	return harness
end

describe("SetLobbyOutfit acceptance (§2.7)", function()
	it("stores a valid outfit as an appearance change: revision +1, no save requested", function()
		local harness = createLoadedHarness()
		local answer = harness.sendSetLobbyOutfit(
			FIRST_PLAYER_USER_ID,
			{ outfitStylingItemKeys = { PINK_TOP_KEY, WHITE_SHOES_KEY } }
		)
		expect(answer).toEqual(ACCEPTED)
		expect(harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)).toEqual({ PINK_TOP_KEY, WHITE_SHOES_KEY })
		expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(1)
		harness.advanceSeconds(60) -- well before the 120 s periodic save
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(FIRST_PLAYER_USER_ID)).toBe(0)
	end)

	it("keeps the order the keys were sent in", function()
		local harness = createLoadedHarness()
		harness.sendSetLobbyOutfit(
			FIRST_PLAYER_USER_ID,
			{ outfitStylingItemKeys = { PINK_BAG_KEY, PINK_HAIR_KEY, BLACK_BOTTOM_KEY } }
		)
		expect(harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)).toEqual({
			PINK_BAG_KEY,
			PINK_HAIR_KEY,
			BLACK_BOTTOM_KEY,
		})
	end)

	it("accepts the empty outfit (the player's own avatar) and stores it", function()
		local harness = createLoadedHarness()
		harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = {} })).toEqual(ACCEPTED)
		expect(harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)).toEqual({})
		expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(2)
	end)

	it("the stored list is the server's own copy: changing the device table afterwards changes nothing", function()
		local harness = createLoadedHarness()
		local deviceOutfitStylingItemKeys = { PINK_TOP_KEY, BLACK_BOTTOM_KEY }
		harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = deviceOutfitStylingItemKeys })
		deviceOutfitStylingItemKeys[1] = FakeStylingItemPool.HIDDEN_HAIR_KEY
		deviceOutfitStylingItemKeys[3] = "asset_9000052"
		expect(harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)).toEqual({ PINK_TOP_KEY, BLACK_BOTTOM_KEY })
		expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(1)
	end)

	it("ignores other fields of the request", function()
		local harness = createLoadedHarness()
		local answer = harness.sendSetLobbyOutfit(
			FIRST_PLAYER_USER_ID,
			{ outfitStylingItemKeys = { PINK_TOP_KEY }, starCoinBalance = 999999, extra = string.rep("x", 100000) }
		)
		expect(answer).toEqual(ACCEPTED)
		local saveDataCopy = harness.playerSaveDataKeeper:readPlayerSaveDataCopy(FIRST_PLAYER_USER_ID)
		expect(saveDataCopy.starCoinBalance).toBe(0)
		expect(saveDataCopy.lobbyOutfitStylingItemKeys).toEqual({ PINK_TOP_KEY })
	end)

	it("builds a fresh answer table for every request", function()
		local harness = createLoadedHarness()
		local firstAnswer = harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = {} })
		local secondAnswer = harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = {} })
		expect(firstAnswer ~= secondAnswer).toBeTrue()
		local firstRejection = harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, nil)
		local secondRejection = harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, nil)
		expect(firstRejection ~= secondRejection).toBeTrue()
		firstRejection.rejectionReason = "changed by a caller"
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, nil)).toEqual(rejectedWith("OutfitInvalid"))
	end)

	it(
		"is accepted when the round question answers false (no participant, or ThemeReveal, Results, Intermission)",
		function()
			local harness = createLoadedHarness()
			harness.stylingOrShowcaseParticipantAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = false
			expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })).toEqual(
				ACCEPTED
			)
			expect(harness.askedStylingOrShowcaseParticipantUserIds).toEqual({ FIRST_PLAYER_USER_ID })
		end
	)
end)

describe("SetLobbyOutfit no-op rule (§2.13 second hard rule)", function()
	it("setting the stored outfit again is accepted with no revision bump, no event and no save", function()
		local harness = createLoadedHarness()
		harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY, WHITE_SHOES_KEY } })
		local changedEventCountBefore = harness.countSaveKeeperEvents("InMemorySaveDataChanged")
		local answer = harness.sendSetLobbyOutfit(
			FIRST_PLAYER_USER_ID,
			{ outfitStylingItemKeys = { PINK_TOP_KEY, WHITE_SHOES_KEY } }
		)
		expect(answer).toEqual(ACCEPTED)
		expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(1)
		expect(harness.countSaveKeeperEvents("InMemorySaveDataChanged")).toBe(changedEventCountBefore)
		expect(harness.fakePlayerSaveDataStorage:countPendingOperations(FIRST_PLAYER_USER_ID)).toBe(0)
	end)

	it("the empty outfit of a new player is already stored: accepted, nothing changes", function()
		local harness = createLoadedHarness()
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = {} })).toEqual(ACCEPTED)
		expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(0)
		expect(harness.countSaveKeeperEvents("InMemorySaveDataChanged")).toBe(0)
	end)

	it("the same keys in another order are a change (the stored order is the dressing order)", function()
		local harness = createLoadedHarness()
		harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY, WHITE_SHOES_KEY } })
		harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { WHITE_SHOES_KEY, PINK_TOP_KEY } })
		expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(2)
		expect(harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)).toEqual({ WHITE_SHOES_KEY, PINK_TOP_KEY })
	end)
end)

describe("SetLobbyOutfit rate limit (§2.13, 2 s)", function()
	it("a second request within 2 s is TooManyRequests, looks at nothing else and changes nothing", function()
		local harness = createLoadedHarness()
		local answerer = harness.setLobbyOutfitRequestAnswerer
		harness.advanceSeconds(1)
		expect(answerer:answerSetLobbyOutfitRequest(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = {} })).toEqual(
			ACCEPTED
		)
		local askedCountBefore = #harness.askedStylingOrShowcaseParticipantUserIds
		harness.advanceSeconds(1.999)
		local answer =
			answerer:answerSetLobbyOutfitRequest(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })
		expect(answer).toEqual(rejectedWith("TooManyRequests"))
		expect(#harness.askedStylingOrShowcaseParticipantUserIds).toBe(askedCountBefore)
		expect(harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)).toEqual({})
		expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(0)
	end)

	it("a request at exactly 2 s after the last accepted one is accepted", function()
		local harness = createLoadedHarness()
		local answerer = harness.setLobbyOutfitRequestAnswerer
		answerer:answerSetLobbyOutfitRequest(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = {} })
		harness.advanceSeconds(2)
		local answer =
			answerer:answerSetLobbyOutfitRequest(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })
		expect(answer).toEqual(ACCEPTED)
	end)

	it("is asked first: even a player whose save is not loaded gets TooManyRequests", function()
		local harness = createLobbyRequestRulesHarness()
		local answerer = harness.setLobbyOutfitRequestAnswerer
		expect(answerer:answerSetLobbyOutfitRequest(FIRST_PLAYER_USER_ID, nil)).toEqual(
			rejectedWith("SaveDataNotLoaded")
		)
		expect(answerer:answerSetLobbyOutfitRequest(FIRST_PLAYER_USER_ID, nil)).toEqual(rejectedWith("TooManyRequests"))
	end)

	it("uses the SetLobbyOutfit channel: other channels and other players are independent", function()
		local harness = createLoadedHarness()
		harness.loadNewPlayer(SECOND_PLAYER_USER_ID)
		local answerer = harness.setLobbyOutfitRequestAnswerer
		expect(answerer:answerSetLobbyOutfitRequest(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = {} })).toEqual(
			ACCEPTED
		)
		expect(answerer:answerSetLobbyOutfitRequest(SECOND_PLAYER_USER_ID, { outfitStylingItemKeys = {} })).toEqual(
			ACCEPTED
		)
		expect(
			harness.playerRequestRateLimiter:admitOrRefusePlayerRequest(FIRST_PLAYER_USER_ID, "SetLobbyOutfit").isRequestAllowed
		).toBeFalse()
		expect(
			harness.playerRequestRateLimiter:admitOrRefusePlayerRequest(FIRST_PLAYER_USER_ID, "RequestEquipDance").isRequestAllowed
		).toBeTrue()
	end)
end)

describe("SetLobbyOutfit SaveDataNotLoaded (§3.4)", function()
	it("is refused before the save has loaded", function()
		local harness = createLobbyRequestRulesHarness()
		harness.playerSaveDataKeeper:startLoadingPlayerSaveData(FIRST_PLAYER_USER_ID) -- still loading
		local answer = harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = {} })
		expect(answer).toEqual(rejectedWith("SaveDataNotLoaded"))
		expect(harness.askedStylingOrShowcaseParticipantUserIds).toEqual({})
	end)

	it("is refused once the player has started leaving", function()
		local harness = createLoadedHarness()
		harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(FIRST_PLAYER_USER_ID)
		local answer = harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })
		expect(answer).toEqual(rejectedWith("SaveDataNotLoaded"))
	end)

	it("is the answer when the save keeper itself reports SaveDataNotLoaded for the change", function()
		-- Stand-in: the real keeper cannot be "loaded" and then refuse the change within one call.
		local harness = createLoadedHarness({
			replacementSaveKeeperMethodsByName = {
				applyChangeToPlayerSaveData = function()
					return { changeOutcome = "SaveDataNotLoaded" }
				end,
			},
		})
		local answer = harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })
		expect(answer).toEqual(rejectedWith("SaveDataNotLoaded"))
	end)

	it("is the answer, without raising, when the player starts leaving during the round question", function()
		local harness = createLoadedHarness()
		harness.stylingOrShowcaseParticipantAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = function(playerUserId)
			harness.playerSaveDataKeeper:startFinalSaveForLeavingPlayer(playerUserId)
			return false
		end
		local didAnswer, answerOrError =
			pcall(harness.sendSetLobbyOutfit, FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })
		expect(didAnswer).toBeTrue()
		expect(answerOrError).toEqual(rejectedWith("SaveDataNotLoaded"))
	end)

	it("stores through the keeper as an appearance change described as 'set lobby outfit'", function()
		local recordedChangeCalls = {}
		local harness = createLoadedHarness({
			replacementSaveKeeperMethodsByName = {
				applyChangeToPlayerSaveData = function(_, playerUserId, changeKind, changeDescription)
					table.insert(recordedChangeCalls, { playerUserId, changeKind, changeDescription })
					return { changeOutcome = "Applied" }
				end,
			},
		})
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })).toEqual(
			ACCEPTED
		)
		expect(SetLobbyOutfitRequestAnswerer.SET_LOBBY_OUTFIT_CHANGE_DESCRIPTION).toBe("set lobby outfit")
		expect(recordedChangeCalls).toEqual({
			{ FIRST_PLAYER_USER_ID, PlayerSaveDataKeeper.APPEARANCE_CHANGE_SAVED_LATER, "set lobby outfit" },
		})
	end)

	it("accepts the keeper's AppliedWithoutAnyDifference outcome (a draft equal to the save)", function()
		local harness = createLoadedHarness({
			replacementSaveKeeperMethodsByName = {
				applyChangeToPlayerSaveData = function()
					return { changeOutcome = "AppliedWithoutAnyDifference" }
				end,
			},
		})
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })).toEqual(
			ACCEPTED
		)
	end)

	it("raises on a save change outcome that cannot happen (a programming error)", function()
		local harness = createLoadedHarness({
			replacementSaveKeeperMethodsByName = {
				applyChangeToPlayerSaveData = function()
					return { changeOutcome = "Declined", declineReason = "stand-in" }
				end,
			},
		})
		expect(function()
			harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })
		end).toThrow("unexpected save change outcome Declined")
	end)
end)

describe("SetLobbyOutfit NotAllowedDuringRound (§2.7: Styling or Showcase participant)", function()
	it("refuses a Styling or Showcase participant and changes nothing", function()
		local harness = createLoadedHarness()
		harness.stylingOrShowcaseParticipantAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = true
		local answer = harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })
		expect(answer).toEqual(rejectedWith("NotAllowedDuringRound"))
		expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(0)
		expect(harness.askedStylingOrShowcaseParticipantUserIds).toEqual({ FIRST_PLAYER_USER_ID })
	end)

	it("treats an answer that is not false (nil, a string) as busy", function()
		local harness = createLoadedHarness()
		harness.stylingOrShowcaseParticipantAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = "yes"
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = {} })).toEqual(
			rejectedWith("NotAllowedDuringRound")
		)
		local nilAnsweringHarness = createLoadedHarness()
		nilAnsweringHarness.stylingOrShowcaseParticipantAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = function()
			return nil
		end
		expect(nilAnsweringHarness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = {} })).toEqual(
			rejectedWith("NotAllowedDuringRound")
		)
	end)

	it("is checked after SaveDataNotLoaded and before the catalog and the outfit", function()
		local harness = createLobbyRequestRulesHarness({ isCatalogLeftNotReady = true })
		harness.stylingOrShowcaseParticipantAnswerByPlayerUserId[FIRST_PLAYER_USER_ID] = true
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, nil)).toEqual(rejectedWith("SaveDataNotLoaded"))
		harness.loadNewPlayer(FIRST_PLAYER_USER_ID)
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, nil)).toEqual(rejectedWith("NotAllowedDuringRound"))
	end)

	it("asks only about the sending player", function()
		local harness = createLoadedHarness()
		harness.stylingOrShowcaseParticipantAnswerByPlayerUserId[SECOND_PLAYER_USER_ID] = true
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = {} })).toEqual(ACCEPTED)
	end)
end)

describe("SetLobbyOutfit WardrobeCatalogNotReady (§2.14)", function()
	it("refuses while the catalog is not ready, even the empty outfit, and changes nothing", function()
		local harness = createLoadedHarness({ isCatalogLeftNotReady = true })
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = {} })).toEqual(
			rejectedWith("WardrobeCatalogNotReady")
		)
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, nil)).toEqual(rejectedWith("WardrobeCatalogNotReady"))
		expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(0)
	end)

	it("accepts once the catalog has been published", function()
		local harness = createLoadedHarness({ isCatalogLeftNotReady = true })
		harness.fakeResolver:publishWardrobeCatalog(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })).toEqual(
			ACCEPTED
		)
	end)

	it("validates against the catalog the server last published", function()
		local harness = createLoadedHarness()
		local availableWithoutPinkTop = table.clone(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
		availableWithoutPinkTop[PINK_TOP_KEY] = nil
		harness.fakeResolver:publishWardrobeCatalog(availableWithoutPinkTop)
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })).toEqual(
			rejectedWith("OutfitInvalid")
		)
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { BLACK_BOTTOM_KEY } })).toEqual(
			ACCEPTED
		)
	end)
end)

describe("SetLobbyOutfit OutfitInvalid (§1.5)", function()
	local INVALID_OUTFITS = {
		{ "a hidden item", { FakeStylingItemPool.HIDDEN_HAIR_KEY } },
		{ "a key not in the pool", { FakeStylingItemPool.KEY_NOT_IN_POOL } },
		{ "a disabled item", { FakeStylingItemPool.DISABLED_HAIR_KEY } },
		{ "a repeated key", { PINK_TOP_KEY, PINK_TOP_KEY } },
		{ "two items in one single-item slot", { PINK_HAIR_KEY, "asset_9000002" } },
		{ "four accessories", { "asset_9000051", "asset_9000052", "asset_9000053", "asset_9000054" } },
		{ "a dress with a top", { RED_DRESS_KEY, PINK_TOP_KEY } },
		{ "a dress with a bottom", { RED_DRESS_KEY, BLACK_BOTTOM_KEY } },
	}
	for _, invalidOutfitCase in INVALID_OUTFITS do
		it("refuses " .. invalidOutfitCase[1] .. " and changes nothing", function()
			local harness = createLoadedHarness()
			harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { WHITE_SHOES_KEY } })
			local answer =
				harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = invalidOutfitCase[2] })
			expect(answer).toEqual(rejectedWith("OutfitInvalid"))
			expect(harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)).toEqual({ WHITE_SHOES_KEY })
			expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(1)
		end)
	end
end)

describe("SetLobbyOutfit wiring to StoredLobbyOutfitKeeper (§2.7 'the server dresses the character')", function()
	it("an accepted outfit reaches the availability-changed subscription as the wearable outfit", function()
		local harness = createLoadedHarness()
		local availabilityChangedRecords = {}
		harness.storedLobbyOutfitKeeper:subscribeToStoredLobbyOutfitAvailabilityChanged(
			function(playerUserId, availability)
				table.insert(availabilityChangedRecords, { playerUserId = playerUserId, availability = availability })
			end
		)
		harness.sendSetLobbyOutfit(
			FIRST_PLAYER_USER_ID,
			{ outfitStylingItemKeys = { PINK_TOP_KEY, BLACK_BOTTOM_KEY, PINK_BAG_KEY } }
		)
		expect(availabilityChangedRecords).toEqual({
			{
				playerUserId = FIRST_PLAYER_USER_ID,
				availability = {
					isWardrobeCatalogReady = true,
					lobbyOutfitStylingItemKeys = { PINK_TOP_KEY, BLACK_BOTTOM_KEY, PINK_BAG_KEY },
					unavailableLobbyOutfitStylingItemKeys = {},
					wearableLobbyOutfitStylingItemKeys = { PINK_TOP_KEY, BLACK_BOTTOM_KEY, PINK_BAG_KEY },
				},
			},
		})
	end)

	it("a no-op or refused request does not reach the subscription", function()
		local harness = createLoadedHarness()
		harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })
		local availabilityChangedCount = 0
		harness.storedLobbyOutfitKeeper:subscribeToStoredLobbyOutfitAvailabilityChanged(function()
			availabilityChangedCount += 1
		end)
		harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })
		harness.sendSetLobbyOutfit(
			FIRST_PLAYER_USER_ID,
			{ outfitStylingItemKeys = { FakeStylingItemPool.HIDDEN_HAIR_KEY } }
		)
		expect(availabilityChangedCount).toBe(0)
		expect(
			harness.storedLobbyOutfitKeeper:readStoredLobbyOutfitAvailability(FIRST_PLAYER_USER_ID).wearableLobbyOutfitStylingItemKeys
		).toEqual({ PINK_TOP_KEY })
	end)
end)

describe("SetLobbyOutfitRequestAnswerer.new", function()
	it("raises when a dependency is missing", function()
		for _, missingDependencyName in
			{
				"playerSaveDataKeeper",
				"playerRequestRateLimiter",
				"marketplaceStylingItemResolver",
				"stylingItemByStylingItemKey",
				"isPlayerStylingOrShowcaseParticipant",
			}
		do
			local dependencies = {
				playerSaveDataKeeper = {},
				playerRequestRateLimiter = {},
				marketplaceStylingItemResolver = {},
				stylingItemByStylingItemKey = {},
				isPlayerStylingOrShowcaseParticipant = function()
					return false
				end,
			}
			dependencies[missingDependencyName] = nil
			expect(function()
				SetLobbyOutfitRequestAnswerer.new(dependencies)
			end).toThrow("missing dependency " .. missingDependencyName)
		end
	end)

	it("lists exactly the §2.7 rejection reasons", function()
		local listedRejectionReasons = {}
		for _, rejectionReason in SetLobbyOutfitRequestAnswerer.SET_LOBBY_OUTFIT_REJECTION_REASONS do
			table.insert(listedRejectionReasons, rejectionReason)
		end
		table.sort(listedRejectionReasons)
		expect(listedRejectionReasons).toEqual({
			"NotAllowedDuringRound",
			"OutfitInvalid",
			"SaveDataNotLoaded",
			"TooManyRequests",
			"WardrobeCatalogNotReady",
		})
		expect(table.isfrozen(SetLobbyOutfitRequestAnswerer.SET_LOBBY_OUTFIT_REJECTION_REASONS)).toBeTrue()
	end)
end)
