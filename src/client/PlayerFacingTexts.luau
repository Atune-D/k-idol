-- PlayerFacingTexts: every sentence the Phase 1 screens show, in plain words, in one place, so the
-- wording can be reviewed and changed without touching the screens or the rules.
-- No real brand, idol, group, artist or song names (spec §5.2).
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   PlayerFacingTexts.describeJoinRejectionReason(rejectionReason) -> string
--     One sentence per §2.2 reason (and the server's RequestFailedOnServer); any other value, and a
--     join request that got no answer (nil), reads as a generic "try again".
--   PlayerFacingTexts.describeRoundBonusRule(roundBonusRule) -> string    (§1.4)
--   PlayerFacingTexts.describeThemeDisplayName(themeId) -> string   ThemeCatalog name, or the id
--   PlayerFacingTexts.formatCountdownSeconds(remainingSeconds?) -> string   "m:ss", rounded up; "" for nil
--   PlayerFacingTexts.describeDraftSavingStatus(draftSavingStatus) -> string
--   PlayerFacingTexts.describeSelectionRefusalReason(selectionRefusalReason) -> string
--   PlayerFacingTexts.describeOutfitPutBack(rejectionReason?) -> string
--   PlayerFacingTexts.formatWholeNumber(number) -> string   "1,240"
--   constant sentences: PERSISTENCE_DELAYED_NOTICE, UNAVAILABLE_SAVED_OUTFIT_ITEMS_NOTICE,
--     WARDROBE_LOCKED_NOTICE, WARDROBE_LOADING_NOTICE, INTERMISSION_NOTICE, SHOWCASE_NOTICE,
--     OUTSIDE_LEADERBOARD_TOP_NOTICE, WAITING_FOR_SERVER_NOTICE

local ThemeCatalog = require("../shared/ThemeCatalog")

local PlayerFacingTexts = {}

-- §2.6, wording fixed by the spec for the unavailable items; the other notices are this file's.
PlayerFacingTexts.PERSISTENCE_DELAYED_NOTICE = "Progress can't be saved right now."
PlayerFacingTexts.UNAVAILABLE_SAVED_OUTFIT_ITEMS_NOTICE = "Some items of your saved outfit are unavailable right now."
PlayerFacingTexts.WARDROBE_LOCKED_NOTICE = "Time's up! Your last saved outfit goes on stage."
PlayerFacingTexts.WARDROBE_LOADING_NOTICE = "The wardrobe is loading..."
PlayerFacingTexts.INTERMISSION_NOTICE = "Next round soon. Get ready for a new theme!"
PlayerFacingTexts.SHOWCASE_NOTICE = "Showtime! Everyone who took part is on stage."
PlayerFacingTexts.OUTSIDE_LEADERBOARD_TOP_NOTICE = "You are outside the top 100."
PlayerFacingTexts.WAITING_FOR_SERVER_NOTICE = "Connecting to the game..."

local JOIN_REJECTION_TEXT_BY_REASON = table.freeze({
	SaveDataNotLoaded = "Your progress is still loading. Try again in a moment.",
	WardrobeCatalogNotReady = "The wardrobe is still loading. Try again in a moment.",
	RoundNotJoinableNow = "Too late to join this round. You can join the next one.",
	AlreadyParticipating = "You are already taking part in this round.",
	TooManyRequests = "Slow down a little, then try again.",
	RequestFailedOnServer = "Something went wrong on the server. Try again.",
})
local GENERIC_JOIN_FAILURE_TEXT = "Could not join right now. Try again."

function PlayerFacingTexts.describeJoinRejectionReason(rejectionReason: any): string
	return JOIN_REJECTION_TEXT_BY_REASON[rejectionReason] or GENERIC_JOIN_FAILURE_TEXT
end

function PlayerFacingTexts.describeRoundBonusRule(roundBonusRule: any): string
	if type(roundBonusRule) ~= "table" then
		return ""
	end
	if roundBonusRule.roundBonusKind == "ColorBonus" and type(roundBonusRule.bonusColorTag) == "string" then
		return string.format("Round bonus: wear %s items (up to 3 count).", roundBonusRule.bonusColorTag)
	end
	if roundBonusRule.roundBonusKind == "StyleBonus" and type(roundBonusRule.bonusStyleTag) == "string" then
		local styleWords = string.gsub(roundBonusRule.bonusStyleTag, "_", " ")
		return string.format("Round bonus: wear %s style items (up to 3 count).", styleWords)
	end
	return ""
end

local themeDisplayNameByThemeId: { [string]: string } = {}
for _, theme in ThemeCatalog.THEMES do
	themeDisplayNameByThemeId[theme.themeId] = theme.themeDisplayName
end

function PlayerFacingTexts.describeThemeDisplayName(themeId: string): string
	return themeDisplayNameByThemeId[themeId] or themeId
end

function PlayerFacingTexts.formatCountdownSeconds(remainingSeconds: number?): string
	if remainingSeconds == nil then
		return ""
	end
	local wholeSeconds = math.max(0, math.ceil(remainingSeconds))
	return string.format("%d:%02d", wholeSeconds // 60, wholeSeconds % 60)
end

local SAVING_STATUS_TEXT_BY_STATUS = table.freeze({
	NothingSentYet = "Pick items to build your outfit.",
	Saving = "Saving...",
	Saved = "Outfit saved",
	PutBackToLastSaved = "Put back to your last saved outfit",
})

function PlayerFacingTexts.describeDraftSavingStatus(draftSavingStatus: string): string
	return SAVING_STATUS_TEXT_BY_STATUS[draftSavingStatus] or ""
end

local SELECTION_REFUSAL_TEXT_BY_REASON = table.freeze({
	NotInWardrobe = "That item is not in the wardrobe right now.",
	AccessoryLimitReached = "You can wear up to 3 accessories. Take one off first.",
	WouldNotBeValidOutfit = "That combination can't be worn together.",
})

function PlayerFacingTexts.describeSelectionRefusalReason(selectionRefusalReason: string): string
	return SELECTION_REFUSAL_TEXT_BY_REASON[selectionRefusalReason] or ""
end

function PlayerFacingTexts.describeOutfitPutBack(rejectionReason: string?): string
	if rejectionReason == "OutfitInvalid" then
		return "The server could not accept that outfit, so we put back your last saved outfit."
	end
	return "We put back your last saved outfit."
end

function PlayerFacingTexts.formatWholeNumber(wholeNumber: number): string
	local digits = string.format("%d", wholeNumber)
	local sign = ""
	if string.sub(digits, 1, 1) == "-" then
		sign, digits = "-", string.sub(digits, 2)
	end
	local groupedDigits = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	if string.sub(groupedDigits, 1, 1) == "," then
		groupedDigits = string.sub(groupedDigits, 2)
	end
	return sign .. groupedDigits
end

return table.freeze(PlayerFacingTexts)
