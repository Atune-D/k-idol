-- Dance catalog rules (development spec §1.7, §1.10, §3.8, §5.2), checked for every entry.

local UnitTestFramework = require("../Support/UnitTestFramework")
local DanceCatalog = require("../../src/shared/DanceCatalog")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

-- Spec v1.3 §3.8: the Roblox-created starter dance animations, verified in Studio.
local SPEC_STARTER_DANCE_ANIMATION_ASSET_IDS = {
	"rbxassetid://507771019",
	"rbxassetid://507776043",
	"rbxassetid://507777268",
}

describe("DanceCatalog entries", function()
	it("starter dances use exactly the three animation ids of spec §3.8, in order, one each", function()
		local starterDanceAnimationAssetIds = {}
		for _, dance in DanceCatalog.DANCES do
			if dance.isGrantedToNewPlayers then
				table.insert(starterDanceAnimationAssetIds, dance.danceAnimationAssetId)
			end
		end
		expect(starterDanceAnimationAssetIds).toEqual(SPEC_STARTER_DANCE_ANIMATION_ASSET_IDS)
	end)

	it("no starter dance is left without an animation", function()
		for _, dance in DanceCatalog.DANCES do
			if dance.isGrantedToNewPlayers then
				expect({ dance.danceId, dance.danceAnimationAssetId ~= "" }).toEqual({ dance.danceId, true })
			end
		end
	end)

	it("equips starter_groove first for a new player", function()
		expect(DanceCatalog.listDanceIdsGrantedToNewPlayers()[1]).toBe("starter_groove")
	end)

	it("has at least one dance granted to new players, so a new save can equip one (§1.10)", function()
		expect(#DanceCatalog.listDanceIdsGrantedToNewPlayers() >= 1).toBeTrue()
	end)

	it("every dance id is unique snake_case with a non-empty display name", function()
		local seenDanceIdSet = {}
		for _, dance in DanceCatalog.DANCES do
			expect({ dance.danceId, string.match(dance.danceId, "^[a-z][_a-z0-9]*$") ~= nil }).toEqual({
				dance.danceId,
				true,
			})
			expect({ dance.danceId, seenDanceIdSet[dance.danceId] }).toEqual({ dance.danceId, nil })
			seenDanceIdSet[dance.danceId] = true
			expect(type(dance.danceDisplayName) == "string" and #dance.danceDisplayName > 0).toBeTrue()
		end
	end)

	it("every animation id is empty (not chosen yet) or an rbxassetid content id", function()
		for _, dance in DanceCatalog.DANCES do
			local animationAssetId = dance.danceAnimationAssetId
			local isWellFormed = animationAssetId == ""
				or string.match(animationAssetId, "^rbxassetid://[1-9]%d*$") ~= nil
			expect({ dance.danceId, isWellFormed }).toEqual({ dance.danceId, true })
		end
	end)

	it("every price is a whole number >= 0, and every starter dance is free and granted (§1.7)", function()
		for _, dance in DanceCatalog.DANCES do
			expect(type(dance.starCoinPrice) == "number" and dance.starCoinPrice >= 0).toBeTrue()
			expect(dance.starCoinPrice == math.floor(dance.starCoinPrice)).toBeTrue()
			expect(type(dance.isGrantedToNewPlayers)).toBe("boolean")
			if dance.isGrantedToNewPlayers then
				expect({ dance.danceId, dance.starCoinPrice }).toEqual({ dance.danceId, 0 })
			end
		end
	end)

	it("holds only starter dances in Phase 1", function()
		for _, dance in DanceCatalog.DANCES do
			expect({ dance.danceId, dance.isGrantedToNewPlayers }).toEqual({ dance.danceId, true })
		end
	end)

	it("is frozen, dance by dance", function()
		expect(table.isfrozen(DanceCatalog)).toBeTrue()
		expect(table.isfrozen(DanceCatalog.DANCES)).toBeTrue()
		for _, dance in DanceCatalog.DANCES do
			expect(table.isfrozen(dance)).toBeTrue()
		end
	end)
end)

describe("DanceCatalog lookups", function()
	it("finds every dance by id and returns nil for unknown or non-string ids", function()
		for _, dance in DanceCatalog.DANCES do
			expect(DanceCatalog.findDanceByDanceId(dance.danceId)).toBe(dance)
		end
		expect(DanceCatalog.findDanceByDanceId("no_such_dance")).toBeNil()
		expect(DanceCatalog.findDanceByDanceId(42)).toBeNil()
		expect(DanceCatalog.findDanceByDanceId(nil)).toBeNil()
	end)

	it("lists granted dance ids in catalog order", function()
		local expectedDanceIds = {}
		for _, dance in DanceCatalog.DANCES do
			if dance.isGrantedToNewPlayers then
				table.insert(expectedDanceIds, dance.danceId)
			end
		end
		expect(DanceCatalog.listDanceIdsGrantedToNewPlayers()).toEqual(expectedDanceIds)
	end)

	it("returns a fresh list each time, so a caller cannot change the catalog", function()
		local firstList = DanceCatalog.listDanceIdsGrantedToNewPlayers()
		table.insert(firstList, "invented_dance")
		expect(table.find(DanceCatalog.listDanceIdsGrantedToNewPlayers(), "invented_dance")).toBeNil()
	end)
end)
