-- Builds the WHOLE game server with ServerGameModuleAssembly exactly as ServerMain does, but on
-- fakes: FakeClock and FakeScheduler, the in-memory development storages, the Marketplace answers
-- captured in Studio for the seven development items (through the real converter), a random
-- generator that always takes the first option (so round 1 has the first theme of ThemeCatalog and
-- the first bonus kind), ids "id-1", "id-2", ..., recording device senders, a recording character
-- presenter and a rate limiter wrapper that counts every admitOrRefusePlayerRequest call.
-- Not a spec file.
--
-- harness = ServerGameAssemblyTestHarness.createStartedServer(options?)
--   options.characterAppearancePresenterless = true   build without a presenter
--   options.catalogs = { danceCatalog = ..., ... }      ServerGameModuleAssembly catalog overrides
--   harness.modules                 ServerGameModuleAssembly's modules
--   harness.fakeClock, harness.fakeScheduler, harness.logger (RecordingLogger)
--   harness.playerSaveDataStorage   the in-memory storage
--   harness.sentMessages            { { channel, playerUserId?, message } } in send order
--   harness.presentations           { { playerUserId, presentation } } in order
--   harness.removedPlayers          { { playerUserId, playerFacingMessage } }
--   harness.admitCallCountByPlayerAndChannel  { ["<id>/<channel>"]: number }
--   harness:joinPlayer(playerUserId)      lifecycle join, then lets the load finish
--   harness:advance(seconds)              runs due callbacks
--   harness:ask(channel, playerUserId, payload) -> answer (nil if not answered yet)
--   harness:sendDraft(playerUserId, message)
--   harness:listSent(channel, playerUserId?) -> { message }
--   harness:secondsUntilPhase(roundPhase) -> number   from now to the next start of that phase
--     (a phase that is running now is reached again one whole round later)
--   harness:advanceToPhase(roundPhase)   advances to exactly that moment

local FakeClock = require("../Support/FakeClock")
local FakeScheduler = require("../Support/FakeScheduler")
local RecordingLogger = require("../Support/RecordingLogger")
local CapturedAnswerMarketplaceItemLookups = require("../fixtures/CapturedAnswerMarketplaceItemLookups")
local InMemoryDevelopmentFanCountLeaderboardStorage =
	require("../../src/server/InMemoryDevelopmentFanCountLeaderboardStorage")
local InMemoryDevelopmentPlayerSaveDataStorage = require("../../src/server/InMemoryDevelopmentPlayerSaveDataStorage")
local ServerGameModuleAssembly = require("../../src/server/ServerGameModuleAssembly")
local ThemedRoundProtocol = require("../../src/shared/ThemedRoundProtocol")

local ServerGameAssemblyTestHarness = {}
ServerGameAssemblyTestHarness.__index = ServerGameAssemblyTestHarness

-- 2027-01-15 08:00:00 UTC, a whole second.
ServerGameAssemblyTestHarness.SERVER_START_UNIX_SECONDS = 1_800_000_000

local function createCountingRateLimiterWrapper(admitCallCountByPlayerAndChannel)
	return function(realLimiter)
		return setmetatable({
			admitOrRefusePlayerRequest = function(_, playerUserId, remoteChannelName)
				local countKey = string.format("%s/%s", tostring(playerUserId), tostring(remoteChannelName))
				admitCallCountByPlayerAndChannel[countKey] = (admitCallCountByPlayerAndChannel[countKey] or 0) + 1
				return realLimiter:admitOrRefusePlayerRequest(playerUserId, remoteChannelName)
			end,
		}, {
			__index = function(_, methodName)
				return function(_, ...)
					return realLimiter[methodName](realLimiter, ...)
				end
			end,
		})
	end
end

local function buildDeviceMessageSenders(harness)
	local function recordSent(channel: string, playerUserId: number?, message)
		table.insert(harness.sentMessages, { channel = channel, playerUserId = playerUserId, message = message })
	end
	return {
		sendRoundStateChangedToEveryDevice = function(message)
			recordSent("RoundStateChanged", nil, message)
		end,
		sendRoundStateChangedToPlayer = function(playerUserId, message)
			recordSent("RoundStateChanged", playerUserId, message)
		end,
		sendRoundOutfitDraftAcknowledgedToPlayer = function(playerUserId, acknowledgement)
			recordSent("RoundOutfitDraftAcknowledged", playerUserId, acknowledgement)
		end,
		sendRoundResultsPublishedToEveryDevice = function(message)
			recordSent("RoundResultsPublished", nil, message)
		end,
		sendPlayerSaveDataSnapshotToPlayer = function(playerUserId, message)
			recordSent("PlayerSaveDataSnapshotChanged", playerUserId, message)
		end,
		sendWardrobeCatalogChangedToEveryDevice = function(message)
			recordSent("WardrobeCatalogChanged", nil, message)
		end,
	}
end

function ServerGameAssemblyTestHarness.createStartedServer(options: { [string]: any }?)
	local chosenOptions = options or {}
	local fakeClock = FakeClock.new(ServerGameAssemblyTestHarness.SERVER_START_UNIX_SECONDS)
	local fakeScheduler = FakeScheduler.new(fakeClock)
	local harness = setmetatable({
		fakeClock = fakeClock,
		fakeScheduler = fakeScheduler,
		logger = RecordingLogger.new(),
		sentMessages = {},
		presentations = {},
		removedPlayers = {},
		admitCallCountByPlayerAndChannel = {},
		marketplaceItemLookups = CapturedAnswerMarketplaceItemLookups.new(),
	}, ServerGameAssemblyTestHarness)
	harness.playerSaveDataStorage = InMemoryDevelopmentPlayerSaveDataStorage.new({ scheduler = fakeScheduler })
	harness.fanCountLeaderboardStorage =
		InMemoryDevelopmentFanCountLeaderboardStorage.new({ scheduler = fakeScheduler })
	local nextUniqueIdNumber = 0
	local serverDependencies = {
		clock = fakeClock,
		scheduler = fakeScheduler,
		logger = harness.logger,
		playerSaveDataStorage = harness.playerSaveDataStorage,
		fanCountLeaderboardStorage = harness.fanCountLeaderboardStorage,
		marketplaceItemLookups = harness.marketplaceItemLookups,
		randomNumberGenerator = {
			nextWholeNumberInRange = function(smallestWholeNumber: number)
				return smallestWholeNumber
			end,
		},
		generateUniqueId = function()
			nextUniqueIdNumber += 1
			return "id-" .. tostring(nextUniqueIdNumber)
		end,
		removePlayerFromGameWithMessage = function(playerUserId, playerFacingMessage)
			table.insert(
				harness.removedPlayers,
				{ playerUserId = playerUserId, playerFacingMessage = playerFacingMessage }
			)
		end,
		lookUpPlayerDisplayNamesByUserId = function(playerUserIds)
			local displayNameByUserId = {}
			for _, playerUserId in playerUserIds do
				displayNameByUserId[playerUserId] = "Tester " .. tostring(playerUserId)
			end
			return displayNameByUserId
		end,
		readPlayerDisplayName = function(playerUserId)
			return "Tester " .. tostring(playerUserId)
		end,
		deviceMessageSenders = buildDeviceMessageSenders(harness),
		wrapPlayerRequestRateLimiter = createCountingRateLimiterWrapper(harness.admitCallCountByPlayerAndChannel),
		catalogs = chosenOptions.catalogs,
	}
	if not chosenOptions.characterAppearancePresenterless then
		serverDependencies.characterAppearancePresenter = {
			presentCharacterAppearance = function(_, playerUserId, presentation)
				table.insert(harness.presentations, { playerUserId = playerUserId, presentation = presentation })
			end,
			forgotPlayerUserIds = {},
			forgetPlayer = function(presenter, playerUserId)
				table.insert(presenter.forgotPlayerUserIds, playerUserId)
			end,
		}
		harness.characterAppearancePresenter = serverDependencies.characterAppearancePresenter
	end
	harness.modules = ServerGameModuleAssembly.assembleServerGameModules(serverDependencies)
	ServerGameModuleAssembly.startServerGameModules(harness.modules, serverDependencies)
	fakeScheduler:advanceTimeAndRunDueCallbacks(0)
	return harness
end

function ServerGameAssemblyTestHarness:advance(elapsedSeconds: number)
	self.fakeScheduler:advanceTimeAndRunDueCallbacks(elapsedSeconds)
end

function ServerGameAssemblyTestHarness:joinPlayer(playerUserId: number)
	self.modules.playerServerLifecycleSequences:handlePlayerJoinedServer(playerUserId)
	self:advance(0)
end

function ServerGameAssemblyTestHarness:ask(remoteChannelName: string, playerUserId: number, untrustedPayload: any)
	local receivedAnswer = nil
	self.modules.deviceRequestChannelAnswerRouter:startAnsweringDeviceRequest(
		remoteChannelName,
		playerUserId,
		untrustedPayload,
		function(answer)
			receivedAnswer = answer
		end
	)
	return receivedAnswer
end

function ServerGameAssemblyTestHarness:sendDraft(playerUserId: number, draftMessage: any)
	self.modules.deviceRequestChannelAnswerRouter:receiveDeviceMessageWithoutAnswer(
		"SetRoundOutfitDraft",
		playerUserId,
		draftMessage
	)
end

function ServerGameAssemblyTestHarness:listSent(remoteChannelName: string, playerUserId: number?)
	local sentMessages = {}
	for _, sentRecord in self.sentMessages do
		if
			sentRecord.channel == remoteChannelName and (playerUserId == nil or sentRecord.playerUserId == playerUserId)
		then
			table.insert(sentMessages, sentRecord.message)
		end
	end
	return sentMessages
end

function ServerGameAssemblyTestHarness:readRoundState()
	return self.modules.themedRoundClock:readCurrentRoundState()
end

-- Seconds from now until the next moment `roundPhase` begins (0 if it begins now).
function ServerGameAssemblyTestHarness:secondsUntilPhase(roundPhase: string): number
	local roundState = self:readRoundState()
	local secondsUntil = (roundState.phaseEndsAtUnixMilliseconds - self.fakeClock:getCurrentUnixMilliseconds()) / 1000
	local followingPhase = ThemedRoundProtocol.getRoundPhaseFollowing(roundState.roundPhase)
	while followingPhase ~= roundPhase do
		secondsUntil += ThemedRoundProtocol.PHASE_DURATION_SECONDS_BY_ROUND_PHASE[followingPhase]
		followingPhase = ThemedRoundProtocol.getRoundPhaseFollowing(followingPhase)
	end
	return secondsUntil
end

function ServerGameAssemblyTestHarness:advanceToPhase(roundPhase: string)
	self:advance(self:secondsUntilPhase(roundPhase))
end

return ServerGameAssemblyTestHarness
