//! Loom profiles (roadmap M8-02, ADR 0014): the weaver's own equipment, described in a weaver's
//! terms, so a draft can be checked against the loom it is planned for (see [`crate::feasibility`]).
//!
//! A profile is NOT part of a draft and never part of WIF: it lives in Ply's `looms.json` (see
//! [`crate::loom_file`]). Every equipment field may be missing. **Unknown is not zero**: a count the
//! weaver did not give is `None` (or an empty list), never 0, and a check that needs it says it could
//! not be checked instead of passing.

use ply_common::Unit;
use serde::{Deserialize, Serialize};

/// The most shafts a profile may record. Real looms stop far below this (a computer dobby has 24 to
/// 40); the cap only rejects absurd values from an untrusted file.
pub const MAX_LOOM_SHAFTS: u16 = 200;

/// The most treadles a profile may record (floor looms have 4 to about 20).
pub const MAX_LOOM_TREADLES: u16 = 200;

/// The most treadles a profile may say the weaver presses together for one pick.
pub const MAX_TREADLES_AT_ONCE: u8 = 10;

/// The largest weaving width a profile may record, in its own unit (inches or cm).
pub const MAX_WEAVING_WIDTH: f64 = 10_000.0;

/// The most dents per unit (per inch or per 10 cm) a reed may record.
pub const MAX_REED_DENTS: f64 = 1_000.0;

/// The most reeds one profile may list.
pub const MAX_REEDS: usize = 20;

/// The longest loom name, in characters.
pub const MAX_LOOM_NAME_CHARS: usize = 100;

/// The longest setup notes, in characters.
pub const MAX_LOOM_NOTES_CHARS: usize = 4_000;

/// The longest id, in bytes (ids are ASCII).
pub const MAX_LOOM_ID_LEN: usize = 64;

/// How a loom makes a shed (research note, section 1). `None` in a profile = not recorded.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LoomKind {
    /// Jack floor loom: a treadle RAISES the shafts tied to it; the others stay down.
    Jack,
    /// Counterbalance floor loom: the tied shafts SINK and the others rise; every treadle moves every
    /// shaft, and the shed is balanced in tension.
    Counterbalance,
    /// Countermarch floor loom: two sets of lamms raise and lower each shaft on its own; every shaft
    /// is tied up or down on every treadle used.
    Countermarch,
    /// Table loom: hand levers, one per shaft, set for each pick; works from a lift plan.
    Table,
    /// Dobby loom (mechanical or computer): selects the shafts for each pick itself; works from a
    /// lift plan.
    Dobby,
}

impl LoomKind {
    /// "a jack loom", "a counterbalance loom", ... for sentences.
    pub fn with_article(self) -> &'static str {
        match self {
            LoomKind::Jack => "a jack loom",
            LoomKind::Counterbalance => "a counterbalance loom",
            LoomKind::Countermarch => "a countermarch loom",
            LoomKind::Table => "a table loom",
            LoomKind::Dobby => "a dobby loom",
        }
    }

    /// True for the looms worked by treadles and a tie-up.
    pub fn is_treadled(self) -> bool {
        matches!(
            self,
            LoomKind::Jack | LoomKind::Counterbalance | LoomKind::Countermarch
        )
    }
}

/// A length with its unit (inches or centimeters).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Length {
    pub value: f64,
    #[serde(with = "unit_serde")]
    pub unit: Unit,
}

impl Length {
    /// This length in inches.
    pub fn inches(self) -> f64 {
        match self.unit {
            Unit::Inches => self.value,
            Unit::Centimeters => self.value / CM_PER_INCH,
        }
    }

    /// This length in `unit`.
    pub fn in_unit(self, unit: Unit) -> f64 {
        match unit {
            Unit::Inches => self.inches(),
            Unit::Centimeters => self.inches() * CM_PER_INCH,
        }
    }
}

/// Centimeters in an inch.
pub const CM_PER_INCH: f64 = 2.54;

/// How a reed's dents are counted: per inch (imperial reeds) or per 10 cm (the usual metric reed
/// number, e.g. a 40/10 reed has 40 dents in 10 cm).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DentUnit {
    #[serde(rename = "inch")]
    PerInch,
    #[serde(rename = "10cm")]
    Per10Cm,
}

/// One reed: how many dents it has per unit of width.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Reed {
    pub dents: f64,
    pub per: DentUnit,
}

impl Reed {
    /// Dents per inch.
    pub fn dents_per_inch(self) -> f64 {
        match self.per {
            DentUnit::PerInch => self.dents,
            DentUnit::Per10Cm => self.dents / 10.0 * CM_PER_INCH,
        }
    }

    /// "the 12-dent reed" or "the 40/10 reed".
    pub fn describe(self) -> String {
        match self.per {
            DentUnit::PerInch => format!("the {}-dent reed", number(self.dents)),
            DentUnit::Per10Cm => format!("the {}/10 reed", number(self.dents)),
        }
    }
}

/// One loom, as the weaver describes it. Every equipment field may be missing (see the module doc).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LoomProfile {
    /// Stable id: `[A-Za-z0-9][A-Za-z0-9_-]{0,63}` (the app uses a uuid). Drafts refer to it.
    pub id: String,
    /// What the weaver calls the loom. May be empty (shown as "this loom").
    pub name: String,
    /// The loom type, or `None` when not recorded.
    pub kind: Option<LoomKind>,
    /// Shafts on the loom.
    pub shafts: Option<u16>,
    /// Treadles on a floor loom. A table loom has a lever per shaft instead, and a dobby selects the
    /// shafts itself, so neither has a treadle count.
    pub treadles: Option<u16>,
    /// The widest warp the loom takes in the reed.
    pub weaving_width: Option<Length>,
    /// The reeds the weaver has. Empty = none recorded.
    #[serde(default)]
    pub reeds: Vec<Reed>,
    /// Tie-up constraint: the most treadles the weaver presses together for one pick (two feet, a
    /// skeleton tie-up). `None` = not recorded.
    pub treadles_at_once: Option<u8>,
    /// Free setup notes.
    #[serde(default)]
    pub notes: String,
}

impl LoomProfile {
    /// A profile with nothing recorded but its id and name.
    pub fn new(id: impl Into<String>, name: impl Into<String>) -> LoomProfile {
        LoomProfile {
            id: id.into(),
            name: name.into(),
            kind: None,
            shafts: None,
            treadles: None,
            weaving_width: None,
            reeds: Vec::new(),
            treadles_at_once: None,
            notes: String::new(),
        }
    }

    /// The name for sentences: the trimmed name, or "this loom" when it has none.
    pub fn display_name(&self) -> String {
        let name = self.name.trim();
        if name.is_empty() {
            "this loom".to_string()
        } else {
            name.to_string()
        }
    }

    /// Every way this profile breaks the limits above, in field order (empty = valid). Profiles come
    /// from a file or across FFI, so they are untrusted: the file reader refuses an invalid one and
    /// the bridge reports it instead of checking against it.
    pub fn problems(&self) -> Vec<String> {
        let mut out = Vec::new();
        if !is_valid_id(&self.id) {
            out.push(format!(
                "loom id {:?} is not a valid id",
                truncate(&self.id)
            ));
        }
        if self.name.chars().count() > MAX_LOOM_NAME_CHARS {
            out.push(format!(
                "the loom name is longer than {MAX_LOOM_NAME_CHARS} characters"
            ));
        }
        if let Some(s) = self.shafts.filter(|&s| s == 0 || s > MAX_LOOM_SHAFTS) {
            out.push(format!("shafts {s} is outside 1..={MAX_LOOM_SHAFTS}"));
        }
        if let Some(t) = self.treadles.filter(|&t| t == 0 || t > MAX_LOOM_TREADLES) {
            out.push(format!("treadles {t} is outside 1..={MAX_LOOM_TREADLES}"));
        }
        if let Some(n) = self
            .treadles_at_once
            .filter(|&n| n == 0 || n > MAX_TREADLES_AT_ONCE)
        {
            out.push(format!(
                "treadles at once {n} is outside 1..={MAX_TREADLES_AT_ONCE}"
            ));
        }
        if let Some(w) = self.weaving_width {
            if !(w.value.is_finite() && w.value > 0.0 && w.value <= MAX_WEAVING_WIDTH) {
                out.push(format!(
                    "weaving width {} is not a width from above 0 to {MAX_WEAVING_WIDTH}",
                    w.value
                ));
            }
        }
        if self.reeds.len() > MAX_REEDS {
            out.push(format!("more than {MAX_REEDS} reeds"));
        }
        for r in &self.reeds {
            if !(r.dents.is_finite() && r.dents > 0.0 && r.dents <= MAX_REED_DENTS) {
                out.push(format!(
                    "reed dents {} is not a count from above 0 to {MAX_REED_DENTS}",
                    r.dents
                ));
            }
        }
        if self.notes.chars().count() > MAX_LOOM_NOTES_CHARS {
            out.push(format!(
                "the notes are longer than {MAX_LOOM_NOTES_CHARS} characters"
            ));
        }
        out
    }
}

/// Whether `id` matches `[A-Za-z0-9][A-Za-z0-9_-]{0,63}`.
pub fn is_valid_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= MAX_LOOM_ID_LEN
        && bytes[0].is_ascii_alphanumeric()
        && bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'-')
}

/// At most 40 characters of `s`, for error messages about untrusted text.
fn truncate(s: &str) -> String {
    s.chars().take(40).collect()
}

/// A number as a weaver writes it: at most one decimal, no trailing ".0" (12, 12.5, 0.8).
pub fn number(v: f64) -> String {
    let r = (v * 10.0).round() / 10.0;
    if (r - r.round()).abs() < 1e-9 {
        format!("{}", r.round() as i64)
    } else {
        format!("{r:.1}")
    }
}

/// `Unit` in `looms.json` as `"inches"` / `"centimeters"` (the engine's `Unit` serializes as
/// `"Inches"`, which is right for its other uses; the loom file has its own lowercase spelling).
mod unit_serde {
    use ply_common::Unit;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(unit: &Unit, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(match unit {
            Unit::Inches => "inches",
            Unit::Centimeters => "centimeters",
        })
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Unit, D::Error> {
        match String::deserialize(d)?.as_str() {
            "inches" => Ok(Unit::Inches),
            "centimeters" => Ok(Unit::Centimeters),
            other => Err(serde::de::Error::custom(format!(
                "unknown unit {other:?}, expected inches or centimeters"
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn full() -> LoomProfile {
        LoomProfile {
            id: "floor-loom".into(),
            name: "Floor loom".into(),
            kind: Some(LoomKind::Jack),
            shafts: Some(8),
            treadles: Some(10),
            weaving_width: Some(Length {
                value: 36.0,
                unit: Unit::Inches,
            }),
            reeds: vec![Reed {
                dents: 12.0,
                per: DentUnit::PerInch,
            }],
            treadles_at_once: Some(2),
            notes: "Back beam squeaks.".into(),
        }
    }

    #[test]
    fn a_complete_and_an_empty_profile_are_valid() {
        assert!(full().problems().is_empty());
        assert!(LoomProfile::new("a", "").problems().is_empty());
    }

    #[test]
    fn zero_is_never_a_valid_count() {
        let mut p = full();
        p.shafts = Some(0);
        p.treadles = Some(0);
        p.treadles_at_once = Some(0);
        p.weaving_width = Some(Length {
            value: 0.0,
            unit: Unit::Inches,
        });
        p.reeds = vec![Reed {
            dents: 0.0,
            per: DentUnit::PerInch,
        }];
        assert_eq!(p.problems().len(), 5, "{:?}", p.problems());
    }

    #[test]
    fn limits_and_ids_are_enforced() {
        let mut p = full();
        p.id = "../etc".into();
        p.shafts = Some(MAX_LOOM_SHAFTS + 1);
        p.weaving_width = Some(Length {
            value: f64::NAN,
            unit: Unit::Centimeters,
        });
        p.reeds = vec![
            Reed {
                dents: 10.0,
                per: DentUnit::PerInch
            };
            MAX_REEDS + 1
        ];
        p.name = "x".repeat(MAX_LOOM_NAME_CHARS + 1);
        p.notes = "y".repeat(MAX_LOOM_NOTES_CHARS + 1);
        assert_eq!(p.problems().len(), 6, "{:?}", p.problems());
        assert!(is_valid_id("3f1c9a2e-0d4b-4c8e-9f00-123456789abc"));
        assert!(!is_valid_id(""));
        assert!(!is_valid_id("-leading"));
        assert!(!is_valid_id(&"a".repeat(65)));
    }

    #[test]
    fn units_convert() {
        let w = Length {
            value: 91.44,
            unit: Unit::Centimeters,
        };
        assert!((w.inches() - 36.0).abs() < 1e-9);
        let reed = Reed {
            dents: 50.0,
            per: DentUnit::Per10Cm,
        };
        assert!((reed.dents_per_inch() - 12.7).abs() < 1e-9);
        assert_eq!(reed.describe(), "the 50/10 reed");
        assert_eq!(number(12.0), "12");
        assert_eq!(number(12.04), "12");
        assert_eq!(number(20.32), "20.3");
    }

    #[test]
    fn display_name_never_blank() {
        assert_eq!(LoomProfile::new("a", "  ").display_name(), "this loom");
        assert_eq!(
            LoomProfile::new("a", " Floor loom ").display_name(),
            "Floor loom"
        );
    }
}
