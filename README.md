# k-idol

## Development

Tools are pinned in `rokit.toml` (Rojo 7.7.1, Lune 0.11.1, StyLua 2.6.0, selene 0.32.0).
Run `rokit install` once in this folder to get exactly these versions. All commands below
are run from the project root.

| Task | Command |
|---|---|
| Run every unit test (exits non-zero on any failure) | `lune run tests/RunAllTests.luau` |
| Lint | `selene src tests tools` |
| Format check | `stylua --check src tests tools` |
| Apply formatting | `stylua src tests tools` |
| Build a place file | `mkdir -p build && rojo build default.project.json -o build/idolgrow.rbxlx` |
| Live sync into Roblox Studio (not used in this project; see "Loading the project into Roblox Studio") | `rojo serve default.project.json` (needs the Rojo Studio plugin) |
| Regenerate the styling item pool after editing `data/styling-item-pool.csv` | `lune run tools/GenerateStylingItemPool.luau` |
| Repeat a failed randomized test run | `IDOLGROW_RANDOM_TEST_SEED=<seed from the failure> lune run tests/RunAllTests.luau` |

Styling item pool (`data/styling-item-pool.csv`, development spec §1.2): columns
`marketplaceItemKind,marketplaceItemId,itemSlot,styleTags,primaryColorTag,isEnabled`, one row per styling item.
`marketplaceItemKind` is `Asset` or `Bundle` (exact case); `shoes` rows must be `Bundle`, every other slot `Asset`.
`styleTags` holds one to three style tags; wrap it in double quotes when it has more than one (`"y2k, cute"`).
`isEnabled` is `true` or `false`. The tool prints every problem with its spreadsheet row number (header = row 1)
and writes nothing if there is any problem. Never edit `src/shared/generated/StylingItemPool.luau` by hand; a test
fails if it differs from what the tool generates from the CSV.

**Development placeholders in the pool.** The seven rows now in `data/styling-item-pool.csv` are a development
sample, not the owner's selection: Asset 7259123616 (hair), Asset 9122110415 (top), Asset 9438759973 (dress),
Asset 4378579302 and Asset 11884330 (accessory), Bundle 98186475028072 (shoes) and Asset 106390919006817
(makeup_lips). An engineer picked them because they were on sale and sellable in all experiences on 2026-11-19, and
chose their slots, style tags and colours; picking and tagging the real pool is the owner's call (spec §9 item 6).
They are enabled so the resolver can be exercised in Studio. Replace them before gate 2F. (The CSV format has no
comment syntax, so this paragraph is where they are marked.)

Conventions:

- File suffix decides the Roblox instance: `Name.luau` → ModuleScript, `Name.server.luau` → Script,
  `Name.client.luau` → LocalScript.
- Mapping (`default.project.json`): `src/server` → `ServerScriptService.Server`, `src/client` →
  `StarterPlayer.StarterPlayerScripts.Client`, and `src/shared` is mapped TWICE, as a sibling named
  `shared` (lower case) next to each side: `ServerScriptService.shared` and
  `StarterPlayer.StarterPlayerScripts.shared`. Roblox copies StarterPlayerScripts into each player's
  `PlayerScripts` at run time, so device code runs as `PlayerScripts.Client.Z` next to
  `PlayerScripts.shared`. Nothing is mapped into ReplicatedStorage (the remote channels folder
  `ReplicatedStorage.Remotes` is created at run time by the server). The two copies of a shared
  module are separate module instances (one per side, as server and device never share one
  anyway): shared modules must stay pure data and pure functions, holding no state that two
  sides or two server modules would need to share.
- Modules require each other with relative string paths: `require("./StylingTagVocabulary")` for a
  sibling, `require("../shared/ThemeCatalog")` from `src/server` or `src/client` into `src/shared`.
  Both resolve identically in Lune (relative to the file) and in Roblox (`"./"` starts at
  `script.Parent`, `"../"` at `script.Parent.Parent`), because each side has its own `shared`
  sibling. A shared module must never require `../server/...` or `../client/...`. Do not use
  `init.luau` folders or `@` aliases. `tools/SyncProjectIntoStudio.luau` prints a `WARNING` for any
  require that would not resolve in Roblox; today it prints none.
- `src/server/PromoCodeCatalog.luau` must never be mapped where a device can read it;
  `tests/server/PromoCodeCatalogServerOnlyPlacement.spec.luau` checks `default.project.json`.
- Tests are `*.spec.luau` files anywhere under `tests/`; the runner finds them automatically.
  Tests never wait: code under test receives "current time" and "do X after N seconds" as
  injected objects, and tests pass `tests/Support/FakeClock.luau` and `tests/Support/FakeScheduler.luau`.

## Loading the project into Roblox Studio

The Rojo Studio plugin is not used. `tools/SyncProjectIntoStudio.luau` turns the tree that
`default.project.json` describes into Luau "batches" that an agent with the Roblox Studio MCP
connection runs with its `execute_luau` tool, in Edit mode, in the open place. Nothing is saved or
published; Studio's HTTP access stays off. Procedure:

1. `lune run tools/SyncProjectIntoStudio.luau` (whole project), or
   `lune run tools/SyncProjectIntoStudio.luau --only Name1,Name2` (only those scripts, matched by
   instance name, plus every script they require **through a require that resolves inside
   Roblox**; a script whose requires are listed in a `WARNING` line is selected without the modules
   those requires name; a shared module's name selects both of its copies). The tool replaces
   `build/studio-sync/NN-*.luau` (`--output-folder <folder>` writes elsewhere; the tests use that)
   and prints the batch list, a `WARNING` for every require that will not resolve inside Roblox
   (none today), and the exact first line the last batch must answer with.
2. Run every listed batch, in file-name order, through `execute_luau` (Edit mode), pasting the file
   content unchanged. Each returns a report:
   - `00-install-runtime-and-read-manifest.luau` carries the sync runtime (tools/StudioSideProjectSyncRuntime.luau
     with its parts pasted in by tools/StudioSyncRuntimeBundler.luau) packed, unpacks it with
     `EncodingService`, refuses (installing nothing) unless it unpacks and its SHA-256 is the one the
     tool stamped into it, then compiles it with `loadstring` and installs it for this Studio session
     (as `_G.IdolgrowStudioProjectSyncRuntime`; it changes nothing in the place) and returns the
     place's script manifest. The later batches refuse to run until exactly this runtime is installed.
   - `NN-write-scripts-K-of-M.luau` creates or updates scripts and reports `created`, `updated`,
     `unchanged`, `replaced` (wrong class) and `removed duplicate`. Its sources travel packed
     (Zstandard + Base64, tools/StudioTransferTextPacker.luau), each distinct source once: both copies
     of a shared module come from one entry of the same batch.
   - `NN-remove-unexpected-and-verify.luau` removes the folders an earlier project file mapped
     (`RETIRED_PROJECT_FOLDERS` in the tool: today `ReplicatedStorage.Shared`, listed as `removed
     retired project folder ...`), creates empty folders, removes (and lists) everything in the four
     mapped folders that the project does not contain (including any instance whose name holds `/`,
     a tab or a line break), and checks the SHA-256 of every selected script. **Its first line must
     equal the line the tool printed**; for a full load today that is
     `remove unexpected instances and verify: sync complete, verified 180 of 180 selected scripts (180 project scripts in all)`
     (2026-11-20, after the Phase 2 device screens were added; 147 before them, 134 with the device side, 107 with the server only, 71 before ServerMain).
     A first line that says `sync complete` with smaller numbers means a partial load.
   - A write or verify batch whose payload (any path, class, packed source or expected script) was
     damaged on the way raises before changing anything: each carries the SHA-256 of its payload, and
     the runtime recomputes it in Studio, then checks each unpacked source against its own SHA-256.
3. After source files change (the shortest procedure): run the tool once, run only its batch 00 and
   save that batch's output (the manifest) to `build/studio-sync/studio-script-manifest.txt`; then run
   `lune run tools/SyncProjectIntoStudio.luau --studio-manifest build/studio-sync/studio-script-manifest.txt`
   and run its write batches and its last batch (its batch 00 is the same as the one just run unless a
   tool file changed in between; running it again is harmless). Only scripts that differ from Studio
   are written. A manifest read under another `default.project.json` must not be reused: the
   manifest names folders by their number in the mapping.

Running the batches again changes nothing and duplicates nothing. Studio receives each script with
its comment-only lines emptied (line numbers unchanged, so error lines match the files; code lines,
trailing comments and `--!` directive lines unchanged; a file with a long string, a `\`-continued
string or a `\z` escape is sent as is), because every byte passes through a tool call. A test checks
that every project script compiles to the same bytecode before and after.

Measured on 2026-11-19 for the whole project (71 scripts: 35 server, 18 shared twice): 8 batches,
120 KB in all (batch 00 7.7 KB; six write batches of 11.7 to 21.0 KB; the last batch 16.1 KB),
against 430 KB unpacked. The full load was run in Studio 0.748 that day, every batch pasted
unchanged, and its last batch answered `sync complete, verified 71 of 71`.

Require results in Edit mode are cached per ModuleScript for the whole Studio session, failures
included: a module that failed to load before a fix keeps answering "Requested module experienced
an error while loading" in Edit mode while its instance is kept (the sync keeps unchanged scripts).
Check requires on the server or client of a playtest, which starts from a fresh copy of the place.

## The game server (src/server/ServerMain.server.luau)

`ServerMain` is wiring only. It builds the Roblox-side parts (`RobloxServerClock`, `RobloxTaskScheduler`,
`RobloxServerLogger`, the storages, `RobloxMarketplaceItemLookups`, the remote channels, the stage, the
character presenter) and hands them to `ServerGameModuleAssembly`, which constructs and starts every rule
module in the order their headers require. The same assembly runs in Lune on fakes
(`tests/server/ServerGameAssemblyTestHarness.luau`), so whole rounds are tested without Roblox.

- **Storage.** `PlayerDataStorageSelectionRule` picks the in-memory development storages only when
  `RunService:IsStudio()` is true and `PlaceId`, `GameId` and `PlaceVersion` are all 0 (a never-published
  place); otherwise the real `RobloxPlayerSaveDataStorage` / `RobloxFanCountLeaderboardStorage`. The
  server then logs one loud warning `DEVELOPMENT STORAGE IN USE ... NOTHING IS SAVED`. In that mode no
  data store is ever opened.
- **Remote channels.** The server creates `ReplicatedStorage.Remotes` at start: one instance per channel of
  `RemoteNames`. `RemoteNames.REMOTE_CHANNEL_KIND_BY_REMOTE_CHANNEL_NAME` says how each travels and
  `ROBLOX_REMOTE_INSTANCE_CLASS_NAME_BY_REMOTE_CHANNEL_KIND` which class it is: every "device asks, server
  answers" channel is a `RemoteFunction` (device: `InvokeServer(payload)`, one answer table back);
  `SetRoundOutfitDraft` is a `RemoteEvent` the device fires; the five server-sent channels are
  `RemoteEvent`s the device listens to (`OnClientEvent`). Every device request is rate-limited exactly
  once (`DeviceRequestChannelAnswerRouter.DEVICE_REQUEST_ROUTES` says where). A module that raises is
  answered `{ isAccepted = false, rejectionReason = "RequestFailedOnServer" }` (not a spec reason).
- **Stage.** Built in code in `Workspace.ThemedRoundStage` (`ThemedRoundStageLayout`: 12 places north of
  the spawn, facing it). At Showcase each participant is dressed in the scored outfit, put on their place
  and dances their equipped dance; at the next phase they get their lobby appearance back and are put on
  the floor in front of the stage. A participant who dies on stage is respawned after 0.25 s instead of
  `Players.RespawnTime` (5 s), so gate 1G's 3 s can be met.
- **One owner of each character.** `RobloxCharacterShowcasePresenter` (one worker per player) is the only
  code that dresses a player's character, moves it, plays a dance on it or puts something above its head.
  `CharacterAppearanceAndStageDirector` decides every presentation (pure; see its header) and each one is
  COMPLETE: outfit, stage place, stage dance, lobby dance (`lobbyDance`), equipped Title and NameplateStyle,
  and, only for "Showcase began" on stage, the StageEntranceEffect to play once.
  `CharacterPresentationStepPlanner` (pure) turns a presentation into steps; an identical dance keeps
  playing. Never play an animation or parent anything to a character from another module: add it to the
  presentation instead.
- **Lobby dances (Phase 2, spec §2.8).** When `LobbyDanceCoordinator` changes a player's lobby dance state,
  the server plays (or stops) that dance on the character with priority Action, looped, and every device
  sees it (Animator replication). The track is moved to `LobbyDanceLoopTimePositionCalculator`'s position
  for the coordinator's `danceStartedAtUnixMilliseconds`, so a follower (who carries the leader's start
  moment) shows the leader's pose. The loop length is not in `DanceCatalog`: the server learns it from
  `AnimationTrack.Length` once the animation has loaded (measured 0.23-0.25 s on the first play; 0 before).
  Until then the dance plays from the start of its loop and jumps into time as soon as the length is known
  (at most 10 s; otherwise a warning and the dance stays out of time). Each start logs
  `RobloxCharacterDancePlayer: <id> aligned to <p> s of its <L> s loop (start moment <ms> ms ...)`. A respawn
  dances again with the same start moment. Going on stage ends the lobby dance (the coordinator); after the
  round the character does not dance. Joining a round does not end it (a Styling participant may dance).
- **Cosmetics (Phase 2, spec §1.7).** Generated in code from data in `src/shared/CosmeticPresentationCatalog`
  (titles: their display name), `NameplateStyleLookCatalog` and `StageEntranceEffectLookCatalog`; a test fails
  when a `CosmeticCatalog` cosmetic has no look or a look names something else. Only an equipped AND owned
  cosmetic of the right kind is shown. Above the head: `Head.IdolgrowOverheadCosmetics` (BillboardGui, 5 studs
  wide, `TitleLabel` and/or `NameplatePlate.NameLabel` with the player's display name); while a nameplate is
  shown the engine's own name display is off (`Humanoid.DisplayDistanceType = None`) so the name is not shown
  twice. Entrance effects are anchored, non-colliding parts and at most one light in
  `Workspace.StageEntranceEffects.StageEntranceEffect_<cosmeticId>`, removed after 2-6 s; every piece fades in
  and out once (no blinking). Nameplates are still images: nothing on them moves.

### What the Phase 2 device screens can rely on (no new channel was added)

- Who dances what: read the other characters' `Animator:GetPlayingAnimationTracks()` and compare
  `Animation.AnimationId` with `DanceCatalog` (a lobby or stage dance is the only Action-priority track the
  server plays). There is no message listing the lobby dancers (`LobbyDanceCoordinator:readEveryLobbyDancerState`
  exists but no channel sends it): a "tap a dancing player" screen must find dancers this way, or a channel
  must be added to the spec first.
- Equipped cosmetics of the local player: `equippedCosmeticIdByKind` in `PlayerSaveDataSnapshotChanged`.
  Shop previews can draw from the same shared look data (`CosmeticPresentationCatalog.findCosmeticPresentation`,
  `StageEntranceEffectPiecePlanner.planStageEntranceEffect`).
- A synced follower's dance is played by the server; the device plays nothing itself.

### Channels as they travel (device side)

| Channel | Kind | Device sends | Server answers / sends |
|---|---|---|---|
| RequestJoinCurrentRound | RemoteFunction | nothing | `{ isAccepted }` or `{ isAccepted=false, rejectionReason }` (§2.2) |
| SetRoundOutfitDraft | RemoteEvent (FireServer) | `{ roundId, outfitDraftSequenceNumber, outfitStylingItemKeys }` | acknowledgement on RoundOutfitDraftAcknowledged |
| RequestWardrobeCatalogSnapshot | RemoteFunction | nothing | `{ isAccepted=true, isWardrobeCatalogReady, wardrobeCatalogVersion, wardrobeItems }` (§2.14) |
| RequestStylingItemOwnership | RemoteFunction | `stylingItemKey` | `{ isAccepted=true, isOwnedByPlayer }`; reasons UnknownStylingItem, OwnershipCheckFailed, TooManyRequests |
| RequestFanCountLeaderboardTopEntries | RemoteFunction | nothing | `{ isAccepted=true, leaderboardEntries, refreshedAtUnixSeconds }` (nil before the first read) |
| SetLobbyOutfit | RemoteFunction | `{ outfitStylingItemKeys }` | §2.7 |
| RequestPurchaseDanceWithStarCoins / ...Cosmetic... | RemoteFunction | `danceId` / `cosmeticId` | §2.8 (+ SaveDataNotLoaded, TooManyRequests) |
| RequestEquipDance / RequestEquipCosmetic | RemoteFunction | `danceId` / `cosmeticId` | §2.8 |
| RequestStartDanceInLobby / RequestSyncDanceWithPlayer / RequestStopDanceInLobby | RemoteFunction | `danceId` / `targetPlayerUserId` / nothing | §2.8 |
| RequestClaimPlaytimeMilestone / RequestClaimDailyQuestReward | RemoteFunction | `milestoneMinutes` / `dailyQuestId` | `{ isAccepted=true, starCoinsGranted }` or §2.9 reasons |
| RequestRedeemPromoCode | RemoteFunction | `promoCodeText` | `{ isAccepted=true, starCoinsGranted }` or §2.10 reasons (TooManyAttempts) |
| RoundStateChanged | RemoteEvent (OnClientEvent) | — | `{ roundId, roundPhase, phaseEndsAtUnixMilliseconds, themeId, roundBonusRule, participantUserIds }` |
| RoundOutfitDraftAcknowledged | RemoteEvent | — | `{ roundId, outfitDraftSequenceNumber, isKept, rejectionReason? }` |
| RoundResultsPublished | RemoteEvent | — | `{ roundId, roundResults }` (§2.5 entries) |
| PlayerSaveDataSnapshotChanged | RemoteEvent | — | §2.6 message |
| WardrobeCatalogChanged | RemoteEvent | — | `{ isWardrobeCatalogReady, wardrobeCatalogVersion }` |

Seen by a device: on joining the server, RoundStateChanged (current phase) at once, then
PlayerSaveDataSnapshotChanged when the save has loaded, and WardrobeCatalogChanged when the catalog becomes
ready (a device that joins later must ask for the snapshot itself; nothing is re-sent). Events fired before
the device script connects are queued by Roblox and delivered when it connects. During a round: one
RoundStateChanged per phase; acknowledgements while Styling; at the start of Results first the
PlayerSaveDataSnapshotChanged carrying the reward, then RoundResultsPublished, then RoundStateChanged
(Results) — the device must not assume RoundStateChanged comes first. The snapshot also arrives once a
minute while playtime is counted.

### Running a playtest and driving the server from the client

Load the project (above), then start a playtest (`start_stop_play`). In the **Client** datamodel,
`execute_luau` can call the server like a device: `game.ReplicatedStorage.Remotes.RequestJoinCurrentRound:InvokeServer()`,
`Remotes.SetRoundOutfitDraft:FireServer({...})`, and connect `OnClientEvent` handlers that record into `_G`
(they persist between calls). In the **Server** datamodel, read the character (`GetAppliedDescription`,
`Animator:GetPlayingAnimationTracks`). A single `execute_luau` call times out after roughly 40 s; wait in
shorter calls. If the host computer sleeps, the playtest pauses and the round clock logs that it re-planned a
late phase (expected). Stop the playtest to return to Edit mode; the place keeps only the scripts.

## The device (src/client/ClientMain.client.luau)

`ClientMain` is wiring only: it waits for `ReplicatedStorage.Remotes`, builds the device's rule modules and
screens, connects the five server-sent channels, and renders the screens whenever something changes and
five times a second (countdown, wardrobe lock). Everything a player can see is decided in pure modules that
Lune tests (`tests/client/`); the `Roblox*`/`*View` files only create interface instances and copy a model
into them. Nothing on the device changes a balance or ownership (spec §5.1). Everything the player owns, has
equipped, has earned or has claimed is shown only from the latest `PlayerSaveDataSnapshotChanged`. The one
file that can ask the engine for a purchase prompt (`RobloxMarketplacePurchasePromptOpener`) is reached only
when `MarketplacePurchasePromptPermission` says yes, which it never does in Roblox Studio (see "Buy" below).

| Part | Pure rule module (tested) | Roblox-facing file |
|---|---|---|
| Round state, joining, wardrobe, drafts, results | `ThemedRoundDeviceSession` (uses `RoundOutfitDraftSender`, `WardrobeSelectionRules`, `RoundPhaseCountdownEstimator`, `ServerSentMessageShapeReader`) | — |
| What the round screens show | `ThemedRoundScreenModelBuilder`, `RoundResultsRowsBuilder`, `PlayerFacingTexts` | `RoundPhasePanelView`, `WardrobePanelView` |
| Wardrobe catalog (gate 1H) | `WardrobeCatalogView`, `WardrobeCatalogSnapshotRequester` | — |
| Wardrobe preview (§3.7) | `src/shared/CharacterOutfitAppearancePlanner` (the server's own rules) | `RobloxWardrobePreviewCharacter` |
| Star Coins, fans, save notices | `PlayerSaveDataStatusBarModel` | `StatusBarView` |
| Leaderboard (§1.11) | `FanCountLeaderboardRequester` | `LeaderboardPanelView` |
| Showcase camera | `ShowcaseAudienceCameraPlacement` | `RobloxShowcaseCameraDirector` |
| Keyboard (J join, L leaderboard, 1–9 wardrobe items; M lobby menu, 1–9 in the lobby outfit) | `DeviceKeyboardShortcutDecision`, `LobbyMenuNavigation` | `ClientMain` |
| Clock, scheduler, channels | — | `RobloxDeviceClockAndScheduler` (`Workspace:GetServerTimeNow`, `task.delay`), `RobloxDeviceRemoteChannels` |
| Phase 2 lobby: ties everything below together | `LobbyDeviceSession` (uses `LobbySaveDataSnapshotReader`, `DeviceLobbyRequestSender`, `LobbyRequestAnswerTexts`) | `LobbyScreensView` |
| Lobby menu (available unless a Styling or Showcase participant) | `LobbyMenuNavigation` | `LobbyMenuView` |
| Dances (§2.8) | `DanceLobbyPanelModelBuilder`, `LobbyDancerObservation` | `DanceLobbyPanelView`, `RobloxLobbyDancerReader` |
| Shop (§1.7, §2.8) | `ShopPanelModelBuilder`, `StageEntranceEffectPreviewDotPlanner` | `ShopPanelView`, `ShopItemPreviewView` |
| Daily rewards (§1.8, §2.9) | `DailyRewardsPanelModelBuilder`, `DailyQuestDescriptionTexts` | `DailyRewardsPanelView` |
| Promo codes (§2.10) | `PromoCodeRedeemForm` | `PromoCodePanelView` |
| Lobby outfit (§2.7) | `LobbyOutfitSelection` (with `WardrobeSelectionRules`) | `LobbyOutfitPanelView` (reuses `WardrobePanelView`) |
| Buy (§2.12) | `StylingItemOwnershipRequester`, `StylingItemPurchasePanelModelBuilder`, `MarketplacePurchasePromptPermission` | `StylingItemPurchasePanelView`, `RobloxMarketplacePurchasePromptOpener` |

- **Screens.** One `ScreenGui` named `IdolgrowDeviceScreens` (`ResetOnSpawn = false`, so a character reset
  keeps it) holds `StatusBar` + `Notices` (always), `RoundPhasePanel` (title, theme, bonus rule, countdown,
  notice, `JoinButton`, `JoinMessageLabel`, `ResultsList`), `WardrobePanel` (`Header`, `ItemList.SlotGroupN.Item_<stylingItemKey>`),
  `WardrobePreviewPanel.WardrobePreview` (ViewportFrame with the device-only copy) and `LeaderboardPanel`;
  Phase 2 adds `LobbyMenuButton`, `LobbyMenuPanel` (`Tabs.Tab_<panel>`, `Content_<panel>` for Dances, Shop,
  Daily, Codes, Outfit) and `StylingItemPurchasePanel` (under the preview). The lobby menu sits in the left
  column, where the round wardrobe is; it is hidden whenever the round wardrobe or the stage needs the screen.
  Built from plain instances by `DeviceInterfaceElementFactory`; no image or asset is used. Buttons are at
  least 52 px tall and act on `GuiButton.Activated` (touch, mouse, gamepad); nothing depends on hover.
- **Adding a screen.** Put what it shows in a pure builder (input: `session:readSessionSnapshot()` or another
  pure model; output: plain texts and flags), test it in `tests/client/`, then add a thin `*View` with
  `create(screenGui, callbacks)` and `render(model)` and call both from `ClientMain` (create once, render in
  `renderScreens`). Player actions go back through callbacks into the session, never into the view. A
  lobby panel is added the same way through `LobbyDeviceSession:readLobbyScreenModel` and `LobbyScreensView`.
- **Lobby requests (§2.13).** Every Phase 2 request goes through `DeviceLobbyRequestSender`: one request per
  channel at a time, the next one only after the channel's interval counted from the previous ANSWER (so the
  server never sees two of the device's requests closer than the interval, whatever the delay). A tap that
  comes too soon is not sent and is explained ("Please wait 2 seconds between tries."). Every answer and every
  rejection reason is explained by `LobbyRequestAnswerTexts`; a test fails when a server reason has no sentence.
- **Who is dancing.** No message says who dances in the lobby; `RobloxLobbyDancerReader` reads each character's
  playing animation ids and `LobbyDancerObservation` matches them with `DanceCatalog` (a Showcase participant
  is on stage, not in the lobby). The Dances panel offers "Dance with them" for every other player either way;
  the server's answer (`TargetNotDancing`, ...) is shown. A player playing a default emote whose animation is a
  starter dance's (the starter dances are Roblox's default dance animations) is shown as dancing it.
- **Playtime between snapshots (§2.9).** The server writes today's playtime about once a minute. The Daily panel
  shows the snapshot's playtime plus the time since it arrived, capped at 59 s, but offers "Claim" only when the
  snapshot itself has reached a milestone, so it never offers a claim the server refuses as `MilestoneNotReached`.
  The day end is midnight UTC; after it nothing is claimable until the new day's snapshot.
- **Buy (§2.12).** Selecting an item in a wardrobe asks `RequestStylingItemOwnership` (0.5 s rule) and again
  after a purchase prompt closes (`MarketplaceService.PromptPurchaseFinished` / `PromptBundlePurchaseFinished`).
  An item not owned shows "Buy for N Robux". 🔴 `MarketplacePurchasePromptPermission` answers no unless
  `RunService:IsStudio()` is exactly `false`; in Studio the panel says "Buying is switched off in Roblox Studio"
  and `RobloxMarketplacePurchasePromptOpener` (asset prompt for kind Asset, bundle prompt for kind Bundle,
  which itself also refuses in Studio) is never called. The game grants and stores nothing about a purchase.
- **Clock.** The countdown uses `Workspace:GetServerTimeNow()`; `RoundPhaseCountdownEstimator` additionally
  corrects a device clock that disagrees with the phase messages and clamps to [0, phase length].
- **One home for values both sides need** (`src/shared`): the §2.13 interval table
  (`RequestChannelMinimumIntervals`, the very table `PlayerRequestRateLimiter` enforces), the stage folder name
  (`ThemedRoundStageInstanceNames`) and the plan-to-HumanoidDescription writing
  (`CharacterAppearancePlanDescriptionWriter`, used by `PlayerCharacterDresser` and
  `RobloxWardrobePreviewCharacter`; it is given the engine's enums and `Instance.new`, so Lune tests it).

### Driving the device in a playtest

The screen GUI publishes what the device believes as attributes on `IdolgrowDeviceScreens`: `RoundId`,
`RoundPhase`, `IsParticipant`, `DraftSavingStatus`, `LatestSentOutfitDraftSequenceNumber`,
`SelectedStylingItemKeys`, `LastKeptStylingItemKeys`, `IsWardrobeUsableNow`, `ListedWardrobeItemCount`,
`LeaderboardRequestCount`, `WardrobeCatalogRequestCount`; Phase 2 adds `HasLobbySaveDataSnapshot`,
`LobbyRequestCount_<channel>`, `OwnershipRequestCount`, `LocalLobbyDanceId`, `IsRunningInStudio`,
`BuyButtonPressCount` and `PurchasePromptOpenCount` (stays 0 in Studio); `LobbyMenuPanel` has `IsOpen` and
`OpenPanelName`, shop cards have `ItemId`/`IsOwned`/`IsEquipped`, `StylingItemPurchasePanel` has
`StylingItemKey`/`IsBuyButtonVisible`; the preview's ViewportFrame has
`PreviewOutfitStylingItemKeys`, item buttons have `StylingItemKey`/`IsSelected`/`IsEnabled`, the round panel
has `ScreenName`. Read them from the **Client** datamodel with `execute_luau`; watch changes with
`GetAttributeChangedSignal` handlers stored in `_G` (they persist between calls).

- Press buttons with `user_mouse_input` and an `instance_path` such as
  `LocalPlayer.PlayerGui.IdolgrowDeviceScreens.RoundPhasePanel.JoinButton`. An item scrolled out of the
  `ItemList` is not clickable that way; use the keys 1–9 (`user_keyboard_input`) instead.
- Force a draft the interface cannot produce: fire `SetRoundOutfitDraft` with
  `LatestSentOutfitDraftSequenceNumber + 1` and an invalid outfit, then tap any item: the device sends that
  number, the server repeats its rejection, and the device puts the selection back.
- Screen captures (`screen_capture`) of the playtest view worked for one engineer (2026-11-20). For the next
  one, `screen_capture`, `user_mouse_input` and `user_keyboard_input` all timed out (2026-11-20, Phase 2
  work). In Studio only, every button made by `DeviceInterfaceElementFactory` also acts when its attribute
  `PlaytestActivationRequestCount` changes (same enabled check and callback as a tap), so from the **Client**
  datamodel `button:SetAttribute("PlaytestActivationRequestCount", n + 1)` presses it; a TextBox's `Text` can
  be set directly. Outside Studio the attribute does nothing. Never press `StylingItemPurchasePanel.BuyButton`.
- The Studio MCP plugin "resets" a camera type changed while one of its `execute_luau` calls runs (console:
  "The execute_luau changed camera type"). Avoid `execute_luau` calls that span a Showcase start or end; the
  camera director re-asserts the default camera for 3 s after Showcase for this reason.
