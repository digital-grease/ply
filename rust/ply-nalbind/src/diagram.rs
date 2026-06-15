//! Per-stitch structural loop diagram (the M6 tier-B visualization). Generated from a stitch's
//! parsed notation, NOT hand-drawn — published nalbinding diagrams are famously error-prone (the
//! Coppergate sock diagram drew an F3 where the text says F2, reprinted uncorrected for years), so a
//! diagram derived from validated data is the point.
//!
//! The engine emits an ABSTRACT vector model (unit coordinates, left-to-right); the Flutter
//! `CustomPainter` scales it to pixels and does the actual drawing. Each engaged step becomes a loop
//! glyph the working thread crosses OVER (drawn in front) or UNDER (drawn behind); skipped loops are
//! bypassed; `-` steps leave a gap; turns (`/`, `:`) become separators; connections become arrows
//! into the previous round below the baseline.

use serde::{Deserialize, Serialize};

use crate::stitch::{ConnSide, Step, StitchType};

/// How the working thread relates to one loop position.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LoopKind {
    /// Thread passes OVER (in front of) an engaged loop.
    OverEngaged,
    /// Thread passes UNDER (behind) an engaged loop.
    UnderEngaged,
    /// A skipped loop the thread passes over but does not engage (drawn faint).
    OverSkipped,
    /// A skipped loop the thread passes under but does not engage.
    UnderSkipped,
    /// A `-` step: no loop here, the thread simply continues.
    NoLoop,
}

/// One loop position along the working thread.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct LoopGlyph {
    pub x: f32,
    pub kind: LoopKind,
}

/// A connection arrow into the previous round, drawn below the baseline.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct ConnArrow {
    pub x: f32,
    pub side: ConnSide,
    pub count: u8,
}

/// The whole diagram in abstract units (1.0 = one loop slot). The renderer scales to pixels.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Diagram {
    pub width: f32,
    pub height: f32,
    /// The y of the working thread; loop arches rise above it, connections drop below.
    pub baseline: f32,
    pub loops: Vec<LoopGlyph>,
    /// x positions of the turn separators (one between each consecutive pass).
    pub turns: Vec<f32>,
    pub connections: Vec<ConnArrow>,
}

/// Build the structural diagram for [stitch].
pub fn diagram(stitch: &StitchType) -> Diagram {
    const SLOT: f32 = 1.0;
    const BASELINE: f32 = 1.6; // arch height above, connection arrow below
    const HEIGHT: f32 = 2.6;

    let mut loops = Vec::new();
    let mut turns = Vec::new();
    let mut x = 0.5;

    for (pi, pass) in stitch.passes.iter().enumerate() {
        if pi > 0 {
            // A turn separator sits in the gap before this pass begins.
            turns.push(x - SLOT / 2.0);
        }
        for step in &pass.steps {
            let kind = match step {
                Step::Over => LoopKind::OverEngaged,
                Step::Under => LoopKind::UnderEngaged,
                Step::SkippedOver => LoopKind::OverSkipped,
                Step::SkippedUnder => LoopKind::UnderSkipped,
                Step::NoEngage => LoopKind::NoLoop,
            };
            loops.push(LoopGlyph { x, kind });
            x += SLOT;
        }
    }

    // Connections trail after a small gap.
    let mut cx = x + SLOT / 2.0;
    let connections: Vec<ConnArrow> = stitch
        .connections
        .iter()
        .map(|c| {
            let arrow = ConnArrow { x: cx, side: c.side, count: c.count };
            cx += SLOT;
            arrow
        })
        .collect();

    let width = if connections.is_empty() { x } else { cx };
    Diagram { width: width.max(SLOT), height: HEIGHT, baseline: BASELINE, loops, turns, connections }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dictionary::builtin;
    use crate::notation;
    use crate::stitch::StitchType;

    fn parse(code: &str) -> StitchType {
        let (passes, connections) = notation::parse(code).unwrap();
        StitchType::anonymous(passes, connections)
    }

    #[test]
    fn one_loop_glyph_per_step_and_a_turn_between_passes() {
        let d = diagram(&parse("UO/UOO F1")); // 2 + 3 steps, 1 turn, 1 connection
        assert_eq!(d.loops.len(), 5);
        assert_eq!(d.turns.len(), 1, "one turn between the two passes");
        assert_eq!(d.connections.len(), 1);
        assert_eq!(d.loops[0].kind, LoopKind::UnderEngaged); // 'U'
        assert_eq!(d.loops[1].kind, LoopKind::OverEngaged); // 'O'
    }

    #[test]
    fn skipped_and_no_engage_map_to_faint_and_gap_glyphs() {
        let d = diagram(&parse("U(U)O-"));
        let kinds: Vec<_> = d.loops.iter().map(|l| l.kind).collect();
        assert_eq!(
            kinds,
            vec![
                LoopKind::UnderEngaged,
                LoopKind::UnderSkipped,
                LoopKind::OverEngaged,
                LoopKind::NoLoop
            ]
        );
    }

    #[test]
    fn multi_turn_has_two_turn_separators() {
        let d = diagram(&parse("U(U)O/UO:UOO B1 F1"));
        assert_eq!(d.turns.len(), 2, "two turns -> two separators");
        assert_eq!(d.connections.len(), 2);
    }

    #[test]
    fn every_builtin_produces_a_finite_nonempty_diagram() {
        for st in builtin() {
            let d = diagram(&st);
            assert!(d.width.is_finite() && d.width > 0.0, "{} width", st.name);
            assert!(d.height.is_finite() && d.height > 0.0, "{} height", st.name);
            assert!(!d.loops.is_empty(), "{} has loops", st.name);
            // loop x positions are strictly increasing and finite
            for w in d.loops.windows(2) {
                assert!(w[1].x > w[0].x && w[1].x.is_finite());
            }
        }
    }
}
