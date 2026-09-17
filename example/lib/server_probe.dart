/// Pre-flight HTTP checks before [UlsyncClient] opens (health and whoami).
///
/// Uses [HttpClient] from `dart:io` so the example does not add a package
/// dependency. macOS acceptance runs on the desktop embedder; web builds are
/// not the round-2 gate for this sample.
library;

import 'dart:convert';
import 'dart:io';

/// Result of `GET /v1/whoami` with a valid bearer token.
final class WhoAmIResult {
  /// Creates a parsed whoami response.
  const WhoAmIResult({required this.userId});

  /// Subject for [UlsyncClient.userScope], from JSON `user_id`.
  final String userId;
}

/// Thrown when the server address cannot be reached or `/health` is not 200.
final class HealthCheckException implements Exception {
  /// Creates the error shown on the server-address screen.
  const HealthCheckException(this.message);

  /// Operator-facing text; never includes the bearer token.
  final String message;

  @override
  String toString() => message;
}

/// Thrown when `/v1/whoami` rejects the access key.
final class SignInException implements Exception {
  /// Creates the error shown on the sign-in screen.
  const SignInException(this.message);

  /// Operator-facing text; never includes the bearer token.
  final String message;

  @override
  String toString() => message;
}

/// Pings `GET <baseUrl>/health` without Authorization.
///
/// Matches the Immich-style server check: five-second timeout, success only on
/// HTTP 200. Any other status or socket error becomes [HealthCheckException]
/// with the product copy from the step-31 pairing flow.
Future<void> pingHealth(Uri baseUrl) async {
  final uri = baseUrl.replace(path: '/health', query: '');
  final client = HttpClient();
  try {
    final response = await () async {
      final request = await client.getUrl(uri);
      return request.close();
    }().timeout(const Duration(seconds: 5));
    if (response.statusCode != HttpStatus.ok) {
      throw const HealthCheckException(
        "Can't reach this server. Check the address and that the server is running.",
      );
    }
    await response.drain<void>();
  } on HealthCheckException {
    rethrow;
  } on Object {
    throw const HealthCheckException(
      "Can't reach this server. Check the address and that the server is running.",
    );
  } finally {
    client.close(force: true);
  }
}

/// Calls `GET <baseUrl>/v1/whoami` with `Authorization: Bearer <accessKey>`.
///
/// Returns [WhoAmIResult.userId] for [UlsyncClient.userScope]. HTTP 401 maps to
/// [SignInException] with the step-31 copy; the client must not open on failure.
Future<WhoAmIResult> fetchWhoAmI({
  required Uri baseUrl,
  required String accessKey,
}) async {
  final uri = baseUrl.replace(path: '/v1/whoami', query: '');
  final client = HttpClient();
  try {
    final response = await () async {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessKey');
      return request.close();
    }().timeout(const Duration(seconds: 5));
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 5));
    if (response.statusCode == HttpStatus.unauthorized) {
      throw const SignInException("Couldn't sign in. Check the access key.");
    }
    if (response.statusCode != HttpStatus.ok) {
      throw SignInException(
        "Couldn't sign in. Server returned ${response.statusCode}.",
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const SignInException("Couldn't sign in. Invalid whoami response.");
    }
    final map = Map<String, Object?>.from(decoded);
    final userId = map['user_id'];
    if (userId is! String || userId.isEmpty) {
      throw const SignInException("Couldn't sign in. Invalid whoami response.");
    }
    return WhoAmIResult(userId: userId);
  } on SignInException {
    rethrow;
  } on Object {
    throw const SignInException("Couldn't sign in. Check the access key.");
  } finally {
    client.close(force: true);
  }
}
