/// Reads the open JWT `exp` claim without verifying the signature.
///
/// This is not authentication. The client already holds the token; it only
/// needs the wall-clock time at which the live stream should be reopened.
/// The server verifies the signature when the stream opens. `alg`, `nbf`,
/// `iss`, `aud`, and the signature are not checked.
library;

import 'dart:convert';

/// Reads the open JWT `exp` claim without verifying the signature.
///
/// This is not authentication. The client already holds the token; it only
/// needs the wall-clock time at which the live stream should be reopened.
/// The server verifies the signature when the stream opens. `alg`, `nbf`,
/// `iss`, `aud`, and the signature are not checked.
///
/// Returns `null` when the compact form is not three segments, the payload
/// is not JSON, or `exp` is missing or not an integer. Callers then use
/// [durationUntilReopen] which falls back to a long interval rather than
/// reconnecting immediately.
DateTime? readJwtExpiry(String token) {
  final parts = token.split('.');
  if (parts.length != 3) {
    return null;
  }
  try {
    final padded = _padBase64Url(parts[1]);
    final jsonText = utf8.decode(base64Url.decode(padded));
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map) {
      return null;
    }
    final map = Map<String, Object?>.from(decoded);
    final exp = map['exp'];
    if (exp is! int) {
      return null;
    }
    // JWT `exp` is NumericDate: seconds since the Unix epoch (RFC 7519),
    // not milliseconds. Multiplying by 1000 is the unit conversion.
    return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

/// Delay until a live stream should be reopened for a fresh token.
///
/// When [exp] is `null` (unreadable) the result is [unreadableInterval],
/// never [Duration.zero]: spinning on a malformed token would look like a
/// reconnect storm. When `exp - reopenBefore` is already in the past, the
/// result is [Duration.zero] (reopen on the next event-loop turn).
Duration durationUntilReopen({
  required DateTime? exp,
  required DateTime now,
  required Duration reopenBefore,
  required Duration unreadableInterval,
}) {
  if (exp == null) {
    return unreadableInterval;
  }
  final target = exp.subtract(reopenBefore);
  if (!target.isAfter(now)) {
    return Duration.zero;
  }
  return target.difference(now);
}

/// Pads a base64url string to a multiple of four characters with `=`.
///
/// JWT compact serialization omits padding; `base64Url.decode` still wants
/// a legal length.
String _padBase64Url(String input) {
  final remainder = input.length % 4;
  if (remainder == 0) {
    return input;
  }
  return input + ('=' * (4 - remainder));
}
