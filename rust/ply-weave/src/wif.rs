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
            .map(|(_, v)| v.as_str())
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
                    sec.entries.push((line[..eq].trim().into(), line[eq + 1..].trim().into()));
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

    // Colors
    let palette = ini.section("COLOR TABLE").map(parse_color_table).unwrap_or_default();
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

    if shafts == 0 && threading.ends() == 0 {
        return Err(WeaveError::WifParse("no recognizable draft data (missing WEAVING/THREADING)".into()));
    }

    Ok(Draft { name, shafts, treadles, shed, unit, threading, drive, colors, notes: String::new() })
}

fn parse_color_table(section: &Section) -> Vec<Color> {
    // WIF color indices are 1-based; palette[0] corresponds to WIF index 1.
    // NOTE: assumes a 0..255 palette range; non-standard ranges (e.g. 0..999) are TODO.
    parse_indexed_lists(section, 0)
        .into_iter()
        .map(|rgb| {
            if rgb.len() >= 3 {
                Color::rgb(rgb[0].min(255) as u8, rgb[1].min(255) as u8, rgb[2].min(255) as u8)
            } else {
                Color::WHITE
            }
        })
        .collect()
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

    line!("[CONTENTS]");
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
}
