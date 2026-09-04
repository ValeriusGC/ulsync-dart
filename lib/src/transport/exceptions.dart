/// Transport-level failures, split solely by whether a caller should retry.
///
/// Distinct from `UlsyncProtocolException`: a codec mismatch is not a
/// network problem and must not be retried. The protocol exception is not
/// a subtype of this hierarchy.
library;

/// Maximum characters of a response body kept on an exception.
///
/// Long enough to name an error in a log line; short enough that an envelope
/// payload is not copied in full. Do not write
/// [UlsyncTransportException.bodySnippet] to a log in full either — it may
/// still contain payload bytes.
const int kBodySnippetLimit = 200;

/// Truncates [body] to [kBodySnippetLimit] characters for exception fields.
String clipBodySnippet(String body) {
  if (body.length <= kBodySnippetLimit) {
    return body;
  }
  return body.substring(0, kBodySnippetLimit);
}

/// Transport-level failure. Split solely by whether a caller should retry.
sealed class UlsyncTransportException implements Exception {
  /// Creates a failure with [message].
  ///
  /// Pass [bodySnippet] through [clipBodySnippet] at the throw site.
  /// The snippet may still contain envelope payload; do not write it to a
  /// log in full.
  const UlsyncTransportException(
    this.message, {
    this.statusCode,
    this.bodySnippet = '',
  });

  /// Human-readable explanation. Does not include the response body.
  final String message;

  /// HTTP status when the failure came from a completed response.
  ///
  /// `null` when no request was sent (empty token) or the connection dropped
  /// before a status line.
  final int? statusCode;

  /// At most [kBodySnippetLimit] characters of the response body.
  ///
  /// May contain envelope payload; do not write it to a log in full.
  final String bodySnippet;

  @override
  String toString() {
    if (statusCode == null) {
      return '$runtimeType: $message';
    }
    return '$runtimeType ($statusCode): $message';
  }
}

/// Connection never completed or dropped. Callers may retry.
final class UlsyncNetworkException extends UlsyncTransportException {
  /// Creates a retryable network failure.
  const UlsyncNetworkException(
    super.message, {
    super.statusCode,
    super.bodySnippet,
  });
}

/// HTTP 5xx. Callers may retry.
///
/// Push and pull do not retry this themselves; they throw so the engine
/// owns the loop. The live feed reconnects on 5xx because the outward
/// stream must not complete.
final class UlsyncServerException extends UlsyncTransportException {
  /// Creates a retryable server failure.
  const UlsyncServerException(
    super.message, {
    super.statusCode,
    super.bodySnippet,
  });
}

/// Missing or empty token, or HTTP 401 after one fresh-token retry.
final class UlsyncUnauthorized extends UlsyncTransportException {
  /// Creates an authorization failure.
  ///
  /// [statusCode] is `null` when the token was empty and no request was sent.
  const UlsyncUnauthorized(
    super.message, {
    super.statusCode,
    super.bodySnippet,
  });
}

/// HTTP 4xx other than the 401-retry case (including 400 and 413).
///
/// Do not retry: the server will give the same answer. Looping on 413
/// drains the battery and the traffic budget.
final class UlsyncRequestRejected extends UlsyncTransportException {
  /// Creates a non-retryable client-error failure.
  const UlsyncRequestRejected(
    super.message, {
    super.statusCode,
    super.bodySnippet,
  });
}
