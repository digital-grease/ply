import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/knit_entry.dart';
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/screens/knit_library_screen.dart';
import 'package:ply/src/screens/library_screen.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/state/thumbnail_providers.dart';

// Missing library thumbnails are rebuilt in the background: one at a time, each project at most once
// per app run (a file that cannot be drawn keeps its placeholder and is not retried every time the
// library is shown), without holding up the list. The queue itself, then the weaving and knitting
// libraries over stand-in repositories (the knitting one through the real rebuild a restore uses).

DraftMeta _meta(String name) =>
    DraftMeta(name: name, savedAt: DateTime.utc(2020), lastOpened: DateTime.utc(2020));

/// A tile's thumbnail image at [path].
Finder _thumbAt(String path) => find.byWidgetPredicate(
    (w) => w is Image && w.image is FileImage && (w.image as FileImage).file.path == path);

/// The tiles still showing the placeholder.
Finder get _placeholders => find.byIcon(Icons.grid_on);

/// The tiles saying their picture could not be drawn (ADR 0021: never a silent blank tile).
Finder get _unavailable => find.byIcon(Icons.broken_image_outlined);

/// A valid 1x1 PNG, so a tile that loads it shows an image, never the placeholder.
final List<int> _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

void main() {
  group('the queue', () {
    test('runs one rebuild at a time, in the order asked', () async {
      final q = ThumbnailRegenerator();
      final log = <String>[];
      final gates = {for (final k in ['a', 'b', 'c']) k: Completer<void>()};
      final outcomes = [
        for (final k in ['a', 'b', 'c'])
          q.request(k, () async {
            log.add('start $k');
            await gates[k]!.future;
            log.add('end $k');
            return true;
          }),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(log, ['start a']);
      gates['b']!.complete(); // b is ready but must wait for a
      await Future<void>.delayed(Duration.zero);
      expect(log, ['start a']);
      gates['a']!.complete();
      await outcomes[1];
      expect(log, ['start a', 'end a', 'start b', 'end b', 'start c']);
      gates['c']!.complete();
      expect(await Future.wait(outcomes), [true, true, true]);
    });

    test('rebuilds each project once, and remembers a failure instead of retrying it', () async {
      final q = ThumbnailRegenerator();
      final calls = <String, int>{};
      Future<bool> Function() rebuild(String key, Object outcome) => () async {
            calls[key] = (calls[key] ?? 0) + 1;
            if (outcome is Exception) throw outcome;
            return outcome as bool;
          };
      // Asked twice before it ran: one rebuild, one outcome.
      final first = q.request('good', rebuild('good', true));
      final again = q.request('good', rebuild('good', true));
      expect(await first, isTrue);
      expect(await again, isTrue);
      // A rebuild that throws or draws nothing; neither stops the queue.
      expect(await q.request('throws', rebuild('throws', Exception('unreadable'))), isFalse);
      expect(await q.request('blank', rebuild('blank', false)), isFalse);
      expect(await q.request('after', rebuild('after', true)), isTrue);
      // Asked again and again (a library shown many times): never re-run.
      for (var i = 0; i < 5; i++) {
        expect(await q.request('throws', rebuild('throws', true)), isFalse);
        expect(await q.request('blank', rebuild('blank', true)), isFalse);
        expect(await q.request('good', rebuild('good', false)), isTrue);
      }
      expect(calls, {'good': 1, 'throws': 1, 'blank': 1, 'after': 1});
      await q.idle;
    });
  });

  group('the weaving library', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('thumbs_weave'));
    tearDown(() => dir.deleteSync(recursive: true));

    testWidgets('rebuilds a missing thumbnail once, in the background; a broken draft keeps its '
        'placeholder and is not retried', (t) async {
      final repo = _Drafts(dir, broken: {'bad'});
      final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo)]);
      addTearDown(c.dispose);
      Future<void> show(int revision) async {
        await t.pumpWidget(UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
              home: LibraryScreen(key: ValueKey(revision), repository: repo)),
        ));
        await t.pump();
      }

      await show(0);
      // The list is shown while the first rebuild is still running.
      expect(find.text('Good'), findsOneWidget);
      expect(find.text('Bad'), findsOneWidget);
      expect(find.text('Saved'), findsOneWidget);
      expect(_placeholders, findsNWidgets(2));
      expect(repo.calls, ['good'], reason: 'one at a time; the tile with a thumbnail needs none');
      repo.gate.complete();
      await t.pumpAndSettle();

      final good = p.join(dir.path, 'good.png');
      expect(File(good).existsSync(), isTrue);
      expect(_thumbAt(good), findsOneWidget);
      expect(_thumbAt(p.join(dir.path, 'saved.png')), findsOneWidget);
      expect(_placeholders, findsNothing);
      expect(_unavailable, findsOneWidget,
          reason: 'the broken draft says Ply could not draw it, instead of an empty placeholder');
      expect(find.byTooltip('No preview: Ply could not draw this project. Open it to see why.'),
          findsOneWidget);
      expect(repo.calls, ['good', 'bad']);

      // Shown again (as after a restore or a tab reload), with the stand-in still listing both
      // without a thumbnail: nothing is rebuilt again, and the rebuilt one is shown.
      for (var revision = 1; revision <= 3; revision++) {
        await show(revision);
        await t.pumpAndSettle();
      }
      expect(repo.calls, ['good', 'bad']);
      expect(_thumbAt(good), findsOneWidget);
      expect(_unavailable, findsOneWidget, reason: 'the remembered outcome is shown again');
    });
  });

  group('a draft with nothing to draw', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('thumbs_empty'));
    tearDown(() => dir.deleteSync(recursive: true));

    testWidgets('keeps the plain placeholder: nothing to draw is not a failure', (t) async {
      final repo = _Drafts(dir, broken: {})..empty = {'good', 'bad'};
      repo.gate.complete();
      final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo)]);
      addTearDown(c.dispose);
      await t.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: LibraryScreen(repository: repo)),
      ));
      await t.pumpAndSettle();
      expect(repo.calls, ['good', 'bad']);
      expect(_unavailable, findsNothing);
      expect(_placeholders, findsNWidgets(2));
    });
  });

  group('the knitting library', () {
    late Directory dir;
    late ui.Image image;
    setUp(() => dir = Directory.systemTemp.createTempSync('thumbs_knit'));
    tearDown(() => dir.deleteSync(recursive: true));

    testWidgets('rebuilds a missing thumbnail once with the restore rebuild; an unreadable pattern '
        'keeps its placeholder and is not retried', (t) async {
      await t.runAsync(() async => image = await _image());
      addTearDown(() => image.dispose());
      final repo = _Knits(dir, image, broken: {'bad'});
      final c = ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(c.dispose);
      Future<void> show(int revision) async {
        await t.pumpWidget(UncontrolledProviderScope(
          container: c,
          child: MaterialApp(home: KnitLibraryScreen(key: ValueKey(revision))),
        ));
        await t.pump();
      }

      await show(0);
      expect(find.text('Scarf'), findsOneWidget);
      expect(find.text('Junk'), findsOneWidget);
      final good = p.join(dir.path, 'good.png');
      // The rebuild encodes a PNG and writes it for real: let that work run between frames.
      await _settle(t, () => _thumbAt(good).evaluate().isNotEmpty && repo.reads.length == 2);
      expect(_isPng(File(good).readAsBytesSync()), isTrue);
      expect(File('$good.tmp').existsSync(), isFalse);
      expect(File(p.join(dir.path, 'bad.png')).existsSync(), isFalse);
      expect(_placeholders, findsOneWidget);
      expect(repo.reads, ['good', 'bad']);
      expect(repo.renderedAt, [KnitRepository.thumbnailCellPx]);

      for (var revision = 1; revision <= 3; revision++) {
        await show(revision);
        await t.pumpAndSettle();
      }
      expect(repo.reads, ['good', 'bad'], reason: 'each pattern is tried once per run');
      expect(_thumbAt(good), findsOneWidget);
      expect(_placeholders, findsOneWidget);
    });
  });
}

/// Alternate real time (for image encoding and file writes started by the widgets) with frames
/// until [done].
Future<void> _settle(WidgetTester t, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await t.pump();
  }
  expect(done(), isTrue, reason: 'the background rebuild did not finish');
}

/// Drafts "good" and "bad" listed without a thumbnail, "saved" with one. The stand-in rebuild writes
/// a thumbnail for every draft but the [broken] ones (as the real one writes nothing for a draft it
/// cannot draw); the first rebuild waits for [gate].
class _Drafts extends DraftRepository {
  _Drafts(this.dir, {required this.broken}) : super(draftsDirOverride: dir) {
    File(p.join(dir.path, 'saved.png')).writeAsBytesSync(_png);
  }

  final Directory dir;
  final Set<String> broken;
  final calls = <String>[];
  final gate = Completer<void>();

  DraftEntry _entry(String id, String name, {bool thumb = false}) => DraftEntry(
        id: id,
        wifPath: p.join(dir.path, '$id.wif'),
        thumbPath: thumb ? p.join(dir.path, '$id.png') : null,
        meta: _meta(name),
      );

  @override
  Future<List<DraftEntry>> list() async =>
      [_entry('good', 'Good'), _entry('bad', 'Bad'), _entry('saved', 'Saved', thumb: true)];

  @override
  Future<void> rebuildThumbnail(String id) async {
    calls.add(id);
    if (calls.length == 1) await gate.future;
    if (broken.contains(id) || empty.contains(id)) return;
    File(p.join(dir.path, '$id.png')).writeAsBytesSync(_png);
  }

  /// Drafts with no ends or no picks: nothing to draw (read from the WIF in the app; stood in here,
  /// as these drafts have no files).
  Set<String> empty = {};

  @override
  Future<bool?> hasCloth(String id) async => !empty.contains(id);
}

/// Patterns "good" and "bad" listed without a thumbnail. Reading a [broken] one fails, as for a
/// pattern this build cannot open; the others render as [image].
class _Knits extends KnitRepository {
  _Knits(this.dir, this.image, {required this.broken});

  final Directory dir;
  final ui.Image image;
  final Set<String> broken;
  final reads = <String>[];
  final renderedAt = <int>[];

  KnitEntry _entry(String id, String name) => KnitEntry(
        id: id,
        patternPath: p.join(dir.path, '$id.plyknit'),
        meta: _meta(name),
      );

  @override
  Future<List<KnitEntry>> listKnits() async => [_entry('good', 'Scarf'), _entry('bad', 'Junk')];

  @override
  Future<KnitPatternDto> readPattern(String id) async {
    reads.add(id);
    if (broken.contains(id)) throw Exception('Could not open the pattern file');
    return _AnyPattern();
  }

  @override
  Future<ui.Image> render(KnitPatternDto pattern, {required int cellPx}) async {
    renderedAt.add(cellPx);
    return image.clone();
  }
}

/// Any pattern: the stand-in render never looks at it.
class _AnyPattern implements KnitPatternDto {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<ui.Image> _image() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint()..color = Colors.red);
  return recorder.endRecording().toImage(4, 4);
}

bool _isPng(List<int> bytes) =>
    bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E;
