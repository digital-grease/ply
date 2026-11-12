//! Parse results with provenance: the exact source text, the structure read from it, every
//! diagnostic, the uninterpreted (opaque) tokens, and a fidelity level saying whether the structure
//! is authoritative.

use std::fmt;

use serde::{Deserialize, Serialize};

use super::diagnostic::{DiagnosticCode, NotationDiagnostic, NotationSeverity, Span};
use crate::stitch::{Connection, Pass};

/// Which parse mode produced a result.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ParseMode {
    /// Authoring: refuses anything lossy or ambiguous.
    Strict,
    /// Reference / import: best effort, never fails, keeps everything it cannot interpret.
    Lenient,
}

/// How faithfully the parsed structure represents the source text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Fidelity {
    /// The source is already the canonical notation: `normalized() == source`.
    Exact,
    /// Only documented, meaning-preserving presentation normalizations (whitespace, case, `Mid`,
    /// prefix connections, leading zeros, multi-loop skip groups) separate the source from its
    /// canonical print. The structure is authoritative.
    Normalized,
    /// At least one lossy diagnostic: something was dropped, reordered, assumed, clamped, or left
    /// uninterpreted. The structure is a best effort and must not be presented as authoritative.
    Lossy,
}

impl Fidelity {
    pub fn is_lossy(self) -> bool {
        self == Fidelity::Lossy
    }

    /// True when the structure may be presented as what the source says (`Exact` or `Normalized`).
    pub fn is_authoritative(self) -> bool {
        !self.is_lossy()
    }

    /// The fidelity implied by a set of diagnostics.
    pub fn from_diagnostics(diagnostics: &[NotationDiagnostic]) -> Fidelity {
        if diagnostics.iter().any(|d| d.code.is_lossy()) {
            Fidelity::Lossy
        } else if diagnostics
            .iter()
            .any(|d| d.code.severity() == NotationSeverity::Info)
        {
            Fidelity::Normalized
        } else {
            Fidelity::Exact
        }
    }
}

/// Where an uninterpreted token sits relative to the parsed structure.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum OpaquePlacement {
    /// Not attached to any structural element; located only by its span.
    Standalone,
    /// Glued (no whitespace) onto the end of `connections[connection]`; its text is also part of
    /// that connection's `extra`.
    ConnectionSuffix { connection: usize },
}

/// A piece of source text the grammar does not interpret, kept verbatim rather than discarded.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpaqueToken {
    /// Exactly `span.text(source)`.
    pub text: String,
    pub span: Span,
    pub placement: OpaquePlacement,
}

/// The result of parsing a Hansen-notation string, with lossless provenance.
///
/// The parts are kept separate on purpose: `source` is what was written, `passes` are the known
/// needle-path operations, `connections` are the joins into the previous round, `opaque` is what
/// could not be interpreted, and `fidelity` says how far the structure can be trusted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParsedNotation {
    /// The exact input string, byte for byte. Every [`Span`] in this result indexes into it.
    pub source: String,
    pub mode: ParseMode,
    /// The needle path. Never contains an empty pass, except for the single empty pass of a
    /// notation with no needle step at all.
    pub passes: Vec<Pass>,
    /// The connections in source order. An uninterpreted suffix glued onto a connection (for
    /// example the `+1` of `F1+1`) is kept verbatim in its `extra`.
    pub connections: Vec<Connection>,
    /// Every uninterpreted token, in source order.
    pub opaque: Vec<OpaqueToken>,
    /// Every finding, sorted by span start. In strict mode only `Info` diagnostics can remain on a
    /// successful result.
    pub diagnostics: Vec<NotationDiagnostic>,
    pub fidelity: Fidelity,
}

impl ParsedNotation {
    /// The canonical print of the parsed structure (what [`print`](crate::notation::print) emits).
    /// Opaque tokens and connection `extra` text are not part of it.
    pub fn normalized(&self) -> String {
        super::print(&self.passes, &self.connections)
    }

    /// The most severe diagnostic, if any.
    pub fn max_severity(&self) -> Option<NotationSeverity> {
        self.diagnostics.iter().map(|d| d.severity).max()
    }

    pub fn has_errors(&self) -> bool {
        self.max_severity() == Some(NotationSeverity::Error)
    }

    pub fn is_lossy(&self) -> bool {
        self.fidelity.is_lossy()
    }

    /// The diagnostics carrying `code`.
    pub fn diagnostics_with(
        &self,
        code: DiagnosticCode,
    ) -> impl Iterator<Item = &NotationDiagnostic> {
        self.diagnostics.iter().filter(move |d| d.code == code)
    }
}

/// Why [`parse_strict`](crate::notation::parse_strict) refused a notation string. Every
/// non-`Info` diagnostic is reported with severity `Error`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StrictRejection {
    /// The exact input string.
    pub source: String,
    /// Every finding (including any `Info` ones), sorted by span start.
    pub diagnostics: Vec<NotationDiagnostic>,
}

impl StrictRejection {
    /// The diagnostics that caused the refusal.
    pub fn blocking(&self) -> impl Iterator<Item = &NotationDiagnostic> {
        self.diagnostics
            .iter()
            .filter(|d| d.severity > NotationSeverity::Info)
    }

    /// The codes that caused the refusal, in source order.
    pub fn codes(&self) -> Vec<DiagnosticCode> {
        self.blocking().map(|d| d.code).collect()
    }
}

impl fmt::Display for StrictRejection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut blocking = self.blocking();
        match blocking.next() {
            Some(first) => {
                write!(
                    f,
                    "invalid Hansen notation: {} at position {}",
                    first.message,
                    char_position(&self.source, first.span.start)
                )?;
                let more = blocking.count();
                if more > 0 {
                    write!(f, " (and {more} more)")?;
                }
                Ok(())
            }
            None => f.write_str("invalid Hansen notation"),
        }
    }
}

impl std::error::Error for StrictRejection {}

/// The character index of byte offset `byte` (what the legacy error messages call a position).
pub(super) fn char_position(source: &str, byte: usize) -> usize {
    source
        .get(..byte)
        .map_or(byte, |prefix| prefix.chars().count())
}
