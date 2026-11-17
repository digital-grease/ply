//! Notation diagnostics: stable machine codes, severities, and byte spans into the source text.
//!
//! The code strings returned by [`DiagnosticCode::as_str`] (and used by serde) are a STABLE contract:
//! a UI or a saved report may key on them, so a code is never renamed or reused for a different
//! meaning. New codes may be added.

use std::fmt;

use serde::{Deserialize, Serialize};

/// A half-open byte range `start..end` into the notation source string. Both ends always fall on
/// UTF-8 character boundaries of the source the span came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct Span {
    pub start: usize,
    pub end: usize,
}

impl Span {
    pub const fn new(start: usize, end: usize) -> Self {
        Span { start, end }
    }

    /// Length in bytes.
    pub const fn len(&self) -> usize {
        self.end.saturating_sub(self.start)
    }

    /// True for a zero-width span.
    pub const fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// True when `byte` lies inside this span.
    pub const fn contains(&self, byte: usize) -> bool {
        self.start <= byte && byte < self.end
    }

    /// The smallest span covering both `self` and `other`.
    pub fn cover(self, other: Span) -> Span {
        Span::new(self.start.min(other.start), self.end.max(other.end))
    }

    /// The source text under this span (empty if the span does not fit `source`).
    pub fn text<'a>(&self, source: &'a str) -> &'a str {
        source.get(self.start..self.end).unwrap_or("")
    }
}

/// How serious a notation diagnostic is. Ordered `Info < Warning < Error`.
///
/// * `Info`: a documented, meaning-preserving presentation normalization (whitespace, letter case,
///   the `Mid` spelling, ...). Strict mode accepts it.
/// * `Warning`: the text is lossy, ambiguous, or uses an unsupported construct, but a best-effort
///   structure exists. Strict mode refuses it.
/// * `Error`: part of the text could not be interpreted at all. Strict mode refuses it, and the
///   legacy [`parse`](crate::notation::parse) entry point returns `Err` for it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum NotationSeverity {
    Info,
    Warning,
    Error,
}

impl NotationSeverity {
    /// The same finding in the vocabulary every craft shares (ADR 0021): one to one. (A strict
    /// reading has already turned every non-`Info` finding into an `Error`.)
    pub const fn level(self) -> ply_common::readiness::Severity {
        match self {
            NotationSeverity::Info => ply_common::readiness::Severity::Info,
            NotationSeverity::Warning => ply_common::readiness::Severity::Warning,
            NotationSeverity::Error => ply_common::readiness::Severity::Error,
        }
    }
}

/// A stable machine code identifying one kind of notation finding. See the module docs of
/// [`notation`](crate::notation) for the grammar each code refers to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DiagnosticCode {
    // --- Error: uninterpretable text --------------------------------------------------------------
    /// A character (run) outside the grammar, e.g. `X`, `#`, a digit not attached to a side.
    UnexpectedCharacter,
    /// A `(` with no matching `)` in the same pass.
    UnmatchedOpenParen,
    /// A `)` with no matching `(` in the same pass.
    UnmatchedCloseParen,
    /// A connection count above 255 (the count is clamped, not silently saturated).
    CountOutOfRange,

    // --- Warning: lossy, ambiguous, or unsupported --------------------------------------------------
    /// A skip group inside another skip group, e.g. `U((U))O`.
    NestedGroup,
    /// A skip group that encloses no loop, e.g. `U()O`.
    EmptyGroup,
    /// A `-` inside a skip group; a skipped no-engage step cannot be represented.
    SkippedNoEngage,
    /// A turn before the first needle step, e.g. `/UO`.
    LeadingTurn,
    /// A turn after the last needle step, e.g. `UO/UOO/`.
    TrailingTurn,
    /// A turn directly after another turn, e.g. `UO//UOO`.
    DoubledTurn,
    /// A pass between turns that holds tokens but no needle step, e.g. `UO/()/UOO`.
    EmptyPass,
    /// `:` used for the first turn, or `/` used for a later turn.
    TurnMarkerMismatch,
    /// A connection written inside the needle path, including inside a skip group (`U(UF1)`), or a
    /// prefix connection mixed with suffix ones.
    ConnectionOutOfPlace,
    /// A connection side with no count, e.g. a bare `F`; a count of 1 is assumed.
    MissingCount,
    /// A count separated from its side by whitespace, e.g. `F 1`.
    DetachedCount,
    /// A `+` dialect token (`F1+1`, `1+1`), which Ply does not interpret; kept verbatim.
    UnsupportedDialect,
    /// The notation has no needle step at all (empty text, or connections only).
    NoNeedlePath,
    /// A connection identical to an earlier one, e.g. `F1 F1`.
    DuplicateConnection,
    /// A connection on the same side as an earlier one with a different count, e.g. `F1 F2`.
    ContradictoryConnection,

    // --- Info: documented, meaning-preserving normalizations ----------------------------------------
    /// Whitespace that differs from the canonical layout (tabs, NBSP, extra or missing spaces).
    WhitespaceNormalized,
    /// Lowercase letters read as their uppercase symbols.
    CaseNormalized,
    /// The `Mid` spelling of the middle side, printed as `M`.
    MidAlias,
    /// Connections written before the needle path, printed after it.
    ConnectionPrefix,
    /// A count written with leading zeros, e.g. `F01`.
    CountLeadingZero,
    /// A multi-loop skip group such as `(UU)`, printed one loop per group: `(U)(U)`.
    GroupSplit,
}

impl DiagnosticCode {
    /// Every code, in declaration order.
    pub const ALL: [DiagnosticCode; 25] = [
        DiagnosticCode::UnexpectedCharacter,
        DiagnosticCode::UnmatchedOpenParen,
        DiagnosticCode::UnmatchedCloseParen,
        DiagnosticCode::CountOutOfRange,
        DiagnosticCode::NestedGroup,
        DiagnosticCode::EmptyGroup,
        DiagnosticCode::SkippedNoEngage,
        DiagnosticCode::LeadingTurn,
        DiagnosticCode::TrailingTurn,
        DiagnosticCode::DoubledTurn,
        DiagnosticCode::EmptyPass,
        DiagnosticCode::TurnMarkerMismatch,
        DiagnosticCode::ConnectionOutOfPlace,
        DiagnosticCode::MissingCount,
        DiagnosticCode::DetachedCount,
        DiagnosticCode::UnsupportedDialect,
        DiagnosticCode::NoNeedlePath,
        DiagnosticCode::DuplicateConnection,
        DiagnosticCode::ContradictoryConnection,
        DiagnosticCode::WhitespaceNormalized,
        DiagnosticCode::CaseNormalized,
        DiagnosticCode::MidAlias,
        DiagnosticCode::ConnectionPrefix,
        DiagnosticCode::CountLeadingZero,
        DiagnosticCode::GroupSplit,
    ];

    /// The stable kebab-case code string (identical to the serde form).
    pub const fn as_str(self) -> &'static str {
        match self {
            DiagnosticCode::UnexpectedCharacter => "unexpected-character",
            DiagnosticCode::UnmatchedOpenParen => "unmatched-open-paren",
            DiagnosticCode::UnmatchedCloseParen => "unmatched-close-paren",
            DiagnosticCode::CountOutOfRange => "count-out-of-range",
            DiagnosticCode::NestedGroup => "nested-group",
            DiagnosticCode::EmptyGroup => "empty-group",
            DiagnosticCode::SkippedNoEngage => "skipped-no-engage",
            DiagnosticCode::LeadingTurn => "leading-turn",
            DiagnosticCode::TrailingTurn => "trailing-turn",
            DiagnosticCode::DoubledTurn => "doubled-turn",
            DiagnosticCode::EmptyPass => "empty-pass",
            DiagnosticCode::TurnMarkerMismatch => "turn-marker-mismatch",
            DiagnosticCode::ConnectionOutOfPlace => "connection-out-of-place",
            DiagnosticCode::MissingCount => "missing-count",
            DiagnosticCode::DetachedCount => "detached-count",
            DiagnosticCode::UnsupportedDialect => "unsupported-dialect",
            DiagnosticCode::NoNeedlePath => "no-needle-path",
            DiagnosticCode::DuplicateConnection => "duplicate-connection",
            DiagnosticCode::ContradictoryConnection => "contradictory-connection",
            DiagnosticCode::WhitespaceNormalized => "whitespace-normalized",
            DiagnosticCode::CaseNormalized => "case-normalized",
            DiagnosticCode::MidAlias => "mid-alias",
            DiagnosticCode::ConnectionPrefix => "connection-prefix",
            DiagnosticCode::CountLeadingZero => "count-leading-zero",
            DiagnosticCode::GroupSplit => "group-split",
        }
    }

    /// Look a code up by its stable string.
    pub fn from_code(code: &str) -> Option<DiagnosticCode> {
        DiagnosticCode::ALL
            .iter()
            .copied()
            .find(|c| c.as_str() == code)
    }

    /// The severity this code carries in LENIENT mode. Strict mode reports every non-`Info` code as
    /// `Error` (it refuses them).
    pub const fn severity(self) -> NotationSeverity {
        use DiagnosticCode::*;
        match self {
            UnexpectedCharacter | UnmatchedOpenParen | UnmatchedCloseParen | CountOutOfRange => {
                NotationSeverity::Error
            }
            NestedGroup
            | EmptyGroup
            | SkippedNoEngage
            | LeadingTurn
            | TrailingTurn
            | DoubledTurn
            | EmptyPass
            | TurnMarkerMismatch
            | ConnectionOutOfPlace
            | MissingCount
            | DetachedCount
            | UnsupportedDialect
            | NoNeedlePath
            | DuplicateConnection
            | ContradictoryConnection => NotationSeverity::Warning,
            WhitespaceNormalized | CaseNormalized | MidAlias | ConnectionPrefix
            | CountLeadingZero | GroupSplit => NotationSeverity::Info,
        }
    }

    /// True when this finding means the parsed structure does NOT faithfully represent the source:
    /// something was dropped, reordered, assumed, clamped, or left uninterpreted. Every lossy code is
    /// at least a `Warning`. The non-lossy warnings (`no-needle-path`, `duplicate-connection`,
    /// `contradictory-connection`) flag text that is represented faithfully but is incomplete or
    /// ambiguous in meaning.
    pub const fn is_lossy(self) -> bool {
        use DiagnosticCode::*;
        !matches!(
            self,
            NoNeedlePath
                | DuplicateConnection
                | ContradictoryConnection
                | WhitespaceNormalized
                | CaseNormalized
                | MidAlias
                | ConnectionPrefix
                | CountLeadingZero
                | GroupSplit
        )
    }
}

impl fmt::Display for DiagnosticCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One finding about a notation string, located by a byte [`Span`] into the source.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NotationDiagnostic {
    pub code: DiagnosticCode,
    /// The effective severity in the mode that produced this diagnostic (see [`NotationSeverity`]).
    pub severity: NotationSeverity,
    pub span: Span,
    /// A human-readable explanation, quoting the offending text.
    pub message: String,
}

impl NotationDiagnostic {
    /// A diagnostic at the code's lenient severity.
    pub fn new(code: DiagnosticCode, span: Span, message: impl Into<String>) -> Self {
        NotationDiagnostic {
            code,
            severity: code.severity(),
            span,
            message: message.into(),
        }
    }
}

impl fmt::Display for NotationDiagnostic {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} [{}] at bytes {}..{}",
            self.message, self.code, self.span.start, self.span.end
        )
    }
}
