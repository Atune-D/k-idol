-- A fake of the one RewardLedger method ThemedRoundReferee uses, grantThemedRoundReward, whose
-- answer a test scripts per player. Records every call. Used for the referee's outcome-isolation
-- scenario (referee audit PART 3 scenario 59), which the real ledger cannot produce on demand.
--
--   ScriptableFakeThemedRoundRewardLedger.new() -> fakeLedger
--   fakeLedger:scriptGrantOutcomeForPlayer(playerUserId, scriptedGrantOutcomeKind)
--     scriptedGrantOutcomeKind: "Granted" (default for unscripted players) |
--       "GrantedWithOtherAmounts" | "Declined" | "SaveDataNotLoaded" | "Raise" | "ReturnNothing" |
--       "ReturnNumber"
--   fakeLedger:grantThemedRoundReward(playerUserId, themedRoundCompletion) -> outcome
--     "Granted" pays the §1.6 tier for the requested starCount with isNewBestStarCountForTheme
--     true; "GrantedWithOtherAmounts" is "Granted" with 81 coins, 41 fans and the flag false (amounts
--     no tier pays, so a test proves the published entry comes from the ledger's answer and not
--     from the computed score); "Declined" and "SaveDataNotLoaded" carry that outcome kind but MISLEADING amounts
--     (999 coins, 999 fans, flag true), so a test proves the referee ignores them;
--     "Raise" raises; "ReturnNothing" returns nil; "ReturnNumber" returns 42 (not a table).
--   fakeLedger.grantCalls   list of { playerUserId, themedRoundCompletion } in call order
--   fakeLedger:countGrantCallsFor(playerUserId) -> number

local OutfitScoreCalculator = require("../../src/shared/OutfitScoreCalculator")

local ScriptableFakeThemedRoundRewardLedger = {}
ScriptableFakeThemedRoundRewardLedger.__index = ScriptableFakeThemedRoundRewardLedger

function ScriptableFakeThemedRoundRewardLedger.new()
	return setmetatable({
		scriptedGrantOutcomeKindByPlayerUserId = {} :: { [number]: string },
		grantCalls = {},
	}, ScriptableFakeThemedRoundRewardLedger)
end

function ScriptableFakeThemedRoundRewardLedger:scriptGrantOutcomeForPlayer(
	playerUserId: number,
	scriptedGrantOutcomeKind: string
)
	self.scriptedGrantOutcomeKindByPlayerUserId[playerUserId] = scriptedGrantOutcomeKind
end

local function findStarRewardTier(starCount: number)
	for _, starRewardTier in OutfitScoreCalculator.STAR_REWARD_TIERS do
		if starRewardTier.starCount == starCount then
			return starRewardTier
		end
	end
	error("ScriptableFakeThemedRoundRewardLedger: starCount must be 1..5, got " .. tostring(starCount))
end

function ScriptableFakeThemedRoundRewardLedger:grantThemedRoundReward(playerUserId: number, themedRoundCompletion)
	table.insert(self.grantCalls, { playerUserId = playerUserId, themedRoundCompletion = themedRoundCompletion })
	local scriptedGrantOutcomeKind = self.scriptedGrantOutcomeKindByPlayerUserId[playerUserId] or "Granted"
	if scriptedGrantOutcomeKind == "Raise" then
		error("ScriptableFakeThemedRoundRewardLedger: deliberate failure")
	end
	if scriptedGrantOutcomeKind == "ReturnNothing" then
		return nil
	end
	if scriptedGrantOutcomeKind == "ReturnNumber" then
		return 42 :: any
	end
	if scriptedGrantOutcomeKind == "GrantedWithOtherAmounts" then
		return {
			rewardLedgerOutcome = "Granted",
			starCoinsGranted = 81,
			fanCountGained = 41,
			isNewBestStarCountForTheme = false,
		}
	end
	if scriptedGrantOutcomeKind == "Granted" then
		local starRewardTier = findStarRewardTier(themedRoundCompletion.starCount)
		return {
			rewardLedgerOutcome = "Granted",
			starCoinsGranted = starRewardTier.starCoinsGranted,
			fanCountGained = starRewardTier.fanCountGained,
			isNewBestStarCountForTheme = true,
		}
	end
	-- Deliberately misleading amounts: the referee must publish 0, 0 and false for anything that
	-- is not "Granted", whatever else the answer carries.
	return {
		rewardLedgerOutcome = scriptedGrantOutcomeKind,
		declineReason = if scriptedGrantOutcomeKind == "Declined" then "ScriptedDecline" else nil,
		starCoinsGranted = 999,
		fanCountGained = 999,
		isNewBestStarCountForTheme = true,
	}
end

function ScriptableFakeThemedRoundRewardLedger:countGrantCallsFor(playerUserId: number): number
	local grantCallCount = 0
	for _, grantCall in self.grantCalls do
		if grantCall.playerUserId == playerUserId then
			grantCallCount += 1
		end
	end
	return grantCallCount
end

return ScriptableFakeThemedRoundRewardLedger
