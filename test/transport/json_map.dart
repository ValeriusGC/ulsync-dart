/// Decodes JSON text into a strictly typed map for transport tests.
///
/// Copied from `test/protocol/json_map.dart` on purpose: a shared helper
/// across test folders is YAGNI until a third copy appears.
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
