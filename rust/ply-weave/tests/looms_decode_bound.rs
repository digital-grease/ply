//! A `looms.json` of up to its byte limit (as a backup carries it) is read without a generic tree:
//! the first pass builds nothing and the looms are decoded into their types, so no file takes more
//! than a few times its own size. Files at the byte limit are built in the shapes that cost the most
//! as a tree (objects of one member nested inside each other, in a key the format does not have, in
//! a loom, in a field of another type, as a loom's reeds), the shapes that cost the most in the
//! looms' types (the smallest reeds, written as lists; empty texts), past the loom count, and the
//! largest file the app can write. A counting allocator measures the peak heap of `read` on each.
//!
//! One test, so nothing else allocates while it is measured.
//!
//! Run: `cargo test -p ply-weave --release --test looms_decode_bound -- --nocapture`

use ply_common::Unit;
use ply_weave::loom::{
    DentUnit, Length, LoomKind, LoomProfile, Reed, MAX_LOOM_NAME_CHARS, MAX_LOOM_NOTES_CHARS,
    MAX_REEDS,
};
use ply_weave::loom_file::{read, write, LoomLibrary, MAX_LOOMS, MAX_LOOMS_FILE_BYTES};
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

/// The documented worst case of a file at the byte limit, with a little room.
const WORST: usize = 8 * MIB;

/// The peak heap `f` adds above what was allocated before it.
fn peak_added<T>(f: impl FnOnce() -> T) -> (T, usize) {
    let base = NOW.load(Ordering::SeqCst);
    PEAK.store(base, Ordering::SeqCst);
    let out = f();
    (out, PEAK.load(Ordering::SeqCst).saturating_sub(base))
}

/// `head`, then as many `item`s as keep the file within the byte limit, then `tail`.
fn at_the_limit(text: &str, item: &str) -> String {
    let (head, tail) = text.split_once('@').expect("one @");
    let n = (MAX_LOOMS_FILE_BYTES - head.len() - tail.len() + 1) / (item.len() + 1);
    let text = format!("{head}{}{tail}", vec![item; n].join(","));
    assert!(text.len() <= MAX_LOOMS_FILE_BYTES);
    assert!(text.len() + item.len() + 1 > MAX_LOOMS_FILE_BYTES);
    text
}

/// A loom with every field at its limit, its notes `notes` characters long.
fn full_loom(i: usize, notes: usize) -> LoomProfile {
    LoomProfile {
        id: format!("{i:064}"),
        name: "é".repeat(MAX_LOOM_NAME_CHARS),
        kind: Some(LoomKind::Countermarch),
        shafts: Some(200),
        treadles: Some(200),
        weaving_width: Some(Length {
            value: 9999.5,
            unit: Unit::Centimeters,
        }),
        reeds: vec![
            Reed {
                dents: 999.5,
                per: DentUnit::Per10Cm,
            };
            MAX_REEDS
        ],
        treadles_at_once: Some(10),
        notes: "x".repeat(notes),
    }
}

/// The largest file the app can write: every loom it allows, every field at its limit, notes as
/// long as the byte limit leaves room for.
fn largest() -> String {
    let lib = |notes: usize| LoomLibrary {
        looms: (0..MAX_LOOMS).map(|i| full_loom(i, notes)).collect(),
    };
    let (mut lo, mut hi) = (0, MAX_LOOM_NOTES_CHARS);
    while lo < hi {
        let mid = (lo + hi).div_ceil(2);
        if write(&lib(mid)).is_ok() {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    let text = write(&lib(lo)).expect("written");
    assert!(text.len() > MAX_LOOMS_FILE_BYTES - 10_000, "{}", text.len());
    text
}

#[test]
fn a_looms_file_at_its_byte_limit_reads_within_the_documented_bound() {
    let nested = format!("{}0{}", r#"{"a":"#.repeat(100), "}".repeat(100));
    let env = |rest: &str| format!(r#"{{"format":"ply.looms","schema_version":1,{rest}}}"#);
    let files: Vec<(&str, bool, String)> = vec![
        (
            "nested objects of one member, in a key the format does not have",
            false,
            at_the_limit(&env(r#""looms":[],"x":[@]"#), &nested),
        ),
        (
            "nested objects of one member, in a loom's key the format does not have",
            false,
            at_the_limit(&env(r#""looms":[{"id":"a","name":"","x":[@]}]"#), &nested),
        ),
        (
            "nested objects of one member, in a loom's notes",
            false,
            at_the_limit(
                &env(r#""looms":[{"id":"a","name":"","notes":[@]}]"#),
                &nested,
            ),
        ),
        (
            "nested objects of one member, as a loom's reeds",
            false,
            at_the_limit(
                &env(r#""looms":[{"id":"a","name":"","reeds":[@]}]"#),
                &nested,
            ),
        ),
        (
            "empty objects as looms, past the loom count",
            false,
            at_the_limit(&env(r#""looms":[@]"#), "{}"),
        ),
        (
            "empty texts in a key the format does not have",
            false,
            at_the_limit(&env(r#""looms":[],"x":[@]"#), r#""""#),
        ),
        (
            "the smallest reeds, written as lists",
            false,
            at_the_limit(
                &env(r#""looms":[{"id":"a","name":"","reeds":[@]}]"#),
                r#"[1,"inch"]"#,
            ),
        ),
        (
            "the smallest looms, written as lists, in an earlier repeat of the key",
            true,
            at_the_limit(
                &env(r#""looms":[@],"looms":[]"#),
                r#"["a","",null,null,null,null,[],null,""]"#,
            ),
        ),
        ("the largest file the app can write", true, largest()),
    ];
    let mut report = Vec::new();
    for (name, reads, text) in &files {
        let (result, peak) = peak_added(|| read(text).map(|_| ()));
        report.push(format!(
            "{name}: {:.1} MiB ({})",
            peak as f64 / MIB as f64,
            match &result {
                Ok(()) => "read".to_string(),
                Err(e) => format!(
                    "refused: {}",
                    e.to_string().chars().take(70).collect::<String>()
                ),
            }
        ));
        assert_eq!(result.is_ok(), *reads, "{name}: {result:?}");
        assert!(peak <= WORST, "{name}: read peaked at {} MiB", peak / MIB);
    }
    eprintln!("{}", report.join("\n"));
}
