/// Unit tests for [readJwtExpiry]: open `exp` claim, no signature verify.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync/src/transport/jwt_expiry.dart';

/// Builds a compact JWT with an unsigned payload. Not a real signature.
String mintJwt({Object? exp, Map<String, Object?> extra = const {}}) {
  String encode(String text) =>
      base64Url.encode(utf8.encode(text)).replaceAll('=', '');
  final header = encode('{"alg":"none","typ":"JWT"}');
  final payload = <String, Object?>{...extra};
  if (exp != null) {
    payload['exp'] = exp;
  }
  return '$header.${encode(jsonEncode(payload))}.sig';
}

void main() {
  test('readJwtExpiry reads integer exp as UTC seconds, not milliseconds', () {
    final exp = DateTime.utc(2026, 9, 4, 12);
    final seconds = exp.millisecondsSinceEpoch ~/ 1000;
    expect(readJwtExpiry(mintJwt(exp: seconds)), exp);
  });

  test('readJwtExpiry returns null on garbage and on a token without exp', () {
    expect(readJwtExpiry('not-a-jwt'), isNull);
    expect(readJwtExpiry('only.two'), isNull);
    expect(readJwtExpiry('a.b.c.d'), isNull);
    expect(readJwtExpiry(mintJwt()), isNull);
    expect(readJwtExpiry(mintJwt(exp: 'soon')), isNull);
    expect(readJwtExpiry(mintJwt(exp: 1.5)), isNull);
  });
}
