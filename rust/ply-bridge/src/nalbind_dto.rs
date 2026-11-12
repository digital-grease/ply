//! Transparently-mirrored NALBINDING DTOs (M6) — the nalbind analog of `dto.rs`/`knit_dto.rs`.
//!
//! The engine `StitchType`/`Diagram` cross FFI as these plain mirrored structs/enums so Dart can read
//! a stitch's structure directly (browse the dictionary, type a Hansen string, draw the loop diagram)
//! rather than juggle an opaque handle. All engine<->DTO conversions live HERE. `SeverityKind` is
//! REUSED from `dto.rs` so all three crafts share one Dart enum.

//!
//! The notation-analysis DTOs ([`ParsedNotationDto`] and friends, M7-04) carry the engine's
//! strict/lenient parse with its provenance. The engine's spans are UTF-8 BYTE offsets; Dart strings
//! index UTF-16 code units, so every span is converted here, once, and crosses as UTF-16 offsets.

use ply_nalbind::diagram::{ConnArrow, Diagram, LoopGlyph, LoopKind};
use ply_nalbind::notation::{
    Fidelity, NotationDiagnostic, NotationSeverity, OpaquePlacement, OpaqueToken, ParseMode,
    ParsedNotation, Span,
};
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

// --- notation analysis (M7-04) -------------------------------------------------------------------

/// Which parse mode produced a [`ParsedNotationDto`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotationModeKind {
    /// Authoring: every problem is an `Error`; only formatting normalizations pass.
    Strict,
    /// Reference / import: each problem at its own severity.
    Lenient,
}

/// How serious one notation finding is. `Info` is a meaning-preserving formatting normalization.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum NotationSeverityKind {
    Info,
    Warning,
    Error,
}

/// How faithfully the best-effort stitch represents the text (the engine's `Fidelity`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FidelityKind {
    /// The text is already the canonical notation.
    Exact,
    /// Only formatting normalizations separate the text from its canonical print.
    Normalized,
    /// Something was dropped, reordered, assumed, clamped, or left uninterpreted.
    Lossy,
}

/// A half-open range `start..end` into [`ParsedNotationDto::source`] in UTF-16 CODE UNITS, so Dart
/// can `source.substring(start, end)` directly.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NotationSpanDto {
    pub start: u32,
    pub end: u32,
}

/// One finding about the notation text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotationDiagnosticDto {
    /// The engine's stable kebab-case code (e.g. `unexpected-character`); safe to key on.
    pub code: String,
    /// The effective severity in the mode that produced it (strict reports every problem as `Error`).
    pub severity: NotationSeverityKind,
    pub message: String,
    pub span: NotationSpanDto,
    /// The source text under `span` (empty for a zero-width span).
    pub text: String,
}

/// A piece of the text the grammar does not interpret, kept verbatim.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpaqueTokenDto {
    pub text: String,
    pub span: NotationSpanDto,
    /// `Some(i)` when the token is glued onto `stitch.connections[i]` (and so is also that
    /// connection's `extra`); `None` when it stands alone.
    pub connection: Option<u32>,
}

/// The result of reading a Hansen-notation string, with provenance. The stitch is ALWAYS the
/// best-effort structure (so the diagram path keeps working); present it as what the text says only
/// when `accepted` is true and `fidelity` is not `Lossy`.
pub struct ParsedNotationDto {
    /// The exact text that was read. Every span indexes into it (UTF-16 code units).
    pub source: String,
    pub mode: NotationModeKind,
    /// Strict acceptance: true when only formatting normalizations (`Info`) remain, in either mode.
    pub accepted: bool,
    pub fidelity: FidelityKind,
    /// The canonical print of the best-effort stitch (opaque text is not part of it).
    pub normalized: String,
    /// The best-effort structure as an anonymous stitch.
    pub stitch: NalbindStitchDto,
    /// Every uninterpreted token, in source order.
    pub opaque: Vec<OpaqueTokenDto>,
    /// Every finding, in source order.
    pub diagnostics: Vec<NotationDiagnosticDto>,
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
        PassDto {
            steps: p.steps.into_iter().map(Into::into).collect(),
        }
    }
}
impl From<PassDto> for Pass {
    fn from(p: PassDto) -> Self {
        Pass {
            steps: p.steps.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<Connection> for ConnectionDto {
    fn from(c: Connection) -> Self {
        ConnectionDto {
            side: c.side.into(),
            count: c.count,
            extra: c.extra,
        }
    }
}
impl From<ConnectionDto> for Connection {
    fn from(c: ConnectionDto) -> Self {
        Connection {
            side: c.side.into(),
            count: c.count,
            extra: c.extra,
        }
    }
}

impl From<PublishedCode> for PublishedCodeDto {
    fn from(c: PublishedCode) -> Self {
        PublishedCodeDto {
            code: c.code,
            source: c.source,
        }
    }
}
impl From<PublishedCodeDto> for PublishedCode {
    fn from(c: PublishedCodeDto) -> Self {
        PublishedCode {
            code: c.code,
            source: c.source,
        }
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
        LoopGlyphDto {
            x: g.x,
            kind: g.kind.into(),
        }
    }
}
impl From<ConnArrow> for ConnArrowDto {
    fn from(a: ConnArrow) -> Self {
        ConnArrowDto {
            x: a.x,
            side: a.side.into(),
            count: a.count,
        }
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

// --- conversions: notation analysis ----------------------------------------------------------------

impl From<ParseMode> for NotationModeKind {
    fn from(m: ParseMode) -> Self {
        match m {
            ParseMode::Strict => NotationModeKind::Strict,
            ParseMode::Lenient => NotationModeKind::Lenient,
        }
    }
}

impl From<NotationSeverity> for NotationSeverityKind {
    fn from(s: NotationSeverity) -> Self {
        match s {
            NotationSeverity::Info => NotationSeverityKind::Info,
            NotationSeverity::Warning => NotationSeverityKind::Warning,
            NotationSeverity::Error => NotationSeverityKind::Error,
        }
    }
}

impl From<Fidelity> for FidelityKind {
    fn from(f: Fidelity) -> Self {
        match f {
            Fidelity::Exact => FidelityKind::Exact,
            Fidelity::Normalized => FidelityKind::Normalized,
            Fidelity::Lossy => FidelityKind::Lossy,
        }
    }
}

/// Maps UTF-8 byte offsets of one string to UTF-16 code-unit offsets in O(1) per lookup.
struct Utf16Offsets {
    /// `units[b]` = UTF-16 units before byte `b`, for every byte offset `0..=len`. A byte inside a
    /// multi-byte character maps to that character's start (the engine never emits one; this only
    /// keeps a bad span from panicking).
    units: Vec<u32>,
}

impl Utf16Offsets {
    fn new(source: &str) -> Self {
        let mut units = Vec::with_capacity(source.len() + 1);
        let mut count: u32 = 0;
        for ch in source.chars() {
            units.extend(std::iter::repeat_n(count, ch.len_utf8()));
            count = count.saturating_add(ch.len_utf16() as u32);
        }
        units.push(count);
        Utf16Offsets { units }
    }

    /// The UTF-16 offset of byte `byte`, clamped to the end of the string.
    fn at(&self, byte: usize) -> u32 {
        self.units[byte.min(self.units.len() - 1)]
    }

    fn span(&self, span: Span) -> NotationSpanDto {
        let start = self.at(span.start);
        NotationSpanDto {
            start,
            end: self.at(span.end).max(start),
        }
    }
}

fn diagnostic_dto(
    d: NotationDiagnostic,
    source: &str,
    map: &Utf16Offsets,
) -> NotationDiagnosticDto {
    NotationDiagnosticDto {
        code: d.code.as_str().to_string(),
        severity: d.severity.into(),
        text: d.span.text(source).to_string(),
        span: map.span(d.span),
        message: d.message,
    }
}

fn opaque_dto(o: OpaqueToken, map: &Utf16Offsets) -> OpaqueTokenDto {
    OpaqueTokenDto {
        span: map.span(o.span),
        connection: match o.placement {
            OpaquePlacement::Standalone => None,
            OpaquePlacement::ConnectionSuffix { connection } => {
                Some(u32::try_from(connection).unwrap_or(u32::MAX))
            }
        },
        text: o.text,
    }
}

/// Convert an engine parse to its DTO. `accepted` is passed in because a strict REJECTION carries
/// the structure of the lenient parse with the rejection's (escalated) diagnostics.
fn parsed_dto(p: ParsedNotation, accepted: bool) -> ParsedNotationDto {
    let map = Utf16Offsets::new(&p.source);
    let normalized = p.normalized();
    let stitch = StitchType::anonymous(p.passes, p.connections).into();
    ParsedNotationDto {
        mode: p.mode.into(),
        accepted,
        fidelity: p.fidelity.into(),
        normalized,
        stitch,
        opaque: p.opaque.into_iter().map(|o| opaque_dto(o, &map)).collect(),
        diagnostics: p
            .diagnostics
            .into_iter()
            .map(|d| diagnostic_dto(d, &p.source, &map))
            .collect(),
        source: p.source,
    }
}

/// Read `text` in strict (authoring) or lenient (reference) mode. Never fails: a strict rejection
/// still returns the lenient best-effort structure, with the rejection's diagnostics (every problem
/// an `Error`) and `accepted = false`.
pub(crate) fn analyze_notation(text: &str, strict: bool) -> ParsedNotationDto {
    if strict {
        match ply_nalbind::parse_strict(text) {
            Ok(parsed) => parsed_dto(parsed, true),
            Err(rejection) => {
                let mut parsed = ply_nalbind::parse_lenient(text);
                parsed.mode = ParseMode::Strict;
                parsed.diagnostics = rejection.diagnostics;
                parsed_dto(parsed, false)
            }
        }
    } else {
        let parsed = ply_nalbind::parse_lenient(text);
        // The engine's own acceptance rule (see `parse_strict`): nothing above `Info`.
        let accepted = parsed
            .diagnostics
            .iter()
            .all(|d| d.severity == NotationSeverity::Info);
        parsed_dto(parsed, accepted)
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

    // --- notation analysis ---------------------------------------------------------------------

    use NotationSeverityKind::{Error, Info, Warning};

    /// The text a UTF-16 span selects, exactly as Dart's `source.substring(start, end)` would.
    fn utf16_slice(source: &str, span: NotationSpanDto) -> String {
        let units: Vec<u16> = source.encode_utf16().collect();
        String::from_utf16(&units[span.start as usize..span.end as usize]).unwrap()
    }

    fn range(span: NotationSpanDto) -> (u32, u32) {
        (span.start, span.end)
    }

    fn codes(p: &ParsedNotationDto) -> Vec<&str> {
        p.diagnostics.iter().map(|d| d.code.as_str()).collect()
    }

    fn diag<'a>(p: &'a ParsedNotationDto, code: &str) -> &'a NotationDiagnosticDto {
        p.diagnostics
            .iter()
            .find(|d| d.code == code)
            .unwrap_or_else(|| panic!("no {code} in {:?} for {:?}", codes(p), p.source))
    }

    /// Every diagnostic and opaque span selects exactly its text in UTF-16, within the source.
    fn assert_spans_select_their_text(p: &ParsedNotationDto) {
        let len = p.source.encode_utf16().count() as u32;
        for d in &p.diagnostics {
            assert!(d.span.start <= d.span.end && d.span.end <= len, "{d:?}");
            assert_eq!(utf16_slice(&p.source, d.span), d.text, "{d:?}");
        }
        for o in &p.opaque {
            assert!(o.span.start <= o.span.end && o.span.end <= len, "{o:?}");
            assert_eq!(utf16_slice(&p.source, o.span), o.text, "{o:?}");
        }
    }

    #[test]
    fn spans_cross_as_utf16_offsets_with_multibyte_text() {
        // NBSP is 2 UTF-8 bytes but 1 UTF-16 unit, so `+1` (bytes 10..12) is units 9..11.
        let p = analyze_notation("UO/UOO\u{a0}F1+1", false);
        let dialect = diag(&p, "unsupported-dialect");
        assert_eq!(range(dialect.span), (9, 11));
        assert_eq!(dialect.text, "+1");
        let nbsp = diag(&p, "whitespace-normalized");
        assert_eq!(range(nbsp.span), (6, 7));
        assert_eq!(nbsp.text, "\u{a0}");
        assert_eq!(nbsp.severity, Info);
        assert_eq!(range(p.opaque[0].span), (9, 11));
        assert_spans_select_their_text(&p);

        // `é` is 2 bytes / 1 unit; `𝕌` (outside the BMP) is 4 bytes / a 2-unit surrogate pair.
        let p = analyze_notation("é UO/𝕌 F1", false);
        let unexpected: Vec<_> = p
            .diagnostics
            .iter()
            .filter(|d| d.code == "unexpected-character")
            .map(|d| (range(d.span), d.text.as_str()))
            .collect();
        assert_eq!(unexpected, vec![((0, 1), "é"), ((5, 7), "𝕌")]);
        assert_eq!(range(diag(&p, "trailing-turn").span), (4, 5));
        let opaque: Vec<_> = p
            .opaque
            .iter()
            .map(|o| (o.text.as_str(), range(o.span), o.connection))
            .collect();
        assert_eq!(opaque, vec![("é", (0, 1), None), ("𝕌", (5, 7), None)]);
        assert_spans_select_their_text(&p);
    }

    #[test]
    fn strict_accepts_canonical_and_normalized_text() {
        let p = analyze_notation("UO/UOO F1", true);
        assert!(p.accepted);
        assert_eq!(p.mode, NotationModeKind::Strict);
        assert_eq!(p.fidelity, FidelityKind::Exact);
        assert!(p.diagnostics.is_empty());
        assert_eq!(p.normalized, "UO/UOO F1");
        assert_eq!(p.stitch.passes.len(), 2);
        assert_eq!(p.stitch.connections.len(), 1);

        let p = analyze_notation("uo/uoo f1", true);
        assert!(p.accepted, "lowercase is a formatting normalization");
        assert_eq!(p.fidelity, FidelityKind::Normalized);
        assert_eq!(p.source, "uo/uoo f1", "the source is kept as written");
        assert_eq!(p.normalized, "UO/UOO F1");
        assert!(!p.diagnostics.is_empty());
        assert!(p.diagnostics.iter().all(|d| d.severity == Info));
    }

    #[test]
    fn a_strict_rejection_keeps_the_best_effort_stitch_and_reports_errors() {
        let p = analyze_notation("UO/UOO F", true);
        assert!(!p.accepted);
        assert_eq!(p.mode, NotationModeKind::Strict);
        assert_eq!(p.fidelity, FidelityKind::Lossy);
        let missing = diag(&p, "missing-count");
        assert_eq!(
            missing.severity, Error,
            "strict reports every problem as an error"
        );
        assert_eq!(missing.text, "F");
        assert_eq!(range(missing.span), (7, 8));
        // The best effort assumes a count of 1, so the diagram still has something to draw.
        assert_eq!(p.stitch.passes.len(), 2);
        assert_eq!(p.stitch.connections[0].count, 1);
        assert_eq!(p.normalized, "UO/UOO F1");

        // Lenient reads the same structure, at the code's own severity, and is not accepted either.
        let l = analyze_notation("UO/UOO F", false);
        assert!(!l.accepted);
        assert_eq!(l.mode, NotationModeKind::Lenient);
        assert_eq!(diag(&l, "missing-count").severity, Warning);
        assert_eq!(l.normalized, p.normalized);
    }

    #[test]
    fn acceptance_and_fidelity_are_independent() {
        // A repeated connection is read faithfully (Exact) but is ambiguous, so strict refuses it.
        let p = analyze_notation("UO/UOO F1 F1", true);
        assert!(!p.accepted);
        assert_eq!(p.fidelity, FidelityKind::Exact);
        assert_eq!(codes(&p), vec!["duplicate-connection"]);
        assert_eq!(p.diagnostics[0].severity, Error);

        // A rejection keeps its formatting notes at Info.
        let p = analyze_notation("uo:uoo", true);
        assert!(!p.accepted);
        assert_eq!(diag(&p, "turn-marker-mismatch").severity, Error);
        assert_eq!(diag(&p, "case-normalized").severity, Info);
    }

    #[test]
    fn opaque_tokens_keep_their_text_and_placement() {
        let p = analyze_notation("UO/UOO F1+1", false);
        assert_eq!(p.opaque.len(), 1);
        assert_eq!(p.opaque[0].text, "+1");
        assert_eq!(
            p.opaque[0].connection,
            Some(0),
            "glued onto the F1 connection"
        );
        assert_eq!(p.stitch.connections[0].extra.as_deref(), Some("+1"));
        assert_eq!(p.normalized, "UO/UOO F1", "opaque text is not printed");
        assert_eq!(p.fidelity, FidelityKind::Lossy);

        let p = analyze_notation("UO/XYZ", false);
        assert_eq!(p.opaque.len(), 1);
        assert_eq!(p.opaque[0].text, "XYZ");
        assert_eq!(p.opaque[0].connection, None, "standalone");
        assert_eq!(range(p.opaque[0].span), (3, 6));
        assert_eq!(diag(&p, "unexpected-character").severity, Error);
        assert!(!p.accepted);
    }

    #[test]
    fn acceptance_matches_the_engine_strict_parser_in_both_modes() {
        for src in [
            "UO/UOO F1",
            "uo/uoo f1",
            "F1 UO/UOO",
            "U(UU)O",
            "UO/UOO\tMid02",
            "UO/UOO\u{a0}F1",
            "",
            "F1",
            "F1+1",
            "UO/UOO F",
            "UO/UOO F1 F1",
            "UO/X",
            "U(UO/UOO",
            "UO/UOO F999",
            " u(U o/UOO\u{a0}F1+1 #",
        ] {
            let engine = ply_nalbind::parse_strict(src).is_ok();
            let lenient = analyze_notation(src, false);
            let strict = analyze_notation(src, true);
            assert_eq!(lenient.accepted, engine, "lenient {src:?}");
            assert_eq!(strict.accepted, engine, "strict {src:?}");
            assert_eq!(lenient.source, src);
            assert_eq!(strict.source, src);
            assert_eq!(
                lenient.normalized, strict.normalized,
                "same structure {src:?}"
            );
            assert_eq!(codes(&lenient), codes(&strict), "same findings {src:?}");
            if engine {
                assert_ne!(strict.fidelity, FidelityKind::Lossy, "{src:?}");
            } else {
                assert!(strict.diagnostics.iter().any(|d| d.severity == Error));
            }
            assert!(strict
                .diagnostics
                .iter()
                .all(|d| matches!(d.severity, Info | Error)));
            assert_spans_select_their_text(&lenient);
            assert_spans_select_their_text(&strict);
        }
    }

    /// The project screen's stitch chips fill in each builtin's first code, which the authoring
    /// (strict) mode must accept and read back as the dictionary's own structure.
    #[test]
    fn every_builtin_first_code_is_accepted_in_strict_mode() {
        for st in ply_nalbind::builtin() {
            let code = &st.codes[0].code;
            let p = analyze_notation(code, true);
            assert!(p.accepted, "{}: {code:?} refused: {:?}", st.name, codes(&p));
            let back = StitchType::from(p.stitch);
            assert_eq!(back.passes, st.passes, "{}", st.name);
            assert_eq!(back.connections, st.connections, "{}", st.name);
        }
        // Åsle's alternate `F1+1` is shown as text only; nothing may claim it was understood.
        let p = analyze_notation("F1+1", true);
        assert!(!p.accepted);
        assert!(codes(&p).contains(&"unsupported-dialect"));
    }

    #[test]
    fn utf16_offsets_never_panic_on_a_bad_span() {
        let map = Utf16Offsets::new("a\u{e9}b"); // bytes: a=0, é=1..3, b=3
        assert_eq!(map.at(0), 0);
        assert_eq!(map.at(2), 1, "a byte inside `é` maps to the start of `é`");
        assert_eq!(map.at(3), 2);
        assert_eq!(map.at(4), 3);
        assert_eq!(map.at(99), 3, "clamped to the end");
        assert_eq!(range(map.span(Span::new(3, 1))), (2, 2), "never inverted");
    }
}
