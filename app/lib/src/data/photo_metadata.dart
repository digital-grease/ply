// Remove what a photo says about where, when and with what it was taken, as it is added to Ply
// (ADR 0016): a phone photo's EXIF block can carry the GPS position, the device and the time, and a
// full backup carries the photos off the device. The image data itself is copied unchanged (no
// re-encoding, no quality loss), and a JPEG keeps its orientation.
//
// - JPEG: APP1 (EXIF and XMP), APP12, APP13 (IPTC) and comments are dropped (`stripJpegMetadata`);
//   when the photo was turned (EXIF Orientation 2 to 8), a minimal EXIF block holding only the
//   Orientation tag is written back, so it still shows the right way up.
// - PNG: the eXIf, tEXt, zTXt, iTXt and tIME chunks are dropped; every other chunk is copied as is.
// - WebP and HEIC are kept as they are: Ply cannot strip them yet, and Help says so.

import 'dart:typed_data';

import '../print/jpeg_metadata.dart';

/// The image formats a photo is recognized as, by its first bytes (not its name).
enum PhotoFormat { jpeg, png, webp, heic, other }

PhotoFormat photoFormatOf(Uint8List b) {
  if (isJpeg(b)) return PhotoFormat.jpeg;
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47 &&
      b[4] == 0x0D &&
      b[5] == 0x0A &&
      b[6] == 0x1A &&
      b[7] == 0x0A) {
    return PhotoFormat.png;
  }
  String ascii(int from, int to) => String.fromCharCodes(b.sublist(from, to));
  if (b.length >= 12 && ascii(0, 4) == 'RIFF' && ascii(8, 12) == 'WEBP') return PhotoFormat.webp;
  if (b.length >= 12 && ascii(4, 8) == 'ftyp') return PhotoFormat.heic;
  return PhotoFormat.other;
}

/// A photo as Ply stores it.
class CleanedPhoto {
  const CleanedPhoto(this.bytes, {required this.stripped});

  final Uint8List bytes;

  /// Whether the metadata was removed (false for a format Ply cannot strip, kept as it was).
  final bool stripped;
}

/// The photo [bytes] without their metadata (see the file header), or null when a JPEG or PNG is
/// not well formed and may hold metadata Ply could not find: such a photo is not stored. One that
/// cannot be read through but holds no metadata marker or chunk name at all is kept as it is.
CleanedPhoto? cleanPhoto(Uint8List bytes) {
  switch (photoFormatOf(bytes)) {
    case PhotoFormat.jpeg:
      final clean = cleanJpeg(bytes);
      if (clean != null) return CleanedPhoto(clean, stripped: true);
      return _hasJpegMetadataMarker(bytes) ? null : CleanedPhoto(bytes, stripped: true);
    case PhotoFormat.png:
      final clean = cleanPng(bytes);
      if (clean != null) return CleanedPhoto(clean, stripped: true);
      return _hasPngMetadataChunk(bytes) ? null : CleanedPhoto(bytes, stripped: true);
    case PhotoFormat.webp:
    case PhotoFormat.heic:
    case PhotoFormat.other:
      return CleanedPhoto(bytes, stripped: false);
  }
}

/// Whether the name of a PNG metadata chunk appears anywhere in [b].
bool _hasPngMetadataChunk(Uint8List b) {
  for (final name in _pngDropped) {
    final n = name.codeUnits;
    outer:
    for (var i = 0; i + n.length <= b.length; i++) {
      for (var j = 0; j < n.length; j++) {
        if (b[i + j] != n[j]) continue outer;
      }
      return true;
    }
  }
  return false;
}

/// Whether [b] holds a marker of a JPEG metadata segment anywhere (APP1, APP12, APP13, COM).
bool _hasJpegMetadataMarker(Uint8List b) {
  for (var i = 0; i + 1 < b.length; i++) {
    if (b[i] == 0xFF &&
        (b[i + 1] == 0xE1 || b[i + 1] == 0xEC || b[i + 1] == 0xED || b[i + 1] == 0xFE)) {
      return true;
    }
  }
  return false;
}

/// [bytes] (a JPEG) without its metadata, keeping its orientation; null when it is not well formed.
Uint8List? cleanJpeg(Uint8List bytes) {
  final orientation = jpegOrientation(bytes);
  final stripped = stripJpegMetadata(bytes);
  if (stripped == null) return null;
  if (orientation == null || orientation == 1) return stripped;
  // Write the orientation back right after SOI, or after the JFIF APP0 segment when there is one.
  var at = 2;
  if (stripped.length > 5 && stripped[2] == 0xFF && stripped[3] == 0xE0) {
    at = 4 + ((stripped[4] << 8) | stripped[5]);
  }
  return Uint8List.fromList([
    ...stripped.sublist(0, at),
    ...orientationExif(orientation),
    ...stripped.sublist(at),
  ]);
}

/// The EXIF Orientation (1 to 8) of a JPEG, or null when it has none Ply can read.
int? jpegOrientation(Uint8List b) {
  if (!isJpeg(b)) return null;
  var i = 2;
  while (i + 4 <= b.length && b[i] == 0xFF) {
    final marker = b[i + 1];
    if (marker == 0xDA || marker == 0xD9) return null;
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0xFF) {
      i += marker == 0xFF ? 1 : 2;
      continue;
    }
    final length = (b[i + 2] << 8) | b[i + 3];
    final start = i + 4;
    final end = i + 2 + length;
    if (length < 2 || end > b.length) return null;
    if (marker == 0xE1 &&
        end - start >= 6 &&
        String.fromCharCodes(b.sublist(start, start + 4)) == 'Exif' &&
        b[start + 4] == 0 &&
        b[start + 5] == 0) {
      final o = _tiffOrientation(Uint8List.sublistView(b, start + 6, end));
      if (o != null) return o;
    }
    i = end;
  }
  return null;
}

/// The Orientation tag (0x0112) of a TIFF block's first IFD.
int? _tiffOrientation(Uint8List t) {
  if (t.length < 8) return null;
  final little = t[0] == 0x49 && t[1] == 0x49;
  final big = t[0] == 0x4D && t[1] == 0x4D;
  if (!little && !big) return null;
  int u16(int o) => little ? t[o] | (t[o + 1] << 8) : (t[o] << 8) | t[o + 1];
  int u32(int o) => little
      ? t[o] | (t[o + 1] << 8) | (t[o + 2] << 16) | (t[o + 3] << 24)
      : (t[o] << 24) | (t[o + 1] << 16) | (t[o + 2] << 8) | t[o + 3];
  if (u16(2) != 42) return null;
  final ifd = u32(4);
  if (ifd < 8 || ifd + 2 > t.length) return null;
  final count = u16(ifd);
  for (var k = 0; k < count; k++) {
    final e = ifd + 2 + 12 * k;
    if (e + 12 > t.length) return null;
    if (u16(e) == 0x0112 && u16(e + 2) == 3 && u32(e + 4) == 1) {
      final v = u16(e + 8);
      return v >= 1 && v <= 8 ? v : null;
    }
  }
  return null;
}

/// A minimal APP1 EXIF segment holding only the Orientation tag (big-endian TIFF, one IFD entry).
Uint8List orientationExif(int orientation) => Uint8List.fromList([
      0xFF, 0xE1, 0x00, 34, // APP1, length 34 (the two length bytes + 32)
      0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
      0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, // TIFF header: big-endian, IFD0 at 8
      0x00, 0x01, // one entry
      0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, orientation, 0x00, 0x00, // Orientation
      0x00, 0x00, 0x00, 0x00, // no next IFD
    ]);

/// The PNG chunks dropped: EXIF, text (which can hold XMP with a position), and the time.
const Set<String> _pngDropped = {'eXIf', 'tEXt', 'zTXt', 'iTXt', 'tIME'};

/// [bytes] (a PNG) without its metadata chunks; null when it is not well formed up to IEND.
Uint8List? cleanPng(Uint8List bytes) {
  if (photoFormatOf(bytes) != PhotoFormat.png) return null;
  final out = BytesBuilder(copy: false)..add(Uint8List.sublistView(bytes, 0, 8));
  var i = 8;
  while (i + 12 <= bytes.length) {
    final length = (bytes[i] << 24) | (bytes[i + 1] << 16) | (bytes[i + 2] << 8) | bytes[i + 3];
    final end = i + 12 + length;
    if (length < 0 || end > bytes.length) return null;
    final type = String.fromCharCodes(bytes.sublist(i + 4, i + 8));
    if (!_pngDropped.contains(type)) out.add(Uint8List.sublistView(bytes, i, end));
    i = end;
    if (type == 'IEND') return out.takeBytes();
  }
  return null;
}
