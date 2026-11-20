-- RobloxStageEntranceEffectPlayer (development spec v1.3 §1.7, §2.4): plays a StageEntranceEffect
-- cosmetic ONCE around a performer who has just been placed on stage, built on the server from
-- plain anchored parts and an optional light so every device sees it. No image, texture, particle
-- emitter or asset is used. Where every piece goes and when is StageEntranceEffectPiecePlanner's
-- plan; this file creates the parts, moves each from waypoint to waypoint with tweens, and
-- destroys everything after the effect's duration.
--
-- The effect lives in Workspace.<EFFECTS_FOLDER_NAME>.<"StageEntranceEffect_" .. cosmeticId> while it
-- plays; the folder is created on first use. Pieces do not collide, are not touched or queried and
-- cast no shadow, so they never block a player or the camera.
--
-- PUBLIC API
--   RobloxStageEntranceEffectPlayer.EFFECTS_FOLDER_NAME = "StageEntranceEffects"
--   RobloxStageEntranceEffectPlayer.playStageEntranceEffectOnce(performerFeetCFrame, stageEntranceEffectLook) -> Folder
--     Never yields. performerFeetCFrame: the performer's feet, looking where the performer faces.
--     The plan's +z (toward the audience) is the CFrame's look direction.
--
-- Roblox API used, read in the official documentation while writing this file:
--   Part, Part.Shape, Enum.PartType.Ball/.Block/.Cylinder
--                       https://create.roblox.com/docs/reference/engine/classes/Part
--                       https://create.roblox.com/docs/reference/engine/enums/PartType
--   BasePart .Anchored, .CanCollide, .CanQuery, .CanTouch, .CastShadow, .Transparency, .Material,
--     .Color, .Size, .CFrame       https://create.roblox.com/docs/reference/engine/classes/BasePart
--   Enum.Material .Neon/.SmoothPlastic/.Glass/.Foil
--                       https://create.roblox.com/docs/reference/engine/enums/Material
--   PointLight.Range, SpotLight .Range/.Angle/.Face, Light .Brightness/.Color/.Shadows
--                       https://create.roblox.com/docs/reference/engine/classes/PointLight
--                       https://create.roblox.com/docs/reference/engine/classes/SpotLight
--                       https://create.roblox.com/docs/reference/engine/classes/Light
--   Enum.NormalId.Bottom   https://create.roblox.com/docs/reference/engine/enums/NormalId
--   TweenService:Create (numbers, CFrame, Color3 can be tweened), Tween:Play
--                       https://create.roblox.com/docs/reference/engine/classes/TweenService
--                       https://create.roblox.com/docs/reference/engine/classes/TweenBase
--   TweenInfo.new(time, easingStyle, easingDirection)
--                       https://create.roblox.com/docs/reference/engine/datatypes/TweenInfo
--   Enum.EasingStyle.Sine, Enum.EasingDirection.InOut
--                       https://create.roblox.com/docs/reference/engine/enums/EasingStyle
--   CFrame :PointToWorldSpace, CFrame.new, CFrame.Angles, Vector3.new, Color3.fromRGB
--                       https://create.roblox.com/docs/reference/engine/datatypes/CFrame
--   Folder, Instance.new, .Name, .Parent, :FindFirstChild, :Destroy
--                       https://create.roblox.com/docs/reference/engine/classes/Instance
--   task.spawn, task.wait, task.delay   https://create.roblox.com/docs/reference/engine/libraries/task

local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local StageEntranceEffectPiecePlanner = require("../shared/StageEntranceEffectPiecePlanner")

local RobloxStageEntranceEffectPlayer = {}

RobloxStageEntranceEffectPlayer.EFFECTS_FOLDER_NAME = "StageEntranceEffects"

local CLEAN_UP_MARGIN_SECONDS = 0.5
local SPOTLIGHT_ANGLE_DEGREES = 40
-- A Roblox cylinder's length runs along its X axis; turning it a quarter around Z stands it upright.
local UPRIGHT_CYLINDER_ROTATION = CFrame.Angles(0, 0, math.pi / 2)

local function readEffectsFolder(): Folder
	local effectsFolder = Workspace:FindFirstChild(RobloxStageEntranceEffectPlayer.EFFECTS_FOLDER_NAME)
	if effectsFolder == nil then
		effectsFolder = Instance.new("Folder")
		effectsFolder.Name = RobloxStageEntranceEffectPlayer.EFFECTS_FOLDER_NAME
		effectsFolder.Parent = Workspace
	end
	return effectsFolder :: Folder
end

local function toColor3(colorRgb): Color3
	return Color3.fromRGB(colorRgb.r, colorRgb.g, colorRgb.b)
end

local function buildWaypointCFrame(performerFeetCFrame: CFrame, offsetStuds, isCylinder: boolean): CFrame
	-- The plan's +z is toward the audience: the CFrame's look direction, which is its -Z axis.
	local worldPosition =
		performerFeetCFrame:PointToWorldSpace(Vector3.new(offsetStuds.x, offsetStuds.y, -offsetStuds.z))
	local orientation = performerFeetCFrame.Rotation
	if isCylinder then
		orientation *= UPRIGHT_CYLINDER_ROTATION
	end
	return CFrame.new(worldPosition) * orientation
end

local function createPiecePart(look, plannedPiece, firstCFrame: CFrame, firstTransparency: number): Part
	local piecePart = Instance.new("Part")
	piecePart.Name = "Piece" .. plannedPiece.pieceNumber
	piecePart.Shape = (Enum.PartType :: any)[look.pieceShape]
	piecePart.Material = (Enum.Material :: any)[look.pieceMaterial]
	piecePart.Size = Vector3.new(look.pieceSizeStuds.x, look.pieceSizeStuds.y, look.pieceSizeStuds.z)
	piecePart.Color = toColor3(plannedPiece.colorRgb)
	piecePart.Anchored = true
	piecePart.CanCollide = false
	piecePart.CanQuery = false
	piecePart.CanTouch = false
	piecePart.CastShadow = false
	piecePart.CFrame = firstCFrame
	piecePart.Transparency = firstTransparency
	return piecePart
end

local function movePieceAlongWaypoints(piecePart: Part, waypointCFrames: { CFrame }, waypoints)
	for waypointIndex = 2, #waypoints do
		local segmentSeconds = waypoints[waypointIndex].atSeconds - waypoints[waypointIndex - 1].atSeconds
		if segmentSeconds > 0 then
			TweenService:Create(
				piecePart,
				TweenInfo.new(segmentSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ CFrame = waypointCFrames[waypointIndex], Transparency = waypoints[waypointIndex].transparency }
			):Play()
			task.wait(segmentSeconds)
		else
			piecePart.CFrame = waypointCFrames[waypointIndex]
			piecePart.Transparency = waypoints[waypointIndex].transparency
		end
		if piecePart.Parent == nil then
			return
		end
	end
end

local function createAndFadeLight(effectFolder: Folder, performerFeetCFrame: CFrame, look, lightBrightnessKeyframes)
	local lightHolder = Instance.new("Part")
	lightHolder.Name = "LightHolder"
	lightHolder.Size = Vector3.new(0.2, 0.2, 0.2)
	lightHolder.Transparency = 1
	lightHolder.Anchored = true
	lightHolder.CanCollide = false
	lightHolder.CanQuery = false
	lightHolder.CanTouch = false
	lightHolder.CastShadow = false
	lightHolder.CFrame = performerFeetCFrame + Vector3.new(0, look.light.heightAboveFeetStuds, 0)
	local light: Light
	if look.light.lightKind == "SpotLight" then
		local spotLight = Instance.new("SpotLight")
		spotLight.Face = Enum.NormalId.Bottom
		spotLight.Angle = SPOTLIGHT_ANGLE_DEGREES
		spotLight.Range = look.light.rangeStuds
		light = spotLight
	else
		local pointLight = Instance.new("PointLight")
		pointLight.Range = look.light.rangeStuds
		light = pointLight
	end
	light.Color = toColor3(look.light.colorRgb)
	light.Shadows = false
	light.Brightness = lightBrightnessKeyframes[1].brightness
	light.Parent = lightHolder
	lightHolder.Parent = effectFolder
	task.spawn(function()
		for keyframeIndex = 2, #lightBrightnessKeyframes do
			local segmentSeconds = lightBrightnessKeyframes[keyframeIndex].atSeconds
				- lightBrightnessKeyframes[keyframeIndex - 1].atSeconds
			TweenService:Create(
				light,
				TweenInfo.new(segmentSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Brightness = lightBrightnessKeyframes[keyframeIndex].brightness }
			):Play()
			task.wait(segmentSeconds)
		end
	end)
end

function RobloxStageEntranceEffectPlayer.playStageEntranceEffectOnce(performerFeetCFrame: CFrame, look): Folder
	local plan = StageEntranceEffectPiecePlanner.planStageEntranceEffect(look)
	local effectFolder = Instance.new("Folder")
	effectFolder.Name = "StageEntranceEffect_" .. look.stageEntranceEffectCosmeticId
	local isCylinder = look.pieceShape == "Cylinder"
	local pieceMovements = {}
	for _, plannedPiece in plan.pieces do
		local waypointCFrames = {}
		for waypointIndex, plannedWaypoint in plannedPiece.waypoints do
			waypointCFrames[waypointIndex] =
				buildWaypointCFrame(performerFeetCFrame, plannedWaypoint.offsetStuds, isCylinder)
		end
		local piecePart =
			createPiecePart(look, plannedPiece, waypointCFrames[1], plannedPiece.waypoints[1].transparency)
		piecePart.Parent = effectFolder
		table.insert(pieceMovements, { piecePart, waypointCFrames, plannedPiece.waypoints })
	end
	effectFolder.Parent = readEffectsFolder()
	for _, pieceMovement in pieceMovements do
		task.spawn(movePieceAlongWaypoints, table.unpack(pieceMovement))
	end
	if plan.lightBrightnessKeyframes ~= nil then
		createAndFadeLight(effectFolder, performerFeetCFrame, look, plan.lightBrightnessKeyframes)
	end
	task.delay(plan.totalDurationSeconds + CLEAN_UP_MARGIN_SECONDS, function()
		effectFolder:Destroy()
	end)
	return effectFolder
end

return RobloxStageEntranceEffectPlayer
