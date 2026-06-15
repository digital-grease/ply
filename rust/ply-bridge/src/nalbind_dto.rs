//! Transparently-mirrored NALBINDING DTOs (M6) — the nalbind analog of `dto.rs`/`knit_dto.rs`.
//!
//! The engine `StitchType`/`Diagram` cross FFI as these plain mirrored structs/enums so Dart can read
//! a stitch's structure directly (browse the dictionary, type a Hansen string, draw the loop diagram)
//! rather than juggle an opaque handle. All engine<->DTO conversions live HERE. `SeverityKind` is
//! REUSED from `dto.rs` so all three crafts share one Dart enum.

use ply_nalbind::diagram::{ConnArrow, Diagram, LoopGlyph, LoopKind};
use ply_nalbind::stitch::{ConnSide, Connection, Pass, PublishedCode, Step, StitchType, Twist};
use ply_nalbind::validate::{NalbindIssue, Severity};

use crate::dto::SeverityKind;

// --- enums (flat C-like; frb mirrors them as plain Dart enums) -------------------------------------

pub enum StepKind {
    Under,
    Over,
    SkippedUnder,
    SkippedOver,
    NoEngage,
}

pub enum ConnSideKind {
    Front,
    Back,
    Middle,
}

pub enum TwistKind {
    Untwisted,
    Twisted,
}

pub enum LoopKindDto {
    OverEngaged,
    UnderEngaged,
    OverSkipped,
    UnderSkipped,
    NoLoop,
}

// --- structs ---------------------------------------------------------------------------------------

pub struct PassDto {
    pub steps: Vec<StepKind>,
}

pub struct ConnectionDto {
    pub side: ConnSideKind,
    pub count: u8,
    pub extra: Option<String>,
}

/// The `a+b` thumb-loop alias (frb has no tuples, so a tiny struct).
pub struct ThumbLoopsDto {
    pub a: u8,
    pub b: u8,
}

pub struct PublishedCodeDto {
    pub code: String,
    pub source: String,
}

pub struct NalbindStitchDto {
    pub name: String,
    pub passes: Vec<PassDto>,
    pub connections: Vec<ConnectionDto>,
    pub thumb_loops: Option<ThumbLoopsDto>,
    pub twist: TwistKind,
    pub also_known_as: Vec<String>,
    pub codes: Vec<PublishedCodeDto>,
    pub note: String,
}

pub struct LoopGlyphDto {
    pub x: f32,
    pub kind: LoopKindDto,
}

pub struct ConnArrowDto {
    pub x: f32,
    pub side: ConnSideKind,
    pub count: u8,
}

pub struct DiagramDto {
    pub width: f32,
    pub height: f32,
    pub baseline: f32,
    pub loops: Vec<LoopGlyphDto>,
    pub turns: Vec<f32>,
    pub connections: Vec<ConnArrowDto>,
}

pub struct NalbindIssueDto {
    pub severity: SeverityKind,
    pub message: String,
}

// --- conversions: enums --------------------------------------------------------------------------

impl From<Step> for StepKind {
    fn from(s: Step) -> Self {
        match s {
            Step::Under => StepKind::Under,
            Step::Over => StepKind::Over,
            Step::SkippedUnder => StepKind::SkippedUnder,
            Step::SkippedOver => StepKind::SkippedOver,
            Step::NoEngage => StepKind::NoEngage,
        }
    }
}
impl From<StepKind> for Step {
    fn from(s: StepKind) -> Self {
        match s {
            StepKind::Under => Step::Under,
            StepKind::Over => Step::Over,
            StepKind::SkippedUnder => Step::SkippedUnder,
            StepKind::SkippedOver => Step::SkippedOver,
            StepKind::NoEngage => Step::NoEngage,
        }
    }
}

impl From<ConnSide> for ConnSideKind {
    fn from(s: ConnSide) -> Self {
        match s {
            ConnSide::Front => ConnSideKind::Front,
            ConnSide::Back => ConnSideKind::Back,
            ConnSide::Middle => ConnSideKind::Middle,
        }
    }
}
impl From<ConnSideKind> for ConnSide {
    fn from(s: ConnSideKind) -> Self {
        match s {
            ConnSideKind::Front => ConnSide::Front,
            ConnSideKind::Back => ConnSide::Back,
            ConnSideKind::Middle => ConnSide::Middle,
        }
    }
}

impl From<Twist> for TwistKind {
    fn from(t: Twist) -> Self {
        match t {
            Twist::Untwisted => TwistKind::Untwisted,
            Twist::Twisted => TwistKind::Twisted,
        }
    }
}
impl From<TwistKind> for Twist {
    fn from(t: TwistKind) -> Self {
        match t {
            TwistKind::Untwisted => Twist::Untwisted,
            TwistKind::Twisted => Twist::Twisted,
        }
    }
}

impl From<LoopKind> for LoopKindDto {
    fn from(k: LoopKind) -> Self {
        match k {
            LoopKind::OverEngaged => LoopKindDto::OverEngaged,
            LoopKind::UnderEngaged => LoopKindDto::UnderEngaged,
            LoopKind::OverSkipped => LoopKindDto::OverSkipped,
            LoopKind::UnderSkipped => LoopKindDto::UnderSkipped,
            LoopKind::NoLoop => LoopKindDto::NoLoop,
        }
    }
}

// --- conversions: structs ------------------------------------------------------------------------

impl From<Pass> for PassDto {
    fn from(p: Pass) -> Self {
        PassDto { steps: p.steps.into_iter().map(Into::into).collect() }
    }
}
impl From<PassDto> for Pass {
    fn from(p: PassDto) -> Self {
        Pass { steps: p.steps.into_iter().map(Into::into).collect() }
    }
}

impl From<Connection> for ConnectionDto {
    fn from(c: Connection) -> Self {
        ConnectionDto { side: c.side.into(), count: c.count, extra: c.extra }
    }
}
impl From<ConnectionDto> for Connection {
    fn from(c: ConnectionDto) -> Self {
        Connection { side: c.side.into(), count: c.count, extra: c.extra }
    }
}

impl From<PublishedCode> for PublishedCodeDto {
    fn from(c: PublishedCode) -> Self {
        PublishedCodeDto { code: c.code, source: c.source }
    }
}
impl From<PublishedCodeDto> for PublishedCode {
    fn from(c: PublishedCodeDto) -> Self {
        PublishedCode { code: c.code, source: c.source }
    }
}

impl From<StitchType> for NalbindStitchDto {
    fn from(s: StitchType) -> Self {
        NalbindStitchDto {
            name: s.name,
            passes: s.passes.into_iter().map(Into::into).collect(),
            connections: s.connections.into_iter().map(Into::into).collect(),
            thumb_loops: s.thumb_loops.map(|(a, b)| ThumbLoopsDto { a, b }),
            twist: s.twist.into(),
            also_known_as: s.also_known_as,
            codes: s.codes.into_iter().map(Into::into).collect(),
            note: s.note,
        }
    }
}
impl From<NalbindStitchDto> for StitchType {
    fn from(s: NalbindStitchDto) -> Self {
        StitchType {
            name: s.name,
            passes: s.passes.into_iter().map(Into::into).collect(),
            connections: s.connections.into_iter().map(Into::into).collect(),
            thumb_loops: s.thumb_loops.map(|t| (t.a, t.b)),
            twist: s.twist.into(),
            also_known_as: s.also_known_as,
            codes: s.codes.into_iter().map(Into::into).collect(),
            note: s.note,
        }
    }
}

impl From<LoopGlyph> for LoopGlyphDto {
    fn from(g: LoopGlyph) -> Self {
        LoopGlyphDto { x: g.x, kind: g.kind.into() }
    }
}
impl From<ConnArrow> for ConnArrowDto {
    fn from(a: ConnArrow) -> Self {
        ConnArrowDto { x: a.x, side: a.side.into(), count: a.count }
    }
}
impl From<Diagram> for DiagramDto {
    fn from(d: Diagram) -> Self {
        DiagramDto {
            width: d.width,
            height: d.height,
            baseline: d.baseline,
            loops: d.loops.into_iter().map(Into::into).collect(),
            turns: d.turns,
            connections: d.connections.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<&NalbindIssue> for NalbindIssueDto {
    fn from(i: &NalbindIssue) -> Self {
        NalbindIssueDto {
            severity: match i.severity {
                Severity::Error => SeverityKind::Error,
                Severity::Warning => SeverityKind::Warning,
            },
            message: i.message.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stitch_dto_round_trips_through_the_engine_type() {
        for st in ply_nalbind::builtin() {
            let dto: NalbindStitchDto = st.clone().into();
            let back: StitchType = dto.into();
            assert_eq!(back, st, "{} did not round-trip through its DTO", st.name);
        }
    }
}
