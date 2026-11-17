//! Lightweight validation of a [`StitchType`]. The notation parser already guarantees well-formed
//! passes/connections, so this catches the few things a directly-constructed or
//! deserialized stitch can still get wrong: an empty needle path, or a connection that engages no
//! loops. Advisory — the reference screen surfaces these inline.
//!
//! Every finding carries a stable code and a typed [`NalbindLocation`] (ADR 0021).

use crate::stitch::StitchType;

/// The severity vocabulary every craft shares (ADR 0021). Stitch validation reports errors and
/// warnings.
pub use ply_common::readiness::Severity;

/// The code of a stitch with no needle path.
pub const NO_NEEDLE_PATH: &str = "stitch-no-needle-path";
/// The code of a connection that engages no loops.
pub const CONNECTION_NO_LOOPS: &str = "connection-no-loops";

/// Where a stitch finding applies.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NalbindLocation {
    /// The stitch as a whole (its needle path).
    Stitch,
    /// One connection, by its 0-based position in the stitch's connections.
    Connection { index: usize },
}

impl NalbindLocation {
    /// "Stitch", "Connection 2".
    pub fn text(&self) -> String {
        match self {
            NalbindLocation::Stitch => "Stitch".to_string(),
            NalbindLocation::Connection { index } => format!("Connection {}", index + 1),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NalbindIssue {
    pub code: &'static str,
    pub severity: Severity,
    pub location: NalbindLocation,
    pub message: String,
}

impl NalbindIssue {
    fn error(code: &'static str, location: NalbindLocation, message: impl Into<String>) -> Self {
        NalbindIssue {
            code,
            severity: Severity::Error,
            location,
            message: message.into(),
        }
    }
    fn warning(code: &'static str, location: NalbindLocation, message: impl Into<String>) -> Self {
        NalbindIssue {
            code,
            severity: Severity::Warning,
            location,
            message: message.into(),
        }
    }
}

/// Validate a stitch; an empty list means it is clean.
pub fn validate(stitch: &StitchType) -> Vec<NalbindIssue> {
    let mut issues = Vec::new();

    let total_steps: usize = stitch.passes.iter().map(|p| p.steps.len()).sum();
    if total_steps == 0 {
        issues.push(NalbindIssue::error(
            NO_NEEDLE_PATH,
            NalbindLocation::Stitch,
            "the stitch has no needle path (no U/O steps)",
        ));
    }

    for (i, c) in stitch.connections.iter().enumerate() {
        if c.count == 0 && c.extra.is_none() {
            issues.push(NalbindIssue::warning(
                CONNECTION_NO_LOOPS,
                NalbindLocation::Connection { index: i },
                format!("connection {} engages 0 loops", i + 1),
            ));
        }
    }

    issues
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dictionary::builtin;
    use crate::notation;
    use crate::stitch::{ConnSide, Connection, StitchType};

    #[test]
    fn every_builtin_is_clean() {
        for st in builtin() {
            assert!(
                validate(&st).is_empty(),
                "{} should be clean: {:?}",
                st.name,
                validate(&st)
            );
        }
    }

    #[test]
    fn an_empty_path_is_an_error() {
        let st = StitchType::anonymous(vec![], vec![]);
        assert!(validate(&st).iter().any(|i| i.severity == Severity::Error));
    }

    #[test]
    fn a_zero_count_connection_warns() {
        let (passes, _) = notation::parse("UO/UOO").unwrap();
        let st = StitchType::anonymous(passes, vec![Connection::new(ConnSide::Front, 0)]);
        let issues = validate(&st);
        assert!(issues.iter().any(|i| i.severity == Severity::Warning
            && i.code == CONNECTION_NO_LOOPS
            && i.location == NalbindLocation::Connection { index: 0 }));
        assert_eq!(issues[0].location.text(), "Connection 1");
    }

    #[test]
    fn an_empty_path_is_located_at_the_stitch() {
        let st = StitchType::anonymous(vec![], vec![]);
        let i = &validate(&st)[0];
        assert_eq!(
            (i.code, i.location),
            (NO_NEEDLE_PATH, NalbindLocation::Stitch)
        );
        assert_eq!(i.location.text(), "Stitch");
    }
}
