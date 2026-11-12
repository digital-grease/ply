import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/photo_store.dart';
import 'package:ply/src/widgets/project_photos.dart';

// PhotoStore (on-device project-photo storage) + the ProjectPhotos widget's add flow. The real
// image_picker is injected with a fake, and path_provider is bypassed via docsOverride.

/// A valid 1x1 transparent PNG so Image.file can decode the stored thumbnail in the widget test.
final Uint8List _png1x1 = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

void main() {
  late Directory docs;

  setUp(() async => docs = await Directory.systemTemp.createTemp('ply_photos'));
  tearDown(() => docs.delete(recursive: true));

  Future<File> source(String name) async {
    final f = File('${docs.path}/$name');
    await f.writeAsBytes(_png1x1);
    return f;
  }

  group('PhotoStore', () {
    test('add copies into <subdir>/<id>.photos and list returns it', () async {
      final store = PhotoStore(subdir: 'knits', id: 'abc', docsOverride: docs);
      final stored = await store.add(await source('pic.jpg'));
      expect(await stored.exists(), isTrue);
      expect(stored.path, contains('knits'));
      expect(stored.path, contains('abc.photos'));
      expect(await store.list(), hasLength(1));
    });

    test('list returns newest first', () async {
      final store = PhotoStore(subdir: 'nalbinds', id: 'p', docsOverride: docs);
      final a = await store.add(await source('a.jpg'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final b = await store.add(await source('b.jpg'));
      final list = await store.list();
      expect(list.first.path, b.path);
      expect(list.last.path, a.path);
    });

    test('add is atomic: identical bytes, no temp file left behind', () async {
      final store = PhotoStore(subdir: 'knits', id: 'a', docsOverride: docs);
      final stored = await store.add(await source('pic.png'));
      expect(stored.readAsBytesSync(), _png1x1);
      expect(stored.path, endsWith('.png'));
      final names = Directory('${docs.path}/knits/a.photos')
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .toList();
      expect(names, hasLength(1));
      expect(names.single.endsWith('.tmp'), isFalse);
    });

    test('a failed add leaves nothing in the store (no partial photo)', () async {
      final store = PhotoStore(subdir: 'knits', id: 'b', docsOverride: docs);
      await expectLater(store.add(File('${docs.path}/missing.jpg')), throwsA(isA<FileSystemException>()));
      expect(Directory('${docs.path}/knits/b.photos').listSync(), isEmpty);
      expect(await store.list(), isEmpty);
    });

    test('list never shows a leftover temp file from an interrupted add', () async {
      final store = PhotoStore(subdir: 'knits', id: 'c', docsOverride: docs);
      await Directory('${docs.path}/knits/c.photos').create(recursive: true);
      File('${docs.path}/knits/c.photos/half.jpg.tmp').writeAsBytesSync(const [0xFF, 0xD8]);
      expect(await store.list(), isEmpty);
    });

    test('delete removes a photo; list ignores non-images', () async {
      final store = PhotoStore(subdir: 'knits', id: 'k', docsOverride: docs);
      final stored = await store.add(await source('p.png'));
      await File('${docs.path}/knits/k.photos/notes.txt').writeAsString('x');
      expect(await store.list(), hasLength(1), reason: 'the .txt is ignored');
      await store.delete(stored);
      expect(await store.list(), isEmpty);
    });
  });

  testWidgets('offers Take a photo / Choose from gallery from the Add tile', (t) async {
    // Empty store -> only the Add tile renders (no Image.file to decode in the test zone).
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: ProjectPhotos(subdir: 'knits', id: 'empty', docsOverride: docs)),
    ));
    await t.pumpAndSettle();
    expect(find.text('Add'), findsOneWidget);

    await t.tap(find.text('Add'));
    await t.pumpAndSettle();
    expect(find.text('Take a photo'), findsOneWidget);
    expect(find.text('Choose from gallery'), findsOneWidget);
  });
}
