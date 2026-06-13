import 'glossary_data.g.dart';

/// The definition for a glossary headword (exact match, case-insensitive), or null if the term
/// is not in the glossary. Lets the editor's concept tooltips draw their help text from the same
/// `docs/GLOSSARY.md` source as the Glossary screen (one source, no hand-copied strings).
String? glossaryDefinition(String term) {
  final q = term.toLowerCase();
  for (final t in kGlossary) {
    if (t.term.toLowerCase() == q) return t.definition;
  }
  return null;
}
