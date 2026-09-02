/// Decodes JSON text into a strictly typed map for protocol tests.
///
/// `jsonDecode` returns `Map<String, dynamic>`. With `strict-casts` and
/// `avoid_dynamic_calls`, passing that map to [Envelope.fromJson] requires an
/// explicit conversion to `Map<String, Object?>`.
library;

import 'dart:convert';

/// Parses [jsonText] and returns a `Map<String, Object?>`.
Map<String, Object?> decodeJsonMap(String jsonText) {
  final decoded = jsonDecode(jsonText);
  if (decoded is! Map) {
    throw FormatException('Expected JSON object, got ${decoded.runtimeType}');
  }
  return Map<String, Object?>.from(decoded);
}
