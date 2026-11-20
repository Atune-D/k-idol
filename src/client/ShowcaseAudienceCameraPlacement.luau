-- ShowcaseAudienceCameraPlacement (development spec §2.4 Showcase): where the device puts its camera
-- during Showcase so the player sees the whole stage, as the audience would.
--
-- Decision (Phase 1): during Showcase every device, participant or not, looks at the whole stage
-- from in front of it, so every outfit on stage can be seen; when Showcase ends the camera goes
-- back to following the player's character. The server alone places and dresses the characters.
--
-- Geometry, from the stage's parts as they stand in the world (the device reads them; the stage
-- layout module is server-only):
--   * the stage box is the smallest box holding every part of the stage folder;
--   * the stage faces the world origin, where the spawn is (ThemedRoundStageLayout: "The stage stands
--     north of it (negative Z) and faces the spawn (+Z)"); the camera stands on the line from the
--     box's centre towards the origin, horizontally; when the box's centre is the origin itself (no
--     direction), it looks along -Z from +Z;
--   * its distance is chosen so the box's width fits the horizontal field of view with
--     FRAMING_MARGIN_FACTOR to spare, measured from the box's front face; it stands
--     CAMERA_HEIGHT_ABOVE_STAGE_TOP_STUDS above the box's top and looks at a point
--     LOOK_AT_HEIGHT_ABOVE_STAGE_TOP_STUDS above the box's top centre: above the performers' heads,
--     so the stage sits in the lower half of the view, below the round panel (seen in Studio).
-- Pure logic on plain {x, y, z} tables: no Roblox-specific interface is used.
--
-- PUBLIC API
--   ShowcaseAudienceCameraPlacement.FRAMING_MARGIN_FACTOR = 1.15
--   ShowcaseAudienceCameraPlacement.CAMERA_HEIGHT_ABOVE_STAGE_TOP_STUDS = 14
--   ShowcaseAudienceCameraPlacement.LOOK_AT_HEIGHT_ABOVE_STAGE_TOP_STUDS = 10
--   ShowcaseAudienceCameraPlacement.computeStageBoxFromParts({ { centerPosition = {x,y,z}, size = {x,y,z} } })
--       -> { minimumCorner, maximumCorner }?   nil for an empty list. Parts are treated as unrotated
--       (the stage builder places them unrotated).
--   ShowcaseAudienceCameraPlacement.computeAudienceCameraPlacement(stageBox, verticalFieldOfViewDegrees,
--       viewportAspectRatio) -> { cameraPosition = {x,y,z}, lookAtPosition = {x,y,z} }

local ShowcaseAudienceCameraPlacement = {}

ShowcaseAudienceCameraPlacement.FRAMING_MARGIN_FACTOR = 1.15
ShowcaseAudienceCameraPlacement.CAMERA_HEIGHT_ABOVE_STAGE_TOP_STUDS = 14
ShowcaseAudienceCameraPlacement.LOOK_AT_HEIGHT_ABOVE_STAGE_TOP_STUDS = 10

function ShowcaseAudienceCameraPlacement.computeStageBoxFromParts(stageParts)
	if #stageParts == 0 then
		return nil
	end
	local minimumCorner = { x = math.huge, y = math.huge, z = math.huge }
	local maximumCorner = { x = -math.huge, y = -math.huge, z = -math.huge }
	for _, stagePart in stageParts do
		for _, axis in { "x", "y", "z" } do
			local halfSize = stagePart.size[axis] / 2
			minimumCorner[axis] = math.min(minimumCorner[axis], stagePart.centerPosition[axis] - halfSize)
			maximumCorner[axis] = math.max(maximumCorner[axis], stagePart.centerPosition[axis] + halfSize)
		end
	end
	return { minimumCorner = minimumCorner, maximumCorner = maximumCorner }
end

function ShowcaseAudienceCameraPlacement.computeAudienceCameraPlacement(
	stageBox,
	verticalFieldOfViewDegrees: number,
	viewportAspectRatio: number
)
	local minimumCorner, maximumCorner = stageBox.minimumCorner, stageBox.maximumCorner
	local centerX = (minimumCorner.x + maximumCorner.x) / 2
	local centerZ = (minimumCorner.z + maximumCorner.z) / 2
	local stageTopY = maximumCorner.y
	-- Horizontal unit vector from the stage centre towards the world origin.
	local towardsOriginLength = math.sqrt(centerX * centerX + centerZ * centerZ)
	local facingX, facingZ = 0, 1
	if towardsOriginLength > 1e-6 then
		facingX, facingZ = -centerX / towardsOriginLength, -centerZ / towardsOriginLength
	end
	-- The stage's extent across and along the facing direction (box treated as axis-aligned).
	local sizeX, sizeZ = maximumCorner.x - minimumCorner.x, maximumCorner.z - minimumCorner.z
	local widthAcross = math.abs(facingZ) * sizeX + math.abs(facingX) * sizeZ
	local depthAlong = math.abs(facingX) * sizeX + math.abs(facingZ) * sizeZ
	local verticalHalfAngle = math.rad(math.clamp(verticalFieldOfViewDegrees, 1, 120)) / 2
	local horizontalHalfAngle = math.atan(math.tan(verticalHalfAngle) * math.max(viewportAspectRatio, 0.1))
	local distanceFromFront = (widthAcross / 2)
		* ShowcaseAudienceCameraPlacement.FRAMING_MARGIN_FACTOR
		/ math.tan(horizontalHalfAngle)
	local distanceFromCenter = depthAlong / 2 + distanceFromFront
	return {
		cameraPosition = {
			x = centerX + facingX * distanceFromCenter,
			y = stageTopY + ShowcaseAudienceCameraPlacement.CAMERA_HEIGHT_ABOVE_STAGE_TOP_STUDS,
			z = centerZ + facingZ * distanceFromCenter,
		},
		lookAtPosition = {
			x = centerX,
			y = stageTopY + ShowcaseAudienceCameraPlacement.LOOK_AT_HEIGHT_ABOVE_STAGE_TOP_STUDS,
			z = centerZ,
		},
	}
end

return table.freeze(ShowcaseAudienceCameraPlacement)
