/// Application-contour origin (SPEC section 1.5).
///
/// The string lives in the application project, not on the device and not
/// inside an envelope. An empty value is a constructor error so a forgotten
/// origin cannot reach the network.
library;

/// Maximum origin length on the wire (SPEC section 1.5).
const int kUlsyncOriginMaxLength = 256;

/// SPEC section 1.5 character class: `A–Z a–z 0–9 . _ / -`.
final RegExp kUlsyncOriginPattern = RegExp(r'^[A-Za-z0-9._/-]+$');

/// Trims [origin] and rejects an empty, overlong, or illegal string.
///
/// Throws [ArgumentError] at construction, never after a network call.
/// The library does not mint a UUID here: a per-device value would refuse
/// the second installation forever.
String requireUlsyncOrigin(String origin) {
  final trimmed = origin.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(origin, 'origin', 'must be non-empty');
  }
  if (trimmed.length > kUlsyncOriginMaxLength) {
    throw ArgumentError.value(
      origin,
      'origin',
      'must be at most $kUlsyncOriginMaxLength characters',
    );
  }
  if (!kUlsyncOriginPattern.hasMatch(trimmed)) {
    throw ArgumentError.value(
      origin,
      'origin',
      'must use A–Z, a–z, 0–9, ".", "_", "/", "-"',
    );
  }
  return trimmed;
}

/// The store already belongs to another application contour.
///
/// HTTP `409` on `GET /v1/sync/hello`. Point this application at the store
/// the origin constant was built for, or change the constant and the store
/// configuration together. The library will not rewrite [requestOrigin].
final class OriginMismatchException implements Exception {
  /// Creates a mismatch naming both sides of the conflict.
  OriginMismatchException({
    required this.storeOrigin,
    required this.requestOrigin,
  });

  /// Origin the store already holds.
  final String storeOrigin;

  /// Origin this client sent.
  final String requestOrigin;

  @override
  String toString() {
    return 'OriginMismatchException: the store is bound to "$storeOrigin" '
        'but this client sent "$requestOrigin". Point this application at '
        'the store this origin constant was built for, or change the '
        'constant and the store configuration together. The library will '
        'not rewrite origin.';
  }
}
