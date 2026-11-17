//! Loom feasibility fixtures (M8-02, ADR 0014): original drafts and loom profiles under
//! `fixtures/weaving/looms/`, each draft checked against one or more of the profiles, held to a
//! hand-written oracle of every diagnostic (code, severity and exact wording).
//!
//! The drafts are written by the builders below; `tracked_fixtures_are_what_the_builders_write`
//! fails if a builder (or the WIF writer) changes them. To rewrite the files on purpose, run
//! `cargo test -p ply-weave --test loom_fixtures -- --ignored regenerate` and review the diff as a
//! change to the fixtures.

use ply_common::Unit;
use ply_weave::construction::Construction;
use ply_weave::draft::*;
use ply_weave::feasibility::{check, LoomCheckInput, LoomSeverity, Sett};
use ply_weave::loom::{DentUnit, Length, LoomKind, LoomProfile, Reed};
use ply_weave::loom_file::{self, LoomLibrary};
use ply_weave::structure::double_weave;
use ply_weave::validate::{validate, Severity};
use ply_weave::wif;
use serde_json::Value;

const DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/weaving/looms");

/// A straight twill on `shafts` shafts (`over` up), straight treadling 1 to `shafts`, white warp and
/// black weft.
fn twill(name: &str, shafts: u16, over: u16, ends: usize, picks: usize) -> Draft {
    let mut d = Draft::blank(shafts, shafts);
    d.name = name.into();
    d.threading = Threading::straight(ends, shafts);
    d.drive = Drive::Treadled {
        tieup: TieUp::twill(over, shafts - over),
        treadling: Treadling(
            (0..picks)
                .map(|p| vec![TreadleId((p % usize::from(shafts)) as u16 + 1)])
                .collect(),
        ),
    };
    d.colors.warp = vec![0; ends];
    d.colors.weft = vec![1; picks];
    d
}

/// The file's sett, as WIF carries it: `[WARP] Spacing` (1 / sett, in the draft's unit).
fn with_spacing(mut d: Draft, spacing: &str) -> Draft {
    d.retained.push(RetainedSection {
        name: wif::WARP_SECTION.into(),
        entries: vec![("Spacing".into(), spacing.into())],
    });
    d
}

/// Every fixture draft: (file stem, draft).
fn drafts() -> Vec<(&'static str, Draft)> {
    let mut double_width = double_weave(
        480,
        8,
        Construction::DoubleWidth {
            fold: ply_weave::Side::Left,
        },
    );
    double_width.name = "Double width, folded".into();
    vec![
        (
            "eight-shaft-twill",
            with_spacing(twill("Eight-shaft twill", 8, 4, 16, 16), "0.05"),
        ),
        (
            "sinking-twill",
            twill("Sinking-shed twill", 4, 2, 8, 8).with_shed(ShedType::Sinking),
        ),
        (
            "double-width-folded",
            with_spacing(double_width, "0.0416667"),
        ),
    ]
}

/// Every fixture loom profile, in file order.
fn looms() -> LoomLibrary {
    let inch = |value| Length {
        value,
        unit: Unit::Inches,
    };
    let reed = |dents, per| Reed { dents, per };
    LoomLibrary {
        looms: vec![
            LoomProfile {
                kind: Some(LoomKind::Jack),
                shafts: Some(4),
                treadles: Some(6),
                weaving_width: Some(inch(24.0)),
                reeds: vec![reed(12.0, DentUnit::PerInch), reed(10.0, DentUnit::PerInch)],
                treadles_at_once: Some(2),
                notes: "Fixture: a small jack floor loom.".into(),
                ..LoomProfile::new("fixture-four-shaft-jack", "Four-shaft jack loom")
            },
            LoomProfile {
                shafts: Some(8),
                notes: "Fixture: only the shaft count is known.".into(),
                ..LoomProfile::new("fixture-partial", "Borrowed loom")
            },
            LoomProfile {
                kind: Some(LoomKind::Countermarch),
                shafts: Some(8),
                treadles: Some(10),
                weaving_width: Some(Length {
                    value: 100.0,
                    unit: Unit::Centimeters,
                }),
                reeds: vec![reed(40.0, DentUnit::Per10Cm), reed(50.0, DentUnit::Per10Cm)],
                treadles_at_once: Some(2),
                notes: "Fixture: a metric countermarch loom.".into(),
                ..LoomProfile::new(
                    "fixture-eight-shaft-countermarch",
                    "Eight-shaft countermarch",
                )
            },
            LoomProfile {
                kind: Some(LoomKind::Table),
                shafts: Some(8),
                weaving_width: Some(inch(16.0)),
                reeds: vec![reed(12.0, DentUnit::PerInch)],
                notes: "Fixture: a table loom with a lever for each shaft.".into(),
                ..LoomProfile::new("fixture-table-loom", "Table loom")
            },
        ],
    }
}

fn read(name: &str) -> String {
    std::fs::read_to_string(format!("{DIR}/{name}")).unwrap_or_else(|e| panic!("{name}: {e}"))
}

fn severity_word(s: LoomSeverity) -> &'static str {
    match s {
        LoomSeverity::NotFeasible => "not_feasible",
        LoomSeverity::Advice => "advice",
        LoomSeverity::NotChecked => "not_checked",
        LoomSeverity::Fits => "fits",
    }
}

#[test]
fn tracked_fixtures_are_what_the_builders_write() {
    for (stem, draft) in drafts() {
        let on_disk = read(&format!("{stem}.wif")).replace("\r\n", "\n");
        assert_eq!(
            on_disk,
            wif::write(&draft).replace("\r\n", "\n"),
            "{stem}.wif"
        );
    }
    assert_eq!(
        read("looms.json").trim_end(),
        loom_file::write(&looms()).unwrap()
    );
}

#[test]
fn fixtures_match_their_oracles() {
    let library = loom_file::read(&read("looms.json")).expect("looms.json reads");
    for (stem, _) in drafts() {
        let draft = wif::parse(&read(&format!("{stem}.wif"))).expect("the draft parses");
        let oracle: Value = serde_json::from_str(&read(&format!("{stem}.expect.json"))).unwrap();
        // Structurally valid: the loom check is a separate judgement.
        let errors = validate(&draft)
            .iter()
            .filter(|i| i.severity == Severity::Error)
            .count();
        assert_eq!(
            errors as u64,
            oracle["structural_errors"].as_u64().unwrap(),
            "{stem}"
        );
        let checks = oracle["checks"].as_array().expect("checks");
        assert!(!checks.is_empty());
        for c in checks {
            let id = c["loom"].as_str().unwrap();
            let loom = library
                .get(id)
                .unwrap_or_else(|| panic!("{stem}: no loom {id}"));
            let sett = c["sett_per_inch"].as_f64().map(|ends| Sett {
                ends,
                per: Unit::Inches,
            });
            let report = check(&draft, loom, &LoomCheckInput { sett });
            let got: Vec<Value> = report
                .diagnostics
                .iter()
                .map(|d| {
                    serde_json::json!({
                        "code": d.code.as_str(),
                        "severity": severity_word(d.severity),
                        "message": d.message,
                    })
                })
                .collect();
            assert_eq!(
                Value::Array(got),
                c["diagnostics"],
                "{stem} on {id}:\n{}",
                serde_json::to_string_pretty(
                    &report
                        .diagnostics
                        .iter()
                        .map(|d| serde_json::json!({
                            "code": d.code.as_str(),
                            "severity": severity_word(d.severity),
                            "message": d.message,
                        }))
                        .collect::<Vec<_>>()
                )
                .unwrap()
            );
            assert_eq!(
                report.feasible(),
                c["feasible"].as_bool().unwrap(),
                "{stem} on {id}"
            );
        }
    }
}

/// Rewrites the fixture drafts and `looms.json` from the builders. Ignored: run it only on purpose
/// (see the module doc), never as part of the normal suite.
#[test]
#[ignore]
fn regenerate() {
    for (stem, draft) in drafts() {
        std::fs::write(format!("{DIR}/{stem}.wif"), wif::write(&draft)).unwrap();
    }
    std::fs::write(
        format!("{DIR}/looms.json"),
        loom_file::write(&looms()).unwrap() + "\n",
    )
    .unwrap();
}
