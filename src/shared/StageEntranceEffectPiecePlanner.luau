-- StageEntranceEffectPiecePlanner (development spec §1.7, §2.4): turns a StageEntranceEffectLook
-- into the exact path of every piece and the brightness of the light over time, so the Roblox side
-- (RobloxStageEntranceEffectPlayer) only creates parts and moves them from waypoint to waypoint.
-- Deterministic: the same look always gives the same plan (no random numbers), so every device
-- sees the same effect and tests can check it.
--
-- Coordinates are studs relative to the performer's feet, in the performer's own frame:
-- x = to the side, y = up, z = toward the audience (the direction the performer faces).
-- A Cylinder piece stands upright (its length, pieceSizeStuds.x, is its height).
--
-- Paths (D = effectDurationSeconds; every piece fades in from fully transparent, moves while at the
-- look's pieceTransparency, and ends fully transparent at exactly D, once):
--   BurstOutward    from chest height straight out in all directions (golden-angle spread)
--   FallFromAbove   from 11-14 studs up down to the floor around the performer, staggered
--   RiseFromFloor   from the floor around the performer up to 7-10 studs, staggered
--   SwirlAround     a full turn around the performer, rising from the feet to above the head
--   SweepAcross     upright beams behind the performer, crossing from side to side, alternating
--   DescendFromSky  from high to one side down onto the performer, each piece a little behind
--                   the one before (a comet and its trail)
--   RiseAsCurtain   upright panels in a row behind the performer (one piece: a column around the
--                   performer) rising into place, holding, then fading
-- Light (when the look has one): brightness 0 at the start, the peak at 0.3 * D, 0 again at D.
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   StageEntranceEffectPiecePlanner.planStageEntranceEffect(stageEntranceEffectLook) -> plan   (frozen)
--     plan = { totalDurationSeconds,
--              pieces = { { pieceNumber, colorRgb, waypoints = { { atSeconds, offsetStuds = {x,y,z},
--                           transparency } } } },
--              lightBrightnessKeyframes = { { atSeconds, brightness } }? }
--     Raises for a look whose pieceMotion is not one of StageEntranceEffectLookCatalog.PIECE_MOTIONS.

local StageEntranceEffectPiecePlanner = {}

local GOLDEN_ANGLE_RADIANS = math.pi * (3 - math.sqrt(5))

local function offset(x: number, y: number, z: number)
	return table.freeze({ x = x, y = y, z = z })
end

local function waypoint(atSeconds: number, offsetStuds, transparency: number)
	return table.freeze({ atSeconds = atSeconds, offsetStuds = offsetStuds, transparency = transparency })
end

local function readPieceHeightStuds(look): number
	if look.pieceShape == "Cylinder" then
		return look.pieceSizeStuds.x
	end
	return look.pieceSizeStuds.y
end

-- Each path builder: (look, pieceIndex starting at 0, D, visibleTransparency) -> { waypoint }.
local PATH_BUILDER_BY_PIECE_MOTION = {}

function PATH_BUILDER_BY_PIECE_MOTION.BurstOutward(_look, pieceIndex, D, visible)
	local angle = pieceIndex * GOLDEN_ANGLE_RADIANS
	local elevation = ((pieceIndex % 5) / 4 - 0.5) * 1.2
	local burstRadius = 5
	local outX = math.cos(angle) * math.cos(elevation) * burstRadius
	local outY = 3 + math.sin(elevation) * burstRadius
	local outZ = math.sin(angle) * math.cos(elevation) * burstRadius
	local center = offset(0, 3, 0)
	return {
		waypoint(0, center, 1),
		waypoint(0.1 * D, center, visible),
		waypoint(0.45 * D, offset(outX, outY, outZ), visible),
		waypoint(D, offset(outX, outY - 1.5, outZ), 1),
	}
end

local function ringPoint(pieceIndex: number, y: number)
	local angle = pieceIndex * GOLDEN_ANGLE_RADIANS
	local ringRadius = 1 + (pieceIndex % 5) * 0.7
	return offset(math.cos(angle) * ringRadius, y, math.sin(angle) * ringRadius)
end

function PATH_BUILDER_BY_PIECE_MOTION.FallFromAbove(look, pieceIndex, D, visible)
	local delay = (pieceIndex / look.pieceCount) * 0.35 * D
	local high = ringPoint(pieceIndex, 11 + (pieceIndex % 4))
	local floor = ringPoint(pieceIndex, 0.3)
	return {
		waypoint(0, high, 1),
		waypoint(delay + 0.1 * D, high, visible),
		waypoint(delay + 0.6 * D, floor, visible),
		waypoint(D, floor, 1),
	}
end

function PATH_BUILDER_BY_PIECE_MOTION.RiseFromFloor(look, pieceIndex, D, visible)
	local delay = (pieceIndex / look.pieceCount) * 0.3 * D
	local floor = ringPoint(pieceIndex, 0.3)
	local high = ringPoint(pieceIndex, 7 + (pieceIndex % 4))
	return {
		waypoint(0, floor, 1),
		waypoint(delay + 0.1 * D, floor, visible),
		waypoint(delay + 0.6 * D, high, visible),
		waypoint(D, offset(high.x, high.y + 1, high.z), 1),
	}
end

function PATH_BUILDER_BY_PIECE_MOTION.SwirlAround(look, pieceIndex, D, visible)
	local swirlRadius = 2.5
	local startAngle = pieceIndex * 2 * math.pi / look.pieceCount
	local turnPoints = {}
	for quarterTurn = 0, 4 do
		local angle = startAngle + quarterTurn * math.pi / 2
		turnPoints[quarterTurn] =
			offset(math.cos(angle) * swirlRadius, 0.5 + quarterTurn * 5.5 / 4, math.sin(angle) * swirlRadius)
	end
	return {
		waypoint(0, turnPoints[0], 1),
		waypoint(0.1 * D, turnPoints[0], visible),
		waypoint(0.3 * D, turnPoints[1], visible),
		waypoint(0.5 * D, turnPoints[2], visible),
		waypoint(0.7 * D, turnPoints[3], visible),
		waypoint(0.85 * D, turnPoints[4], visible),
		waypoint(D, turnPoints[4], 1),
	}
end

function PATH_BUILDER_BY_PIECE_MOTION.SweepAcross(look, pieceIndex, D, visible)
	local centerY = readPieceHeightStuds(look) / 2
	local behindZ = -3 - (pieceIndex % 2) * 0.6
	local sideSign = if pieceIndex % 2 == 0 then 1 else -1
	local startX = -8 * sideSign + sideSign * pieceIndex * 0.8
	local endX = 8 * sideSign - sideSign * (look.pieceCount - 1 - pieceIndex) * 0.8
	return {
		waypoint(0, offset(startX, centerY, behindZ), 1),
		waypoint(0.15 * D, offset(startX, centerY, behindZ), visible),
		waypoint(0.85 * D, offset(endX, centerY, behindZ), visible),
		waypoint(D, offset(endX, centerY, behindZ), 1),
	}
end

function PATH_BUILDER_BY_PIECE_MOTION.DescendFromSky(_look, pieceIndex, D, visible)
	local trailDelay = pieceIndex * 0.03 * D
	local sky = offset(-9, 16, -5)
	local angle = pieceIndex * GOLDEN_ANGLE_RADIANS
	local landing = offset(math.cos(angle) * 0.4, 0.6, math.sin(angle) * 0.4)
	return {
		waypoint(0, sky, 1),
		waypoint(0.05 * D + trailDelay, sky, visible),
		waypoint(0.6 * D + trailDelay, landing, visible),
		waypoint(D, landing, 1),
	}
end

function PATH_BUILDER_BY_PIECE_MOTION.RiseAsCurtain(look, pieceIndex, D, visible)
	local pieceHeight = readPieceHeightStuds(look)
	local isSingleColumn = look.pieceCount == 1
	local panelSpacing = look.pieceSizeStuds.x + 0.2
	local panelX = if isSingleColumn then 0 else (pieceIndex - (look.pieceCount - 1) / 2) * panelSpacing
	local panelZ = if isSingleColumn then 0 else -2.5
	local raised = offset(panelX, pieceHeight / 2, panelZ)
	return {
		waypoint(0, offset(panelX, pieceHeight / 2 - 2, panelZ), 1),
		waypoint(0.4 * D, raised, visible),
		waypoint(0.75 * D, raised, visible),
		waypoint(D, raised, 1),
	}
end

function StageEntranceEffectPiecePlanner.planStageEntranceEffect(look)
	local buildPath = PATH_BUILDER_BY_PIECE_MOTION[look.pieceMotion]
	if buildPath == nil then
		error("StageEntranceEffectPiecePlanner: unknown pieceMotion " .. tostring(look.pieceMotion), 2)
	end
	local D = look.effectDurationSeconds
	local pieces = {}
	for pieceIndex = 0, look.pieceCount - 1 do
		table.insert(
			pieces,
			table.freeze({
				pieceNumber = pieceIndex + 1,
				colorRgb = look.pieceColorRgbs[pieceIndex % #look.pieceColorRgbs + 1],
				waypoints = table.freeze(buildPath(look, pieceIndex, D, look.pieceTransparency)),
			})
		)
	end
	local lightBrightnessKeyframes = nil
	if look.light ~= nil then
		lightBrightnessKeyframes = table.freeze({
			table.freeze({ atSeconds = 0, brightness = 0 }),
			table.freeze({ atSeconds = 0.3 * D, brightness = look.light.peakBrightness }),
			table.freeze({ atSeconds = D, brightness = 0 }),
		})
	end
	return table.freeze({
		totalDurationSeconds = D,
		pieces = table.freeze(pieces),
		lightBrightnessKeyframes = lightBrightnessKeyframes,
	})
end

return table.freeze(StageEntranceEffectPiecePlanner)
