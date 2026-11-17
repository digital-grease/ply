//! The weaving readiness acceptance fixture (ADR 0021, `fixtures/weaving/readiness/`, shared with the
//! app's tests): `mixed-problems.wif` is an eight-shaft twill sampler with the slips a weaver makes
//! (a treadle the tie-up does not have, a pick marked tabby on a twill shed, a double shot), to be
//! woven on the four-shaft jack loom of `fixtures/weaving/looms/looms.json`. Its hand-derived
//! `.expect.json` says what readiness must report: the verdict, the checks that ran, and every item
//! (check, code, severity, place, exact sentence) in order.
//!
//! Run: `cargo test -p ply-weave --test readiness_fixtures`

use ply_common::readiness::Severity;
use ply_weave::draft::{Draft, Drive, PickRole, ShotGroup, Threading, TieUp, TreadleId, Treadling};
use ply_weave::feasibility::{check, LoomCheckInput};
use ply_weave::readiness::{ready_to_make, LoomCheck, PlanInput};
use ply_weave::{loom_file, wif};
use serde_json::Value;

const NAME: &str = "mixed-problems";
const LOOM: &str = "fixture-four-shaft-jack";

fn path(rel: &str) -> String {
    format!("{}/../../fixtures/{rel}", env!("CARGO_MANIFEST_DIR"))
}

fn read(rel: &str) -> String {
    let p = path(rel);
    std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{p}: {e}"))
}

/// The draft the fixture records, as a weaver drew it: an 8-shaft 4/4 straight twill, 16 ends by 16
/// picks, treadled 1 to 8 and back up again, with three slips.
fn drawn() -> Draft {
    let mut d = Draft::blank(8, 8);
    d.name = "Twill sampler with slips".into();
    d.threading = Threading::straight(16, 8);
    // Treadles 1 to 8, then 1 to 6 and 7 twice: pick 5 presses treadle 9 (the tie-up has 8), and
    // picks 15 and 16 are one shed, grouped as a double shot.
    let treadles = [1, 2, 3, 4, 9, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 7];
    d.drive = Drive::Treadled {
        tieup: TieUp::twill(4, 4),
        treadling: Treadling(treadles.iter().map(|&t| vec![TreadleId(t)]).collect()),
    };
    d.colors.warp = vec![0; 16];
    d.colors.weft = vec![1; 16];
    // Every pick is a pattern pick but pick 2, marked tabby by mistake: its twill shed is not plain
    // weave.
    d.pick_roles = (0..16)
        .map(|p| {
            if p == 1 {
                PickRole::Tabby
            } else {
                PickRole::Pattern
            }
        })
        .collect();
    d.weft_work.shot_groups = vec![ShotGroup {
        start: 14,
        picks: 2,
    }];
    d.notes = "Readiness fixture: a sampler with the slips a weaver makes.".into();
    d
}

/// Write the fixture's draft with the engine's own WIF writer. Run on purpose only:
/// `cargo test -p ply-weave --test readiness_fixtures -- --ignored`.
#[test]
#[ignore]
fn write_the_fixture() {
    std::fs::write(
        path(&format!("weaving/readiness/{NAME}.wif")),
        wif::write(&drawn()),
    )
    .unwrap();
}

#[test]
fn the_fixture_is_the_drawn_draft_and_re_saves_to_the_same_bytes() {
    let text = read(&format!("weaving/readiness/{NAME}.wif"));
    let draft = wif::parse(&text).expect("the fixture parses");
    assert_eq!(wif::write(&draft), text, "re-saving gives the same bytes");
    assert_eq!(text, wif::write(&drawn()), "the file is the drawn draft");
}

#[test]
fn readiness_matches_the_oracle() {
    let draft = wif::parse(&read(&format!("weaving/readiness/{NAME}.wif"))).unwrap();
    let looms = loom_file::read(&read("weaving/looms/looms.json")).expect("looms.json");
    let loom = looms
        .looms
        .iter()
        .find(|l| l.id == LOOM)
        .expect("the jack loom");
    let report = check(&draft, loom, &LoomCheckInput::default());
    let r = ready_to_make(&draft, LoomCheck::Checked(&report), PlanInput::NotPlanned);

    let oracle: Value =
        serde_json::from_str(&read(&format!("weaving/readiness/{NAME}.expect.json"))).unwrap();
    assert_eq!(oracle["loom"], LOOM);
    let verdict = serde_json::to_value(r.verdict()).unwrap();
    assert_eq!(verdict, oracle["verdict"], "verdict");
    let checked: Vec<&str> = r.checked.iter().map(|c| c.as_str()).collect();
    let want_checked: Vec<&str> = oracle["checked"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(checked, want_checked, "checks");
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
    // The blocking set is exactly the structural errors (what the PDF's problems box lists).
    let structural = ply_weave::validate::validate(&draft)
        .into_iter()
        .filter(|i| i.severity == Severity::Error)
        .count();
    assert_eq!(r.count(Severity::Error), structural as u64);
    assert_eq!(oracle["errors"], r.count(Severity::Error));
}
