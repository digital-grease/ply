import '../models/glossary_term.dart';

/// Parse the weaving-glossary markdown (`docs/GLOSSARY.md`) into a flat term list.
///
/// The doc is the single source of truth; this parser is shared by the codegen
/// (`tool/gen_glossary.dart`) and the drift test, so the generated `glossary_data.g.dart` can never
/// silently fall out of sync with it.
///
/// Recognized shape, one term per top-level bullet:
/// ```
/// - **Term** — definition            (plain)
/// - **Term** (alias) — definition    (an alias between the headword and the dash)
/// ```
/// A line indented under a bullet continues that term's definition (joined with a single space).
/// `###` section headers and the intro paragraph are ignored, and a header also closes the
/// currently-open term.
List<GlossaryTerm> parseGlossary(String markdown) {
  final terms = <GlossaryTerm>[];

  // Accumulator for the term currently being built, so continuation lines can extend it.
  String? term;
  String? aka;
  final def = StringBuffer();

  void flush() {
    if (term != null) {
      terms.add(GlossaryTerm(term: term!, aka: aka, definition: def.toString().trim()));
    }
    term = null;
    aka = null;
    def.clear();
  }

  final bullet = RegExp(r'^-\s+\*\*(.+?)\*\*(.*)$');
  for (final raw in markdown.split('\n')) {
    final trimmed = raw.trim();
    final m = bullet.firstMatch(trimmed);
    if (m != null) {
      flush();
      term = m.group(1)!.trim();
      final rest = m.group(2)!.trim();
      // Split the remainder on the first em-dash (U+2014, the source's headword/definition
      // separator): the left side is an optional alias, the right side starts the definition.
      final dash = rest.indexOf('—');
      if (dash >= 0) {
        aka = _alias(rest.substring(0, dash).trim());
        def.write(rest.substring(dash + 1).trim());
      } else {
        def.write(rest);
      }
    } else if (trimmed.startsWith('#')) {
      flush(); // a section header closes the current term
    } else if (term != null && raw.startsWith(' ') && trimmed.isNotEmpty) {
      // An indented, non-bullet, non-empty line continues the open definition.
      if (def.isNotEmpty) def.write(' ');
      def.write(trimmed);
    }
    // else: a blank line or the intro paragraph (no open term) — ignored.
  }
  flush();
  return terms;
}

/// The text between the headword and the dash, with a single wrapping parenthesis pair stripped
/// (`(filling/pick)` -> `filling/pick`). Empty becomes null.
String? _alias(String s) {
  if (s.startsWith('(') && s.endsWith(')')) {
    s = s.substring(1, s.length - 1).trim();
  }
  return s.isEmpty ? null : s;
}
