local UnitTestFramework = require("../Support/UnitTestFramework")
local ThemedRoundStageLayout = require("../../src/server/ThemedRoundStageLayout")
local ThemedRoundProtocol = require("../../src/shared/ThemedRoundProtocol")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local function isInsideStagePlatform(position): boolean
	local platform = ThemedRoundStageLayout.STAGE_PLATFORM
	local padSize = ThemedRoundStageLayout.STAGE_PLACE_PAD_SIZE
	return math.abs(position.x - platform.centerPosition.x) + padSize.x / 2 <= platform.size.x / 2
		and math.abs(position.z - platform.centerPosition.z) + padSize.z / 2 <= platform.size.z / 2
end

describe("ThemedRoundStageLayout", function()
	it("has at least 12 places, one for every possible participant of a full server", function()
		expect(ThemedRoundStageLayout.STAGE_PLACE_COUNT >= 12).toBeTrue()
		expect(ThemedRoundStageLayout.STAGE_PLACE_COUNT >= ThemedRoundProtocol.MAX_PLAYERS_PER_SERVER).toBeTrue()
	end)

	it("puts every pad on the platform, with no two pads overlapping", function()
		local padSize = ThemedRoundStageLayout.STAGE_PLACE_PAD_SIZE
		for firstNumber = 1, ThemedRoundStageLayout.STAGE_PLACE_COUNT do
			local firstPlace = ThemedRoundStageLayout.readStagePlace(firstNumber)
			expect(firstPlace.stagePlaceNumber).toBe(firstNumber)
			expect(isInsideStagePlatform(firstPlace.padCenterPosition)).toBeTrue()
			for secondNumber = firstNumber + 1, ThemedRoundStageLayout.STAGE_PLACE_COUNT do
				local secondPlace = ThemedRoundStageLayout.readStagePlace(secondNumber)
				local isSeparated = math.abs(firstPlace.padCenterPosition.x - secondPlace.padCenterPosition.x)
						>= padSize.x
					or math.abs(firstPlace.padCenterPosition.z - secondPlace.padCenterPosition.z) >= padSize.z
				expect({ firstNumber, secondNumber, isSeparated }).toEqual({ firstNumber, secondNumber, true })
			end
		end
	end)

	it("stands performers on the pad top, above the platform, and returns them to the floor off the stage", function()
		for stagePlaceNumber = 1, ThemedRoundStageLayout.STAGE_PLACE_COUNT do
			local stagePlace = ThemedRoundStageLayout.readStagePlace(stagePlaceNumber)
			local padTop = stagePlace.padCenterPosition.y + ThemedRoundStageLayout.STAGE_PLACE_PAD_SIZE.y / 2
			expect(stagePlace.standingFloorHeight).toBeCloseTo(padTop, 1e-9)
			expect(stagePlace.standingFloorHeight > ThemedRoundStageLayout.STAGE_PLATFORM.size.y).toBeTrue()
			expect(isInsideStagePlatform(stagePlace.lobbyReturnFloorPosition)).toBeFalse()
			expect(stagePlace.lobbyReturnFloorPosition.y).toBe(0)
		end
	end)

	it("stands the stage away from the spawn at the origin and faces the performers toward it", function()
		local platform = ThemedRoundStageLayout.STAGE_PLATFORM
		expect(platform.centerPosition.z + platform.size.z / 2 < 0).toBeTrue()
		expect(ThemedRoundStageLayout.FACING_DIRECTION).toEqual({ x = 0, y = 0, z = 1 })
	end)

	it("wraps a whole number beyond the last place onto the existing places and raises for anything else", function()
		local count = ThemedRoundStageLayout.STAGE_PLACE_COUNT
		expect(ThemedRoundStageLayout.readStagePlace(count + 1)).toBe(ThemedRoundStageLayout.readStagePlace(1))
		for _, invalidNumber in { 0, -1, 1.5, 0 / 0, math.huge, "1" :: any } do
			expect(function()
				ThemedRoundStageLayout.readStagePlace(invalidNumber)
			end).toThrow("no stage place")
		end
	end)

	it("cannot be changed at run time", function()
		expect(table.isfrozen(ThemedRoundStageLayout)).toBeTrue()
		expect(table.isfrozen(ThemedRoundStageLayout.readStagePlace(1))).toBeTrue()
	end)
end)
