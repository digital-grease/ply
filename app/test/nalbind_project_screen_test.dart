import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/native_format.dart';
import 'package:ply/src/rust/nalbind_dto.dart';
import 'package:ply/src/screens/nalbind_project_screen.dart';
import 'package:ply/src/state/nalbind_providers.dart';
import 'package:ply/src/widgets/nalbind_diagram_view.dart';

import 'nalbind_test_support.dart';

// Host coverage for the nalbind PROJECT screen's dirty-on-exit guard: a back with unsaved form edits
// prompts Save / Discard / Keep editing, a clean form pops straight through, Save runs the normal
// save flow and leaves only on success, and the in-flight-save races behave. Also the AUTHORING
// notation field: read in strict mode, every problem listed under the field, an inexact reading's
// diagram labelled approximate, and saving still allowed with problems. A fake repo stubs the
// stitch FFI and the persistence calls (no disk, no FFI).

const _oslo = NalbindStitchDto(
  name: 'Oslo',
  passes: [
    PassDto(steps: [StepKind.under, StepKind.over]),
    PassDto(steps: [StepKind.under, StepKind.over, StepKind.over]),
  ],
  connections: [ConnectionDto(side: ConnSideKind.front, count: 1)],
  thumbLoops: ThumbLoopsDto(a: 1, b: 1),
  twist: TwistKind.untwisted,
  alsoKnownAs: ['Finnish 1+1'],
  codes: [PublishedCodeDto(code: 'UO/UOO F1', source: 'neulakintaat.fi')],
  note: 'The classic beginner stitch.',
);

final _diagram = DiagramDto(
  width: 6,
  height: 2.6,
  baseline: 1.6,
  loops: const [
    LoopGlyphDto(x: 0.5, kind: LoopKindDto.underEngaged),
    LoopGlyphDto(x: 1.5, kind: LoopKindDto.overEngaged),
  ],
  turns: Float32List.fromList([2.0]),
  connections: const [ConnArrowDto(x: 6, side: ConnSideKind.front, count: 1)],
);

/// The best-effort structure of `UO/XYZ` (just `UO`).
const _uo = NalbindStitchDto(
  name: '',
  passes: [
    PassDto(steps: [StepKind.under, StepKind.over]),
  ],
  connections: [],
  twist: TwistKind.untwisted,
  alsoKnownAs: [],
  codes: [],
  note: '',
);

const _caption = "Sketch of one stitch's needle path, not a picture of finished fabric.";
const _approximate = 'Approximate: the notation was not read exactly, so this sketch may be wrong.';
const _saveHint = 'You can save with these problems and fix them later.';

const _stored = NalbindProject(
  name: 'Mittens',
  notation: 'UO/UOO F1',
  stitchName: 'Oslo',
  notes: 'thumb gusset at round 6',
);

class FakeProjectRepo extends NalbindRepository {
  int saveCount = 0;
  NalbindProject? saved;
  String? savedId;
  int listCount = 0;

  /// When set, saveProject suspends on this until completed (holds one save in flight).
  Completer<void>? saveGate;

  /// When true, saveProject throws (a failed write).
  bool saveError = false;

  @override
  Future<List<NalbindStitchDto>> builtins() async => [_oslo];

  @override
  Future<DiagramDto> diagram(NalbindStitchDto dto) async => _diagram;

  /// The `strict` flag of every analyze call, in order.
  final modes = <bool>[];

  @override
  Future<ParsedNotationDto> analyze(String notation, {required bool strict}) async {
    modes.add(strict);
    return notation == 'UO/XYZ'
        ? badReading(_uo, strict: strict)
        : reading(notation, _oslo, strict: strict);
  }

  @override
  Future<List<NalbindIssueDto>> validate(NalbindStitchDto dto) async => const [];

  /// When set, the NEXT saveProject throws it (the repository refusing to replace the file on disk).
  NativeFormatException? refuseNextSave;

  @override
  Future<String> saveProject(NalbindProject project, {String? id}) async {
    saveCount++;
    if (saveGate != null) await saveGate!.future;
    if (saveError) throw Exception('disk full');
    final refusal = refuseNextSave;
    if (refusal != null) {
      refuseNextSave = null;
      throw refusal;
    }
    saved = project;
    savedId = id;
    return id ?? 'new-id';
  }

  /// When true, readProject throws (a project file that cannot be read or parsed).
  bool readError = false;

  /// When set, readProject throws it instead (a typed format problem).
  Object? readFailure;

  /// What readProject returns.
  NalbindProject stored = _stored;

  @override
  Future<NalbindProject> readProject(String id) async {
    if (readError) throw const FormatException('corrupt project');
    final failure = readFailure;
    if (failure != null) throw failure;
    return stored;
  }

  @override
  Future<void> touchOpened(String id) async {}

  @override
  Future<List<NalbindProjectEntry>> listProjects() async {
    listCount++;
    return const [];
  }
}

/// Pumps a host that PUSHES the project screen (so a back has somewhere to go), mirroring the
/// Nalbinding tab's `push<void>`. [openId] opens the stored project; null starts a new one.
Future<ProviderContainer> pumpProject(WidgetTester tester, FakeProjectRepo repo,
    {String? openId}) async {
  final c = ProviderContainer(overrides: [nalbindRepositoryProvider.overrideWithValue(repo)]);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => NalbindProjectScreen(openId: openId)),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byType(NalbindProjectScreen), findsOneWidget);
  return c;
}

Finder get _nameField => find.widgetWithText(TextField, 'Project name');
Finder get _notationField => find.widgetWithText(TextField, 'Hansen notation');

final _xyzError = shownFinding(
    'Error', 'XYZ', 'unexpected characters `XYZ`; kept verbatim as an opaque token');
final _turnError =
    shownFinding('Error', '/', 'turn `/` comes after the last needle step; dropped');

Future<void> tapBack(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
}

const _leaveTitle = 'Leave without saving?';

void main() {
  testWidgets('a project that fails to open is never overwritten by the empty form', (tester) async {
    final repo = FakeProjectRepo()..readError = true;
    await pumpProject(tester, repo, openId: 'p1');
    expect(find.textContaining('Could not open the project'), findsOneWidget);
    expect(find.textContaining('leave the original file untouched'), findsOneWidget);

    await tester.enterText(_nameField, 'Rescued notes');
    await tester.pump();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1);
    expect(repo.savedId, isNull, reason: 'saved as a NEW project, not over the unreadable p1');
    expect(repo.saved?.name, 'Rescued notes');
  });

  testWidgets('a project saved by a newer Ply says so, and Save never writes over it', (tester) async {
    final repo = FakeProjectRepo()
      ..readFailure = const NativeFormatException(NativeFormatProblem.newerVersion,
          document: NativeDocument.nalbindProject);
    await pumpProject(tester, repo, openId: 'p1');
    expect(
        find.textContaining('This project was saved by a newer version of Ply. Update the app to '
            'open it. Saving will create a new project and leave the original file untouched.'),
        findsOneWidget);

    await tester.enterText(_nameField, 'Notes from memory');
    await tester.pump();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1);
    expect(repo.savedId, isNull, reason: 'a NEW project, never over the newer p1');
  });

  testWidgets('a save the repository refuses forgets the file; the next save makes a new project',
      (tester) async {
    final repo = FakeProjectRepo()
      ..refuseNextSave = const NativeFormatException(NativeFormatProblem.newerVersion,
          document: NativeDocument.nalbindProject, whileSaving: true);
    await pumpProject(tester, repo, openId: 'p1');
    await tester.enterText(_nameField, 'Mittens v2');
    await tester.pump();

    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1);
    expect(find.textContaining('from a newer version of Ply, so it was not replaced'),
        findsOneWidget);
    expect(find.textContaining('Save again to keep your changes as a new project'), findsOneWidget);

    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 2);
    expect(repo.savedId, isNull, reason: 'saved as a NEW project');
    expect(repo.saved?.name, 'Mittens v2');
  });

  testWidgets('a fresh, untouched project pops straight back with no prompt', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsNothing);
    expect(find.byType(NalbindProjectScreen), findsNothing);
    expect(repo.saveCount, 0);
  });

  testWidgets('an opened project left untouched pops with no prompt', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo, openId: 'p1');
    expect(find.text('Mittens'), findsOneWidget, reason: 'the stored project loaded');
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsNothing);
    expect(find.byType(NalbindProjectScreen), findsNothing);
  });

  testWidgets('an edit reverted by hand reads clean (value comparison)', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo, openId: 'p1');
    await tester.enterText(_nameField, 'Mittens, v2');
    await tester.pump();
    await tester.enterText(_nameField, 'Mittens ');
    await tester.pump(); // a trailing space the save would trim away is not an unsaved change
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsNothing);
    expect(find.byType(NalbindProjectScreen), findsNothing);
  });

  testWidgets('back with edits prompts; Keep editing stays with the edit intact', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.enterText(_nameField, 'Socks');
    await tester.pump();
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsOneWidget);
    expect(find.textContaining("this project haven't been saved"), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Keep editing'));
    await tester.pumpAndSettle();
    expect(find.byType(NalbindProjectScreen), findsOneWidget, reason: 'still editing');
    expect(find.text('Socks'), findsOneWidget);
    expect(repo.saveCount, 0);
  });

  testWidgets('picking a stitch chip counts as an unsaved change', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.tap(find.widgetWithText(ActionChip, 'Oslo'));
    await tester.pumpAndSettle();
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsOneWidget);
  });

  testWidgets('Discard leaves without saving', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo, openId: 'p1');
    await tester.enterText(find.byType(TextField).last, 'new notes');
    await tester.pump();
    await tapBack(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(NalbindProjectScreen), findsNothing, reason: 'discard exits');
    expect(find.text('open'), findsOneWidget, reason: 'exactly one pop: the host survives');
    expect(repo.saveCount, 0, reason: 'nothing persisted on discard');
  });

  testWidgets('Save from the prompt saves the form, then leaves', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.enterText(_nameField, '  Socks  ');
    await tester.pump();
    await tapBack(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1);
    expect(repo.saved, const NalbindProject(name: 'Socks'), reason: 'the normal save flow (trimmed)');
    expect(repo.savedId, isNull, reason: 'a never-saved project gets a new id');
    expect(find.byType(NalbindProjectScreen), findsNothing, reason: 'a successful save exits');
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('Save from the prompt on an opened project overwrites it, then leaves', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo, openId: 'p1');
    await tester.enterText(_nameField, 'Mittens, v2');
    await tester.pump();
    await tapBack(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(repo.savedId, 'p1');
    expect(repo.saved, _stored.copyWith(name: 'Mittens, v2'));
    expect(find.byType(NalbindProjectScreen), findsNothing);
  });

  testWidgets('a failed save stays on screen, keeps the edits, and still guards the back',
      (tester) async {
    final repo = FakeProjectRepo()..saveError = true;
    await pumpProject(tester, repo);
    await tester.enterText(_nameField, 'Socks');
    await tester.pump();
    await tapBack(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1);
    expect(find.byType(NalbindProjectScreen), findsOneWidget, reason: 'a failed save never leaves');
    expect(find.textContaining('Could not save'), findsOneWidget);
    expect(find.text('Socks'), findsOneWidget);

    await tapBack(tester);
    expect(find.text(_leaveTitle), findsOneWidget, reason: 'still unsaved, so still guarded');
  });

  testWidgets('an AppBar Save makes the form clean; a later edit guards again', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.enterText(_nameField, 'Socks');
    await tester.pump();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1);
    expect(find.byType(NalbindProjectScreen), findsOneWidget, reason: 'the project saves in place');

    await tester.enterText(_nameField, 'Socks, v2');
    await tester.pump();
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Keep editing'));
    await tester.pumpAndSettle();

    await tester.enterText(_nameField, 'Socks'); // back to what was saved
    await tester.pump();
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsNothing);
    expect(find.byType(NalbindProjectScreen), findsNothing);
  });

  testWidgets('AppBar Save in flight + back -> Discard pops once; a save landing after the screen '
      'is gone still refreshes the list', (tester) async {
    final repo = FakeProjectRepo();
    final c = await pumpProject(tester, repo);
    await c.read(nalbindProjectsProvider.future); // the library list, built once
    expect(repo.listCount, 1);
    await tester.enterText(_nameField, 'Socks');
    await tester.pump();

    repo.saveGate = Completer<void>(); // park the write
    await tester.tap(find.byTooltip('Save'));
    await tester.pump();
    expect(repo.saveCount, 1);

    await tapBack(tester);
    expect(find.text(_leaveTitle), findsOneWidget, reason: 'a back mid-save still offers the choice');
    await tester.tap(find.widgetWithText(TextButton, 'Discard'));
    await tester.pumpAndSettle(); // the screen is fully gone (disposed) ...
    expect(find.byType(NalbindProjectScreen), findsNothing, reason: 'discarded');
    repo.saveGate!.complete(); // ... before the parked save resumes
    await tester.pumpAndSettle();

    expect(find.text('open'), findsOneWidget, reason: 'the host route survives (no second pop)');
    expect(repo.saveCount, 1, reason: 'the save the user had already started is not repeated');
    expect(tester.takeException(), isNull);
    // The save that finished after the screen closed still invalidated the library list.
    await c.read(nalbindProjectsProvider.future);
    expect(repo.listCount, 2);
  });

  testWidgets('AppBar Save in flight + back -> Save joins that save (one write), then leaves',
      (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.enterText(_nameField, 'Socks');
    await tester.pump();

    repo.saveGate = Completer<void>();
    await tester.tap(find.byTooltip('Save'));
    await tester.pump();
    await tapBack(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.byType(NalbindProjectScreen), findsOneWidget, reason: 'waits for the save to land');

    repo.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1, reason: 'joined the in-flight save, no second write');
    expect(find.byType(NalbindProjectScreen), findsNothing, reason: 'left once the save succeeded');
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets("a second back during the leave prompt's own save is dropped", (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.enterText(_nameField, 'Socks');
    await tester.pump();

    repo.saveGate = Completer<void>();
    await tapBack(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle(); // the write is parked; no dialog is on screen now
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsNothing, reason: 'no second prompt stacked');

    repo.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1);
    expect(find.byType(NalbindProjectScreen), findsNothing);
    expect(find.text('open'), findsOneWidget, reason: 'one pop only');
  });

  testWidgets("an edit typed during the leave prompt's save keeps the screen open", (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.enterText(_nameField, 'Socks');
    await tester.pump();

    repo.saveGate = Completer<void>();
    await tapBack(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.enterText(_nameField, 'Socks, v2'); // lands while the write is in flight
    repo.saveGate!.complete();
    await tester.pumpAndSettle();

    expect(repo.saved, const NalbindProject(name: 'Socks'));
    expect(find.byType(NalbindProjectScreen), findsOneWidget,
        reason: 'the newer edit was not in that save, so leaving would drop it');
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsOneWidget);
  });

  testWidgets('the notation field reads in strict mode and lists every problem as an error',
      (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.enterText(_notationField, 'UO/XYZ');
    await tester.pumpAndSettle();

    expect(repo.modes, [true], reason: 'the project field is authoring');
    expect(find.text(_xyzError), findsOneWidget);
    expect(find.text(_turnError), findsOneWidget, reason: 'strict makes the warning an error too');
    expect(find.text(_saveHint), findsOneWidget);
    // The best effort is drawn, labelled approximate, and captioned as a schematic.
    final view = tester.widget<NalbindDiagramView>(find.byType(NalbindDiagramView));
    expect(view.approximate, isTrue);
    expect(find.text(_approximate), findsOneWidget);
    expect(find.text(_caption), findsOneWidget);
  });

  testWidgets('a builtin chip reads exactly: no problems, and the diagram is not approximate',
      (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.tap(find.widgetWithText(ActionChip, 'Oslo'));
    await tester.pumpAndSettle();
    expect(repo.modes, [true]);
    expect(find.textContaining('Error at'), findsNothing);
    expect(find.text(_saveHint), findsNothing);
    expect(find.text(_approximate), findsNothing);
    expect(tester.widget<NalbindDiagramView>(find.byType(NalbindDiagramView)).approximate, isFalse);
    expect(find.text(_caption), findsOneWidget);

    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Saved.'), findsOneWidget);
  });

  testWidgets('a project with notation problems still saves, says so, and keeps them listed',
      (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.enterText(_nameField, 'Draft socks');
    await tester.enterText(_notationField, 'UO/XYZ');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1, reason: 'a project is a draft: problems never block a save');
    expect(repo.saved?.notation, 'UO/XYZ', reason: 'saved as written');
    expect(find.text('Saved. The stitch notation still has problems.'), findsOneWidget);
    expect(find.text(_xyzError), findsOneWidget, reason: 'the problems stay visible');
    expect(find.text(_approximate), findsOneWidget);
  });

  testWidgets('an opened project shows its notation problems straight away', (tester) async {
    final repo = FakeProjectRepo()
      ..stored = const NalbindProject(name: 'Old mitten', notation: 'UO/XYZ');
    await pumpProject(tester, repo, openId: 'p1');
    expect(repo.modes, [true]);
    expect(find.text(_xyzError), findsOneWidget);
    expect(find.text(_turnError), findsOneWidget);
    expect(find.text(_approximate), findsOneWidget);
  });

  testWidgets('clearing the notation clears its problems and its diagram', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.enterText(_notationField, 'UO/XYZ');
    await tester.pumpAndSettle();
    expect(find.text(_xyzError), findsOneWidget);
    await tester.enterText(_notationField, '');
    await tester.pumpAndSettle();
    expect(find.text(_xyzError), findsNothing);
    expect(find.text(_saveHint), findsNothing);
    expect(find.byType(NalbindDiagramView), findsNothing);
  });

  // The project name has the limit weaving and knitting names have (ADR 0007), said where it is
  // typed and never cut short.
  Finder nameSays(String text) => find.descendant(of: _nameField, matching: find.text(text));

  testWidgets('a name past the limit is refused, never cut, until it is shortened', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    final long = 'N' * (DraftMeta.maxNameChars + 1);
    await tester.enterText(_nameField, long);
    await tester.pumpAndSettle();
    const said = 'Names can be at most 200 characters (this one has 201).';
    expect(nameSays(said), findsOneWidget, reason: 'said as it is typed');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 0, reason: 'nothing written while it is too long');
    expect(find.text(said), findsNWidgets(2), reason: 'under the field, and said on Save');
    expect(tester.widget<TextField>(_nameField).controller!.text, long, reason: 'never cut');

    await tester.enterText(_nameField, 'N' * DraftMeta.maxNameChars);
    await tester.pumpAndSettle();
    expect(nameSays(said), findsNothing);
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1);
    expect(repo.saved?.name, 'N' * DraftMeta.maxNameChars);
  });

  testWidgets('a name saved before the limit opens and saves as it is; a change must shorten it',
      (tester) async {
    final long = 'L' * 300;
    final repo = FakeProjectRepo()
      ..stored = NalbindProject(name: long, notation: 'UO/UOO F1', stitchName: 'Oslo');
    await pumpProject(tester, repo, openId: 'p1');
    expect(tester.widget<TextField>(_nameField).controller!.text, long);
    expect(find.textContaining('Names can be at most'), findsNothing, reason: 'it opens as it is');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1, reason: 'and saves as it always has');
    expect(repo.saved?.name, long);

    await tester.enterText(_nameField, '${long}s');
    await tester.pumpAndSettle();
    const said = 'Names can be at most 200 characters (this one has 301).';
    expect(nameSays(said), findsOneWidget);
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1, reason: 'a changed name past the limit is not written');

    // Typing the saved name back is no change.
    await tester.enterText(_nameField, long);
    await tester.pumpAndSettle();
    expect(nameSays(said), findsNothing);
    await tester.enterText(_nameField, 'Mittens');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 2);
    expect(repo.saved?.name, 'Mittens');
  });
}
