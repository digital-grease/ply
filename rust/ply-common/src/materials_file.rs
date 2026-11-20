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
//!
//! **Decoding builds no generic tree** (ADR 0007, amendment of 2026-11-18, item 8), as for
//! `looms.json`. [`read`] makes two passes over the text. The first
//! ([`crate::envelope::top_level`]) accepts and refuses the text exactly as a decode into a
//! `serde_json::Value` would, reads the envelope and counts the records, building nothing; the
//! second decodes a current-version file's records straight into their types. Every verdict is the
//! tree's, in the tree's order (not JSON, not an object, the format, the version, too many
//! materials, too many swatches, then the records themselves), with one exception no writer can
//! produce: a key repeated inside a record is refused, where the tree kept its last value. An older
//! version would be read through a tree for `MIGRATIONS`; when version 2 is added, that route needs
//! a bound of its own (as older `.plyknit` versions have).

use crate::envelope::{top_level, KeyAmong, TopEntry, TopValue};
use crate::materials::{Material, RecordDiagnostic, Severity, Swatch};
use serde::de::{Deserializer, IgnoredAny, MapAccess, Visitor};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;
use std::fmt;

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
            if let Err(e @ MaterialsFileError::NewerVersion { .. }) = probe(text) {
                return Err(e);
            }
        }
        return Err(MaterialsFileError::TooLarge(format!(
            "{} bytes, over {MAX_MATERIALS_FILE_BYTES}",
            text.len()
        )));
    }
    let probed = probe(text)?;
    if probed.version != MATERIALS_SCHEMA_VERSION {
        return read_through_tree(text);
    }
    // Count before decoding the records, so a hostile file cannot make the decoder build huge lists.
    for (key, entry, max) in [
        ("materials", &probed.materials, MAX_MATERIALS),
        ("swatches", &probed.swatches, MAX_SWATCHES),
    ] {
        if let Some(TopEntry {
            value: TopValue::List(n),
            ..
        }) = entry
        {
            if *n > max {
                return Err(MaterialsFileError::TooLarge(format!(
                    "{n} {key}, over {max}"
                )));
            }
        }
    }
    let (materials, swatches) = current_records(
        text,
        probed.materials.map(|e| e.index),
        probed.swatches.map(|e| e.index),
    )
    .map_err(|e| MaterialsFileError::Malformed(e.to_string()))?;
    checked(MaterialLibrary {
        materials,
        swatches,
    })
}

/// A library read from the file, refused (`Malformed`) when it breaks a limit, repeats an id or
/// holds a record with an error.
fn checked(library: MaterialLibrary) -> Result<MaterialLibrary, MaterialsFileError> {
    if let Some(first) = library.problems().into_iter().next() {
        return Err(MaterialsFileError::Malformed(first));
    }
    Ok(library)
}

/// How a file was read before the typed decode, and how a file of an older version (none yet) is
/// read: decoded into a `serde_json::Value`, migrated, counted, then decoded into the records. Tests
/// compare the typed route with it.
fn read_through_tree(text: &str) -> Result<MaterialLibrary, MaterialsFileError> {
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
    checked(MaterialLibrary {
        materials: doc.materials,
        swatches: doc.swatches,
    })
}

/// The schema version of a `materials.json`, by the detection rule, without reading its records.
pub fn schema_version(text: &str) -> Result<u32, MaterialsFileError> {
    probe(text).map(|p| p.version)
}

/// The keys of the envelope [`probe`] reads, in its order.
const ENVELOPE_KEYS: [&str; 4] = ["format", "schema_version", "materials", "swatches"];

/// What [`probe`] found: a version this build reads, and the record keys the tree would keep.
struct Probed {
    version: u32,
    materials: Option<TopEntry>,
    swatches: Option<TopEntry>,
}

/// Apply the detection rule as [`split`] does, with the same verdict on every text, without
/// building a tree (see [`top_level`]).
fn probe(text: &str) -> Result<Probed, MaterialsFileError> {
    let Some(found) = top_level(text, &ENVELOPE_KEYS)
        .map_err(|e| MaterialsFileError::Malformed(e.to_string()))?
    else {
        return Err(MaterialsFileError::Malformed(
            "a materials file must be a JSON object".into(),
        ));
    };
    let [format, version, materials, swatches] = <[Option<TopEntry>; 4]>::try_from(found)
        .unwrap_or_else(|_| unreachable!("one entry a key"));
    match format.map(|e| e.value) {
        Some(TopValue::Scalar(Value::String(f))) if f == MATERIALS_FORMAT => {}
        Some(other) => {
            return Err(MaterialsFileError::WrongFormat {
                found: shown(&other).chars().take(40).collect(),
            })
        }
        None => {
            return Err(MaterialsFileError::WrongFormat {
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
            MaterialsFileError::Malformed("schema_version must be a positive integer".into())
        })?;
    if version > u64::from(MATERIALS_SCHEMA_VERSION) {
        return Err(MaterialsFileError::NewerVersion {
            found: version,
            supported: MATERIALS_SCHEMA_VERSION,
        });
    }
    Ok(Probed {
        // At most MATERIALS_SCHEMA_VERSION here, so it fits a u32.
        version: version as u32,
        materials,
        swatches,
    })
}

/// A top-level value for a message: a scalar as JSON text (as the tree printed it), a list or an
/// object by its kind.
fn shown(value: &TopValue) -> String {
    match value {
        TopValue::Scalar(v) => v.to_string(),
        TopValue::List(_) => "a list".into(),
        TopValue::Object => "an object".into(),
    }
}

/// The records of a current-version file whose envelope [`probe`] accepted, decoded straight into
/// their types: the `materials` and `swatches` entries at `materials` and `swatches` (the ones a
/// tree keeps) are decoded, the envelope's own keys and earlier record entries are skipped (the
/// probe has walked them), and any other key is refused as an unknown field, as the tree's typed
/// decode refused it.
fn current_records(
    text: &str,
    materials: Option<usize>,
    swatches: Option<usize>,
) -> Result<(Vec<Material>, Vec<Swatch>), serde_json::Error> {
    let mut de = serde_json::Deserializer::from_str(text);
    let records = (&mut de).deserialize_map(CurrentRecords {
        materials,
        swatches,
    })?;
    de.end()?;
    Ok(records)
}

struct CurrentRecords {
    materials: Option<usize>,
    swatches: Option<usize>,
}

impl<'de> Visitor<'de> for CurrentRecords {
    type Value = (Vec<Material>, Vec<Swatch>);
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a materials file")
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
        let (mut materials, mut swatches) = (None, None);
        let mut index = 0;
        while let Some(key) = map.next_key_seed(KeyAmong(&ENVELOPE_KEYS))? {
            match key {
                Ok(2) if Some(index) == self.materials => {
                    materials = Some(map.next_value::<Vec<Material>>()?);
                }
                Ok(3) if Some(index) == self.swatches => {
                    swatches = Some(map.next_value::<Vec<Swatch>>()?);
                }
                Ok(_) => {
                    map.next_value::<IgnoredAny>()?;
                }
                Err(other) => {
                    return Err(serde::de::Error::unknown_field(
                        &other,
                        &["materials", "swatches"],
                    ))
                }
            }
            index += 1;
        }
        let materials = materials.ok_or_else(|| serde::de::Error::missing_field("materials"))?;
        let swatches = swatches.ok_or_else(|| serde::de::Error::missing_field("swatches"))?;
        Ok((materials, swatches))
    }
}

/// Apply the detection rule: the file's schema version and the rest of the envelope (its document),
/// decoded into a tree (the route of [`read_through_tree`]).
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

    /// The verdicts of the typed route and the tree route on `text`: the same library, or the same
    /// kind of refusal. A refusal found before the records are decoded (the JSON itself, the
    /// envelope, the counts) has the same message too; one found decoding them has the tree's kind.
    fn assert_same_verdict(text: &str) {
        let typed = read(text);
        let tree = read_through_tree(text);
        match (&typed, &tree) {
            (Ok(a), Ok(b)) => assert_eq!(a, b, "{text:.200}"),
            (Err(MaterialsFileError::Malformed(a)), Err(MaterialsFileError::Malformed(b))) => {
                if probe(text).is_err() {
                    assert_eq!(a, b, "{text:.200}");
                }
            }
            (Err(a @ MaterialsFileError::WrongFormat { found }), Err(b)) => {
                if found.starts_with("a ") || found.starts_with("an ") {
                    // A list or an object is named by its kind, where the tree printed it.
                    assert!(
                        matches!(b, MaterialsFileError::WrongFormat { .. }),
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

    fn fixture() -> String {
        std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../fixtures/materials/materials.json"
        ))
        .unwrap()
    }

    #[test]
    fn the_typed_route_gives_the_tree_route_s_verdict() {
        let env = |rest: &str| format!(r#"{{"format":"ply.materials","schema_version":1,{rest}}}"#);
        let deep = |n: usize| format!("{}{}", "[".repeat(n), "]".repeat(n));
        let ok = r#""materials":[],"swatches":[]"#;
        let mut cases = vec![
            fixture(),
            write(&library()).unwrap(),
            // Keys in any order, records as lists, a unit variant as a one-key object.
            r#"{"swatches":[],"materials":[{"id":"a"}],"schema_version":1,"format":"ply.materials"}"#
                .into(),
            env(r#""materials":[{"id":"a","fibers":[["wool",50]]}],"swatches":[]"#),
            env(r#""materials":[],"swatches":[{"id":"s","after":{"width":{"value":{"value":10,"unit":{"cm":null}},"source":"measured"}}}]"#),
            env(r#""materials":[{"id":"a","available_mass":[[50,"g"],"entered"]}],"swatches":[]"#),
            // Repeated top-level keys: the last counts.
            env(r#""materials":7,"materials":[],"swatches":[],"swatches":[{"id":"s"}]"#),
            env(r#""materials":[{"id":"a"}],"swatches":[],"materials":[]"#),
            // Refusals, each with others behind it.
            "".into(),
            "[]".into(),
            "null".into(),
            env(ok).replace('}', "} x"),
            env(&format!("{ok},\"x\":1")),
            env(&format!("\"x\":1,{ok}")),
            env(r#""materials":[]"#),
            env(r#""swatches":[]"#),
            env(r#""materials":{},"swatches":[]"#),
            env(r#""materials":[{"id":"a","colour":"red"}],"swatches":[]"#),
            env(r#""materials":[{"id":"a"},{"id":"a"}],"swatches":[]"#),
            env(r#""materials":[{"id":"a","weight":"chunky"}],"swatches":[]"#),
            env(r#""materials":[],"swatches":[{"id":"s","date":"yesterday"}]"#),
            env(r#""materials":[],"swatches":[{"id":"s","craft":"crochet"}]"#),
            env(r#""materials":[],"swatches":[{"id":"s","after":{"width":{"value":{"value":0,"unit":"cm"},"source":"measured"}}}]"#),
            r#"{"schema_version":1,"materials":[],"swatches":[]}"#.into(),
            r#"{"format":"ply.looms","schema_version":1}"#.into(),
            format!(r#"{{"format":"{}","schema_version":1}}"#, "x".repeat(100)),
            r#"{"format":[1,2,3],"schema_version":1}"#.into(),
            r#"{"format":{"a":"b"},"schema_version":1}"#.into(),
            r#"{"format":"ply.materials","schema_version":0}"#.into(),
            r#"{"format":"ply.materials","schema_version":2.5}"#.into(),
            r#"{"format":"ply.materials","schema_version":3,"materials":"later"}"#.into(),
            // What a decode into a tree refuses anywhere, the probe refuses alike.
            env(&format!(r#"{ok},"x":{}"#, deep(127))),
            env(&format!(r#"{ok},"x":{}"#, deep(128))),
            env(&format!(r#"{ok},"x":{}"#, deep(300))),
            env(&format!(r#"{ok},"x":"\ud83d""#)),
            env(&format!(r#"{ok},"x":-1e400"#)),
            format!(r#"{{"format":"ply.materials","schema_version":2,"x":{}}}"#, deep(300)),
            r#"{"format":"ply.materials","schema_version":2,"x":"\ud83d"}"#.into(),
        ];
        let many = |key: &str, n: usize, extra: &str| {
            let records: Vec<String> = (0..n).map(|i| format!(r#"{{"id":"r{i}"}}"#)).collect();
            let other = if key == "materials" {
                "swatches"
            } else {
                "materials"
            };
            env(&format!(
                r#""{key}":[{}],"{other}":[]{extra}"#,
                records.join(",")
            ))
        };
        for extra in ["", r#","x":1"#, r#","materials":[]"#] {
            cases.push(many("materials", MAX_MATERIALS + 1, extra));
            cases.push(many("swatches", MAX_SWATCHES + 1, extra));
        }
        cases.push(env(&format!(
            r#""materials":[{}],"swatches":[{}]"#,
            vec!["7"; MAX_MATERIALS + 1].join(","),
            vec!["7"; MAX_SWATCHES + 1].join(",")
        )));
        for text in &cases {
            assert_same_verdict(text);
        }
    }

    #[test]
    fn the_typed_route_refuses_a_key_repeated_inside_a_record() {
        // The one difference from the tree route, in a file no writer produces (serde writes each
        // field once): the tree kept the last value.
        let text = r#"{"format":"ply.materials","schema_version":1,"materials":[{"id":"a","name":"x","name":"A"}],"swatches":[]}"#;
        assert_eq!(
            read_through_tree(text).unwrap().materials,
            vec![Material::new("a", "A")]
        );
        assert!(matches!(read(text), Err(MaterialsFileError::Malformed(_))));
    }

    mod generated {
        use super::*;
        use proptest::prelude::*;

        fn arb_value() -> impl Strategy<Value = Value> {
            let leaf = prop_oneof![
                Just(Value::Null),
                any::<bool>().prop_map(Value::from),
                any::<i64>().prop_map(Value::from),
                any::<u64>().prop_map(Value::from),
                (-1e6f64..1e6).prop_map(Value::from),
                prop::sample::select(vec![
                    "",
                    "cm",
                    "m",
                    "in",
                    "yd",
                    "g",
                    "kg",
                    "oz",
                    "lb",
                    "measured",
                    "entered",
                    "default",
                    "light",
                    "medium",
                    "knitting",
                    "weaving",
                    "main",
                    "2026-11-18",
                ])
                .prop_map(Value::from),
            ];
            leaf.prop_recursive(3, 16, 4, |inner| {
                prop_oneof![
                    prop::collection::vec(inner.clone(), 0..4).prop_map(Value::from),
                    prop::collection::btree_map(
                        prop::sample::select(vec!["value", "unit", "source", "x", "count"]),
                        inner,
                        0..3
                    )
                    .prop_map(|m| Value::Object(
                        m.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
                    )),
                ]
            })
        }

        /// Every place in `v` (as JSON pointers), the root included.
        fn places(v: &Value, at: String, out: &mut Vec<String>) {
            out.push(at.clone());
            match v {
                Value::Array(a) => {
                    for (i, x) in a.iter().enumerate() {
                        places(x, format!("{at}/{i}"), out);
                    }
                }
                Value::Object(o) => {
                    for (k, x) in o {
                        places(
                            x,
                            format!("{at}/{}", k.replace('~', "~0").replace('/', "~1")),
                            out,
                        );
                    }
                }
                _ => {}
            }
        }

        #[derive(Debug, Clone)]
        enum Change {
            Replace(Value),
            Remove,
            AddKey(Value),
            AsList,
        }

        fn arb_change() -> impl Strategy<Value = Change> {
            prop_oneof![
                4 => arb_value().prop_map(Change::Replace),
                2 => Just(Change::Remove),
                1 => arb_value().prop_map(Change::AddKey),
                1 => Just(Change::AsList),
            ]
        }

        /// The fixture with `changes` made at the places `at` picks.
        fn changed(changes: &[(usize, Change)]) -> String {
            let mut v: Value = serde_json::from_str(&fixture()).unwrap();
            for (at, change) in changes {
                let mut all = Vec::new();
                places(&v, String::new(), &mut all);
                let place = &all[at % all.len()];
                let (parent, last) = match place.rfind('/') {
                    Some(i) => (&place[..i], &place[i + 1..]),
                    None => ("", ""),
                };
                match change {
                    Change::Replace(with) => *v.pointer_mut(place).unwrap() = with.clone(),
                    Change::Remove => match v.pointer_mut(parent) {
                        Some(Value::Object(o)) => {
                            o.remove(&last.replace("~1", "/").replace("~0", "~"));
                        }
                        Some(Value::Array(a)) => {
                            if let Ok(i) = last.parse::<usize>() {
                                if i < a.len() {
                                    a.remove(i);
                                }
                            }
                        }
                        _ => {}
                    },
                    Change::AddKey(with) => {
                        if let Some(Value::Object(o)) = v.pointer_mut(place) {
                            o.insert("unknown".into(), with.clone());
                        }
                    }
                    Change::AsList => {
                        let target = v.pointer_mut(place).unwrap();
                        if let Value::Object(o) = target {
                            *target = Value::Array(o.values().cloned().collect());
                        }
                    }
                }
            }
            v.to_string()
        }

        proptest! {
            #![proptest_config(ProptestConfig::with_cases(768))]

            /// The fixture (every kind of record and quantity) with one to three changes made
            /// anywhere in it: the typed route gives the tree route's verdict on each.
            #[test]
            fn the_typed_route_gives_the_tree_route_s_verdict(
                changes in prop::collection::vec((any::<usize>(), arb_change()), 1..4),
            ) {
                assert_same_verdict(&changed(&changes));
            }
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
