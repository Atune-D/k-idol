-- Randomized test support: a small seeded random number generator and a trial runner that
-- names the seed in every failure, so a failing random case can be reproduced exactly.
--
-- Each run picks a fresh seed, unless the environment variable IDOLGROW_RANDOM_TEST_SEED is set:
--   IDOLGROW_RANDOM_TEST_SEED=123456 lune run tests/RunAllTests.luau
-- Every randomized test uses that same seed, so the failing trial repeats.

local process = require("@lune/process")

local UnitTestExpectations = require("../Support/UnitTestExpectations")

local SeededRandomTrials = {}

export type SeededRandomNumberGenerator = {
	nextWholeNumberInRange: (smallestWholeNumber: number, largestWholeNumber: number) -> number,
	nextFractionBetweenZeroAndOne: () -> number,
	pickRandomListElement: <ListElement>(candidateList: { ListElement }) -> ListElement,
	shuffleListInPlace: <ListElement>(shuffledList: { ListElement }) -> (),
}

local RANDOM_TEST_SEED_ENVIRONMENT_VARIABLE = "IDOLGROW_RANDOM_TEST_SEED"
local UINT32_MODULUS = 4294967296

local function chooseRandomTestSeedForThisRun(): number
	local seedOverrideText = process.env[RANDOM_TEST_SEED_ENVIRONMENT_VARIABLE]
	if seedOverrideText ~= nil and seedOverrideText ~= "" then
		local seedOverride = tonumber(seedOverrideText)
		if seedOverride == nil or seedOverride ~= math.floor(seedOverride) or seedOverride < 1 then
			error(RANDOM_TEST_SEED_ENVIRONMENT_VARIABLE .. " must be a positive whole number, got " .. seedOverrideText)
		end
		return seedOverride
	end
	-- Mix wall-clock seconds with the high-resolution clock so two runs in one second differ.
	return (os.time() * 1000 + math.floor(os.clock() * 1000000)) % (UINT32_MODULUS - 1) + 1
end

SeededRandomTrials.RANDOM_TEST_SEED = chooseRandomTestSeedForThisRun()

-- xorshift32: deterministic for a given seed, independent of math.random's global state.
function SeededRandomTrials.createSeededRandomNumberGenerator(randomSeed: number): SeededRandomNumberGenerator
	local generatorState = randomSeed % UINT32_MODULUS
	if generatorState == 0 then
		generatorState = 2463534242
	end

	local function nextUnsigned32BitNumber(): number
		generatorState = bit32.bxor(generatorState, bit32.lshift(generatorState, 13))
		generatorState = bit32.bxor(generatorState, bit32.rshift(generatorState, 17))
		generatorState = bit32.bxor(generatorState, bit32.lshift(generatorState, 5))
		return generatorState
	end

	local seededRandomNumberGenerator = {}

	function seededRandomNumberGenerator.nextFractionBetweenZeroAndOne(): number
		return nextUnsigned32BitNumber() / UINT32_MODULUS
	end

	function seededRandomNumberGenerator.nextWholeNumberInRange(
		smallestWholeNumber: number,
		largestWholeNumber: number
	): number
		local rangeSize = largestWholeNumber - smallestWholeNumber + 1
		return smallestWholeNumber + math.floor(seededRandomNumberGenerator.nextFractionBetweenZeroAndOne() * rangeSize)
	end

	function seededRandomNumberGenerator.pickRandomListElement<ListElement>(candidateList: { ListElement }): ListElement
		assert(#candidateList > 0, "pickRandomListElement needs a non-empty list")
		return candidateList[seededRandomNumberGenerator.nextWholeNumberInRange(1, #candidateList)]
	end

	function seededRandomNumberGenerator.shuffleListInPlace<ListElement>(shuffledList: { ListElement })
		for listPosition = #shuffledList, 2, -1 do
			local swapPosition = seededRandomNumberGenerator.nextWholeNumberInRange(1, listPosition)
			shuffledList[listPosition], shuffledList[swapPosition] =
				shuffledList[swapPosition], shuffledList[listPosition]
		end
	end

	return seededRandomNumberGenerator :: any
end

-- Runs `trialBody` `trialCount` times with one generator seeded from this run's seed. When a
-- trial fails, the failure message is prefixed with the seed and trial number.
function SeededRandomTrials.runSeededRandomTrials(
	trialCount: number,
	trialBody: (
		seededRandomNumberGenerator: SeededRandomNumberGenerator,
		trialNumber: number
	) -> ()
)
	local seededRandomNumberGenerator =
		SeededRandomTrials.createSeededRandomNumberGenerator(SeededRandomTrials.RANDOM_TEST_SEED)
	for trialNumber = 1, trialCount do
		local didTrialPass, trialError = pcall(trialBody, seededRandomNumberGenerator, trialNumber)
		if not didTrialPass then
			local reproductionHint = string.format(
				"[random trial %d of %d failed with seed %d; reproduce with %s=%d] ",
				trialNumber,
				trialCount,
				SeededRandomTrials.RANDOM_TEST_SEED,
				RANDOM_TEST_SEED_ENVIRONMENT_VARIABLE,
				SeededRandomTrials.RANDOM_TEST_SEED
			)
			if UnitTestExpectations.isExpectationFailure(trialError) then
				trialError.failureMessage = reproductionHint .. trialError.failureMessage
				error(trialError, 0)
			end
			error(reproductionHint .. tostring(trialError), 0)
		end
	end
end

return table.freeze(SeededRandomTrials)
