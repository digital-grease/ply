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
/// list sized to its header count. `retained` is empty here (its round-trip has its own unit test).
fn arb_draft() -> impl Strategy<Value = Draft> {
    (1u16..=6, 1u16..=6, 0usize..=10, 0usize..=10, 1usize..=4).prop_flat_map(
        |(shafts, treadles, ends, picks, ncol)| {
            (
                "[a-zA-Z0-9]{1,8}",                                              // name
                "[a-zA-Z0-9\n]{0,12}",                                          // notes
                (any::<bool>(), any::<bool>()),                                 // (rising, inches)
                // 0..=2 shafts per end exercises the skip-empty write + Threads-count recovery path
                // AND multi-shaft ends.
                prop::collection::vec(prop::collection::vec(1u16..=shafts, 0..=2), ends), // threading
                prop::collection::vec(
                    prop::collection::vec(1u16..=shafts, 0..=shafts as usize),
                    treadles as usize,
                ),                                                              // tie-up rows
                prop::collection::vec(1u16..=treadles, picks),                  // treadling
                prop::collection::vec((any::<u8>(), any::<u8>(), any::<u8>()), ncol), // palette
                prop::collection::vec(0usize..ncol, ends),                      // warp colors
                prop::collection::vec(0usize..ncol, picks),                     // weft colors
                // Retained unmodeled sections: VENDOR-prefixed names (never a modeled section),
                // whitespace-free keys/values (so trim/line-trim leave them untouched).
                prop::collection::vec(
                    (
                        "VENDOR[A-Z0-9]{0,5}",
                        prop::collection::vec(("[A-Z0-9]{1,4}", "[a-zA-Z0-9]{0,6}"), 0..=3),
                    ),
                    0..=2,
                ),                                                              // retained
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
                    )| Draft {
                        name,
                        shafts,
                        treadles,
                        shed: if rising { ShedType::Rising } else { ShedType::Sinking },
                        unit: if inches { Unit::Inches } else { Unit::Centimeters },
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
                            .map(|(rname, entries)| RetainedSection { name: rname, entries })
                            .collect(),
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
        "[NOTES]\n1=a\n2=b\n",                     // trailing newline
        ";[WEAVING]\nShafts=4",                    // comment line
    ] {
        let _ = parse(s);
    }
}
