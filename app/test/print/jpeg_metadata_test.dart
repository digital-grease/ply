import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' show PdfImageOrientation, PdfJpegInfo;
import 'package:ply/src/print/jpeg_metadata.dart';

import 'print_test_support.dart';

// Photo metadata never reaches a shared PDF: the EXIF block (GPS position, camera), XMP, IPTC and
// comments are cut from a JPEG, while the color and image data are copied byte for byte.

/// The JPEG markers in [bytes] before the first scan, in order.
List<int> _markers(Uint8List bytes) {
  final out = <int>[];
  var i = 2;
  while (i + 3 < bytes.length) {
    final m = bytes[i + 1];
    out.add(m);
    if (m == 0xDA) break;
    i += 2 + ((bytes[i + 2] << 8) | bytes[i + 3]);
  }
  return out;
}

void main() {
  test('the fixture really carries EXIF (with GPS and orientation) and a comment', () {
    expect(_markers(jpegWithExif), containsAll([0xE0, 0xE1, 0xFE, 0xDB, 0xC0, 0xC4, 0xDA]));
    expect(PdfJpegInfo(jpegWithExif).orientation, PdfImageOrientation.rightTop);
  });

  test('EXIF and the comment are removed; JFIF, tables and the scan are kept verbatim', () {
    final clean = stripJpegMetadata(jpegWithExif)!;
    final markers = _markers(clean);
    expect(markers, isNot(contains(0xE1)), reason: 'EXIF / XMP');
    expect(markers, isNot(contains(0xFE)), reason: 'comment');
    expect(markers.first, 0xE0, reason: 'JFIF kept');
    expect(markers, containsAll([0xDB, 0xC0, 0xC4, 0xDA]));
    expect(containsBytes(clean, ascii.encode('PlyTestCam')), isFalse);
    expect(containsBytes(clean, ascii.encode('secret-comment')), isFalse);
    // Everything from the start of scan on is identical.
    final sos = jpegWithExif.length - (clean.length - _sosOffset(clean));
    expect(clean.sublist(_sosOffset(clean)), jpegWithExif.sublist(sos));
    // Still a JPEG the PDF library reads, the same size.
    final info = PdfJpegInfo(clean);
    expect((info.width, info.height), (8, 6));
  });

  test('a file that is not a well-formed JPEG is refused, never passed through', () {
    expect(stripJpegMetadata(tinyPng), isNull);
    expect(stripJpegMetadata(Uint8List.fromList([0xFF, 0xD8, 0xFF])), isNull, reason: 'truncated');
    expect(
        stripJpegMetadata(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x40, 1, 2])), isNull,
        reason: 'a segment longer than the file');
    expect(stripJpegMetadata(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9])), isNull,
        reason: 'no scan');
    expect(isJpeg(jpegWithExif), isTrue);
    expect(isJpeg(tinyPng), isFalse);
  });
}

int _sosOffset(Uint8List bytes) {
  for (var i = 2; i + 1 < bytes.length; i++) {
    if (bytes[i] == 0xFF && bytes[i + 1] == 0xDA) return i;
  }
  return -1;
}
