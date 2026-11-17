//! The nalbinding recipe acceptance fixtures (`fixtures/nalbinding/recipes/`, shared with the app's
//! tests): each `.plynal` is a schema version 3 project the app's own writer produced; its
//! hand-derived `.expect.json` says what the recipe checks must report for every segment (part,
//! phase, stitch, count, written instruction, target, checked) and every issue (code, severity,
//! place, exact text). Together the fixtures give every recipe code but `too-large`, which a file
//! cannot reach (the app refuses a file past the limits as unreadable; unit tests cover it).
//!
//! Run: `cargo test -p ply-nalbind --test recipe_fixtures`

use std::collections::BTreeSet;

use ply_nalbind::recipe::{
    check, Count, Phase, Reading, Recipe, RecipeCode, RecipeSeverity, SegmentKind, StitchReading,
    StitchUse,
};
use serde_json::Value;

const FIXTURES: [&str; 4] = [
    "mitten-cuff-up",
    "hat-centre-start",
    "recipe-problems",
    "recipe-empty",
];

fn read(name: &str, ext: &str) -> String {
    let path = format!(
        "{}/../../fixtures/nalbinding/recipes/{name}.{ext}",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
}

fn json_of<T: serde::Serialize>(value: T) -> Value {
    serde_json::to_value(value).unwrap()
}

fn kind_name(k: SegmentKind) -> Value {
    json_of(k)
}

fn phase_name(p: Phase) -> Value {
    json_of(p)
}

fn count_value(c: Count) -> Value {
    match c {
        Count::Known(n) => Value::from(n),
        Count::Unknown => Value::from("unknown"),
        Count::Refused => Value::from("refused"),
        Count::NotApplicable => Value::from("not-applicable"),
    }
}

fn severity_name(s: RecipeSeverity) -> &'static str {
    match s {
        RecipeSeverity::Info => "info",
        RecipeSeverity::Warning => "warning",
        RecipeSeverity::Error => "error",
    }
}

/// The fixture's project: its stitch notation and its recipe.
fn project(name: &str) -> (Value, String, Recipe) {
    let doc: Value = serde_json::from_str(&read(name, "plynal")).unwrap();
    assert_eq!(doc["format"], "ply.nalbind", "{name}");
    assert_eq!(doc["schemaVersion"], 3, "{name}");
    let notation = doc["notation"].as_str().unwrap().to_string();
    let recipe: Recipe = serde_json::from_value(doc["recipe"].clone())
        .unwrap_or_else(|e| panic!("{name}: the engine cannot read the app's recipe: {e}"));
    (doc, notation, recipe)
}

#[test]
fn recipe_fixtures_match_their_oracles() {
    for name in FIXTURES {
        let oracle: Value = serde_json::from_str(&read(name, "expect.json")).unwrap();
        let (doc, notation, recipe) = project(name);
        assert_eq!(
            oracle["project_notation"], notation,
            "{name}: project stitch"
        );
        assert_eq!(oracle["done"], json_of(&recipe.done), "{name}: done");
        assert_eq!(
            doc["recipe"]["done"], oracle["done"],
            "{name}: done as written"
        );

        let report = check(&recipe, &notation);
        assert_eq!(oracle["fit"], json_of(&report.fit), "{name}: fit");

        let expected = oracle["segments"].as_array().unwrap();
        assert_eq!(
            report.segments.len(),
            expected.len(),
            "{name}: segment count"
        );
        for (s, e) in report.segments.iter().zip(expected) {
            let at = format!("{name}, segment {}", s.index);
            assert_eq!(e["index"], s.index, "{at}: index");
            assert_eq!(e["id"], s.id.as_str(), "{at}: id");
            assert_eq!(e["kind"], kind_name(s.kind), "{at}: kind");
            assert_eq!(e["phase"], phase_name(s.phase), "{at}: phase");
            assert_eq!(e["part"], json_of(s.part), "{at}: part");
            assert_eq!(e["count"], count_value(s.count), "{at}: count");
            assert_eq!(e["written"], s.written.as_str(), "{at}: written");
            assert_eq!(e["target"], json_of(&s.target), "{at}: target");
            assert_eq!(e["checked"], s.checked, "{at}: checked");
            let (source, st): (&str, Option<&StitchReading>) = match &s.stitch {
                None => ("", None),
                Some(StitchUse::Project) => ("project", report.project_stitch.as_ref()),
                Some(StitchUse::Own(r)) => ("own", Some(r)),
            };
            match (st, &e["stitch"]) {
                (None, Value::Null) => assert_eq!(source, "", "{at}: no stitch"),
                (Some(st), es) if es.is_object() => {
                    let reading = match st.reading {
                        Reading::Strict => "strict",
                        Reading::Lenient => "lenient",
                    };
                    assert_eq!(es["source"], source, "{at}: stitch source");
                    assert_eq!(es["notation"], st.notation.as_str(), "{at}: notation");
                    assert_eq!(es["reading"], reading, "{at}: reading");
                    let read = es.get("read").and_then(Value::as_bool).unwrap_or(true);
                    assert_eq!(st.read.is_some(), read, "{at}: read or too long");
                    let accepted = st.read.as_ref().is_some_and(|r| r.accepted);
                    assert_eq!(es["accepted"], accepted, "{at}: accepted");
                }
                (got, want) => panic!("{at}: stitch {got:?}, oracle {want}"),
            }
        }

        let issues = oracle["issues"].as_array().unwrap();
        let got: Vec<String> = report.issues.iter().map(|i| i.text.clone()).collect();
        assert_eq!(
            report.issues.len(),
            issues.len(),
            "{name}: issues\n{got:#?}"
        );
        for (i, e) in report.issues.iter().zip(issues) {
            let at = format!("{name}, issue {}", i.text);
            assert_eq!(e["code"], i.code.as_str(), "{at}: code");
            assert_eq!(e["severity"], severity_name(i.severity), "{at}: severity");
            assert_eq!(e["segment"], json_of(i.segment), "{at}: segment");
            assert_eq!(e["fit"], json_of(i.fit), "{at}: fit");
            assert_eq!(e["text"], i.text.as_str(), "{at}: text");
            if let Some(s) = i.segment {
                assert_eq!(
                    i.segment_id.as_deref(),
                    Some(recipe.segments[s].id.as_str()),
                    "{at}: segment id"
                );
            }
        }
    }
}

#[test]
fn the_fixtures_give_every_code_a_file_can_reach() {
    let mut seen = BTreeSet::new();
    for name in FIXTURES {
        let (_, notation, recipe) = project(name);
        for i in check(&recipe, &notation).issues {
            seen.insert(i.code.as_str());
        }
    }
    let missing: Vec<&str> = RecipeCode::ALL
        .iter()
        .map(|c| c.as_str())
        .filter(|c| !seen.contains(c) && *c != "too-large")
        .collect();
    assert!(
        missing.is_empty(),
        "no fixture gives these codes: {missing:?}"
    );
}

#[test]
fn the_worked_objects_are_clean_where_they_should_be() {
    // The mitten is the M8 exit gate's structured worked object: separate start, body, shaping and
    // finish steps, a thumb opening worked later, and nothing to report.
    let (_, notation, recipe) = project("mitten-cuff-up");
    let report = check(&recipe, &notation);
    assert!(report.issues.is_empty(), "{:?}", report.issues);
    let phases: Vec<Phase> = report.segments.iter().map(|s| s.phase).collect();
    for p in [Phase::Start, Phase::Body, Phase::Shaping, Phase::Finish] {
        assert!(phases.contains(&p), "the mitten has a {p:?} step");
    }
    // The hat has only an Info: Ply cannot count past "until it measures 17 cm across".
    let (_, notation, recipe) = project("hat-centre-start");
    let report = check(&recipe, &notation);
    assert!(report
        .issues
        .iter()
        .all(|i| i.severity == RecipeSeverity::Info));
}
