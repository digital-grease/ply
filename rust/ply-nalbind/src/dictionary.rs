//! The curated builtin stitch dictionary (~12 stitches). Each entry's `passes`/`connections` are
//! PARSED from a canonical Hansen string (so the dictionary also exercises the parser), with the
//! `a+b` thumb-loop alias, source-attributed published codes (sources genuinely disagree — see the
//! second code on several entries), alternate names, and a one-line description for the reference
//! screen + glossary.
//!
//! Codes are recorded "as published"; where sources differ we keep both rather than assert one
//! canonical string (see `docs/NALBIND_DESIGN.md`). These are a starting reference, not gospel.

use crate::notation;
use crate::stitch::{PublishedCode, StitchType, Twist};

fn s(
    name: &str,
    code: &str,
    thumb: Option<(u8, u8)>,
    aka: &[&str],
    codes: &[(&str, &str)],
    note: &str,
) -> StitchType {
    let (passes, connections) = notation::parse(code).expect("a builtin code must parse");
    StitchType {
        name: name.to_string(),
        passes,
        connections,
        thumb_loops: thumb,
        twist: Twist::Untwisted,
        also_known_as: aka.iter().map(|a| a.to_string()).collect(),
        codes: codes
            .iter()
            .map(|(c, src)| PublishedCode { code: c.to_string(), source: src.to_string() })
            .collect(),
        note: note.to_string(),
    }
}

/// The builtin stitch dictionary, in a rough simple-to-complex order.
pub fn builtin() -> Vec<StitchType> {
    vec![
        s(
            "Oslo",
            "UO/UOO F1",
            Some((1, 1)),
            &["Finnish 1+1"],
            &[("UO/UOO F1", "neulakintaat.fi"), ("UO/UOO F2", "some sources")],
            "The classic beginner stitch; the simplest two-pass structure.",
        ),
        s(
            "Mammen",
            "UOO/UUOO F2",
            Some((1, 2)),
            &["Finnish 1+2"],
            &[("UOO/UUOO F2", "neulakintaat.fi")],
            "A dense, common Viking-age stitch. Same loops as Korgen; only the F2 connection differs.",
        ),
        s(
            "Korgen",
            "UOO/UUOO F1",
            Some((1, 2)),
            &[],
            &[("UOO/UUOO F1", "neulakintaat.fi")],
            "Identical loop structure to Mammen; the F1 connection is the only difference.",
        ),
        s(
            "York",
            "UU/OOO F2",
            None,
            &["Coppergate", "Jorvik"],
            &[("UU/OOO F2", "Regia wiki"), ("UU/OOO F1", "some sources")],
            "A single-pass stitch from the Coppergate (York) finds. Sources give F1 or F2.",
        ),
        s(
            "Finnish",
            "UUOO/UUOOO F2",
            Some((2, 2)),
            &["Finnish 2+2"],
            &[("UUOO/UUOOO F2", "Kaukonen"), ("UUOO/UUOOO F1", "some sources")],
            "Two-pass, two-loop groups; a thick, warm fabric.",
        ),
        s(
            "Russian",
            "UUOOUU/OOUUOOO",
            Some((2, 2)),
            &["Russian 2+2+2"],
            &[("UUOOUU/OOUUOOO", "Kaukonen")],
            "A three-phase, very dense and decorative stitch.",
        ),
        s(
            "Dalby",
            "UOU/OUOO F1",
            None,
            &["Russian 1+1+1"],
            &[("UOU/OUOO F1", "neulakintaat.fi")],
            "A three-phase Russian-family stitch. Published strings vary between sources.",
        ),
        s(
            "Brodén",
            "UOOO/UUUOO F1",
            Some((1, 3)),
            &["Broden", "Finnish 1+3"],
            &[("UOOO/UUUOO F1", "neulakintaat.fi"), ("UOOO/UUUOO F2", "some sources")],
            "Extends Mammen by one loop group. Sources give F1 or F2.",
        ),
        s(
            "Åsle",
            "U(U)O/UO:UOO B1 F1",
            None,
            &["Asle"],
            &[("U(U)O/UO:UOO B1 F1", "neulakintaat.fi"), ("F1+1", "alt form")],
            "A 16-17th c. Swedish mitten stitch: two turns, a skipped loop, and a double connection.",
        ),
        s(
            "Coptic",
            "-/-O F1 B1",
            None,
            &["Tarim", "encircled looping"],
            &[("-/-O F1 B1", "neulakintaat.fi")],
            "Encircled looping that resembles knitting; found in the Tarim Basin, Peru, and Egypt.",
        ),
        s(
            "Danish",
            "O/UO F1",
            None,
            &[],
            &[("O/UO F1", "neulakintaat.fi")],
            "A simple stitch; a back-connected variant resists Hansen notation entirely.",
        ),
        s(
            "Saltdal",
            "UUU/OOOU F1",
            None,
            &[],
            &[("UUU/OOOU F1", "Regia wiki"), ("UUU/OOOU B1", "some sources")],
            "A single-pass variant; connection given as F1 or B1 depending on source.",
        ),
    ]
    .into_iter()
    .map(|st| if st.name == "Coptic" { StitchType { twist: Twist::Twisted, ..st } } else { st })
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stitch::{ConnSide, Connection};

    #[test]
    fn every_builtin_code_parses_and_has_metadata() {
        let dict = builtin();
        assert_eq!(dict.len(), 12);
        for st in &dict {
            assert!(!st.name.is_empty());
            assert!(!st.passes.is_empty(), "{} has no passes", st.name);
            assert!(!st.codes.is_empty(), "{} has no published code", st.name);
            assert!(!st.note.is_empty(), "{} has no description", st.name);
        }
    }

    #[test]
    fn mammen_and_korgen_share_skeleton_differ_by_connection() {
        let dict = builtin();
        let mammen = dict.iter().find(|s| s.name == "Mammen").unwrap();
        let korgen = dict.iter().find(|s| s.name == "Korgen").unwrap();
        assert_eq!(mammen.passes, korgen.passes, "same loop skeleton");
        assert_eq!(mammen.connections, vec![Connection::new(ConnSide::Front, 2)]);
        assert_eq!(korgen.connections, vec![Connection::new(ConnSide::Front, 1)]);
        assert_ne!(mammen.connections, korgen.connections, "identity is (skeleton, connection)");
    }

    #[test]
    fn asle_is_multi_turn_with_two_connections() {
        let dict = builtin();
        let asle = dict.iter().find(|s| s.name == "Åsle").unwrap();
        assert_eq!(asle.passes.len(), 3, "two turns -> three passes");
        assert_eq!(asle.connections.len(), 2, "B1 + F1");
    }

    #[test]
    fn coptic_is_twisted() {
        let dict = builtin();
        let coptic = dict.iter().find(|s| s.name == "Coptic").unwrap();
        assert_eq!(coptic.twist, Twist::Twisted);
    }
}
