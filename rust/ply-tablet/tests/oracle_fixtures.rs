//! The oracle bands of ADR 0018 (the two of sections 11 and 12, and a third sampler worked by hand
//! from the same rules), as exact table tests. Each fixture in
//! `fixtures/tablet/oracle/` is a band (`.band.json`, the engine's own band shape), its oracle
//! (`.expect.json`, transcribed from the ADR's hand-worked tables or worked by hand from its rules,
//! never from this engine) and a
//! record (`.fixture.toml`). For every pick and every card: the action, threading, arrangement after
//! the turn, top-face and back threads with their colours, twining, reversal, `twist` and `woven`;
//! then every face cell of the drawn faces, every diagnostic (code, severity, typed location, in
//! order), and the final state.
//!
//! Run: `cargo test -p ply-tablet --test oracle_fixtures`

use ply_tablet::{
    state_after, try_simulate_all, validate, validate_with, Face, FaceColor, FaceThread,
    TabletBand, TabletCode, TabletLimits, TabletLocation, TabletWindow, Turn,
};
use serde_json::Value;

const ORACLES: [&str; 3] = [
    "band-1-threaded-in",
    "sampler-2-starts-idles-flip",
    "sampler-3-flip-then-opposite",
];

fn read(name: &str, ext: &str) -> String {
    let path = format!(
        "{}/../../fixtures/tablet/oracle/{name}.{ext}",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
}

fn band(name: &str) -> TabletBand {
    serde_json::from_str(&read(name, "band.json")).unwrap_or_else(|e| panic!("{name}: {e}"))
}

fn oracle(name: &str) -> Value {
    serde_json::from_str(&read(name, "expect.json")).unwrap()
}

fn letters(exp: &Value) -> Vec<String> {
    exp["palette_letters"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect()
}

/// The oracle's words for a face: "A", "A continues", "A or D".
fn hole_text(f: FaceThread) -> String {
    match f {
        FaceThread::Thread(h) => h.to_string(),
        FaceThread::Continued(h) => format!("{h} continues"),
        FaceThread::Ambiguous(a, b) => format!("{a} or {b}"),
        FaceThread::Empty(h) => format!("{h} empty"),
        FaceThread::Unknown => "unknown".to_string(),
    }
}

fn color_text(band: &TabletBand, card: usize, f: FaceThread, letters: &[String]) -> String {
    let l = |c: Option<u32>| c.map_or("none".to_string(), |c| letters[c as usize].clone());
    match ply_tablet::face_color(band, card, f) {
        FaceColor::One(c) => match f {
            FaceThread::Continued(_) => format!("{} continues", l(Some(c))),
            _ => l(Some(c)),
        },
        FaceColor::Either(a, b) => format!("{} or {}", l(a), l(b)),
        FaceColor::NotModelled => "none".to_string(),
        FaceColor::Unknown => "unknown".to_string(),
    }
}

/// One drawn row of a face as the oracle writes it: colour letters, `?` for an ambiguous cell.
fn face_text(
    w: &TabletWindow,
    band: &TabletBand,
    pick: u32,
    face: Face,
    letters: &[String],
) -> String {
    w.face_row(band, pick, face)
        .unwrap()
        .iter()
        .map(|cell| match cell.color {
            FaceColor::One(c) => letters[c as usize].clone(),
            FaceColor::Either(..) => "?".to_string(),
            FaceColor::NotModelled => "-".to_string(),
            FaceColor::Unknown => "x".to_string(),
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn diag_json(d: &ply_tablet::Diagnostic) -> Value {
    serde_json::json!({
        "code": d.code,
        "severity": d.severity,
        "location": d.location,
    })
}

#[test]
fn oracle_bands_match_their_tables_cell_by_cell() {
    for name in ORACLES {
        let band = band(name);
        let exp = oracle(name);
        let letters = letters(&exp);
        let w = try_simulate_all(&band, &TabletLimits::DEFAULT)
            .unwrap_or_else(|e| panic!("{name}: {e}"));
        let picks = exp["picks"].as_u64().unwrap() as u32;
        assert_eq!(w.picks(), picks, "{name}: picks");
        assert_eq!(w.cards, band.cards.len(), "{name}: cards");

        let mut cells = 0;
        for card in exp["cards"].as_array().unwrap() {
            let c = card["card"].as_u64().unwrap() as usize - 1;
            for e in card["picks"].as_array().unwrap() {
                let pick = e["pick"].as_u64().unwrap() as u32;
                let at = format!("{name}: card {}, pick {pick}", c + 1);
                let cp = w.card_pick(pick, c).unwrap();
                assert_eq!(cp.turn.letter().to_string(), e["turn"], "{at}: turn");
                assert_eq!(
                    cp.threading
                        .map(|t| t.letter().to_string())
                        .unwrap_or_default(),
                    e["threading"],
                    "{at}: threading"
                );
                assert_eq!(
                    cp.position.map(|p| p.chart()).unwrap_or_default(),
                    e["position"],
                    "{at}: arrangement after the turn (NT FT FB NB)"
                );
                assert_eq!(hole_text(cp.top), e["top"], "{at}: top-face thread");
                assert_eq!(hole_text(cp.back), e["back"], "{at}: back thread");
                assert_eq!(
                    color_text(&band, c, cp.top, &letters),
                    e["top_color"],
                    "{at}: top colour"
                );
                assert_eq!(
                    color_text(&band, c, cp.back, &letters),
                    e["back_color"],
                    "{at}: back colour"
                );
                assert_eq!(
                    cp.twining.map(|t| t.letter().to_string()),
                    e["twining"].as_str().map(str::to_string),
                    "{at}: twining"
                );
                assert_eq!(cp.reversal, e["reversal"], "{at}: reversal");
                assert_eq!(
                    cp.twist.twist,
                    e["twist"].as_i64().map(|v| v as i32),
                    "{at}: twist"
                );
                assert_eq!(
                    cp.twist.woven,
                    e["woven"].as_i64().map(|v| v as i32),
                    "{at}: woven"
                );
                assert_eq!(cp.released, e["released"], "{at}: release");
                assert_eq!(cp.flipped, e["flipped"], "{at}: flip");
                cells += 1;
            }
        }
        assert_eq!(
            cells,
            band.cards.len() * picks as usize,
            "{name}: every cell checked"
        );

        // The faces as drawn: the top face card 1 first, the back card n first; pick 1 first.
        for (face, key) in [(Face::Top, "top_face"), (Face::Back, "back_face")] {
            if let Some(rows) = exp.get(key) {
                let rows = rows.as_array().unwrap();
                assert_eq!(rows.len(), picks as usize, "{name}: {key} rows");
                for (i, row) in rows.iter().enumerate() {
                    let pick = i as u32 + 1;
                    assert_eq!(
                        face_text(&w, &band, pick, face, &letters),
                        row.as_str().unwrap(),
                        "{name}: {key}, pick {pick}"
                    );
                }
            }
        }
        if let Some(rows) = exp.get("top_slant") {
            for (i, row) in rows.as_array().unwrap().iter().enumerate() {
                let pick = i as u32 + 1;
                let slants: Vec<String> = w
                    .face_row(&band, pick, Face::Top)
                    .unwrap()
                    .iter()
                    .map(|c| c.twining.map_or("|".to_string(), |t| t.slant().to_string()))
                    .collect();
                assert_eq!(
                    slants.join(" "),
                    row.as_str().unwrap(),
                    "{name}: slant, pick {pick}"
                );
            }
        }

        // Every diagnostic, in the engine's documented order.
        let got: Vec<Value> = validate(&band).iter().map(diag_json).collect();
        let want = exp["diagnostics"].as_array().unwrap();
        assert_eq!(&got, want, "{name}: diagnostics");

        // The final state, through the resume entry point.
        let end = state_after(&band, picks, &TabletLimits::DEFAULT).unwrap();
        assert_eq!(end.pick, picks);
        for f in exp["final"].as_array().unwrap() {
            let c = f["card"].as_u64().unwrap() as usize - 1;
            let s = &end.cards[c];
            assert_eq!(
                s.position.unwrap().chart(),
                f["position"],
                "{name}: final card {}",
                c + 1
            );
            assert_eq!(
                s.threading
                    .map(|t| t.letter().to_string())
                    .unwrap_or_default(),
                f["threading"]
            );
            assert_eq!(s.twist.twist, f["twist"].as_i64().map(|v| v as i32));
            assert_eq!(s.twist.woven, f["woven"].as_i64().map(|v| v as i32));
        }
    }
}

#[test]
fn band_1_headline_results() {
    let band = band("band-1-threaded-in");
    let limits = TabletLimits::DEFAULT;
    let home = ply_tablet::CardPosition::ply_home();
    // After the 4 forward turns: S cards +4, Z cards -4.
    let s4 = state_after(&band, 4, &limits).unwrap();
    for (i, c) in s4.cards.iter().enumerate() {
        assert_eq!(
            c.twist.twist,
            Some(if i < 4 { 4 } else { -4 }),
            "card {}",
            i + 1
        );
        assert_eq!(c.position, Some(home));
    }
    // After the 4 backward turns: every card 0 and home.
    let s8 = state_after(&band, 8, &limits).unwrap();
    for c in &s8.cards {
        assert_eq!(c.twist.twist, Some(0));
        assert_eq!(c.position, Some(home));
    }
    // After the mixed block: every card +4 and home.
    let s12 = state_after(&band, 12, &limits).unwrap();
    for c in &s12.cards {
        assert_eq!(c.twist.twist, Some(4));
        assert_eq!(c.position, Some(home));
    }
    // Before any pick: as set up.
    let s0 = state_after(&band, 0, &limits).unwrap();
    assert!(s0
        .cards
        .iter()
        .all(|c| c.position == Some(home) && c.twist.twist == Some(0)));
}

#[test]
fn band_1_runs_are_at_most_three_picks() {
    let band = band("band-1-threaded-in");
    let exp = oracle("band-1-threaded-in");
    // At the default threshold (3) nothing floats too long; at 2, exactly the runs of 3 show.
    assert!(validate(&band)
        .iter()
        .all(|d| d.code != TabletCode::LongFloat));
    let mut tight = band.clone();
    tight.settings.float_warning_picks = 2;
    let runs: Vec<Value> = validate_with(&tight, &TabletLimits::DEFAULT)
        .iter()
        .filter(|d| d.code == TabletCode::LongFloat)
        .map(|d| serde_json::to_value(&d.location).unwrap())
        .collect();
    assert_eq!(&runs, exp["runs_of_three"].as_array().unwrap());
    // And no thread spends 4 picks in one layer.
    tight.settings.float_warning_picks = 3;
    assert!(validate_with(&tight, &TabletLimits::DEFAULT)
        .iter()
        .all(|d| d.code != TabletCode::LongFloat));
    // The run so far of the shown thread at the reversal: A crosses the top on picks 8 and 9 of
    // the Left cards and has been in the upper layer since pick 7.
    let w = try_simulate_all(&band, &TabletLimits::DEFAULT).unwrap();
    assert_eq!(w.card_pick(9, 0).unwrap().top_run, Some(3));
    assert_eq!(w.card_pick(1, 0).unwrap().top_run, Some(1));
    assert_eq!(w.card_pick(2, 0).unwrap().top_run, Some(2));
}

#[test]
fn sampler_2_release_flip_and_floats() {
    let band = band("sampler-2-starts-idles-flip");
    let exp = oracle("sampler-2-starts-idles-flip");
    let diags = validate(&band);
    let released = diags
        .iter()
        .find(|d| d.code == TabletCode::TwistReleased)
        .unwrap();
    let q = &exp["released_quarters"];
    assert_eq!(
        released.location,
        TabletLocation::Pick {
            pick: q["pick"].as_u64().unwrap() as u32,
            cards: ply_tablet::CardSet::one(q["card"].as_u64().unwrap() as u32),
            face: None,
        }
    );
    assert!(
        released
            .message
            .contains(&format!("({} quarter turns)", q["quarters"])),
        "{}",
        released.message
    );
    let flip = diags.iter().find(|d| d.code == TabletCode::Flip).unwrap();
    assert!(flip.message.contains("now Z-threaded"), "{}", flip.message);
    let reversal = diags
        .iter()
        .find(|d| d.code == TabletCode::Reversal)
        .unwrap();
    assert_eq!(reversal.message, "Reversal at pick 3, card 3.");

    let w = try_simulate_all(&band, &TabletLimits::DEFAULT).unwrap();
    // Card 1's thread B has been in the upper layer since pick 1 and shows (as a continued float)
    // on picks 3 and 4; thread C (shown on pick 6) since pick 2.
    assert_eq!(w.card_pick(4, 0).unwrap().top_run, Some(4));
    assert_eq!(w.card_pick(6, 0).unwrap().top_run, Some(5));
    assert_eq!(w.card_pick(6, 0).unwrap().back_run, Some(5));
    // The ambiguous idle has no single run.
    assert_eq!(w.card_pick(1, 3).unwrap().top_run, None);
    assert_eq!(w.card_pick(1, 3).unwrap().turn, Turn::Idle);
    // Picks 3 and 4 are the same written pick worked twice (segment 2, step 1, repeats 1 and 2).
    let (i3, i4) = (w.info(3).unwrap(), w.info(4).unwrap());
    assert_eq!((i3.segment, i3.step, i3.repeat), (2, 1, 1));
    assert_eq!((i4.segment, i4.step, i4.repeat), (2, 1, 2));
    assert_eq!(w.info(6).unwrap().segment, 3);
    assert!(w.rows.iter().all(|r| r.weft == Some(0) && !r.all_idle));
}

#[test]
fn oracle_records_are_complete() {
    for name in ORACLES {
        let record = read(name, "fixture.toml");
        for key in [
            "id = ",
            "title = ",
            "license = ",
            "provenance = ",
            "automated_checks = \"pass\"",
            "practitioner_tablet_check = \"pending\"",
        ] {
            assert!(record.contains(key), "{name}.fixture.toml lacks `{key}`");
        }
        // The band round-trips through the engine's band shape without loss.
        let band = band(name);
        let again: TabletBand =
            serde_json::from_str(&serde_json::to_string(&band).unwrap()).unwrap();
        assert_eq!(again, band, "{name}: round trip");
    }
}
