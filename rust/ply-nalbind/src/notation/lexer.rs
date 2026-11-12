//! Tokenizer for Hansen notation. Every non-whitespace character of the source ends up inside exactly
//! one token (or one attached connection-suffix piece), and every whitespace character inside exactly
//! one whitespace run or one detached-count connection token. Nothing is dropped here; the analyzer
//! decides what each token means and diagnoses anything it cannot represent.

use super::diagnostic::Span;
use crate::stitch::ConnSide;

/// A needle-path step glyph as written (skip status is decided later by paren matching).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum StepGlyph {
    Under,
    Over,
    NoEngage,
}

/// Which turn marker was written.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TurnMarker {
    /// `/`, the first turn.
    Slash,
    /// `:`, every later turn.
    Colon,
}

/// A token the grammar does not interpret.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum OpaqueKind {
    /// The `+` dialect: `+` followed by digits, optionally led by a digit run (`F1+1`, `1+1+1`).
    Dialect,
    /// A run of characters outside the grammar.
    Unexpected,
}

/// An uninterpreted piece glued directly (no whitespace) onto the end of a connection token.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct OpaquePiece {
    pub kind: OpaqueKind,
    pub span: Span,
}

/// How a connection's count was written.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum CountForm {
    /// `F1`: digits immediately after the side.
    Attached,
    /// `F 1`: digits separated from the side by whitespace.
    Detached,
    /// `F`: no digits at all.
    Missing,
}

/// A lexed connection: side, count, and any attached opaque suffix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ConnLex {
    pub side: ConnSide,
    /// The side letter was written in lowercase.
    pub lowercase: bool,
    /// The side was spelled `Mid` (any case).
    pub mid_alias: bool,
    /// The span of the side letter(s): `F`, `B`, `M`, or `Mid`.
    pub side_span: Span,
    pub form: CountForm,
    /// The count digits, if any were written.
    pub digits: Option<Span>,
    /// The count's numeric value (saturating), if digits were written.
    pub value: Option<u64>,
    /// Opaque pieces glued directly after the count (or after the side, for a bare side).
    pub suffix: Vec<OpaquePiece>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum TokenKind {
    Step {
        glyph: StepGlyph,
        lowercase: bool,
    },
    Open,
    Close,
    Turn(TurnMarker),
    /// A connection. The token span covers side + count only; suffix pieces carry their own spans.
    Conn(ConnLex),
    /// A standalone uninterpreted token.
    Opaque(OpaqueKind),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Token {
    pub kind: TokenKind,
    pub span: Span,
}

/// The token stream plus the whitespace runs between tokens, both in source order.
#[derive(Debug, Default)]
pub(super) struct Lexed {
    pub tokens: Vec<Token>,
    pub whitespace: Vec<Span>,
}

/// Characters that begin a grammar token (so they end an opaque run or a connection suffix).
pub(super) fn is_starter(c: char) -> bool {
    matches!(
        c,
        'U' | 'u' | 'O' | 'o' | '-' | '(' | ')' | '/' | ':' | 'F' | 'f' | 'B' | 'b' | 'M' | 'm'
    )
}

struct Cursor<'a> {
    src: &'a str,
    chars: Vec<(usize, char)>,
}

impl Cursor<'_> {
    fn len(&self) -> usize {
        self.chars.len()
    }

    fn ch(&self, i: usize) -> Option<char> {
        self.chars.get(i).map(|&(_, c)| c)
    }

    /// Byte offset of char index `i` (the source length at the end).
    fn off(&self, i: usize) -> usize {
        self.chars.get(i).map_or(self.src.len(), |&(b, _)| b)
    }

    fn span(&self, from: usize, to: usize) -> Span {
        Span::new(self.off(from), self.off(to))
    }

    /// Index just past the ASCII-digit run starting at `i` (`i` itself if there is none).
    fn digits_end(&self, mut i: usize) -> usize {
        while self.ch(i).is_some_and(|c| c.is_ascii_digit()) {
            i += 1;
        }
        i
    }

    fn whitespace_end(&self, mut i: usize) -> usize {
        while self.ch(i).is_some_and(char::is_whitespace) {
            i += 1;
        }
        i
    }

    /// True when the digit run starting at `i` is immediately followed by `+` (the `a+b` dialect).
    fn digit_run_then_plus(&self, i: usize) -> bool {
        let end = self.digits_end(i);
        end > i && self.ch(end) == Some('+')
    }

    /// Lex an opaque token starting at `i` (a char that is neither whitespace nor a starter).
    fn opaque(&self, i: usize) -> (OpaqueKind, usize) {
        let c = self.ch(i).unwrap_or('+');
        if c == '+' || self.digit_run_then_plus(i) {
            let mut j = self.digits_end(i);
            while self.ch(j) == Some('+') {
                j = self.digits_end(j + 1);
            }
            return (OpaqueKind::Dialect, j);
        }
        let mut j = i;
        while let Some(ch) = self.ch(j) {
            if ch.is_whitespace() || is_starter(ch) || ch == '+' {
                break;
            }
            if j > i && ch.is_ascii_digit() && self.digit_run_then_plus(j) {
                break;
            }
            j += 1;
        }
        (OpaqueKind::Unexpected, j.max(i + 1))
    }

    /// Lex a connection starting at the side letter at `i`.
    fn connection(&self, i: usize) -> (Token, usize) {
        let c = self.ch(i).unwrap_or('F');
        let side = match c.to_ascii_uppercase() {
            'F' => ConnSide::Front,
            'B' => ConnSide::Back,
            _ => ConnSide::Middle,
        };
        let mut j = i + 1;
        let mut mid_alias = false;
        if side == ConnSide::Middle
            && self.ch(j).is_some_and(|c| c.eq_ignore_ascii_case(&'i'))
            && self.ch(j + 1).is_some_and(|c| c.eq_ignore_ascii_case(&'d'))
        {
            j += 2;
            mid_alias = true;
        }
        let side_span = self.span(i, j);

        let attached_end = self.digits_end(j);
        let (form, digits) = if attached_end > j {
            let d = (j, attached_end);
            j = attached_end;
            (CountForm::Attached, Some(d))
        } else {
            let k = self.whitespace_end(j);
            let detached_end = self.digits_end(k);
            if k > j && detached_end > k {
                j = detached_end;
                (CountForm::Detached, Some((k, detached_end)))
            } else {
                (CountForm::Missing, None)
            }
        };
        let value = digits.map(|(a, b)| {
            self.chars[a..b].iter().fold(0u64, |acc, &(_, d)| {
                acc.saturating_mul(10)
                    .saturating_add(u64::from(d.to_digit(10).unwrap_or(0)))
            })
        });
        let token_end = j;

        let mut suffix = Vec::new();
        while let Some(ch) = self.ch(j) {
            if ch.is_whitespace() || is_starter(ch) {
                break;
            }
            let (kind, next) = self.opaque(j);
            suffix.push(OpaquePiece {
                kind,
                span: self.span(j, next),
            });
            j = next;
        }

        let token = Token {
            kind: TokenKind::Conn(ConnLex {
                side,
                lowercase: c.is_ascii_lowercase(),
                mid_alias,
                side_span,
                form,
                digits: digits.map(|(a, b)| self.span(a, b)),
                value,
                suffix,
            }),
            span: self.span(i, token_end),
        };
        (token, j)
    }
}

/// Tokenize `src`. Never fails: anything outside the grammar becomes an opaque token.
pub(super) fn lex(src: &str) -> Lexed {
    let cur = Cursor {
        src,
        chars: src.char_indices().collect(),
    };
    let mut out = Lexed::default();
    let mut i = 0;
    while i < cur.len() {
        let c = cur.ch(i).unwrap_or(' ');
        if c.is_whitespace() {
            let j = cur.whitespace_end(i);
            out.whitespace.push(cur.span(i, j));
            i = j;
            continue;
        }
        let simple = |kind: TokenKind| Token {
            kind,
            span: cur.span(i, i + 1),
        };
        let step = |glyph: StepGlyph| TokenKind::Step {
            glyph,
            lowercase: c.is_ascii_lowercase(),
        };
        match c {
            'U' | 'u' => out.tokens.push(simple(step(StepGlyph::Under))),
            'O' | 'o' => out.tokens.push(simple(step(StepGlyph::Over))),
            '-' => out.tokens.push(simple(step(StepGlyph::NoEngage))),
            '(' => out.tokens.push(simple(TokenKind::Open)),
            ')' => out.tokens.push(simple(TokenKind::Close)),
            '/' => out.tokens.push(simple(TokenKind::Turn(TurnMarker::Slash))),
            ':' => out.tokens.push(simple(TokenKind::Turn(TurnMarker::Colon))),
            'F' | 'f' | 'B' | 'b' | 'M' | 'm' => {
                let (token, next) = cur.connection(i);
                out.tokens.push(token);
                i = next;
                continue;
            }
            _ => {
                let (kind, next) = cur.opaque(i);
                out.tokens.push(Token {
                    kind: TokenKind::Opaque(kind),
                    span: cur.span(i, next),
                });
                i = next;
                continue;
            }
        }
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every non-whitespace byte is inside a token or a suffix piece; every whitespace byte is inside
    /// a whitespace run or a (detached-count) connection token.
    fn assert_full_coverage(src: &str) {
        let lexed = lex(src);
        let mut spans: Vec<Span> = lexed.whitespace.clone();
        for t in &lexed.tokens {
            spans.push(t.span);
            if let TokenKind::Conn(c) = &t.kind {
                spans.extend(c.suffix.iter().map(|p| p.span));
            }
        }
        for (b, ch) in src.char_indices() {
            assert!(
                spans.iter().any(|s| s.contains(b)),
                "byte {b} ({ch:?}) of {src:?} is not covered by any token"
            );
        }
    }

    #[test]
    fn lexer_covers_every_character() {
        for src in [
            "UO/UOO F1",
            "U(U)O/UO:UOO B1 F1",
            "uo / uoo  f 1+1x Mid02 1+1+1 \u{a0}é#",
            "F1+B1",
            "x12+3y",
            "",
            "+",
            "M i d",
        ] {
            assert_full_coverage(src);
        }
    }

    #[test]
    fn dialect_takes_leading_digits_and_chained_segments() {
        let lexed = lex("1+1+2");
        assert_eq!(lexed.tokens.len(), 1);
        assert_eq!(lexed.tokens[0].kind, TokenKind::Opaque(OpaqueKind::Dialect));
        assert_eq!(lexed.tokens[0].span, Span::new(0, 5));
    }

    #[test]
    fn connection_suffix_is_attached_only_without_whitespace() {
        let glued = lex("F1+1");
        let TokenKind::Conn(c) = &glued.tokens[0].kind else {
            panic!("expected a connection")
        };
        assert_eq!(c.suffix.len(), 1);
        assert_eq!(c.suffix[0].span, Span::new(2, 4));

        let spaced = lex("F1 +1");
        assert_eq!(
            spaced.tokens.len(),
            2,
            "a spaced `+1` is a standalone token"
        );
    }
}
