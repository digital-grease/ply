import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' show PdfImageOrientation, PdfJpegInfo;
import 'package:ply/src/data/photo_metadata.dart';
import 'package:ply/src/data/photo_store.dart';

import 'print/print_test_support.dart';

// A photo's metadata is removed as it is added (ADR 0016), for swatch and project photos alike: a
// JPEG loses its EXIF (with its GPS position and camera), its comment and any XMP or IPTC, but keeps
// its orientation; a PNG loses its text, EXIF and time chunks; WebP and HEIC are kept as they are; a
// JPEG or PNG that cannot be read but may hold metadata is not stored at all.

/// [png] with a tEXt chunk (an invented position) and an eXIf chunk inserted after IHDR.
Uint8List pngWithText(Uint8List png) {
  List<int> chunk(String type, List<int> data) => [
        (data.length >> 24) & 0xFF, (data.length >> 16) & 0xFF, (data.length >> 8) & 0xFF,
        data.length & 0xFF, ...ascii.encode(type), ...data, 0, 0, 0, 0, // CRC not checked here
      ];
  const ihdrEnd = 8 + 12 + 13;
  return Uint8List.fromList([
    ...png.sublist(0, ihdrEnd),
    ...chunk('tEXt', ascii.encode('Location\u0000GPS 51.5N 0.1W secret-place')),
    ...chunk('eXIf', ascii.encode('MM\u0000*PlyTestCam')),
    ...png.sublist(ihdrEnd),
  ]);
}

void main() {
  test('a JPEG with GPS loses it all but keeps its orientation', () {
    expect(jpegOrientation(jpegWithExif), 6, reason: 'the fixture is turned (rightTop)');
    expect(containsBytes(jpegWithExif, ascii.encode('PlyTestCam')), isTrue);
    final clean = cleanPhoto(jpegWithExif)!;
    expect(clean.stripped, isTrue);
    final b = clean.bytes;
    expect(containsBytes(b, ascii.encode('PlyTestCam')), isFalse, reason: 'the camera');
    expect(containsBytes(b, ascii.encode('secret-comment')), isFalse, reason: 'the comment');
    // The only EXIF left is the minimal block with the orientation: no GPS IFD (tag 0x8825) at all.
    expect(containsBytes(b, const [0x88, 0x25]), isFalse);
    expect(containsBytes(b, orientationExif(6)), isTrue);
    expect(jpegOrientation(b), 6);
    expect(PdfJpegInfo(b).orientation, PdfImageOrientation.rightTop,
        reason: 'still the right way up');
    // The image data is copied unchanged.
    final scan = jpegWithExif.indexOf(0xDA, 2);
    expect(containsBytes(b, jpegWithExif.sublist(scan - 1)), isTrue);
  });

  test('an upright JPEG gets no EXIF back', () {
    final turned = cleanJpeg(jpegWithExif)!;
    final block = orientationExif(6);
    final at = List.generate(turned.length - block.length, (i) => i)
        .firstWhere((i) => containsBytes(turned.sublist(i, i + block.length), block));
    // Make it upright (the Orientation value sits 29 bytes into the block) and clean it again.
    final upright = Uint8List.fromList(turned)..[at + 29] = 1;
    expect(jpegOrientation(upright), 1);
    final cleaned = cleanJpeg(upright)!;
    expect(containsBytes(cleaned, const [0xFF, 0xE1]), isFalse, reason: 'no EXIF at all');
  });

  test('a PNG loses its text, EXIF and time chunks and keeps its image', () {
    final marked = pngWithText(tinyPng);
    expect(containsBytes(marked, ascii.encode('secret-place')), isTrue);
    final clean = cleanPhoto(marked)!;
    expect(clean.stripped, isTrue);
    expect(containsBytes(clean.bytes, ascii.encode('secret-place')), isFalse);
    expect(containsBytes(clean.bytes, ascii.encode('PlyTestCam')), isFalse);
    expect(clean.bytes, tinyPng, reason: 'every other chunk copied as it was');
  });

  test('WebP and HEIC are kept as they are, and say so', () {
    final webp =
        Uint8List.fromList([...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('WEBPVP8 ')]);
    for (final b in [webp, heicLike]) {
      final c = cleanPhoto(b)!;
      expect(c.stripped, isFalse);
      expect(c.bytes, b);
    }
  });

  test('a broken JPEG or PNG that may hold metadata is not stored; one that cannot is', () {
    final brokenWithExif = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x40, 1, 2]);
    expect(cleanPhoto(brokenWithExif), isNull);
    expect(cleanPhoto(Uint8List.fromList([0xFF, 0xD8, 0xFF])), isNotNull, reason: 'no metadata');
    final brokenPng = pngWithText(tinyPng).sublist(0, 60);
    expect(cleanPhoto(brokenPng), isNull);
  });

  group('PhotoStore.add', () {
    late Directory docs;
    setUp(() async => docs = await Directory.systemTemp.createTemp('photo_meta'));
    tearDown(() => docs.delete(recursive: true));

    test('stores a photo without its GPS, for swatches and projects alike', () async {
      final src = File('${docs.path}/camera.jpg')..writeAsBytesSync(jpegWithExif);
      for (final subdir in ['swatches', 'nalbinds']) {
        final stored = await PhotoStore(subdir: subdir, id: 'x', docsOverride: docs).add(src);
        final b = stored.readAsBytesSync();
        expect(containsBytes(b, ascii.encode('PlyTestCam')), isFalse, reason: subdir);
        expect(jpegOrientation(b), 6, reason: subdir);
      }
      expect(src.readAsBytesSync(), jpegWithExif, reason: 'the picked file is not changed');
    });

    test('a photo that may hold metadata it cannot remove is refused, leaving nothing', () async {
      final src = File('${docs.path}/broken.jpg')
        ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x40, 1, 2]);
      final store = PhotoStore(subdir: 'swatches', id: 'y', docsOverride: docs);
      await expectLater(store.add(src), throwsA(isA<PhotoNotReadableException>()));
      expect(await store.list(), isEmpty);
      expect(Directory('${docs.path}/swatches/y.photos').listSync(), isEmpty,
          reason: 'no temp file');
    });

    test('photos already stored are never rewritten', () async {
      final dir = Directory('${docs.path}/swatches/z.photos')..createSync(recursive: true);
      final old = File('${dir.path}/old.jpg')..writeAsBytesSync(jpegWithExif);
      final store = PhotoStore(subdir: 'swatches', id: 'z', docsOverride: docs);
      await store.add(File('${docs.path}/new.png')..writeAsBytesSync(tinyPng));
      expect(old.readAsBytesSync(), jpegWithExif);
      expect(await store.list(), hasLength(2));
    });
  });
}
