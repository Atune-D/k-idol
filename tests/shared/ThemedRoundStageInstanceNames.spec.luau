-- The stage folder name has ONE home (src/shared/ThemedRoundStageInstanceNames). The server's stage
-- builder and the device's camera director are Roblox-facing files Lune cannot load, so their source
-- is checked: both read the shared name and neither spells the name itself.

local UnitTestFramework = require("../Support/UnitTestFramework")
local ThemedRoundStageInstanceNames = require("../../src/shared/ThemedRoundStageInstanceNames")
local fs = require("@lune/fs")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

-- The file's code lines (lines that are only a comment are left out, so headers may name things).
local function readCodeWithoutCommentLines(sourcePath: string): string
	local codeLines = {}
	for _, sourceLine in string.split(fs.readFile(sourcePath), "\n") do
		if not string.match(sourceLine, "^%s*%-%-") then
			table.insert(codeLines, sourceLine)
		end
	end
	return table.concat(codeLines, "\n")
end

local function countPlainOccurrences(text: string, fragment: string): number
	local count, searchFrom = 0, 1
	while true do
		local foundAt = string.find(text, fragment, searchFrom, true)
		if foundAt == nil then
			return count
		end
		count += 1
		searchFrom = foundAt + #fragment
	end
end

describe("ThemedRoundStageInstanceNames", function()
	it("names the stage folder ThemedRoundStage", function()
		expect(ThemedRoundStageInstanceNames.STAGE_FOLDER_NAME).toBe("ThemedRoundStage")
		expect(table.isfrozen(ThemedRoundStageInstanceNames)).toBe(true)
	end)

	it("is where the server's stage builder and the device's camera director take the name from", function()
		for _, sourcePath in
			{ "src/server/RobloxThemedRoundStageBuilder.luau", "src/client/RobloxShowcaseCameraDirector.luau" }
		do
			local source = readCodeWithoutCommentLines(sourcePath)
			expect(countPlainOccurrences(source, "ThemedRoundStageInstanceNames.STAGE_FOLDER_NAME") >= 1).toBe(true)
			expect(countPlainOccurrences(source, '= "ThemedRoundStage"')).toBe(0)
		end
	end)
end)
