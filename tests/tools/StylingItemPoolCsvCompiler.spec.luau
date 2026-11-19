-- Unit: item-pool tool (development spec §6.2). All ids here are fake (9000001 and up).

local luau = require("@lune/luau")

local UnitTestFramework = require("../Support/UnitTestFramework")
local StylingItemPoolCsvCompiler = require("../../tools/StylingItemPoolCsvCompiler")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local CSV_HEADER_LINE = "marketplaceItemKind,marketplaceItemId,itemSlot,styleTags,primaryColorTag,isEnabled"

local function buildCsvText(csvDataLines: { string }): string
	return CSV_HEADER_LINE .. "\n" .. table.concat(csvDataLines, "\n") .. "\n"
end

local function compileCsvDataLines(csvDataLines: { string })
	return StylingItemPoolCsvCompiler.compileStylingItemPoolCsv(buildCsvText(csvDataLines))
end

-- Asserts that exactly one problem was reported, on `expectedCsvRowNumber`, and that its
-- description contains `expectedDescriptionFragment`.
local function expectSingleProblem(compilation, expectedCsvRowNumber: number, expectedDescriptionFragment: string)
	expect(#compilation.csvProblems).toBe(1)
	local csvProblem = compilation.csvProblems[1]
	expect(csvProblem.csvRowNumber).toBe(expectedCsvRowNumber)
	if not string.find(csvProblem.problemDescription, expectedDescriptionFragment, 1, true) then
		expect(csvProblem.problemDescription).toBe(expectedDescriptionFragment)
	end
end

local VALID_TOP_LINE = 'Asset,9000011,top,"y2k, cute",pink,true'
local VALID_SHOES_LINE = "Bundle,9000041,shoes,cute,white,true"

describe("StylingItemPoolCsvCompiler accepts a valid file", function()
	it("accepts a header-only file as an empty pool", function()
		local compilation = StylingItemPoolCsvCompiler.compileStylingItemPoolCsv(CSV_HEADER_LINE .. "\n")
		expect(compilation.csvProblems).toEqual({})
		expect(compilation.stylingItems).toEqual({})
	end)

	it("parses every column and derives stylingItemKey for an asset and a bundle", function()
		local compilation = compileCsvDataLines({ VALID_TOP_LINE, VALID_SHOES_LINE })
		expect(compilation.csvProblems).toEqual({})
		expect(compilation.stylingItems).toEqual({
			{
				stylingItemKey = "asset_9000011",
				marketplaceItemKind = "Asset",
				marketplaceItemId = 9000011,
				itemSlot = "top",
				styleTags = { "y2k", "cute" },
				primaryColorTag = "pink",
				isEnabled = true,
			},
			{
				stylingItemKey = "bundle_9000041",
				marketplaceItemKind = "Bundle",
				marketplaceItemId = 9000041,
				itemSlot = "shoes",
				styleTags = { "cute" },
				primaryColorTag = "white",
				isEnabled = true,
			},
		})
	end)

	it("treats an asset and a bundle with the same id as two different keys", function()
		local compilation = compileCsvDataLines({
			"Asset,9000001,hair,y2k,pink,true",
			"Bundle,9000001,shoes,cute,white,true",
		})
		expect(compilation.csvProblems).toEqual({})
		expect(compilation.stylingItems[1].stylingItemKey).toBe("asset_9000001")
		expect(compilation.stylingItems[2].stylingItemKey).toBe("bundle_9000001")
	end)

	it("accepts columns in any order, CRLF line endings, TRUE/FALSE and blank lines", function()
		local csvText = "isEnabled,primaryColorTag,styleTags,itemSlot,marketplaceItemId,marketplaceItemKind\r\n"
			.. "FALSE,black,gothic,hair,9000002,Asset\r\n"
			.. "\r\n"
			.. "TRUE,white,cute,shoes,9000041,Bundle\r\n"
		local compilation = StylingItemPoolCsvCompiler.compileStylingItemPoolCsv(csvText)
		expect(compilation.csvProblems).toEqual({})
		expect(#compilation.stylingItems).toBe(2)
		expect(compilation.stylingItems[1].stylingItemKey).toBe("asset_9000002")
		expect(compilation.stylingItems[1].isEnabled).toBe(false)
		expect(compilation.stylingItems[2].isEnabled).toBe(true)
	end)

	it("accepts one, two and three style tags", function()
		local compilation = compileCsvDataLines({
			"Asset,9000001,hair,y2k,pink,true",
			'Asset,9000002,hair,"y2k, cute",pink,true',
			'Asset,9000003,hair,"y2k, cute, retro",pink,true',
		})
		expect(compilation.csvProblems).toEqual({})
		expect(compilation.stylingItems[3].styleTags).toEqual({ "y2k", "cute", "retro" })
	end)

	it("accepts every item slot when its kind is right", function()
		local csvDataLines = {}
		for slotPosition, itemSlot in
			{
				"hair",
				"top",
				"bottom",
				"dress",
				"accessory",
				"makeup_eyes",
				"makeup_lips",
				"makeup_face",
				"eyelashes",
				"eyebrows",
			}
		do
			table.insert(csvDataLines, string.format("Asset,%d,%s,cute,pink,true", 9000100 + slotPosition, itemSlot))
		end
		table.insert(csvDataLines, VALID_SHOES_LINE)
		local compilation = compileCsvDataLines(csvDataLines)
		expect(compilation.csvProblems).toEqual({})
		expect(#compilation.stylingItems).toBe(11)
	end)
end)

describe("StylingItemPoolCsvCompiler rejects", function()
	it("an unknown style tag", function()
		expectSingleProblem(compileCsvDataLines({ "Asset,9000001,hair,hip_hop,pink,true" }), 2, '"hip_hop"')
	end)

	it("an unknown colour tag", function()
		expectSingleProblem(compileCsvDataLines({ "Asset,9000001,hair,y2k,grey,true" }), 2, '"grey"')
	end)

	it("an unknown item slot", function()
		expectSingleProblem(compileCsvDataLines({ "Asset,9000001,makeup,y2k,pink,true" }), 2, '"makeup"')
	end)

	it("a duplicate stylingItemKey, naming the first row", function()
		expectSingleProblem(
			compileCsvDataLines({
				VALID_TOP_LINE,
				"Asset,9000099,hair,y2k,pink,true",
				"Asset,9000011,top,y2k,pink,false",
			}),
			4,
			"asset_9000011 is a duplicate of row 2"
		)
	end)

	it("a row with no style tag", function()
		expectSingleProblem(compileCsvDataLines({ "Asset,9000001,hair,,pink,true" }), 2, "at least one style tag")
	end)

	it("a row with four style tags", function()
		expectSingleProblem(
			compileCsvDataLines({ 'Asset,9000001,hair,"y2k, cute, retro, punk",pink,true' }),
			2,
			"at most 3"
		)
	end)

	it("a style tag listed twice or an empty entry between commas", function()
		expectSingleProblem(compileCsvDataLines({ 'Asset,9000001,hair,"y2k, y2k",pink,true' }), 2, "listed twice")
		expectSingleProblem(compileCsvDataLines({ 'Asset,9000001,hair,"y2k,,cute",pink,true' }), 2, "empty entry")
	end)

	it("a shoes row that is not a Bundle", function()
		expectSingleProblem(
			compileCsvDataLines({ "Asset,9000041,shoes,cute,white,true" }),
			2,
			"must have marketplaceItemKind Bundle"
		)
	end)

	it("a non-shoes row that is not an Asset, for every non-shoes slot", function()
		for _, itemSlot in
			{
				"hair",
				"top",
				"bottom",
				"dress",
				"accessory",
				"makeup_eyes",
				"makeup_lips",
				"makeup_face",
				"eyelashes",
				"eyebrows",
			}
		do
			expectSingleProblem(
				compileCsvDataLines({ string.format("Bundle,9000001,%s,cute,pink,true", itemSlot) }),
				2,
				"must have marketplaceItemKind Asset"
			)
		end
	end)

	it("a marketplaceItemKind that is not exactly Asset or Bundle", function()
		for _, malformedKind in { "asset", "BUNDLE", "Item", "", "Asset Bundle" } do
			expectSingleProblem(
				compileCsvDataLines({ malformedKind .. ",9000001,hair,y2k,pink,true" }),
				2,
				"must be exactly Asset or Bundle"
			)
		end
	end)

	it("a malformed marketplaceItemId", function()
		for _, malformedId in { "", "0", "-5", "12.5", "1e7", "0123", "abc", "9007199254740993", " 12 3" } do
			expectSingleProblem(
				compileCsvDataLines({ "Asset," .. malformedId .. ",hair,y2k,pink,true" }),
				2,
				"is not a positive whole number"
			)
		end
	end)

	it("a malformed isEnabled", function()
		for _, malformedBoolean in { "", "yes", "1", "0", "t", "enabled" } do
			expectSingleProblem(
				compileCsvDataLines({ "Asset,9000001,hair,y2k,pink," .. malformedBoolean }),
				2,
				"must be true or false"
			)
		end
	end)

	it("an empty or multi-valued slot or colour", function()
		expectSingleProblem(compileCsvDataLines({ "Asset,9000001,,y2k,pink,true" }), 2, "itemSlot is empty")
		expectSingleProblem(
			compileCsvDataLines({ 'Asset,9000001,"hair, top",y2k,pink,true' }),
			2,
			"more than one value"
		)
		expectSingleProblem(compileCsvDataLines({ "Asset,9000001,hair,y2k,,true" }), 2, "primaryColorTag is empty")
		expectSingleProblem(
			compileCsvDataLines({ 'Asset,9000001,hair,y2k,"pink, red",true' }),
			2,
			"more than one value"
		)
	end)

	it("a row with the wrong number of fields", function()
		expectSingleProblem(
			compileCsvDataLines({ "Asset,9000001,hair,y2k,pink" }),
			2,
			"row has 5 fields but the header has 6"
		)
	end)

	it("a header with a missing, unknown or repeated column", function()
		local missingColumnCompilation = StylingItemPoolCsvCompiler.compileStylingItemPoolCsv(
			"marketplaceItemId,itemSlot,styleTags,primaryColorTag,isEnabled\n"
		)
		expectSingleProblem(missingColumnCompilation, 1, 'required column "marketplaceItemKind" is missing')
		local oldV10HeaderCompilation = StylingItemPoolCsvCompiler.compileStylingItemPoolCsv(
			"marketplaceAssetId,itemSlot,styleTags,primaryColorTag,isEnabled\n"
		)
		expect(#oldV10HeaderCompilation.csvProblems > 0).toBeTrue()
		local repeatedColumnCompilation =
			StylingItemPoolCsvCompiler.compileStylingItemPoolCsv(CSV_HEADER_LINE .. ",isEnabled\n")
		expectSingleProblem(repeatedColumnCompilation, 1, 'column "isEnabled" appears twice')
	end)

	it("an unknown extra column (no columns besides the six of spec §1.2)", function()
		expectSingleProblem(
			StylingItemPoolCsvCompiler.compileStylingItemPoolCsv(CSV_HEADER_LINE .. ",ownerNotes\n"),
			1,
			'unknown column "ownerNotes"'
		)
	end)

	it("text after the closing quote of a quoted field", function()
		expectSingleProblem(
			compileCsvDataLines({ 'Asset,9000001,hair,"y2k"x,pink,true' }),
			2,
			"text follows the closing quote"
		)
	end)

	it("an empty file and broken quoting", function()
		expectSingleProblem(StylingItemPoolCsvCompiler.compileStylingItemPoolCsv(""), 1, "the file is empty")
		expectSingleProblem(compileCsvDataLines({ 'Asset,9000001,hair,"y2k,pink,true' }), 2, "never closed")
		expectSingleProblem(
			compileCsvDataLines({ 'Asset,9000001,hair,y2"k,pink,true' }),
			2,
			"double quote appears inside"
		)
	end)
end)

describe("StylingItemPoolCsvCompiler problem reporting", function()
	it("reports every problem of every row with its row number, in row order", function()
		local compilation = compileCsvDataLines({
			VALID_TOP_LINE, -- row 2, fine
			"Asset,9000041,shoes,cute,white,true", -- row 3, shoes not a bundle
			"Asset,abc,hair,hip_hop,grey,maybe", -- row 4, four problems
			"Asset,9000011,top,y2k,pink,true", -- row 5, duplicate of row 2
		})
		local reportedRowNumbers = {}
		for _, csvProblem in compilation.csvProblems do
			table.insert(reportedRowNumbers, csvProblem.csvRowNumber)
		end
		expect(reportedRowNumbers).toEqual({ 3, 4, 4, 4, 4, 5 })
		expect(StylingItemPoolCsvCompiler.formatCsvProblemForConsole(compilation.csvProblems[1])).toBe(
			"row 3: a shoes row must have marketplaceItemKind Bundle (a pair of shoes is one bundle), not Asset"
		)
	end)

	it("numbers rows correctly in a CRLF file", function()
		local csvText = CSV_HEADER_LINE
			.. "\r\nAsset,9000001,hair,y2k,pink,true\r\nAsset,9000002,hair,y2k,grey,true\r\n"
		expectSingleProblem(StylingItemPoolCsvCompiler.compileStylingItemPoolCsv(csvText), 3, '"grey"')
	end)

	it("counts a line break inside a quoted field as part of one spreadsheet row", function()
		local compilation =
			compileCsvDataLines({ 'Asset,9000001,hair,"y2k,\ncute",pink,true', "Asset,9000002,hair,y2k,grey,true" })
		expectSingleProblem(compilation, 3, '"grey"')
	end)

	it("sorts quoting problems (found first) into row order with field problems", function()
		local compilation = compileCsvDataLines({
			"Asset,9000001,hair,y2k,grey,true", -- row 2, field problem
			'Asset,9000002,hair,y2"k,pink,true', -- row 3, quoting problem
		})
		local reportedRowNumbers = {}
		for _, csvProblem in compilation.csvProblems do
			table.insert(reportedRowNumbers, csvProblem.csvRowNumber)
		end
		expect(reportedRowNumbers).toEqual({ 2, 3 })
	end)
end)

describe("StylingItemPoolCsvCompiler generated module", function()
	local function loadRenderedModule(renderedSource: string)
		return luau.load(renderedSource, { debugName = "RenderedStylingItemPool" })()
	end

	it("renders a module whose items equal the compiled CSV rows", function()
		local compilation = compileCsvDataLines({
			VALID_TOP_LINE,
			VALID_SHOES_LINE,
			"Asset,9000061,makeup_eyes,elegant,beige,false",
		})
		expect(compilation.csvProblems).toEqual({})
		local renderedModule = loadRenderedModule(
			StylingItemPoolCsvCompiler.renderGeneratedStylingItemPoolModuleSource(compilation.stylingItems)
		)
		expect(renderedModule.STYLING_ITEMS).toEqual(compilation.stylingItems)
		expect(renderedModule.STYLING_ITEMS[3].isEnabled).toBe(false)
		expect(table.isfrozen(renderedModule)).toBeTrue()
		expect(table.isfrozen(renderedModule.STYLING_ITEMS)).toBeTrue()
		expect(table.isfrozen(renderedModule.STYLING_ITEMS[1])).toBeTrue()
		expect(table.isfrozen(renderedModule.STYLING_ITEMS[1].styleTags)).toBeTrue()
	end)

	it("renders an empty pool as a module with no items", function()
		local renderedModule =
			loadRenderedModule(StylingItemPoolCsvCompiler.renderGeneratedStylingItemPoolModuleSource({}))
		expect(renderedModule.STYLING_ITEMS).toEqual({})
	end)

	it("keeps large ids exact", function()
		local compilation = compileCsvDataLines({ "Asset,9007199254740991,hair,y2k,pink,true" })
		expect(compilation.csvProblems).toEqual({})
		local renderedSource =
			StylingItemPoolCsvCompiler.renderGeneratedStylingItemPoolModuleSource(compilation.stylingItems)
		expect(string.find(renderedSource, "marketplaceItemId = 9007199254740991,", 1, true) ~= nil).toBeTrue()
		expect(string.find(renderedSource, '"asset_9007199254740991"', 1, true) ~= nil).toBeTrue()
	end)
end)
