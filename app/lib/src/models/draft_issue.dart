// A structural validation problem, surfaced to the editor's inline gutter.
//
// This is the domain twin of the bridge's `ValidationIssueDto` (mirrored, NOT imported, so the
// UI/state layers never touch generated symbols, the same isolation DraftDoc keeps). The
// repository maps `ValidationIssueDto` -> [DraftIssue] at the wire boundary. The point of
// carrying a real [IssueSeverity] enum (rather than M1's flattened "Error: ..." string) is so
// the editor can color Errors red vs Warnings amber and gate Save on Errors. Each issue also
// carries the engine's stable code, its place in words and a typed [DraftPlace] the editor can go
// to (ADR 0021).

/// Severity of a [DraftIssue]: the shared vocabulary (ADR 0021), domain twin of the wire
/// `SeverityKind`. [info] is advice about a deliberate instruction (for example how to catch the
/// weft on a double shot), not a problem; weaving validation never reports [unsupported].
enum IssueSeverity { error, warning, unsupported, info }

/// What a [DraftPlace] names.
enum DraftPlaceKind {
  threading,
  tieUp,
  treadling,
  liftPlan,
  warpColor,
  weftColor,
  pick,
  picks,
  pickList,
  pickRanges,
  shaft,
  shuttle,
}

/// Where a weaving finding is, in the weaver's 1-based numbers (end 1, pick 1, shaft 1, treadle 1):
/// the cell, or the first of the picks it names. [color] is the 0-based palette index named.
class DraftPlace {
  const DraftPlace({
    required this.kind,
    this.end,
    this.pick,
    this.lastPick,
    this.shaft,
    this.treadle,
    this.color,
    this.shuttle,
  });

  final DraftPlaceKind kind;
  final int? end;
  final int? pick;

  /// The last pick of the first range named (equal to [pick] for one pick).
  final int? lastPick;
  final int? shaft;
  final int? treadle;
  final int? color;
  final int? shuttle;

  @override
  bool operator ==(Object other) =>
      other is DraftPlace &&
      other.kind == kind &&
      other.end == end &&
      other.pick == pick &&
      other.lastPick == lastPick &&
      other.shaft == shaft &&
      other.treadle == treadle &&
      other.color == color &&
      other.shuttle == shuttle;

  @override
  int get hashCode => Object.hash(kind, end, pick, lastPick, shaft, treadle, color, shuttle);

  @override
  String toString() => 'DraftPlace(${kind.name}, end $end, pick $pick-$lastPick, shaft $shaft, '
      'treadle $treadle)';
}

/// One validation problem: a [severity] and a human-readable [message], with the engine's stable
/// [code], its [place] in words and its [location].
class DraftIssue {
  const DraftIssue({
    required this.severity,
    required this.message,
    this.code = '',
    this.place,
    this.location,
  });

  /// Error gates Save; Warning is advisory; Info is advice.
  final IssueSeverity severity;

  /// Human-readable description, already formatted by the engine validator.
  final String message;

  /// The engine's stable code (`weave.treadle_untied`); empty when not known.
  final String code;

  /// Where it is, in words ("Pick 3, treadle 9"); null for the whole draft.
  final String? place;

  /// Where it is, for the editor to show it; null for the whole draft.
  final DraftPlace? location;

  /// True when this issue blocks a clean save.
  bool get isError => severity == IssueSeverity.error;

  /// True when this is advice rather than a problem.
  bool get isInfo => severity == IssueSeverity.info;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DraftIssue &&
          runtimeType == other.runtimeType &&
          severity == other.severity &&
          message == other.message &&
          code == other.code &&
          place == other.place &&
          location == other.location;

  @override
  int get hashCode => Object.hash(severity, message, code, place, location);

  @override
  String toString() => 'DraftIssue(${severity.name}: $message)';
}
