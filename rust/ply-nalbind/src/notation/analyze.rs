//! The notation analyzer: token stream -> best-effort structure + diagnostics (at lenient severity).
//! Both parse modes run this; they differ only in how they treat the resulting diagnostics.

use std::collections::HashSet;

use super::diagnostic::{DiagnosticCode as Code, NotationDiagnostic, Span};
use super::lexer::{lex, ConnLex, CountForm, OpaqueKind, StepGlyph, Token, TokenKind, TurnMarker};
use super::parsed::{OpaquePlacement, OpaqueToken};
use crate::stitch::{ConnSide, Connection, Pass, Step};

/// The largest connection count the model can hold.
const MAX_COUNT: u64 = u8::MAX as u64;

pub(super) struct Analysis {
    pub passes: Vec<Pass>,
    pub connections: Vec<Connection>,
    pub opaque: Vec<OpaqueToken>,
    /// Sorted by span start; severities are the codes' lenient severities.
    pub diagnostics: Vec<NotationDiagnostic>,
}

/// Where a connection token sits relative to the path extent (its steps and skip-group parens).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Placement {
    Prefix,
    Suffix,
    Inside,
}

/// The tokens between two turns (or the source ends).
struct RawPass {
    /// The turn token that opens this pass (`None` for the first pass).
    opener: Option<usize>,
    /// Every non-turn token in the pass, in order.
    tokens: Vec<usize>,
    steps: Vec<Step>,
}

struct Diags<'a> {
    src: &'a str,
    out: Vec<NotationDiagnostic>,
}

impl Diags<'_> {
    fn push(&mut self, code: Code, span: Span, message: String) {
        self.out.push(NotationDiagnostic::new(code, span, message));
    }

    fn text(&self, span: Span) -> &str {
        span.text(self.src)
    }
}

fn side_letter(side: ConnSide) -> char {
    match side {
        ConnSide::Front => 'F',
        ConnSide::Back => 'B',
        ConnSide::Middle => 'M',
    }
}

fn quote(text: &str) -> String {
    format!("`{}`", text.escape_debug())
}

pub(super) fn analyze(src: &str) -> Analysis {
    let lexed = lex(src);
    let tokens = &lexed.tokens;
    let mut d = Diags {
        src,
        out: Vec::new(),
    };

    token_diagnostics(tokens, &mut d);

    // --- connection placement ------------------------------------------------------------------
    // The path extent is its steps and skip-group parens (so a connection inside a group, as in
    // `U(UF1)` or `(F1U)`, is out of place). Turns are left out: a stray turn at either end is
    // diagnosed on its own and does not make an adjacent connection misplaced.
    let path_tokens: Vec<usize> = (0..tokens.len())
        .filter(|&i| {
            matches!(
                tokens[i].kind,
                TokenKind::Step { .. } | TokenKind::Open | TokenKind::Close
            )
        })
        .collect();
    let conn_tokens: Vec<usize> = (0..tokens.len())
        .filter(|&i| matches!(tokens[i].kind, TokenKind::Conn(_)))
        .collect();
    let placements: Vec<Placement> = conn_tokens
        .iter()
        .map(|&i| match (path_tokens.first(), path_tokens.last()) {
            (Some(&first), _) if i < first => Placement::Prefix,
            (Some(_), Some(&last)) if i < last => Placement::Inside,
            _ => Placement::Suffix,
        })
        .collect();
    let has_suffix = placements.contains(&Placement::Suffix);
    for (&ti, &placement) in conn_tokens.iter().zip(&placements) {
        let span = tokens[ti].span;
        let text = quote(d.text(span));
        match placement {
            Placement::Inside => d.push(
                Code::ConnectionOutOfPlace,
                span,
                format!(
                    "connection {text} is written inside the needle path; its position there is \
                     not modeled and it is listed with the connections after the path"
                ),
            ),
            Placement::Prefix if has_suffix => d.push(
                Code::ConnectionOutOfPlace,
                span,
                format!(
                    "connection {text} is written before the needle path while other connections \
                     follow it; the split placement is not modeled and it is listed in source order \
                     after the path"
                ),
            ),
            Placement::Prefix => d.push(
                Code::ConnectionPrefix,
                span,
                format!("connection {text} is written before the needle path; printed after it"),
            ),
            Placement::Suffix => {}
        }
    }

    // --- passes: split at turns, match parens, read steps ----------------------------------------
    let mut raw: Vec<RawPass> = vec![RawPass {
        opener: None,
        tokens: Vec::new(),
        steps: Vec::new(),
    }];
    for (i, t) in tokens.iter().enumerate() {
        if let TokenKind::Turn(_) = t.kind {
            raw.push(RawPass {
                opener: Some(i),
                tokens: Vec::new(),
                steps: Vec::new(),
            });
        } else if let Some(last) = raw.last_mut() {
            last.tokens.push(i);
        }
    }
    for pass in &mut raw {
        pass.steps = read_pass(tokens, &pass.tokens, &mut d);
    }
    let passes = resolve_turns(tokens, &raw, &mut d);

    // --- connections + opaque tokens -------------------------------------------------------------
    let mut connections: Vec<Connection> = Vec::new();
    let mut conn_spans: Vec<Span> = Vec::new();
    let mut opaque: Vec<OpaqueToken> = Vec::new();
    for t in tokens {
        match &t.kind {
            TokenKind::Conn(c) => {
                let index = connections.len();
                let count = match c.value {
                    Some(v) => v.min(MAX_COUNT) as u8,
                    None => 1,
                };
                let extra = match (c.suffix.first(), c.suffix.last()) {
                    (Some(a), Some(b)) => Some(a.span.cover(b.span).text(src).to_string()),
                    _ => None,
                };
                for piece in &c.suffix {
                    opaque.push(OpaqueToken {
                        text: piece.span.text(src).to_string(),
                        span: piece.span,
                        placement: OpaquePlacement::ConnectionSuffix { connection: index },
                    });
                }
                connections.push(Connection {
                    side: c.side,
                    count,
                    extra,
                });
                conn_spans.push(t.span);
            }
            TokenKind::Opaque(_) => opaque.push(OpaqueToken {
                text: t.span.text(src).to_string(),
                span: t.span,
                placement: OpaquePlacement::Standalone,
            }),
            _ => {}
        }
    }
    connection_conflicts(&connections, &conn_spans, &mut d);

    if passes.iter().all(|p| p.steps.is_empty()) {
        d.push(
            Code::NoNeedlePath,
            Span::new(0, src.len()),
            "the notation has no needle step (`U`, `O`, or `-`); it does not describe a stitch path"
                .to_string(),
        );
    }

    whitespace_diagnostics(tokens, &lexed.whitespace, &conn_tokens, &placements, &mut d);

    let mut diagnostics = d.out;
    diagnostics.sort_by_key(|x| (x.span.start, x.span.end));
    Analysis {
        passes,
        connections,
        opaque,
        diagnostics,
    }
}

/// Diagnostics that depend on one token alone: case, `Mid`, counts, and uninterpreted text.
fn token_diagnostics(tokens: &[Token], d: &mut Diags<'_>) {
    let mut lowercase: Vec<Span> = Vec::new();
    for t in tokens {
        match &t.kind {
            TokenKind::Step {
                lowercase: true, ..
            } => lowercase.push(t.span),
            TokenKind::Conn(c) => {
                if c.lowercase {
                    lowercase.push(Span::new(c.side_span.start, c.side_span.start + 1));
                }
                conn_diagnostics(t.span, c, d);
            }
            TokenKind::Opaque(kind) => opaque_diagnostic(*kind, t.span, None, d),
            _ => {}
        }
    }

    // One case diagnostic per contiguous run of lowercase symbols.
    let mut runs: Vec<Span> = Vec::new();
    for s in lowercase {
        match runs.last_mut() {
            Some(last) if last.end == s.start => last.end = s.end,
            _ => runs.push(s),
        }
    }
    for s in runs {
        let text = quote(d.text(s));
        d.push(
            Code::CaseNormalized,
            s,
            format!("lowercase {text} is read as uppercase"),
        );
    }
}

fn conn_diagnostics(span: Span, c: &ConnLex, d: &mut Diags<'_>) {
    let letter = side_letter(c.side);
    if c.mid_alias {
        let text = quote(d.text(c.side_span));
        d.push(
            Code::MidAlias,
            c.side_span,
            format!("{text} is the spelled-out middle side; printed as `M`"),
        );
    }
    match c.form {
        CountForm::Missing => {
            let text = quote(d.text(span));
            d.push(
                Code::MissingCount,
                span,
                format!(
                    "connection {text} has no loop count; a count of 1 is assumed (the notation \
                     defines a connection as a side plus a count)"
                ),
            );
        }
        CountForm::Detached => {
            let text = quote(d.text(span));
            let digits = c.digits.map(|s| d.text(s).to_string()).unwrap_or_default();
            d.push(
                Code::DetachedCount,
                span,
                format!(
                    "connection {text} has whitespace between its side and its count; read as \
                     `{letter}{digits}`, though it could also be a bare side followed by a stray number"
                ),
            );
        }
        CountForm::Attached => {}
    }
    if let (Some(digits), Some(value)) = (c.digits, c.value) {
        let raw = d.text(digits).to_string();
        if value > MAX_COUNT {
            d.push(
                Code::CountOutOfRange,
                span,
                format!(
                    "connection count {raw} is out of range (0 to {MAX_COUNT}); the structure holds \
                     {MAX_COUNT} and the written count is kept only in the source text"
                ),
            );
        } else if raw.len() > 1 && raw.starts_with('0') {
            d.push(
                Code::CountLeadingZero,
                digits,
                format!("count `{raw}` has a leading zero; printed as `{value}`"),
            );
        }
    }
    for piece in &c.suffix {
        opaque_diagnostic(piece.kind, piece.span, Some(span), d);
    }
}

/// `attached_to` is the span of the connection a suffix piece is glued onto, if any.
fn opaque_diagnostic(kind: OpaqueKind, span: Span, attached_to: Option<Span>, d: &mut Diags<'_>) {
    let text = quote(d.text(span));
    let kept = match attached_to {
        Some(conn) => format!(
            "kept verbatim in the extra text of connection {}",
            quote(d.text(conn))
        ),
        None => "kept verbatim as an opaque token".to_string(),
    };
    match kind {
        OpaqueKind::Dialect => d.push(
            Code::UnsupportedDialect,
            span,
            format!(
                "{text} uses the `+` dialect (as in `F1+1`, or the `a+b` thumb-loop alias), which \
                 is not Hansen notation and is not interpreted; {kept}"
            ),
        ),
        OpaqueKind::Unexpected => {
            let noun = if span.text(d.src).chars().count() == 1 {
                "unexpected character"
            } else {
                "unexpected characters"
            };
            d.push(
                Code::UnexpectedCharacter,
                span,
                format!("{noun} {text}; {kept}"),
            );
        }
    }
}

/// Match parens within one pass and read its steps. Unmatched parens are ignored (the loops after an
/// unmatched `(` stay engaged); a step is skipped when it lies inside a matched pair.
fn read_pass(tokens: &[Token], pass_tokens: &[usize], d: &mut Diags<'_>) -> Vec<Step> {
    let path: Vec<usize> = pass_tokens
        .iter()
        .copied()
        .filter(|&i| {
            matches!(
                tokens[i].kind,
                TokenKind::Step { .. } | TokenKind::Open | TokenKind::Close
            )
        })
        .collect();

    let mut matched = vec![false; path.len()];
    let mut stack: Vec<usize> = Vec::new();
    for (p, &ti) in path.iter().enumerate() {
        match tokens[ti].kind {
            TokenKind::Open => stack.push(p),
            TokenKind::Close => match stack.pop() {
                Some(o) => {
                    matched[o] = true;
                    matched[p] = true;
                }
                None => d.push(
                    Code::UnmatchedCloseParen,
                    tokens[ti].span,
                    "`)` has no matching `(` in its pass; ignored, so no loop is marked skipped by it"
                        .to_string(),
                ),
            },
            _ => {}
        }
    }
    for o in stack {
        d.push(
            Code::UnmatchedOpenParen,
            tokens[path[o]].span,
            "`(` has no matching `)` in its pass; the skip group is ignored and the loops after it \
             are read as engaged"
                .to_string(),
        );
    }

    let mut steps = Vec::new();
    // (position of the matched `(` in `path`, steps read before it)
    let mut open: Vec<(usize, usize)> = Vec::new();
    for (p, &ti) in path.iter().enumerate() {
        match tokens[ti].kind {
            TokenKind::Open if matched[p] => open.push((p, steps.len())),
            TokenKind::Close if matched[p] => {
                let Some((o, before)) = open.pop() else {
                    continue;
                };
                let span = tokens[path[o]].span.cover(tokens[ti].span);
                let inside = steps.len() - before;
                let text = quote(d.text(span));
                if inside == 0 {
                    d.push(
                        Code::EmptyGroup,
                        span,
                        format!("skip group {text} encloses no loop; dropped"),
                    );
                } else if !open.is_empty() {
                    d.push(
                        Code::NestedGroup,
                        span,
                        format!(
                            "skip group {text} is nested inside another skip group; nesting has no \
                             defined meaning, so its loops are read as skipped once and the inner \
                             parentheses are dropped"
                        ),
                    );
                } else if inside > 1 {
                    let split: String = steps[before..]
                        .iter()
                        .map(|s| match s {
                            Step::SkippedUnder => "(U)",
                            Step::SkippedOver => "(O)",
                            _ => "-",
                        })
                        .collect();
                    d.push(
                        Code::GroupSplit,
                        span,
                        format!(
                            "skip group {text} marks {inside} skipped loops; printed one loop per \
                             group: `{split}`"
                        ),
                    );
                }
            }
            TokenKind::Step { glyph, .. } => {
                let skipped = !open.is_empty();
                steps.push(match (glyph, skipped) {
                    (StepGlyph::Under, false) => Step::Under,
                    (StepGlyph::Under, true) => Step::SkippedUnder,
                    (StepGlyph::Over, false) => Step::Over,
                    (StepGlyph::Over, true) => Step::SkippedOver,
                    (StepGlyph::NoEngage, false) => Step::NoEngage,
                    (StepGlyph::NoEngage, true) => {
                        d.push(
                            Code::SkippedNoEngage,
                            tokens[ti].span,
                            "`-` inside a skip group: a skipped no-engage step cannot be \
                             represented, so it is read as a plain `-`"
                                .to_string(),
                        );
                        Step::NoEngage
                    }
                });
            }
            _ => {}
        }
    }
    steps
}

/// Keep one turn between each pair of consecutive non-empty passes, drop (and diagnose) every other
/// turn, then check the kept turns' markers. Returns the structure's passes (never containing an
/// empty pass, except the single empty pass of a notation with no steps at all).
fn resolve_turns(tokens: &[Token], raw: &[RawPass], d: &mut Diags<'_>) -> Vec<Pass> {
    let opener_span = |k: usize| raw[k].opener.map(|t| tokens[t].span);
    let nonempty: Vec<usize> = (0..raw.len())
        .filter(|&k| !raw[k].steps.is_empty())
        .collect();

    let (Some(&first), Some(&last)) = (nonempty.first(), nonempty.last()) else {
        // No step anywhere: every turn is dropped.
        let turns: Vec<Span> = (1..raw.len()).filter_map(opener_span).collect();
        if let (Some(a), Some(b)) = (turns.first(), turns.last()) {
            d.push(
                Code::EmptyPass,
                a.cover(*b),
                "turn(s) in a notation with no needle step delimit only empty passes; dropped"
                    .to_string(),
            );
        }
        return vec![Pass::new(Vec::new())];
    };

    if first > 0 {
        if let (Some(a), Some(b)) = (opener_span(1), opener_span(first)) {
            let span = a.cover(b);
            let text = quote(d.text(span));
            d.push(
                Code::LeadingTurn,
                span,
                format!("turn {text} comes before the first needle step; dropped"),
            );
        }
    }
    if last + 1 < raw.len() {
        if let (Some(a), Some(b)) = (opener_span(last + 1), opener_span(raw.len() - 1)) {
            let span = a.cover(b);
            let text = quote(d.text(span));
            d.push(
                Code::TrailingTurn,
                span,
                format!("turn {text} comes after the last needle step; dropped"),
            );
        }
    }

    let mut kept_turns: Vec<usize> = Vec::new();
    for pair in nonempty.windows(2) {
        let (a, b) = (pair[0], pair[1]);
        if let Some(t) = raw[a + 1].opener {
            kept_turns.push(t);
        }
        if b > a + 1 {
            let (Some(first_dropped), Some(last_dropped)) = (opener_span(a + 2), opener_span(b))
            else {
                continue;
            };
            let gap_tokens: Vec<usize> = (a + 1..b)
                .flat_map(|k| raw[k].tokens.iter().copied())
                .collect();
            match gap_tokens.first() {
                None => {
                    let span = first_dropped.cover(last_dropped);
                    let text = quote(d.text(span));
                    d.push(
                        Code::DoubledTurn,
                        span,
                        format!(
                            "turn {text} directly follows another turn, leaving an empty pass; \
                             dropped"
                        ),
                    );
                }
                Some(&g) => {
                    // Cover every dropped turn AND the stranded tokens: the first stranded token
                    // can sit before the first dropped turn (`UO/()/UOO`) or after it (`UO//F/UO`).
                    let span = first_dropped.cover(last_dropped).cover(tokens[g].span);
                    let text = quote(d.text(span));
                    d.push(
                        Code::EmptyPass,
                        span,
                        format!(
                            "pass {text} has no needle step; the empty pass and its closing turn \
                             are dropped"
                        ),
                    );
                }
            }
        }
    }

    for (ordinal, &t) in kept_turns.iter().enumerate() {
        let TokenKind::Turn(marker) = tokens[t].kind else {
            continue;
        };
        let expected = if ordinal == 0 {
            TurnMarker::Slash
        } else {
            TurnMarker::Colon
        };
        if marker != expected {
            let message = if ordinal == 0 {
                "`:` is used for the first turn; the first turn is written `/` and `:` marks a \
                 further turn. Read as a turn; the marker choice is not modeled"
                    .to_string()
            } else {
                format!(
                    "`/` is used for turn {}; turns after the first are written `:`. Read as a \
                     turn; the marker choice is not modeled",
                    ordinal + 1
                )
            };
            d.push(Code::TurnMarkerMismatch, tokens[t].span, message);
        }
    }

    nonempty
        .iter()
        .map(|&k| Pass::new(raw[k].steps.clone()))
        .collect()
}

/// Same-side connections: identical ones are duplicates, differing ones contradict each other.
fn connection_conflicts(connections: &[Connection], spans: &[Span], d: &mut Diags<'_>) {
    for (i, c) in connections.iter().enumerate() {
        let Some(j) = (0..i).find(|&j| connections[j].side == c.side) else {
            continue;
        };
        let text = quote(d.text(spans[i]));
        let earlier = quote(d.text(spans[j]));
        if connections[j] == *c {
            d.push(
                Code::DuplicateConnection,
                spans[i],
                format!(
                    "connection {text} repeats the identical earlier connection {earlier}; it is \
                     unclear whether one connection or two is meant"
                ),
            );
        } else {
            d.push(
                Code::ContradictoryConnection,
                spans[i],
                format!(
                    "connection {text} is on the same side as the earlier connection {earlier} with \
                     a different count or suffix; it is unclear which one is meant"
                ),
            );
        }
    }
}

/// Whitespace differing from the canonical layout: exactly one ASCII space before each connection
/// that follows the needle path, and no whitespace anywhere else.
fn whitespace_diagnostics(
    tokens: &[Token],
    whitespace: &[Span],
    conn_tokens: &[usize],
    placements: &[Placement],
    d: &mut Diags<'_>,
) {
    let suffix_conn_starts: HashSet<usize> = conn_tokens
        .iter()
        .zip(placements)
        .filter(|(_, p)| **p == Placement::Suffix)
        .map(|(&i, _)| tokens[i].span.start)
        .collect();
    let ws_ends: HashSet<usize> = whitespace.iter().map(|s| s.end).collect();
    let first_token_start = tokens.first().map(|t| t.span.start);

    for &ws in whitespace {
        let has_prev = first_token_start.is_some_and(|s| s < ws.start);
        let before_suffix_conn = suffix_conn_starts.contains(&ws.end);
        if has_prev && before_suffix_conn && d.text(ws) == " " {
            continue;
        }
        let what = if !has_prev {
            "leading whitespace"
        } else if ws.end == d.src.len() {
            "trailing whitespace"
        } else if before_suffix_conn {
            "non-canonical whitespace before a connection (the canonical separator is one space)"
        } else {
            "whitespace inside the needle path"
        };
        let text = quote(d.text(ws));
        d.push(
            Code::WhitespaceNormalized,
            ws,
            format!("{what} {text} is normalized away"),
        );
    }

    for (&i, &p) in conn_tokens.iter().zip(placements) {
        let span = tokens[i].span;
        if p == Placement::Suffix && i > 0 && !ws_ends.contains(&span.start) {
            let text = quote(d.text(span));
            d.push(
                Code::WhitespaceNormalized,
                span,
                format!("no space before connection {text}; one space is inserted when printed"),
            );
        }
    }
}
