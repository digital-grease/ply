//! A current-version `.plyknit` the restore's value guard lets through is decoded into the pattern's
//! types, never into a generic tree, so it takes no more memory than the documented worst case of
//! `native::MAX_VALUES` for current files. Files at the value limit are built in the shapes that cost
//! the most per value in those types (empty texts in one list, the smallest steps, sections, rows,
//! pieces and needle groups written as lists), and in the shape that cost the most as a tree
//! (objects of one member nested inside each other, here in a key the types do not name). A counting
//! allocator measures the peak heap of `native::read` on each, and on the largest pattern the app
//! can make.
//!
//! One test, so nothing else allocates while it is measured.
//!
//! Run: `cargo test -p ply-knit --test decode_bound`

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

/// The documented worst case of a current-version file at the value limit (about 144 MiB), with a
/// little room.
const WORST: usize = 160 * MIB;

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

/// A current-version file with the `@` in `document` replaced by the items.
fn current(document: &str, item: &str) -> String {
    let text = format!(r#"{{"format":"ply.knit","schema_version":6,"document":{document}}}"#);
    let (head, tail) = text.split_once('@').expect("one @");
    at_the_limit(head, item, tail)
}

/// A pattern with nothing in it, with `@` in place of the value of `field` (a list).
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
        ("pieces", "[]"),
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

/// A pattern with one section holding one step whose action is `action` (with `@` in it).
fn pattern_with_step(action: &str) -> String {
    pattern_with("sections").replace(
        "[@]",
        &format!(
            r#"[{{"id":"s","name":"","notes":"","construction":null,"piece":null,"steps":[{{"id":"t","action":{action}}}]}}]"#
        ),
    )
}

#[test]
fn a_current_file_at_the_value_limit_decodes_within_the_documented_bound() {
    let nested = format!("{}0{}", r#"{"a":"#.repeat(100), "}".repeat(100));
    let one_section =
        r#"[{"id":"s","name":"","notes":"","construction":null,"piece":null,"steps":[@]}]"#;
    let files = [
        (
            "objects of one member nested inside each other, in a key the types do not name",
            current(
                &pattern_with("notes").replace(r#""notes":[@]"#, r#""notes":"","later":[@]"#),
                &nested,
            ),
        ),
        (
            "empty texts in one list (a close step's holds)",
            current(
                &pattern_with_step(r#"{"Close":{"method":"Graft","holds":[@]}}"#),
                r#""""#,
            ),
        ),
        (
            "the smallest steps, written as lists",
            current(
                &pattern_with("sections").replace("[@]", one_section),
                r#"["",{"RoundStart":[]}]"#,
            ),
        ),
        (
            "the smallest sections, written as lists",
            current(&pattern_with("sections"), r#"["","","",null,null,[]]"#),
        ),
        (
            "the smallest chart rows, written as lists",
            current(&pattern_with("rows"), "[[],[]]"),
        ),
        (
            "chart cells, written as lists",
            current(&pattern_with("cells"), "[0,null]"),
        ),
        (
            "the smallest stitch definitions, written as lists",
            current(&pattern_with("stitches"), r#"["",0,0,null,null,0]"#),
        ),
        (
            "the smallest pieces, written as lists",
            current(&pattern_with("pieces"), r#"["",""]"#),
        ),
        (
            "the smallest needle groups, written as lists",
            current(
                &pattern_with_step(r#"{"Groups":{"groups":[@]}}"#),
                r#"["",0,""]"#,
            ),
        ),
    ];
    for (name, text) in &files {
        let (result, peak) = peak_added(|| read(text).map(|_| ()));
        assert!(result.is_ok(), "{name}: {result:?}");
        assert!(peak <= WORST, "{name}: read peaked at {} MiB", peak / MIB);
    }
    // The nested objects cost nothing at all: the key holding them is skipped unread.
    let (_, peak) = peak_added(|| read(&files[0].1).map(|_| ()));
    assert!(peak < MIB, "skipped values peaked at {peak} bytes");
}
