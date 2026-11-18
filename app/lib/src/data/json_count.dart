// How many values a JSON text holds, counted without decoding it.
//
// Dart's `jsonDecode` takes memory for every value, and many small values take far more than their
// text: 4 MB of `{}` decodes to over 300 MB. A reader that decodes untrusted JSON with it can count
// the values first and refuse a text with more than any honest one has. The count bounds decode
// memory only roughly (a value's cost depends on its kind: an empty object is the dearest, about
// 250 bytes), so a limit built on it is a guard against the blowup, not an exact budget.
//
// This is the engine's counter (`ply_common::json_count::count_values`, the one behind the value
// guards of patterns and projects; ADR 0002) in Dart, the same one-pass scan with the same counts,
// for the JSON the backup restore decodes in Dart itself (the manifest and the sidecars): those are
// checked in host tests, which cannot load the engine, and the manifest is checked before anything
// else, where a missing engine call would refuse every backup. The tests run the engine's own cases.
//
// What it counts: every object, list, string, number, `true`, `false` and `null`, and every object
// key (a key is a string). `{"a": [1, 2]}` has five: the object, the key, the list, and two numbers.
//
// How: one pass over the text, allocating nothing and never recursing. String contents are skipped
// (an escape is two characters, so a `\"` never ends a string, and nothing is decoded); a number or
// a literal is skipped as one run of characters, however long. The text is not checked: a malformed
// one gets a count too, and the reader that decodes it refuses it.
//
// [measureJson] also reports two things only the Dart readers need: how deeply lists and objects
// nest, and whether a number is too large for a double. `jsonDecode` takes both in its stride, but
// what the restore does next does not: `jsonEncode` recurses (thousands of levels overflow the
// stack) and refuses infinity, which `jsonDecode` makes of `1e400` or of a 400-digit integer. The
// engine needs neither: serde_json refuses nesting past 128 levels where it builds a value (and
// skips an unread one without recursing), and refuses a number out of a double's range.

const int _quote = 0x22; // "
const int _backslash = 0x5C; // \
const int _openBrace = 0x7B; // {
const int _openBracket = 0x5B; // [
const int _minus = 0x2D; // -
const int _plus = 0x2B; // +
const int _dot = 0x2E; // .
const int _closeBrace = 0x7D; // }
const int _closeBracket = 0x5D; // ]
const int _e = 0x65; // e
const int _upperE = 0x45; // E

bool _isAsciiAlphanumeric(int c) =>
    (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

/// The number of JSON values in [text], the UTF-8 bytes of a JSON text or the UTF-16 code units of
/// one (`String.codeUnits`): only ASCII characters matter, so both give the same count. With [stop],
/// counting ends as soon as the count passes it (the result is then `stop + 1`), so a caller that
/// only asks "at most [stop]?" never scans past the point it learns the answer.
int countJsonValues(List<int> text, {int? stop}) => measureJson(text, stop: stop).values;

/// Whether [text] (as [countJsonValues] takes it) has at most [limit] JSON values.
bool jsonValuesWithin(List<int> text, int limit) => countJsonValues(text, stop: limit) <= limit;

/// What [measureJson] finds in a JSON text: its [values] (as [countJsonValues] counts them), its
/// deepest nesting of lists and objects ([depth]: 0 for a lone number, 1 for `[]` or `{}`), and
/// whether a number in it is too large for a double ([nonFinite]: `jsonDecode` would make it
/// infinity).
typedef JsonShape = ({int values, int depth, bool nonFinite});

/// [countJsonValues] with the nesting depth and whether a number is out of a double's range, in the
/// same one pass. With [stop], it ends as soon as the count passes it (the depth and numbers past
/// that point are not looked at).
JsonShape measureJson(List<int> text, {int? stop}) {
  final n = text.length;
  var count = 0;
  var depth = 0;
  var deepest = 0;
  var nonFinite = false;
  var i = 0;
  while (i < n) {
    final c = text[i];
    if (c == _quote) {
      count++;
      i++;
      while (i < n) {
        final s = text[i];
        if (s == _backslash) {
          i += 2;
        } else if (s == _quote) {
          i++;
          break;
        } else {
          i++;
        }
      }
    } else if (c == _openBrace || c == _openBracket) {
      count++;
      i++;
      if (++depth > deepest) deepest = depth;
    } else if (c == _closeBrace || c == _closeBracket) {
      i++;
      if (depth > 0) depth--;
      continue;
    } else if (c == _minus || _isAsciiAlphanumeric(c)) {
      // A number, `true`, `false` or `null`: one value however long.
      count++;
      final start = i;
      var exponent = false;
      i++;
      while (i < n) {
        final t = text[i];
        if (!_isAsciiAlphanumeric(t) && t != _dot && t != _plus && t != _minus) break;
        if (t == _e || t == _upperE) exponent = true;
        i++;
      }
      // Only a number with an exponent or of hundreds of digits can be out of a double's range.
      if (!nonFinite && (c == _minus || (c >= 0x30 && c <= 0x39)) && (exponent || i - start > 300)) {
        final number = double.tryParse(String.fromCharCodes(text, start, i));
        if (number != null && !number.isFinite) nonFinite = true;
      }
    } else {
      i++;
      continue;
    }
    if (stop != null && count > stop) break;
  }
  return (values: count, depth: deepest, nonFinite: nonFinite);
}
