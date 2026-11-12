//! Hansen-notation parsing and printing, with a strict and a lenient mode and lossless provenance.
//!
//! # Entry points
//!
//! * [`parse_strict`]: for AUTHORING. Accepts only text whose canonical print is the same notation,
//!   allowing just the documented presentation normalizations listed below. Anything lossy,
//!   ambiguous, or unsupported is refused with positioned diagnostics.
//! * [`parse_lenient`]: for REFERENCE and IMPORT. Never fails. Returns a best-effort structure plus
//!   every diagnostic, the exact source text, the uninterpreted tokens kept verbatim, and a
//!   [`Fidelity`] level, so a UI can refuse to present a lossy parse as authoritative.
//! * [`parse`]: the LEGACY lenient path, kept for existing callers (the FFI bridge). It runs the
//!   lenient parser and returns `Err` only when an `Error`-severity diagnostic is present; otherwise
//!   it returns the best-effort structure and DISCARDS the diagnostics and the source. It behaves as
//!   before on every input the old parser handled correctly. New code should use a mode above.
//! * [`print()`]: the canonical printer. `parse_strict(&print(p, c))` reproduces `(p, c)` exactly.
//!
//! # Grammar
//!
//! Derived from `docs/NALBIND_DESIGN.md` ("Hansen notation"). The canonical form, which is exactly
//! what [`print()`] emits:
//!
//! ```text
//! notation   = path , { " " , connection } ;
//! path       = pass , { turn , pass } ;
//! pass       = item , { item } ;                  (every pass has at least one step)
//! item       = "U" | "O" | "-" | "(" , ( "U" | "O" ) , ")" ;
//! turn       = "/"                                (the first turn)
//!            | ":" ;                              (every later turn)
//! connection = side , count ;
//! side       = "F" | "B" | "M" ;
//! count      = "0" | nonzero-digit , { digit } ;   (value 0 to 255)
//! ```
//!
//! | Symbol | Meaning (from the design doc) | Model |
//! |---|---|---|
//! | `U` / `O` | the needle passes under / over a loop | [`Step::Under`] / [`Step::Over`] |
//! | `-` | no over/under on that step (looping stitches such as Coptic) | [`Step::NoEngage`] |
//! | `( )` | a skipped loop: it exists but the needle does not engage it | [`Step::SkippedUnder`] / [`Step::SkippedOver`] |
//! | `/` | the turn (return point) between the first two passes | a new [`Pass`] |
//! | `:` | a further turn (the 2nd and later direction changes), so `.../...:...` | a new [`Pass`] |
//! | `F` `B` `M` + count | a connection into the previous round: side plus loops engaged | [`Connection`] |
//!
//! Twist / chirality has no symbol (the design doc: the flat string does not capture it), so it is
//! never parsed; it lives in [`crate::stitch::Twist`].
//!
//! ## Accepted normalizations (`Info`; strict mode accepts them)
//!
//! Each one preserves the meaning, and the exact original is always kept in
//! [`ParsedNotation::source`]:
//!
//! * `whitespace-normalized`: any Unicode whitespace (space, tab, NBSP, newline) between tokens is
//!   insignificant. The canonical layout is no whitespace inside the path and one space before each
//!   connection, so concatenated connections (`F1B1`, as the design doc writes Coptic) gain a space.
//! * `case-normalized`: lowercase `u` `o` `f` `b` `m` are read as uppercase.
//! * `mid-alias`: `Mid` (any case) is the design doc's spelled-out `M`.
//! * `connection-prefix`: connections written before the path (the design doc: "some sources prefix
//!   the connection (`F1 UO/UOO`)") are printed after it.
//! * `count-leading-zero`: `F01` is the count 1.
//! * `group-split`: a multi-loop skip group `(UU)` marks each enclosed loop skipped; printed
//!   `(U)(U)`.
//!
//! ## Lossy, ambiguous, or unsupported constructs (strict mode refuses them)
//!
//! Where the design doc gives a construct no meaning, Ply does not invent one. The construct is
//! diagnosed with its byte span, the source text is kept, uninterpreted text is preserved verbatim
//! as an [`OpaqueToken`] (and in [`Connection::extra`] when it is glued onto a connection), and the
//! lenient result is marked [`Fidelity::Lossy`] whenever the structure is not faithful.
//!
//! | Code | Severity | Example | Lenient best effort |
//! |---|---|---|---|
//! | `unexpected-character` | Error | `UO/XYZ`, `F1x` | kept opaque (in `extra` when glued to a connection) |
//! | `unmatched-open-paren` | Error | `U(UO/UOO` | the `(` is ignored; the loops after it stay engaged |
//! | `unmatched-close-paren` | Error | `U)O` | the `)` is ignored |
//! | `count-out-of-range` | Error | `F999` | the count is clamped to 255, never silently |
//! | `nested-group` | Warning | `U((U))O` | read as one level of skipping |
//! | `empty-group` | Warning | `U()O` | dropped |
//! | `skipped-no-engage` | Warning | `U(-)O` | read as a plain `-` |
//! | `leading-turn` | Warning | `/UO` | dropped |
//! | `trailing-turn` | Warning | `UO/UOO//` | dropped |
//! | `doubled-turn` | Warning | `UO//UOO` | the extra turn is dropped (no empty pass) |
//! | `empty-pass` | Warning | `UO/()/UOO` | the empty pass and its closing turn are dropped |
//! | `turn-marker-mismatch` | Warning | `UO:UOO`, `UO/UO/UOO` | read as a turn; printed by position |
//! | `connection-out-of-place` | Warning | `UF1O/UOO`, `U(UF1)` | listed after the path |
//! | `missing-count` | Warning | `UO/UOO F` | a count of 1 is assumed (the legacy reading) |
//! | `detached-count` | Warning | `UO/UOO F 1` | read as `F1` |
//! | `unsupported-dialect` | Warning | `F1+1`, `1+1` | kept opaque (in `extra` when glued to a connection) |
//! | `no-needle-path` | Warning | (empty), `F1` | an empty path; faithful, but not a stitch |
//! | `duplicate-connection` | Warning | `F1 F1` | both kept; faithful, but ambiguous |
//! | `contradictory-connection` | Warning | `F1 F2` | both kept; faithful, but ambiguous |
//!
//! Decisions where the design doc is silent:
//!
//! * `/` versus `:`. The doc defines `/` as the turn and `:` as a further (2nd and later) turn, so
//!   the marker is a function of position and the model stores only the passes. The doc gives no
//!   meaning to `:` in first position or `/` in a later one, so those are `turn-marker-mismatch`:
//!   read as a turn (the one meaning both symbols share), marked lossy, refused in strict mode.
//! * The `+` dialect. The doc mentions `a+b(+c)` only as a parallel thumb-loop naming that "is not
//!   Hansen syntax", and the builtin dictionary lists `F1+1` as an alternate Åsle code without
//!   defining it. So a `+` with its following digits (and any digit run leading into it, as in
//!   `1+1`) is never interpreted. Text after it that is itself a valid token (`B1` in `F1+B1`) is
//!   still read as that token.
//! * A bare side (`F`). The doc writes a connection as "a side + a count"; a missing count has no
//!   documented meaning. Lenient mode keeps the legacy reading (count 1) but marks it lossy.
//! * Skip groups. The doc shows `(U)` marking one skipped loop; each `U` / `O` inside a group is read
//!   as a skipped loop. Nesting, empty groups, and `-` inside a group have no documented meaning.
//! * Counts are `u8` in the model. 0 is accepted here (validation warns about a 0-loop connection).
//! * Same-side connections are faithful to the text but ambiguous (one connection or two? which
//!   count?), so they are warnings that strict mode refuses, and both are kept.
//!
//! # Invariants (unit- and property-tested)
//!
//! * Neither mode panics on any input, and every span falls on character boundaries of the source.
//! * Strict-accepted text round-trips exactly: its normalized print parses strictly to the same
//!   structure, with [`Fidelity::Exact`] and the same normalized text.
//! * `parse_strict(&print(p, c))` reproduces `(p, c)` for any structure with non-empty passes, no
//!   connection `extra`, and at most one connection per side.
//! * Lenient never drops a non-whitespace character without a `Warning`-or-higher diagnostic whose
//!   span covers it.
//! * [`print()`] emits only the modeled structure: connection `extra` text and opaque tokens are not
//!   printed (show [`ParsedNotation::source`] for what was written).

mod analyze;
mod diagnostic;
mod lexer;
mod parsed;
#[cfg(test)]
mod tests;

pub use diagnostic::{DiagnosticCode, NotationDiagnostic, NotationSeverity, Span};
pub use parsed::{
    Fidelity, OpaquePlacement, OpaqueToken, ParseMode, ParsedNotation, StrictRejection,
};

use crate::error::NalbindError;
use crate::stitch::{ConnSide, Connection, Pass, Step};

/// Parse for reference / import. Never fails: returns the best-effort structure, every diagnostic
/// (at each code's lenient severity), the exact source text, and the uninterpreted tokens.
pub fn parse_lenient(text: &str) -> ParsedNotation {
    let analysis = analyze::analyze(text);
    let fidelity = Fidelity::from_diagnostics(&analysis.diagnostics);
    ParsedNotation {
        source: text.to_string(),
        mode: ParseMode::Lenient,
        passes: analysis.passes,
        connections: analysis.connections,
        opaque: analysis.opaque,
        diagnostics: analysis.diagnostics,
        fidelity,
    }
}

/// Parse for authoring. Succeeds only when every diagnostic is an `Info` normalization, so the
/// result's fidelity is [`Fidelity::Exact`] or [`Fidelity::Normalized`]. Otherwise returns every
/// diagnostic, with each non-`Info` one reported as an `Error`.
pub fn parse_strict(text: &str) -> Result<ParsedNotation, StrictRejection> {
    let mut parsed = parse_lenient(text);
    if parsed
        .diagnostics
        .iter()
        .any(|d| d.severity > NotationSeverity::Info)
    {
        let diagnostics = parsed
            .diagnostics
            .into_iter()
            .map(|mut d| {
                if d.severity > NotationSeverity::Info {
                    d.severity = NotationSeverity::Error;
                }
                d
            })
            .collect();
        return Err(StrictRejection {
            source: parsed.source,
            diagnostics,
        });
    }
    parsed.mode = ParseMode::Strict;
    Ok(parsed)
}

/// LEGACY lenient entry point (used by the FFI bridge): the [`parse_lenient`] structure, or `Err`
/// for the first `Error`-severity diagnostic (unexpected characters, unmatched parentheses, an
/// out-of-range count). Warnings and their provenance are discarded, so prefer [`parse_lenient`] or
/// [`parse_strict`] in new code.
pub fn parse(input: &str) -> Result<(Vec<Pass>, Vec<Connection>), NalbindError> {
    let parsed = parse_lenient(input);
    if let Some(d) = parsed
        .diagnostics
        .iter()
        .find(|d| d.severity == NotationSeverity::Error)
    {
        return Err(NalbindError::BadNotation(format!(
            "{} at position {}",
            d.message,
            parsed::char_position(input, d.span.start)
        )));
    }
    Ok((parsed.passes, parsed.connections))
}

/// Print passes + connections as canonical Hansen notation (see the grammar above). Connection
/// `extra` text is not printed: it is free text, not notation.
pub fn print(passes: &[Pass], connections: &[Connection]) -> String {
    let mut s = String::new();
    for (k, pass) in passes.iter().enumerate() {
        match k {
            0 => {}
            1 => s.push('/'),
            _ => s.push(':'),
        }
        for step in &pass.steps {
            match step {
                Step::Under => s.push('U'),
                Step::Over => s.push('O'),
                Step::SkippedUnder => s.push_str("(U)"),
                Step::SkippedOver => s.push_str("(O)"),
                Step::NoEngage => s.push('-'),
            }
        }
    }
    for c in connections {
        if !s.is_empty() {
            s.push(' ');
        }
        s.push(match c.side {
            ConnSide::Front => 'F',
            ConnSide::Back => 'B',
            ConnSide::Middle => 'M',
        });
        s.push_str(&c.count.to_string());
    }
    s
}
