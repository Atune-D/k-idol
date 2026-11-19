-- Dances a character can perform (development spec §1.7). Phase 1 holds starter dances only,
-- because the showcase needs a dance to play; purchasable dances arrive in Phase 2.
--
-- `danceAnimationAssetId` is a Roblox content id string ("rbxassetid://<number>") that can be
-- assigned to Animation.AnimationId as it is. An empty string means "animation not chosen yet"
-- (allowed for future owner-made dances; every starter dance has an id).
--
-- Phases 1 and 2 use Roblox's own dance animations as placeholders (spec §3.8). Spec §5.2: only
-- animations owned by Roblox or by the game's owner; no dance named after a song, artist or idol.
-- Owner-made dances are added here as new entries; no other code change is needed.
-- Pure data: no Roblox-specific interface is used.

export type Dance = {
	danceId: string,
	danceDisplayName: string,
	danceAnimationAssetId: string,
	starCoinPrice: number,
	isGrantedToNewPlayers: boolean,
}

local function defineDance(dance: Dance): Dance
	return table.freeze(dance)
end

local DanceCatalog = {}

-- Starter dances (spec §1.7). Their animation ids are the three Roblox-created dance animations
-- listed in spec §3.8 (v1.3): created by Roblox, from the default character animation script,
-- each verified in Roblox Studio to loop for 15 seconds without a visible jump. They are short,
-- basic placeholders until owner-made dances exist. The first entry is equipped for a new player.
DanceCatalog.DANCES = table.freeze({
	defineDance({
		danceId = "starter_groove",
		danceDisplayName = "Starter Groove",
		danceAnimationAssetId = "rbxassetid://507771019", -- spec §3.8
		starCoinPrice = 0,
		isGrantedToNewPlayers = true,
	}),
	defineDance({
		danceId = "starter_bounce",
		danceDisplayName = "Starter Bounce",
		danceAnimationAssetId = "rbxassetid://507776043", -- spec §3.8
		starCoinPrice = 0,
		isGrantedToNewPlayers = true,
	}),
	defineDance({
		danceId = "starter_sway",
		danceDisplayName = "Starter Sway",
		danceAnimationAssetId = "rbxassetid://507777268", -- spec §3.8
		starCoinPrice = 0,
		isGrantedToNewPlayers = true,
	}),
})

local danceByDanceId: { [string]: Dance } = {}
for _, dance in DanceCatalog.DANCES do
	danceByDanceId[dance.danceId] = dance
end
table.freeze(danceByDanceId)

-- Returns the dance with this id, or nil for an unknown id (including non-string values).
function DanceCatalog.findDanceByDanceId(danceId: any): Dance?
	if type(danceId) ~= "string" then
		return nil
	end
	return danceByDanceId[danceId]
end

-- Ids of every dance a new player starts with, in catalog order (spec §1.10: the first one is
-- equipped for a new player).
function DanceCatalog.listDanceIdsGrantedToNewPlayers(): { string }
	local grantedDanceIds = {}
	for _, dance in DanceCatalog.DANCES do
		if dance.isGrantedToNewPlayers then
			table.insert(grantedDanceIds, dance.danceId)
		end
	end
	return grantedDanceIds
end

return table.freeze(DanceCatalog)
