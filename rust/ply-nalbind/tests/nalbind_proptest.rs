//! Property-based hardening of `ply-nalbind`. Guarantees over generated stitches and strings:
//!
//! * the legacy `parse(print(x)) == x` round-trip is identity, and so is the lenient one;
//! * `parse_strict(print(x))` is EXACT (no diagnostics) for every structure with at most one
//!   connection per side;
//! * text written with only the documented normalizations (case, whitespace, `Mid`, prefix
//!   connections, leading zeros, multi-loop skip groups) is accepted by strict mode losslessly;
//! * strict-accepted text round-trips exactly: its normalized print reparses strictly to the same
//!   structure, with `Exact` fidelity and the same normalized text;
//! * lenient never drops a non-whitespace character without a LOSSY diagnostic covering it, checked
//!   by an independent reader over the uncovered residue;
//! * spans are valid, fidelity and modes agree with the diagnostics, and the legacy `parse` agrees
//!   with lenient;
//! * nothing panics on arbitrary text or bytes (`parse`, `parse_lenient`, `parse_strict`, `diagram`,
//!   `validate`), and the `StitchType` JSON round-trip is identity.
//!
//! Run: `cargo test -p ply-nalbind --test nalbind_proptest`

use ply_nalbind::diagram::diagram;
use ply_nalbind::notation::{
    self, DiagnosticCode, Fidelity, NotationSeverity, OpaquePlacement, ParseMode, ParsedNotation,
};
use ply_nalbind::stitch::{ConnSide, Connection, Pass, PublishedCode, Step, StitchType, Twist};
use ply_nalbind::validate::validate;
use proptest::prelude::*;

fn arb_step() -> impl Strategy<Value = Step> {
    prop_oneof![
        Just(Step::Under),
        Just(Step::Over),
        Just(Step::SkippedUnder),
        Just(Step::SkippedOver),
        Just(Step::NoEngage),
    ]
}

fn arb_side() -> impl Strategy<Value = ConnSide> {
    prop_oneof![
        Just(ConnSide::Front),
        Just(ConnSide::Back),
        Just(ConnSide::Middle)
    ]
}

fn arb_twist() -> impl Strategy<Value = Twist> {
    prop_oneof![Just(Twist::Untwisted), Just(Twist::Twisted)]
}

/// Passes for the NOTATION round-trip: each pass has >= 1 step (real stitches have no empty passes,
/// and the parser never produces one).
fn arb_passes_nonempty() -> impl Strategy<Value = Vec<Pass>> {
    prop::collection::vec(
        prop::collection::vec(arb_step(), 1..6).prop_map(Pass::new),
        1..4,
    )
}

/// Connections the notation can round-trip: `side + count`, no `extra` (free text is not printed).
/// Sides may repeat (a faithful but ambiguous notation).
fn arb_conns_simple() -> impl Strategy<Value = Vec<Connection>> {
    prop::collection::vec(
        (arb_side(), 0u8..30).prop_map(|(side, count)| Connection::new(side, count)),
        0..3,
    )
}

/// Connections with at most one per side (what strict mode accepts), in any order, full count range.
fn arb_conns_distinct() -> impl Strategy<Value = Vec<Connection>> {
    (
        prop::option::of(any::<u8>()),
        prop::option::of(any::<u8>()),
        prop::option::of(any::<u8>()),
        0u8..6,
    )
        .prop_map(|(f, b, m, order)| {
            let mut v: Vec<Connection> = [
                f.map(|c| Connection::new(ConnSide::Front, c)),
                b.map(|c| Connection::new(ConnSide::Back, c)),
                m.map(|c| Connection::new(ConnSide::Middle, c)),
            ]
            .into_iter()
            .flatten()
            .collect();
            let shift = usize::from(order) % v.len().max(1);
            v.rotate_left(shift);
            if order >= 3 {
                v.reverse();
            }
            v
        })
}

/// A full (possibly degenerate) stitch for the no-panic + JSON-round-trip properties: passes may be
/// empty, connections may carry an `extra` escape-hatch string.
fn arb_stitch() -> impl Strategy<Value = StitchType> {
    (
        "[A-Za-z ]{0,10}",
        prop::collection::vec(
            prop::collection::vec(arb_step(), 0..6).prop_map(Pass::new),
            0..4,
        ),
        prop::collection::vec(
            (arb_side(), 0u8..30, prop::option::of("[a-z ]{0,8}"))
                .prop_map(|(side, count, extra)| Connection { side, count, extra }),
            0..3,
        ),
        prop::option::of((0u8..5, 0u8..5)),
        arb_twist(),
        prop::collection::vec("[a-z]{1,6}", 0..3),
        prop::collection::vec(("[UO/():-]{0,10}", "[a-z.]{1,10}"), 0..2),
        "[a-z .]{0,20}",
    )
        .prop_map(
            |(name, passes, connections, thumb_loops, twist, aka, codes, note)| StitchType {
                name,
                passes,
                connections,
                thumb_loops,
                twist,
                also_known_as: aka,
                codes: codes
                    .into_iter()
                    .map(|(code, source)| PublishedCode { code, source })
                    .collect(),
                note,
            },
        )
}

/// Notation-shaped noise: real symbols, near-misses, odd whitespace, and foreign characters, so the
/// interesting malformed cases (unmatched/nested groups, stray turns, `+`, detached counts) are hit
/// far more often than with uniform random text.
fn arb_notationish() -> impl Strategy<Value = String> {
    let fragments: Vec<&'static str> = vec![
        "U", "O", "u", "o", "-", "(", ")", "/", ":", "F", "B", "M", "f", "b", "Mid", "mid", "0",
        "1", "2", "9", "01", "999", "+", " ", "  ", "\t", "\u{a0}", "X", "é", "#", "UO", "(U)",
        "F1", "B1",
    ];
    prop::collection::vec(prop::sample::select(fragments), 0..24).prop_map(|v| v.concat())
}

/// Canonical text of a valid structure with ONE notation-shaped fragment spliced in at a random char
/// boundary, so each malformation is also exercised inside an otherwise strict-clean string (random
/// noise rarely produces one).
fn arb_single_corruption() -> impl Strategy<Value = String> {
    let fragments: Vec<&'static str> = vec![
        " ", "\t", "\u{a0}", "U", "o", "-", "(", ")", "()", "/", ":", "//", "F", "B1", "Mid", "0",
        "1", "01", "999", "+", "+1", "1+1", "X", "é",
    ];
    (
        arb_passes_nonempty(),
        arb_conns_distinct(),
        any::<usize>(),
        prop::sample::select(fragments),
    )
        .prop_map(|(passes, conns, at, fragment)| {
            let mut s = notation::print(&passes, &conns);
            let boundaries: Vec<usize> = (0..=s.len()).filter(|&b| s.is_char_boundary(b)).collect();
            s.insert_str(boundaries[at % boundaries.len()], fragment);
            s
        })
}

/// A structure rendered with ONLY documented normalizations, chosen by `style` bytes: case, the
/// `Mid` spelling, leading zeros, odd whitespace between tokens, prefix placement of connections,
/// and merging runs of skipped loops into one group.
fn render_normalized(passes: &[Pass], conns: &[Connection], style: &[u8], prefix: bool) -> String {
    let mut k = 0usize;
    let mut pick = |n: u8| -> u8 {
        let v = style[k % style.len()];
        k += 1;
        v % n
    };
    let mut path = String::new();
    for (pi, pass) in passes.iter().enumerate() {
        if pi > 0 {
            path.push(if pi == 1 { '/' } else { ':' });
        }
        let mut i = 0;
        while i < pass.steps.len() {
            let sep = ["", "", " ", "\t"][usize::from(pick(4))];
            path.push_str(sep);
            let letter = |s: Step, lower: bool| -> char {
                let c = match s {
                    Step::Under | Step::SkippedUnder => 'U',
                    Step::Over | Step::SkippedOver => 'O',
                    Step::NoEngage => '-',
                };
                if lower {
                    c.to_ascii_lowercase()
                } else {
                    c
                }
            };
            let skipped = |s: Step| matches!(s, Step::SkippedUnder | Step::SkippedOver);
            let step = pass.steps[i];
            if skipped(step) {
                // Merge a run of skipped loops into one group when the style says so.
                let merge = pick(2) == 1;
                let mut j = i + 1;
                if merge {
                    while j < pass.steps.len() && skipped(pass.steps[j]) {
                        j += 1;
                    }
                }
                path.push('(');
                for &s in &pass.steps[i..j] {
                    path.push(letter(s, pick(2) == 1));
                }
                path.push(')');
                i = j;
            } else {
                path.push(letter(step, pick(2) == 1));
                i += 1;
            }
        }
    }
    let mut conn_text = Vec::new();
    for c in conns {
        let side = match (c.side, pick(4)) {
            (ConnSide::Front, 0) => "f",
            (ConnSide::Front, _) => "F",
            (ConnSide::Back, 0) => "b",
            (ConnSide::Back, _) => "B",
            (ConnSide::Middle, 0) => "m",
            (ConnSide::Middle, 1) => "Mid",
            (ConnSide::Middle, 2) => "mID",
            (ConnSide::Middle, _) => "M",
        };
        let zeros = "0".repeat(usize::from(pick(3) / 2));
        conn_text.push(format!("{side}{zeros}{}", c.count));
    }
    let gap = |p: u8| ["", " ", "  ", "\u{a0}"][usize::from(p)];
    let mut out = String::new();
    if prefix {
        for t in &conn_text {
            out.push_str(t);
            out.push_str(gap(pick(4)));
        }
        out.push_str(&path);
    } else {
        out.push_str(&path);
        for t in &conn_text {
            out.push_str(gap(pick(4)));
            out.push_str(t);
        }
    }
    out
}

// --- an independent reader for the "no unmarked loss" property --------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Item {
    Step(Step),
    Turn,
}

fn structure_items(passes: &[Pass]) -> Vec<Item> {
    let mut items = Vec::new();
    for (k, p) in passes.iter().enumerate() {
        if k > 0 {
            items.push(Item::Turn);
        }
        items.extend(p.steps.iter().map(|&s| Item::Step(s)));
    }
    items
}

fn is_subsequence<T: PartialEq>(needle: &[T], haystack: &[T]) -> bool {
    let mut rest = haystack.iter();
    needle.iter().all(|n| rest.any(|h| h == n))
}

/// The source with whitespace and every character covered by a LOSSY diagnostic removed.
fn uncovered_residue(p: &ParsedNotation) -> String {
    p.source
        .char_indices()
        .filter(|&(b, c)| {
            !c.is_whitespace()
                && !p
                    .diagnostics
                    .iter()
                    .any(|d| d.code.is_lossy() && d.span.contains(b))
        })
        .map(|(_, c)| c)
        .collect()
}

/// Read the residue as well-formed notation: ASCII case-insensitive, `Mid` allowed, counts required,
/// skip groups one level deep and never holding `-`, a turn, or a connection, and connections in a
/// single block before or after the path. Anything else in it means a character was dropped,
/// reordered, or reinterpreted without a lossy diagnostic covering it. (An empty `()` is allowed:
/// a group's contents can be covered on their own, e.g. by `nested-group` or `skipped-no-engage`.)
#[allow(clippy::type_complexity)]
fn read_residue(residue: &str) -> Result<(Vec<Item>, Vec<(ConnSide, u64)>), String> {
    let chars: Vec<char> = residue.chars().map(|c| c.to_ascii_uppercase()).collect();
    let mut items = Vec::new();
    let mut conns = Vec::new();
    let mut in_group = false;
    let mut seen_path = false;
    let mut prefix_conns = false;
    let mut conn_after_path = false;
    let fail = |why: &str| Err(format!("{why} survived uncovered in residue {residue:?}"));
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if matches!(c, 'U' | 'O' | '-' | '(' | ')' | '/' | ':') {
            if conn_after_path {
                return fail("a path symbol after a connection");
            }
            seen_path = true;
        }
        match c {
            'U' => items.push(Item::Step(if in_group {
                Step::SkippedUnder
            } else {
                Step::Under
            })),
            'O' => items.push(Item::Step(if in_group {
                Step::SkippedOver
            } else {
                Step::Over
            })),
            '-' if in_group => return fail("a `-` inside a skip group"),
            '-' => items.push(Item::Step(Step::NoEngage)),
            '(' if in_group => return fail("a nested skip group"),
            '(' => in_group = true,
            ')' if !in_group => return fail("an unmatched `)`"),
            ')' => in_group = false,
            '/' | ':' if in_group => return fail("a turn inside a skip group"),
            '/' | ':' => items.push(Item::Turn),
            'F' | 'B' | 'M' if in_group => return fail("a connection inside a skip group"),
            'F' | 'B' | 'M' => {
                if seen_path {
                    conn_after_path = true;
                } else {
                    prefix_conns = true;
                }
                let side = match c {
                    'F' => ConnSide::Front,
                    'B' => ConnSide::Back,
                    _ => ConnSide::Middle,
                };
                let mut j = i + 1;
                if c == 'M' && chars.get(j) == Some(&'I') && chars.get(j + 1) == Some(&'D') {
                    j += 2;
                }
                let start = j;
                while chars.get(j).is_some_and(|d| d.is_ascii_digit()) {
                    j += 1;
                }
                if j == start {
                    return Err(format!("a bare side survived in residue {residue:?}"));
                }
                let value = chars[start..j].iter().fold(0u64, |acc, d| {
                    acc.saturating_mul(10)
                        .saturating_add(u64::from(d.to_digit(10).unwrap_or(0)))
                });
                conns.push((side, value));
                i = j;
                continue;
            }
            other => return fail(&format!("{other:?}")),
        }
        i += 1;
    }
    if in_group {
        return fail("an unclosed `(`");
    }
    if prefix_conns && conn_after_path {
        return fail("connections both before and after the path");
    }
    Ok((items, conns))
}

/// Apply ONLY the documented `Info` normalizations to `s`, independently of the parser: drop
/// whitespace between tokens, uppercase, `Mid` -> `M`, strip leading zeros, split multi-loop skip
/// groups, and move a prefix connection block after the path. `None` if `s` needs anything else.
/// Turns are copied verbatim, so a wrong or stray marker shows up as a mismatch, not as `None`.
fn documented_normalize(s: &str) -> Option<String> {
    let chars: Vec<char> = s.chars().map(|c| c.to_ascii_uppercase()).collect();
    let mut path = String::new();
    let mut prefix: Vec<String> = Vec::new();
    let mut suffix: Vec<String> = Vec::new();
    let mut group: Option<usize> = None; // loops in the open group
    let mut seen_path = false;
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if matches!(c, 'U' | 'O' | '-' | '(' | ')' | '/' | ':') {
            if !suffix.is_empty() {
                return None;
            }
            seen_path = true;
        }
        match (c, group) {
            (c, _) if c.is_whitespace() => {}
            ('U' | 'O', Some(n)) => {
                path.push_str(&format!("({c})"));
                group = Some(n + 1);
            }
            ('U' | 'O' | '-' | '/' | ':', None) => path.push(c),
            ('(', None) => group = Some(0),
            (')', Some(n)) if n > 0 => group = None,
            ('F' | 'B' | 'M', None) => {
                let mut j = i + 1;
                if c == 'M' && chars.get(j) == Some(&'I') && chars.get(j + 1) == Some(&'D') {
                    j += 2;
                }
                let start = j;
                while chars.get(j).is_some_and(|d| d.is_ascii_digit()) {
                    j += 1;
                }
                if j == start {
                    return None;
                }
                let digits: String = chars[start..j].iter().collect();
                let trimmed = digits.trim_start_matches('0');
                let text = format!("{c}{}", if trimmed.is_empty() { "0" } else { trimmed });
                if seen_path {
                    suffix.push(text);
                } else {
                    prefix.push(text);
                }
                i = j;
                continue;
            }
            _ => return None,
        }
        i += 1;
    }
    if group.is_some() || (!prefix.is_empty() && !suffix.is_empty()) {
        return None;
    }
    let mut out = path;
    for conn in prefix.into_iter().chain(suffix) {
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(&conn);
    }
    Some(out)
}

/// Checks shared by every lenient result.
fn check_lenient_invariants(s: &str, p: &ParsedNotation) -> Result<(), TestCaseError> {
    prop_assert_eq!(&p.source, s);
    prop_assert_eq!(p.mode, ParseMode::Lenient);

    // Spans are in range, on char boundaries, and sorted.
    for d in &p.diagnostics {
        prop_assert!(d.span.start <= d.span.end && d.span.end <= s.len());
        prop_assert!(s.is_char_boundary(d.span.start) && s.is_char_boundary(d.span.end));
        prop_assert_eq!(d.severity, d.code.severity());
    }
    prop_assert!(p
        .diagnostics
        .windows(2)
        .all(|w| (w[0].span.start, w[0].span.end) <= (w[1].span.start, w[1].span.end)));

    // Opaque tokens are verbatim and correctly attached.
    for o in &p.opaque {
        prop_assert_eq!(o.span.text(s), o.text.as_str());
        prop_assert!(!o.text.is_empty());
        if let OpaquePlacement::ConnectionSuffix { connection } = o.placement {
            let extra = p.connections[connection].extra.clone().unwrap_or_default();
            prop_assert!(
                extra.contains(&o.text),
                "{:?} not in extra {:?}",
                o.text,
                extra
            );
        }
    }

    // No empty pass, except the single pass of a notation with no step.
    let total: usize = p.passes.iter().map(|x| x.steps.len()).sum();
    if total == 0 {
        prop_assert_eq!(&p.passes, &vec![Pass::new(vec![])]);
        prop_assert!(p.diagnostics_with(DiagnosticCode::NoNeedlePath).count() == 1);
    } else {
        prop_assert!(p.passes.iter().all(|x| !x.steps.is_empty()));
    }

    // Fidelity agrees with the diagnostics, and Exact means the source is already canonical.
    let any_lossy = p.diagnostics.iter().any(|d| d.code.is_lossy());
    prop_assert_eq!(p.fidelity == Fidelity::Lossy, any_lossy);
    if p.fidelity == Fidelity::Exact {
        prop_assert_eq!(p.normalized(), s.to_string());
    }

    // No unmarked loss: whatever is not covered by a lossy diagnostic is represented, in order.
    let residue = uncovered_residue(p);
    let (items, conns) = read_residue(&residue).map_err(TestCaseError::fail)?;
    let structure = structure_items(&p.passes);
    prop_assert!(
        is_subsequence(&items, &structure),
        "uncovered path {:?} is not in the structure {:?} (source {:?})",
        items,
        structure,
        s
    );
    let structure_conns: Vec<(ConnSide, u64)> = p
        .connections
        .iter()
        .map(|c| (c.side, u64::from(c.count)))
        .collect();
    prop_assert!(
        is_subsequence(&conns, &structure_conns),
        "uncovered connections {:?} are not in {:?} (source {:?})",
        conns,
        structure_conns,
        s
    );
    Ok(())
}

/// Strict mode agrees with lenient, and an accepted result round-trips exactly.
fn check_strict(s: &str) -> Result<(), TestCaseError> {
    let lenient = notation::parse_lenient(s);
    match notation::parse_strict(s) {
        Ok(p) => {
            prop_assert!(lenient.max_severity() <= Some(NotationSeverity::Info));
            prop_assert_eq!(p.mode, ParseMode::Strict);
            prop_assert!(p.fidelity.is_authoritative());
            prop_assert!(p
                .diagnostics
                .iter()
                .all(|d| d.severity == NotationSeverity::Info));
            prop_assert_eq!(&p.passes, &lenient.passes);
            prop_assert_eq!(&p.connections, &lenient.connections);
            prop_assert!(p.opaque.is_empty());

            let normalized = p.normalized();
            // Strict accepts only documented normalizations: an independent normalizer that knows
            // nothing else must reach the same canonical text.
            prop_assert_eq!(
                documented_normalize(s),
                Some(normalized.clone()),
                "strict accepted {:?} through an undocumented normalization",
                s
            );
            let again = notation::parse_strict(&normalized).map_err(|e| {
                TestCaseError::fail(format!("normalized {normalized:?} of {s:?} refused: {e}"))
            })?;
            prop_assert_eq!(again.fidelity, Fidelity::Exact);
            prop_assert!(again.diagnostics.is_empty());
            prop_assert_eq!(&again.passes, &p.passes);
            prop_assert_eq!(&again.connections, &p.connections);
            prop_assert_eq!(again.normalized(), normalized);
        }
        Err(e) => {
            prop_assert!(lenient.max_severity() >= Some(NotationSeverity::Warning));
            prop_assert_eq!(&e.source, s);
            prop_assert!(e.blocking().count() > 0);
            prop_assert!(e.blocking().all(|d| d.severity == NotationSeverity::Error));
        }
    }
    Ok(())
}

/// The legacy `parse` is lenient minus warnings: `Err` exactly when lenient has an error.
fn check_legacy(s: &str) -> Result<(), TestCaseError> {
    let lenient = notation::parse_lenient(s);
    match notation::parse(s) {
        Ok((passes, conns)) => {
            prop_assert!(!lenient.has_errors());
            prop_assert_eq!(passes, lenient.passes);
            prop_assert_eq!(conns, lenient.connections);
        }
        Err(e) => {
            prop_assert!(lenient.has_errors());
            prop_assert!(e.to_string().starts_with("invalid Hansen notation:"));
        }
    }
    Ok(())
}

proptest! {
    /// `parse(print(passes, conns)) == (passes, conns)`: the legacy round-trip is identity.
    #[test]
    fn notation_round_trips(passes in arb_passes_nonempty(), conns in arb_conns_simple()) {
        let s = notation::print(&passes, &conns);
        let (p2, c2) = notation::parse(&s).expect("our own printed output must parse");
        prop_assert_eq!(p2, passes.clone());
        prop_assert_eq!(c2, conns.clone());
        let lenient = notation::parse_lenient(&s);
        prop_assert_eq!(&lenient.passes, &passes);
        prop_assert_eq!(&lenient.connections, &conns);
        prop_assert!(!lenient.is_lossy(), "printed output is never lossy: {:?}", lenient.diagnostics);
    }

    /// `parse_strict(print(x))` is EXACT for every structure strict mode can express.
    #[test]
    fn printed_structures_are_strict_exact(passes in arb_passes_nonempty(), conns in arb_conns_distinct()) {
        let s = notation::print(&passes, &conns);
        let p = notation::parse_strict(&s)
            .map_err(|e| TestCaseError::fail(format!("{s:?} refused: {e}")))?;
        prop_assert_eq!(p.fidelity, Fidelity::Exact);
        prop_assert!(p.diagnostics.is_empty(), "{:?}", p.diagnostics);
        prop_assert_eq!(p.passes, passes);
        prop_assert_eq!(p.connections, conns);
        prop_assert_eq!(p.source, s);
    }

    /// Text written with only documented normalizations is accepted by strict mode, losslessly.
    #[test]
    fn documented_normalizations_are_strict_and_lossless(
        passes in arb_passes_nonempty(),
        conns in arb_conns_distinct(),
        style in prop::collection::vec(any::<u8>(), 1..64),
        prefix in any::<bool>(),
    ) {
        let s = render_normalized(&passes, &conns, &style, prefix);
        let p = notation::parse_strict(&s)
            .map_err(|e| TestCaseError::fail(format!("{s:?} refused: {e}")))?;
        prop_assert_eq!(&p.passes, &passes, "source {:?}", s);
        prop_assert_eq!(&p.connections, &conns, "source {:?}", s);
        prop_assert_eq!(p.normalized(), notation::print(&passes, &conns));
        check_strict(&s)?;
    }

    /// Notation-shaped noise: every lenient invariant, strict agreement, and legacy agreement.
    #[test]
    fn notationish_text_upholds_every_invariant(s in arb_notationish()) {
        check_lenient_invariants(&s, &notation::parse_lenient(&s))?;
        check_strict(&s)?;
        check_legacy(&s)?;
    }

    /// One malformation inside otherwise valid text: every lenient invariant, strict agreement (an
    /// independent normalizer must reproduce any strict acceptance), and legacy agreement.
    #[test]
    fn single_corruptions_of_valid_text_uphold_every_invariant(s in arb_single_corruption()) {
        check_lenient_invariants(&s, &notation::parse_lenient(&s))?;
        check_strict(&s)?;
        check_legacy(&s)?;
    }

    /// No mode panics on arbitrary text, and the invariants hold there too.
    #[test]
    fn parse_never_panics_on_text(s in ".*") {
        let _ = notation::parse(&s);
        check_lenient_invariants(&s, &notation::parse_lenient(&s))?;
        check_strict(&s)?;
    }

    /// ...nor on arbitrary bytes read as lossy UTF-8.
    #[test]
    fn parse_never_panics_on_bytes(bytes in prop::collection::vec(any::<u8>(), 0..256)) {
        let s = String::from_utf8_lossy(&bytes);
        let _ = notation::parse(&s);
        check_lenient_invariants(&s, &notation::parse_lenient(&s))?;
        check_strict(&s)?;
    }

    /// `diagram` and `validate` never panic; the diagram stays consistent (one glyph per step, finite).
    #[test]
    fn diagram_and_validate_never_panic(st in arb_stitch()) {
        let total: usize = st.passes.iter().map(|p| p.steps.len()).sum();
        let d = diagram(&st);
        prop_assert_eq!(d.loops.len(), total);
        prop_assert!(d.width.is_finite() && d.height.is_finite() && d.width > 0.0);
        let _ = validate(&st);
    }

    /// `from_json(to_json(s)) == s`: the StitchType JSON round-trip is identity.
    #[test]
    fn stitch_json_round_trips(st in arb_stitch()) {
        let json = st.to_json().expect("serializes");
        let back = StitchType::from_json(&json).expect("parses back");
        prop_assert_eq!(back, st);
    }
}
