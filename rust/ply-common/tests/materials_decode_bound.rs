//! A `materials.json` of up to its byte limit (as a backup carries it) is read without a generic
//! tree: the first pass builds nothing and the records are decoded into their types, so no file
//! takes more than a few times its own size. Files at the byte limit are built in the shapes that
//! cost the most as a tree (objects of one member nested inside each other, in a key the format does
//! not have, in a record, in a field of another type, as a record's list), the shapes that cost the
//! most in the records' types (the smallest fibers and swatch yarns, written as lists; empty
//! texts), past the record counts, and the largest file the app can write. A counting allocator
//! measures the peak heap of `read` on each.
//!
//! One test, so nothing else allocates while it is measured.
//!
//! Run: `cargo test -p ply-common --release --test materials_decode_bound -- --nocapture`

use ply_common::materials::{
    FiberPart, Material, Stage, Swatch, SwatchYarn, YarnRole, MAX_FIBERS, MAX_NAME_CHARS,
    MAX_NOTES_CHARS, MAX_SHORT_TEXT_CHARS, MAX_SWATCH_YARNS,
};
use ply_common::materials_file::{
    read, write, MaterialLibrary, MAX_MATERIALS, MAX_MATERIALS_FILE_BYTES, MAX_SWATCHES,
};
use ply_common::provenance::Recorded;
use ply_common::quantity::{CountOver, Length, LengthPerMass, LengthUnit, Mass};
use ply_common::{CraftKind, YarnWeight};
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
const WORST: usize = 24 * MIB;

/// The peak heap `f` adds above what was allocated before it.
fn peak_added<T>(f: impl FnOnce() -> T) -> (T, usize) {
    let base = NOW.load(Ordering::SeqCst);
    PEAK.store(base, Ordering::SeqCst);
    let out = f();
    (out, PEAK.load(Ordering::SeqCst).saturating_sub(base))
}

/// The text with its `@` replaced by as many `item`s as keep it within the byte limit.
fn at_the_limit(text: &str, item: &str) -> String {
    let (head, tail) = text.split_once('@').expect("one @");
    let n = (MAX_MATERIALS_FILE_BYTES - head.len() - tail.len() + 1) / (item.len() + 1);
    let text = format!("{head}{}{tail}", vec![item; n].join(","));
    assert!(text.len() <= MAX_MATERIALS_FILE_BYTES);
    assert!(text.len() + item.len() + 1 > MAX_MATERIALS_FILE_BYTES);
    text
}

fn recorded<T>(value: T) -> Option<Recorded<T>> {
    Some(Recorded::measured(value))
}

/// A material with every field filled, its notes `notes` characters long.
fn full_material(i: usize, notes: usize) -> Material {
    let short = "s".repeat(MAX_SHORT_TEXT_CHARS);
    Material {
        id: format!("{i:064}"),
        name: "n".repeat(MAX_NAME_CHARS),
        maker: short.clone(),
        fibers: (0..MAX_FIBERS)
            .map(|_| FiberPart {
                fiber: short.clone(),
                percent: Some(12.5),
            })
            .collect(),
        weight: Some(YarnWeight::SuperBulky),
        structure: short.clone(),
        length_per_mass: recorded(LengthPerMass::new(
            Length::new(1234.5, LengthUnit::Yard),
            Mass::grams(100.25),
        )),
        wpi: recorded(CountOver::new(11.5, Length::new(1.0, LengthUnit::Inch))),
        color: short.clone(),
        dye_lot: short,
        available_mass: recorded(Mass::grams(4500.75)),
        available_length: recorded(Length::new(12345.5, LengthUnit::Meter)),
        notes: "x".repeat(notes),
    }
}

/// A swatch with every field filled, its notes `notes` characters long.
fn full_swatch(i: usize, notes: usize) -> Swatch {
    let short = "s".repeat(MAX_SHORT_TEXT_CHARS);
    let stage = Stage {
        width: recorded(Length::cm(10.5)),
        length: recorded(Length::cm(12.5)),
        across: recorded(CountOver::new(22.5, Length::cm(10.0))),
        along: recorded(CountOver::new(30.5, Length::cm(10.0))),
        conditions: short.clone(),
    };
    Swatch {
        id: format!("{i:064}"),
        name: "n".repeat(MAX_NAME_CHARS),
        craft: Some(CraftKind::Weaving),
        technique: short.clone(),
        date: Some("2026-11-18".into()),
        yarns: (0..MAX_SWATCH_YARNS)
            .map(|k| SwatchYarn {
                material_id: Some(format!("{k:064}")),
                name: "y".repeat(MAX_NAME_CHARS),
                role: Some(YarnRole::Warp),
            })
            .collect(),
        tools: short.clone(),
        sett: recorded(CountOver::new(24.5, Length::new(1.0, LengthUnit::Inch))),
        width_in_reed: recorded(Length::cm(30.5)),
        on_loom: stage.clone(),
        before: stage.clone(),
        after: stage,
        finishing: short.clone(),
        mass: recorded(Mass::grams(25.5)),
        tension: short.clone(),
        provenance: short,
        notes: "x".repeat(notes),
    }
}

/// The largest file the app can write: as many records with every field filled as fit within the
/// byte limit, their notes as long as it leaves room for. (Every record the app allows, 500 of each,
/// does not fit: a record with every field filled is several kilobytes.)
fn largest() -> String {
    let lib = |n: usize, notes: usize| MaterialLibrary {
        materials: (0..n.min(MAX_MATERIALS))
            .map(|i| full_material(i, notes))
            .collect(),
        swatches: (0..n.min(MAX_SWATCHES))
            .map(|i| full_swatch(i, notes))
            .collect(),
    };
    let fits = |n: usize, notes: usize| write(&lib(n, notes)).is_ok();
    let mut n = 1;
    while n < MAX_MATERIALS && fits(n + 1, 0) {
        n += 1;
    }
    let (mut lo, mut hi) = (0, MAX_NOTES_CHARS);
    while lo < hi {
        let mid = (lo + hi).div_ceil(2);
        if fits(n, mid) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    let text = write(&lib(n, lo)).expect("written");
    assert!(
        text.len() > MAX_MATERIALS_FILE_BYTES - 20_000,
        "{}",
        text.len()
    );
    text
}

#[test]
fn a_materials_file_at_its_byte_limit_reads_within_the_documented_bound() {
    let nested = format!("{}0{}", r#"{"a":"#.repeat(100), "}".repeat(100));
    let env = |rest: &str| format!(r#"{{"format":"ply.materials","schema_version":1,{rest}}}"#);
    let files: Vec<(&str, bool, String)> = vec![
        (
            "nested objects of one member, in a key the format does not have",
            false,
            at_the_limit(&env(r#""materials":[],"swatches":[],"x":[@]"#), &nested),
        ),
        (
            "nested objects of one member, in a record's key the format does not have",
            false,
            at_the_limit(
                &env(r#""materials":[{"id":"a","x":[@]}],"swatches":[]"#),
                &nested,
            ),
        ),
        (
            "nested objects of one member, in a record's notes",
            false,
            at_the_limit(
                &env(r#""materials":[],"swatches":[{"id":"a","notes":[@]}]"#),
                &nested,
            ),
        ),
        (
            "nested objects of one member, as a material's fibers",
            false,
            at_the_limit(
                &env(r#""materials":[{"id":"a","fibers":[@]}],"swatches":[]"#),
                &nested,
            ),
        ),
        (
            "empty objects as materials, past the record count",
            false,
            at_the_limit(&env(r#""materials":[@],"swatches":[]"#), "{}"),
        ),
        (
            "empty texts in a key the format does not have",
            false,
            at_the_limit(&env(r#""materials":[],"swatches":[],"x":[@]"#), r#""""#),
        ),
        (
            "the smallest fibers, written as lists",
            false,
            at_the_limit(
                &env(r#""materials":[{"id":"a","fibers":[@]}],"swatches":[]"#),
                r#"["",null]"#,
            ),
        ),
        (
            "the smallest swatch yarns, written as lists",
            false,
            at_the_limit(
                &env(r#""materials":[],"swatches":[{"id":"a","yarns":[@]}]"#),
                r#"[null,"",null]"#,
            ),
        ),
        (
            "the smallest swatches, written as lists, in an earlier repeat of the key",
            true,
            at_the_limit(
                &env(r#""materials":[],"swatches":[@],"swatches":[]"#),
                r#"["a"]"#,
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
