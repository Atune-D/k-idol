-- StageEntranceEffectPreviewDotPlanner (development spec §1.7, §2.4): the shop's small STILL preview of a
-- stage entrance effect, built from the same data the server plays (StageEntranceEffectLookCatalog
-- turned into piece paths by StageEntranceEffectPiecePlanner), so the preview shows the real effect's
-- shape and colours. Nothing in it moves, flashes or repeats (spec: "nothing flashing").
--
-- How: the effect is seen from the audience (front view: the performer's x to the side, y up; the
-- depth z is dropped). Each piece is drawn once, as a dot where it is halfway through the time it is
-- fully visible (the middle of the waypoints at its lowest transparency), so every piece shows at a
-- moment it is really seen. The view box is VIEW_HALF_WIDTH_STUDS to each side of the performer and
-- VIEW_HEIGHT_STUDS high from the floor; a dot outside it is clamped to the edge. Dot sizes follow the
-- piece size (an upright Cylinder's height is its x), clamped so every dot stays visible and small.
-- The performer is drawn as a plain silhouette standing at the bottom centre (PERFORMER_BOX).
-- The light, when the look has one, is reported as hasLight with its colour (the view draws a soft
-- still glow behind the performer).
-- Pure logic: no Roblox-specific interface is used.
--
-- PUBLIC API
--   StageEntranceEffectPreviewDotPlanner.VIEW_HALF_WIDTH_STUDS = 8, .VIEW_HEIGHT_STUDS = 16
--   StageEntranceEffectPreviewDotPlanner.PERFORMER_BOX = { centerXScale, bottomYScale, widthScale, heightScale }
--   StageEntranceEffectPreviewDotPlanner.planStageEntranceEffectPreview(stageEntranceEffectLook) -> preview
--   preview = { dots = { { centerXScale, centerYScale, widthScale, heightScale, colorRgb, transparency } },
--               performerBox (= PERFORMER_BOX), hasLight, lightColorRgb? }
--     Scales are 0..1 of the preview box, y from the TOP (as interface positions are).

local StageEntranceEffectPiecePlanner = require("../shared/StageEntranceEffectPiecePlanner")

local StageEntranceEffectPreviewDotPlanner = {}

StageEntranceEffectPreviewDotPlanner.VIEW_HALF_WIDTH_STUDS = 8
StageEntranceEffectPreviewDotPlanner.VIEW_HEIGHT_STUDS = 16
StageEntranceEffectPreviewDotPlanner.PERFORMER_BOX =
	table.freeze({ centerXScale = 0.5, bottomYScale = 1, widthScale = 2 / 16, heightScale = 5 / 16 })

local EDGE_MARGIN_SCALE = 0.03
local MINIMUM_DOT_SCALE = 0.03
local MAXIMUM_DOT_SCALE = 0.3

local function clamp(value: number, lowest: number, highest: number): number
	return math.max(lowest, math.min(highest, value))
end

local function interpolateOffset(waypoints, atSeconds: number)
	for waypointIndex = 1, #waypoints - 1 do
		local fromWaypoint, toWaypoint = waypoints[waypointIndex], waypoints[waypointIndex + 1]
		if atSeconds <= toWaypoint.atSeconds then
			local span = toWaypoint.atSeconds - fromWaypoint.atSeconds
			local fraction = if span > 0 then (atSeconds - fromWaypoint.atSeconds) / span else 1
			local fromOffset, toOffset = fromWaypoint.offsetStuds, toWaypoint.offsetStuds
			return {
				x = fromOffset.x + (toOffset.x - fromOffset.x) * fraction,
				y = fromOffset.y + (toOffset.y - fromOffset.y) * fraction,
			}
		end
	end
	local lastOffset = waypoints[#waypoints].offsetStuds
	return { x = lastOffset.x, y = lastOffset.y }
end

-- The middle of the time the piece is at its lowest transparency, and that transparency.
local function findMostVisibleMoment(waypoints): (number, number)
	local lowestTransparency = math.huge
	for _, waypoint in waypoints do
		lowestTransparency = math.min(lowestTransparency, waypoint.transparency)
	end
	local firstSeconds, lastSeconds = nil, nil
	for _, waypoint in waypoints do
		if waypoint.transparency == lowestTransparency then
			firstSeconds = firstSeconds or waypoint.atSeconds
			lastSeconds = waypoint.atSeconds
		end
	end
	return ((firstSeconds :: number) + (lastSeconds :: number)) / 2, lowestTransparency
end

local function readPieceFrontSizeStuds(look): (number, number)
	if look.pieceShape == "Cylinder" then
		return look.pieceSizeStuds.y, look.pieceSizeStuds.x
	end
	return look.pieceSizeStuds.x, look.pieceSizeStuds.y
end

function StageEntranceEffectPreviewDotPlanner.planStageEntranceEffectPreview(stageEntranceEffectLook)
	local plan = StageEntranceEffectPiecePlanner.planStageEntranceEffect(stageEntranceEffectLook)
	local halfWidth = StageEntranceEffectPreviewDotPlanner.VIEW_HALF_WIDTH_STUDS
	local viewHeight = StageEntranceEffectPreviewDotPlanner.VIEW_HEIGHT_STUDS
	local widthStuds, heightStuds = readPieceFrontSizeStuds(stageEntranceEffectLook)
	local widthScale = clamp(widthStuds / (2 * halfWidth), MINIMUM_DOT_SCALE, MAXIMUM_DOT_SCALE)
	local heightScale = clamp(heightStuds / viewHeight, MINIMUM_DOT_SCALE, MAXIMUM_DOT_SCALE)
	local dots = {}
	for _, piece in plan.pieces do
		local momentSeconds, transparency = findMostVisibleMoment(piece.waypoints)
		local frontOffset = interpolateOffset(piece.waypoints, momentSeconds)
		table.insert(dots, {
			centerXScale = clamp(
				(frontOffset.x + halfWidth) / (2 * halfWidth),
				EDGE_MARGIN_SCALE,
				1 - EDGE_MARGIN_SCALE
			),
			centerYScale = clamp(1 - frontOffset.y / viewHeight, EDGE_MARGIN_SCALE, 1 - EDGE_MARGIN_SCALE),
			widthScale = widthScale,
			heightScale = heightScale,
			colorRgb = piece.colorRgb,
			transparency = transparency,
		})
	end
	local light = stageEntranceEffectLook.light
	return {
		dots = dots,
		performerBox = StageEntranceEffectPreviewDotPlanner.PERFORMER_BOX,
		hasLight = light ~= nil,
		lightColorRgb = if light ~= nil then light.colorRgb else nil,
	}
end

return table.freeze(StageEntranceEffectPreviewDotPlanner)
