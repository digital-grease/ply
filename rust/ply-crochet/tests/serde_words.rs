//! The leaf words serialize as ADR 0022 section 21 spells them, so the native document of M11-02 can
//! use them as they are; each reads back to itself, and an unknown word is refused.
//!
//! Run: `cargo test -p ply-crochet --test serde_words`

use ply_crochet::*;
use serde::de::DeserializeOwned;
use serde::Serialize;
use std::collections::BTreeMap;
use std::fmt::Debug;

fn words<T: Serialize + DeserializeOwned + PartialEq + Debug>(pairs: &[(T, &str)]) {
    for (value, word) in pairs {
        let json = serde_json::to_string(value).unwrap();
        assert_eq!(json, format!("\"{word}\""), "{value:?}");
        let back: T = serde_json::from_str(&json).unwrap();
        assert_eq!(&back, value);
    }
    assert!(serde_json::from_str::<T>("\"no_such_word\"").is_err());
}

#[test]
fn leaf_words_are_spelled_as_section_21() {
    words(&[
        (Basic::B0, "b0"),
        (Basic::B1H, "b1h"),
        (Basic::B1, "b1"),
        (Basic::B2, "b2"),
        (Basic::B3, "b3"),
    ]);
    assert!(
        serde_json::from_str::<Basic>("\"sc\"").is_err(),
        "a display name is no identity"
    );
    words(&[
        (Counted::Slip, "slip"),
        (Counted::Basic(Basic::B0), "b0"),
        (Counted::Basic(Basic::B1), "b1"),
    ]);
    words(&[
        (PosKind::Stitch, "stitch"),
        (PosKind::Space, "space"),
        (PosKind::Chain, "chain"),
        (PosKind::Any, "any"),
    ]);
    words(&[
        (Part::Both, "both"),
        (Part::FrontLoop, "front_loop"),
        (Part::BackLoop, "back_loop"),
    ]);
    words(&[
        (ChainPart::Unspecified, "unspecified"),
        (ChainPart::TopLoop, "top_loop"),
        (ChainPart::BackBump, "back_bump"),
    ]);
    words(&[
        (SlipRole::Stitch, "stitch"),
        (SlipRole::Join, "join"),
        (SlipRole::Travel, "travel"),
    ]);
    words(&[(Close::Join, "join"), (Close::Spiral, "spiral")]);
    words(&[
        (Terms::Us, "us"),
        (Terms::Uk, "uk"),
        (Terms::Unstated, "unstated"),
    ]);
    words(&[
        (FirstSide::Rs, "rs"),
        (FirstSide::Ws, "ws"),
        (FirstSide::NotStated, "not_stated"),
    ]);
    words(&[
        (StartChainRule::ByHeight, "by_height"),
        (StartChainRule::Never, "never"),
        (StartChainRule::Always, "always"),
    ]);
}

#[test]
fn a_count_by_identity_is_a_map_keyed_by_identity_words() {
    // Section 21: `"count": {"by_identity": {"b1": 18, "b0": 6}}`.
    let mut by_identity = BTreeMap::new();
    by_identity.insert(Counted::Basic(Basic::B1), 18u32);
    by_identity.insert(Counted::Basic(Basic::B0), 6u32);
    let json = serde_json::to_string(&by_identity).unwrap();
    assert_eq!(json, r#"{"b0":6,"b1":18}"#);
    let back: BTreeMap<Counted, u32> = serde_json::from_str(r#"{"b1": 18, "b0": 6}"#).unwrap();
    assert_eq!(back, by_identity);
    assert!(serde_json::from_str::<BTreeMap<Counted, u32>>(r#"{"dc": 1}"#).is_err());
    // And a derived count writes its identities the same way.
    let c = LayerCount {
        stitches: vec![(Counted::Basic(Basic::B1), 18), (Counted::Slip, 1)],
        spaces: vec![(2, 12)],
        not_checked: 0,
    };
    let json = serde_json::to_string(&c).unwrap();
    assert_eq!(
        json,
        r#"{"stitches":[["b1",18],["slip",1]],"spaces":[[2,12]],"not_checked":0}"#
    );
    assert_eq!(serde_json::from_str::<LayerCount>(&json).unwrap(), c);
}
