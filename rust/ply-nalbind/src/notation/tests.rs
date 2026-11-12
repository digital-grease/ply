//! Unit tests for the notation grammar, both parse modes, provenance, and the legacy entry points.

use super::*;
use crate::stitch::{ConnSide, Connection, Step};

use DiagnosticCode as C;
use NotationSeverity as S;

fn lenient(s: &str) -> ParsedNotation {
    parse_lenient(s)
}

fn codes(p: &ParsedNotation) -> Vec<DiagnosticCode> {
    p.diagnostics.iter().map(|d| d.code).collect()
}

/// The single diagnostic with `code` (fails if there are zero or several).
fn one(p: &ParsedNotation, code: DiagnosticCode) -> &NotationDiagnostic {
    let found: Vec<_> = p.diagnostics_with(code).collect();
    assert_eq!(
        found.len(),
        1,
        "expected exactly one {code} in {:?}, got {:?}",
        p.source,
        p.diagnostics
    );
    found[0]
}

/// Lenient parse of `src` reports exactly `expected` (code, byte span) pairs, in source order.
fn assert_lenient(src: &str, expected: &[(DiagnosticCode, usize, usize)]) -> ParsedNotation {
    let p = lenient(src);
    let got: Vec<(DiagnosticCode, usize, usize)> = p
        .diagnostics
        .iter()
        .map(|d| (d.code, d.span.start, d.span.end))
        .collect();
    assert_eq!(
        got, expected,
        "diagnostics for {src:?}: {:?}",
        p.diagnostics
    );
    for d in &p.diagnostics {
        assert_eq!(
            d.severity,
            d.code.severity(),
            "lenient keeps lenient severity"
        );
        assert!(!d.message.is_empty());
    }
    p
}

/// Strict parse of `src` is refused and reports `code` as an `Error`.
fn assert_strict_refuses(src: &str, code: DiagnosticCode) -> StrictRejection {
    let err = parse_strict(src).expect_err(src);
    assert!(
        err.blocking()
            .any(|d| d.code == code && d.severity == S::Error),
        "strict refusal of {src:?} lacks {code} as an error: {:?}",
        err.diagnostics
    );
    assert_eq!(err.source, src);
    err
}

fn conn(side: ConnSide, count: u8) -> Connection {
    Connection::new(side, count)
}

// --- canonical notation ----------------------------------------------------------------------------

#[test]
fn parses_oslo() {
    let (passes, conns) = parse("UO/UOO F1").unwrap();
    assert_eq!(passes.len(), 2);
    assert_eq!(passes[0].steps, vec![Step::Under, Step::Over]);
    assert_eq!(passes[1].steps, vec![Step::Under, Step::Over, Step::Over]);
    assert_eq!(conns, vec![conn(ConnSide::Front, 1)]);
}

#[test]
fn canonical_strings_are_exact_in_strict_mode() {
    for s in [
        "UO/UOO F1",
        "UOO/UUOO F2",
        "UU/OOO F2",
        "UUOOUU/OOUUOOO",
        "U(U)O/UO:UOO B1 F1", // multi-turn + skipped + two connections (Åsle-like)
        "-/-O F1 B1",         // no-engage looping (Coptic-like)
        "(U)(O)/-:U:O M0",
        "U F255",
    ] {
        let p = parse_strict(s).unwrap_or_else(|e| panic!("{s:?} refused: {e}"));
        assert_eq!(p.fidelity, Fidelity::Exact, "{s:?}");
        assert!(p.diagnostics.is_empty(), "{s:?}: {:?}", p.diagnostics);
        assert_eq!(p.normalized(), s);
        assert_eq!(p.source, s);
        assert_eq!(p.mode, ParseMode::Strict);
        let (lp, lc) = parse(s).unwrap();
        assert_eq!((lp, lc), (p.passes.clone(), p.connections.clone()));
    }
}

#[test]
fn skipped_loops_and_no_engage() {
    let (passes, _) = parse("U(UU)O-").unwrap();
    assert_eq!(
        passes[0].steps,
        vec![
            Step::Under,
            Step::SkippedUnder,
            Step::SkippedUnder,
            Step::Over,
            Step::NoEngage
        ]
    );
}

#[test]
fn bare_side_defaults_to_one_and_mid_is_accepted() {
    // Legacy behavior is unchanged; the new modes say what was assumed.
    let (_, conns) = parse("UO/UOO F Mid2").unwrap();
    assert_eq!(
        conns,
        vec![conn(ConnSide::Front, 1), conn(ConnSide::Middle, 2)]
    );
    let p = assert_lenient(
        "UO/UOO F Mid2",
        &[(C::MissingCount, 7, 8), (C::MidAlias, 9, 12)],
    );
    assert!(p.is_lossy());
    assert_strict_refuses("UO/UOO F Mid2", C::MissingCount);
}

#[test]
fn unknown_character_errors_not_panics() {
    assert!(parse("UO/XYZ").is_err());
}

// --- the verified problems from the audit, one by one ---------------------------------------------

#[test]
fn unmatched_open_paren_does_not_leak_a_skip_across_the_turn() {
    // Old behavior: `U(U)(O)/(U)(O)(O) F1`, validated clean.
    let p = assert_lenient("U(UO/UOO F1", &[(C::UnmatchedOpenParen, 1, 2)]);
    assert_eq!(p.normalized(), "UUO/UOO F1", "the stray `(` skips nothing");
    assert!(p.has_errors());
    assert_eq!(p.fidelity, Fidelity::Lossy);
    assert_strict_refuses("U(UO/UOO F1", C::UnmatchedOpenParen);
    let err = parse("U(UO/UOO F1").unwrap_err().to_string();
    assert!(err.starts_with("invalid Hansen notation:"), "{err}");
    assert!(err.contains("at position 1"), "{err}");
}

#[test]
fn unmatched_close_paren_is_an_error() {
    let p = assert_lenient("U)O/UOO F1", &[(C::UnmatchedCloseParen, 1, 2)]);
    assert_eq!(p.normalized(), "UO/UOO F1");
    assert_strict_refuses("U)O/UOO F1", C::UnmatchedCloseParen);
    assert!(parse("U)O").is_err());
}

#[test]
fn a_group_cannot_span_a_turn() {
    let p = assert_lenient(
        "U(U/O)O",
        &[
            (C::UnmatchedOpenParen, 1, 2),
            (C::UnmatchedCloseParen, 5, 6),
        ],
    );
    assert_eq!(p.normalized(), "UU/OO");
}

#[test]
fn nested_group_is_flagged() {
    let p = assert_lenient("U((U))O", &[(C::NestedGroup, 2, 5)]);
    assert_eq!(p.normalized(), "U(U)O");
    assert_eq!(p.fidelity, Fidelity::Lossy);
    assert_strict_refuses("U((U))O", C::NestedGroup);
}

#[test]
fn empty_group_is_flagged() {
    let p = assert_lenient("U()O", &[(C::EmptyGroup, 1, 3)]);
    assert_eq!(p.normalized(), "UO");
    assert_strict_refuses("U()O", C::EmptyGroup);
    // Whitespace inside the empty group is covered by the group's own span.
    let p = lenient("U( )O");
    assert_eq!(one(&p, C::EmptyGroup).span, Span::new(1, 4));
}

#[test]
fn colon_as_first_turn_is_a_marker_mismatch() {
    // Old behavior: silently printed back as `UO/UOO`.
    let p = assert_lenient("UO:UOO", &[(C::TurnMarkerMismatch, 2, 3)]);
    assert_eq!(p.normalized(), "UO/UOO");
    assert_eq!(p.passes.len(), 2, "still read as a turn");
    assert_eq!(p.fidelity, Fidelity::Lossy);
    assert_strict_refuses("UO:UOO", C::TurnMarkerMismatch);
}

#[test]
fn slash_as_a_later_turn_is_a_marker_mismatch() {
    let p = assert_lenient("UO/UO/UOO", &[(C::TurnMarkerMismatch, 5, 6)]);
    assert_eq!(p.normalized(), "UO/UO:UOO");
    assert_strict_refuses("UO/UO/UOO", C::TurnMarkerMismatch);
}

#[test]
fn doubled_turn_leaves_no_empty_pass() {
    // Old behavior: `UO/:UOO`, an empty middle pass that validated clean.
    let p = assert_lenient("UO//UOO", &[(C::DoubledTurn, 3, 4)]);
    assert_eq!(p.passes.len(), 2);
    assert_eq!(p.normalized(), "UO/UOO");
    assert_strict_refuses("UO//UOO", C::DoubledTurn);
    let p = assert_lenient("UO/:UOO", &[(C::DoubledTurn, 3, 4)]);
    assert_eq!(p.normalized(), "UO/UOO");
}

#[test]
fn trailing_turn_is_diagnosed_not_silently_dropped() {
    // Replaces the old `trailing_turn_is_dropped`, which asserted the silent drop as intended.
    let p = assert_lenient("UO/UOO//", &[(C::TrailingTurn, 6, 8)]);
    assert_eq!(p.normalized(), "UO/UOO");
    assert_eq!(p.fidelity, Fidelity::Lossy);
    assert_eq!(
        p.source, "UO/UOO//",
        "the dropped turns survive in the source"
    );
    assert_strict_refuses("UO/UOO//", C::TrailingTurn);
    let p = assert_lenient("UO/", &[(C::TrailingTurn, 2, 3)]);
    assert_eq!(p.passes.len(), 1);
    // The legacy path still returns the best-effort structure for this warning.
    assert_eq!(parse("UO/").unwrap().0.len(), 1);
}

#[test]
fn leading_turn_is_dropped_and_flagged() {
    let p = assert_lenient("/UO/UOO", &[(C::LeadingTurn, 0, 1)]);
    assert_eq!(
        p.normalized(),
        "UO/UOO",
        "the remaining turn is the first, so it is `/`"
    );
    assert_strict_refuses("/UO/UOO", C::LeadingTurn);
}

#[test]
fn a_pass_with_tokens_but_no_step_is_an_empty_pass() {
    let p = assert_lenient("UO/()/UOO", &[(C::EmptyGroup, 3, 5), (C::EmptyPass, 3, 6)]);
    assert_eq!(p.normalized(), "UO/UOO");
    assert_strict_refuses("UO/()/UOO", C::EmptyPass);
    // Regression (found by the residue property): the stranded token can follow a dropped turn,
    // and the span must still cover that turn.
    let p = assert_lenient(
        "UO//F/UO",
        &[
            (C::EmptyPass, 3, 6),
            (C::MissingCount, 4, 5),
            (C::ConnectionOutOfPlace, 4, 5),
        ],
    );
    assert_eq!(p.normalized(), "UO/UO F1");
}

#[test]
fn turns_without_any_step() {
    let p = assert_lenient("/", &[(C::EmptyPass, 0, 1), (C::NoNeedlePath, 0, 1)]);
    assert_eq!(p.passes, vec![Pass::new(vec![])]);
}

#[test]
fn plus_dialect_is_preserved_verbatim_and_diagnosed() {
    // Replaces the old `plus_dialect_is_tolerated`, which asserted that `+1` was silently dropped.
    let src = "U(U)O/UO:UOO F1+1";
    let p = assert_lenient(src, &[(C::UnsupportedDialect, 15, 17)]);
    assert_eq!(p.connections.len(), 1);
    assert_eq!(p.connections[0].side, ConnSide::Front);
    assert_eq!(p.connections[0].count, 1);
    assert_eq!(
        p.connections[0].extra.as_deref(),
        Some("+1"),
        "kept verbatim"
    );
    assert_eq!(
        p.opaque,
        vec![OpaqueToken {
            text: "+1".into(),
            span: Span::new(15, 17),
            placement: OpaquePlacement::ConnectionSuffix { connection: 0 },
        }]
    );
    assert_eq!(p.fidelity, Fidelity::Lossy);
    assert_strict_refuses(src, C::UnsupportedDialect);
    // The legacy path accepts it (a warning) and now carries the suffix instead of dropping it.
    let (_, conns) = parse(src).unwrap();
    assert_eq!(conns[0].extra.as_deref(), Some("+1"));
}

#[test]
fn plus_between_connections_keeps_the_plus_and_reads_the_next_connection() {
    let p = assert_lenient(
        "UO/UOO F1+B1",
        &[
            (C::UnsupportedDialect, 9, 10),
            (C::WhitespaceNormalized, 10, 12),
        ],
    );
    assert_eq!(p.connections[0].extra.as_deref(), Some("+"));
    assert_eq!(p.connections[1], conn(ConnSide::Back, 1));
    assert_eq!(p.normalized(), "UO/UOO F1 B1");
}

#[test]
fn plus_inside_the_needle_path_is_a_standalone_opaque_token() {
    let p = assert_lenient("U+O", &[(C::UnsupportedDialect, 1, 2)]);
    assert_eq!(p.normalized(), "UO");
    assert_eq!(p.opaque[0].placement, OpaquePlacement::Standalone);
    assert_eq!(p.opaque[0].text, "+");
}

#[test]
fn thumb_loop_alias_is_one_unsupported_token() {
    let p = assert_lenient(
        "2+2+2",
        &[(C::UnsupportedDialect, 0, 5), (C::NoNeedlePath, 0, 5)],
    );
    assert_eq!(p.opaque.len(), 1);
    assert_eq!(p.opaque[0].text, "2+2+2");
}

#[test]
fn asle_alternate_code_is_connection_only_and_unsupported() {
    // `F1+1` is the dictionary's "alt form" for Åsle. It has no needle path and uses the `+`
    // dialect, so strict refuses it and lenient keeps the `+1` verbatim on the F1 connection.
    let p = assert_lenient(
        "F1+1",
        &[(C::NoNeedlePath, 0, 4), (C::UnsupportedDialect, 2, 4)],
    );
    assert_eq!(p.connections[0].extra.as_deref(), Some("+1"));
    assert_eq!(p.passes, vec![Pass::new(vec![])]);
    assert_strict_refuses("F1+1", C::UnsupportedDialect);
}

#[test]
fn connection_inside_the_path_is_out_of_place() {
    // Old behavior: silently moved to the end.
    let p = assert_lenient("UF1O/UOO", &[(C::ConnectionOutOfPlace, 1, 3)]);
    assert_eq!(p.normalized(), "UO/UOO F1");
    assert_eq!(p.fidelity, Fidelity::Lossy);
    assert_strict_refuses("UF1O/UOO", C::ConnectionOutOfPlace);
    // A connection inside a skip group is inside the path, even at the path's ends.
    let p = assert_lenient("U(UF1)", &[(C::ConnectionOutOfPlace, 3, 5)]);
    assert_eq!(p.normalized(), "U(U) F1");
    assert_strict_refuses("U(UF1)", C::ConnectionOutOfPlace);
    assert_lenient("(F1U)O", &[(C::ConnectionOutOfPlace, 1, 3)]);
    // A connection followed by a step is also before the end of the path (and the spaces around it
    // are inside the path, so they are non-canonical too).
    assert_lenient(
        "UO/UOO F1 U",
        &[
            (C::WhitespaceNormalized, 6, 7),
            (C::ConnectionOutOfPlace, 7, 9),
            (C::WhitespaceNormalized, 9, 10),
        ],
    );
}

#[test]
fn prefix_connections_are_a_documented_normalization() {
    let p = assert_lenient(
        "F1 UO/UOO",
        &[(C::ConnectionPrefix, 0, 2), (C::WhitespaceNormalized, 2, 3)],
    );
    assert_eq!(p.fidelity, Fidelity::Normalized);
    let strict = parse_strict("F1 UO/UOO").unwrap();
    assert_eq!(strict.normalized(), "UO/UOO F1");
}

#[test]
fn mixed_prefix_and_suffix_connections_are_out_of_place() {
    let p = assert_lenient(
        "F1 UO/UOO B1",
        &[
            (C::ConnectionOutOfPlace, 0, 2),
            (C::WhitespaceNormalized, 2, 3),
        ],
    );
    assert_eq!(p.normalized(), "UO/UOO F1 B1");
    assert_strict_refuses("F1 UO/UOO B1", C::ConnectionOutOfPlace);
}

#[test]
fn count_out_of_range_is_flagged_not_silently_saturated() {
    let p = assert_lenient("UO/UOO F999", &[(C::CountOutOfRange, 7, 11)]);
    assert_eq!(p.connections[0].count, 255);
    assert!(p.has_errors());
    assert_strict_refuses("UO/UOO F999", C::CountOutOfRange);
    assert!(parse("UO/UOO F999").is_err());
    // The boundary is accepted.
    assert!(parse_strict("UO/UOO F255").is_ok());
    assert_lenient("UO/UOO F256", &[(C::CountOutOfRange, 7, 11)]);
    // An absurd digit run neither overflows nor panics.
    let long = format!("UO F{}", "9".repeat(200));
    assert_eq!(lenient(&long).connections[0].count, 255);
}

#[test]
fn detached_count_is_joined_with_a_warning() {
    // Old behavior: `F` alone meant F1 but `F 1` was an error.
    let p = assert_lenient("UO/UOO F 1", &[(C::DetachedCount, 7, 10)]);
    assert_eq!(p.connections, vec![conn(ConnSide::Front, 1)]);
    assert_eq!(p.fidelity, Fidelity::Lossy);
    assert_strict_refuses("UO/UOO F 1", C::DetachedCount);
    let p = assert_lenient("UO/UOO F\t2", &[(C::DetachedCount, 7, 10)]);
    assert_eq!(p.connections, vec![conn(ConnSide::Front, 2)]);
}

#[test]
fn bare_side_is_a_missing_count() {
    let p = assert_lenient("UO/UOO F", &[(C::MissingCount, 7, 8)]);
    assert_eq!(p.connections, vec![conn(ConnSide::Front, 1)]);
    assert_strict_refuses("UO/UOO F", C::MissingCount);
}

#[test]
fn leading_zero_count_is_an_info_normalization() {
    let p = assert_lenient("UO/UOO F01", &[(C::CountLeadingZero, 8, 10)]);
    assert_eq!(p.fidelity, Fidelity::Normalized);
    assert_eq!(
        parse_strict("UO/UOO F01").unwrap().normalized(),
        "UO/UOO F1"
    );
    // A lone zero is canonical.
    assert!(lenient("UO/UOO F0").diagnostics.is_empty());
}

// --- whitespace and case policy -------------------------------------------------------------------

#[test]
fn whitespace_policy_tab_nbsp_and_spacing_are_info() {
    for (src, span) in [
        ("UO/UOO\tF1", (6, 7)),
        ("UO/UOO\u{a0}F1", (6, 8)), // NBSP is two bytes
        ("UO/UOO  F1", (6, 8)),
        (" UO/UOO F1", (0, 1)),
        ("UO/UOO F1 ", (9, 10)),
        ("UO /UOO F1", (2, 3)),
    ] {
        let p = assert_lenient(src, &[(C::WhitespaceNormalized, span.0, span.1)]);
        assert_eq!(p.fidelity, Fidelity::Normalized, "{src:?}");
        let strict = parse_strict(src).unwrap_or_else(|e| panic!("{src:?}: {e}"));
        assert_eq!(strict.normalized(), "UO/UOO F1", "{src:?}");
        assert_eq!(strict.source, src, "the original whitespace is kept");
    }
}

#[test]
fn missing_space_before_a_connection_is_info() {
    let p = assert_lenient("UO/UOOF1", &[(C::WhitespaceNormalized, 6, 8)]);
    assert_eq!(p.normalized(), "UO/UOO F1");
    // The design doc writes Coptic with concatenated connections.
    let p = assert_lenient("-/-O F1B1", &[(C::WhitespaceNormalized, 7, 9)]);
    assert_eq!(
        parse_strict("-/-O F1B1").unwrap().normalized(),
        "-/-O F1 B1"
    );
    assert_eq!(p.fidelity, Fidelity::Normalized);
}

#[test]
fn spaced_out_letters_are_accepted() {
    let p = parse_strict("U O O / U U O O  F2").unwrap();
    assert_eq!(p.normalized(), "UOO/UUOO F2");
    assert_eq!(p.fidelity, Fidelity::Normalized);
    assert!(p
        .diagnostics
        .iter()
        .all(|d| d.code == C::WhitespaceNormalized));
}

#[test]
fn case_policy_lowercase_is_info_and_merged_per_run() {
    let p = assert_lenient(
        "uo/uoo f1",
        &[
            (C::CaseNormalized, 0, 2),
            (C::CaseNormalized, 3, 6),
            (C::CaseNormalized, 7, 8),
        ],
    );
    assert_eq!(p.fidelity, Fidelity::Normalized);
    assert_eq!(parse_strict("uo/uoo f1").unwrap().normalized(), "UO/UOO F1");
    let p = assert_lenient(
        "UO/UOO mid2",
        &[(C::CaseNormalized, 7, 8), (C::MidAlias, 7, 10)],
    );
    assert_eq!(p.normalized(), "UO/UOO M2");
}

#[test]
fn multi_loop_skip_group_is_split_when_printed() {
    let p = assert_lenient("U(UU)O-", &[(C::GroupSplit, 1, 5)]);
    assert_eq!(p.fidelity, Fidelity::Normalized);
    assert_eq!(parse_strict("U(UU)O-").unwrap().normalized(), "U(U)(U)O-");
}

#[test]
fn skipped_no_engage_is_lossy() {
    let p = assert_lenient("U(-)O", &[(C::SkippedNoEngage, 2, 3)]);
    assert_eq!(
        p.passes[0].steps,
        vec![Step::Under, Step::NoEngage, Step::Over]
    );
    assert_strict_refuses("U(-)O", C::SkippedNoEngage);
}

// --- unknown text and suffixes ----------------------------------------------------------------------

#[test]
fn unknown_suffix_is_kept_verbatim_on_the_connection() {
    let p = assert_lenient("UO/UOO F1x?", &[(C::UnexpectedCharacter, 9, 11)]);
    assert_eq!(p.connections[0].extra.as_deref(), Some("x?"));
    assert_eq!(
        p.opaque[0].placement,
        OpaquePlacement::ConnectionSuffix { connection: 0 }
    );
    assert!(p.has_errors());
    assert!(parse("UO/UOO F1x?").is_err());
    // Several glued pieces become one verbatim `extra`, each piece diagnosed.
    let p = assert_lenient(
        "UO B2*+3",
        &[
            (C::UnexpectedCharacter, 5, 6),
            (C::UnsupportedDialect, 6, 8),
        ],
    );
    assert_eq!(p.connections[0].extra.as_deref(), Some("*+3"));
    assert_eq!(p.opaque.len(), 2);
}

#[test]
fn unknown_characters_are_opaque_with_char_boundary_spans() {
    // The pass after `/` holds no step (only opaque text), so the turn is also trailing.
    let p = assert_lenient(
        "UO/XYZ",
        &[(C::TrailingTurn, 2, 3), (C::UnexpectedCharacter, 3, 6)],
    );
    assert_eq!(p.opaque[0].text, "XYZ");
    assert_eq!(p.opaque[0].placement, OpaquePlacement::Standalone);
    let err = parse("UO/XYZ").unwrap_err().to_string();
    assert!(err.contains("at position 3"), "{err}");

    // Multi-byte characters: spans are byte offsets on char boundaries; the legacy message keeps
    // reporting a character position.
    let p = assert_lenient(
        "UO/é",
        &[(C::TrailingTurn, 2, 3), (C::UnexpectedCharacter, 3, 5)],
    );
    assert_eq!(p.opaque[0].text, "é");
    let p = assert_lenient(
        "é UO/UOO F1",
        &[
            (C::UnexpectedCharacter, 0, 2),
            (C::WhitespaceNormalized, 2, 3),
        ],
    );
    assert_eq!(p.normalized(), "UO/UOO F1");
    let err = parse("UOé#").unwrap_err().to_string();
    assert!(err.contains("at position 2"), "{err}");
}

#[test]
fn a_stray_number_is_unexpected() {
    let p = assert_lenient("UO2/UOO", &[(C::UnexpectedCharacter, 2, 3)]);
    assert_eq!(p.normalized(), "UO/UOO");
}

// --- connections ----------------------------------------------------------------------------------

#[test]
fn duplicate_connection_is_kept_and_flagged() {
    let p = assert_lenient("UO/UOO F1 F1", &[(C::DuplicateConnection, 10, 12)]);
    assert_eq!(
        p.connections,
        vec![conn(ConnSide::Front, 1), conn(ConnSide::Front, 1)]
    );
    assert_eq!(p.fidelity, Fidelity::Exact, "faithful, just ambiguous");
    assert_eq!(p.normalized(), "UO/UOO F1 F1");
    assert_strict_refuses("UO/UOO F1 F1", C::DuplicateConnection);
    assert_eq!(parse("UO/UOO F1 F1").unwrap().1.len(), 2);
}

#[test]
fn contradictory_connection_is_kept_and_flagged() {
    let p = assert_lenient("UU/OOO F1 F2", &[(C::ContradictoryConnection, 10, 12)]);
    assert_eq!(p.connections.len(), 2);
    assert_strict_refuses("UU/OOO F1 F2", C::ContradictoryConnection);
    // Different sides do not conflict (Åsle, Coptic).
    assert!(parse_strict("U(U)O/UO:UOO B1 F1").is_ok());
    // A differing unmodeled suffix makes same-count connections contradictory, not duplicates.
    let p = lenient("UO F1 F1+1");
    assert_eq!(one(&p, C::ContradictoryConnection).span, Span::new(6, 8));
}

// --- empty input ----------------------------------------------------------------------------------

#[test]
fn empty_notation_has_no_needle_path() {
    let p = assert_lenient("", &[(C::NoNeedlePath, 0, 0)]);
    assert_eq!(p.passes, vec![Pass::new(vec![])]);
    assert_eq!(
        p.fidelity,
        Fidelity::Exact,
        "an empty structure faithfully represents nothing"
    );
    assert_strict_refuses("", C::NoNeedlePath);
    // Legacy behavior is unchanged.
    assert_eq!(parse("").unwrap(), (vec![Pass::new(vec![])], vec![]));
}

#[test]
fn connections_only_print_without_a_leading_space() {
    let p = lenient("F1 B2");
    assert_eq!(codes(&p), vec![C::NoNeedlePath]);
    assert_eq!(p.normalized(), "F1 B2");
}

// --- provenance, fidelity, modes ------------------------------------------------------------------

#[test]
fn lenient_keeps_the_exact_source() {
    let src = " u(U o/UOO\u{a0}F1+1 #";
    let p = lenient(src);
    assert_eq!(p.source, src);
    assert_eq!(p.mode, ParseMode::Lenient);
    assert_eq!(p.fidelity, Fidelity::Lossy);
    for o in &p.opaque {
        assert_eq!(o.span.text(src), o.text);
    }
}

#[test]
fn strict_rejection_reports_blocking_diagnostics_as_errors_and_keeps_info() {
    let err = parse_strict("uo:uoo").unwrap_err();
    assert_eq!(err.codes(), vec![C::TurnMarkerMismatch]);
    let case: Vec<_> = err
        .diagnostics
        .iter()
        .filter(|d| d.code == C::CaseNormalized)
        .collect();
    assert_eq!(case.len(), 2);
    assert!(case.iter().all(|d| d.severity == S::Info));
    let lenient_mismatch = one(&lenient("uo:uoo"), C::TurnMarkerMismatch).severity;
    assert_eq!(lenient_mismatch, S::Warning);
    let shown = err.to_string();
    assert!(shown.starts_with("invalid Hansen notation:"), "{shown}");
    assert!(shown.contains("at position 2"), "{shown}");
}

#[test]
fn strict_success_has_only_info_and_lenient_agrees() {
    for src in [
        "UO/UOO F1",
        "uo/uoo f1",
        "F1 UO/UOO",
        "U(UU)O",
        "UO/UOO\tMid02",
    ] {
        let s = parse_strict(src).unwrap();
        let l = lenient(src);
        assert!(s.diagnostics.iter().all(|d| d.severity == S::Info));
        assert_eq!(s.passes, l.passes);
        assert_eq!(s.connections, l.connections);
        assert_eq!(s.diagnostics, l.diagnostics);
        assert!(s.fidelity.is_authoritative());
    }
}

#[test]
fn exact_fidelity_means_the_source_is_canonical() {
    for src in [
        "UO/UOO F1",
        "UO/UOO F1 ",
        "uo/uoo f1",
        "U(UU)O",
        "UO:UOO",
        "UO/UOO F1 F1",
    ] {
        let p = lenient(src);
        if p.fidelity == Fidelity::Exact {
            assert_eq!(p.normalized(), src);
        } else {
            assert_ne!(p.normalized(), src, "{src:?} is {:?}", p.fidelity);
        }
    }
}

#[test]
fn diagnostics_are_sorted_by_span() {
    let p = lenient("U)O( / ( ) F999 x f");
    let starts: Vec<usize> = p.diagnostics.iter().map(|d| d.span.start).collect();
    let mut sorted = starts.clone();
    sorted.sort_unstable();
    assert_eq!(starts, sorted);
}

#[test]
fn legacy_parse_accepts_warnings_and_rejects_errors() {
    // Warnings: the best-effort structure, as before.
    assert_eq!(parse("UO:UOO").unwrap().0.len(), 2);
    assert_eq!(parse("U((U))O").unwrap().0[0].steps.len(), 3);
    assert_eq!(
        parse("U+O").unwrap().0[0].steps,
        vec![Step::Under, Step::Over]
    );
    // Errors: refused, where the old parser silently produced a wrong structure.
    for src in ["U(UO/UOO F1", "U)O", "UO F999", "UO/XYZ"] {
        assert!(parse(src).is_err(), "{src:?}");
    }
}

// --- the code table ---------------------------------------------------------------------------------

#[test]
fn code_strings_are_stable() {
    let expected = [
        "unexpected-character",
        "unmatched-open-paren",
        "unmatched-close-paren",
        "count-out-of-range",
        "nested-group",
        "empty-group",
        "skipped-no-engage",
        "leading-turn",
        "trailing-turn",
        "doubled-turn",
        "empty-pass",
        "turn-marker-mismatch",
        "connection-out-of-place",
        "missing-count",
        "detached-count",
        "unsupported-dialect",
        "no-needle-path",
        "duplicate-connection",
        "contradictory-connection",
        "whitespace-normalized",
        "case-normalized",
        "mid-alias",
        "connection-prefix",
        "count-leading-zero",
        "group-split",
    ];
    let actual: Vec<&str> = DiagnosticCode::ALL.iter().map(|c| c.as_str()).collect();
    assert_eq!(actual, expected);
    for code in DiagnosticCode::ALL {
        let json = serde_json::to_string(&code).unwrap();
        assert_eq!(json, format!("\"{}\"", code.as_str()), "serde form matches");
        assert_eq!(DiagnosticCode::from_code(code.as_str()), Some(code));
        assert_eq!(code.to_string(), code.as_str());
    }
    assert_eq!(DiagnosticCode::from_code("nope"), None);
}

#[test]
fn every_lossy_code_is_at_least_a_warning() {
    for code in DiagnosticCode::ALL {
        if code.is_lossy() {
            assert!(
                code.severity() >= S::Warning,
                "{code} is lossy but {:?}",
                code.severity()
            );
        }
        if code.severity() == S::Info {
            assert!(!code.is_lossy(), "{code}");
        }
    }
}

#[test]
fn parsed_notation_serializes() {
    let p = lenient("UO/UOO F1+1");
    let json = serde_json::to_string(&p).unwrap();
    assert!(json.contains("\"unsupported-dialect\""), "{json}");
    let back: ParsedNotation = serde_json::from_str(&json).unwrap();
    assert_eq!(back, p);
}
