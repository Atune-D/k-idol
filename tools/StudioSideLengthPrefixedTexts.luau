-- StudioSideLengthPrefixedTexts: the format in which a Studio project sync write batch carries its
-- script sources: every text written as "<byte count in decimal>:<text>", one after the other.
-- Lune joins (tools/StudioTransferTextPacker.luau, before compressing); the Studio-side runtime
-- splits (tools/StudioSideProjectSyncRuntime.luau, after decompressing). It is a runtime PART: it
-- requires nothing, because tools/StudioSyncRuntimeBundler.luau pastes it into batch 00.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- StudioSideLengthPrefixedTexts.joinTexts(texts) -> string
-- StudioSideLengthPrefixedTexts.splitTexts(joinedText) -> { string }
--   Exactly the texts that joinTexts was given, in order (any bytes, empty texts included).
--   Raises when the text is not in this format (a missing prefix, a count past the end).
-- StudioSideLengthPrefixedTexts.unpackAndSplitTexts(unpackText, packedText, batchLabel) -> { string }
--   splitTexts(unpackText(packedText)); when either raises, raises "StudioSideProjectSyncRuntime:
--   <batchLabel>: the packed sources do not unpack (<reason>); nothing was changed".

local StudioSideLengthPrefixedTexts = {}

function StudioSideLengthPrefixedTexts.joinTexts(texts: { string }): string
	local joinedParts = {}
	for _, text in texts do
		table.insert(joinedParts, #text .. ":" .. text)
	end
	return table.concat(joinedParts)
end

function StudioSideLengthPrefixedTexts.splitTexts(joinedText: string): { string }
	local texts = {}
	local readPosition = 1
	while readPosition <= #joinedText do
		local byteCountText = string.match(joinedText, "^(%d+):", readPosition)
		if byteCountText == nil then
			error("StudioSideLengthPrefixedTexts: no byte count at position " .. readPosition)
		end
		local textStart = readPosition + #byteCountText + 1
		local textEnd = textStart + tonumber(byteCountText) - 1
		if textEnd > #joinedText then
			error("StudioSideLengthPrefixedTexts: a text runs past the end at position " .. readPosition)
		end
		table.insert(texts, string.sub(joinedText, textStart, textEnd))
		readPosition = textEnd + 1
	end
	return texts
end

function StudioSideLengthPrefixedTexts.unpackAndSplitTexts(
	unpackText: (string) -> string,
	packedText: string,
	batchLabel: string
): { string }
	local didUnpack, textsOrError = pcall(function()
		return StudioSideLengthPrefixedTexts.splitTexts(unpackText(packedText))
	end)
	if not didUnpack then
		error(
			string.format(
				"StudioSideProjectSyncRuntime: %s: the packed sources do not unpack (%s); nothing was changed",
				tostring(batchLabel),
				tostring(textsOrError)
			)
		)
	end
	return textsOrError
end

return StudioSideLengthPrefixedTexts
