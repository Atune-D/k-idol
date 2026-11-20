-- Unit: StudioSourceCommentLineBlanker (the copy of a script the Studio sync sends).

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local StudioSourceCommentLineBlanker = require("../../tools/StudioSourceCommentLineBlanker")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function blank(sourceText: string)
	return StudioSourceCommentLineBlanker.blankCommentOnlyLines(sourceText)
end

describe("StudioSourceCommentLineBlanker", function()
	it("empties comment-only lines (indented ones too) and keeps every other line and the line count", function()
		local studioSourceText, wasSentVerbatim =
			blank("-- header\nlocal a = 1 -- trailing\n\t-- indented\n  --x\nreturn a\n")
		expect(studioSourceText).toBe("\nlocal a = 1 -- trailing\n\n\nreturn a\n")
		expect(wasSentVerbatim).toBeFalse()
	end)

	it("keeps CR LF line endings, also on a blanked line", function()
		expect((blank("-- c\r\nreturn 1\r\n"))).toBe("\r\nreturn 1\r\n")
	end)

	it("keeps a last line without a newline", function()
		expect((blank("return 1\n-- end"))).toBe("return 1\n")
	end)

	it("sends a file with a long bracket verbatim", function()
		for _, sourceText in
			{ "local s = [[\n-- not a comment\n]]\n", "--[[ block\n-- x\n]]\n", "local s = [==[\n-- x\n]==]" }
		do
			local studioSourceText, wasSentVerbatim = blank(sourceText)
			expect(studioSourceText).toBe(sourceText)
			expect(wasSentVerbatim).toBeTrue()
		end
	end)

	it("sends a file with a backslash-continued string verbatim", function()
		local sourceText = 'local s = "a\\\n-- still the string"\n'
		local studioSourceText, wasSentVerbatim = blank(sourceText)
		expect(studioSourceText).toBe(sourceText)
		expect(wasSentVerbatim).toBeTrue()
		expect(select(2, blank('local s = "a\\\r\n-- still"\r\n'))).toBeTrue()
	end)

	it("sends a file with a \\z string continuation verbatim", function()
		local sourceText = 'return "a\\z\n-- b"\n'
		local studioSourceText, wasSentVerbatim = blank(sourceText)
		expect(studioSourceText).toBe(sourceText)
		expect(wasSentVerbatim).toBeTrue()
		expect(luau.compile(studioSourceText)).toBe(luau.compile(sourceText))
	end)

	it("never blanks a --! directive line, but blanks the other comment lines", function()
		local studioSourceText, wasSentVerbatim = blank("--!strict\n  --!native\n--!optimize 2\n-- note\nreturn 1\n")
		expect(studioSourceText).toBe("--!strict\n  --!native\n--!optimize 2\n\nreturn 1\n")
		expect(wasSentVerbatim).toBeFalse()
	end)

	it("compiles every project script to the same bytecode before and after blanking", function()
		local projectRootFolderPath =
			string.match(debug.info(1, "s"), "^(.*)[/\\]tests[/\\]tools[/\\][^/\\]+$") :: string
		local comparedScriptCount = 0
		local function compareScriptsUnder(folderPath: string)
			for _, entryName in fs.readDir(folderPath) do
				local entryPath = folderPath .. "/" .. entryName
				if fs.isDir(entryPath) then
					compareScriptsUnder(entryPath)
				elseif string.sub(entryName, -5) == ".luau" then
					local sourceText = fs.readFile(entryPath)
					local studioSourceText = blank(sourceText)
					if luau.compile(studioSourceText) ~= luau.compile(sourceText) then
						expect(entryPath).toBe("a script whose blanked copy compiles to the same bytecode")
					end
					comparedScriptCount += 1
				end
			end
		end
		compareScriptsUnder(projectRootFolderPath .. "/src")
		expect(comparedScriptCount > 30).toBeTrue()
	end)

	it("keeps the line count and every code line for random sources", function()
		local candidateLines = {
			"-- comment",
			"\t-- tab comment",
			"local x = 1",
			"",
			"x += 1 -- note",
			"return x",
			"  ",
			"print('--')",
			"--!strict",
		}
		SeededRandomTrials.runSeededRandomTrials(200, function(randomNumberGenerator)
			local sourceLines = {}
			for _ = 1, randomNumberGenerator.nextWholeNumberInRange(0, 12) do
				table.insert(sourceLines, randomNumberGenerator.pickRandomListElement(candidateLines))
			end
			local sourceText = table.concat(sourceLines, "\n")
			local studioLines = string.split((blank(sourceText)), "\n")
			local originalLines = string.split(sourceText, "\n")
			expect(#studioLines).toBe(#originalLines)
			for linePosition, originalLine in originalLines do
				local isBlankable = string.match(originalLine, "^[ \t]*%-%-")
					and not string.match(originalLine, "^[ \t]*%-%-!")
				local expectedLine = if isBlankable then "" else originalLine
				expect(studioLines[linePosition]).toBe(expectedLine)
			end
		end)
	end)
end)
