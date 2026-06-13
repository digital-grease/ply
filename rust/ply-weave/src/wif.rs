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
                sections.push(Section { name, entries: Vec::new() });
            } else if let Some(eq) = line.find('=') {
                if let Some(sec) = sections.last_mut() {
                    // Trim the KEY but keep the VALUE raw so `[NOTES]` preserves a line's leading
                    // whitespace (the outer `line.trim()` still strips trailing whitespace).
                    sec.entries.push((line[..eq].trim().into(), line[eq + 1..].into()));
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

/// Parse a numeric-keyed section (`1=3,5`) into a position-indexed `Vec<Vec<u16>>`
/// (1-based keys map to 0-based slots; gaps become empty lists).
fn parse_indexed_lists(section: &Section, count_hint: usize) -> Vec<Vec<u16>> {
    let mut max = count_hint;
    for (k, _) in &section.entries {
        if let Ok(i) = k.parse::<usize>() {
            max = max.max(i);
        }
    }
    let mut out = vec![Vec::new(); max];
    for (k, v) in &section.entries {
        if let Ok(i) = k.parse::<usize>() {
            if i >= 1 {
                out[i - 1] = v.split(',').filter_map(|t| t.trim().parse::<u16>().ok()).collect();
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
    lines.into_iter().map(|(_, v)| v).collect::<Vec<_>>().join("\n")
}

// ---------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------

/// Parse WIF text into a `Draft`.
pub fn parse(text: &str) -> Result<Draft> {
    let ini = Ini::parse(text);

    let weaving = ini.section("WEAVING");
    let shafts = weaving.and_then(|s| s.get("Shafts")).and_then(|v| v.parse().ok()).unwrap_or(0);
    let treadles = weaving.and_then(|s| s.get("Treadles")).and_then(|v| v.parse().ok()).unwrap_or(0);
    let rising = weaving
        .and_then(|s| s.get("Rising Shed"))
        .map(|v| matches!(v.to_lowercase().as_str(), "true" | "yes" | "1" | "on"))
        .unwrap_or(true);
    let shed = if rising { ShedType::Rising } else { ShedType::Sinking };

    let warp_sec = ini.section("WARP");
    let weft_sec = ini.section("WEFT");
    let warp_threads = warp_sec.and_then(|s| s.get("Threads")).and_then(|v| v.parse::<usize>().ok()).unwrap_or(0);
    let weft_threads = weft_sec.and_then(|s| s.get("Threads")).and_then(|v| v.parse::<usize>().ok()).unwrap_or(0);

    let unit = match warp_sec.and_then(|s| s.get("Units")).map(|u| u.to_lowercase()) {
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

    // Drive: prefer an explicit LIFTPLAN, otherwise TIEUP + TREADLING.
    let drive = if let Some(lp) = ini.section("LIFTPLAN") {
        Drive::Liftplan(Liftplan(
            parse_indexed_lists(lp, weft_threads)
                .into_iter()
                .map(|v| v.into_iter().map(ShaftId).collect())
                .collect(),
        ))
    } else {
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
        Drive::Treadled { tieup, treadling }
    };

    // Colors. `[COLOR PALETTE] Range` (default 255) sets the color-table component scale; scale to
    // the model's 0..=255 so a non-standard range (e.g. 0..999) keeps its colors instead of clipping.
    let palette_range = ini
        .section("COLOR PALETTE")
        .and_then(|s| s.get("Range"))
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|&r| r > 0)
        .unwrap_or(255);
    let palette = ini
        .section("COLOR TABLE")
        .map(|s| parse_color_table(s, palette_range))
        .unwrap_or_default();
    let warp_default = warp_sec.and_then(|s| s.get("Color")).and_then(parse_color_ref);
    let weft_default = weft_sec.and_then(|s| s.get("Color")).and_then(parse_color_ref);
    let warp_colors = colors_for(ini.section("WARP COLORS"), threading.ends(), warp_default);
    let weft_colors = colors_for(ini.section("WEFT COLORS"), drive.picks(), weft_default);
    let colors = ColorPlan { palette, warp: warp_colors, weft: weft_colors };

    let name = ini
        .section("TEXT")
        .and_then(|s| s.get("Title"))
        .unwrap_or("Untitled")
        .to_string();

    let notes = ini.section("NOTES").map(parse_notes).unwrap_or_default();

    // Retain every section Ply does NOT model, verbatim, so `write` can re-emit it (thickness,
    // spacing, vendor sections). Section names are already uppercased by the Ini reader.
    const MODELED: &[&str] = &[
        "WIF", "TEXT", "CONTENTS", "WEAVING", "WARP", "WEFT", "COLOR TABLE", "COLOR PALETTE",
        "THREADING", "TIEUP", "TREADLING", "LIFTPLAN", "WARP COLORS", "WEFT COLORS", "NOTES",
    ];
    let retained = ini
        .sections
        .iter()
        .filter(|s| !MODELED.contains(&s.name.as_str()))
        .map(|s| RetainedSection { name: s.name.clone(), entries: s.entries.clone() })
        .collect();

    if shafts == 0 && threading.ends() == 0 {
        return Err(WeaveError::WifParse("no recognizable draft data (missing WEAVING/THREADING)".into()));
    }

    Ok(Draft { name, shafts, treadles, shed, unit, threading, drive, colors, notes, retained })
}

fn parse_color_table(section: &Section, range: u32) -> Vec<Color> {
    // WIF color indices are 1-based; palette[0] corresponds to WIF index 1. Components are in
    // 0..=`range` (from `[COLOR PALETTE] Range`, default 255) and are scaled to the model's 0..=255.
    parse_indexed_lists(section, 0)
        .into_iter()
        .map(|rgb| {
            if rgb.len() >= 3 {
                Color::rgb(scale8(rgb[0], range), scale8(rgb[1], range), scale8(rgb[2], range))
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
    v.split(',').next()?.trim().parse::<usize>().ok().map(|i| i.saturating_sub(1))
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
    for sec in &draft.retained {
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

    // Re-emit unmodeled sections kept verbatim on import (thickness, spacing, vendor sections), so a
    // structurally-edited re-serialize is no longer lossy for them. (A resize already dropped any
    // per-thread section whose axis changed — see `Draft::resized`.)
    for sec in &draft.retained {
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
            Drive::Treadled { tieup, .. } => assert_eq!(tieup.shafts_for(TreadleId(1)), &[ShaftId(1), ShaftId(2)]),
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
        assert!(text.contains("[TEXT]"), "a named draft writes a [TEXT] section");
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
        assert_eq!(parse(&text).unwrap().notes, "Line one, with a comma.\nLine two.");
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

    const RETAIN_WIF: &str = "[WEAVING]\nShafts=2\nTreadles=2\n[WARP]\nThreads=2\n\
        [WEFT]\nThreads=2\n[THREADING]\n1=1\n2=2\n[TIEUP]\n1=1\n2=2\n[TREADLING]\n1=1\n2=2\n\
        [WARP THICKNESS]\n1=10\n2=10\n[ACME VENDOR]\nFoo=Bar\n";

    /// M3 2.3: an unmodeled per-thread section (`[WARP THICKNESS]`) and an unknown vendor section are
    /// retained verbatim and re-emitted by `write`, so a re-serialize is no longer lossy for them.
    #[test]
    fn unmodeled_sections_survive_wif_roundtrip() {
        let d = parse(RETAIN_WIF).unwrap();
        assert_eq!(d.retained.len(), 2);
        let text = write(&d);
        assert!(text.contains("[WARP THICKNESS]") && text.contains("[ACME VENDOR]"));
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
        assert!(!names.contains(&"WARP THICKNESS"), "stale per-thread warp section dropped");
        assert!(names.contains(&"ACME VENDOR"), "global vendor section kept");
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
            threading: Threading(vec![vec![ShaftId(1)], vec![ShaftId(2)], vec![ShaftId(3)], vec![ShaftId(4)]]),
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
            notes: String::new(),
            retained: Vec::new(),
        };

        let lp = d.to_liftplan_draft();
        // Sanity: the convert really produced empty raised sets at the three boundary positions.
        assert!(lp.raised_shafts(0).is_empty(), "pick 0 raises nothing (start)");
        assert!(lp.raised_shafts(2).is_empty(), "pick 2 raises nothing (middle)");
        assert!(lp.raised_shafts(4).is_empty(), "pick 4 raises nothing (end)");

        let rt = parse(&write(&lp)).unwrap();
        assert_eq!(rt.picks(), lp.picks(), "pick count survives (empty rows recovered via WEFT Threads)");
        for p in 0..lp.picks() {
            assert_eq!(rt.raised_shafts(p), lp.raised_shafts(p), "pick {p} raised set preserved");
        }

        // The degenerate all-empty plan (every pick presses the sink-all treadle) must still recover
        // its full pick count rather than collapsing to zero rows.
        let all_empty = Draft {
            drive: Drive::Treadled {
                tieup: TieUp(vec![vec![ShaftId(1), ShaftId(2), ShaftId(3), ShaftId(4)]]),
                treadling: Treadling(vec![vec![TreadleId(1)], vec![TreadleId(1)], vec![TreadleId(1)]]),
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
        assert_eq!(rt2.picks(), 3, "an all-empty liftplan still recovers 3 picks");
        for p in 0..rt2.picks() {
            assert!(rt2.raised_shafts(p).is_empty(), "pick {p} stays empty");
        }
    }
}
