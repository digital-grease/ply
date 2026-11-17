//! Invalid bands (`fixtures/tablet/invalid/`, listed with their hand-written expectations in
//! `cases.expect.json`): each is one small band with one defect, and validation must list exactly the
//! expected diagnostics (code, severity, typed location); a band with errors must be refused by
//! simulation with the same errors; a band that only warns must still simulate. Bands past the size
//! limits that would be large files (1,001 cards, 10,001 segments, oversized text) are built here
//! instead of stored.
//!
//! Run: `cargo test -p ply-tablet --test invalid_fixtures`

use ply_tablet::{
    expanded_picks, state_after, try_simulate, try_simulate_all, validate, CardPosition,
    HoleThreads, PickNote, PickSpec, Segment, Severity, Tablet, TabletBand, TabletCode,
    TabletError, TabletLimits, TabletLocation, ThreadingDirection, Turn, TurnSequence, MAX_CARDS,
    MAX_PACKS, MAX_PICKS, MAX_SEGMENTS, MAX_TEXT_BYTES,
};
use serde_json::Value;

fn read(name: &str) -> String {
    let path = format!(
        "{}/../../fixtures/tablet/invalid/{name}",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
}

#[test]
fn invalid_fixtures_give_exactly_their_diagnostics() {
    let exp: Value = serde_json::from_str(&read("cases.expect.json")).unwrap();
    let cases = exp["cases"].as_array().unwrap();
    assert!(cases.len() >= 24);
    for case in cases {
        let file = case["file"].as_str().unwrap();
        let text = read(file);
        let parsed: Result<TabletBand, _> = serde_json::from_str(&text);
        if case["outcome"] == "unreadable" {
            assert!(parsed.is_err(), "{file}: should not deserialize");
            continue;
        }
        let band = parsed.unwrap_or_else(|e| panic!("{file}: {e}"));
        let diags = validate(&band);
        let want = case["diagnostics"].as_array().unwrap();
        assert_eq!(diags.len(), want.len(), "{file}: {diags:#?}");
        for (d, w) in diags.iter().zip(want) {
            assert_eq!(d.code.as_str(), w["code"], "{file}");
            assert_eq!(
                serde_json::to_value(d.severity).unwrap(),
                w["severity"],
                "{file}"
            );
            assert_eq!(
                serde_json::to_value(&d.location).unwrap(),
                w["location"],
                "{file}: location"
            );
            assert!(!d.message.is_empty());
            if let Some(part) = w.get("remediation_contains") {
                let r = d.remediation.as_deref().unwrap_or("");
                assert!(
                    r.contains(part.as_str().unwrap()),
                    "{file}: remediation {r:?}"
                );
            }
        }
        let sim = try_simulate_all(&band, &TabletLimits::DEFAULT);
        match case["outcome"].as_str().unwrap() {
            "refused" => match sim {
                Err(TabletError::Invalid(errors)) => {
                    assert_eq!(errors, diags, "{file}: refused with every error");
                    assert!(errors.iter().all(|d| d.severity == Severity::Error));
                    assert!(errors.iter().all(|d| d.code != TabletCode::ListCapped));
                    assert!(state_after(&band, 0, &TabletLimits::DEFAULT).is_err());
                }
                other => panic!("{file}: expected a refusal, got {other:?}"),
            },
            "simulates" => {
                sim.unwrap_or_else(|e| panic!("{file}: {e}"));
            }
            o => panic!("{file}: unknown outcome {o}"),
        }
    }
}

fn card(i: usize) -> Tablet {
    Tablet::new(
        format!("card-{i}"),
        HoleThreads::all(0),
        ThreadingDirection::S,
        CardPosition::ply_home(),
    )
}

fn small_band(cards: usize, turning: Vec<Segment>) -> TabletBand {
    TabletBand {
        palette: vec![ply_common::Color::BLACK],
        cards: (1..=cards).map(card).collect(),
        turning: TurnSequence::new(turning),
        ..TabletBand::default()
    }
}

fn only_code(band: &TabletBand) -> Vec<TabletCode> {
    validate(band).iter().map(|d| d.code).collect()
}

#[test]
fn one_card_past_the_card_limit_is_refused_alone() {
    let n = MAX_CARDS + 1;
    let band = small_band(
        n,
        vec![Segment::new(1, vec![PickSpec::all(Turn::Forward, n)])],
    );
    let diags = validate(&band);
    assert_eq!(diags.len(), 1, "{diags:#?}");
    assert_eq!(diags[0].code, TabletCode::TooLarge);
    assert_eq!(diags[0].location, TabletLocation::Band);
    assert!(
        diags[0].message.contains("1,001 cards"),
        "{}",
        diags[0].message
    );
    assert!(matches!(
        try_simulate_all(&band, &TabletLimits::DEFAULT),
        Err(TabletError::Invalid(_))
    ));
    // Exactly at the limit is fine.
    let ok = small_band(
        MAX_CARDS,
        vec![Segment::new(
            1,
            vec![PickSpec::all(Turn::Forward, MAX_CARDS)],
        )],
    );
    assert!(validate(&ok).is_empty());
}

#[test]
fn too_many_segments_packs_or_colours_are_refused() {
    let seg = || Segment::new(1, vec![PickSpec::all(Turn::Forward, 1)]);
    let band = small_band(1, (0..=MAX_SEGMENTS).map(|_| seg()).collect());
    assert_eq!(only_code(&band), [TabletCode::TooLarge]);
    assert!(expanded_picks(&band.turning, &TabletLimits::DEFAULT).is_err());

    let mut band = small_band(1, vec![seg()]);
    band.palette = vec![ply_common::Color::WHITE; 257];
    assert_eq!(only_code(&band), [TabletCode::TooLarge]);

    let mut band = small_band(1, vec![seg()]);
    band.packs = (0..1001)
        .map(|i| ply_tablet::Pack {
            id: format!("p{i}"),
            name: String::new(),
            cards: vec![],
        })
        .collect();
    assert_eq!(only_code(&band), [TabletCode::TooLarge]);
}

#[test]
fn repeat_expansion_is_counted_before_anything_is_allocated() {
    let limits = TabletLimits::DEFAULT;
    let pick = || PickSpec::all(Turn::Forward, 1);
    // Exactly the cap.
    let at_cap = TurnSequence::new(vec![Segment::new(MAX_PICKS, vec![pick()])]);
    assert_eq!(expanded_picks(&at_cap, &limits).unwrap(), MAX_PICKS);
    // One past it.
    let past = TurnSequence::new(vec![
        Segment::new(MAX_PICKS / 2, vec![pick(), pick()]),
        Segment::new(1, vec![pick()]),
    ]);
    assert!(expanded_picks(&past, &limits).is_err());
    // Past u32 within one segment, and summed over many.
    let huge = TurnSequence::new(vec![Segment::new(u32::MAX, vec![pick(), pick(), pick()])]);
    assert!(expanded_picks(&huge, &limits).is_err());
    let many = TurnSequence::new(
        (0..3)
            .map(|_| Segment::new(u32::MAX, vec![pick()]))
            .collect(),
    );
    assert!(expanded_picks(&many, &limits).is_err());
    // An empty segment repeated u32::MAX times expands to nothing, and is not spun through.
    let empty = TurnSequence::new(vec![
        Segment::new(u32::MAX, vec![]),
        Segment::new(2, vec![pick()]),
    ]);
    assert_eq!(expanded_picks(&empty, &limits).unwrap(), 2);
    let band = small_band(1, empty.segments.clone());
    let w = try_simulate_all(&band, &limits).unwrap();
    assert_eq!(w.picks(), 2);
    assert_eq!(w.info(2).unwrap().segment, 2);
    // The window cap is checked before the window is allocated.
    let wide = small_band(
        1000,
        vec![Segment::new(2000, vec![PickSpec::all(Turn::Forward, 1000)])],
    );
    assert!(matches!(
        try_simulate(&wide, 1..=1001, &limits),
        Err(TabletError::WindowTooLarge {
            cells: 1_001_000,
            ..
        })
    ));
    assert!(try_simulate(&wide, 1001..=2000, &limits).is_ok());
    // Windows outside the band, empty or reversed, are refused.
    for (a, b) in [(0, 1), (3, 2), (1, 2001), (2001, 2001)] {
        assert!(matches!(
            try_simulate(&wide, a..=b, &limits),
            Err(TabletError::InvalidWindow { .. })
        ));
    }
    assert!(matches!(
        state_after(&wide, 2001, &limits),
        Err(TabletError::PickOutOfRange {
            pick: 2001,
            picks: 2000
        })
    ));
}

#[test]
fn oversized_text_fields_are_refused() {
    let long = "x".repeat(MAX_TEXT_BYTES + 1);
    let mut band = small_band(
        1,
        vec![Segment::new(1, vec![PickSpec::all(Turn::Forward, 1)])],
    );
    band.turning.segments[0].picks[0].note = Some(PickNote {
        kind: ply_tablet::NoteKind::Other,
        text: long.clone(),
    });
    assert_eq!(only_code(&band), [TabletCode::TooLarge]);

    let mut band = small_band(1, vec![Segment::new(1, vec![PickSpec::new("?")])]);
    band.turning.segments[0].picks[0]
        .unsupported
        .insert("card-1".into(), long.clone());
    assert_eq!(only_code(&band), [TabletCode::TooLarge]);

    // Ids follow the id grammar (at most 64 bytes), so a long one is an invalid id.
    let mut band = small_band(1, vec![]);
    band.cards[0].id = ply_tablet::CardId(long);
    assert_eq!(only_code(&band), [TabletCode::IdInvalid]);
}

#[test]
fn ids_follow_the_shared_grammar() {
    // The document example's ids (ADR 0018 section 14) are valid; others are refused with the card
    // or pack named.
    for ok in ["card-1", "pack-2", "c", "A_1-b", &"x".repeat(64)] {
        let mut band = small_band(1, vec![]);
        band.cards[0].id = ply_tablet::CardId(ok.to_string());
        band.packs = vec![ply_tablet::Pack {
            id: ok.to_string(),
            name: "Left".into(),
            cards: vec![ply_tablet::CardId(ok.to_string())],
        }];
        assert!(validate(&band).is_empty(), "{ok}");
    }
    for bad in ["", "-a", "_a", "a b", "a/b", "é", &"x".repeat(65)] {
        let mut band = small_band(2, vec![]);
        band.cards[1].id = ply_tablet::CardId(bad.to_string());
        let diags = validate(&band);
        assert_eq!(diags.len(), 1, "{bad:?}: {diags:#?}");
        assert_eq!(diags[0].code, TabletCode::IdInvalid);
        assert_eq!(diags[0].location, TabletLocation::Card { card: 2 });
    }
}

#[test]
fn one_pack_cannot_list_more_entries_than_a_band_has_cards() {
    // A pack listing a card 1,001 times is refused before its entries are counted, and a pack at the
    // limit gives one bounded diagnostic: the pack numbers and names are capped, the listings
    // counted.
    let mut band = small_band(2, vec![]);
    band.packs = vec![ply_tablet::Pack {
        id: "p".into(),
        name: "Left".into(),
        cards: vec!["card-1".into(); MAX_CARDS + 1],
    }];
    assert_eq!(only_code(&band), [TabletCode::TooLarge]);

    let mut band = small_band(1, vec![]);
    band.packs = (0..MAX_PACKS)
        .map(|i| ply_tablet::Pack {
            id: format!("p{i}"),
            name: "n".repeat(MAX_TEXT_BYTES),
            cards: vec!["card-1".into(); MAX_CARDS],
        })
        .collect();
    let diags = validate(&band);
    assert_eq!(diags.len(), 1);
    match &diags[0].location {
        TabletLocation::PackCard {
            card,
            packs,
            listings,
        } => {
            assert_eq!(*card, 1);
            assert_eq!(packs.packs.len(), ply_tablet::MAX_LOCATION_PACKS);
            assert_eq!(packs.total, MAX_PACKS as u32);
            assert_eq!(*listings, (MAX_PACKS * MAX_CARDS) as u32);
        }
        other => panic!("{other:?}"),
    }
    // The names are quoted in short: the message stays small whatever the input.
    assert!(diags[0].message.len() < 400, "{}", diags[0].message.len());
}

#[test]
fn errors_past_the_cap_are_counted_in_the_refusal() {
    // 3,000 bad letters: the refusal lists 1,000 of them, the length error, and says how many more.
    let band = small_band(
        2,
        vec![Segment::new(1, vec![PickSpec::new("x".repeat(3_000))])],
    );
    match try_simulate_all(&band, &TabletLimits::DEFAULT) {
        Err(TabletError::Invalid(errors)) => {
            let letters = errors
                .iter()
                .filter(|d| d.code == TabletCode::TurnLetter)
                .count();
            assert_eq!(letters, ply_tablet::MAX_DIAGNOSTICS_PER_CODE);
            assert!(errors.iter().any(|d| d.code == TabletCode::TurnsLength));
            assert!(errors.iter().any(|d| d.location
                == TabletLocation::Omitted {
                    code: TabletCode::TurnLetter,
                    count: 2_000
                }));
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn limits_that_could_overflow_are_refused() {
    let band = small_band(1, vec![Segment::new(1, vec![PickSpec::new("F")])]);
    let wide = TabletLimits {
        max_picks: i32::MAX as u32 + 1,
        ..TabletLimits::DEFAULT
    };
    assert!(wide.unsound().is_some());
    assert_eq!(
        ply_tablet::validate_with(&band, &wide)
            .iter()
            .map(|d| d.code)
            .collect::<Vec<_>>(),
        [TabletCode::TooLarge]
    );
    assert!(matches!(
        try_simulate_all(&band, &wide),
        Err(TabletError::Invalid(_))
    ));
    assert!(expanded_picks(&band.turning, &wide).is_err());
    // The largest sound limit is accepted.
    let edge = TabletLimits {
        max_picks: i32::MAX as u32,
        ..TabletLimits::DEFAULT
    };
    assert!(edge.unsound().is_none());
    assert!(try_simulate_all(&band, &edge).is_ok());
}

#[test]
fn an_empty_band_is_a_valid_partial_document() {
    // No cards and no picks: nothing to report, and an empty window.
    let band = small_band(0, vec![]);
    assert!(validate(&band).is_empty());
    let w = try_simulate_all(&band, &TabletLimits::DEFAULT).unwrap();
    assert_eq!((w.first_pick, w.last_pick, w.picks()), (1, 0, 0));
    assert!(w.rows.is_empty() && w.cells.is_empty() && w.row(1).is_none());
    assert_eq!(
        state_after(&band, 0, &TabletLimits::DEFAULT).unwrap().pick,
        0
    );
    // Cards but no picks: the same empty window.
    let band = small_band(3, vec![]);
    let w = try_simulate_all(&band, &TabletLimits::DEFAULT).unwrap();
    assert_eq!((w.picks(), w.cards), (0, 3));
    // Picks but no cards: no card turns, but there is no card to idle either, so no all-idle
    // warning.
    let band = small_band(0, vec![Segment::new(5, vec![PickSpec::new("")])]);
    assert!(validate(&band).is_empty(), "{:#?}", validate(&band));
    let w = try_simulate_all(&band, &TabletLimits::DEFAULT).unwrap();
    assert_eq!(w.picks(), 5);
    assert!(w.rows.iter().all(|r| !r.all_idle));
}

#[test]
fn every_structural_error_is_listed_not_just_the_first() {
    let mut band = small_band(
        3,
        vec![
            Segment::new(0, vec![PickSpec::new("FFF")]),
            Segment::new(
                1,
                vec![
                    PickSpec::new("FZ"),
                    PickSpec::new("?F?").with_flip(&["nope"]),
                ],
            ),
        ],
    );
    band.cards[1].start = ply_tablet::Arrangement::new(
        ply_tablet::Hole::B,
        ply_tablet::Hole::D,
        ply_tablet::Hole::C,
        ply_tablet::Hole::A,
    );
    band.cards[2].threads.c = Some(9);
    let codes = only_code(&band);
    // Listed in code order: start, length, letter, unsupported text (x2), card ref, palette, repeat.
    assert_eq!(
        codes,
        [
            TabletCode::StartIllegal,
            TabletCode::TurnsLength,
            TabletCode::TurnLetter,
            TabletCode::UnsupportedText,
            TabletCode::UnsupportedText,
            TabletCode::CardRef,
            TabletCode::PaletteRef,
            TabletCode::RepeatZero,
        ]
    );
    match try_simulate_all(&band, &TabletLimits::DEFAULT) {
        Err(TabletError::Invalid(errors)) => assert_eq!(errors.len(), 8),
        other => panic!("{other:?}"),
    }
}
