//! `materials.json`: the crafter's materials and swatches, one file in the app's documents
//! directory (ADR 0016).
//!
//! ```json
//! { "format": "ply.materials", "schema_version": 1, "materials": [ ... ], "swatches": [ ... ] }
//! ```
//!
//! Detection follows ADR 0002, as `looms.json` does (ADR 0014): one JSON object whose `format` is
//! exactly `ply.materials` and whose `schema_version` is a positive integer. A NEWER version is
//! refused with [`MaterialsFileError::NewerVersion`] before the records are looked at, so this build
//! never reads (and the app never overwrites) a file a later Ply wrote. An older version would be
//! migrated in memory through `MIGRATIONS` (none yet: version 1 is the first).
//!
//! The file is untrusted input: its size, the number of records, every value (a record with an
//! [`Severity::Error`] diagnostic is refused) and the uniqueness of ids are checked, and unknown
//! fields are refused (a file with them was not written by this version). Unknown values are written
//! as `null` (or empty text and lists), so the file itself shows what was not recorded. Derived
//! figures are never written: they are worked out from the measurements when shown.

use crate::materials::{Material, RecordDiagnostic, Severity, Swatch};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;

/// The `format` value of `materials.json`.
pub const MATERIALS_FORMAT: &str = "ply.materials";

/// The schema version this build writes, and the newest it reads.
pub const MATERIALS_SCHEMA_VERSION: u32 = 1;

/// The largest `materials.json` this build reads, in bytes.
pub const MAX_MATERIALS_FILE_BYTES: usize = 2 * 1024 * 1024;

/// The most materials one file may hold.
pub const MAX_MATERIALS: usize = 500;

/// The most swatches one file may hold.
pub const MAX_SWATCHES: usize = 500;

/// The largest file whose envelope is still looked at when it is over the size limit, so that a file
/// a newer Ply wrote is reported as newer (never overwritten), not as too large.
pub const MAX_PROBED_FILE_BYTES: usize = 16 * 1024 * 1024;

/// Why a `materials.json` cannot be read or written.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MaterialsFileError {
    /// Written by a newer Ply: do not read it, do not overwrite it.
    NewerVersion { found: u64, supported: u32 },
    /// A JSON object with another (or no) `format`.
    WrongFormat { found: String },
    /// Over the size or record-count limit.
    TooLarge(String),
    /// Not JSON, a malformed envelope, a field of the wrong type or an unknown field, a value that
    /// cannot be true, or a repeated id.
    Malformed(String),
}

impl std::fmt::Display for MaterialsFileError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MaterialsFileError::NewerVersion { found, supported } => write!(
                f,
                "the materials file was saved by a newer version of Ply (schema version {found}; \
                 this build reads up to {supported})"
            ),
            MaterialsFileError::WrongFormat { found } => {
                write!(f, "not a Ply materials file (format {found})")
            }
            MaterialsFileError::TooLarge(s) => write!(f, "the materials file is too large: {s}"),
            MaterialsFileError::Malformed(s) => {
                write!(f, "the materials file could not be read: {s}")
            }
        }
    }
}

impl std::error::Error for MaterialsFileError {}

/// Every material and swatch the crafter has, in the order they listed them.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct MaterialLibrary {
    pub materials: Vec<Material>,
    pub swatches: Vec<Swatch>,
}

impl MaterialLibrary {
    pub fn material(&self, id: &str) -> Option<&Material> {
        self.materials.iter().find(|m| m.id == id)
    }

    pub fn swatch(&self, id: &str) -> Option<&Swatch> {
        self.swatches.iter().find(|s| s.id == id)
    }

    /// Every problem that stops this library from being written or read (empty = valid): too many
    /// records, a repeated id, or a record with an error.
    pub fn problems(&self) -> Vec<String> {
        let mut out = Vec::new();
        if self.materials.len() > MAX_MATERIALS {
            out.push(format!("more than {MAX_MATERIALS} materials"));
        }
        if self.swatches.len() > MAX_SWATCHES {
            out.push(format!("more than {MAX_SWATCHES} swatches"));
        }
        let mut ids = BTreeSet::new();
        for m in &self.materials {
            if !ids.insert(m.id.as_str()) {
                out.push(format!("material id {:?} appears twice", m.id));
            }
            out.extend(errors(&m.diagnostics()).map(|d| format!("{}: {d}", m.display_name())));
        }
        let mut ids = BTreeSet::new();
        for s in &self.swatches {
            if !ids.insert(s.id.as_str()) {
                out.push(format!("swatch id {:?} appears twice", s.id));
            }
            out.extend(errors(&s.diagnostics()).map(|d| format!("{}: {d}", s.display_name())));
        }
        out
    }

    fn too_many(&self) -> bool {
        self.materials.len() > MAX_MATERIALS || self.swatches.len() > MAX_SWATCHES
    }
}

/// The error messages among `diagnostics` (warnings never stop a record being stored).
fn errors(diagnostics: &[RecordDiagnostic]) -> impl Iterator<Item = String> + '_ {
    diagnostics
        .iter()
        .filter(|d| d.severity == Severity::Error)
        .map(|d| format!("{} ({})", d.message, d.code))
}

#[derive(Serialize)]
struct Envelope<'a> {
    format: &'static str,
    schema_version: u32,
    materials: &'a [Material],
    swatches: &'a [Swatch],
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
    materials: Vec<Material>,
    swatches: Vec<Swatch>,
}

/// Serialize `library` as a current-version `materials.json` (pretty JSON). A library that breaks the
/// limits or holds a record with an error is refused rather than written, so Ply never writes a file
/// it would refuse to read.
pub fn write(library: &MaterialLibrary) -> Result<String, MaterialsFileError> {
    if let Some(first) = library.problems().into_iter().next() {
        return Err(if library.too_many() {
            MaterialsFileError::TooLarge(first)
        } else {
            MaterialsFileError::Malformed(first)
        });
    }
    let text = serde_json::to_string_pretty(&Envelope {
        format: MATERIALS_FORMAT,
        schema_version: MATERIALS_SCHEMA_VERSION,
        materials: &library.materials,
        swatches: &library.swatches,
    })
    .map_err(|e| MaterialsFileError::Malformed(e.to_string()))?;
    if text.len() > MAX_MATERIALS_FILE_BYTES {
        return Err(MaterialsFileError::TooLarge(format!(
            "{} bytes, over {MAX_MATERIALS_FILE_BYTES}",
            text.len()
        )));
    }
    Ok(text)
}

/// Parse a `materials.json` of any supported version (see the module doc for what is refused).
pub fn read(text: &str) -> Result<MaterialLibrary, MaterialsFileError> {
    if text.len() > MAX_MATERIALS_FILE_BYTES {
        if text.len() <= MAX_PROBED_FILE_BYTES {
            if let Err(e @ MaterialsFileError::NewerVersion { .. }) = split(text) {
                return Err(e);
            }
        }
        return Err(MaterialsFileError::TooLarge(format!(
            "{} bytes, over {MAX_MATERIALS_FILE_BYTES}",
            text.len()
        )));
    }
    let (version, document) = split(text)?;
    let document = migrate(version, document)?;
    // Count before decoding the records, so a hostile file cannot make the decoder build huge lists.
    for (key, max) in [("materials", MAX_MATERIALS), ("swatches", MAX_SWATCHES)] {
        if let Some(n) = document.get(key).and_then(Value::as_array).map(Vec::len) {
            if n > max {
                return Err(MaterialsFileError::TooLarge(format!(
                    "{n} {key}, over {max}"
                )));
            }
        }
    }
    let doc: Document = serde_json::from_value(document)
        .map_err(|e| MaterialsFileError::Malformed(e.to_string()))?;
    let library = MaterialLibrary {
        materials: doc.materials,
        swatches: doc.swatches,
    };
    if let Some(first) = library.problems().into_iter().next() {
        return Err(MaterialsFileError::Malformed(first));
    }
    Ok(library)
}

/// The schema version of a `materials.json`, by the detection rule, without reading its records.
pub fn schema_version(text: &str) -> Result<u32, MaterialsFileError> {
    split(text).map(|(v, _)| v)
}

fn split(text: &str) -> Result<(u32, Value), MaterialsFileError> {
    let value: Value =
        serde_json::from_str(text).map_err(|e| MaterialsFileError::Malformed(e.to_string()))?;
    let Value::Object(mut obj) = value else {
        return Err(MaterialsFileError::Malformed(
            "a materials file must be a JSON object".into(),
        ));
    };
    match obj.get("format") {
        Some(Value::String(f)) if f == MATERIALS_FORMAT => {}
        Some(other) => {
            return Err(MaterialsFileError::WrongFormat {
                found: other.to_string().chars().take(40).collect(),
            })
        }
        None => {
            return Err(MaterialsFileError::WrongFormat {
                found: "missing".into(),
            })
        }
    }
    let version = obj
        .get("schema_version")
        .and_then(Value::as_u64)
        .filter(|&v| v >= 1)
        .ok_or_else(|| {
            MaterialsFileError::Malformed("schema_version must be a positive integer".into())
        })?;
    if version > u64::from(MATERIALS_SCHEMA_VERSION) {
        return Err(MaterialsFileError::NewerVersion {
            found: version,
            supported: MATERIALS_SCHEMA_VERSION,
        });
    }
    obj.remove("format");
    obj.remove("schema_version");
    // `version` is at most MATERIALS_SCHEMA_VERSION here, so it fits a u32.
    Ok((version as u32, Value::Object(obj)))
}

/// One migration: a document at version `n` in, the same document at version `n + 1` out.
type Migration = fn(Value) -> Result<Value, MaterialsFileError>;

/// The ordered migration chain, tied to [`MATERIALS_SCHEMA_VERSION`] so bumping the version without
/// appending a migration does not compile. Version 1 is the first, so there are none yet.
const MIGRATIONS: [Migration; MATERIALS_SCHEMA_VERSION as usize - 1] = [];

fn migrate(from: u32, mut document: Value) -> Result<Value, MaterialsFileError> {
    for step in MIGRATIONS.iter().skip((from as usize).saturating_sub(1)) {
        document = step(document)?;
    }
    Ok(document)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::materials::{FiberPart, Stage, SwatchYarn, YarnRole};
    use crate::provenance::Recorded;
    use crate::quantity::{CountOver, Length, LengthPerMass, LengthUnit, Mass};
    use crate::{CraftKind, YarnWeight};
    use serde_json::json;

    fn library() -> MaterialLibrary {
        let mut wool = Material::new("grey-wool", "Grey wool");
        wool.fibers = vec![FiberPart {
            fiber: "wool".into(),
            percent: Some(100.0),
        }];
        wool.weight = Some(YarnWeight::Light);
        wool.length_per_mass = Some(Recorded::entered(LengthPerMass::new(
            Length::new(200.0, LengthUnit::Meter),
            Mass::grams(100.0),
        )));
        let mut sw = Swatch::new("sw-1", "Grey wool");
        sw.craft = Some(CraftKind::Knitting);
        sw.yarns = vec![SwatchYarn {
            material_id: Some("grey-wool".into()),
            name: "Grey wool".into(),
            role: Some(YarnRole::Main),
        }];
        sw.after = Stage {
            across: Some(Recorded::measured(CountOver::new(20.0, Length::cm(10.0)))),
            ..Stage::default()
        };
        MaterialLibrary {
            materials: vec![wool, Material::new("partial", "")],
            swatches: vec![sw, Swatch::new("empty", "")],
        }
    }

    #[test]
    fn round_trips_and_writes_unknowns_as_null() {
        let text = write(&library()).unwrap();
        assert_eq!(read(&text).unwrap(), library());
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["format"], "ply.materials");
        assert_eq!(v["schema_version"], 1);
        let partial = &v["materials"][1];
        for key in [
            "weight",
            "length_per_mass",
            "wpi",
            "available_mass",
            "available_length",
        ] {
            assert!(partial[key].is_null(), "{key} is written as null");
        }
        assert_eq!(v["materials"][0]["weight"], "light");
        assert_eq!(v["materials"][0]["length_per_mass"]["source"], "entered");
        assert_eq!(
            v["materials"][0]["length_per_mass"]["value"]["length"]["unit"],
            "m"
        );
        assert_eq!(v["swatches"][0]["craft"], "knitting");
        assert_eq!(v["swatches"][0]["yarns"][0]["role"], "main");
        assert!(v["swatches"][1]["after"]["width"].is_null());
        // Nothing derived is written.
        assert!(!text.contains("per_10cm") && !text.contains("figures"));
        assert_eq!(write(&read(&text).unwrap()).unwrap(), text);
    }

    #[test]
    fn missing_optional_keys_read_as_unknown() {
        let text = r#"{"format":"ply.materials","schema_version":1,
            "materials":[{"id":"a"}],"swatches":[{"id":"b"}]}"#;
        let lib = read(text).unwrap();
        assert_eq!(lib.materials, vec![Material::new("a", "")]);
        assert_eq!(lib.swatches, vec![Swatch::new("b", "")]);
    }

    #[test]
    fn a_newer_file_is_refused_before_its_records_are_read() {
        let text = r#"{"format":"ply.materials","schema_version":2,"materials":"later"}"#;
        assert_eq!(
            read(text),
            Err(MaterialsFileError::NewerVersion {
                found: 2,
                supported: 1
            })
        );
        assert!(matches!(
            schema_version(text),
            Err(MaterialsFileError::NewerVersion { .. })
        ));
    }

    #[test]
    fn foreign_malformed_and_impossible_files_are_refused() {
        let ok = r#""materials":[],"swatches":[]"#;
        for (text, wrong_format) in [
            ("[]".to_string(), false),
            ("not json".to_string(), false),
            (r#"{"format":"ply.looms","schema_version":1}"#.to_string(), true),
            (format!(r#"{{"format":"ply.materials","schema_version":0,{ok}}}"#), false),
            (r#"{"format":"ply.materials","schema_version":1,"materials":[]}"#.to_string(), false),
            (format!(r#"{{"format":"ply.materials","schema_version":1,{ok},"x":1}}"#), false),
            (
                r#"{"format":"ply.materials","schema_version":1,"materials":[{"id":"a","colour":"red"}],"swatches":[]}"#.to_string(),
                false,
            ),
            (
                r#"{"format":"ply.materials","schema_version":1,"materials":[{"id":"a"},{"id":"a"}],"swatches":[]}"#.to_string(),
                false,
            ),
            // A size of zero cannot be true.
            (
                r#"{"format":"ply.materials","schema_version":1,"materials":[],"swatches":[{"id":"s","after":{"width":{"value":{"value":0,"unit":"cm"},"source":"measured"}}}]}"#.to_string(),
                false,
            ),
            // A record never holds one of Ply's defaults.
            (
                r#"{"format":"ply.materials","schema_version":1,"materials":[{"id":"a","available_mass":{"value":{"value":50,"unit":"g"},"source":"default"}}],"swatches":[]}"#.to_string(),
                false,
            ),
            (
                r#"{"format":"ply.materials","schema_version":1,"materials":[{"id":"a","weight":"chunky"}],"swatches":[]}"#.to_string(),
                false,
            ),
            (
                r#"{"format":"ply.materials","schema_version":1,"materials":[],"swatches":[{"id":"s","date":"yesterday"}]}"#.to_string(),
                false,
            ),
        ] {
            let err = read(&text).unwrap_err();
            assert_eq!(
                matches!(err, MaterialsFileError::WrongFormat { .. }),
                wrong_format,
                "{text}: {err}"
            );
        }
    }

    #[test]
    fn warnings_do_not_stop_a_record_being_stored() {
        let mut lib = library();
        lib.materials[0].fibers.push(FiberPart {
            fiber: "silk".into(),
            percent: None,
        });
        lib.materials[0].fibers[0].percent = Some(90.0); // not all known: no warning either way
        lib.swatches[0].before.width = Some(Recorded::measured(Length::cm(10.0)));
        lib.swatches[0].after.width = Some(Recorded::measured(Length::cm(25.0))); // grew 150%: a warning
        let text = write(&lib).unwrap();
        assert_eq!(read(&text).unwrap(), lib);
    }

    #[test]
    fn limits_are_enforced_on_read_and_write() {
        let mut big = MaterialLibrary::default();
        for i in 0..=MAX_MATERIALS {
            big.materials.push(Material::new(format!("m{i}"), ""));
        }
        assert!(matches!(write(&big), Err(MaterialsFileError::TooLarge(_))));
        let swatches: Vec<Value> = (0..=MAX_SWATCHES)
            .map(|i| json!({"id": format!("s{i}")}))
            .collect();
        let text = json!({"format": "ply.materials", "schema_version": 1, "materials": [],
            "swatches": swatches})
        .to_string();
        assert!(matches!(read(&text), Err(MaterialsFileError::TooLarge(_))));
        let huge = format!(
            r#"{{"format":"ply.materials","schema_version":1,"materials":[],"swatches":[],"pad":"{}"}}"#,
            "x".repeat(MAX_MATERIALS_FILE_BYTES)
        );
        assert!(matches!(read(&huge), Err(MaterialsFileError::TooLarge(_))));
        let huge_newer = huge.replace("\"schema_version\":1", "\"schema_version\":2");
        assert!(matches!(
            read(&huge_newer),
            Err(MaterialsFileError::NewerVersion { found: 2, .. })
        ));
        let mut bad = library();
        bad.swatches[0].after.across =
            Some(Recorded::measured(CountOver::new(-3.0, Length::cm(10.0))));
        assert!(matches!(write(&bad), Err(MaterialsFileError::Malformed(_))));
    }
}
