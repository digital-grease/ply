//! Lightweight validation of a [`StitchType`]. The notation parser already guarantees well-formed
//! passes/connections, so this catches the few things a directly-constructed or
//! deserialized stitch can still get wrong: an empty needle path, or a connection that engages no
//! loops. Advisory — the reference screen surfaces these inline.

use serde::{Deserialize, Serialize};

use crate::stitch::StitchType;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Severity {
    Error,
    Warning,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NalbindIssue {
    pub severity: Severity,
    pub message: String,
}

impl NalbindIssue {
    fn error(message: impl Into<String>) -> Self {
        NalbindIssue { severity: Severity::Error, message: message.into() }
    }
    fn warning(message: impl Into<String>) -> Self {
        NalbindIssue { severity: Severity::Warning, message: message.into() }
    }
}

/// Validate a stitch; an empty list means it is clean.
pub fn validate(stitch: &StitchType) -> Vec<NalbindIssue> {
    let mut issues = Vec::new();

    let total_steps: usize = stitch.passes.iter().map(|p| p.steps.len()).sum();
    if total_steps == 0 {
        issues.push(NalbindIssue::error("the stitch has no needle path (no U/O steps)"));
    }

    for (i, c) in stitch.connections.iter().enumerate() {
        if c.count == 0 && c.extra.is_none() {
            issues.push(NalbindIssue::warning(format!(
                "connection {} engages 0 loops",
                i + 1
            )));
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
            assert!(validate(&st).is_empty(), "{} should be clean: {:?}", st.name, validate(&st));
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
        assert!(validate(&st).iter().any(|i| i.severity == Severity::Warning));
    }
}
