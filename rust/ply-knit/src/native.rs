//! The native `.plyknit` file format: a versioned ENVELOPE around a [`KnitPattern`] document, and
//! the ordered migrations that bring an older file up to the current schema.
//!
//! ```json
//! { "format": "ply.knit", "schema_version": 3, "document": { "name": "...", "legend": ... } }
//! ```
//!
//! **Version detection (deterministic).** A `.plyknit` file is one JSON object.
//! - It has a `"format"` key: it is an envelope. `format` must be exactly `"ply.knit"` and
//!   `schema_version` a positive integer; the pattern is the `"document"` value.
//! - It has no `"format"` key: it is a LEGACY version-1 file. Releases v0.1.0 to v0.1.7 wrote the bare
//!   pattern object, which never has a `format` field.
//!
//! **Why an envelope.** Released readers decode the bare pattern strictly (every field required), so
//! they fail to parse an enveloped file and their editor shows an error instead of loading something
//! else that a later save would write back over the real pattern.
//!
//! **Reading never writes.** A file newer than [`KNIT_SCHEMA_VERSION`] is refused with
//! [`KnitError::NewerVersion`] before its document is looked at. An older file is migrated IN MEMORY
//! through the `MIGRATIONS` chain, one version at a time; the caller decides whether to save it.
//!
//! **Changing the format.** Any change to the document shape OR to the built-in stitch vocabulary
//! (see [`StitchLegend::builtin`](crate::StitchLegend::builtin)) bumps [`KNIT_SCHEMA_VERSION`] and
//! appends one migration that knows exactly what changed. Migrations work on JSON values, not on the
//! current Rust types, so an old step keeps working after the types move on.
//!
//! **Versions.**
//! - 1: the bare pattern object of releases v0.1.0 to v0.1.7 (no envelope).
//! - 2: the envelope; built-in stitches stored exactly as saved (the frozen `builtins_v2`).
//! - 3: the document gains `cast_on` (a stitch count, or `null` when the pattern does not state
//!   one). The built-in vocabulary is unchanged from version 2.

use serde::Serialize;
use serde_json::{json, Value};

use crate::error::KnitError;
use crate::pattern::KnitPattern;

/// The `format` value of a `.plyknit` envelope.
pub const KNIT_FORMAT: &str = "ply.knit";

/// The `.plyknit` schema version this build writes, and the newest it can read.
pub const KNIT_SCHEMA_VERSION: u32 = 3;

/// A pattern read from a `.plyknit` file, with the schema version the file was written at.
#[derive(Debug, Clone, PartialEq)]
pub struct LoadedPattern {
    /// The pattern, migrated to the current schema.
    pub pattern: KnitPattern,
    /// The file's own schema version (1 for a legacy, unversioned file). Older than
    /// [`KNIT_SCHEMA_VERSION`] means saving will upgrade the file's format.
    pub source_version: u32,
}

#[derive(Serialize)]
struct Envelope<'a> {
    format: &'static str,
    schema_version: u32,
    document: &'a KnitPattern,
}

/// Serialize a pattern as a current-version `.plyknit` envelope (pretty JSON). A NaN/infinite gauge
/// is rejected: serde would write it as `null`, which then fails to parse back.
pub fn write(pattern: &KnitPattern) -> Result<String, KnitError> {
    if !pattern.gauge.sts.is_finite() || !pattern.gauge.rows.is_finite() {
        return Err(KnitError::NonFiniteGauge);
    }
    Ok(serde_json::to_string_pretty(&Envelope {
        format: KNIT_FORMAT,
        schema_version: KNIT_SCHEMA_VERSION,
        document: pattern,
    })?)
}

/// Parse a `.plyknit` file of any supported version, migrating an older one to the current schema in
/// memory. A newer version, a foreign `format`, or a malformed envelope is a typed error.
pub fn read(text: &str) -> Result<LoadedPattern, KnitError> {
    let (source_version, document) = split(serde_json::from_str(text)?)?;
    let document = migrate(source_version, document)?;
    Ok(LoadedPattern {
        pattern: serde_json::from_value(document)?,
        source_version,
    })
}

/// The schema version of a `.plyknit` file by the detection rule above, without decoding or
/// migrating its document. Errors exactly as [`read`] would for the envelope itself.
pub fn schema_version(text: &str) -> Result<u32, KnitError> {
    split(serde_json::from_str(text)?).map(|(version, _)| version)
}

/// Apply the detection rule: the file's schema version and its document value.
fn split(value: Value) -> Result<(u32, Value), KnitError> {
    let Value::Object(mut obj) = value else {
        return Err(KnitError::Malformed(
            "a .plyknit file must be a JSON object".into(),
        ));
    };
    let Some(format) = obj.get("format") else {
        return Ok((1, Value::Object(obj))); // legacy: the bare pattern object
    };
    if format.as_str() != Some(KNIT_FORMAT) {
        return Err(KnitError::WrongFormat {
            found: format.to_string(),
        });
    }
    let version = obj
        .get("schema_version")
        .and_then(Value::as_u64)
        .filter(|&v| v >= 1)
        .ok_or_else(|| KnitError::Malformed("schema_version must be a positive integer".into()))?;
    if version > u64::from(KNIT_SCHEMA_VERSION) {
        return Err(KnitError::NewerVersion {
            found: version,
            supported: KNIT_SCHEMA_VERSION,
        });
    }
    let document = obj
        .remove("document")
        .ok_or_else(|| KnitError::Malformed("the envelope has no document".into()))?;
    // `version` is at most KNIT_SCHEMA_VERSION here, so it fits a u32.
    Ok((version as u32, document))
}

/// One migration: a document at version `n` in, the same document at version `n + 1` out.
type Migration = fn(Value) -> Result<Value, KnitError>;

/// The ordered migration chain: `MIGRATIONS[i]` upgrades a document from version `i + 1` to `i + 2`.
/// The length is tied to [`KNIT_SCHEMA_VERSION`], so bumping the version without appending its
/// migration does not compile.
const MIGRATIONS: [Migration; KNIT_SCHEMA_VERSION as usize - 1] = [v1_to_v2, v2_to_v3];

/// Run every migration from `from` up to the current version, in order.
fn migrate(from: u32, mut document: Value) -> Result<Value, KnitError> {
    // `split` guarantees 1 <= from <= KNIT_SCHEMA_VERSION.
    for step in &MIGRATIONS[(from as usize).saturating_sub(1)..] {
        document = step(document)?;
    }
    Ok(document)
}

/// Built-in counts that released versions wrote at the head of a legacy (version 1) legend:
/// 12 (v0.1.0 to v0.1.5), 20 (v0.1.6), 21 (v0.1.7). Each is a prefix of the next.
const LEGACY_BUILTIN_COUNTS: [usize; 3] = [12, 20, 21];

/// The built-in stitch vocabulary exactly as schema version 2 defines it, in wire form. FROZEN: this
/// is what a version-2 legend's built-in entries mean. Version 3 changed the document shape only, so
/// it uses this vocabulary unchanged. A later vocabulary gets its own frozen copy and its own
/// migration; this one never changes.
fn builtins_v2() -> Vec<Value> {
    let def = |symbol: &str, consumes: u8, produces: u8, ws_variant: Option<u8>| {
        json!({
            "symbol": symbol,
            "consumes": consumes,
            "produces": produces,
            "ws_variant": ws_variant,
            "cable": null,
            "macro_rows": 1,
        })
    };
    vec![
        def("ns", 0, 0, None),
        def("k", 1, 1, Some(2)),
        def("p", 1, 1, Some(1)),
        def("yo", 0, 1, None),
        def("k2tog", 2, 1, Some(6)),
        def("ssk", 2, 1, Some(6)),
        def("p2tog", 2, 1, Some(4)),
        def("cdd", 3, 1, None),
        def("m1l", 0, 1, None),
        def("m1r", 0, 1, None),
        def("kfb", 1, 2, None),
        def("sl", 1, 1, None),
        def("k3tog", 3, 1, None),
        def("sk2po", 3, 1, None),
        def("ssp", 2, 1, None),
        def("kbf", 1, 2, None),
        def("pfb", 1, 2, None),
        def("m1p", 0, 1, None),
        def("m1lp", 0, 1, None),
        def("m1rp", 0, 1, None),
        def("ktbl", 1, 1, None),
    ]
}

/// Whether a saved legend entry is the given frozen built-in. Compares the six version-1 fields, with
/// an absent optional field read as `null` (serde accepts that for `Option` fields).
fn same_def(saved: &Value, builtin: &Value) -> bool {
    const FIELDS: [&str; 6] = [
        "symbol",
        "consumes",
        "produces",
        "ws_variant",
        "cable",
        "macro_rows",
    ];
    let (Some(saved), Some(builtin)) = (saved.as_object(), builtin.as_object()) else {
        return false;
    };
    FIELDS
        .iter()
        .all(|f| saved.get(*f).unwrap_or(&Value::Null) == builtin.get(*f).unwrap_or(&Value::Null))
}

/// Version 1 to 2: put a legacy pattern on the full version-2 built-in vocabulary.
///
/// A legacy legend is `[the built-ins of the release that saved it] ++ [custom stitches]`. The
/// built-in count is one of [`LEGACY_BUILTIN_COUNTS`]: the largest of them that the saved legend
/// matches entry for entry. (Matching alone could over-count if a custom equalled the next built-in;
/// releases only ever created cables as customs, and no built-in is a cable, but the released counts
/// make the rule exact either way.) The missing built-ins are inserted after that prefix, every
/// custom moves up by the number inserted, and each chart cell and custom `ws_variant` that named a
/// custom follows it.
///
/// A legend that does not start with the 12 original built-ins was not written by any release and is
/// refused rather than guessed at.
fn v1_to_v2(mut doc: Value) -> Result<Value, KnitError> {
    let builtins = builtins_v2();
    let n = builtins.len();
    let Some(saved) = doc.pointer("/legend/stitches").and_then(Value::as_array) else {
        return Ok(doc); // not the legacy shape; the typed decode reports what is missing
    };
    let matched = saved
        .iter()
        .zip(&builtins)
        .take_while(|(s, b)| same_def(s, b))
        .count();
    let Some(k) = LEGACY_BUILTIN_COUNTS
        .iter()
        .copied()
        .filter(|&c| c <= matched)
        .max()
    else {
        return Err(KnitError::Malformed(format!(
            "the stitch legend does not start with Ply's {} original built-in stitches",
            LEGACY_BUILTIN_COUNTS[0]
        )));
    };
    if k == n {
        return Ok(doc); // saved by v0.1.7: already on the full vocabulary
    }
    let (k, inserted) = (k as u64, (n - k) as u64);
    let remap = |id: &mut Value| -> Result<(), KnitError> {
        if let Some(old) = id.as_u64().filter(|&old| old >= k) {
            let new = old
                .checked_add(inserted)
                .ok_or_else(|| KnitError::Malformed(format!("stitch id {old} is out of range")))?;
            *id = Value::from(new);
        }
        Ok(())
    };

    if let Some(stitches) = doc
        .pointer_mut("/legend/stitches")
        .and_then(Value::as_array_mut)
    {
        let mut customs = stitches.split_off(k as usize);
        for custom in &mut customs {
            if let Some(ws) = custom.get_mut("ws_variant") {
                remap(ws)?;
            }
        }
        *stitches = builtins.into_iter().chain(customs).collect();
    }
    if let Some(rows) = doc.pointer_mut("/chart/rows").and_then(Value::as_array_mut) {
        for row in rows {
            let Some(cells) = row.get_mut("cells").and_then(Value::as_array_mut) else {
                continue;
            };
            for cell in cells {
                if let Some(stitch) = cell.get_mut("stitch") {
                    remap(stitch)?;
                }
            }
        }
    }
    Ok(doc)
}

/// Version 2 to 3: the document gains `cast_on`, set to `null` ("not set").
///
/// A version-2 pattern never stated a cast-on, so the migration states none: it does not derive one
/// from row 1 (that would put a number in the file the knitter never wrote, and would turn a
/// first-row to-end repeat into a count Ply guessed). A `cast_on` key already in a version-2 document
/// was written by no release and meant nothing there, so it is replaced by `null` rather than given a
/// meaning now. Everything else in the document is untouched.
fn v2_to_v3(mut doc: Value) -> Result<Value, KnitError> {
    if let Some(obj) = doc.as_object_mut() {
        obj.insert("cast_on".into(), Value::Null);
    }
    // Not an object: left as is, so the typed decode reports what is wrong.
    Ok(doc)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pattern::{
        builtin, CableDef, Cell, Chart, Construction, Cross, Gauge, Row, Side, StitchDef,
        StitchLegend,
    };
    use ply_common::{Color, Unit};

    /// The fixture tree shared with the Flutter tests.
    fn fixture(rel: &str) -> String {
        let path = format!(
            "{}/../../fixtures/migrations/plyknit/{rel}",
            env!("CARGO_MANIFEST_DIR")
        );
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path}: {e}"))
    }

    /// Every released legacy fixture: (release, file, built-ins that release wrote).
    const LEGACY: [(&str, &str, usize); 6] = [
        ("v0.1.5", "sampler", 12),
        ("v0.1.5", "custom-ws-variant", 12),
        ("v0.1.6", "sampler", 20),
        ("v0.1.6", "custom-ws-variant", 20),
        ("v0.1.7", "sampler", 21),
        ("v0.1.7", "custom-ws-variant", 21),
    ];

    fn cable(symbol: &str, front: u8, back: u8, direction: Cross) -> StitchDef {
        StitchDef {
            symbol: symbol.into(),
            consumes: front + back,
            produces: front + back,
            ws_variant: None,
            cable: Some(CableDef {
                front,
                back,
                direction,
                front_purl: false,
                back_purl: false,
            }),
            macro_rows: 1,
        }
    }

    fn ribbing() -> KnitPattern {
        KnitPattern {
            name: "1x1 rib".into(),
            construction: Construction::Flat,
            first_row_side: Side::Rs,
            cast_on: None,
            gauge: Gauge {
                sts: 24.0,
                rows: 32.0,
                unit: Unit::Inches,
            },
            palette: vec![Color::WHITE],
            legend: StitchLegend::builtin(),
            chart: Chart {
                width: 2,
                rows: vec![Row::plain(vec![
                    Cell::of(builtin::KNIT),
                    Cell::of(builtin::PURL),
                ])],
            },
            notes: String::new(),
        }
    }

    /// The bare (legacy, version 1) JSON a release wrote for `p`: no envelope, and no `cast_on`
    /// (no release had one).
    fn legacy_json(p: &KnitPattern) -> String {
        let mut v = serde_json::to_value(p).unwrap();
        v.as_object_mut().unwrap().remove("cast_on");
        serde_json::to_string_pretty(&v).unwrap()
    }

    /// A version-2 envelope holding `p` as the version-2 writer stored it (no `cast_on` key).
    fn v2_json(p: &KnitPattern) -> String {
        let mut doc = serde_json::to_value(p).unwrap();
        doc.as_object_mut().unwrap().remove("cast_on");
        serde_json::to_string_pretty(&json!({
            "format": "ply.knit",
            "schema_version": 2,
            "document": doc,
        }))
        .unwrap()
    }

    /// The real version-2 bytes the engine wrote before version 3 (see each `.fixture.toml`).
    const SCHEMA_V2: [&str; 3] = [
        "rib-edges-flat",
        "rib-cast-on-unknown-flat",
        "cable-repeat-round",
    ];

    /// The built-in vocabulary is part of the schema. If this fails, the built-ins changed: bump
    /// KNIT_SCHEMA_VERSION, freeze the new vocabulary next to `builtins_v2`, and append a migration
    /// that maps exactly what changed (see the format ADR). Do not edit `builtins_v2`. Schema 3 only
    /// added `cast_on`, so its vocabulary is still the version-2 one.
    #[test]
    fn current_builtins_are_the_frozen_schema_vocabulary() {
        assert_eq!(
            KNIT_SCHEMA_VERSION, 3,
            "update this test with the new snapshot"
        );
        let current = serde_json::to_value(&StitchLegend::builtin().stitches).unwrap();
        assert_eq!(current, Value::Array(builtins_v2()));
        assert_eq!(builtins_v2().len(), *LEGACY_BUILTIN_COUNTS.last().unwrap());
    }

    #[test]
    fn write_produces_a_current_envelope() {
        let json = write(&ribbing()).unwrap();
        let v: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["format"], "ply.knit");
        assert_eq!(v["schema_version"], 3);
        assert_eq!(v["document"]["name"], "1x1 rib");
        assert_eq!(
            v["document"]["cast_on"],
            Value::Null,
            "not set is written as null"
        );
        assert_eq!(schema_version(&json).unwrap(), 3);
    }

    #[test]
    fn the_envelope_round_trips() {
        let p = ribbing();
        let loaded = read(&write(&p).unwrap()).unwrap();
        assert_eq!(loaded.pattern, p);
        assert_eq!(loaded.source_version, KNIT_SCHEMA_VERSION);
    }

    /// A version-3 file keeps its cast-on through save and load, byte for byte on a re-save.
    #[test]
    fn a_v3_cast_on_round_trips() {
        let mut p = ribbing();
        p.cast_on = Some(26);
        let text = write(&p).unwrap();
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["document"]["cast_on"], 26);
        let loaded = read(&text).unwrap();
        assert_eq!(loaded.source_version, 3);
        assert_eq!(loaded.pattern, p);
        assert_eq!(write(&loaded.pattern).unwrap(), text);
    }

    /// The real version-2 bytes migrate to the current version with the cast-on NOT set and every
    /// other document field exactly as stored; a re-save is a current envelope that loads unchanged.
    #[test]
    fn every_schema_v2_fixture_migrates_to_v3_unchanged_but_for_the_cast_on() {
        for name in SCHEMA_V2 {
            let text = fixture(&format!("schema-v2/{name}.plyknit"));
            assert_eq!(schema_version(&text).unwrap(), 2, "{name}");
            let stored: Value = serde_json::from_str(&text).unwrap();
            let stored_doc = stored["document"].clone();
            assert!(
                stored_doc.get("cast_on").is_none(),
                "{name}: v2 had no cast_on"
            );

            let loaded = read(&text).unwrap();
            assert_eq!(loaded.source_version, 2, "{name}");
            assert_eq!(
                loaded.pattern.cast_on, None,
                "{name}: a migration never invents one"
            );
            let mut migrated = serde_json::to_value(&loaded.pattern).unwrap();
            assert_eq!(
                migrated.as_object_mut().unwrap().remove("cast_on"),
                Some(Value::Null)
            );
            assert_eq!(migrated, stored_doc, "{name}: nothing else changes");

            let saved = write(&loaded.pattern).unwrap();
            assert_eq!(schema_version(&saved).unwrap(), KNIT_SCHEMA_VERSION);
            let again = read(&saved).unwrap();
            assert_eq!(again.source_version, KNIT_SCHEMA_VERSION);
            assert_eq!(again.pattern, loaded.pattern, "{name}");
        }
    }

    /// The migrated version-2 fixtures count, write and validate exactly as they did at version 2
    /// (the oracle results recorded in `fixtures/knitting/repeats/` when these bytes were written).
    /// The one wording change: the first-row warning now points at the cast-on setting.
    #[test]
    fn schema_v2_fixtures_count_write_and_validate_as_before() {
        use crate::{stitch_flow, to_written, validate, Severity};
        type Expect = (
            &'static str,
            &'static [&'static str],
            &'static [Option<u64>],
            &'static [(&'static str, &'static str)],
        );
        let expected: [Expect; 3] = [
            (
                "rib-edges-flat",
                &[
                    "Row 1 (RS): k, [k2, p2] 3 times, k",
                    "Row 2 (WS): p, [k2, p2] 3 times, p",
                    "Row 3 (RS): k, [k2, p2] 3 times, k",
                    "Row 4 (WS): p, [k2, p2] 3 times, p",
                ],
                &[Some(14), Some(14), Some(14), Some(14)],
                &[],
            ),
            (
                "rib-cast-on-unknown-flat",
                &[
                    "Row 1 (RS): k, *k2, p2; rep from * to last st, k",
                    "Row 2 (WS): p, *k2, p2; rep from * to last st, p",
                ],
                &[None, None],
                &[
                    (
                        "warning",
                        "row 1: the repeat over cols 2-5 is worked to the end of the row, but the \
                         pattern has no cast-on count, so Ply cannot count this row (it needs a \
                         multiple of 4 stitches plus 2); set the cast-on in the pattern settings",
                    ),
                    (
                        "warning",
                        "row 2: the repeat over cols 2-5 is worked to the end of the row, but the \
                         stitch count after row 1 is unknown, so Ply cannot count this row (it \
                         needs a multiple of 4 stitches plus 2)",
                    ),
                ],
            ),
            (
                "cable-repeat-round",
                &[
                    "Round 1: k2, [p, 2/2 RC, p] 4 times",
                    "Round 2: k2, *p, k4, p; rep from * to end",
                    "Round 3: (repeats need fixing: the repeat over cols 1-5 splits the cable at \
                     cols 4-7; a cable must be wholly inside or outside a repeat)",
                    "Round 4: k2, [p, k4, p] 4 times",
                ],
                &[Some(26), Some(26), None, Some(26)],
                &[(
                    "error",
                    "row 3: the repeat over cols 1-5 splits the cable at cols 4-7; a cable must \
                     be wholly inside or outside a repeat",
                )],
            ),
        ];
        for (name, written, produced, issues) in expected {
            let p = read(&fixture(&format!("schema-v2/{name}.plyknit")))
                .unwrap()
                .pattern;
            assert_eq!(
                to_written(&p),
                written,
                "{name}: no cast-on line, rows as before"
            );
            let counts: Vec<Option<u64>> = stitch_flow(&p)
                .iter()
                .map(|f| f.count.map(|c| c.produced))
                .collect();
            assert_eq!(counts, produced, "{name}: counts");
            let got: Vec<(&str, String)> = validate(&p)
                .into_iter()
                .map(|i| {
                    let s = match i.severity {
                        Severity::Error => "error",
                        Severity::Warning => "warning",
                    };
                    (s, i.message)
                })
                .collect();
            let want: Vec<(&str, String)> =
                issues.iter().map(|&(s, m)| (s, m.to_string())).collect();
            assert_eq!(got, want, "{name}: validation");
        }
    }

    /// A version-2 document never meant anything by a `cast_on` key (no writer produced one), so the
    /// migration replaces it with "not set" instead of giving it a meaning now.
    #[test]
    fn v2_to_v3_never_carries_a_number_forward() {
        let p = ribbing();
        let mut v: Value = serde_json::from_str(&v2_json(&p)).unwrap();
        v["document"]["cast_on"] = json!(99);
        let loaded = read(&v.to_string()).unwrap();
        assert_eq!(loaded.source_version, 2);
        assert_eq!(loaded.pattern.cast_on, None);
        assert_eq!(loaded.pattern, p);
        // The step alone, on a value that is not a document object, leaves it for the typed decode.
        assert_eq!(v2_to_v3(json!([1, 2])).unwrap(), json!([1, 2]));
    }

    /// The real bytes each release wrote load, migrate onto the full vocabulary, and every cell still
    /// names the stitch it named when it was saved.
    #[test]
    fn every_legacy_fixture_migrates_with_cells_on_the_same_stitches() {
        let current = StitchLegend::builtin().stitches;
        for (release, name, saved_builtins) in LEGACY {
            let text = fixture(&format!("{release}/{name}.plyknit"));
            let old: Value = serde_json::from_str(&text).unwrap();
            let old_legend = old["legend"]["stitches"].as_array().unwrap();
            assert_eq!(schema_version(&text).unwrap(), 1, "{release}/{name}");

            let loaded = read(&text).unwrap();
            assert_eq!(loaded.source_version, 1);
            let p = loaded.pattern;
            let customs = old_legend.len() - saved_builtins;
            assert_eq!(
                p.legend.stitches.len(),
                current.len() + customs,
                "{release}/{name}"
            );
            assert_eq!(p.legend.stitches[..current.len()], current[..]);
            // Each custom keeps its definition; a ws_variant naming a custom follows it.
            for (j, custom) in p.legend.stitches[current.len()..].iter().enumerate() {
                let was = &old_legend[saved_builtins + j];
                assert_eq!(custom.symbol, was["symbol"].as_str().unwrap());
                assert_eq!(serde_json::to_value(custom.cable).unwrap(), was["cable"]);
                let old_ws = was["ws_variant"].as_u64().map(|w| w as usize);
                let expect_ws = old_ws.map(|w| {
                    if w < saved_builtins {
                        w
                    } else {
                        w - saved_builtins + current.len()
                    }
                });
                assert_eq!(custom.ws_variant, expect_ws, "{release}/{name} custom {j}");
            }
            // Every cell resolves to the same stitch definition (by symbol + counts) as before.
            let old_rows = old["chart"]["rows"].as_array().unwrap();
            assert_eq!(p.chart.rows.len(), old_rows.len());
            for (row, old_row) in p.chart.rows.iter().zip(old_rows) {
                let old_cells = old_row["cells"].as_array().unwrap();
                assert_eq!(row.cells.len(), old_cells.len());
                for (cell, old_cell) in row.cells.iter().zip(old_cells) {
                    let was = &old_legend[old_cell["stitch"].as_u64().unwrap() as usize];
                    let now = &p.legend.stitches[cell.stitch];
                    assert_eq!(now.symbol, was["symbol"].as_str().unwrap());
                    assert_eq!(u64::from(now.consumes), was["consumes"].as_u64().unwrap());
                    assert_eq!(serde_json::to_value(now.cable).unwrap(), was["cable"]);
                    assert_eq!(
                        cell.color.map(|c| c as u64),
                        old_cell["color"].as_u64(),
                        "colorwork survives"
                    );
                }
                assert_eq!(
                    serde_json::to_value(&row.repeats).unwrap(),
                    old_row["repeats"],
                    "repeat spans survive"
                );
            }
            assert_eq!(p.name, old["name"].as_str().unwrap());
            assert_eq!(p.notes, old["notes"].as_str().unwrap());
            assert_eq!(
                p.cast_on, None,
                "{release}/{name}: migrated all the way, not set"
            );
            assert_eq!(p.palette.len(), old["palette"].as_array().unwrap().len());
        }
    }

    /// load -> save -> load is stable: migrating twice changes nothing, and the saved file is a
    /// current envelope.
    #[test]
    fn migration_is_idempotent() {
        for (release, name, _) in LEGACY {
            let once = read(&fixture(&format!("{release}/{name}.plyknit")))
                .unwrap()
                .pattern;
            let saved = write(&once).unwrap();
            assert_eq!(schema_version(&saved).unwrap(), KNIT_SCHEMA_VERSION);
            let twice = read(&saved).unwrap();
            assert_eq!(twice.pattern, once, "{release}/{name}");
            assert_eq!(write(&twice.pattern).unwrap(), saved, "byte-stable re-save");
        }
    }

    /// The old heuristic upgrade, now the v1 -> v2 step: a 12-built-in legend with a cable at index 12
    /// is spliced, and the cable cell follows the cable.
    #[test]
    fn v1_to_v2_moves_a_custom_cable_and_remaps_its_cells() {
        let mut old = ribbing();
        old.legend.stitches.truncate(12);
        old.legend
            .stitches
            .push(cable("2/2 RC", 2, 2, Cross::Right));
        old.chart.rows[0].cells[1] = Cell::of(12);
        let p = read(&legacy_json(&old)).unwrap().pattern;
        assert_eq!(p.legend.stitches.len(), 22);
        assert_eq!(p.legend.stitches[21].symbol, "2/2 RC");
        assert_eq!(p.chart.rows[0].cells[0].stitch, builtin::KNIT);
        assert_eq!(p.chart.rows[0].cells[1].stitch, 21);
    }

    /// The released built-in counts make the split exact: a custom that happens to equal the next
    /// built-in is still a custom.
    #[test]
    fn v1_to_v2_uses_the_released_builtin_counts() {
        let mut old = ribbing();
        old.legend.stitches.truncate(12);
        // A custom identical to built-in 12 (k3tog). No release could create one; the rule still
        // treats it as a custom because releases wrote 12, 20 or 21 built-ins.
        old.legend
            .stitches
            .push(StitchLegend::builtin().stitches[12].clone());
        old.chart.rows[0].cells[1] = Cell::of(12);
        let p = read(&legacy_json(&old)).unwrap().pattern;
        assert_eq!(p.legend.stitches.len(), 22, "21 built-ins + the custom");
        assert_eq!(
            p.chart.rows[0].cells[1].stitch, 21,
            "the cell follows the custom"
        );
    }

    #[test]
    fn a_legacy_legend_without_the_original_builtins_is_refused() {
        let mut old = ribbing();
        old.legend.stitches.truncate(5);
        let err = read(&legacy_json(&old)).unwrap_err();
        assert!(matches!(err, KnitError::Malformed(_)), "{err}");
    }

    /// Version 2 and 3 legends load exactly as saved: no prefix matching. Here built-in 5 (ssk)
    /// differs from the vocabulary and a custom equals a built-in; neither is touched.
    #[test]
    fn a_v2_legend_loads_exactly_as_saved() {
        let mut p = ribbing();
        p.legend.stitches[builtin::SSK].ws_variant = Some(builtin::PURL);
        p.legend
            .stitches
            .push(StitchLegend::builtin().stitches[builtin::KNIT].clone());
        p.chart.rows[0].cells[1] = Cell::of(21);
        let loaded = read(&write(&p).unwrap()).unwrap();
        assert_eq!(loaded.pattern, p);
        let from_v2 = read(&v2_json(&p)).unwrap();
        assert_eq!(from_v2.source_version, 2);
        assert_eq!(from_v2.pattern, p);

        // The same legend written as a LEGACY file goes through the v1 -> v2 rule instead, which does
        // not recognize the altered built-ins as any release's vocabulary.
        assert!(matches!(
            read(&legacy_json(&p)),
            Err(KnitError::Malformed(_))
        ));
    }

    #[test]
    fn a_newer_version_is_a_typed_error() {
        let p = ribbing();
        let text = write(&p)
            .unwrap()
            .replace("\"schema_version\": 3", "\"schema_version\": 4");
        let err = read(&text).unwrap_err();
        assert!(
            matches!(
                err,
                KnitError::NewerVersion {
                    found: 4,
                    supported: 3
                }
            ),
            "{err}"
        );
        assert!(matches!(
            schema_version(&text),
            Err(KnitError::NewerVersion { .. })
        ));
        // Refused before the document is looked at: even a document this build cannot decode.
        let future = r#"{"format":"ply.knit","schema_version":99,"document":{"rows":"new shape"}}"#;
        assert!(matches!(
            read(future),
            Err(KnitError::NewerVersion { found: 99, .. })
        ));
    }

    #[test]
    fn a_wrong_format_is_an_error() {
        let err = read(r#"{"format":"ply.nalbind","schemaVersion":2,"name":"x"}"#).unwrap_err();
        assert!(matches!(err, KnitError::WrongFormat { .. }), "{err}");
        assert!(matches!(
            read(r#"{"format":7,"schema_version":2,"document":{}}"#),
            Err(KnitError::WrongFormat { .. })
        ));
    }

    #[test]
    fn a_malformed_envelope_is_an_error() {
        for bad in [
            r#"{"format":"ply.knit","document":{}}"#,
            r#"{"format":"ply.knit","schema_version":0,"document":{}}"#,
            r#"{"format":"ply.knit","schema_version":"2","document":{}}"#,
            r#"{"format":"ply.knit","schema_version":2}"#,
            r#"[1, 2, 3]"#,
        ] {
            assert!(
                matches!(read(bad), Err(KnitError::Malformed(_))),
                "{bad} should be malformed"
            );
        }
        // A well-formed envelope around a document missing a field fails the typed decode.
        assert!(matches!(
            read(r#"{"format":"ply.knit","schema_version":2,"document":{}}"#),
            Err(KnitError::Json(_))
        ));
    }

    /// An envelope claiming version 1 holds a legacy document and is migrated like one.
    #[test]
    fn an_envelope_at_version_1_is_migrated() {
        let mut old = ribbing();
        old.legend.stitches.truncate(12);
        let text = serde_json::to_string(&json!({
            "format": "ply.knit",
            "schema_version": 1,
            "document": serde_json::to_value(&old).unwrap(),
        }))
        .unwrap();
        let loaded = read(&text).unwrap();
        assert_eq!(loaded.source_version, 1);
        assert_eq!(loaded.pattern.legend, StitchLegend::builtin());
    }
}
