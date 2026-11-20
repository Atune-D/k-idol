-- RobloxShowcaseCameraDirector (development spec §2.4 Showcase): during Showcase the device's camera
-- looks at the whole stage from the audience's side (ShowcaseAudienceCameraPlacement decides where);
-- when Showcase ends it gives the camera back to Roblox's default camera scripts, following the
-- player's character. The server alone places, dresses and animates the characters on stage.
--   * Showcase begins: CameraType = Scriptable (the default camera scripts then leave the camera
--     alone) and CFrame = the audience placement for the stage box read from Workspace's stage
--     folder. If there is no stage folder, the camera is not touched.
--   * Showcase ends (any other screen): CameraType = Custom and CameraSubject = the character's
--     Humanoid (the reference's way to restore the default subject), repeated on every update for
--     RETURN_CAMERA_REASSERT_SECONDS whenever the camera is not Custom.
--   * A character respawn while Showcase lasts keeps the stage view: the placement is applied again
--     on every update, so whatever the camera scripts did on respawn is undone at once.
--
-- PUBLIC API
--   RobloxShowcaseCameraDirector.new(localPlayer) -> director
--   director:update(screenName)   call on every screen update
--
-- Roblox API used, read in the official documentation (create.roblox.com/docs/reference/engine/...):
--   Workspace.CurrentCamera, Workspace:FindFirstChild            classes/Workspace, classes/Instance
--   Camera.CameraType ("The default camera scripts will not move or update the camera if CameraType is
--     set to Enum.CameraType.Scriptable"), .CFrame, .FieldOfView, .ViewportSize, .CameraSubject ("To
--     restore CameraSubject to its default value, set it to the local character's Humanoid")
--                                                               classes/Camera
--   Enum.CameraType.Scriptable, Enum.CameraType.Custom          enums/CameraType
--   BasePart.Position, .Size; Instance:GetDescendants, :IsA     classes/BasePart, classes/Instance
--   CFrame.lookAt, Vector3.new                                  datatypes/CFrame, datatypes/Vector3
--   os.clock                                                    libraries/os

local Workspace = game:GetService("Workspace")

local ShowcaseAudienceCameraPlacement = require("./ShowcaseAudienceCameraPlacement")
local ThemedRoundStageInstanceNames = require("../shared/ThemedRoundStageInstanceNames")

local RobloxShowcaseCameraDirector = {}
RobloxShowcaseCameraDirector.__index = RobloxShowcaseCameraDirector

-- The folder RobloxThemedRoundStageBuilder builds on the server; both read its name from src/shared.
local STAGE_FOLDER_NAME = ThemedRoundStageInstanceNames.STAGE_FOLDER_NAME
-- After Showcase the camera is given back on every update for this long, should something switch it
-- back (measured in Studio on 2026-11-20: the Studio MCP plugin "resets" a camera type changed while
-- one of its execute_luau calls runs, which put the camera back to Scriptable after Showcase).
local RETURN_CAMERA_REASSERT_SECONDS = 3

function RobloxShowcaseCameraDirector.new(localPlayer: Player)
	return setmetatable({ localPlayer = localPlayer, isShowingStage = false }, RobloxShowcaseCameraDirector)
end

local function readStageParts()
	local stageFolder = Workspace:FindFirstChild(STAGE_FOLDER_NAME)
	if stageFolder == nil then
		return {}
	end
	local stageParts = {}
	for _, descendant in stageFolder:GetDescendants() do
		if descendant:IsA("BasePart") then
			local position, size = descendant.Position, descendant.Size
			table.insert(stageParts, {
				centerPosition = { x = position.X, y = position.Y, z = position.Z },
				size = { x = size.X, y = size.Y, z = size.Z },
			})
		end
	end
	return stageParts
end

local function toVector3(position): Vector3
	return Vector3.new(position.x, position.y, position.z)
end

function RobloxShowcaseCameraDirector:showStage(): boolean
	local camera = Workspace.CurrentCamera
	local stageBox = ShowcaseAudienceCameraPlacement.computeStageBoxFromParts(readStageParts())
	if camera == nil or stageBox == nil then
		return false
	end
	local viewportSize = camera.ViewportSize
	local aspectRatio = if viewportSize.Y > 0 then viewportSize.X / viewportSize.Y else 16 / 9
	local placement =
		ShowcaseAudienceCameraPlacement.computeAudienceCameraPlacement(stageBox, camera.FieldOfView, aspectRatio)
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(toVector3(placement.cameraPosition), toVector3(placement.lookAtPosition))
	return true
end

function RobloxShowcaseCameraDirector:returnCameraToCharacter()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	camera.CameraType = Enum.CameraType.Custom
	local character = self.localPlayer.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid ~= nil then
		camera.CameraSubject = humanoid
	end
end

function RobloxShowcaseCameraDirector:update(screenName: string)
	if screenName == "Showcase" then
		self.isShowingStage = self:showStage()
		self.returnCameraUntilClock = nil
		return
	end
	if self.isShowingStage then
		self.isShowingStage = false
		self.returnCameraUntilClock = os.clock() + RETURN_CAMERA_REASSERT_SECONDS
	end
	local camera = Workspace.CurrentCamera
	if self.returnCameraUntilClock == nil or camera == nil then
		return
	end
	if os.clock() > self.returnCameraUntilClock then
		self.returnCameraUntilClock = nil
	elseif camera.CameraType ~= Enum.CameraType.Custom then
		self:returnCameraToCharacter()
	end
end

return RobloxShowcaseCameraDirector
