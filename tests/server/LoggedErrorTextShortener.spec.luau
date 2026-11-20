-- LoggedErrorTextShortener: raised errors become log text of bounded length.

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local LoggedErrorTextShortener = require("../../src/server/LoggedErrorTextShortener")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local shortenErrorTextForLog = LoggedErrorTextShortener.shortenErrorTextForLog

describe("LoggedErrorTextShortener", function()
	it("the limit is 300 characters and the marker is '...(cut)'", function()
		expect(LoggedErrorTextShortener.MAXIMUM_LOGGED_ERROR_TEXT_LENGTH).toBe(300)
		expect(LoggedErrorTextShortener.CUT_MARKER).toBe("...(cut)")
		expect(table.isfrozen(LoggedErrorTextShortener)).toBeTrue()
	end)

	it("keeps a text of exactly the limit unchanged", function()
		local errorText = string.rep("a", 300)
		expect(shortenErrorTextForLog(errorText)).toBe(errorText)
	end)

	it("cuts a text one character over the limit to the limit plus the marker", function()
		expect(shortenErrorTextForLog(string.rep("a", 300) .. "b")).toBe(string.rep("a", 300) .. "...(cut)")
	end)

	it("keeps a short text and the empty text unchanged", function()
		expect(shortenErrorTextForLog("short")).toBe("short")
		expect(shortenErrorTextForLog("")).toBe("")
	end)

	it("describes error values that are not strings", function()
		expect(shortenErrorTextForLog(nil)).toBe("nil")
		expect(shortenErrorTextForLog(42)).toBe("42")
		expect(string.find(shortenErrorTextForLog({}), "table", 1, true)).toBe(1)
	end)

	it("random lengths: the result is the text itself or its first 300 characters plus the marker", function()
		SeededRandomTrials.runSeededRandomTrials(200, function(randomNumberGenerator)
			local errorText = string.rep("z", randomNumberGenerator.nextWholeNumberInRange(0, 2000))
			local shortenedText = shortenErrorTextForLog(errorText)
			if #errorText <= 300 then
				expect(shortenedText).toBe(errorText)
			else
				expect(shortenedText).toBe(string.sub(errorText, 1, 300) .. "...(cut)")
			end
		end)
	end)
end)
