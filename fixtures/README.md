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
  nalbinding/recipes/<name>.plynal               # craft acceptance fixture: a project with a recipe
  nalbinding/recipes/<name>.expect.json          # its oracle (each step's report, every issue)
  nalbinding/recipes/<name>.fixture.toml         # its record
  tablet/oracle/<name>.band.json                 # tablet weaving band: cards, starts, turning
  tablet/oracle/<name>.expect.json               # its oracle (every card at every pick, faces, twist)
  tablet/oracle/<name>.fixture.toml              # its record
  tablet/invalid/<name>.band.json                # a band with one defect
  tablet/invalid/cases.expect.json               # the diagnostics each one must give
  materials/materials.json                       # materials and swatches as Ply stores them
  materials/materials.expect.json                # their oracle: figures, diagnostics, estimates
  materials/diagnostics.json                     # records that cannot be true
  materials/materials.fixture.toml               # their record
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
| | `plyknit/schema-v2/` | `.plyknit` schema version 2, which no tagged release wrote (v0.1.7 wrote version 1); development builds from the envelope (ADR 0002) to before version 3 (ADR 0006) did. The bytes are copies of `knitting/repeats/` fixtures the engine's own writer produced, taken before the version 3 writer existed. Named by schema version, not app version, and each has a `.fixture.toml` record. |
| | `plyknit/schema-v3/` | `.plyknit` schema version 3 (the cast-on count), which no tagged release wrote either; development builds before version 4 (sections) did. Copies of `knitting/repeats/` fixtures the engine's own writer produced, taken before the version 4 writer existed, each with a `.fixture.toml` record. |
| | `plyknit/schema-v4/` | `.plyknit` schema version 4 (sections), which no tagged release wrote either; development builds before version 5 (sections in the round) did. Copies of three `knitting/sections/` fixtures and one `knitting/repeats/` fixture the engine's own writer produced, taken before the version 5 writer existed, each with a `.fixture.toml` record. |
| `.plynal` nalbinding project | `plynal/v0.1.7/` | `NalbindProject.toJson` + `jsonEncode` at `v0.1.7`, unchanged since `v0.1.0`. |
| | `plynal/schema-v2/` | `.plynal` schema version 2 (the inline version keys), which no tagged release wrote; development builds before version 3 (the recipe) did. Written by the version 2 model files at commit `2a23bae`, extracted with `git show` into a scratch Dart package, through their own `toJson` and `jsonEncode`. Each has a `.fixture.toml` record. |
| `<id>.json` sidecar (`DraftMeta`) | `sidecar/v0.1.7/` | `DraftMeta.toJson` + `jsonEncode` at `v0.1.7`, shaped as the weaving, knitting and nalbinding save paths of that release built it. |

Each `.plyknit` folder has:

- `sampler.plyknit`: what the app could create: built-in stitches including the newest one that
  release had, two custom cables (`2/2 RC`, `1/1 LC` with a purled strand), three-color colorwork,
  and repeat spans.
- `custom-ws-variant.plyknit`: an engine-level shape the app UI cannot create, kept so the migration
  of a custom stitch's `ws_variant` is exercised: one custom cable's WS variant names another custom,
  another's names a built-in. Worked in the round.

`plyknit/schema-v2/` instead holds three charts that exercise the version 2 to 3 migration (flat with
edge stitches, a first-row to-end repeat, a custom cable in the round), each with a
`<name>.fixture.toml` recording where the bytes came from and what the migration must produce.
`plyknit/schema-v3/` holds three charts for the version 3 to 4 migration (a stated cast-on, a fixed
repeat in the round, a custom cable in the round), recorded the same way. `plyknit/schema-v4/` holds
four files for the version 4 to 5 migration (three patterns with flat sections, including every
version-4 step kind and short rows, and a chart-only pattern in the round), recorded the same way.

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
| `weaving/doubleweave/` | Four-shaft plain-weave double weave in each construction: `independent-layers` (two shuttles, both edges open), `tube` (one shuttle, both edges joined, 11 ends), `double-width-fold-left` and `double-width-fold-right` (one shuttle, top, bottom, bottom, top). Written by the engine's double-weave generator with their pick roles, shuttles, starting sides and declared construction. Their oracles add the pass directions, every shuttle turn, the derived edges, and for double width the unfolded face, which must be plain weave. | `rust/ply-weave/tests/double_weave.rs`; `app/test/double_weave_construction_test.dart` |
| `weaving/looms/` | Loom feasibility: `looms.json` holds four invented loom profiles as Ply stores them (a four-shaft jack loom, a partial profile with only its shaft count, a metric countermarch loom, a table loom), recorded in `looms.fixture.toml`. Three drafts are checked against them: `eight-shaft-twill` (structurally valid, not feasible on four shafts and six treadles, not checked where the partial profile records nothing), `sinking-twill` (a sinking-shed tie-up: advice on a jack loom, how to tie the lamms on a countermarch), and `double-width-folded` (480 ends at 24 ends per inch, checked at its folded width in the reed). Each oracle lists every loom diagnostic of every check (code, severity, exact message) and the verdict, written by hand from the rules. | `rust/ply-weave/tests/loom_fixtures.rs`; `rust/ply-weave/src/loom_file.rs`; `app/test/loom_profile_test.dart` |

A generated fixture is regenerated only on purpose: if the generator's output changes, the test
fails, and the change has to be reviewed as a change to the cloth.

## `knitting/`

Craft acceptance fixtures for knitting: original charts, each with an oracle derived by hand (not
dumped from the code under test) and a record. Every fixture is three files with the same name:

- `<name>.plyknit`: the pattern, written by the engine's own `.plyknit` writer (a current-version
  envelope). The tests require that re-saving it gives the same bytes.
- `<name>.expect.json`: the oracle. Construction, chart width, the cast-on and its written line when
  the chart states one (absent = not stated), and for every row (row 1 first) the written instruction, the stitches it consumes and produces, how many times its to-end repeat is
  worked, and the expanded worked sequence as worked symbols (`null` where the row cannot be
  counted); then the validation issues, in order, with their exact messages.
- `<name>.fixture.toml`: the record. Title, technique, license, provenance, the conventions the
  written text follows (cited, never copied), and the verification status: `automated_checks` and
  `practitioner_knit_check` (`pending` until a knitter has worked or checked it).

| Folder | Contents | Tests |
|---|---|---|
| `knitting/repeats/` | Authored horizontal repeats: a simple fixed repeat (`seed-stitch-round`), edge stitches and RS/WS mirroring (`rib-edges-flat`), to-end repeats with an exact remainder (`rib-to-end-flat`), an invalid remainder (`rib-to-end-remainder-flat`), an unknown first-row count (`rib-cast-on-unknown-flat`) and the same chart counted from a stated cast-on (`rib-cast-on-flat`), lace balance and count growth (`eyelet-lace-round`), a cable inside and across a repeat edge (`cable-repeat-round`), and every refused repeat shape (`rejected-spans-round`). | `rust/ply-knit/tests/repeat_fixtures.rs`; `app/test/native_format_test.dart` |
| `knitting/sections/` | The construction layer (sections and the stitch ledger). On flat pieces: a shoulder sloped with wrap-and-turn short rows and then held (`shoulder-short-rows-flat`), a front neckline worked on held stitches with both sides and the neck edge returned to the needle and bound off (`neckline-hold-flat`), and a list of impossible or unfinished steps the ledger must name in plain words (`ledger-problems-flat`). In the round: a top-down sock with a heel flap, heel turn, gusset and grafted toe (`sock-heel-flap-round`), a sock with a German short-row heel (`sock-short-row-heel-round`), and every refusal of the steps for work in the round (`round-problems`). Each oracle gives the written instructions, every ledger line with its count (on the needle, still to work, waiting past a turn, wraps pending, each group on hold, bound off, side, and for work in the round: in the round, each needle group, worked flat, grafted) and the validation issues. | `rust/ply-knit/tests/section_fixtures.rs`; `app/test/knit_sections_fixture_test.dart`, `app/test/knit_sections_state_test.dart`, `app/test/knit_sections_screen_test.dart`, `app/test/knit_sock_sections_test.dart` |

## `materials/`

Materials and swatch records (shared by every craft), with an oracle worked out by hand from the
formulas and a record.

- `materials.json`: three invented materials and four invented swatches, as the engine's
  `materials.json` writer stores them. The tests require that re-saving it gives the same bytes.
- `materials.expect.json`: the oracle. Every figure Ply works out from each record (code, value,
  text) and every diagnostic (code, severity, field, and the message where it matters); the
  diagnostics of `diagnostics.json`; and five planning estimates worked out from the swatches (a
  knitting cast-on from a swatch and from a default, a weighed-swatch yarn estimate, a warp and a
  weft from a woven sample), each with every input's source and the sentence that cites it.
- `diagnostics.json`: records that cannot be true, which the engine names and refuses to store.
- `materials.fixture.toml`: the record. Sources, license, how the oracle was made, and the
  verification status, with a practitioner check per craft (`pending`).

| Folder | Contents | Tests |
|---|---|---|
| `materials/` | A DK wool, an 8/2 cotton and a material with only a name; a knitting swatch before and after washing (weighed), a woven towel sample on the loom, off it and after wet finishing, a nalbinding sample before and after fulling, and a lace swatch that grew by 60% when blocked (a warning). | `rust/ply-common/tests/materials_fixtures.rs`, `rust/ply-knit/tests/materials_estimates.rs`, `rust/ply-weave/tests/materials_estimates.rs`; `app/test/materials_fixture_test.dart` |

## `nalbinding/`

Craft acceptance fixtures for nalbinding: original projects with a structured recipe, each with an
oracle derived by hand (not dumped from the code under test) and a record. Every fixture is three
files with the same name:

- `<name>.plynal`: the project, written by the app's own `.plynal` writer (schema version 3). The
  tests require that re-saving it gives the same bytes, and the engine reads the same file.
- `<name>.expect.json`: the oracle. The project's stitch, the fit as written, and for every step
  (step 1 first) its kind, phase, part, stitch (where it comes from, the notation as written, how it
  is read, whether it was accepted), the stitch count after it from the recipe's own numbers (a
  number, `unknown`, `refused` or `not-applicable`), its written instruction, its target and whether
  Ply checked it; then every issue in order with its code, severity, place and exact text; and the
  steps ticked done.
- `<name>.fixture.toml`: the record. Title, technique, license, provenance, the conventions the
  recipe follows (cited, never copied), and the verification status: `automated_checks` and
  `practitioner_nalbind_check` (`pending` until a nalbinder has worked or checked it).

| Folder | Contents | Tests |
|---|---|---|
| `nalbinding/recipes/` | A mitten worked from the cuff with a thumb opening and a thumb picked up around it (`mitten-cuff-up`, two parts, no problems), a hat from a centre start at the crown (`hat-centre-start`, one count Ply cannot follow, two steps ticked done), every check a saved recipe can give (`recipe-problems`) and a recipe with no steps yet (`recipe-empty`). | `rust/ply-nalbind/tests/recipe_fixtures.rs`; `app/test/nalbind_recipe_model_test.dart`, `app/test/nalbind_recipe_fixture_test.dart`, `app/test/nalbind_recipe_backup_test.dart` |

## `tablet/`

Tablet (card) weaving fixtures for the `ply-tablet` engine, following the conventions of ADR 0018:
cards numbered from the weaver's left, corners named NT, FT, FB and NB as seen from the weaver's
right, a forward turn moving the top edge away from the weaver, S and Z by the thread's path, Z
twining counted positive. There is no native tablet file yet (`.plytab` comes with the editor), so a
band is stored in the engine's own band form: `<name>.band.json` is exactly what
`ply_tablet::TabletBand` reads and writes (palette as `#rrggbb`, each card's id, threads by hole
with all four keys `A` to `D` present and `null` for an empty hole, threading, start by corner
name; packs; the turning as segments of picks with one turn letter `F`, `B`, `I` or `?` per card,
the words for each `?`, and the flips and twist releases before a pick; warning settings). Card and
pack ids are 1 to 64 letters, digits, `-` or `_`, starting with a letter or digit. Unknown fields are
refused.

- `oracle/<name>.expect.json`: the oracle, transcribed from the hand-worked tables of ADR 0018 or
  worked by hand from its rules (never from the engine). For every card and pick: the action,
  threading, arrangement after the turn (`NT FT FB NB`), the hole and colour on the top face and on
  the back (`X continues` for an idle card whose float carries on, `X or Y` for an ambiguous idle,
  `X empty` with colour `none` for an empty hole), twining, reversal, `twist` and
  `woven`, and whether the card was released or flipped before the pick; the drawn faces, one string
  per pick with pick 1 first (top face card 1 at the left, back card 1 at the right; `?` for an
  ambiguous cell, `-` for an empty hole) and the stitch slants (`/` Z, `\` S, `|` idle); every
  diagnostic in order (code, severity, typed location); the final state.
- `oracle/<name>.fixture.toml`: the record. Title, technique, license, provenance, the conventions
  (cited, never copied), and the verification status: `automated_checks` and
  `practitioner_tablet_check` (`pending` until a tablet weaver has woven or checked it).
- `invalid/<name>.band.json`: one small band (two cards, two picks) with one defect each, and
  `invalid/cases.expect.json`, written by hand from the rules: for each file whether it is refused
  (with exactly which errors), simulates (with exactly which warnings), or cannot be read at all.
  Bands that would be large files (1,001 cards, 10,001 segments, oversized text, a pack listing more
  entries than a band can have cards) are built by the tests instead of stored.

| Folder | Contents | Tests |
|---|---|---|
| `tablet/oracle/` | `band-1-threaded-in`: 8 cards (S and Z), all at home, 4 forward, 4 backward, then two packs turned opposite ways; twist +4 and -4, 0, then +4 on every card; the colour doubled at each reversal. `sampler-2-starts-idles-flip`: 4 cards with a start one quarter on, the printed-face-right lettering, an idle on pick 1 (ambiguous faces), idles that lengthen floats on both faces, a twist release and a flip that unwinds twist to 0. `sampler-3-flip-then-opposite`: 4 cards worked by hand from the rules, with a flip followed by the opposite direction (no reversal), an idle right after a flip, a twist release, and an empty hole that crosses both faces and is a candidate of an ambiguous idle. | `rust/ply-tablet/tests/oracle_fixtures.rs` |
| `tablet/invalid/` | One case per structural error a small file can show: two diagonal holes on one edge, a repeated hole, a turn string one card short, an unknown letter, a `2` style half turn (pointed to `?`), `?` without words and words without `?`, words, a flip, a release or a pack naming an unknown card, one flip list naming a card twice, a colour past the palette, a segment repeated 0 times, repeats past the 200,000-pick cap and past `u32`, two cards with one id, a card id and a pack id outside the id grammar; a card in two packs and a card listed twice in one pack (warnings); an unknown field, a card without all four hole keys and an unknown threading letter (unreadable). | `rust/ply-tablet/tests/invalid_fixtures.rs` |
