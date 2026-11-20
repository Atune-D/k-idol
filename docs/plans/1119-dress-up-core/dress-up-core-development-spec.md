# Dress-Up Core · Development Spec

> A Roblox idol dress-up game: style an outfit to a theme, perform a dance on stage, get scored by the system, earn Star Coins and fans.

- **Version**: v1.3 (2026-11-19) — records the results of the Phase 1 trials, run in Roblox Studio (§8, §10). The design holds: un-owned Marketplace items, shoe bundles and makeup can all be worn. Changes: sellability is read from item details because bundle product info lacks it; dressing rules for layering order; the wardrobe preview is a device-only copy of the character; starter dance ids filled in.
  - v1.2 (2026-11-19) — takes in a second external audit: six findings, all confirmed (§10). Changes: a reward and the record that makes it non-repeatable are one indivisible change; outfit drafts carry a sequence number, are acknowledged and are never dropped for arriving early; the server publishes the wardrobe catalog it validates against; stored outfits survive unavailable items; a character that respawns is put back into the state its player is in; the publishing threshold is now 100.
  - v1.1 (2026-11-19) — takes in an external audit of v1.0 and of the first code: five findings, all confirmed (§10). Changes: styling items can be Marketplace bundles, so a pair of shoes is one item; outfits are lists of styling item keys; items that cannot be sold in this game are hidden; purchase acceptance now requires a completed purchase; the leaderboard write can never lower a value; save starts are spaced per player and requests are rate-limited; save events hand each listener an isolated snapshot.
  - v1.0 (2026-11-19) — first draft of the new direction. Confirmed by the owner the same day.
- **Status** (2026-11-19, after commit `0e7d0d5`): scaffolding, the tags-and-scoring slice and the save-and-leaderboard slice are written, verified and pushed (266 unit tests). Round logic, server wiring, the client and all of Phase 2 are not written. Where things stand and how to continue: [`dress-up-core-handoff.md`](./dress-up-core-handoff.md).
- **Supersedes**: [`../1119-rhythm-mvp/rhythm-mvp-development-spec.md`](../1119-rhythm-mvp/rhythm-mvp-development-spec.md) (the rhythm-game direction, dropped on 2026-11-19). Its save-data, leaderboard and publishing rules are carried into this document; its rhythm gameplay is not.
- **Readers**: the engineering session that implements this; §0 is written for a non-engineer.
- **Division of labour**: this is the only document for this initiative. There is no separate plan document yet; the reasons behind decisions are recorded in §0.3. 🔴 **If another document conflicts with this one, this one wins.**
- **Modules involved**: `src/shared`, `src/server`, `src/client`, `data`, `tools`, `tests` (partly written; this document is their contract).
- **⛔ Do not touch**: `claude-code-transferable-practices 2/` (collaboration kit, read-only reference).
- **Contract depth**: Phases 1–2 are specified as an engineering contract (§1–§6). Phases 3–4 are specified at design level only (§7) and get their own contract before they are built.
- **Out of scope for all four phases**: team competition; player-to-player voting; selling Star Coins for Robux; trading; custom-made clothing; multi-language.

> Symbols: 🔴 hard constraint · ⛔ forbidden · ✅ done · 🟡 under observation · ⚠️ has side effects, confirm separately · ⬜ not started

---

## 0. Ten-minute overview (plain language; the engineering contract starts at §1)

### 0.1 What the game is

Players dress their Roblox character from a curated wardrobe to match a theme, go on stage and dance, and receive a score from the system. Scores turn into two things:

- **Star Coins** — spendable. Used to buy dance moves and cosmetic effects.
- **Fans** — never spent, never decrease. They drive the global leaderboard and rank titles.

Where each kind of content comes from, and how the game earns money:

| Content | Source | Revenue |
|---|---|---|
| Clothing, accessories, shoes, hair | Roblox Marketplace items, hand-picked and tagged by the owner | Players buy them in-game with Robux; the game owner receives a 40% commission |
| Makeup | Roblox Marketplace makeup category (to be confirmed, §8) | Same commission (to be confirmed) |
| Dance moves | Made by the owner: original choreography → motion capture → Roblox animation | Bought with Star Coins. Robux-priced dances come in a later phase |
| Stage effects, titles, nameplates | Generated in code | Bought with Star Coins |

### 0.2 How the pieces fit

**Where the game runs**

| Place | What it is | Job |
|---|---|---|
| Player's device | Phone, tablet or PC | Show things and collect input |
| Roblox game server | A machine Roblox hosts for us; every player in a session is connected to it | Decide and record |
| Roblox cloud storage | Permanent storage provided by Roblox | Keep |

No self-hosted cloud server is needed.

**One currency ties every activity together**

Every activity pays out the same currency, and everything a player wants is bought with it. Whatever a player does, they are moving toward the same goal.

```
 HOW PLAYERS EARN                          HOW PLAYERS SPEND

 Themed rounds (by stars) ───┐
 Styling commissions ────────┤             ┌──► Dance moves (main)
 Tournament prizes ──────────┤             │
 Playtime rewards ───────────┼─► Star ─────┼──► Stage and entrance effects
 Daily quests ───────────────┤   Coins     │
 Promo codes ────────────────┤             ├──► Titles and nameplates
 Hidden quests ──────────────┘             │
                                           └──► Photo filters and poses
```

Two rules keep this healthy:

- There must always be more to buy than an active player can afford in two to three weeks. Otherwise the currency becomes worthless and players leave.
- Dance moves cannot be the only thing to buy, because each one has to be filmed and captured. Effects, titles and nameplates are generated in code and can be produced in bulk.

**Three shared foundations**

| Foundation | What it does | Used by |
|---|---|---|
| Tags and scoring | Judges how well an outfit fits a theme | Themed rounds, styling commissions, tournament, virtual contestants |
| Reward ledger | The single place where Star Coins and fans are granted or spent | Every way to earn and every purchase |
| Schedule | One configuration table saying which content is open during which dates | Rotating themes, weekend events, limited dances, promo-code validity, tournament times |

Every later activity is a thin layer on top of these three.

**How one round flows**

```
 PLAYER'S DEVICE              ROBLOX GAME SERVER          ROBLOX CLOUD STORAGE

                              Round clock: announces
  ┌──── theme + bonus rule ◄── theme (10 s)
  ▼
 Wardrobe: pick items
  │ each change, send
  │ the current outfit
  └────────────────────────► Referee: keeps the latest
                              valid outfit (180 s)
                                │ time is up
                                ▼
  ┌──── everyone's outfit ◄── Stage: all dance (60 s)
  ▼                             │
 Watch the showcase             ▼
                              Referee: scores each outfit
                                │
                                ▼
                              Ledger: grants coins + fans
                                │      (in server memory)
  ┌──── score, stars, coins ◄───┤
  ▼                             │ queued immediately
 Results screen (20 s)          ▼
                              Archivist: writes save ───► Player save data
                                │ only after the write
                                │ succeeds
                                ▼
                              Leaderboard keeper ───────► Fan leaderboard
```

Then a 10-second break, and the next round starts by itself with a new theme. One round is 280 seconds.

🔴 The score is computed on the server from the outfit the server itself holds. The device never reports a score. This removes the forged-score problem the rhythm design had.

**One worked example**

1. Theme: **Y2K Pop**. It wants the style `y2k` most, then `cute`, then `streetwear`. This round's bonus: the colour **pink**.
2. Player 8801 wears six things: a `y2k` hairstyle (pink), a `y2k` top (pink), `streetwear` trousers (black), `cute` shoes (white), a `y2k` bag (pink), and `elegant` eye makeup (beige).
3. The server scores it:
   - Theme match: 33 of 50. Hair, top and bag match fully, shoes partly, trousers a little, makeup not at all.
   - Completeness: 20 of 20. All six scoring slots are filled.
   - Colour harmony: 15 of 15. Only one non-neutral colour family.
   - Round bonus: 15 of 15. Three pink items.
   - Total 83 → **4 stars**.
4. 4 stars pay 80 Star Coins and 40 fans. Balance goes 350 → 430, fans 1200 → 1240.
5. The save is written to cloud storage. After that succeeds, 1240 is sent to the leaderboard.

**What else there is to do** (so that a player is not repeating one loop)

| Activity | Phase | What it is |
|---|---|---|
| Themed rounds | 1 | The core loop above |
| Lobby and dance floor | 2 | Untimed space: free styling, dancing, tapping another player to dance in sync with them, the dance shop |
| Playtime rewards | 2 | Claimable at 5, 10, 20, 30, 45 and 60 minutes of play each day, growing in size |
| Daily quests | 2 | Three small goals a day |
| Promo codes | 2 | Codes handed out on social channels |
| Styling commissions | 3 | A virtual client asks for a look; the player styles alone, any time, and is paid by score |
| Virtual contestants | 3 | System-generated competitors so rounds are not empty when few players are online |
| Tournament | 4 | Three-round elimination with a twist each round, on a fixed timetable |
| Limited-time and hidden content | 4 | Weekly theme rotation, weekend double coins, monthly limited dances, a secret client with an exclusive dance |

**Things to know before agreeing**

**A. Players under 16 are not reachable at launch.**
- What: Roblox publishes in tiers. Reaching 16+ only needs an age-checked account. Reaching under-16s additionally needs ID verification, 2-step verification, a fee or subscription, and passing an evaluation: a set number of "highly engaged", age-checked 16+ players within 60 days. The documented number is 100. It was 500 until August 2026 and 250 until 2026-11-19, the day this was written; it may change again.
- Why it matters: the natural audience for an idol dress-up game is under 16.
- If ignored: the game launches and its target audience cannot find it. Details in §5.3.

**B. System scoring can be "solved".**
- What: the scoring rules are fixed, so players will discover the best outfit for each theme.
- Why it matters: once solved, a theme stops being a creative task.
- Mitigation: a random bonus rule every round, rotating themes, and a growing item pool. This reduces the problem; it does not remove it.

**C. Everything rests on the owner's content work.**
- What: three things cannot be done by code — picking and tagging about 200 Marketplace items, producing dance moves, and writing theme and commission lists.
- If it stalls: there is no wardrobe and nothing exclusive to sell.

**D. The dance pipeline is unproven.**
- What: phone video → 3D motion → Blender → Roblox animation has not been run end to end. The owner has no Windows machine with an NVIDIA GPU, which the originally proposed tool requires. Current estimate of success at acceptable quality: about 50%.
- Mitigation: the game is built with Roblox's own dance animations as placeholders, so the rest does not wait. Three were confirmed to work in the trial (§3.8). They are very plain, so the game has nothing distinctive to sell until owner-made dances exist.

**E. Saves are protected across servers, at the cost of occasional waiting.**
- What: a save can be held by only one server at a time. A player who leaves one server and immediately joins another waits until the first one hands the save back.
- Cost: up to about 30 seconds on a quick rejoin; 6 minutes if the previous server crashed.

### 0.3 Decision log

| # | Question | Decision | Decided by | Date |
|---|---|---|---|---|
| 1 | Core genre | Dress-up with system scoring; the key-press rhythm gameplay is removed | Owner | 2026-11-19 |
| 2 | Who scores | The system first; player voting may be added later | Owner | 2026-11-19 |
| 3 | Where clothing comes from | A hand-picked, hand-tagged pool of Marketplace items (about 200 to start) | Owner agreed to AI proposal | 2026-11-19 |
| 4 | How scoring works | Theme match + completeness + a random per-round bonus | Owner agreed to AI proposal | 2026-11-19 |
| 5 | Dance moves | Original choreography, self-filmed, motion-captured. Not extracted from other people's videos | AI recommendation; owner asked follow-ups, ⬜ confirm | 2026-11-19 |
| 6 | Slot machine | Not built. Roblox prohibits playable gambling and names interactive slot machines. Replaced by free playtime rewards | AI, from official policy; owner moved to timed rewards | 2026-11-19 |
| 7 | Retention patterns to adopt | Single currency fed by many activities; promo codes; hidden and limited content; an untimed free space; a second game mode | Owner | 2026-11-19 |
| 8 | Target market | North America | Owner | 2026-11-19 |
| 9 | Staffing | One person; code written by AI; no outsourced art | Owner | 2026-11-19 |
| 10 | Own cloud server | None. Roblox built-in services only | AI; not objected | 2026-11-19 |
| 11 | Two numbers instead of one | Star Coins (spent) and fans (ranking), both earned from the same activities | AI default, ⬜ confirm | 2026-11-19 |
| 12 | Selling Star Coins for Robux | Not in Phases 1–4. If coins could be bought, every random reward paid for with coins would fall under Roblox's paid-random-item rules | AI default, ⬜ confirm | 2026-11-19 |
| 13 | Robux-priced dances | Not in Phases 1–2. Launch revenue is the 40% commission only. Robux dances come with Phase 3, when purchase handling is built | AI default, ⬜ confirm | 2026-11-19 |
| 14 | Virtual contestants | Built in Phase 3, clearly labelled as virtual | AI default, ⬜ confirm | 2026-11-19 |
| 15 | Build order | Four phases; publish after Phase 2 and let player data reorder Phases 3–4 | AI default, ⬜ confirm | 2026-11-19 |
| 16 | Input | Touch first, keyboard and mouse supported | AI default, ⬜ confirm | 2026-11-19 |
| 17 | Weekly effort assumed | About 10 hours | AI default, ⬜ confirm | 2026-11-19 |
| 18 | Publishing tier | ⬜ Undecided: publish to 16+ and go through the normal evaluation, or pay for expedited review. See §5.3 | Owner to decide | — |
| 19 | Save protection across servers | Included from Phase 1 | Carried from the previous spec | 2026-11-19 |
| 20 | Leaderboard update timing | Only after the save has been written | Carried from the previous spec | 2026-11-19 |
| 21 | Code comment language | English | Owner | 2026-11-19 |
| 22 | Shoes | A pair of shoes is one styling item backed by a Marketplace bundle; the item pool distinguishes assets from bundles | Audit finding, confirmed in official docs; AI adopted | 2026-11-19 |
| 23 | Items that cannot be bought in this game | Hidden from the wardrobe and logged | Audit finding, confirmed in official docs; AI adopted | 2026-11-19 |
| 24 | Leaderboard writes | Atomic "keep the larger of the stored and the saved value" | Audit finding; AI adopted | 2026-11-19 |
| 25 | Save frequency | Save starts spaced at least 10 seconds apart per player; appearance changes do not trigger a save; every request channel is rate-limited on the server | Audit finding; AI adopted | 2026-11-19 |

| 26 | Rewards and their records | One indivisible in-memory change per grant or spend | Audit finding; AI adopted | 2026-11-19 |
| 27 | Outfit drafts | Sequence number, acknowledgement, resend; the server coalesces instead of refusing | Audit finding; AI adopted | 2026-11-19 |
| 28 | Wardrobe contents on the device | Taken from a catalog the server publishes, the same one it validates against | Audit finding; AI adopted | 2026-11-19 |
| 29 | Stored outfit with unavailable items | Wear what is available; remove a key from the save only when the item has left the pool | Audit finding; AI adopted | 2026-11-19 |
| 30 | Character respawn | The server re-applies whatever the player's current state calls for | Audit finding; AI adopted | 2026-11-19 |

On 2026-11-19 the owner confirmed v1.0 as a whole, which settles decisions 5 and 11–17. Decision 18 remains open.

---

## 1. Data model

> Naming: modules and files in `PascalCase`, data fields in `camelCase`, constants in `UPPER_SNAKE_CASE`, tag values and ids in `snake_case`. Every name must be understandable on its own.

### 1.1 Tag vocabularies (`src/shared/StylingTagVocabulary.luau`)

Fixed lists. An item or theme may only use values from these lists.

| Vocabulary | Values (starting set) |
|---|---|
| `styleTag` | `y2k`, `streetwear`, `cute`, `elegant`, `gothic`, `sporty`, `retro`, `fantasy`, `beach`, `formal`, `punk`, `preppy` |
| `colorTag` | `pink`, `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `brown`, and the neutrals `black`, `white`, `gray`, `beige` |
| `itemSlot` | `hair`, `top`, `bottom`, `dress`, `shoes`, `accessory`, `makeup_eyes`, `makeup_lips`, `makeup_face`, `eyelashes`, `eyebrows` |

`NEUTRAL_COLOR_TAGS = { black, white, gray, beige }`.

### 1.2 Styling item pool

The owner maintains a spreadsheet exported as `data/styling-item-pool.csv`. A tool in `tools/` validates it and generates `src/shared/generated/StylingItemPool.luau`. 🔴 The generated file is never edited by hand.

A **styling item** is one thing a player puts on and one thing the scoring counts. It is backed by either a single Marketplace asset or a Marketplace bundle. Roblox shoes are two separate assets, left and right, sold together as a bundle; a pair of shoes is therefore one styling item of kind `Bundle`.

| Column / field | Type | Example | Notes |
|---|---|---|---|
| `marketplaceItemKind` | `Asset` or `Bundle` | `Asset` | What the id below refers to, and what the player buys |
| `marketplaceItemId` | number | `1234567890` | The asset id or the bundle id |
| `itemSlot` | `itemSlot` | `top` | Exactly one |
| `styleTags` | list of `styleTag` | `y2k, cute` | One to three |
| `primaryColorTag` | `colorTag` | `pink` | Exactly one |
| `isEnabled` | boolean | `true` | `false` hides the item without deleting the row |

The tool derives `stylingItemKey` for each row: `asset_<marketplaceItemId>` or `bundle_<marketplaceItemId>`. This key is how the rest of the game refers to the item.

The tool rejects the file if any value is outside the vocabularies, a `stylingItemKey` is duplicated, a row has no style tag, a `shoes` row is not of kind `Bundle`, or a row in any other slot is not of kind `Asset`.

**Read from Roblox at run time, not stored here** (by the server, once per server session, then cached):

| What | For |
|---|---|
| Name, price, thumbnail | Display |
| For a bundle: the list of assets it contains | Dressing the character |
| Whether the item can be bought, and where it may be sold. Read from the avatar item details, which report both for assets and for bundles; bundle product info reports neither (§8) | Deciding whether to show it |
| The Roblox asset type of every worn asset (for example hair accessory, left shoe, lip makeup, layered jacket) | Building the appearance correctly on the server and in the device preview |

🔴 A styling item is hidden for that server session and logged when any of these holds: its details fail to load; it is not on sale; it cannot be sold in this game; it is a bundle whose contents fail to load. A hidden item is treated as not being in the pool: an outfit containing it is invalid.

**Selection rules for the owner.** Pick only items that are on sale and whose creator allows sale in all experiences. An item restricted to the Marketplace or to its creator's own games can be shown by other games but not bought in them, so it earns nothing here.

### 1.3 Themes (`src/shared/ThemeCatalog.luau`)

| Field | Type | Example |
|---|---|---|
| `themeId` | string | `"y2k_pop"` |
| `themeDisplayName` | string | `"Y2K Pop"` |
| `styleTagWeights` | map `styleTag` → number in (0, 1] | `{ y2k = 1.0, cute = 0.6, streetwear = 0.4 }` |

A style tag not listed in `styleTagWeights` has weight 0 for that theme.

### 1.4 Round bonus rule (chosen at random each round)

| Field | Type | Example |
|---|---|---|
| `roundBonusKind` | `"ColorBonus"` or `"StyleBonus"` | `"ColorBonus"` |
| `bonusColorTag` | `colorTag`, when kind is `ColorBonus` | `pink` |
| `bonusStyleTag` | `styleTag`, when kind is `StyleBonus` | — |

🔴 A `StyleBonus` never picks a style tag that already has weight in the round's theme, and a `ColorBonus` never picks a neutral colour.

### 1.5 Outfit and its validity (`src/shared/OutfitValidator.luau`)

An outfit is a list of `stylingItemKey` values. It is valid when:

| # | Rule |
|---|---|
| 1 | Every key is an enabled, non-hidden styling item of the pool |
| 2 | No key appears twice |
| 3 | At most one item each in `hair`, `top`, `bottom`, `dress`, `shoes`, `makeup_eyes`, `makeup_lips`, `makeup_face`, `eyelashes`, `eyebrows` |
| 4 | At most `MAX_ACCESSORY_ITEM_COUNT = 3` items in `accessory` |
| 5 | A `dress` cannot be combined with a `top` or a `bottom` |

An empty outfit is valid. Any subset of a valid outfit is valid.

**Stored outfits that contain unavailable items.** `lobbyOutfitStylingItemKeys` was valid when stored; later an item may leave the pool or be hidden. The rules above apply to what a device **submits**. For what is already **stored**:

| Case | Likely cause | When dressing | In the save |
|---|---|---|---|
| The key is no longer in the pool, or its row has `isEnabled = false` | The owner removed it; permanent | Skipped | Removed from `lobbyOutfitStylingItemKeys`, once, when the save is loaded |
| The key is in the pool but hidden for this server session (§1.2) | Lookup failure, off sale, not sellable here; may be temporary | Skipped | 🔴 Kept. A temporary fault must never erase part of a stored outfit |

The remaining items are worn. The player is told how many are unavailable (§2.6).

### 1.6 Scoring (`src/shared/OutfitScoreCalculator.luau`)

**Scoring slots.** Six of them. Each takes the best-matching item among the item slots that feed it.

| Scoring slot | Fed by |
|---|---|
| `hair` | `hair` |
| `upperBody` | `top`, or `dress` |
| `lowerBody` | `bottom`, or `dress` |
| `shoes` | `shoes` |
| `accessory` | any `accessory` item |
| `makeup` | any of `makeup_eyes`, `makeup_lips`, `makeup_face`, `eyelashes`, `eyebrows` |

A dress fills both `upperBody` and `lowerBody`. A pair of shoes is one styling item and fills `shoes` once.

**Item match** for a theme = the largest `styleTagWeights` value among the item's `styleTags` (0 if none is listed).

**Components**

| Component | Range | Formula |
|---|---|---|
| `themeMatchPoints` | 0–50 | `50 × (sum over the six scoring slots of the best item match in that slot) ÷ 6`. An empty slot contributes 0 |
| `completenessPoints` | 0–20 | `20 × (number of filled scoring slots) ÷ 6` |
| `colorHarmonyPoints` | 0, 8 or 15 | Count the distinct non-neutral `primaryColorTag` values across all worn items. 0–2 → 15; 3 → 8; 4 or more → 0. An empty outfit scores 0 |
| `roundBonusPoints` | 0, 5, 10 or 15 | `5 × min(3, number of worn items that satisfy the bonus rule)` |

`outfitScore = floor(themeMatchPoints + completenessPoints + colorHarmonyPoints + roundBonusPoints)`, from 0 to 100.

**Stars and rewards**

| `outfitScore` | `starCount` | Star Coins | Fans |
|---|---|---|---|
| 0–39 | 1 | 20 | 10 |
| 40–59 | 2 | 40 | 20 |
| 60–74 | 3 | 60 | 30 |
| 75–89 | 4 | 80 | 40 |
| 90–100 | 5 | 100 | 50 |

🔴 A participant whose final outfit is empty receives no stars and no reward.

All numbers in this section are starting values to be tuned after playtests. They live in this one file.

**The §0.2 example, computed**

| Scoring slot | Item | Item match |
|---|---|---|
| `hair` | `y2k`, pink | 1.0 |
| `upperBody` | `y2k`, pink | 1.0 |
| `lowerBody` | `streetwear`, black | 0.4 |
| `shoes` | `cute`, white | 0.6 |
| `accessory` | `y2k`, pink | 1.0 |
| `makeup` | `elegant`, beige | 0 |

`themeMatchPoints = 50 × 4.0 ÷ 6 = 33.33` · `completenessPoints = 20` · one non-neutral colour → `colorHarmonyPoints = 15` · three pink items → `roundBonusPoints = 15` · `outfitScore = floor(83.33) = 83` → 4 stars → 80 Star Coins, 40 fans.

### 1.7 Dances and cosmetics

The dance catalog exists from Phase 1, holding only starter dances, because the showcase needs a dance to play. The dance shop, purchasable dances and all cosmetics arrive in Phase 2.

**`src/shared/DanceCatalog.luau`**

| Field | Type | Example |
|---|---|---|
| `danceId` | string | `"starter_wave"` |
| `danceDisplayName` | string | `"Starter Wave"` |
| `danceAnimationAssetId` | string | filled in when the animation exists |
| `starCoinPrice` | number | `900`; `0` for starter dances |
| `isGrantedToNewPlayers` | boolean | `true` for starter dances |

**`src/shared/CosmeticCatalog.luau`**

| Field | Type | Example |
|---|---|---|
| `cosmeticId` | string | `"title_rising_star"` |
| `cosmeticKind` | `"Title"`, `"NameplateStyle"` or `"StageEntranceEffect"` | `"Title"` |
| `cosmeticDisplayName` | string | `"Rising Star"` |
| `starCoinPrice` | number | `300` |

Pricing guide (starting values): a themed round pays about 60 Star Coins on average. Cheap items cost about 5 rounds, standard items about 15, premium items about 50.

### 1.8 Daily content (Phase 2)

**Day boundary.** `dailyDateKey` is the UTC calendar date as `YYYY-MM-DD`. Everything "daily" resets when it changes.

**Playtime milestones** (`PLAYTIME_MILESTONES`, cumulative minutes played that day → Star Coins):

| Minutes | 5 | 10 | 20 | 30 | 45 | 60 |
|---|---|---|---|---|---|---|
| Star Coins | 20 | 30 | 50 | 80 | 100 | 150 |

Total 430 per day. Each is claimed by the player; unclaimed milestones are lost at the day boundary.

**Daily quests** (`src/shared/DailyQuestCatalog.luau`). Three quests per day, the same for every player, selected from the catalog by a random generator seeded with `dailyDateKey`.

| Field | Type | Example |
|---|---|---|
| `dailyQuestId` | string | `"complete_rounds_5"` |
| `dailyQuestKind` | `"CompleteRounds"`, `"EarnStarsAtLeast"` or `"UseColorInRatedOutfit"` | `"CompleteRounds"` |
| `targetCount` | number | `5` |
| `minimumStarCount` | number, optional | `3` |
| `requiredColorTag` | `colorTag`, optional | `pink` |
| `starCoinReward` | number | `100` |

### 1.9 Promo codes (Phase 2, server only)

`src/server/PromoCodeCatalog.luau`. 🔴 This file is never placed where player devices can read it.

| Field | Type | Example |
|---|---|---|
| `promoCodeId` | string | `"launch_2026"` |
| `promoCodeText` | string, compared case-insensitively | `"IDOLSTART"` |
| `starCoinReward` | number | `300` |
| `validFromUnixSeconds` / `validUntilUnixSeconds` | number | — |

### 1.10 Player save data

Standard data store `PlayerSaveData_v1`, key `player_<playerUserId>`.

| Field | Type | Before the example round | After |
|---|---|---|---|
| `saveDataSchemaVersion` | number | `1` | `1` |
| `fanCount` | number | `1200` | `1240` |
| `starCoinBalance` | number | `350` | `430` |
| `totalRoundsCompletedCount` | number | `14` | `15` |
| `bestStarCountByThemeId` | map | `{ y2k_pop = 3 }` | `{ y2k_pop = 4 }` |
| `ownedDanceIds` | list | `{ "starter_wave" }` | unchanged |
| `equippedDanceId` | string | `"starter_wave"` | unchanged |
| `ownedCosmeticIds` | list | `{}` | unchanged |
| `equippedCosmeticIdByKind` | map | `{}` | unchanged |
| `lobbyOutfitStylingItemKeys` | list | last outfit set in the lobby; empty means the player's own avatar | unchanged |
| `dailyProgress` | table | see below | see below |
| `redeemedPromoCodeIds` | list | `{}` | unchanged |
| `firstJoinedAtUnixSeconds` | number | fixed | fixed |
| `lastSavedAtUnixSeconds` | number | time of last save | time of this save |
| `gameServerSessionLock` | table or empty | see §3.4 | see §3.4 |

`dailyProgress`:

| Field | Type |
|---|---|
| `dailyDateKey` | string |
| `playtimeSecondsToday` | number |
| `claimedPlaytimeMilestoneMinutes` | list of numbers |
| `dailyQuestProgressCountByQuestId` | map |
| `claimedDailyQuestIds` | list |

When the current `dailyDateKey` differs from the stored one, the whole `dailyProgress` table is replaced by a fresh one.

A new player starts with `fanCount = 0`, `starCoinBalance = 0`, every dance whose `isGrantedToNewPlayers` is true, and `equippedDanceId` set to the first of them.

**Migration.** A change to the save structure raises `saveDataSchemaVersion` by one, and `PlayerSaveDataKeeper` upgrades older versions when it loads them. Phase 1 has only version 1.

### 1.11 Fan leaderboard

- Ordered data store `FanCountLeaderboard_v1`, key `tostring(playerUserId)`, value `fanCount`.
- 🔴 Only a `fanCount` that has already been written to `PlayerSaveData_v1` may be written to the leaderboard. The leaderboard never shows more fans than the save holds.
- 🔴 A leaderboard write never lowers the stored value (§3.5).
- Each server reads the top 100 every 60 seconds and caches them. Devices read only the cache.

⚠️ An ordered data store cannot answer "what rank is this player". Ranks are shown for the top 100 only; everyone else sees "outside the top 100".

---

## 2. Interface contract (device ↔ server)

All channels live in `ReplicatedStorage.Remotes`; their names are defined in `src/shared/RemoteNames.luau`.

Every request below answers `{ isAccepted = true, … }` or `{ isAccepted = false, rejectionReason }`.

### 2.1 Round clock

Constants: `THEME_REVEAL_SECONDS = 10`, `STYLING_SECONDS = 180`, `SHOWCASE_SECONDS = 60`, `RESULTS_SECONDS = 20`, `INTERMISSION_SECONDS = 10`. `MAX_PLAYERS_PER_SERVER = 12`.

`roundPhase` cycles `ThemeReveal → Styling → Showcase → Results → Intermission → ThemeReveal …` for as long as the server runs, whether or not anyone is taking part.

**`RoundStateChanged`** (server → every device, on each phase change and to each player on joining the server):

`{ roundId, roundPhase, phaseEndsAtUnixMilliseconds, themeId, roundBonusRule, participantUserIds }`

- `roundId` is a server-generated unique id, new at each `ThemeReveal`.
- A theme is not repeated within the last `RECENT_THEME_EXCLUSION_COUNT = 5` rounds on that server.

### 2.2 `RequestJoinCurrentRound` (device asks, server answers)

Accepted during `ThemeReveal`, and during `Styling` while at least `MINIMUM_STYLING_SECONDS_TO_JOIN = 60` seconds remain.

Rejection reasons: `SaveDataNotLoaded`, `WardrobeCatalogNotReady`, `RoundNotJoinableNow`, `AlreadyParticipating`, `TooManyRequests`.

A participant who leaves the server is removed from the round and gets no reward for it.

### 2.3 Outfit drafts: `SetRoundOutfitDraft` and `RoundOutfitDraftAcknowledged`

**`SetRoundOutfitDraft`** (device tells server): `{ roundId, outfitDraftSequenceNumber, outfitStylingItemKeys }`.

`outfitDraftSequenceNumber` starts at 1 for each player in each round and rises by 1 with every new draft the device produces.

**`RoundOutfitDraftAcknowledged`** (server → that device): `{ roundId, outfitDraftSequenceNumber, isKept, rejectionReason }`.

**What the server does with an arriving draft**

| # | Check | If it fails |
|---|---|---|
| 1 | The sender is a participant of the current round, `roundId` matches, and `roundPhase` is `Styling` | Ignored, no acknowledgement |
| 2 | `outfitDraftSequenceNumber` is higher than the highest this server has already processed for the player this round | Not processed again; the earlier acknowledgement for the highest processed draft is sent again |
| 3 | At least `OUTFIT_DRAFT_SERVER_PROCESSING_INTERVAL_SECONDS = 0.25` has passed since this player's previous draft was processed | 🔴 **Not refused.** The draft waits in a one-place buffer; a newer draft arriving meanwhile replaces it. The waiting draft is processed as soon as the interval has passed |
| 4 | `outfitStylingItemKeys` is a valid outfit (§1.5) | Acknowledged with `isKept = false` and `rejectionReason = "OutfitInvalid"`; the previously kept draft stays |

A draft that passes all four becomes the player's **kept draft** and is acknowledged with `isKept = true`.

**What the device does**

- After each wardrobe change it sends the current outfit, at most once every `OUTFIT_DRAFT_SEND_INTERVAL_SECONDS = 0.5`. A change made inside that interval is sent when the interval ends, so the latest outfit is always eventually sent.
- If the latest draft it sent has not been acknowledged after `OUTFIT_DRAFT_RESEND_AFTER_SECONDS = 1`, it sends it again with the same sequence number.
- It shows the outfit as saved only when the latest draft is acknowledged as kept. On `isKept = false` it puts the preview back to the last kept draft and says so.
- It locks the wardrobe `WARDROBE_LOCK_BEFORE_STYLING_END_SECONDS = 1` before `phaseEndsAtUnixMilliseconds`, so the last change has time to arrive.

🔴 **Cut-off.** At the end of `Styling` the server first processes any draft still waiting in a buffer, then scores each participant's kept draft. Anything arriving later is ignored. The showcase and the results show the outfit that was scored, so a player always sees what was judged.

### 2.4 Showcase

At the start of `Showcase` the server dresses each participant's character in their final outfit, places them on the stage and plays their `equippedDanceId`. Every device in the server sees it. At the end the server restores each participant's lobby appearance: the available part of their `lobbyOutfitStylingItemKeys` (§1.5), where an empty list means the player's own Roblox avatar. In Phase 1 the list is always empty.

🔴 **Respawn.** Whenever a player's character spawns — on joining, after a reset, after falling out of the world — the server applies what that player's current state calls for:

| Player's state | On spawn |
|---|---|
| Participant, during `Showcase` | The scored outfit, their place on the stage, and their dance started again |
| Participant, during `Styling` | Lobby appearance from the server; the device re-applies its draft preview |
| Anything else | Lobby appearance |

A respawn never changes what was or will be scored.

### 2.5 `RoundResultsPublished` (server → every device, at the start of `Results`)

`{ roundId, roundResults }`, each entry:

`{ playerUserId, playerDisplayName, outfitScore, themeMatchPoints, completenessPoints, colorHarmonyPoints, roundBonusPoints, starCount, starCoinsGranted, fanCountGained, isNewBestStarCountForTheme }`

Sorted by `outfitScore`, highest first. Rewards are granted through the ledger (§3.3) at this moment.

### 2.6 `PlayerSaveDataSnapshotChanged` (server → the owning device)

`{ fanCount, starCoinBalance, ownedDanceIds, equippedDanceId, ownedCosmeticIds, equippedCosmeticIdByKind, lobbyOutfitStylingItemKeys, unavailableLobbyOutfitStylingItemKeys, dailyProgress, todaysDailyQuestIds, isSaveDataPersistenceDelayed }`

`unavailableLobbyOutfitStylingItemKeys` lists the stored keys that are hidden this session. When it is not empty the device shows "Some items of your saved outfit are unavailable right now."

Sent once when the save has loaded, then whenever the in-memory save or the persistence state changes. 🔴 The device shows balances only from this message and never computes them itself.

### 2.7 `SetLobbyOutfit` (Phase 2; device asks, server answers)

`{ outfitStylingItemKeys }`. Accepted when the outfit is valid and the player is not a participant in the `Styling` or `Showcase` phase. The server dresses the character and stores `lobbyOutfitStylingItemKeys`.

Rejection reasons: `SaveDataNotLoaded`, `WardrobeCatalogNotReady`, `OutfitInvalid`, `NotAllowedDuringRound`, `TooManyRequests`.

### 2.8 Dance requests (Phase 2)

| Request | Payload | Accepted when | Rejection reasons |
|---|---|---|---|
| `RequestPurchaseDanceWithStarCoins` | `danceId` | The dance exists, is not owned, and the balance covers `starCoinPrice` | `UnknownDance`, `AlreadyOwned`, `InsufficientStarCoins`, `SaveDataNotLoaded` |
| `RequestPurchaseCosmeticWithStarCoins` | `cosmeticId` | Same rules for cosmetics | `UnknownCosmetic`, `AlreadyOwned`, `InsufficientStarCoins`, `SaveDataNotLoaded` |
| `RequestEquipDance` | `danceId` | The dance is owned | `DanceNotOwned` |
| `RequestEquipCosmetic` | `cosmeticId` | The cosmetic is owned | `CosmeticNotOwned` |
| `RequestStartDanceInLobby` | `danceId` | The dance is owned and the player is not on stage | `DanceNotOwned`, `NotAllowedDuringRound` |
| `RequestSyncDanceWithPlayer` | `targetPlayerUserId` | The target is currently dancing in the lobby | `TargetNotDancing`, `NotAllowedDuringRound` |
| `RequestStopDanceInLobby` | — | Always | — |

A synced player performs the target's dance, in time with the target, without owning it, until either of them stops. This is the free trial that sells dances.

### 2.9 Daily requests (Phase 2)

| Request | Payload | Accepted when | Rejection reasons |
|---|---|---|---|
| `RequestClaimPlaytimeMilestone` | `milestoneMinutes` | It is a defined milestone, `playtimeSecondsToday` has reached it, and it is not yet claimed today | `UnknownMilestone`, `MilestoneNotReached`, `AlreadyClaimed` |
| `RequestClaimDailyQuestReward` | `dailyQuestId` | It is one of today's quests, its progress has reached `targetCount`, and it is not yet claimed today | `NotTodaysQuest`, `QuestNotCompleted`, `AlreadyClaimed` |

`playtimeSecondsToday` is counted by the server while the player is connected.

### 2.10 `RequestRedeemPromoCode` (Phase 2)

Payload: `promoCodeText`. Rejection reasons: `UnknownPromoCode`, `PromoCodeNotActive`, `AlreadyRedeemed`, `TooManyAttempts`.

🔴 At most one attempt per player every `PROMO_CODE_ATTEMPT_MINIMUM_INTERVAL_SECONDS = 2`; faster attempts get `TooManyAttempts` without being checked.

### 2.11 `RequestFanCountLeaderboardTopEntries`

Answer: `{ leaderboardEntries, refreshedAtUnixSeconds }`, each entry `{ leaderboardRank, playerUserId, playerDisplayName, fanCount }`, at most 100.

### 2.12 Buying a Marketplace item (Phase 2)

The wardrobe shows a "Buy" button on a selected styling item the player does not own (ownership per §2.14). It opens Roblox's own purchase prompt: the asset prompt for kind `Asset`, the bundle prompt for kind `Bundle`. Ownership is likewise checked per kind. Roblox completes the purchase and delivers the item to the player's account; the game does not grant anything itself and stores nothing about it.

Two conditions outside the code decide whether a purchase can complete and whether the game owner is paid:

- 🔴 The game must have **Allow Third Party Sales** switched on (Experience Settings → Security). Without it, items made by other creators can be seen and not bought.
- The item's creator must allow sale in this game. Items that do not are hidden (§1.2), so every item with a "Buy" button is one Roblox reports as sellable here.

### 2.13 Request rate limits and no-op requests

🔴 The server enforces a minimum interval per player per channel. A request arriving sooner is answered `{ isAccepted = false, rejectionReason = "TooManyRequests" }`, or ignored if the channel has no answer, and changes nothing.

| Channel | Minimum interval (seconds) |
|---|---|
| `SetRoundOutfitDraft` | 0.25, and coalesced rather than refused (§2.3) |
| `RequestWardrobeCatalogSnapshot` | 2 |
| `RequestStylingItemOwnership` | 0.5 |
| `RequestJoinCurrentRound` | 1 |
| `SetLobbyOutfit` | 2 |
| `RequestEquipDance`, `RequestEquipCosmetic` | 1 |
| `RequestPurchaseDanceWithStarCoins`, `RequestPurchaseCosmeticWithStarCoins` | 1 |
| `RequestClaimPlaytimeMilestone`, `RequestClaimDailyQuestReward` | 1 |
| `RequestStartDanceInLobby`, `RequestSyncDanceWithPlayer`, `RequestStopDanceInLobby` | 0.5 |
| `RequestRedeemPromoCode` | 2 (answers `TooManyAttempts`, as in §2.10) |
| `RequestFanCountLeaderboardTopEntries` | 5 |

🔴 A request that would leave the save exactly as it is (equipping what is already equipped, setting the lobby outfit to the current one) is accepted and does not count as a change: no revision bump, no save, no snapshot message.

### 2.14 Wardrobe catalog

The server decides which styling items are available (§1.2). The device must show exactly that set, with the same names, prices and bundle contents, or it would offer items whose drafts the server then rejects.

`isWardrobeCatalogReady` is false from server start until `MarketplaceStylingItemResolver` has finished its first pass over the pool, retrying a failed lookup up to 3 times before hiding the item.

**`RequestWardrobeCatalogSnapshot`** (device asks, server answers):

`{ isAccepted = true, isWardrobeCatalogReady, wardrobeCatalogVersion, wardrobeItems }`, each item `{ stylingItemKey, marketplaceItemKind, marketplaceItemId, itemDisplayName, priceInRobux, wornAssets }`, where each worn asset is `{ wornAssetId, robloxAssetTypeName }`.

- `wardrobeItems` holds every available item and no hidden one. It is empty while the catalog is not ready.
- `wornAssets` is the single asset for kind `Asset`. For kind `Bundle` it is the bundle's wearable contents; a bundle also lists a saved-outfit entry, which is not wearable and is left out.
- Slot and tags are not repeated here; the device reads them from the shared item pool by `stylingItemKey`.

**`WardrobeCatalogChanged`** (server → every device): `{ isWardrobeCatalogReady, wardrobeCatalogVersion }`, sent when readiness or the version changes. A device then asks for the snapshot again.

🔴 The server validates outfits against the catalog of the version it last published. Until the catalog is ready the wardrobe shows a loading state, and `RequestJoinCurrentRound` and `SetLobbyOutfit` are rejected with `WardrobeCatalogNotReady`.

**`RequestStylingItemOwnership`** (device asks, server answers): payload `stylingItemKey`; answer `{ isAccepted = true, isOwnedByPlayer }`. Ownership is asked for one item at a time, when the player selects it, and again after a purchase prompt closes. It is not part of the snapshot, because checking every item for every player would cost hundreds of Roblox requests per join. Rejection reasons: `UnknownStylingItem`, `TooManyRequests`.

---

## 3. Implementation notes

### 3.1 Tools and way of working

Installed on this machine (checked 2026-11-19): Rojo 7.7.1, Lune 0.11.1, Rokit 1.2.0, StyLua 2.6.0, selene 0.32.0, Roblox Studio, macOS 14.5.

- All code lives in this folder and is synced into Roblox Studio by Rojo.
- Pure-logic modules are tested from the command line with Lune.
- 🔴 The interface, lobby and stage are built in code, not placed by hand in Studio, so the whole game can be rebuilt from this folder.

### 3.2 Planned layout (nothing exists yet)

```
idolgrow/
├── default.project.json
├── data/
│   └── styling-item-pool.csv                  owner-maintained
├── tools/
│   └── GenerateStylingItemPool.luau           CSV → generated module
├── src/
│   ├── shared/
│   │   ├── StylingTagVocabulary.luau
│   │   ├── generated/StylingItemPool.luau     generated, never hand-edited
│   │   ├── ThemeCatalog.luau
│   │   ├── OutfitValidator.luau
│   │   ├── OutfitScoreCalculator.luau
│   │   ├── DanceCatalog.luau                  starter dances in Phase 1
│   │   ├── CosmeticCatalog.luau               Phase 2
│   │   ├── DailyQuestCatalog.luau             Phase 2
│   │   └── RemoteNames.luau
│   ├── server/
│   │   ├── ServerMain.server.luau             wiring only
│   │   ├── ThemedRoundClock.luau              phases and timing
│   │   ├── ThemedRoundReferee.luau            drafts, scoring, results
│   │   ├── RewardLedger.luau                  every grant and every spend
│   │   ├── PlayerSaveDataKeeper.luau          lock and save queue
│   │   ├── RobloxPlayerSaveDataStorage.luau   the only file touching the save store
│   │   ├── FanCountLeaderboardKeeper.luau
│   │   ├── RobloxFanCountLeaderboardStorage.luau
│   │   ├── PlayerCharacterDresser.luau        applies outfits to characters
│   │   ├── MarketplaceStylingItemResolver.luau  details, bundle contents, sellable here
│   │   ├── PlayerRequestRateLimiter.luau      per-player, per-channel intervals
│   │   ├── LobbyDanceCoordinator.luau         Phase 2
│   │   ├── DailyProgressTracker.luau          Phase 2
│   │   ├── PromoCodeRedeemer.luau             Phase 2
│   │   └── PromoCodeCatalog.luau              Phase 2, server only
│   └── client/
│       ├── ClientMain.client.luau             wiring only
│       ├── WardrobeScreen/
│       ├── RoundScreens/
│       ├── LobbyScreens/                      Phase 2
│       └── StageAndLobbyScene/
├── tests/
└── docs/
```

### 3.3 Hard constraints per part

- 🔴 `RewardLedger` is the only module that changes `fanCount` or `starCoinBalance`. Every grant carries a `rewardSourceKind` (`ThemedRound`, `PlaytimeMilestone`, `DailyQuest`, `PromoCode`; later `StylingCommission`, `Tournament`, `HiddenQuest`) and every spend a `purchaseKind` (`Dance`, `Cosmetic`). Both are logged.
- 🔴 `starCoinBalance` can never go below 0. A spend that would do so is refused.
- 🔴 **A reward and its record are one change.** Every grant or spend is a single in-memory change that does three things together, with nothing able to run in between: checks eligibility against the current save, changes the balance or fan count, and writes the record that makes the operation non-repeatable. A save therefore can never contain one without the others, and a crash at any moment leaves either all of it or none of it.

  | Operation | Record written in the same change |
  |---|---|
  | Playtime milestone claim | The milestone added to `claimedPlaytimeMilestoneMinutes` |
  | Daily quest claim | The quest added to `claimedDailyQuestIds` |
  | Promo code redemption | The code added to `redeemedPromoCodeIds` |
  | Dance or cosmetic purchase | The item added to `ownedDanceIds` or `ownedCosmeticIds` |
  | Round reward | `totalRoundsCompletedCount`, `bestStarCountByThemeId` and daily quest progress |

  If the change cannot be applied, nothing changes and the request is rejected. The ledger's grant and spend operations take the caller's eligibility check and record as part of the same change; no caller grants first and records afterwards.
- 🔴 `RobloxPlayerSaveDataStorage` is the only file that touches `PlayerSaveData_v1`; `RobloxFanCountLeaderboardStorage` is the only file that touches `FanCountLeaderboard_v1`.
- 🔴 The rule parts of the clock, referee, ledger, archivist, leaderboard keeper, daily tracker and promo redeemer call no Roblox-specific interface directly. Storage, the current time and the random generator are passed in, so tests can substitute fakes.
- 🔴 `OutfitValidator`, `OutfitScoreCalculator` and the tag vocabulary call no Roblox-specific interface.
- 🔴 `ThemedRoundReferee` never accepts a score, star count or reward amount from a device.
- 🔴 Every event `PlayerSaveDataKeeper` raises gives **each listener its own isolated snapshot**: either a separate deep copy per listener or one deeply frozen table. Nothing a listener does to what it receives can change what another listener, or the keeper, sees.
- 🔴 `MarketplaceStylingItemResolver` is the only module that asks Roblox about Marketplace items and bundles. Everything else reads its cached answers.

### 3.4 Saves: cross-server protection and save rules

#### The lock

`gameServerSessionLock` is stored inside the player's save and says which server currently holds it.

| Field | Meaning |
|---|---|
| `sessionLockId` | A unique id the server generates when it loads this player's save |
| `lockRefreshedAtUnixSeconds` | Time of the most recent successful save |

`SESSION_LOCK_EXPIRY_SECONDS = 360`. A lock not refreshed for that long is treated as expired (its server has crashed).

🔴 Every read and write of a player's save is one atomic "read the current value → decide → write back" operation. Reading first and writing later as two steps is not allowed.

#### Loading (when a player joins)

| State of the stored save | Action |
|---|---|
| No lock, or an expired lock | Write our own lock and take the save |
| Another server's unexpired lock | Give up; retry every 5 seconds, at most 6 times |
| Storage error | Same retries |
| Retries exhausted | Remove the player from the game with "Your save is still being written. Please rejoin in a moment." |

🔴 Until loading succeeds the player cannot join a round, buy, claim or redeem (`SaveDataNotLoaded`). 🔴 In no failure case is a fresh starting save used in place of the real one.

#### Writing

Each write first checks that the stored `sessionLockId` is still ours.

| Stored lock | Action |
|---|---|
| Ours | Write the save and set `lockRefreshedAtUnixSeconds` to now |
| Not ours (another server has taken over) | 🔴 Abandon the write, stop all further saving for this player, remove the player from the game. Unsaved in-memory progress is discarded and logged |

The final save (player leaving, server shutting down) clears `gameServerSessionLock` in the same write.

#### When saves happen

| Moment | Note |
|---|---|
| After any ledger grant or spend, and after any claim or redemption | A save is requested at once |
| After an appearance change (equip, lobby outfit) | No save is requested. The change is written by the next save of any kind |
| Every 120 seconds | Written even with no changes, to refresh the lock |
| Player leaves | Final save, hands the lock back |
| Server shuts down | Final save for everyone in parallel. Roblox allows 30 seconds |

🔴 **Spacing.** For one player, a save starts no sooner than `MINIMUM_SECONDS_BETWEEN_SAVE_STARTS = 10` seconds after that player's previous save started. A save requested earlier waits until then and writes whatever is in memory at that moment. Retries after a failure (2, 4, 8 seconds) and the final save are exempt. This caps the steady rate at 6 saves per player per minute regardless of what devices send.

#### Concurrency and failure

- 🔴 At most one save in flight per player. A request arriving meanwhile only records "save once more afterwards".
- 🔴 Unsaved work is tracked with revision numbers. Each in-memory change adds 1 to `inMemoryChangeRevision`. A save notes the revision when it **starts** and, on success, sets `lastSavedChangeRevision` to that noted value, not to the current one. While `inMemoryChangeRevision > lastSavedChangeRevision` another save is due. Changes made during a save are therefore never lost.
- On failure the save stays pending and is retried after 2, 4 and 8 seconds, three attempts per round of retries. If all fail, it waits for the next trigger.
- After a full round of failed retries `isSaveDataPersistenceDelayed` becomes true and the device shows "Progress can't be saved right now". Any successful save resets it.
- The final save is retried up to 5 times, then abandoned and logged; the lock then expires by itself.

### 3.5 Leaderboard sync

The leaderboard keeper holds `lastLeaderboardSyncedFanCount` in memory per online player.

| Moment | Action |
|---|---|
| After a player's save has loaded | Sync once from the loaded `fanCount`. This repairs the gap left if a previous server crashed after saving and before syncing |
| After each successful save | If the saved `fanCount` differs from `lastLeaderboardSyncedFanCount`, sync |
| Sync fails | No retry and no message to the player; compared again after the next successful save |

- 🔴 A leaderboard fault never blocks scoring, rewards or saving.
- 🔴 The keeper takes `fanCount` only from the "save succeeded" event, never from the latest in-memory value.
- 🔴 Each leaderboard write is one atomic operation that stores `max(value already stored, fanCount being written)`. Fans never decrease, so the larger value is always the newer one. A late write from an old server, completing after a newer server's write, therefore cannot move the leaderboard backwards.

### 3.6 Data store budgets (official limits, §8)

Default limits per server per minute: standard read and standard write `60 + players × 40` each; ordered write `30 + players × 5`; ordered list read `5 + players × 2`. The whole game also has a limit that scales with concurrent players: standard writes `300 + concurrent players × 20` per minute. An atomic read-modify-write uses one read and one write.

For a full 12-player server, per minute:

| | Expected | Hard ceiling from §3.4 spacing | Limit |
|---|---|---|---|
| Save operations | About 12: timed saves 6, round rewards about 3, purchases and claims a few | 72 (6 per player) | 540 |
| Leaderboard writes | About 3 | 72 (at most one per save) | 90 |
| Leaderboard list reads | 1 | 1 | 29 |

The ceiling holds whatever devices send, because appearance changes do not request saves, requests are rate-limited (§2.13) and save starts are spaced. Without the spacing, 12 players each changing something once a second would ask for 720 saves a minute against a limit of 540.

### 3.7 Dressing characters

- All avatars are R15.
- The server dresses a character by replacing its clothing, accessories, hair and makeup with the outfit; body shape and skin tone stay as the player's own.
- A styling item of kind `Bundle` is put on by applying every wearable asset the bundle contains, as resolved by `MarketplaceStylingItemResolver`. For shoes that is the left and the right shoe.
- 🔴 The appearance is built by starting from the character's currently applied appearance and replacing only clothing, accessories, hair and makeup. This is what keeps body parts, body colours and scale unchanged; the trial confirmed it after every step.
- 🔴 **Layering order.** Layered clothing gets an explicit order so that pieces do not swallow each other: shoes below dresses and bottoms, inner tops below jackets. The trial showed fur boots wrapping around a dress hem when ordered above it. Rigid accessories (hair, glasses, necklaces) must not be given an order at all: doing so makes the whole appearance fail to apply, with only a console warning.
- Makeup is applied as part of the same appearance, as a makeup entry carrying its asset id and type (face, lip or eye). It needs an R15 character whose head is a mesh head. ⚠️ Whether every player's avatar has one is not established (§8); on an avatar where it cannot show, the item still counts for scoring.

**Wardrobe preview.** Measured in Studio: an appearance applied by the server takes about 0.3–0.6 seconds to show on the device, and a device is not allowed to apply an appearance to its player's real character at all. So:

- 🔴 The wardrobe shows a **device-only copy** of the player's character, dressed on the device from the catalog snapshot (§2.14). The trial measured about 0.25 seconds per change this way. A short "updating" indication covers the wait.
- The player's real character is not touched during `Styling`. The server dresses it at the start of `Showcase` (§2.4) and for the lobby outfit (§2.7).
- The device preview and the server use the same rules above, so what the player previews is what the server later applies.
- A faster path exists (the server prepares each accessory once; the device attaches a copy in about 2 milliseconds) but was tried only with rigid hair, not with layered clothing. It is not used in Phases 1–2.

### 3.8 Dances

- Phases 1–2 ship with Roblox's own dance animations as starter and placeholder dances: animation ids `507771019`, `507776043` and `507777268`. They are created by Roblox and come from the default character animation script; in the trial each looped for 15 seconds with no visible jump at the loop point. They are short, 1–2 second loops, and look basic.
- Owner-made dances are added to `DanceCatalog` as they are produced; no code change is needed to add one.
- ⛔ No dance is named after a song, artist or idol.

---

## 4. Out of scope and known weaknesses for Phases 1–2

- Scoring can be solved (§0.2 B).
- Playtime rewards can be collected by an idle player. Accepted; the daily total is capped at 430 Star Coins.
- One person running several accounts. Not addressed.
- Ranks beyond the top 100.
- After a server crash a player waits up to 6 minutes for the lock to expire.
- Changing the schedule, themes, prices or promo codes requires publishing a new version of the game. Live editing without publishing is a later improvement.

---

## 5. Boundaries

### 5.1 Code

- ⛔ Device code never changes `fanCount`, `starCoinBalance` or ownership; they only arrive through `PlayerSaveDataSnapshotChanged`.
- ⛔ No Phase 3–4 code, and no empty placeholder modules for it, is written during Phases 1–2.
- ⛔ Nothing inside `claude-code-transferable-practices 2/` is changed.

### 5.2 Content

- ⛔ No models, textures or animations copied from other games or websites.
- ⛔ No Marketplace item carrying a real brand's logo or a real person's likeness enters the styling item pool unless it is that brand's official item.
- ⛔ No real idol or group names anywhere.
- ⛔ No animation uploaded by someone else. An animation plays in a game only when it belongs to the game's owner or to Roblox (§8, not yet confirmed from official text).
- ⛔ No dance that someone familiar with an existing choreography would recognise as that choreography. Learning a style's vocabulary and composing new sequences is fine. In 2025 the choreographer of the "Apple" dance sued Roblox over an emote sold in a dress-up game; the case settled.
- ⛔ No Toolbox model is added without inspecting every script in it.
- ⛔ No playable gambling of any kind, and no slot-machine, casino or betting imagery.
- ⛔ No random reward that can be obtained by paying Robux, directly or through anything bought with Robux.

### 5.3 Publishing tiers (Roblox rules, read 2026-11-19)

| Tier | Who it reaches | What it needs |
|---|---|---|
| Personal use | Only the creator | Nothing |
| 16+ and Trusted Friends | Age-checked players 16 and older | Age-checked account, at least 2 days old, in good standing |
| All ages | Includes under-16s | Everything above; ID verification (government ID for creators 18+); 2-step verification; a content rating of Minimal, Mild or Moderate; a fee or subscription; passing the evaluation |

**Evaluation.** The game is first available only to age-checked 16+ players. It becomes available to under-16s after a set number of "highly engaged" players have played within a 60-day window and a safety review has passed. A highly engaged player must meet requirements on account age, playtime in this game, and a purchase somewhere on Roblox in the last 60 days.

**The numbers move; the dashboard is the source of truth.**

- Entry threshold: **100** unique plays by highly engaged, age-checked players within 60 days, in the official documentation as last updated 2026-11-19 20:53 UTC. The same page said 250 earlier that day, and an official announcement shows 500 → 250 on 2026-08-19.
- Maintenance threshold: 25 highly engaged players to stay eligible.
- Actual figures and the game's own progress: Creator Hub → the game → Publish Settings → Manage Audience.
- 🔴 The number has changed twice in three months. Check it again before any launch decision.

**Fees (Robux, once per game).**

| Fee | Amount | What it does | Refund |
|---|---|---|---|
| Publishing fee | 1,000 | Satisfies "fee or subscription". An active Roblox Plus or Premium subscription held for 2 consecutive months also satisfies it | Two official pages disagree: one says refunded if the game keeps 25 highly engaged players for 60 days without moderation; the other says refunded automatically 90 days after becoming eligible, or 90 days after payment if never eligible. ⚠️ Go by what the payment page shows |
| Expedited review fee | 50,000 | Speeds up the safety and compliance review for a game that has not yet reached the highly-engaged threshold. The game must still meet the same standards; the documentation mentions a 48-hour review and resubmission if issues are found | Requestable after 90 days, if the game is in good standing and keeps 25 highly engaged players; otherwise the fee can be left in place to keep eligibility |

🔴 The expedited fee is not "pay to skip evaluation". It replaces the wait for player numbers; the safety review still happens and the refund is conditional.

⚠️ Decision 18 is the owner's. This document assumes "publish to 16+, go through the normal evaluation". Acceptance gates do not include all-ages publishing.

### 5.4 Random rewards

Roblox's rule, as read on 2026-11-19: a random reward given for an action that involves no payment of Robux or of currency bought with Robux needs no odds disclosure. A random reward paid for with Robux, directly or indirectly, must show every outcome with its exact odds and must be withheld from players in restricted regions.

Because Star Coins cannot be bought (decision 12), any random reward in this game stays in the first category. Phases 1–2 contain no random rewards at all; playtime milestones pay fixed amounts.

---

## 6. Tests and acceptance for Phases 1–2

### 6.1 Test environment

With data-store access switched on, Studio reads and writes the game's **real** data stores.

- 🔴 Two Roblox games are created: one for testing, one for release. Studio data-store access is switched on only for the test game.
- ⛔ Studio data-store access is never switched on for the release game.

### 6.2 Test list

| Type | Where | Run by | Covers |
|---|---|---|---|
| Unit: item-pool tool (Lune) | `tests/` | AI, after each change | Rejects unknown tags, duplicate keys, rows without a style tag, a `shoes` row that is not a `Bundle`, a non-shoes row that is not an `Asset`; derives `stylingItemKey`; generated module matches the CSV |
| Unit: outfit validity (Lune) | `tests/` | AI | Each of the five rules in §1.5, passing and failing; a shoes bundle counts as one item; an outfit containing a hidden item is invalid |
| Unit: scoring (Lune) | `tests/` | AI | The §1.6 worked example gives exactly 83 and 4 stars; each component at its minimum and maximum; a dress filling two slots; neutral colours ignored; empty outfit gets nothing; star boundaries at 39/40, 59/60, 74/75, 89/90 |
| Unit: round clock (Lune, fake clock) | `tests/` | AI | Phase order and durations; a new `roundId` each round; no theme repeated within 5 rounds; the clock runs with no participants |
| Unit: referee (Lune, fake clock) | `tests/` | AI | Each of the four checks in §2.3; two drafts arriving 0.1 seconds apart are both taken into account and the later one is scored; a waiting draft is processed at the end of `Styling` before scoring; a stale or duplicate sequence number is not processed twice; every processed draft is acknowledged; a late draft does not change the scored outfit; joining is refused when less than 60 seconds remain; a participant who leaves gets nothing |
| Unit: ledger (Lune, fake storage) | `tests/` | AI | For each operation in the §3.3 table: after a save failure or a crash injected at every possible point, the reloaded save holds either the reward together with its record or neither, and the operation cannot then be repeated for a second reward. Grants and spends change the right number; a spend that would go negative is refused; buying an owned item is refused and costs nothing |
| Unit: daily content (Lune, fake clock) | `tests/` | AI | Milestones cannot be claimed early or twice; progress resets when `dailyDateKey` changes; the same three quests for every player on a given date; quest progress counts only qualifying rounds |
| Unit: promo codes (Lune, fake clock) | `tests/` | AI | Case-insensitive match; before and after the validity window; second redemption refused; attempts faster than 2 seconds refused |
| Unit: archivist (Lune, fake storage and clock) | `tests/` | AI | A held lock makes loading wait and succeed after release; an expired lock is taken over; a write is abandoned once the lock is lost; a failed save stays pending and retries; a change made during a save is not lost; overlapping save requests do not run in parallel; a failed load never produces a starting save; a listener that modifies the snapshot it received does not affect the next listener or the keeper; an appearance change does not request a save; two save requests within 10 seconds produce save starts at least 10 seconds apart; retries and the final save ignore the spacing |
| Unit: leaderboard keeper (Lune, fake storage) | `tests/` | AI | No sync when the save failed; catch-up sync after loading; a failed sync does not affect rewards; two writes completing in the opposite order to which they were issued leave the larger value stored |
| Unit: wardrobe catalog and stored outfits (Lune, fake Roblox answers) | `tests/` | AI | The snapshot contains every available item and no hidden one; requests are rejected until the catalog is ready; a stored key that left the pool is removed from the save at load; a stored key that is only hidden this session is skipped when dressing and kept in the save; the unavailable keys are reported |
| Unit: appearance on spawn (Lune) | `tests/` | AI | The decision of what to apply for each player state in the §2.4 respawn table |
| Unit: request rate limiter (Lune, fake clock) | `tests/` | AI | A request inside the interval is refused and changes nothing; one at exactly the interval is accepted; limits are per player and per channel; a no-op request causes no revision bump |
| Unit: Marketplace item resolver rules (Lune, fake Roblox answers) | `tests/` | AI | An item is hidden when details fail, when not on sale, when not sellable in this game, when a bundle's contents fail; a bundle resolves to its asset list |
| Manual, test game, Studio single player | — | Owner | A full round; the results screen matches §1.6; balances survive leaving and immediately rejoining; buying and equipping a dance; claiming a milestone; redeeming a code |
| Manual, test game, Studio multi-player simulation | — | Owner | Two simulated players see each other's outfits and dances in the showcase; both appear on the leaderboard; dance sync works |
| Manual, real phone | — | Owner | The wardrobe is usable by touch; a round is completable on a phone |

Target: at least 80 unit tests across Phases 1–2.

🔴 Each unit test is first seen to fail by deliberately breaking the logic it covers, then the logic is restored. A test that has never failed does not count.

**Not tested, and why**

- Lock behaviour and save failures on real storage: real faults cannot be produced on demand; only fake storage is used. A difference between fake and real storage behaviour is not covered.
- A quick switch between two real servers: Studio cannot simulate two independent servers.
- Automated interface and end-to-end tests: Lune cannot run Roblox's interface.
- Load tests: there is no player base yet.
- Whether scoring feels fair or fun: only real players can show this.

### 6.3 Acceptance gates

**Phase 1 — playable internally**

| Gate | Criterion | Status |
|---|---|---|
| 1A | All Phase 1 unit tests pass, each seen to fail once | ⬜ |
| 1B | The owner's CSV with at least 30 real tagged items generates without errors | ⬜ |
| 1C | In the test game, a full round runs and the results screen matches §1.6 for the outfit worn | ⬜ |
| 1D | Rounds keep cycling for 30 minutes with no participants and no errors | ⬜ |
| 1E | After leaving and immediately rejoining, Star Coins, fans and round count are unchanged | ⬜ |
| 1G | A participant who resets their character during `Showcase` is back on the stage in the scored outfit, dancing, within 3 seconds; the score is unchanged | ⬜ |
| 1H | The wardrobe on the device lists exactly the items the server reports as available; an item made unavailable in the test pool does not appear | ⬜ |
| 1F | Two simulated players each finish a round; within 2 minutes of their saves succeeding both appear on the leaderboard with the same fan counts as their saves | ⬜ |

**Phase 2 — publishable**

| Gate | Criterion | Status |
|---|---|---|
| 2A | All Phase 2 unit tests pass, each seen to fail once | ⬜ |
| 2B | The styling item pool holds at least 200 enabled items covering all six scoring slots | ⬜ |
| 2C | A dance can be bought with Star Coins, equipped, and seen in the showcase | ⬜ |
| 2D | Tapping a dancing player syncs the dance without owning it | ⬜ |
| 2E | Playtime milestones, daily quests and a promo code can each be claimed once and not twice | ⬜ |
| 2F | In the published game, with Allow Third Party Sales on, a real purchase of one low-priced `Asset` item and one shoes `Bundle` completes: each item arrives in the buying account's inventory, and each sale appears in the game owner's sales records. Opening the prompt alone does not pass this gate | ⬜ |
| 2G | A round is completable by touch on a real phone | ⬜ |
| 2H | Published to the "16+ and Trusted Friends" tier | ⬜ |

---

## 7. Phases 3–4 (design level; not yet a contract)

Each of these gets its own section of engineering contract, in a later version of this document, before it is built.

### 7.1 Styling commissions (Phase 3)

A virtual client states a request ("I'm going on a beach date"). Behind it is a theme plus a fixed bonus rule. The player styles alone with no shared timer, submits, and is paid by score through the ledger as `StylingCommission`. Several commissions are on offer at once and refresh on a timer. It reuses the wardrobe, validity rules and scoring unchanged.

### 7.2 Virtual contestants (Phase 3)

When a round has fewer than a set number of human participants, the server fills the stage with system-generated contestants whose outfits are assembled from the styling item pool with a spread of quality. They are labelled as virtual, appear in results, and never appear on the leaderboard or receive rewards.

### 7.3 Robux-priced dances (Phase 3)

Premium dances sold for Robux. This needs purchase-receipt handling that grants each purchase exactly once even across retries and server changes; it builds on the save lock in §3.4.

### 7.4 Tournament (Phase 4)

Three rounds, each with a theme and a twist (for example half the styling time, or at most three colours). After each round the lower-scoring half is eliminated. It runs on a fixed timetable, every 30 minutes, with a countdown shown in the lobby. The winner receives a large Star Coin prize and an exclusive title. Virtual contestants fill empty places.

### 7.5 Schedule, limited-time and hidden content (Phase 4)

- **Schedule**: one configuration table of entries with a start and end time and a kind — theme rotation, Star Coin multiplier, limited dance availability.
- **Limited-time**: a weekly rotating theme set; weekend double Star Coins; a dance available only during its month.
- **Hidden**: posters in the lobby carrying promo codes; a secret client who appears only at certain hours and whose chain of five commissions rewards a dance obtainable no other way.

### 7.6 Later than Phase 4

Season pass, theme collection book, photo spot, player voting, team competition.

---

## 8. Fact check

| Fact | Source | Status |
|---|---|---|
| The game owner receives a 40% commission when a player buys a Marketplace avatar item inside the game | Official docs "Marketplace fees and commissions" | ✅ Read |
| A game's server can dress a player in Marketplace items the account does not own — rigid and layered, including items by other creators — with body and skin unchanged | Official docs "Avatar Editor Service", "Character appearance"; **trial 1 in Studio**: hair, jacket, dress, necklace, glasses, each reported not owned and each visibly worn | ✅ Run. In an unpublished place; re-check in the published game |
| Playable gambling is prohibited; "interactive slot machines" are named; unplayable gambling imagery restricts a game to 13+ | Official docs "Content ratings" | ✅ Read |
| Free random rewards need no odds disclosure; paid ones need exact odds and regional restriction | Official docs "Paid random items policy guidelines" | ✅ Read |
| Marketplace makeup can be applied from game code, as assets of type face, lip or eye makeup. No makeup-only bundles were found; the "makeup" bundles in catalog search are whole replacement heads and are excluded | Official reference `MakeupDescription`; **trial 1**: a lip makeup item visibly changed the lips | ✅ Run. Needs an R15 mesh head; whether every avatar has one is not established |
| Shoes on a mannequin must be set as a bundle "to include the right and left shoe" | Official docs "Homestore" | ✅ Read |
| Selling another creator's item in a game needs Allow Third Party Sales on, and the item's sale location must allow the game; otherwise users "can only see the added items, but can't purchase them" | Official docs "Homestore" | ✅ Read |
| For assets, product info reports `CanBeSoldInThisGame` and a sale-location type. For **bundles it reports neither**, nor price or on-sale status. Avatar item details report sale location and purchasability for both kinds | **Trial 1**. The enum page `ProductLocationRestriction` lists values 0–2 while the engine returned 5 ("shop and all experiences"); that page is out of date | ✅ Run. Checked against an unpublished place; re-check in the published game |
| A shoes bundle resolves to a left shoe, a right shoe and a non-wearable saved-outfit entry; applying the two shoes shows both. Bundles have their own purchase prompt and ownership check | Official references `AssetService`, `MarketplaceService`; **trial 1** | ✅ Run. Purchase prompt not exercised |
| An ordered data store supports an atomic read-modify-write (`UpdateAsync`) | Official docs "Data store error codes and limits" lists it for ordered data stores | ✅ Read. Not run |
| Only shoes need bundles | **Trial 1 and 4**: makeup items are single assets | ✅ Run, for the items tried |
| Publishing tiers, the 25 maintenance threshold, fees | Official docs "Roblox Kids and Select", "Publish games and places"; official forum announcement of 2026-08-19 | ✅ Read. Publishing-fee refund terms differ between two official pages |
| The entry threshold is 100 | Official docs "Roblox Kids and Select", page stamped 2026-11-19 20:53 UTC. The copy read at 03:02 UTC the same day said 250 | ✅ Read, twice; the two copies were compared |
| Leaving one server and joining another can read a stale save; Roblox recommends session locking | Official docs "Player data and purchasing systems" | ✅ Read |
| A server has 30 seconds to save at shutdown | Same | ✅ Read |
| Studio accesses the game's real data stores; use a separate test version | Official docs "Data stores" | ✅ Read |
| Data store per-minute limits | Official docs "Data store error codes and limits" | ✅ Read |
| The "Apple" dance lawsuit against Roblox, filed April 2025, settled September 2025 | Press reports (PC Gamer, Tubefilter) | ✅ Read as reported |
| The proposed motion-capture tool (RGB MoCap) is a native Windows application needing an NVIDIA GPU; it exports FBX and BVH but has no Roblox skeleton target | Its own README | ✅ Read |
| An open-source model it builds on (GVHMR) has a Colab demo, but outputs body parameters that need converting to an animation file | Search summary | 🟡 No verified end-to-end route found |
| Rules for playing an animation the game does not own | Official docs do not state the rule ("Asset privacy", "Animation editor", "Use animations" were read). **Trial 3**: Roblox-owned animations play in a place owned by nobody. An animation owned by a third party was not tried | 🟡 Roblox-owned: run. Third-party: not established; ⛔ still not used |
| Roblox's default dances `507771019`, `507776043`, `507777268` are created by Roblox and loop cleanly | **Trial 3**: creator read from product info; each played 15 seconds with pose changes at the loop point within normal frame-to-frame range. Ids come from the engine's default animation script, not from a documentation page | ✅ Run |
| Wardrobe change timing | **Trial 2**, in Studio on a local connection: server-applied 285–600 ms; a device may not apply an appearance to its own real character; on a device-only copy 229–307 ms; attaching a prepared accessory about 2 ms (rigid hair only) | ✅ Run. Real devices and real networks will be slower; not measured |
| Tests never wait: time and delayed work are injected and faked | Scaffolding slice; 41 tests | ✅ Resolved by design |
| Rojo 7.7.1 maps `.luau`, `.server.luau`, `.client.luau` to module, server and client scripts | Scaffolding slice: built and inspected | ✅ Run |
| String requires `./Sibling` and `../Folder/Module` resolve between modules in Roblox, in edit mode, on the server and on the client | **Trial 5** | ✅ Run. Folder-as-module (`init.luau`) not tried and not used |
| The 40% commission covers bundles and makeup | Official "Marketplace fees and commissions" lists makeup and shoes among sellable items and gives 40% to the game owner for in-game purchases, without naming bundles or makeup in the commission rule itself | 🟡 Likely; settled only by gate 2F |
| Tools installed on this machine and their versions | Version commands run on 2026-11-19 | ✅ Measured |

**The Phase 1 trials were run on 2026-11-19** in an unsaved Studio place, through the Studio MCP connection. Nothing was purchased, saved, published or uploaded. Raw output and 16 screen captures are kept outside the repository. Results are in the table above. The trials were:

1. Dress a character in five Marketplace asset items the test account does not own, in one shoes bundle (both shoes must appear), and in one makeup item. For each, read whether Roblox reports it as sellable in this game.
2. Measure how quickly a wardrobe change appears on the device.
3. Play two Roblox-owned dance animations on a character in a loop.

Outcome: clothing, shoes and makeup all work, so the six scoring slots stay and the design stands.

Still to be established, all of them only possible in the published game: that items report as sellable there, that a purchase completes, and that the commission arrives (gate 2F); timing on real devices (gate 2G).

---

## 9. What only the owner can do

| # | Task | Why the owner | Status |
|---|---|---|---|
| 1 | Check publishing eligibility at `create.roblox.com/settings/eligibility/publishing-permissions` | Needs the owner's login | ⬜ |
| 2 | Complete the account age check | Needs the owner's ID or face | ⬜ |
| 3 | Install the Rojo plugin in Roblox Studio | Done inside the owner's Studio | ⬜ |
| 4 | Create two Roblox games, test and release; switch on Studio data-store access only for the test one | Needs the owner's login | ⬜ |
| 5 | Decide the publishing tier (decision 18 in §0.3). The other decisions were confirmed with v1.0 | Product choice | ⬜ |
| 6 | Pick and tag Marketplace items: 30 for Phase 1, 200 for Phase 2. Only items on sale and sellable in all experiences; shoes as bundles (§1.2) | Taste and judgement | ⬜ |
| 6a | Switch on Allow Third Party Sales in both the test game and the release game | Needs the owner's login | ⬜ |
| 7 | Review the theme list (about 30); AI drafts it | Taste | ⬜ |
| 8 | Run the dance-capture trial: film 10 seconds, extract motion, convert in Blender, import into Roblox; AI writes the step-by-step guide | Needs the owner's body, camera and GPU access | ⬜ |
| 9 | Produce dances once the trial works | Same | ⬜ |

---

## 10. Revision record

### v1.1

Source: an external audit of spec v1.0 and of the code written so far, passed on by the owner on 2026-11-19. The audit changed no files.

| Audit finding | Verdict | How it was checked | Disposition | Where |
|---|---|---|---|---|
| P1 — the item model cannot represent a pair of shoes | Confirmed | Official "Homestore" page says shoes must be a bundle containing right and left; `OutfitValidator.luau` allows one `shoes` item and the model had only a single asset id | Adopted: assets and bundles distinguished; one bundle is one styling item; outfits become lists of `stylingItemKey` | §1.2, §1.5, §1.6, §2.3, §2.7, §2.12, §3.7 |
| P2 — save-event listeners share one mutable snapshot | Confirmed | Read `PlayerSaveDataKeeper.luau`: the caller makes one deep copy per event and `fireEvent` hands that same table to every listener. Not re-run here | Adopted as a hard constraint with a test | §3.3, §6.2 |
| P2 — "on sale" does not mean "buyable in this game" | Confirmed | Official "Homestore" page and `MarketplaceService` reference | Adopted: selection rule, run-time hiding, third-party-sales setting, gate 2F requires a completed purchase | §1.2, §2.12, §6.3, §9 |
| P2 — a late leaderboard write can overwrite a newer one | Confirmed by reasoning | Both writes carry values that were genuinely saved, so the v1.0 rule did not prevent it | Adopted: atomic keep-the-larger write, with an out-of-order test | §1.11, §3.5, §6.2 |
| P2 — saving on every equip change with no server rate limit | Confirmed | 12 players × 60 changes a minute = 720 against a limit of 60 + 12 × 40 = 540 | Adopted: appearance changes do not request saves, save starts spaced 10 seconds per player, per-channel rate limits, no-op requests ignored | §2.13, §3.4, §3.6, §6.2 |

**State of the code at the time of the v1.1 revision** (superseded — see the Status line at the top and the handoff note). Scaffolding was accepted (41 tests). The scoring/item-pool slice and the save/leaderboard slice were both stopped part-way at that time. They were later finished against v1.2 and v1.3 and accepted.

### v1.2

Source: a second external audit, of spec v1.1, passed on by the owner on 2026-11-19. The audit changed no files.

| Audit finding | Verdict | How it was checked | Disposition | Where |
|---|---|---|---|---|
| P1 — a reward and its claimed/redeemed/owned record are not required to be written together | Confirmed as a gap in the spec | v1.1 required a save after grants and claims but nowhere required the balance change and the record to be one change. The existing `PlayerSaveDataKeeper` already applies a change through a single non-yielding function, so the mechanism exists; the requirement did not. The audit's failure-injection reproduction was not re-run here | Adopted: hard constraint with a per-operation table and crash-recovery tests | §3.3, §6.2 |
| P2 — a correctly sent last draft can be silently dropped | Confirmed by reasoning | Device and server both used 0.5 seconds; network jitter can make two sends 0.5 seconds apart arrive closer together | Adopted: sequence number, acknowledgement, resend, a waiting place on the server instead of refusal, a defined cut-off | §2.3, §2.13, §6.2 |
| P2 — no contract for sending the server-filtered wardrobe to the device | Confirmed | §2 of v1.1 had no channel for available items, prices or bundle contents | Adopted: catalog snapshot, readiness, change notice, on-demand ownership | §2.14, §2.2, §2.7, §2.12, gate 1H |
| P2 — no rule for a stored outfit whose items became unavailable | Confirmed | §1.5 made such an outfit invalid while §2.4 required restoring it | Adopted: wear the available part; remove a key from the save only when the item left the pool | §1.5, §2.4, §2.6, §6.2 |
| P2 — respawn during the showcase is undefined | Confirmed | §2.4 dressed and placed characters only at the start of `Showcase` | Adopted: state-based re-application on every spawn | §2.4, §6.2, gate 1G |
| P2 — the publishing threshold is now 100 | Confirmed | The official page was downloaded again and compared with the copy from earlier the same day: 250 at 03:02 UTC, 100 at 20:53 UTC | Adopted: 100 everywhere, with the history and a reminder to re-check | §0.2, §5.3, §8 |

**New channels since the scaffolding was written.** `RoundOutfitDraftAcknowledged`, `RequestWardrobeCatalogSnapshot`, `WardrobeCatalogChanged`, `RequestStylingItemOwnership`. `src/shared/RemoteNames.luau` now lists all 21 (done in commit `0e7d0d5`).

### v1.3

Source: the Phase 1 trials, run in Roblox Studio by an engineer agent on 2026-11-19 and checked by the reviewer against the raw output and screen captures (baseline avatar, shoes, dress with shoes).

| Trial | Verdict | What changed in this document |
|---|---|---|
| 1 — wearing un-owned assets, a shoes bundle, makeup | Works | §8 facts; §1.2 sellability read from item details and asset types recorded; §3.7 dressing rules |
| 2 — how fast a change shows | Partly: no path is instant | §3.7 preview is a device-only copy; §2.14 snapshot carries asset types |
| 3 — Roblox-owned dances | Works | §3.8 ids filled in; `DanceCatalog` must use them |
| 4 — documentation questions | Makeup from code: yes. Animation ownership: docs silent. Commission on bundles and makeup: likely, unproven | §8 |
| 5 — string requires in Roblox | Works | §8 |
