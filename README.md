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
| Live sync into Roblox Studio | `rojo serve default.project.json` (needs the Rojo Studio plugin) |
| Regenerate the styling item pool after editing `data/styling-item-pool.csv` | `lune run tools/GenerateStylingItemPool.luau` |
| Repeat a failed randomized test run | `IDOLGROW_RANDOM_TEST_SEED=<seed from the failure> lune run tests/RunAllTests.luau` |

Styling item pool (`data/styling-item-pool.csv`, development spec §1.2): columns
`marketplaceItemKind,marketplaceItemId,itemSlot,styleTags,primaryColorTag,isEnabled`, one row per styling item.
`marketplaceItemKind` is `Asset` or `Bundle` (exact case); `shoes` rows must be `Bundle`, every other slot `Asset`.
`styleTags` holds one to three style tags; wrap it in double quotes when it has more than one (`"y2k, cute"`).
`isEnabled` is `true` or `false`. The tool prints every problem with its spreadsheet row number (header = row 1)
and writes nothing if there is any problem. Never edit `src/shared/generated/StylingItemPool.luau` by hand; a test
fails if it differs from what the tool generates from the CSV.

Conventions:

- File suffix decides the Roblox instance: `Name.luau` → ModuleScript, `Name.server.luau` → Script,
  `Name.client.luau` → LocalScript. `src/shared` → `ReplicatedStorage.Shared`, `src/server` →
  `ServerScriptService.Server`, `src/client` → `StarterPlayer.StarterPlayerScripts.Client`.
- Modules require each other with relative string paths, e.g. `require("./StylingTagVocabulary")`
  for a sibling. The same line works in Lune (relative to the file) and in Roblox (relative to
  `script.Parent`). Do not use `init.luau` folders or `@` aliases in shared logic modules.
- Tests are `*.spec.luau` files anywhere under `tests/`; the runner finds them automatically.
  Tests never wait: code under test receives "current time" and "do X after N seconds" as
  injected objects, and tests pass `tests/Support/FakeClock.luau` and `tests/Support/FakeScheduler.luau`.
