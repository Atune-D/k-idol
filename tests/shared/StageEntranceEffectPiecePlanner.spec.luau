-- StageEntranceEffectPiecePlanner: every entrance effect plays once, gently, near the performer,
-- and ends invisible at exactly its duration.

local UnitTestFramework = require("../Support/UnitTestFramework")
local StageEntranceEffectLookCatalog = require("../../src/shared/StageEntranceEffectLookCatalog")
local StageEntranceEffectPiecePlanner = require("../../src/shared/StageEntranceEffectPiecePlanner")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local MAXIMUM_DISTANCE_FROM_FEET_STUDS = 22
-- A piece's visibility may change at most twice: fade in once, fade out once (no blinking).
local MAXIMUM_VISIBILITY_DIRECTION_CHANGES = 2

local function distanceFromFeet(offsetStuds): number
	return math.sqrt(offsetStuds.x ^ 2 + offsetStuds.y ^ 2 + offsetStuds.z ^ 2)
end

local function countTransparencyDirectionChanges(waypoints): number
	local directionChangeCount, previousDirection = 0, 0
	for waypointIndex = 2, #waypoints do
		local difference = waypoints[waypointIndex].transparency - waypoints[waypointIndex - 1].transparency
		local direction = if difference > 0 then 1 elseif difference < 0 then -1 else 0
		if direction ~= 0 and direction ~= previousDirection then
			directionChangeCount += 1
			previousDirection = direction
		end
	end
	return directionChangeCount
end

describe("StageEntranceEffectPiecePlanner", function()
	for _, look in StageEntranceEffectLookCatalog.STAGE_ENTRANCE_EFFECT_LOOKS do
		it("plans " .. look.stageEntranceEffectCosmeticId .. " as a single gentle play", function()
			local plan = StageEntranceEffectPiecePlanner.planStageEntranceEffect(look)
			expect(plan.totalDurationSeconds).toBe(look.effectDurationSeconds)
			expect(#plan.pieces).toBe(look.pieceCount)
			for pieceIndex, plannedPiece in plan.pieces do
				expect(plannedPiece.pieceNumber).toBe(pieceIndex)
				expect(plannedPiece.colorRgb).toBe(look.pieceColorRgbs[(pieceIndex - 1) % #look.pieceColorRgbs + 1])
				local waypoints = plannedPiece.waypoints
				expect(waypoints[1].atSeconds).toBe(0)
				expect(waypoints[1].transparency).toBe(1)
				expect(waypoints[#waypoints].atSeconds).toBe(look.effectDurationSeconds)
				expect(waypoints[#waypoints].transparency).toBe(1)
				for waypointIndex, plannedWaypoint in waypoints do
					if waypointIndex > 1 then
						expect(plannedWaypoint.atSeconds >= waypoints[waypointIndex - 1].atSeconds).toBeTrue()
					end
					expect(plannedWaypoint.atSeconds <= look.effectDurationSeconds).toBeTrue()
					expect(plannedWaypoint.transparency == 1 or plannedWaypoint.transparency == look.pieceTransparency).toBeTrue()
					expect(distanceFromFeet(plannedWaypoint.offsetStuds) <= MAXIMUM_DISTANCE_FROM_FEET_STUDS).toBeTrue()
				end
				expect(countTransparencyDirectionChanges(waypoints) <= MAXIMUM_VISIBILITY_DIRECTION_CHANGES).toBeTrue()
			end
			if look.light == nil then
				expect(plan.lightBrightnessKeyframes).toBeNil()
			else
				local keyframes = plan.lightBrightnessKeyframes
				expect(keyframes[1]).toEqual({ atSeconds = 0, brightness = 0 })
				expect(keyframes[2].brightness).toBe(look.light.peakBrightness)
				expect(keyframes[2].atSeconds >= 0.4).toBeTrue()
				expect(keyframes[3]).toEqual({ atSeconds = look.effectDurationSeconds, brightness = 0 })
				expect(#keyframes).toBe(3)
			end
		end)
	end

	it("is deterministic: the same look gives the same plan", function()
		local look = StageEntranceEffectLookCatalog.findStageEntranceEffectLook("entrance_fireworks_finale")
		expect(StageEntranceEffectPiecePlanner.planStageEntranceEffect(look)).toEqual(
			StageEntranceEffectPiecePlanner.planStageEntranceEffect(look)
		)
	end)

	it("moves the pieces of each motion the way its name says", function()
		local function firstVisibleAndLastOffsets(cosmeticId: string, pieceNumber: number)
			local plan = StageEntranceEffectPiecePlanner.planStageEntranceEffect(
				StageEntranceEffectLookCatalog.findStageEntranceEffectLook(cosmeticId)
			)
			local waypoints = plan.pieces[pieceNumber].waypoints
			return waypoints[2].offsetStuds, waypoints[#waypoints].offsetStuds
		end
		local fallStart, fallEnd = firstVisibleAndLastOffsets("entrance_heart_shower", 3)
		expect(fallStart.y > fallEnd.y + 5).toBeTrue()
		local riseStart, riseEnd = firstVisibleAndLastOffsets("entrance_bubble_burst", 3)
		expect(riseEnd.y > riseStart.y + 5).toBeTrue()
		local burstStart, burstEnd = firstVisibleAndLastOffsets("entrance_confetti_pop", 5)
		expect(distanceFromFeet({ x = burstEnd.x, y = burstEnd.y - burstStart.y, z = burstEnd.z }) > 3).toBeTrue()
		local cometStart, cometEnd = firstVisibleAndLastOffsets("entrance_comet_arrival", 1)
		expect(cometStart.y > 10 and cometEnd.y < 1).toBeTrue()
		local sweepStart, sweepEnd = firstVisibleAndLastOffsets("entrance_neon_laser_sweep", 1)
		expect(math.abs(sweepEnd.x - sweepStart.x) > 8 and sweepStart.z < 0).toBeTrue()
	end)

	it("raises for an unknown motion", function()
		local look = table.clone(StageEntranceEffectLookCatalog.findStageEntranceEffectLook("entrance_confetti_pop"))
		look.pieceMotion = "Strobe"
		expect(function()
			StageEntranceEffectPiecePlanner.planStageEntranceEffect(look)
		end).toThrow("unknown pieceMotion Strobe")
	end)
end)
