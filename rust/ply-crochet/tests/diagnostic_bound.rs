//! Diagnostics are bounded where they are made, not only where they are listed: a pattern that
//! raises a million findings of one code keeps at most `max_diagnostics_per_code` of them (and one
//! `crochet.list_capped` counting the rest), and `try_resolve` builds none it would throw away. A
//! counting allocator measures the peak heap of `validate` and `try_resolve_all` on the shapes that
//! cost the most: a row of a million skips past the end, three such rows, repeats that each list 64
//! left-over positions, and a million structural errors across 100 layers. The legend collision check
//! is timed on 512 entries with 10,000-byte names and abbreviations.
//!
//! One test, so nothing else allocates while it is measured.
//!
//! Run: `cargo test -p ply-crochet --release --test diagnostic_bound -- --nocapture`

mod common;

use common::*;
use ply_crochet::*;
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

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

/// Room for the kept diagnostics of a few codes (each at most 1,000, with a message and a listing of
/// at most 64 positions) and one layer's working state.
const BOUND: usize = 16 * MIB;

fn peak_added<T>(f: impl FnOnce() -> T) -> (T, usize) {
    let base = NOW.load(Ordering::SeqCst);
    PEAK.store(base, Ordering::SeqCst);
    let out = f();
    (out, PEAK.load(Ordering::SeqCst).saturating_sub(base))
}

/// Row 1 of 5 stitches, then `rows` rows of `work`.
fn over_five(rows: usize, work: impl Fn() -> Vec<Instr>) -> CrochetPattern {
    let mut layers = vec![(
        row(vec![
            Instr::start_from_foundation(1, CountsAs::Nothing),
            Instr::to_end(vec![st(B0, nch())]),
        ]),
        None,
    )];
    for _ in 0..rows {
        layers.push((row(work()), None));
    }
    piece(PieceStart::FoundationChain(6), layers)
}

fn measure(name: &str, p: &CrochetPattern, code: CrochetCode) {
    let (ds, peak) = peak_added(|| validate(p));
    let kept = ds.iter().filter(|d| d.code == code).count();
    let capped = ds.iter().any(|d| {
        d.code == CrochetCode::ListCapped
            && matches!(d.detail, Detail::Omitted { code: c, .. } if c == code)
    });
    eprintln!(
        "{name}: validate kept {kept} of {}, peak {:.1} MiB",
        code.as_str(),
        peak as f64 / MIB as f64
    );
    assert_eq!(kept, MAX_DIAGNOSTICS_PER_CODE, "{name}");
    assert!(capped, "{name}: the rest are counted");
    assert!(peak < BOUND, "{name}: validate peaked at {peak} bytes");
    drop(ds);
    let (r, peak) = peak_added(|| try_resolve_all(p, &CrochetLimits::DEFAULT));
    eprintln!(
        "{name}: try_resolve_all peak {:.1} MiB",
        peak as f64 / MIB as f64
    );
    assert!(
        peak < BOUND,
        "{name}: try_resolve_all peaked at {peak} bytes"
    );
    drop(r);
}

#[test]
fn diagnostics_are_bounded_where_they_are_made() {
    // A row of a million skips, all but the first five past the end.
    let skips = || vec![ch_none(1), Instr::times(1_000_000, vec![sk(1)])];
    let p = over_five(1, skips);
    measure("1 row of skips", &p, CrochetCode::AnchorPastEnd);
    let p = over_five(3, skips);
    measure("3 rows of skips", &p, CrochetCode::AnchorPastEnd);

    // Each repeat lists 64 of its 100 left-over positions.
    let mut layers = vec![(
        row(vec![
            Instr::start_from_foundation(1, CountsAs::Nothing),
            Instr::to_end(vec![st(B0, nch())]),
        ]),
        None,
    )];
    layers.push((
        row(vec![
            ch_none(1),
            Instr::times(200_000, vec![Instr::to_last(100_000, vec![sk(1)])]),
        ]),
        None,
    ));
    let p = piece(PieceStart::FoundationChain(101), layers);
    measure("repeats that do not fit", &p, CrochetCode::RepeatDoesNotFit);

    // A million structural errors: 100 layers of 9,999 skips of 0.
    let p = over_five(99, || {
        let mut w = vec![ch_none(1)];
        w.extend((0..9_999).map(|_| Instr::skip(0, PosKind::Stitch)));
        w
    });
    let (ds, peak) = peak_added(|| validate(&p));
    eprintln!(
        "1M repeat_zero: kept {}, peak {:.1} MiB",
        ds.len(),
        peak as f64 / MIB as f64
    );
    assert_eq!(
        ds.iter()
            .filter(|d| d.code == CrochetCode::RepeatZero)
            .count(),
        MAX_DIAGNOSTICS_PER_CODE
    );
    assert!(
        peak < BOUND,
        "1M repeat_zero: validate peaked at {peak} bytes"
    );
    drop(ds);
    let (r, peak) = peak_added(|| try_resolve_all(&p, &CrochetLimits::DEFAULT));
    match &r {
        Err(CrochetError::Invalid(ds)) => assert!(ds.len() <= MAX_DIAGNOSTICS_PER_CODE + 1),
        other => panic!("{other:?}"),
    }
    assert!(
        peak < BOUND,
        "1M repeat_zero: try_resolve peaked at {peak} bytes"
    );
    drop(r);

    // The legend collision check on 512 entries with 10,000-byte words.
    let mut p = over_five(1, || vec![ch_none(1), Instr::to_end(vec![st(B0, ns())])]);
    for e in 0..MAX_LEGEND_ENTRIES {
        let word = format!("{e:05}{}", "x".repeat(MAX_TEXT_BYTES - 5));
        p.legend.push(LegendEntry {
            id: LegendId::new(format!("e{e}")),
            name: word.clone(),
            abbreviation: word,
            body: vec![sts(B0, Target::UseSite, 2)],
        });
    }
    let t = Instant::now();
    let ds = validate(&p);
    let took = t.elapsed();
    eprintln!("512 long legend entries: validate took {took:?}");
    assert!(ds.is_empty(), "{:?}", keys(&ds));
    assert!(took < Duration::from_secs(3), "took {took:?}");
    let t = Instant::now();
    let _ = try_resolve_all(&p, &CrochetLimits::DEFAULT).unwrap();
    assert!(t.elapsed() < Duration::from_secs(3));
}
