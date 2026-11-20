-- CharacterSpawnAppearanceDecider (development spec v1.3 §2.4 "Respawn", §3.7; referee audit PART 1
-- question 23, PART 2 item o): decides what a player's character should look like at the moment
-- it spawns (on joining, after a reset, after falling out of the world). It only DECIDES;
-- applying the appearance to a character is the character dresser's job.
--
-- The §2.4 table, read at the moment of spawn (not of the reset):
--   Participant, during Showcase   the scored outfit, their stage place, their dance restarted
--   Participant, during Styling    lobby appearance; the device re-applies its draft preview
--   Anything else                  lobby appearance
-- Gaps the table leaves open (audit question 23):
--   * Save not loaded: lobby appearance with an EMPTY outfit (the player's own avatar), checked
--     first, whatever the round says. Never an error.
--   * Save loaded but the lobby outfit not known yet (wearableLobbyOutfitStylingItemKeys nil,
--     for example a dresser that runs before StoredLobbyOutfitKeeper in the same loaded event):
--     the EMPTY outfit stands in for the lobby appearance, the round decides the rest. No error.
--   * A participant on stage whose scored outfit is empty: their stage place and dance, in the
--     lobby appearance (owner decision shouldShowLobbyAppearanceOnStageForEmptyScoredOutfit;
--     the alternative applies the empty scored outfit).
--   * A participant in Showcase who has no stage entry (not scored) gets the lobby appearance.
-- 🔴 A spawn never changes what was or will be scored: this module only reads the facts it is
-- given (ThemedRoundReferee:readCharacterSpawnRoundFacts is itself read-only) and hands back
-- frozen values.
-- Pure logic: no Roblox-specific interface is used.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- CharacterSpawnAppearanceDecider.CHARACTER_SPAWN_APPEARANCE_CASES   frozen:
--   ScoredOutfitOnStage          participant during Showcase with a non-empty scored outfit
--   LobbyAppearanceOnStage       participant during Showcase with an empty scored outfit (Q23)
--   LobbyAppearanceWhileStyling  participant during Styling
--   LobbyAppearance              everyone and everything else, including save not loaded
--
-- CharacterSpawnAppearanceDecider.decideCharacterSpawnAppearance(characterSpawnFacts, ownerDecisions?)
--   -> CharacterSpawnAppearance
--   characterSpawnFacts = {
--     isPlayerSaveDataLoaded: boolean,
--     wearableLobbyOutfitStylingItemKeys: { string }?,   the §2.4 lobby appearance (normally
--         StoredLobbyOutfitKeeper's wearableLobbyOutfitStylingItemKeys; {} = own avatar). Not
--         read when the save is not loaded; nil means "not known yet" and counts as {}.
--     characterSpawnRoundFacts: ThemedRoundReferee:readCharacterSpawnRoundFacts(playerUserId),
--   }
--   ownerDecisions: optional, ThemedRoundOwnerDecisions shape (default DEFAULT_OWNER_DECISIONS).
--   CharacterSpawnAppearance = {   frozen
--     characterSpawnAppearanceCase: one of the four cases,
--     outfitStylingItemKeysToWear: { string },   frozen; a copy, never the caller's list
--     stagePlaceNumber: number?,                 only for the two "OnStage" cases
--     shouldRestartDance: boolean,               true only for the two "OnStage" cases
--   }
-- ════════════════════════════════════════════════════════════════════════════════════════════

local ThemedRoundOwnerDecisions = require("./ThemedRoundOwnerDecisions")
local ThemedRoundProtocol = require("../shared/ThemedRoundProtocol")

local ROUND_PHASES = ThemedRoundProtocol.ROUND_PHASES

local CharacterSpawnAppearanceDecider = {}

CharacterSpawnAppearanceDecider.CHARACTER_SPAWN_APPEARANCE_CASES = table.freeze({
	ScoredOutfitOnStage = "ScoredOutfitOnStage",
	LobbyAppearanceOnStage = "LobbyAppearanceOnStage",
	LobbyAppearanceWhileStyling = "LobbyAppearanceWhileStyling",
	LobbyAppearance = "LobbyAppearance",
})

local CHARACTER_SPAWN_APPEARANCE_CASES = CharacterSpawnAppearanceDecider.CHARACTER_SPAWN_APPEARANCE_CASES
local EMPTY_OUTFIT_STYLING_ITEM_KEYS = table.freeze({})

local function copyOutfitAsFrozenList(outfitStylingItemKeys: { string }): { string }
	return table.freeze(table.move(outfitStylingItemKeys, 1, #outfitStylingItemKeys, 1, {}))
end

local function buildCharacterSpawnAppearance(
	characterSpawnAppearanceCase: string,
	outfitStylingItemKeysToWear: { string },
	stagePlaceNumber: number?
)
	return table.freeze({
		characterSpawnAppearanceCase = characterSpawnAppearanceCase,
		outfitStylingItemKeysToWear = outfitStylingItemKeysToWear,
		stagePlaceNumber = stagePlaceNumber,
		shouldRestartDance = stagePlaceNumber ~= nil,
	})
end

function CharacterSpawnAppearanceDecider.decideCharacterSpawnAppearance(characterSpawnFacts, ownerDecisions: any?)
	local chosenOwnerDecisions = ownerDecisions or ThemedRoundOwnerDecisions.DEFAULT_OWNER_DECISIONS
	if not characterSpawnFacts.isPlayerSaveDataLoaded then
		return buildCharacterSpawnAppearance(
			CHARACTER_SPAWN_APPEARANCE_CASES.LobbyAppearance,
			EMPTY_OUTFIT_STYLING_ITEM_KEYS
		)
	end
	local wearableLobbyOutfitStylingItemKeys = characterSpawnFacts.wearableLobbyOutfitStylingItemKeys
	local lobbyOutfitStylingItemKeys = if wearableLobbyOutfitStylingItemKeys == nil
		then EMPTY_OUTFIT_STYLING_ITEM_KEYS
		else copyOutfitAsFrozenList(wearableLobbyOutfitStylingItemKeys)
	local characterSpawnRoundFacts = characterSpawnFacts.characterSpawnRoundFacts
	if not characterSpawnRoundFacts.isParticipant then
		return buildCharacterSpawnAppearance(
			CHARACTER_SPAWN_APPEARANCE_CASES.LobbyAppearance,
			lobbyOutfitStylingItemKeys
		)
	end

	local roundPhase = characterSpawnRoundFacts.roundPhase
	local showcaseStageEntry = characterSpawnRoundFacts.showcaseStageEntry
	if roundPhase == ROUND_PHASES.Showcase and showcaseStageEntry ~= nil then
		local scoredOutfitStylingItemKeys = showcaseStageEntry.scoredOutfitStylingItemKeys
		if
			#scoredOutfitStylingItemKeys == 0
			and chosenOwnerDecisions.shouldShowLobbyAppearanceOnStageForEmptyScoredOutfit
		then
			return buildCharacterSpawnAppearance(
				CHARACTER_SPAWN_APPEARANCE_CASES.LobbyAppearanceOnStage,
				lobbyOutfitStylingItemKeys,
				showcaseStageEntry.stagePlaceNumber
			)
		end
		return buildCharacterSpawnAppearance(
			CHARACTER_SPAWN_APPEARANCE_CASES.ScoredOutfitOnStage,
			copyOutfitAsFrozenList(scoredOutfitStylingItemKeys),
			showcaseStageEntry.stagePlaceNumber
		)
	end
	if roundPhase == ROUND_PHASES.Styling then
		return buildCharacterSpawnAppearance(
			CHARACTER_SPAWN_APPEARANCE_CASES.LobbyAppearanceWhileStyling,
			lobbyOutfitStylingItemKeys
		)
	end
	return buildCharacterSpawnAppearance(CHARACTER_SPAWN_APPEARANCE_CASES.LobbyAppearance, lobbyOutfitStylingItemKeys)
end

return table.freeze(CharacterSpawnAppearanceDecider)
