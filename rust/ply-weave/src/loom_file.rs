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

use crate::loom::LoomProfile;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;
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
            if let Err(e @ LoomFileError::NewerVersion { .. }) = split(text) {
                return Err(e);
            }
        }
        return Err(LoomFileError::TooLarge(format!(
            "{} bytes, over {MAX_LOOMS_FILE_BYTES}",
            text.len()
        )));
    }
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
    let library = LoomLibrary { looms: doc.looms };
    if let Some(first) = library.problems().into_iter().next() {
        return Err(LoomFileError::Malformed(first));
    }
    Ok(library)
}

/// The schema version of a `looms.json`, by the detection rule, without reading its looms. Errors as
/// [`read`] would for the envelope itself.
pub fn schema_version(text: &str) -> Result<u32, LoomFileError> {
    split(text).map(|(v, _)| v)
}

/// Apply the detection rule: the file's schema version and the rest of the envelope (its document).
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
