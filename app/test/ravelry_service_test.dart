import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ply/src/data/ravelry_service.dart';

// The read-only Ravelry API client, exercised against a MOCK http client — no real network. Covers
// auth header, parsing, the empty-query short-circuit, and error mapping.

RavelryService _serviceReturning(int status, Object body) {
  final client = MockClient((req) async => http.Response(jsonEncode(body), status));
  return RavelryService(accessKey: 'a', key: 'k', client: client);
}

void main() {
  test('currentUsername parses the signed-in user', () async {
    final s = _serviceReturning(200, {
      'user': {'username': 'knitterjane'}
    });
    expect(await s.currentUsername(), 'knitterjane');
  });

  test('sends HTTPS Basic Auth with the access key + key', () async {
    String? auth;
    Uri? uri;
    final client = MockClient((req) async {
      auth = req.headers['Authorization'];
      uri = req.url;
      return http.Response(jsonEncode({'user': {'username': 'x'}}), 200);
    });
    await RavelryService(accessKey: 'myaccess', key: 'mykey', client: client).currentUsername();
    expect(auth, 'Basic ${base64Encode(utf8.encode('myaccess:mykey'))}');
    expect(uri!.scheme, 'https');
    expect(uri!.host, 'api.ravelry.com');
  });

  test('searchPatterns maps results and builds the ravelry.com URL', () async {
    final s = _serviceReturning(200, {
      'results': [
        {
          'title': 'Cozy Socks',
          'type_name': 'Pattern',
          'caption': 'by Jane',
          'tiny_image_url': 'http://x/t.jpg',
          'image_url': 'http://x/i.jpg',
          'record': {'permalink': 'cozy-socks', 'type': 'pattern', 'id': 42},
        },
      ],
    });
    final results = await s.searchPatterns('socks');
    expect(results, hasLength(1));
    expect(results.first.title, 'Cozy Socks');
    expect(results.first.caption, 'by Jane');
    expect(results.first.ravelryUrl, 'https://www.ravelry.com/patterns/library/cozy-socks');
  });

  test('an empty/blank query short-circuits with no request', () async {
    var called = false;
    final client = MockClient((req) async {
      called = true;
      return http.Response('{}', 200);
    });
    final s = RavelryService(accessKey: 'a', key: 'k', client: client);
    expect(await s.searchPatterns('   '), isEmpty);
    expect(called, isFalse);
  });

  test('401/403 -> a clear credentials error', () async {
    final s = _serviceReturning(403, {'error': 'forbidden'});
    expect(
      () => s.currentUsername(),
      throwsA(isA<RavelryException>().having((e) => e.message, 'message', contains('credentials'))),
    );
  });

  test('429 -> a rate-limit message', () async {
    final s = _serviceReturning(429, <String, Object>{});
    expect(
      () => s.searchPatterns('x'),
      throwsA(isA<RavelryException>().having((e) => e.message, 'message', contains('rate limit'))),
    );
  });

  test('a network failure surfaces a friendly error', () async {
    final client = MockClient((req) async => throw const HttpExceptionStub());
    final s = RavelryService(accessKey: 'a', key: 'k', client: client);
    expect(
      () => s.currentUsername(),
      throwsA(isA<RavelryException>().having((e) => e.message, 'message', contains('reach Ravelry'))),
    );
  });
}

class HttpExceptionStub implements Exception {
  const HttpExceptionStub();
}
