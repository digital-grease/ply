// A minimal POSIX ustar (IEEE Std 1003.1-1988) archive writer and reader for Ply's library backup.
//
// Deliberately small and UNCOMPRESSED: no decompression means no decompression-bomb class at all
// (an entry's bytes on disk are exactly its stated size), photos are already compressed, and the
// whole format fits in one auditable file. Only what the backup needs is supported:
//
// - Writing: regular files only (typeflag '0'), mode 0644, uid/gid 0, empty owner names. A path
//   longer than 100 bytes is split at a '/' into the 155-byte `prefix` and the 100-byte `name`.
// - Reading: regular files only. Links, devices, directories, FIFOs, pax/GNU extension headers and
//   anything else is refused, as is a header with a bad checksum or magic, a size in base-256, a
//   path with a non-printable or non-ASCII byte, an entry running past the end of the file, and an
//   archive without its two-block end marker. Paths are returned raw: the caller decides which
//   paths are acceptable (see `library_backup.dart`).
//
// The reader works on a [RandomAccessFile], so a large archive is never loaded into memory.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The ustar block size: every header is one block and every entry's data is padded to a block.
const int ustarBlockSize = 512;

/// The largest entry size the 11-digit octal size field can hold (8 GiB - 1).
const int ustarMaxEntrySize = 0x1FFFFFFFF;

/// The longest path a ustar header can carry: a 155-byte prefix, the '/' between, a 100-byte name.
const int ustarMaxPathLength = 256;

/// Bytes of padding after [size] bytes of entry data, up to the next block boundary.
int ustarPadding(int size) => (ustarBlockSize - size % ustarBlockSize) % ustarBlockSize;

/// The bytes an entry of [size] data bytes occupies in an archive: its header plus padded data.
int ustarEntryLength(int size) => ustarBlockSize + size + ustarPadding(size);

/// The end-of-archive marker: two zero blocks.
const int ustarEndLength = 2 * ustarBlockSize;

/// What was wrong with an archive. The reader never guesses: anything it does not fully understand
/// is one of these.
enum UstarProblem {
  /// The file ends inside a header or an entry, or without the end-of-archive marker.
  truncated,

  /// A header's checksum, magic, version or numeric field is wrong, or bytes follow the end marker.
  damaged,

  /// An entry that is not a regular file (link, device, directory, FIFO, extension header).
  notRegularFile,

  /// A path with a byte outside printable ASCII, or an empty path.
  badPath,
}

/// A structural problem in an archive. [message] is diagnostic only.
class UstarFormatException implements Exception {
  const UstarFormatException(this.problem, this.message);

  final UstarProblem problem;
  final String message;

  @override
  String toString() => 'UstarFormatException(${problem.name}): $message';
}

/// The fields of one ustar header. Production code writes only regular-file headers through
/// [UstarHeader.file]; the full constructor exists so tests can build the malformed and hostile
/// headers the reader must refuse, through the same encoder.
class UstarHeader {
  const UstarHeader({
    required this.name,
    required this.size,
    this.prefix = '',
    this.typeflag = '0',
    this.linkname = '',
    this.mode = 0x1A4, // 0644
    this.modified = 0,
    this.magic = 'ustar\u0000',
    this.version = '00',
  });

  /// A regular-file header for [path] (split into prefix and name when longer than 100 bytes).
  /// Throws an [ArgumentError] for a path a ustar header cannot carry: empty, longer than
  /// [ustarMaxPathLength], with a byte outside printable ASCII, or with no '/' at which it splits
  /// into a prefix of at most 155 bytes and a non-empty name of at most 100.
  factory UstarHeader.file(String path, int size, {int modified = 0}) {
    if (size < 0 || size > ustarMaxEntrySize) {
      throw ArgumentError.value(size, 'size', 'outside the ustar size range');
    }
    final (prefix, name) = ustarSplitPath(path);
    return UstarHeader(name: name, prefix: prefix, size: size, modified: modified);
  }

  final String name;
  final String prefix;
  final int size;
  final String typeflag;
  final String linkname;
  final int mode;

  /// Seconds since the epoch.
  final int modified;
  final String magic;
  final String version;

  /// The 512-byte header block, with its checksum computed.
  Uint8List encode() {
    final b = Uint8List(ustarBlockSize);
    void put(int offset, int width, String value) {
      final bytes = latin1.encode(value);
      if (bytes.length > width) {
        throw ArgumentError.value(value, 'field', 'longer than $width bytes');
      }
      b.setRange(offset, offset + bytes.length, bytes);
    }

    // An octal number in [width] bytes: zero-padded digits, then a NUL.
    void octal(int offset, int width, int value) =>
        put(offset, width, '${value.toRadixString(8).padLeft(width - 1, '0')}\u0000');

    put(0, 100, name);
    octal(100, 8, mode);
    octal(108, 8, 0); // uid
    octal(116, 8, 0); // gid
    octal(124, 12, size);
    octal(136, 12, modified);
    put(148, 8, '        '); // checksum placeholder: eight spaces while summing
    put(156, 1, typeflag);
    put(157, 100, linkname);
    put(257, 6, magic);
    put(263, 2, version);
    // uname (265) and gname (297) stay empty.
    octal(329, 8, 0); // devmajor
    octal(337, 8, 0); // devminor
    put(345, 155, prefix);
    var sum = 0;
    for (final byte in b) {
      sum += byte;
    }
    put(148, 8, '${sum.toRadixString(8).padLeft(6, '0')}\u0000 ');
    return b;
  }
}

/// Split [path] into a ustar (prefix, name) pair. See [UstarHeader.file] for what is refused.
(String, String) ustarSplitPath(String path) {
  if (path.isEmpty) throw ArgumentError.value(path, 'path', 'empty');
  for (final unit in path.codeUnits) {
    if (unit < 0x20 || unit > 0x7E) {
      throw ArgumentError.value(path, 'path', 'not printable ASCII');
    }
  }
  if (path.length <= 100) return ('', path);
  if (path.length > ustarMaxPathLength) {
    throw ArgumentError.value(path, 'path', 'longer than $ustarMaxPathLength bytes');
  }
  // The latest '/' that leaves a prefix of at most 155 bytes and a name of at most 100.
  for (var i = path.length - 1; i > 0; i--) {
    if (path.codeUnitAt(i) != 0x2F) continue;
    final prefix = path.substring(0, i);
    final name = path.substring(i + 1);
    if (prefix.length <= 155 && name.isNotEmpty && name.length <= 100) return (prefix, name);
    if (prefix.length <= 155) break; // only shorter prefixes remain, so the name only grows
  }
  throw ArgumentError.value(path, 'path', 'cannot be split into a ustar prefix and name');
}

/// One regular-file entry of an archive: its [path], its data [size], and where the data starts.
class UstarEntry {
  const UstarEntry({required this.path, required this.size, required this.dataOffset});

  final String path;
  final int size;

  /// Byte offset of the entry's data in the archive file.
  final int dataOffset;
}

/// Reads the entries of a ustar archive in order, one header at a time. Call [next] until it returns
/// null (the end marker); every structural problem throws a [UstarFormatException].
class UstarReader {
  UstarReader(this._file, this._length);

  final RandomAccessFile _file;
  final int _length;
  int _position = 0;
  bool _ended = false;

  /// The next entry, or null once the end-of-archive marker (and nothing but zeros after it) has
  /// been read. Skips the previous entry's data without reading it.
  Future<UstarEntry?> next() async {
    if (_ended) return null;
    final header = await _readBlock(_position);
    if (_isZero(header)) {
      final second = await _readBlock(_position + ustarBlockSize);
      if (!_isZero(second)) {
        throw const UstarFormatException(UstarProblem.damaged, 'a lone zero block');
      }
      await _requireZeroTail(_position + 2 * ustarBlockSize);
      _ended = true;
      return null;
    }
    final entry = _parseHeader(header, _position);
    final dataEnd = entry.dataOffset + entry.size;
    if (dataEnd > _length) {
      throw UstarFormatException(UstarProblem.truncated, '${entry.path} runs past the end');
    }
    _position = dataEnd + ustarPadding(entry.size);
    return entry;
  }

  Future<Uint8List> _readBlock(int offset) async {
    if (offset + ustarBlockSize > _length) {
      throw const UstarFormatException(UstarProblem.truncated, 'the archive ends early');
    }
    await _file.setPosition(offset);
    final block = await _file.read(ustarBlockSize);
    if (block.length != ustarBlockSize) {
      throw const UstarFormatException(UstarProblem.truncated, 'short read');
    }
    return block;
  }

  /// Bytes after the end marker must all be zero (some writers pad to a record size).
  Future<void> _requireZeroTail(int from) async {
    var offset = from;
    while (offset < _length) {
      await _file.setPosition(offset);
      final chunk = await _file.read(_length - offset < 65536 ? _length - offset : 65536);
      if (chunk.isEmpty) break;
      if (!_isZero(chunk)) {
        throw const UstarFormatException(UstarProblem.damaged, 'data after the end marker');
      }
      offset += chunk.length;
    }
  }

  static bool _isZero(Uint8List bytes) {
    for (final b in bytes) {
      if (b != 0) return false;
    }
    return true;
  }

  static UstarEntry _parseHeader(Uint8List h, int offset) {
    // Checksum: the unsigned sum of the header with the checksum field read as spaces.
    var sum = 0;
    for (var i = 0; i < ustarBlockSize; i++) {
      sum += (i >= 148 && i < 156) ? 0x20 : h[i];
    }
    final stored = _octal(h, 148, 8, 'checksum');
    if (stored != sum) {
      throw UstarFormatException(UstarProblem.damaged, 'header checksum at $offset');
    }
    if (!_bytesEqual(h, 257, const [0x75, 0x73, 0x74, 0x61, 0x72, 0x00]) || // "ustar\0"
        !_bytesEqual(h, 263, const [0x30, 0x30])) {
      // "00"
      throw UstarFormatException(UstarProblem.damaged, 'not a POSIX ustar header at $offset');
    }
    final name = _string(h, 0, 100);
    final prefix = _string(h, 345, 155);
    final path = prefix.isEmpty ? name : '$prefix/$name';
    final type = h[156];
    // '0' and the pre-POSIX NUL are both a regular file; nothing else is accepted.
    if (type != 0x30 && type != 0x00) {
      throw UstarFormatException(UstarProblem.notRegularFile,
          '$path has type ${type >= 0x20 && type < 0x7F ? String.fromCharCode(type) : type}');
    }
    if (name.isEmpty) {
      throw UstarFormatException(UstarProblem.badPath, 'an entry with no name at $offset');
    }
    final size = _octal(h, 124, 12, 'size');
    return UstarEntry(path: path, size: size, dataOffset: offset + ustarBlockSize);
  }

  static bool _bytesEqual(Uint8List h, int offset, List<int> expected) {
    for (var i = 0; i < expected.length; i++) {
      if (h[offset + i] != expected[i]) return false;
    }
    return true;
  }

  /// A NUL-terminated (or field-filling) string of printable ASCII.
  static String _string(Uint8List h, int offset, int width) {
    var end = offset;
    while (end < offset + width && h[end] != 0) {
      final b = h[end];
      if (b < 0x20 || b > 0x7E) {
        throw const UstarFormatException(UstarProblem.badPath, 'a non-printable byte in a path');
      }
      end++;
    }
    // Anything after the terminator must be NUL too, so no hidden second string rides along.
    for (var i = end; i < offset + width; i++) {
      if (h[i] != 0) {
        throw const UstarFormatException(UstarProblem.badPath, 'bytes after a path terminator');
      }
    }
    return String.fromCharCodes(h, offset, end);
  }

  /// An octal field: optional leading spaces, at least one octal digit, then NULs or spaces only.
  /// A base-256 field (high bit set) is refused.
  static int _octal(Uint8List h, int offset, int width, String field) {
    var i = offset;
    final end = offset + width;
    while (i < end && h[i] == 0x20) {
      i++;
    }
    var value = 0;
    var digits = 0;
    while (i < end && h[i] >= 0x30 && h[i] <= 0x37) {
      value = value * 8 + (h[i] - 0x30);
      digits++;
      i++;
    }
    while (i < end && (h[i] == 0x00 || h[i] == 0x20)) {
      i++;
    }
    if (digits == 0 || i != end) {
      throw UstarFormatException(UstarProblem.damaged, 'a bad $field field');
    }
    return value;
  }
}
