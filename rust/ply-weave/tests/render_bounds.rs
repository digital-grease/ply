//! Allocation evidence for the render budget (M7-01).
//!
//! A WIF file is untrusted input. Before M7-01, a 300-byte file declaring the largest draft the
//! parser accepts (100,000 x 100,000) made the renderer ask for about 160 GB before any size check.
//! A counting global allocator measures the bytes each call requests, so these assertions prove the
//! budget is enforced BEFORE allocating, not merely that an error comes back eventually.
//!
//! Everything runs inside ONE `#[test]` so no other test thread perturbs the shared counter.

use ply_weave::{
    fit_cell_px, fit_region_cell_px, structure, try_render_region, try_render_rgba_with, wif,
    DrawdownRegion, RenderError, RenderLimits, RenderOptions,
};
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

struct Counting;

static REQUESTED: AtomicUsize = AtomicUsize::new(0);

// SAFETY: every call forwards unchanged to the system allocator; the counter only observes sizes.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        REQUESTED.fetch_add(layout.size(), Ordering::Relaxed);
        System.alloc(layout)
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        REQUESTED.fetch_add(layout.size(), Ordering::Relaxed);
        System.alloc_zeroed(layout)
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout)
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        REQUESTED.fetch_add(new_size, Ordering::Relaxed);
        System.realloc(ptr, layout, new_size)
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

/// Run `f`, returning its result and the total bytes it asked the allocator for.
fn measure<T>(f: impl FnOnce() -> T) -> (T, usize) {
    let before = REQUESTED.load(Ordering::SeqCst);
    let out = f();
    (out, REQUESTED.load(Ordering::SeqCst) - before)
}

/// A tiny WIF whose `Threads=` counts claim ten million ends and picks; the parser clamps each
/// axis to `MAX_THREADS` (100,000), leaving a draft of ten billion intersections.
const HUGE_WIF: &str = "[WIF]\nVersion=1.1\n[WEAVING]\nShafts=2\nTreadles=2\nRising Shed=true\n\
[WARP]\nThreads=10000000\n[WEFT]\nThreads=10000000\n[THREADING]\n1=1\n[TIEUP]\n1=1\n\
[TREADLING]\n1=1\n";

const KIB: usize = 1024;
const MIB: usize = 1024 * KIB;

#[test]
fn render_budget_is_enforced_before_allocating() {
    let limits = RenderLimits::DEFAULT;
    let opts = RenderOptions::default();

    // 1. The crafted file: refused with ZERO sizable allocation (the old path requested ~160 GB).
    let huge = wif::parse(HUGE_WIF).expect("the crafted WIF is syntactically valid");
    assert_eq!((huge.ends(), huge.picks()), (100_000, 100_000));
    let (r, bytes) = measure(|| try_render_rgba_with(&huge, 12, &opts, &limits));
    assert!(matches!(r, Err(RenderError::TooManyCells { .. })), "{r:?}");
    assert!(bytes < 4 * KIB, "refusal allocated {bytes} bytes");
    let (r, bytes) = measure(|| fit_cell_px(&huge, 12, &limits));
    assert!(matches!(r, Err(RenderError::TooManyCells { .. })), "{r:?}");
    assert!(bytes < 4 * KIB, "fit refusal allocated {bytes} bytes");

    // 2. A realistic large draft at the editor's 12 px: the raster check fails after sizing only the
    //    per-thread extents (linear in ends + picks), not the 576 MB raster.
    let big = structure::plain_weave(1000, 1000);
    let (r, bytes) = measure(|| try_render_rgba_with(&big, 12, &opts, &limits));
    assert!(
        matches!(r, Err(RenderError::RasterTooLarge { .. })),
        "{r:?}"
    );
    assert!(bytes < 64 * KIB, "raster refusal allocated {bytes} bytes");

    // 3. The same draft at the fitted pitch renders, and the whole render stays within the budget:
    //    the 64 MiB raster cap plus one byte per intersection and small per-thread vectors.
    let px = fit_cell_px(&big, 12, &limits).expect("a 1000 x 1000 draft fits at a smaller pitch");
    assert_eq!(px, 4);
    let (img, bytes) = measure(|| try_render_rgba_with(&big, px, &opts, &limits));
    let img = img.expect("fitted render succeeds");
    assert_eq!((img.width, img.height), (4000, 4000));
    assert!(
        bytes <= limits.max_raster_bytes + 2 * MIB,
        "fitted render allocated {bytes} bytes"
    );

    // 4. Viewport rendering (M7-01, second slice): a phone-screen region of the crafted ten-billion-
    //    intersection draft renders, and asks only for region-sized buffers: its raster, its faces
    //    (plus the float margin), the 64 KiB shed lookup table, and per-thread extents. Nothing
    //    scales with the whole draft. All overlays on, so every buffer the render can use is used.
    let all_on = RenderOptions {
        gridlines: true,
        float_threshold: 5,
        thread_texture: true,
    };
    for region in [
        DrawdownRegion::new(50_000..50_064, 70_000..70_048), // the middle of the cloth
        DrawdownRegion::new(99_936..100_000, 99_952..100_000), // the far corner
        DrawdownRegion::new(0..64, 0..48),                   // end 1, pick 1
    ] {
        let (px, bytes) = measure(|| fit_region_cell_px(&huge, &region, 12, &limits));
        assert_eq!(px, Ok(12));
        assert!(bytes < 4 * KIB, "fitting a region allocated {bytes} bytes");
        let raster = (64 * 12) * (48 * 12) * 4;
        let (img, bytes) = measure(|| try_render_region(&huge, &region, 12, &all_on, &limits));
        let img = img.expect("a viewport region of a huge draft renders");
        assert_eq!((img.width, img.height), (64 * 12, 48 * 12));
        assert_eq!(img.pixels.len(), raster);
        assert!(
            bytes <= raster + 256 * KIB,
            "region {region:?} allocated {bytes} bytes for a {raster}-byte raster"
        );
    }

    // 5. A region over the intersection budget is refused before allocating, like a whole draft.
    let (r, bytes) = measure(|| {
        try_render_region(
            &huge,
            &DrawdownRegion::new(0..3000, 0..3000),
            1,
            &opts,
            &limits,
        )
    });
    assert!(matches!(r, Err(RenderError::TooManyCells { .. })), "{r:?}");
    assert!(bytes < 4 * KIB, "region refusal allocated {bytes} bytes");
}
