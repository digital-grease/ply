//! The route an OLDER `.plyknit` (schema 1 to 5) took before it was decoded into a lean tree
//! ([`crate::json_tree`]): a `serde_json::Value`, the migrations on it, then the typed decode. Kept
//! for tests only, as it was (word for word but for the visibility the tests need), as the oracle
//! the lean route is held to: the same pattern for every file, or the same error with the same
//! message.

use serde_json::{json, Value};

use crate::error::KnitError;
use crate::native::{schema_version, LoadedPattern, KNIT_SCHEMA_VERSION};
use ply_common::envelope::FORMAT_KEY;

/// `native::read` for an older file, as it was: through a `serde_json::Value`.
pub(crate) fn read(text: &str) -> Result<LoadedPattern, KnitError> {
    let source_version = schema_version(text)?;
    let document = document_of(serde_json::from_str(text)?)?;
    let document = migrate(source_version, document)?;
    Ok(LoadedPattern {
        pattern: serde_json::from_value(document)?,
        source_version,
    })
}

/// The pattern in a parsed file whose envelope [`schema_version`] accepted: an envelope's `document`,
/// or the whole object of a legacy file (one without a `format` key).
pub(crate) fn document_of(value: Value) -> Result<Value, KnitError> {
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
pub(crate) const MIGRATIONS: [Migration; KNIT_SCHEMA_VERSION as usize - 1] =
    [v1_to_v2, v2_to_v3, v3_to_v4, v4_to_v5, v5_to_v6];

/// Run every migration from `from` up to the current version, in order.
pub(crate) fn migrate(from: u32, mut document: Value) -> Result<Value, KnitError> {
    // `schema_version` guarantees 1 <= from <= KNIT_SCHEMA_VERSION.
    for step in &MIGRATIONS[(from as usize).saturating_sub(1)..] {
        document = step(document)?;
    }
    Ok(document)
}

/// Built-in counts that released versions wrote at the head of a legacy (version 1) legend:
/// 12 (v0.1.0 to v0.1.5), 20 (v0.1.6), 21 (v0.1.7). Each is a prefix of the next.
pub(crate) const LEGACY_BUILTIN_COUNTS: [usize; 3] = [12, 20, 21];

/// The built-in stitch vocabulary exactly as schema version 2 defines it, in wire form. FROZEN: this
/// is what a version-2 legend's built-in entries mean. Versions 3 to 6 changed the document shape
/// only, so they use this vocabulary unchanged. A later vocabulary gets its own frozen copy and its own
/// migration; this one never changes.
pub(crate) fn builtins_v2() -> Vec<Value> {
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
pub(crate) fn same_def(saved: &Value, builtin: &Value) -> bool {
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
pub(crate) fn v1_to_v2(mut doc: Value) -> Result<Value, KnitError> {
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
pub(crate) fn v2_to_v3(mut doc: Value) -> Result<Value, KnitError> {
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
pub(crate) fn v3_to_v4(mut doc: Value) -> Result<Value, KnitError> {
    if let Some(obj) = doc.as_object_mut() {
        obj.insert("sections".into(), Value::Array(Vec::new()));
    }
    // Not an object: left as is, so the typed decode reports what is wrong.
    Ok(doc)
}

/// The fields every writer gave a section, a short row and a close step, which the typed decode
/// requires (the fields a migration adds aside).
pub(crate) const SECTION_FIELDS: [&str; 4] = ["id", "name", "notes", "steps"];
pub(crate) const SHORT_ROW_FIELDS: [&str; 4] = ["stitch", "to", "method", "resolve_turns"];
pub(crate) const CLOSE_FIELDS: [&str; 1] = ["method"];

/// Refuse (`Malformed`) an object a migration is about to add a field to when it lacks one of the
/// `fields` every writer gave it. The typed decode would refuse it anyway; refusing it first keeps a
/// hostile file of empty objects (`[{}, {}, ...]`) from being grown into a map each: an empty object
/// costs a few bytes in its list, and one with a field its own map node of hundreds.
pub(crate) fn require_fields(
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
pub(crate) const V4_STEP_KINDS: [&str; 8] = [
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
pub(crate) const V4_TURNS: [&str; 2] = ["Last", "Count"];

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
pub(crate) fn v4_to_v5(mut doc: Value) -> Result<Value, KnitError> {
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
pub(crate) const V5_STEP_KINDS: [&str; 16] = [
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
pub(crate) fn v5_to_v6(mut doc: Value) -> Result<Value, KnitError> {
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

/// The lean route against this one, on every older fixture and on files generated from them.
mod equivalence {
    use super::*;
    use crate::pattern::KnitPattern;
    use proptest::prelude::*;

    /// The two routes give the same pattern, or the same error with the same message.
    fn assert_same(text: &str) {
        let lean = crate::native::read(text);
        let tree = read(text);
        match (&lean, &tree) {
            (Ok(a), Ok(b)) => assert_eq!(a, b, "{text:.300}"),
            (Err(a), Err(b)) => {
                assert_eq!(
                    std::mem::discriminant(a),
                    std::mem::discriminant(b),
                    "{text:.300}: lean {a:?}, tree {b:?}"
                );
                assert_eq!(a.to_string(), b.to_string(), "{text:.300}");
            }
            _ => panic!("{text:.300}: lean {lean:?}, tree {tree:?}"),
        }
    }

    fn fixture_files() -> Vec<std::path::PathBuf> {
        fn walk(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
            for entry in std::fs::read_dir(dir).unwrap_or_else(|e| panic!("{dir:?}: {e}")) {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    walk(&path, out);
                } else if path.extension().is_some_and(|e| e == "plyknit") {
                    out.push(path);
                }
            }
        }
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
        let mut files = Vec::new();
        walk(&root.join("knitting"), &mut files);
        walk(&root.join("migrations/plyknit"), &mut files);
        files.sort();
        files
    }

    /// Every fixture's pattern, as this build reads it, as a JSON value (read once).
    fn seeds() -> &'static [Value] {
        static SEEDS: std::sync::OnceLock<Vec<Value>> = std::sync::OnceLock::new();
        SEEDS.get_or_init(|| {
            fixture_files()
                .iter()
                .map(|path| {
                    let text = std::fs::read_to_string(path).unwrap();
                    let pattern: KnitPattern = crate::native::read(&text).unwrap().pattern;
                    serde_json::to_value(pattern).unwrap()
                })
                .collect()
        })
    }

    fn each_step(doc: &mut Value, mut f: impl FnMut(&str, &mut Value)) {
        let Some(sections) = doc.get_mut("sections").and_then(Value::as_array_mut) else {
            return;
        };
        for section in sections {
            let Some(steps) = section.get_mut("steps").and_then(Value::as_array_mut) else {
                continue;
            };
            for step in steps {
                if let Some(action) = step.get_mut("action").and_then(Value::as_object_mut) {
                    for (kind, body) in action.iter_mut() {
                        f(kind, body);
                    }
                }
            }
        }
    }

    /// `doc` (a current pattern) as a version-`v` writer stored it: without the fields that version
    /// did not have. A legacy (version 1) file is the bare pattern, its legend starting with the
    /// first `builtins` of the built-in stitches (12, 20 or 21, as releases wrote them).
    fn at_version(mut doc: Value, v: u32, builtins: usize) -> String {
        let obj = doc.as_object_mut().unwrap();
        if v <= 5 {
            obj.remove("pieces");
            if let Some(sections) = obj.get_mut("sections").and_then(Value::as_array_mut) {
                for s in sections {
                    s.as_object_mut().unwrap().remove("piece");
                }
            }
            each_step(&mut doc, |kind, body| {
                if kind == "Close" {
                    body.as_object_mut().unwrap().remove("holds");
                }
            });
        }
        if v <= 4 {
            if let Some(sections) = doc.get_mut("sections").and_then(Value::as_array_mut) {
                for s in sections {
                    s.as_object_mut().unwrap().remove("construction");
                }
            }
            each_step(&mut doc, |kind, body| {
                if kind == "ShortRow" {
                    body.as_object_mut().unwrap().remove("decrease");
                }
            });
        }
        let obj = doc.as_object_mut().unwrap();
        if v <= 3 {
            obj.remove("sections");
        }
        if v <= 2 {
            obj.remove("cast_on");
        }
        if v > 1 {
            return json!({"format": "ply.knit", "schema_version": v, "document": doc}).to_string();
        }
        // A legacy legend: the built-ins of the release, then the customs, moved down to follow.
        let dropped = (21 - builtins) as u64;
        let down = |id: &mut Value| {
            if let Some(old) = id.as_u64().filter(|&old| old >= 21) {
                *id = Value::from(old - dropped);
            }
        };
        if let Some(stitches) = doc
            .pointer_mut("/legend/stitches")
            .and_then(Value::as_array_mut)
        {
            if stitches.len() >= 21 {
                stitches.drain(builtins..21);
            }
            for s in stitches.iter_mut() {
                if let Some(ws) = s.get_mut("ws_variant") {
                    down(ws);
                }
            }
        }
        if let Some(rows) = doc.pointer_mut("/chart/rows").and_then(Value::as_array_mut) {
            for row in rows {
                if let Some(cells) = row.get_mut("cells").and_then(Value::as_array_mut) {
                    for cell in cells {
                        if let Some(stitch) = cell.get_mut("stitch") {
                            down(stitch);
                        }
                    }
                }
            }
        }
        doc.to_string()
    }

    #[test]
    fn every_older_fixture_reads_the_same_both_ways() {
        let files = fixture_files();
        assert!(files.len() >= 30, "{} fixtures", files.len());
        let mut older = 0;
        for path in &files {
            let text = std::fs::read_to_string(path).unwrap();
            if schema_version(&text).unwrap() < KNIT_SCHEMA_VERSION {
                older += 1;
                assert_same(&text);
            }
        }
        assert!(older >= 19, "{older} older fixtures");
        // Every fixture as each older version stored it (the legacy one on each release's
        // built-ins), compact and pretty.
        for seed in seeds() {
            for v in 1..KNIT_SCHEMA_VERSION {
                for builtins in [12, 20, 21] {
                    let text = at_version(seed.clone(), v, builtins);
                    assert_same(&text);
                    let pretty: Value = serde_json::from_str(&text).unwrap();
                    assert_same(&serde_json::to_string_pretty(&pretty).unwrap());
                    if v > 1 {
                        break;
                    }
                }
            }
        }
    }

    #[test]
    fn odd_older_files_read_the_same_both_ways() {
        let seed = seeds().iter().find(|s| s["sections"] != json!([])).unwrap();
        let v5 = at_version(seed.clone(), 5, 21);
        let v4 = at_version(seed.clone(), 4, 21);
        let v1 = at_version(seed.clone(), 1, 12);
        let deep = |n: usize| format!("{}{}", "[".repeat(n), "]".repeat(n));
        let cases = [
            // What the parser refuses anywhere in the file.
            v5.replacen(
                r#""document":"#,
                &format!(r#""x":{},"document":"#, deep(127)),
                1,
            ),
            v5.replacen(
                r#""document":"#,
                &format!(r#""x":{},"document":"#, deep(300)),
                1,
            ),
            v5.replacen(
                r#""notes":"#,
                &format!(r#""later":{},"notes":"#, deep(124)),
                1,
            ),
            v5.replacen(
                r#""notes":"#,
                &format!(r#""later":{},"notes":"#, deep(126)),
                1,
            ),
            v5.replacen(r#""notes":"#, r#""later":"\ud83d","notes":"#, 1),
            v5.replacen(r#""notes":"#, r#""later":1e400,"notes":"#, 1),
            v1.replacen('{', &format!(r#"{{"later":{},"#, deep(127)), 1),
            v1.replacen('{', &format!(r#"{{"later":{},"#, deep(128)), 1),
            format!("{v4} x"),
            // Repeated keys, at every level: the last counts.
            v5.replacen(r#""document":"#, r#""document":7,"document":"#, 1),
            v5.replacen(r#""name":"#, r#""name":7,"name":"#, 1),
            v5.replacen(r#""steps":["#, r#""steps":7,"steps":["#, 1),
            v5.replacen(r#""action":{"#, r#""action":{"Join":{},"#, 1),
            v4.replacen(r#""action":{"#, r#""action":7,"action":{"#, 1),
            v1.replacen(r#""stitches":["#, r#""stitches":[],"stitches":["#, 1),
            // A struct, a section, a step written as a list.
            v5.replacen(
                r#""gauge":{"rows":"#,
                r#""gauge":[1,2,"Inches"],"gauge-was":{"rows":"#,
                1,
            ),
            v5.replacen(
                r#""sections":["#,
                r#""sections":[["s","","",null,null,[["t",{"RoundStart":{}}]]]],"sections-was":["#,
                1,
            ),
            v5.replacen(
                r#""sections":["#,
                r#""sections":[["s","","",null,null,[["t",{"RoundStart":[]}]]]],"sections-was":["#,
                1,
            ),
            // Kinds and turns a version does not have, an action of two keys.
            v4.replacen(
                r#""action":{"#,
                r#""action":{"Groups":{"groups":[]}},"was":{"#,
                1,
            ),
            v5.replacen(
                r#""action":{"#,
                r#""action":{"Rows":{"count":1,"text":""},"x":1},"was":{"#,
                1,
            ),
            v5.replacen(r#""action":{"#, r#""action":{},"was":{"#, 1),
            v5.replacen(r#""action":{"#, r#""action":"JoinRound","was":{"#, 1),
            // Stitch ids past what a legacy remap can move.
            v1.replacen(r#""stitch":"#, r#""stitch":18446744073709551615,"was":"#, 1),
            v1.replacen(r#""stitch":"#, r#""stitch":18446744073709551606,"was":"#, 1),
            v1.replacen(r#""stitch":"#, r#""stitch":-1,"was":"#, 1),
            v1.replacen(r#""stitch":"#, r#""stitch":12.0,"was":"#, 1),
        ];
        for text in &cases {
            assert_same(text);
        }
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

    /// The names the pattern's shapes use, so generated objects reach the migrations' paths.
    const NAMES: [&str; 32] = [
        "id",
        "name",
        "notes",
        "steps",
        "action",
        "stitch",
        "to",
        "method",
        "resolve_turns",
        "decrease",
        "holds",
        "piece",
        "pieces",
        "construction",
        "sections",
        "legend",
        "stitches",
        "chart",
        "rows",
        "cells",
        "Work",
        "ShortRow",
        "Close",
        "Join",
        "Groups",
        "Last",
        "BeforeGap",
        "RoundStart",
        "ws_variant",
        "symbol",
        "x",
        "",
    ];

    fn arb_value() -> impl Strategy<Value = Value> {
        let leaf = prop_oneof![
            Just(Value::Null),
            any::<bool>().prop_map(Value::from),
            (0u64..30).prop_map(Value::from),
            any::<i64>().prop_map(Value::from),
            any::<u64>().prop_map(Value::from),
            (-1e6f64..1e6).prop_map(Value::from),
            prop::sample::select(NAMES.to_vec()).prop_map(Value::from),
        ];
        leaf.prop_recursive(4, 24, 4, |inner| {
            prop_oneof![
                prop::collection::vec(inner.clone(), 0..4).prop_map(Value::from),
                prop::collection::btree_map(prop::sample::select(NAMES.to_vec()), inner, 0..4)
                    .prop_map(|m| Value::Object(
                        m.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
                    )),
            ]
        })
    }

    #[derive(Debug, Clone)]
    enum Change {
        Replace(Value),
        Remove,
        AddKey(&'static str, Value),
        Rename(&'static str),
        AsList,
        Repeat(Value),
    }

    fn arb_change() -> impl Strategy<Value = Change> {
        let name = prop::sample::select(NAMES.to_vec());
        prop_oneof![
            4 => arb_value().prop_map(Change::Replace),
            2 => Just(Change::Remove),
            1 => (name.clone(), arb_value()).prop_map(|(k, v)| Change::AddKey(k, v)),
            2 => name.prop_map(Change::Rename),
            1 => Just(Change::AsList),
            1 => arb_value().prop_map(Change::Repeat),
        ]
    }

    /// `doc` with `changes` made at the places `at` picks, as text. A repeated key is made in the
    /// text: a marker key, renamed after writing to a key the object already has.
    fn changed(mut doc: Value, changes: &[(usize, Change)]) -> String {
        let mut repeats = Vec::new();
        for (at, change) in changes {
            let mut all = Vec::new();
            places(&doc, String::new(), &mut all);
            let place = all[at % all.len()].clone();
            let (parent, last) = match place.rfind('/') {
                Some(i) => (&place[..i], &place[i + 1..]),
                None => ("", ""),
            };
            let last = last.replace("~1", "/").replace("~0", "~");
            match change {
                Change::Replace(with) => *doc.pointer_mut(&place).unwrap() = with.clone(),
                Change::Remove => match doc.pointer_mut(parent) {
                    Some(Value::Object(o)) => {
                        o.remove(&last);
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
                Change::AddKey(key, with) => {
                    if let Some(Value::Object(o)) = doc.pointer_mut(&place) {
                        o.insert(key.to_string(), with.clone());
                    }
                }
                Change::Rename(to) => {
                    if let Some(Value::Object(o)) = doc.pointer_mut(parent) {
                        if let Some(v) = o.remove(&last) {
                            o.insert(to.to_string(), v);
                        }
                    }
                }
                Change::AsList => {
                    let target = doc.pointer_mut(&place).unwrap();
                    if let Value::Object(o) = target {
                        *target = Value::Array(o.values().cloned().collect());
                    }
                }
                Change::Repeat(with) => {
                    if let Some(Value::Object(o)) = doc.pointer_mut(&place) {
                        if let Some(first) = o.keys().next().cloned() {
                            let marker = format!("repeat-marker-{}", repeats.len());
                            o.insert(marker.clone(), with.clone());
                            repeats.push((marker, first));
                        }
                    }
                }
            }
        }
        let mut text = doc.to_string();
        for (marker, key) in repeats {
            text = text.replace(
                &serde_json::to_string(&marker).unwrap(),
                &serde_json::to_string(&key).unwrap(),
            );
        }
        text
    }

    /// The document of a version-`v` file (`text` from [`at_version`]), and how to wrap it again.
    fn document(text: &str, v: u32) -> Value {
        let file: Value = serde_json::from_str(text).unwrap();
        if v == 1 {
            file
        } else {
            file["document"].clone()
        }
    }

    fn wrapped(document: String, v: u32) -> String {
        if v == 1 {
            document
        } else {
            format!(r#"{{"format":"ply.knit","schema_version":{v},"document":{document}}}"#)
        }
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(1024))]

        /// A fixture at an older version with one to four changes made anywhere in its pattern:
        /// a value replaced, a key removed, added, renamed or repeated, an object written as a
        /// list. Both routes give the same verdict.
        #[test]
        fn changed_older_files_read_the_same_both_ways(
            seed in any::<prop::sample::Index>(),
            v in 1u32..KNIT_SCHEMA_VERSION,
            builtins in prop::sample::select(vec![12usize, 20, 21]),
            changes in prop::collection::vec((any::<usize>(), arb_change()), 1..5),
        ) {
            let seed = seed.get(seeds()).clone();
            let doc = document(&at_version(seed, v, builtins), v);
            assert_same(&wrapped(changed(doc, &changes), v));
        }

        /// A document of any shape (in the pattern's own names) at an older version.
        #[test]
        fn any_older_document_reads_the_same_both_ways(
            v in 1u32..KNIT_SCHEMA_VERSION,
            doc in arb_value(),
        ) {
            if v == 1 && doc.get("format").is_some() {
                return Ok(());
            }
            assert_same(&wrapped(doc.to_string(), v));
        }
    }
}
