-- A deterministic random number generator seeded from text, written in plain Luau so that the same
-- seed text gives the same numbers on every Roblox game server, on every device and in Lune.
--
-- Why it exists: the three daily quests (development spec §1.8) are "selected from the catalog by
-- a random generator seeded with dailyDateKey" and must be the same for every player. Roblox's own
-- random generator and math.random are runtime-specific and may differ between engine versions or
-- between Roblox and Lune, so neither is used here.
--
-- Algorithm (both parts are public domain and well known):
--   1. Seed: the text is hashed with 32-bit FNV-1a (offset basis 2166136261, prime 16777619),
--      byte by byte over string.byte values.
--   2. Generator: mulberry32 (Tommy Ettinger). State is one unsigned 32-bit number. Each step adds
--      0x6D2B79F5 to the state, then mixes a copy of it:
--        t = imul(t xor (t >> 15), t or 1)
--        t = t xor (t + imul(t xor (t >> 7), t or 61))
--        output = t xor (t >> 14)
--   3. Whole numbers in a range use rejection sampling, so every value in the range is exactly
--      equally likely.
-- All arithmetic is exact: 32-bit products are computed in 16-bit halves so no intermediate
-- value exceeds 2^53, the largest whole number a Luau number holds exactly.
--
-- Changing anything here changes which daily quests every player gets on every date.
-- Pure logic: no Roblox-specific interface is used.

local PortableSeededRandomNumberGenerator = {}

local UNSIGNED_32_BIT_MODULUS = 4294967296
local FNV_1A_32_BIT_OFFSET_BASIS = 2166136261
local FNV_1A_32_BIT_PRIME = 16777619
local MULBERRY32_STATE_INCREMENT = 0x6D2B79F5

export type PortableSeededRandomNumberGenerator = {
	nextUnsigned32BitNumber: () -> number,
	nextWholeNumberInRange: (smallestWholeNumber: number, largestWholeNumber: number) -> number,
}

-- (firstFactor * secondFactor) mod 2^32 for two unsigned 32-bit numbers, computed exactly.
local function multiplyUnsigned32BitNumbersModulo2Pow32(firstFactor: number, secondFactor: number): number
	local secondFactorLowHalf = secondFactor % 65536
	local secondFactorHighHalf = (secondFactor - secondFactorLowHalf) / 65536
	local lowHalfProduct = firstFactor * secondFactorLowHalf -- below 2^48
	local highHalfProductModulo2Pow16 = (firstFactor * secondFactorHighHalf) % 65536 -- product below 2^48
	return (lowHalfProduct + highHalfProductModulo2Pow16 * 65536) % UNSIGNED_32_BIT_MODULUS
end

-- 32-bit FNV-1a hash of `seedText`, an unsigned 32-bit number.
function PortableSeededRandomNumberGenerator.hashSeedTextWithFnv1a32(seedText: string): number
	if type(seedText) ~= "string" then
		error("PortableSeededRandomNumberGenerator: seedText must be a string", 2)
	end
	local seedTextHash = FNV_1A_32_BIT_OFFSET_BASIS
	for seedTextBytePosition = 1, #seedText do
		seedTextHash = bit32.bxor(seedTextHash, string.byte(seedText, seedTextBytePosition))
		seedTextHash = multiplyUnsigned32BitNumbersModulo2Pow32(seedTextHash, FNV_1A_32_BIT_PRIME)
	end
	return seedTextHash
end

-- A new mulberry32 generator starting from an unsigned 32-bit seed (a whole number 0 to 2^32 - 1).
function PortableSeededRandomNumberGenerator.createFromUnsigned32BitSeed(
	unsigned32BitSeed: number
): PortableSeededRandomNumberGenerator
	if
		type(unsigned32BitSeed) ~= "number"
		or unsigned32BitSeed % 1 ~= 0
		or unsigned32BitSeed < 0
		or unsigned32BitSeed >= UNSIGNED_32_BIT_MODULUS
	then
		error("PortableSeededRandomNumberGenerator: the seed must be a whole number from 0 to 2^32 - 1", 2)
	end
	local mulberry32State = unsigned32BitSeed

	local function nextUnsigned32BitNumber(): number
		mulberry32State = (mulberry32State + MULBERRY32_STATE_INCREMENT) % UNSIGNED_32_BIT_MODULUS
		local mixedNumber = mulberry32State
		mixedNumber = multiplyUnsigned32BitNumbersModulo2Pow32(
			bit32.bxor(mixedNumber, bit32.rshift(mixedNumber, 15)),
			bit32.bor(mixedNumber, 1)
		)
		local secondMixTerm = multiplyUnsigned32BitNumbersModulo2Pow32(
			bit32.bxor(mixedNumber, bit32.rshift(mixedNumber, 7)),
			bit32.bor(mixedNumber, 61)
		)
		mixedNumber = bit32.bxor(mixedNumber, (mixedNumber + secondMixTerm) % UNSIGNED_32_BIT_MODULUS)
		return bit32.bxor(mixedNumber, bit32.rshift(mixedNumber, 14))
	end

	-- A whole number from smallestWholeNumber to largestWholeNumber inclusive, all equally likely.
	local function nextWholeNumberInRange(smallestWholeNumber: number, largestWholeNumber: number): number
		local rangeSize = largestWholeNumber - smallestWholeNumber + 1
		if
			smallestWholeNumber % 1 ~= 0
			or largestWholeNumber % 1 ~= 0
			or rangeSize < 1
			or rangeSize > UNSIGNED_32_BIT_MODULUS
		then
			error("PortableSeededRandomNumberGenerator: the range must be whole numbers, smallest <= largest", 2)
		end
		-- Draws at or above this limit would make the low values of the range more likely; redraw them.
		-- No test pins `>=` against `>`: only a draw exactly equal to the limit tells them apart, and
		-- no seed is known that produces one, so this line is checked by reading, not by a test.
		local unbiasedDrawLimit = UNSIGNED_32_BIT_MODULUS - UNSIGNED_32_BIT_MODULUS % rangeSize
		local drawnNumber = nextUnsigned32BitNumber()
		while drawnNumber >= unbiasedDrawLimit do
			drawnNumber = nextUnsigned32BitNumber()
		end
		return smallestWholeNumber + drawnNumber % rangeSize
	end

	return table.freeze({
		nextUnsigned32BitNumber = nextUnsigned32BitNumber,
		nextWholeNumberInRange = nextWholeNumberInRange,
	})
end

-- A new generator whose sequence depends on `seedText` alone: mulberry32 seeded with its FNV-1a hash.
function PortableSeededRandomNumberGenerator.createFromSeedText(seedText: string): PortableSeededRandomNumberGenerator
	return PortableSeededRandomNumberGenerator.createFromUnsigned32BitSeed(
		PortableSeededRandomNumberGenerator.hashSeedTextWithFnv1a32(seedText)
	)
end

return table.freeze(PortableSeededRandomNumberGenerator)
