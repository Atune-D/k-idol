-- The Showcase audience camera geometry, and the wardrobe preview's appearance plan: the device plans
-- its preview with the SAME shared planner the server dresses characters with, from the snapshot.

local UnitTestFramework = require("../Support/UnitTestFramework")
local DeviceTestFixtures = require("./DeviceTestFixtures")
local CharacterOutfitAppearancePlanner = require("../../src/shared/CharacterOutfitAppearancePlanner")
local ServerPathPlanner = require("../../src/server/CharacterOutfitAppearancePlanner")
local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local RecordingLogger = require("../Support/RecordingLogger")
local CapturedAnswerMarketplaceItemLookups = require("../fixtures/CapturedAnswerMarketplaceItemLookups")
local MarketplaceStylingItemResolver = require("../../src/server/MarketplaceStylingItemResolver")
local ShowcaseAudienceCameraPlacement = require("../../src/client/ShowcaseAudienceCameraPlacement")
local StylingItemPool = require("../../src/shared/generated/StylingItemPool")
local WardrobeCatalogView = require("../../src/client/WardrobeCatalogView")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local F = DeviceTestFixtures

describe("ShowcaseAudienceCameraPlacement", function()
	-- The stage the server builds (measured in Studio): a platform centred at (0, 1, -55) and pads.
	local stageParts = {
		{ centerPosition = { x = 0, y = 1, z = -55 }, size = { x = 60, y = 2, z = 24 } },
		{ centerPosition = { x = -22.5, y = 2.2, z = -50 }, size = { x = 6, y = 0.4, z = 6 } },
		{ centerPosition = { x = 22.5, y = 2.2, z = -60 }, size = { x = 6, y = 0.4, z = 6 } },
	}

	it("boxes every part of the stage", function()
		local box = ShowcaseAudienceCameraPlacement.computeStageBoxFromParts(stageParts)
		expect(box.minimumCorner).toEqual({ x = -30, y = 0, z = -67 })
		expect(box.maximumCorner.x).toBe(30)
		expect(box.maximumCorner.y).toBeCloseTo(2.4)
		expect(box.maximumCorner.z).toBe(-43)
		expect(ShowcaseAudienceCameraPlacement.computeStageBoxFromParts({})).toBeNil()
	end)

	it("stands in front of the stage, towards the spawn, far enough to see its whole width", function()
		local box = ShowcaseAudienceCameraPlacement.computeStageBoxFromParts(stageParts)
		local placement = ShowcaseAudienceCameraPlacement.computeAudienceCameraPlacement(box, 70, 16 / 9)
		expect(placement.cameraPosition.x).toBeCloseTo(0)
		expect(placement.cameraPosition.z > box.maximumCorner.z).toBeTrue()
		expect(placement.cameraPosition.y).toBeCloseTo(2.4 + 14)
		expect(placement.lookAtPosition).toEqual({ x = 0, y = box.maximumCorner.y + 10, z = -55 })
		-- It looks above the performers' heads (about 5 studs tall), so the stage sits below the
		-- view's centre, under the round panel.
		expect(placement.lookAtPosition.y > box.maximumCorner.y + 5).toBeTrue()
		-- The stage's front corners are inside the horizontal field of view.
		local verticalHalf = math.rad(70) / 2
		local horizontalHalf = math.atan(math.tan(verticalHalf) * 16 / 9)
		local distanceToFront = placement.cameraPosition.z - box.maximumCorner.z
		expect(math.atan(30 / distanceToFront) < horizontalHalf).toBeTrue()
		-- A narrower (phone portrait) view stands further back.
		local portrait = ShowcaseAudienceCameraPlacement.computeAudienceCameraPlacement(box, 70, 9 / 16)
		expect(portrait.cameraPosition.z > placement.cameraPosition.z).toBeTrue()
	end)

	it("faces along -Z from +Z when the stage is centred on the origin", function()
		local box = { minimumCorner = { x = -5, y = 0, z = -5 }, maximumCorner = { x = 5, y = 2, z = 5 } }
		local placement = ShowcaseAudienceCameraPlacement.computeAudienceCameraPlacement(box, 70, 1)
		expect(placement.cameraPosition.x).toBeCloseTo(0)
		expect(placement.cameraPosition.z > 5).toBeTrue()
	end)
end)

describe("wardrobe preview appearance plan", function()
	it("the server path is the very same planner module as the shared one", function()
		expect(ServerPathPlanner).toBe(CharacterOutfitAppearancePlanner)
	end)

	it("plans the device preview exactly as the server plans the real character, for every outfit tried", function()
		local fakeScheduler = FakeScheduler.new(FakeClock.new(1_800_000_000))
		local resolver = MarketplaceStylingItemResolver.new({
			stylingItems = StylingItemPool.STYLING_ITEMS,
			marketplaceItemLookups = CapturedAnswerMarketplaceItemLookups.new(),
			scheduler = fakeScheduler,
			logger = RecordingLogger.new(),
		})
		resolver:startResolvingWardrobeCatalog()
		fakeScheduler:advanceTimeAndRunDueCallbacks(1)
		local view = F.buildDevelopmentWardrobeCatalogView()
		local ownEyebrows =
			{ { accessoryTypeName = "Eyebrow", assetId = 10725837187, isLayered = true, layeredClothingOrder = 0 } }
		local outfits = {
			{},
			{ F.HAIR, F.DRESS, F.SHOES_BUNDLE, F.GLASSES, F.TURTLE_NECK, F.LIP_MAKEUP },
			{ F.JACKET_TOP, F.SHOES_BUNDLE },
			{ F.LIP_MAKEUP, F.HAIR },
		}
		for _, outfit in outfits do
			local devicePlan = CharacterOutfitAppearancePlanner.planCharacterAppearanceForOutfit({
				outfitStylingItemKeys = outfit,
				readResolvedStylingItemDetails = WardrobeCatalogView.readResolvedStylingItemDetailsFromView(view),
				currentAccessoryEntries = ownEyebrows,
			})
			local serverPlan = CharacterOutfitAppearancePlanner.planCharacterAppearanceForOutfit({
				outfitStylingItemKeys = outfit,
				readResolvedStylingItemDetails = function(stylingItemKey)
					return resolver:readResolvedStylingItemDetails(stylingItemKey)
				end,
				currentAccessoryEntries = ownEyebrows,
			})
			expect(devicePlan).toEqual(serverPlan)
		end
	end)
end)
