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
