//! The native `.plytab` document (ADR 0018 section 14 and its M10-02 amendments): a versioned
//! envelope around one band with its name and notes.
//!
//! ```json
//! { "format": "ply.tablet", "schema_version": 1, "document": { "name": "...", "notes": "", ... } }
//! ```
//!
//! **Detection (deterministic, ADR 0002 rule 1).** A `.plytab` file is one JSON object whose
//! `format` is exactly `ply.tablet` and whose `schema_version` is a positive integer; the band is the
//! `document` value. There is no legacy version. A file NEWER than [`TABLET_SCHEMA_VERSION`] is
//! refused with [`DocumentError::NewerVersion`] after reading only those two keys, before the
//! document is decoded, so this build never loads (and the app never overwrites) what a later Ply
//! wrote.
//!
//! **Strict.** Unknown fields, unknown values (a threading letter, a hole, a note kind) and repeated
//! keys are refused anywhere in the file: a file with them was not written by this version, and a
//! later version that adds them bumps the schema with a migration. A hole left out of a card is
//! refused rather than read as empty (`null` is an empty hole).
//!
//! **Bounded.** The file is untrusted. Its size is checked before it is parsed, and every count that
//! sizes what the editor holds (cards, palette, packs and their lists, segments, written picks, each
//! pick's lists, every text) is checked against [`TabletLimits`] after it is decoded; past a limit
//! the file is refused as too large. Structural mistakes (an illegal start, a wrong turn string, a
//! repeat that expands past the pick limit) are NOT refused here: a band with errors opens, shows
//! them, and saves as a draft; only simulation and print refuse it. [`write_document`] applies the
//! same limits, so Ply never writes a file it would refuse to read.
//!
//! **Round trip.** [`write_document`] is deterministic (pretty JSON, fields in a fixed order, empty
//! optional lists left out), so a file it wrote reads and writes back byte for byte.
//!
//! **Versions.** 1: this shape, the first. A later bump appends one migration (on JSON values, not
//! on the Rust types) to `MIGRATIONS`, whose length is tied to the version constant.

use crate::band::{
    hex_palette, BandSettings, ColorIndex, Pack, Tablet, TabletBand, TabletLimits, TurnSequence,
};
use ply_common::Color;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The `format` value of a `.plytab` envelope.
pub const TABLET_FORMAT: &str = "ply.tablet";

/// The `.plytab` schema version this build writes, and the newest it reads.
pub const TABLET_SCHEMA_VERSION: u32 = 1;

/// The largest `.plytab` file this build reads or writes, in bytes. A band at the card and pick
/// limits written with repeats is a few hundred kilobytes; one written out pick by pick is larger,
/// and this keeps what the editor holds (and copies to the app) bounded.
pub const MAX_DOCUMENT_BYTES: usize = 16 * 1024 * 1024;

/// The largest file whose envelope is still looked at when it is over [`MAX_DOCUMENT_BYTES`], so a
/// file a newer Ply wrote is reported as newer (never overwritten), not as too large.
pub const MAX_PROBED_DOCUMENT_BYTES: usize = 64 * 1024 * 1024;

/// The most bytes of a band's notes.
pub const MAX_NOTES_BYTES: usize = 100_000;

/// A band as Ply saves it: its name and notes, and the band itself.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TabletDocument {
    pub name: String,
    pub notes: String,
    pub band: TabletBand,
}

/// A document read from a file, with the schema version the file was written at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoadedDocument {
    pub document: TabletDocument,
    /// The file's own schema version. Older than [`TABLET_SCHEMA_VERSION`] means saving upgrades
    /// the file's format (the app keeps a one-time backup of the original first).
    pub source_version: u32,
}

/// Why a `.plytab` file cannot be read or written.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum DocumentError {
    /// Written by a newer Ply: do not read it, do not overwrite it.
    #[error(
        "the band was saved by a newer version of Ply (schema version {found}; this build reads up \
         to {supported})"
    )]
    NewerVersion { found: u64, supported: u32 },
    /// A JSON object with another (or no) `format`.
    #[error("not a Ply tablet weaving band (format {found})")]
    WrongFormat { found: String },
    /// Past a size or count limit.
    #[error("the band is too large: {0}")]
    TooLarge(String),
    /// Not JSON, a malformed envelope, an unknown or repeated field, a missing field, or a value of
    /// the wrong type.
    #[error("the band could not be read: {0}")]
    Malformed(String),
}

/// Parse a `.plytab` file of any supported version (an older one migrated in memory; nothing is
/// written).
pub fn read_document(text: &str) -> Result<LoadedDocument, DocumentError> {
    if text.len() > MAX_DOCUMENT_BYTES {
        if text.len() <= MAX_PROBED_DOCUMENT_BYTES {
            // A newer file is reported as newer, whatever its size.
            if let Err(e @ DocumentError::NewerVersion { .. }) = probe(text) {
                return Err(e);
            }
        }
        return Err(DocumentError::TooLarge(format!(
            "the file is {} bytes; Ply opens bands of up to {} bytes",
            text.len(),
            MAX_DOCUMENT_BYTES
        )));
    }
    let version = probe(text)?;
    let document = if version == TABLET_SCHEMA_VERSION {
        let envelope: EnvelopeIn = serde_json::from_str(text).map_err(malformed)?;
        envelope.document.into()
    } else {
        // An older version: migrate the document as JSON, then read it as the current shape.
        let mut obj: serde_json::Map<String, Value> =
            serde_json::from_str(text).map_err(malformed)?;
        let doc = obj
            .remove("document")
            .ok_or_else(|| DocumentError::Malformed("the envelope has no document".into()))?;
        let doc = migrate(version, doc)?;
        serde_json::from_value::<DocumentIn>(doc)
            .map_err(malformed)?
            .into()
    };
    check_document_limits(&document, &TabletLimits::DEFAULT).map_err(DocumentError::TooLarge)?;
    Ok(LoadedDocument {
        document,
        source_version: version,
    })
}

/// Serialize a document as a current-version `.plytab` envelope (pretty JSON). Refuses a document
/// past the limits [`read_document`] applies, so a file this build would refuse is never written.
pub fn write_document(doc: &TabletDocument) -> Result<String, DocumentError> {
    check_document_limits(doc, &TabletLimits::DEFAULT).map_err(DocumentError::TooLarge)?;
    let b = &doc.band;
    let text = serde_json::to_string_pretty(&EnvelopeOut {
        format: TABLET_FORMAT,
        schema_version: TABLET_SCHEMA_VERSION,
        document: DocumentOut {
            name: &doc.name,
            notes: &doc.notes,
            palette: &b.palette,
            weft: b.weft,
            cards: &b.cards,
            packs: &b.packs,
            turning: &b.turning,
            settings: &b.settings,
        },
    })
    .map_err(|e| DocumentError::Malformed(e.to_string()))?;
    if text.len() > MAX_DOCUMENT_BYTES {
        return Err(DocumentError::TooLarge(format!(
            "it would be {} bytes; Ply saves bands of up to {} bytes",
            text.len(),
            MAX_DOCUMENT_BYTES
        )));
    }
    Ok(text)
}

/// The schema version of a `.plytab` file by the detection rule, without decoding its document.
/// Errors exactly as [`read_document`] would for the envelope itself.
pub fn document_schema_version(text: &str) -> Result<u32, DocumentError> {
    if text.len() > MAX_PROBED_DOCUMENT_BYTES {
        return Err(DocumentError::TooLarge(format!(
            "the file is {} bytes",
            text.len()
        )));
    }
    probe(text)
}

/// Every count that sizes what the editor holds, against `limits` (Ply opens and saves only
/// documents within them): the name and notes; cards, palette, packs, segments and written picks;
/// each pack's list; each pick's turn letters (no more than a band can have cards), release and
/// flip lists and words; and every text field. The first one past its limit, in words.
pub fn check_document_limits(doc: &TabletDocument, limits: &TabletLimits) -> Result<(), String> {
    let text = |what: &str, s: &str, max: usize| -> Result<(), String> {
        if s.len() > max {
            Err(format!("{what} is {} bytes; the limit is {max}", s.len()))
        } else {
            Ok(())
        }
    };
    let count = |what: &str, n: usize, max: usize| -> Result<(), String> {
        if n > max {
            Err(format!("it has {n} {what}; the limit is {max}"))
        } else {
            Ok(())
        }
    };
    let b = &doc.band;
    let max_text = limits.max_text_bytes;
    text("the name", &doc.name, max_text)?;
    text("the notes", &doc.notes, MAX_NOTES_BYTES)?;
    count("cards", b.cards.len(), limits.max_cards)?;
    count("palette colours", b.palette.len(), limits.max_palette)?;
    count("packs", b.packs.len(), limits.max_packs)?;
    count("segments", b.turning.segments.len(), limits.max_segments)?;
    for card in &b.cards {
        text("a card id", card.id.as_str(), max_text)?;
    }
    for pack in &b.packs {
        text("a pack id", &pack.id, max_text)?;
        text("a pack name", &pack.name, max_text)?;
        count("cards in one pack", pack.cards.len(), limits.max_cards)?;
        for id in &pack.cards {
            text("a card id in a pack", id.as_str(), max_text)?;
        }
    }
    // A UTF-8 letter is at most 4 bytes, so a longer turn string cannot be one letter per card.
    let max_turns = limits.max_cards.saturating_mul(4);
    let mut written: u64 = 0;
    for seg in &b.turning.segments {
        written = written.saturating_add(seg.picks.len() as u64);
        if written > u64::from(limits.max_picks) {
            return Err(format!(
                "its turning writes out more than {} picks",
                limits.max_picks
            ));
        }
        for pick in &seg.picks {
            text("a pick's turns", &pick.turns, max_turns)?;
            count(
                "releases before one pick",
                pick.release_twist.len(),
                limits.max_cards,
            )?;
            count("flips before one pick", pick.flip.len(), limits.max_cards)?;
            count(
                "cards with words on one pick",
                pick.unsupported.len(),
                limits.max_cards,
            )?;
            for id in pick.release_twist.iter().chain(&pick.flip) {
                text("a card id in a pick", id.as_str(), max_text)?;
            }
            for (id, words) in &pick.unsupported {
                text("a card id in a pick", id.as_str(), max_text)?;
                text("the words for a card", words, max_text)?;
            }
            if let Some(note) = &pick.note {
                text("a pick note", &note.text, max_text)?;
            }
        }
    }
    Ok(())
}

/// One migration: a document at version `n` in, the same document at version `n + 1` out.
type Migration = fn(Value) -> Result<Value, DocumentError>;

/// The ordered migration chain: `MIGRATIONS[i]` upgrades a document from version `i + 1` to `i + 2`.
/// Its length is tied to [`TABLET_SCHEMA_VERSION`], so bumping the version without appending a
/// migration does not compile. Version 1 is the first, so the chain is empty.
const MIGRATIONS: [Migration; TABLET_SCHEMA_VERSION as usize - 1] = [];

fn migrate(from: u32, mut document: Value) -> Result<Value, DocumentError> {
    // `probe` guarantees 1 <= from <= TABLET_SCHEMA_VERSION.
    for step in &MIGRATIONS[(from as usize).saturating_sub(1)..] {
        document = step(document)?;
    }
    Ok(document)
}

fn malformed(e: serde_json::Error) -> DocumentError {
    DocumentError::Malformed(e.to_string())
}

/// The envelope keys alone. Everything else in the object (the document) is skipped unread, and so
/// is any `format` or `schema_version` value that is not what the rule expects: nothing in the file
/// is built in memory except a short format name, so probing a hostile file costs one pass over its
/// bytes and no allocation in proportion to it.
#[derive(Deserialize)]
struct Probe {
    #[serde(default)]
    format: Option<ProbedFormat>,
    #[serde(default)]
    schema_version: Option<ProbedVersion>,
}

/// What the `format` key holds: a short string (a format name is a few bytes), or only the kind of
/// value it was.
enum ProbedFormat {
    Name(String),
    Other(&'static str),
}

/// What the `schema_version` key holds: a positive integer, or anything else.
enum ProbedVersion {
    Positive(u64),
    Bad,
}

/// Skip a list or object without building it.
fn drain_seq<'de, A: serde::de::SeqAccess<'de>>(mut seq: A) -> Result<(), A::Error> {
    while seq.next_element::<serde::de::IgnoredAny>()?.is_some() {}
    Ok(())
}

fn drain_map<'de, A: serde::de::MapAccess<'de>>(mut map: A) -> Result<(), A::Error> {
    while map
        .next_entry::<serde::de::IgnoredAny, serde::de::IgnoredAny>()?
        .is_some()
    {}
    Ok(())
}

impl<'de> Deserialize<'de> for ProbedFormat {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> serde::de::Visitor<'de> for V {
            type Value = ProbedFormat;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("a format name")
            }
            fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<ProbedFormat, E> {
                Ok(if v.len() <= 80 {
                    ProbedFormat::Name(v.to_string())
                } else {
                    ProbedFormat::Other("a long text")
                })
            }
            fn visit_bool<E: serde::de::Error>(self, _: bool) -> Result<ProbedFormat, E> {
                Ok(ProbedFormat::Other("true or false"))
            }
            fn visit_i64<E: serde::de::Error>(self, _: i64) -> Result<ProbedFormat, E> {
                Ok(ProbedFormat::Other("a number"))
            }
            fn visit_u64<E: serde::de::Error>(self, _: u64) -> Result<ProbedFormat, E> {
                Ok(ProbedFormat::Other("a number"))
            }
            fn visit_f64<E: serde::de::Error>(self, _: f64) -> Result<ProbedFormat, E> {
                Ok(ProbedFormat::Other("a number"))
            }
            fn visit_seq<A: serde::de::SeqAccess<'de>>(
                self,
                s: A,
            ) -> Result<ProbedFormat, A::Error> {
                drain_seq(s)?;
                Ok(ProbedFormat::Other("a list"))
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                m: A,
            ) -> Result<ProbedFormat, A::Error> {
                drain_map(m)?;
                Ok(ProbedFormat::Other("an object"))
            }
        }
        d.deserialize_any(V)
    }
}

impl<'de> Deserialize<'de> for ProbedVersion {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> serde::de::Visitor<'de> for V {
            type Value = ProbedVersion;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("a positive integer")
            }
            fn visit_u64<E: serde::de::Error>(self, v: u64) -> Result<ProbedVersion, E> {
                Ok(if v >= 1 {
                    ProbedVersion::Positive(v)
                } else {
                    ProbedVersion::Bad
                })
            }
            fn visit_i64<E: serde::de::Error>(self, v: i64) -> Result<ProbedVersion, E> {
                Ok(u64::try_from(v)
                    .ok()
                    .filter(|&v| v >= 1)
                    .map_or(ProbedVersion::Bad, ProbedVersion::Positive))
            }
            fn visit_f64<E: serde::de::Error>(self, _: f64) -> Result<ProbedVersion, E> {
                Ok(ProbedVersion::Bad)
            }
            fn visit_bool<E: serde::de::Error>(self, _: bool) -> Result<ProbedVersion, E> {
                Ok(ProbedVersion::Bad)
            }
            fn visit_str<E: serde::de::Error>(self, _: &str) -> Result<ProbedVersion, E> {
                Ok(ProbedVersion::Bad)
            }
            fn visit_seq<A: serde::de::SeqAccess<'de>>(
                self,
                s: A,
            ) -> Result<ProbedVersion, A::Error> {
                drain_seq(s)?;
                Ok(ProbedVersion::Bad)
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                m: A,
            ) -> Result<ProbedVersion, A::Error> {
                drain_map(m)?;
                Ok(ProbedVersion::Bad)
            }
        }
        d.deserialize_any(V)
    }
}

/// The detection rule: the file's schema version, or why it is not a `.plytab` this build reads.
fn probe(text: &str) -> Result<u32, DocumentError> {
    // An object, never an array read field by field.
    if !text.trim_start().starts_with('{') {
        return Err(DocumentError::Malformed(
            "a .plytab file must be one JSON object".into(),
        ));
    }
    let p: Probe = serde_json::from_str(text).map_err(|e| {
        DocumentError::Malformed(format!("a .plytab file must be one JSON object ({e})"))
    })?;
    match p.format {
        Some(ProbedFormat::Name(f)) if f == TABLET_FORMAT => {}
        Some(ProbedFormat::Name(f)) => {
            return Err(DocumentError::WrongFormat {
                found: serde_json::to_string(&f).unwrap_or(f),
            })
        }
        Some(ProbedFormat::Other(kind)) => {
            return Err(DocumentError::WrongFormat {
                found: kind.to_string(),
            })
        }
        None => {
            return Err(DocumentError::WrongFormat {
                found: "none".into(),
            })
        }
    }
    let version = match p.schema_version {
        Some(ProbedVersion::Positive(v)) => v,
        _ => {
            return Err(DocumentError::Malformed(
                "schema_version must be a positive integer".into(),
            ))
        }
    };
    if version > u64::from(TABLET_SCHEMA_VERSION) {
        return Err(DocumentError::NewerVersion {
            found: version,
            supported: TABLET_SCHEMA_VERSION,
        });
    }
    // At most TABLET_SCHEMA_VERSION here, so it fits a u32.
    Ok(version as u32)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EnvelopeIn {
    #[allow(dead_code)]
    format: String,
    #[allow(dead_code)]
    schema_version: u32,
    document: DocumentIn,
}

/// The document as read: every key required except the optional ones the writer leaves out.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DocumentIn {
    name: String,
    notes: String,
    #[serde(with = "hex_palette")]
    palette: Vec<Color>,
    #[serde(default)]
    weft: Option<ColorIndex>,
    cards: Vec<Tablet>,
    #[serde(default)]
    packs: Vec<Pack>,
    turning: TurnSequence,
    settings: BandSettings,
}

impl From<DocumentIn> for TabletDocument {
    fn from(d: DocumentIn) -> TabletDocument {
        TabletDocument {
            name: d.name,
            notes: d.notes,
            band: TabletBand {
                palette: d.palette,
                weft: d.weft,
                cards: d.cards,
                packs: d.packs,
                turning: d.turning,
                settings: d.settings,
            },
        }
    }
}

#[derive(Serialize)]
struct EnvelopeOut<'a> {
    format: &'static str,
    schema_version: u32,
    document: DocumentOut<'a>,
}

/// The document as written, in the section 14 order.
#[derive(Serialize)]
struct DocumentOut<'a> {
    name: &'a str,
    notes: &'a str,
    #[serde(serialize_with = "palette_out")]
    palette: &'a [Color],
    #[serde(skip_serializing_if = "Option::is_none")]
    weft: Option<ColorIndex>,
    cards: &'a [Tablet],
    #[serde(skip_serializing_if = "<[Pack]>::is_empty")]
    packs: &'a [Pack],
    turning: &'a TurnSequence,
    settings: &'a BandSettings,
}

fn palette_out<S: serde::Serializer>(palette: &&[Color], s: S) -> Result<S::Ok, S::Error> {
    hex_palette::serialize(palette, s)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tiny() -> TabletDocument {
        let mut band: TabletBand = serde_json::from_str(
            r##"{"palette": ["#000000"], "cards": [{"id": "c", "threads": {"A": 0, "B": 0, "C": 0,
            "D": null}, "threading": "S", "start": {"near_top": "A", "far_top": "D",
            "far_bottom": "C", "near_bottom": "B"}}], "turning": [{"picks": [{"turns": "F"}]}]}"##,
        )
        .unwrap();
        band.settings = BandSettings::default();
        TabletDocument {
            name: "Tiny".into(),
            notes: "One card.".into(),
            band,
        }
    }

    #[test]
    fn a_written_document_reads_back_and_writes_the_same_bytes() {
        let doc = tiny();
        let text = write_document(&doc).unwrap();
        let back = read_document(&text).unwrap();
        assert_eq!(back.source_version, 1);
        assert_eq!(back.document, doc);
        assert_eq!(write_document(&back.document).unwrap(), text);
        assert!(text.starts_with("{\n  \"format\": \"ply.tablet\",\n  \"schema_version\": 1,"));
        // Optional lists are left out when empty, and the empty hole is written as null.
        assert!(!text.contains("\"packs\""));
        assert!(text.contains("\"D\": null"));
    }

    #[test]
    fn the_envelope_decides_before_the_document_is_read() {
        let newer = r#"{"format": "ply.tablet", "schema_version": 2, "document": {"anything": 1}}"#;
        assert_eq!(
            read_document(newer),
            Err(DocumentError::NewerVersion {
                found: 2,
                supported: 1
            })
        );
        assert_eq!(
            document_schema_version(newer),
            read_document(newer).map(|d| d.source_version)
        );
        for (text, want) in [
            (
                r#"{"format": "ply.knit", "schema_version": 6}"#,
                "WrongFormat",
            ),
            (r#"{"schema_version": 1, "document": {}}"#, "WrongFormat"),
            (
                r#"{"format": "ply.tablet", "schema_version": 0, "document": {}}"#,
                "Malformed",
            ),
            (
                r#"{"format": "ply.tablet", "schema_version": "1", "document": {}}"#,
                "Malformed",
            ),
            (
                r#"{"format": "ply.tablet", "schema_version": 1}"#,
                "Malformed",
            ),
            (r#"[1, 2]"#, "Malformed"),
            ("not json", "Malformed"),
        ] {
            let got = read_document(text).unwrap_err();
            assert!(format!("{got:?}").starts_with(want), "{text}: {got:?}");
        }
    }

    #[test]
    fn unknown_and_missing_fields_are_refused() {
        let text = write_document(&tiny()).unwrap();
        let cases = [
            text.replacen("\"notes\"", "\"extra\": 1,\n    \"notes\"", 1),
            text.replacen(
                "\"schema_version\": 1,",
                "\"schema_version\": 1, \"more\": true,",
                1,
            ),
            text.replacen("\"threading\": \"S\"", "\"threading\": \"X\"", 1),
            text.replacen("    \"notes\": \"One card.\",\n", "", 1),
            text.replacen("\"D\": null", "\"E\": null", 1),
            text.replacen(
                "\"name\": \"Tiny\",",
                "\"name\": \"Tiny\", \"name\": \"Again\",",
                1,
            ),
        ];
        for bad in cases {
            assert_ne!(bad, text);
            assert!(
                matches!(read_document(&bad), Err(DocumentError::Malformed(_))),
                "{bad}"
            );
        }
    }

    #[test]
    fn sizes_are_checked_on_read_and_on_write() {
        let mut doc = tiny();
        doc.notes = "x".repeat(MAX_NOTES_BYTES + 1);
        assert!(matches!(
            write_document(&doc),
            Err(DocumentError::TooLarge(_))
        ));
        let mut doc = tiny();
        doc.band.cards = vec![doc.band.cards[0].clone(); crate::MAX_CARDS + 1];
        assert!(matches!(
            write_document(&doc),
            Err(DocumentError::TooLarge(_))
        ));
        // Written by hand past the limit: refused on read too.
        let big = write_document(&tiny()).unwrap().replacen(
            "\"turns\": \"F\"",
            &format!("\"turns\": \"{}\"", "F".repeat(crate::MAX_CARDS * 4 + 1)),
            1,
        );
        assert!(matches!(
            read_document(&big),
            Err(DocumentError::TooLarge(_))
        ));
        // A file over the byte cap that a newer Ply wrote is reported as newer.
        let pad = " ".repeat(MAX_DOCUMENT_BYTES);
        let newer =
            format!(r#"{{"format": "ply.tablet", "schema_version": 9, "document": {{}}}}{pad}"#);
        assert!(matches!(
            read_document(&newer),
            Err(DocumentError::NewerVersion { found: 9, .. })
        ));
        let older =
            format!(r#"{{"format": "ply.tablet", "schema_version": 1, "document": {{}}}}{pad}"#);
        assert!(matches!(
            read_document(&older),
            Err(DocumentError::TooLarge(_))
        ));
    }

    #[test]
    fn a_band_with_structural_errors_still_opens_and_saves() {
        let mut doc = tiny();
        doc.band.turning.segments[0].picks[0].turns = "FFx".into();
        doc.band.turning.segments[0].repeat = u32::MAX;
        let text = write_document(&doc).unwrap();
        assert_eq!(read_document(&text).unwrap().document, doc);
        assert!(!crate::validate(&doc.band).is_empty());
    }
}
