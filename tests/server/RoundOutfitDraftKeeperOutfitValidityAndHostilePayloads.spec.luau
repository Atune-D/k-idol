-- RoundOutfitDraftKeeper, §2.3 check 4 and untrusted messages: invalid outfits, hostile outfit
-- fields, malformed envelopes, forged fields, the private copy. Referee audit PART 3 section E,
-- scenarios 34 to 42 (times are round seconds T).

local fs = require("@lune/fs")

local UnitTestFramework = require("../Support/UnitTestFramework")
local FakeStylingItemPool = require("../fixtures/FakeStylingItemPool")
local RoundOutfitDraftKeeperTestHarness = require("./RoundOutfitDraftKeeperTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_P = RoundOutfitDraftKeeperTestHarness.PLAYER_P
local PLAYER_Q = RoundOutfitDraftKeeperTestHarness.PLAYER_Q
local ROUND_ID = RoundOutfitDraftKeeperTestHarness.ROUND_ID
local OUTFIT_A = RoundOutfitDraftKeeperTestHarness.OUTFIT_A
local OUTFIT_B = RoundOutfitDraftKeeperTestHarness.OUTFIT_B
local OUTFIT_C = RoundOutfitDraftKeeperTestHarness.OUTFIT_C
local OUTFIT_D = RoundOutfitDraftKeeperTestHarness.OUTFIT_D
local INVALID_OUTFIT_X = RoundOutfitDraftKeeperTestHarness.INVALID_OUTFIT_X
local WORKED_EXAMPLE_OUTFIT_E83 = RoundOutfitDraftKeeperTestHarness.WORKED_EXAMPLE_OUTFIT_E83
local expectedAcknowledgement = RoundOutfitDraftKeeperTestHarness.expectedAcknowledgement

local function createStylingHarnessWithParticipants(playerUserIds: { number })
	local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes()
	harness.joinAtRoundSecond3AndStartStyling(playerUserIds)
	return harness
end

local function countTableKeys(countedTable: { [any]: any }): number
	local keyCount = 0
	for _ in countedTable do
		keyCount += 1
	end
	return keyCount
end

describe("RoundOutfitDraftKeeper check 4 (spec §2.3, §1.5): invalid outfits", function()
	it("scenario 34: every kind of invalid outfit is acknowledged OutfitInvalid, never the detailed reason", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		local thirteenKeys = {}
		for keyNumber = 1, 13 do
			table.insert(thirteenKeys, "asset_90000" .. tostring(keyNumber))
		end
		local invalidOutfitCases = {
			{ "top plus dress", INVALID_OUTFIT_X, "DressCombinedWithTopOrBottom" },
			{ "hidden key", { FakeStylingItemPool.HIDDEN_HAIR_KEY }, "StylingItemHiddenThisSession" },
			{ "unknown key", { FakeStylingItemPool.KEY_NOT_IN_POOL }, "StylingItemNotInPool" },
			{ "duplicated key", { "asset_9000002", "asset_9000002" }, "DuplicateStylingItem" },
			{
				"four accessories",
				{ "asset_9000051", "asset_9000052", "asset_9000053", "asset_9000054" },
				"TooManyAccessoryItems",
			},
			{ "thirteen keys", thirteenKeys, "OutfitIsNotAListOfStylingItemKeys" },
		}
		for caseNumber, invalidOutfitCase in invalidOutfitCases do
			local roundSeconds = 20 + caseNumber
			harness.sendDraftAtRoundSecond(roundSeconds, PLAYER_P, caseNumber + 1, invalidOutfitCase[2])
			local acknowledgements = harness.listAcknowledgementsSentTo(PLAYER_P)
			expect({ invalidOutfitCase[1], acknowledgements[#acknowledgements] }).toEqual({
				invalidOutfitCase[1],
				expectedAcknowledgement(roundSeconds, caseNumber + 1, false),
			})
			local validationCalls = harness.countingOutfitValidator.validationCalls
			-- The validator did find the detailed reason; the keeper did not pass it on.
			expect(validationCalls[#validationCalls].verdict.outfitRejectionReason).toBe(invalidOutfitCase[3])
			expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_A)
		end
		for _, sentRecord in harness.recordingSender.sentAcknowledgementRecords do
			expect(countTableKeys(sentRecord.acknowledgement) <= 4).toBeTrue()
		end
		expect(harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()[PLAYER_P]).toEqual(OUTFIT_A)
	end)

	it("judges validity against the available key set read at processing time", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		local readsBefore = harness.countAvailableKeySetReads()
		harness.sendDraftAtRoundSecond(21, PLAYER_P, 2, OUTFIT_B)
		expect(harness.countAvailableKeySetReads()).toBe(readsBefore + 1)
		harness.hideStylingItemKeyFromNowOn(OUTFIT_C[1])
		harness.sendDraftAtRoundSecond(22, PLAYER_P, 3, OUTFIT_C)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[3]).toEqual(expectedAcknowledgement(22, 3, false))
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_B)
	end)

	it("scenario 40: an empty draft is a valid outfit and is kept", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(21, PLAYER_P, 2, {})
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[2]).toEqual(expectedAcknowledgement(21, 2, true))
		expect(harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()[PLAYER_P]).toEqual({})
	end)
end)

describe("RoundOutfitDraftKeeper with hostile outfit fields in a well-formed envelope", function()
	it("scenario 35: each hostile outfit field is rejected without raising; the kept draft stays", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)

		local listWithHole = {}
		listWithHole[1] = "asset_9000002"
		listWithHole[3] = "asset_9000012"
		local hundredThousandEntryList = table.create(100000, "asset_9000002")
		local listWithRaisingIndex = setmetatable({}, {
			__index = function()
				error("hostile __index ran")
			end,
			__len = function()
				error("hostile __len ran")
			end,
			__iter = function()
				error("hostile __iter ran")
			end,
		})
		local listContainingItself = {}
		listContainingItself[1] = listContainingItself
		local hostileOutfitFieldCases = {
			{ "number", 5 },
			{ "string", "asset_1" },
			{ "list of numbers", { 1, 2 } },
			{ "list with a hole", listWithHole },
			{ "100000-entry list", hundredThousandEntryList },
			{ "one 1 MB string", { string.rep("a", 1024 * 1024) } },
			{ "metatable whose __index raises", listWithRaisingIndex },
			{ "list containing itself", listContainingItself },
			{ "map", { a = "asset_1" } },
			{ "boolean", true },
			{ "function", function() end },
		}

		local nextSequenceNumber = 2
		local roundSeconds = 21
		local function sendHostileMessageAndExpectRejection(caseName: string, hostileMessage: any)
			harness.advanceToRoundSecond(roundSeconds)
			local didReturn, raisedError = pcall(function()
				harness.keeper:receiveOutfitDraftFromDevice(PLAYER_P, hostileMessage)
			end)
			expect({ caseName, didReturn, raisedError }).toEqual({ caseName, true, nil })
			local acknowledgements = harness.listAcknowledgementsSentTo(PLAYER_P)
			expect({ caseName, acknowledgements[#acknowledgements] }).toEqual({
				caseName,
				expectedAcknowledgement(roundSeconds, nextSequenceNumber, false),
			})
			expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_A)
			nextSequenceNumber += 1
			roundSeconds += 0.25
		end

		sendHostileMessageAndExpectRejection("field absent", { roundId = ROUND_ID, outfitDraftSequenceNumber = 2 })
		sendHostileMessageAndExpectRejection(
			"field nil",
			{ roundId = ROUND_ID, outfitDraftSequenceNumber = 3, outfitStylingItemKeys = nil }
		)
		for _, hostileCase in hostileOutfitFieldCases do
			sendHostileMessageAndExpectRejection(hostileCase[1], {
				roundId = ROUND_ID,
				outfitDraftSequenceNumber = nextSequenceNumber,
				outfitStylingItemKeys = hostileCase[2],
			})
		end
		expect(harness.countingOutfitValidator.validationCallCount).toBe(nextSequenceNumber - 1)
	end)

	it("scenario 35: what is validated is a small private value, never the device's large table", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		local hundredThousandEntryList = table.create(100000, "asset_9000002")
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		harness.keeper:receiveOutfitDraftFromDevice(PLAYER_P, {
			roundId = ROUND_ID,
			outfitDraftSequenceNumber = 2,
			outfitStylingItemKeys = hundredThousandEntryList,
		})
		harness.advanceToRoundSecond(21)
		local validationCalls = harness.countingOutfitValidator.validationCalls
		local validatedOutfitValue = validationCalls[#validationCalls].validatedOutfitValue
		expect(rawequal(validatedOutfitValue, hundredThousandEntryList)).toBeFalse()
		expect(type(validatedOutfitValue) ~= "table" or #validatedOutfitValue <= 13).toBeTrue()
	end)

	it("scenario 35: a waiting draft never holds a 1 MB string or a large table from a short list", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		local oneMegabyteString = string.rep("a", 1024 * 1024)
		local hundredThousandEntryTable = table.create(100000, "asset_9000002")
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		harness.keeper:receiveOutfitDraftFromDevice(PLAYER_P, {
			roundId = ROUND_ID,
			outfitDraftSequenceNumber = 2,
			outfitStylingItemKeys = { oneMegabyteString, hundredThousandEntryTable },
		})
		-- Read straight from the waiting place while the draft waits for its interval.
		local waitingSnapshot =
			harness.keeper.participantStateByPlayerUserId[PLAYER_P].waitingOutfitStylingItemKeysSnapshot
		expect(waitingSnapshot).toBe(false)
		harness.advanceToRoundSecond(21)
		local validationCalls = harness.countingOutfitValidator.validationCalls
		expect(validationCalls[#validationCalls].validatedOutfitValue).toBe(false)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[2]).toEqual(expectedAcknowledgement(20.25, 2, false))
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_A)
	end)

	it("scenario 36: a frozen message holding a frozen valid list is processed and kept", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.advanceToRoundSecond(20)
		local frozenMessage = table.freeze({
			roundId = ROUND_ID,
			outfitDraftSequenceNumber = 1,
			outfitStylingItemKeys = table.freeze({ "asset_9000003", "asset_9000012" }),
		})
		harness.keeper:receiveOutfitDraftFromDevice(PLAYER_P, frozenMessage)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({ expectedAcknowledgement(20, 1, true) })
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_B)
	end)
end)

describe("RoundOutfitDraftKeeper with malformed envelopes", function()
	it("scenario 37: each malformed envelope is ignored without raising and changes nothing", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_A)
		harness.sendDraftAtRoundSecond(20.1, PLAYER_P, 2, OUTFIT_B) -- waiting, due 20.25
		local raisingMetatableMessage = setmetatable({}, {
			__index = function()
				error("hostile __index ran")
			end,
			__iter = function()
				error("hostile __iter ran")
			end,
		})
		local messageContainingItself = {}
		messageContainingItself.roundId = messageContainingItself
		messageContainingItself.outfitDraftSequenceNumber = messageContainingItself
		local malformedMessageCases = {
			{ "nil", nil },
			{ "true", true },
			{ "42", 42 },
			{ "string", "x" },
			{ "function", function() end },
			{ "empty table", {} },
			{ "roundId only", { roundId = ROUND_ID } },
			{ "raising metatable", raisingMetatableMessage },
			{ "containing itself", messageContainingItself },
			{ "array form", { ROUND_ID, 9, OUTFIT_C } },
		}
		harness.advanceToRoundSecond(20.2)
		local didReturnWithoutMessage = pcall(function()
			harness.keeper:receiveOutfitDraftFromDevice(PLAYER_P)
		end)
		expect(didReturnWithoutMessage).toBeTrue()
		for _, malformedCase in malformedMessageCases do
			local didReturn, raisedError = pcall(function()
				harness.keeper:receiveOutfitDraftFromDevice(PLAYER_P, malformedCase[2])
			end)
			expect({ malformedCase[1], didReturn, raisedError }).toEqual({ malformedCase[1], true, nil })
		end
		expect(#harness.listAcknowledgementsSentTo(PLAYER_P)).toBe(1)
		expect(harness.keeper:readHighestProcessedOutfitDraftSequenceNumber(PLAYER_P)).toBe(1)
		expect(harness.fakeScheduler:getPendingCallbackCount()).toBe(1)
		harness.advanceToRoundSecond(20.25) -- the waiting seq 2 is still there and processed on time
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[2]).toEqual(expectedAcknowledgement(20.25, 2, true))

		-- Ignored messages did not record a processing: seq 3 exactly 0.25 s later goes at once.
		harness.advanceToRoundSecond(20.5)
		for _, malformedCase in malformedMessageCases do
			harness.keeper:receiveOutfitDraftFromDevice(PLAYER_P, malformedCase[2])
		end
		harness.keeper:receiveOutfitDraftFromDevice(PLAYER_P, harness.buildOutfitDraftMessage(3, OUTFIT_C))
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[3]).toEqual(expectedAcknowledgement(20.5, 3, true))
		expect(harness.countingOutfitValidator.validationCallCount).toBe(3)
	end)

	it("scenario 38: forged result fields are ignored and the draft belongs to the server-known sender", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P, PLAYER_Q })
		harness.advanceToRoundSecond(20)
		harness.keeper:receiveOutfitDraftFromDevice(PLAYER_P, {
			roundId = ROUND_ID,
			outfitDraftSequenceNumber = 1,
			outfitStylingItemKeys = table.clone(WORKED_EXAMPLE_OUTFIT_E83),
			outfitScore = 100,
			starCount = 5,
			starCoinsGranted = 1e9,
			fanCountGained = 1e9,
			playerUserId = PLAYER_Q,
		})
		expect(harness.recordingSender.countAcknowledgements()).toBe(1)
		expect(harness.recordingSender.sentAcknowledgementRecords[1].playerUserId).toBe(PLAYER_P)
		expect(harness.recordingSender.sentAcknowledgementRecords[1].acknowledgement).toEqual({
			roundId = ROUND_ID,
			outfitDraftSequenceNumber = 1,
			isKept = true,
		})
		expect(harness.countingOutfitValidator.validationCalls[1].validatedOutfitValue).toEqual(
			WORKED_EXAMPLE_OUTFIT_E83
		)
		local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		expect(finalOutfits[PLAYER_P]).toEqual(WORKED_EXAMPLE_OUTFIT_E83)
		expect(finalOutfits[PLAYER_Q]).toEqual({})
	end)

	it("the acknowledgement always carries the server's own roundId, not the received value", function()
		local harness = RoundOutfitDraftKeeperTestHarness.createKeeperWithFakes()
		harness.advanceToRoundSecond(3)
		local numericRoundKeeper = harness.createKeeperForRound("17")
		numericRoundKeeper:addParticipant(PLAYER_P)
		numericRoundKeeper:startAcceptingOutfitDrafts()
		harness.advanceToRoundSecond(20)
		numericRoundKeeper:receiveOutfitDraftFromDevice(PLAYER_P, harness.buildOutfitDraftMessage(1, OUTFIT_A, 17))
		expect(harness.recordingSender.countAcknowledgements()).toBe(0)
		numericRoundKeeper:receiveOutfitDraftFromDevice(PLAYER_P, harness.buildOutfitDraftMessage(1, OUTFIT_A, "17"))
		local sentAcknowledgement = harness.recordingSender.sentAcknowledgementRecords[1].acknowledgement
		expect(sentAcknowledgement.roundId).toBe("17")
		expect(table.isfrozen(sentAcknowledgement)).toBeTrue()
	end)
end)

describe("RoundOutfitDraftKeeper keeps a private copy (audit question 9)", function()
	it("scenario 39 (a): changing the submitted list while the draft waits changes nothing", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20.00, PLAYER_P, 1, OUTFIT_A)
		local submittedList = table.clone(OUTFIT_B)
		harness.advanceToRoundSecond(20.10)
		harness.keeper:receiveOutfitDraftFromDevice(
			PLAYER_P,
			{ roundId = ROUND_ID, outfitDraftSequenceNumber = 2, outfitStylingItemKeys = submittedList }
		)
		harness.advanceToRoundSecond(20.15)
		submittedList[1] = "asset_9000011"
		submittedList[2] = "asset_9000032"
		harness.advanceToRoundSecond(20.25)
		expect(harness.countingOutfitValidator.validationCalls[2].validatedOutfitValue).toEqual(OUTFIT_B)
		expect(harness.listAcknowledgementsSentTo(PLAYER_P)[2]).toEqual(expectedAcknowledgement(20.25, 2, true))
		expect(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)).toEqual(OUTFIT_B)
	end)

	it("scenario 39 (b): changing the submitted list after the acknowledgement changes nothing", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.advanceToRoundSecond(20)
		local submittedList = table.clone(OUTFIT_D)
		harness.keeper:receiveOutfitDraftFromDevice(
			PLAYER_P,
			{ roundId = ROUND_ID, outfitDraftSequenceNumber = 1, outfitStylingItemKeys = submittedList }
		)
		table.clear(submittedList)
		local keptOutfit = harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P)
		expect(keptOutfit).toEqual(OUTFIT_D)
		expect(table.isfrozen(keptOutfit)).toBeTrue()
		expect(harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()[PLAYER_P]).toEqual(OUTFIT_D)
	end)

	it("keeps exactly the table that was validated", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_C)
		local validatedOutfitValue = harness.countingOutfitValidator.validationCalls[1].validatedOutfitValue
		expect(rawequal(harness.keeper:readKeptOutfitStylingItemKeys(PLAYER_P), validatedOutfitValue)).toBeTrue()
	end)
end)

describe("RoundOutfitDraftKeeper acknowledgements and the save", function()
	it("scenario 41: the source of every draft protocol module names neither the save nor the ledger", function()
		local specFilePath = debug.info(1, "s")
		local projectRootPath = string.match(specFilePath, "^(.*)[/\\]tests[/\\]server[/\\][^/\\]+$")
		expect(projectRootPath ~= nil).toBeTrue()
		for _, moduleFileName in
			{
				"RoundOutfitDraftKeeper.luau",
				"RoundOutfitDraftKeeperDependencyCheck.luau",
				"RoundOutfitDraftParticipantState.luau",
				"RoundOutfitDraftAcknowledgementOutbox.luau",
				"SetRoundOutfitDraftMessageReader.luau",
			}
		do
			local moduleSource = fs.readFile(projectRootPath .. "/src/server/" .. moduleFileName)
			for _, forbiddenText in
				{ "PlayerSaveDataKeeper", "RewardLedger", "applyChangeToPlayerSaveData", "grantThemedRoundReward" }
			do
				expect({ moduleFileName, forbiddenText, string.find(moduleSource, forbiddenText, 1, true) }).toEqual({
					moduleFileName,
					forbiddenText,
				})
			end
		end
	end)

	it("scenario 42: exactly one fresh acknowledgement per processed draft over a scripted run", function()
		local harness = createStylingHarnessWithParticipants({ PLAYER_P })
		local scriptedArrivals = {
			{ 20.00, 1, OUTFIT_A }, -- processed at once
			{ 20.05, 2, OUTFIT_B }, -- replaced while waiting
			{ 20.10, 3, INVALID_OUTFIT_X }, -- processed at 20.25, invalid
			{ 20.30, 3, OUTFIT_C }, -- duplicate: re-send
			{ 20.40, 4, OUTFIT_C }, -- processed at 20.50
			{ 21.00, 5, OUTFIT_D }, -- at once
			{ 21.01, 6, OUTFIT_A }, -- replaced
			{ 21.02, 7, OUTFIT_B }, -- replaced
			{ 21.03, 8, INVALID_OUTFIT_X }, -- processed 21.25
			{ 22.00, 9, {} }, -- at once
			{ 22.10, 10, OUTFIT_C }, -- 22.25
			{ 30.00, 11, OUTFIT_D }, -- at once
			{ 30.01, 8, OUTFIT_A }, -- re-send
			{ 30.02, 12, OUTFIT_A }, -- replaced
			{ 30.03, 13, OUTFIT_B }, -- 30.25
			{ 189.90, 14, OUTFIT_C }, -- at once
			{ 189.91, 15, OUTFIT_D }, -- replaced
			{ 189.92, 16, INVALID_OUTFIT_X }, -- replaced
			{ 189.93, 17, OUTFIT_A }, -- replaced
			{ 189.94, 18, OUTFIT_B }, -- flushed at the cut-off
		}
		for _, arrival in scriptedArrivals do
			harness.sendDraftAtRoundSecond(arrival[1], PLAYER_P, arrival[2], arrival[3])
		end
		harness.advanceToRoundSecond(190)
		local finalOutfits = harness.keeper:cutOffOutfitDraftsAndFreezeFinalOutfits()
		expect(finalOutfits[PLAYER_P]).toEqual(OUTFIT_B)

		expect(harness.listAcknowledgementsSentTo(PLAYER_P)).toEqual({
			expectedAcknowledgement(20.00, 1, true),
			expectedAcknowledgement(20.25, 3, false),
			expectedAcknowledgement(20.30, 3, false),
			expectedAcknowledgement(20.50, 4, true),
			expectedAcknowledgement(21.00, 5, true),
			expectedAcknowledgement(21.25, 8, false),
			expectedAcknowledgement(22.00, 9, true),
			expectedAcknowledgement(22.25, 10, true),
			expectedAcknowledgement(30.00, 11, true),
			expectedAcknowledgement(30.01, 11, true),
			expectedAcknowledgement(30.25, 13, true),
			expectedAcknowledgement(189.90, 14, true),
			expectedAcknowledgement(190.00, 18, true),
		})
		-- Processed numbers: 1, 3, 4, 5, 8, 9, 10, 11, 13, 14, 18 = 11 validations.
		expect(harness.countingOutfitValidator.validationCallCount).toBe(11)
	end)
end)
