-- Unit: StudioTransferTextPacker (Zstandard + Base64 for the Studio sync) and the Studio-side
-- format it packs (StudioSideLengthPrefixedTexts). Unpacking is done the way Studio does it,
-- with the harness's strict Base64 decoder and a decompressor that, like Roblox's
-- EncodingService:DecompressBuffer, refuses a frame whose header does not state the content size.

local serde = require("@lune/serde")

local UnitTestFramework = require("../Support/UnitTestFramework")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")
local StudioProjectSyncTestHarness = require("./StudioProjectSyncTestHarness")
local StudioSideLengthPrefixedTexts = require("../../tools/StudioSideLengthPrefixedTexts")
local StudioTransferTextPacker = require("../../tools/StudioTransferTextPacker")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function unpackLikeStudio(packedText: string): string
	return StudioProjectSyncTestHarness.decompressZstdFrameStatingItsSize(
		StudioProjectSyncTestHarness.decodeBase64((string.gsub(packedText, "%s", "")))
	)
end

local function buildRandomText(randomNumberGenerator, maximumPieceCount: number): string
	local textPieces = { "\n", "\r\n", "\0", "\255", "é", "]]", "--", "local x = 1", "\t", "12:", ":", "=" }
	local pieces = {}
	for _ = 1, randomNumberGenerator.nextWholeNumberInRange(0, maximumPieceCount) do
		table.insert(pieces, randomNumberGenerator.pickRandomListElement(textPieces))
	end
	return table.concat(pieces)
end

describe("StudioTransferTextPacker.encodeBase64", function()
	it("matches the RFC 4648 test vectors and encodes any byte", function()
		local expectedEncodings = {
			{ "", "" },
			{ "f", "Zg==" },
			{ "fo", "Zm8=" },
			{ "foo", "Zm9v" },
			{ "foob", "Zm9vYg==" },
			{ "fooba", "Zm9vYmE=" },
			{ "foobar", "Zm9vYmFy" },
			{ "\0\255\254", "AP/+" },
		}
		for _, expectedEncoding in expectedEncodings do
			expect({ expectedEncoding[1], StudioTransferTextPacker.encodeBase64(expectedEncoding[1]) }).toEqual(
				expectedEncoding
			)
		end
	end)
end)

describe("StudioTransferTextPacker.addContentSizeToZstdFrame", function()
	it("makes a Lune frame, which Roblox refuses, acceptable without touching its blocks", function()
		local text = string.rep("return { 'pool' }\n", 40)
		local luneFrameBytes = serde.compress("zstd", text, 19)
		expect(function()
			StudioProjectSyncTestHarness.decompressZstdFrameStatingItsSize(luneFrameBytes)
		end).toThrow("decompression failed")
		local patchedFrameBytes = StudioTransferTextPacker.addContentSizeToZstdFrame(luneFrameBytes, #text)
		expect(StudioProjectSyncTestHarness.decompressZstdFrameStatingItsSize(patchedFrameBytes)).toBe(text)
		expect(#patchedFrameBytes).toBe(#luneFrameBytes + 4)
		expect(string.sub(patchedFrameBytes, 11)).toBe(string.sub(luneFrameBytes, 7))
		-- A frame that already states its size is returned unchanged.
		expect(StudioTransferTextPacker.addContentSizeToZstdFrame(patchedFrameBytes, #text)).toBe(patchedFrameBytes)
	end)

	it("puts the size after the window descriptor and the dictionary id, little-endian", function()
		local magicBytes = string.char(0x28, 0xB5, 0x2F, 0xFD)
		-- Descriptor 0x01: no size, not single segment, a 1-byte dictionary id (0x07); window 0x58.
		local syntheticHeader = magicBytes .. string.char(0x01, 0x58, 0x07) .. "BLOCKS"
		expect(StudioTransferTextPacker.addContentSizeToZstdFrame(syntheticHeader, 258)).toBe(
			magicBytes .. string.char(0x81, 0x58, 0x07, 0x02, 0x01, 0x00, 0x00) .. "BLOCKS"
		)
		-- Descriptor 0x03: a 4-byte dictionary id.
		expect(StudioTransferTextPacker.addContentSizeToZstdFrame(magicBytes .. string.char(0x03, 0x58) .. "abcdX", 1)).toBe(
			magicBytes .. string.char(0x83, 0x58) .. "abcd" .. string.char(0x01, 0x00, 0x00, 0x00) .. "X"
		)
	end)

	it("raises for bytes that are not a Zstandard frame and for a size of 4 GiB or more", function()
		expect(function()
			StudioTransferTextPacker.addContentSizeToZstdFrame("not a frame", 3)
		end).toThrow("not a Zstandard frame")
		expect(function()
			StudioTransferTextPacker.addContentSizeToZstdFrame("\40\181\47\253", 3)
		end).toThrow("not a Zstandard frame")
		expect(function()
			StudioTransferTextPacker.addContentSizeToZstdFrame("\40\181\47\253\0\88rest", 2 ^ 32)
		end).toThrow("a text of 4 GiB or more cannot be packed")
	end)
end)

describe("StudioTransferTextPacker.packTextForStudio", function()
	it("gives back exactly the text when unpacked as Studio does, for random texts", function()
		SeededRandomTrials.runSeededRandomTrials(150, function(randomNumberGenerator)
			local text = buildRandomText(randomNumberGenerator, 60)
			local packedText = StudioTransferTextPacker.packTextForStudio(text)
			expect(unpackLikeStudio(packedText)).toBe(text)
			expect(string.find(packedText, "[^%w%+/=\n]")).toBeNil()
			for packedLine in string.gmatch(packedText, "[^\n]+") do
				expect(#packedLine <= 100).toBeTrue()
			end
		end)
	end)

	it("shrinks source text several times over", function()
		local sourceText = string.rep('local ThemeCatalog = require("../shared/ThemeCatalog")\n', 500)
		local packedText = StudioTransferTextPacker.packTextForStudio(sourceText)
		expect(unpackLikeStudio(packedText)).toBe(sourceText)
		expect(#packedText * 5 < #sourceText).toBeTrue()
	end)
end)

describe("StudioSideLengthPrefixedTexts", function()
	it("splits back exactly the texts it joined, for random texts", function()
		SeededRandomTrials.runSeededRandomTrials(200, function(randomNumberGenerator)
			local texts = {}
			for _ = 1, randomNumberGenerator.nextWholeNumberInRange(0, 5) do
				table.insert(texts, buildRandomText(randomNumberGenerator, 8))
			end
			expect(StudioSideLengthPrefixedTexts.splitTexts(StudioSideLengthPrefixedTexts.joinTexts(texts))).toEqual(
				texts
			)
		end)
		expect(StudioSideLengthPrefixedTexts.joinTexts({ "ab", "", "1:" })).toBe("2:ab0:2:1:")
	end)

	it("raises for a text not in its format", function()
		for _, malformedText in { "abc", ":x", "3:ab", "2:ab3:cd", "2:abx" } do
			expect(function()
				StudioSideLengthPrefixedTexts.splitTexts(malformedText)
			end).toThrow("StudioSideLengthPrefixedTexts: ")
		end
	end)

	it("unpackAndSplitTexts passes good texts through and wraps any unpacking problem", function()
		local packedText =
			StudioTransferTextPacker.packTextForStudio(StudioSideLengthPrefixedTexts.joinTexts({ "a", "bc" }))
		expect(StudioSideLengthPrefixedTexts.unpackAndSplitTexts(unpackLikeStudio, packedText, "write scripts 1 of 1")).toEqual({
			"a",
			"bc",
		})
		expect(function()
			StudioSideLengthPrefixedTexts.unpackAndSplitTexts(unpackLikeStudio, "AAAA", "write scripts 2 of 3")
		end).toThrow("StudioSideProjectSyncRuntime: write scripts 2 of 3: the packed sources do not unpack (")
		expect(function()
			StudioSideLengthPrefixedTexts.unpackAndSplitTexts(function()
				return "9:short"
			end, "", "write scripts 1 of 1")
		end).toThrow("the packed sources do not unpack (")
	end)
end)
