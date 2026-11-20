-- The device's round logic (ThemedRoundDeviceSession, WardrobeCatalogSnapshotRequester,
-- PlayerSaveDataStatusBarModel) driven against the WHOLE game server assembled on fakes
-- (ServerGameAssemblyTestHarness), on one shared fake clock. Server messages reach the device as the
-- server sends them (pumped every 50 ms of fake time). Covers two full rounds in a row: joining,
-- drafts and their acknowledgements, the lock, the scored outfit equal to the last saved selection,
-- results, the balance rising only with the snapshot, and numbering restarting at 1 in round two.

local UnitTestFramework = require("../Support/UnitTestFramework")
local DeviceTestFixtures = require("./DeviceTestFixtures")
local ServerGameAssemblyTestHarness = require("../server/ServerGameAssemblyTestHarness")
local PlayerSaveDataStatusBarModel = require("../../src/client/PlayerSaveDataStatusBarModel")
local ThemedRoundDeviceSession = require("../../src/client/ThemedRoundDeviceSession")
local WardrobeCatalogSnapshotRequester = require("../../src/client/WardrobeCatalogSnapshotRequester")

local describe, it, expect = UnitTestFramework.describe, UnitTestFramework.it, UnitTestFramework.expect

local F = DeviceTestFixtures
local LOCAL_USER_ID = 101

local function connectDeviceToServer()
	local harness = ServerGameAssemblyTestHarness.createStartedServer()
	local device =
		{ harness = harness, sentDrafts = {}, deliveredCount = 0, statusBar = PlayerSaveDataStatusBarModel.new() }
	device.session = ThemedRoundDeviceSession.new({
		localPlayerUserId = LOCAL_USER_ID,
		clock = harness.fakeClock,
		scheduler = harness.fakeScheduler,
		stylingItemByStylingItemKey = F.STYLING_ITEM_BY_STYLING_ITEM_KEY,
		sendOutfitDraftToServer = function(message)
			table.insert(device.sentDrafts, message)
			harness:sendDraft(LOCAL_USER_ID, message)
		end,
		requestJoinCurrentRound = function(onAnswer)
			onAnswer(harness:ask("RequestJoinCurrentRound", LOCAL_USER_ID, nil))
		end,
	})
	device.catalogRequester = WardrobeCatalogSnapshotRequester.new({
		clock = harness.fakeClock,
		scheduler = harness.fakeScheduler,
		stylingItemByStylingItemKey = F.STYLING_ITEM_BY_STYLING_ITEM_KEY,
		requestWardrobeCatalogSnapshot = function(onAnswer)
			onAnswer(harness:ask("RequestWardrobeCatalogSnapshot", LOCAL_USER_ID, nil))
		end,
		onWardrobeCatalogViewReady = function(view)
			device.session:applyWardrobeCatalogView(view)
		end,
	})
	function device.pump()
		while device.deliveredCount < #harness.sentMessages do
			device.deliveredCount += 1
			local sent = harness.sentMessages[device.deliveredCount]
			if sent.playerUserId == nil or sent.playerUserId == LOCAL_USER_ID then
				local channel, message = sent.channel, sent.message
				if channel == "RoundStateChanged" then
					device.session:receiveRoundStateChanged(message)
				elseif channel == "RoundOutfitDraftAcknowledged" then
					device.session:receiveRoundOutfitDraftAcknowledged(message)
				elseif channel == "RoundResultsPublished" then
					device.session:receiveRoundResultsPublished(message)
				elseif channel == "PlayerSaveDataSnapshotChanged" then
					device.statusBar:receivePlayerSaveDataSnapshot(message)
				elseif channel == "WardrobeCatalogChanged" then
					device.catalogRequester:receiveWardrobeCatalogChanged(message)
				end
			end
		end
	end
	function device.run(seconds)
		local steps = math.round(seconds / 0.05)
		for _ = 1, steps do
			harness:advance(0.05)
			device.pump()
		end
	end
	function device.runUntilPhase(roundPhase)
		device.run(harness:secondsUntilPhase(roundPhase) + 0.05)
	end
	function device.acknowledgementsSent()
		return harness:listSent("RoundOutfitDraftAcknowledged", LOCAL_USER_ID)
	end
	harness:joinPlayer(LOCAL_USER_ID)
	device.catalogRequester:start()
	device.pump()
	return device
end

local function findPresentedOutfit(harness, roundId)
	local roundResultEntry = nil
	for _, message in harness:listSent("RoundResultsPublished") do
		if message.roundId == roundId then
			roundResultEntry = message.roundResults[1]
		end
	end
	return roundResultEntry
end

describe("device session against the assembled server", function()
	it("plays two rounds: saved only after acknowledgement, scored outfit = last saved selection, no leaks", function()
		local device = connectDeviceToServer()
		device.run(5)
		local session = device.session
		expect(session:readSessionSnapshot().wardrobeCatalogView.isWardrobeCatalogReady).toBeTrue()
		expect(device.statusBar:readStatusBarModel().starCoinBalanceText).toBe("0")

		-- Round 1: join in ThemeReveal, style in Styling.
		expect(session:askToJoinCurrentRound()).toBeTrue()
		expect(session:readSessionSnapshot().isParticipant).toBeTrue()
		device.runUntilPhase("Styling")
		local roundOneId = session:readSessionSnapshot().roundState.roundId

		session:tapWardrobeItem(F.JACKET_TOP)
		expect(session:readSessionSnapshot().draftSavingStatus).toBe("Saving")
		device.run(0.3) -- the server processes and acknowledges
		expect(session:readSessionSnapshot().draftSavingStatus).toBe("Saved")
		session:tapWardrobeItem(F.HAIR)
		device.run(0.05)
		session:tapWardrobeItem(F.DRESS) -- replaces the top
		expect(session:readSessionSnapshot().selectedStylingItemKeys).toEqual({ F.HAIR, F.DRESS })
		expect(session:readSessionSnapshot().draftSavingStatus).toBe("Saving")
		device.run(1)
		expect(session:readSessionSnapshot().draftSavingStatus).toBe("Saved")
		local acknowledgements = device.acknowledgementsSent()
		local lastAcknowledgement = acknowledgements[#acknowledgements]
		expect(lastAcknowledgement.isKept).toBeTrue()
		expect(lastAcknowledgement.outfitDraftSequenceNumber).toBe(
			session:readSessionSnapshot().latestSentOutfitDraftSequenceNumber
		)
		-- The hair and the dress were tapped inside one send interval: one draft, number 2.
		expect(lastAcknowledgement.outfitDraftSequenceNumber).toBe(2)
		expect(device.sentDrafts[#device.sentDrafts].outfitStylingItemKeys).toEqual({ F.HAIR, F.DRESS })

		-- The lock: one second before the end the wardrobe refuses taps.
		local secondsLeft = session:readSessionSnapshot().remainingSecondsInPhase
		device.run(secondsLeft - 1.05)
		session:tapWardrobeItem(F.GLASSES)
		device.run(0.1)
		expect(session:isWardrobeUsableNow()).toBeFalse()
		expect(session:tapWardrobeItem(F.LIP_MAKEUP)).toBeNil()
		device.run(0.3)
		expect(session:readSessionSnapshot().draftSavingStatus).toBe("Saved")
		local savedSelection = session:readSessionSnapshot().selectedStylingItemKeys
		expect(savedSelection).toEqual({ F.HAIR, F.DRESS, F.GLASSES })

		-- Showcase: the server presents exactly the last saved selection.
		device.runUntilPhase("Showcase")
		local showcaseEntry = device.harness.modules.themedRoundReferee:readShowcaseStageEntry(LOCAL_USER_ID)
		expect(showcaseEntry.scoredOutfitStylingItemKeys).toEqual(savedSelection)

		-- Results: the snapshot raises the balance; the device shows exactly the server's numbers.
		device.runUntilPhase("Results")
		local resultEntry = findPresentedOutfit(device.harness, roundOneId)
		expect(session:readSessionSnapshot().roundResults.roundResults[1].outfitScore).toBe(resultEntry.outfitScore)
		expect(device.statusBar:readStatusBarModel().starCoinBalanceText).toBe(tostring(resultEntry.starCoinsGranted))
		expect(device.statusBar:readStatusBarModel().fanCountText).toBe(tostring(resultEntry.fanCountGained))

		-- Round 2: nothing of round 1 is left, and numbering starts again at 1.
		device.runUntilPhase("ThemeReveal")
		local roundTwoSnapshot = session:readSessionSnapshot()
		expect(roundTwoSnapshot.roundState.roundId == roundOneId).toBeFalse()
		expect(roundTwoSnapshot.isParticipant).toBeFalse()
		expect(roundTwoSnapshot.selectedStylingItemKeys).toEqual({})
		expect(roundTwoSnapshot.roundResults).toBeNil()
		device.runUntilPhase("Styling")
		expect(session:askToJoinCurrentRound()).toBeTrue()
		session:tapWardrobeItem(F.LIP_MAKEUP)
		device.run(0.3)
		local lastDraft = device.sentDrafts[#device.sentDrafts]
		expect(lastDraft.roundId).toBe(roundTwoSnapshot.roundState.roundId)
		expect(lastDraft.outfitDraftSequenceNumber).toBe(1)
		expect(session:readSessionSnapshot().draftSavingStatus).toBe("Saved")
	end)

	it("shows the server's refusal when joining too late in Styling", function()
		local device = connectDeviceToServer()
		device.run(5)
		device.runUntilPhase("Styling")
		device.run(121)
		expect(device.session:askToJoinCurrentRound()).toBeTrue()
		local snapshot = device.session:readSessionSnapshot()
		expect(snapshot.isParticipant).toBeFalse()
		expect(snapshot.joinRejection.rejectionReason).toBe("RoundNotJoinableNow")
	end)

	it("puts the selection back when the server rejects a forced invalid draft", function()
		local device = connectDeviceToServer()
		device.run(5)
		device.runUntilPhase("Styling")
		device.session:askToJoinCurrentRound()
		device.session:tapWardrobeItem(F.HAIR)
		device.run(1)
		-- A draft the interface cannot produce, sent with the next number as the device would.
		device.session.draftSender:submitCurrentOutfit({ F.HAIR, F.DRESS, F.JACKET_TOP })
		device.run(1)
		local snapshot = device.session:readSessionSnapshot()
		expect(snapshot.selectedStylingItemKeys).toEqual({ F.HAIR })
		expect(snapshot.draftSavingStatus).toBe("PutBackToLastSaved")
		expect(snapshot.outfitPutBackNotice.rejectionReason).toBe("OutfitInvalid")
	end)
end)
