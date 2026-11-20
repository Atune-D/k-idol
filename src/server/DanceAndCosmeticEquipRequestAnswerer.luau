-- DanceAndCosmeticEquipRequestAnswerer (development spec v1.3 §1.10 `equippedDanceId`,
-- `equippedCosmeticIdByKind`, §2.8 rows `RequestEquipDance` and `RequestEquipCosmetic`, §2.13,
-- §3.4 "After an appearance change (equip, lobby outfit): no save is requested"): equips a dance
-- or a cosmetic the player owns.
--
-- An equip is one PlayerSaveDataKeeper change of kind "AppearanceChangeSavedLater": no save is
-- requested, the change is written by the next save of any kind. Ownership is checked inside that
-- same change, against the current save. Equipping what is already equipped is accepted and
-- changes nothing (§2.13): the keeper reports "AppliedWithoutAnyDifference", so there is no
-- revision bump, no save and no snapshot event.
--
-- Calls no Roblox-specific interface. Everything external is injected (see `new`).
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (the server wiring is written from this)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- DanceAndCosmeticEquipRequestAnswerer.new(dependencies) -> equipRequestAnswerer
--   dependencies = {
--     playerSaveDataKeeper: PlayerSaveDataKeeper   (isPlayerSaveDataLoaded and
--                                                   applyChangeToPlayerSaveData are used),
--     playerRequestRateLimiter: PlayerRequestRateLimiter (only admitOrRefusePlayerRequest is used),
--     danceCatalog: DanceCatalogForShop,           -- see DanceAndCosmeticCatalogEntryFinder;
--     cosmeticCatalog: CosmeticCatalogForShop,     -- normally src/shared/DanceCatalog / CosmeticCatalog
--     logger: { logInformation: (self, message: string) -> (), logWarning: (self, message: string) -> () },
--   }
--   Raises, naming it, when any dependency is missing, or when a catalog lacks its lookup
--   function (DanceAndCosmeticRequestScreening.checkDanceAndCosmeticDependenciesPresent).
--
-- DanceAndCosmeticEquipRequestAnswerer.EQUIP_REJECTION_REASONS (frozen):
--   DanceNotOwned, CosmeticNotOwned, SaveDataNotLoaded, TooManyRequests.
--
-- equipRequestAnswerer:equipOwnedDanceAndBuildAnswer(playerUserId, untrustedDanceId) -> answer
--   Answers `RequestEquipDance`; on acceptance sets `equippedDanceId`.
-- equipRequestAnswerer:equipOwnedCosmeticAndBuildAnswer(playerUserId, untrustedCosmeticId) -> answer
--   Answers `RequestEquipCosmetic`; on acceptance sets `equippedCosmeticIdByKind[<the catalog's
--   cosmeticKind>]`, leaving the other kinds as they are.
--
--   Steps, in order; the first that refuses gives the answer and nothing after it runs
--   (steps 1-3 are DanceAndCosmeticRequestScreening):
--     1. playerRequestRateLimiter:admitOrRefusePlayerRequest(playerUserId, <the request's channel
--        name from RemoteNames>). On refusal: its rejectionReason ("TooManyRequests"); the id is
--        not looked at and nothing else is asked.
--     2. Save not loaded: "SaveDataNotLoaded".
--     3. The id names no catalog entry usable for equipping (DanceAndCosmeticCatalogEntryFinder,
--        use "Equip": the price is not looked at; a cosmetic's kind must be one of spec §1.7):
--          * not a string of 1..64 bytes: "DanceNotOwned" / "CosmeticNotOwned", nothing else is
--            asked (the spec gives equip no "Unknown..." reason);
--          * otherwise, inside one keeper change: if the id is owned AND is the one currently
--            equipped (`equippedDanceId`, or any value of `equippedCosmeticIdByKind`), the
--            request is accepted and the save is left exactly as it is (§2.13: equipping what is
--            already equipped; no revision bump, no save, no event). In every other case
--            (never in the catalog; owned but its entry was removed or is unusable; not owned):
--            "DanceNotOwned" / "CosmeticNotOwned", nothing changes. An owned id whose entry was
--            removed stays in ownedDanceIds / ownedCosmeticIds untouched (no progress is lost;
--            it becomes equippable again if the entry returns).
--     4. Inside one keeper change: the id is not in ownedDanceIds / ownedCosmeticIds ->
--        "DanceNotOwned" / "CosmeticNotOwned", nothing changes. Otherwise it is equipped; only
--        `equippedDanceId` or the one `equippedCosmeticIdByKind` key changes.
--        If it was already equipped the save is left exactly as it is (accepted, no revision bump,
--        no save, no event). A keeper that finds the save not loaded -> "SaveDataNotLoaded".
--   answer = { isAccepted = true }
--          | { isAccepted = false, rejectionReason = <one of EQUIP_REJECTION_REASONS> }
--   A fresh table every time; the caller may change it.
--   Logging: this module logs nothing itself; the finder warns about an unusable catalog entry
--   (naming the device's string, at most 64 bytes, escaped). Nothing the device sent is echoed back.
-- ════════════════════════════════════════════════════════════════════════════════════════════

local DanceAndCosmeticCatalogEntryFinder = require("./DanceAndCosmeticCatalogEntryFinder")
local DanceAndCosmeticRequestScreening = require("./DanceAndCosmeticRequestScreening")
local PlayerSaveDataKeeper = require("./PlayerSaveDataKeeper")
local RemoteNames = require("../shared/RemoteNames")

local REMOTE_CHANNEL_NAMES = RemoteNames.REMOTE_CHANNEL_NAMES
local SCREENING_OUTCOMES = DanceAndCosmeticRequestScreening.SCREENING_OUTCOMES
local buildRejectedAnswer = DanceAndCosmeticRequestScreening.buildRejectedAnswer

local DanceAndCosmeticEquipRequestAnswerer = {}
DanceAndCosmeticEquipRequestAnswerer.__index = DanceAndCosmeticEquipRequestAnswerer

DanceAndCosmeticEquipRequestAnswerer.EQUIP_REJECTION_REASONS = table.freeze({
	DanceNotOwned = "DanceNotOwned",
	CosmeticNotOwned = "CosmeticNotOwned",
	SaveDataNotLoaded = "SaveDataNotLoaded",
	TooManyRequests = "TooManyRequests",
})

local EQUIP_REJECTION_REASONS = DanceAndCosmeticEquipRequestAnswerer.EQUIP_REJECTION_REASONS

local REQUIRED_DEPENDENCY_NAMES = table.freeze({
	"playerSaveDataKeeper",
	"playerRequestRateLimiter",
	"danceCatalog",
	"cosmeticCatalog",
	"logger",
})

-- Everything that differs between the two equip requests.
type DanceOrCosmeticEquipRequestSettings = {
	remoteChannelName: string,
	danceOrCosmeticFamily: DanceAndCosmeticRequestScreening.DanceOrCosmeticFamily,
	notOwnedRejectionReason: string,
	equipChangeDescriptionPrefix: string,
	writeEquippedEntryIntoSaveDataDraft: (saveDataDraft: any, catalogEntry: any) -> (),
	isIdCurrentlyEquippedInSaveData: (saveData: any, danceOrCosmeticId: string) -> boolean,
}

local DANCE_EQUIP_REQUEST_SETTINGS: DanceOrCosmeticEquipRequestSettings = table.freeze({
	remoteChannelName = REMOTE_CHANNEL_NAMES.RequestEquipDance,
	danceOrCosmeticFamily = DanceAndCosmeticRequestScreening.DANCE_FAMILY,
	notOwnedRejectionReason = EQUIP_REJECTION_REASONS.DanceNotOwned,
	equipChangeDescriptionPrefix = "equip dance",
	writeEquippedEntryIntoSaveDataDraft = function(saveDataDraft, danceEntry)
		saveDataDraft.equippedDanceId = danceEntry.danceId
	end,
	isIdCurrentlyEquippedInSaveData = function(saveData, danceId: string): boolean
		return saveData.equippedDanceId == danceId
	end,
})

local COSMETIC_EQUIP_REQUEST_SETTINGS: DanceOrCosmeticEquipRequestSettings = table.freeze({
	remoteChannelName = REMOTE_CHANNEL_NAMES.RequestEquipCosmetic,
	danceOrCosmeticFamily = DanceAndCosmeticRequestScreening.COSMETIC_FAMILY,
	notOwnedRejectionReason = EQUIP_REJECTION_REASONS.CosmeticNotOwned,
	equipChangeDescriptionPrefix = "equip cosmetic",
	writeEquippedEntryIntoSaveDataDraft = function(saveDataDraft, cosmeticEntry)
		saveDataDraft.equippedCosmeticIdByKind[cosmeticEntry.cosmeticKind] = cosmeticEntry.cosmeticId
	end,
	isIdCurrentlyEquippedInSaveData = function(saveData, cosmeticId: string): boolean
		for _, equippedCosmeticId in saveData.equippedCosmeticIdByKind do
			if equippedCosmeticId == cosmeticId then
				return true
			end
		end
		return false
	end,
})

function DanceAndCosmeticEquipRequestAnswerer.new(dependencies)
	DanceAndCosmeticRequestScreening.checkDanceAndCosmeticDependenciesPresent(
		"DanceAndCosmeticEquipRequestAnswerer",
		dependencies,
		REQUIRED_DEPENDENCY_NAMES
	)
	return setmetatable({
		playerSaveDataKeeper = dependencies.playerSaveDataKeeper,
		playerRequestRateLimiter = dependencies.playerRequestRateLimiter,
		danceCatalog = dependencies.danceCatalog,
		cosmeticCatalog = dependencies.cosmeticCatalog,
		logger = dependencies.logger,
	}, DanceAndCosmeticEquipRequestAnswerer)
end

-- Runs one appearance change and turns the keeper's outcome into the answer.
local function applyEquipChangeAndBuildAnswer(
	self,
	equipRequestSettings: DanceOrCosmeticEquipRequestSettings,
	playerUserId: number,
	danceOrCosmeticId: string,
	decideAndApplyEquipChange: (saveDataDraft: any) -> (boolean, string?)
)
	local changeResult = self.playerSaveDataKeeper:applyChangeToPlayerSaveData(
		playerUserId,
		PlayerSaveDataKeeper.APPEARANCE_CHANGE_SAVED_LATER,
		equipRequestSettings.equipChangeDescriptionPrefix .. " " .. danceOrCosmeticId,
		decideAndApplyEquipChange
	)
	local changeOutcome = changeResult.changeOutcome
	if changeOutcome == "Applied" or changeOutcome == "AppliedWithoutAnyDifference" then
		return { isAccepted = true }
	end
	if changeOutcome == "SaveDataNotLoaded" then
		return buildRejectedAnswer(EQUIP_REJECTION_REASONS.SaveDataNotLoaded)
	end
	return buildRejectedAnswer(equipRequestSettings.notOwnedRejectionReason)
end

-- No usable catalog entry: only "equip what is owned and already equipped" is accepted, as a
-- change that leaves the save exactly as it is (§2.13).
local function acceptOnlyReequipOfEquippedIdAndBuildAnswer(
	self,
	equipRequestSettings: DanceOrCosmeticEquipRequestSettings,
	playerUserId: number,
	untrustedDanceOrCosmeticId: any
)
	if not DanceAndCosmeticCatalogEntryFinder.isLookupWorthyDanceOrCosmeticId(untrustedDanceOrCosmeticId) then
		return buildRejectedAnswer(equipRequestSettings.notOwnedRejectionReason)
	end
	local ownedIdsFieldName = equipRequestSettings.danceOrCosmeticFamily.ownedIdsFieldName
	return applyEquipChangeAndBuildAnswer(
		self,
		equipRequestSettings,
		playerUserId,
		untrustedDanceOrCosmeticId,
		function(saveDataDraft)
			local isOwnedAndEquipped = table.find(saveDataDraft[ownedIdsFieldName], untrustedDanceOrCosmeticId) ~= nil
				and equipRequestSettings.isIdCurrentlyEquippedInSaveData(saveDataDraft, untrustedDanceOrCosmeticId)
			if not isOwnedAndEquipped then
				return false, equipRequestSettings.notOwnedRejectionReason
			end
			return true
		end
	)
end

local function equipOwnedDanceOrCosmeticAndBuildAnswer(
	self,
	equipRequestSettings: DanceOrCosmeticEquipRequestSettings,
	playerUserId: number,
	untrustedDanceOrCosmeticId: any
)
	local danceOrCosmeticFamily = equipRequestSettings.danceOrCosmeticFamily
	local screeningOutcome, rejectionReasonOrCatalogEntry =
		DanceAndCosmeticRequestScreening.screenRequestAndFindCatalogEntry(
			self,
			danceOrCosmeticFamily,
			equipRequestSettings.remoteChannelName,
			DanceAndCosmeticCatalogEntryFinder.CATALOG_ENTRY_USES.Equip,
			playerUserId,
			untrustedDanceOrCosmeticId
		)
	if screeningOutcome == SCREENING_OUTCOMES.RequestRefused then
		return buildRejectedAnswer(rejectionReasonOrCatalogEntry)
	end
	if screeningOutcome == SCREENING_OUTCOMES.NoUsableCatalogEntry then
		return acceptOnlyReequipOfEquippedIdAndBuildAnswer(
			self,
			equipRequestSettings,
			playerUserId,
			untrustedDanceOrCosmeticId
		)
	end

	local catalogEntry = rejectionReasonOrCatalogEntry
	local equippedDanceOrCosmeticId = catalogEntry[danceOrCosmeticFamily.catalogEntryIdFieldName]
	local ownedIdsFieldName = danceOrCosmeticFamily.ownedIdsFieldName
	return applyEquipChangeAndBuildAnswer(
		self,
		equipRequestSettings,
		playerUserId,
		equippedDanceOrCosmeticId,
		function(saveDataDraft)
			if table.find(saveDataDraft[ownedIdsFieldName], equippedDanceOrCosmeticId) == nil then
				return false, equipRequestSettings.notOwnedRejectionReason
			end
			equipRequestSettings.writeEquippedEntryIntoSaveDataDraft(saveDataDraft, catalogEntry)
			return true
		end
	)
end

function DanceAndCosmeticEquipRequestAnswerer:equipOwnedDanceAndBuildAnswer(playerUserId: number, untrustedDanceId: any)
	return equipOwnedDanceOrCosmeticAndBuildAnswer(self, DANCE_EQUIP_REQUEST_SETTINGS, playerUserId, untrustedDanceId)
end

function DanceAndCosmeticEquipRequestAnswerer:equipOwnedCosmeticAndBuildAnswer(
	playerUserId: number,
	untrustedCosmeticId: any
)
	return equipOwnedDanceOrCosmeticAndBuildAnswer(
		self,
		COSMETIC_EQUIP_REQUEST_SETTINGS,
		playerUserId,
		untrustedCosmeticId
	)
end

return DanceAndCosmeticEquipRequestAnswerer
