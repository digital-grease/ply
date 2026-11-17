//! `CraftKind::TabletWeaving` (M10-02, ADR 0018): its serde name is the sidecar's `craft` value, and
//! it is not a swatch craft at `materials.json` schema version 1. A build before it reads an unknown
//! craft as an unreadable file and sets the whole file aside (ADR 0016), so this build never writes
//! the value there and never reads it.
//!
//! Run: `cargo test -p ply-common --test craft_kind`

use ply_common::materials::Swatch;
use ply_common::materials_file::{read, write, MaterialLibrary, MaterialsFileError};
use ply_common::CraftKind;

#[test]
fn the_sidecar_name_is_the_serde_name() {
    assert_eq!(
        serde_json::to_string(&CraftKind::TabletWeaving).unwrap(),
        "\"TabletWeaving\""
    );
    let back: CraftKind = serde_json::from_str("\"TabletWeaving\"").unwrap();
    assert_eq!(back, CraftKind::TabletWeaving);
}

#[test]
fn a_tablet_weaving_swatch_is_never_written_or_read_at_version_1() {
    let mut swatch = Swatch::new("band-sample", "Band sample");
    swatch.craft = Some(CraftKind::TabletWeaving);
    let library = MaterialLibrary {
        materials: Vec::new(),
        swatches: vec![swatch.clone()],
    };
    assert!(matches!(
        write(&library),
        Err(MaterialsFileError::Malformed(_))
    ));
    // The same file written by hand: refused, as an older build would refuse it.
    swatch.craft = Some(CraftKind::Weaving);
    let text = write(&MaterialLibrary {
        materials: Vec::new(),
        swatches: vec![swatch],
    })
    .unwrap();
    let hand = text.replacen("\"craft\": \"weaving\"", "\"craft\": \"tablet_weaving\"", 1);
    assert_ne!(hand, text);
    assert!(matches!(read(&hand), Err(MaterialsFileError::Malformed(_))));
}
