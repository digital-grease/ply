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

  test('a colon separates the headword when there is no dash; a dash still wins', () {
    final terms = parseGlossary('- **Plain**: one line\n'
        '- **Aliased** (aka): wraps\n'
        '  onto two lines\n'
        '- **Dashed** \u2014 keeps its colon: here\n');
    expect(terms.map((t) => (t.term, t.aka, t.definition)), [
      ('Plain', null, 'one line'),
      ('Aliased', 'aka', 'wraps onto two lines'),
      ('Dashed', null, 'keeps its colon: here'),
    ]);
  });

  test('shadow weave is defined as the authentic block weave', () {
    final shadow = kGlossary.firstWhere((t) => t.term == 'Shadow weave');
    expect(shadow.aka, isNull);
    expect(shadow.definition, startsWith('a block weave'));
    expect(shadow.definition, contains('Atwater and Powell'));
    expect(shadow.definition, contains('log cabin'));
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

  test('the tablet weaving terms are present, findable as card weaving, and keep ADR 0018', () {
    GlossaryTerm byName(String name) => kGlossary.firstWhere((t) => t.term == name);
    const tablet = [
      'Tablet weaving',
      'Card',
      'Hole',
      'Pack',
      'Near top and far top',
      'Home position',
      'Forward and backward turn',
      'S and Z threading',
      'Twining',
      'Twist',
      'Twist release',
      'Reversal',
      'Idle',
      'Flip',
      'Float (tablet weaving)',
    ];
    for (final name in tablet) {
      expect(kGlossary.where((t) => t.term == name), hasLength(1), reason: '$name appears once');
    }
    // The shaft-weaving Float keeps its headword, so lookups by "Float" are unchanged.
    expect(byName('Float').definition, contains('satin'));

    // Mirrors the screen filter: case-insensitive over term + aka + definition.
    bool matches(GlossaryTerm t, String q) =>
        t.term.toLowerCase().contains(q) ||
        (t.aka?.toLowerCase().contains(q) ?? false) ||
        t.definition.toLowerCase().contains(q);
    final hits = kGlossary.where((t) => matches(t, 'card weaving')).map((t) => t.term);
    expect(hits, containsAll(['Tablet weaving', 'Card']));
    expect(byName('Tablet weaving').aka, 'card weaving');
    expect(byName('Card').aka, 'tablet');

    // The conventions that must not drift.
    expect(
      byName('Home position').definition,
      contains('A at the near top, D at the far top, C at the far bottom and B at the near bottom'),
    );
    expect(byName('Card').definition, contains("side view from the weaver's right"));
    expect(
      byName('Forward and backward turn').definition,
      contains('top edge moves away from the weaver'),
    );
    expect(byName('Flip').definition, contains('from S to Z'));
    expect(byName('Tablet weaving').definition, contains('pick 1 at the bottom'));
    expect(byName('Tablet weaving').definition, contains('does not read or write WIF'));
    for (final name in ['Twist', 'Reversal', 'Float (tablet weaving)']) {
      expect(byName(name).definition, contains("await a tablet weaver's review"), reason: name);
    }
    // The S and Z diagram is a code block in the doc only; the parser leaves it out of the text.
    final sz = byName('S and Z threading').definition;
    expect(sz, endsWith('so a flip changes S to Z and Z to S.'));
    expect(sz, isNot(contains('+---')));
  });
}
