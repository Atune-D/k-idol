-- The one function that asks the engine for a purchase prompt (§2.12), loaded from its source with a
-- stand-in `game` (Lune has no Roblox engine). 🔴 It never asks for a prompt unless RunService:IsStudio()
-- is exactly false; outside Studio it asks for the asset prompt for an Asset and the bundle prompt for
-- a Bundle. No real engine call is ever made here.

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local OPENER_SOURCE_PATH = "src/client/RobloxMarketplacePurchasePromptOpener.luau"

local function loadOpenerWithStandInEngine(isStudioAnswer)
	local promptCalls = {}
	local standInServices = {
		RunService = {
			IsStudio = function()
				return isStudioAnswer
			end,
		},
		MarketplaceService = {
			PromptPurchase = function(_, player, assetId)
				table.insert(promptCalls, { "PromptPurchase", player, assetId })
			end,
			PromptBundlePurchase = function(_, player, bundleId)
				table.insert(promptCalls, { "PromptBundlePurchase", player, bundleId })
			end,
		},
	}
	local standInGame = {
		GetService = function(_, serviceName)
			return standInServices[serviceName]
		end,
	}
	local opener = luau.load(fs.readFile(OPENER_SOURCE_PATH), {
		debugName = "RobloxMarketplacePurchasePromptOpener",
		environment = { game = standInGame },
	})()
	return opener, promptCalls
end

local LOCAL_PLAYER = { Name = "stand-in player" }

describe("RobloxMarketplacePurchasePromptOpener", function()
	it("asks for no prompt at all while running in Studio, or when the engine's answer is not false", function()
		for _, isStudioAnswer in { true, nil, "false", 0 } do
			local opener, promptCalls = loadOpenerWithStandInEngine(isStudioAnswer)
			for _, purchasePromptKind in { "Asset", "Bundle" } do
				expect(opener.openPurchasePromptForStylingItem(LOCAL_PLAYER, purchasePromptKind, 7259123616)).toBeFalse()
			end
			expect(#promptCalls).toBe(0)
		end
	end)

	it("outside Studio, asks for the asset prompt for an Asset and the bundle prompt for a Bundle", function()
		local opener, promptCalls = loadOpenerWithStandInEngine(false)
		expect(opener.openPurchasePromptForStylingItem(LOCAL_PLAYER, "Asset", 7259123616)).toBeTrue()
		expect(opener.openPurchasePromptForStylingItem(LOCAL_PLAYER, "Bundle", 98186475028072)).toBeTrue()
		expect(promptCalls).toEqual({
			{ "PromptPurchase", LOCAL_PLAYER, 7259123616 },
			{ "PromptBundlePurchase", LOCAL_PLAYER, 98186475028072 },
		})
	end)

	it("outside Studio, asks for nothing for any other kind", function()
		local opener, promptCalls = loadOpenerWithStandInEngine(false)
		expect(opener.openPurchasePromptForStylingItem(LOCAL_PLAYER, "GamePass", 5)).toBeFalse()
		expect(#promptCalls).toBe(0)
	end)
end)
