-- SetLobbyOutfitRequestAnswerer when the stored lobby outfit holds keys hidden this session
-- (development spec §1.5 "Stored outfits that contain unavailable items": hidden keys are kept;
-- §2.13: setting the current outfit is not a change). Uses the REAL save keeper
-- (LobbyRequestRulesTestHarness).

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local LobbyRequestRulesTestHarness = require("./LobbyRequestRulesTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local FIRST_PLAYER_USER_ID = LobbyRequestRulesTestHarness.FIRST_PLAYER_USER_ID

local PINK_TOP_KEY = "asset_9000011"
local PINK_BAG_KEY = "asset_9000051"

local ACCEPTED = { isAccepted = true }
local function rejectedWith(rejectionReason: string)
	return { isAccepted = false, rejectionReason = rejectionReason }
end

local function createLoadedHarness()
	local harness = LobbyRequestRulesTestHarness.createLobbyRequestRulesHarness()
	harness.loadNewPlayer(FIRST_PLAYER_USER_ID)
	return harness
end

describe("SetLobbyOutfit with stored keys hidden this session (§1.5 'Kept', §2.13 no-op)", function()
	local HIDDEN_HAIR_KEY = FakeStylingItemPool.HIDDEN_HAIR_KEY

	-- Stores { PINK_TOP_KEY, HIDDEN_HAIR_KEY } while the hair is available, then republishes the
	-- catalog without it, so the stored hair is hidden this session (revision 1).
	local function createHarnessWithStoredHiddenHair()
		local harness = createLoadedHarness()
		local availableWithHair = table.clone(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
		availableWithHair[HIDDEN_HAIR_KEY] = true
		harness.fakeResolver:publishWardrobeCatalog(availableWithHair)
		assert(
			harness.sendSetLobbyOutfit(
				FIRST_PLAYER_USER_ID,
				{ outfitStylingItemKeys = { PINK_TOP_KEY, HIDDEN_HAIR_KEY } }
			).isAccepted,
			"storing the outfit should be accepted"
		)
		harness.fakeResolver:publishWardrobeCatalog(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
		return harness
	end

	it("re-sending exactly the stored outfit is accepted and changes nothing", function()
		local harness = createHarnessWithStoredHiddenHair()
		local changedEventCountBefore = harness.countSaveKeeperEvents("InMemorySaveDataChanged")
		expect(
			harness.sendSetLobbyOutfit(
				FIRST_PLAYER_USER_ID,
				{ outfitStylingItemKeys = { PINK_TOP_KEY, HIDDEN_HAIR_KEY } }
			)
		).toEqual(ACCEPTED)
		expect(harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)).toEqual({ PINK_TOP_KEY, HIDDEN_HAIR_KEY })
		expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(1)
		expect(harness.countSaveKeeperEvents("InMemorySaveDataChanged")).toBe(changedEventCountBefore)
	end)

	it("sending the wearable part (what the device shows) is accepted and keeps the hidden key", function()
		local harness = createHarnessWithStoredHiddenHair()
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })).toEqual(
			ACCEPTED
		)
		expect(harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)).toEqual({ PINK_TOP_KEY, HIDDEN_HAIR_KEY })
		expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(1)
	end)

	it("a different valid outfit replaces the whole stored list, dropping the hidden key (decided)", function()
		local harness = createHarnessWithStoredHiddenHair()
		expect(
			harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY, PINK_BAG_KEY } })
		).toEqual(ACCEPTED)
		expect(harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)).toEqual({ PINK_TOP_KEY, PINK_BAG_KEY })
		expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(2)
	end)

	it("the stored keys in another order, or the hidden key alone, are still validated: OutfitInvalid", function()
		local harness = createHarnessWithStoredHiddenHair()
		expect(
			harness.sendSetLobbyOutfit(
				FIRST_PLAYER_USER_ID,
				{ outfitStylingItemKeys = { HIDDEN_HAIR_KEY, PINK_TOP_KEY } }
			)
		).toEqual(rejectedWith("OutfitInvalid"))
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { HIDDEN_HAIR_KEY } })).toEqual(
			rejectedWith("OutfitInvalid")
		)
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = {} })).toEqual(ACCEPTED)
		expect(harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)).toEqual({})
	end)

	it("once the hidden key is available again, sending the outfit without it is a real change", function()
		local harness = createHarnessWithStoredHiddenHair()
		local availableWithHair = table.clone(FakeStylingItemPool.FAKE_AVAILABLE_STYLING_ITEM_KEY_SET)
		availableWithHair[HIDDEN_HAIR_KEY] = true
		harness.fakeResolver:publishWardrobeCatalog(availableWithHair)
		expect(harness.sendSetLobbyOutfit(FIRST_PLAYER_USER_ID, { outfitStylingItemKeys = { PINK_TOP_KEY } })).toEqual(
			ACCEPTED
		)
		expect(harness.readInMemoryLobbyOutfit(FIRST_PLAYER_USER_ID)).toEqual({ PINK_TOP_KEY })
		expect(harness.readInMemoryChangeRevision(FIRST_PLAYER_USER_ID)).toBe(2)
	end)
end)
