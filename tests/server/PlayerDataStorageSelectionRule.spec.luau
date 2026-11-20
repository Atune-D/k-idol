local UnitTestFramework = require("../Support/UnitTestFramework")
local PlayerDataStorageSelectionRule = require("../../src/server/PlayerDataStorageSelectionRule")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local KINDS = PlayerDataStorageSelectionRule.PLAYER_DATA_STORAGE_KINDS
local decide = PlayerDataStorageSelectionRule.decidePlayerDataStorageKind

local NEVER_PUBLISHED_STUDIO_FACTS = table.freeze({
	isRunningInStudio = true,
	placeId = 0,
	gameId = 0,
	placeVersion = 0,
})

local function withFact(factName: string, factValue: any)
	local facts = table.clone(NEVER_PUBLISHED_STUDIO_FACTS)
	facts[factName] = factValue
	return facts
end

describe("PlayerDataStorageSelectionRule", function()
	it("chooses the in-memory development storage only for a never-published place in Studio", function()
		expect(decide(NEVER_PUBLISHED_STUDIO_FACTS)).toBe(KINDS.InMemoryDevelopmentStorage)
	end)

	it("chooses the real data stores for every combination of the four facts except the all-unpublished one", function()
		local developmentChoiceCount = 0
		for _, isRunningInStudio in { true, false } do
			for _, placeId in { 0, 1818 } do
				for _, gameId in { 0, 4242 } do
					for _, placeVersion in { 0, 7 } do
						local chosenKind = decide({
							isRunningInStudio = isRunningInStudio,
							placeId = placeId,
							gameId = gameId,
							placeVersion = placeVersion,
						})
						local isAllUnpublishedStudio = isRunningInStudio
							and placeId == 0
							and gameId == 0
							and placeVersion == 0
						expect(chosenKind).toBe(
							if isAllUnpublishedStudio then KINDS.InMemoryDevelopmentStorage else KINDS.RobloxDataStores
						)
						if chosenKind == KINDS.InMemoryDevelopmentStorage then
							developmentChoiceCount += 1
						end
					end
				end
			end
		end
		expect(developmentChoiceCount).toBe(1)
	end)

	it("chooses the real data stores when any fact is missing, of the wrong type or NaN", function()
		for _, factName in { "isRunningInStudio", "placeId", "gameId", "placeVersion" } do
			for _, wrongValue in { nil :: any, "0", 0 / 0, {}, 1 } do
				if factName ~= "isRunningInStudio" or wrongValue ~= nil then
					expect(decide(withFact(factName, wrongValue))).toBe(KINDS.RobloxDataStores)
				end
			end
		end
		expect(decide(withFact("isRunningInStudio", nil))).toBe(KINDS.RobloxDataStores)
		expect(decide(withFact("isRunningInStudio", 1))).toBe(KINDS.RobloxDataStores)
		expect(decide(withFact("isRunningInStudio", "true"))).toBe(KINDS.RobloxDataStores)
	end)

	it("chooses the real data stores when no facts table is given", function()
		expect(decide(nil)).toBe(KINDS.RobloxDataStores)
		expect(decide("Studio")).toBe(KINDS.RobloxDataStores)
		expect(decide({})).toBe(KINDS.RobloxDataStores)
	end)

	it("does not let a metatable pretend to hold the facts", function()
		local pretendingFacts = setmetatable({}, { __index = NEVER_PUBLISHED_STUDIO_FACTS })
		expect(decide(pretendingFacts)).toBe(KINDS.RobloxDataStores)
		for _, factName in { "isRunningInStudio", "placeId", "gameId", "placeVersion" } do
			local factsWithOneInherited = setmetatable(
				withFact(factName, nil),
				{ __index = { [factName] = NEVER_PUBLISHED_STUDIO_FACTS[factName] } }
			)
			expect({ factName, decide(factsWithOneInherited) }).toEqual({ factName, KINDS.RobloxDataStores })
		end
	end)

	it("says loudly in its warning that nothing is saved", function()
		local warningText = PlayerDataStorageSelectionRule.DEVELOPMENT_STORAGE_WARNING_TEXT
		expect(string.find(warningText, "NOTHING IS SAVED", 1, true) ~= nil).toBeTrue()
		expect(string.find(warningText, "never been published", 1, true) ~= nil).toBeTrue()
	end)
end)
