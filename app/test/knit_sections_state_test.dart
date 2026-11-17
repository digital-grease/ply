import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/knit_sections.dart';
import 'package:ply/src/models/knit_stitches.dart';
import 'package:ply/src/rust/dto.dart' show ColorDto, UnitKind;
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/state/knit_editor_state.dart';

import 'knit_sections_test_support.dart';

// The sections editor's pure state: adding, renaming, annotating, deleting and reordering sections
// and steps (one undo entry each, no-ops for no change), stable ids that never clash, every other
// edit keeping the sections, and the model helpers the screen uses. No FFI.

KnitPatternDto _pattern({List<KnitSectionDto> sections = const []}) => KnitPatternDto(
      name: 'p',
      construction: ConstructionKind.flat,
      firstRowSide: SideKind.rs,
      castOn: 4,
      gauge: const GaugeDto(sts: 20, rows: 28, unit: UnitKind.inches),
      palette: const [ColorDto(r: 255, g: 255, b: 255)],
      legend: const StitchLegendDto(stitches: []),
      chart: ChartDto(width: 4, rows: [
        for (var r = 0; r < 3; r++)
          RowDto(
            cells: List.generate(4, (_) => const CellDto(stitch: KnitStitch.knit)),
            repeats: const [],
          ),
      ]),
      notes: '',
      sections: sections,
      pieces: const [],
    );

const _knitToEnd =
    KnitStepActionDto.work(stitch: WorkStitchKind.knit, to: WorkToDto.end(), resolveTurns: false);

void main() {
  group('sections', () {
    test('adding sections gives each a new id and an undo entry', () {
      var s = KnitEditorState(pattern: _pattern());
      s = s.addSection('  Back ').addSection('Front');
      expect([for (final x in s.pattern.sections) (x.id, x.name)],
          [('section-1', 'Back'), ('section-2', 'Front')]);
      expect(s.undo, hasLength(2));
      s = s.removeSection('section-1').addSection('Sleeve');
      expect(s.pattern.sections.last.id, 'section-3', reason: 'a freed id is not reused');
      expect(s.undoEdit().pattern.sections.map((x) => x.name), ['Front']);
    });

    test('rename, notes, move and delete; no change is a no-op', () {
      var s = KnitEditorState(pattern: _pattern()).addSection('A').addSection('B').addSection('C');
      final before = s;
      expect(identical(s.renameSection('section-1', 'A'), before), isTrue);
      expect(identical(s.renameSection('nope', 'X'), before), isTrue);
      expect(identical(s.moveSection('section-1', -1), before), isTrue, reason: 'already first');
      s = s.renameSection('section-1', ' Yoke ').setSectionNotes('section-2', 'Use 4 mm.');
      expect(s.pattern.sections[0].name, 'Yoke');
      expect(s.pattern.sections[1].notes, 'Use 4 mm.');
      s = s.moveSection('section-1', 5);
      expect(s.pattern.sections.map((x) => x.id), ['section-2', 'section-3', 'section-1']);
      s = s.moveSection('section-1', -1);
      expect(s.pattern.sections.map((x) => x.id), ['section-2', 'section-1', 'section-3']);
      s = s.removeSection('section-2');
      expect(s.pattern.sections.map((x) => x.name), ['Yoke', 'C']);
      expect(identical(s.removeSection('section-2'), s), isTrue);
    });

    test('steps: add (with ids unique across sections), replace, move, remove', () {
      var s = KnitEditorState(pattern: _pattern()).addSection('A').addSection('B');
      s = s
          .addStep('section-1', const KnitStepActionDto.castOn(count: 4))
          .addStep('section-2', _knitToEnd)
          .addStep('section-1', const KnitStepActionDto.hold(name: 'x'), index: 0);
      expect([for (final st in s.pattern.sections[0].steps) st.id], ['step-3', 'step-1']);
      expect(s.pattern.sections[1].steps.single.id, 'step-2');
      expect(identical(s.addStep('nope', _knitToEnd), s), isTrue);

      final replaced = s.replaceStep('step-1', const KnitStepActionDto.castOn(count: 9));
      expect(replaced.pattern.sections[0].steps[1],
          const KnitStepDto(id: 'step-1', action: KnitStepActionDto.castOn(count: 9)),
          reason: 'the id is kept, so a return step still finds its hold');
      expect(
          identical(
              replaced.replaceStep('step-1', const KnitStepActionDto.castOn(count: 9)), replaced),
          isTrue);

      s = replaced.moveStep('step-3', 1);
      expect([for (final st in s.pattern.sections[0].steps) st.id], ['step-1', 'step-3']);
      expect(identical(s.moveStep('step-3', 1), s), isTrue, reason: 'already last');
      s = s.removeStep('step-1');
      expect([for (final st in s.pattern.sections[0].steps) st.id], ['step-3']);
      expect(identical(s.removeStep('step-1'), s), isTrue);
      expect(s.undo.length, 8, reason: 'one undo entry per real edit (2 sections, 6 step edits)');
    });

    test('every other edit keeps the sections', () {
      final sections = [
        const KnitSectionDto(id: 'section-1', name: 'A', notes: '', steps: [
          KnitStepDto(id: 'step-1', action: _knitToEnd),
        ]),
      ];
      final start = KnitEditorState(pattern: _pattern(sections: sections));
      for (final edited in [
        start.paintCell(0, 0, KnitStitch.purl, null),
        start.fillRegion(0, 0, 1, 1, KnitStitch.purl, null),
        start.resizeChart(6, 2),
        start.setGauge(const GaugeDto(sts: 10, rows: 12, unit: UnitKind.centimeters)),
        start.setConstruction(ConstructionKind.inTheRound),
        start.setFirstRowSide(SideKind.ws),
        start.setNotes('n'),
        start.setCastOn(8),
        start.setCastOn(null),
        start.addPaletteColor(const ColorDto(r: 1, g: 2, b: 3)),
        start.markRepeat(0, 0, 0, 1, const RepeatDto.times(count: 2)),
      ]) {
        expect(edited.pattern, isNot(same(start.pattern)), reason: 'the edit changed something');
        expect(edited.pattern.sections, same(sections));
      }
    });
  });

  group('repeated ids from a hand-edited file', () {
    const a = KnitStepDto(id: 'dup', action: KnitStepActionDto.castOn(count: 1));
    const b = KnitStepDto(id: 'dup', action: KnitStepActionDto.castOn(count: 2));
    final p = _pattern(sections: const [
      KnitSectionDto(id: 'x', name: 'A', notes: '', steps: [a]),
      KnitSectionDto(id: 'x', name: 'B', notes: '', steps: [b]),
    ]);

    test('edits by position change exactly the chosen section or step', () {
      final s = KnitEditorState(pattern: p);
      final replaced = s.replaceStepAt(1, 0, const KnitStepActionDto.castOn(count: 9));
      expect([
        for (final x in replaced.pattern.sections) x.steps.single.action
      ], [
        a.action,
        const KnitStepActionDto.castOn(count: 9),
      ]);
      final removed = s.removeStepAt(1, 0);
      expect([for (final x in removed.pattern.sections) x.steps.length], [1, 0]);
      expect(removed.undo, hasLength(1));
      expect([for (final x in s.removeSectionAt(1).pattern.sections) x.name], ['A']);
      expect(s.renameSectionAt(1, 'C').pattern.sections.map((x) => x.name), ['A', 'C']);
      expect(identical(s.removeStepAt(1, 3), s), isTrue, reason: 'out of range: no-op, no undo');
    });

    test('the id-based forms act on the first match only', () {
      final s = KnitEditorState(pattern: p);
      expect([for (final x in s.removeSection('x').pattern.sections) x.name], ['B']);
      expect([for (final x in s.removeStep('dup').pattern.sections) x.steps.length], [0, 1]);
    });
  });

  group('model helpers', () {
    test('ids continue past the largest one in use, ignoring other shapes', () {
      final p = _pattern(sections: const [
        KnitSectionDto(id: 'section-4', name: '', notes: '', steps: [
          KnitStepDto(id: 'step-9', action: _knitToEnd),
          KnitStepDto(id: 'custom', action: _knitToEnd),
        ]),
        KnitSectionDto(id: 'odd', name: '', notes: '', steps: []),
      ]);
      expect(nextSectionId(p), 'section-5');
      expect(nextStepId(p), 'step-10');
      expect(nextStepId(_pattern()), 'step-1');
    });

    test('an id a return step still names is never given to a new step', () {
      // Hold step-3, return it from step-2, then delete the hold: a new hold must not become step-3
      // (the orphaned return would silently return the new group).
      var s = KnitEditorState(pattern: _pattern()).addSection('A');
      s = s
          .addStep('section-1', _knitToEnd)
          .addStep('section-1', _knitToEnd)
          .addStep('section-1', const KnitStepActionDto.hold(count: 2, name: 'g'));
      s = s.replaceStep('step-2', const KnitStepActionDto.resume(hold: 'step-3'));
      s = s.removeStep('step-3');
      expect(nextStepId(s.pattern), 'step-4');
      s = s.addStep('section-1', const KnitStepActionDto.hold(count: 2, name: 'new'));
      expect(s.pattern.sections.single.steps.last.id, 'step-4');
    });

    test('hold steps are listed for a return step, named by section and position', () {
      final p = _pattern(sections: const [
        KnitSectionDto(id: 's1', name: 'Front', notes: '', steps: [
          KnitStepDto(id: 'a', action: _knitToEnd),
          KnitStepDto(id: 'b', action: KnitStepActionDto.hold(count: 12, name: 'center neck')),
        ]),
        KnitSectionDto(id: 's2', name: '', notes: '', steps: [
          KnitStepDto(id: 'c', action: KnitStepActionDto.hold(name: ' ')),
        ]),
      ]);
      final holds = knitHoldSteps(p);
      expect([for (final h in holds) h.stepId], ['b', 'c']);
      expect(holds[0].label, 'center neck (Front, step 2)');
      expect(holds[1].label, 'Unnamed group (Section 2, step 1)');
      expect(
          defaultKnitStepAction(KnitStepKind.resume, p), const KnitStepActionDto.resume(hold: 'c'),
          reason: 'a new return step starts on the latest group');
    });

    test('every action maps to its kind, and new steps start with no stated stitch change', () {
      final p = _pattern();
      for (final kind in KnitStepKind.values) {
        expect(knitStepKind(defaultKnitStepAction(kind, p)), kind);
      }
      expect(defaultKnitStepAction(KnitStepKind.unchecked, p),
          const KnitStepActionDto.opaque(text: ''),
          reason: 'Ply never assumes an unchecked step changes nothing');
      expect(defaultKnitStepAction(KnitStepKind.chartRows, p),
          const KnitStepActionDto.chartRows(first: 1, last: 3));
    });

    test('section headings are recognized, and nothing else is', () {
      expect(isKnitSectionHeading('Section 1: Back'), isTrue);
      expect(isKnitSectionHeading('Section 12'), isTrue);
      for (final line in [
        'Row 1 (RS): k24',
        'Cast on 24 sts.',
        'Notes: Section 1: Back',
        'Next row (RS): knit to end. (24 sts on the needle)',
        'Section one',
      ]) {
        expect(isKnitSectionHeading(line), isFalse, reason: line);
      }
    });
  });

  group('the shared fixtures', () {
    test('every section fixture decodes into the DTOs with every step kind it uses', () {
      final kinds = <KnitStepKind>{};
      for (final name in kSectionFixtures) {
        final p = patternFromPlyknit(sectionFixtureText(name, 'plyknit'));
        expect(p.sections, isNotEmpty, reason: name);
        final ids = [
          for (final s in p.sections)
            for (final st in s.steps) st.id
        ];
        expect(ids.toSet(), hasLength(ids.length), reason: '$name: step ids are unique');
        for (final s in p.sections) {
          for (final st in s.steps) {
            kinds.add(knitStepKind(st.action));
          }
        }
        // New ids added in the editor never clash with the fixture's.
        final edited = KnitEditorState(pattern: p).addStep(p.sections.first.id, _knitToEnd);
        expect(ids, isNot(contains(edited.pattern.sections.first.steps.last.id)));
      }
      expect(
          kinds,
          containsAll([
            KnitStepKind.chartRows,
            KnitStepKind.work,
            KnitStepKind.shortRow,
            KnitStepKind.bindOff,
            KnitStepKind.hold,
            KnitStepKind.resume,
            KnitStepKind.unchecked,
          ]));
    });

    test('a return step in a fixture names a hold step of the same pattern', () {
      final p = patternFromPlyknit(sectionFixtureText('neckline-hold-flat', 'plyknit'));
      final holds = {for (final h in knitHoldSteps(p)) h.stepId: h};
      final returns = [
        for (final s in p.sections)
          for (final st in s.steps)
            if (st.action case KnitStepActionDto_Resume(:final hold, :final facing)) (hold, facing),
      ];
      expect(returns, [('step-4', SideKind.rs), ('step-3', SideKind.rs)]);
      expect(holds['step-4']!.label, 'right side (Divide for the neck, step 3)');
      expect(holds['step-3']!.label, 'center neck (Divide for the neck, step 2)');
    });
  });
}
