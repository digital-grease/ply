// The glossary is generated from docs/GLOSSARY.md (the single source). These tests pin that:
//   1. DRIFT GUARD: the committed const (kGlossary) equals a fresh parse of the doc, so editing the
//      doc without regenerating (`dart run tool/gen_glossary.dart`) fails CI rather than shipping a
//      stale in-app glossary.
//   2. The parser handles the source's real shapes (aliases, multi-line continuations, escapes).
//
// Host-only: reads the doc off disk relative to the app/ working dir and exercises pure Dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/glossary_data.g.dart';
import 'package:ply/src/data/glossary_parser.dart';
import 'package:ply/src/models/glossary_term.dart';

void main() {
  test('kGlossary is in sync with docs/GLOSSARY.md (regenerate if this fails)', () {
    final doc = File('../docs/GLOSSARY.md').readAsStringSync();
    final fresh = parseGlossary(doc);
    expect(kGlossary, equals(fresh),
        reason: 'docs/GLOSSARY.md changed without regenerating glossary_data.g.dart — '
            'run `dart run tool/gen_glossary.dart`');
  });

  test('the parse covers the doc and carries definitions', () {
    expect(kGlossary.length, greaterThanOrEqualTo(20), reason: 'the full term set is present');
    // Every entry has a non-empty headword and definition.
    for (final t in kGlossary) {
      expect(t.term.trim(), isNotEmpty);
      expect(t.definition.trim(), isNotEmpty, reason: '${t.term} has a definition');
    }
  });

  test('aliases and multi-line continuations parse correctly', () {
    GlossaryTerm byName(String name) => kGlossary.firstWhere((t) => t.term == name);

    // Alias from `**Weft** (filling/pick) — ...`.
    expect(byName('Weft').aka, 'filling/pick');
    // A multi-line definition is joined into one (the Shaft entry wraps across two source lines).
    final shaft = byName('Shaft');
    expect(shaft.aka, 'harness');
    expect(shaft.definition, contains('More shafts'));
    expect(shaft.definition, contains('Numbered from 1.'),
        reason: 'the continuation line is appended');
    // A headword with a slash stays intact.
    expect(kGlossary.any((t) => t.term == 'Rising shed / sinking shed'), isTrue);
  });

  test('definition-text is searchable (a sett query finds EPI in the body, not just headwords)', () {
    // Mirrors the screen filter: case-insensitive over term + aka + definition.
    bool matches(GlossaryTerm t, String q) =>
        t.term.toLowerCase().contains(q) ||
        (t.aka?.toLowerCase().contains(q) ?? false) ||
        t.definition.toLowerCase().contains(q);

    final epiHits = kGlossary.where((t) => matches(t, 'epi')).map((t) => t.term);
    expect(epiHits, contains('Sett'), reason: 'EPI lives in Sett\'s definition body');
  });
}
