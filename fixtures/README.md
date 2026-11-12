# Test fixtures

Shared test data for the Rust engine and the Flutter app. Both test suites read these files in
place; nothing here is shipped in the app.

```text
fixtures/
  README.md                                      # this file
  migrations/<format>/<app-version>/<name>.<ext> # bytes exactly as a released version wrote them
  weaving/<technique>/<name>.wif                 # craft acceptance fixture: the draft itself
  weaving/<technique>/<name>.expect.json         # its structural oracle
  weaving/<technique>/<name>.fixture.toml        # its record: sources, license, verification
  knitting/<topic>/<name>.plyknit                # craft acceptance fixture: the chart itself
  knitting/<topic>/<name>.expect.json            # its oracle (written rows, counts, issues)
  knitting/<topic>/<name>.fixture.toml           # its record
```

More trees (adversarial inputs, other crafts) will be added under their own top-level folders as
later work needs them, following the same rules.

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

## `weaving/`

Craft acceptance fixtures: drafts a weaver could put on the loom, each with the oracle the tests
hold it to and a record of where it came from. Every fixture is three files with the same name:

- `<name>.wif`: the draft, as Ply writes it.
- `<name>.expect.json`: the structural oracle. Dimensions, tie-up, threading, treadling, thread
  roles (`D` dark, `L` light), the interlacement matrix and the color drawdown (one string per pick,
  pick 1 first, end 1 at the left), and any technique-specific map. When the fixture comes from a
  generator, the parameters that produce it.
- `<name>.fixture.toml`: the record. Title, technique, license, provenance, bibliographic sources
  (cited, never copied), and the verification status: `automated_checks` (what the tests prove) and
  `practitioner_weave_check` (`pending` until a weaver has woven or checked it on paper).

| Folder | Contents | Tests |
|---|---|---|
| `weaving/shadow/` | Authentic shadow weave: `aw2-atwater-4-point` (Atwater, 4 shafts, point of A2 B1 C1 D2) and `pw2-powell-8-point` (Powell, 8 shafts, point of A1 to H1). Original designs written by the engine's shadow-weave generator, one repeat each way. | `rust/ply-weave/tests/shadow_weave.rs` |

A generated fixture is regenerated only on purpose: if the generator's output changes, the test
fails, and the change has to be reviewed as a change to the cloth.

## `knitting/`

Craft acceptance fixtures for knitting: original charts, each with an oracle derived by hand (not
dumped from the code under test) and a record. Every fixture is three files with the same name:

- `<name>.plyknit`: the chart, written by the engine's own `.plyknit` writer (a current-version
  envelope). The tests require that re-saving it gives the same bytes.
- `<name>.expect.json`: the oracle. Construction, chart width, and for every row (row 1 first) the
  written instruction, the stitches it consumes and produces, how many times its to-end repeat is
  worked, and the expanded worked sequence as worked symbols (`null` where the row cannot be
  counted); then the validation issues, in order, with their exact messages.
- `<name>.fixture.toml`: the record. Title, technique, license, provenance, the conventions the
  written text follows (cited, never copied), and the verification status: `automated_checks` and
  `practitioner_knit_check` (`pending` until a knitter has worked or checked it).

| Folder | Contents | Tests |
|---|---|---|
| `knitting/repeats/` | Authored horizontal repeats: a simple fixed repeat (`seed-stitch-round`), edge stitches and RS/WS mirroring (`rib-edges-flat`), to-end repeats with an exact remainder (`rib-to-end-flat`), an invalid remainder (`rib-to-end-remainder-flat`) and an unknown first-row count (`rib-cast-on-unknown-flat`), lace balance and count growth (`eyelet-lace-round`), a cable inside and across a repeat edge (`cable-repeat-round`), and every refused repeat shape (`rejected-spans-round`). | `rust/ply-knit/tests/repeat_fixtures.rs`; `app/test/native_format_test.dart` |
