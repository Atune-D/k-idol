-- The portable seeded generator behind the daily quest choice (development spec §1.8).
-- The expected numbers below were computed by an independent Python implementation of FNV-1a and
-- mulberry32 with exact integer arithmetic; the FNV-1a values are also the algorithm's published
-- test vectors, and mulberry32 seed 1 → 2693262067 is the widely quoted 0.6270739405881613 × 2^32.

local UnitTestFramework = require("../Support/UnitTestFramework")
local PortableSeededRandomNumberGenerator = require("../../src/shared/PortableSeededRandomNumberGenerator")
local SeededRandomTrials = require("../fixtures/SeededRandomTrials")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local UNSIGNED_32_BIT_MODULUS = 4294967296

local function drawUnsigned32BitNumbers(generator, drawCount: number): { number }
	local drawnNumbers = {}
	for _ = 1, drawCount do
		table.insert(drawnNumbers, generator.nextUnsigned32BitNumber())
	end
	return drawnNumbers
end

describe("PortableSeededRandomNumberGenerator seed hashing (FNV-1a, 32 bit)", function()
	it("matches the published FNV-1a test vectors", function()
		expect(PortableSeededRandomNumberGenerator.hashSeedTextWithFnv1a32("")).toBe(0x811C9DC5)
		expect(PortableSeededRandomNumberGenerator.hashSeedTextWithFnv1a32("a")).toBe(0xE40C292C)
		expect(PortableSeededRandomNumberGenerator.hashSeedTextWithFnv1a32("foobar")).toBe(0xBF9CF968)
	end)

	it("hashes a daily date key to the value computed independently", function()
		expect(PortableSeededRandomNumberGenerator.hashSeedTextWithFnv1a32("2026-11-19")).toBe(1964763441)
	end)

	it("refuses a seed text that is not a string", function()
		expect(function()
			PortableSeededRandomNumberGenerator.hashSeedTextWithFnv1a32(20261119 :: any)
		end).toThrow("seedText must be a string")
	end)
end)

describe("PortableSeededRandomNumberGenerator sequence (mulberry32)", function()
	it("matches the reference outputs for seeds 0 and 1", function()
		expect(drawUnsigned32BitNumbers(PortableSeededRandomNumberGenerator.createFromUnsigned32BitSeed(0), 3)).toEqual({
			1144304738,
			1416247,
			958946056,
		})
		expect(drawUnsigned32BitNumbers(PortableSeededRandomNumberGenerator.createFromUnsigned32BitSeed(1), 3)).toEqual({
			2693262067,
			11749833,
			2265367787,
		})
	end)

	it("seeded from a date key, matches the reference outputs", function()
		local dateKeySeededGenerator = PortableSeededRandomNumberGenerator.createFromSeedText("2026-11-19")
		expect(drawUnsigned32BitNumbers(dateKeySeededGenerator, 5)).toEqual({
			177235288,
			3973000793,
			728935449,
			1302669693,
			3961622413,
		})
	end)

	it("draws whole numbers in a range with rejection sampling, matching the reference", function()
		local dateKeySeededGenerator = PortableSeededRandomNumberGenerator.createFromSeedText("2026-11-19")
		local drawnWholeNumbers = {}
		for _ = 1, 8 do
			table.insert(drawnWholeNumbers, dateKeySeededGenerator.nextWholeNumberInRange(1, 6))
		end
		expect(drawnWholeNumbers).toEqual({ 5, 6, 4, 4, 2, 3, 1, 3 })
	end)

	it("redraws instead of folding a draw that would bias the range (reference: seed 1, range of 3 × 2^30)", function()
		-- Draws 4, 5 and 10 of seed 1 (4213581821, 4159151403, 4272732017) are at or above 3 × 2^30,
		-- the unbiased limit for this range, so they are skipped rather than reduced.
		local generator = PortableSeededRandomNumberGenerator.createFromUnsigned32BitSeed(1)
		local drawnWholeNumbers = {}
		for _ = 1, 12 do
			table.insert(drawnWholeNumbers, generator.nextWholeNumberInRange(0, 3 * 2 ^ 30 - 1))
		end
		expect(drawnWholeNumbers).toEqual({
			2693262067,
			11749833,
			2265367787,
			1207330352,
			2632122864,
			3095568220,
			1828783984,
			1955374602,
			2099329838,
			596715197,
			1734070562,
			1063107040,
		})
	end)

	it("two generators from the same text give the same sequence; different texts differ", function()
		local firstGenerator = PortableSeededRandomNumberGenerator.createFromSeedText("2027-03-04")
		local secondGenerator = PortableSeededRandomNumberGenerator.createFromSeedText("2027-03-04")
		local otherDayGenerator = PortableSeededRandomNumberGenerator.createFromSeedText("2027-03-05")
		local firstSequence = drawUnsigned32BitNumbers(firstGenerator, 20)
		expect(drawUnsigned32BitNumbers(secondGenerator, 20)).toEqual(firstSequence)
		local otherDaySequence = drawUnsigned32BitNumbers(otherDayGenerator, 20)
		local matchingPositionCount = 0
		for drawPosition = 1, 20 do
			if otherDaySequence[drawPosition] == firstSequence[drawPosition] then
				matchingPositionCount += 1
			end
		end
		expect(matchingPositionCount).toBe(0)
	end)

	it("refuses seeds outside 0 to 2^32 - 1 and malformed ranges", function()
		for _, invalidSeed in { -1, UNSIGNED_32_BIT_MODULUS, 1.5, "1" :: any } do
			expect(function()
				PortableSeededRandomNumberGenerator.createFromUnsigned32BitSeed(invalidSeed)
			end).toThrow("the seed must be a whole number")
		end
		local generator = PortableSeededRandomNumberGenerator.createFromUnsigned32BitSeed(7)
		expect(function()
			generator.nextWholeNumberInRange(3, 2)
		end).toThrow("the range must be whole numbers")
		expect(function()
			generator.nextWholeNumberInRange(1, 2.5)
		end).toThrow("the range must be whole numbers")
		expect(function()
			generator.nextWholeNumberInRange(1.5, 3)
		end).toThrow("the range must be whole numbers")
		-- 2^32 + 1 values: wider than one 32-bit draw can cover without bias.
		expect(function()
			generator.nextWholeNumberInRange(0, UNSIGNED_32_BIT_MODULUS)
		end).toThrow("the range must be whole numbers")
		-- Exactly 2^32 values is the widest range allowed.
		expect(generator.nextWholeNumberInRange(0, UNSIGNED_32_BIT_MODULUS - 1) % 1).toBe(0)
	end)

	it("is frozen: the module and every generator", function()
		expect(table.isfrozen(PortableSeededRandomNumberGenerator)).toBeTrue()
		expect(table.isfrozen(PortableSeededRandomNumberGenerator.createFromUnsigned32BitSeed(7))).toBeTrue()
	end)
end)

describe("PortableSeededRandomNumberGenerator randomized properties", function()
	it("every draw is an unsigned 32-bit whole number, for random seeds", function()
		SeededRandomTrials.runSeededRandomTrials(200, function(trialRandomNumberGenerator)
			local randomSeed = trialRandomNumberGenerator.nextWholeNumberInRange(0, UNSIGNED_32_BIT_MODULUS - 1)
			local generatorUnderTest = PortableSeededRandomNumberGenerator.createFromUnsigned32BitSeed(randomSeed)
			for _ = 1, 20 do
				local drawnNumber = generatorUnderTest.nextUnsigned32BitNumber()
				expect({
					randomSeed,
					drawnNumber % 1 == 0 and drawnNumber >= 0 and drawnNumber < UNSIGNED_32_BIT_MODULUS,
				}).toEqual({
					randomSeed,
					true,
				})
			end
		end)
	end)

	it("whole numbers stay inside random ranges, both ends included", function()
		SeededRandomTrials.runSeededRandomTrials(200, function(trialRandomNumberGenerator)
			local smallestWholeNumber = trialRandomNumberGenerator.nextWholeNumberInRange(-50, 50)
			local largestWholeNumber = smallestWholeNumber + trialRandomNumberGenerator.nextWholeNumberInRange(0, 10)
			local generatorUnderTest = PortableSeededRandomNumberGenerator.createFromSeedText(
				tostring(trialRandomNumberGenerator.nextWholeNumberInRange(1, 1000000))
			)
			local seenWholeNumberSet = {}
			for _ = 1, 400 do
				local drawnWholeNumber =
					generatorUnderTest.nextWholeNumberInRange(smallestWholeNumber, largestWholeNumber)
				expect(
					drawnWholeNumber % 1 == 0
						and drawnWholeNumber >= smallestWholeNumber
						and drawnWholeNumber <= largestWholeNumber
				).toBeTrue()
				seenWholeNumberSet[drawnWholeNumber] = true
			end
			-- 400 draws over at most 11 values: every value appears (miss chance below 1e-15 per value).
			for expectedWholeNumber = smallestWholeNumber, largestWholeNumber do
				expect({ expectedWholeNumber, seenWholeNumberSet[expectedWholeNumber] }).toEqual({
					expectedWholeNumber,
					true,
				})
			end
		end)
	end)

	it("spreads draws evenly: each of 12 values within 20% of its expected count over 12000 draws", function()
		local generatorUnderTest = PortableSeededRandomNumberGenerator.createFromSeedText("even-spread-check")
		local drawCountByValue = {}
		for _ = 1, 12000 do
			local drawnWholeNumber = generatorUnderTest.nextWholeNumberInRange(1, 12)
			drawCountByValue[drawnWholeNumber] = (drawCountByValue[drawnWholeNumber] or 0) + 1
		end
		for drawnValue = 1, 12 do
			local drawCount = drawCountByValue[drawnValue] or 0
			expect({ drawnValue, drawCount >= 800 and drawCount <= 1200 }).toEqual({ drawnValue, true })
		end
	end)
end)
