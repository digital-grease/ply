//! Progress tracking primitives every craft shares (roadmap M8-05, ADR 0023).
//!
//! A crafter's place is kept in their craft's own work unit (a weaving pick, a knitting chart row
//! or ledger line, later a nalbinding recipe step or a tablet pick); this module holds no notion of
//! what a unit is. It gives the two things every craft needs to resume safely:
//!
//! - [`Fingerprint`], a stable 64-bit hash (FNV-1a with fixed constants) a craft feeds with each
//!   unit's identity. The fingerprint of a place is the hash of every unit up to and including it
//!   (its PREFIX), so any change at or before the place changes it, and a change after it does not.
//! - [`reconcile`], the one rule for comparing a saved place with the pattern as it is now: the same,
//!   changed after the place, changed at or before it, past the end, or nothing to work. It never
//!   moves a place on its own: a place past the end is shown at the last unit and reported, and a
//!   place found elsewhere is only suggested.
//!
//! Pure and allocation-light: the caller supplies the prefix of any unit through a closure, so a
//! long draft is hashed once, up to the saved place.

/// A stable 64-bit FNV-1a hash. The constants are fixed, so the same input gives the same value on
/// every platform and in every build: a fingerprint saved by one build is compared by another.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Fingerprint(u64);

impl Fingerprint {
    const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;

    /// An empty hash.
    pub fn new() -> Self {
        Fingerprint(Self::OFFSET)
    }

    /// Feed raw bytes.
    pub fn bytes(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 ^= u64::from(b);
            self.0 = self.0.wrapping_mul(Self::PRIME);
        }
    }

    /// Feed a number (eight little-endian bytes, so 1 and 256 never collide by length).
    pub fn number(&mut self, v: u64) {
        self.bytes(&v.to_le_bytes());
    }

    /// Feed a text, prefixed by its length, so `("ab", "c")` and `("a", "bc")` differ.
    pub fn text(&mut self, s: &str) {
        self.number(s.len() as u64);
        self.bytes(s.as_bytes());
    }

    /// The hash so far.
    pub fn value(&self) -> u64 {
        self.0
    }

    /// The hash as 16 lowercase hexadecimal digits, as the progress file stores it.
    pub fn hex(&self) -> String {
        to_hex(self.0)
    }
}

impl Default for Fingerprint {
    fn default() -> Self {
        Fingerprint::new()
    }
}

/// `v` as 16 lowercase hexadecimal digits.
pub fn to_hex(v: u64) -> String {
    format!("{v:016x}")
}

/// A stored fingerprint read back: exactly 16 lowercase hexadecimal digits, or `None`.
pub fn parse_hex(s: &str) -> Option<u64> {
    if s.len() != 16
        || !s
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return None;
    }
    u64::from_str_radix(s, 16).ok()
}

/// What a place was saved against: how many units the pattern had, and the prefix fingerprint at
/// the place's unit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Basis {
    pub units: u64,
    pub prefix: u64,
}

/// How a saved place compares with the pattern as it is now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResumeStatus {
    /// The work up to the place is unchanged and so is the pattern's length: resume.
    Same,
    /// The work up to the place is unchanged, but units were added or removed after it (`was`: the
    /// unit count when the place was saved). Resume; there is nothing to check.
    LengthChanged { was: u64 },
    /// Something at or before the place changed (or the place was saved without a fingerprint): the
    /// place is shown at the same unit number, for the crafter to check.
    Changed,
    /// The place (`was`, a 0-based unit) is past the end of the pattern now: it is shown at the last
    /// unit, for the crafter to check.
    Clamped { was: u64 },
    /// The pattern has no units to work.
    Empty,
}

impl ResumeStatus {
    /// True when the crafter should check the place before working on (it is not where it was, or
    /// the work before it changed).
    pub fn needs_a_look(&self) -> bool {
        matches!(self, ResumeStatus::Changed | ResumeStatus::Clamped { .. })
    }
}

/// Where to resume: the 0-based unit to show, how it compares, and (only when the place needs a
/// look) a unit where the saved unit's identity is found now, to offer, never to apply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Resume {
    pub status: ResumeStatus,
    pub unit: u64,
    pub suggested: Option<u64>,
}

/// Compare a saved place (`saved_unit`, 0-based, with its `basis`) with a pattern of `units_now`
/// units. `prefix_now(u)` is the prefix fingerprint of unit `u` now (called only for a unit that
/// exists); `find()` looks for the saved unit's identity elsewhere (called only when the place needs
/// a look). Never panics; a suggestion is dropped when it is the unit already shown or past the end.
pub fn reconcile(
    saved_unit: u64,
    basis: Option<Basis>,
    units_now: u64,
    prefix_now: impl FnOnce(u64) -> u64,
    find: impl FnOnce() -> Option<u64>,
) -> Resume {
    if units_now == 0 {
        return Resume {
            status: ResumeStatus::Empty,
            unit: 0,
            suggested: None,
        };
    }
    let suggest = |shown: u64, found: Option<u64>| found.filter(|&f| f != shown && f < units_now);
    if saved_unit >= units_now {
        let shown = units_now - 1;
        return Resume {
            status: ResumeStatus::Clamped { was: saved_unit },
            unit: shown,
            suggested: suggest(shown, find()),
        };
    }
    match basis {
        Some(b) if prefix_now(saved_unit) == b.prefix => Resume {
            status: if b.units == units_now {
                ResumeStatus::Same
            } else {
                ResumeStatus::LengthChanged { was: b.units }
            },
            unit: saved_unit,
            suggested: None,
        },
        _ => Resume {
            status: ResumeStatus::Changed,
            unit: saved_unit,
            suggested: suggest(saved_unit, find()),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn prefixes(ids: &[&str]) -> Vec<u64> {
        let mut fp = Fingerprint::new();
        ids.iter()
            .map(|id| {
                fp.text(id);
                fp.value()
            })
            .collect()
    }

    /// The FNV-1a reference vectors: the constants are the published ones, so the value is stable.
    #[test]
    fn fingerprint_matches_the_fnv1a_reference() {
        let mut fp = Fingerprint::new();
        assert_eq!(fp.value(), 0xcbf2_9ce4_8422_2325);
        fp.bytes(b"a");
        assert_eq!(fp.value(), 0xaf63_dc4c_8601_ec8c);
        let mut fp = Fingerprint::new();
        fp.bytes(b"foobar");
        assert_eq!(fp.value(), 0x8594_4171_f739_67e8);
        assert_eq!(fp.hex(), "85944171f73967e8");
    }

    #[test]
    fn texts_are_length_prefixed() {
        let mut a = Fingerprint::new();
        a.text("ab");
        a.text("c");
        let mut b = Fingerprint::new();
        b.text("a");
        b.text("bc");
        assert_ne!(a.value(), b.value());
    }

    #[test]
    fn hex_round_trips_and_refuses_anything_else() {
        for v in [0, 1, u64::MAX, 0x0123_4567_89ab_cdef] {
            assert_eq!(parse_hex(&to_hex(v)), Some(v));
        }
        for bad in [
            "",
            "123",
            "0123456789ABCDEF",
            "0123456789abcdeg",
            "+123456789abcdef",
        ] {
            assert_eq!(parse_hex(bad), None, "{bad}");
        }
        assert_eq!(parse_hex("00000000000000000"), None, "17 digits");
    }

    #[test]
    fn the_same_work_resumes_where_it_was() {
        let p = prefixes(&["a", "b", "c"]);
        let basis = Basis {
            units: 3,
            prefix: p[1],
        };
        let r = reconcile(1, Some(basis), 3, |u| p[u as usize], || None);
        assert_eq!(r.status, ResumeStatus::Same);
        assert_eq!(r.unit, 1);
        assert!(!r.status.needs_a_look());
    }

    #[test]
    fn units_added_after_the_place_change_nothing_to_check() {
        let p = prefixes(&["a", "b", "c", "d"]);
        let basis = Basis {
            units: 3,
            prefix: p[1],
        };
        let r = reconcile(1, Some(basis), 4, |u| p[u as usize], || Some(3));
        assert_eq!(r.status, ResumeStatus::LengthChanged { was: 3 });
        assert_eq!((r.unit, r.suggested), (1, None));
        assert!(!r.status.needs_a_look());
    }

    #[test]
    fn a_change_before_the_place_needs_a_look_at_the_same_number() {
        let before = prefixes(&["a", "b", "c"]);
        let now = prefixes(&["a", "x", "b", "c"]);
        let basis = Basis {
            units: 3,
            prefix: before[1],
        };
        let r = reconcile(1, Some(basis), 4, |u| now[u as usize], || Some(2));
        assert_eq!(r.status, ResumeStatus::Changed);
        assert_eq!(r.unit, 1, "never moved");
        assert_eq!(r.suggested, Some(2), "the same unit found later is offered");
        assert!(r.status.needs_a_look());
    }

    #[test]
    fn a_place_past_the_end_is_clamped_and_reported() {
        let p = prefixes(&["a", "b"]);
        let basis = Basis {
            units: 5,
            prefix: 7,
        };
        let r = reconcile(4, Some(basis), 2, |u| p[u as usize], || None);
        assert_eq!(r.status, ResumeStatus::Clamped { was: 4 });
        assert_eq!(r.unit, 1);
        assert!(r.status.needs_a_look());
    }

    #[test]
    fn nothing_to_work_and_a_missing_basis() {
        let r = reconcile(3, None, 0, |_| unreachable!(), || unreachable!());
        assert_eq!(r.status, ResumeStatus::Empty);
        let r = reconcile(0, None, 2, |_| 1, || Some(0));
        assert_eq!(r.status, ResumeStatus::Changed);
        assert_eq!(r.suggested, None, "the unit shown is never also suggested");
    }

    #[test]
    fn a_suggestion_past_the_end_is_dropped() {
        let r = reconcile(9, None, 3, |_| 0, || Some(7));
        assert_eq!(r.suggested, None);
        let r = reconcile(9, None, 3, |_| 0, || Some(0));
        assert_eq!(r.suggested, Some(0));
    }
}
