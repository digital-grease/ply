//! `looms.json`: the weaver's loom profiles, one file in the app's documents directory (ADR 0014).
//!
//! ```json
//! { "format": "ply.looms", "schema_version": 1, "looms": [ { "id": "...", "name": "...", ... } ] }
//! ```
//!
//! Detection follows ADR 0002: the file is one JSON object whose `format` is exactly `ply.looms` and
//! whose `schema_version` is a positive integer. A NEWER version is refused with
//! [`LoomFileError::NewerVersion`] before the looms are looked at, so this build never reads (and the
//! app never overwrites) a file a later Ply wrote. An older version would be migrated in memory
//! through `MIGRATIONS` (none yet: version 1 is the first).
//!
//! The file is untrusted input: its size, the number of looms, every value (see
//! [`LoomProfile::problems`]) and the uniqueness of ids are checked, and unknown fields are refused
//! (a file with them was not written by this version). Unknown equipment is written as `null`, so the
//! file itself shows what the weaver did not record.
//!
//! **Decoding builds no generic tree** (ADR 0007, amendment of 2026-11-18, item 8). [`read`] makes
//! two passes over the text. The first ([`ply_common::envelope::top_level`]) accepts and refuses
//! the text exactly as a decode into a `serde_json::Value` would, reads the envelope and counts the
//! looms, building nothing; the second decodes a current-version file's looms straight into their
//! types. Every verdict is the tree's, in the tree's order (not JSON, not an object, the format, the
//! version, too many looms, then the looms themselves), with one exception no writer can produce: a
//! key repeated inside a loom is refused, where the tree kept its last value. An older version
//! would be read through a tree for `MIGRATIONS`; when version 2 is added, that route needs a bound
//! of its own (as older `.plyknit` versions have).

use crate::loom::LoomProfile;
use ply_common::envelope::{top_level, KeyAmong, TopEntry, TopValue};
use serde::de::{Deserializer, IgnoredAny, MapAccess, Visitor};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;
use std::fmt;
use thiserror::Error;

/// The `format` value of `looms.json`.
pub const LOOMS_FORMAT: &str = "ply.looms";

/// The schema version this build writes, and the newest it reads.
pub const LOOMS_SCHEMA_VERSION: u32 = 1;

/// The largest `looms.json` this build reads, in bytes.
pub const MAX_LOOMS_FILE_BYTES: usize = 1024 * 1024;

/// The most looms one file may hold.
pub const MAX_LOOMS: usize = 200;

/// The largest file whose envelope is still looked at when it is over [`MAX_LOOMS_FILE_BYTES`], so
/// that a file a newer Ply wrote is reported as newer (never overwritten), not as too large.
pub const MAX_PROBED_FILE_BYTES: usize = 16 * 1024 * 1024;

/// Why a `looms.json` cannot be read or written.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum LoomFileError {
    /// Written by a newer Ply: do not read it, do not overwrite it.
    #[error("the looms file was saved by a newer version of Ply (schema version {found}; this build reads up to {supported})")]
    NewerVersion { found: u64, supported: u32 },
    /// A JSON object with another (or no) `format`.
    #[error("not a Ply looms file (format {found})")]
    WrongFormat { found: String },
    /// Over the size or loom-count limit.
    #[error("the looms file is too large: {0}")]
    TooLarge(String),
    /// Not JSON, a malformed envelope, a field of the wrong type or an unknown field, a value outside
    /// its limits, or a repeated id.
    #[error("the looms file could not be read: {0}")]
    Malformed(String),
}

/// Every loom profile the weaver has, in the order they listed them.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct LoomLibrary {
    pub looms: Vec<LoomProfile>,
}

impl LoomLibrary {
    /// The loom with `id`, if any.
    pub fn get(&self, id: &str) -> Option<&LoomProfile> {
        self.looms.iter().find(|l| l.id == id)
    }

    /// Every problem that stops this library from being written or read (empty = valid): too many
    /// looms, a repeated id, or a profile outside its limits.
    pub fn problems(&self) -> Vec<String> {
        let mut out = Vec::new();
        if self.looms.len() > MAX_LOOMS {
            out.push(format!("more than {MAX_LOOMS} looms"));
        }
        let mut ids = BTreeSet::new();
        for loom in &self.looms {
            if !ids.insert(loom.id.as_str()) {
                out.push(format!("loom id {:?} appears twice", loom.id));
            }
            for p in loom.problems() {
                out.push(format!("{}: {p}", loom.display_name()));
            }
        }
        out
    }
}

#[derive(Serialize)]
struct Envelope<'a> {
    format: &'static str,
    schema_version: u32,
    looms: &'a [LoomProfile],
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
    looms: Vec<LoomProfile>,
}

/// Serialize `library` as a current-version `looms.json` (pretty JSON). A library that breaks the
/// limits is refused rather than written, so Ply never writes a file it would refuse to read.
pub fn write(library: &LoomLibrary) -> Result<String, LoomFileError> {
    let problems = library.problems();
    if let Some(first) = problems.first() {
        return Err(if library.looms.len() > MAX_LOOMS {
            LoomFileError::TooLarge(first.clone())
        } else {
            LoomFileError::Malformed(first.clone())
        });
    }
    let text = serde_json::to_string_pretty(&Envelope {
        format: LOOMS_FORMAT,
        schema_version: LOOMS_SCHEMA_VERSION,
        looms: &library.looms,
    })
    .map_err(|e| LoomFileError::Malformed(e.to_string()))?;
    if text.len() > MAX_LOOMS_FILE_BYTES {
        return Err(LoomFileError::TooLarge(format!(
            "{} bytes, over {MAX_LOOMS_FILE_BYTES}",
            text.len()
        )));
    }
    Ok(text)
}

/// Parse a `looms.json` of any supported version (see the module doc for what is refused).
pub fn read(text: &str) -> Result<LoomLibrary, LoomFileError> {
    if text.len() > MAX_LOOMS_FILE_BYTES {
        // A newer Ply may write a larger file: say so, so the caller leaves it alone.
        if text.len() <= MAX_PROBED_FILE_BYTES {
            if let Err(e @ LoomFileError::NewerVersion { .. }) = probe(text) {
                return Err(e);
            }
        }
        return Err(LoomFileError::TooLarge(format!(
            "{} bytes, over {MAX_LOOMS_FILE_BYTES}",
            text.len()
        )));
    }
    let probed = probe(text)?;
    if probed.version != LOOMS_SCHEMA_VERSION {
        return read_through_tree(text);
    }
    // Count before decoding any profile, so a hostile file cannot make the decoder build a huge list.
    if let Some(TopEntry {
        value: TopValue::List(n),
        ..
    }) = probed.looms
    {
        if n > MAX_LOOMS {
            return Err(LoomFileError::TooLarge(format!(
                "{n} looms, over {MAX_LOOMS}"
            )));
        }
    }
    let looms = current_looms(text, probed.looms.map(|e| e.index))
        .map_err(|e| LoomFileError::Malformed(e.to_string()))?;
    checked(LoomLibrary { looms })
}

/// A library read from the file, refused (`Malformed`) when it breaks a limit or repeats an id.
fn checked(library: LoomLibrary) -> Result<LoomLibrary, LoomFileError> {
    if let Some(first) = library.problems().into_iter().next() {
        return Err(LoomFileError::Malformed(first));
    }
    Ok(library)
}

/// How a file was read before the typed decode, and how a file of an older version (none yet) is
/// read: decoded into a `serde_json::Value`, migrated, counted, then decoded into the looms. Tests
/// compare the typed route with it.
fn read_through_tree(text: &str) -> Result<LoomLibrary, LoomFileError> {
    let (version, document) = split(text)?;
    let document = migrate(version, document)?;
    // Count before decoding every profile, so a hostile file cannot make the decoder build a huge list.
    if let Some(n) = document
        .get("looms")
        .and_then(Value::as_array)
        .map(Vec::len)
    {
        if n > MAX_LOOMS {
            return Err(LoomFileError::TooLarge(format!(
                "{n} looms, over {MAX_LOOMS}"
            )));
        }
    }
    let doc: Document =
        serde_json::from_value(document).map_err(|e| LoomFileError::Malformed(e.to_string()))?;
    checked(LoomLibrary { looms: doc.looms })
}

/// The schema version of a `looms.json`, by the detection rule, without reading its looms. Errors as
/// [`read`] would for the envelope itself.
pub fn schema_version(text: &str) -> Result<u32, LoomFileError> {
    probe(text).map(|p| p.version)
}

/// The keys of the envelope [`probe`] reads, in its order.
const ENVELOPE_KEYS: [&str; 3] = ["format", "schema_version", "looms"];

/// What [`probe`] found: a version this build reads, and the `looms` key the tree would keep.
struct Probed {
    version: u32,
    looms: Option<TopEntry>,
}

/// Apply the detection rule as [`split`] does, with the same verdict on every text, without
/// building a tree (see [`top_level`]).
fn probe(text: &str) -> Result<Probed, LoomFileError> {
    let Some(found) =
        top_level(text, &ENVELOPE_KEYS).map_err(|e| LoomFileError::Malformed(e.to_string()))?
    else {
        return Err(LoomFileError::Malformed(
            "a looms file must be a JSON object".into(),
        ));
    };
    let [format, version, looms] = <[Option<TopEntry>; 3]>::try_from(found)
        .unwrap_or_else(|_| unreachable!("one entry a key"));
    match format.map(|e| e.value) {
        Some(TopValue::Scalar(Value::String(f))) if f == LOOMS_FORMAT => {}
        Some(other) => {
            return Err(LoomFileError::WrongFormat {
                found: shown(&other),
            })
        }
        None => {
            return Err(LoomFileError::WrongFormat {
                found: "missing".into(),
            })
        }
    }
    let version = version
        .and_then(|e| match e.value {
            TopValue::Scalar(v) => v.as_u64(),
            _ => None,
        })
        .filter(|&v| v >= 1)
        .ok_or_else(|| {
            LoomFileError::Malformed("schema_version must be a positive integer".into())
        })?;
    if version > u64::from(LOOMS_SCHEMA_VERSION) {
        return Err(LoomFileError::NewerVersion {
            found: version,
            supported: LOOMS_SCHEMA_VERSION,
        });
    }
    Ok(Probed {
        // At most LOOMS_SCHEMA_VERSION here, so it fits a u32.
        version: version as u32,
        looms,
    })
}

/// A top-level value for a message: a scalar as JSON text (as the tree printed it), a list or an
/// object by its kind (the tree printed it whole, which for a file of a megabyte was a megabyte).
fn shown(value: &TopValue) -> String {
    match value {
        TopValue::Scalar(v) => v.to_string(),
        TopValue::List(_) => "a list".into(),
        TopValue::Object => "an object".into(),
    }
}

/// The looms of a current-version file whose envelope [`probe`] accepted, decoded straight into
/// their types: the `looms` entry at `last` (the one a tree keeps) is decoded, the envelope's own
/// keys and earlier `looms` entries are skipped (the probe has walked them), and any other key is
/// refused as an unknown field, as the tree's typed decode refused it.
fn current_looms(text: &str, last: Option<usize>) -> Result<Vec<LoomProfile>, serde_json::Error> {
    let mut de = serde_json::Deserializer::from_str(text);
    let looms = (&mut de).deserialize_map(CurrentLooms { last })?;
    de.end()?;
    Ok(looms)
}

struct CurrentLooms {
    last: Option<usize>,
}

impl<'de> Visitor<'de> for CurrentLooms {
    type Value = Vec<LoomProfile>;
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a looms file")
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Vec<LoomProfile>, A::Error> {
        let mut looms = None;
        let mut index = 0;
        while let Some(key) = map.next_key_seed(KeyAmong(&ENVELOPE_KEYS))? {
            match key {
                Ok(2) if Some(index) == self.last => {
                    looms = Some(map.next_value::<Vec<LoomProfile>>()?);
                }
                Ok(_) => {
                    map.next_value::<IgnoredAny>()?;
                }
                Err(other) => return Err(serde::de::Error::unknown_field(&other, &["looms"])),
            }
            index += 1;
        }
        looms.ok_or_else(|| serde::de::Error::missing_field("looms"))
    }
}

/// Apply the detection rule: the file's schema version and the rest of the envelope (its document),
/// decoded into a tree (the route of [`read_through_tree`]).
fn split(text: &str) -> Result<(u32, Value), LoomFileError> {
    let value: Value =
        serde_json::from_str(text).map_err(|e| LoomFileError::Malformed(e.to_string()))?;
    let Value::Object(mut obj) = value else {
        return Err(LoomFileError::Malformed(
            "a looms file must be a JSON object".into(),
        ));
    };
    match obj.get("format") {
        Some(Value::String(f)) if f == LOOMS_FORMAT => {}
        Some(other) => {
            return Err(LoomFileError::WrongFormat {
                found: other.to_string(),
            })
        }
        None => {
            return Err(LoomFileError::WrongFormat {
                found: "missing".into(),
            })
        }
    }
    let version = obj
        .get("schema_version")
        .and_then(Value::as_u64)
        .filter(|&v| v >= 1)
        .ok_or_else(|| {
            LoomFileError::Malformed("schema_version must be a positive integer".into())
        })?;
    if version > u64::from(LOOMS_SCHEMA_VERSION) {
        return Err(LoomFileError::NewerVersion {
            found: version,
            supported: LOOMS_SCHEMA_VERSION,
        });
    }
    obj.remove("format");
    obj.remove("schema_version");
    // `version` is at most LOOMS_SCHEMA_VERSION here, so it fits a u32.
    Ok((version as u32, Value::Object(obj)))
}

/// One migration: a document at version `n` in, the same document at version `n + 1` out.
type Migration = fn(Value) -> Result<Value, LoomFileError>;

/// The ordered migration chain: `MIGRATIONS[i]` upgrades a document from version `i + 1` to `i + 2`.
/// Its length is tied to [`LOOMS_SCHEMA_VERSION`], so bumping the version without appending a
/// migration does not compile. Version 1 is the first, so there are none yet.
const MIGRATIONS: [Migration; LOOMS_SCHEMA_VERSION as usize - 1] = [];

/// Run every migration from `from` up to the current version, in order.
fn migrate(from: u32, mut document: Value) -> Result<Value, LoomFileError> {
    for step in MIGRATIONS.iter().skip((from as usize).saturating_sub(1)) {
        document = step(document)?;
    }
    Ok(document)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::loom::{DentUnit, Length, LoomKind, Reed, MAX_LOOM_SHAFTS};
    use ply_common::Unit;
    use serde_json::json;

    fn floor_loom() -> LoomProfile {
        LoomProfile {
            id: "floor-loom".into(),
            name: "Floor loom".into(),
            kind: Some(LoomKind::Jack),
            shafts: Some(8),
            treadles: Some(10),
            weaving_width: Some(Length {
                value: 36.0,
                unit: Unit::Inches,
            }),
            reeds: vec![
                Reed {
                    dents: 12.0,
                    per: DentUnit::PerInch,
                },
                Reed {
                    dents: 40.0,
                    per: DentUnit::Per10Cm,
                },
            ],
            treadles_at_once: Some(2),
            notes: "Tie-up cords are texsolv.".into(),
        }
    }

    fn library() -> LoomLibrary {
        LoomLibrary {
            looms: vec![floor_loom(), LoomProfile::new("partial", "Borrowed loom")],
        }
    }

    #[test]
    fn round_trips_and_writes_unknowns_as_null() {
        let text = write(&library()).unwrap();
        assert_eq!(read(&text).unwrap(), library());
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["format"], "ply.looms");
        assert_eq!(v["schema_version"], 1);
        let partial = &v["looms"][1];
        for key in [
            "kind",
            "shafts",
            "treadles",
            "weaving_width",
            "treadles_at_once",
        ] {
            assert!(partial[key].is_null(), "{key} is written as null");
        }
        assert_eq!(partial["reeds"], json!([]));
        assert_eq!(v["looms"][0]["weaving_width"]["unit"], "inches");
        assert_eq!(v["looms"][0]["reeds"][1]["per"], "10cm");
        assert_eq!(v["looms"][0]["kind"], "jack");
        // Writing what was read gives the same bytes.
        assert_eq!(write(&read(&text).unwrap()).unwrap(), text);
    }

    #[test]
    fn missing_optional_keys_read_as_unknown() {
        let text = r#"{"format":"ply.looms","schema_version":1,"looms":[{"id":"a","name":"A"}]}"#;
        assert_eq!(read(text).unwrap().looms, vec![LoomProfile::new("a", "A")]);
    }

    #[test]
    fn a_newer_file_is_refused_before_its_looms_are_read() {
        // Version 2 with a shape this build does not know: refused as newer, not as malformed.
        let text = r#"{"format":"ply.looms","schema_version":2,"looms":"later"}"#;
        assert_eq!(
            read(text),
            Err(LoomFileError::NewerVersion {
                found: 2,
                supported: 1
            })
        );
        assert!(matches!(
            schema_version(text),
            Err(LoomFileError::NewerVersion { .. })
        ));
        assert_eq!(
            schema_version(&write(&library()).unwrap()),
            Ok(LOOMS_SCHEMA_VERSION)
        );
    }

    #[test]
    fn foreign_and_malformed_files_are_refused() {
        for (text, wrong_format) in [
            ("[]", false),
            ("not json", false),
            (r#"{"format":"ply.knit","schema_version":1}"#, true),
            (r#"{"looms":[]}"#, true),
            (
                r#"{"format":"ply.looms","schema_version":0,"looms":[]}"#,
                false,
            ),
            (
                r#"{"format":"ply.looms","schema_version":"1","looms":[]}"#,
                false,
            ),
            (r#"{"format":"ply.looms","schema_version":1}"#, false),
            (
                r#"{"format":"ply.looms","schema_version":1,"looms":[],"extra":1}"#,
                false,
            ),
            (
                r#"{"format":"ply.looms","schema_version":1,"looms":[{"id":"a","name":"A","colour":"red"}]}"#,
                false,
            ),
            (
                r#"{"format":"ply.looms","schema_version":1,"looms":[{"id":"a","name":"A","shafts":0}]}"#,
                false,
            ),
            (
                r#"{"format":"ply.looms","schema_version":1,"looms":[{"id":"a","name":"A","kind":"rigid_heddle"}]}"#,
                false,
            ),
            (
                r#"{"format":"ply.looms","schema_version":1,"looms":[{"id":"a","name":"A"},{"id":"a","name":"B"}]}"#,
                false,
            ),
        ] {
            let err = read(text).unwrap_err();
            assert_eq!(
                matches!(err, LoomFileError::WrongFormat { .. }),
                wrong_format,
                "{text}: {err}"
            );
        }
    }

    #[test]
    fn limits_are_enforced_on_read_and_write() {
        let mut big = LoomLibrary::default();
        for i in 0..=MAX_LOOMS {
            big.looms.push(LoomProfile::new(format!("l{i}"), ""));
        }
        assert!(matches!(write(&big), Err(LoomFileError::TooLarge(_))));
        let looms: Vec<Value> = (0..=MAX_LOOMS)
            .map(|i| json!({"id": format!("l{i}"), "name": ""}))
            .collect();
        let text = json!({"format": "ply.looms", "schema_version": 1, "looms": looms}).to_string();
        assert!(matches!(read(&text), Err(LoomFileError::TooLarge(_))));

        let huge = format!(
            r#"{{"format":"ply.looms","schema_version":1,"looms":[],"pad":"{}"}}"#,
            "x".repeat(MAX_LOOMS_FILE_BYTES)
        );
        assert!(matches!(read(&huge), Err(LoomFileError::TooLarge(_))));
        // A large file from a newer Ply is newer, not too large (the app leaves it alone).
        let huge_newer = huge.replace("\"schema_version\":1", "\"schema_version\":2");
        assert!(matches!(
            read(&huge_newer),
            Err(LoomFileError::NewerVersion { found: 2, .. })
        ));

        let mut bad = library();
        bad.looms[0].shafts = Some(MAX_LOOM_SHAFTS + 1);
        assert!(matches!(write(&bad), Err(LoomFileError::Malformed(_))));
    }

    /// The verdicts of the typed route and the tree route on `text`: the same library, or the same
    /// kind of refusal. A refusal found before the looms are decoded (the JSON itself, the envelope,
    /// the count) has the same message too; one found decoding them has the tree's kind.
    fn assert_same_verdict(text: &str) {
        let typed = read(text);
        let tree = read_through_tree(text);
        match (&typed, &tree) {
            (Ok(a), Ok(b)) => assert_eq!(a, b, "{text:.200}"),
            (Err(LoomFileError::Malformed(a)), Err(LoomFileError::Malformed(b))) => {
                if probe(text).is_err() {
                    assert_eq!(a, b, "{text:.200}");
                }
            }
            (Err(a @ LoomFileError::WrongFormat { found }), Err(b)) => {
                if found.starts_with("a ") || found.starts_with("an ") {
                    // A list or an object is named by its kind, where the tree printed it whole.
                    assert!(
                        matches!(b, LoomFileError::WrongFormat { .. }),
                        "{text:.200}"
                    );
                } else {
                    assert_eq!(a, b, "{text:.200}");
                }
            }
            (Err(a), Err(b)) => assert_eq!(a, b, "{text:.200}"),
            _ => panic!("{text:.200}: typed {typed:?}, tree {tree:?}"),
        }
    }

    #[test]
    fn the_typed_route_gives_the_tree_route_s_verdict() {
        let fixture = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../fixtures/weaving/looms/looms.json"
        ))
        .unwrap();
        let written = write(&library()).unwrap();
        let loom = r#"{"id":"a","name":"A"}"#;
        let env = |rest: &str| format!(r#"{{"format":"ply.looms","schema_version":1,{rest}}}"#);
        let deep = |n: usize| format!("{}{}", "[".repeat(n), "]".repeat(n));
        let mut cases = vec![
            fixture.clone(),
            written.clone(),
            // Keys in any order, escaped keys, structs as lists, numbers in other spellings.
            format!(r#"{{"looms":[{loom}],"schema_version":1,"format":"ply.looms"}}"#),
            r#"{"form\u0061t":"ply.looms","schema_version":1,"looms":[]}"#.into(),
            env(r#""looms":[["a","A",null,8,null,[36,"inches"],[[12,"inch"]],2,""]]"#),
            env(r#""looms":[{"id":"a","name":"A","shafts":8.0}]"#),
            env(r#""looms":[{"id":"a","name":"A","weaving_width":{"value":1e2,"unit":"inches"}}]"#),
            env(r#""looms":[{"id":"a","name":"A","kind":{"jack":null}}]"#),
            // Repeated top-level keys: the last counts, whatever came before.
            env(r#""looms":7,"looms":[{"id":"a","name":"A"}]"#),
            env(r#""looms":[{"id":"a","name":"A"}],"looms":[]"#),
            env(r#""looms":[{"id":"x","shafts":0}],"looms":[{"id":"a","name":"A"}]"#),
            r#"{"format":"ply.knit","format":"ply.looms","schema_version":1,"looms":[]}"#.into(),
            r#"{"format":"ply.looms","schema_version":1,"schema_version":2,"looms":[]}"#.into(),
            r#"{"format":"ply.looms","schema_version":2,"schema_version":1,"looms":[]}"#.into(),
            // Refusals of every kind, each with others behind it.
            "".into(),
            "[]".into(),
            "7".into(),
            "null".into(),
            r#""ply.looms""#.into(),
            format!("{written} x"),
            env(r#""looms":[],"x":1"#),
            env(r#""x":1,"looms":[]"#),
            env(r#""looms":[{"id":"a","name":"A","x":{"y":[1,2]}}]"#),
            env(r#""looms":[{"id":"a"}]"#),
            env(r#""looms":{"id":"a"}"#),
            env(r#""looms":null"#),
            env(r#""looms":[1]"#),
            env(r#""looms":[{"id":"a","name":"A","shafts":-1}]"#),
            env(r#""looms":[{"id":"a","name":"A","shafts":70000}]"#),
            env(r#""looms":[{"id":"a","name":"A","kind":"loom"}]"#),
            env(r#""looms":[{"id":"a","name":"A","weaving_width":{"value":1,"unit":"feet"}}]"#),
            env(r#""looms":[{"id":"a","name":"A"},{"id":"a","name":"B"}]"#),
            r#"{"schema_version":1,"looms":[]}"#.into(),
            r#"{"format":null,"schema_version":1,"looms":[]}"#.into(),
            r#"{"format":7,"schema_version":1,"looms":[]}"#.into(),
            r#"{"format":"ply.looms\n","schema_version":1,"looms":[]}"#.into(),
            r#"{"format":["ply.looms"],"schema_version":1,"looms":[]}"#.into(),
            r#"{"format":{"a":1},"schema_version":1,"looms":[]}"#.into(),
            r#"{"format":"ply.looms","looms":[]}"#.into(),
            r#"{"format":"ply.looms","schema_version":0,"looms":[]}"#.into(),
            r#"{"format":"ply.looms","schema_version":-1,"looms":[]}"#.into(),
            r#"{"format":"ply.looms","schema_version":1.0,"looms":[]}"#.into(),
            r#"{"format":"ply.looms","schema_version":"1","looms":[]}"#.into(),
            r#"{"format":"ply.looms","schema_version":[1],"looms":[]}"#.into(),
            r#"{"format":"ply.looms","schema_version":18446744073709551615,"looms":[]}"#.into(),
            r#"{"format":"ply.looms","schema_version":2,"looms":"later"}"#.into(),
            // What a decode into a tree refuses anywhere in the text, the probe refuses alike,
            // before the envelope is looked at: nesting past the depth limit, a lone surrogate, a
            // number out of range. Each also with a newer version or a foreign format.
            env(&format!(r#""looms":[],"x":{}"#, deep(127))),
            env(&format!(r#""looms":[],"x":{}"#, deep(128))),
            env(&format!(r#""looms":[],"x":{}"#, deep(300))),
            env(r#""looms":[],"x":"\ud83d""#),
            env(r#""looms":[],"x":1e400"#),
            env(r#""looms":[{"id":"a","name":"\ud83d"}]"#),
            format!(
                r#"{{"format":"ply.looms","schema_version":2,"x":{}}}"#,
                deep(300)
            ),
            format!(
                r#"{{"format":"ply.knit","schema_version":1,"x":{}}}"#,
                deep(300)
            ),
            r#"{"format":"ply.looms","schema_version":2,"x":"\udc00"}"#.into(),
            r#"{"format":["\ud83d"],"schema_version":1}"#.into(),
            format!(r#"{{"format":{},"schema_version":1}}"#, deep(300)),
        ];
        // Past the loom count, with every other kind of problem behind it.
        let many = |extra: &str| {
            let looms: Vec<String> = (0..=MAX_LOOMS)
                .map(|i| format!(r#"{{"id":"l{i}"}}"#))
                .collect();
            env(&format!(r#""looms":[{}]{extra}"#, looms.join(",")))
        };
        cases.push(many(""));
        cases.push(many(r#","x":1"#));
        cases.push(many(r#","looms":[]"#));
        cases.push(many(&format!(r#","x":{}"#, deep(300))));
        cases.push(format!(
            r#"{{"format":"ply.looms","schema_version":1,"looms":[{}]}}"#,
            vec!["7"; MAX_LOOMS + 1].join(",")
        ));
        for text in &cases {
            assert_same_verdict(text);
        }
    }

    mod generated {
        use super::*;
        use crate::loom::{DentUnit, Length, LoomKind, Reed};
        use proptest::prelude::*;

        fn arb_loom() -> impl Strategy<Value = LoomProfile> {
            (
                prop_oneof![Just("a".to_string()), "[A-Za-z0-9_-]{0,70}", ".{0,4}"],
                ".{0,8}",
                prop::option::of(prop_oneof![
                    Just(LoomKind::Jack),
                    Just(LoomKind::Counterbalance),
                    Just(LoomKind::Countermarch),
                    Just(LoomKind::Table),
                    Just(LoomKind::Dobby),
                ]),
                prop::option::of(0u16..300),
                prop::option::of(0u16..300),
                prop::option::of((-1.0f64..20_000.0, any::<bool>())),
                prop::collection::vec((-1.0f64..2000.0, any::<bool>()), 0..24),
                prop::option::of(0u8..20),
                ".{0,8}",
            )
                .prop_map(
                    |(id, name, kind, shafts, treadles, width, reeds, at_once, notes)| {
                        LoomProfile {
                            id,
                            name,
                            kind,
                            shafts,
                            treadles,
                            weaving_width: width.map(|(value, inches)| Length {
                                value,
                                unit: if inches {
                                    ply_common::Unit::Inches
                                } else {
                                    ply_common::Unit::Centimeters
                                },
                            }),
                            reeds: reeds
                                .into_iter()
                                .map(|(dents, inch)| Reed {
                                    dents,
                                    per: if inch {
                                        DentUnit::PerInch
                                    } else {
                                        DentUnit::Per10Cm
                                    },
                                })
                                .collect(),
                            treadles_at_once: at_once,
                            notes,
                        }
                    },
                )
        }

        /// One change to a file, of the kinds a hand or a crafted file makes.
        #[derive(Debug, Clone)]
        enum Change {
            None,
            /// A key the format does not have, at the top or in a loom.
            Unknown {
                top: bool,
                at: usize,
            },
            /// The `looms` key again, before the real one.
            LoomsTwice(serde_json::Value),
            /// A loom's value replaced by another value.
            Replace {
                at: usize,
                key: usize,
                with: serde_json::Value,
            },
            /// A loom written as a list of its values.
            AsList(usize),
            /// A loom's key dropped.
            Drop {
                at: usize,
                key: usize,
            },
            /// The version or format changed.
            Version(serde_json::Value),
            Format(serde_json::Value),
        }

        fn arb_value() -> impl Strategy<Value = serde_json::Value> {
            let leaf = prop_oneof![
                Just(serde_json::Value::Null),
                any::<bool>().prop_map(serde_json::Value::from),
                any::<i64>().prop_map(serde_json::Value::from),
                any::<u64>().prop_map(serde_json::Value::from),
                (-1e6f64..1e6).prop_map(serde_json::Value::from),
                ".{0,6}".prop_map(serde_json::Value::from),
            ];
            leaf.prop_recursive(3, 16, 4, |inner| {
                prop_oneof![
                    prop::collection::vec(inner.clone(), 0..4).prop_map(serde_json::Value::from),
                    prop::collection::btree_map("[a-z]{0,3}", inner, 0..4)
                        .prop_map(|m| serde_json::Value::Object(m.into_iter().collect())),
                ]
            })
        }

        fn arb_change() -> impl Strategy<Value = Change> {
            prop_oneof![
                3 => Just(Change::None),
                1 => (any::<bool>(), 0usize..8).prop_map(|(top, at)| Change::Unknown { top, at }),
                1 => arb_value().prop_map(Change::LoomsTwice),
                3 => (0usize..8, 0usize..9, arb_value())
                    .prop_map(|(at, key, with)| Change::Replace { at, key, with }),
                1 => (0usize..8).prop_map(Change::AsList),
                1 => (0usize..8, 0usize..9).prop_map(|(at, key)| Change::Drop { at, key }),
                1 => arb_value().prop_map(Change::Version),
                1 => arb_value().prop_map(Change::Format),
            ]
        }

        /// The file for `looms` with `change` made to it, as text.
        fn file(looms: &[LoomProfile], change: &Change) -> String {
            let mut looms: Vec<serde_json::Value> = looms
                .iter()
                .map(|l| serde_json::to_value(l).unwrap())
                .collect();
            let pick = |n: usize, len: usize| if len == 0 { None } else { Some(n % len) };
            let keys = |v: &serde_json::Value| -> Vec<String> {
                v.as_object()
                    .map(|o| o.keys().cloned().collect())
                    .unwrap_or_default()
            };
            let mut top = serde_json::Map::new();
            top.insert("format".into(), LOOMS_FORMAT.into());
            top.insert("schema_version".into(), 1.into());
            let mut before = String::new();
            match change {
                Change::None => {}
                Change::Unknown { top: true, .. } => {
                    top.insert("extra".into(), serde_json::json!([1, {"a": null}]));
                }
                Change::Unknown { at, .. } => {
                    if let Some(i) = pick(*at, looms.len()) {
                        looms[i]["colour"] = "red".into();
                    }
                }
                Change::LoomsTwice(v) => before = format!(r#""looms":{v},"#),
                Change::Replace { at, key, with } => {
                    if let Some(i) = pick(*at, looms.len()) {
                        let k = keys(&looms[i]);
                        if let Some(j) = pick(*key, k.len()) {
                            looms[i][&k[j]] = with.clone();
                        }
                    }
                }
                Change::AsList(at) => {
                    if let Some(i) = pick(*at, looms.len()) {
                        let l: LoomProfile = serde_json::from_value(looms[i].clone()).unwrap();
                        looms[i] = serde_json::json!([
                            l.id,
                            l.name,
                            l.kind,
                            l.shafts,
                            l.treadles,
                            l.weaving_width,
                            l.reeds,
                            l.treadles_at_once,
                            l.notes
                        ]);
                    }
                }
                Change::Drop { at, key } => {
                    if let Some(i) = pick(*at, looms.len()) {
                        let k = keys(&looms[i]);
                        if let Some(j) = pick(*key, k.len()) {
                            looms[i].as_object_mut().unwrap().remove(&k[j]);
                        }
                    }
                }
                Change::Version(v) => {
                    top.insert("schema_version".into(), v.clone());
                }
                Change::Format(v) => {
                    top.insert("format".into(), v.clone());
                }
            }
            top.insert("looms".into(), serde_json::Value::Array(looms));
            let text = serde_json::Value::Object(top).to_string();
            text.replacen('{', &format!("{{{before}"), 1)
        }

        proptest! {
            #![proptest_config(ProptestConfig::with_cases(512))]

            /// Generated libraries, valid and not, as written and with one change made to the
            /// file: the typed route gives the tree route's verdict on each.
            #[test]
            fn the_typed_route_gives_the_tree_route_s_verdict(
                looms in prop::collection::vec(arb_loom(), 0..6),
                change in arb_change(),
            ) {
                let text = file(&looms, &change);
                assert_same_verdict(&text);
                if matches!(change, Change::None) {
                    let lib = LoomLibrary { looms };
                    if lib.problems().is_empty() {
                        prop_assert_eq!(read(&text).unwrap(), lib);
                    }
                }
            }
        }
    }

    #[test]
    fn the_typed_route_refuses_a_key_repeated_inside_a_loom() {
        // The one difference from the tree route, in a file no writer produces (serde writes each
        // field once): the tree kept the last value.
        let text = r#"{"format":"ply.looms","schema_version":1,"looms":[{"id":"a","name":"x","name":"A"}]}"#;
        assert_eq!(
            read_through_tree(text).unwrap().looms,
            vec![LoomProfile::new("a", "A")]
        );
        assert!(matches!(read(text), Err(LoomFileError::Malformed(_))));
    }

    #[test]
    fn the_tracked_fixture_round_trips_byte_for_byte() {
        let text = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../fixtures/weaving/looms/looms.json"
        ))
        .unwrap();
        let lib = read(&text).unwrap();
        assert!(lib.looms.len() >= 4);
        assert_eq!(write(&lib).unwrap(), text.trim_end_matches('\n'));
    }
}
