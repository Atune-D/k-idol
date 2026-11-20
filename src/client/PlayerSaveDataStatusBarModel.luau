-- PlayerSaveDataStatusBarModel (development spec §2.6 PlayerSaveDataSnapshotChanged, §5.1): what the
-- always-visible status bar shows, built ONLY from the latest save snapshot message.
-- ⛔ §5.1 / §2.6 🔴: the device never computes or changes a balance; Star Coins and fans shown are
-- exactly the numbers of the latest snapshot. A round reward appears only when the snapshot carrying
-- it arrives, never from RoundResultsPublished.
--   * Before the first snapshot: "..." for both numbers (the save is still loading).
--   * isSaveDataPersistenceDelayed = true shows PERSISTENCE_DELAYED_NOTICE.
--   * A non-empty unavailableLobbyOutfitStylingItemKeys shows UNAVAILABLE_SAVED_OUTFIT_ITEMS_NOTICE.
--   * A message of the wrong shape is ignored (the previous snapshot stays).
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   PlayerSaveDataStatusBarModel.new() -> keeper
--   keeper:receivePlayerSaveDataSnapshot(message) -> boolean   true when it was taken
--   keeper:readStatusBarModel() -> { starCoinBalanceText, fanCountText, noticeTexts = { string } }

local PlayerFacingTexts = require("./PlayerFacingTexts")
local ServerSentMessageShapeReader = require("./ServerSentMessageShapeReader")

local PlayerSaveDataStatusBarModel = {}
PlayerSaveDataStatusBarModel.__index = PlayerSaveDataStatusBarModel

local NOT_LOADED_TEXT = "..."

function PlayerSaveDataStatusBarModel.new()
	return setmetatable({ latestSnapshot = nil }, PlayerSaveDataStatusBarModel)
end

function PlayerSaveDataStatusBarModel:receivePlayerSaveDataSnapshot(message: any): boolean
	local snapshot = ServerSentMessageShapeReader.readPlayerSaveDataSnapshotMessage(message)
	if snapshot == nil then
		return false
	end
	self.latestSnapshot = snapshot
	return true
end

function PlayerSaveDataStatusBarModel:readStatusBarModel()
	local snapshot = self.latestSnapshot
	if snapshot == nil then
		return { starCoinBalanceText = NOT_LOADED_TEXT, fanCountText = NOT_LOADED_TEXT, noticeTexts = {} }
	end
	local noticeTexts = {}
	if snapshot.isSaveDataPersistenceDelayed then
		table.insert(noticeTexts, PlayerFacingTexts.PERSISTENCE_DELAYED_NOTICE)
	end
	if #snapshot.unavailableLobbyOutfitStylingItemKeys > 0 then
		table.insert(noticeTexts, PlayerFacingTexts.UNAVAILABLE_SAVED_OUTFIT_ITEMS_NOTICE)
	end
	return {
		starCoinBalanceText = PlayerFacingTexts.formatWholeNumber(snapshot.shownStarCoinBalance),
		fanCountText = PlayerFacingTexts.formatWholeNumber(snapshot.shownFanCount),
		noticeTexts = noticeTexts,
	}
end

return PlayerSaveDataStatusBarModel
