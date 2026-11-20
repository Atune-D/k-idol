-- ThemedRoundReferee, what is published when grants do not go through, and when each message is
-- sent (development spec §2.1 RoundStateChanged, §2.5, §3.3). Referee audit PART 3 scenario 59
-- with a scriptable fake ledger, PART 1 questions 15, 18, 21; plus failing senders and a failing
-- display-name lookup, which must never stop the round.

local UnitTestFramework = require("../Support/UnitTestFramework")
local ScriptableFakeThemedRoundRewardLedger = require("../Support/ScriptableFakeThemedRoundRewardLedger")
local ThemedRoundRefereeTestHarness = require("./ThemedRoundRefereeTestHarness")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local PLAYER_P = ThemedRoundRefereeTestHarness.PLAYER_P
local PLAYER_Q = ThemedRoundRefereeTestHarness.PLAYER_Q
local OUTFIT_A = ThemedRoundRefereeTestHarness.OUTFIT_A
local OUTFIT_E83 = ThemedRoundRefereeTestHarness.WORKED_EXAMPLE_OUTFIT_E83
local createRefereeWithFakes = ThemedRoundRefereeTestHarness.createRefereeWithFakes

local PLAYER_1, PLAYER_2, PLAYER_3, PLAYER_4, PLAYER_5 = 9201, 9202, 9203, 9204, 9205

local function findEntryFor(roundResults, playerUserId: number)
	for _, roundResultsEntry in roundResults do
		if roundResultsEntry.playerUserId == playerUserId then
			return roundResultsEntry
		end
	end
	return nil
end

describe(
	"ThemedRoundReferee ledger outcomes are isolated and reported truthfully (audit scenario 59, question 18)",
	function()
		local function playRoundWithScriptedLedger()
			local fakeLedger = ScriptableFakeThemedRoundRewardLedger.new()
			fakeLedger:scriptGrantOutcomeForPlayer(PLAYER_1, "SaveDataNotLoaded")
			fakeLedger:scriptGrantOutcomeForPlayer(PLAYER_2, "Declined")
			fakeLedger:scriptGrantOutcomeForPlayer(PLAYER_3, "Raise")
			fakeLedger:scriptGrantOutcomeForPlayer(PLAYER_5, "ReturnNothing")
			local harness = createRefereeWithFakes({ rewardLedger = fakeLedger })
			local playerUserIds = { PLAYER_1, PLAYER_2, PLAYER_3, PLAYER_4, PLAYER_5 }
			harness.loadAndJoinAtRoundSecond3(playerUserIds)
			for _, playerUserId in playerUserIds do
				harness.sendDraftAtRoundSecond(20, playerUserId, 1, OUTFIT_E83)
			end
			harness.advanceToRoundSecond(280)
			return harness, fakeLedger
		end

		it(
			"SaveDataNotLoaded: no entry; Declined, a raise, or no answer: true score with 0, 0, false; Granted: paid",
			function()
				local harness = playRoundWithScriptedLedger()
				local publishedMessages = harness.listPublishedRoundResultsMessages()
				expect(#publishedMessages).toBe(1)
				local roundResults = publishedMessages[1].roundResults
				expect(#roundResults).toBe(4)
				expect(findEntryFor(roundResults, PLAYER_1)).toBeNil()
				for _, notPaidPlayerUserId in { PLAYER_2, PLAYER_3, PLAYER_5 } do
					local roundResultsEntry = findEntryFor(roundResults, notPaidPlayerUserId)
					expect(roundResultsEntry.outfitScore).toBe(83)
					expect(roundResultsEntry.starCount).toBe(4)
					expect(roundResultsEntry.starCoinsGranted).toBe(0)
					expect(roundResultsEntry.fanCountGained).toBe(0)
					expect(roundResultsEntry.isNewBestStarCountForTheme).toBeFalse()
					expect(harness.readInMemorySaveData(notPaidPlayerUserId).starCoinBalance).toBe(350)
				end
				local paidEntry = findEntryFor(roundResults, PLAYER_4)
				expect({ paidEntry.starCoinsGranted, paidEntry.fanCountGained, paidEntry.isNewBestStarCountForTheme }).toEqual({
					80,
					40,
					true,
				})
			end
		)

		it("calls the ledger exactly once per participant up to the next round, the raising one included", function()
			local harness, fakeLedger = playRoundWithScriptedLedger()
			for _, playerUserId in { PLAYER_1, PLAYER_2, PLAYER_3, PLAYER_4, PLAYER_5 } do
				expect(fakeLedger:countGrantCallsFor(playerUserId)).toBe(1)
			end
			local grantCall = fakeLedger.grantCalls[4]
			expect(grantCall.playerUserId).toBe(PLAYER_4)
			expect(grantCall.themedRoundCompletion).toEqual({
				roundId = "round-1",
				themeId = "y2k_pop",
				starCount = 4,
				scoredOutfitStylingItemKeys = OUTFIT_E83,
			})
			local warningsNamingPlayer3 = 0
			for _, loggedWarning in harness.recordingLogger.loggedWarnings do
				if string.find(loggedWarning, tostring(PLAYER_3), 1, true) then
					warningsNamingPlayer3 += 1
				end
			end
			expect(warningsNamingPlayer3).toBe(1)
		end)
	end
)

describe("ThemedRoundReferee publishes what the ledger applied (audit question 18)", function()
	it("a Granted answer with other amounts than the score's tier is published as the ledger answered", function()
		local fakeLedger = ScriptableFakeThemedRoundRewardLedger.new()
		fakeLedger:scriptGrantOutcomeForPlayer(PLAYER_P, "GrantedWithOtherAmounts")
		local harness = createRefereeWithFakes({ rewardLedger = fakeLedger })
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
		harness.advanceToRoundSecond(251)
		local roundResultsEntry = harness.listPublishedRoundResultsMessages()[1].roundResults[1]
		expect({
			roundResultsEntry.starCount,
			roundResultsEntry.starCoinsGranted,
			roundResultsEntry.fanCountGained,
			roundResultsEntry.isNewBestStarCountForTheme,
		}).toEqual({ 4, 81, 41, false })
	end)

	it("SaveDataNotLoaded treats the player as left: not listed in the Results RoundStateChanged or reads", function()
		local fakeLedger = ScriptableFakeThemedRoundRewardLedger.new()
		fakeLedger:scriptGrantOutcomeForPlayer(PLAYER_P, "SaveDataNotLoaded")
		local harness = createRefereeWithFakes({ rewardLedger = fakeLedger })
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P, PLAYER_Q })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
		harness.sendDraftAtRoundSecond(20, PLAYER_Q, 1, OUTFIT_E83)
		harness.advanceToRoundSecond(250)
		local roundResults = harness.listPublishedRoundResultsMessages()[1].roundResults
		expect(#roundResults).toBe(1)
		expect(roundResults[1].playerUserId).toBe(PLAYER_Q)
		expect(harness.readLastBroadcastParticipantUserIds()).toEqual({ PLAYER_Q })
		expect(harness.referee:isParticipantOfCurrentRound(PLAYER_P)).toBeFalse()
		expect(harness.referee:listCurrentRoundParticipantUserIds()).toEqual({ PLAYER_Q })
		harness.advanceToRoundSecond(280)
		expect(fakeLedger:countGrantCallsFor(PLAYER_P)).toBe(1)
	end)
end)

describe("ThemedRoundReferee ledger answers that are not outcomes", function()
	it("an answer that is nil or not a table is logged and shown as nothing applied", function()
		local fakeLedger = ScriptableFakeThemedRoundRewardLedger.new()
		fakeLedger:scriptGrantOutcomeForPlayer(PLAYER_P, "ReturnNumber")
		fakeLedger:scriptGrantOutcomeForPlayer(PLAYER_Q, "ReturnNothing")
		local harness = createRefereeWithFakes({ rewardLedger = fakeLedger })
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P, PLAYER_Q })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
		harness.sendDraftAtRoundSecond(20, PLAYER_Q, 1, OUTFIT_E83)
		harness.advanceToRoundSecond(251)
		local roundResults = harness.listPublishedRoundResultsMessages()[1].roundResults
		for _, playerUserId in { PLAYER_P, PLAYER_Q } do
			local roundResultsEntry = findEntryFor(roundResults, playerUserId)
			expect({ roundResultsEntry.starCount, roundResultsEntry.starCoinsGranted, roundResultsEntry.fanCountGained }).toEqual({
				4,
				0,
				0,
			})
		end
		expect(#harness.recordingLogger.loggedWarnings).toBe(2)
		for _, loggedWarning in harness.recordingLogger.loggedWarnings do
			expect(string.find(loggedWarning, "the ledger gave no answer", 1, true) ~= nil).toBeTrue()
		end
	end)
end)

describe("ThemedRoundReferee display names (§2.5 playerDisplayName)", function()
	it("takes the name from the server; a lookup that fails shows the user id and is logged", function()
		local harness = createRefereeWithFakes({
			readPlayerDisplayName = function(playerUserId: number)
				if playerUserId == PLAYER_P then
					error("display name lookup failed")
				end
				if playerUserId == PLAYER_Q then
					return 12345 :: any
				end
				return "Name of " .. tostring(playerUserId)
			end,
		})
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P, PLAYER_Q, PLAYER_1 })
		for _, playerUserId in { PLAYER_P, PLAYER_Q, PLAYER_1 } do
			harness.sendDraftAtRoundSecond(20, playerUserId, 1, OUTFIT_E83)
		end
		harness.advanceToRoundSecond(251)
		local roundResults = harness.listPublishedRoundResultsMessages()[1].roundResults
		expect(findEntryFor(roundResults, PLAYER_P).playerDisplayName).toBe(tostring(PLAYER_P))
		expect(findEntryFor(roundResults, PLAYER_Q).playerDisplayName).toBe(tostring(PLAYER_Q))
		expect(findEntryFor(roundResults, PLAYER_1).playerDisplayName).toBe("Name of " .. tostring(PLAYER_1))
		expect(findEntryFor(roundResults, PLAYER_P).starCoinsGranted).toBe(80)
		expect(#harness.recordingLogger.loggedWarnings).toBe(2)
	end)
end)

describe(
	"ThemedRoundReferee message order (§2.1, audit question 15: RoundStateChanged after the referee's work)",
	function()
		it(
			"at Showcase the cut-off's acknowledgement goes out before RoundStateChanged; at Results the publication does",
			function()
				local harness = createRefereeWithFakes()
				harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
				harness.sendDraftAtRoundSecond(189.90, PLAYER_P, 1, OUTFIT_A)
				harness.sendDraftAtRoundSecond(189.95, PLAYER_P, 2, OUTFIT_E83)
				local logLengthBeforeShowcase = #harness.orderedSentMessageLog
				harness.advanceToRoundSecond(190)
				expect(
					table.move(
						harness.orderedSentMessageLog,
						logLengthBeforeShowcase + 1,
						#harness.orderedSentMessageLog,
						1,
						{}
					)
				).toEqual({
					{ sentMessageKind = "RoundOutfitDraftAcknowledged", playerUserId = PLAYER_P },
					{ sentMessageKind = "RoundStateChanged" },
				})
				local logLengthBeforeResults = #harness.orderedSentMessageLog
				harness.advanceToRoundSecond(250)
				expect(
					table.move(
						harness.orderedSentMessageLog,
						logLengthBeforeResults + 1,
						#harness.orderedSentMessageLog,
						1,
						{}
					)
				).toEqual({
					{ sentMessageKind = "RoundResultsPublished" },
					{ sentMessageKind = "RoundStateChanged" },
				})
			end
		)

		it("sends one RoundStateChanged per phase change carrying the clock's state", function()
			local harness = createRefereeWithFakes()
			harness.advanceToRoundSecond(280)
			local expectedPhases = { "ThemeReveal", "Styling", "Showcase", "Results", "Intermission", "ThemeReveal" }
			local expectedRoundMilliseconds = { 0, 10000, 190000, 250000, 270000, 280000 }
			expect(#harness.sentRoundStateChangedRecords).toBe(#expectedPhases)
			for recordPosition, sentRecord in harness.sentRoundStateChangedRecords do
				local roundStateChangedMessage = sentRecord.roundStateChangedMessage
				expect(sentRecord.roundMilliseconds).toBe(expectedRoundMilliseconds[recordPosition])
				expect(roundStateChangedMessage.roundPhase).toBe(expectedPhases[recordPosition])
				expect(table.isfrozen(roundStateChangedMessage)).toBeTrue()
			end
			local lastMessage = harness.sentRoundStateChangedRecords[6].roundStateChangedMessage
			local roundState = harness.readCurrentRoundState()
			expect(lastMessage).toEqual({
				roundId = "round-2",
				roundPhase = "ThemeReveal",
				phaseEndsAtUnixMilliseconds = roundState.phaseEndsAtUnixMilliseconds,
				themeId = roundState.themeId,
				roundBonusRule = roundState.roundBonusRule,
				participantUserIds = {},
			})
		end)

		it("gives the current message on demand to a player who has just joined the server", function()
			local harness = createRefereeWithFakes()
			harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
			harness.advanceToRoundSecond(15)
			local roundState = harness.readCurrentRoundState()
			expect(harness.referee:readRoundStateChangedMessage()).toEqual({
				roundId = "round-1",
				roundPhase = "Styling",
				phaseEndsAtUnixMilliseconds = roundState.phaseEndsAtUnixMilliseconds,
				themeId = "y2k_pop",
				roundBonusRule = roundState.roundBonusRule,
				participantUserIds = { PLAYER_P },
			})
			expect(table.isfrozen(harness.referee:readRoundStateChangedMessage())).toBeTrue()
			harness.themedRoundClock:stopRoundCycle()
			expect(harness.referee:readRoundStateChangedMessage()).toBeNil()
		end)

		it("does not broadcast a mid-phase join; others learn of it at the next phase change", function()
			local harness = createRefereeWithFakes()
			harness.loadPlayers({ PLAYER_P })
			harness.advanceToRoundSecond(20)
			local broadcastCountBeforeJoin = #harness.sentRoundStateChangedRecords
			harness.referee:admitOrRejectJoinCurrentRoundRequest(PLAYER_P)
			expect(#harness.sentRoundStateChangedRecords).toBe(broadcastCountBeforeJoin)
		end)
	end
)

describe("ThemedRoundReferee failing senders never stop the round", function()
	it(
		"a RoundResultsPublished sender that raises is logged; the results are still kept and the next phase runs",
		function()
			local harness = createRefereeWithFakes()
			harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
			harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
			harness.shouldRoundResultsPublishedSenderRaise = true
			harness.advanceToRoundSecond(250)
			expect(#harness.sentRoundResultsPublishedRecords).toBe(1)
			expect(harness.referee:readLastPublishedRoundResults().roundResults[1].starCoinsGranted).toBe(80)
			expect(harness.orderedSentMessageLog[#harness.orderedSentMessageLog]).toEqual({
				sentMessageKind = "RoundStateChanged",
			})
			expect(#harness.recordingLogger.loggedWarnings).toBe(1)
			expect(
				string.find(
					harness.recordingLogger.loggedWarnings[1],
					"sendRoundResultsPublishedToEveryDevice",
					1,
					true
				) ~= nil
			).toBeTrue()
		end
	)

	it("a RoundStateChanged sender that raises is logged and every later phase is still refereed", function()
		local harness = createRefereeWithFakes()
		harness.loadAndJoinAtRoundSecond3({ PLAYER_P })
		harness.sendDraftAtRoundSecond(20, PLAYER_P, 1, OUTFIT_E83)
		harness.shouldRoundStateChangedSenderRaise = true
		harness.advanceToRoundSecond(251)
		expect(harness.countGrantCallsFor(PLAYER_P)).toBe(1)
		expect(#harness.recordingLogger.loggedWarnings).toBe(2)
		expect(
			string.find(harness.recordingLogger.loggedWarnings[1], "sendRoundStateChangedToEveryDevice", 1, true) ~= nil
		).toBeTrue()
	end)
end)
