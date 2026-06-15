# Nalbinding engine design proposal (`ply-nalbind`, M6)

> **Status: M6 v1 BUILT + tested (2026-06-15).** Owner choices for M6 v1:
> (1) **scope = stitch reference + per-stitch visualization only** (no project/recipe model yet);
> (2) **visualization = tier B**, the per-stitch Hansen loop diagram generated from the notation;
> (3) **model depth = full Hansen grammar** (multi-turn, skipped loops, no-engage, twist,
> source-attributed multi-codes, description escape hatch); (4) **corpus = the ~12 curated stitches**
> below. Defaults confirmed: native JSON `.plynal`, a "Nalbinding" tab in the unified home, glossary
> gains nalbinding terms, no gauge/yardage calculator. This doc is the design rationale of record; it
> is research-backed (sources at the end).

## Goal & constraints

Add nalbinding as the third sibling engine `ply-nalbind`, reusing the proven shell (library, on-device
persistence, the frb bridge, the glossary). Inherited rules from `CLAUDE.md`: engine crates are
FFI-free and Flutter-free; coarse FFI (compute whole results per call); native format is JSON, app
DTOs live only in `ply-bridge`.

Nalbinding is the **most different** of the three crafts, and the model is almost entirely a design
choice because of three hard facts the research confirmed:

1. **No interchange standard and no digital tooling exist.** Weaving had WIF to pin its model; knitting
   had charts. Nalbinding has neither — patterns are shared as prose + stitch counts + fit ("go out
   until the circle is as round as your foot"). This is a genuine open niche, and it means we are not
   matching anyone's format; we are choosing one.
2. **It is not grid-based.** It is worked in a continuous **spiral** (no row boundary; a visible
   "step" where round 1 meets round 2). A new stitch connects in **two directions at once** (Hald's
   criterion): *vertically* into loop(s) of the previous round, and *laterally* into adjacent
   same-round loops. This dual interlooping is why nalbinding does not unravel when cut. The
   load-bearing representation is therefore a **node-graph** (each stitch a node; each connection an
   edge back to an earlier stitch's loops), not an `(x, y)` grid.
3. **Gauge is not a stable concept.** Stitches are sized by the maker's own thumb, so no two workers
   match. Sizing is by measurement/fit, not stitch count. So a "drawdown" and a gauge calculator (the
   anchors of the weave/knit engines) do not transfer; the analog deliverables are a **stitch
   reference** and a **structural visualization** (the ROADMAP's stated M6 scope).

## Hansen notation (the established stitch encoding)

Egon Hansen's 1990 notation describes **the path of the needle through the loops**, the work viewed
flat. It is the closest thing to a standard the craft has, so the model is built around it.

**The stitch string** is a sequence over this alphabet:

| Symbol | Meaning |
|---|---|
| `U` | needle passes **under** a loop |
| `O` | needle passes **over** a loop |
| `/`  | the **turn / return point** (thread reverses; divides the outbound thumb pass from the return pass) |
| `:`  | a **further** turn (2nd+ direction change) — so multi-turn stitches have `…/…:…` |
| `( )` | a **skipped** loop (exists in the structure, needle does not engage it), e.g. `U(U)O` |
| `-`  | **no** over/under on that pass (used by looping stitches like Coptic) |

The count of `U`/`O` is the number of loops engaged in that pass; it is **not fixed** (simple stitches
~5 symbols, complex ones much longer). The two sides of `/` are usually asymmetric (the return pass
engages one more loop), e.g. Oslo `UO/UOO`.

**The connection** anchors the new loop into the previous round, written as a side + a count:

| Marker | Meaning |
|---|---|
| `F` | join from the **front** (needle front→back) |
| `B` | join from the **back** (back→front) |
| `M` / `Mid` | join through the **middle** (less standardized) |
| number | **how many** previous-round loops the connection engages (`F2` = 1 new + 1 old loop → denser) |

A complete stitch is `<skeleton> <connection>`, e.g. **`UO/UOO F1`** (Oslo). Some sources *prefix* the
connection (`F1 UO/UOO`); multi-part connections concatenate (Åsle `U(U)O/UO:UOO B1 F1`).

A **parallel** community naming counts thumb-loop groups, `a+b(+c)`: Oslo = 1+1, Mammen = 1+2, Finnish
= 2+2, Russian = 2+2+2. This is **not** Hansen syntax but is used interchangeably, so we store it as an
alias.

### What the model must handle (notation realities from the research)

- **Identity is `(skeleton, connection)` together, not skeleton alone.** Mammen `UOO/UUOO F2` and
  Korgen `UOO/UUOO F1` are different named stitches differing only in the connection.
- **Hansen is lossy on connections.** The academic *Nålbinding Connections* survey documents 150+ real
  connection types vs Hansen's handful. We keep `F/B/M + count` as the modeled common case and reserve
  a **free-text/extensibility slot** for connections it can't express.
- **It does not capture twist / chirality**, and the same flat string can be physically mirrored — a
  separate `twist`/orientation attribute is needed, and the Hansen string is **not a unique key**.
- **Multi-turn stitches** (Åsle, Omani) have more than one turn, so a stitch's path is a **list of
  passes**, not a single binary front/back split.
- **Sources disagree on codes** (York is `F1` or `F2`; Dalby strings vary). Store **multiple
  source-attributed codes** per stitch, not one asserted canonical string.
- **Some stitches resist Hansen entirely** (a back-connected Danish variant). Provide a
  **description-only** escape hatch.

## Strawman data model (react to this)

```rust
// ply-nalbind/src/stitch.rs  — a stitch-DICTIONARY entry

/// One under/over pass of the needle. Simple stitches have 2 passes (split by `/`); multi-turn
/// stitches (Åsle, Omani) have 3+ (further `:` turns).
pub struct Pass { pub steps: Vec<Step> }
pub enum Step { Under, Over, SkippedUnder, SkippedOver, NoEngage /* `-` */ }

pub enum ConnSide { Front, Back, Middle }
pub struct Connection {
    pub side: ConnSide,
    pub count: u8,                 // F1, F2, ...
    pub extra: Option<String>,     // escape hatch for connections Hansen can't express
}

pub enum Twist { Untwisted, Twisted }

pub struct PublishedCode { pub code: String, pub source: String } // same stitch, differing sources

/// A stitch TYPE. Keyed on (passes, connection) TOGETHER. Hansen string is derived, not stored as id.
pub struct StitchType {
    pub name: String,                  // "Oslo"
    pub passes: Vec<Pass>,             // UO / UOO
    pub connection: Connection,        // F1
    pub thumb_loops: Option<(u8, u8)>, // the a+b alias (Oslo = 1+1)
    pub twist: Twist,
    pub also_known_as: Vec<String>,    // regional/alt names
    pub codes: Vec<PublishedCode>,     // source-attributed published strings
    pub note: String,                  // for description-only / Hansen-resistant stitches
}
```

```rust
// ply-nalbind/src/project.rs  — an optional PROJECT model (a worked piece), IF in M6 v1 scope

/// Garments are NOT one monotone spiral — they are an ordered sequence of shaping SEGMENTS
/// (disc → tube → short-row heel → tube → cuff), some worked back-and-forth.
pub enum SegmentKind { Disc, Tube, FlatPanel, ShortRow }
pub enum Shaping { Even, IncreaseEvery(u16), DecreaseEvery(u16), Custom(String) }

pub struct Segment {
    pub kind: SegmentKind,
    pub shaping: Shaping,
    pub rounds: Option<u16>,           // or a fit target in the unit
    pub note: String,
}

pub struct Project {
    pub name: String,
    pub stitch: StitchType,            // or a reference into a dictionary
    pub start: StartMethod,            // FoundationChain | CentreOut | ClosedRing
    pub segments: Vec<Segment>,
    pub notes: String,
}
```

A Hansen **parser/printer** (`U/O/(/):/-` + `F/B/M`+number → `Vec<Pass>` + `Connection`, and back) is
the one piece of "real engine logic" here, round-trippable and proptest-hardened like the WIF and
`.plyknit` parsers.

## Visualization options (the genuinely hard part)

The ROADMAP asks for a "simple structure visualization." Three tiers, increasing fidelity/effort:

- **A — Notation + glyph (minimal).** Render the Hansen string prettily plus a stylized loop icon.
  Cheapest; little structural insight.
- **B — Per-stitch loop diagram (Hansen-style).** Draw the thread path of one stitch as curving lines
  with explicit **over/under crossings** and the **F/B connection arrow**, generated from the notation.
  This is the authentic scholarly diagram and the analog of a weave "structure" cell — but the
  crossing geometry is fiddly to get right (and famously error-prone even in print; a generated-from-
  validated-data diagram is a real selling point).
- **C — Spiral/round node-graph schematic.** Draw stitches as nodes around the growing spiral edge
  with connection edges back to the previous round, highlighting where `F2` grabs two loops and where
  increases double-up / decreases skip. Visualizes **topology + shaping** without true 3-D. Needs the
  project model (B does not).

## Built-in stitch corpus (strawman set to ship)

Oslo `UO/UOO F1`, Mammen `UOO/UUOO F2`, Korgen `UOO/UUOO F1`, York/Coppergate `UU/OOO F2`, Finnish
`UUOO/UUOOO F2`, Russian `UUOOUU/OOUUOOO`, Dalby `UOU/OUOO F1`, Brodén `UOOO/UUUOO F1`, Åsle
`U(U)O/UO:UOO B1 F1`, Coptic `-/-O F1B1`, Danish `O/UO F1`, Saltdal `UUU/OOOU F1` — each with
source-attributed codes (sources disagree), the `a+b` alias, and a one-line description for the
glossary + reference screen.

## Owner decisions (the real ask)

1. **M6 v1 scope.** (a) **Stitch reference + per-stitch visualization only** (the ROADMAP MVP, matches
   how the craft is actually shared), or (b) **also the project/recipe model** (ordered stitches +
   shaping segments)? *Recommendation: (a) first; it is the high-value, tractable core, and (b) can
   follow.*
2. **Visualization tier.** A (notation + glyph), **B** (per-stitch Hansen loop diagram), or C (spiral
   node-graph, needs the project model)? *Recommendation: B — authentic and the true analog of the
   weave/knit structure view; flag the crossing-geometry effort.*
3. **Stitch-model depth.** Full Hansen grammar now (multi-turn `:`, skipped `( )`, `-`, twist,
   source-attributed multi-codes, description escape hatch), or a pragmatic subset (single-turn `F/B`
   + count) with the rest deferred? *Recommendation: full grammar in the model + parser (it is the
   durable part), even if the editor UI exposes a subset first.*
4. **Built-in corpus.** Ship the ~12 curated stitches above, a smaller starter set, or a larger
   catalog? *Recommendation: the ~12 above — broad enough to be useful, small enough to verify.*

**Sensible defaults I will assume unless you say otherwise:** native format JSON `.plynal` (consistent
with `.wif`/`.plyknit`); a "Nalbinding" tab added to the unified home; the glossary gains nalbinding
terms; **no gauge/yardage calculator** (gauge is unstable in this craft — a rough yardage-by-length
estimate could come later if wanted).

## Sources

Egon Hansen, *Nalebinding: definition and description* (1990); `en.neulakintaat.fi` (Hansen's notation
+ per-stitch pages); Wikipedia *Nålebinding*; `nalbinding.net`, `nalbound.com` (connections, shaping by
eye, starts/finishes); ShyRedFox / Väkerrystä (F1/B1 meaning); Andersson Lindberg, *Nålbinding
Connections* (the 150+ connection survey, limits of Hansen); Loopholes blog (Hald's dual-connection
criterion; Vandermonde crossing notation; the famous Coppergate F2/F3 diagram error); Shelagh Lewins
(sock/heel construction segments). Full URLs in the research notes.
