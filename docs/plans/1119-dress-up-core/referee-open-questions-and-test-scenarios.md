ENGINEERING BRIEF SECTION: THEMED-ROUND REFEREE — SPEC AMBIGUITIES AND REQUIRED TESTS

Read-only work; no file was created or changed and no test was run. Every item below was checked against docs/plans/1119-dress-up-core/dress-up-core-development-spec.md (v1.3) and, where a reader cited code, against src/shared/OutfitValidator.luau, src/shared/OutfitScoreCalculator.luau, src/server/PlayerSaveDataKeeper.luau and tests/Support/FakeScheduler.luau. ThemedRoundReferee, ThemedRoundClock, RewardLedger and PlayerRequestRateLimiter do not exist yet.

Four reader disagreements were resolved (details in the items named):
- Re-sent acknowledgements: bounded to one per 0.25 s, not unlimited (Q3).
- Kept draft after a catalog change: scored exactly as kept, not reduced (Q10).
- Rejoining the same round: accepted with clean state, not refused; owner to confirm (Q11).
- Position of AlreadyParticipating in the rejection order: before the phase check (Q13).

Two reader test expectations were wrong and are corrected: a frozen table has no metatable, so a frozen well-formed payload or list is processed normally; and the "20 duplicates give 20 acknowledgements" test is replaced by the bounded one.

====================================================================
PART 1 — OPEN QUESTIONS (the spec does not decide; implement the default; list every one in the engineer's report)
====================================================================

1. §2.3 check 3 with check 2 — "a newer draft arriving meanwhile replaces it"
   Question: is "newer" by arrival order or by sequence number? Check 2 compares only with the highest PROCESSED number, so a number between the processed and the waiting one passes it. What about the same number as the waiting one with different content?
   Default: the one-place buffer is replaced only by a strictly higher sequence number. An arrival that passes check 2 but is lower than or equal to the waiting number is dropped: no acknowledgement, no state change. For an equal number, the first-arrived content stays. Invariant: the highest-numbered draft that arrived from a participant during Styling is always processed, by the timer or by the cut-off.
   Ask owner: No.

2. §2.3 checks 3 and 4 — invalid newer draft versus a valid waiting draft
   Question: is validity judged on arrival or at processing? Can an invalid seq 3 displace a valid waiting seq 2?
   Default: follow the table order. Buffer replacement looks only at the number; validity is judged once, at processing. In the corner case the result is one ack {3, false, "OutfitInvalid"}, the earlier kept draft stays, and the valid seq 2 is never processed. The device restores its preview to the last kept draft, so the player still sees what is judged. Validating on arrival would need rules the spec lacks and allow more than one validation per 0.25 s.
   Ask owner: No. Report as a spec gap (work lost in a rare corner).

3. §2.3 check 2 versus §2.13 — duplicates: what is re-sent, and how often
   Question: (a) what is sent when check 2 fails and nothing has been processed yet; (b) is the re-sent acknowledgement itself limited? Check 2 sits before check 3, so duplicates bypass the 0.25 s interval.
   Default: (a) nothing is sent. (b) Keep exactly one stored acknowledgement per participant per round (the one for the highest processed number) and re-send it unchanged, at most once per player per 0.25 s. Further duplicates in that window are dropped silently. A re-send never validates and never changes the kept draft, the highest processed number, the buffer or the processing interval.
   Readers disagreed (unlimited re-sends versus a bound). The bound is chosen because unlimited re-sends make the server's outbound work device-driven on the one channel §2.13 exempts from refusal. It cannot lose work: the honest device resends only after 1 s and is always answered. The bound is an addition to the spec; report it.
   Ask owner: No.

4. §2.3 payload line and check 2 — legal sequence numbers and malformed envelopes
   Question: what is done with a payload that is not the three-field table, or a sequence number that is a non-number, NaN, infinite, 0, negative, fractional or at least 2^53?
   Default: a legal sequence number has type number, is finite, equals its own floor, and lies in 1 .. 2^53−1. Anything else, and any payload that is not a table without a metatable, is handled like a check-1 failure: ignored, no acknowledgement, nothing stored, no raise, validator not called. Highest processed starts at 0.
   Read the envelope only after the type and metatable test, with rawget on the three named fields. Never echo, log, concatenate or use a device value as a table key. No per-request log line. A device that jumps to a huge legal number only locks itself out for that round.
   Ask owner: No.

5. §2.1 and §2.3 check 1 — what "roundId matches" means for an untrusted value
   Default: roundId is a server-generated primitive. A match needs the same primitive type and rawequal with the current id; no tostring/tonumber coercion, no lookup keyed by the received value. Draft state exists for the current round only, so a past or future id fails check 1. The acknowledgement carries the server's own roundId, never the received one.
   Ask owner: No.

6. §2.3 payload and §3.3 — extra fields (outfitScore, starCount, starCoinsGranted, playerUserId, themeId)
   Default: never read, stored, copied or echoed, and they do not make the draft invalid. The sender is the identity supplied by the server side of the channel. The same holds for arguments sent with RequestJoinCurrentRound, which §2.2 defines without a payload: every argument is ignored and the answer is always a fresh table of exactly the §2 shape.
   Ask owner: No.

7. §2.3 check 1 and the Cut-off paragraph — the exact cut-off instant and leftover timers
   Question: for a draft handled in the same millisecond Styling ends, is the test the wall clock or the phase the server holds? What happens to a 0.25 s timer due after the cut-off?
   Default: the cut-off is one non-yielding step, run once per roundId: process each waiting draft, then stop accepting, then freeze and score. Check 1 asks whether that step has run, not what the clock reads. A draft handled before the step is an ordinary Styling draft and is scored; one handled after it is ignored even at the same millisecond. No acknowledgement with isKept = true may ever be sent after scoring has begun.
   Every waiting-draft timer is cancelled at the cut-off, on leaving and at round end. A callback that still fires checks roundId and state and does nothing. A second cut-off call for the same roundId does nothing. The phase-change wiring must run this step before anything reads the outfits (stage, results).
   Ask owner: No.

8. §2.3 check 3 — a newer draft arrives after the interval has passed but before the waiting draft's timer ran
   Default: the newer draft supersedes the waiting one; the timer is cancelled and the newer draft is processed at once. Two invariants: the highest processed number never decreases (the buffer is cleared whenever a higher number is processed), and no two processings for one player are closer than 0.25 s except the cut-off flush.
   Ask owner: No.

9. §2.3 — which content is kept: the device's table or a server copy
   Default: on arrival take a bounded shallow snapshot. If the value is a table without a metatable, copy at most 13 entries by raw iteration; otherwise store the raw value. Validate that snapshot at processing; a valid one is frozen and becomes the kept draft. What is validated is exactly what is kept and scored, and nothing the caller does to its table afterwards changes it. Note that OutfitValidator.validateOutfit returns only a verdict, not the cleaned list, so the referee needs its own copy.
   Ask owner: No.

10. §2.14 and §1.2 with §2.3 — the available-item set changes during Styling
    Question: is a waiting draft validated against the catalog at arrival or at processing? Is a kept draft re-validated at the cut-off?
    Default: check 4 uses the set current at the moment of processing. A kept draft is never re-validated, reduced or dropped; it is scored exactly as acknowledged.
    Readers disagreed: one wanted hidden keys dropped at the cut-off. That lowers a score the player was told was kept, so it is rejected. Scoring as kept is safe in code: calculateOutfitScore raises only for a key missing from the static pool, which a hidden item is not.
    Per §1.2 availability is fixed "once per server session", so this should not occur in Phases 1–2. What the showcase dresses when a kept item has since been hidden belongs to the dresser batch.
    Ask owner: No. Report.

11. §2.2 — "A participant who leaves the server is removed from the round and gets no reward for it": rejoining the same round
    Question: a participant leaves, reconnects, and asks to join the same roundId while the window is open. Accept or refuse, and what happens to the old state?
    Default: leaving erases everything the referee holds for that player in that round: participation, kept draft, waiting draft and timer, highest processed number, stored acknowledgement, any score. A later join that meets §2.2's written conditions is accepted as a brand-new participant, with highest processed 0 and an empty kept outfit. Nothing from before the departure is ever scored, acknowledged or paid.
    Readers disagreed (accept clean versus refuse for the rest of the round). Both readings lose no work, pay once and trust nothing. Accepting follows §2.2's acceptance sentence without inventing a rejection case.
    Ask owner: YES. Recommend accept-clean, because a dropped connection should not lock a player out for up to 250 s. Refusing with RoundNotJoinableNow is the alternative; it costs that lock-out and needs a per-round list of leavers.

12. §2.2 with §3.4 "Writing" — the save session ends before the player has left
    Question: the keeper loses the session lock at T=185 but the Roblox departure arrives at T=192. Is the player a participant in between?
    Default: treat the keeper's session-ended event (any reason) exactly like leaving the server: remove at once, cancel the waiting draft, never score, list or pay. The later "player left" notification must be tolerated without error.
    Ask owner: No.

13. §2.2 and §2.13 — precedence of join rejection reasons; where the 1 s limit lives
    Default order: TooManyRequests; then AlreadyParticipating if the sender is a participant of the current roundId, in any phase; then SaveDataNotLoaded, WardrobeCatalogNotReady, RoundNotJoinableNow in the order §2.2 lists them.
    Readers disagreed on where AlreadyParticipating goes. It is placed before the phase check so a participant asking again late in Styling is never told RoundNotJoinableNow, which a device could read as "you are not in this round" and close the wardrobe.
    No rejected join changes any state. The limit belongs to PlayerRequestRateLimiter in front of the referee. A refused request does not restart the interval (§2.13 "changes nothing"). Referee tests space repeat joins more than 1 s apart.
    Ask owner: No.

14. §2.1 MAX_PLAYERS_PER_SERVER = 12 with §2.2 — is 12 a cap the referee enforces?
    Default: the spec has no participant cap and no rejection reason for a full round; add none. Required: twelve participants can join, be scored and be paid independently. A defensive bound, if added, must reuse RoundNotJoinableNow and be reported as a deviation.
    Ask owner: No.

15. §2.1 RoundStateChanged.participantUserIds — content, timing, carry-over
    Default: always the live set at the instant the message is built, in order of accepted joins. It is empty at each ThemeReveal start and never carried into the next round; each round needs its own accepted join. Send only at the moments §2.1 names (phase change, player joining the server). A mid-phase join is made known to the joiner by the request's answer; do not add a broadcast silently.
    Ask owner: No. Mention that other devices learn of a mid-Styling joiner only at Showcase start.

16. §2.3 Cut-off, §1.6, §2.5, §3.3 "Round reward" row — a participant with no kept draft or a kept empty list
    Question: what is scored, are they listed in roundResults, and does anything in the save change?
    Default: every participant starts with the empty outfit as kept draft; only a draft that passed all four checks this round replaces it. Never score the lobby outfit, the avatar or an invalid draft. They stay a participant.
    For an empty final outfit make no ledger call at all: no coins, fans, totalRoundsCompletedCount, bestStarCountByThemeId entry, quest progress or save request. Take the result from calculateOutfitScore on the empty list (it returns starCount 0, isOutfitEmpty true). Never call determineStarRewardForOutfitScore directly; it pays 1 star for score 0.
    The entry is present with all numbers 0 and isNewBestStarCountForTheme false.
    Ask owner: YES, two points. (a) Listed with zeros or left out: recommend listed, so the player sees what was judged. (b) Does an empty round count as a completed round or quest progress: recommend no, otherwise an idle scripted device earns progress every 280 s.

17. §2.2 and §2.5 — leaving between scoring (end of Styling) and reward (start of Results), and after the grant
    Default: a participant gone before the start of Results gets no ledger call and no roundResults entry. A reward granted at the start of Results is final: leaving afterwards changes nothing and there is no undo.
    Ask owner: No.

18. §2.5 and §3.3 — the grant is not applied
    Question: what does the entry show, and is the grant retried?
    Default: grant first, then build the message from what happened. SaveDataNotLoaded means the player is leaving or the session ended: treat as left, no entry. Declined or a raise: entry with the true score and stars but starCoinsGranted 0, fanCountGained 0, isNewBestStarCountForTheme false. Published amounts are never the computed ones unless the change was Applied.
    No retry of a round grant, ever. Each participant's grant is isolated: one failure never blocks the others or the publication.
    Ask owner: No.

19. §3.3 "A reward and its record are one change" with the "Round reward" row — what makes a round reward non-repeatable
    Question: the listed record (totalRoundsCompletedCount, bestStarCountByThemeId, quest progress) holds no roundId, so the save cannot refuse a second grant for the same round.
    Default: the referee keeps an in-memory settlement marker per (roundId, playerUserId), set before the ledger is called and never cleared whatever the outcome. The Results step runs at most once per roundId, and a roundId that is not current is never settled. No device request of any kind leads to a grant.
    The whole grant is one applyChangeToPlayerSaveData of kind ProgressChangeSavedAtOnce. The marker does not survive a crash, but a roundId exists on one server only, so a restarted server can never settle it again.
    Ask owner: No. Tell the RewardLedger author: the §6.2 ledger row asks that each §3.3 operation "cannot then be repeated", and for round rewards that guard lives in the referee.

20. §2.5 "Sorted by outfitScore, highest first" — ties
    Default: outfitScore descending, then order of accepted join, then playerUserId ascending. No device-supplied value takes part. Luau's table.sort is not stable, so the comparison must be total.
    Ask owner: No. Record the choice in the spec.

21. §2.5 — publication with no entries, and players who connect during Results
    Default: publish exactly once per round at the start of Results, to every connected device, with an empty list when there is nothing to show. No re-send to late arrivals. The published list is kept unchanged until the next ThemeReveal.
    Ask owner: No. Mention that a player connecting mid-Results sees no results.

22. §2.5 isNewBestStarCountForTheme with §1.10 — undefined term
    Default: true only when the new starCount is strictly greater than the stored value, a missing entry counting as 0. It is computed inside the same change that writes bestStarCountByThemeId and is false whenever the change was not Applied. The stored value never goes down.
    Ask owner: YES, low stakes. Recommend as above: the first rated round on a theme is a new best, an equal count is not.

23. §2.4 respawn table with §3.7 — states the table leaves open
    Default: the decision reads state at the moment of spawn, not of reset. Save not loaded: lobby appearance with an empty stored list, nothing applied, no error. Stage places are assigned once at Showcase start and never reassigned when someone leaves. A spawn never touches the kept draft, the sequence state or the score.
    A participant in Showcase whose scored outfit is empty stands on stage and dances in the lobby appearance. Applying §3.7 literally to an empty outfit would strip the character.
    Ask owner: YES for the empty-outfit case only. Recommend lobby appearance; never show a stripped avatar.

24. §3.4 "Server shuts down" with §2.5 — shutdown in the middle of a round
    Default: rewards exist at one moment only, the start of Results. A round that has not reached it when shutdown begins pays nothing. Once shutdown has begun the referee accepts no joins or drafts, scores nothing, calls the ledger for nobody and publishes nothing. The keeper's SaveDataNotLoaded answer is the backstop. Rewards already granted are written by the final save.
    Ask owner: YES. Recommend this default, since an early payout would add a second grant moment the spec does not define. The cost is that every shutdown, game updates included, forfeits up to 250 s of each player's current round.

25. §2.13 first sentence and §3.6 "The ceiling holds whatever devices send" — the referee's own work under a flood
    Default: per arriving draft, constant work before any allocation, then overwrite the single waiting place or drop. At most one pending timer per participant. At most one validation per participant per 0.25 s, plus one at the cut-off. Per-player state exists only for current participants and is removed on leaving and at round end. No per-request logging.
    Ask owner: No. Report as the interpretation used.

====================================================================
PART 2 — SPEC ANSWERS THAT ARE EASY TO MISS (readers marked these open; the text decides them)
====================================================================

a. When the outfit is scored. §2.3 Cut-off: "At the end of Styling the server first processes any draft still waiting in a buffer, then scores each participant's kept draft." The §0.2 diagram draws scoring after the dance, but the §0 heading says "plain language; the engineering contract starts at §1", and §2.4 speaks of "the scored outfit" during Showcase. Score once at the cut-off, freeze it, never recompute.

b. What the 0.25 s interval is measured from. §2.3 check 3: "has passed since this player's previous draft was processed". It is processing to processing, not arrival to arrival. The §2.13 row defers to this: "0.25, and coalesced rather than refused (§2.3)". The generic rate limiter must therefore not sit in front of SetRoundOutfitDraft. Drafts failing check 1 or 2 are not "processed", so they neither consume nor restart the interval. A player's first draft in a round is processed at once.

c. An invalid draft counts as processed. Check 3's "The waiting draft is processed as soon as the interval has passed" comes before check 4, and a check-4 failure is "Acknowledged with isKept = false". §6.2 adds "every processed draft is acknowledged". An invalid draft therefore becomes the highest processed number, restarts the interval, and its acknowledgement is the stored one. A valid resend under the same number is not processed.

d. Which acknowledgement is re-sent. Check 2: "the earlier acknowledgement for the highest processed draft is sent again". It is the highest processed one, not the one for the number the duplicate carried, and it is the stored copy.

e. A waiting draft that gets replaced is never acknowledged. Check 3 says it is replaced, so it was never processed; §6.2 ties acknowledgement to processing. §6.2's "both taken into account" is met by the plain case: seq 1 at once, seq 2 at 0.25 s.

f. "Never dropped for arriving early" means inside the 0.25 s interval only. The §10 v1.2 row defines the defect as two sends arriving closer together than the interval. A draft before Styling or before joining falls under check 1: "Ignored, no acknowledgement". It leaves no trace, and the device's 1 s resend delivers it later.

g. Sequence numbers may skip, and the first need not be 1. Check 2 requires only "higher than the highest this server has already processed". Check 3 itself creates gaps.

h. The cut-off flush ignores the interval and is acknowledged. The Cut-off sentence in (a), plus §6.2's "a waiting draft is processed at the end of Styling before scoring" and "every processed draft is acknowledged". An invalid flushed draft gets {n, false, "OutfitInvalid"} and the earlier kept draft is scored.

i. A resend arriving after the cut-off gets nothing. Cut-off: "Anything arriving later is ignored"; check 1 comes first in the table. No draft acknowledgement is ever sent outside Styling. Gap to report: the spec does not say how a device learns the fate of a final draft whose acknowledgement it missed.

j. A well-formed envelope with a missing or malformed outfit field is a check-4 failure, not an ignored request. Check 4: not "a valid outfit (§1.5)" gives isKept = false with "OutfitInvalid", the only reason §2.3 defines; the validator's detailed reason is never sent. Confirmed in code: validateOutfit accepts any value, never raises for it, rejects a table with a metatable, and stops after 13 entries.

k. A join with exactly 60 s left is accepted. §2.2: "while at least MINIMUM_STYLING_SECONDS_TO_JOIN = 60 seconds remain"; §6.2: "refused when less than 60 seconds remain". Measure at server arrival, in milliseconds, against the published phaseEndsAtUnixMilliseconds. The request has no payload, so no device time exists to trust.

l. Draft state is per round. §2.3: the number "starts at 1 for each player in each round"; check 2 says "for the player this round"; §2.1 says roundId is "new at each ThemeReveal". Nothing kept in one round can be scored or paid in another.

m. Empty outfits. §1.5: "An empty outfit is valid", so a draft of {} is acknowledged isKept = true. §1.6: "A participant whose final outfit is empty receives no stars and no reward."

n. Grant before publishing. §2.5: "Rewards are granted through the ledger (§3.3) at this moment", so entries can and must report what was actually applied. §3.3: the referee "never accepts a score, star count or reward amount from a device".

o. Respawn. §2.4: "A respawn never changes what was or will be scored."

====================================================================
PART 3 — REQUIRED TEST SCENARIOS (merged and de-duplicated)
====================================================================

Conventions for all scenarios
- Lune with FakeClock and FakeScheduler from tests/Support, time in whole milliseconds.
- T = seconds since the round's ThemeReveal began: ThemeReveal 0–10, Styling 10–190, Showcase 190–250, Results 250–270, Intermission 270–280, next ThemeReveal 280. R1 is the current roundId, R2 the next.
- P, Q, R, S have loaded saves and a ready catalog, and joined at T=3 unless stated.
- A, B, C, D are distinct valid fixture outfits with different known scores. X is invalid (top plus dress). E83 is the §1.6 worked example in a y2k_pop round with the pink ColorBonus: 83, 4 stars, 80 coins, 40 fans.
- ack{n, true} and ack{n, false} mean RoundOutfitDraftAcknowledged {R1, n, isKept, rejectionReason nil or "OutfitInvalid"} recorded by a fake sender. "Fresh" means sent when a draft is processed; "re-sent" means repeated under check 2.
- Fakes: a validator spy with a call count, a fake ledger with a call log and scriptable outcome, a fake keeper.
- Expected numbers come from OutfitScoreCalculator output; its component points are unrounded.
- Each test is first seen to fail by breaking the logic it covers (§6.2).

A. Joining (§2.2)
1. Window boundaries. Requests at T=0.000, 9.999, 129.999 and 130.000 are accepted. T=130.001 gives RoundNotJoinableNow. Non-participants at T=190.000, 250 and 270 get RoundNotJoinableNow. T=280.000 is accepted into R2.
2. Preconditions. Save not loaded at T=5 gives SaveDataNotLoaded; after it loads at T=20 a request at T=22 is accepted. Catalog not ready at T=5 gives WardrobeCatalogNotReady; ready at T=30, a request at T=32 is accepted. Both failing at T=5 gives SaveDataNotLoaded.
3. Join twice. P keeps E83 as seq 2 at T=40, then asks again at T=45, 150, 200 and 255. Each answer is AlreadyParticipating, never RoundNotJoinableNow. The kept draft and highest processed number are unchanged, P is in the list once, and seq 3 at T=46 is processed normally.
4. A rejected join creates no state. After each rejection in 1 and 2, a draft from that player gets no ack and the validator is not called.
5. Hostile join arguments. At T=265 send the join with argument R2's id, then NaN, then a table with a raising metatable, then a 100000-entry table. Nothing raises, each answer is a fresh table of exactly the §2 shape with RoundNotJoinableNow, and the player is not a participant when R2 starts.
6. Join flood. 100 requests from one player at the same instant, T=20: exactly one is accepted and the rest are refused. The player is in the set once and at T=250 has one entry and one grant.
7. Twelve participants join between T=1 and T=9. All are scored at T=190; each gets exactly one grant and one entry at T=250.
8. participantUserIds per phase. P joins at T=3, Q at T=60, R never, P leaves at T=200. The list reads [] at T=0, [P] at T=10, [P, Q] at T=61 and T=190, [Q] at T=201, 250 and 270, [] at T=280.
9. Participation does not carry over. P finishes R1. At T=280 the list is empty and a draft {R2, 1, A} from P gets no ack. After P joins R2, the same draft is acknowledged ack{R2, 1, true}.

B. Check 1 — participant, roundId, phase (§2.3)
10. Not a participant. Q never joined and sends {R1, 1, A} at T=20: no ack, validator not called, no state held for Q, no entry and no ledger call at T=250.
11. Draft before joining does not consume the number. Q sends seq 1 (A) at T=20.0 and is ignored, joins at T=20.5, and re-sends seq 1 at T=21.0: fresh ack{1, true} at T=21.0 and A is scored.
12. Wrong roundId. At T=20 P sends, in turn, the previous round's id, a never-issued future id, the current id in the wrong primitive type, NaN, and a table. Each: no raise, no ack, nothing stored. Then {R1, 1, B} at T=20.10 is processed at once, which shows the ignored drafts did not start the interval.
13. Before Styling. P sends seq 1 (A) at T=9.6: no ack, nothing held. The same seq 1 at T=10.6 gives ack{1, true}.
14. After Styling. P kept C. Drafts {R1, 9, D} at T=190.5, 249, 255 and 275 get no ack, and the published result is computed from C.

C. Check 2 — sequence numbers and re-sent acknowledgements
15. Simplest pass. Seq 1 (A) at T=20.00 gives exactly one ack {R1, 1, true, nil} at T=20.00, sent only to P. The cut-off scores A.
16. Duplicate with different content. Seq 1 (A) at T=20; seq 1 (B) at T=21. One re-sent ack identical to the first, validator called once in total, A scored.
17. Number going backwards. Seq 1 (A) at T=20, seq 2 (B) at T=21, seq 1 (C) at T=22. The re-sent ack is {2, true} and B stays kept.
18. Re-send after an invalid highest draft. Seq 5 (B) at T=20 gives {5, true}; seq 6 (X) at T=21 gives {6, false}. Seq 5 again at T=22 and seq 6 again at T=23, this time with a valid outfit, each get the re-sent {6, false, "OutfitInvalid"}. The validator is not called again. Seq 7 (C) at T=24 is kept.
19. Skips. The first draft is seq 7 (A) at T=20 and is kept. Seq 50 (B) at T=21 is kept. Seq 49 (C) at T=22 gets the re-sent {50, true}; B stays kept.
20. Nothing processed yet. P's first messages are seq 0, then seq −1: no raise, no ack, nothing stored. Then seq 1 is kept.
21. Hostile sequence numbers. P has kept seq 1 (A). At T=21 send one case each with outfit B: nil, "2", true, {}, a table with raising __lt/__le, NaN, +infinity, −infinity, 1.5, 2^53, 1e308. Each: no raise, no ack of any kind, kept stays A. Then seq 2 (B) at T=22 is kept, which shows the highest processed number was not poisoned.
22. Re-sends are bounded and disturb nothing. Seq 1 (A) is processed at T=20.00; 20 copies arrive between T=20.01 and T=20.20. Exactly one re-sent ack goes out, at T=20.01, and the validator has been called once in total. Seq 2 (B) at T=20.21 gets its fresh ack at T=20.25, not later. In a separate run a single resend at T=21.00 gets one re-sent ack.

D. Check 3 — interval, waiting place, timers
23. Two drafts 0.1 s apart (§6.2). Seq 1 (A) at T=20.00 is acked at once. Seq 2 (B) at T=20.10 gets nothing at 20.10 or 20.249, then exactly one ack{2, true} at T=20.250. The cut-off scores B.
24. Exact boundary. Seq 1 at T=20.000; seq 2 arriving at exactly T=20.250 is processed immediately. In a separate run seq 2 at T=20.249 gets no ack until T=20.250.
25. Interval runs from processing. Seq 1 at T=20.00; seq 2 at T=20.10 (processed at 20.25); seq 3 at T=20.40 gets no ack at 20.40 and ack{3, true} at T=20.50.
26. An invalid draft consumes the interval. Seq 1 (A) at T=20.00; seq 2 (X) at T=20.30 gets ack{2, false} at 20.30; seq 3 (B) at T=20.40 gets ack{3, true} at T=20.55.
27. Coalescing with one timer. Seq 1 at T=20.00, then seq 2 at 20.05, seq 3 at 20.10, seq 4 at 20.20. The scheduler holds exactly one pending callback for P throughout. At T=20.25 there is exactly one ack, for seq 4. Seq 2 and 3 are never acknowledged and the validator ran once for the batch. A later resend of seq 2 gets the re-sent {4, true}.
28. A lower number never displaces the waiting draft. Seq 4 at T=20.00; seq 6 (B) at 20.05; seq 5 (A) at 20.10. At T=20.25 exactly one ack{6, true}, none for 5, B kept.
29. Same number as the waiting draft. Seq 1 (A) at T=20.00; seq 2 (B) at 20.05; seq 2 again carrying C at 20.10. No ack at 20.10 (neither {2} nor a re-sent {1}). At T=20.25 exactly one ack{2, true}, B kept.
30. Waiting draft turns out invalid. Seq 1 (A) at T=20.00; seq 2 (X) at 20.10. Nothing at 20.10; ack{2, false} at 20.25; A stays kept.
31. Invalid draft displaces a valid waiting one (reported spec gap). Seq 1 (A) at T=20.00; seq 2 (B) at 20.05; seq 3 (X) at 20.10. At T=20.25 exactly one ack{3, false}, none for seq 2, A kept.
32. Overdue waiting draft meets a newer arrival. Seq 1 (A) at T=20.00; seq 2 (B) at 20.10, due 20.25. Move the FakeClock directly to 20.27 without running callbacks; seq 3 (C) arrives; then run due callbacks. The only ack after 20.00 is {3, true}; B never becomes kept; nothing more is sent up to T=21.
33. Players are independent. P seq 1 at T=20.00; Q seq 1 at 20.05, processed at 20.05. P seq 2 at 20.10 and Q seq 2 at 20.12 both wait. P's ack comes at 20.25 and Q's at 20.30. Neither buffer replaced the other's draft.

E. Check 4 and hostile payloads
34. Invalid draft. Kept seq 1 = A. At T=21 seq 2 = X gives ack{2, false, "OutfitInvalid"}; A is scored. Repeat with a hidden key, an unknown key, a duplicated key, four accessories, 13 keys. The ack never carries the validator's detailed reason.
35. Hostile outfit field in a well-formed envelope. One case each at T=21 with a fresh higher number: field absent, nil, 5, "asset_1", {1, 2}, a list with a hole, a 100000-entry list, a list holding one 1 MB string, a list with a metatable whose __index raises, a list containing itself, a map {a = "asset_1"}. Each: no raise, ack{n, false, "OutfitInvalid"}, earlier kept draft unchanged, and the referee does a bounded number of raw steps whatever the payload size.
36. Frozen tables are ordinary tables. A frozen well-formed payload holding a frozen valid list is processed and kept. The referee never writes into what it received.
37. Malformed envelope. One case each at T=21: no argument, nil, true, 42, "x", a function, {}, {roundId = R1} with no sequence number, a table with a raising metatable, a table containing itself. Each: no raise and no ack. The kept draft, waiting draft, highest number and processing time are unchanged; prove it by sending the normal next draft immediately and seeing it processed at once.
38. Forged result fields. P sends {R1, 1, E83, outfitScore = 100, starCount = 5, starCoinsGranted = 1e9, fanCountGained = 1e9, playerUserId = Q's id}. P's entry shows 83, 4, 80, 40; the ledger is called for P with 80 and 40; Q's entry and balance are unaffected.
39. Private copy. The test mutates the submitted list (a) between arrival at T=20.10 and processing at T=20.25, and (b) after the ack. In both cases what is validated, kept and scored is the content at arrival.
40. An empty draft is valid. Seq 1 (A) at T=20; seq 2 ({}) at T=21 gives ack{2, true}. The final outfit is empty.
41. Drafts never touch the save. 50 drafts from P (valid, invalid, duplicates): applyChangeToPlayerSaveData is never called, inMemoryChangeRevision is unchanged, and no save is requested before Results.
42. Exactly one fresh ack per processed draft. Over a scripted run of 20 drafts (valid, invalid, replaced while waiting, flushed at the cut-off), the fresh-ack numbers equal the processed numbers. Each ack carries the server's roundId, the number, isKept, and rejectionReason nil when kept.

F. Cut-off (§2.3)
43. Flush before scoring (§6.2). Seq 7 (B) at T=189.90 gives {7, true}; seq 8 (C) at T=189.95 waits, due 190.15. At the cut-off (T=190.00) ack{8, true} is sent before the score exists, and C is scored. Advancing to T=191 sends nothing and changes nothing.
44. Flush of an invalid waiting draft. As 43 with seq 8 = X: ack{8, false, "OutfitInvalid"}; B is scored.
45. Same instant as the end of Styling. With the clock at exactly T=190.000: (a) deliver seq 9 (D) before invoking the cut-off step: it is acknowledged {9, true} and scored. (b) In a separate run deliver it after the step: no ack, scored outfit unchanged. In neither run is there a kept ack for an outfit other than the scored one.
46. Late resend. Seq 8 (C) processed at T=189.20; a resend of seq 8 at T=190.10 gets no ack at all; the result is from C.
47. Cut-off delivered twice, or a stale timer firing after it. Flush and scoring happen once. The second call sends no ack and changes no score.
48. Scoring happens once. P is scored at T=190; the available-item set changes at T=220; the entry and grant at T=250 use the T=190 result.

G. Leaving, lock loss, rejoining, round isolation
49. Leaving during ThemeReveal. P joins at T=3 and leaves at T=6: not in the list at T=10; no score, ledger call or entry.
50. Leaving with a draft waiting. Seq 7 (B) processed at T=44.90; seq 8 (C) waits from T=44.95; P leaves at T=45.00. Advancing to T=46 sends no ack and raises nothing. P is not scored at T=190, and has no ledger call or entry at T=250.
51. Leaving between scoring and reward. P and Q both keep E83 and are scored at T=190; P leaves at T=220. At T=250 the ledger is called exactly once (Q, 80/40), there is exactly one entry, and P's save is untouched.
52. Leaving after the grant. P is granted 80/40 at T=250 and leaves at T=255. No further ledger call; the balance stays 430 and fans 1240; the published entry is unchanged.
53. Rejoin in the same round starts clean. P has seq 7 kept (B) by T=40, leaves at T=45, is loaded again and asks at T=95: accepted. Seq 1 (C) at T=96 gets a fresh ack{1, true}, not a re-sent {7}. The cut-off scores C and there is exactly one grant at T=250. Variant: the rejoined P sends nothing; the final outfit is empty, not B. If the owner chooses refusal instead, the request at T=95 answers RoundNotJoinableNow; in either case B is never scored or acknowledged after T=45.
54. Session lock lost mid-round. P keeps seq 4. At T=185 the keeper fires session-ended "SessionLockLost" while P is still connected. Seq 5 at T=186 gets no ack. P is not in the list or scored at T=190, and has no ledger call or entry at T=250. The "player left" notification at T=192 causes no error.
55. Across rounds. In R1 P reaches seq 40 with B kept. In R2's Styling: before P joins R2, {R2, 1, C} gets no ack. After P joins R2, {R1, 41, D} gets no ack and {R2, 1, C} gets ack{R2, 1, true}. Variant: P joins R2 and sends nothing; the final outfit is empty and nothing is paid for B again. A timer left from R1 does nothing when it fires in R2.

H. Scoring, results, rewards (§1.6, §2.5, §3.3)
56. Happy path against §1.10. P starts with balance 350, fans 1200, rounds 14, best {y2k_pop = 3} and keeps E83. At T=250 one applied change gives 430 / 1240 / 15 / {y2k_pop = 4}. inMemoryChangeRevision rises by exactly 1. The entry is {83, 4 stars, 80, 40, isNewBestStarCountForTheme true}.
57. isNewBestStarCountForTheme. Stored 4, earned 4: false, stays 4. Stored 5, earned 3: false, stays 5. No stored entry, earned 1: true, becomes 1.
58. Paid once per round. After the grants at T=250, deliver the "Results began" notification for R1 again at T=255 and call the settlement entry point directly. The ledger call count for P is still 1, the balance 430, rounds 15, and there is no second publication. Then 1000 drafts and 1000 joins during T=250–270 leave balances and results unchanged.
59. Ledger outcomes are isolated and reported truthfully. P1 to P4 are all scored. The fake ledger answers SaveDataNotLoaded for P1, Declined for P2, raises for P3, Applied for P4. P1 has no entry. P2 and P3 have entries with the true score and stars but 0 coins, 0 fans and flag false; their saves are unchanged. P4 is paid 80/40. The publication is sent exactly once. No ledger call is repeated up to T=280.
60. Empty final outfits. Three participants: one sends nothing, one sends only X (ack{1, false}), one keeps A then keeps {}. Each ends with final outfit {} and an entry of all zeros with flag false. No ledger call is made. Each save is identical to before: rounds count, best-star map and revision unchanged, no save requested.
61. Sorting. Scores 91, 61 and 83 are published in the order 91, 83, 61.
62. Ties. Q joins at T=3 and P at T=20, both keep E83. R then S join and end with empty outfits. roundResults is exactly [Q, P, R, S], identical over 100 seeded repetitions with shuffled internal insertion order.
63. No participants (gate 1D). Three full rounds with nobody joining: no error, one RoundResultsPublished per round with roundResults = {}, ledger never called. Variant: the only participant leaves at T=220; one publication with an empty list.
64. Results come only from server state. Every entry carries the server-held playerUserId and display name. Every numeric field equals calculateOutfitScore on the frozen kept draft with the round's theme and bonus rule.

I. Available-item set changes during Styling (reported as outside what §1.2 describes)
65. Kept draft keeps its score. P keeps E83 (six items) at T=40. At T=120 the hair item leaves the available set. P sends nothing more. At T=190 the scored outfit is all six keys and the score is 83. Nothing raises, and the outfit handed to the showcase equals the scored outfit.
66. Waiting draft is validated at processing. Seq 5 is processed at T=119.90. Seq 6 (C, containing item K) arrives at T=119.95 and waits. K is hidden at T=120.00. At T=120.15 the ack is {6, false, "OutfitInvalid"} and the earlier kept draft stays.
67. A new draft after the change. In the setup of 65, P sends seq 2 at T=125 still containing the hidden hair item: ack{2, false}; kept stays seq 1.

J. Floods and bounded work
68. Draft flood. From T=20.00 to T=20.99, in 0.01 s steps, P sends 10000 valid drafts with rising numbers. The validator is called at most 4 times in that second (20.00, 20.25, 20.50, 20.75), with at most 4 acks and never more than one pending timer. After T=21.00 the kept draft is the highest number sent.
69. Non-participant flood. 10000 drafts at T=20 from a player who never joined: zero acks, zero validator calls, zero timers, no state retained.
70. One player's flood does not delay another. While P floods as in 68, Q's single draft at T=20.30 is acknowledged at T=20.30.

K. Appearance on spawn (§2.4, §6.2 row "Unit: appearance on spawn")
71. Table rows. A participant at T=200 gets the scored outfit, their own stage place and the dance restarted. A participant at T=60 gets the lobby appearance. A participant at T=5, 255 or 275 gets the lobby appearance. A non-participant at T=5, 60, 200, 255 or 275 gets the lobby appearance.
72. State is read at spawn time. A reset at T=249.5 with spawn at T=250.5 gives the lobby appearance. A reset at T=189.5 with spawn at T=190.5 gives the scored outfit on stage.
73. Gaps. A spawn while the save is not loaded gives the lobby appearance with an empty outfit and no error. A participant in Showcase with scored outfit {} gets a stage place and dance in the lobby appearance. P, Q, R hold places 1, 2, 3; Q leaves at T=210; R spawns at T=215 and is still at place 3. A participant who left at T=200 and whose user id spawns again at T=230 gets the lobby appearance.
74. Spawning is read-only. Calling the decision 1000 times for P during Styling and Showcase leaves the kept draft, sequence state, frozen score and results unchanged. Mutating the returned outfit does not change the referee's copy.

L. Server shutdown
75. Shutdown before Results. Shutdown is signalled at T=220 with P and Q scored. A join and a draft at T=221 change nothing. At T=250 there is no ledger call and no publication.
76. Shutdown after the grants. Shutdown at T=255: no second grant, and the amounts granted at T=250 are what the keeper's final save writes.

M. Randomized runs (seed printed on failure)
77. Draft protocol. Three players send random arrivals with gaps of 0–0.6 s, numbers that repeat, skip and go backwards, and valid and invalid outfits, some at and after T=190.000. Invariants:
    - The scored outfit equals the outfit of the last fresh ack with isKept = true, or is empty when there is none.
    - Fresh-ack numbers strictly increase per player.
    - No two processings of one player are closer than 0.250 s, except the cut-off flush.
    - Each processed number has exactly one fresh ack; every other ack is a re-send caused by a check-2 failure during Styling.
    - The highest-numbered draft that arrived from a participant during Styling is always processed.
    - No ack is sent after the cut-off step.
78. Lifecycle. 200 seeded rounds with random joins, leaves, lock losses, drafts and respawns. Invariants:
    - The ledger is called at most once per (roundId, playerUserId).
    - It is never called for a player who left, lost the save, or ended with an empty outfit.
    - Every entry's starCoinsGranted and fanCountGained equal the amounts actually applied.
    - Entries are sorted by outfitScore descending with the fixed tie-break.
    - Every listed player was a participant at T=250.
79. Arbitrary values. 5000 steps, each a random player (participant or not), a random time step of 0–0.3 s across all five phases, and a request built from arbitrary Luau values: nil, booleans, NaN, ±infinity, huge and fractional numbers, long strings, nested and self-referencing tables, tables with metatables, valid and invalid outfits. Invariants:
    - The referee never raises.
    - Pending timers never exceed the number of participants.
    - Validator calls stay within participants × (elapsed Styling seconds ÷ 0.25 + 1) + participants.
    - The scored-outfit invariant of 77 holds.
    - Grants per round never exceed the participants present at Results, each paid exactly once.
    - Nobody without a non-empty kept draft is rewarded.