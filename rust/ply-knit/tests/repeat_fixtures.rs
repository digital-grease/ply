//! Knitting repeat acceptance fixtures (`fixtures/knitting/repeats/`): original charts with
//! hand-derived oracles. Each fixture is a `.plyknit` file the engine wrote, an `.expect.json` oracle
//! (the cast-on and its written line when the chart states one; the written line, worked counts,
//! to-end repeat count and expanded worked sequence of every row; the validation issues), and a
//! `.fixture.toml` record.
//!
//! What this proves for every fixture: the file loads as a current envelope and re-saves to the same
//! bytes (so repeats survive save and load); the written instructions, the stitch counts and the
//! expanded worked sequence all agree with the oracle and with each other; and validation reports
//! exactly the oracle's problems.
//!
//! Run: `cargo test -p ply-knit --test repeat_fixtures`

use ply_knit::instruction::op_totals;
use ply_knit::{native, stitch_flow, to_written, validate, Construction, Severity};
use serde_json::Value;

const DIR: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../fixtures/knitting/repeats"
);

/// Every tracked fixture, by name.
const FIXTURES: [&str; 9] = [
    "seed-stitch-round",
    "rib-edges-flat",
    "rib-to-end-flat",
    "rib-to-end-remainder-flat",
    "rib-cast-on-unknown-flat",
    "rib-cast-on-flat",
    "eyelet-lace-round",
    "cable-repeat-round",
    "rejected-spans-round",
];

fn read(name: &str, ext: &str) -> String {
    let path = format!("{DIR}/{name}.{ext}");
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
}

fn opt_u64(v: &Value) -> Option<u64> {
    if v.is_null() {
        None
    } else {
        Some(v.as_u64().expect("a count"))
    }
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

#[test]
fn repeat_fixtures_match_their_oracles() {
    for name in FIXTURES {
        let text = read(name, "plyknit");
        let expect: Value = serde_json::from_str(&read(name, "expect.json")).unwrap();

        // Save and load: a current envelope, re-saved byte for byte.
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
        assert!(
            p.chart.rows.iter().all(|r| !r.repeats.is_empty())
                || name == "rib-to-end-remainder-flat",
            "{name}: every row but a set-up row carries its repeat"
        );

        let construction = match p.construction {
            Construction::Flat => "Flat",
            Construction::InTheRound => "InTheRound",
        };
        assert_eq!(expect["construction"], construction, "{name}");
        assert_eq!(
            expect["width"].as_u64(),
            Some(p.chart.width as u64),
            "{name}"
        );

        // The cast-on (absent from the oracle = not stated) and, when stated, its written line first.
        let cast_on = expect.get("cast_on").and_then(Value::as_u64);
        assert_eq!(p.cast_on.map(u64::from), cast_on, "{name}: cast-on");
        let mut written = to_written(&p);
        if cast_on.is_some() {
            let line = written.remove(0);
            assert_eq!(line, expect["cast_on_line"].as_str().unwrap(), "{name}");
        }

        let rows = expect["rows"].as_array().unwrap();
        assert_eq!(
            rows.len(),
            p.chart.rows.len(),
            "{name}: one oracle row per row"
        );
        assert_eq!(
            written.len(),
            rows.len(),
            "{name}: one written line per row"
        );
        let flow = stitch_flow(&p);
        for (r, want) in rows.iter().enumerate() {
            let at = format!("{name} row {}", r + 1);
            assert_eq!(want["row"].as_u64(), Some(r as u64 + 1), "{at}");
            assert_eq!(
                written[r],
                want["written"].as_str().unwrap(),
                "{at}: written"
            );

            let f = &flow[r];
            let count = f.count;
            assert_eq!(
                count.map(|c| c.consumed),
                opt_u64(&want["consumes"]),
                "{at}: consumes"
            );
            assert_eq!(
                count.map(|c| c.produced),
                opt_u64(&want["produces"]),
                "{at}: produces"
            );
            assert_eq!(
                count.and_then(|c| c.to_end_times),
                opt_u64(&want["to_end_times"]),
                "{at}: to-end repeats"
            );

            // The expanded worked sequence, as the worked symbols, agrees with the oracle and with
            // the counts.
            let worked = if count.is_some() { f.worked() } else { None };
            let symbols = worked.as_ref().map(|ops| {
                ops.iter()
                    .map(|op| p.legend.get(op.worked).unwrap().symbol.clone())
                    .collect::<Vec<_>>()
            });
            let want_worked = want["worked"].as_array().map(|a| {
                a.iter()
                    .map(|s| s.as_str().unwrap().to_string())
                    .collect::<Vec<_>>()
            });
            assert_eq!(symbols, want_worked, "{at}: worked sequence");
            if let (Some(ops), Some(c)) = (&worked, count) {
                assert_eq!(
                    op_totals(ops),
                    Some((c.consumed, c.produced)),
                    "{at}: counts are the sums over the worked sequence"
                );
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
            format!("id = \"knitting/repeats/{name}\""),
            "license = \"original\"".to_string(),
            "automated_checks = \"pass\"".to_string(),
            "practitioner_knit_check = \"pending\"".to_string(),
        ] {
            assert!(record.contains(&key), "{name}.fixture.toml lacks `{key}`");
        }
    }
}
