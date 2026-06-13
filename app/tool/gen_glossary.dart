// Regenerate `lib/src/data/glossary_data.g.dart` from `docs/GLOSSARY.md` (the single source).
//
// Run from the app/ directory:  dart run tool/gen_glossary.dart
//
// The doc stays the source of truth; the generated const is just a fast, asset-free artifact, and
// test/glossary_test.dart fails if this file drifts from a fresh parse of the doc.
import 'dart:io';

import 'package:ply/src/data/glossary_parser.dart';

void main() {
  final doc = File('../docs/GLOSSARY.md').readAsStringSync();
  final terms = parseGlossary(doc);

  final out = StringBuffer()
    ..writeln('// GENERATED FILE — do not edit by hand.')
    ..writeln('// Source: docs/GLOSSARY.md   Regenerate: dart run tool/gen_glossary.dart')
    ..writeln('//')
    ..writeln('// The glossary doc is the single source of truth; test/glossary_test.dart fails if')
    ..writeln('// this file drifts from it.')
    ..writeln()
    ..writeln("import '../models/glossary_term.dart';")
    ..writeln()
    ..writeln('/// Every weaving-glossary term, parsed from docs/GLOSSARY.md at codegen time.')
    ..writeln('const List<GlossaryTerm> kGlossary = [');
  for (final t in terms) {
    out.writeln('  GlossaryTerm(');
    out.writeln('    term: ${_lit(t.term)},');
    if (t.aka != null) out.writeln('    aka: ${_lit(t.aka!)},');
    out.writeln('    definition: ${_lit(t.definition)},');
    out.writeln('  ),');
  }
  out.writeln('];');

  File('lib/src/data/glossary_data.g.dart').writeAsStringSync(out.toString());
  stdout.writeln('Wrote ${terms.length} glossary terms to lib/src/data/glossary_data.g.dart');
}

/// A safe Dart single-quoted string literal.
String _lit(String s) {
  final escaped = s
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\n', r'\n');
  return "'$escaped'";
}
