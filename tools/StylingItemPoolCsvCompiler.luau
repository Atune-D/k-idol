-- Parses, validates and renders the owner's styling item pool spreadsheet (development spec §1.2).
--
-- This module has no file access, so tests call it directly. The command-line wrapper is
-- tools/GenerateStylingItemPool.luau, which reads the CSV, prints problems and writes the
-- generated module.
--
-- CSV format: RFC 4180 style. Fields that contain a comma (such as `styleTags` = "y2k, cute")
-- must be wrapped in double quotes; a double quote inside a quoted field is written twice.
-- Row numbers in problems are spreadsheet row numbers: the header is row 1.
--
-- Columns (all required, any order, no others): marketplaceItemKind (Asset or Bundle, exact
-- case), marketplaceItemId (positive whole number), itemSlot, styleTags (1 to 3, comma
-- separated), primaryColorTag, isEnabled (true or false, any letter case, because spreadsheet
-- exports write TRUE / FALSE). Each row gets a derived `stylingItemKey` (asset_<id> or
-- bundle_<id>); a `shoes` row must be a Bundle and every other row an Asset.

local StylingItemLookup = require("../src/shared/StylingItemLookup")
local StylingTagVocabulary = require("../src/shared/StylingTagVocabulary")

local StylingItemPoolCsvCompiler = {}

export type StylingItemPoolCsvProblem = {
	csvRowNumber: number,
	problemDescription: string,
}

export type CompiledStylingItem = StylingItemLookup.StylingItem

export type StylingItemPoolCompilation = {
	stylingItems: { CompiledStylingItem },
	csvProblems: { StylingItemPoolCsvProblem },
}

type CsvRecord = {
	csvRowNumber: number,
	csvFieldTexts: { string },
}

StylingItemPoolCsvCompiler.REQUIRED_CSV_COLUMN_NAMES = table.freeze({
	"marketplaceItemKind",
	"marketplaceItemId",
	"itemSlot",
	"styleTags",
	"primaryColorTag",
	"isEnabled",
})

StylingItemPoolCsvCompiler.MINIMUM_STYLE_TAG_COUNT_PER_ITEM = 1
StylingItemPoolCsvCompiler.MAXIMUM_STYLE_TAG_COUNT_PER_ITEM = 3

-- Largest integer a Luau number holds exactly; Roblox asset and bundle ids are far below it.
local LARGEST_EXACT_INTEGER = 9007199254740991

local function trimSurroundingWhitespace(untrimmedText: string): string
	return (string.gsub(untrimmedText, "^%s*(.-)%s*$", "%1"))
end

local function addCsvProblem(
	csvProblems: { StylingItemPoolCsvProblem },
	csvRowNumber: number,
	problemDescription: string
)
	table.insert(csvProblems, { csvRowNumber = csvRowNumber, problemDescription = problemDescription })
end

-- Splits CSV text into records of raw field texts. Handles quoted fields, doubled quotes inside
-- them, line breaks inside quoted fields, and both LF and CRLF line endings. A record's row
-- number counts records, not physical lines, so it matches the spreadsheet row.
local function splitCsvTextIntoRecords(csvText: string, csvProblems: { StylingItemPoolCsvProblem }): { CsvRecord }
	local csvRecords: { CsvRecord } = {}
	local currentFieldTexts: { string } = {}
	local currentFieldCharacters: { string } = {}
	local isInsideQuotedField = false
	local wasCurrentFieldQuoted = false
	local isCurrentRecordMalformed = false
	local currentCsvRowNumber = 1
	local characterIndex = 1
	local csvTextLength = #csvText

	local function finishField()
		table.insert(currentFieldTexts, table.concat(currentFieldCharacters))
		table.clear(currentFieldCharacters)
		wasCurrentFieldQuoted = false
	end

	local function finishRecord()
		finishField()
		if not isCurrentRecordMalformed then
			table.insert(csvRecords, { csvRowNumber = currentCsvRowNumber, csvFieldTexts = currentFieldTexts })
		end
		currentFieldTexts = {}
		isCurrentRecordMalformed = false
		currentCsvRowNumber += 1
	end

	while characterIndex <= csvTextLength do
		local character = string.sub(csvText, characterIndex, characterIndex)
		if isInsideQuotedField then
			if character == '"' then
				if string.sub(csvText, characterIndex + 1, characterIndex + 1) == '"' then
					table.insert(currentFieldCharacters, '"')
					characterIndex += 1
				else
					isInsideQuotedField = false
				end
			else
				table.insert(currentFieldCharacters, character)
			end
		elseif character == '"' then
			if #currentFieldCharacters == 0 and not wasCurrentFieldQuoted then
				isInsideQuotedField = true
				wasCurrentFieldQuoted = true
			elseif not isCurrentRecordMalformed then
				isCurrentRecordMalformed = true
				addCsvProblem(
					csvProblems,
					currentCsvRowNumber,
					'a double quote appears inside an unquoted field; wrap the whole field in quotes and write a quote as ""'
				)
			end
		elseif character == "," then
			finishField()
		elseif character == "\r" and string.sub(csvText, characterIndex + 1, characterIndex + 1) == "\n" then
			finishRecord()
			characterIndex += 1
		elseif character == "\n" or character == "\r" then
			finishRecord()
		else
			if wasCurrentFieldQuoted and not string.match(character, "%s") and not isCurrentRecordMalformed then
				isCurrentRecordMalformed = true
				addCsvProblem(csvProblems, currentCsvRowNumber, "text follows the closing quote of a quoted field")
			end
			table.insert(currentFieldCharacters, character)
		end
		characterIndex += 1
	end

	if isInsideQuotedField then
		addCsvProblem(csvProblems, currentCsvRowNumber, "a quoted field is never closed")
		return csvRecords
	end
	-- A file that ends with a line break has no further record; otherwise finish the last one.
	if #currentFieldCharacters > 0 or #currentFieldTexts > 0 or wasCurrentFieldQuoted then
		finishRecord()
	end
	return csvRecords
end

local function isBlankRecord(csvRecord: CsvRecord): boolean
	for _, csvFieldText in csvRecord.csvFieldTexts do
		if trimSurroundingWhitespace(csvFieldText) ~= "" then
			return false
		end
	end
	return true
end

-- Returns the column index of each required column, or nil after recording problems.
local function readHeaderColumnIndexes(
	headerRecord: CsvRecord,
	csvProblems: { StylingItemPoolCsvProblem }
): { [string]: number }?
	local columnIndexByColumnName: { [string]: number } = {}
	local requiredColumnNameSet = {}
	for _, requiredColumnName in StylingItemPoolCsvCompiler.REQUIRED_CSV_COLUMN_NAMES do
		requiredColumnNameSet[requiredColumnName] = true
	end

	local problemCountBefore = #csvProblems
	for columnIndex, headerFieldText in headerRecord.csvFieldTexts do
		local columnName = trimSurroundingWhitespace(headerFieldText)
		if not requiredColumnNameSet[columnName] then
			addCsvProblem(csvProblems, headerRecord.csvRowNumber, string.format("unknown column %q", columnName))
		elseif columnIndexByColumnName[columnName] ~= nil then
			addCsvProblem(csvProblems, headerRecord.csvRowNumber, string.format("column %q appears twice", columnName))
		else
			columnIndexByColumnName[columnName] = columnIndex
		end
	end
	for _, requiredColumnName in StylingItemPoolCsvCompiler.REQUIRED_CSV_COLUMN_NAMES do
		if columnIndexByColumnName[requiredColumnName] == nil then
			addCsvProblem(
				csvProblems,
				headerRecord.csvRowNumber,
				string.format("required column %q is missing", requiredColumnName)
			)
		end
	end
	if #csvProblems > problemCountBefore then
		return nil
	end
	return columnIndexByColumnName
end

local function parseMarketplaceItemKind(
	marketplaceItemKindText: string,
	csvRowNumber: number,
	csvProblems: { StylingItemPoolCsvProblem }
): string?
	if not StylingItemLookup.isKnownMarketplaceItemKind(marketplaceItemKindText) then
		addCsvProblem(
			csvProblems,
			csvRowNumber,
			string.format("marketplaceItemKind %q must be exactly Asset or Bundle", marketplaceItemKindText)
		)
		return nil
	end
	return marketplaceItemKindText
end

local function parseMarketplaceItemId(
	marketplaceItemIdText: string,
	csvRowNumber: number,
	csvProblems: { StylingItemPoolCsvProblem }
): number?
	local parsedMarketplaceItemId = tonumber(marketplaceItemIdText)
	if
		not string.match(marketplaceItemIdText, "^[1-9]%d*$")
		or parsedMarketplaceItemId == nil
		or parsedMarketplaceItemId > LARGEST_EXACT_INTEGER
	then
		addCsvProblem(
			csvProblems,
			csvRowNumber,
			string.format(
				"marketplaceItemId %q is not a positive whole number (digits only, no leading zero)",
				marketplaceItemIdText
			)
		)
		return nil
	end
	return parsedMarketplaceItemId
end

local function parseItemSlot(
	itemSlotText: string,
	csvRowNumber: number,
	csvProblems: { StylingItemPoolCsvProblem }
): string?
	if itemSlotText == "" then
		addCsvProblem(csvProblems, csvRowNumber, "itemSlot is empty; exactly one item slot is required")
		return nil
	end
	if string.find(itemSlotText, ",", 1, true) then
		addCsvProblem(
			csvProblems,
			csvRowNumber,
			string.format("itemSlot %q lists more than one value; exactly one item slot is required", itemSlotText)
		)
		return nil
	end
	if not StylingTagVocabulary.isKnownItemSlot(itemSlotText) then
		addCsvProblem(
			csvProblems,
			csvRowNumber,
			string.format("itemSlot %q is not in the item slot vocabulary", itemSlotText)
		)
		return nil
	end
	return itemSlotText
end

local function parseStyleTags(
	styleTagsText: string,
	csvRowNumber: number,
	csvProblems: { StylingItemPoolCsvProblem }
): { string }?
	if styleTagsText == "" then
		addCsvProblem(csvProblems, csvRowNumber, "styleTags is empty; every row needs at least one style tag")
		return nil
	end
	local styleTags = {}
	local seenStyleTagSet = {}
	local hasStyleTagProblem = false
	for _, untrimmedStyleTag in string.split(styleTagsText, ",") do
		local styleTag = trimSurroundingWhitespace(untrimmedStyleTag)
		if styleTag == "" then
			addCsvProblem(
				csvProblems,
				csvRowNumber,
				string.format("styleTags %q contains an empty entry", styleTagsText)
			)
			hasStyleTagProblem = true
		elseif not StylingTagVocabulary.isKnownStyleTag(styleTag) then
			addCsvProblem(
				csvProblems,
				csvRowNumber,
				string.format("style tag %q is not in the style tag vocabulary", styleTag)
			)
			hasStyleTagProblem = true
		elseif seenStyleTagSet[styleTag] then
			addCsvProblem(csvProblems, csvRowNumber, string.format("style tag %q is listed twice", styleTag))
			hasStyleTagProblem = true
		else
			seenStyleTagSet[styleTag] = true
			table.insert(styleTags, styleTag)
		end
	end
	if #styleTags > StylingItemPoolCsvCompiler.MAXIMUM_STYLE_TAG_COUNT_PER_ITEM then
		addCsvProblem(
			csvProblems,
			csvRowNumber,
			string.format(
				"styleTags lists %d tags; at most %d are allowed",
				#styleTags,
				StylingItemPoolCsvCompiler.MAXIMUM_STYLE_TAG_COUNT_PER_ITEM
			)
		)
		hasStyleTagProblem = true
	end
	if hasStyleTagProblem then
		return nil
	end
	return styleTags
end

local function parsePrimaryColorTag(
	primaryColorTagText: string,
	csvRowNumber: number,
	csvProblems: { StylingItemPoolCsvProblem }
): string?
	if primaryColorTagText == "" then
		addCsvProblem(csvProblems, csvRowNumber, "primaryColorTag is empty; exactly one colour tag is required")
		return nil
	end
	if string.find(primaryColorTagText, ",", 1, true) then
		addCsvProblem(
			csvProblems,
			csvRowNumber,
			string.format(
				"primaryColorTag %q lists more than one value; exactly one colour tag is required",
				primaryColorTagText
			)
		)
		return nil
	end
	if not StylingTagVocabulary.isKnownColorTag(primaryColorTagText) then
		addCsvProblem(
			csvProblems,
			csvRowNumber,
			string.format("primaryColorTag %q is not in the colour tag vocabulary", primaryColorTagText)
		)
		return nil
	end
	return primaryColorTagText
end

-- Accepts `true` / `false` in any letter case, because spreadsheet exports write TRUE / FALSE.
local function parseIsEnabled(
	isEnabledText: string,
	csvRowNumber: number,
	csvProblems: { StylingItemPoolCsvProblem }
): boolean?
	local lowercaseIsEnabledText = string.lower(isEnabledText)
	if lowercaseIsEnabledText == "true" then
		return true
	end
	if lowercaseIsEnabledText == "false" then
		return false
	end
	addCsvProblem(csvProblems, csvRowNumber, string.format("isEnabled %q must be true or false", isEnabledText))
	return nil
end

-- §1.2: a `shoes` row must be a Bundle; a row in any other slot must be an Asset.
local function checkMarketplaceItemKindMatchesItemSlot(
	marketplaceItemKind: string,
	itemSlot: string,
	csvRowNumber: number,
	csvProblems: { StylingItemPoolCsvProblem }
): boolean
	local requiredMarketplaceItemKind = StylingItemLookup.getRequiredMarketplaceItemKindForItemSlot(itemSlot)
	if marketplaceItemKind == requiredMarketplaceItemKind then
		return true
	end
	if itemSlot == StylingItemLookup.ITEM_SLOT_REQUIRING_BUNDLE then
		addCsvProblem(
			csvProblems,
			csvRowNumber,
			string.format(
				"a %s row must have marketplaceItemKind Bundle (a pair of shoes is one bundle), not %s",
				itemSlot,
				marketplaceItemKind
			)
		)
	else
		addCsvProblem(
			csvProblems,
			csvRowNumber,
			string.format(
				"a %s row must have marketplaceItemKind Asset; only shoes rows may be Bundle, not %s",
				itemSlot,
				marketplaceItemKind
			)
		)
	end
	return false
end

-- Parses and validates the whole CSV. Every problem found is returned with its row number, in
-- row order; the items are only meaningful when `csvProblems` is empty.
function StylingItemPoolCsvCompiler.compileStylingItemPoolCsv(csvText: string): StylingItemPoolCompilation
	local csvProblems: { StylingItemPoolCsvProblem } = {}
	local stylingItems: { CompiledStylingItem } = {}
	local csvRecords = splitCsvTextIntoRecords(csvText, csvProblems)

	local headerRecord = csvRecords[1]
	if headerRecord == nil or headerRecord.csvRowNumber ~= 1 then
		if headerRecord == nil and #csvProblems == 0 then
			addCsvProblem(csvProblems, 1, "the file is empty; the header row is required")
		end
		return { stylingItems = stylingItems, csvProblems = csvProblems }
	end
	local columnIndexByColumnName = readHeaderColumnIndexes(headerRecord, csvProblems)
	if columnIndexByColumnName == nil then
		return { stylingItems = stylingItems, csvProblems = csvProblems }
	end

	local headerColumnCount = #headerRecord.csvFieldTexts
	local firstCsvRowNumberByStylingItemKey: { [string]: number } = {}
	for csvRecordIndex = 2, #csvRecords do
		local csvRecord = csvRecords[csvRecordIndex]
		local csvRowNumber = csvRecord.csvRowNumber
		if isBlankRecord(csvRecord) then
			continue
		end
		if #csvRecord.csvFieldTexts ~= headerColumnCount then
			addCsvProblem(
				csvProblems,
				csvRowNumber,
				string.format("row has %d fields but the header has %d", #csvRecord.csvFieldTexts, headerColumnCount)
			)
			continue
		end

		local function readTrimmedField(columnName: string): string
			return trimSurroundingWhitespace(csvRecord.csvFieldTexts[columnIndexByColumnName[columnName]])
		end

		local marketplaceItemKind =
			parseMarketplaceItemKind(readTrimmedField("marketplaceItemKind"), csvRowNumber, csvProblems)
		local marketplaceItemId =
			parseMarketplaceItemId(readTrimmedField("marketplaceItemId"), csvRowNumber, csvProblems)
		local itemSlot = parseItemSlot(readTrimmedField("itemSlot"), csvRowNumber, csvProblems)
		local styleTags = parseStyleTags(readTrimmedField("styleTags"), csvRowNumber, csvProblems)
		local primaryColorTag = parsePrimaryColorTag(readTrimmedField("primaryColorTag"), csvRowNumber, csvProblems)
		local isEnabled = parseIsEnabled(readTrimmedField("isEnabled"), csvRowNumber, csvProblems)

		local doesKindMatchSlot = false
		if marketplaceItemKind ~= nil and itemSlot ~= nil then
			doesKindMatchSlot =
				checkMarketplaceItemKindMatchesItemSlot(marketplaceItemKind, itemSlot, csvRowNumber, csvProblems)
		end

		local stylingItemKey = nil
		if marketplaceItemKind ~= nil and marketplaceItemId ~= nil then
			stylingItemKey = StylingItemLookup.deriveStylingItemKey(marketplaceItemKind, marketplaceItemId)
			local firstCsvRowNumber = firstCsvRowNumberByStylingItemKey[stylingItemKey]
			if firstCsvRowNumber ~= nil then
				addCsvProblem(
					csvProblems,
					csvRowNumber,
					string.format("stylingItemKey %s is a duplicate of row %d", stylingItemKey, firstCsvRowNumber)
				)
				continue
			end
			firstCsvRowNumberByStylingItemKey[stylingItemKey] = csvRowNumber
		end

		if
			stylingItemKey ~= nil
			and doesKindMatchSlot
			and styleTags ~= nil
			and primaryColorTag ~= nil
			and isEnabled ~= nil
		then
			table.insert(stylingItems, {
				stylingItemKey = stylingItemKey,
				marketplaceItemKind = marketplaceItemKind :: string,
				marketplaceItemId = marketplaceItemId :: number,
				itemSlot = itemSlot :: string,
				styleTags = styleTags,
				primaryColorTag = primaryColorTag,
				isEnabled = isEnabled,
			})
		end
	end

	-- Row order; problems of one row keep the order in which they were found.
	local discoveryPositionByCsvProblem: { [StylingItemPoolCsvProblem]: number } = {}
	for discoveryPosition, csvProblem in csvProblems do
		discoveryPositionByCsvProblem[csvProblem] = discoveryPosition
	end
	table.sort(csvProblems, function(leftProblem, rightProblem)
		if leftProblem.csvRowNumber ~= rightProblem.csvRowNumber then
			return leftProblem.csvRowNumber < rightProblem.csvRowNumber
		end
		return discoveryPositionByCsvProblem[leftProblem] < discoveryPositionByCsvProblem[rightProblem]
	end)
	return { stylingItems = stylingItems, csvProblems = csvProblems }
end

function StylingItemPoolCsvCompiler.formatCsvProblemForConsole(csvProblem: StylingItemPoolCsvProblem): string
	return string.format("row %d: %s", csvProblem.csvRowNumber, csvProblem.problemDescription)
end

local GENERATED_MODULE_HEADER_LINES = {
	"-- GENERATED FILE. DO NOT EDIT BY HAND.",
	"-- Source: data/styling-item-pool.csv. Regenerate with: lune run tools/GenerateStylingItemPool.luau",
	"-- Each entry is one row of the styling item pool (development spec §1.2), in CSV order.",
	"-- stylingItemKey is derived by the tool: asset_<marketplaceItemId> or bundle_<marketplaceItemId>.",
	"-- Disabled rows are kept with isEnabled = false so they stay out of outfits without being lost.",
	"",
	"local StylingItemPool = {}",
	"",
}

local function renderQuotedText(validatedText: string): string
	-- Only vocabulary values, kinds and derived keys reach here; all are [%w_]+ after validation.
	assert(string.match(validatedText, "^[%w_]+$"), "renderQuotedText: unexpected characters")
	return '"' .. validatedText .. '"'
end

-- Renders the generated module's source. The output is already in StyLua format, so
-- `stylua --check` passes on the generated file without reformatting.
function StylingItemPoolCsvCompiler.renderGeneratedStylingItemPoolModuleSource(
	stylingItems: { CompiledStylingItem }
): string
	local sourceLines = table.clone(GENERATED_MODULE_HEADER_LINES)
	if #stylingItems == 0 then
		table.insert(sourceLines, "StylingItemPool.STYLING_ITEMS = table.freeze({})")
	else
		table.insert(sourceLines, "StylingItemPool.STYLING_ITEMS = table.freeze({")
		for _, stylingItem in stylingItems do
			local quotedStyleTags = {}
			for _, styleTag in stylingItem.styleTags do
				table.insert(quotedStyleTags, renderQuotedText(styleTag))
			end
			table.insert(sourceLines, "\ttable.freeze({")
			table.insert(
				sourceLines,
				string.format("\t\tstylingItemKey = %s,", renderQuotedText(stylingItem.stylingItemKey))
			)
			table.insert(
				sourceLines,
				string.format("\t\tmarketplaceItemKind = %s,", renderQuotedText(stylingItem.marketplaceItemKind))
			)
			table.insert(sourceLines, string.format("\t\tmarketplaceItemId = %d,", stylingItem.marketplaceItemId))
			table.insert(sourceLines, string.format("\t\titemSlot = %s,", renderQuotedText(stylingItem.itemSlot)))
			table.insert(
				sourceLines,
				string.format("\t\tstyleTags = table.freeze({ %s }),", table.concat(quotedStyleTags, ", "))
			)
			table.insert(
				sourceLines,
				string.format("\t\tprimaryColorTag = %s,", renderQuotedText(stylingItem.primaryColorTag))
			)
			table.insert(sourceLines, string.format("\t\tisEnabled = %s,", tostring(stylingItem.isEnabled)))
			table.insert(sourceLines, "\t}),")
		end
		table.insert(sourceLines, "})")
	end
	table.insert(sourceLines, "")
	table.insert(sourceLines, "return table.freeze(StylingItemPool)")
	table.insert(sourceLines, "")
	return table.concat(sourceLines, "\n")
end

return table.freeze(StylingItemPoolCsvCompiler)
