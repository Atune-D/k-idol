-- LobbyDanceAndEquippedCosmeticsPresentationReader: which lobby dance and which cosmetics a
-- character presentation carries.

local UnitTestFramework = require("../Support/UnitTestFramework")
local LobbyDanceAndEquippedCosmeticsPresentationReader =
	require("../../src/server/LobbyDanceAndEquippedCosmeticsPresentationReader")
local CosmeticCatalog = require("../../src/shared/CosmeticCatalog")
local DanceCatalog = require("../../src/shared/DanceCatalog")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local Reader = LobbyDanceAndEquippedCosmeticsPresentationReader
local PLAYER = 501

local function coordinatorAnswering(lobbyDanceState)
	return {
		readLobbyDanceStateOfPlayer = function(_, playerUserId)
			expect(playerUserId).toBe(PLAYER)
			return lobbyDanceState
		end,
	}
end

local function danceCatalogWith(extraDance)
	return {
		findDanceByDanceId = function(danceId)
			if extraDance and danceId == extraDance.danceId then
				return extraDance
			end
			return DanceCatalog.findDanceByDanceId(danceId)
		end,
	}
end

local function saveWith(ownedCosmeticIds, equippedCosmeticIdByKind)
	return { ownedCosmeticIds = ownedCosmeticIds, equippedCosmeticIdByKind = equippedCosmeticIdByKind }
end

describe("LobbyDanceAndEquippedCosmeticsPresentationReader lobby dance", function()
	it("is nil when the player does not dance in the lobby", function()
		local lobbyDance, unusableDanceId =
			Reader.readLobbyDanceToPresent(coordinatorAnswering(nil), DanceCatalog, PLAYER)
		expect(lobbyDance).toBeNil()
		expect(unusableDanceId).toBeNil()
	end)

	it("carries the dance's animation and the coordinator's start moment and followed player", function()
		local lobbyDance = Reader.readLobbyDanceToPresent(
			coordinatorAnswering({
				dancingPlayerUserId = PLAYER,
				danceId = "starter_bounce",
				danceStartedAtUnixMilliseconds = 1_800_000_000_123,
				followedPlayerUserId = 777,
			}),
			DanceCatalog,
			PLAYER
		)
		expect(lobbyDance).toEqual({
			danceId = "starter_bounce",
			danceAnimationAssetId = "rbxassetid://507776043",
			danceStartedAtUnixMilliseconds = 1_800_000_000_123,
			followedPlayerUserId = 777,
		})
		expect(table.isfrozen(lobbyDance)).toBeTrue()
	end)

	it("presents no dance, naming it, for a dance without a usable animation or no catalog entry", function()
		local unproducedDance = {
			danceId = "unproduced",
			danceDisplayName = "Unproduced",
			danceAnimationAssetId = "",
			starCoinPrice = 900,
			isGrantedToNewPlayers = false,
		}
		for _, danceId in { "unproduced", "retired_dance" } do
			local lobbyDance, unusableDanceId = Reader.readLobbyDanceToPresent(
				coordinatorAnswering({
					dancingPlayerUserId = PLAYER,
					danceId = danceId,
					danceStartedAtUnixMilliseconds = 1,
				}),
				danceCatalogWith(unproducedDance),
				PLAYER
			)
			expect(lobbyDance).toBeNil()
			expect(unusableDanceId).toBe(danceId)
		end
	end)
end)

describe("LobbyDanceAndEquippedCosmeticsPresentationReader cosmetics", function()
	it("shows nothing for a player with nothing equipped, or no save", function()
		expect(Reader.readEquippedCosmeticIdsToPresent(saveWith({}, {}), CosmeticCatalog)).toEqual({})
		expect(Reader.readEquippedCosmeticIdsToPresent(nil, CosmeticCatalog)).toEqual({})
	end)

	it("shows each equipped, owned cosmetic of each kind", function()
		local equipped = Reader.readEquippedCosmeticIdsToPresent(
			saveWith({ "title_rising_star", "nameplate_mint_fresh", "entrance_confetti_pop", "title_superstar" }, {
				Title = "title_rising_star",
				NameplateStyle = "nameplate_mint_fresh",
				StageEntranceEffect = "entrance_confetti_pop",
			}),
			CosmeticCatalog
		)
		expect(equipped).toEqual({
			titleCosmeticId = "title_rising_star",
			nameplateStyleCosmeticId = "nameplate_mint_fresh",
			stageEntranceEffectCosmeticId = "entrance_confetti_pop",
		})
		expect(table.isfrozen(equipped)).toBeTrue()
	end)

	it("never shows a cosmetic that is not owned, unknown, or equipped under another kind", function()
		local equipped = Reader.readEquippedCosmeticIdsToPresent(
			saveWith({ "nameplate_mint_fresh", "retired_title" }, {
				Title = "title_superstar", -- not owned
				NameplateStyle = "retired_title", -- owned but not in the catalog
				StageEntranceEffect = "nameplate_mint_fresh", -- owned, wrong kind
			}),
			CosmeticCatalog
		)
		expect(equipped).toEqual({})
	end)

	it("shows nothing for a damaged save", function()
		for _, damagedSave in
			{
				{ ownedCosmeticIds = "title_superstar", equippedCosmeticIdByKind = { Title = "title_superstar" } },
				{ ownedCosmeticIds = { "title_superstar" }, equippedCosmeticIdByKind = "title_superstar" },
				{ ownedCosmeticIds = { "title_superstar" }, equippedCosmeticIdByKind = { Title = 42 } },
				{},
			}
		do
			expect(Reader.readEquippedCosmeticIdsToPresent(damagedSave, CosmeticCatalog)).toEqual({})
		end
	end)

	it("builds signatures that are equal exactly when the three ids are equal", function()
		local signature = Reader.buildEquippedCosmeticsSignature
		expect(signature({})).toBe(signature({}))
		expect(signature({ titleCosmeticId = "a" }) == signature({ nameplateStyleCosmeticId = "a" })).toBeFalse()
		expect(signature({ titleCosmeticId = "a" }) == signature({ titleCosmeticId = "b" })).toBeFalse()
		expect(signature({ stageEntranceEffectCosmeticId = "e" }) == signature({})).toBeFalse()
		expect(signature({ titleCosmeticId = "a", nameplateStyleCosmeticId = "b" })).toBe(
			signature({ nameplateStyleCosmeticId = "b", titleCosmeticId = "a" })
		)
	end)
end)
