-- ThemedRoundStageLayout (development spec v1.3 §2.4 Showcase, §3.1 "the stage is built in code"):
-- where the showcase stage stands and where each of its places is, as plain numbers. The
-- Roblox-side RobloxThemedRoundStageBuilder builds parts from it and the showcase presenter puts
-- characters on it; keeping the numbers here lets Lune check that there is a place for every
-- possible participant and that no two places overlap.
--
-- Coordinates are studs in world space; +Y is up. The default Baseplate of a new place has its top
-- surface at Y = 0 and the default SpawnLocation stands at the origin. The stage stands north of
-- it (negative Z) and faces the spawn (+Z), so a player arriving sees the stage.
-- Pure data and pure functions: no Roblox-specific interface is used.
--
-- PUBLIC API
--   ThemedRoundStageLayout.STAGE_PLACE_COUNT   = 12 (ThemedRoundProtocol.MAX_PLAYERS_PER_SERVER)
--   ThemedRoundStageLayout.STAGE_PLATFORM      frozen { centerPosition = {x,y,z}, size = {x,y,z} }
--   ThemedRoundStageLayout.STAGE_PLACE_PAD_SIZE   frozen {x,y,z}
--   ThemedRoundStageLayout.FACING_DIRECTION   frozen {x,y,z}, the direction every performer faces
--   ThemedRoundStageLayout.readStagePlace(stagePlaceNumber) -> frozen {
--       stagePlaceNumber, padCenterPosition = {x,y,z}, standingFloorHeight: number,
--       lobbyReturnFloorPosition = {x,y,z} }   (the floor point in front of the stage where the
--       performer is put back after Showcase). A number outside 1..STAGE_PLACE_COUNT that is a
--       whole number wraps around onto the existing places (the referee hands out places in join
--       order and the round has at most MAX_PLAYERS_PER_SERVER participants; wrapping only matters if
--       that ever changes, and then two performers share a place instead of an error).
--       Anything that is not a whole number >= 1 raises.

local ThemedRoundProtocol = require("../shared/ThemedRoundProtocol")

local ThemedRoundStageLayout = {}

ThemedRoundStageLayout.STAGE_PLACE_COUNT = ThemedRoundProtocol.MAX_PLAYERS_PER_SERVER

local PLACES_PER_ROW = 6
local PLACE_SPACING_STUDS = 9
local FRONT_ROW_Z = -50
local BACK_ROW_Z = -60
local PLATFORM_HEIGHT_STUDS = 2
local PAD_HEIGHT_STUDS = 0.4
local LOBBY_RETURN_Z = -36

ThemedRoundStageLayout.STAGE_PLATFORM = table.freeze({
	centerPosition = table.freeze({ x = 0, y = PLATFORM_HEIGHT_STUDS / 2, z = (FRONT_ROW_Z + BACK_ROW_Z) / 2 }),
	size = table.freeze({ x = PLACES_PER_ROW * PLACE_SPACING_STUDS + 6, y = PLATFORM_HEIGHT_STUDS, z = 24 }),
})

ThemedRoundStageLayout.STAGE_PLACE_PAD_SIZE = table.freeze({ x = 6, y = PAD_HEIGHT_STUDS, z = 6 })

ThemedRoundStageLayout.FACING_DIRECTION = table.freeze({ x = 0, y = 0, z = 1 })

local function buildStagePlace(stagePlaceNumber: number)
	local positionInRow = (stagePlaceNumber - 1) % PLACES_PER_ROW
	local rowIndex = (stagePlaceNumber - 1) // PLACES_PER_ROW
	local padX = (positionInRow - (PLACES_PER_ROW - 1) / 2) * PLACE_SPACING_STUDS
	local padZ = if rowIndex == 0 then FRONT_ROW_Z else BACK_ROW_Z
	local standingFloorHeight = PLATFORM_HEIGHT_STUDS + PAD_HEIGHT_STUDS
	return table.freeze({
		stagePlaceNumber = stagePlaceNumber,
		padCenterPosition = table.freeze({ x = padX, y = PLATFORM_HEIGHT_STUDS + PAD_HEIGHT_STUDS / 2, z = padZ }),
		standingFloorHeight = standingFloorHeight,
		lobbyReturnFloorPosition = table.freeze({ x = padX, y = 0, z = LOBBY_RETURN_Z - rowIndex * 4 }),
	})
end

local stagePlaces = {}
for stagePlaceNumber = 1, ThemedRoundStageLayout.STAGE_PLACE_COUNT do
	stagePlaces[stagePlaceNumber] = buildStagePlace(stagePlaceNumber)
end
table.freeze(stagePlaces)

function ThemedRoundStageLayout.readStagePlace(stagePlaceNumber: number)
	if
		type(stagePlaceNumber) ~= "number"
		or stagePlaceNumber < 1
		or stagePlaceNumber ~= math.floor(stagePlaceNumber)
		or stagePlaceNumber == math.huge
	then
		error(string.format("ThemedRoundStageLayout: no stage place %s", tostring(stagePlaceNumber)), 2)
	end
	return stagePlaces[(stagePlaceNumber - 1) % ThemedRoundStageLayout.STAGE_PLACE_COUNT + 1]
end

return table.freeze(ThemedRoundStageLayout)
