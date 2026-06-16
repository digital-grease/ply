import 'dart:convert';

import 'package:http/http.dart' as http;

/// A read-only client for the Ravelry API (https://api.ravelry.com) using HTTP Basic Auth with the
/// USER'S OWN key. This is the ONLY part of Ply that touches the network; it is optional and
/// off-by-default. Write methods are intentionally absent in v1 (the connector is read-only).
///
/// The [http.Client] is injectable so the client is host-testable with a mock — no real network in
/// tests. Credentials are an access key (username) + a personal/read-only key (password), per
/// Ravelry's Basic Auth docs; HTTPS is required by Ravelry.
class RavelryService {
  RavelryService({required this.accessKey, required this.key, http.Client? client})
      : _client = client ?? http.Client();

  final String accessKey;
  final String key;
  final http.Client _client;

  static const String _base = 'https://api.ravelry.com';

  Map<String, String> get _headers => {
        'Authorization': 'Basic ${base64Encode(utf8.encode('$accessKey:$key'))}',
      };

  /// Verify the credentials and return the signed-in Ravelry username. Throws [RavelryException] on
  /// an auth or network error.
  Future<String> currentUsername() async {
    final res = await _get(Uri.parse('$_base/current_user.json'));
    final user = (jsonDecode(res.body) as Map<String, dynamic>)['user'] as Map<String, dynamic>?;
    return (user?['username'] as String?) ?? '';
  }

  /// Read-only global search restricted to patterns. Returns display-ready results (title + image +
  /// permalink); browsing/importing happens on ravelry.com — Ravelry does not expose editable drafts.
  Future<List<RavelrySearchResult>> searchPatterns(String query, {int limit = 30}) async {
    if (query.trim().isEmpty) return const [];
    final uri = Uri.parse('$_base/search.json').replace(queryParameters: {
      'query': query.trim(),
      'types': 'Pattern',
      'limit': '$limit',
    });
    final res = await _get(uri);
    final results = (jsonDecode(res.body) as Map<String, dynamic>)['results'] as List? ?? const [];
    return [
      for (final r in results)
        if (r is Map<String, dynamic>) RavelrySearchResult.fromJson(r),
    ];
  }

  Future<http.Response> _get(Uri uri) async {
    final http.Response res;
    try {
      res = await _client.get(uri, headers: _headers);
    } catch (e) {
      throw RavelryException('Could not reach Ravelry. Check your connection.');
    }
    if (res.statusCode == 200) return res;
    throw RavelryException(switch (res.statusCode) {
      401 || 403 => 'Ravelry rejected the credentials. Check your access key and read-only key.',
      429 => 'Ravelry rate limit reached — wait a moment and try again.',
      >= 500 => 'Ravelry is unavailable right now (${res.statusCode}).',
      _ => 'Ravelry request failed (${res.statusCode}).',
    });
  }
}

/// One pattern search result (read-only display data).
class RavelrySearchResult {
  const RavelrySearchResult({
    required this.title,
    required this.typeName,
    this.caption,
    this.thumbUrl,
    this.imageUrl,
    this.permalink,
  });

  final String title;
  final String typeName;
  final String? caption;
  final String? thumbUrl;
  final String? imageUrl;
  final String? permalink;

  /// The pattern's page on ravelry.com (for "view on Ravelry"), or null without a permalink.
  String? get ravelryUrl =>
      permalink == null ? null : 'https://www.ravelry.com/patterns/library/$permalink';

  factory RavelrySearchResult.fromJson(Map<String, dynamic> json) {
    final record = json['record'] as Map<String, dynamic>?;
    return RavelrySearchResult(
      title: (json['title'] as String?) ?? '',
      typeName: (json['type_name'] as String?) ?? '',
      caption: json['caption'] as String?,
      thumbUrl: json['tiny_image_url'] as String?,
      imageUrl: json['image_url'] as String?,
      permalink: record?['permalink'] as String?,
    );
  }
}

/// A Ravelry API/network error with a user-facing [message].
class RavelryException implements Exception {
  RavelryException(this.message);
  final String message;
  @override
  String toString() => message;
}
