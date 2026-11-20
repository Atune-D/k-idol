-- Guard for the hard constraint "RewardLedger is the only module that changes fanCount or
-- starCoinBalance" (development spec §3.3). Any module could call the keeper's
-- applyChangeToPlayerSaveData and edit the two fields, so this test reads every .luau file under
-- src/ (found by scanning the folders), strips comments and string contents, and fails, naming
-- the file and line, when a file other than the ledger's single save change assigns to either
-- field: plain assignment (`x.fanCount = ...`), compound assignment (`+=`, `-=`, ...), the
-- bracket form (`x["fanCount"] = ...`) or `rawset(x, "fanCount", ...)`.
--
-- A table constructor field (`{ fanCount = value }`) builds a NEW table and changes no save. It is
-- allowed only in the files listed below, each with its reason, so a new file doing it fails until
-- someone decides. Known limit: an assignment split across lines before its `=` is not seen.

local fs = require("@lune/fs")

local UnitTestFramework = require("../Support/UnitTestFramework")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local GUARDED_SAVE_FIELD_NAMES = { "starCoinBalance", "fanCount" }

-- The one file allowed to change the two fields (RewardLedger's single save change).
local SOLE_BALANCE_WRITER_FILE_PATH = "src/server/RewardLedgerSingleSaveChange.luau"

local TABLE_CONSTRUCTOR_REASON_BY_ALLOWED_FILE_PATH = {
	["src/server/PlayerSaveDataSchema.luau"] = "builds the starting save of a brand-new player (spec §1.10)",
	["src/server/FanCountLeaderboardKeeper.luau"] = "builds leaderboard entries for devices from the cached top list",
	["src/server/RobloxFanCountLeaderboardStorage.luau"] = "builds leaderboard entries from the ordered data store page",
	["src/server/InMemoryDevelopmentFanCountLeaderboardStorage.luau"] = "builds leaderboard entries from the "
		.. "in-memory development leaderboard (unpublished Studio place only)",
}

export type BalanceFieldAssignment = {
	sourceFilePath: string,
	sourceLineNumber: number,
	assignedFieldName: string,
	assignmentForm: "FieldAssignment" | "TableConstructorField",
	sourceLineText: string,
}

local function findProjectRootFolderPath(): string
	local specFilePath = debug.info(1, "s")
	local projectRootFolderPath = string.match(specFilePath, "^(.*)[/\\]tests[/\\]server[/\\][^/\\]+$")
	assert(projectRootFolderPath ~= nil, "cannot work out the project root from " .. tostring(specFilePath))
	return projectRootFolderPath
end

local PROJECT_ROOT_FOLDER_PATH = findProjectRootFolderPath()

local function collectLuauFileRelativePaths(relativeFolderPath: string, luauFileRelativePaths: { string })
	for _, entryName in fs.readDir(PROJECT_ROOT_FOLDER_PATH .. "/" .. relativeFolderPath) do
		local entryRelativePath = relativeFolderPath .. "/" .. entryName
		if fs.isDir(PROJECT_ROOT_FOLDER_PATH .. "/" .. entryRelativePath) then
			collectLuauFileRelativePaths(entryRelativePath, luauFileRelativePaths)
		elseif string.sub(entryName, -5) == ".luau" then
			table.insert(luauFileRelativePaths, entryRelativePath)
		end
	end
end

local function countNewlines(text: string): number
	local _, newlineCount = string.gsub(text, "\n", "")
	return newlineCount
end

-- Long bracket opener at `position` (`[[`, `[==[`, ...): returns its closer, or nil.
local function findLongBracketCloser(luauSource: string, position: number): string?
	local equalSigns = string.match(luauSource, "^%[(=*)%[", position)
	return if equalSigns then "]" .. equalSigns .. "]" else nil
end

-- Comments become nothing and string contents become empty, except a string that is a bare
-- identifier (so `x["fanCount"]` stays visible). Newlines are kept so line numbers still match.
local function removeCommentsAndStringContents(luauSource: string): string
	local keptPieces = {}
	local position = 1
	local sourceLength = #luauSource
	while position <= sourceLength do
		local currentCharacter = string.sub(luauSource, position, position)
		if string.sub(luauSource, position, position + 1) == "--" then
			local longCommentCloser = findLongBracketCloser(luauSource, position + 2)
			local commentEnd
			if longCommentCloser then
				local _, closerEnd = string.find(luauSource, longCommentCloser, position + 2, true)
				commentEnd = closerEnd or sourceLength
			else
				commentEnd = (string.find(luauSource, "\n", position, true) or sourceLength + 1) - 1
			end
			table.insert(keptPieces, string.rep("\n", countNewlines(string.sub(luauSource, position, commentEnd))))
			position = commentEnd + 1
		elseif currentCharacter == '"' or currentCharacter == "'" or currentCharacter == "`" then
			local scanPosition = position + 1
			while scanPosition <= sourceLength do
				local scannedCharacter = string.sub(luauSource, scanPosition, scanPosition)
				if scannedCharacter == "\\" then
					scanPosition += 2
				elseif scannedCharacter == currentCharacter then
					break
				else
					scanPosition += 1
				end
			end
			local stringContent = string.sub(luauSource, position + 1, scanPosition - 1)
			local keptContent = if string.match(stringContent, "^[%a_][%w_]*$") then stringContent else ""
			table.insert(keptPieces, '"' .. keptContent .. '"' .. string.rep("\n", countNewlines(stringContent)))
			position = scanPosition + 1
		elseif currentCharacter == "[" and findLongBracketCloser(luauSource, position) then
			local longStringCloser = findLongBracketCloser(luauSource, position) :: string
			local _, closerEnd = string.find(luauSource, longStringCloser, position + 2, true)
			local longStringEnd = closerEnd or sourceLength
			table.insert(
				keptPieces,
				'""' .. string.rep("\n", countNewlines(string.sub(luauSource, position, longStringEnd)))
			)
			position = longStringEnd + 1
		else
			table.insert(keptPieces, currentCharacter)
			position += 1
		end
	end
	return table.concat(keptPieces)
end

-- True when `textAfterFieldName` starts with `=` (not `==`) or a compound assignment operator.
local function startsWithAssignmentOperator(textAfterFieldName: string): boolean
	if string.match(textAfterFieldName, "^%s*=") and not string.match(textAfterFieldName, "^%s*==") then
		return true
	end
	return string.match(textAfterFieldName, "^%s*[%+%-%*/%%%^]=") ~= nil
		or string.match(textAfterFieldName, "^%s*//=") ~= nil
		or string.match(textAfterFieldName, "^%s*%.%.=") ~= nil
end

local function classifyFieldNameOccurrence(codeLine: string, nameStart: number, nameEnd: number): string?
	local textBefore = string.sub(codeLine, 1, nameStart - 1)
	local textAfter = string.sub(codeLine, nameEnd + 1)
	if string.match(textBefore, '%[%s*"$') then
		local textAfterBracket = string.match(textAfter, '^"%s*%](.*)$')
		if textAfterBracket and startsWithAssignmentOperator(textAfterBracket) then
			return "FieldAssignment"
		end
		if string.match(textBefore, 'rawset%s*%(.*"$') then
			return "FieldAssignment"
		end
		return nil
	end
	if string.match(textBefore, 'rawset%s*%(.*"$') and string.match(textAfter, '^"') then
		return "FieldAssignment"
	end
	if not startsWithAssignmentOperator(textAfter) then
		return nil
	end
	if string.match(textBefore, "[%.:]%s*$") then
		return "FieldAssignment"
	end
	if string.match(textBefore, "^%s*local%s+[%w_,%s]*$") then
		return nil -- a local variable named like the field, not a save field
	end
	return "TableConstructorField"
end

-- Every assignment to a guarded field in one file's source.
local function findBalanceFieldAssignments(sourceFilePath: string, luauSource: string): { BalanceFieldAssignment }
	local foundAssignments = {}
	local originalLines = string.split(luauSource, "\n")
	for lineNumber, codeLine in string.split(removeCommentsAndStringContents(luauSource), "\n") do
		for _, guardedFieldName in GUARDED_SAVE_FIELD_NAMES do
			local searchFrom = 1
			while true do
				local nameStart, nameEnd =
					string.find(codeLine, "%f[%w_]" .. guardedFieldName .. "%f[^%w_]", searchFrom)
				if nameStart == nil then
					break
				end
				local assignmentForm = classifyFieldNameOccurrence(codeLine, nameStart, nameEnd :: number)
				if assignmentForm then
					table.insert(foundAssignments, {
						sourceFilePath = sourceFilePath,
						sourceLineNumber = lineNumber,
						assignedFieldName = guardedFieldName,
						assignmentForm = assignmentForm,
						sourceLineText = string.gsub(originalLines[lineNumber] or "", "^%s+", ""),
					})
				end
				searchFrom = (nameEnd :: number) + 1
			end
		end
	end
	return foundAssignments
end

local function scanEverySourceFile(): ({ BalanceFieldAssignment }, { string })
	local sourceFilePaths = {}
	collectLuauFileRelativePaths("src", sourceFilePaths)
	table.sort(sourceFilePaths)
	local everyAssignment = {}
	for _, sourceFilePath in sourceFilePaths do
		local luauSource = fs.readFile(PROJECT_ROOT_FOLDER_PATH .. "/" .. sourceFilePath)
		for _, foundAssignment in findBalanceFieldAssignments(sourceFilePath, luauSource) do
			table.insert(everyAssignment, foundAssignment)
		end
	end
	return everyAssignment, sourceFilePaths
end

local function describeAssignment(foundAssignment: BalanceFieldAssignment): string
	return string.format(
		"%s:%d assigns %s (%s): %s",
		foundAssignment.sourceFilePath,
		foundAssignment.sourceLineNumber,
		foundAssignment.assignedFieldName,
		foundAssignment.assignmentForm,
		foundAssignment.sourceLineText
	)
end

local function isAssignmentAllowed(foundAssignment: BalanceFieldAssignment): boolean
	if foundAssignment.sourceFilePath == SOLE_BALANCE_WRITER_FILE_PATH then
		return true
	end
	return foundAssignment.assignmentForm == "TableConstructorField"
		and TABLE_CONSTRUCTOR_REASON_BY_ALLOWED_FILE_PATH[foundAssignment.sourceFilePath] ~= nil
end

describe("RewardLedger sole balance writer guard (spec §3.3)", function()
	it("finds no file under src/ other than the ledger's single save change assigning either field", function()
		local everyAssignment = scanEverySourceFile()
		local forbiddenAssignmentDescriptions = {}
		for _, foundAssignment in everyAssignment do
			if not isAssignmentAllowed(foundAssignment) then
				table.insert(forbiddenAssignmentDescriptions, describeAssignment(foundAssignment))
			end
		end
		expect(forbiddenAssignmentDescriptions).toEqual({})
	end)

	it("scans folders recursively and sees the ledger's own assignments (the scan is not blind)", function()
		local everyAssignment, scannedFilePaths = scanEverySourceFile()
		expect(scannedFilePaths).toContain(SOLE_BALANCE_WRITER_FILE_PATH)
		expect(scannedFilePaths).toContain("src/shared/generated/StylingItemPool.luau")
		local soleWriterFieldNames = {}
		for _, foundAssignment in everyAssignment do
			if foundAssignment.sourceFilePath == SOLE_BALANCE_WRITER_FILE_PATH then
				soleWriterFieldNames[foundAssignment.assignedFieldName] = foundAssignment.assignmentForm
			end
		end
		expect(soleWriterFieldNames).toEqual({ starCoinBalance = "FieldAssignment", fanCount = "FieldAssignment" })
	end)

	it("keeps no stale allowance: every allowed file still builds such a table", function()
		local everyAssignment = scanEverySourceFile()
		local filePathsWithTableConstructorField = {}
		for _, foundAssignment in everyAssignment do
			if foundAssignment.assignmentForm == "TableConstructorField" then
				filePathsWithTableConstructorField[foundAssignment.sourceFilePath] = true
			end
		end
		for allowedFilePath in TABLE_CONSTRUCTOR_REASON_BY_ALLOWED_FILE_PATH do
			expect({ allowedFilePath, filePathsWithTableConstructorField[allowedFilePath] == true }).toEqual({
				allowedFilePath,
				true,
			})
		end
	end)
end)

describe("RewardLedger sole balance writer guard: what the scan recognises", function()
	local function listFoundForms(luauSource: string): { string }
		local foundForms = {}
		for _, foundAssignment in findBalanceFieldAssignments("example.luau", luauSource) do
			table.insert(
				foundForms,
				string.format(
					"%d:%s:%s",
					foundAssignment.sourceLineNumber,
					foundAssignment.assignedFieldName,
					foundAssignment.assignmentForm
				)
			)
		end
		return foundForms
	end

	it("finds plain, compound, bracket and rawset assignments to either field", function()
		local exampleSource = table.concat({
			"saveData.fanCount = 5",
			"saveDataDraft.starCoinBalance += 80",
			"saveDataDraft.starCoinBalance -= 80",
			"self.saveData.fanCount*=2",
			'saveData["starCoinBalance"] = 0',
			"rawset(saveData, 'fanCount', 1)",
		}, "\n")
		expect(listFoundForms(exampleSource)).toEqual({
			"1:fanCount:FieldAssignment",
			"2:starCoinBalance:FieldAssignment",
			"3:starCoinBalance:FieldAssignment",
			"4:fanCount:FieldAssignment",
			"5:starCoinBalance:FieldAssignment",
			"6:fanCount:FieldAssignment",
		})
	end)

	it("classifies a table constructor field as building a new table", function()
		expect(listFoundForms("local entry = { playerUserId = 1, fanCount = 0 }\nreturn {\n\tstarCoinBalance = 0,\n}")).toEqual({
			"1:fanCount:TableConstructorField",
			"3:starCoinBalance:TableConstructorField",
		})
	end)

	it("ignores comparisons, reads, comments, strings, locals and longer names", function()
		local exampleSource = table.concat({
			"if saveData.fanCount == 5 or saveData.fanCount ~= 6 or saveData.fanCount <= 7 then end",
			"local balanceAfter = saveData.starCoinBalance + 80",
			"-- saveData.fanCount = 1",
			"--[[ saveData.starCoinBalance = 1",
			"saveData.fanCount = 2 ]]",
			'print("saveData.fanCount = 3")',
			"local starCoinBalance = 4",
			"saveData.fanCountAfterChange = 5",
			"local message = [[saveData.fanCount = 6]]",
		}, "\n")
		expect(listFoundForms(exampleSource)).toEqual({})
	end)

	it("keeps line numbers right after multi-line comments and strings", function()
		local exampleSource = '--[[\nnote\n]]\nlocal text = "a\\\nb"\nsaveData.fanCount = 1'
		-- Lines: 1-3 block comment, 4-5 a string continued across a line, 6 the assignment.
		expect(listFoundForms(exampleSource)).toEqual({ "6:fanCount:FieldAssignment" })
	end)
end)
