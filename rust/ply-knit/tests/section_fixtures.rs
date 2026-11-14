//! Knitting section acceptance fixtures (`fixtures/knitting/sections/`): original flat patterns
//! with short rows and held stitches, each with a hand-derived oracle. Each fixture is a `.plyknit`
//! file the engine wrote, an `.expect.json` oracle (the written instructions; every ledger line with
//! its place, text and count; the validation issues) and a `.fixture.toml` record.
//!
//! What this proves for every fixture: the file loads as a current envelope and re-saves to the same
//! bytes (so sections survive save and load); the written instructions and the stitch ledger agree
//! with the oracle line by line; and validation reports exactly the oracle's problems.
//!
//! Run: `cargo test -p ply-knit --test section_fixtures`

use ply_knit::sections::{ledger, section_title, LineCount};
use ply_knit::{native, to_written, validate, Construction, Severity, Side};
use serde_json::Value;

const DIR: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../fixtures/knitting/sections"
);

/// Every tracked fixture, by name.
const FIXTURES: [&str; 3] = [
    "shoulder-short-rows-flat",
    "neckline-hold-flat",
    "ledger-problems-flat",
];

fn read(name: &str, ext: &str) -> String {
    let path = format!("{DIR}/{name}.{ext}");
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
}

#[test]
fn every_fixture_on_disk_is_listed() {
    let mut on_disk: Vec<String> = std::fs::read_dir(DIR)
        .unwrap()
        .filter_map(|e| {
            let name = e.unwrap().file_name().into_string().unwrap();
            name.strip_suffix(".plyknit").map(str::to_string)
        })
        .collect();
    on_disk.sort();
    let mut listed: Vec<String> = FIXTURES.iter().map(|s| s.to_string()).collect();
    listed.sort();
    assert_eq!(on_disk, listed);
}

fn side(s: Option<Side>) -> Value {
    match s {
        Some(Side::Rs) => "RS".into(),
        Some(Side::Ws) => "WS".into(),
        None => Value::Null,
    }
}

#[test]
fn section_fixtures_match_their_oracles() {
    for name in FIXTURES {
        let text = read(name, "plyknit");
        let expect: Value = serde_json::from_str(&read(name, "expect.json")).unwrap();

        let loaded = native::read(&text).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(
            loaded.source_version,
            ply_knit::KNIT_SCHEMA_VERSION,
            "{name}"
        );
        let p = loaded.pattern;
        assert_eq!(
            p.to_json().unwrap(),
            text,
            "{name}: re-saving changes the file"
        );
        assert!(!p.sections.is_empty(), "{name}: has sections");
        assert_eq!(expect["construction"], "Flat");
        assert_eq!(p.construction, Construction::Flat);
        assert_eq!(
            expect["cast_on"].as_u64(),
            p.cast_on.map(u64::from),
            "{name}"
        );

        let written: Vec<String> = expect["written"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| l.as_str().unwrap().to_string())
            .collect();
        assert_eq!(to_written(&p), written, "{name}: written");

        let l = ledger(&p);
        let steps = expect["steps"].as_array().unwrap();
        assert_eq!(
            l.lines.len(),
            steps.len(),
            "{name}: one oracle entry per line"
        );
        for (i, (line, want)) in l.lines.iter().zip(steps).enumerate() {
            let at = format!("{name} line {}", i + 1);
            assert_eq!(
                section_title(&p, line.section),
                want["section"].as_str().unwrap(),
                "{at}"
            );
            assert_eq!(line.step as u64 + 1, want["step"].as_u64().unwrap(), "{at}");
            assert_eq!(
                line.chart_row.map(|r| r as u64 + 1),
                want["chart_row"].as_u64(),
                "{at}"
            );
            assert_eq!(line.written(), want["line"].as_str().unwrap(), "{at}");
            match (&line.count, &want["count"]) {
                (LineCount::Counted(c), Value::Object(w)) => {
                    assert_eq!(c.on_needle, w["on_needle"].as_u64().unwrap(), "{at}");
                    assert_eq!(c.to_work, w["to_work"].as_u64().unwrap(), "{at}");
                    assert_eq!(c.mid_row, w["mid_row"].as_bool().unwrap(), "{at}");
                    assert_eq!(c.past_turns, w["past_turns"].as_u64().unwrap(), "{at}");
                    assert_eq!(
                        c.pending_turns,
                        w["pending_turns"].as_u64().unwrap(),
                        "{at}"
                    );
                    let held: Vec<(String, u64)> =
                        c.held.iter().map(|h| (h.name.clone(), h.count)).collect();
                    let want_held: Vec<(String, u64)> = w["held"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|h| (h[0].as_str().unwrap().to_string(), h[1].as_u64().unwrap()))
                        .collect();
                    assert_eq!(held, want_held, "{at}: held");
                    assert_eq!(c.bound_off, w["bound_off"].as_u64().unwrap(), "{at}");
                    assert_eq!(side(c.side), w["side"], "{at}: side");
                    // The ledger never loses a stitch: what is on the needle, on hold and bound
                    // off is what was cast on, plus what was added, less what was removed. These
                    // fixtures add or remove nothing else, so it is the cast-on (or, for a chart
                    // row that makes more than it takes, more).
                    let total = c.on_needle + c.held_total() + c.bound_off;
                    assert!(
                        total >= u64::from(p.cast_on.unwrap()),
                        "{at}: {total} stitches accounted for"
                    );
                }
                (LineCount::Unknown, Value::String(s)) => assert_eq!(s, "unknown", "{at}"),
                (LineCount::NotCounted, Value::String(s)) => {
                    assert_eq!(s, "not counted", "{at}")
                }
                (got, want) => panic!("{at}: count {got:?}, oracle {want}"),
            }
        }

        let issues: Vec<(String, String)> = validate(&p)
            .into_iter()
            .map(|i| {
                let severity = match i.severity {
                    Severity::Error => "error",
                    Severity::Warning => "warning",
                };
                (severity.to_string(), i.message)
            })
            .collect();
        let want_issues: Vec<(String, String)> = expect["issues"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| {
                (
                    i["severity"].as_str().unwrap().to_string(),
                    i["message"].as_str().unwrap().to_string(),
                )
            })
            .collect();
        assert_eq!(issues, want_issues, "{name}: validation");

        let record = read(name, "fixture.toml");
        for key in [
            format!("id = \"knitting/sections/{name}\""),
            "license = \"original\"".to_string(),
            "automated_checks = \"pass\"".to_string(),
            "practitioner_knit_check = \"pending\"".to_string(),
        ] {
            assert!(record.contains(&key), "{name}.fixture.toml lacks `{key}`");
        }
    }
}
