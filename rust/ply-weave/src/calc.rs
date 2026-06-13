//! Weaving calculators.
//!
//! v1 covers the headline weaving numbers: **sett** (how densely to space the warp),
//! **warp length / total warp yarn**, and **weft yarn** from picks-per-unit, woven
//! width, and a user-supplied weft take-up allowance.

use serde::{Deserialize, Serialize};

/// Weave structure family — controls how dense a sett to suggest from yarn WPI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Structure {
    /// Plain weave / tabby: maximum interlacement, most open sett.
    Plain,
    /// Twill: fewer interlacements, denser sett.
    Twill,
    /// Satin / sateen: long floats, densest.
    Satin,
}

impl Structure {
    /// Fraction of wraps-per-inch to use as ends-per-inch for a balanced cloth.
    /// Common rules of thumb: plain ~0.50, twill ~0.66, satin ~0.75 of WPI.
    pub fn sett_fraction(self) -> f32 {
        match self {
            Structure::Plain => 0.50,
            Structure::Twill => 0.66,
            Structure::Satin => 0.75,
        }
    }
}

/// Suggest a sett (ends per inch) from a measured wraps-per-inch and structure.
pub fn suggest_sett(wpi: f32, structure: Structure) -> f32 {
    (wpi * structure.sett_fraction()).round()
}

/// Inputs for a warp-length / yarn-usage estimate. Lengths are in the draft's unit.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WarpPlan {
    /// Finished length wanted, per item.
    pub finished_length: f32,
    pub items: u32,
    /// Number of warp ends across the width.
    pub ends: u32,
    /// Loom waste per warp (thrums, tie-on, take-up to the back beam).
    pub loom_waste: f32,
    /// Take-up + shrinkage as a fraction (e.g. 0.10 for 10%).
    pub takeup_shrinkage: f32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct YarnEstimate {
    /// Total warp length to wind (all items + take-up + a single loom-waste allowance).
    pub warp_length: f32,
    /// Total warp yarn summed over every end (`warp_length * ends`).
    pub total_warp: f32,
}

/// Estimate warp length and total warp yarn needed.
///
/// `warp_length = items * finished_length * (1 + takeup_shrinkage) + loom_waste`
/// `total_warp  = warp_length * ends`
pub fn estimate_warp(plan: &WarpPlan) -> YarnEstimate {
    let per_item = plan.finished_length * (1.0 + plan.takeup_shrinkage);
    let warp_length = per_item * plan.items as f32 + plan.loom_waste;
    YarnEstimate { warp_length, total_warp: warp_length * plan.ends as f32 }
}

/// Inputs for a weft-yarn estimate. Lengths are in the draft's unit; `picks_per_unit`
/// is weft picks per that same unit of woven length (i.e. picks-per-inch when the
/// draft works in inches).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WeftPlan {
    /// Weft picks per unit of woven length (picks-per-inch in an imperial draft).
    pub picks_per_unit: f32,
    /// Woven width — the warp's width in the reed.
    pub width: f32,
    /// Woven length per item (the length actually woven, before cutting from the loom).
    pub woven_length: f32,
    pub items: u32,
    /// Weft take-up + selvedge/wastage, as a fraction (e.g. 0.10 for 10%). Captures the
    /// crimp the weft gains traveling over and under the warp plus a selvedge-turn
    /// allowance. Surfaced as a user input so the weaver dials it to their own cloth
    /// rather than trusting a baked-in guess.
    pub takeup: f32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WeftEstimate {
    /// Total weft picks across all items (`round(picks_per_unit * woven_length) * items`).
    pub picks: u32,
    /// Total weft yarn: `picks * width * (1 + takeup)`, in the draft's unit.
    pub total_weft: f32,
}

/// Estimate total weft yarn needed.
///
/// `picks      = round(picks_per_unit * woven_length) * items`
/// `total_weft = picks * width * (1 + takeup)`
///
/// The take-up here is width-direction: it scales each pick's length, not the pick
/// count. Length-direction take-up belongs to the warp estimate / `woven_length`.
pub fn estimate_weft(plan: &WeftPlan) -> WeftEstimate {
    // `as u32` already saturates a huge float; saturate the product too so an extreme
    // picks-per-item * items can't overflow-panic (debug) / wrap (release).
    let picks_per_item = (plan.picks_per_unit * plan.woven_length).round() as u32;
    let picks = picks_per_item.saturating_mul(plan.items);
    let total_weft = picks as f32 * plan.width * (1.0 + plan.takeup);
    WeftEstimate { picks, total_weft }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sett_scales_with_structure() {
        assert_eq!(suggest_sett(20.0, Structure::Plain), 10.0);
        assert_eq!(suggest_sett(20.0, Structure::Twill), 13.0); // 13.2 -> 13
    }

    #[test]
    fn warp_estimate_includes_waste_and_takeup() {
        let plan = WarpPlan {
            finished_length: 60.0,
            items: 1,
            ends: 200,
            loom_waste: 24.0,
            takeup_shrinkage: 0.10,
        };
        let est = estimate_warp(&plan);
        assert_eq!(est.warp_length, 90.0); // 60*1.1 + 24
        assert_eq!(est.total_warp, 18_000.0); // 90 * 200
    }

    #[test]
    fn weft_estimate_uses_user_takeup() {
        let plan = WeftPlan {
            picks_per_unit: 12.0, // 12 ppi
            width: 20.0,          // 20" in the reed
            woven_length: 60.0,   // 60" woven
            items: 1,
            takeup: 0.10, // 10% weft take-up + selvedge allowance
        };
        let est = estimate_weft(&plan);
        assert_eq!(est.picks, 720); // 12 * 60
        assert_eq!(est.total_weft, 15_840.0); // 720 * 20 * 1.1
    }
}
