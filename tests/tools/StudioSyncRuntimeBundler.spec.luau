-- Unit: StudioSyncRuntimeBundler, which pastes the runtime parts into the one text batch 00 carries.

local luau = require("@lune/luau")

local UnitTestFramework = require("../Support/UnitTestFramework")
local StudioProjectSyncTestHarness = require("./StudioProjectSyncTestHarness")
local StudioProjectSyncBatchRenderer = require("../../tools/StudioProjectSyncBatchRenderer")
local StudioSyncRuntimeBundler = require("../../tools/StudioSyncRuntimeBundler")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PART_SOURCE_BY_NAME = {
	Doubler = "-- a part\nlocal Doubler = {}\nfunction Doubler.double(n)\n\treturn n * 2\nend\nreturn Doubler\n",
	Greeter = 'local Greeter = {}\nfunction Greeter.greet()\n\treturn "hi"\nend\nreturn Greeter\n',
}

local function readPart(partName: string): string
	return assert(PART_SOURCE_BY_NAME[partName], "no part " .. partName)
end

describe("StudioSyncRuntimeBundler.bundleRuntimeSourceText", function()
	it("replaces each part require with the part's own text, so the bundle runs without require", function()
		local runtimeSourceText = table.concat({
			'-- header: require("./Nothing") in a comment is ignored',
			'local Doubler = require("./Doubler")',
			'local Greeter = require("./Greeter")',
			"return { answer = Doubler.double(21), greeting = Greeter.greet() }",
		}, "\n")
		local bundledText = StudioSyncRuntimeBundler.bundleRuntimeSourceText(runtimeSourceText, readPart)
		expect(string.find(bundledText, 'require("./Doubler")', 1, true)).toBeNil()
		expect(string.find(bundledText, "local Doubler = (function()", 1, true) ~= nil).toBeTrue()
		local bundleResult = luau.load(bundledText, {
			environment = {
				require = function()
					error("the bundle must not require anything")
				end,
			},
		})()
		expect(bundleResult).toEqual({ answer = 42, greeting = "hi" })
	end)

	it("raises for any other require in the runtime, and for a part that requires", function()
		for _, unsupportedLine in
			{
				'local Doubler = require("../Doubler")',
				'local Twice = require("./Doubler")',
				"local Doubler = require(script.Doubler)",
				'print(require("./Doubler"))',
			}
		do
			expect(function()
				StudioSyncRuntimeBundler.bundleRuntimeSourceText(unsupportedLine, readPart)
			end).toThrow("the runtime may only require its parts")
		end
		expect(function()
			StudioSyncRuntimeBundler.bundleRuntimeSourceText('local Needy = require("./Needy")', function()
				return 'local Other = require("./Other")\nreturn {}'
			end)
		end).toThrow("runtime part Needy must not require")
	end)

	it("bundles this project's runtime into a text that compiles and offers the runtime API", function()
		local bundledText = StudioProjectSyncTestHarness.RUNTIME_SOURCE_TEXT
		local bundledCodeText = StudioProjectSyncBatchRenderer.stripCommentLinesAndIndentation(bundledText)
		expect(string.find(bundledCodeText, "require", 1, true)).toBeNil()
		local runtime = luau.load(bundledText)()
		for _, functionName in
			{
				"createStudioAccessFromRobloxStudio",
				"describeBatchPayloadCanonically",
				"applyScriptWriteBatch",
				"removeUnexpectedInstancesAndVerifyProject",
				"readStudioScriptManifest",
			}
		do
			expect({ functionName, type(runtime[functionName]) }).toEqual({ functionName, "function" })
		end
	end)
end)
