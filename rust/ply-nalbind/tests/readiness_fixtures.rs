//! The nalbinding readiness acceptance fixture (ADR 0021, `fixtures/nalbinding/readiness/`, shared
//! with the app's tests): `mixed-problems.plynal` is a mitten project whose notation is typed in
//! lower case and whose recipe has the slips a nalbinder makes (a thumb opening never worked, a tip
//! decreased by more stitches than the round has) and a free-text care step. Its hand-derived
//! `.expect.json` says what readiness must report: the verdict, the checks that ran, and every item
//! (check, code, severity, place, exact sentence) in order.
//!
//! Run: `cargo test -p ply-nalbind --test readiness_fixtures`

use ply_common::readiness::Severity;
use ply_nalbind::readiness::ready_to_make;
use ply_nalbind::recipe::{check, Recipe, RecipeSeverity};
use serde_json::Value;

fn read(ext: &str) -> String {
    let p = format!(
        "{}/../../fixtures/nalbinding/readiness/mixed-problems.{ext}",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{p}: {e}"))
}

#[test]
fn readiness_matches_the_oracle() {
    let doc: Value = serde_json::from_str(&read("plynal")).unwrap();
    assert_eq!(doc["format"], "ply.nalbind");
    assert_eq!(doc["schemaVersion"], 3);
    let notation = doc["notation"].as_str().unwrap();
    let recipe: Recipe = serde_json::from_value(doc["recipe"].clone()).unwrap();
    let r = ready_to_make(notation, Some(&recipe));

    let oracle: Value = serde_json::from_str(&read("expect.json")).unwrap();
    assert_eq!(
        serde_json::to_value(r.verdict()).unwrap(),
        oracle["verdict"]
    );
    let checked: Vec<&str> = r.checked.iter().map(|c| c.as_str()).collect();
    let want: Vec<&str> = oracle["checked"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(checked, want, "checks");
    let items = oracle["items"].as_array().unwrap();
    assert_eq!(r.items.len(), items.len(), "{:#?}", r.items);
    for (got, want) in r.items.iter().zip(items) {
        let at = format!("{} {}", got.check.as_str(), got.code);
        assert_eq!(got.check.as_str(), want["check"], "{at}: check");
        assert_eq!(got.code, want["code"].as_str().unwrap(), "{at}: code");
        assert_eq!(got.severity.as_str(), want["severity"], "{at}: severity");
        assert_eq!(got.place.as_deref(), want["place"].as_str(), "{at}: place");
        assert_eq!(
            got.message,
            want["message"].as_str().unwrap(),
            "{at}: message"
        );
    }
    // The blocking set is exactly what the PDF's problems box lists: the strict notation's errors
    // (none here), the stitch's errors (none) and the recipe's errors.
    let recipe_errors = check(&recipe, notation.trim())
        .issues
        .iter()
        .filter(|i| i.severity == RecipeSeverity::Error)
        .count();
    assert_eq!(r.count(Severity::Error), recipe_errors as u64);
    assert_eq!(oracle["errors"], recipe_errors);
}
