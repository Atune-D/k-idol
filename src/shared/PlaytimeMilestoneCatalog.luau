-- Playtime milestones (development spec §1.8, `PLAYTIME_MILESTONES`): cumulative minutes played in
-- one UTC day → Star Coins paid when the player claims that milestone. Total 430 per day. Unclaimed
-- milestones are lost at the day boundary (the whole dailyProgress table is replaced, spec §1.10).
--
-- The numbers are fixed by the spec. Playtime rewards are fixed amounts, never random (spec §5.4).
-- Pure data: no Roblox-specific interface is used.

export type PlaytimeMilestone = {
	milestoneMinutes: number,
	starCoinReward: number,
}

local SECONDS_PER_MINUTE = 60

local function definePlaytimeMilestone(milestoneMinutes: number, starCoinReward: number): PlaytimeMilestone
	return table.freeze({
		milestoneMinutes = milestoneMinutes,
		starCoinReward = starCoinReward,
	})
end

local PlaytimeMilestoneCatalog = {}

-- In ascending order of minutes.
PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES = table.freeze({
	definePlaytimeMilestone(5, 20),
	definePlaytimeMilestone(10, 30),
	definePlaytimeMilestone(20, 50),
	definePlaytimeMilestone(30, 80),
	definePlaytimeMilestone(45, 100),
	definePlaytimeMilestone(60, 150),
})

local playtimeMilestoneByMilestoneMinutes: { [number]: PlaytimeMilestone } = {}
for _, playtimeMilestone in PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES do
	playtimeMilestoneByMilestoneMinutes[playtimeMilestone.milestoneMinutes] = playtimeMilestone
end
table.freeze(playtimeMilestoneByMilestoneMinutes)

-- Returns the milestone for exactly these minutes, or nil for anything else (including untrusted
-- non-number values sent by a device, NaN and in-between minutes). Reading a table with any key,
-- nil and NaN included, only returns nil, and the table's keys are numbers, so no guard is needed.
function PlaytimeMilestoneCatalog.findPlaytimeMilestoneByMilestoneMinutes(milestoneMinutes: any): PlaytimeMilestone?
	return playtimeMilestoneByMilestoneMinutes[milestoneMinutes]
end

-- How many seconds of play today a milestone needs.
function PlaytimeMilestoneCatalog.calculateRequiredPlaytimeSecondsForMilestone(
	playtimeMilestone: PlaytimeMilestone
): number
	return playtimeMilestone.milestoneMinutes * SECONDS_PER_MINUTE
end

return table.freeze(PlaytimeMilestoneCatalog)
