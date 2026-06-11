//! Shared types across all Ply craft engines (weaving, knitting, nalbinding).
//!
//! This crate is **pure**: no Flutter, no FFI, no I/O beyond serde. Keep it that way
//! so it can be reused by the app, a CLI, batch tooling, or a server-side generator.

use serde::{Deserialize, Serialize};

/// The three fiber crafts Ply targets. Present from day one so the multi-engine
/// seam is visible even while only weaving is implemented.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CraftKind {
    Weaving,
    Knitting,
    Nalbinding,
}

/// An sRGB color. WIF color palettes are RGB triples; we store the same.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Color {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl Color {
    pub const WHITE: Color = Color { r: 255, g: 255, b: 255 };
    pub const BLACK: Color = Color { r: 0, g: 0, b: 0 };

    pub const fn rgb(r: u8, g: u8, b: u8) -> Self {
        Color { r, g, b }
    }

    /// Parse `#rrggbb` or `rrggbb`.
    pub fn from_hex(s: &str) -> Option<Color> {
        let s = s.strip_prefix('#').unwrap_or(s);
        if s.len() != 6 {
            return None;
        }
        Some(Color {
            r: u8::from_str_radix(&s[0..2], 16).ok()?,
            g: u8::from_str_radix(&s[2..4], 16).ok()?,
            b: u8::from_str_radix(&s[4..6], 16).ok()?,
        })
    }

    pub fn to_hex(self) -> String {
        format!("#{:02x}{:02x}{:02x}", self.r, self.g, self.b)
    }
}

/// Craft Yarn Council weight system (codes 0-7). Used to seed sett suggestions and
/// to label yarns consistently across crafts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum YarnWeight {
    Lace,       // 0
    SuperFine,  // 1  fingering / sock
    Fine,       // 2  sport
    Light,      // 3  DK
    Medium,     // 4  worsted / aran
    Bulky,      // 5
    SuperBulky, // 6
    Jumbo,      // 7
}

impl YarnWeight {
    pub fn code(self) -> u8 {
        match self {
            YarnWeight::Lace => 0,
            YarnWeight::SuperFine => 1,
            YarnWeight::Fine => 2,
            YarnWeight::Light => 3,
            YarnWeight::Medium => 4,
            YarnWeight::Bulky => 5,
            YarnWeight::SuperBulky => 6,
            YarnWeight::Jumbo => 7,
        }
    }

    /// Approximate wraps-per-inch midpoint, a craft rule of thumb (not exact). Used to
    /// seed a sett suggestion when the user hasn't measured their own WPI.
    pub fn typical_wpi(self) -> f32 {
        match self {
            YarnWeight::Lace => 18.0,
            YarnWeight::SuperFine => 14.0,
            YarnWeight::Fine => 12.0,
            YarnWeight::Light => 11.0,
            YarnWeight::Medium => 9.0,
            YarnWeight::Bulky => 7.0,
            YarnWeight::SuperBulky => 5.0,
            YarnWeight::Jumbo => 3.0,
        }
    }
}

/// A yarn in the user's stash or referenced by a pattern.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Yarn {
    pub label: String,
    pub fiber: Option<String>,
    pub weight: Option<YarnWeight>,
    /// Yards per unit mass (e.g. yards per 100 g), for usage estimation. Optional.
    pub yards_per_unit: Option<f32>,
    pub color: Color,
}

/// Measurement units. WIF stores either decimal inches or centimeters.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Unit {
    Inches,
    Centimeters,
}

/// Lightweight project metadata stored alongside the native pattern file (e.g. a JSON
/// sidecar next to a `.wif`). Keeps app concerns out of the engine crates.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProjectMeta {
    pub name: String,
    pub craft: CraftKind,
    pub author: Option<String>,
    pub notes: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn color_hex_roundtrip() {
        let c = Color::rgb(18, 52, 86);
        assert_eq!(c.to_hex(), "#123456");
        assert_eq!(Color::from_hex("#123456"), Some(c));
        assert_eq!(Color::from_hex("123456"), Some(c));
        assert_eq!(Color::from_hex("nope"), None);
    }
}
