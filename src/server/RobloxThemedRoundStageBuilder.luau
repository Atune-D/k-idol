-- RobloxThemedRoundStageBuilder (development spec v1.3 §2.4, §3.1 "the stage is built in code,
-- not placed by hand"): builds the showcase stage in Workspace from ThemedRoundStageLayout at
-- server start: one anchored platform and one anchored pad per stage place, in a folder named
-- STAGE_FOLDER_NAME. Plain parts with colours only; no model, texture or asset is inserted.
--
-- PUBLIC API
--   RobloxThemedRoundStageBuilder.STAGE_FOLDER_NAME = "ThemedRoundStage" (from src/shared/ThemedRoundStageInstanceNames)
--   RobloxThemedRoundStageBuilder.buildThemedRoundStage() -> Folder
--     Raises when Workspace already holds a child of that name (built twice).
--   RobloxThemedRoundStageBuilder.buildPerformerStandingCFrameOnStagePlace(stagePlaceNumber, rootPartHeightAboveFloor) -> CFrame
--   RobloxThemedRoundStageBuilder.buildLobbyReturnCFrame(stagePlaceNumber, rootPartHeightAboveFloor) -> CFrame
--     Both face ThemedRoundStageLayout.FACING_DIRECTION.
--
-- Roblox API used, read in the official documentation while writing this file:
--   Workspace (game:GetService)   https://create.roblox.com/docs/reference/engine/classes/Workspace
--   Part, BasePart.Anchored, .Size, .CFrame, .Color, .Material, .TopSurface, .BottomSurface
--                                 https://create.roblox.com/docs/reference/engine/classes/BasePart
--   Instance.new, .Name, .Parent, :FindFirstChild  https://create.roblox.com/docs/reference/engine/classes/Instance
--   Vector3.new                   https://create.roblox.com/docs/reference/engine/datatypes/Vector3
--   CFrame.new, CFrame.lookAt     https://create.roblox.com/docs/reference/engine/datatypes/CFrame
--   Color3.fromRGB                https://create.roblox.com/docs/reference/engine/datatypes/Color3
--   Enum.Material.SmoothPlastic, .Neon  https://create.roblox.com/docs/reference/engine/enums/Material
--   Enum.SurfaceType.Smooth       https://create.roblox.com/docs/reference/engine/enums/SurfaceType

local Workspace = game:GetService("Workspace")

local ThemedRoundStageInstanceNames = require("../shared/ThemedRoundStageInstanceNames")
local ThemedRoundStageLayout = require("./ThemedRoundStageLayout")

local RobloxThemedRoundStageBuilder = {}

-- One home for the name, shared with the device's camera director (src/shared/ThemedRoundStageInstanceNames).
RobloxThemedRoundStageBuilder.STAGE_FOLDER_NAME = ThemedRoundStageInstanceNames.STAGE_FOLDER_NAME

local PLATFORM_COLOR = Color3.fromRGB(46, 38, 66)
local PAD_COLOR = Color3.fromRGB(255, 120, 190)

local function toVector3(position): Vector3
	return Vector3.new(position.x, position.y, position.z)
end

local function createAnchoredPart(partName: string, centerPosition, size, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = partName
	part.Anchored = true
	part.Size = toVector3(size)
	part.CFrame = CFrame.new(toVector3(centerPosition))
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

function RobloxThemedRoundStageBuilder.buildThemedRoundStage(): Folder
	if Workspace:FindFirstChild(RobloxThemedRoundStageBuilder.STAGE_FOLDER_NAME) ~= nil then
		error("RobloxThemedRoundStageBuilder: the stage was already built")
	end
	local stageFolder = Instance.new("Folder")
	stageFolder.Name = RobloxThemedRoundStageBuilder.STAGE_FOLDER_NAME
	local platform = ThemedRoundStageLayout.STAGE_PLATFORM
	createAnchoredPart(
		"StagePlatform",
		platform.centerPosition,
		platform.size,
		PLATFORM_COLOR,
		Enum.Material.SmoothPlastic
	).Parent =
		stageFolder
	for stagePlaceNumber = 1, ThemedRoundStageLayout.STAGE_PLACE_COUNT do
		local stagePlace = ThemedRoundStageLayout.readStagePlace(stagePlaceNumber)
		createAnchoredPart(
			string.format("StagePlace%02d", stagePlaceNumber),
			stagePlace.padCenterPosition,
			ThemedRoundStageLayout.STAGE_PLACE_PAD_SIZE,
			PAD_COLOR,
			Enum.Material.Neon
		).Parent =
			stageFolder
	end
	stageFolder.Parent = Workspace
	return stageFolder
end

local function buildFacingCFrame(floorPosition, rootPartHeightAboveFloor: number): CFrame
	local standingPosition = Vector3.new(floorPosition.x, floorPosition.y + rootPartHeightAboveFloor, floorPosition.z)
	return CFrame.lookAt(standingPosition, standingPosition + toVector3(ThemedRoundStageLayout.FACING_DIRECTION))
end

function RobloxThemedRoundStageBuilder.buildPerformerStandingCFrameOnStagePlace(
	stagePlaceNumber: number,
	rootPartHeightAboveFloor: number
): CFrame
	local stagePlace = ThemedRoundStageLayout.readStagePlace(stagePlaceNumber)
	local padCenter = stagePlace.padCenterPosition
	return buildFacingCFrame(
		{ x = padCenter.x, y = stagePlace.standingFloorHeight, z = padCenter.z },
		rootPartHeightAboveFloor
	)
end

function RobloxThemedRoundStageBuilder.buildLobbyReturnCFrame(
	stagePlaceNumber: number,
	rootPartHeightAboveFloor: number
): CFrame
	return buildFacingCFrame(
		ThemedRoundStageLayout.readStagePlace(stagePlaceNumber).lobbyReturnFloorPosition,
		rootPartHeightAboveFloor
	)
end

return RobloxThemedRoundStageBuilder
