/// One weaving-glossary entry, generated from `docs/GLOSSARY.md` (the single source of truth).
///
/// Immutable and value-equal so the generated `glossary_data.g.dart` const list can be diffed
/// against a fresh parse of the doc — that diff is the drift guard in `test/glossary_test.dart`.
class GlossaryTerm {
  const GlossaryTerm({required this.term, this.aka, required this.definition});

  /// The headword (the bold text in the source bullet), e.g. `Warp`, `Rising shed / sinking shed`.
  final String term;

  /// An alternate name the source carries between the headword and the dash (e.g. Weft's
  /// `filling/pick`), with any wrapping parentheses stripped. Null when the entry has none.
  final String? aka;

  /// The plain-text definition (continuation lines in the source are joined with a space).
  final String definition;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GlossaryTerm &&
          runtimeType == other.runtimeType &&
          term == other.term &&
          aka == other.aka &&
          definition == other.definition;

  @override
  int get hashCode => Object.hash(term, aka, definition);

  @override
  String toString() => 'GlossaryTerm($term)';
}
