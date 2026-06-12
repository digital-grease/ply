// A structural validation problem, surfaced to the editor's inline gutter.
//
// This is the domain twin of the bridge's `ValidationIssueDto` (mirrored, NOT imported, so the
// UI/state layers never touch generated symbols, the same isolation DraftDoc keeps). The
// repository maps `ValidationIssueDto` -> [DraftIssue] at the wire boundary. The point of
// carrying a real [IssueSeverity] enum (rather than M1's flattened "Error: ..." string) is so
// the editor can color Errors red vs Warnings amber and gate Save on Errors.

/// Severity of a [DraftIssue]. Domain twin of the wire `SeverityKind`.
enum IssueSeverity { error, warning }

/// One validation problem: a [severity] and a human-readable [message].
class DraftIssue {
  const DraftIssue({required this.severity, required this.message});

  /// Error gates Save; Warning is advisory.
  final IssueSeverity severity;

  /// Human-readable description, already formatted by the engine validator.
  final String message;

  /// True when this issue blocks a clean save.
  bool get isError => severity == IssueSeverity.error;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DraftIssue &&
          runtimeType == other.runtimeType &&
          severity == other.severity &&
          message == other.message;

  @override
  int get hashCode => Object.hash(severity, message);

  @override
  String toString() => 'DraftIssue(${severity.name}: $message)';
}
