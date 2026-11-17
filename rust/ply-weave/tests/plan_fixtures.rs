//! The warp and weft plan acceptance fixtures (roadmap M8-03, ADR 0019): a towel and a scarf
//! planned from a finished size through a sampled swatch and a loom to a material estimate, checked
//! against the hand-worked oracles in `fixtures/weaving/plans/` (every input with its source and
//! basis, every figure, the denting, the loom checks, the supply, the issues and the notes).
//!
//! Run: `cargo test -p ply-weave --test plan_fixtures`

use ply_common::materials_file::{read, MaterialLibrary};
use ply_common::Unit;
use ply_weave::feasibility::{LoomSeverity, Sett};
use ply_weave::loom::{DentUnit, LoomProfile};
use ply_weave::worksheet::{
    work_out, DraftFacts, FigureUnit, IssueKind, SupplyRole, WeavePlan, Worksheet, WorksheetRequest,
};
use serde_json::Value;

const DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/weaving/plans");

struct Fixture {
    input: Value,
    expect: Value,
    library: MaterialLibrary,
    loom: Option<LoomProfile>,
}

fn fixture(name: &str) -> Fixture {
    let input: Value =
        serde_json::from_str(&std::fs::read_to_string(format!("{DIR}/{name}.plan.json")).unwrap())
            .unwrap();
    let expect: Value = serde_json::from_str(
        &std::fs::read_to_string(format!("{DIR}/{name}.expect.json")).unwrap(),
    )
    .unwrap();
    let library = read(&input["materials"].to_string()).expect("the records are valid");
    let loom: Option<LoomProfile> = serde_json::from_value(input["loom"].clone()).unwrap();
    if let Some(l) = &loom {
        assert!(l.problems().is_empty(), "{:?}", l.problems());
    }
    Fixture {
        input,
        expect,
        library,
        loom,
    }
}

fn sett(v: &Value) -> Option<Sett> {
    if v.is_null() {
        return None;
    }
    Some(Sett {
        ends: v["ends"].as_f64().unwrap(),
        per: match v["per"].as_str().unwrap() {
            "inch" => Unit::Inches,
            _ => Unit::Centimeters,
        },
    })
}

fn run(f: &Fixture, plan: &WeavePlan) -> Worksheet {
    let draft = &f.input["draft"];
    let req = WorksheetRequest {
        plan,
        swatch: plan
            .swatch_id
            .as_deref()
            .and_then(|id| f.library.swatch(id)),
        warp: plan
            .warp_material_id
            .as_deref()
            .and_then(|id| f.library.material(id)),
        weft: plan
            .weft_material_id
            .as_deref()
            .and_then(|id| f.library.material(id)),
        loom: f.loom.as_ref(),
        loom_sett: sett(&f.input["loomSett"]),
        draft: DraftFacts {
            ends: draft["ends"].as_u64().unwrap() as usize,
            mean_strands: draft["meanStrands"].as_f64().unwrap(),
            file_sett: sett(&draft["fileSett"]),
        },
        metric: f.input["metric"].as_bool().unwrap(),
    };
    work_out(&req)
}

fn close(what: &str, got: f64, want: f64, tol: f64) {
    assert!(
        (got - want).abs() <= tol * want.abs().max(1.0),
        "{what}: got {got}, want {want}"
    );
}

fn unit_name(u: FigureUnit) -> String {
    match u {
        FigureUnit::Count => "count".into(),
        FigureUnit::Length(l) => l.symbol().into(),
    }
}

fn severity(s: LoomSeverity) -> &'static str {
    match s {
        LoomSeverity::NotFeasible => "not_feasible",
        LoomSeverity::Advice => "advice",
        LoomSeverity::NotChecked => "not_checked",
        LoomSeverity::Fits => "fits",
    }
}

fn role(r: SupplyRole) -> &'static str {
    match r {
        SupplyRole::Warp => "warp",
        SupplyRole::Weft => "weft",
        SupplyRole::WarpAndWeft => "warp_and_weft",
    }
}

fn check_case(name: &str, case: &str, w: &Worksheet, e: &Value, tol: f64) {
    let at = format!("{name}/{case}");
    // Inputs: every one, in order, with its source and its words.
    let want = e["inputs"].as_array().unwrap();
    let got: Vec<_> = w.inputs.iter().map(|i| i.key.as_str()).collect();
    let want_keys: Vec<_> = want.iter().map(|i| i["key"].as_str().unwrap()).collect();
    assert_eq!(got, want_keys, "{at}: input keys");
    for (g, x) in w.inputs.iter().zip(want) {
        let k = &g.key;
        assert_eq!(g.label, x["label"].as_str().unwrap(), "{at} {k} label");
        assert_eq!(
            g.source.as_str(),
            x["source"].as_str().unwrap(),
            "{at} {k} source"
        );
        assert_eq!(g.value, x["value"].as_str().unwrap(), "{at} {k} value");
        assert_eq!(g.basis, x["basis"].as_str().unwrap(), "{at} {k} basis");
    }
    // Figures.
    let want = e["figures"].as_array().unwrap();
    let got: Vec<_> = w.figures.iter().map(|f| f.key).collect();
    let want_keys: Vec<_> = want.iter().map(|f| f["key"].as_str().unwrap()).collect();
    assert_eq!(got, want_keys, "{at}: figure keys");
    for (g, x) in w.figures.iter().zip(want) {
        let k = g.key;
        close(
            &format!("{at} {k}"),
            g.value,
            x["value"].as_f64().unwrap(),
            tol,
        );
        assert_eq!(g.label, x["label"].as_str().unwrap(), "{at} {k} label");
        assert_eq!(unit_name(g.unit), x["unit"].as_str().unwrap(), "{at} {k}");
        assert_eq!(g.text, x["text"].as_str().unwrap(), "{at} {k} text");
        assert_eq!(
            g.assumed,
            x["assumed"].as_bool().unwrap(),
            "{at} {k} assumed"
        );
        assert!(!g.working.is_empty(), "{at} {k} has its working");
        for key in &g.uses {
            assert!(
                w.input(key).is_some(),
                "{at} {k} uses {key}, which is an input"
            );
        }
    }
    // Denting.
    match (&w.denting, &e["denting"]) {
        (None, Value::Null) => {}
        (Some(d), x) => {
            assert_eq!(d.reed.dents, x["reed"]["dents"].as_f64().unwrap(), "{at}");
            let per = match d.reed.per {
                DentUnit::PerInch => "inch",
                DentUnit::Per10Cm => "10cm",
            };
            assert_eq!(per, x["reed"]["per"].as_str().unwrap(), "{at}");
            let order: Vec<u64> = x["order"]
                .as_array()
                .unwrap()
                .iter()
                .map(|n| n.as_u64().unwrap())
                .collect();
            assert_eq!(
                d.order.iter().map(|&n| u64::from(n)).collect::<Vec<_>>(),
                order,
                "{at}"
            );
            assert_eq!(u64::from(d.dents), x["dents"].as_u64().unwrap(), "{at}");
            close(
                &format!("{at} denting width"),
                d.width.value,
                x["width"]["value"].as_f64().unwrap(),
                tol,
            );
            assert_eq!(d.width.unit.symbol(), x["width"]["unit"].as_str().unwrap());
            assert_eq!(d.text, x["text"].as_str().unwrap(), "{at} denting");
        }
        (None, x) => panic!("{at}: no denting, want {x}"),
    }
    // Checks.
    let want = e["checks"].as_array().unwrap();
    assert_eq!(w.checks.len(), want.len(), "{at}: {:?}", w.checks);
    for (g, x) in w.checks.iter().zip(want) {
        assert_eq!(g.code, x["code"].as_str().unwrap(), "{at}");
        assert_eq!(
            severity(g.severity),
            x["severity"].as_str().unwrap(),
            "{at}"
        );
        assert_eq!(g.message, x["message"].as_str().unwrap(), "{at}");
    }
    // Supply.
    let want = e["supply"].as_array().unwrap();
    assert_eq!(w.supply.len(), want.len(), "{at}: {:?}", w.supply);
    for (g, x) in w.supply.iter().zip(want) {
        assert_eq!(role(g.role), x["role"].as_str().unwrap(), "{at}");
        assert_eq!(g.material_id, x["material_id"].as_str().unwrap(), "{at}");
        close(
            &format!("{at} need"),
            g.need.value,
            x["need"]["value"].as_f64().unwrap(),
            tol,
        );
        assert_eq!(g.need.unit.symbol(), x["need"]["unit"].as_str().unwrap());
        let m = g.need_mass.unwrap();
        close(
            &format!("{at} need mass"),
            m.value,
            x["need_mass"]["value"].as_f64().unwrap(),
            tol,
        );
        assert_eq!(m.unit.symbol(), x["need_mass"]["unit"].as_str().unwrap());
        close(
            &format!("{at} on hand"),
            g.on_hand.unwrap().value,
            x["on_hand"]["value"].as_f64().unwrap(),
            tol,
        );
        assert_eq!(g.on_hand_about, x["on_hand_about"].as_bool().unwrap());
        close(
            &format!("{at} remaining"),
            g.remaining.unwrap().value,
            x["remaining"]["value"].as_f64().unwrap(),
            tol,
        );
        assert_eq!(g.text, x["text"].as_str().unwrap(), "{at} supply");
        assert_eq!(
            g.assumed,
            x["assumed"].as_bool().unwrap(),
            "{at} supply assumed"
        );
    }
    // Issues and notes.
    let want = e["issues"].as_array().unwrap();
    assert_eq!(w.issues.len(), want.len(), "{at}: {:?}", w.issues);
    for (g, x) in w.issues.iter().zip(want) {
        assert_eq!(g.code, x["code"].as_str().unwrap(), "{at}");
        let kind = match g.kind {
            IssueKind::Invalid => "invalid",
            IssueKind::Needed => "needed",
        };
        assert_eq!(kind, x["kind"].as_str().unwrap(), "{at}");
        assert_eq!(g.field, x["field"].as_str().unwrap(), "{at}");
        assert_eq!(g.message, x["message"].as_str().unwrap(), "{at}");
    }
    let input_notes: Vec<(&str, &str)> = e["input_notes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| (n["key"].as_str().unwrap(), n["text"].as_str().unwrap()))
        .collect();
    let got: Vec<(&str, &str)> = w
        .input_notes
        .iter()
        .map(|n| (n.key.as_str(), n.text.as_str()))
        .collect();
    assert_eq!(got, input_notes, "{at}: input notes");
    for (key, _) in &got {
        assert!(
            w.input(key).is_some(),
            "{at}: a note explains {key}, an input"
        );
    }
    let notes: Vec<&str> = e["notes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n.as_str().unwrap())
        .collect();
    assert_eq!(w.notes, notes, "{at}: notes");
}

fn check_fixture(name: &str) {
    let f = fixture(name);
    let tol = f.expect["tolerance"].as_f64().unwrap();
    for case in f.input["cases"].as_array().unwrap() {
        let case_name = case["name"].as_str().unwrap();
        let plan: WeavePlan = serde_json::from_value(case["plan"].clone()).unwrap();
        // The plan record reads back as written (the sidecar shape).
        assert_eq!(
            serde_json::to_value(&plan).unwrap(),
            case["plan"],
            "{name}/{case_name}: the plan record round-trips"
        );
        let before = f.library.clone();
        let w = run(&f, &plan);
        assert_eq!(
            f.library, before,
            "{name}/{case_name}: the records are never changed"
        );
        check_case(name, case_name, &w, &f.expect["cases"][case_name], tol);
    }
}

#[test]
fn the_towel_plan() {
    check_fixture("towel");
}

#[test]
fn the_scarf_plan() {
    check_fixture("scarf");
}

/// Overriding one assumption changes only what depends on it: the towel's take-up override leaves
/// every width figure as it was and moves every length, warp and weft figure the same way.
#[test]
fn one_override_moves_only_what_uses_it() {
    let f = fixture("towel");
    let cases = f.input["cases"].as_array().unwrap();
    let plan =
        |i: usize| -> WeavePlan { serde_json::from_value(cases[i]["plan"].clone()).unwrap() };
    let a = run(&f, &plan(0));
    let b = run(&f, &plan(1));
    for key in [
        "width_in_reed_target",
        "warp_ends",
        "width_in_reed",
        "finished_width",
        "weft_per_pick",
    ] {
        assert_eq!(
            a.figure(key).unwrap().value,
            b.figure(key).unwrap().value,
            "{key}"
        );
    }
    for key in [
        "woven_length",
        "warp_length",
        "warp_yarn",
        "weft_picks",
        "weft_yarn",
    ] {
        assert!(
            b.figure(key).unwrap().value > a.figure(key).unwrap().value,
            "{key}: a larger take-up needs more"
        );
    }
}
