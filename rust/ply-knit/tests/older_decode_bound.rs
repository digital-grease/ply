//! An OLDER-version `.plyknit` (schema 1 to 5) the restore's value guard lets through is decoded
//! into a lean JSON tree for the migrations, never into a `serde_json::Value`, so it takes no more
//! memory than the documented worst case of `native::MAX_VALUES` for older files. Files at the value
//! limit are built in the shapes that cost the most as a tree (objects of one member, nested inside
//! each other or along the pattern's own paths, in keys the pattern names and keys it does not, and
//! in the envelope), the shapes that cost the most per value in the pattern's types (empty texts in
//! one list, the smallest steps, sections and rows written as lists), the shapes that cost the
//! lean tree more than its usual share (one object with a key for every value, at each level a
//! migration adds keys to; one key repeated for every value), the shapes the migrations refuse
//! (empty sections and close steps) and the largest pattern the app can make, written at an older
//! version. A counting allocator measures the peak heap of `native::read` on each.
//!
//! One test, so nothing else allocates while it is measured.
//!
//! Run: `cargo test -p ply-knit --release --test older_decode_bound -- --nocapture`

use ply_common::json_count::count_values;
use ply_knit::native::{read, MAX_VALUES};
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

struct Counting;

static NOW: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let p = System.alloc(layout);
        if !p.is_null() {
            let now = NOW.fetch_add(layout.size(), Ordering::SeqCst) + layout.size();
            PEAK.fetch_max(now, Ordering::SeqCst);
        }
        p
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout);
        NOW.fetch_sub(layout.size(), Ordering::SeqCst);
    }
}

#[global_allocator]
static ALLOC: Counting = Counting;

const MIB: usize = 1024 * 1024;

/// The documented worst case of an older file at the value limit (about 212 MiB), with a little
/// room. Through a `serde_json::Value` it was about 900 MiB.
const WORST: usize = 240 * MIB;

/// The peak heap `f` adds above what was allocated before it.
fn peak_added<T>(f: impl FnOnce() -> T) -> (T, usize) {
    let base = NOW.load(Ordering::SeqCst);
    PEAK.store(base, Ordering::SeqCst);
    let out = f();
    (out, PEAK.load(Ordering::SeqCst).saturating_sub(base))
}

/// `head`, then as many `item`s as keep the file within the value limit, then `tail`.
fn at_the_limit(head: &str, item: &str, tail: &str) -> String {
    let base = count_values(&format!("{head}{tail}"));
    let each = count_values(item);
    let n = ((MAX_VALUES - base) / each) as usize;
    let text = format!("{head}{}{tail}", vec![item; n].join(","));
    assert!(count_values(&text) <= MAX_VALUES);
    assert!(count_values(&text) > MAX_VALUES - each);
    text
}

/// `text` with its `@` replaced by as many distinct keys (`"k0":0`, `"k1":0`, ...) as keep it within
/// the value limit: one wide object.
fn wide(text: &str) -> String {
    let (head, tail) = text.split_once('@').expect("one @");
    let n = ((MAX_VALUES - count_values(&format!("{head}{tail}"))) / 2) as usize;
    let keys: Vec<String> = (0..n).map(|i| format!(r#""k{i:x}":0"#)).collect();
    let text = format!("{head}{}{tail}", keys.join(","));
    assert!(count_values(&text) <= MAX_VALUES);
    assert!(count_values(&text) > MAX_VALUES - 2);
    text
}

/// A version-`v` file with the `@` in `document` replaced by the items.
fn older(v: u32, document: &str, item: &str) -> String {
    let text = format!(r#"{{"format":"ply.knit","schema_version":{v},"document":{document}}}"#);
    let (head, tail) = text.split_once('@').expect("one @");
    at_the_limit(head, item, tail)
}

/// A legacy (version 1) file, the bare pattern, with `@` replaced by the items.
fn legacy(document: &str, item: &str) -> String {
    let (head, tail) = document.split_once('@').expect("one @");
    at_the_limit(head, item, tail)
}

/// A legacy (version 1) pattern with nothing in it but the 12 built-in stitches of v0.1.0 to
/// v0.1.5 and one custom stitch (id 12), whose cells the migration moves.
fn legacy_doc() -> String {
    format!(
        r#"{{"name":"x","construction":"Flat","first_row_side":"Rs","gauge":{{"sts":1,"rows":1,"unit":"Inches"}},"palette":[],"legend":{{"stitches":[{LEGACY_12}]}},"chart":{{"width":0,"rows":[]}},"notes":""}}"#
    )
}

/// A version-5 pattern with nothing in it, with `@` in place of the value of `field` (a list).
fn pattern_with(field: &str) -> String {
    let fields = [
        ("name", r#""x""#),
        ("construction", r#""Flat""#),
        ("first_row_side", r#""Rs""#),
        ("cast_on", "null"),
        ("gauge", r#"{"sts":1,"rows":1,"unit":"Inches"}"#),
        ("palette", "[]"),
        ("legend", r#"{"stitches":[]}"#),
        ("chart", r#"{"width":0,"rows":[]}"#),
        ("notes", r#""""#),
        ("sections", "[]"),
    ];
    let body: Vec<String> = fields
        .iter()
        .map(|(k, v)| {
            let v = match (*k, field) {
                ("legend", "stitches") => r#"{"stitches":[@]}"#.to_string(),
                ("chart", "rows") => r#"{"width":0,"rows":[@]}"#.to_string(),
                ("chart", "cells") => {
                    r#"{"width":0,"rows":[{"cells":[@],"repeats":[]}]}"#.to_string()
                }
                (k, f) if k == f => "[@]".to_string(),
                _ => v.to_string(),
            };
            format!(r#""{k}":{v}"#)
        })
        .collect();
    format!("{{{}}}", body.join(","))
}

/// A version-5 pattern with one section whose steps are `@`.
fn pattern_with_steps() -> String {
    pattern_with("sections").replace(
        "[@]",
        r#"[{"id":"s","name":"","notes":"","construction":null,"steps":[@]}]"#,
    )
}

/// A version-5 pattern with one section holding one step whose action is `action` (with `@` in it).
fn pattern_with_step(action: &str) -> String {
    pattern_with("sections").replace(
        "[@]",
        &format!(
            r#"[{{"id":"s","name":"","notes":"","construction":null,"steps":[{{"id":"t","action":{action}}}]}}]"#
        ),
    )
}

/// The largest pattern the app can make (as `tests/value_limit.rs` builds it, in its file form),
/// written as a version-5 file: no pieces, no section names its piece.
fn largest_v5() -> String {
    let text = |n: usize| "x".repeat(n);
    let mut stitches: Vec<String> = Vec::new();
    for _ in 0..21 {
        stitches.push(r#"{"symbol":"k","consumes":1,"produces":1,"ws_variant":2,"cable":null,"macro_rows":1}"#.into());
    }
    for i in 0..1000 {
        stitches.push(format!(
            r#"{{"symbol":"{i:064}","consumes":3,"produces":3,"ws_variant":1,"cable":{{"front":2,"back":1,"direction":"Left","front_purl":true,"back_purl":false}},"macro_rows":1}}"#
        ));
    }
    let palette = vec![r#"{"r":10,"g":20,"b":30}"#; 1000].join(",");
    let cell = r#"{"stitch":1020,"color":999}"#;
    let row = format!(
        r#"{{"cells":[{}],"repeats":[{}]}}"#,
        vec![cell; 200].join(","),
        (0..200)
            .map(|c| format!(
                r#"{{"start":{c},"end":{},"count":{{"Times":65535}}}}"#,
                c + 1
            ))
            .collect::<Vec<_>>()
            .join(",")
    );
    let rows = vec![row; 400].join(",");
    let sections = (0..1000)
        .map(|s| {
            let steps = (0..10)
                .map(|k| {
                    format!(
                        r#"{{"id":"step-{:059}","action":{{"Opaque":{{"text":"{}","stitch_change":-1000000}}}}}}"#,
                        s * 10 + k,
                        text(500)
                    )
                })
                .collect::<Vec<_>>()
                .join(",");
            format!(
                r#"{{"id":"section-{s:056}","name":"{}","notes":"{}","construction":"InTheRound","steps":[{steps}]}}"#,
                text(200),
                text(500)
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    format!(
        r#"{{"format":"ply.knit","schema_version":5,"document":{{"name":"{}","construction":"Flat","first_row_side":"Rs","cast_on":1000000,"gauge":{{"sts":22.5,"rows":30.0,"unit":"Centimeters"}},"palette":[{palette}],"legend":{{"stitches":[{}]}},"chart":{{"width":200,"rows":[{rows}]}},"notes":"{}","sections":[{sections}]}}}}"#,
        text(1000),
        stitches.join(","),
        text(100_000)
    )
}

#[test]
fn an_older_file_at_the_value_limit_decodes_within_the_documented_bound() {
    let nested = format!("{}0{}", r#"{"a":"#.repeat(100), "}".repeat(100));
    let envelope_head = r#"{"format":"ply.knit","schema_version":5,"later":[@],"document":"#;
    let empty = pattern_with("notes").replace(r#""notes":[@]"#, r#""notes":"""#);
    let files: Vec<(&str, bool, String)> = vec![
        (
            "nested objects of one member, in a key the pattern does not name",
            true,
            older(
                5,
                &pattern_with("notes").replace(r#""notes":[@]"#, r#""notes":"","later":[@]"#),
                &nested,
            ),
        ),
        (
            "nested objects of one member, in a key the pattern names (refused)",
            false,
            older(5, &pattern_with("notes"), &nested),
        ),
        (
            "nested objects of one member, in the envelope",
            true,
            at_the_limit(
                envelope_head.split_once('@').unwrap().0,
                &nested,
                &format!("{}{empty}}}", envelope_head.split_once('@').unwrap().1),
            ),
        ),
        (
            "nested objects of one member, in a legacy (version 1) file's key it does not name",
            true,
            legacy(&legacy_doc().replacen('{', r#"{"later":[@],"#, 1), &nested),
        ),
        (
            "chart cells as objects of one member",
            true,
            older(5, &pattern_with("cells"), r#"{"stitch":0}"#),
        ),
        (
            "the smallest steps as objects",
            true,
            older(
                5,
                &pattern_with_steps(),
                r#"{"id":"","action":{"RoundStart":{}}}"#,
            ),
        ),
        (
            "steps with an enum inside a step's action",
            true,
            older(
                5,
                &pattern_with_steps(),
                r#"{"id":"","action":{"Work":{"stitch":"Knit","to":{"Last":0},"resolve_turns":false}}}"#,
            ),
        ),
        (
            "objects of one member along the pattern's paths (refused)",
            false,
            older(
                5,
                &pattern_with_steps(),
                r#"{"action":{"Work":{"to":{"Last":0}}}}"#,
            ),
        ),
        (
            "empty texts in one list (a shaping step's groups)",
            true,
            older(
                5,
                &pattern_with_step(
                    r#"{"Shape":{"change":0,"every":1,"until":{"Times":1},"groups":[@],"text":""}}"#,
                ),
                r#""""#,
            ),
        ),
        (
            "the smallest steps, written as lists",
            true,
            older(5, &pattern_with_steps(), r#"["",{"RoundStart":{}}]"#),
        ),
        (
            "the smallest sections, written as lists",
            true,
            older(5, &pattern_with("sections"), r#"["","","",null,null,[]]"#),
        ),
        (
            "the smallest chart rows, written as lists",
            true,
            older(5, &pattern_with("rows"), "[[],[]]"),
        ),
        (
            "the smallest stitch definitions, written as lists",
            true,
            older(5, &pattern_with("stitches"), r#"["",0,0,null,null,0]"#),
        ),
        (
            "version-4 empty sections (refused)",
            false,
            older(4, &pattern_with("sections"), "{}"),
        ),
        (
            "version-5 empty close steps (refused)",
            false,
            older(5, &pattern_with_steps(), r#"{"action":{"Close":{}}}"#),
        ),
        (
            "a legacy (version 1) file's cells, remapped",
            true,
            legacy(
                &legacy_doc().replace(r#""rows":[]"#, r#""rows":[{"repeats":[],"cells":[@]}]"#),
                r#"{"stitch":12}"#,
            ),
        ),
        (
            "one wide object: the envelope, with a key for every value",
            true,
            wide(&format!(
                r#"{{"format":"ply.knit","schema_version":5,@,"document":{empty}}}"#
            )),
        ),
        (
            "one wide object: a version-2 document (the migrations add keys to it)",
            true,
            wide(&format!(
                r#"{{"format":"ply.knit","schema_version":2,"document":{}}}"#,
                empty.replacen(r#""notes":"""#, r#""notes":"",@"#, 1)
            )),
        ),
        (
            "one wide object: a legacy (version 1) file",
            true,
            wide(&legacy_doc().replacen('{', "{@,", 1)),
        ),
        (
            "one wide object: a version-4 section (the migrations add keys to it)",
            true,
            wide(&format!(
                r#"{{"format":"ply.knit","schema_version":4,"document":{}}}"#,
                pattern_with("sections")
                    .replace("[@]", r#"[{"id":"s","name":"","notes":"","steps":[],@}]"#)
            )),
        ),
        (
            "one key repeated for every value, in the document",
            true,
            older(
                5,
                &pattern_with("notes").replace(r#""notes":[@]"#, r#""notes":"",@"#),
                r#""":0"#,
            ),
        ),
        (
            "one key repeated for every value, in the envelope",
            true,
            at_the_limit(
                r#"{"format":"ply.knit","schema_version":5,"#,
                r#""":0"#,
                &format!(r#","document":{empty}}}"#),
            ),
        ),
        (
            "the largest pattern the app can make, as version 5",
            true,
            largest_v5(),
        ),
    ];
    let mut report = Vec::new();
    for (name, reads, text) in &files {
        assert!(count_values(text) <= MAX_VALUES, "{name}");
        let (result, peak) = peak_added(|| read(text).map(|_| ()));
        report.push(format!(
            "{name}: {} MiB ({})",
            peak / MIB,
            match &result {
                Ok(()) => "read".to_string(),
                Err(e) => format!(
                    "refused: {}",
                    e.to_string().chars().take(60).collect::<String>()
                ),
            }
        ));
        assert_eq!(result.is_ok(), *reads, "{name}: {result:?}");
        assert!(peak <= WORST, "{name}: read peaked at {} MiB", peak / MIB);
    }
    eprintln!("{}", report.join("\n"));
    // Objects of one member, the costliest shape as a `serde_json::Value` (901 MiB), are among the
    // cheapest here.
    let (_, peak) = peak_added(|| read(&files[0].2).map(|_| ()));
    assert!(
        peak < 80 * MIB,
        "nested objects peaked at {} MiB",
        peak / MIB
    );
}

/// The 12 built-in stitches releases v0.1.0 to v0.1.5 wrote at the head of a legacy legend, with one
/// custom stitch (id 12) after them.
const LEGACY_12: &str = r#"{"symbol":"ns","consumes":0,"produces":0,"ws_variant":null,"cable":null,"macro_rows":1},{"symbol":"k","consumes":1,"produces":1,"ws_variant":2,"cable":null,"macro_rows":1},{"symbol":"p","consumes":1,"produces":1,"ws_variant":1,"cable":null,"macro_rows":1},{"symbol":"yo","consumes":0,"produces":1,"ws_variant":null,"cable":null,"macro_rows":1},{"symbol":"k2tog","consumes":2,"produces":1,"ws_variant":6,"cable":null,"macro_rows":1},{"symbol":"ssk","consumes":2,"produces":1,"ws_variant":6,"cable":null,"macro_rows":1},{"symbol":"p2tog","consumes":2,"produces":1,"ws_variant":4,"cable":null,"macro_rows":1},{"symbol":"cdd","consumes":3,"produces":1,"ws_variant":null,"cable":null,"macro_rows":1},{"symbol":"m1l","consumes":0,"produces":1,"ws_variant":null,"cable":null,"macro_rows":1},{"symbol":"m1r","consumes":0,"produces":1,"ws_variant":null,"cable":null,"macro_rows":1},{"symbol":"kfb","consumes":1,"produces":2,"ws_variant":null,"cable":null,"macro_rows":1},{"symbol":"sl","consumes":1,"produces":1,"ws_variant":null,"cable":null,"macro_rows":1},{"symbol":"c","consumes":1,"produces":1,"ws_variant":null,"cable":null,"macro_rows":1}"#;
