-- StudioTransferTextPacker: shrinks text that the Studio project sync must pass through an
-- `execute_luau` tool call. Every byte of a batch is written out by the agent driving Studio, so
-- the full project (about 300 KB of source after blanking comment lines, plus a second copy of the
-- shared modules) was too large to transfer as plain source. Packed, it is about a fifth.
-- Lune only (@lune/serde). Studio unpacks with EncodingService (createStudioAccessFromRobloxStudio
-- in tools/StudioSideProjectSyncRuntime.luau, and the inline code of batch 00).
--
-- Packing: Zstandard (serde.compress "zstd"), then Base64 (RFC 4648 alphabet with "=" padding),
-- written as lines of 100 characters (Studio removes the line breaks before decoding).
-- Roblox's EncodingService:DecompressBuffer refuses a Zstandard frame whose header does not state
-- the content size ("decompression failed - Error (generic)", Studio 0.748, 2026-11-19), and Lune's
-- frames do not state it, so the frame header is rewritten to carry it (RFC 8878 section 3.1.1.1:
-- Frame_Content_Size_Flag 2, a 4-byte little-endian size after the window descriptor and the
-- dictionary id); the compressed blocks are not touched. Checked in that Studio on a sample:
-- the unpacked text was byte-identical (SHA-256), CR and NUL bytes included.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- StudioTransferTextPacker.packTextForStudio(text) -> packedText
--   Base64 lines (only A-Z a-z 0-9 + / = and "\n") of the Zstandard frame of `text`, its header
--   stating the content size. Raises for a text of 4 GiB or more.
-- StudioTransferTextPacker.encodeBase64(binaryText) -> string   (one line, "=" padded)
-- StudioTransferTextPacker.addContentSizeToZstdFrame(frameBytes, contentByteCount) -> frameBytes
--   The same frame with the content size in its header (unchanged when it already has one).
--   Raises when `frameBytes` does not start with a Zstandard frame header.

local serde = require("@lune/serde")

local StudioTransferTextPacker = {}

local PACKED_LINE_LENGTH = 100
-- Zstandard's highest regular level: the smallest transfer; packing the whole project takes well
-- under a second in Lune.
local ZSTD_COMPRESSION_LEVEL = 19
local ZSTD_FRAME_MAGIC_BYTES = "\40\181\47\253"
local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DICTIONARY_ID_BYTE_COUNTS = { [0] = 0, [1] = 1, [2] = 2, [3] = 4 }

function StudioTransferTextPacker.encodeBase64(binaryText: string): string
	local encodedParts = {}
	for groupStart = 1, #binaryText, 3 do
		local firstByte, secondByte, thirdByte = string.byte(binaryText, groupStart, groupStart + 2)
		local groupValue = firstByte * 65536 + (secondByte or 0) * 256 + (thirdByte or 0)
		local encodedGroup = {}
		for characterPosition = 1, 4 do
			local sixBits = bit32.band(bit32.rshift(groupValue, 6 * (4 - characterPosition)), 63)
			encodedGroup[characterPosition] = string.sub(BASE64_ALPHABET, sixBits + 1, sixBits + 1)
		end
		if secondByte == nil then
			encodedGroup[3], encodedGroup[4] = "=", "="
		elseif thirdByte == nil then
			encodedGroup[4] = "="
		end
		table.insert(encodedParts, table.concat(encodedGroup))
	end
	return table.concat(encodedParts)
end

function StudioTransferTextPacker.addContentSizeToZstdFrame(frameBytes: string, contentByteCount: number): string
	if string.sub(frameBytes, 1, 4) ~= ZSTD_FRAME_MAGIC_BYTES or #frameBytes < 6 then
		error("StudioTransferTextPacker: not a Zstandard frame")
	end
	local frameHeaderDescriptor = string.byte(frameBytes, 5)
	local contentSizeFlag = bit32.rshift(frameHeaderDescriptor, 6)
	local isSingleSegment = bit32.band(frameHeaderDescriptor, 32) ~= 0
	if contentSizeFlag ~= 0 or isSingleSegment then
		return frameBytes
	end
	if contentByteCount >= 2 ^ 32 then
		error("StudioTransferTextPacker: a text of 4 GiB or more cannot be packed")
	end
	-- Without Single_Segment the header is: descriptor, window descriptor (1 byte), dictionary id.
	local headerEnd = 6 + DICTIONARY_ID_BYTE_COUNTS[bit32.band(frameHeaderDescriptor, 3)]
	return ZSTD_FRAME_MAGIC_BYTES
		.. string.char(bit32.bor(frameHeaderDescriptor, 128))
		.. string.sub(frameBytes, 6, headerEnd)
		.. string.pack("<I4", contentByteCount)
		.. string.sub(frameBytes, headerEnd + 1)
end

function StudioTransferTextPacker.packTextForStudio(text: string): string
	local frameBytes =
		StudioTransferTextPacker.addContentSizeToZstdFrame(serde.compress("zstd", text, ZSTD_COMPRESSION_LEVEL), #text)
	local encodedText = StudioTransferTextPacker.encodeBase64(frameBytes)
	local packedLines = {}
	for lineStart = 1, #encodedText, PACKED_LINE_LENGTH do
		table.insert(packedLines, string.sub(encodedText, lineStart, lineStart + PACKED_LINE_LENGTH - 1))
	end
	return table.concat(packedLines, "\n")
end

return table.freeze(StudioTransferTextPacker)
