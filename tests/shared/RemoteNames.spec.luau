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

-- Spec §2, copied by hand: the channels marked "server -> every device", "server -> that device"
-- or "server -> the owning device". Every other channel of §2 is sent by a device ("device asks,
-- server answers" or "device tells server").
local SPEC_SERVER_SENT_REMOTE_CHANNEL_NAMES = {
	"RoundStateChanged", -- §2.1
	"RoundOutfitDraftAcknowledged", -- §2.3
	"RoundResultsPublished", -- §2.5
	"PlayerSaveDataSnapshotChanged", -- §2.6
	"WardrobeCatalogChanged", -- §2.14
}

local function listSortedSetMembers(remoteChannelNameSet: { [string]: boolean }): { string }
	local sortedSetMembers = {}
	for remoteChannelName, isMember in remoteChannelNameSet do
		expect(isMember).toBe(true)
		table.insert(sortedSetMembers, remoteChannelName)
	end
	table.sort(sortedSetMembers)
	return sortedSetMembers
end

local function listSortedSpecDeviceSentRemoteChannelNames(): { string }
	local specDeviceSentRemoteChannelNames = {}
	for _, specRemoteChannelName in SPEC_REMOTE_CHANNEL_NAMES do
		if not table.find(SPEC_SERVER_SENT_REMOTE_CHANNEL_NAMES, specRemoteChannelName) then
			table.insert(specDeviceSentRemoteChannelNames, specRemoteChannelName)
		end
	end
	table.sort(specDeviceSentRemoteChannelNames)
	return specDeviceSentRemoteChannelNames
end

describe("RemoteNames channel directions (spec §2)", function()
	local DEVICE_SENT = RemoteNames.DEVICE_SENT_REMOTE_CHANNEL_NAME_SET
	local SERVER_SENT = RemoteNames.SERVER_SENT_REMOTE_CHANNEL_NAME_SET

	it("puts every channel in exactly one of the two direction sets", function()
		for remoteChannelName in RemoteNames.REMOTE_CHANNEL_NAMES do
			local isDeviceSent = rawget(DEVICE_SENT, remoteChannelName) == true
			local isServerSent = rawget(SERVER_SENT, remoteChannelName) == true
			if isDeviceSent == isServerSent then
				error(
					string.format(
						"%s is device-sent=%s and server-sent=%s; it must be in exactly one set",
						remoteChannelName,
						tostring(isDeviceSent),
						tostring(isServerSent)
					)
				)
			end
		end
	end)

	it("lists only defined channels in either set", function()
		for _, remoteChannelNameSet in { DEVICE_SENT, SERVER_SENT } do
			for remoteChannelName in remoteChannelNameSet do
				expect(rawget(RemoteNames.REMOTE_CHANNEL_NAMES, remoteChannelName)).toBe(remoteChannelName)
			end
		end
	end)

	it("matches the directions of spec §2: 5 channels the server sends on, 16 a device sends on", function()
		local sortedSpecServerSentRemoteChannelNames = table.clone(SPEC_SERVER_SENT_REMOTE_CHANNEL_NAMES)
		table.sort(sortedSpecServerSentRemoteChannelNames)
		expect(listSortedSetMembers(SERVER_SENT)).toEqual(sortedSpecServerSentRemoteChannelNames)
		expect(listSortedSetMembers(DEVICE_SENT)).toEqual(listSortedSpecDeviceSentRemoteChannelNames())
		expect(#listSortedSetMembers(SERVER_SENT)).toBe(5)
		expect(#listSortedSetMembers(DEVICE_SENT)).toBe(16)
	end)

	it("reads a known channel of the other direction as nil", function()
		expect(DEVICE_SENT.RoundStateChanged).toBeNil()
		expect(SERVER_SENT.SetRoundOutfitDraft).toBeNil()
		expect(DEVICE_SENT.SetRoundOutfitDraft).toBe(true)
		expect(SERVER_SENT.RoundStateChanged).toBe(true)
	end)

	it("raises naming the name when a name that is not a channel is read from either set", function()
		expect(function()
			return (DEVICE_SENT :: any).RequestJoinCurentRound
		end).toThrow('unknown remote channel "RequestJoinCurentRound"')
		expect(function()
			return (SERVER_SENT :: any).RoundStateChagned
		end).toThrow('unknown remote channel "RoundStateChagned"')
	end)

	it("cannot be changed at run time", function()
		for _, remoteChannelNameSet in { DEVICE_SENT, SERVER_SENT } do
			expect(table.isfrozen(remoteChannelNameSet)).toBeTrue()
			expect(function()
				(remoteChannelNameSet :: any).RoundStateChanged = true
			end).toThrow()
			expect(function()
				(remoteChannelNameSet :: any).SetRoundOutfitDraft = nil
			end).toThrow()
		end
	end)
end)

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

describe("RemoteNames channel kinds (how each channel travels)", function()
	local KINDS = RemoteNames.REMOTE_CHANNEL_KINDS
	local KIND_BY_NAME = RemoteNames.REMOTE_CHANNEL_KIND_BY_REMOTE_CHANNEL_NAME

	-- Spec §2.3, copied by hand: the one channel a device sends without waiting for an answer.
	local SPEC_DEVICE_MESSAGES_WITHOUT_ANSWER = { "SetRoundOutfitDraft" }

	it("gives every server-sent channel the ServerMessage kind", function()
		for _, remoteChannelName in SPEC_SERVER_SENT_REMOTE_CHANNEL_NAMES do
			expect(KIND_BY_NAME[remoteChannelName]).toBe(KINDS.ServerMessage)
		end
	end)

	it("gives SetRoundOutfitDraft the message kind and every other device channel the request kind", function()
		local requestChannelCount = 0
		for _, remoteChannelName in listSortedSpecDeviceSentRemoteChannelNames() do
			if table.find(SPEC_DEVICE_MESSAGES_WITHOUT_ANSWER, remoteChannelName) then
				expect(KIND_BY_NAME[remoteChannelName]).toBe(KINDS.DeviceMessageWithoutAnswer)
			else
				expect(KIND_BY_NAME[remoteChannelName]).toBe(KINDS.DeviceRequestWithServerAnswer)
				requestChannelCount += 1
			end
		end
		expect(requestChannelCount).toBe(15)
	end)

	it("has exactly one known kind for every channel and nothing else", function()
		local kindCount = 0
		for remoteChannelName, remoteChannelKind in KIND_BY_NAME do
			expect(rawget(RemoteNames.REMOTE_CHANNEL_NAMES, remoteChannelName)).toBe(remoteChannelName)
			expect(rawget(KINDS, remoteChannelKind)).toBe(remoteChannelKind)
			kindCount += 1
		end
		expect(kindCount).toBe(#SPEC_REMOTE_CHANNEL_NAMES)
	end)

	it("maps requests to RemoteFunction and every other kind to RemoteEvent", function()
		local CLASS_BY_KIND = RemoteNames.ROBLOX_REMOTE_INSTANCE_CLASS_NAME_BY_REMOTE_CHANNEL_KIND
		expect(CLASS_BY_KIND.DeviceRequestWithServerAnswer).toBe("RemoteFunction")
		expect(CLASS_BY_KIND.DeviceMessageWithoutAnswer).toBe("RemoteEvent")
		expect(CLASS_BY_KIND.ServerMessage).toBe("RemoteEvent")
		local kindCount = 0
		for _ in KINDS do
			kindCount += 1
		end
		expect(kindCount).toBe(3)
	end)

	it("raises naming the name when the kind of a name that is not a channel is read", function()
		expect(function()
			return (KIND_BY_NAME :: any).RequestJoinCurentRound
		end).toThrow('unknown remote channel "RequestJoinCurentRound"')
	end)

	it("cannot be changed at run time", function()
		expect(table.isfrozen(KINDS)).toBeTrue()
		expect(table.isfrozen(KIND_BY_NAME)).toBeTrue()
		expect(table.isfrozen(RemoteNames.ROBLOX_REMOTE_INSTANCE_CLASS_NAME_BY_REMOTE_CHANNEL_KIND)).toBeTrue()
	end)
end)
