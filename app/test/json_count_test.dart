import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/json_count.dart';

// The Dart value counter is the engine's (`ply_common::json_count::count_values`) in Dart: the same
// cases as the engine's own tests, counted over the UTF-8 bytes and over the code units alike.

void main() {
  int count(String text) {
    final byBytes = countJsonValues(utf8.encode(text));
    expect(countJsonValues(text.codeUnits), byBytes, reason: 'bytes and code units agree');
    return byBytes;
  }

  test('every value and key counts once', () {
    expect(count(''), 0);
    expect(count('0'), 1);
    expect(count('[]'), 1);
    expect(count('{}'), 1);
    expect(count('{"a": [1, 2]}'), 5);
    expect(count('[true, false, null, -1.5e+10, 0]'), 6);
    expect(count('{"a":{},"b":[],"c":"x"}'), 7);
    expect(count(' [ {} , {} ] \n'), 3);
    // A list of n empty objects is n + 1 values.
    expect(count('[${'{},' * 999}{}]'), 1001);
  });

  test('string contents and long tokens count as one', () {
    // Brackets, quotes and digits inside a string are text, not values.
    expect(count(r'["a, [b], {c}: 1 \"2\" 3"]'), 2);
    expect(count(r'["\\", "x"]'), 3); // an escaped backslash ends with the string
    expect(count(r'["é\n\t\/"]'), 2);
    // A lone surrogate, as Dart's jsonEncode writes it, is skipped like any escape.
    expect(count(r'{"notes":"\ud83d","name":"x\udc00y"}'), 5);
    expect(count(jsonEncode({'notes': '\ud83d'})), 3);
    // Non-ASCII text in a string.
    expect(count('["café 中\u{1f600}"]'), 2);
    // A number of any length is one value.
    expect(count('[${'9' * 100000}, 1]'), 3);
  });

  test('nesting of any depth is counted without recursion', () {
    expect(count('${'[' * 1000000}${']' * 1000000}'), 1000000);
  });

  test('a malformed text is counted without complaint', () {
    expect(count('{"unterminated'), 2);
    expect(count('not json'), 2);
    expect(count('"\\'), 1); // an escape at the very end
  });

  test('the deepest nesting and numbers too large for a double are found in the same pass', () {
    JsonShape of(String text) {
      final shape = measureJson(utf8.encode(text));
      expect(measureJson(text.codeUnits), shape, reason: 'bytes and code units agree');
      expect(shape.values, count(text));
      return shape;
    }

    expect(of('0').depth, 0);
    expect(of('[]').depth, 1);
    expect(of('{"a": [1, {"b": []}], "c": {}}').depth, 4);
    expect(of('[[], [[]], []]').depth, 3, reason: 'the deepest, not the last');
    expect(of('["[[[[", "{{"]').depth, 1, reason: 'brackets in a string are text');
    expect(of('${'[' * 5000}${']' * 5000}').depth, 5000);
    expect(of(']]][').depth, 1, reason: 'malformed text is measured without complaint');

    for (final big in ['1e400', '-1e400', '1E309', '9' * 400, '-${'9' * 400}', '2.5e+999']) {
      expect(of('{"a": [$big]}').nonFinite, isTrue, reason: big);
      expect(jsonDecode('[$big]')[0], anyOf(double.infinity, double.negativeInfinity));
    }
    for (final fine in ['1e308', '-1.7976931348623157e308', '1e-400', '9' * 300, '0', 'true']) {
      expect(of('[$fine]').nonFinite, isFalse, reason: fine);
    }
    expect(of('["1e400"]').nonFinite, isFalse, reason: 'a string, not a number');
  });

  test('with a stop, counting ends as soon as the count passes it', () {
    final text = utf8.encode('[${'{},' * 999}{}]'); // 1001 values
    expect(countJsonValues(text, stop: 2000), 1001);
    expect(countJsonValues(text, stop: 1001), 1001);
    expect(countJsonValues(text, stop: 1000), 1001);
    expect(countJsonValues(text, stop: 10), 11);
    expect(jsonValuesWithin(text, 1001), isTrue);
    expect(jsonValuesWithin(text, 1000), isFalse);
    expect(jsonValuesWithin(utf8.encode(''), 0), isTrue);
  });
}
