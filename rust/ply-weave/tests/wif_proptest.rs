//! Property-based hardening of WIF (M3 Phase 4): the write->parse round-trip is identity over
//! arbitrary valid drafts, and `parse` never panics on arbitrary input (the documented leniency).

use ply_common::{Color, Unit};
use ply_weave::draft::*;
use ply_weave::wif::{parse, write};
use proptest::prelude::*;

/// A strategy for VALID, round-trippable drafts. Constraints that keep `parse(write(d)) == d` a
/// genuine identity (not a normalization artifact): `shafts >= 1` (so parse never rejects), a
/// non-empty whitespace-free `name` (an empty name writes no `[TEXT]` and parse defaults to
/// "Untitled"), `notes` with no spaces (parse trims each line), `>= 1` palette color, and every
/// list sized to its header count. Retained sections are VENDOR-prefixed; pick roles, shuttles, starting
/// sides, and strands are arbitrary (an all-unknown draw is normalized to the empty "nothing recorded"
/// form a read returns), and shot groups are drawn at random and kept where they are sound.
fn arb_draft() -> impl Strategy<Value = Draft> {
    (1u16..=6, 1u16..=6, 0usize..=10, 0usize..=10, 1usize..=4).prop_flat_map(
        |(shafts, treadles, ends, picks, ncol)| {
            (
                "[a-zA-Z0-9]{1,8}",             // name
                "[a-zA-Z0-9\n]{0,12}",          // notes
                (any::<bool>(), any::<bool>()), // (rising, inches)
                // 0..=2 shafts per end exercises the skip-empty write + Threads-count recovery path
                // AND multi-shaft ends.
                prop::collection::vec(prop::collection::vec(1u16..=shafts, 0..=2), ends), // threading
                prop::collection::vec(
                    prop::collection::vec(1u16..=shafts, 0..=shafts as usize),
                    treadles as usize,
                ), // tie-up rows
                prop::collection::vec(1u16..=treadles, picks), // treadling
                prop::collection::vec((any::<u8>(), any::<u8>(), any::<u8>()), ncol), // palette
                prop::collection::vec(0usize..ncol, ends),     // warp colors
                prop::collection::vec(0usize..ncol, picks),    // weft colors
                // Retained unmodeled sections: VENDOR-prefixed names (never a modeled section),
                // whitespace-free keys/values (so trim/line-trim leave them untouched).
                prop::collection::vec(
                    (
                        "VENDOR[A-Z0-9]{0,5}",
                        prop::collection::vec(("[A-Z0-9]{1,4}", "[a-zA-Z0-9]{0,6}"), 0..=3),
                    ),
                    0..=2,
                ), // retained
                // Pick roles: one per pick drawn from all five (Unknown included), so the sparse
                // private-section write and the fingerprint-checked read are both exercised.
                prop::collection::vec(0u8..5, picks),
                // Weft work: per-pick shuttles (0 = unknown), starting sides, per-pick strands, and
                // candidate shot groups (kept only where they are sound for the drawn sheds).
                (
                    prop::collection::vec(0u8..=3, picks),
                    prop::collection::vec((1u8..=3, any::<bool>()), 0..=3),
                    prop::collection::vec(1u8..=4, picks),
                    prop::collection::vec((0usize..10, 2usize..=3), 0..=3),
                ),
            )
                .prop_map(
                    move |(
                        name,
                        notes,
                        (rising, inches),
                        threading,
                        tieup,
                        treadling,
                        palette,
                        warp,
                        weft,
                        retained,
                        roles,
                        (shuttles, starts, strands, groups),
                    )| {
                        let mut d = Draft {
                            name,
                            shafts,
                            treadles,
                            shed: if rising {
                                ShedType::Rising
                            } else {
                                ShedType::Sinking
                            },
                            unit: if inches {
                                Unit::Inches
                            } else {
                                Unit::Centimeters
                            },
                            threading: Threading(
                                threading
                                    .into_iter()
                                    .map(|row| row.into_iter().map(ShaftId).collect())
                                    .collect(),
                            ),
                            drive: Drive::Treadled {
                                tieup: TieUp(
                                    tieup
                                        .into_iter()
                                        .map(|row| row.into_iter().map(ShaftId).collect())
                                        .collect(),
                                ),
                                treadling: Treadling(
                                    treadling.into_iter().map(|t| vec![TreadleId(t)]).collect(),
                                ),
                            },
                            colors: ColorPlan {
                                palette: palette
                                    .into_iter()
                                    .map(|(r, g, b)| Color::rgb(r, g, b))
                                    .collect(),
                                warp,
                                weft,
                            },
                            // Thickness is empty here (a uniform grid); its write->parse round-trip has
                            // its own unit test, and arbitrary f32 formatting is out of scope for this
                            // identity property.
                            warp_thickness: Vec::new(),
                            weft_thickness: Vec::new(),
                            notes,
                            retained: retained
                                .into_iter()
                                .map(|(rname, entries)| RetainedSection {
                                    name: rname,
                                    entries,
                                })
                                .collect(),
                            // "No known role" is stored as EMPTY (that is what a read of a file with no
                            // roles section gives back), so normalize an all-Unknown draw to it.
                            pick_roles: {
                                let r: Vec<PickRole> = roles
                                    .into_iter()
                                    .map(|k| match k {
                                        1 => PickRole::Pattern,
                                        2 => PickRole::Tabby,
                                        3 => PickRole::TopLayer,
                                        4 => PickRole::BottomLayer,
                                        _ => PickRole::Unknown,
                                    })
                                    .collect();
                                if r.iter().all(|&x| x == PickRole::Unknown) {
                                    Vec::new()
                                } else {
                                    r
                                }
                            },
                            // Nothing recorded is stored EMPTY, so all-unknown shuttles and all-one
                            // strands normalize to it, as a read returns them.
                            weft_work: WeftWork {
                                shuttles: if shuttles.iter().all(|&s| s == 0) {
                                    Vec::new()
                                } else {
                                    shuttles
                                        .into_iter()
                                        .map(|s| (s > 0).then_some(ShuttleId(s)))
                                        .collect()
                                },
                                shuttle_starts: starts
                                    .into_iter()
                                    .map(|(s, left)| {
                                        (ShuttleId(s), if left { Side::Left } else { Side::Right })
                                    })
                                    .collect(),
                                strands: if strands.iter().all(|&n| n == 1) {
                                    Vec::new()
                                } else {
                                    strands
                                },
                                shot_groups: groups
                                    .into_iter()
                                    .map(|(start, picks)| ShotGroup { start, picks })
                                    .collect(),
                            },
                        };
                        // Only sound groups (inside the picks, one shed, no overlap) are what Ply writes.
                        d.weft_work.shot_groups = d.sound_shot_groups();
                        d
                    },
                )
        },
    )
}

proptest! {
    /// `parse(write(d)) == d` for arbitrary valid drafts — the WIF round-trip is identity.
    #[test]
    fn write_then_parse_is_identity(d in arb_draft()) {
        let back = parse(&write(&d)).expect("a generated draft writes parseable WIF");
        prop_assert_eq!(back, d);
    }

    /// `parse` NEVER panics on arbitrary text (it returns Ok or Err — the documented leniency).
    #[test]
    fn parse_never_panics(s in ".*") {
        let _ = parse(&s);
    }

    /// ...nor on arbitrary bytes read as lossy UTF-8.
    #[test]
    fn parse_never_panics_on_bytes(bytes in prop::collection::vec(any::<u8>(), 0..256)) {
        let _ = parse(&String::from_utf8_lossy(&bytes));
    }
}

/// A regression corpus of adversarial inputs that must parse-or-error without panicking.
#[test]
fn parser_corpus_never_panics() {
    for s in [
        "",
        "[WEAVING]",
        "[WEAVING]\nShafts=99999999999999999999", // numeric overflow -> defaults, not panic
        "[THREADING]\n1=",                        // empty value
        "[THREADING]\n=5",                        // empty key
        "[WARP]\nThreads=-1",                     // negative count
        "[COLOR TABLE]\n1=999,999,999",           // out-of-range channels
        "[COLOR PALETTE]\nRange=0\n[COLOR TABLE]\n1=1,2,3", // Range 0 (division guard)
        "[TIEUP]\nx=y",                           // non-numeric key/value
        "]]][[[==",                               // malformed brackets/equals
        "[NOTES]\n1=a\n2=b\n",                    // trailing newline
        ";[WEAVING]\nShafts=4",                   // comment line
        // Unbounded-allocation guards: a sparse high numeric key or a huge `Threads=` count would,
        // uncapped, request a multi-GB Vec and ABORT (uncatchable). These must parse-or-error instead.
        "[WEAVING]\nShafts=2\n[THREADING]\n4000000000=1", // 4-billion sparse key (dropped)
        "[COLOR TABLE]\n3000000000=1,2,3",                // huge key via parse_color_table
        "[WEAVING]\nShafts=2\n[WARP]\nThreads=200000000\n[THREADING]\n1=1\n2=2", // huge Threads= count
    ] {
        let _ = parse(s);
    }
}
