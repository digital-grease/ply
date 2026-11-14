import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ply/src/print/pdf_fonts.dart';
import 'package:ply/src/print/print_document.dart';

// Shared helpers for the print tests: the bundled fonts read straight from `assets/fonts` (no asset
// bundle needed), small images, and a reader for the text of an UNCOMPRESSED Ply PDF (built with
// `compress: false`), so tests can check what a page really says.

PlyPdfFonts? _fonts;

/// The bundled print fonts, read from disk once.
PlyPdfFonts testFonts() => _fonts ??= PlyPdfFonts.fromBytes(
      regular: ByteData.sublistView(File('assets/fonts/FiraSans-Regular.ttf').readAsBytesSync()),
      bold: ByteData.sublistView(File('assets/fonts/FiraSans-Bold.ttf').readAsBytesSync()),
    );

/// An opaque [width] x [height] raster of one color.
PrintRaster solidRaster(int width, int height, {int r = 250, int g = 248, int b = 244}) {
  final rgba = Uint8List(width * height * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = r;
    rgba[i + 1] = g;
    rgba[i + 2] = b;
    rgba[i + 3] = 255;
  }
  return PrintRaster(width: width, height: height, rgba: rgba);
}

/// An 8x6 JPEG whose EXIF says "rotate 90" and carries a camera make ("PlyTestCam") and a GPS
/// position, plus a comment segment ("secret-comment"). Made with Pillow for these tests.
final Uint8List jpegWithExif = base64Decode([
  '/9j/4AAQSkZJRgABAQAAAQABAAD/4QCsRXhpZgAATU0AKgAAAAgAAwEPAAIAAAALAAAAMgESAAMAAAABAAYAAIglAAQAAAABAAAA',
  'PgAAAABQbHlUZXN0Q2FtAAAABAABAAIAAAACTgAAAAACAAUAAAADAAAAdAADAAIAAAACRQAAAAAEAAUAAAADAAAAjAAAAAAAAAA7',
  'AAAAAQAAADYAAAABAAAAKQAAAAEAAAAKAAAAAQAAAC0AAAABAAAAAwAAAAH//gAQc2VjcmV0LWNvbW1lbnT/2wBDAAMCAgMCAgMD',
  'AwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsN',
  'FBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAAGAAgDASIAAhEBAxEB/8QAHwAA',
  'AQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0Kx',
  'wRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWW',
  'l5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEB',
  'AQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLR',
  'ChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOk',
  'paanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDxCLvRRRXJx3/y',
  'UWJ/7c/9NxP6G8M/+STwf/cT/wBOzP/Z',
].join());

/// A 5x3 PNG.
final Uint8List tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAUAAAADCAIAAADUVFKvAAAAE0lEQVR4nGPkOsHFgASYkDlY+AAoSADi7CtNWQAAAABJRU5ErkJggg==');

/// The start of a HEIC file (an ISO box "ftypheic"), a format the PDF library cannot read.
final Uint8List heicLike = Uint8List.fromList([
  0,
  0,
  0,
  24,
  ...ascii.encode('ftypheic'),
  0,
  0,
  0,
  0,
  ...ascii.encode('mif1heic'),
]);

/// Whether [haystack] contains the bytes of [needle].
bool containsBytes(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// The pages of an uncompressed Ply PDF, read back: each page's MediaBox and its text, as the
/// words painted on it joined by single spaces (the PDF draws a word per text run, so a phrase
/// reads back with single spaces between its words).
class PdfReadBack {
  factory PdfReadBack(Uint8List bytes) {
    final s = latin1.decode(bytes);
    final objects = <int, String>{
      for (final m in RegExp(r'(\d+) 0 obj\n(.*?)\nendobj', dotAll: true).allMatches(s))
        int.parse(m[1]!): m[2]!,
    };
    final fonts = <String, Map<int, String>>{};
    for (final body in objects.values) {
      final f = RegExp(r'^<</Type/Font/Subtype/Type0/Name/(F\d+)\b.*?/ToUnicode (\d+) 0 R')
          .firstMatch(body);
      if (f != null) fonts[f[1]!] = _cmap(objects[int.parse(f[2]!)]!);
    }
    final root = objects.values.firstWhere((b) => b.startsWith('<</Type/Pages'));
    final kids = RegExp(r'(\d+) 0 R')
        .allMatches(RegExp(r'/Kids\[(.*?)\]').firstMatch(root)![1]!)
        .map((m) => int.parse(m[1]!));
    final boxes = <List<double>>[];
    final texts = <String>[];
    for (final kid in kids) {
      final page = objects[kid]!;
      boxes.add(RegExp(r'/MediaBox\[([^\]]*)\]')
          .firstMatch(page)![1]!
          .trim()
          .split(RegExp(r'\s+'))
          .map(double.parse)
          .toList());
      final contents = objects[int.parse(RegExp(r'/Contents (\d+) 0 R').firstMatch(page)![1]!)]!;
      final stream = contents.substring(contents.indexOf('stream\n') + 7);
      texts.add(_text(stream, fonts));
    }
    return PdfReadBack._(boxes, texts);
  }

  PdfReadBack._(this.mediaBoxes, this.pages);

  /// Each page's [x0, y0, x1, y1] in points.
  final List<List<double>> mediaBoxes;

  /// Each page's text.
  final List<String> pages;

  int get pageCount => pages.length;

  /// All the text, page after page.
  String get text => pages.join(' ');

  static Map<int, String> _cmap(String body) {
    final map = <int, String>{};
    for (final section in RegExp(r'beginbfchar(.*?)endbfchar', dotAll: true).allMatches(body)) {
      for (final m in RegExp(r'<([0-9A-Fa-f]{4})>\s*<([0-9A-Fa-f]+)>').allMatches(section[1]!)) {
        final hex = m[2]!;
        map[int.parse(m[1]!, radix: 16)] = String.fromCharCodes([
          for (var i = 0; i + 4 <= hex.length; i += 4)
            int.parse(hex.substring(i, i + 4), radix: 16),
        ]);
      }
    }
    return map;
  }

  static String _text(String stream, Map<String, Map<int, String>> fonts) {
    final words = <String>[];
    var font = <int, String>{};
    final ops = RegExp(r'/(F\d+) [\d.]+ Tf|\[([^\]]*)\]\s*TJ|<([0-9A-Fa-f]*)>\s*Tj');
    String decode(String hex) => [
          for (var i = 0; i + 4 <= hex.length; i += 4)
            font[int.parse(hex.substring(i, i + 4), radix: 16)] ?? '?',
        ].join();
    for (final m in ops.allMatches(stream)) {
      if (m[1] != null) {
        font = fonts[m[1]!] ?? const {};
      } else if (m[2] != null) {
        words.add(RegExp(r'<([0-9A-Fa-f]*)>').allMatches(m[2]!).map((h) => decode(h[1]!)).join());
      } else {
        words.add(decode(m[3]!));
      }
    }
    return words.where((w) => w.isNotEmpty).join(' ');
  }
}
