//! Label sets: what identities are called on screen and in print (ADR 0022 section 3).
//!
//! A label set maps identities and words to text and never the other way into the model: switching
//! sets never changes an operation, a target, an id, a count or a byte of a pattern; it only changes
//! text. Resolution and validation read no label set. The two built-in sets follow the name tables
//! of the crochet research: `us` (US and Canadian stitch names) and `uk` (UK names, and Australian
//! by inference). The same abbreviations name different stitches in the two sets ("dc" is `b1` in US
//! terms and `b0` in UK terms), which is why every view names its set.
//!
//! M11-01 builds the sets, the reserved words the legend check uses and the count phrase of rule W17
//! ([`LabelSet::count_text`]); the rest of the written form (section 14) is M11-02's.

use crate::count::LayerCount;
use crate::stitch::{Basic, Counted, Identity};

/// Which built-in label set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LabelSetId {
    Us,
    Uk,
}

/// One built-in label set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct LabelSet {
    id: LabelSetId,
}

/// Each basic stitch's (full name, abbreviation), shortest first, in US terms.
const US_BASICS: [(&str, &str); 5] = [
    ("single crochet", "sc"),
    ("half double crochet", "hdc"),
    ("double crochet", "dc"),
    ("treble", "tr"),
    ("double treble", "dtr"),
];

/// The same in UK terms.
const UK_BASICS: [(&str, &str); 5] = [
    ("double crochet", "dc"),
    ("half treble", "htr"),
    ("treble", "tr"),
    ("double treble", "dtr"),
    ("triple treble", "trtr"),
];

/// Other spellings of the stitch names that a legend may not reuse either: the long forms
/// ("treble crochet"), the alternative "ttr" for the UK triple treble (crocheter review item 8),
/// and the names of the two-wrap half stitch that is not in v1 yet (US "half treble", UK "half double
/// treble", "hdtr").
const OTHER_NAMES: [&str; 9] = [
    "treble crochet",
    "triple crochet",
    "double treble crochet",
    "triple treble crochet",
    "half treble crochet",
    "half double treble",
    "half double treble crochet",
    "hdtr",
    "ttr",
];

/// Target words, verbs and terms of either set that a legend entry may not reuse (whole strings,
/// ignoring case). Stitch names, abbreviations and the derived forms (`sc2tog`, `FPdc`, `fsc`,
/// `ch-2 sp`) are matched separately.
const RESERVED_TERMS: [&str; 44] = [
    "st",
    "sts",
    "stitch",
    "stitches",
    "sp",
    "sps",
    "space",
    "spaces",
    "ch",
    "chs",
    "chain",
    "chains",
    "ch sp",
    "ch-sp",
    "ch sps",
    "ch-sps",
    "sl st",
    "sl sts",
    "ss",
    "slip stitch",
    "slip stitches",
    "sk",
    "skip",
    "miss",
    "yo",
    "yoh",
    "yarn over",
    "yarn over hook",
    "gauge",
    "tension",
    "blo",
    "flo",
    "back loop only",
    "front loop only",
    "tog",
    "rep",
    "beg",
    "tch",
    "t-ch",
    "rnd",
    "rnds",
    "ring",
    "fp",
    "bp",
];

impl LabelSet {
    /// US terms.
    pub const US: LabelSet = LabelSet { id: LabelSetId::Us };
    /// UK terms.
    pub const UK: LabelSet = LabelSet { id: LabelSetId::Uk };
    /// Both built-in sets.
    pub const ALL: [LabelSet; 2] = [LabelSet::US, LabelSet::UK];

    pub const fn id(self) -> LabelSetId {
        self.id
    }

    /// What a view and a print say at their head: "US terms", "UK terms".
    pub const fn heading(self) -> &'static str {
        match self.id {
            LabelSetId::Us => "US terms",
            LabelSetId::Uk => "UK terms",
        }
    }

    const fn basics(self) -> &'static [(&'static str, &'static str); 5] {
        match self.id {
            LabelSetId::Us => &US_BASICS,
            LabelSetId::Uk => &UK_BASICS,
        }
    }

    /// A basic stitch's full name ("single crochet", UK "double crochet").
    pub const fn stitch_name(self, b: Basic) -> &'static str {
        self.basics()[b.index()].0
    }

    /// A basic stitch's abbreviation ("sc", UK "dc").
    pub const fn stitch_abbreviation(self, b: Basic) -> &'static str {
        self.basics()[b.index()].1
    }

    /// The slip stitch's abbreviation: "sl st", UK "ss".
    pub const fn slip_abbreviation(self) -> &'static str {
        match self.id {
            LabelSetId::Us => "sl st",
            LabelSetId::Uk => "ss",
        }
    }

    /// "sk", UK "miss".
    pub const fn skip_word(self) -> &'static str {
        match self.id {
            LabelSetId::Us => "sk",
            LabelSetId::Uk => "miss",
        }
    }

    /// "yo", UK "yoh".
    pub const fn yarn_over(self) -> &'static str {
        match self.id {
            LabelSetId::Us => "yo",
            LabelSetId::Uk => "yoh",
        }
    }

    /// "gauge", UK "tension".
    pub const fn gauge_word(self) -> &'static str {
        match self.id {
            LabelSetId::Us => "gauge",
            LabelSetId::Uk => "tension",
        }
    }

    /// An identity's full name ("double crochet 2 together" for `tog(b1 x 2)` in US terms).
    pub fn name(self, identity: Identity) -> String {
        match identity {
            Identity::Chain => "chain".to_string(),
            Identity::Slip => "slip stitch".to_string(),
            Identity::Basic(b) => self.stitch_name(b).to_string(),
            Identity::Together { stitch, legs } => {
                format!("{} {legs} together", self.stitch_name(stitch))
            }
        }
    }

    /// An identity's abbreviation ("sc", "sc2tog", "sl st"; UK "dc", "dc2tog", "ss").
    pub fn abbreviation(self, identity: Identity) -> String {
        match identity {
            Identity::Chain => "ch".to_string(),
            Identity::Slip => self.slip_abbreviation().to_string(),
            Identity::Basic(b) => self.stitch_abbreviation(b).to_string(),
            Identity::Together { stitch, legs } => {
                format!("{}{legs}tog", self.stitch_abbreviation(stitch))
            }
        }
    }

    /// The abbreviation a count uses for one counted identity.
    pub fn counted_abbreviation(self, counted: Counted) -> &'static str {
        match counted {
            Counted::Slip => self.slip_abbreviation(),
            Counted::Basic(b) => self.stitch_abbreviation(b),
        }
    }

    /// What this set reads an abbreviation as, if it names an identity of v1 here ("dc" is `b1` in
    /// US terms and `b0` in UK terms; "htr" is nothing in US terms until `b2h` joins v1). Ply never
    /// imports text in v1; this is the reverse of [`LabelSet::abbreviation`], used to show that a
    /// set's labels name each identity exactly once.
    pub fn read_abbreviation(self, text: &str) -> Option<Identity> {
        let t = normalize(text);
        if t == "ch" {
            return Some(Identity::Chain);
        }
        if t == self.slip_abbreviation() || t == "sl st" {
            return Some(Identity::Slip);
        }
        if let Some(b) = Basic::ALL
            .into_iter()
            .find(|&b| self.stitch_abbreviation(b) == t)
        {
            return Some(Identity::Basic(b));
        }
        let (stem, legs) = split_tog(&t)?;
        let stitch = Basic::ALL
            .into_iter()
            .find(|&b| self.stitch_abbreviation(b) == stem)?;
        Some(Identity::Together { stitch, legs })
    }

    /// Rule W17 (ADR 0022 section 14): "(9 sc)", "(5 sc, 4 ch-1 sps)", "(18 dc, 6 sc)",
    /// "(3 sc, 1 dc, 1 not checked)", or "(count unknown)" when the count is unknown. Stitches by
    /// identity in order of first appearance, then spaces by chain length, then opaque positions. A
    /// layer that made nothing is "(0 sts)".
    pub fn count_text(self, count: Option<&LayerCount>) -> String {
        let Some(c) = count else {
            return "(count unknown)".to_string();
        };
        let mut parts: Vec<String> = Vec::new();
        for &(counted, n) in &c.stitches {
            parts.push(format!("{n} {}", self.counted_abbreviation(counted)));
        }
        for &(chains, n) in &c.spaces {
            parts.push(format!(
                "{n} ch-{chains} {}",
                if n == 1 { "sp" } else { "sps" }
            ));
        }
        if c.not_checked > 0 {
            parts.push(format!("{} not checked", c.not_checked));
        }
        if parts.is_empty() {
            return "(0 sts)".to_string();
        }
        format!("({})", parts.join(", "))
    }
}

/// Lower case, trimmed, runs of white space as one space.
fn normalize(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

/// `sc2tog` as ("sc", 2): a stem, one or more digits, then "tog".
fn split_tog(t: &str) -> Option<(&str, u32)> {
    let body = t.strip_suffix("tog")?;
    let digits = body.len() - body.trim_end_matches(|c: char| c.is_ascii_digit()).len();
    if digits == 0 || digits > 6 {
        return None;
    }
    let (stem, number) = body.split_at(body.len() - digits);
    Some((stem, number.parse().ok()?))
}

/// True when `text`, compared whole and ignoring case, is a word either built-in label set reserves:
/// a stitch name or abbreviation of either set (and their plurals and long forms), a derived
/// abbreviation (`sc2tog`, `dc3tog`, `FPdc`, `BPtr`, `fsc`), a chain-space word (`ch-2 sp`), or a
/// target word, verb or term (`st`, `sp`, `sk`, `miss`, `sl st`, `ss`, `yo`, `tension`, ...). The
/// project legend may not reuse any of them, whatever the document's source terms (ADR 0022 section
/// 3, `crochet.legend_collision`).
pub fn is_reserved_word(text: &str) -> bool {
    let t = normalize(text);
    if t.is_empty() {
        return false;
    }
    if RESERVED_TERMS.contains(&t.as_str()) || OTHER_NAMES.contains(&t.as_str()) {
        return true;
    }
    let names = |set: LabelSet| {
        Basic::ALL
            .into_iter()
            .flat_map(move |b| [set.stitch_name(b), set.stitch_abbreviation(b)])
    };
    let is_name = |s: &str| {
        LabelSet::ALL
            .into_iter()
            .flat_map(names)
            .chain(OTHER_NAMES)
            .any(|n| n == s)
    };
    if is_name(&t) {
        return true;
    }
    // Plurals of the full names ("single crochets", "trebles").
    if let Some(stem) = t.strip_suffix('s') {
        if is_name(stem) {
            return true;
        }
    }
    let is_abbr = |s: &str| {
        LabelSet::ALL.into_iter().any(|set| {
            Basic::ALL
                .into_iter()
                .any(|b| set.stitch_abbreviation(b) == s)
        }) || s == "hdtr"
            || s == "ttr"
    };
    // sc2tog, dc3tog, ...
    if let Some((stem, _)) = split_tog(&t) {
        if is_abbr(stem) {
            return true;
        }
    }
    // FPdc, BPtr (post stitches), fsc, fdc (foundation stitches).
    for prefix in ["fp", "bp", "f"] {
        if let Some(stem) = t.strip_prefix(prefix) {
            if is_abbr(stem) {
                return true;
            }
        }
    }
    // ch-2 sp, ch-12 sps, ch2 sp.
    if let Some(rest) = t.strip_prefix("ch") {
        let rest = rest.strip_prefix('-').unwrap_or(rest);
        let digits = rest.len() - rest.trim_start_matches(|c: char| c.is_ascii_digit()).len();
        if digits > 0 {
            let tail = rest[digits..].trim_start();
            if tail.is_empty() || tail == "sp" || tail == "sps" {
                return true;
            }
        }
    }
    false
}

/// A legend word as the collision rule compares it: lower case, trimmed, runs of white space as one
/// space (two words collide when their keys are equal and not empty).
pub(crate) fn word_key(text: &str) -> String {
    normalize(text)
}

/// True when two legend words are the same word for the collision rule.
#[cfg(test)]
pub(crate) fn same_word(a: &str, b: &str) -> bool {
    let (a, b) = (word_key(a), word_key(b));
    !a.is_empty() && a == b
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_traps_of_section_3_read_differently_in_the_two_sets() {
        let us = LabelSet::US;
        let uk = LabelSet::UK;
        let b = |b| Some(Identity::Basic(b));
        let tog = |stitch, legs| Some(Identity::Together { stitch, legs });
        assert_eq!(us.read_abbreviation("dc"), b(Basic::B1));
        assert_eq!(uk.read_abbreviation("dc"), b(Basic::B0));
        assert_eq!(us.read_abbreviation("tr"), b(Basic::B2));
        assert_eq!(uk.read_abbreviation("tr"), b(Basic::B1));
        assert_eq!(us.read_abbreviation("dtr"), b(Basic::B3));
        assert_eq!(uk.read_abbreviation("dtr"), b(Basic::B2));
        assert_eq!(us.read_abbreviation("htr"), None, "b2h is not in v1");
        assert_eq!(uk.read_abbreviation("htr"), b(Basic::B1H));
        assert_eq!(us.read_abbreviation("dc2tog"), tog(Basic::B1, 2));
        assert_eq!(uk.read_abbreviation("dc2tog"), tog(Basic::B0, 2));
        assert_eq!(us.read_abbreviation("tr2tog"), tog(Basic::B2, 2));
        assert_eq!(uk.read_abbreviation("tr2tog"), tog(Basic::B1, 2));
        assert_eq!(
            us.read_abbreviation("FPdc"),
            None,
            "post stitches are later"
        );
        assert!(is_reserved_word("FPdc"));
        assert_eq!(us.read_abbreviation("sc"), b(Basic::B0));
        assert_eq!(uk.read_abbreviation("sc"), None);
        assert_eq!(uk.read_abbreviation("ss"), Some(Identity::Slip));
    }

    #[test]
    fn names_follow_the_research_tables() {
        let us: Vec<_> = Basic::ALL
            .iter()
            .map(|&b| LabelSet::US.abbreviation(Identity::Basic(b)))
            .collect();
        let uk: Vec<_> = Basic::ALL
            .iter()
            .map(|&b| LabelSet::UK.abbreviation(Identity::Basic(b)))
            .collect();
        assert_eq!(us, ["sc", "hdc", "dc", "tr", "dtr"]);
        assert_eq!(uk, ["dc", "htr", "tr", "dtr", "trtr"]);
        assert_eq!(LabelSet::US.stitch_name(Basic::B0), "single crochet");
        assert_eq!(LabelSet::UK.stitch_name(Basic::B0), "double crochet");
        assert_eq!(
            LabelSet::US.abbreviation(Identity::Together {
                stitch: Basic::B0,
                legs: 2
            }),
            "sc2tog"
        );
        assert_eq!(LabelSet::UK.abbreviation(Identity::Slip), "ss");
        assert_eq!(
            (LabelSet::US.skip_word(), LabelSet::UK.skip_word()),
            ("sk", "miss")
        );
        assert_eq!(LabelSet::UK.heading(), "UK terms");
    }

    #[test]
    fn reserved_words_compare_whole_strings_ignoring_case() {
        for w in [
            "dc",
            "Dc",
            "DC",
            "double crochet",
            "Double  Crochet",
            "sc",
            "htr",
            "dc2tog",
            "sc3tog",
            "st",
            "sp",
            "ch",
            "sk",
            "miss",
            "sl st",
            "ss",
            "ch-2 sp",
            "ch-1 sps",
            "fsc",
            "BPtr",
            "trtr",
            "ttr",
            "trebles",
            "yoh",
        ] {
            assert!(is_reserved_word(w), "{w} is reserved");
        }
        for w in [
            "V-st", "inc", "dec", "invdec", "shell", "puff", "cl", "", "  ",
        ] {
            assert!(!is_reserved_word(w), "{w:?} is free");
        }
        assert!(same_word("Inc", " inc "));
        assert!(!same_word("", ""));
    }

    #[test]
    fn count_text_follows_w17() {
        let mut c = LayerCount::default();
        for _ in 0..5 {
            c.add_stitch(Counted::Basic(Basic::B0));
        }
        for _ in 0..4 {
            c.add_space(1);
        }
        assert_eq!(LabelSet::US.count_text(Some(&c)), "(5 sc, 4 ch-1 sps)");
        assert_eq!(LabelSet::UK.count_text(Some(&c)), "(5 dc, 4 ch-1 sps)");
        let mut one = LayerCount::default();
        one.add_space(2);
        assert_eq!(LabelSet::US.count_text(Some(&one)), "(1 ch-2 sp)");
        assert_eq!(LabelSet::US.count_text(None), "(count unknown)");
        assert_eq!(
            LabelSet::US.count_text(Some(&LayerCount::default())),
            "(0 sts)"
        );
    }
}
