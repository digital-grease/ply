//! The `.plyknit` version probe on hostile files: reading the version of a file builds nothing in
//! proportion to it. A counting allocator measures the peak memory the probe adds while it reads
//! files of tens of megabytes whose document, `format` or `schema_version` is a huge list or object;
//! it must stay under a megabyte, whatever the file's size (the backup restore asks it of every
//! pattern before anything else). So must the restore's value guard, which counts a file's values
//! without decoding it.
//!
//! One test per file, so no other test allocates while one is measured.
//!
//! Run: `cargo test -p ply-knit --test native_probe`

use ply_knit::native::{schema_version, within_value_limit};
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

const MB: usize = 1024 * 1024;

/// The peak memory `f` adds above what was allocated before it.
fn measured<T>(f: impl FnOnce() -> T) -> (T, usize) {
    let base = NOW.load(Ordering::SeqCst);
    PEAK.store(base, Ordering::SeqCst);
    let out = f();
    (out, PEAK.load(Ordering::SeqCst).saturating_sub(base))
}

/// `{"format": ..., "schema_version": ..., "document": [...]}` with `fill` repeated to about `bytes`.
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
    // A 40 MB document of empty objects under a tiny envelope: decoded, gigabytes.
    let text = hostile(r#""ply.knit""#, "6", "{}", 40 * MB);
    let (v, peak) = measured(|| schema_version(&text));
    assert_eq!(v.unwrap(), 6);
    assert!(peak < MB, "probe peak {peak} bytes");
    // The restore's guard counts its values and refuses it, allocating nothing.
    let (fits, peak) = measured(|| within_value_limit(&text));
    assert!(!fits);
    assert_eq!(peak, 0, "guard peak {peak} bytes");
    drop(text);

    // A newer file is reported as newer, at the same cost.
    let text = hostile(r#""ply.knit""#, "7", r#"[1,"two",{"k":3}]"#, 20 * MB);
    let (v, peak) = measured(|| schema_version(&text));
    assert!(
        matches!(v, Err(KnitError::NewerVersion { found: 7, .. })),
        "{v:?}"
    );
    assert!(peak < MB, "newer peak {peak} bytes");
    drop(text);

    // A legacy file (no format) is read to its end to be sure, at the same cost.
    let mut text = String::with_capacity(20 * MB + 100);
    text.push_str(r#"{"name": "big", "legend": ["#);
    while text.len() < 20 * MB {
        text.push_str("{},");
    }
    text.push_str("{}]}");
    let (v, peak) = measured(|| schema_version(&text));
    assert_eq!(v.unwrap(), 1);
    assert!(peak < MB, "legacy peak {peak} bytes");
    drop(text);

    // The format itself a huge list, or the version a huge object: skipped, never built.
    let big_list = format!("[{}]", "[0],".repeat(4 * MB) + "0");
    let text = hostile(&big_list, "6", "{}", 16);
    let (v, peak) = measured(|| schema_version(&text));
    assert!(
        matches!(v, Err(KnitError::WrongFormat { ref found }) if found == "a list"),
        "{v:?}"
    );
    assert!(peak < MB, "format peak {peak} bytes");
    let big_map = format!("{{{}\"k\": 0}}", "\"k\": {},".repeat(2 * MB));
    let text = hostile(r#""ply.knit""#, &big_map, "{}", 16);
    let (v, peak) = measured(|| schema_version(&text));
    assert!(matches!(v, Err(KnitError::Malformed(_))), "{v:?}");
    assert!(peak < MB, "version peak {peak} bytes");
}
