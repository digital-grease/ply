//! A file the restore's value guard lets through takes no more memory to read than the guard's
//! documented worst case, even when the migrations would add a field to every object. Empty
//! sections, short rows and close steps (`{}`) cost a few bytes each in their list, and would cost a
//! map node of hundreds of bytes each once a migration added a field; the migrations refuse them
//! first. A counting allocator measures the peak heap of `native::read` on files at the value limit.
//!
//! One test, so nothing else allocates while it is measured.
//!
//! Run: `cargo test -p ply-knit --test migration_bound`

use ply_common::json_count::count_values;
use ply_knit::native::{read, MAX_VALUES};
use ply_knit::KnitError;
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

/// The documented worst case of a file at the value limit (`MAX_VALUES`), with a little room.
const WORST: usize = 950 * MIB;

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
    let n = ((MAX_VALUES - base) / count_values(item)) as usize;
    let text = format!("{head}{}{tail}", vec![item; n].join(","));
    assert!(count_values(&text) <= MAX_VALUES);
    assert!(count_values(&text) > MAX_VALUES - 10);
    text
}

/// A version-`v` document with everything but its sections, which follow.
fn document(v: u32) -> String {
    format!(
        r#"{{"format":"ply.knit","schema_version":{v},"document":{{"name":"x","construction":"Flat","first_row_side":"Rs","cast_on":null,"gauge":{{"sts":1,"rows":1,"unit":"Inches"}},"palette":[],"legend":{{"stitches":[]}},"chart":{{"width":0,"rows":[]}},"notes":"","sections":["#
    )
}

#[test]
fn files_of_empty_objects_for_the_migrations_to_fill_are_refused_first() {
    let section = r#"{"id":"s","name":"","notes":"","steps":["#;
    let files = [
        (
            "version-4 empty sections",
            at_the_limit(&document(4), "{}", "]}}"),
        ),
        (
            "version-5 empty sections",
            at_the_limit(&document(5), "{}", "]}}"),
        ),
        (
            "version-5 empty close steps",
            at_the_limit(
                &format!("{}{section}", document(5)),
                r#"{"action":{"Close":{}}}"#,
                "]}]}}",
            ),
        ),
        (
            "version-4 empty short rows",
            at_the_limit(
                &format!("{}{section}", document(4)),
                r#"{"action":{"ShortRow":{}}}"#,
                "]}]}}",
            ),
        ),
    ];
    for (name, text) in files {
        let (result, peak) = peak_added(|| read(&text).map(|_| ()));
        assert!(
            matches!(result, Err(KnitError::Malformed(_))),
            "{name}: {result:?}"
        );
        assert!(peak <= WORST, "{name}: read peaked at {} MiB", peak / MIB);
    }
}
