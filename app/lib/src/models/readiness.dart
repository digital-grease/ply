// "Ready to make or share" (ADR 0021): the engine's readiness report for one document, as the print
// and share flow reads it. The domain twin of the bridge's `ReadinessDto` (mirrored, not imported,
// so the flow and its tests never touch generated symbols); `ReadinessRepository` maps one to the
// other at the wire.
//
// Saving never reads this. An output that someone will make from or receive asks for it and follows
// its verdict: errors block a ready output (only an explicitly chosen, labelled draft copy is
// made), warnings and unsupported items are acknowledged in one step, information never asks.

/// The severity vocabulary every craft shares, most serious first.
enum ReadinessLevel {
  /// The pattern cannot be worked as written. Blocks a ready output.
  error,

  /// It can be worked, but something is likely to go wrong or is worth checking.
  warning,

  /// Something Ply cannot check or represent, listed with what was not checked.
  unsupported,

  /// Advice or a fact; never asks.
  info,
}

/// Which check a finding came from.
enum ReadinessCheck { draft, loom, plan, chart, sections, notation, stitch, recipe, band }

/// What an output may do.
enum ReadinessVerdict {
  /// Nothing to ask: produce it.
  ready,

  /// Warnings or unsupported items to acknowledge in one step first.
  needsAcknowledgement,

  /// Errors: never produced as ready; only an explicitly chosen, labelled draft copy.
  notReady,
}

/// What a check covered, in words, for "Ply checked the draft and the loom chosen for it".
String readinessCheckWords(ReadinessCheck c) => switch (c) {
      ReadinessCheck.draft => 'the draft',
      ReadinessCheck.loom => 'the loom chosen for it',
      ReadinessCheck.plan => 'the warp and weft plan',
      ReadinessCheck.chart => 'the chart',
      ReadinessCheck.sections => 'the sections',
      ReadinessCheck.notation => 'the notation',
      ReadinessCheck.stitch => 'the stitch',
      ReadinessCheck.recipe => 'the recipe',
      ReadinessCheck.band => 'the band',
    };

/// One finding an output must consider.
class ReadinessItem {
  const ReadinessItem({
    required this.check,
    required this.code,
    required this.level,
    required this.message,
    this.place,
    this.remediation,
    this.omitted = 0,
  });

  final ReadinessCheck check;

  /// The engine's stable code (unique within its check).
  final String code;
  final ReadinessLevel level;

  /// Where it is, in words ("Pick 3, treadle 9"); null for the whole document.
  final String? place;

  /// The finding, a sentence.
  final String message;

  /// What the maker can do, when the engine suggests something.
  final String? remediation;

  /// 0 for a finding. For the item that closes a kind past the engine's cap (200 findings of one
  /// kind are listed), how many findings of that kind it stands for: counted, not listed.
  final int omitted;

  /// How many findings this item stands for.
  int get weight => omitted == 0 ? 1 : omitted;

  /// The place and the finding on one line: "Pick 3, treadle 9: Pick 3 presses treadle 9 ...".
  String get text => place == null ? message : '$place: $message';

  @override
  String toString() => 'ReadinessItem(${check.name}/$code ${level.name}: $text)';
}

/// Everything an output must consider for one document.
class ReadinessReport {
  const ReadinessReport({this.checked = const [], this.items = const []});

  /// The checks that ran, in order.
  final List<ReadinessCheck> checked;

  /// Every finding, most serious first.
  final List<ReadinessItem> items;

  /// The verdict (the engine's rule, ADR 0021): any error is not ready; any warning or unsupported
  /// item needs acknowledging; otherwise ready.
  ReadinessVerdict get verdict {
    if (items.any((i) => i.level == ReadinessLevel.error)) return ReadinessVerdict.notReady;
    if (items
        .any((i) => i.level == ReadinessLevel.warning || i.level == ReadinessLevel.unsupported)) {
      return ReadinessVerdict.needsAcknowledgement;
    }
    return ReadinessVerdict.ready;
  }

  List<ReadinessItem> _at(ReadinessLevel l) => [
        for (final i in items)
          if (i.level == l) i,
      ];

  /// How many findings have [level], the ones counted but not listed included.
  int count(ReadinessLevel level) => [
        for (final i in items)
          if (i.level == level) i.weight,
      ].fold(0, (a, b) => a + b);

  int get errorCount => count(ReadinessLevel.error);

  /// This report with [extra] findings the app adds (what the engine cannot know, such as a loom
  /// that is not in My looms), each placed with its severity, after the engine's of the same level.
  ReadinessReport withItems(List<ReadinessItem> extra, {List<ReadinessCheck> checks = const []}) {
    if (extra.isEmpty && checks.every(checked.contains)) return this;
    return ReadinessReport(
      checked: [
        ...checked,
        for (final c in checks)
          if (!checked.contains(c)) c,
      ],
      items: [
        for (final level in ReadinessLevel.values) ...[
          ...items.where((i) => i.level == level),
          ...extra.where((i) => i.level == level),
        ],
      ],
    );
  }

  List<ReadinessItem> get errors => _at(ReadinessLevel.error);
  List<ReadinessItem> get warnings => _at(ReadinessLevel.warning);
  List<ReadinessItem> get unsupported => _at(ReadinessLevel.unsupported);
  List<ReadinessItem> get info => _at(ReadinessLevel.info);

  /// "the draft and the loom chosen for it", or null when nothing ran.
  String? get checkedWords {
    final words = [for (final c in checked) readinessCheckWords(c)];
    if (words.isEmpty) return null;
    if (words.length == 1) return words.single;
    return '${words.sublist(0, words.length - 1).join(', ')} and ${words.last}';
  }
}
