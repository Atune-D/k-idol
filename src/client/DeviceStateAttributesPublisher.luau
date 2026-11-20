-- DeviceStateAttributesPublisher: copies a few facts of the device's round session onto the screens'
-- ScreenGui as attributes, so a playtest (an engineer, or a Studio check through the Client datamodel)
-- can read what the device believes without a debugger. It changes nothing and is read by nothing in
-- the game.
--
-- Attributes written on the ScreenGui:
--   RoundId (string, "" before any round), RoundPhase, IsParticipant, DraftSavingStatus,
--   LatestSentOutfitDraftSequenceNumber, SelectedStylingItemKeys and LastKeptStylingItemKeys
--   (comma-separated), IsWardrobeUsableNow, ListedWardrobeItemCount.
--
-- PUBLIC API
--   DeviceStateAttributesPublisher.publishSessionSnapshot(screenGui, sessionSnapshot)
--   DeviceStateAttributesPublisher.publishRequestCounts(screenGui, leaderboardRequestCount, wardrobeCatalogRequestCount)
--
-- Roblox API used: Instance:SetAttribute   https://create.roblox.com/docs/reference/engine/classes/Instance

local DeviceStateAttributesPublisher = {}

function DeviceStateAttributesPublisher.publishSessionSnapshot(screenGui: ScreenGui, sessionSnapshot)
	local roundState = sessionSnapshot.roundState
	local view = sessionSnapshot.wardrobeCatalogView
	screenGui:SetAttribute("RoundId", if roundState ~= nil then roundState.roundId else "")
	screenGui:SetAttribute("RoundPhase", if roundState ~= nil then roundState.roundPhase else "")
	screenGui:SetAttribute("IsParticipant", sessionSnapshot.isParticipant)
	screenGui:SetAttribute("DraftSavingStatus", sessionSnapshot.draftSavingStatus)
	screenGui:SetAttribute("LatestSentOutfitDraftSequenceNumber", sessionSnapshot.latestSentOutfitDraftSequenceNumber)
	screenGui:SetAttribute("SelectedStylingItemKeys", table.concat(sessionSnapshot.selectedStylingItemKeys, ","))
	screenGui:SetAttribute("LastKeptStylingItemKeys", table.concat(sessionSnapshot.lastKeptStylingItemKeys, ","))
	screenGui:SetAttribute("IsWardrobeUsableNow", sessionSnapshot.isWardrobeUsableNow)
	screenGui:SetAttribute("ListedWardrobeItemCount", if view ~= nil then #view.listedStylingItemKeys else 0)
end

-- How many requests the device has sent on the two throttled request channels (for checking the
-- 5 s and 2 s intervals in a playtest): attributes LeaderboardRequestCount, WardrobeCatalogRequestCount.
function DeviceStateAttributesPublisher.publishRequestCounts(
	screenGui: ScreenGui,
	leaderboardRequestCount: number,
	wardrobeCatalogRequestCount: number
)
	screenGui:SetAttribute("LeaderboardRequestCount", leaderboardRequestCount)
	screenGui:SetAttribute("WardrobeCatalogRequestCount", wardrobeCatalogRequestCount)
end

-- Phase 2: what the lobby has sent and seen, for checks in a playtest. Attributes written:
--   HasLobbySaveDataSnapshot, LobbyRequestCount_<channel> for every lobby request channel,
--   OwnershipRequestCount, LocalLobbyDanceId ("" when not seen dancing), IsRunningInStudio,
--   BuyButtonPressCount and PurchasePromptOpenCount (how often the wiring asked the engine to open a
--   purchase prompt; it stays 0 in Studio).
function DeviceStateAttributesPublisher.publishLobbyDiagnostics(screenGui: ScreenGui, lobbyDiagnostics, lobbyFacts)
	screenGui:SetAttribute("HasLobbySaveDataSnapshot", lobbyDiagnostics.hasSaveDataSnapshot)
	for channelName, sentCount in lobbyDiagnostics.sentRequestCountByChannelName do
		screenGui:SetAttribute("LobbyRequestCount_" .. channelName, sentCount)
	end
	screenGui:SetAttribute("OwnershipRequestCount", lobbyDiagnostics.ownershipRequestCount)
	screenGui:SetAttribute("LocalLobbyDanceId", lobbyFacts.localLobbyDanceId or "")
	screenGui:SetAttribute("IsRunningInStudio", lobbyFacts.isRunningInStudio)
	screenGui:SetAttribute("BuyButtonPressCount", lobbyFacts.buyButtonPressCount)
	screenGui:SetAttribute("PurchasePromptOpenCount", lobbyFacts.purchasePromptOpenCount)
end

return table.freeze(DeviceStateAttributesPublisher)
