//! One card's geometry (ADR 0018 sections 1 to 4): its holes, the four corner positions, the 8 legal
//! arrangements, threading direction, the quarter turns and the flip.
//!
//! Every card drawing in Ply is a side view from the weaver's right, band at the left:
//!
//! ```text
//!     near                 far
//!   NT o-----------------o FT     upper layer of the shed: the threads at NT and FT
//!      |       card      |
//!   NB o-----------------o FB     lower layer of the shed: the threads at NB and FB
//! ```
//!
//! A forward quarter turn moves the top edge away from the weaver (clockwise in that view): each
//! hole moves NT to FT to FB to NB to NT. Backward is the reverse.

use serde::{Deserialize, Serialize};
use std::fmt;

/// A card's holes, lettered A, B, C, D in order round the card, so A and C are diagonal, and so are
/// B and D. The letters are the weaver's names for the holes; where they sit is the arrangement.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Hole {
    A,
    B,
    C,
    D,
}

impl Hole {
    /// Every hole, in letter order.
    pub const ALL: [Hole; 4] = [Hole::A, Hole::B, Hole::C, Hole::D];

    /// 0 for A up to 3 for D.
    pub const fn index(self) -> usize {
        match self {
            Hole::A => 0,
            Hole::B => 1,
            Hole::C => 2,
            Hole::D => 3,
        }
    }

    /// The hole with this index (taken modulo 4).
    pub const fn from_index(i: usize) -> Hole {
        Hole::ALL[i % 4]
    }

    pub const fn letter(self) -> char {
        match self {
            Hole::A => 'A',
            Hole::B => 'B',
            Hole::C => 'C',
            Hole::D => 'D',
        }
    }

    /// The hole diagonally across the card (A and C, B and D).
    pub const fn diagonal(self) -> Hole {
        Hole::from_index(self.index() + 2)
    }
}

impl fmt::Display for Hole {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.letter())
    }
}

/// The four corners of a card used flat, named by where they are (never by a letter), seen from the
/// weaver's right.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Position {
    NearTop,
    FarTop,
    FarBottom,
    NearBottom,
}

impl Position {
    /// The corners in the order a forward turn moves a hole through them (NT, FT, FB, NB).
    pub const ALL: [Position; 4] = [
        Position::NearTop,
        Position::FarTop,
        Position::FarBottom,
        Position::NearBottom,
    ];

    /// 0 for NT up to 3 for NB (the order of [`Position::ALL`]).
    pub const fn index(self) -> usize {
        match self {
            Position::NearTop => 0,
            Position::FarTop => 1,
            Position::FarBottom => 2,
            Position::NearBottom => 3,
        }
    }

    /// The upper layer of the shed is NT and FT; the weft passes below them.
    pub const fn is_upper(self) -> bool {
        matches!(self, Position::NearTop | Position::FarTop)
    }

    /// The short name used in charts: NT, FT, FB or NB.
    pub const fn abbreviation(self) -> &'static str {
        match self {
            Position::NearTop => "NT",
            Position::FarTop => "FT",
            Position::FarBottom => "FB",
            Position::NearBottom => "NB",
        }
    }
}

/// Threading direction in the thread-path meaning (ADR 0018 section 3): seen from above with the
/// warp running up the page, each thread of an S-threaded card crosses the card like the middle
/// stroke of an S; Z is the mirror. It belongs to the card's current orientation, so a flip changes
/// it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ThreadingDirection {
    S,
    Z,
}

impl ThreadingDirection {
    /// The other direction, which a flip gives.
    pub const fn flipped(self) -> ThreadingDirection {
        match self {
            ThreadingDirection::S => ThreadingDirection::Z,
            ThreadingDirection::Z => ThreadingDirection::S,
        }
    }

    pub const fn letter(self) -> char {
        match self {
            ThreadingDirection::S => 'S',
            ThreadingDirection::Z => 'Z',
        }
    }
}

/// The hand of the cord a turned card weaves in one pick.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Twining {
    S,
    Z,
}

impl Twining {
    /// The twining a quarter turn weaves (ADR 0018 section 6): an S card turned forward or a Z card
    /// turned backward weaves Z; an S card turned backward or a Z card turned forward weaves S.
    pub const fn of(threading: ThreadingDirection, forward: bool) -> Twining {
        match (threading, forward) {
            (ThreadingDirection::S, true) | (ThreadingDirection::Z, false) => Twining::Z,
            (ThreadingDirection::S, false) | (ThreadingDirection::Z, true) => Twining::S,
        }
    }

    /// The twist ledger's step for one pick of this twining: Z (right-handed) is +1, S is -1.
    pub const fn quarters(self) -> i32 {
        match self {
            Twining::Z => 1,
            Twining::S => -1,
        }
    }

    pub const fn letter(self) -> char {
        match self {
            Twining::S => 'S',
            Twining::Z => 'Z',
        }
    }

    /// The stitch as drawn with the warp running up the page: `/` for Z, `\` for S (the same on
    /// both faces, since a twined cord has one hand from either side).
    pub const fn slant(self) -> char {
        match self {
            Twining::S => '\\',
            Twining::Z => '/',
        }
    }
}

/// What a card does for one pick (v1: one quarter turn or none).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Turn {
    /// A quarter turn with the top edge moving away from the weaver (`F`).
    Forward,
    /// A quarter turn with the top edge moving toward the weaver (`B`).
    Backward,
    /// Not turned (`I`).
    Idle,
    /// Something Ply does not model, such as a half turn (`?`); the pattern's words are kept with
    /// the pick. The card's arrangement, faces and twist are unknown from here.
    Unsupported,
}

impl Turn {
    /// The letter used in turn strings and charts.
    pub const fn letter(self) -> char {
        match self {
            Turn::Forward => 'F',
            Turn::Backward => 'B',
            Turn::Idle => 'I',
            Turn::Unsupported => '?',
        }
    }

    /// The turn for a chart letter (exactly `F`, `B`, `I` or `?`; nothing else, not even lower
    /// case, since sources disagree on what other marks mean).
    pub const fn from_letter(c: char) -> Option<Turn> {
        match c {
            'F' => Some(Turn::Forward),
            'B' => Some(Turn::Backward),
            'I' => Some(Turn::Idle),
            '?' => Some(Turn::Unsupported),
            _ => None,
        }
    }

    /// The same from a byte of a turn string.
    pub(crate) const fn from_byte(b: u8) -> Option<Turn> {
        match b {
            b'F' => Some(Turn::Forward),
            b'B' => Some(Turn::Backward),
            b'I' => Some(Turn::Idle),
            b'?' => Some(Turn::Unsupported),
            _ => None,
        }
    }
}

/// One face of the band.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Face {
    /// The face the weaver sees from their seat; its threads cross the top edge of the cards.
    Top,
    /// The other face; its threads cross the bottom edge of the cards.
    Back,
}

impl Face {
    /// The card indices (0-based) in the order a face is drawn (ADR 0018 section 8): the top face
    /// has card 1 at the left; the back, turned over sideways, has card 1 at the right.
    pub fn display_order(self, cards: usize) -> impl Iterator<Item = usize> {
        let top = self == Face::Top;
        (0..cards).map(move |i| if top { i } else { cards - 1 - i })
    }

    pub const fn name(self) -> &'static str {
        match self {
            Face::Top => "top face",
            Face::Back => "back",
        }
    }
}

/// Which hole is at each corner, as a file or the weaver states it: any four holes, legal or not.
/// [`CardPosition::try_from_arrangement`] accepts exactly the 8 legal ones.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Arrangement {
    pub near_top: Hole,
    pub far_top: Hole,
    pub far_bottom: Hole,
    pub near_bottom: Hole,
}

impl Arrangement {
    pub const fn new(nt: Hole, ft: Hole, fb: Hole, nb: Hole) -> Arrangement {
        Arrangement {
            near_top: nt,
            far_top: ft,
            far_bottom: fb,
            near_bottom: nb,
        }
    }

    /// The holes in corner order NT, FT, FB, NB.
    pub const fn holes(self) -> [Hole; 4] {
        [
            self.near_top,
            self.far_top,
            self.far_bottom,
            self.near_bottom,
        ]
    }
}

/// Why an [`Arrangement`] is not one of the 8 a real card can take.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind")]
pub enum IllegalArrangement {
    /// A hole is named at two corners (and so another is missing).
    Repeated { hole: Hole, missing: Hole },
    /// Two diagonal holes are named on one edge of the card (the first corner pair, in NT, FT, FB,
    /// NB order, that holds them).
    DiagonalOnEdge {
        first: Position,
        second: Position,
        holes: (Hole, Hole),
    },
}

/// A legal arrangement: reading the corners NT, FT, FB, NB gives the four letters in cyclic order,
/// forwards or backwards (4 rotations times 2 ways round).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CardPosition {
    at: [Hole; 4],
}

impl CardPosition {
    /// Ply home: A at NT, D at FT, C at FB, B at NB. Seen from the weaver's right the letters run
    /// A, B, C, D counterclockwise from the near top, so forward turns bring A, B, C, D across the
    /// top.
    pub const PLY_HOME: CardPosition = CardPosition {
        at: [Hole::A, Hole::D, Hole::C, Hole::B],
    };

    /// The printed-face-right preset (a card lettered clockwise on its printed face, printed face to
    /// the right, A and D on top with D nearest the weaver): D at NT, A at FT, B at FB, C at NB.
    /// Forward turns bring D, C, B, A across the top.
    pub const PRINTED_FACE_RIGHT: CardPosition = CardPosition {
        at: [Hole::D, Hole::A, Hole::B, Hole::C],
    };

    pub fn new(nt: Hole, ft: Hole, fb: Hole, nb: Hole) -> Result<CardPosition, IllegalArrangement> {
        CardPosition::try_from_arrangement(Arrangement::new(nt, ft, fb, nb))
    }

    pub const fn ply_home() -> CardPosition {
        CardPosition::PLY_HOME
    }

    /// Check an arrangement. A repeated letter is reported before a diagonal pair, since a
    /// repeated letter always also leaves a hole out.
    pub fn try_from_arrangement(a: Arrangement) -> Result<CardPosition, IllegalArrangement> {
        let at = a.holes();
        let mut seen = [false; 4];
        for h in at {
            if seen[h.index()] {
                let missing = Hole::ALL.into_iter().find(|m| !at.contains(m)).unwrap_or(h);
                return Err(IllegalArrangement::Repeated { hole: h, missing });
            }
            seen[h.index()] = true;
        }
        // Four distinct letters: legal iff every step round the corners moves the same way round
        // the lettering (+1 for each step, or -1 for each step).
        let step = |i: usize| (at[(i + 1) % 4].index() + 4 - at[i].index()) % 4;
        let first = step(0);
        if (first == 1 || first == 3) && (1..4).all(|i| step(i) == first) {
            return Ok(CardPosition { at });
        }
        // Some pair of neighbouring corners (one edge) holds two diagonal holes.
        for i in 0..4 {
            if step(i) == 2 {
                return Err(IllegalArrangement::DiagonalOnEdge {
                    first: Position::ALL[i],
                    second: Position::ALL[(i + 1) % 4],
                    holes: (at[i], at[(i + 1) % 4]),
                });
            }
        }
        // Unreachable for four distinct letters (steps of 1 and 3 that are not all equal force a
        // step of 2), but an error is still the safe answer.
        Err(IllegalArrangement::DiagonalOnEdge {
            first: Position::NearTop,
            second: Position::FarTop,
            holes: (at[0], at[1]),
        })
    }

    /// All 8 legal arrangements: Ply home and its three quarter turns forward, then the
    /// printed-face-right preset and its three quarter turns forward.
    pub fn all() -> [CardPosition; 8] {
        let mut out = [CardPosition::PLY_HOME; 8];
        let mut p = CardPosition::PLY_HOME;
        for slot in out.iter_mut().take(4) {
            *slot = p;
            p = p.forward();
        }
        let mut q = CardPosition::PRINTED_FACE_RIGHT;
        for slot in out.iter_mut().skip(4) {
            *slot = q;
            q = q.forward();
        }
        out
    }

    /// One quarter turn forward: NT to FT, FT to FB, FB to NB, NB to NT.
    pub const fn forward(self) -> CardPosition {
        let [nt, ft, fb, nb] = self.at;
        CardPosition {
            at: [nb, nt, ft, fb],
        }
    }

    /// One quarter turn backward: NT to NB, NB to FB, FB to FT, FT to NT.
    pub const fn backward(self) -> CardPosition {
        let [nt, ft, fb, nb] = self.at;
        CardPosition {
            at: [ft, fb, nb, nt],
        }
    }

    /// Half way round the card's vertical axis: NT and FT swap, NB and FB swap.
    pub const fn flipped(self) -> CardPosition {
        let [nt, ft, fb, nb] = self.at;
        CardPosition {
            at: [ft, nt, nb, fb],
        }
    }

    pub const fn hole_at(self, p: Position) -> Hole {
        self.at[p.index()]
    }

    /// Where `hole` is.
    pub fn position_of(self, hole: Hole) -> Position {
        let i = self.at.iter().position(|&h| h == hole).unwrap_or(0);
        Position::ALL[i]
    }

    /// Whether `hole` is in the upper layer of the shed (at NT or FT).
    pub fn is_upper(self, hole: Hole) -> bool {
        self.position_of(hole).is_upper()
    }

    pub const fn arrangement(self) -> Arrangement {
        let [nt, ft, fb, nb] = self.at;
        Arrangement::new(nt, ft, fb, nb)
    }

    /// The holes in corner order NT, FT, FB, NB.
    pub const fn holes(self) -> [Hole; 4] {
        self.at
    }

    /// The holes as chart text, "A D C B" (NT FT FB NB).
    pub fn chart(self) -> String {
        let [nt, ft, fb, nb] = self.at;
        format!("{nt} {ft} {fb} {nb}")
    }

    /// The thread that travels along the top edge in a turn (it shows on the top face), and the one
    /// that travels along the bottom edge (it shows on the back), for a turn from this position.
    /// Forward: the hole at NT crosses the top and the hole at FB the bottom; backward: the hole at
    /// FT crosses the top and the hole at NB the bottom.
    pub const fn crossing(self, forward: bool) -> (Hole, Hole) {
        let [nt, ft, fb, nb] = self.at;
        if forward {
            (nt, fb)
        } else {
            (ft, nb)
        }
    }
}

/// Written as its [`Arrangement`] (`near_top`, `far_top`, `far_bottom`, `near_bottom`).
impl Serialize for CardPosition {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        self.arrangement().serialize(s)
    }
}

/// Read as an [`Arrangement`], refusing the 16 illegal orders and any repeated hole.
impl<'de> Deserialize<'de> for CardPosition {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let a = Arrangement::deserialize(d)?;
        CardPosition::try_from_arrangement(a)
            .map_err(|_| serde::de::Error::custom("not one of the 8 legal card arrangements"))
    }
}

impl From<CardPosition> for Arrangement {
    fn from(p: CardPosition) -> Arrangement {
        p.arrangement()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use Hole::*;

    #[test]
    fn exactly_eight_of_the_twenty_four_orders_are_legal() {
        let mut legal = 0;
        let mut repeated = 0;
        let mut diagonal = 0;
        for a in Hole::ALL {
            for b in Hole::ALL {
                for c in Hole::ALL {
                    for d in Hole::ALL {
                        match CardPosition::new(a, b, c, d) {
                            Ok(_) => legal += 1,
                            Err(IllegalArrangement::Repeated { .. }) => repeated += 1,
                            Err(IllegalArrangement::DiagonalOnEdge { .. }) => diagonal += 1,
                        }
                    }
                }
            }
        }
        assert_eq!(legal, 8);
        assert_eq!(diagonal, 16);
        assert_eq!(repeated, 256 - 24);
        let all = CardPosition::all();
        for (i, p) in all.iter().enumerate() {
            assert!(all[..i].iter().all(|q| q != p), "duplicate {}", p.chart());
        }
    }

    #[test]
    fn turns_and_flip_from_ply_home_match_the_adr_drawings() {
        let home = CardPosition::ply_home();
        assert_eq!(home.chart(), "A D C B");
        assert_eq!(home.forward().chart(), "B A D C");
        assert_eq!(home.backward().chart(), "D C B A");
        assert_eq!(home.flipped().chart(), "D A B C");
        assert_eq!(home.flipped(), CardPosition::PRINTED_FACE_RIGHT);
        // Forward from home: A crosses the top (NT to FT), C the bottom (FB to NB).
        assert_eq!(home.crossing(true), (A, C));
        // Backward from home: D crosses the top (FT to NT), B the bottom (NB to FB).
        assert_eq!(home.crossing(false), (D, B));
    }

    #[test]
    fn diagonal_and_repeated_holes_are_named() {
        assert_eq!(
            CardPosition::new(A, C, B, D),
            Err(IllegalArrangement::DiagonalOnEdge {
                first: Position::NearTop,
                second: Position::FarTop,
                holes: (A, C),
            })
        );
        assert_eq!(
            CardPosition::new(A, A, C, B),
            Err(IllegalArrangement::Repeated {
                hole: A,
                missing: D
            })
        );
    }

    #[test]
    fn twining_table() {
        use ThreadingDirection as T;
        assert_eq!(Twining::of(T::S, true), Twining::Z);
        assert_eq!(Twining::of(T::S, false), Twining::S);
        assert_eq!(Twining::of(T::Z, true), Twining::S);
        assert_eq!(Twining::of(T::Z, false), Twining::Z);
        assert_eq!(Twining::Z.quarters(), 1);
        assert_eq!(Twining::S.quarters(), -1);
    }

    #[test]
    fn back_face_runs_right_to_left() {
        assert_eq!(Face::Top.display_order(3).collect::<Vec<_>>(), [0, 1, 2]);
        assert_eq!(Face::Back.display_order(3).collect::<Vec<_>>(), [2, 1, 0]);
        assert_eq!(Face::Back.display_order(0).count(), 0);
    }
}
