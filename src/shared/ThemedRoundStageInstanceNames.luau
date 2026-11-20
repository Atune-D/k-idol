-- ThemedRoundStageInstanceNames (development spec §2.4 Showcase, README "Stage"): the name of the
-- Workspace folder the server builds the themed-round stage in, in ONE place that both sides read.
-- The server's RobloxThemedRoundStageBuilder creates the folder under this name; the device's
-- RobloxShowcaseCameraDirector looks for it under the same name to frame the stage.
-- Pure data: no Roblox-specific interface is used.
--
-- PUBLIC API
--   ThemedRoundStageInstanceNames.STAGE_FOLDER_NAME = "ThemedRoundStage"

local ThemedRoundStageInstanceNames = {}

ThemedRoundStageInstanceNames.STAGE_FOLDER_NAME = "ThemedRoundStage"

return table.freeze(ThemedRoundStageInstanceNames)
