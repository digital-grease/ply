//! WIF (Weaving Information File) import/export.
//!
//! WIF is an INI-style text format — `[SECTION]` headers and `key=value` lines — and is
//! the universal weaving interchange standard (supported by essentially all weaving
//! software and computerized looms). See `docs/WIF_MAPPING.md` for the full mapping.
//!
//! v1 round-trips the common shaft-loom case: `WEAVING`, `THREADING`,
//! `TIEUP`+`TREADLING` or `LIFTPLAN`, `COLOR TABLE`, and `WARP`/`WEFT` default +
//! per-thread colors. Thickness, spacing, and non-0..255 palette ranges are parsed
//! leniently / defaulted (never panic) and are TODO for full fidelity.
//!
//! Per-pick roles (not part of WIF proper) live in Ply's WIF 1.1 private section
//! [`PICK_ROLES_SECTION`], tied to the cloth by a pick count and [`shed_fingerprint`] so a file
//! whose picks another program changed reads back with every role unknown (ADR 0008).

use crate::draft::*;
use crate::error::{Result, WeaveError};
use ply_common::{Color, Unit};
use std::fmt::Write as _;

// ---------------------------------------------------------------------------
// Tiny INI reader (WIF is INI with the 64K limit removed).
// ---------------------------------------------------------------------------

struct Section {
    name: String, // uppercased for matching
    entries: Vec<(String, String)>,
}

impl Section {
    fn get(&self, key: &str) -> Option<&str> {
        let lk = key.to_lowercase();
        self.entries
            .iter()
            .find(|(k, _)| k.to_lowercase() == lk)
            // Values are stored RAW (so `[NOTES]` keeps a line's leading whitespace); trim on access
            // for the numeric/keyword callers (Shafts, Range, Title, …) that expect a clean token.
            .map(|(_, v)| v.as_str().trim())
    }
}

struct Ini {
    sections: Vec<Section>,
}

impl Ini {
    fn parse(text: &str) -> Ini {
        let mut sections: Vec<Section> = Vec::new();
        for raw in text.lines() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with(';') {
                continue;
            }
            if let Some(rest) = line.strip_prefix('[') {
                let name = rest.split(']').next().unwrap_or("").trim().to_uppercase();
                sections.push(Section {
                    name,
                    entries: Vec::new(),
                });
            } else if let Some(eq) = line.find('=') {
                if let Some(sec) = sections.last_mut() {
                    // Trim the KEY but keep the VALUE raw so `[NOTES]` preserves a line's leading
                    // whitespace (the outer `line.trim()` still strips trailing whitespace).
                    sec.entries
                        .push((line[..eq].trim().into(), line[eq + 1..].into()));
                }
            }
        }
        Ini { sections }
    }

    fn section(&self, name: &str) -> Option<&Section> {
        let up = name.to_uppercase();
        self.sections.iter().find(|s| s.name == up)
    }
}

/// The most threads (ends/picks/treadles) a single section may declare. A guard against a malformed
/// WIF — an attacker-controlled `Threads=` count OR a sparse high numeric key like `4000000000=1`
/// would otherwise drive `vec![..; max]` into a multi-GB allocation that ABORTS the process (an
/// abort `catch_unwind` can't stop). 100,000 is far past any real draft (a wide fine-sett warp runs
/// a few thousand ends), and caps the worst-case bogus-file allocation at a few MB. The FFI bridge
/// applies the same per-axis cap to resize and structure generation. It bounds the DOCUMENT (which
/// is linear in ends + picks); the quadratic drawdown is bounded separately by
/// [`crate::RenderLimits`].
pub const MAX_THREADS: usize = 100_000;

/// Parse a numeric-keyed section (`1=3,5`) into a position-indexed `Vec<Vec<u16>>`
/// (1-based keys map to 0-based slots; gaps become empty lists). Length is capped at [`MAX_THREADS`]
/// and keys above it are ignored, so untrusted input can never request an unbounded allocation.
fn parse_indexed_lists(section: &Section, count_hint: usize) -> Vec<Vec<u16>> {
    let mut max = count_hint.min(MAX_THREADS);
    for (k, _) in &section.entries {
        if let Ok(i) = k.parse::<usize>() {
            if i <= MAX_THREADS {
                max = max.max(i);
            }
        }
    }
    let mut out = vec![Vec::new(); max];
    for (k, v) in &section.entries {
        if let Ok(i) = k.parse::<usize>() {
            if i >= 1 && i <= max {
                out[i - 1] = v
                    .split(',')
                    .filter_map(|t| t.trim().parse::<u16>().ok())
                    .collect();
            }
        }
    }
    out
}

/// Read a `[NOTES]` section. WIF stores free text as numbered lines (`1=first`, `2=second`);
/// collect them in numeric-key order and join with newlines. Comma-SAFE (unlike
/// `parse_indexed_lists`), so a note containing commas survives.
fn parse_notes(section: &Section) -> String {
    let mut lines: Vec<(usize, &str)> = section
        .entries
        .iter()
        .filter_map(|(k, v)| k.parse::<usize>().ok().map(|i| (i, v.as_str())))
        .collect();
    lines.sort_by_key(|(i, _)| *i);
    lines
        .into_iter()
        .map(|(_, v)| v)
        .collect::<Vec<_>>()
        .join("\n")
}

// ---------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------

/// Parse WIF text into a `Draft`.
pub fn parse(text: &str) -> Result<Draft> {
    let ini = Ini::parse(text);

    let weaving = ini.section("WEAVING");
    let shafts = weaving
        .and_then(|s| s.get("Shafts"))
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let treadles = weaving
        .and_then(|s| s.get("Treadles"))
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let rising = weaving
        .and_then(|s| s.get("Rising Shed"))
        .map(|v| matches!(v.to_lowercase().as_str(), "true" | "yes" | "1" | "on"))
        .unwrap_or(true);
    let shed = if rising {
        ShedType::Rising
    } else {
        ShedType::Sinking
    };

    let warp_sec = ini.section("WARP");
    let weft_sec = ini.section("WEFT");
    let warp_threads = warp_sec
        .and_then(|s| s.get("Threads"))
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(0);
    let weft_threads = weft_sec
        .and_then(|s| s.get("Threads"))
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(0);

    let unit = match warp_sec
        .and_then(|s| s.get("Units"))
        .map(|u| u.to_lowercase())
    {
        Some(u) if u.contains("cent") => Unit::Centimeters,
        _ => Unit::Inches,
    };

    // Threading
    let threading = Threading(
        ini.section("THREADING")
            .map(|s| parse_indexed_lists(s, warp_threads))
            .unwrap_or_default()
            .into_iter()
            .map(|v| v.into_iter().map(ShaftId).collect())
            .collect(),
    );

    // Drive. A WIF may ship a treadle loom's [TIEUP]+[TREADLING], a dobby's [LIFTPLAN], or — from some
    // exporters — BOTH. Choose by what actually carries data: prefer the authored tie-up + treadling
    // whenever the TREADLING has data. (The old code preferred ANY present [LIFTPLAN] and so silently
    // dropped the tie-up when both were present — the "import pasted the pattern into the treadling and
    // left no tie-up" bug.) Fall back to the liftplan only when there is no treadling data but a
    // [LIFTPLAN] section is present — even all-empty, since its rows still define the pick count via the
    // [WEFT] Threads recovery.
    let tieup = TieUp(
        ini.section("TIEUP")
            .map(|s| parse_indexed_lists(s, treadles as usize))
            .unwrap_or_default()
            .into_iter()
            .map(|v| v.into_iter().map(ShaftId).collect())
            .collect(),
    );
    let treadling = Treadling(
        ini.section("TREADLING")
            .map(|s| parse_indexed_lists(s, weft_threads))
            .unwrap_or_default()
            .into_iter()
            .map(|v| v.into_iter().map(TreadleId).collect())
            .collect(),
    );
    let treadling_has_data = treadling.0.iter().any(|r| !r.is_empty());
    let drive = if treadling_has_data || ini.section("LIFTPLAN").is_none() {
        Drive::Treadled { tieup, treadling }
    } else {
        Drive::Liftplan(Liftplan(
            parse_indexed_lists(ini.section("LIFTPLAN").unwrap(), weft_threads)
                .into_iter()
                .map(|v| v.into_iter().map(ShaftId).collect())
                .collect(),
        ))
    };

    // Colors. `[COLOR PALETTE] Range` (default 255) sets the color-table component scale; scale to
    // the model's 0..=255 so a non-standard range (e.g. 0..999) keeps its colors instead of clipping.
    let palette_range = ini
        .section("COLOR PALETTE")
        .and_then(|s| s.get("Range"))
        // WIF writes `Range` as a `min,max` PAIR (e.g. `0,999`); a few files give just the max. Take
        // the LAST comma component as the scale. A bare `parse::<u32>()` chokes on the comma, silently
        // falls back to 255, and then scale8 clips every 0..max component with `.min(255)` — washing
        // out bright colors and collapsing distinct light ones onto white (the import-color bug).
        .and_then(|v| v.rsplit(',').next()?.trim().parse::<u32>().ok())
        .filter(|&r| r > 0)
        .unwrap_or(255);
    let palette = ini
        .section("COLOR TABLE")
        .map(|s| parse_color_table(s, palette_range))
        .unwrap_or_default();
    let warp_default = warp_sec
        .and_then(|s| s.get("Color"))
        .and_then(parse_color_ref);
    let weft_default = weft_sec
        .and_then(|s| s.get("Color"))
        .and_then(parse_color_ref);
    let warp_colors = colors_for(ini.section("WARP COLORS"), threading.ends(), warp_default);
    let weft_colors = colors_for(ini.section("WEFT COLORS"), drive.picks(), weft_default);
    let colors = ColorPlan {
        palette,
        warp: warp_colors,
        weft: weft_colors,
    };

    let name = ini
        .section("TEXT")
        .and_then(|s| s.get("Title"))
        .unwrap_or("Untitled")
        .to_string();

    let notes = ini.section("NOTES").map(parse_notes).unwrap_or_default();

    // Per-thread thickness (relative). `[WARP/WEFT THICKNESS]` carries `index=value`; an absent
    // section stays EMPTY (the "uniform grid" convention) so equal-thickness drafts render plainly.
    let warp_thickness = thickness_for(ini.section("WARP THICKNESS"), threading.ends());
    let weft_thickness = thickness_for(ini.section("WEFT THICKNESS"), drive.picks());

    // Retain every section Ply does NOT model, verbatim, so `write` can re-emit it (spacing,
    // vendor sections). Section names are already uppercased by the Ini reader.
    const MODELED: &[&str] = &[
        "WIF",
        "TEXT",
        "CONTENTS",
        "WEAVING",
        "WARP",
        "WEFT",
        "COLOR TABLE",
        "COLOR PALETTE",
        "THREADING",
        "TIEUP",
        "TREADLING",
        "LIFTPLAN",
        "WARP COLORS",
        "WEFT COLORS",
        "NOTES",
        "WARP THICKNESS",
        "WEFT THICKNESS",
    ];
    // Ply's own private section (pick roles) is MODELED when this build can read its version; a
    // section from a NEWER Ply is kept verbatim like any unmodeled section, so re-saving here does
    // not destroy it (see `read_pick_roles`).
    let roles_section = ini.section(PICK_ROLES_SECTION);
    let roles_version = roles_section.map(pick_roles_version);
    let retained = ini
        .sections
        .iter()
        .filter(|s| !MODELED.contains(&s.name.as_str()))
        .filter(|s| s.name != PICK_ROLES_SECTION || roles_version == Some(RolesVersion::Newer))
        .map(|s| RetainedSection {
            name: s.name.clone(),
            entries: s.entries.clone(),
        })
        .collect();

    if shafts == 0 && threading.ends() == 0 {
        return Err(WeaveError::WifParse(
            "no recognizable draft data (missing WEAVING/THREADING)".into(),
        ));
    }

    let mut draft = Draft {
        name,
        shafts,
        treadles,
        shed,
        unit,
        threading,
        drive,
        colors,
        warp_thickness,
        weft_thickness,
        notes,
        retained,
        pick_roles: Vec::new(),
    };
    // Roles are checked against the cloth just parsed (pick count and per-pick raised shafts), so a
    // section another program carried over while it changed the picks is dropped, never misapplied.
    if let (Some(section), Some(RolesVersion::Current)) = (roles_section, roles_version) {
        draft.pick_roles = read_pick_roles(section, &draft);
    }
    // A dobby-style WIF (a [LIFTPLAN] with no tie-up) would otherwise show the whole lift pattern in
    // the treadling column with no tie-up. When the plan is simple enough to weave on a treadle loom,
    // factor it into the conventional tie-up + treadling (identical cloth); a too-complex plan stays a
    // liftplan. A treadled import is left untouched (factor_liftplan returns None for it).
    let factored = draft.factor_liftplan(MAX_FACTOR_TREADLES);
    Ok(factored.unwrap_or(draft))
}

/// Cap on the distinct lifts a `[LIFTPLAN]`-only WIF may have for import to factor it into a tie-up +
/// treadling (see [`Draft::factor_liftplan`]). Generous enough for hand-weaving (overshot, twills,
/// summer-and-winter all factor to a handful of treadles); a more complex dobby plan stays a liftplan.
const MAX_FACTOR_TREADLES: usize = 40;

// ---------------------------------------------------------------------------
// Pick roles: Ply's WIF 1.1 private section (ADR 0008)
// ---------------------------------------------------------------------------

/// The WIF 1.1 private section Ply stores per-pick roles in. WIF 1.1 reserves
/// `[PRIVATE <SourceID> <SectionName>]` for program-specific data ("A program that does not
/// recognize a private section skips it"); `PLY` is Ply's Source ID and stays fixed even if the
/// app is renamed, so files keep reading. Section names are matched case-insensitively (the INI
/// reader uppercases them).
pub const PICK_ROLES_SECTION: &str = "PRIVATE PLY PICK ROLES";

/// The layout version of [`PICK_ROLES_SECTION`] this build reads and writes.
pub const PICK_ROLES_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RolesVersion {
    /// [`PICK_ROLES_VERSION`]: read it.
    Current,
    /// A later Ply's layout: keep the section verbatim, read no roles from it.
    Newer,
    /// Missing or unreadable `Version`: no Ply build wrote it, so ignore and drop it.
    Unreadable,
}

fn pick_roles_version(section: &Section) -> RolesVersion {
    match section.get("Version").and_then(|v| v.parse::<u32>().ok()) {
        Some(PICK_ROLES_VERSION) => RolesVersion::Current,
        Some(v) if v > PICK_ROLES_VERSION => RolesVersion::Newer,
        _ => RolesVersion::Unreadable,
    }
}

/// The token a role is written as (lowercase; read case-insensitively).
fn role_token(role: PickRole) -> &'static str {
    match role {
        PickRole::Unknown => "unknown",
        PickRole::Pattern => "pattern",
        PickRole::Tabby => "tabby",
        PickRole::TopLayer => "top-layer",
        PickRole::BottomLayer => "bottom-layer",
    }
}

/// The role a token names. An unrecognized token is `Unknown`: never a guess.
fn role_from_token(token: &str) -> PickRole {
    match token.trim().to_ascii_lowercase().as_str() {
        "pattern" => PickRole::Pattern,
        "tabby" => PickRole::Tabby,
        "top-layer" => PickRole::TopLayer,
        "bottom-layer" => PickRole::BottomLayer,
        _ => PickRole::Unknown,
    }
}

/// A fingerprint of the draft's cloth along the weft: FNV-1a (64-bit) over, for each pick in order,
/// its raised shafts ascending and comma-separated, each pick followed by `;` (pick 1 raising shafts
/// 1 and 3 then pick 2 raising nothing hashes `"1,3;;"`), written as 16 lowercase hex digits. It is
/// computed from [`Draft::raised_shafts`], so it does not change when the same cloth is re-expressed
/// (liftplan or tie-up, either shed direction, a factored liftplan) but does change when any pick's
/// shed changes or picks are added, removed, or reordered. Roles are read back only when it matches.
pub fn shed_fingerprint(draft: &Draft) -> String {
    const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;
    let mut hash = OFFSET;
    let mut feed = |bytes: &[u8]| {
        for &b in bytes {
            hash ^= u64::from(b);
            hash = hash.wrapping_mul(PRIME);
        }
    };
    for pick in 0..draft.picks() {
        let mut raised: Vec<u16> = draft.raised_shafts(pick).iter().map(|s| s.0).collect();
        raised.sort_unstable();
        raised.dedup();
        for (i, s) in raised.iter().enumerate() {
            if i > 0 {
                feed(b",");
            }
            feed(s.to_string().as_bytes());
        }
        feed(b";");
    }
    format!("{hash:016x}")
}

/// Read a current-version [`PICK_ROLES_SECTION`] against the parsed `draft`. The section is used
/// only when its `Picks` count AND its `Sheds` fingerprint match the cloth; otherwise the picks were
/// changed by software that kept the section without understanding it, and the roles cannot be
/// trusted, so every role is Unknown (the section is dropped and not re-written). Keys are 1-based
/// picks (sparse: a pick not listed is Unknown); a key past the picks is ignored. A result with no
/// known role is empty (the "no roles recorded" convention).
fn read_pick_roles(section: &Section, draft: &Draft) -> Vec<PickRole> {
    let picks = draft.picks();
    let count_ok = section.get("Picks").and_then(|v| v.parse::<usize>().ok()) == Some(picks);
    let sheds_ok = section
        .get("Sheds")
        .is_some_and(|v| v.eq_ignore_ascii_case(&shed_fingerprint(draft)));
    if !count_ok || !sheds_ok {
        return Vec::new();
    }
    let mut roles = vec![PickRole::Unknown; picks];
    for (k, v) in &section.entries {
        if let Ok(i) = k.trim().parse::<usize>() {
            if (1..=picks).contains(&i) {
                roles[i - 1] = role_from_token(v);
            }
        }
    }
    if roles.iter().all(|&r| r == PickRole::Unknown) {
        Vec::new()
    } else {
        roles
    }
}

/// Parse a per-thread `[WARP/WEFT THICKNESS]` section (`index=value`) into a length-`n` `Vec<f32>`.
/// Returns EMPTY when the section is absent so the "all-default uniform" convention survives. A
/// thread missing from a present section defaults to the smallest specified value (so it renders at
/// the base width) rather than a fixed 1.0 that could dwarf real unit-based thickness values.
fn thickness_for(section: Option<&Section>, n: usize) -> Vec<f32> {
    let Some(s) = section else {
        return Vec::new();
    };
    let mut vals: Vec<Option<f32>> = vec![None; n];
    for (k, v) in &s.entries {
        if let Ok(i) = k.parse::<usize>() {
            if (1..=n).contains(&i) {
                if let Ok(t) = v.trim().parse::<f32>() {
                    if t.is_finite() && t > 0.0 {
                        vals[i - 1] = Some(t);
                    }
                }
            }
        }
    }
    let fallback = vals.iter().filter_map(|&x| x).fold(f32::INFINITY, f32::min);
    let fallback = if fallback.is_finite() { fallback } else { 1.0 };
    vals.into_iter().map(|x| x.unwrap_or(fallback)).collect()
}

fn parse_color_table(section: &Section, range: u32) -> Vec<Color> {
    // WIF color indices are 1-based; palette[0] corresponds to WIF index 1. Components are in
    // 0..=`range` (from `[COLOR PALETTE] Range`, default 255) and are scaled to the model's 0..=255.
    parse_indexed_lists(section, 0)
        .into_iter()
        .map(|rgb| {
            if rgb.len() >= 3 {
                Color::rgb(
                    scale8(rgb[0], range),
                    scale8(rgb[1], range),
                    scale8(rgb[2], range),
                )
            } else {
                Color::WHITE
            }
        })
        .collect()
}

/// Scale a `0..=range` color component into the model's `0..=255`, rounded. `range == 255` (or a
/// degenerate 0) is identity, so standard files are byte-for-byte unchanged.
fn scale8(v: u16, range: u32) -> u8 {
    if range == 255 || range == 0 {
        return v.min(255) as u8;
    }
    (((v as u32) * 255 + range / 2) / range).min(255) as u8
}

/// A `Color=` value in WARP/WEFT is a 1-based palette index; convert to 0-based.
fn parse_color_ref(v: &str) -> Option<ColorIndex> {
    v.split(',')
        .next()?
        .trim()
        .parse::<usize>()
        .ok()
        .map(|i| i.saturating_sub(1))
}

fn colors_for(section: Option<&Section>, n: usize, default: Option<ColorIndex>) -> Vec<ColorIndex> {
    let mut out = vec![default.unwrap_or(0); n];
    if let Some(s) = section {
        for (k, val) in &s.entries {
            if let (Ok(i), Ok(c)) = (k.parse::<usize>(), val.trim().parse::<usize>()) {
                if i >= 1 && i <= n {
                    out[i - 1] = c.saturating_sub(1);
                }
            }
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

/// Serialize a `Draft` to WIF text. Round-trips everything `parse` reads. WIF files
/// conventionally use CRLF line endings.
pub fn write(draft: &Draft) -> String {
    let mut o = String::new();
    let nl = "\r\n";
    macro_rules! line {
        ($($a:tt)*) => {{ let _ = write!(o, $($a)*); o.push_str(nl); }};
    }

    let liftplan = matches!(draft.drive, Drive::Liftplan(_));
    let unit = match draft.unit {
        Unit::Inches => "Inches",
        Unit::Centimeters => "Centimeters",
    };

    line!("[WIF]");
    line!("Version=1.1");
    line!("Developers=ply");
    line!("Source Program=Ply");
    line!("");

    // Embed the draft's name as the WIF Title so a written file is self-describing and the name
    // survives a write->parse round-trip (parse reads [TEXT] Title, defaulting to "Untitled").
    // Skip an empty name rather than emit a blank Title. (Author/notes live in the app sidecar,
    // not the engine Draft, so they are not written here.)
    if !draft.name.is_empty() {
        line!("[TEXT]");
        line!("Title={}", draft.name);
        line!("");
    }

    // Free-form notes round-trip as numbered `[NOTES]` lines (skip when empty, like Title).
    if !draft.notes.is_empty() {
        line!("[NOTES]");
        for (i, l) in draft.notes.split('\n').enumerate() {
            line!("{}={}", i + 1, l);
        }
        line!("");
    }

    // [CONTENTS] declares every section actually written, so a strict WIF reader knows what to find.
    line!("[CONTENTS]");
    if !draft.name.is_empty() {
        line!("TEXT=true");
    }
    if !draft.notes.is_empty() {
        line!("NOTES=true");
    }
    line!("COLOR PALETTE=true");
    line!("COLOR TABLE=true");
    line!("WEAVING=true");
    line!("WARP=true");
    line!("WEFT=true");
    line!("THREADING=true");
    if liftplan {
        line!("LIFTPLAN=true");
    } else {
        line!("TIEUP=true");
        line!("TREADLING=true");
    }
    line!("WARP COLORS=true");
    line!("WEFT COLORS=true");
    if !draft.warp_thickness.is_empty() {
        line!("WARP THICKNESS=true");
    }
    if !draft.weft_thickness.is_empty() {
        line!("WEFT THICKNESS=true");
    }
    // Ply's private pick-roles section is written only when some role is known. When it is, a kept
    // copy from a newer Ply (in `retained`) is replaced by it rather than written twice.
    let write_roles = draft.has_pick_roles();
    let retained: Vec<&RetainedSection> = draft
        .retained
        .iter()
        .filter(|s| !(write_roles && s.name.eq_ignore_ascii_case(PICK_ROLES_SECTION)))
        .collect();
    // WIF 1.1 lists private sections in [CONTENTS] as `PRIVATE <SourceID> <SectionName>=true`.
    if write_roles {
        line!("{}=true", PICK_ROLES_SECTION);
    }
    for sec in &retained {
        line!("{}=true", sec.name);
    }
    line!("");

    line!("[WEAVING]");
    line!("Shafts={}", draft.shafts);
    line!("Treadles={}", draft.treadles);
    line!("Rising Shed={}", matches!(draft.shed, ShedType::Rising));
    line!("");

    line!("[WARP]");
    line!("Threads={}", draft.ends());
    line!("Units={}", unit);
    line!("");
    line!("[WEFT]");
    line!("Threads={}", draft.picks());
    line!("Units={}", unit);
    line!("");

    // Declare the palette encoding explicitly so the file is self-describing: Ply's model is RGB
    // 0..=255, so a re-export normalizes any imported non-standard Range to 255 (the colors are
    // already scaled into 0..=255). Standard files are unaffected (Range was 255 to begin with).
    line!("[COLOR PALETTE]");
    line!("Entries={}", draft.colors.palette.len());
    line!("Form=RGB");
    line!("Range=255");
    line!("");

    line!("[COLOR TABLE]");
    for (i, c) in draft.colors.palette.iter().enumerate() {
        line!("{}={},{},{}", i + 1, c.r, c.g, c.b);
    }
    line!("");

    line!("[THREADING]");
    for (i, shafts) in draft.threading.0.iter().enumerate() {
        if !shafts.is_empty() {
            line!("{}={}", i + 1, join_ids(shafts.iter().map(|s| s.0)));
        }
    }
    line!("");

    match &draft.drive {
        Drive::Liftplan(lp) => {
            line!("[LIFTPLAN]");
            for (i, shafts) in lp.0.iter().enumerate() {
                if !shafts.is_empty() {
                    line!("{}={}", i + 1, join_ids(shafts.iter().map(|s| s.0)));
                }
            }
            line!("");
        }
        Drive::Treadled { tieup, treadling } => {
            line!("[TIEUP]");
            for (i, shafts) in tieup.0.iter().enumerate() {
                line!("{}={}", i + 1, join_ids(shafts.iter().map(|s| s.0)));
            }
            line!("");
            line!("[TREADLING]");
            for (i, treadles) in treadling.0.iter().enumerate() {
                line!("{}={}", i + 1, join_ids(treadles.iter().map(|t| t.0)));
            }
            line!("");
        }
    }

    line!("[WARP COLORS]");
    for (i, c) in draft.colors.warp.iter().enumerate() {
        line!("{}={}", i + 1, c + 1);
    }
    line!("");
    line!("[WEFT COLORS]");
    for (i, c) in draft.colors.weft.iter().enumerate() {
        line!("{}={}", i + 1, c + 1);
    }

    // Per-thread thickness (modeled): emit `index=value` only when set. `{}` on an f32 drops a
    // trailing `.0` (10.0 -> "10"), so the values round-trip stably through `thickness_for`.
    if !draft.warp_thickness.is_empty() {
        line!("");
        line!("[WARP THICKNESS]");
        for (i, t) in draft.warp_thickness.iter().enumerate() {
            line!("{}={}", i + 1, t);
        }
    }
    if !draft.weft_thickness.is_empty() {
        line!("");
        line!("[WEFT THICKNESS]");
        for (i, t) in draft.weft_thickness.iter().enumerate() {
            line!("{}={}", i + 1, t);
        }
    }

    // Pick roles (Ply private section, ADR 0008): the layout version, the pick count and shed
    // fingerprint they belong to, then one `pick=role` line per pick whose role is known (sparse: an
    // unlisted pick is Unknown). No value starts with `[`, as WIF 1.1 requires of private sections.
    if write_roles {
        line!("");
        line!("[{}]", PICK_ROLES_SECTION);
        line!("Version={}", PICK_ROLES_VERSION);
        line!("Picks={}", draft.picks());
        line!("Sheds={}", shed_fingerprint(draft));
        for (i, &role) in draft.pick_roles.iter().take(draft.picks()).enumerate() {
            if role != PickRole::Unknown {
                line!("{}={}", i + 1, role_token(role));
            }
        }
    }

    // Re-emit unmodeled sections kept verbatim on import (spacing, vendor sections), so a
    // structurally-edited re-serialize is no longer lossy for them. (A resize already dropped any
    // per-thread section whose axis changed — see `Draft::resized`.)
    for sec in retained {
        line!("");
        line!("[{}]", sec.name);
        for (k, v) in &sec.entries {
            line!("{}={}", k, v);
        }
    }

    o
}

fn join_ids(it: impl Iterator<Item = u16>) -> String {
    it.map(|n| n.to_string()).collect::<Vec<_>>().join(",")
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "\
[WIF]
Version=1.1
[WEAVING]
Shafts=4
Treadles=4
Rising Shed=true
[WARP]
Threads=4
Units=Inches
[WEFT]
Threads=4
[COLOR TABLE]
1=0,0,0
2=255,255,255
[THREADING]
1=1
2=2
3=3
4=4
[TIEUP]
1=1,2
2=2,3
3=3,4
4=1,4
[TREADLING]
1=1
2=2
3=3
4=4
[WARP COLORS]
1=1
2=1
3=1
4=1
[WEFT COLORS]
1=2
2=2
3=2
4=2
";

    #[test]
    fn parses_sample() {
        let d = parse(SAMPLE).unwrap();
        assert_eq!(d.shafts, 4);
        assert_eq!(d.treadles, 4);
        assert_eq!(d.ends(), 4);
        assert_eq!(d.picks(), 4);
        assert_eq!(d.colors.palette.len(), 2);
        assert!(matches!(d.shed, ShedType::Rising));
        match &d.drive {
            Drive::Treadled { tieup, .. } => {
                assert_eq!(tieup.shafts_for(TreadleId(1)), &[ShaftId(1), ShaftId(2)])
            }
            _ => panic!("expected treadled drive"),
        }
    }

    #[test]
    fn roundtrips_through_write_then_parse() {
        let a = parse(SAMPLE).unwrap();
        let text = write(&a);
        let b = parse(&text).unwrap();
        assert_eq!(a, b);
    }

    /// A non-default SINKING shed must survive write -> parse: `write` emits `Rising Shed=false` and
    /// `parse` reads it back. Every other round-trip fixture is Rising, so an always-write-Rising (or
    /// drop-on-parse) regression would otherwise be invisible. Pins the engine half of the m6 device
    /// shed assertion.
    #[test]
    fn sinking_shed_survives_wif_roundtrip() {
        let mut d = parse(SAMPLE).unwrap();
        d.shed = ShedType::Sinking;
        assert!(matches!(parse(&write(&d)).unwrap().shed, ShedType::Sinking));
    }

    /// Phase 5.2: a from-scratch draft's name (typed at the first-save prompt and propagated into
    /// the document) must be embedded as `[TEXT] Title` by `write` and read back by a reopen.
    /// Before this, `write` emitted no Title, so every reopened draft defaulted to "Untitled".
    #[test]
    fn draft_name_survives_wif_roundtrip_as_title() {
        let mut d = parse(SAMPLE).unwrap();
        d.name = "Ada's Scarf".into();
        let text = write(&d);
        assert!(
            text.contains("[TEXT]"),
            "a named draft writes a [TEXT] section"
        );
        assert!(text.contains("Title=Ada's Scarf"));
        assert_eq!(parse(&text).unwrap().name, "Ada's Scarf");
    }

    /// An empty name writes no `[TEXT]` section (nothing meaningful to embed); a reopen then falls
    /// back to the parse default "Untitled" rather than carrying a blank Title.
    #[test]
    fn empty_draft_name_writes_no_title_section() {
        let mut d = parse(SAMPLE).unwrap();
        d.name = String::new();
        let text = write(&d);
        assert!(!text.contains("[TEXT]"));
        assert_eq!(parse(&text).unwrap().name, "Untitled");
    }

    /// M3 2.1: multi-line `[NOTES]` (comma-bearing) survive write -> parse; before, `parse` hard-set
    /// notes to "" and `write` emitted nothing.
    #[test]
    fn notes_survive_wif_roundtrip() {
        let mut d = parse(SAMPLE).unwrap();
        d.notes = "Line one, with a comma.\nLine two.".into();
        let text = write(&d);
        assert!(text.contains("[NOTES]"));
        assert_eq!(
            parse(&text).unwrap().notes,
            "Line one, with a comma.\nLine two."
        );
    }

    /// A note line's LEADING whitespace survives the round-trip (values are stored raw; only the
    /// numeric/keyword getters trim). Trailing whitespace is normalized by the line-level trim.
    #[test]
    fn notes_leading_whitespace_round_trips() {
        let mut d = parse(SAMPLE).unwrap();
        d.notes = "  indented\nplain".into();
        assert_eq!(parse(&write(&d)).unwrap().notes, "  indented\nplain");
    }

    /// Empty notes write no `[NOTES]` section (like an empty Title).
    #[test]
    fn empty_notes_writes_no_notes_section() {
        let d = parse(SAMPLE).unwrap(); // SAMPLE has no [NOTES]
        assert_eq!(d.notes, "");
        assert!(!write(&d).contains("[NOTES]"));
    }

    /// M3 2.2: a non-default `[COLOR PALETTE] Range` scales the color table into the model's 0..=255
    /// instead of clipping; a re-export normalizes to Range=255 and the colors survive a round-trip.
    #[test]
    fn non_default_palette_range_scales_to_0_255() {
        let wif = "[WEAVING]\nShafts=1\nTreadles=1\n[THREADING]\n1=1\n\
                   [COLOR PALETTE]\nRange=999\nForm=RGB\n[COLOR TABLE]\n1=999,0,500\n";
        let d = parse(wif).unwrap();
        let c = d.colors.palette[0];
        assert_eq!((c.r, c.g, c.b), (255, 0, 128)); // 999->255, 0->0, round(500/999*255)=128
        let text = write(&d);
        assert!(text.contains("Range=255"));
        assert_eq!(parse(&text).unwrap().colors.palette[0], c); // colors survive the round-trip
    }

    /// WIF writes `[COLOR PALETTE] Range` as a `min,max` PAIR (`0,999`) — the common real-world form.
    /// Regression: the parser used to `parse::<u32>()` the whole `"0,999"`, fail on the comma, fall
    /// back to 255, and clip every 0..999 component — so two distinct light colors collapsed onto
    /// white (colors "lost"). The pair must scale by its MAX so imported colors are preserved.
    #[test]
    fn palette_range_pair_min_max_is_scaled_by_its_max() {
        let wif = "[WEAVING]\nShafts=1\nTreadles=1\n[THREADING]\n1=1\n\
                   [COLOR PALETTE]\nRange=0,999\nForm=RGB\n[COLOR TABLE]\n1=999,0,500\n2=600,600,600\n";
        let d = parse(wif).unwrap();
        // 999->255, 0->0, round(500/999*255)=128 — NOT the broken (255,0,255)-style clip.
        assert_eq!(
            (
                d.colors.palette[0].r,
                d.colors.palette[0].g,
                d.colors.palette[0].b
            ),
            (255, 0, 128)
        );
        // round(600/999*255)=153 — a mid grey that the clip bug would have flattened to white (255).
        assert_eq!(
            (
                d.colors.palette[1].r,
                d.colors.palette[1].g,
                d.colors.palette[1].b
            ),
            (153, 153, 153)
        );
    }

    const RETAIN_WIF: &str = "[WEAVING]\nShafts=2\nTreadles=2\n[WARP]\nThreads=2\n\
        [WEFT]\nThreads=2\n[THREADING]\n1=1\n2=2\n[TIEUP]\n1=1\n2=2\n[TREADLING]\n1=1\n2=2\n\
        [WARP SPACING]\n1=10\n2=10\n[ACME VENDOR]\nFoo=Bar\n";

    /// M3 2.3: an unmodeled per-thread section (`[WARP SPACING]`) and an unknown vendor section are
    /// retained verbatim and re-emitted by `write`, so a re-serialize is no longer lossy for them.
    /// (Thickness is now modeled, so spacing stands in as the still-unmodeled per-thread example.)
    #[test]
    fn unmodeled_sections_survive_wif_roundtrip() {
        let d = parse(RETAIN_WIF).unwrap();
        assert_eq!(d.retained.len(), 2);
        let text = write(&d);
        assert!(text.contains("[WARP SPACING]") && text.contains("[ACME VENDOR]"));
        assert!(text.contains("Foo=Bar"));
        assert_eq!(parse(&text).unwrap().retained, d.retained); // round-trips
    }

    /// A resize that changes the end count DROPS a per-thread `[WARP …]` section (its one-row-per-end
    /// data would desync) but KEEPS a global vendor section.
    #[test]
    fn resize_drops_stale_per_thread_retained() {
        let d = parse(RETAIN_WIF).unwrap();
        let r = d.resized(3, d.picks(), d.shafts, d.treadles); // grow ends 2 -> 3
        let names: Vec<&str> = r.retained.iter().map(|s| s.name.as_str()).collect();
        assert!(
            !names.contains(&"WARP SPACING"),
            "stale per-thread warp section dropped"
        );
        assert!(names.contains(&"ACME VENDOR"), "global vendor section kept");
    }

    /// M4 4.1: per-thread `[WARP/WEFT THICKNESS]` parse into the modeled fields (NOT `retained`),
    /// survive write -> parse, and a thread missing from a present section defaults to the smallest
    /// specified value (so it renders at base width, never dwarfing real unit-based values).
    #[test]
    fn thickness_parses_modeled_and_round_trips() {
        let wif = "[WEAVING]\nShafts=2\nTreadles=2\n[WARP]\nThreads=3\n[WEFT]\nThreads=2\n\
                   [THREADING]\n1=1\n2=2\n3=1\n[TIEUP]\n1=1\n2=2\n[TREADLING]\n1=1\n2=2\n\
                   [WARP THICKNESS]\n1=1\n2=3\n[WEFT THICKNESS]\n1=2\n2=2\n";
        let d = parse(wif).unwrap();
        // Modeled, not retained.
        assert!(
            d.retained.is_empty(),
            "thickness is modeled, not stuffed into retained"
        );
        // End 3 is absent from [WARP THICKNESS] -> defaults to the smallest present value (1).
        assert_eq!(d.warp_thickness, vec![1.0, 3.0, 1.0]);
        assert_eq!(d.weft_thickness, vec![2.0, 2.0]);
        // Round-trips through write -> parse.
        let rt = parse(&write(&d)).unwrap();
        assert_eq!(rt.warp_thickness, d.warp_thickness);
        assert_eq!(rt.weft_thickness, d.weft_thickness);
        assert!(write(&d).contains("[WARP THICKNESS]") && write(&d).contains("[WEFT THICKNESS]"));
    }

    /// A draft with no thickness sections keeps the EMPTY "uniform" convention (no 1.0 vectors
    /// materialized) and writes no `[*THICKNESS]` sections.
    #[test]
    fn absent_thickness_stays_empty_and_writes_nothing() {
        let d = parse(SAMPLE).unwrap();
        assert!(d.warp_thickness.is_empty() && d.weft_thickness.is_empty());
        let text = write(&d);
        assert!(!text.contains("THICKNESS"));
    }

    /// A WIF that ships BOTH a [LIFTPLAN] and an authored [TIEUP]+[TREADLING] keeps the tie-up: the
    /// old code preferred any present liftplan and dropped the tie-up (the import-loses-tieup bug).
    #[test]
    fn both_liftplan_and_treadling_keeps_the_authored_tieup() {
        let wif = "\
[WIF]
[WEAVING]
Shafts=4
Treadles=2
Rising Shed=true
[WARP]
Threads=4
[WEFT]
Threads=2
[THREADING]
1=1
2=2
3=3
4=4
[TIEUP]
1=1,2
2=3,4
[TREADLING]
1=1
2=2
[LIFTPLAN]
1=1,2
2=3,4
";
        let d = parse(wif).unwrap();
        match &d.drive {
            Drive::Treadled { tieup, treadling } => {
                assert_eq!(tieup.0.len(), 2, "the authored tie-up survives");
                assert!(tieup.0.iter().all(|t| !t.is_empty()));
                assert_eq!(treadling.0.len(), 2);
            }
            _ => panic!("a WIF with TIEUP+TREADLING data must import as treadled, not liftplan"),
        }
    }

    /// A dobby-style WIF (a [LIFTPLAN] with no tie-up) factors into the conventional tie-up +
    /// treadling on import — so it shows a tie-up instead of the whole pattern in the treadling.
    #[test]
    fn liftplan_only_wif_factors_into_a_tieup() {
        let wif = "\
[WIF]
[WEAVING]
Shafts=4
Treadles=0
Rising Shed=true
[WARP]
Threads=4
[WEFT]
Threads=4
[THREADING]
1=1
2=2
3=3
4=4
[LIFTPLAN]
1=1,2
2=3,4
3=1,2
4=3,4
";
        let d = parse(wif).unwrap();
        match &d.drive {
            Drive::Treadled { tieup, treadling } => {
                assert_eq!(tieup.0.len(), 2, "two distinct lifts -> two treadles");
                assert_eq!(treadling.0.len(), 4);
            }
            _ => panic!("a simple liftplan-only WIF should factor to a treadled draft"),
        }
        // Cloth is unchanged: the factored tie-up raises exactly the original lift sets.
        assert_eq!(d.raised_shafts(0), vec![ShaftId(1), ShaftId(2)]);
        assert_eq!(d.raised_shafts(1), vec![ShaftId(3), ShaftId(4)]);
        assert_eq!(d.raised_shafts(2), vec![ShaftId(1), ShaftId(2)]);
    }

    /// The editor's Treadled->Liftplan convert sets the draft structurally-dirty, so the NEXT save
    /// re-serializes the liftplan via `write` and a later open re-`parse`s it. A liftplan pick that
    /// raises NO shaft writes as an empty/absent row, so the pick count must survive via the
    /// `[WEFT] Threads=N` count, even when the empty picks are at the START, MIDDLE, or END (or the
    /// whole plan is empty). This pins that recovery so the convert-then-save-then-reload cloth
    /// stays byte-identical. (Companion to the device cloth-preservation test, which only covers the
    /// first round-trip.)
    #[test]
    fn liftplan_with_empty_picks_survives_wif_roundtrip() {
        // A sinking-shed draft: treadle 1 sinks ALL shafts (so the pick RAISES none -> empty row),
        // treadle 2 sinks only shaft 1 (raises 2,3,4). Pressing 1/2/1/2/1 puts an empty raised set
        // at picks 0 (start), 2 (middle), and 4 (end).
        let d = Draft {
            name: "empty-picks".into(),
            shafts: 4,
            treadles: 2,
            shed: ShedType::Sinking,
            unit: Unit::Inches,
            threading: Threading(vec![
                vec![ShaftId(1)],
                vec![ShaftId(2)],
                vec![ShaftId(3)],
                vec![ShaftId(4)],
            ]),
            drive: Drive::Treadled {
                tieup: TieUp(vec![
                    vec![ShaftId(1), ShaftId(2), ShaftId(3), ShaftId(4)], // treadle 1: sink all
                    vec![ShaftId(1)],                                     // treadle 2: sink shaft 1
                ]),
                treadling: Treadling(vec![
                    vec![TreadleId(1)],
                    vec![TreadleId(2)],
                    vec![TreadleId(1)],
                    vec![TreadleId(2)],
                    vec![TreadleId(1)],
                ]),
            },
            colors: ColorPlan {
                palette: vec![Color::WHITE, Color::BLACK],
                warp: vec![0, 0, 0, 0],
                weft: vec![0, 0, 0, 0, 0],
            },
            warp_thickness: Vec::new(),
            weft_thickness: Vec::new(),
            notes: String::new(),
            retained: Vec::new(),
            pick_roles: Vec::new(),
        };

        let lp = d.to_liftplan_draft();
        // Sanity: the convert really produced empty raised sets at the three boundary positions.
        assert!(
            lp.raised_shafts(0).is_empty(),
            "pick 0 raises nothing (start)"
        );
        assert!(
            lp.raised_shafts(2).is_empty(),
            "pick 2 raises nothing (middle)"
        );
        assert!(
            lp.raised_shafts(4).is_empty(),
            "pick 4 raises nothing (end)"
        );

        let rt = parse(&write(&lp)).unwrap();
        assert_eq!(
            rt.picks(),
            lp.picks(),
            "pick count survives (empty rows recovered via WEFT Threads)"
        );
        for p in 0..lp.picks() {
            assert_eq!(
                rt.raised_shafts(p),
                lp.raised_shafts(p),
                "pick {p} raised set preserved"
            );
        }

        // The degenerate all-empty plan (every pick presses the sink-all treadle) must still recover
        // its full pick count rather than collapsing to zero rows.
        let all_empty = Draft {
            drive: Drive::Treadled {
                tieup: TieUp(vec![vec![ShaftId(1), ShaftId(2), ShaftId(3), ShaftId(4)]]),
                treadling: Treadling(vec![
                    vec![TreadleId(1)],
                    vec![TreadleId(1)],
                    vec![TreadleId(1)],
                ]),
            },
            treadles: 1,
            colors: ColorPlan {
                palette: vec![Color::WHITE, Color::BLACK],
                warp: vec![0, 0, 0, 0],
                weft: vec![0, 0, 0],
            },
            ..d.clone()
        }
        .to_liftplan_draft();
        let rt2 = parse(&write(&all_empty)).unwrap();
        assert_eq!(
            rt2.picks(),
            3,
            "an all-empty liftplan still recovers 3 picks"
        );
        for p in 0..rt2.picks() {
            assert!(rt2.raised_shafts(p).is_empty(), "pick {p} stays empty");
        }
    }

    // --- Pick roles in Ply's WIF 1.1 private section (ADR 0008) ---

    /// The generated overshot, with its pattern/tabby roles.
    fn overshot_roles() -> Draft {
        crate::structure::overshot(16, 8, 4)
    }

    #[test]
    fn pick_roles_round_trip_in_the_private_section() {
        let d = overshot_roles();
        assert!(d.has_pick_roles());
        let text = write(&d);
        assert!(text.contains("[PRIVATE PLY PICK ROLES]"));
        assert!(
            text.contains("PRIVATE PLY PICK ROLES=true"),
            "listed in [CONTENTS] as WIF 1.1 specifies"
        );
        assert!(text.contains("Version=1\r\nPicks=8\r\nSheds="));
        assert!(text.contains("1=pattern") && text.contains("2=tabby"));
        let back = parse(&text).unwrap();
        assert_eq!(back.pick_roles, d.pick_roles);
        assert!(
            back.retained.is_empty(),
            "modeled, not kept as an unknown section"
        );
        assert_eq!(back, d, "the whole draft round-trips");
        // A second write is byte-identical (no duplicate section).
        assert_eq!(write(&back), text);
    }

    #[test]
    fn roles_are_sparse_and_written_only_when_some_role_is_known() {
        let mut d = parse(SAMPLE).unwrap();
        assert!(d.pick_roles.is_empty(), "a third-party WIF has no roles");
        assert!(
            !write(&d).contains("PRIVATE PLY"),
            "nothing known, nothing written"
        );
        d.pick_roles = vec![PickRole::Unknown; 4];
        assert!(
            !write(&d).contains("PRIVATE PLY"),
            "all-unknown writes nothing either"
        );
        d.pick_roles[2] = PickRole::BottomLayer;
        let text = write(&d);
        assert!(text.contains("3=bottom-layer"));
        assert!(!text.contains("1=unknown"), "unknown picks are not listed");
        let back = parse(&text).unwrap();
        assert_eq!(
            back.pick_roles,
            vec![
                PickRole::Unknown,
                PickRole::Unknown,
                PickRole::BottomLayer,
                PickRole::Unknown
            ]
        );
    }

    /// A Ply file opened and re-saved by software that keeps the private section but changes the
    /// picks: the roles no longer describe the cloth, so they are dropped (all Unknown), never applied
    /// to the wrong picks.
    #[test]
    fn roles_from_a_changed_cloth_are_dropped() {
        let text = write(&overshot_roles());
        // One more pick (WEFT Threads and a treadling line), section untouched.
        let grown = text
            .replace("[WEFT]\r\nThreads=8", "[WEFT]\r\nThreads=9")
            .replace(
                "8=4\r\n\r\n[WARP COLORS]",
                "8=4\r\n9=1\r\n\r\n[WARP COLORS]",
            );
        let g = parse(&grown).unwrap();
        assert_eq!((g.ends(), g.picks()), (16, 9));
        assert_eq!(
            g.raised_shafts(8),
            vec![ShaftId(1), ShaftId(2)],
            "the added pick"
        );
        assert!(g.pick_roles.is_empty(), "pick count changed: roles dropped");
        assert!(!write(&g).contains("PRIVATE PLY"), "and not written back");
        // Same count, one shed changed (pick 2 now presses the pattern treadle 1).
        let edited = text.replace("[TREADLING]\r\n1=1\r\n2=3", "[TREADLING]\r\n1=1\r\n2=1");
        assert_ne!(edited, text);
        assert!(
            parse(&edited).unwrap().pick_roles.is_empty(),
            "sheds changed: dropped"
        );
        // A re-expression of the SAME cloth keeps them: the fingerprint reads raised shafts.
        let lp = overshot_roles().to_liftplan_draft();
        assert_eq!(
            parse(&write(&lp)).unwrap().pick_roles,
            overshot_roles().pick_roles
        );
    }

    #[test]
    fn a_liftplan_only_import_keeps_roles_through_factoring() {
        let lp = overshot_roles().to_liftplan_draft();
        let back = parse(&write(&lp)).unwrap();
        assert!(
            matches!(back.drive, Drive::Treadled { .. }),
            "factored on import"
        );
        assert_eq!(back.pick_roles, overshot_roles().pick_roles);
    }

    #[test]
    fn a_newer_roles_section_is_kept_verbatim_and_unread() {
        let newer = format!(
            "{SAMPLE}[PRIVATE PLY PICK ROLES]\nVersion=2\nPicks=4\nShuttles=a,b\n1=pattern\n"
        );
        let d = parse(&newer).unwrap();
        assert!(d.pick_roles.is_empty(), "this build cannot read version 2");
        assert_eq!(d.retained.len(), 1, "kept so a re-save does not destroy it");
        let text = write(&d);
        assert!(text.contains("Version=2") && text.contains("Shuttles=a,b"));
        // Once this build records roles of its own, its section replaces the kept one.
        let mut d2 = d.clone();
        d2.pick_roles = vec![PickRole::Pattern; 4];
        let text2 = write(&d2);
        assert_eq!(text2.matches("[PRIVATE PLY PICK ROLES]").count(), 1);
        assert_eq!(text2.matches("PRIVATE PLY PICK ROLES=true").count(), 1);
        assert!(text2.contains("Version=1") && !text2.contains("Version=2"));
        // An unreadable (versionless) section is ignored and dropped.
        let junk = format!("{SAMPLE}[PRIVATE PLY PICK ROLES]\n1=tabby\n");
        let j = parse(&junk).unwrap();
        assert!(j.pick_roles.is_empty() && j.retained.is_empty());
    }

    #[test]
    fn other_programs_private_sections_are_untouched() {
        // Another program's private section is an ordinary unmodeled section: kept verbatim.
        let other = format!("{SAMPLE}[PRIVATE WEAVEIT AWESOME]\nSparkles=1\n");
        let d = parse(&other).unwrap();
        assert_eq!(d.retained.len(), 1);
        assert!(d.pick_roles.is_empty());
        assert!(write(&d).contains("[PRIVATE WEAVEIT AWESOME]"));
        // Section and token matching is case-insensitive, like the rest of WIF.
        let mut text = write(&overshot_roles())
            .replace("[PRIVATE PLY PICK ROLES]", "[private ply pick roles]");
        text = text.replace("1=pattern", "1=PATTERN");
        assert_eq!(
            parse(&text).unwrap().pick_roles,
            overshot_roles().pick_roles
        );
    }

    #[test]
    fn shed_fingerprint_follows_the_documented_recipe() {
        // Two picks: raise 1 and 3, then nothing -> FNV-1a 64 of "1,3;;".
        let mut d = Draft::blank(3, 0);
        d.threading = Threading(vec![vec![ShaftId(1)]]);
        d.drive = Drive::Liftplan(Liftplan(vec![vec![ShaftId(3), ShaftId(1)], vec![]]));
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for b in b"1,3;;" {
            h ^= u64::from(*b);
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
        assert_eq!(shed_fingerprint(&d), format!("{h:016x}"));
        assert_eq!(shed_fingerprint(&d).len(), 16);
    }

    /// A malformed WIF must never drive an unbounded allocation: a sparse 4-billion numeric key would,
    /// uncapped, request a ~96 GB `Vec` and ABORT the process (uncatchable). The cap drops the
    /// out-of-range key so the draft loads (here with empty threading) instead of crashing.
    #[test]
    fn malformed_huge_thread_key_does_not_abort() {
        let d = parse("[WEAVING]\nShafts=2\nTreadles=2\n[THREADING]\n4000000000=1\n").unwrap();
        assert!(
            d.threading.0.len() <= MAX_THREADS,
            "threading length is capped, not 4e9"
        );
        // An in-cap key still maps to its position (no off-by-one from the cap logic).
        let d2 = parse("[WEAVING]\nShafts=2\n[THREADING]\n5=1\n").unwrap();
        assert_eq!(d2.threading.0.len(), 5);
        assert_eq!(d2.threading.0[4], vec![ShaftId(1)]);
    }
}
