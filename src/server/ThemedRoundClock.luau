-- ThemedRoundClock (development spec v1.3 §0.2, §1.4, §2.1): runs the themed-round cycle
-- ThemeReveal → Styling → Showcase → Results → Intermission → ThemeReveal … for as long as the
-- server runs, whether or not anyone takes part.
--
-- It owns the phases, their timing, the round id, the theme and the round bonus rule. It does NOT
-- own participants, drafts, scoring or rewards: those belong to ThemedRoundReferee, which reads
-- this clock and subscribes to its phase changes.
--
-- Calls no Roblox-specific interface. Everything external is injected (see `new`).
--
-- Rules it enforces:
--   * Phase durations come from ThemedRoundProtocol (shared with the device).
--   * Each phase end is planned from the previous PLANNED end, not from the moment the scheduler
--     happened to run the callback, so normal scheduler lateness never accumulates into drift.
--     Only when a callback runs so late that the next phase's planned end has already passed
--     (the server stalled for longer than that whole phase) is that phase re-planned to last its
--     full duration from now, and a warning is logged. A phase is never skipped.
--   * A new round id at each ThemeReveal.
--   * The theme is chosen at random among the catalog themes NOT used in the last
--     RECENT_THEME_EXCLUSION_COUNT rounds on this server.
--   * The round bonus kind is chosen at random (each kind equally likely), then its tag:
--     a StyleBonus picks only a style tag with weight 0 in the round's theme; a ColorBonus picks
--     only a non-neutral colour (§1.4 🔴). Every allowed tag is equally likely.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC API (the round referee and server wiring are written from this)
-- ════════════════════════════════════════════════════════════════════════════════════════════
--
-- ThemedRoundClock.new(dependencies) -> themedRoundClock
--   dependencies = {
--     themeCatalogThemes: { Theme },   normally ThemeCatalog.THEMES. Checked here; `new` raises
--         unless there are MORE than RECENT_THEME_EXCLUSION_COUNT themes (so the exclusion can
--         always be honoured), every themeId is a unique non-empty string, and every theme
--         leaves at least one style tag of StylingTagVocabulary.STYLE_TAGS unweighted (so a
--         StyleBonus is always possible).
--     clock: { getCurrentUnixMilliseconds: (self) -> number },
--     scheduler: { scheduleCallbackAfterSeconds: (self, delaySeconds, callback) -> cancelCallback },
--     randomNumberGenerator: { nextWholeNumberInRange: (smallestWholeNumber, largestWholeNumber) -> number },
--         Called with a dot (no self). Returns a whole number in the inclusive range. The clock
--         uses no other source of randomness.
--     generateUniqueRoundId: () -> string,   a new unique non-empty id per call (one per round)
--     logger: { logInformation: (self, message: string) -> (), logWarning: (self, message: string) -> () },
--         Each round start is logged once with logInformation (round id, theme id, bonus).
--   }
--
-- themedRoundClock:startRoundCycle()
--   Starts round 1 at once: its ThemeReveal begins now and the phase-change listeners are called
--   before this returns. Subscribe BEFORE starting to see that first ThemeReveal. Raises if the
--   clock was already started or was ever stopped: a clock is never restarted.
-- themedRoundClock:stopRoundCycle()
--   For server shutdown and tests. Cancels the pending phase change; no phase change and no
--   listener call happens afterwards. Stopping is for good: calling it again does nothing more,
--   and a stop that comes before the start (shutdown racing start-up) makes the start raise.
--   May be called from inside a listener: the listeners of the change in progress still all
--   run, and nothing follows.
-- A phase change that FAILS (an injected dependency misbehaves: generateUniqueRoundId returns no
--   non-empty string, randomNumberGenerator returns a number outside the asked range, or the
--   scheduler raises) is a wiring bug and stops the cycle for good. The clock logs a warning
--   saying the round cycle has stopped and why, and is left exactly as after stopRoundCycle
--   (not running, no current state, nothing pending). No listener is called for the failed
--   phase. In startRoundCycle (round 1's ThemeReveal) the error is then raised to the caller, so
--   a broken wiring fails loudly at server start; in a later, scheduled phase change it is not
--   raised (it is already logged, and there is no caller to receive it).
-- themedRoundClock:isRoundCycleRunning() -> boolean
--   True from startRoundCycle until stopRoundCycle or a failed phase change.
-- themedRoundClock:readCurrentRoundState() -> RoundState?
--   The current state while running; nil before starting and after stopping (or a failed phase
--   change). The returned
--   table is deeply frozen and is replaced (never changed) at each phase change.
--
-- RoundState = {   everything of RoundStateChanged (§2.1) except participantUserIds, which the
--                  referee adds
--   roundId: string,
--   roundPhase: "ThemeReveal" | "Styling" | "Showcase" | "Results" | "Intermission",
--   phaseEndsAtUnixMilliseconds: number,   whole milliseconds; the moment this phase ends and
--                                          the next begins
--   themeId: string,
--   roundBonusRule: { roundBonusKind = "ColorBonus", bonusColorTag = <non-neutral colour> }
--                 | { roundBonusKind = "StyleBonus", bonusStyleTag = <style tag of weight 0> },
-- }
-- roundId, themeId and roundBonusRule are chosen at ThemeReveal and stay the same (the same
-- frozen roundBonusRule table) through all five phases of that round.
--
-- themedRoundClock:subscribeToRoundPhaseChanged(listener(roundState)) -> unsubscribe
--   Called on every phase change, including the first ThemeReveal, with the NEW state (the same
--   frozen table readCurrentRoundState now returns). Listeners run synchronously, in
--   subscription order, inside the phase change itself: the end of Styling and the start of
--   Showcase are one step, and no other scheduled work runs between the moment a phase ends and
--   the return of the last listener. The current time equals the planned phase boundary unless
--   the scheduler ran late. This is where the referee does the Styling cut-off (at
--   roundPhase == "Showcase") and publishes results (at roundPhase == "Results").
--   A listener that raises is logged as a warning and never stops the clock or other listeners.
--   Subscribing or unsubscribing from inside a listener takes effect from the next change.
--
-- ThemedRoundClock.chooseRoundBonusRuleForTheme(theme, randomNumberGenerator) -> RoundBonusRule
--   The round bonus choice on its own (frozen result), exposed so the §1.4 constraints can be
--   tested for every theme directly.
-- ThemedRoundClock.RECENT_THEME_EXCLUSION_COUNT = 5   (§2.1, server only)
-- ════════════════════════════════════════════════════════════════════════════════════════════

local OutfitScoreCalculator = require("../shared/OutfitScoreCalculator")
local StylingTagVocabulary = require("../shared/StylingTagVocabulary")
local ThemeCatalog = require("../shared/ThemeCatalog")
local ThemedRoundProtocol = require("../shared/ThemedRoundProtocol")

type Theme = ThemeCatalog.Theme
type RoundBonusRule = OutfitScoreCalculator.RoundBonusRule

export type RoundState = {
	roundId: string,
	roundPhase: string,
	phaseEndsAtUnixMilliseconds: number,
	themeId: string,
	roundBonusRule: RoundBonusRule,
}

type RandomNumberGenerator = {
	nextWholeNumberInRange: (smallestWholeNumber: number, largestWholeNumber: number) -> number,
}

local ThemedRoundClock = {}
ThemedRoundClock.__index = ThemedRoundClock

ThemedRoundClock.RECENT_THEME_EXCLUSION_COUNT = 5

local MILLISECONDS_PER_SECOND = 1000
local ROUND_PHASES = ThemedRoundProtocol.ROUND_PHASES
local ROUND_BONUS_KINDS = OutfitScoreCalculator.ROUND_BONUS_KINDS
local ROUND_BONUS_KIND_CHOICES = table.freeze({ ROUND_BONUS_KINDS.ColorBonus, ROUND_BONUS_KINDS.StyleBonus })

local NON_NEUTRAL_COLOR_TAGS: { string } = {}
for _, colorTag in StylingTagVocabulary.COLOR_TAGS do
	if not StylingTagVocabulary.isNeutralColorTag(colorTag) then
		table.insert(NON_NEUTRAL_COLOR_TAGS, colorTag)
	end
end
table.freeze(NON_NEUTRAL_COLOR_TAGS)

local function listStyleTagsWithoutWeightInTheme(theme: Theme): { string }
	local unweightedStyleTags = {}
	for _, styleTag in StylingTagVocabulary.STYLE_TAGS do
		if ThemeCatalog.getStyleTagWeightForTheme(theme, styleTag) == 0 then
			table.insert(unweightedStyleTags, styleTag)
		end
	end
	return unweightedStyleTags
end

local function pickRandomListElement<ListElement>(
	randomNumberGenerator: RandomNumberGenerator,
	candidateList: { ListElement }
): ListElement
	local pickedPosition = randomNumberGenerator.nextWholeNumberInRange(1, #candidateList)
	local pickedElement = candidateList[pickedPosition]
	if pickedElement == nil then
		error(
			string.format(
				"ThemedRoundClock: randomNumberGenerator returned %s, outside 1..%d",
				tostring(pickedPosition),
				#candidateList
			),
			2
		)
	end
	return pickedElement
end

function ThemedRoundClock.chooseRoundBonusRuleForTheme(
	theme: Theme,
	randomNumberGenerator: RandomNumberGenerator
): RoundBonusRule
	local roundBonusKind = pickRandomListElement(randomNumberGenerator, ROUND_BONUS_KIND_CHOICES)
	if roundBonusKind == ROUND_BONUS_KINDS.ColorBonus then
		return table.freeze({
			roundBonusKind = roundBonusKind,
			bonusColorTag = pickRandomListElement(randomNumberGenerator, NON_NEUTRAL_COLOR_TAGS),
		})
	end
	local unweightedStyleTags = listStyleTagsWithoutWeightInTheme(theme)
	if #unweightedStyleTags == 0 then
		-- `new` refuses such a catalog, so this is only reachable by calling this function directly.
		error(string.format("ThemedRoundClock: theme %s weights every style tag", tostring(theme.themeId)), 2)
	end
	return table.freeze({
		roundBonusKind = roundBonusKind,
		bonusStyleTag = pickRandomListElement(randomNumberGenerator, unweightedStyleTags),
	})
end

local function assertThemeCatalogCanBeUsed(themeCatalogThemes: any)
	if type(themeCatalogThemes) ~= "table" then
		error("ThemedRoundClock.new: themeCatalogThemes must be a list of themes", 3)
	end
	local themeCount = #themeCatalogThemes
	if themeCount <= ThemedRoundClock.RECENT_THEME_EXCLUSION_COUNT then
		error(
			string.format(
				"ThemedRoundClock.new: themeCatalogThemes has %d themes; more than %d are needed so no theme "
					.. "repeats within the last %d rounds",
				themeCount,
				ThemedRoundClock.RECENT_THEME_EXCLUSION_COUNT,
				ThemedRoundClock.RECENT_THEME_EXCLUSION_COUNT
			),
			3
		)
	end
	local seenThemeIdSet = {}
	for _, theme in themeCatalogThemes do
		local themeId = theme.themeId
		if type(themeId) ~= "string" or themeId == "" or seenThemeIdSet[themeId] then
			error(string.format("ThemedRoundClock.new: themeId %s is missing or not unique", tostring(themeId)), 3)
		end
		seenThemeIdSet[themeId] = true
		if #listStyleTagsWithoutWeightInTheme(theme) == 0 then
			error(
				string.format(
					"ThemedRoundClock.new: theme %s weights every style tag; no StyleBonus is possible",
					themeId
				),
				3
			)
		end
	end
end

function ThemedRoundClock.new(dependencies)
	for _, requiredDependencyName in
		{ "themeCatalogThemes", "clock", "scheduler", "randomNumberGenerator", "generateUniqueRoundId", "logger" }
	do
		if dependencies[requiredDependencyName] == nil then
			error("ThemedRoundClock.new: missing dependency " .. requiredDependencyName, 2)
		end
	end
	assertThemeCatalogCanBeUsed(dependencies.themeCatalogThemes)
	return setmetatable({
		themeCatalogThemes = table.clone(dependencies.themeCatalogThemes),
		clock = dependencies.clock,
		scheduler = dependencies.scheduler,
		randomNumberGenerator = dependencies.randomNumberGenerator,
		generateUniqueRoundId = dependencies.generateUniqueRoundId,
		logger = dependencies.logger,

		hasStarted = false,
		isRunning = false,
		currentRoundState = nil :: RoundState?,
		-- Most recent last; at most RECENT_THEME_EXCLUSION_COUNT entries.
		recentlyUsedThemeIds = {} :: { string },
		cancelPendingPhaseChange = nil :: (() -> ())?,
		-- Bumped by every scheduled change and by stop, so a callback that escaped cancellation
		-- can tell it is stale and do nothing.
		phaseChangeGeneration = 0,
		phaseChangeSubscriptions = {} :: { { listener: (RoundState) -> () } },
	}, ThemedRoundClock)
end

local function readCurrentWholeUnixMilliseconds(self): number
	return math.round(self.clock:getCurrentUnixMilliseconds())
end

local function chooseThemeExcludingRecentThemes(self): Theme
	local eligibleThemes = {}
	for _, theme in self.themeCatalogThemes do
		if table.find(self.recentlyUsedThemeIds, theme.themeId) == nil then
			table.insert(eligibleThemes, theme)
		end
	end
	local chosenTheme = pickRandomListElement(self.randomNumberGenerator, eligibleThemes)
	table.insert(self.recentlyUsedThemeIds, chosenTheme.themeId)
	if #self.recentlyUsedThemeIds > ThemedRoundClock.RECENT_THEME_EXCLUSION_COUNT then
		table.remove(self.recentlyUsedThemeIds, 1)
	end
	return chosenTheme
end

local function generateRoundIdForNewRound(self): string
	local roundId = self.generateUniqueRoundId()
	if type(roundId) ~= "string" or roundId == "" then
		error("ThemedRoundClock: generateUniqueRoundId must return a non-empty string, got " .. tostring(roundId), 2)
	end
	return roundId
end

local function buildRoundStateForPhase(
	self,
	roundPhase: string,
	phaseEndsAtUnixMilliseconds: number,
	previousRoundState: RoundState?
): RoundState
	if roundPhase == ROUND_PHASES.ThemeReveal or previousRoundState == nil then
		local roundId = generateRoundIdForNewRound(self)
		local chosenTheme = chooseThemeExcludingRecentThemes(self)
		local roundBonusRule = ThemedRoundClock.chooseRoundBonusRuleForTheme(chosenTheme, self.randomNumberGenerator)
		self.logger:logInformation(
			string.format(
				"ThemedRoundClock: round %s starts with theme %s and bonus %s %s",
				roundId,
				chosenTheme.themeId,
				roundBonusRule.roundBonusKind,
				tostring(roundBonusRule.bonusColorTag or roundBonusRule.bonusStyleTag)
			)
		)
		return table.freeze({
			roundId = roundId,
			roundPhase = roundPhase,
			phaseEndsAtUnixMilliseconds = phaseEndsAtUnixMilliseconds,
			themeId = chosenTheme.themeId,
			roundBonusRule = roundBonusRule,
		})
	end
	return table.freeze({
		roundId = previousRoundState.roundId,
		roundPhase = roundPhase,
		phaseEndsAtUnixMilliseconds = phaseEndsAtUnixMilliseconds,
		themeId = previousRoundState.themeId,
		roundBonusRule = previousRoundState.roundBonusRule,
	})
end

local function notifyPhaseChangeListeners(self, roundState: RoundState)
	for _, subscription in table.clone(self.phaseChangeSubscriptions) do
		local didListenerSucceed, listenerError = pcall(subscription.listener, roundState)
		if not didListenerSucceed then
			self.logger:logWarning(
				string.format(
					"ThemedRoundClock: a phase-change listener failed at %s of round %s: %s",
					roundState.roundPhase,
					roundState.roundId,
					tostring(listenerError)
				)
			)
		end
	end
end

-- Forward declaration: entering a phase schedules the next one.
local enterRoundPhase: (
	self: any,
	roundPhase: string,
	plannedPhaseStartUnixMilliseconds: number,
	shouldRaiseWhenEnteringFails: boolean
) -> ()

local function scheduleNextPhaseChange(self, roundState: RoundState)
	self.phaseChangeGeneration += 1
	local scheduledPhaseChangeGeneration = self.phaseChangeGeneration
	local delayMilliseconds =
		math.max(0, roundState.phaseEndsAtUnixMilliseconds - readCurrentWholeUnixMilliseconds(self))
	self.cancelPendingPhaseChange = self.scheduler:scheduleCallbackAfterSeconds(
		delayMilliseconds / MILLISECONDS_PER_SECOND,
		function()
			if not self.isRunning or self.phaseChangeGeneration ~= scheduledPhaseChangeGeneration then
				return
			end
			self.cancelPendingPhaseChange = nil
			-- Not re-raised here: the failure is already logged and the clock already stopped, and
			-- raising into the scheduler would only add a second, context-free error report.
			enterRoundPhase(
				self,
				ThemedRoundProtocol.getRoundPhaseFollowing(roundState.roundPhase),
				roundState.phaseEndsAtUnixMilliseconds,
				false
			)
		end
	)
end

-- Builds the new phase's state, makes it current and schedules its end. Raises when an injected
-- dependency misbehaves (bad round id, out-of-range random number, scheduler error).
local function prepareRoundPhaseAndScheduleItsEnd(
	self,
	roundPhase: string,
	plannedPhaseStartUnixMilliseconds: number
): RoundState
	local phaseDurationMilliseconds = ThemedRoundProtocol.PHASE_DURATION_SECONDS_BY_ROUND_PHASE[roundPhase]
		* MILLISECONDS_PER_SECOND
	local phaseEndsAtUnixMilliseconds = plannedPhaseStartUnixMilliseconds + phaseDurationMilliseconds
	local currentUnixMilliseconds = readCurrentWholeUnixMilliseconds(self)
	if currentUnixMilliseconds >= phaseEndsAtUnixMilliseconds then
		self.logger:logWarning(
			string.format(
				"ThemedRoundClock: phase change ran %d ms late, past the planned end of %s; re-planning %s "
					.. "to last its full duration from now",
				currentUnixMilliseconds - plannedPhaseStartUnixMilliseconds,
				roundPhase,
				roundPhase
			)
		)
		phaseEndsAtUnixMilliseconds = currentUnixMilliseconds + phaseDurationMilliseconds
	end

	local roundState = buildRoundStateForPhase(self, roundPhase, phaseEndsAtUnixMilliseconds, self.currentRoundState)
	self.currentRoundState = roundState
	-- Scheduled before the listeners run, so a listener that stops the clock cancels it.
	scheduleNextPhaseChange(self, roundState)
	return roundState
end

-- A failure to enter a phase is a wiring bug: the cycle is not recovered. The clock is left
-- exactly as after stopRoundCycle (so it never reports a round that is no longer running), the
-- failure is logged, and listeners are not called for the phase that failed.
function enterRoundPhase(
	self,
	roundPhase: string,
	plannedPhaseStartUnixMilliseconds: number,
	shouldRaiseWhenEnteringFails: boolean
)
	local didPrepare, preparedRoundStateOrError =
		pcall(prepareRoundPhaseAndScheduleItsEnd, self, roundPhase, plannedPhaseStartUnixMilliseconds)
	if not didPrepare then
		local failureMessage = string.format(
			"ThemedRoundClock: the round cycle has stopped because entering %s failed: %s",
			roundPhase,
			tostring(preparedRoundStateOrError)
		)
		self.logger:logWarning(failureMessage)
		self:stopRoundCycle()
		if shouldRaiseWhenEnteringFails then
			error(failureMessage, 0)
		end
		return
	end
	notifyPhaseChangeListeners(self, preparedRoundStateOrError)
end

function ThemedRoundClock:startRoundCycle()
	if self.hasStarted then
		error("ThemedRoundClock: the round cycle was already started or stopped; a clock is never restarted", 2)
	end
	self.hasStarted = true
	self.isRunning = true
	enterRoundPhase(self, ROUND_PHASES.ThemeReveal, readCurrentWholeUnixMilliseconds(self), true)
end

function ThemedRoundClock:stopRoundCycle()
	-- Also when not started yet, so a start that comes after a shutdown stop is refused.
	self.hasStarted = true
	self.isRunning = false
	self.currentRoundState = nil
	self.phaseChangeGeneration += 1
	local cancelPendingPhaseChange = self.cancelPendingPhaseChange
	self.cancelPendingPhaseChange = nil
	if cancelPendingPhaseChange then
		cancelPendingPhaseChange()
	end
end

function ThemedRoundClock:isRoundCycleRunning(): boolean
	return self.isRunning
end

function ThemedRoundClock:readCurrentRoundState(): RoundState?
	return self.currentRoundState
end

function ThemedRoundClock:subscribeToRoundPhaseChanged(listener: (RoundState) -> ()): () -> ()
	if type(listener) ~= "function" then
		error("ThemedRoundClock: listener must be a function", 2)
	end
	local subscription = { listener = listener }
	table.insert(self.phaseChangeSubscriptions, subscription)
	return function()
		local subscriptionIndex = table.find(self.phaseChangeSubscriptions, subscription)
		if subscriptionIndex then
			table.remove(self.phaseChangeSubscriptions, subscriptionIndex)
		end
	end
end

return ThemedRoundClock
