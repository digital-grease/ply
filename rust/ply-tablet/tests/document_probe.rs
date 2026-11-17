//! The `.plytab` envelope probe on hostile files (M10-02 review): reading the version of a file
//! builds nothing in proportion to it. A counting allocator measures the peak memory the probe adds
//! while reading files of tens of megabytes whose document, `format` or `schema_version` is a huge
//! list or object; it must stay under a megabyte, whatever the file's size.
//!
//! One test per file, so no other test allocates while one is measured.
//!
//! Run: `cargo test -p ply-tablet --test document_probe`

use ply_tablet::{document_schema_version, read_document, DocumentError, MAX_DOCUMENT_BYTES};
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

/// The peak memory `f` adds above what was allocated before it.
fn peak_added<T>(f: impl FnOnce() -> T) -> (T, usize) {
    let base = NOW.load(Ordering::SeqCst);
    PEAK.store(base, Ordering::SeqCst);
    let out = f();
    (out, PEAK.load(Ordering::SeqCst).saturating_sub(base))
}

/// `{"format": ..., "schema_version": ..., "document": ...}` with `fill` repeated to about `bytes`.
fn hostile(format: &str, version: &str, fill: &str, bytes: usize) -> String {
    let mut s = String::with_capacity(bytes + 200);
    s.push_str(&format!(
        r#"{{"format": {format}, "schema_version": {version}, "document": ["#
    ));
    while s.len() < bytes {
        s.push_str(fill);
        s.push(',');
    }
    s.push_str("{}]}");
    s
}

#[test]
fn probing_a_hostile_file_allocates_nothing_in_proportion_to_it() {
    const MB: usize = 1024 * 1024;
    // A 40 MB document of empty objects (what one backup entry measured at gigabytes when decoded).
    let text = hostile(r#""ply.tablet""#, "1", "{}", 40 * MB);
    let (v, peak) = peak_added(|| document_schema_version(&text));
    assert_eq!(v, Ok(1));
    assert!(peak < MB, "probe peak {peak} bytes");
    // The reader refuses it as too large, after the same probe, without decoding it.
    let (r, peak) = peak_added(|| read_document(&text).map(|_| ()));
    assert!(matches!(r, Err(DocumentError::TooLarge(_))));
    assert!(text.len() > MAX_DOCUMENT_BYTES);
    assert!(peak < MB, "reader peak {peak} bytes");
    drop(text);

    // A newer file is reported as newer, at the same cost.
    let text = hostile(r#""ply.tablet""#, "7", "[1,2,3]", 20 * MB);
    let (v, peak) = peak_added(|| document_schema_version(&text));
    assert!(matches!(
        v,
        Err(DocumentError::NewerVersion { found: 7, .. })
    ));
    assert!(peak < MB, "newer peak {peak} bytes");
    drop(text);

    // The format itself a huge list, or the version a huge object: skipped, never built.
    let big_list = format!("[{}]", "[0],".repeat(4 * MB) + "0");
    let text = hostile(&big_list, "1", "{}", 16);
    let (v, peak) = peak_added(|| document_schema_version(&text));
    assert!(matches!(v, Err(DocumentError::WrongFormat { ref found }) if found == "a list"));
    assert!(peak < MB, "format peak {peak} bytes");
    let big_map = format!("{{{}\"k\": 0}}", "\"k\": {},".repeat(2 * MB));
    let text = hostile(r#""ply.tablet""#, &big_map, "{}", 16);
    let (v, peak) = peak_added(|| document_schema_version(&text));
    assert!(matches!(v, Err(DocumentError::Malformed(_))), "{v:?}");
    assert!(peak < MB, "version peak {peak} bytes");
}
