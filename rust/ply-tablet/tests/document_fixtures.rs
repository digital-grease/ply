//! The native `.plytab` document (ADR 0018 section 14 and its M10-02 amendments) against the
//! fixtures in `fixtures/tablet/documents/`: the three oracle bands as documents, which read to
//! exactly the oracle bands and write back byte for byte, and one-defect documents in `invalid/`
//! (listed with their expected refusal in `invalid/cases.expect.json`): a newer version refused
//! before the document is read, unknown fields, bad envelopes, missing keys. Documents past the size
//! limits are built here rather than stored.
//!
//! Run: `cargo test -p ply-tablet --test document_fixtures`

use ply_tablet::{
    document_schema_version, read_document, validate, write_document, DocumentError, TabletBand,
    TabletDocument, MAX_CARDS, MAX_DOCUMENT_BYTES, MAX_PICKS, MAX_TEXT_BYTES,
};
use serde_json::Value;

const ORACLES: [(&str, &str, &str); 3] = [
    (
        "band-1-threaded-in",
        "Oracle band 1: threaded-in diagonals",
        "An original band made for Ply's tests (ADR 0018 section 11): 8 cards, cards 1 to 4 \
         S-threaded and 5 to 8 Z-threaded, all at Ply home; 4 forward turns, 4 backward, then the \
         Left pack forward and the Right pack backward.",
    ),
    (
        "sampler-2-starts-idles-flip",
        "Oracle sampler 2: starts, idles, a flip, a release",
        "A test sampler, not a design (ADR 0018 section 12): 4 cards, every hole a different colour.",
    ),
    (
        "sampler-3-flip-then-opposite",
        "Oracle sampler 3: a flip, then the opposite turn",
        "A test sampler worked by hand from the rules of ADR 0018, not a design: flips followed by \
         the opposite direction, a release and an empty hole.",
    ),
];

fn fixture(rel: &str) -> String {
    let path = format!("{}/../../fixtures/tablet/{rel}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
}

fn oracle_band(name: &str) -> TabletBand {
    serde_json::from_str(&fixture(&format!("oracle/{name}.band.json"))).unwrap()
}

/// Writes the oracle documents with the engine's own writer. Run on purpose only, after a change to
/// the document shape: `cargo test -p ply-tablet --test document_fixtures -- --ignored`.
#[test]
#[ignore]
fn regenerate_oracle_documents() {
    for (name, title, notes) in ORACLES {
        let doc = TabletDocument {
            name: title.to_string(),
            notes: notes.to_string(),
            band: oracle_band(name),
        };
        let path = format!(
            "{}/../../fixtures/tablet/documents/{name}.plytab",
            env!("CARGO_MANIFEST_DIR")
        );
        std::fs::write(&path, write_document(&doc).unwrap()).unwrap();
    }
}

#[test]
fn oracle_documents_read_as_their_bands_and_round_trip_byte_for_byte() {
    for (name, title, notes) in ORACLES {
        let text = fixture(&format!("documents/{name}.plytab"));
        let loaded = read_document(&text).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(loaded.source_version, 1);
        assert_eq!(loaded.document.name, title);
        assert_eq!(loaded.document.notes, notes);
        assert_eq!(loaded.document.band, oracle_band(name), "{name}");
        // One save gives the same bytes, and so does every save after it.
        let saved = write_document(&loaded.document).unwrap();
        assert_eq!(saved, text, "{name}: not byte for byte");
        let again = write_document(&read_document(&saved).unwrap().document).unwrap();
        assert_eq!(again, text);
        assert_eq!(document_schema_version(&text), Ok(1));
    }
}

#[test]
fn a_hand_formatted_document_settles_after_one_save() {
    // The same band 1, compacted and with its keys in another order: it reads to the same band,
    // and after one save it is the canonical bytes.
    let text = fixture("documents/band-1-threaded-in.plytab");
    let value: Value = serde_json::from_str(&text).unwrap();
    let mut doc = value["document"].as_object().unwrap().clone();
    let name = doc.remove("name").unwrap();
    doc.insert("name".into(), name); // name last
    let compact = serde_json::to_string(&serde_json::json!({
        "document": doc,
        "schema_version": 1,
        "format": "ply.tablet",
    }))
    .unwrap();
    assert_ne!(compact, text);
    let loaded = read_document(&compact).unwrap();
    assert_eq!(write_document(&loaded.document).unwrap(), text);
}

#[test]
fn invalid_documents_are_refused_as_their_cases_say() {
    let exp: Value = serde_json::from_str(&fixture("documents/invalid/cases.expect.json")).unwrap();
    let cases = exp["cases"].as_array().unwrap();
    assert!(cases.len() >= 10);
    for case in cases {
        let file = case["file"].as_str().unwrap();
        let text = fixture(&format!("documents/invalid/{file}"));
        let got = read_document(&text);
        let kind = match &got {
            Ok(_) => "opens",
            Err(DocumentError::NewerVersion { .. }) => "newer",
            Err(DocumentError::WrongFormat { .. }) => "wrong_format",
            Err(DocumentError::TooLarge(_)) => "too_large",
            Err(DocumentError::Malformed(_)) => "malformed",
        };
        assert_eq!(kind, case["outcome"], "{file}: {got:?}");
        if let Some(part) = case.get("message_contains") {
            let message = got
                .as_ref()
                .err()
                .map(|e| e.to_string())
                .unwrap_or_default();
            assert!(
                message.contains(part.as_str().unwrap()),
                "{file}: {message}"
            );
        }
        // The probe agrees with the reader about the envelope.
        match (document_schema_version(&text), kind) {
            (Err(DocumentError::NewerVersion { found, .. }), "newer") => {
                assert_eq!(Value::from(found), case["schema_version"], "{file}")
            }
            (Ok(1), "malformed" | "opens" | "too_large") => {}
            (Err(DocumentError::WrongFormat { .. }), "wrong_format") => {}
            (Err(DocumentError::Malformed(_)), "malformed") => {}
            (other, _) => panic!("{file}: probe {other:?} for {kind}"),
        }
    }
}

#[test]
fn a_document_with_structural_errors_opens_with_its_errors() {
    let text = fixture("documents/invalid/start-illegal-opens.plytab");
    let doc = read_document(&text).unwrap().document;
    let diags = validate(&doc.band);
    assert_eq!(diags[0].code.as_str(), "tablet.start_illegal");
    // And it saves as a draft: the writer keeps what it read.
    assert_eq!(
        read_document(&write_document(&doc).unwrap())
            .unwrap()
            .document,
        doc
    );
}

fn base() -> TabletDocument {
    read_document(&fixture("documents/sampler-2-starts-idles-flip.plytab"))
        .unwrap()
        .document
}

/// Documents past a count limit are refused on read and never written; built here, not stored.
#[test]
fn documents_past_the_limits_are_refused_both_ways() {
    let mut cases: Vec<(&str, TabletDocument)> = Vec::new();
    let mut d = base();
    d.band.cards = (0..=MAX_CARDS)
        .map(|i| {
            let mut c = d.band.cards[0].clone();
            c.id = format!("c{i}").as_str().into();
            c
        })
        .collect();
    cases.push(("1,001 cards", d));
    let mut d = base();
    d.name = "n".repeat(MAX_TEXT_BYTES + 1);
    cases.push(("a long name", d));
    let mut d = base();
    let pick = d.band.turning.segments[0].picks[0].clone();
    d.band.turning.segments[0].picks = vec![pick; MAX_PICKS as usize + 1];
    cases.push(("200,001 written picks", d));
    let mut d = base();
    d.band.turning.segments[0].picks[0].note = Some(ply_tablet::PickNote {
        kind: ply_tablet::NoteKind::Other,
        text: "w".repeat(MAX_TEXT_BYTES + 1),
    });
    cases.push(("a long note", d));
    for (what, doc) in cases {
        assert!(
            matches!(write_document(&doc), Err(DocumentError::TooLarge(_))),
            "{what}: written"
        );
        // Serialized without the writer's check, as a hostile file would be: refused on read.
        let value = serde_json::json!({
            "format": "ply.tablet",
            "schema_version": 1,
            "document": {
                "name": doc.name,
                "notes": doc.notes,
                "palette": ["#1a1a1a", "#f2efe6", "#b3262e", "#d4a017"],
                "weft": 0,
                "cards": serde_json::to_value(&doc.band.cards).unwrap(),
                "turning": serde_json::to_value(&doc.band.turning).unwrap(),
                "settings": serde_json::to_value(doc.band.settings).unwrap(),
            }
        });
        let text = serde_json::to_string(&value).unwrap();
        if text.len() <= MAX_DOCUMENT_BYTES {
            assert!(
                matches!(read_document(&text), Err(DocumentError::TooLarge(_))),
                "{what}: read"
            );
        }
    }
}
