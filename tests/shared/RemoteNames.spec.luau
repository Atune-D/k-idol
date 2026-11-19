local UnitTestFramework = require("../Support/UnitTestFramework")
local RemoteNames = require("../../src/shared/RemoteNames")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

-- Every channel named in development spec §2 (Phases 1 and 2), copied by hand.
local SPEC_REMOTE_CHANNEL_NAMES = {
	"RoundStateChanged",
	"RequestJoinCurrentRound",
	"SetRoundOutfitDraft",
	"RoundResultsPublished",
	"PlayerSaveDataSnapshotChanged",
	"SetLobbyOutfit",
	"RequestPurchaseDanceWithStarCoins",
	"RequestPurchaseCosmeticWithStarCoins",
	"RequestEquipDance",
	"RequestEquipCosmetic",
	"RequestStartDanceInLobby",
	"RequestSyncDanceWithPlayer",
	"RequestStopDanceInLobby",
	"RequestClaimPlaytimeMilestone",
	"RequestClaimDailyQuestReward",
	"RequestRedeemPromoCode",
	"RequestFanCountLeaderboardTopEntries",
	-- Added in spec v1.2 (§10, "New channels since the scaffolding was written").
	"RoundOutfitDraftAcknowledged",
	"RequestWardrobeCatalogSnapshot",
	"WardrobeCatalogChanged",
	"RequestStylingItemOwnership",
}

describe("RemoteNames", function()
	it("lists exactly the 21 channels of spec v1.2", function()
		expect(#SPEC_REMOTE_CHANNEL_NAMES).toBe(21)
		local definedRemoteChannelCount = 0
		for _ in RemoteNames.REMOTE_CHANNEL_NAMES do
			definedRemoteChannelCount += 1
		end
		expect(definedRemoteChannelCount).toBe(21)
	end)

	it("places channels in the folder named Remotes (spec §2)", function()
		expect(RemoteNames.REMOTES_FOLDER_NAME).toBe("Remotes")
	end)

	it("defines every channel named in spec §2", function()
		for _, specRemoteChannelName in SPEC_REMOTE_CHANNEL_NAMES do
			expect(rawget(RemoteNames.REMOTE_CHANNEL_NAMES, specRemoteChannelName)).toBe(specRemoteChannelName)
		end
	end)

	it("defines no channel that is not in spec §2", function()
		local definedRemoteChannelNames = {}
		for remoteChannelKey, remoteChannelName in RemoteNames.REMOTE_CHANNEL_NAMES do
			expect(remoteChannelName).toBe(remoteChannelKey)
			table.insert(definedRemoteChannelNames, remoteChannelName)
		end
		local sortedSpecRemoteChannelNames = table.clone(SPEC_REMOTE_CHANNEL_NAMES)
		table.sort(sortedSpecRemoteChannelNames)
		table.sort(definedRemoteChannelNames)
		expect(definedRemoteChannelNames).toEqual(sortedSpecRemoteChannelNames)
	end)

	it("raises an error naming the channel when an unknown channel is read", function()
		expect(function()
			return (RemoteNames.REMOTE_CHANNEL_NAMES :: any).RoundStateChagned
		end).toThrow('unknown remote channel "RoundStateChagned"')
	end)

	it("cannot be changed at run time", function()
		expect(table.isfrozen(RemoteNames)).toBeTrue()
		expect(table.isfrozen(RemoteNames.REMOTE_CHANNEL_NAMES)).toBeTrue()
		expect(function()
			(RemoteNames.REMOTE_CHANNEL_NAMES :: any).InventedChannel = "InventedChannel"
		end).toThrow()
	end)
end)
