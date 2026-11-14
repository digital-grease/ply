// Strip the metadata segments from a JPEG before it goes into a PDF that may be shared. A phone
// photo's EXIF block can carry the GPS position, the device and the time; the PDF needs none of it,
// and Ply's photos never leave the device unless the user shares them. The image data itself is
// copied unchanged (no re-encoding, no quality loss).

import 'dart:typed_data';

/// The APPn / COM markers removed: APP1 (EXIF and XMP), APP12 (Ducky / picture info), APP13
/// (Photoshop IRB and IPTC), and comments. Kept: APP0 (JFIF), APP2 (ICC color profile) and APP14
/// (Adobe color transform), which decoders need to show the colors right.
const _dropped = {0xE1, 0xEC, 0xED, 0xFE};

/// Whether [bytes] start like a JPEG file.
bool isJpeg(Uint8List bytes) =>
    bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;

/// [bytes] (a JPEG) without its metadata segments, or null when the file is not a well-formed JPEG
/// up to its first scan (the caller then leaves the photo out and says so, rather than embedding
/// metadata it could not remove). Everything from the start-of-scan marker on is copied verbatim.
Uint8List? stripJpegMetadata(Uint8List bytes) {
  if (!isJpeg(bytes)) return null;
  final out = BytesBuilder(copy: false)..add(const [0xFF, 0xD8]);
  var i = 2;
  while (i < bytes.length) {
    if (bytes[i] != 0xFF) return null; // segments must start with a marker
    // Skip fill bytes (any number of 0xFF before the marker code).
    var j = i;
    while (j < bytes.length && bytes[j] == 0xFF) {
      j++;
    }
    if (j >= bytes.length) return null;
    final marker = bytes[j];
    if (marker == 0xDA) {
      out.add(Uint8List.sublistView(bytes, j - 1)); // SOS: the scan(s) and EOI, verbatim
      return out.takeBytes();
    }
    if (marker == 0xD9) return null; // EOI before any scan: no image
    // Standalone markers (TEM, RSTn) carry no length.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      out.add([0xFF, marker]);
      i = j + 1;
      continue;
    }
    if (j + 2 >= bytes.length) return null;
    final length = (bytes[j + 1] << 8) | bytes[j + 2]; // includes the two length bytes
    final end = j + 1 + length;
    if (length < 2 || end > bytes.length) return null;
    if (!_dropped.contains(marker)) out.add(Uint8List.sublistView(bytes, j - 1, end));
    i = end;
  }
  return null; // no scan
}
