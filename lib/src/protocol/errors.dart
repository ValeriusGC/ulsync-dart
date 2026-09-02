/// Protocol-level errors for the ulsync wire format.
///
/// Separates "the bytes do not match the contract" from network failures and
/// HTTP error responses (step 13). The application can retry a timeout but
/// must not treat a codec mismatch as a programming defect.
library;

/// Thrown when JSON or base64 does not match the envelope contract.
///
/// Implements [Exception], not [Error]: a format mismatch is an expected
/// runtime condition (stale client, server rollout), not a bug in the library.
final class UlsyncProtocolException implements Exception {
  /// Creates an exception describing [message].
  ///
  /// When the failure is tied to a single wire key, pass it as [field] so
  /// callers and logs can name the offending property without parsing text.
  const UlsyncProtocolException(this.message, {this.field});

  /// Human-readable explanation of the mismatch.
  final String message;

  /// Wire JSON key that failed validation, when the failure is field-specific.
  final String? field;

  @override
  String toString() {
    if (field == null) {
      return 'UlsyncProtocolException: $message';
    }
    return 'UlsyncProtocolException ($field): $message';
  }
}
