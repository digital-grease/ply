//! The severity vocabulary every craft shares, and the "ready to make or share" report an output
//! reads (ADR 0021, roadmap M7-05 and contract 10.2).
//!
//! Saving never reads this: a draft saves whatever it holds. An output that will be made from or
//! sent to someone (a printed or shared pattern) asks each craft's `ready_to_make` function for a
//! [`Readiness`] and follows its [`Verdict`]: errors block a ready output, warnings and unsupported
//! items are acknowledged in one step, information never asks.

use serde::{Deserialize, Serialize};

/// How much a finding matters: the same four words in every craft. Ordered most serious first, so
/// sorting a list puts errors first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    /// The pattern cannot be worked as written. Blocks a ready output.
    Error,
    /// It can be worked, but something is likely to go wrong or is worth checking.
    Warning,
    /// Something Ply cannot check or represent. It is kept as written and listed with what was not
    /// checked, never silently approximated.
    Unsupported,
    /// Advice or a fact worth showing; never a problem.
    Info,
}

impl Severity {
    /// Every severity, most serious first.
    pub const ALL: [Severity; 4] = [
        Severity::Error,
        Severity::Warning,
        Severity::Unsupported,
        Severity::Info,
    ];

    /// The stable lower-case word (`error`, `warning`, `unsupported`, `info`), the serde form.
    pub const fn as_str(self) -> &'static str {
        match self {
            Severity::Error => "error",
            Severity::Warning => "warning",
            Severity::Unsupported => "unsupported",
            Severity::Info => "info",
        }
    }

    /// True when a finding of this severity keeps an output from being ready.
    pub const fn blocks(self) -> bool {
        matches!(self, Severity::Error)
    }

    /// True when a ready output asks the user to acknowledge it first.
    pub const fn needs_acknowledgement(self) -> bool {
        matches!(self, Severity::Warning | Severity::Unsupported)
    }
}

/// Which check a readiness item came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Check {
    /// A weaving draft's structural validation.
    Draft,
    /// A weaving draft against the loom chosen for it.
    Loom,
    /// A weaving draft's warp, weft and finishing plan.
    Plan,
    /// A knitting chart's validation (cells, cables, repeats, stitch counts).
    Chart,
    /// A knitting pattern's sections and their stitch ledger.
    Sections,
    /// A nalbinding project's notation, read strictly.
    Notation,
    /// A nalbinding stitch's own validation.
    Stitch,
    /// A nalbinding project's recipe.
    Recipe,
    /// A tablet weaving band.
    Band,
}

impl Check {
    pub const ALL: [Check; 9] = [
        Check::Draft,
        Check::Loom,
        Check::Plan,
        Check::Chart,
        Check::Sections,
        Check::Notation,
        Check::Stitch,
        Check::Recipe,
        Check::Band,
    ];

    /// The stable lower-case word, the serde form.
    pub const fn as_str(self) -> &'static str {
        match self {
            Check::Draft => "draft",
            Check::Loom => "loom",
            Check::Plan => "plan",
            Check::Chart => "chart",
            Check::Sections => "sections",
            Check::Notation => "notation",
            Check::Stitch => "stitch",
            Check::Recipe => "recipe",
            Check::Band => "band",
        }
    }
}

/// The most findings of one kind (one check, code and severity) a report lists; the rest are
/// counted in one "more not listed" item, so a hostile or huge document gives a bounded report.
pub const MAX_ITEMS_PER_KIND: usize = 200;

/// The most characters of a finding's sentence a report keeps (longer ones end in "...").
pub const MAX_MESSAGE_CHARS: usize = 600;

/// The most characters of a finding's place a report keeps (longer ones end in "...").
pub const MAX_PLACE_CHARS: usize = 160;

/// One finding an output must consider.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadinessItem {
    pub check: Check,
    /// The engine's stable code for this kind of finding (unique within its check).
    pub code: String,
    pub severity: Severity,
    /// Where it is, in words ("Pick 3, treadle 9", "Back, step 3"); `None` for the whole document.
    pub place: Option<String>,
    /// The finding, a sentence for people. Tests key on the check and code, not on this text.
    pub message: String,
    /// What the maker can do, when the engine can suggest something.
    pub remediation: Option<String>,
    /// 0 for a finding. For the item that closes a kind past [`MAX_ITEMS_PER_KIND`], how many
    /// findings of that kind it stands for (they are counted, not listed).
    pub omitted: u64,
}

impl ReadinessItem {
    pub fn new(
        check: Check,
        code: impl Into<String>,
        severity: Severity,
        place: Option<String>,
        message: impl Into<String>,
    ) -> Self {
        ReadinessItem {
            check,
            code: code.into(),
            severity,
            place,
            message: message.into(),
            remediation: None,
            omitted: 0,
        }
    }

    pub fn with_remediation(mut self, remediation: Option<String>) -> Self {
        self.remediation = remediation;
        self
    }

    /// How many findings this item stands for: 1, or the count of a "more not listed" item.
    pub fn weight(&self) -> u64 {
        if self.omitted == 0 {
            1
        } else {
            self.omitted
        }
    }
}

/// What an output may do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    /// Nothing blocks or needs acknowledging: the output is produced straight away.
    Ready,
    /// No errors, but warnings or unsupported items the user acknowledges in one step first.
    NeedsAcknowledgement,
    /// At least one error: an output marked ready is never produced. Only an explicitly chosen,
    /// labelled draft copy is.
    NotReady,
}

/// Everything an output must consider for one document: the checks that ran and every finding.
/// Built with a [`ReadinessBuilder`].
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Readiness {
    /// The checks that ran, in the order they ran, each once.
    pub checked: Vec<Check>,
    /// The findings, most serious first; within one severity, kinds in the order the checks first
    /// found them, each kind's findings in the order found, then its "more not listed" item if any.
    pub items: Vec<ReadinessItem>,
}

impl Readiness {
    pub fn verdict(&self) -> Verdict {
        if self.items.iter().any(|i| i.severity.blocks()) {
            Verdict::NotReady
        } else if self
            .items
            .iter()
            .any(|i| i.severity.needs_acknowledgement())
        {
            Verdict::NeedsAcknowledgement
        } else {
            Verdict::Ready
        }
    }

    /// How many findings have `severity`, the ones counted but not listed included.
    pub fn count(&self, severity: Severity) -> u64 {
        self.items
            .iter()
            .filter(|i| i.severity == severity)
            .map(ReadinessItem::weight)
            .sum()
    }

    /// The items of `severity`, in list order.
    pub fn with_severity(&self, severity: Severity) -> impl Iterator<Item = &ReadinessItem> {
        self.items.iter().filter(move |i| i.severity == severity)
    }

    /// The (check, code) of every item, in list order: a stable key for tests.
    pub fn codes(&self) -> Vec<(Check, &str)> {
        self.items
            .iter()
            .map(|i| (i.check, i.code.as_str()))
            .collect()
    }
}

/// One kind of finding: its first appearance fixes its place in the list.
struct Kind {
    check: Check,
    code: String,
    severity: Severity,
    kept: usize,
    omitted: u64,
}

#[cfg(test)]
thread_local! {
    /// How many items this thread's builders have made (test builds only), to prove that a finding
    /// past the cap is counted without being built.
    static BUILT: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// Collects a [`Readiness`]: every push is O(1) (amortized), at most [`MAX_ITEMS_PER_KIND`] items of
/// a kind are kept (the rest only counted), text is bounded, and [`ReadinessBuilder::finish`] sorts
/// once.
#[derive(Default)]
pub struct ReadinessBuilder {
    checked: Vec<Check>,
    /// (kind index, item), in push order.
    items: Vec<(usize, ReadinessItem)>,
    kinds: Vec<Kind>,
    /// Kind indices by (check, severity), then code.
    index: std::collections::HashMap<(Check, Severity), std::collections::HashMap<String, usize>>,
}

impl ReadinessBuilder {
    pub fn new() -> Self {
        ReadinessBuilder::default()
    }

    /// Record that `check` ran (once, however often it is called).
    pub fn ran(&mut self, check: Check) {
        if !self.checked.contains(&check) {
            self.checked.push(check);
        }
    }

    /// Add one finding.
    pub fn push(&mut self, item: ReadinessItem) {
        let (check, severity) = (item.check, item.severity);
        let code = item.code.clone();
        self.push_with(check, &code, severity, move || item);
    }

    /// Add one finding of the kind (`check`, `code`, `severity`), built by `make` only when it will
    /// be listed: past [`MAX_ITEMS_PER_KIND`] of its kind it is only counted.
    pub fn push_with(
        &mut self,
        check: Check,
        code: &str,
        severity: Severity,
        make: impl FnOnce() -> ReadinessItem,
    ) {
        self.ran(check);
        let next = self.kinds.len();
        let by_code = self.index.entry((check, severity)).or_default();
        let k = match by_code.get(code) {
            Some(&k) => k,
            None => {
                by_code.insert(code.to_string(), next);
                self.kinds.push(Kind {
                    check,
                    code: code.to_string(),
                    severity,
                    kept: 0,
                    omitted: 0,
                });
                next
            }
        };
        let kind = &mut self.kinds[k];
        if kind.kept >= MAX_ITEMS_PER_KIND {
            kind.omitted = kind.omitted.saturating_add(1);
            return;
        }
        kind.kept += 1;
        #[cfg(test)]
        BUILT.with(|b| b.set(b.get() + 1));
        let mut item = make();
        debug_assert!(item.check == check && item.code == code && item.severity == severity);
        item.message = bounded(&item.message, MAX_MESSAGE_CHARS);
        item.place = item.place.map(|p| bounded(&p, MAX_PLACE_CHARS));
        item.remediation = item.remediation.map(|r| bounded(&r, MAX_MESSAGE_CHARS));
        self.items.push((k, item));
    }

    /// The report: most serious first, each kind together in the order kinds were first found, a
    /// capped kind closed by one item counting the rest. One stable sort.
    pub fn finish(self) -> Readiness {
        let ReadinessBuilder {
            checked,
            mut items,
            kinds,
            ..
        } = self;
        for (k, kind) in kinds.iter().enumerate() {
            if kind.omitted > 0 {
                let mut more = ReadinessItem::new(
                    kind.check,
                    kind.code.clone(),
                    kind.severity,
                    None,
                    format!(
                        "{} more like this {} not listed: Ply lists the first {} of each kind.",
                        thousands(kind.omitted),
                        if kind.omitted == 1 { "is" } else { "are" },
                        MAX_ITEMS_PER_KIND
                    ),
                );
                more.omitted = kind.omitted;
                items.push((k, more));
            }
        }
        // Stable: within one kind, findings keep their order and the "more" item comes last.
        items.sort_by_key(|(k, _)| (kinds[*k].severity, *k));
        Readiness {
            checked,
            items: items.into_iter().map(|(_, i)| i).collect(),
        }
    }
}

/// At most `max` characters of `text` (cut on a character boundary), with "..." when cut.
pub fn bounded(text: &str, max: usize) -> String {
    let mut chars = text.chars();
    let mut out: String = chars.by_ref().take(max).collect();
    if chars.next().is_some() {
        out.push_str("...");
    }
    out
}

/// `1234567` as "1,234,567".
fn thousands(n: u64) -> String {
    let digits = n.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, ch) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(ch);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(check: Check, code: &str, severity: Severity) -> ReadinessItem {
        ReadinessItem::new(check, code, severity, None, code)
    }

    #[test]
    fn severities_sort_most_serious_first_and_name_themselves() {
        let mut all = vec![
            Severity::Info,
            Severity::Unsupported,
            Severity::Error,
            Severity::Warning,
        ];
        all.sort();
        assert_eq!(all, Severity::ALL);
        let words: Vec<&str> = Severity::ALL.iter().map(|s| s.as_str()).collect();
        assert_eq!(words, ["error", "warning", "unsupported", "info"]);
        assert!(Severity::Error.blocks());
        assert!(!Severity::Warning.blocks() && !Severity::Unsupported.blocks());
        assert!(Severity::Warning.needs_acknowledgement());
        assert!(Severity::Unsupported.needs_acknowledgement());
        assert!(
            !Severity::Info.needs_acknowledgement() && !Severity::Error.needs_acknowledgement()
        );
        // The serde form is the word.
        assert_eq!(
            serde_json::to_string(&Severity::Unsupported).unwrap(),
            "\"unsupported\""
        );
    }

    #[test]
    fn the_verdict_follows_the_most_serious_finding() {
        let report = |items: &[ReadinessItem]| {
            let mut b = ReadinessBuilder::new();
            for i in items {
                b.push(i.clone());
            }
            b.finish()
        };
        assert_eq!(report(&[]).verdict(), Verdict::Ready);
        let info = item(Check::Draft, "a", Severity::Info);
        assert_eq!(
            report(std::slice::from_ref(&info)).verdict(),
            Verdict::Ready,
            "information never asks"
        );
        let unsupported = item(Check::Loom, "b", Severity::Unsupported);
        assert_eq!(
            report(&[info.clone(), unsupported.clone()]).verdict(),
            Verdict::NeedsAcknowledgement
        );
        let warning = item(Check::Plan, "c", Severity::Warning);
        assert_eq!(report(&[warning]).verdict(), Verdict::NeedsAcknowledgement);
        let error = item(Check::Draft, "d", Severity::Error);
        assert_eq!(
            report(&[info, unsupported, error]).verdict(),
            Verdict::NotReady
        );
    }

    #[test]
    fn items_sort_by_severity_then_kind_and_checks_are_recorded_once() {
        let mut b = ReadinessBuilder::new();
        b.ran(Check::Draft);
        b.push(item(Check::Draft, "info", Severity::Info));
        b.push(item(Check::Draft, "warn-1", Severity::Warning));
        b.push(item(Check::Loom, "unsupported", Severity::Unsupported));
        b.push(item(Check::Loom, "warn-2", Severity::Warning));
        b.push(item(Check::Plan, "error", Severity::Error));
        b.push(item(Check::Draft, "warn-1", Severity::Warning));
        b.ran(Check::Draft);
        let r = b.finish();
        assert_eq!(
            r.codes(),
            vec![
                (Check::Plan, "error"),
                (Check::Draft, "warn-1"),
                (Check::Draft, "warn-1"),
                (Check::Loom, "warn-2"),
                (Check::Loom, "unsupported"),
                (Check::Draft, "info"),
            ]
        );
        assert_eq!(r.checked, vec![Check::Draft, Check::Loom, Check::Plan]);
        assert_eq!(r.count(Severity::Warning), 3);
        assert_eq!(r.with_severity(Severity::Error).count(), 1);
        let words: Vec<&str> = Check::ALL.iter().map(|c| c.as_str()).collect();
        assert_eq!(
            words,
            [
                "draft", "loom", "plan", "chart", "sections", "notation", "stitch", "recipe",
                "band"
            ]
        );
    }

    #[test]
    fn a_kind_past_the_cap_is_counted_without_being_built() {
        let before = BUILT.with(|b| b.get());
        let mut b = ReadinessBuilder::new();
        const N: u64 = 100_000;
        for n in 0..N {
            b.push_with(Check::Draft, "many", Severity::Error, || {
                ReadinessItem::new(
                    Check::Draft,
                    "many",
                    Severity::Error,
                    Some(format!("End {n}")),
                    "bad",
                )
            });
        }
        b.push(item(Check::Draft, "other", Severity::Warning));
        let built = BUILT.with(|b| b.get()) - before;
        assert_eq!(
            built,
            MAX_ITEMS_PER_KIND as u64 + 1,
            "only the listed items are built"
        );
        let r = b.finish();
        assert_eq!(r.items.len(), MAX_ITEMS_PER_KIND + 2);
        let more = &r.items[MAX_ITEMS_PER_KIND];
        assert_eq!((more.code.as_str(), more.omitted), ("many", N - 200));
        assert_eq!(
            more.message,
            "99,800 more like this are not listed: Ply lists the first 200 of each kind."
        );
        assert_eq!(r.count(Severity::Error), N, "every finding is counted");
        assert_eq!(r.items.last().unwrap().code, "other");
        assert_eq!(r.verdict(), Verdict::NotReady);
    }

    #[test]
    fn long_text_is_bounded() {
        let mut b = ReadinessBuilder::new();
        b.push(ReadinessItem::new(
            Check::Notation,
            "long",
            Severity::Error,
            Some("p".repeat(10_000)),
            "m".repeat(1_000_000),
        ));
        let r = b.finish();
        let i = &r.items[0];
        assert_eq!(i.message.chars().count(), MAX_MESSAGE_CHARS + 3);
        assert!(i.message.ends_with("..."));
        assert_eq!(
            i.place.as_ref().unwrap().chars().count(),
            MAX_PLACE_CHARS + 3
        );
        assert_eq!(bounded("ééé", 2), "éé...");
        assert_eq!(bounded("short", 10), "short");
    }
}
