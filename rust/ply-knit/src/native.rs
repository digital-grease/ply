//! The native `.plyknit` file format: a versioned ENVELOPE around a [`KnitPattern`] document, and
//! the ordered migrations that bring an older file up to the current schema.
//!
//! ```json
//! { "format": "ply.knit", "schema_version": 6, "document": { "name": "...", "legend": ... } }
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
//! **The version is read from the text alone.** [`schema_version`] applies the detection rule with
//! the shared envelope probe ([`ply_common::envelope`]): one pass over the text that skips the
//! document unread and builds nothing in proportion to the file, however large. [`read`] asks it
//! first, so a newer, foreign or malformed envelope is refused before any of the file is decoded.
//!
//! **A guard for untrusted files.** The document is decoded into a JSON tree (for the migrations),
//! and many small values make a tree far larger than its text. [`within_value_limit`] counts a
//! file's values without decoding it; the backup restore refuses a pattern past [`MAX_VALUES`]
//! before it reads it. Opening and saving do not ask.
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
//! - 4: the document gains `sections` (the construction layer, [`crate::sections`]; `[]` for a
//!   chart-only pattern). The built-in vocabulary is unchanged from version 2. A step kind this
//!   build does not know makes the file unreadable: it is never dropped on load.
//! - 5: working in the round and sock heels. Each section gains `construction` (`null`: not
//!   stated), each short-row step gains `decrease` (`null`: none), short rows can turn at the gap
//!   (`BeforeGap`, `PastGap`), and eight step kinds are new (`JoinRound`, `WorkFlat`, `Rows`,
//!   `Shape`, `PickUp`, `Groups`, `Close`, `RoundStart`). The built-in vocabulary is unchanged from version 2. A
//!   version-4 file that names a newer step kind or turn was not written by any version-4 writer
//!   and is refused.
//! - 6: several pieces (ADR 0020). The document gains `pieces` (`[]`: one piece), each section
//!   gains `piece` (`null`: the first piece, the only one in an older file), each close step gains
//!   `holds` (`[]`: it closes the stitches on the needle, as before), and one step kind is new
//!   (`Join`). The built-in vocabulary is unchanged from version 2. A version-5 file that names
//!   `Join` was not written by any version-5 writer and is refused.

use ply_common::envelope::{envelope_version, EnvelopeError, EnvelopeRule, FORMAT_KEY};
use ply_common::json_count::count_values;
use serde::Serialize;
use serde_json::{json, Value};

use crate::error::KnitError;
use crate::pattern::KnitPattern;

/// The `format` value of a `.plyknit` envelope.
pub const KNIT_FORMAT: &str = "ply.knit";

/// The `.plyknit` schema version this build writes, and the newest it can read.
pub const KNIT_SCHEMA_VERSION: u32 = 6;

/// The most JSON values (objects, lists, strings, numbers, `true`, `false`, `null` and object
/// keys, as [`ply_common::json_count::count_values`] counts them) a pattern from a backup may
/// have: past it, the restore refuses the pattern as too complex to check, without decoding it.
///
/// Sized from the largest pattern the app can make, from the format's limits: a chart of 200
/// stitches by 400 rows (the editor's and the new pattern screen's limits) with every cell coloured
/// and a repeat on every column, 1,000 custom stitches and 1,000 colours, 50 pieces, 1,000 sections
/// and 10,000 steps (a text of any length is one value). It has 1.28 million values; this is over
/// twice that. The guard bounds decode memory only roughly: a file at the limit decodes, at worst
/// (objects of one member nested inside each other), to about 900 MiB of `serde_json::Value`
/// (counted by a counting allocator, before the allocator's own overhead), and the largest real
/// pattern to about 230 MiB. The migrations add a field to every section, short row and close step,
/// so they first refuse one without the fields every writer gave it: an empty object, a few bytes in
/// its list, would otherwise grow into a map node of hundreds. A long text is one value and decodes
/// to about its length.
pub const MAX_VALUES: u64 = 3_000_000;

/// How a `.plyknit` states its version: the envelope's `format` and `schema_version`, or no `format`
/// key at all for a legacy version-1 file.
const KNIT_ENVELOPE: EnvelopeRule = EnvelopeRule {
    format: KNIT_FORMAT,
    version_key: "schema_version",
    legacy_without_format: true,
};

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
/// memory. A newer version, a foreign `format`, or a malformed envelope is a typed error, found by
/// [`schema_version`] before the file is decoded.
pub fn read(text: &str) -> Result<LoadedPattern, KnitError> {
    let source_version = schema_version(text)?;
    let document = document_of(serde_json::from_str(text)?)?;
    let document = migrate(source_version, document)?;
    Ok(LoadedPattern {
        pattern: serde_json::from_value(document)?,
        source_version,
    })
}

/// The schema version of a `.plyknit` file by the detection rule above, read from the text alone:
/// nothing else in the file is decoded or built, however large it is. A version newer than this
/// build reads is [`KnitError::NewerVersion`] (with the version found). Errors exactly as [`read`]
/// does for the envelope itself.
pub fn schema_version(text: &str) -> Result<u32, KnitError> {
    let version = envelope_version(text, &KNIT_ENVELOPE).map_err(|e| match e {
        EnvelopeError::Json(e) => KnitError::Json(e),
        EnvelopeError::NotAnObject => {
            KnitError::Malformed("a .plyknit file must be a JSON object".into())
        }
        EnvelopeError::WrongFormat { found } => KnitError::WrongFormat { found },
        EnvelopeError::BadVersion => {
            KnitError::Malformed("schema_version must be a positive integer".into())
        }
    })?;
    if version > u64::from(KNIT_SCHEMA_VERSION) {
        return Err(KnitError::NewerVersion {
            found: version,
            supported: KNIT_SCHEMA_VERSION,
        });
    }
    // At most KNIT_SCHEMA_VERSION here, so it fits a u32.
    Ok(version as u32)
}

/// Whether `text` has at most [`MAX_VALUES`] JSON values, counted in one pass without decoding it
/// or allocating anything. The backup restore asks before it reads a pattern; nothing else does.
pub fn within_value_limit(text: &str) -> bool {
    count_values(text) <= MAX_VALUES
}

/// The pattern in a parsed file whose envelope [`schema_version`] accepted: an envelope's `document`,
/// or the whole object of a legacy file (one without a `format` key).
fn document_of(value: Value) -> Result<Value, KnitError> {
    let Value::Object(mut obj) = value else {
        return Err(KnitError::Malformed(
            "a .plyknit file must be a JSON object".into(),
        ));
    };
    if !obj.contains_key(FORMAT_KEY) {
        return Ok(Value::Object(obj)); // legacy: the bare pattern object
    }
    obj.remove("document")
        .ok_or_else(|| KnitError::Malformed("the envelope has no document".into()))
}

/// One migration: a document at version `n` in, the same document at version `n + 1` out.
type Migration = fn(Value) -> Result<Value, KnitError>;

/// The ordered migration chain: `MIGRATIONS[i]` upgrades a document from version `i + 1` to `i + 2`.
/// The length is tied to [`KNIT_SCHEMA_VERSION`], so bumping the version without appending its
/// migration does not compile.
const MIGRATIONS: [Migration; KNIT_SCHEMA_VERSION as usize - 1] =
    [v1_to_v2, v2_to_v3, v3_to_v4, v4_to_v5, v5_to_v6];

/// Run every migration from `from` up to the current version, in order.
fn migrate(from: u32, mut document: Value) -> Result<Value, KnitError> {
    // `schema_version` guarantees 1 <= from <= KNIT_SCHEMA_VERSION.
    for step in &MIGRATIONS[(from as usize).saturating_sub(1)..] {
        document = step(document)?;
    }
    Ok(document)
}

/// Built-in counts that released versions wrote at the head of a legacy (version 1) legend:
/// 12 (v0.1.0 to v0.1.5), 20 (v0.1.6), 21 (v0.1.7). Each is a prefix of the next.
const LEGACY_BUILTIN_COUNTS: [usize; 3] = [12, 20, 21];

/// The built-in stitch vocabulary exactly as schema version 2 defines it, in wire form. FROZEN: this
/// is what a version-2 legend's built-in entries mean. Versions 3 to 6 changed the document shape
/// only, so they use this vocabulary unchanged. A later vocabulary gets its own frozen copy and its own
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

/// Version 3 to 4: the document gains `sections`, set to `[]` (a chart-only pattern).
///
/// A version-3 pattern was a chart and nothing else, so the migration gives it no sections and it
/// behaves exactly as before. A `sections` key already in a version-3 document was written by no
/// release and meant nothing there, so it is replaced by `[]` rather than read as sections now.
/// Everything else in the document is untouched.
fn v3_to_v4(mut doc: Value) -> Result<Value, KnitError> {
    if let Some(obj) = doc.as_object_mut() {
        obj.insert("sections".into(), Value::Array(Vec::new()));
    }
    // Not an object: left as is, so the typed decode reports what is wrong.
    Ok(doc)
}

/// The fields every writer gave a section, a short row and a close step, which the typed decode
/// requires (the fields a migration adds aside).
const SECTION_FIELDS: [&str; 4] = ["id", "name", "notes", "steps"];
const SHORT_ROW_FIELDS: [&str; 4] = ["stitch", "to", "method", "resolve_turns"];
const CLOSE_FIELDS: [&str; 1] = ["method"];

/// Refuse (`Malformed`) an object a migration is about to add a field to when it lacks one of the
/// `fields` every writer gave it. The typed decode would refuse it anyway; refusing it first keeps a
/// hostile file of empty objects (`[{}, {}, ...]`) from being grown into a map each: an empty object
/// costs a few bytes in its list, and one with a field its own map node of hundreds.
fn require_fields(
    obj: &serde_json::Map<String, Value>,
    what: &str,
    fields: &[&str],
) -> Result<(), KnitError> {
    match fields.iter().find(|f| !obj.contains_key(**f)) {
        Some(missing) => Err(KnitError::Malformed(format!("{what} has no {missing}"))),
        None => Ok(()),
    }
}

/// The section step kinds a version-4 document can have: the vocabulary of schema version 4,
/// FROZEN. Version 5 added kinds; a version-4 file naming one was written by no version-4 writer.
const V4_STEP_KINDS: [&str; 8] = [
    "ChartRows",
    "Work",
    "ShortRow",
    "CastOn",
    "BindOff",
    "Hold",
    "Resume",
    "Opaque",
];

/// The short-row turns a version-4 document can have (frozen, as above).
const V4_TURNS: [&str; 2] = ["Last", "Count"];

/// Version 4 to 5: each section gains `construction`, set to `null` ("not stated"), and each
/// short-row step gains `decrease`, set to `null` (no decrease at the turn).
///
/// A version-4 section never said how it was worked, and a version-4 short row never decreased, so
/// the migration states neither: every version-4 step keeps exactly its meaning. A stray
/// `construction` or `decrease` key meant nothing at version 4 and is replaced by `null`. A step
/// kind or short-row turn that version 4 did not have is refused (`Malformed`) rather than read with
/// its version-5 meaning: no version-4 writer produced one. So is a section or short row without the
/// fields every writer gave it (see [`require_fields`]). Anything else malformed is left for the
/// typed decode to report. Everything else in the document is untouched.
fn v4_to_v5(mut doc: Value) -> Result<Value, KnitError> {
    let Some(sections) = doc.get_mut("sections").and_then(Value::as_array_mut) else {
        return Ok(doc);
    };
    for section in sections {
        let Some(obj) = section.as_object_mut() else {
            continue;
        };
        require_fields(obj, "a section", &SECTION_FIELDS)?;
        obj.insert("construction".into(), Value::Null);
        let Some(steps) = obj.get_mut("steps").and_then(Value::as_array_mut) else {
            continue;
        };
        for step in steps {
            let Some(action) = step.get_mut("action").and_then(Value::as_object_mut) else {
                continue;
            };
            if action.len() != 1 {
                continue;
            }
            let Some((kind, body)) = action.iter_mut().next() else {
                continue;
            };
            if !V4_STEP_KINDS.contains(&kind.as_str()) {
                return Err(KnitError::Malformed(format!(
                    "a version-4 file cannot have a section step of kind {kind}, which is newer \
                     than version 4"
                )));
            }
            if kind != "ShortRow" {
                continue;
            }
            let Some(fields) = body.as_object_mut() else {
                continue;
            };
            require_fields(fields, "a short row", &SHORT_ROW_FIELDS)?;
            let turn = fields
                .get("to")
                .and_then(Value::as_object)
                .and_then(|to| to.keys().next().cloned());
            if let Some(turn) = turn.filter(|t| !V4_TURNS.contains(&t.as_str())) {
                return Err(KnitError::Malformed(format!(
                    "a version-4 file cannot have a short row that turns at {turn}, which is newer \
                     than version 4"
                )));
            }
            fields.insert("decrease".into(), Value::Null);
        }
    }
    Ok(doc)
}

/// The section step kinds a version-5 document can have: the vocabulary of schema version 5,
/// FROZEN. Version 6 added `Join`; a version-5 file naming it was written by no version-5 writer.
const V5_STEP_KINDS: [&str; 16] = [
    "ChartRows",
    "Work",
    "ShortRow",
    "CastOn",
    "BindOff",
    "Hold",
    "Resume",
    "Opaque",
    "JoinRound",
    "WorkFlat",
    "Rows",
    "Shape",
    "PickUp",
    "Groups",
    "Close",
    "RoundStart",
];

/// Version 5 to 6: the document gains `pieces`, set to `[]` (one piece), each section gains
/// `piece`, set to `null` (it works the first piece, here the only one), and each close step gains
/// `holds`, set to `[]` (it closes the stitches on the needle).
///
/// A version-5 pattern was one piece, every section working it, which is exactly what no pieces and
/// every section's piece not stated mean, and a version-5 close always closed the stitches on the
/// needle: every version-5 step keeps its meaning. A stray `pieces`, `piece` or `holds` key meant
/// nothing at version 5 and is replaced. A step kind that version 5 did not have (`Join`) is refused
/// (`Malformed`) rather than read with its version-6 meaning: no version-5 writer produced one. So
/// is a section or close step without the fields every writer gave it (see [`require_fields`]).
/// Anything else malformed is left for the typed decode to report. Everything else in the document
/// is untouched.
fn v5_to_v6(mut doc: Value) -> Result<Value, KnitError> {
    let Some(obj) = doc.as_object_mut() else {
        return Ok(doc);
    };
    obj.insert("pieces".into(), Value::Array(Vec::new()));
    let Some(sections) = obj.get_mut("sections").and_then(Value::as_array_mut) else {
        return Ok(doc);
    };
    for section in sections {
        let Some(obj) = section.as_object_mut() else {
            continue;
        };
        require_fields(obj, "a section", &SECTION_FIELDS)?;
        obj.insert("piece".into(), Value::Null);
        let Some(steps) = obj.get_mut("steps").and_then(Value::as_array_mut) else {
            continue;
        };
        for step in steps {
            let Some(action) = step.get_mut("action").and_then(Value::as_object_mut) else {
                continue;
            };
            if action.len() != 1 {
                continue;
            }
            let Some((kind, body)) = action.iter_mut().next() else {
                continue;
            };
            if !V5_STEP_KINDS.contains(&kind.as_str()) {
                return Err(KnitError::Malformed(format!(
                    "a version-5 file cannot have a section step of kind {kind}, which is newer \
                     than version 5"
                )));
            }
            // A version-5 close always closed the stitches on the needle.
            if kind == "Close" {
                if let Some(fields) = body.as_object_mut() {
                    require_fields(fields, "a close step", &CLOSE_FIELDS)?;
                    fields.insert("holds".into(), Value::Array(Vec::new()));
                }
            }
        }
    }
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
            sections: Vec::new(),
            pieces: Vec::new(),
        }
    }

    /// The bare (legacy, version 1) JSON a release wrote for `p`: no envelope, and no `cast_on` or
    /// `sections` (no release had them).
    fn legacy_json(p: &KnitPattern) -> String {
        let mut v = serde_json::to_value(p).unwrap();
        v.as_object_mut().unwrap().remove("cast_on");
        v.as_object_mut().unwrap().remove("sections");
        serde_json::to_string_pretty(&v).unwrap()
    }

    /// A version-2 envelope holding `p` as the version-2 writer stored it (no `cast_on` or
    /// `sections` key).
    fn v2_json(p: &KnitPattern) -> String {
        let mut doc = serde_json::to_value(p).unwrap();
        doc.as_object_mut().unwrap().remove("cast_on");
        doc.as_object_mut().unwrap().remove("sections");
        serde_json::to_string_pretty(&json!({
            "format": "ply.knit",
            "schema_version": 2,
            "document": doc,
        }))
        .unwrap()
    }

    /// A version-3 envelope holding `p` as the version-3 writer stored it (no `sections` key).
    fn v3_json(p: &KnitPattern) -> String {
        let mut doc = serde_json::to_value(p).unwrap();
        doc.as_object_mut().unwrap().remove("sections");
        serde_json::to_string_pretty(&json!({
            "format": "ply.knit",
            "schema_version": 3,
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

    /// The real version-3 bytes the engine wrote before version 4 (see each `.fixture.toml`).
    const SCHEMA_V3: [&str; 3] = [
        "rib-cast-on-flat",
        "seed-stitch-round",
        "cable-repeat-round",
    ];

    /// The built-in vocabulary is part of the schema. If this fails, the built-ins changed: bump
    /// KNIT_SCHEMA_VERSION, freeze the new vocabulary next to `builtins_v2`, and append a migration
    /// that maps exactly what changed (see the format ADR). Do not edit `builtins_v2`. Schema 3 only
    /// added `cast_on`, schema 4 `sections`, schema 5 section kinds and schema 6 pieces, so the
    /// vocabulary is still the version-2 one.
    #[test]
    fn current_builtins_are_the_frozen_schema_vocabulary() {
        assert_eq!(
            KNIT_SCHEMA_VERSION, 6,
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
        assert_eq!(v["schema_version"], 6);
        assert_eq!(v["document"]["name"], "1x1 rib");
        assert_eq!(
            v["document"]["cast_on"],
            Value::Null,
            "not set is written as null"
        );
        assert_eq!(
            v["document"]["sections"],
            json!([]),
            "a chart-only pattern is written with no sections"
        );
        assert_eq!(
            v["document"]["pieces"],
            json!([]),
            "a pattern of one piece is written with no pieces"
        );
        assert_eq!(schema_version(&json).unwrap(), 6);
    }

    #[test]
    fn the_envelope_round_trips() {
        let p = ribbing();
        let loaded = read(&write(&p).unwrap()).unwrap();
        assert_eq!(loaded.pattern, p);
        assert_eq!(loaded.source_version, KNIT_SCHEMA_VERSION);
    }

    /// A current file keeps its cast-on through save and load, byte for byte on a re-save.
    #[test]
    fn a_cast_on_round_trips() {
        let mut p = ribbing();
        p.cast_on = Some(26);
        let text = write(&p).unwrap();
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["document"]["cast_on"], 26);
        let loaded = read(&text).unwrap();
        assert_eq!(loaded.source_version, KNIT_SCHEMA_VERSION);
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
            assert_eq!(
                migrated.as_object_mut().unwrap().remove("sections"),
                Some(json!([])),
                "{name}: migrated on through version 4 with no sections"
            );
            assert_eq!(
                migrated.as_object_mut().unwrap().remove("pieces"),
                Some(json!([])),
                "{name}: migrated on through version 6 as one piece"
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
        use crate::{stitch_flow, to_written, validate};
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
                    let s = i.severity.as_str();
                    (s, i.message)
                })
                .collect();
            let want: Vec<(&str, String)> =
                issues.iter().map(|&(s, m)| (s, m.to_string())).collect();
            assert_eq!(got, want, "{name}: validation");
        }
    }

    /// The real version-3 bytes migrate to the current version with no sections and every other
    /// document field exactly as stored (the cast-on included); a re-save is a current envelope that
    /// loads unchanged.
    #[test]
    fn every_schema_v3_fixture_migrates_to_v4_unchanged_but_for_the_sections() {
        for name in SCHEMA_V3 {
            let text = fixture(&format!("schema-v3/{name}.plyknit"));
            assert_eq!(schema_version(&text).unwrap(), 3, "{name}");
            let stored: Value = serde_json::from_str(&text).unwrap();
            let stored_doc = stored["document"].clone();
            assert!(
                stored_doc.get("sections").is_none(),
                "{name}: v3 had no sections"
            );
            assert!(
                stored_doc.get("cast_on").is_some(),
                "{name}: v3 had a cast_on"
            );

            let loaded = read(&text).unwrap();
            assert_eq!(loaded.source_version, 3, "{name}");
            assert!(
                loaded.pattern.sections.is_empty(),
                "{name}: a migration never invents sections"
            );
            let mut migrated = serde_json::to_value(&loaded.pattern).unwrap();
            assert_eq!(
                migrated.as_object_mut().unwrap().remove("sections"),
                Some(json!([]))
            );
            assert_eq!(
                migrated.as_object_mut().unwrap().remove("pieces"),
                Some(json!([]))
            );
            assert_eq!(migrated, stored_doc, "{name}: nothing else changes");

            let saved = write(&loaded.pattern).unwrap();
            assert_eq!(schema_version(&saved).unwrap(), KNIT_SCHEMA_VERSION);
            let again = read(&saved).unwrap();
            assert_eq!(again.source_version, KNIT_SCHEMA_VERSION);
            assert_eq!(again.pattern, loaded.pattern, "{name}");
            assert_eq!(write(&again.pattern).unwrap(), saved, "{name}: byte-stable");
        }
    }

    /// The migrated version-3 fixtures count, write and validate exactly as they did at version 3
    /// (the oracle results recorded in `fixtures/knitting/repeats/` when these bytes were written).
    #[test]
    fn schema_v3_fixtures_count_write_and_validate_as_before() {
        use crate::{stitch_flow, to_written, validate};
        let expect = |name: &str| -> Value {
            let path = format!(
                "{}/../../fixtures/knitting/repeats/{name}.expect.json",
                env!("CARGO_MANIFEST_DIR")
            );
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
        };
        for name in SCHEMA_V3 {
            let p = read(&fixture(&format!("schema-v3/{name}.plyknit")))
                .unwrap()
                .pattern;
            let want = expect(name);
            let mut lines = to_written(&p);
            if let Some(line) = want.get("cast_on_line").and_then(Value::as_str) {
                assert_eq!(lines.remove(0), line, "{name}");
            }
            let rows = want["rows"].as_array().unwrap();
            let written: Vec<&str> = rows
                .iter()
                .map(|r| r["written"].as_str().unwrap())
                .collect();
            assert_eq!(lines, written, "{name}: written rows as before");
            let produced: Vec<Option<u64>> = rows.iter().map(|r| r["produces"].as_u64()).collect();
            let counts: Vec<Option<u64>> = stitch_flow(&p)
                .iter()
                .map(|f| f.count.map(|c| c.produced))
                .collect();
            assert_eq!(counts, produced, "{name}: counts");
            let got: Vec<(String, String)> = validate(&p)
                .into_iter()
                .map(|i| {
                    let s = i.severity.as_str();
                    (s.to_string(), i.message)
                })
                .collect();
            let issues: Vec<(String, String)> = want["issues"]
                .as_array()
                .unwrap()
                .iter()
                .map(|i| {
                    (
                        i["severity"].as_str().unwrap().to_string(),
                        i["message"].as_str().unwrap().to_string(),
                    )
                })
                .collect();
            assert_eq!(got, issues, "{name}: validation");
        }
    }

    /// The real version-4 bytes the engine wrote before version 5 (see each `.fixture.toml`).
    const SCHEMA_V4: [&str; 4] = [
        "shoulder-short-rows-flat",
        "neckline-hold-flat",
        "ledger-problems-flat",
        "eyelet-lace-round",
    ];

    /// The real version-4 bytes migrate to the current version with only the new fields added (each
    /// section's `construction` and each short row's `decrease`, both null) and every other document
    /// field exactly as stored; a re-save is a current envelope that loads unchanged.
    #[test]
    fn every_schema_v4_fixture_migrates_to_v5_unchanged_but_for_the_new_fields() {
        for name in SCHEMA_V4 {
            let text = fixture(&format!("schema-v4/{name}.plyknit"));
            assert_eq!(schema_version(&text).unwrap(), 4, "{name}");
            let stored: Value = serde_json::from_str(&text).unwrap();
            let stored_doc = stored["document"].clone();
            let loaded = read(&text).unwrap();
            assert_eq!(loaded.source_version, 4, "{name}");
            let mut migrated = serde_json::to_value(&loaded.pattern).unwrap();
            assert_eq!(
                migrated.as_object_mut().unwrap().remove("pieces"),
                Some(json!([])),
                "{name}: migrated on through version 6 as one piece"
            );
            let mut short_rows = 0;
            for section in migrated["sections"].as_array_mut().unwrap() {
                assert_eq!(
                    section.as_object_mut().unwrap().remove("construction"),
                    Some(Value::Null),
                    "{name}: a migration never states how a section is worked"
                );
                assert_eq!(
                    section.as_object_mut().unwrap().remove("piece"),
                    Some(Value::Null),
                    "{name}: every section works the one piece"
                );
                for step in section["steps"].as_array_mut().unwrap() {
                    if let Some(sr) = step["action"].get_mut("ShortRow") {
                        assert_eq!(
                            sr.as_object_mut().unwrap().remove("decrease"),
                            Some(Value::Null),
                            "{name}: a migration never adds a decrease"
                        );
                        short_rows += 1;
                    }
                }
            }
            let stored_short_rows = text.matches("\"ShortRow\"").count();
            assert_eq!(short_rows, stored_short_rows, "{name}");
            assert_eq!(migrated, stored_doc, "{name}: nothing else changes");

            let saved = write(&loaded.pattern).unwrap();
            assert_eq!(schema_version(&saved).unwrap(), KNIT_SCHEMA_VERSION);
            let again = read(&saved).unwrap();
            assert_eq!(again.source_version, KNIT_SCHEMA_VERSION);
            assert_eq!(again.pattern, loaded.pattern, "{name}");
            assert_eq!(write(&again.pattern).unwrap(), saved, "{name}: byte-stable");
        }
    }

    /// The migrated version-4 fixtures write, count and validate exactly as they did at version 4:
    /// the oracles in `fixtures/knitting/` were derived for version 4 and did not change.
    #[test]
    fn schema_v4_fixtures_count_write_and_validate_as_before() {
        use crate::sections::{ledger, LedgerLine};
        use crate::{stitch_flow, to_written, validate};
        let oracle = |name: &str| -> Value {
            let topic = if name.ends_with("-round") {
                "repeats"
            } else {
                "sections"
            };
            let path = format!(
                "{}/../../fixtures/knitting/{topic}/{name}.expect.json",
                env!("CARGO_MANIFEST_DIR")
            );
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
        };
        for name in SCHEMA_V4 {
            let p = read(&fixture(&format!("schema-v4/{name}.plyknit")))
                .unwrap()
                .pattern;
            let want = oracle(name);
            if let Some(written) = want.get("written").and_then(Value::as_array) {
                let written: Vec<&str> = written.iter().map(|l| l.as_str().unwrap()).collect();
                assert_eq!(to_written(&p), written, "{name}: written");
                let lines: Vec<String> = ledger(&p).lines.iter().map(LedgerLine::written).collect();
                let want_lines: Vec<&str> = want["steps"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|l| l["line"].as_str().unwrap())
                    .collect();
                assert_eq!(lines, want_lines, "{name}: ledger lines");
            } else {
                let mut lines = to_written(&p);
                if let Some(line) = want.get("cast_on_line").and_then(Value::as_str) {
                    assert_eq!(lines.remove(0), line, "{name}");
                }
                let rows = want["rows"].as_array().unwrap();
                let written: Vec<&str> = rows
                    .iter()
                    .map(|r| r["written"].as_str().unwrap())
                    .collect();
                assert_eq!(lines, written, "{name}: written rows as before");
                let produced: Vec<Option<u64>> =
                    rows.iter().map(|r| r["produces"].as_u64()).collect();
                let counts: Vec<Option<u64>> = stitch_flow(&p)
                    .iter()
                    .map(|f| f.count.map(|c| c.produced))
                    .collect();
                assert_eq!(counts, produced, "{name}: counts");
            }
            let got: Vec<(String, String)> = validate(&p)
                .into_iter()
                .map(|i| {
                    let s = i.severity.as_str();
                    (s.to_string(), i.message)
                })
                .collect();
            let issues: Vec<(String, String)> = want["issues"]
                .as_array()
                .unwrap()
                .iter()
                .map(|i| {
                    (
                        i["severity"].as_str().unwrap().to_string(),
                        i["message"].as_str().unwrap().to_string(),
                    )
                })
                .collect();
            assert_eq!(got, issues, "{name}: validation");
        }
    }

    /// Every version-5 step kind and field survives save and load exactly, and the re-save is
    /// byte-stable.
    #[test]
    fn version_5_steps_round_trip() {
        use crate::sections::*;
        let mut p = ribbing();
        p.construction = Construction::InTheRound;
        p.cast_on = Some(64);
        let step = |id: &str, action: StepAction| Step {
            id: id.into(),
            action,
        };
        p.sections = vec![Section {
            id: "section-1".into(),
            name: "Heel".into(),
            notes: String::new(),
            construction: Some(Construction::Flat),
            piece: None,
            steps: vec![
                step(
                    "step-1",
                    StepAction::Groups {
                        groups: vec![
                            NeedleGroup {
                                name: "sole".into(),
                                count: 32,
                                notes: "needles 1 and 2".into(),
                            },
                            NeedleGroup {
                                name: "instep".into(),
                                count: 32,
                                notes: String::new(),
                            },
                        ],
                    },
                ),
                step(
                    "step-2",
                    StepAction::WorkFlat {
                        count: 32,
                        name: "heel flap".into(),
                        slip_edges: true,
                    },
                ),
                step(
                    "step-3",
                    StepAction::Rows {
                        count: 32,
                        text: "sl 1, k1".into(),
                    },
                ),
                step(
                    "step-4",
                    StepAction::ShortRow {
                        stitch: WorkStitch::Knit,
                        to: TurnAt::BeforeGap(1),
                        method: TurnMethod::Unspecified,
                        resolve_turns: false,
                        decrease: Some(TurnDecrease {
                            kind: Decrease::Ssk,
                            after: 1,
                        }),
                    },
                ),
                step(
                    "step-5",
                    StepAction::ShortRow {
                        stitch: WorkStitch::Purl,
                        to: TurnAt::PastGap(2),
                        method: TurnMethod::German,
                        resolve_turns: true,
                        decrease: None,
                    },
                ),
                step(
                    "step-6",
                    StepAction::PickUp {
                        count: 16,
                        along: PickUpAlong::Piece("step-2".into()),
                        group: Some("sole".into()),
                    },
                ),
                step(
                    "step-7",
                    StepAction::PickUp {
                        count: 3,
                        along: PickUpAlong::Edge("the cast-on edge".into()),
                        group: None,
                    },
                ),
                step("step-8", StepAction::JoinRound {}),
                step(
                    "step-9",
                    StepAction::Shape {
                        change: -2,
                        every: 2,
                        until: ShapeUntil::Remain(64),
                        groups: vec!["sole".into()],
                        text: "k1, ssk".into(),
                    },
                ),
                step(
                    "step-10",
                    StepAction::Shape {
                        change: 1,
                        every: 1,
                        until: ShapeUntil::Times(3),
                        groups: Vec::new(),
                        text: String::new(),
                    },
                ),
                step(
                    "step-11",
                    StepAction::Close {
                        method: CloseMethod::Graft,
                        holds: Vec::new(),
                    },
                ),
                step(
                    "step-12",
                    StepAction::Close {
                        method: CloseMethod::ThreeNeedleBindOff,
                        holds: Vec::new(),
                    },
                ),
            ],
        }];
        let text = write(&p).unwrap();
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["document"]["sections"][0]["construction"], "Flat");
        assert_eq!(
            v["document"]["sections"][0]["steps"][7]["action"],
            json!({"JoinRound": {}})
        );
        assert_eq!(
            v["document"]["sections"][0]["steps"][3]["action"]["ShortRow"]["to"],
            json!({"BeforeGap": 1})
        );
        let loaded = read(&text).unwrap();
        assert_eq!(loaded.pattern, p);
        assert_eq!(write(&loaded.pattern).unwrap(), text);
    }

    /// A version-3 document never meant anything by a `sections` key (no writer produced one), so
    /// the migration replaces it with no sections instead of reading it as a construction now.
    #[test]
    fn v3_to_v4_never_carries_sections_forward() {
        let p = ribbing();
        let mut v: Value = serde_json::from_str(&v3_json(&p)).unwrap();
        v["document"]["sections"] = json!([{"id": "x", "name": "stray", "notes": "", "steps": []}]);
        let loaded = read(&v.to_string()).unwrap();
        assert_eq!(loaded.source_version, 3);
        assert!(loaded.pattern.sections.is_empty());
        assert_eq!(loaded.pattern, p);
        assert_eq!(v3_to_v4(json!("x")).unwrap(), json!("x"));
    }

    /// Sections survive save and load exactly, every step kind included, and the re-save is
    /// byte-stable.
    #[test]
    fn sections_round_trip() {
        use crate::pattern::Side;
        use crate::sections::*;
        let mut p = ribbing();
        p.cast_on = Some(24);
        let step = |id: &str, action: StepAction| Step {
            id: id.into(),
            action,
        };
        p.sections = vec![Section {
            id: "section-1".into(),
            name: "Shoulder".into(),
            notes: "Use the smaller needle.".into(),
            construction: None,
            piece: None,
            steps: vec![
                step("step-1", StepAction::ChartRows { first: 1, last: 1 }),
                step(
                    "step-2",
                    StepAction::ShortRow {
                        stitch: WorkStitch::Knit,
                        to: TurnAt::Last(6),
                        method: TurnMethod::WrapAndTurn,
                        resolve_turns: false,
                        decrease: None,
                    },
                ),
                step(
                    "step-3",
                    StepAction::Work {
                        stitch: WorkStitch::InPattern,
                        to: WorkTo::Count(3),
                        resolve_turns: true,
                    },
                ),
                step("step-4", StepAction::CastOn { count: 2 }),
                step(
                    "step-5",
                    StepAction::BindOff {
                        count: None,
                        resolve_turns: true,
                    },
                ),
                step(
                    "step-6",
                    StepAction::Hold {
                        count: Some(4),
                        name: "neck".into(),
                    },
                ),
                step(
                    "step-7",
                    StepAction::Resume {
                        hold: "step-6".into(),
                        facing: Some(Side::Ws),
                    },
                ),
                step(
                    "step-8",
                    StepAction::Opaque {
                        text: "Try it on.".into(),
                        stitch_change: Some(-2),
                    },
                ),
                step(
                    "step-9",
                    StepAction::ShortRow {
                        stitch: WorkStitch::Purl,
                        to: TurnAt::Count(5),
                        method: TurnMethod::German,
                        resolve_turns: false,
                        decrease: None,
                    },
                ),
            ],
        }];
        let text = write(&p).unwrap();
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(
            v["document"]["sections"][0]["steps"][1]["action"]["ShortRow"]["to"],
            json!({"Last": 6})
        );
        assert_eq!(
            v["document"]["sections"][0]["steps"][4]["action"]["BindOff"]["count"],
            Value::Null
        );
        let loaded = read(&text).unwrap();
        assert_eq!(loaded.pattern, p);
        assert_eq!(write(&loaded.pattern).unwrap(), text);
    }

    /// A step kind this build does not know is never dropped. Within version 5 no writer
    /// produces one, so the file is unreadable (a typed error, nothing loaded); a later version that
    /// adds kinds bumps the schema version and is refused as newer before its document is read.
    #[test]
    fn an_unknown_step_kind_is_refused_not_dropped() {
        let p = ribbing();
        let mut v: Value = serde_json::from_str(&write(&p).unwrap()).unwrap();
        v["document"]["sections"] = json!([{
            "id": "section-1", "name": "Heel", "notes": "", "construction": null, "piece": null,
            "steps": [{"id": "step-1", "action": {"Split": {"count": 12}}}]
        }]);
        assert!(matches!(read(&v.to_string()), Err(KnitError::Json(_))));
        v["schema_version"] = json!(7);
        assert!(matches!(
            read(&v.to_string()),
            Err(KnitError::NewerVersion {
                found: 7,
                supported: 6
            })
        ));
        // The control: the same file with a step kind this build knows loads.
        v["schema_version"] = json!(6);
        v["document"]["sections"][0]["steps"][0]["action"] = json!({"CastOn": {"count": 3}});
        assert!(read(&v.to_string()).is_ok());
    }

    /// A version-4 file never had the version-5 step kinds or gap turns (no version-4 writer made
    /// one), so one that names them is refused instead of being read with today's meaning; the same
    /// steps in a version-5 file load.
    #[test]
    fn a_version_4_file_with_a_newer_step_kind_is_refused() {
        let p = ribbing();
        let mut v: Value = serde_json::from_str(&write(&p).unwrap()).unwrap();
        v["schema_version"] = json!(4);
        for (action, kind) in [
            (
                json!({"PickUp": {"count": 12, "along": {"Edge": "x"}, "group": null}}),
                "PickUp",
            ),
            (json!({"JoinRound": {}}), "JoinRound"),
            (
                json!({"ShortRow": {"stitch": "Knit", "to": {"BeforeGap": 1}, "method": "Unspecified", "resolve_turns": false}}),
                "BeforeGap",
            ),
        ] {
            v["document"]["sections"] = json!([{
                "id": "section-1", "name": "Heel", "notes": "",
                "steps": [{"id": "step-1", "action": action}]
            }]);
            let err = read(&v.to_string()).unwrap_err();
            assert!(
                matches!(&err, KnitError::Malformed(m) if m.contains(kind)),
                "{kind}: {err}"
            );
        }
    }

    /// The version-4 to 5 step gives every section "not stated" and every short row "no decrease",
    /// replacing stray keys a version-4 document might carry, and touches nothing else.
    #[test]
    fn v4_to_v5_states_nothing_new() {
        let doc = json!({
            "sections": [{
                "id": "s", "name": "", "notes": "", "construction": "InTheRound",
                "steps": [
                    {"id": "a", "action": {"ShortRow": {"stitch": "Knit", "to": {"Last": 2}, "method": "German", "resolve_turns": true, "decrease": {"kind": "Ssk", "after": 1}}}},
                    {"id": "b", "action": {"CastOn": {"count": 3}}}
                ]
            }]
        });
        let out = v4_to_v5(doc).unwrap();
        assert_eq!(out["sections"][0]["construction"], Value::Null);
        assert_eq!(
            out["sections"][0]["steps"][0]["action"]["ShortRow"]["decrease"],
            Value::Null
        );
        assert_eq!(
            out["sections"][0]["steps"][1]["action"],
            json!({"CastOn": {"count": 3}})
        );
        assert_eq!(v4_to_v5(json!("x")).unwrap(), json!("x"));
        assert_eq!(
            v4_to_v5(json!({"sections": 3})).unwrap(),
            json!({"sections": 3})
        );
    }

    /// The real version-5 bytes the engine wrote before version 6 (see each `.fixture.toml`).
    const SCHEMA_V5: [&str; 3] = [
        "sock-heel-flap-round",
        "sock-short-row-heel-round",
        "round-problems",
    ];

    /// The real version-5 bytes migrate to the current version as one piece (no pieces, every
    /// section's piece null) and every other document field exactly as stored; a re-save is a
    /// current envelope that loads unchanged.
    #[test]
    fn every_schema_v5_fixture_migrates_to_v6_as_one_piece() {
        for name in SCHEMA_V5 {
            let text = fixture(&format!("schema-v5/{name}.plyknit"));
            assert_eq!(schema_version(&text).unwrap(), 5, "{name}");
            let stored: Value = serde_json::from_str(&text).unwrap();
            let stored_doc = stored["document"].clone();
            assert!(
                stored_doc.get("pieces").is_none(),
                "{name}: v5 had no pieces"
            );
            let loaded = read(&text).unwrap();
            assert_eq!(loaded.source_version, 5, "{name}");
            assert!(loaded.pattern.pieces.is_empty(), "{name}: one piece");
            let mut migrated = serde_json::to_value(&loaded.pattern).unwrap();
            assert_eq!(
                migrated.as_object_mut().unwrap().remove("pieces"),
                Some(json!([]))
            );
            for section in migrated["sections"].as_array_mut().unwrap() {
                assert_eq!(
                    section.as_object_mut().unwrap().remove("piece"),
                    Some(Value::Null),
                    "{name}: every section works the one piece"
                );
                for step in section["steps"].as_array_mut().unwrap() {
                    if let Some(close) = step["action"].get_mut("Close") {
                        assert_eq!(
                            close.as_object_mut().unwrap().remove("holds"),
                            Some(json!([])),
                            "{name}: a version-5 close closes the stitches on the needle"
                        );
                    }
                }
            }
            assert_eq!(migrated, stored_doc, "{name}: nothing else changes");

            let saved = write(&loaded.pattern).unwrap();
            assert_eq!(schema_version(&saved).unwrap(), KNIT_SCHEMA_VERSION);
            let again = read(&saved).unwrap();
            assert_eq!(again.source_version, KNIT_SCHEMA_VERSION);
            assert_eq!(again.pattern, loaded.pattern, "{name}");
            assert_eq!(write(&again.pattern).unwrap(), saved, "{name}: byte-stable");
        }
    }

    /// The migrated version-5 fixtures write, count and validate exactly as they did at version 5:
    /// the oracles in `fixtures/knitting/sections/` were derived for version 5 and did not change.
    #[test]
    fn schema_v5_fixtures_count_write_and_validate_as_before() {
        use crate::sections::{ledger, LedgerLine};
        use crate::{to_written, validate};
        for name in SCHEMA_V5 {
            let p = read(&fixture(&format!("schema-v5/{name}.plyknit")))
                .unwrap()
                .pattern;
            let path = format!(
                "{}/../../fixtures/knitting/sections/{name}.expect.json",
                env!("CARGO_MANIFEST_DIR")
            );
            let want: Value =
                serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
            let written: Vec<&str> = want["written"]
                .as_array()
                .unwrap()
                .iter()
                .map(|l| l.as_str().unwrap())
                .collect();
            assert_eq!(to_written(&p), written, "{name}: written");
            let l = ledger(&p);
            assert!(l.pieces.is_empty(), "{name}: one piece, no summaries");
            assert!(l.lines.iter().all(|line| line.piece.is_none()), "{name}");
            let lines: Vec<String> = l.lines.iter().map(LedgerLine::written).collect();
            let want_lines: Vec<&str> = want["steps"]
                .as_array()
                .unwrap()
                .iter()
                .map(|l| l["line"].as_str().unwrap())
                .collect();
            assert_eq!(lines, want_lines, "{name}: ledger lines");
            let got: Vec<(String, String)> = validate(&p)
                .into_iter()
                .map(|i| {
                    let s = i.severity.as_str();
                    (s.to_string(), i.message)
                })
                .collect();
            let issues: Vec<(String, String)> = want["issues"]
                .as_array()
                .unwrap()
                .iter()
                .map(|i| {
                    (
                        i["severity"].as_str().unwrap().to_string(),
                        i["message"].as_str().unwrap().to_string(),
                    )
                })
                .collect();
            assert_eq!(got, issues, "{name}: validation");
        }
    }

    /// The version-5 to 6 step gives the document no pieces and every section "the first piece",
    /// replacing stray keys a version-5 document might carry, and touches nothing else.
    #[test]
    fn v5_to_v6_makes_one_piece() {
        let doc = json!({
            "pieces": [{"id": "x", "name": "stray"}],
            "sections": [{
                "id": "s", "name": "", "notes": "", "construction": null, "piece": "x",
                "steps": [{"id": "b", "action": {"CastOn": {"count": 3}}}]
            }]
        });
        let out = v5_to_v6(doc).unwrap();
        assert_eq!(out["pieces"], json!([]));
        assert_eq!(out["sections"][0]["piece"], Value::Null);
        assert_eq!(
            out["sections"][0]["steps"][0]["action"],
            json!({"CastOn": {"count": 3}})
        );
        assert_eq!(v5_to_v6(json!("x")).unwrap(), json!("x"));
        assert_eq!(
            v5_to_v6(json!({"sections": 3})).unwrap(),
            json!({"sections": 3, "pieces": []})
        );
    }

    /// A version-5 file never had the join step (no version-5 writer made one), so one that names it
    /// is refused instead of being read with today's meaning; the same step in a version-6 file
    /// loads.
    #[test]
    fn a_version_5_file_with_a_join_is_refused() {
        let p = ribbing();
        let mut v: Value = serde_json::from_str(&write(&p).unwrap()).unwrap();
        let join =
            json!({"Join": {"source": {"Held": "a"}, "stitch": "Knit", "resolve_turns": false}});
        v["document"]["sections"] = json!([{
            "id": "section-1", "name": "Thumb", "notes": "", "construction": null, "piece": null,
            "steps": [{"id": "step-1", "action": join}]
        }]);
        assert!(read(&v.to_string()).is_ok(), "a version-6 join loads");
        v["schema_version"] = json!(5);
        let err = read(&v.to_string()).unwrap_err();
        assert!(
            matches!(&err, KnitError::Malformed(m) if m.contains("Join")),
            "{err}"
        );
    }

    /// Pieces, a section's piece and every join survive save and load exactly, and the re-save is
    /// byte-stable.
    #[test]
    fn version_6_pieces_round_trip() {
        use crate::sections::*;
        let mut p = ribbing();
        p.construction = Construction::InTheRound;
        p.cast_on = Some(40);
        p.pieces = vec![
            Piece {
                id: "piece-1".into(),
                name: "hand".into(),
            },
            Piece {
                id: "piece-2".into(),
                name: "thumb".into(),
            },
        ];
        let section = |id: &str, piece: Option<&str>, steps: Vec<Step>| Section {
            id: id.into(),
            name: id.into(),
            notes: String::new(),
            construction: None,
            piece: piece.map(str::to_string),
            steps,
        };
        p.sections = vec![
            section(
                "section-1",
                None,
                vec![Step {
                    id: "step-1".into(),
                    action: StepAction::Hold {
                        count: Some(8),
                        name: "thumb".into(),
                    },
                }],
            ),
            section(
                "section-2",
                Some("piece-2"),
                vec![
                    Step {
                        id: "step-2".into(),
                        action: StepAction::Join {
                            source: JoinSource::Held("step-1".into()),
                            stitch: WorkStitch::Knit,
                            resolve_turns: true,
                        },
                    },
                    Step {
                        id: "step-3".into(),
                        action: StepAction::Join {
                            source: JoinSource::Piece("piece-1".into()),
                            stitch: WorkStitch::InPattern,
                            resolve_turns: false,
                        },
                    },
                ],
            ),
        ];
        let text = write(&p).unwrap();
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["document"]["pieces"][1]["name"], "thumb");
        assert_eq!(v["document"]["sections"][0]["piece"], Value::Null);
        assert_eq!(v["document"]["sections"][1]["piece"], "piece-2");
        assert_eq!(
            v["document"]["sections"][1]["steps"][0]["action"],
            json!({"Join": {"source": {"Held": "step-1"}, "stitch": "Knit", "resolve_turns": true}})
        );
        let loaded = read(&text).unwrap();
        assert_eq!(loaded.pattern, p);
        assert_eq!(write(&loaded.pattern).unwrap(), text);
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
            assert!(p.sections.is_empty(), "{release}/{name}: no sections");
            assert!(p.pieces.is_empty(), "{release}/{name}: one piece");
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

    /// Version 2, 3 and 4 legends load exactly as saved: no prefix matching. Here built-in 5 (ssk)
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
        let from_v3 = read(&v3_json(&p)).unwrap();
        assert_eq!(from_v3.source_version, 3);
        assert_eq!(from_v3.pattern, p);

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
            .replace("\"schema_version\": 6", "\"schema_version\": 7");
        let err = read(&text).unwrap_err();
        assert!(
            matches!(
                err,
                KnitError::NewerVersion {
                    found: 7,
                    supported: 6
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

    /// The version comes from the envelope alone, by the rule `read` applies: legacy (no `format`)
    /// is 1, an envelope states its own, a newer one is a typed error carrying what was found, and
    /// anything that is not a `.plyknit` envelope says why.
    #[test]
    fn the_version_is_read_from_the_envelope_by_the_detection_rule() {
        let p = ribbing();
        assert_eq!(schema_version(&legacy_json(&p)).unwrap(), 1);
        assert_eq!(schema_version(&write(&p).unwrap()).unwrap(), 6);
        assert_eq!(
            schema_version(r#"{"format":"ply.knit","schema_version":6,"document":"anything"}"#)
                .unwrap(),
            6
        );
        let newer = r#"{"format":"ply.knit","schema_version":18446744073709551615,"document":{}}"#;
        assert!(matches!(
            schema_version(newer),
            Err(KnitError::NewerVersion {
                found: u64::MAX,
                supported: 6
            })
        ));
        assert!(matches!(
            schema_version(r#"{"format":"ply.nalbind","schemaVersion":3,"name":"x"}"#),
            Err(KnitError::WrongFormat { found }) if found == "\"ply.nalbind\""
        ));
        assert!(matches!(
            schema_version(r#"{"format":null,"schema_version":6,"document":{}}"#),
            Err(KnitError::WrongFormat { found }) if found == "null"
        ));
        assert!(matches!(
            schema_version("not json"),
            Err(KnitError::Json(_))
        ));
        assert!(matches!(
            schema_version(r#"{"format":"ply.knit","schema_version":6,"document":{}} {}"#),
            Err(KnitError::Json(_))
        ));
        for bad in [
            r#"[1, 2, 3]"#,
            r#""ply.knit""#,
            r#"{"format":"ply.knit","document":{}}"#,
            r#"{"format":"ply.knit","schema_version":0,"document":{}}"#,
            r#"{"format":"ply.knit","schema_version":-1,"document":{}}"#,
            r#"{"format":"ply.knit","schema_version":6.5,"document":{}}"#,
            r#"{"format":"ply.knit","schema_version":"6","document":{}}"#,
            r#"{"format":"ply.knit","schema_version":[6],"document":{}}"#,
        ] {
            assert!(
                matches!(schema_version(bad), Err(KnitError::Malformed(_))),
                "{bad} should be malformed"
            );
        }
    }

    /// The probe and the reader agree on every envelope, the odd ones included: keys after the
    /// document, a repeated key (its last value counts in both), a document of the wrong shape.
    #[test]
    fn the_probe_and_the_reader_agree_on_the_envelope() {
        let p = ribbing();
        let doc = serde_json::to_string(&p).unwrap();
        let cases = [
            format!(r#"{{"document":{doc},"schema_version":6,"format":"ply.knit"}}"#),
            format!(
                r#"{{"format":"ply.knit","schema_version":9,"schema_version":6,"document":{doc}}}"#
            ),
            format!(
                r#"{{"format":"ply.knit","schema_version":6,"schema_version":9,"document":{doc}}}"#
            ),
            format!(
                r#"{{"format":"ply.knit","format":"ply.tablet","schema_version":6,"document":{doc}}}"#
            ),
            format!(r#"{{"format":"ply.knit","schema_version":6,"document":{doc},"document":7}}"#),
            r#"{"format":"ply.knit","schema_version":2}"#.to_string(),
        ];
        for text in &cases {
            let probed = schema_version(text);
            match (read(text), probed) {
                (Ok(loaded), Ok(v)) => assert_eq!(loaded.source_version, v, "{text}"),
                // A sound envelope around a document the reader refuses: the probe is not a decode.
                (Err(KnitError::Json(_) | KnitError::Malformed(_)), Ok(_)) => {}
                (Err(a), Err(b)) => assert_eq!(format!("{a:?}"), format!("{b:?}"), "{text}"),
                (r, v) => panic!("{text}: read {r:?}, probe {v:?}"),
            }
        }
        assert_eq!(read(&cases[0]).unwrap().pattern, p);
        assert!(matches!(
            read(&cases[2]),
            Err(KnitError::NewerVersion { found: 9, .. })
        ));
        assert!(matches!(
            read(&cases[3]),
            Err(KnitError::WrongFormat { .. })
        ));
    }
}
