# Test fixtures

Shared test data for the Rust engine and the Flutter app. Both test suites read these files in
place; nothing here is shipped in the app.

```text
fixtures/
  README.md                                      # this file
  migrations/<format>/<app-version>/<name>.<ext> # bytes exactly as a released version wrote them
```

More trees (craft acceptance fixtures, adversarial inputs) will be added under their own top-level
folders as later work needs them, following the same rules.

## Reading fixtures from tests

- Rust: `concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/...")` (crates live in `rust/<crate>/`).
- Flutter host tests: `../fixtures/...`, relative to `app/` (`flutter test` runs from the package
  root).

## Rules

1. **Original content only.** Every fixture is made for Ply's own tests. Never copy a pattern,
   draft, chart or text from a book, website, or another program. If a fixture recreates a
   published technique, describe the source in a note next to it; do not reproduce the source.
2. **Migration fixtures are immutable.** A file under `migrations/` records what a released version
   of Ply actually wrote. Never edit, reformat, or regenerate it. If a fixture is wrong, add a new
   one beside it and explain why.
3. **Produced by released code, not by hand.** Migration fixtures come from the release tag's own
   serializer (see below), so their bytes are real, including key order, number formatting and
   escaping.

## `migrations/`

| Format | Folder | What wrote it |
|---|---|---|
| `.plyknit` knitting pattern | `plyknit/v0.1.5/` | The `ply-knit` crate at tag `v0.1.5`. Its serializer and 12 built-in stitches are unchanged from `v0.1.0`, so these bytes stand for `v0.1.0` to `v0.1.5`. |
| | `plyknit/v0.1.6/` | `ply-knit` at `v0.1.6` (20 built-in stitches). |
| | `plyknit/v0.1.7/` | `ply-knit` at `v0.1.7` (21 built-in stitches). |
| `.plynal` nalbinding project | `plynal/v0.1.7/` | `NalbindProject.toJson` + `jsonEncode` at `v0.1.7`, unchanged since `v0.1.0`. |
| `<id>.json` sidecar (`DraftMeta`) | `sidecar/v0.1.7/` | `DraftMeta.toJson` + `jsonEncode` at `v0.1.7`, shaped as the weaving, knitting and nalbinding save paths of that release built it. |

Each `.plyknit` folder has:

- `sampler.plyknit`: what the app could create: built-in stitches including the newest one that
  release had, two custom cables (`2/2 RC`, `1/1 LC` with a purled strand), three-color colorwork,
  and repeat spans.
- `custom-ws-variant.plyknit`: an engine-level shape the app UI cannot create, kept so the migration
  of a custom stitch's `ws_variant` is exercised: one custom cable's WS variant names another custom,
  another's names a built-in. Worked in the round.

### How they were made

`.plyknit`: the release's Rust sources were extracted with `git archive <tag> rust` into a scratch
directory outside the repository, and a throwaway binary depending on that release's `ply-knit` by
path built the patterns above and wrote them with the release's own `KnitPattern::to_json`.

`.plynal` and sidecars: the release's model files were extracted with
`git show <tag>:app/lib/src/models/<file>.dart` into a scratch Dart package, and a throwaway script
wrote the values through the release's own `toJson` and `jsonEncode`, as its repositories did.
Timestamps are fixed values, not the time of generation.
