-- Fixtures for the device specs. Not a spec file.
--   DeviceTestFixtures.readServerWardrobeCatalogSnapshotAnswer() -> the REAL server's answer to
--     RequestWardrobeCatalogSnapshot for the seven development items (the whole server assembled on
--     fakes by ServerGameAssemblyTestHarness, with the Marketplace answers captured in Studio).
--   DeviceTestFixtures.STYLING_ITEM_BY_STYLING_ITEM_KEY   the shared pool's lookup
--   DeviceTestFixtures.buildDevelopmentWardrobeCatalogView() -> WardrobeCatalogView of that answer
--   DeviceTestFixtures.buildSnapshotAnswerWithItems(stylingItemKeys) -> an accepted, ready answer
--     listing only those keys (taken from the server's answer)
--   Key names: HAIR, JACKET_TOP, DRESS, TURTLE_NECK, GLASSES, SHOES_BUNDLE, LIP_MAKEUP

local ServerGameAssemblyTestHarness = require("../server/ServerGameAssemblyTestHarness")
local StylingItemLookup = require("../../src/shared/StylingItemLookup")
local StylingItemPool = require("../../src/shared/generated/StylingItemPool")
local WardrobeCatalogView = require("../../src/client/WardrobeCatalogView")

local DeviceTestFixtures = {}

DeviceTestFixtures.HAIR = "asset_7259123616"
DeviceTestFixtures.JACKET_TOP = "asset_9122110415"
DeviceTestFixtures.DRESS = "asset_9438759973"
DeviceTestFixtures.TURTLE_NECK = "asset_4378579302"
DeviceTestFixtures.GLASSES = "asset_11884330"
DeviceTestFixtures.SHOES_BUNDLE = "bundle_98186475028072"
DeviceTestFixtures.LIP_MAKEUP = "asset_106390919006817"

DeviceTestFixtures.STYLING_ITEM_BY_STYLING_ITEM_KEY =
	StylingItemLookup.buildStylingItemByStylingItemKey(StylingItemPool.STYLING_ITEMS)

local cachedServerAnswer = nil

function DeviceTestFixtures.readServerWardrobeCatalogSnapshotAnswer()
	if cachedServerAnswer == nil then
		local harness = ServerGameAssemblyTestHarness.createStartedServer()
		harness:joinPlayer(101)
		harness:advance(5)
		cachedServerAnswer = harness:ask("RequestWardrobeCatalogSnapshot", 101, nil)
		assert(cachedServerAnswer.isWardrobeCatalogReady == true, "the development catalog must be ready")
	end
	return cachedServerAnswer
end

function DeviceTestFixtures.buildDevelopmentWardrobeCatalogView()
	return WardrobeCatalogView.buildWardrobeCatalogView(
		DeviceTestFixtures.readServerWardrobeCatalogSnapshotAnswer(),
		DeviceTestFixtures.STYLING_ITEM_BY_STYLING_ITEM_KEY
	)
end

function DeviceTestFixtures.buildSnapshotAnswerWithItems(stylingItemKeys: { string })
	local serverAnswer = DeviceTestFixtures.readServerWardrobeCatalogSnapshotAnswer()
	local wardrobeItems = {}
	for _, serverItem in serverAnswer.wardrobeItems do
		if table.find(stylingItemKeys, serverItem.stylingItemKey) ~= nil then
			table.insert(wardrobeItems, serverItem)
		end
	end
	return {
		isAccepted = true,
		isWardrobeCatalogReady = true,
		wardrobeCatalogVersion = serverAnswer.wardrobeCatalogVersion,
		wardrobeItems = wardrobeItems,
	}
end

return DeviceTestFixtures
