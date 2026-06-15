//! Hansen-notation parsing and printing. The parsed STRUCTURE (`Vec<Pass>` + `Vec<Connection>`) is
//! canonical; the string is a view. So the invariant we guarantee is `parse(print(x)) == x` (structure
//! → string → structure is identity), NOT exact source-string fidelity — published strings vary in
//! formatting and dialect, and the originals are kept verbatim in `StitchType::codes`.
//!
//! Grammar (case-insensitive): `U`/`O` engage a loop under/over; `(` `)` mark skipped loops; `-` is a
//! no-engage step; `/` is the first turn and `:` each subsequent turn (so passes are `p0 / p1 : p2`).
//! A connection is a side `F`/`B`/`M` (or `Mid`) followed by a loop count (a bare side defaults to 1);
//! connections may appear anywhere and repeat (Åsle `B1 F1`). The `+` dialect separator (`F1+1`) is
//! tolerated and its trailing count dropped (it is not modeled; the raw string lives in `codes`).

use crate::error::NalbindError;
use crate::stitch::{ConnSide, Connection, Pass, Step};

/// Parse a Hansen string into passes + connections. Errors on a character the grammar does not know.
pub fn parse(input: &str) -> Result<(Vec<Pass>, Vec<Connection>), NalbindError> {
    let chars: Vec<char> = input.chars().collect();
    let mut passes: Vec<Pass> = vec![Pass { steps: Vec::new() }];
    let mut connections: Vec<Connection> = Vec::new();
    let mut skipping = false;
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        match c {
            'U' | 'u' => last(&mut passes)
                .steps
                .push(if skipping { Step::SkippedUnder } else { Step::Under }),
            'O' | 'o' => last(&mut passes)
                .steps
                .push(if skipping { Step::SkippedOver } else { Step::Over }),
            '-' => last(&mut passes).steps.push(Step::NoEngage),
            '(' => skipping = true,
            ')' => skipping = false,
            '/' | ':' => passes.push(Pass { steps: Vec::new() }),
            'F' | 'f' => {
                let (n, ni) = read_count(&chars, i + 1);
                connections.push(Connection::new(ConnSide::Front, n));
                i = ni;
                continue;
            }
            'B' | 'b' => {
                let (n, ni) = read_count(&chars, i + 1);
                connections.push(Connection::new(ConnSide::Back, n));
                i = ni;
                continue;
            }
            'M' | 'm' => {
                // Accept either "M" or the spelled-out "Mid".
                let mut j = i + 1;
                if j + 1 < chars.len()
                    && chars[j].eq_ignore_ascii_case(&'i')
                    && chars[j + 1].eq_ignore_ascii_case(&'d')
                {
                    j += 2;
                }
                let (n, ni) = read_count(&chars, j);
                connections.push(Connection::new(ConnSide::Middle, n));
                i = ni;
                continue;
            }
            // The `F1+1` dialect: tolerate `+` and drop the trailing count (not modeled here).
            '+' => {
                let (_n, ni) = read_count(&chars, i + 1);
                i = ni;
                continue;
            }
            c if c.is_whitespace() => {}
            _ => {
                return Err(NalbindError::BadNotation(format!(
                    "unexpected character {c:?} at position {i}"
                )))
            }
        }
        i += 1;
    }
    // A trailing empty pass means the string ended on a turn (e.g. "UO/"); drop it but keep >= 1 pass.
    while passes.len() > 1 && passes.last().is_some_and(|p| p.steps.is_empty()) {
        passes.pop();
    }
    Ok((passes, connections))
}

/// Print passes + connections to a canonical Hansen string. Round-trips: `parse(print(x)) == x`.
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
        s.push(' ');
        s.push(match c.side {
            ConnSide::Front => 'F',
            ConnSide::Back => 'B',
            ConnSide::Middle => 'M',
        });
        s.push_str(&c.count.to_string());
    }
    s
}

fn last(passes: &mut [Pass]) -> &mut Pass {
    passes.last_mut().expect("passes is seeded with one element and never emptied")
}

/// Read a base-10 loop count starting at `start`. A missing number defaults to 1 (a bare `F`); the
/// value saturates at `u8::MAX` so an absurd digit run can't overflow.
fn read_count(chars: &[char], start: usize) -> (u8, usize) {
    let mut j = start;
    let mut num: u32 = 0;
    let mut saw = false;
    while j < chars.len() && chars[j].is_ascii_digit() {
        saw = true;
        num = num.saturating_mul(10).saturating_add(chars[j].to_digit(10).unwrap_or(0));
        j += 1;
    }
    (if saw { num.min(u8::MAX as u32) as u8 } else { 1 }, j)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round(s: &str) -> String {
        let (p, c) = parse(s).expect("parses");
        print(&p, &c)
    }

    #[test]
    fn parses_oslo() {
        let (passes, conns) = parse("UO/UOO F1").unwrap();
        assert_eq!(passes.len(), 2);
        assert_eq!(passes[0].steps, vec![Step::Under, Step::Over]);
        assert_eq!(passes[1].steps, vec![Step::Under, Step::Over, Step::Over]);
        assert_eq!(conns, vec![Connection::new(ConnSide::Front, 1)]);
    }

    #[test]
    fn canonical_strings_round_trip() {
        for s in [
            "UO/UOO F1",
            "UOO/UUOO F2",
            "UU/OOO F2",
            "UUOOUU/OOUUOOO",
            "U(U)O/UO:UOO B1 F1", // multi-turn + skipped + two connections (Åsle-like)
            "-/-O F1 B1",         // no-engage looping (Coptic-like)
        ] {
            assert_eq!(round(s), s, "round-trip changed {s:?}");
        }
    }

    #[test]
    fn skipped_loops_and_no_engage() {
        let (passes, _) = parse("U(UU)O-").unwrap();
        assert_eq!(
            passes[0].steps,
            vec![Step::Under, Step::SkippedUnder, Step::SkippedUnder, Step::Over, Step::NoEngage]
        );
    }

    #[test]
    fn bare_side_defaults_to_one_and_mid_is_accepted() {
        let (_, conns) = parse("UO/UOO F Mid2").unwrap();
        assert_eq!(
            conns,
            vec![Connection::new(ConnSide::Front, 1), Connection::new(ConnSide::Middle, 2)]
        );
    }

    #[test]
    fn trailing_turn_is_dropped() {
        let (passes, _) = parse("UO/").unwrap();
        assert_eq!(passes.len(), 1, "a trailing empty pass is dropped");
    }

    #[test]
    fn plus_dialect_is_tolerated() {
        let (_, conns) = parse("U(U)O/UO:UOO F1+1").unwrap();
        assert_eq!(conns, vec![Connection::new(ConnSide::Front, 1)], "the +1 is dropped");
    }

    #[test]
    fn unknown_character_errors_not_panics() {
        assert!(parse("UO/XYZ").is_err());
    }
}
