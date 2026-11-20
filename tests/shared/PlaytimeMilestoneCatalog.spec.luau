-- Playtime milestone table (development spec §1.8).

local UnitTestFramework = require("../Support/UnitTestFramework")
local PlaytimeMilestoneCatalog = require("../../src/shared/PlaytimeMilestoneCatalog")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

describe("PlaytimeMilestoneCatalog", function()
	it("matches the spec §1.8 table exactly, in ascending order", function()
		expect(PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES).toEqual({
			{ milestoneMinutes = 5, starCoinReward = 20 },
			{ milestoneMinutes = 10, starCoinReward = 30 },
			{ milestoneMinutes = 20, starCoinReward = 50 },
			{ milestoneMinutes = 30, starCoinReward = 80 },
			{ milestoneMinutes = 45, starCoinReward = 100 },
			{ milestoneMinutes = 60, starCoinReward = 150 },
		})
	end)

	it("pays 430 Star Coins in total per day (spec §1.8, §4)", function()
		local totalStarCoinReward = 0
		for _, playtimeMilestone in PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES do
			totalStarCoinReward += playtimeMilestone.starCoinReward
		end
		expect(totalStarCoinReward).toBe(430)
	end)

	it("finds each milestone by its exact minutes and nothing else", function()
		for _, playtimeMilestone in PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES do
			expect(PlaytimeMilestoneCatalog.findPlaytimeMilestoneByMilestoneMinutes(playtimeMilestone.milestoneMinutes)).toBe(
				playtimeMilestone
			)
		end
		for _, unknownMilestoneMinutes in { 0, 4, 6, 5.5, 61, 90, -5, 0 / 0, math.huge, "5", nil, {}, true } do
			expect(PlaytimeMilestoneCatalog.findPlaytimeMilestoneByMilestoneMinutes(unknownMilestoneMinutes)).toBeNil()
		end
	end)

	it("a milestone needs its minutes times 60 seconds of play", function()
		local fiveMinuteMilestone = assert(PlaytimeMilestoneCatalog.findPlaytimeMilestoneByMilestoneMinutes(5))
		local hourMilestone = assert(PlaytimeMilestoneCatalog.findPlaytimeMilestoneByMilestoneMinutes(60))
		expect(PlaytimeMilestoneCatalog.calculateRequiredPlaytimeSecondsForMilestone(fiveMinuteMilestone)).toBe(300)
		expect(PlaytimeMilestoneCatalog.calculateRequiredPlaytimeSecondsForMilestone(hourMilestone)).toBe(3600)
	end)

	it("is frozen, milestone by milestone", function()
		expect(table.isfrozen(PlaytimeMilestoneCatalog)).toBeTrue()
		expect(table.isfrozen(PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES)).toBeTrue()
		for _, playtimeMilestone in PlaytimeMilestoneCatalog.PLAYTIME_MILESTONES do
			expect(table.isfrozen(playtimeMilestone)).toBeTrue()
		end
	end)
end)
