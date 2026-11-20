-- RoundResultsRowsBuilder (development spec §2.5 RoundResultsPublished, §1.6 scoring): the text rows
-- of the Results screen, one per entry, in the order the server sent them (highest score first).
--   * Every row shows the place, the name, the score, the four components and the stars.
--   * The theme match and completeness components are fractional (for example 33.333...); they are
--     shown with one decimal. The score itself is the server's whole number, shown as sent.
--   * Only the local player's row shows the Star Coins and fans gained and whether it is a new best
--     for the theme (§2.5 fields are sent for everyone, but they are that player's business).
--   * An entry with 0 stars is the empty-outfit entry (§1.6 "A participant whose final outfit is
--     empty receives no stars and no reward"): its row says so instead of showing stars and rewards.
-- The device never computes a score or a reward; it only formats what the server sent (§0.2 🔴).
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   RoundResultsRowsBuilder.buildRoundResultsRows(roundResults, localPlayerUserId) -> { row }
--     roundResults: as ServerSentMessageShapeReader.readRoundResultsPublishedMessage reads it.
--     row = { placeText, playerNameText, scoreText, componentsText, starsText, rewardText,
--             isLocalPlayer }   (rewardText is "" for other players)

local PlayerFacingTexts = require("./PlayerFacingTexts")

local RoundResultsRowsBuilder = {}

local function formatOneDecimal(points: number): string
	local roundedTenths = math.floor(points * 10 + 0.5) / 10
	if roundedTenths == math.floor(roundedTenths) then
		return string.format("%d", roundedTenths)
	end
	return string.format("%.1f", roundedTenths)
end

local function describeStars(starCount: number): string
	if starCount <= 0 then
		return "No stars: no outfit was saved"
	end
	return string.format("%d of 5 stars", starCount)
end

local function describeLocalReward(entry): string
	if entry.starCount <= 0 then
		return "No reward this round. Pick at least one item next time!"
	end
	local rewardText = string.format(
		"You earned %s Star Coins and %s fans",
		PlayerFacingTexts.formatWholeNumber(entry.starCoinsGranted),
		PlayerFacingTexts.formatWholeNumber(entry.fanCountGained)
	)
	if entry.isNewBestStarCountForTheme then
		rewardText ..= " - a new best for this theme!"
	end
	return rewardText
end

function RoundResultsRowsBuilder.buildRoundResultsRows(roundResults, localPlayerUserId: number)
	local rows = {}
	for place, entry in roundResults.roundResults do
		local isLocalPlayer = entry.playerUserId == localPlayerUserId
		table.insert(rows, {
			placeText = string.format("#%d", place),
			playerNameText = if isLocalPlayer then entry.playerDisplayName .. " (you)" else entry.playerDisplayName,
			scoreText = string.format("Score %d", entry.outfitScore),
			componentsText = string.format(
				"Theme %s/50 · Complete %s/20 · Colors %s/15 · Bonus %s/15",
				formatOneDecimal(entry.themeMatchPoints),
				formatOneDecimal(entry.completenessPoints),
				formatOneDecimal(entry.colorHarmonyPoints),
				formatOneDecimal(entry.roundBonusPoints)
			),
			starsText = describeStars(entry.starCount),
			rewardText = if isLocalPlayer then describeLocalReward(entry) else "",
			isLocalPlayer = isLocalPlayer,
		})
	end
	return rows
end

return table.freeze(RoundResultsRowsBuilder)
